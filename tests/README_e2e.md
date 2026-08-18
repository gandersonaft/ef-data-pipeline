# Local end-to-end testing with a live Survey123 submission

The pytest suite (`test_webhook.py`/`test_qc.py`) mocks Postgres, ArcGIS, and Supabase Storage entirely,
so it never needs live credentials. This document covers the separate, manual step of testing against a
**real** Survey123 submission.

The webhook payload shape, the CRC handshake, and the POST signature scheme are now **confirmed** (see
`app/esri.py`'s module docstring and the "Confirmed AGOL webhook behavior" section in the top-level
README) — this doc no longer needs to walk through discovering them, just how to exercise the pipeline
end to end.

## 1. Run the API

Either locally with a tunnel, or against the deployed Render service — either works for this walkthrough.

**Locally:**
```bash
pip install -r app/requirements.txt
cp .env.example .env   # fill in real DATABASE_URL / SUPABASE_* / ARCGIS_* / WEBHOOK_SHARED_SECRET
uvicorn app.main:app --reload
ngrok http 8000        # or: npx localtunnel --port 8000
```
Note the public HTTPS URL ngrok/localtunnel gives you, e.g. `https://abcd1234.ngrok-free.app`.

**Or just use the deployed Render URL** if one already exists for this project — check with whoever set
it up, or `https://ef-data-pipeline-webhook.onrender.com` if it's still the same service.

## 2. Register the webhook in ArcGIS Online — manual prerequisite

This is a setup step in ArcGIS Online that **cannot be automated by this codebase** — it has to be done
through the AGOL UI against your own AGOL credentials, on the **feature layer item** (not a Survey123-
item-level webhook — the two have different payload shapes, see the README):

1. Go to the `efish_neps_v8` hosted feature layer item in ArcGIS Online (item
   `8533e51b881b43b4b7281ff5753d42e2`, "Electrofishing Data Entry Prototype V2").
2. **Settings → Webhooks** → add a new webhook.
3. Payload URL: `<your base URL>/webhook/survey123`.
4. Select all layers/tables if possible (main layer, `rep_pass`, `rep_fish`, `rep_photos`, `rep_widths`)
   — a single submission touches all of them, and each fires its own notification.
5. Signing secret: the same value as `WEBHOOK_SHARED_SECRET` in your `.env`.
6. Save. AGOL immediately sends a CRC validation `GET` to your payload URL — if the webhook shows as
   enabled/active afterward, the handshake succeeded. If it doesn't, check your service logs for a `GET
   /webhook/survey123?crc_token=...` request and what it returned; it must be `{"response_token":
   "sha256=<base64 HMAC-SHA256(secret, crc_token)>"}` within 5 seconds.

## 3. Submit a real test survey

Fill out and submit `efish_neps_v8` via the Survey123 field app (or the Survey123 web app), with at least
2 passes and a few fish per pass, plus a site photo.

## 4. Watch what arrives

Check the `webhook_log` table (`select id, received_at, status, error_detail from webhook_log order by
received_at desc limit 10;`) — expect up to 5 rows for one submission (one per touched layer). Then check:

- Did the resulting rows in `electrofishing_events`, `electrofishing_runs`, `fish_records`,
  `site_photos`, `site_width_measurements` look right?
- Did the uploaded photo land in Supabase Storage at the expected
  `electrofishing/{year}/{site_code}/{global_id}.{ext}` path, and does a signed URL for it resolve?
- Is `electrofishing_events.qc_status`/`qc_flags` populated as expected given what you submitted?
- Any rows with `status='error'`? Check `error_detail` — `scripts/reprocess_webhook_log.py` can replay
  them once the underlying issue is fixed.

## 5. Iterate

Fix whatever a real submission reveals, resubmit, and repeat until it round-trips cleanly — event
inserted, runs/fish inserted, photo uploaded and a `site_photos` row created, QC flags computed
correctly, and no `status='error'` rows left behind.
