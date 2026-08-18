# Local end-to-end testing with a live Survey123 submission

The pytest suite (`test_webhook.py`/`test_qc.py`) mocks Postgres, ArcGIS, and Supabase Storage entirely,
so it never needs live credentials. This document covers the separate, manual step of testing against a
**real** Survey123 submission — which is also how you resolve the biggest open unknown in this project:
**whether ArcGIS Online delivers the full nested submission tree in a single webhook POST, or fires
separately per edited sub-layer** (see `app/esri.py`'s module docstring). The receiver is written to
handle either case, but that needs confirming against a real delivery before you can trust the happy path
in production.

## 1. Run the API locally

```bash
pip install -r app/requirements.txt
cp .env.example .env   # fill in real DATABASE_URL / SUPABASE_* / ARCGIS_* / WEBHOOK_SHARED_SECRET
uvicorn app.main:app --reload
```

## 2. Expose it publicly

```bash
ngrok http 8000
```

(or `npx localtunnel --port 8000`). Note the public HTTPS URL it gives you, e.g.
`https://abcd1234.ngrok-free.app`.

## 3. Register the webhook in ArcGIS Online — manual prerequisite

This is a one-time setup step in ArcGIS Online that **cannot be automated by this codebase** — it has to
be done through the AGOL UI (or the REST admin `addWebhook` operation) against your own AGOL credentials:

1. Go to the item `8533e51b881b43b4b7281ff5753d42e2` ("Electrofishing Data Entry Prototype V2") in
   ArcGIS Online.
2. Settings → Webhooks (or use the `addWebhook` REST admin operation directly against the feature
   service).
3. Set the payload URL to `https://abcd1234.ngrok-free.app/webhook/survey123`.
4. Select the layers/events to trigger on (the main layer at minimum; ideally all of it — main layer,
   `rep_pass`, `rep_fish`, `rep_photos`, `rep_widths` — so you can observe whichever delivery behavior AGOL
   actually uses).
5. Set a signing secret matching `WEBHOOK_SHARED_SECRET` in your `.env`. **The exact header name/scheme
   AGOL uses for the signature is unconfirmed** — `app/esri.py`'s `verify_webhook_signature()` assumes a
   hex-encoded HMAC-SHA256 in a header; check what AGOL's webhook config UI actually documents when you
   set this up, and adjust `verify_webhook_signature()`/the header name read in `main.py` to match. (In
   `ENVIRONMENT=development`, `main.py` skips signature verification entirely so you can test the rest of
   the pipeline before this is nailed down.)

## 4. Submit a real test survey

Fill out and submit `efish_neps_v8` via the Survey123 field app (or the Survey123 web app), with at least
2 passes and a few fish per pass, plus a site photo.

## 5. Watch what actually arrives

Tail the `uvicorn` logs, and check the `webhook_log` table (`select * from webhook_log order by
received_at desc limit 5;`) for the raw payload AGOL sent. Specifically check:

- **Does the payload already contain `event`/`rep_pass`/`rep_fish`/`rep_photos`/`rep_widths` as a single
  nested tree** (matching `tests/fixtures/sample_survey123_payload.json`'s shape), or does it only carry
  a single edited layer/row, requiring the `esri.fetch_full_submission()` fallback in `main.py`'s
  `normalize_payload()`?
- If it's the fallback case: does `_extract_event_global_id()` in `app/main.py` correctly locate the
  event's globalid from the real envelope shape? This function currently makes a best-effort guess at a
  couple of plausible shapes — update it once you've seen a real payload.
- Is `globalid`/`GlobalID` field casing what `app/models.py` assumes (lowercase)? Adjust the Pydantic
  field aliases if not.
- Did the resulting rows in `electrofishing_events`, `electrofishing_runs`, `fish_records`,
  `site_photos`, `site_width_measurements` look right, and did the uploaded photo land in Supabase
  Storage at the expected `electrofishing/{year}/{site_code}/{global_id}.{ext}` path?

## 6. Iterate

Fix whatever the real payload shape reveals, resubmit, and repeat until a live Survey123 submission
round-trips cleanly end to end (event inserted, runs/fish inserted, photo uploaded and a `site_photos` row
created, QC flags computed correctly).
