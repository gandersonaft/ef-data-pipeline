"""
FastAPI webhook receiver for Survey123 (efish_neps_v8) submissions.

Confirmed against a live webhook (see esri.py's module docstring for
citations): the hosted-feature-layer webhook sends a compact per-layer
change notification (not the full submission), up to 5 times per Survey123
submission (once per touched layer: event, rep_pass, rep_fish, rep_photos,
rep_widths). `normalize_payload()` resolves each notification to its
event's globalid via `esri.resolve_event_global_id()`, then pulls that
event's complete current tree via `esri.fetch_full_submission()`. Because
crud.py's upserts are all `ON CONFLICT (global_id) DO UPDATE`, reprocessing
the same event 5x (once per notification) is safe and self-healing rather
than something that needs de-duplicating.

The `GET /webhook/survey123` route below is Esri's CRC (Challenge-Response
Check) handshake, performed at webhook creation AND "regularly" thereafter
per Esri's docs — it must stay live permanently, not just during setup.
"""

from __future__ import annotations

import json

import asyncpg
import httpx
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import ValidationError

from app import crud, esri, qc, storage, webhook_log
from app.config import get_settings
from app.db import get_pool, lifespan, transaction
from app.esri import normalize_guid
from app.models import (
    EventAttributes,
    FishAttributes,
    Geometry,
    NormalizedSubmission,
    PhotoAttributes,
    RunAttributes,
    RunWithFish,
    WidthAttributes,
)

app = FastAPI(title="EF Data Pipeline Webhook Receiver", lifespan=lifespan)


# --- dependency indirection, so tests can swap in mocks via app.dependency_overrides ---

def get_esri():
    return esri


def get_storage():
    return storage


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/webhook/survey123")
async def crc_challenge(crc_token: str, esri_mod=Depends(get_esri)):
    """Esri's CRC handshake — sent at webhook creation and periodically
    thereafter. Must respond within 5s or AGOL considers the webhook invalid
    and stops delivering events. See esri.py's module docstring."""
    return {"response_token": esri_mod.compute_crc_response_token(crc_token)}


def _attrs(feature) -> dict:
    """Accepts either a bare attributes dict (our own assembled envelope shape,
    matching test fixtures) or an Esri {"attributes": {...}} feature wrapper
    (returned by esri.fetch_full_submission's queryRelatedRecords fallback)."""
    return feature["attributes"] if isinstance(feature, dict) and "attributes" in feature else feature


async def normalize_payload(payload: dict, esri_mod) -> NormalizedSubmission:
    if "event" in payload and "rep_pass" in payload:
        # Our own assembled envelope shape (used by tests/fixtures) — parse directly.
        tree = payload
    elif "layerId" in payload and "changesUrl" in payload:
        # Real AGOL feature-layer webhook notification (see esri.py docstring).
        token = await esri_mod.get_token()
        event_global_id = await esri_mod.resolve_event_global_id(payload, token)
        tree = await esri_mod.fetch_full_submission(event_global_id, token)
    else:
        raise ValueError(f"Unrecognized webhook payload shape: keys={sorted(payload.keys())}")

    event_feature = tree["event"]
    event = EventAttributes.model_validate(_attrs(event_feature))
    geometry = None
    if isinstance(event_feature, dict) and event_feature.get("geometry"):
        geometry = Geometry.model_validate(event_feature["geometry"])

    pass_list = [RunAttributes.model_validate(_attrs(p)) for p in tree.get("rep_pass", [])]
    fish_list = [FishAttributes.model_validate(_attrs(f)) for f in tree.get("rep_fish", [])]
    photo_list = [PhotoAttributes.model_validate(_attrs(p)) for p in tree.get("rep_photos", [])]
    width_list = [WidthAttributes.model_validate(_attrs(w)) for w in tree.get("rep_widths", [])]

    runs = [
        RunWithFish(
            run=run,
            fish=[f for f in fish_list if normalize_guid(f.parentglobalid) == normalize_guid(run.globalid)],
        )
        for run in pass_list
    ]

    return NormalizedSubmission(
        event=event, geometry=geometry, runs=runs, photos=photo_list, widths=width_list, raw_payload=payload
    )


async def _download_and_upload_photos(submission: NormalizedSubmission, esri_mod, storage_mod) -> list[tuple]:
    """Network I/O for attachments, done BEFORE the DB transaction opens."""
    settings = get_settings()
    rep_photos_url = f"{settings.agol_feature_service_url.rstrip('/')}/1"  # rep_photos = related table id 1

    uploads: list[tuple] = []
    for photo in submission.photos:
        if photo.objectid is None:
            continue
        token = await esri_mod.get_token()
        attachments = await esri_mod.list_attachments(rep_photos_url, photo.objectid, token)
        for att in attachments:
            content, content_type = await esri_mod.download_attachment(
                rep_photos_url, photo.objectid, att.attachment_id, token
            )
            ext = storage_mod.ext_from_content_type(content_type)
            path = storage_mod.build_storage_path(
                submission.event.survey_date, submission.event.effective_site_code(),
                normalize_guid(photo.globalid), ext,
            )
            await storage_mod.upload_photo(content, content_type, path)
            url = storage_mod.sign_url(path)
            uploads.append((photo, path, url, content_type))
    return uploads


@app.post("/webhook/survey123")
async def receive_survey123(
    request: Request,
    pool: asyncpg.Pool = Depends(get_pool),
    esri_mod=Depends(get_esri),
    storage_mod=Depends(get_storage),
):
    raw = await request.body()
    settings = get_settings()
    headers = dict(request.headers)

    # Log first, verify/parse after: we're still discovering the exact wire
    # format for some webhook sources (e.g. Survey123 item-level webhooks may
    # sign differently than feature-layer ones), so every delivery attempt
    # must be captured for inspection even if it fails signature/JSON
    # parsing -- an unrecognized delivery we can't debug is worse than one
    # extra logged row.
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        log_id = await webhook_log.log_received(
            pool, {"_raw_body_text": raw.decode("utf-8", errors="replace")}, headers=headers
        )
        await webhook_log.mark_error(pool, log_id, "payload was not valid JSON")
        return JSONResponse(status_code=200, content={"status": "rejected", "detail": "invalid JSON"})

    log_id = await webhook_log.log_received(pool, payload, headers=headers)

    # Confirmed 2026-08-18: Survey123 item-level webhooks have no secret/
    # signing-key field at all in their setup UI, unlike feature-layer
    # webhooks -- so they never send x-esriHook-Signature. Enforcing
    # verification unconditionally would permanently 401 every Survey123-
    # level delivery. Trade-off: verify strictly when a signature IS present
    # (protects the feature-layer webhook, which does sign), but accept
    # unsigned requests rather than blocking this webhook type outright.
    # Revisit if this endpoint needs stronger protection later (e.g. an
    # Esri egress IP allowlist) -- right now correctness of the ingestion
    # path matters more than defending an endpoint with no real attacker
    # incentive yet.
    signature_header = headers.get("x-esrihook-signature", "")
    if (
        settings.environment != "development"
        and signature_header
        and not esri_mod.verify_webhook_signature(raw, signature_header)
    ):
        await webhook_log.mark_error(pool, log_id, "invalid signature")
        raise HTTPException(status_code=401, detail="invalid signature")

    try:
        submission = await normalize_payload(payload, esri_mod)
        photo_uploads = await _download_and_upload_photos(submission, esri_mod, storage_mod)

        async with transaction(pool) as conn:
            site_id = await crud.upsert_site(conn, submission.event)
            event_id = await crud.upsert_event(conn, submission, site_id)
            run_id_map = await crud.upsert_runs(conn, event_id, submission.runs)
            fish_rows = await crud.upsert_fish(conn, run_id_map, submission.runs)
            await crud.upsert_widths(conn, event_id, submission.widths)
            await crud.upsert_photos(conn, event_id, photo_uploads)

            run_pass_no = {
                run_id_map[normalize_guid(rwf.run.globalid)]: rwf.run.pass_no for rwf in submission.runs
            }
            pass_flags = qc.check_pass_progression(fish_rows, run_pass_no)
            k_flags = qc.check_condition_factor(fish_rows)
            status, flags = qc.summarize(pass_flags, k_flags)
            await crud.update_qc(conn, event_id, status, flags)

        await webhook_log.mark_processed(pool, log_id)
        return {
            "event_id": event_id,
            "runs": len(run_id_map),
            "fish": len(fish_rows),
            "photos": len(photo_uploads),
            "qc_status": status,
            "qc_flags": flags,
        }

    except (ValidationError, ValueError) as e:
        await webhook_log.mark_error(pool, log_id, str(e))
        # Don't trigger an AGOL retry storm for data the payload will never fix on redelivery.
        return JSONResponse(status_code=200, content={"status": "rejected", "detail": str(e)})

    except (asyncpg.PostgresError, OSError, httpx.HTTPError) as e:
        await webhook_log.mark_error(pool, log_id, str(e))
        # Transient infra error — let AGOL's retry/backoff kick in.
        raise HTTPException(status_code=500, detail="transient error, retry") from e
