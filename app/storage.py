from __future__ import annotations

import re
from datetime import date

from supabase import Client, create_client

from app.config import get_settings

# Real site codes are free-text (e.g. "3 fishfarm", "6c allt a mhagarain") and
# can contain spaces and other characters that are fragile as raw URL path
# segments -- confirmed 2026-08-18: a space in a stored path broke the Shiny
# app's signed-URL generation (httr2 didn't auto-encode it, curl rejected the
# resulting URL outright as malformed). Collapse anything outside
# alphanumerics/dash/underscore to a single underscore at the source, so every
# consumer of storage_path (this API, the Shiny app, anyone else) gets a
# clean, portable key rather than each needing its own encoding workaround.
_UNSAFE_PATH_CHARS = re.compile(r"[^A-Za-z0-9_-]+")


def get_storage_client() -> Client:
    settings = get_settings()
    return create_client(settings.supabase_url, settings.supabase_service_key)


def build_storage_path(survey_date: date, site_code: str, global_id: str, ext: str) -> str:
    """
    electrofishing/{year}/{site_code}/{global_id}.{ext}

    Deterministic from the photo's own GlobalID, so a webhook retry re-uploads
    to the same path (upsert=True in upload_photo) instead of duplicating.
    """
    safe_site_code = _UNSAFE_PATH_CHARS.sub("_", site_code).strip("_")
    return f"electrofishing/{survey_date.year}/{safe_site_code}/{global_id}.{ext}"


def ext_from_content_type(content_type: str) -> str:
    return {
        "image/jpeg": "jpg",
        "image/jpg": "jpg",
        "image/png": "png",
        "image/heic": "heic",
        "image/webp": "webp",
    }.get(content_type.lower(), "bin")


async def upload_photo(content: bytes, content_type: str, path: str) -> None:
    settings = get_settings()
    client = get_storage_client()
    client.storage.from_(settings.storage_bucket).upload(
        path,
        content,
        {"content-type": content_type, "upsert": "true"},
    )


def sign_url(path: str) -> str:
    """
    Bucket is private (per design decision) — generate a short-lived signed
    URL rather than relying on a permanent public URL. Called both right
    after upload (to populate site_photos.photo_url as a cache) and again by
    the Shiny QC Review tab when the cached URL may have expired.
    """
    settings = get_settings()
    client = get_storage_client()
    result = client.storage.from_(settings.storage_bucket).create_signed_url(
        path, settings.signed_url_ttl_seconds
    )
    return result["signedURL"]
