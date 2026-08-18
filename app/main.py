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

from app import esri, processing, storage, webhook_log
from app.config import get_settings
from app.db import get_pool, lifespan
from app.models import NormalizedSubmission

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

    return processing.build_normalized_submission(tree, payload)


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
        result = await processing.process_submission(
            pool, esri_mod, storage_mod, submission, settings.agol_feature_service_url
        )
        await webhook_log.mark_processed(pool, log_id)
        return result

    except (ValidationError, ValueError) as e:
        await webhook_log.mark_error(pool, log_id, str(e))
        # Don't trigger an AGOL retry storm for data the payload will never fix on redelivery.
        return JSONResponse(status_code=200, content={"status": "rejected", "detail": str(e)})

    except (asyncpg.PostgresError, OSError, httpx.HTTPError) as e:
        await webhook_log.mark_error(pool, log_id, str(e))
        # Transient infra error — let AGOL's retry/backoff kick in.
        raise HTTPException(status_code=500, detail="transient error, retry") from e
