"""
ArcGIS Online integration: OAuth2 token management, the CRC (Challenge-
Response Check) webhook validation handshake, resolving a feature-service
webhook's compact per-layer change notification into the submission it
belongs to, the queryRelatedRecords-based full-tree fetch, attachment
download, and webhook signature verification.

Confirmed (2026-08-18, against a live webhook + Esri's own docs/sample code —
see https://developers.arcgis.com/rest/services-reference/online/web-hooks-security-feature-service/
and https://doc.arcgis.com/en/arcgis-online/reference/webhook-payloads.htm):

- The hosted-feature-layer webhook (registered on the layer item's Settings ->
  Webhooks tab, as opposed to a Survey123-item-level webhook) sends a small
  per-layer notification, NOT the full nested submission:
      {"name", "layerId", "orgId", "serviceName", "lastUpdatedTime",
       "changesUrl", "events": ["FeaturesCreated", ...]}
  `changesUrl` is URL-encoded and points at the Extract Changes operation
  (already carrying `async=true`) for that one layer. A single Survey123
  submission touches 5 layers (main event, rep_pass, rep_fish, rep_photos,
  rep_widths), so AGOL fires up to 5 of these notifications per submission —
  the "fires separately per edited sub-layer" case, confirmed for real.
- Esri performs a CRC handshake on webhook creation, and "regularly" (not a
  guaranteed interval) thereafter: `GET <payloadUrl>?crc_token=<token>`,
  expecting `{"response_token": "sha256=<base64 HMAC-SHA256(secret, token)>"}`
  back within 5 seconds. Get this wrong and AGOL stops sending events
  entirely — this isn't a one-time bootstrap step, the GET route must stay up
  permanently. See `main.py`'s `GET /webhook/survey123` route.
- POST delivery signing uses the same base64 HMAC-SHA256 scheme, in an
  `x-esriHook-Signature: sha256=<...>` header.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import time
import urllib.parse
from dataclasses import dataclass

import httpx

from app.config import get_settings

_TOKEN_URL = "https://www.arcgis.com/sharing/rest/oauth2/token"

_cached_token: str | None = None
_cached_token_expires_at: float = 0.0

# Layer ids per the efish_neps_v8 service definition (confirmed via the
# ArcGIS REST addToDefinition debug output when the form was published):
# 0 = main event layer, 1 = rep_photos, 2 = rep_widths, 3 = rep_pass
# (all direct children of the main layer), 4 = rep_fish (child of rep_pass,
# NOT of the main layer -- a submission's fish rows are one hop further away).
_DIRECT_CHILD_LAYER_IDS = {1, 2, 3}
_REP_FISH_LAYER_ID = 4
_REP_PASS_LAYER_ID = 3


def normalize_guid(raw: str | None) -> str | None:
    """Strip braces and lowercase an Esri GlobalID/ParentGlobalID for stable comparisons/storage."""
    if raw is None:
        return None
    return raw.strip().strip("{}").lower()


async def get_token() -> str:
    global _cached_token, _cached_token_expires_at

    if _cached_token and time.monotonic() < _cached_token_expires_at:
        return _cached_token

    settings = get_settings()
    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(
            _TOKEN_URL,
            data={
                "client_id": settings.arcgis_client_id,
                "client_secret": settings.arcgis_client_secret,
                "grant_type": "client_credentials",
                "f": "json",
            },
        )
        resp.raise_for_status()
        data = resp.json()

    if "error" in data:
        raise RuntimeError(f"ArcGIS token request failed: {data['error']}")

    _cached_token = data["access_token"]
    # refresh a little early to avoid racing expiry
    _cached_token_expires_at = time.monotonic() + int(data["expires_in"]) - 60
    return _cached_token


def compute_crc_response_token(crc_token: str) -> str:
    """The CRC handshake response value for GET /webhook/survey123?crc_token=...  """
    settings = get_settings()
    digest = hmac.new(
        settings.webhook_shared_secret.encode("utf-8"), crc_token.encode("utf-8"), hashlib.sha256
    ).digest()
    return "sha256=" + base64.b64encode(digest).decode("utf-8")


def verify_webhook_signature(raw_body: bytes, signature_header: str) -> bool:
    """Verifies the `x-esriHook-Signature: sha256=<base64 HMAC-SHA256>` header."""
    if not signature_header:
        return False

    settings = get_settings()
    digest = hmac.new(settings.webhook_shared_secret.encode("utf-8"), raw_body, hashlib.sha256).digest()
    expected = "sha256=" + base64.b64encode(digest).decode("utf-8")
    return hmac.compare_digest(expected, signature_header)


@dataclass
class AttachmentMeta:
    attachment_id: str
    name: str
    content_type: str


async def list_attachments(layer_url: str, object_id: int, token: str) -> list[AttachmentMeta]:
    url = f"{layer_url}/{object_id}/attachments"
    async with httpx.AsyncClient(timeout=15.0) as client:
        resp = await client.get(url, params={"f": "json", "token": token})
        resp.raise_for_status()
        data = resp.json()

    return [
        AttachmentMeta(
            attachment_id=str(a["id"]),
            name=a.get("name", ""),
            content_type=a.get("contentType", "application/octet-stream"),
        )
        for a in data.get("attachmentInfos", [])
    ]


async def download_attachment(layer_url: str, object_id: int, attachment_id: str, token: str) -> tuple[bytes, str]:
    """Download an attachment fully in-memory. Returns (content_bytes, content_type)."""
    url = f"{layer_url}/{object_id}/attachments/{attachment_id}"
    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.get(url, params={"token": token})
        resp.raise_for_status()
        content_type = resp.headers.get("content-type", "application/octet-stream")
        return resp.content, content_type


async def _run_extract_changes(client: httpx.AsyncClient, changes_url: str, token: str) -> list[dict]:
    """
    changesUrl (from a webhook notification) carries async=true, so fetching
    it submits an Extract Changes job rather than returning results directly.
    Poll the returned statusUrl until it completes, then fetch resultUrl.
    Returns the result's "edits" list: one entry per touched layer, each
    with {"id": <layerId>, "objectIds": {"adds": [...], "updates": [...],
    "deletes": [...]}}.
    """
    resp = await client.get(changes_url, params={"token": token})
    resp.raise_for_status()
    data = resp.json()

    status_url = data.get("statusUrl")
    if status_url is None:
        # Already resolved (unlikely given async=true, but handle it).
        result_url = data.get("resultUrl")
        if not result_url:
            raise RuntimeError(f"Unexpected extractChanges response, no statusUrl/resultUrl: {data}")
    else:
        result_url = None
        for _ in range(30):  # ~30s cap; see module docstring re: request latency
            status_resp = await client.get(status_url, params={"f": "json", "token": token})
            status_resp.raise_for_status()
            status_data = status_resp.json()
            status = status_data.get("status")
            if status == "Completed":
                result_url = status_data["resultUrl"]
                break
            if status in ("Failed", "Cancelled"):
                raise RuntimeError(f"extractChanges job {status}: {status_data}")
            await asyncio.sleep(1)
        if result_url is None:
            raise TimeoutError("extractChanges job did not complete within 30s")

    result_resp = await client.get(result_url, params={"token": token})
    result_resp.raise_for_status()
    return result_resp.json().get("edits", [])


async def _query_layer_by_object_ids(
    client: httpx.AsyncClient, base: str, layer_id: int, object_ids: list[int], token: str
) -> list[dict]:
    if not object_ids:
        return []
    resp = await client.get(
        f"{base}/{layer_id}/query",
        params={
            "f": "json",
            "token": token,
            "objectIds": ",".join(str(i) for i in object_ids),
            "outFields": "*",
            "returnGeometry": "true",
        },
    )
    resp.raise_for_status()
    return resp.json().get("features", [])


async def resolve_event_global_id(notification: dict, token: str) -> str:
    """
    Resolves a per-layer webhook notification down to the main event's
    globalid, by extracting the changed feature(s) and walking up the
    parentglobalid chain as needed (rep_fish is two hops from the event:
    rep_fish -> rep_pass -> event).
    """
    settings = get_settings()
    base = settings.agol_feature_service_url.rstrip("/")
    layer_id = notification["layerId"]
    changes_url = urllib.parse.unquote(notification["changesUrl"])

    async with httpx.AsyncClient(timeout=45.0) as client:
        edits = await _run_extract_changes(client, changes_url, token)
        layer_edit = next((e for e in edits if e.get("id") == layer_id), None)
        if not layer_edit:
            raise ValueError(f"No edits found for layer {layer_id} in extractChanges result: {edits}")

        object_ids = list(layer_edit.get("objectIds", {}).get("adds", []))
        object_ids += list(layer_edit.get("objectIds", {}).get("updates", []))
        if not object_ids:
            raise ValueError(f"No added/updated objectIds for layer {layer_id}: {layer_edit}")

        features = await _query_layer_by_object_ids(client, base, layer_id, object_ids, token)
        if not features:
            raise ValueError(f"Could not fetch features for layer {layer_id}, objectIds {object_ids}")

        attrs = features[0]["attributes"]

        if layer_id == 0:
            return normalize_guid(attrs["globalid"])

        if layer_id in _DIRECT_CHILD_LAYER_IDS:
            return normalize_guid(attrs["parentglobalid"])

        if layer_id == _REP_FISH_LAYER_ID:
            pass_global_id = normalize_guid(attrs["parentglobalid"])
            pass_resp = await client.get(
                f"{base}/{_REP_PASS_LAYER_ID}/query",
                params={
                    "f": "json",
                    "token": token,
                    "where": f"globalid='{{{pass_global_id}}}'",
                    "outFields": "parentglobalid",
                },
            )
            pass_resp.raise_for_status()
            pass_features = pass_resp.json().get("features", [])
            if not pass_features:
                raise ValueError(f"Could not find rep_pass row for globalid {pass_global_id}")
            return normalize_guid(pass_features[0]["attributes"]["parentglobalid"])

        raise ValueError(f"Unrecognized layerId {layer_id} in webhook notification")


async def fetch_full_submission(event_global_id: str, token: str) -> dict:
    """
    Given an event's globalid, pulls its complete current tree (event, all
    passes, all fish, all photos, all widths) via queryRelatedRecords.
    Idempotent by design: called once per webhook notification (main.py may
    call it up to 5x per submission, once per touched layer), and every call
    re-fetches the full current state, so redundant calls just re-upsert the
    same rows via crud.py's ON CONFLICT logic rather than causing duplicates
    or requiring de-duplication/coordination between notifications.
    """
    settings = get_settings()
    base = settings.agol_feature_service_url.rstrip("/")

    async with httpx.AsyncClient(timeout=30.0) as client:
        event_resp = await client.get(
            f"{base}/0/query",
            params={
                "f": "json",
                "token": token,
                "where": f"globalid='{{{event_global_id}}}'",
                "outFields": "*",
                "returnGeometry": "true",
            },
        )
        event_resp.raise_for_status()
        event_features = event_resp.json().get("features", [])
        if not event_features:
            raise ValueError(f"No event found for globalid {event_global_id}")
        event_feature = event_features[0]
        event_object_id = event_feature["attributes"]["objectid"]

        async def related(layer_id: int) -> list[dict]:
            r = await client.get(
                f"{base}/0/queryRelatedRecords",
                params={
                    "f": "json",
                    "token": token,
                    "objectIds": event_object_id,
                    "relationshipId": layer_id,
                    "outFields": "*",
                },
            )
            r.raise_for_status()
            groups = r.json().get("relatedRecordGroups", [])
            if not groups:
                return []
            return groups[0].get("relatedRecords", [])

        # relationship ids per the service definition: rep_photos=1, rep_widths=2, rep_pass=3
        photos = await related(1)
        widths = await related(2)
        passes = await related(3)

        fish: list[dict] = []
        for p in passes:
            pass_object_id = p["attributes"]["objectid"]
            r = await client.get(
                f"{base}/3/queryRelatedRecords",
                params={
                    "f": "json",
                    "token": token,
                    "objectIds": pass_object_id,
                    "relationshipId": 0,  # rep_pass_rep_fish
                    "outFields": "*",
                },
            )
            r.raise_for_status()
            groups = r.json().get("relatedRecordGroups", [])
            if groups:
                fish.extend(groups[0].get("relatedRecords", []))

    return {
        "event": event_feature,
        "rep_pass": passes,
        "rep_fish": fish,
        "rep_photos": photos,
        "rep_widths": widths,
    }
