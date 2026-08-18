"""
Polling fallback for when ArcGIS Online's webhook delivery isn't working.

Context: as of 2026-08-18, AGOL produced zero webhook delivery attempts
(confirmed via webhook_log staying empty AND Render's raw request logs
showing no incoming traffic at all) across TWO independent, correctly-
configured webhook mechanisms (a feature-layer webhook and a Survey123
item-level webhook), despite real, confirmed Survey123 submissions landing
in the feature service. Everything checkable without ArcGIS org-admin
access was ruled out (payload URL, trigger events, source-vs-view, change
tracking, CRC handshake, unsigned-delivery handling). This script sidesteps
the whole webhook question: it just asks the feature service "what's new"
on a schedule, using the same queryRelatedRecords logic the webhook path
uses once it *does* know which event to fetch.

How it works: tracks a high-water mark (poll_state.last_object_id) against
the main survey layer's auto-incrementing objectid. Each run, queries for
objectid > high-water-mark, and for each new event found, pulls its full
submission tree via esri.fetch_full_submission() and runs it through the
same upsert+QC pipeline the webhook uses (app/processing.py) -- so there's
exactly one code path for "what happens once we know an event's globalid",
shared between both entry points.

Scope note: this only catches NEW submissions (FeaturesCreated), not edits
to already-processed ones -- matching electrofishing survey data, which is
essentially write-once in practice. If edit-tracking is ever needed, extend
the query to also check EditDate against the last poll time.

Idempotent and safe to run as often as you like or to re-run after a
failure: the high-water mark only advances after a batch fully succeeds,
and every upsert in the pipeline is ON CONFLICT-based.

Usage:
    python scripts/poll_submissions.py

Intended to run on a schedule (Render Cron Job, GitHub Actions scheduled
workflow, plain OS cron, etc. -- see README for options). Requires the same
env vars as the main API: DATABASE_URL, ARCGIS_CLIENT_ID/SECRET,
AGOL_FEATURE_SERVICE_URL, SUPABASE_URL, SUPABASE_SERVICE_KEY, STORAGE_BUCKET.
"""

from __future__ import annotations

import asyncio

import asyncpg
import httpx

from app import esri, processing, storage
from app.config import get_settings


async def _get_last_object_id(conn: asyncpg.Connection) -> int:
    row = await conn.fetchrow("select last_object_id from poll_state where key = 'main_layer'")
    return row["last_object_id"] if row else 0


async def _set_last_object_id(conn: asyncpg.Connection, object_id: int) -> None:
    await conn.execute(
        """
        insert into poll_state (key, last_object_id, updated_at) values ('main_layer', $1, now())
        on conflict (key) do update set last_object_id = excluded.last_object_id, updated_at = now()
        """,
        object_id,
    )


async def list_new_events(base: str, since_object_id: int, token: str) -> list[dict]:
    async with httpx.AsyncClient(timeout=30.0) as client:
        resp = await client.get(
            f"{base}/0/query",
            params={
                "f": "json",
                "token": token,
                "where": f"objectid > {since_object_id}",
                "outFields": "objectid,globalid",
                "orderByFields": "objectid ASC",
                "returnGeometry": "false",
            },
        )
        resp.raise_for_status()
        return resp.json().get("features", [])


async def main() -> None:
    settings = get_settings()
    pool = await asyncpg.create_pool(dsn=settings.database_url, min_size=1, max_size=2)
    base = settings.agol_feature_service_url.rstrip("/")

    try:
        async with pool.acquire() as conn:
            since_object_id = await _get_last_object_id(conn)

        token = await esri.get_token()
        new_features = await list_new_events(base, since_object_id, token)

        if not new_features:
            print(f"No new submissions since objectid {since_object_id}.")
            return

        print(f"Found {len(new_features)} new submission(s) since objectid {since_object_id}.")
        max_object_id = since_object_id

        for feature in new_features:
            attrs = feature["attributes"]
            object_id = attrs["objectid"]
            global_id = esri.normalize_guid(attrs["globalid"])

            tree = await esri.fetch_full_submission(global_id, token)
            submission = processing.build_normalized_submission(
                tree, {"_source": "poll", "objectid": object_id}
            )
            result = await processing.process_submission(
                pool, esri, storage, submission, settings.agol_feature_service_url
            )
            print(
                f"  objectid={object_id} globalid={global_id} -> "
                f"event_id={result['event_id']} qc_status={result['qc_status']}"
            )

            max_object_id = max(max_object_id, object_id)

        async with pool.acquire() as conn:
            await _set_last_object_id(conn, max_object_id)
        print(f"Updated high-water mark to objectid {max_object_id}.")

    finally:
        await pool.close()


if __name__ == "__main__":
    asyncio.run(main())
