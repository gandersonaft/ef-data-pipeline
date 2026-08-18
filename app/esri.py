"""
ArcGIS Online integration: OAuth2 token management, attachment download, the
queryRelatedRecords fallback for reassembling a full submission tree, and
webhook signature verification.

IMPORTANT — open risk (see plan / README): it is unverified whether an AGOL
webhook delivers the full nested submission (event + rep_pass[] + rep_fish[]
+ rep_photos[] + rep_widths[]) in a single POST, or fires separately per
edited sub-layer. `fetch_full_submission()` exists as the fallback path for
the latter case — see main.py's `normalize_payload()` for how the two paths
are selected. This must be confirmed against a live webhook delivery
(tests/README_e2e.md) before relying on either assumption in production.

Similarly, the exact webhook signature header name/scheme and the exact
casing of `globalid`/`GlobalID` in real payloads need confirming against the
live AGOL webhook configuration and a captured real payload — see
`verify_webhook_signature()` and `models.py` for where those assumptions
live.
"""

from __future__ import annotations

import hashlib
import hmac
import time
from dataclasses import dataclass

import httpx

from app.config import get_settings

_TOKEN_URL = "https://www.arcgis.com/sharing/rest/oauth2/token"

_cached_token: str | None = None
_cached_token_expires_at: float = 0.0


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


async def fetch_full_submission(event_global_id: str, token: str) -> dict:
    """
    Fallback for when a webhook delivery only contains a single edited layer's
    row(s) rather than the full nested tree. Uses queryRelatedRecords against
    the main layer and each related table (rep_pass, rep_fish nested under
    each pass, rep_photos, rep_widths), keyed by the event's globalid, and
    reassembles the same nested shape that a full-tree delivery would have.
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


def verify_webhook_signature(raw_body: bytes, signature_header: str) -> bool:
    """
    HMAC-SHA256 verification of the AGOL webhook payload against
    WEBHOOK_SHARED_SECRET. The exact header name/scheme AGOL uses must be
    confirmed against the live webhook configuration UI when the webhook is
    registered (tests/README_e2e.md) — this assumes a hex-encoded
    HMAC-SHA256 digest, the common convention, and should be adjusted to
    match whatever AGOL actually sends.
    """
    if not signature_header:
        return False

    settings = get_settings()
    expected = hmac.new(
        settings.webhook_shared_secret.encode("utf-8"), raw_body, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature_header)
