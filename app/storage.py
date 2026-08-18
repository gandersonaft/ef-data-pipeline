from __future__ import annotations

from datetime import date

from supabase import Client, create_client

from app.config import get_settings


def get_storage_client() -> Client:
    settings = get_settings()
    return create_client(settings.supabase_url, settings.supabase_service_key)


def build_storage_path(survey_date: date, site_code: str, global_id: str, ext: str) -> str:
    """
    electrofishing/{year}/{site_code}/{global_id}.{ext}

    Deterministic from the photo's own GlobalID, so a webhook retry re-uploads
    to the same path (upsert=True in upload_photo) instead of duplicating.
    """
    safe_site_code = site_code.replace("/", "_").replace("\\", "_")
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
