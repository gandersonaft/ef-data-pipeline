# EF Data Pipeline & DB

End-to-end data pipeline for NEPS electrofishing surveys:

```
Survey123 (efish_neps_v8)
    │  ArcGIS Online webhook (POST)
    ▼
FastAPI webhook receiver (app/)
    │  asyncpg transaction + Supabase Storage upload
    ▼
Supabase Postgres + PostGIS + Storage (supabase/)
    │  read-only pooled connection
    ▼
R Shiny reporting portal (shiny_app/)  →  Posit Connect / shinyapps.io
```

The Survey123 form this pipeline ingests lives at
`C:\Users\graem\ArcGIS\My Survey Designs\8533e51b881b43b4b7281ff5753d42e2\` (`form_id=efish_neps_v8`,
"NEPS Electrofishing Survey"). This project does not modify that form — it only consumes its submissions.

## Layout

- `supabase/` — `schema.sql` (DDL), `roles.sql` (least-privilege DB roles), `seed_sites.py` (loads
  `data/site_data.csv` into the `sites` table).
- `data/site_data.csv` — copy of the form's site lookup CSV (source: the XLSForm project's
  `media/site_data.csv`). Re-copy from there whenever the master site list changes, then re-run
  `seed_sites.py`.
- `app/` — FastAPI webhook receiver (`/webhook/survey123`) and the shared submission-processing pipeline
  (`app/processing.py`) used by both the webhook and the polling fallback below.
- `tests/` — pytest suite + fixtures + manual e2e testing notes (`tests/README_e2e.md`).
- `shiny_app/` — R Shiny reporting portal (3 tabs: Depletion & Density, Length-Frequency & Condition,
  QC & Photo Review).
- `scripts/reprocess_webhook_log.py` — replay failed webhook deliveries from the `webhook_log` table.
- `scripts/poll_submissions.py` — **polling fallback**, currently the primary ingestion path (see below).

## Quick start (local dev)

1. Copy `.env.example` → `.env` and fill in real values (Supabase connection string, ArcGIS OAuth
   client credentials, storage bucket name, webhook shared secret).
2. Apply the schema to your Supabase project (SQL editor, or `psql "$DATABASE_URL" -f supabase/schema.sql`
   then `-f supabase/roles.sql`).
3. Seed sites: `python supabase/seed_sites.py`
4. Install and run the API: `pip install -r app/requirements.txt && uvicorn app.main:app --reload`
5. Run tests: `pytest tests/`
6. For a real Survey123 round-trip test, see `tests/README_e2e.md`.
7. Run the Shiny app: copy `shiny_app/.Renviron.example` → `shiny_app/.Renviron`, fill in the
   `shiny_reader` credentials, then `R -e "shiny::runApp('shiny_app')"`.

## Deployment (Render)

The webhook receiver is deployed at `https://ef-data-pipeline-webhook.onrender.com` (Render web
service `ef-data-pipeline-webhook`, Python runtime, auto-deploys from `main`).

**Database connection gotcha that cost us a failed deploy, so it's written down here**: Supabase's
"direct" connection host (`db.<project-ref>.supabase.co:5432`) is IPv6-only unless you've paid for
Supabase's IPv4 add-on. Render — like Vercel, GitHub Actions, and Retool — has no IPv6 egress, so a
direct-host `DATABASE_URL` builds fine and then crashes on startup with `OSError: [Errno 101] Network
is unreachable` the instant asyncpg tries to connect. Use Supabase's **Supavisor pooler** instead
(session mode, port 5432): get the exact hostname from Supabase Dashboard → your project → **Connect**
→ Session pooler. Don't guess the hostname — it's `aws-<N>-<region>.pooler.supabase.com` where `<N>`
varies per project (we hit `aws-0-` for one eu-west-2 project when the correct value was `aws-1-`), and
a wrong guess fails with a *different*, confusing error (`tenant/user not found`) rather than a
DNS/network failure. The pooler username is always `<role>.<project-ref>`, not just `<role>`.

## Confirmed AGOL webhook behavior (was "unverified", now isn't)

Against a live webhook on the `efish_neps_v8` layer item (Settings → Webhooks), not a Survey123-item-
level webhook — these two have genuinely different payload shapes, see
[Esri's feature-layer webhook payload docs](https://doc.arcgis.com/en/arcgis-online/reference/webhook-payloads.htm)
vs. [Survey123's webhook docs](https://doc.arcgis.com/en/survey123/analyze/webhooks.htm):

- **AGOL fires a small per-layer change notification, not the full submission** —
  `{"name", "layerId", "orgId", "serviceName", "lastUpdatedTime", "changesUrl", "events"}` — up to 5
  times per Survey123 submission (once per touched layer: event, rep_pass, rep_fish, rep_photos,
  rep_widths). `app/esri.py`'s `resolve_event_global_id()` walks `changesUrl` (itself an async Extract
  Changes job — submit, poll `statusUrl`, fetch `resultUrl`) to find the changed feature, then climbs the
  `parentglobalid` chain (rep_fish is two hops from the event: rep_fish → rep_pass → event) down to the
  event's globalid, then hands off to the existing `fetch_full_submission()` queryRelatedRecords fetch.
  Every notification independently re-fetches and re-upserts the event's complete current tree, so
  getting all 5 for one submission (in any order, possibly interleaved with other submissions) is safe —
  no coordination between them is needed, `crud.py`'s `ON CONFLICT` upserts absorb the redundancy.
- **Esri performs a CRC (Challenge-Response Check) handshake** — `GET /webhook/survey123?crc_token=...`,
  expecting `{"response_token": "sha256=<base64 HMAC-SHA256(secret, crc_token)>"}` back within 5 seconds
  — at webhook creation **and periodically thereafter** (not just once at setup). Miss this and AGOL
  silently stops sending events. This is why the receiver has a permanent `GET` route alongside the
  `POST` one, not just a one-time verification step.
- **POST delivery signing** uses the header `x-esriHook-Signature: sha256=<base64 HMAC-SHA256 of the
  raw body>` — same algorithm as the CRC response, different header than originally guessed
  (`x-esri-webhook-signature`, hex-encoded — wrong on both counts).

## Polling fallback — currently the primary ingestion path

Despite everything above being confirmed correct against Esri's docs, **AGOL has produced zero webhook
delivery attempts** — not failures, zero attempts — across two independently-configured, correctly-set-up
webhook mechanisms (a feature-layer webhook and a Survey123 item-level webhook), verified by watching both
`webhook_log` and Render's raw request logs during real, confirmed Survey123 submissions. Every other
explanation was ruled out: payload URL, trigger events, source-vs-view, change tracking enabled, CRC
handshake working correctly when tested manually, unsigned-delivery handling. The org's own admin webhook
panel (Organization → Settings → Webhooks) would likely show more, but requires admin access not
available when this was diagnosed. Until that's resolved (admin conversation, or an Esri support case),
**`scripts/poll_submissions.py` is the real ingestion path**, not a backup:

- Tracks a high-water mark (`poll_state.last_object_id`) against the main layer's objectid.
- Each run, queries for `objectid > last_object_id`, and for each new event, calls
  `esri.fetch_full_submission()` (the same queryRelatedRecords fetch the webhook path uses) followed by
  the same `app/processing.py` upsert+QC pipeline — so there's exactly one code path for "what happens
  once we know an event's globalid," shared between both entry points.
- Only catches new submissions (`FeaturesCreated`), not edits to already-processed ones — acceptable
  since this survey data is essentially write-once in practice.
- Needs to run on a schedule (Render Cron Job, GitHub Actions scheduled workflow, plain OS cron — not yet
  decided/deployed as of this writing; run it manually until that's set up).

## Two real bugs this surfaced, worth knowing about if something looks off

- **Wrong relationship id silently dropped every fish record, on every submission, from day one.**
  `esri.fetch_full_submission()` queried `rep_pass`'s related `rep_fish` records using relationship id
  `0`, based on an earlier investigation that turned out to be wrong (or the service was republished with
  different numbering since). The real id, confirmed by querying each layer's `relationships` array
  directly (`GET {layer}?f=json`), is **4**. This didn't error — `queryRelatedRecords` with a
  nonexistent relationship id just returns no related records — so every submission "succeeded" with
  `fish: 0` and nothing looked broken until someone who knew the real catch counts noticed they were
  missing. If any layer's relationship/layer ids seem to misbehave again, re-verify against the live
  service; don't trust a prior note (including this one, after another republish).
- **One invalid fish row used to cost the entire submission.** This form has had required-field
  validation stripped for testing (see project history), so an incomplete row (e.g. missing `species`) is
  a real, confirmed occurrence, not a hypothetical. `build_normalized_submission()` used to validate all
  fish rows in one list comprehension, so a single bad row raised and lost the whole event — passes,
  other valid fish, photos, widths, everything. Now each row is validated individually; a bad one is
  skipped, counted (`NormalizedSubmission.skipped_fish`), and surfaced as an `incomplete_fish_record` QC
  flag rather than silently (or catastrophically) discarded.

## Known open items

- No `weight` field exists in the current form — `wet_weight_g`/`condition_factor` will be `NULL` for
  all real submissions today. The schema and Shiny app support it for when/if it's added to the form.
- Photos are site-level only (`rep_photos`), never per-fish.
- The Extract Changes polling in `resolve_event_global_id()` runs synchronously inside the request
  handler (up to ~30s cap). Moot while the webhook itself isn't delivering anything, but worth revisiting
  if/when it starts working.
- `scripts/poll_submissions.py` isn't yet deployed on a schedule anywhere — see "Polling fallback" above.
