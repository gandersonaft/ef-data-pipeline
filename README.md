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
- `app/` — FastAPI webhook receiver (`/webhook/survey123`).
- `tests/` — pytest suite + fixtures + manual e2e testing notes (`tests/README_e2e.md`).
- `shiny_app/` — R Shiny reporting portal (3 tabs: Depletion & Density, Length-Frequency & Condition,
  QC & Photo Review).
- `scripts/reprocess_webhook_log.py` — replay failed webhook deliveries from the `webhook_log` table.

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

## Known open items

- No `weight` field exists in the current form — `wet_weight_g`/`condition_factor` will be `NULL` for
  all real submissions today. The schema and Shiny app support it for when/if it's added to the form.
- Photos are site-level only (`rep_photos`), never per-fish.
- The Extract Changes polling in `resolve_event_global_id()` runs synchronously inside the request
  handler (up to ~30s cap). If AGOL's own delivery timeout turns out to be shorter than that in
  practice, this will need to move to a background task (`202 Accepted` immediately, process after) —
  worth watching once real submission volume tells us how long this actually takes.
