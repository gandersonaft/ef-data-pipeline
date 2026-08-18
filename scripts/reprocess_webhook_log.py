"""
Replay webhook_log rows with status='error' by resubmitting their stored
payload to the running FastAPI service's /webhook/survey123 endpoint.

Usage:
    python scripts/reprocess_webhook_log.py [--api-url http://localhost:8000] [--limit 20]

Requires DATABASE_URL in the environment (read-only access to webhook_log is
enough to select the payloads; the actual writes happen through the API, same
as a normal delivery, so upserts stay idempotent).
"""

from __future__ import annotations

import argparse
import asyncio
import os

import asyncpg
import httpx


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--api-url", default="http://localhost:8000")
    parser.add_argument("--limit", type=int, default=20)
    args = parser.parse_args()

    database_url = os.environ.get("DATABASE_URL")
    if not database_url:
        raise SystemExit("DATABASE_URL is not set")

    conn = await asyncpg.connect(database_url)
    try:
        rows = await conn.fetch(
            "select id, payload from webhook_log where status = 'error' order by received_at limit $1",
            args.limit,
        )
    finally:
        await conn.close()

    if not rows:
        print("No errored webhook_log rows to reprocess.")
        return

    async with httpx.AsyncClient(timeout=60.0) as client:
        for row in rows:
            resp = await client.post(f"{args.api_url}/webhook/survey123", content=row["payload"])
            print(f"webhook_log id={row['id']}: replayed, status={resp.status_code}, body={resp.text[:200]}")


if __name__ == "__main__":
    asyncio.run(main())
