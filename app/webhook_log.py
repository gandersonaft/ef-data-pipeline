"""
Operational log of webhook deliveries. Deliberately writes OUTSIDE the main
insert transaction (via its own pool connection) so a log entry survives even
when the submission's own transaction rolls back — that's what makes
scripts/reprocess_webhook_log.py able to find and replay `status='error'` rows.
"""

from __future__ import annotations

import json

import asyncpg


async def log_received(
    pool: asyncpg.Pool, payload: dict, event_global_id: str | None = None, headers: dict | None = None
) -> int:
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            "insert into webhook_log (event_global_id, payload, headers) values ($1, $2, $3) returning id",
            event_global_id, json.dumps(payload), json.dumps(headers) if headers is not None else None,
        )
        return row["id"]


async def mark_processed(pool: asyncpg.Pool, log_id: int) -> None:
    async with pool.acquire() as conn:
        await conn.execute("update webhook_log set status = 'processed' where id = $1", log_id)


async def mark_error(pool: asyncpg.Pool, log_id: int, detail: str) -> None:
    async with pool.acquire() as conn:
        await conn.execute(
            "update webhook_log set status = 'error', error_detail = $1 where id = $2",
            detail, log_id,
        )
