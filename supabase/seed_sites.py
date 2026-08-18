"""
Seed/upsert the `sites` table from data/site_data.csv.

Source CSV columns (copied from the Survey123 XLSForm project's
media/site_data.csv, which the form itself consumes via
`select_one_from_file site_data.csv` / `pulldata("site_data", ...)`):

    name, label, catchment, river, situation, easting, northing, x, y

`name` is the site code and is unique; re-running this script is safe and
will upsert rows whose `site_code` already exists (e.g. after refreshing the
CSV with a new master site list).

Usage:
    python supabase/seed_sites.py [path/to/site_data.csv]

Requires DATABASE_URL in the environment (or a .env file loaded by the
caller) pointing at a Postgres role with INSERT/UPDATE on `sites`
(webhook_writer is sufficient).
"""

from __future__ import annotations

import csv
import os
import sys
from pathlib import Path

import psycopg2
from psycopg2.extras import execute_values

DEFAULT_CSV_PATH = Path(__file__).resolve().parent.parent / "data" / "site_data.csv"

UPSERT_SQL = """
    insert into sites (site_code, site_label, catchment, river, situation,
                        easting, northing, lon, lat, source)
    values %s
    on conflict (site_code) do update set
        site_label = excluded.site_label,
        catchment  = excluded.catchment,
        river      = excluded.river,
        situation  = excluded.situation,
        easting    = excluded.easting,
        northing   = excluded.northing,
        lon        = excluded.lon,
        lat        = excluded.lat,
        updated_at = now()
    where sites.source = 'site_data_csv';
    -- rows created from an in-field "new site" submission (source =
    -- 'survey_new_site') are left alone even if a later CSV refresh
    -- happens to reuse the same site code, to avoid clobbering
    -- field-captured coordinates with stale master-list data.
"""


def to_int(value: str) -> int | None:
    value = (value or "").strip()
    return int(value) if value else None


def to_float(value: str) -> float | None:
    value = (value or "").strip()
    return float(value) if value else None


def load_rows(csv_path: Path) -> list[tuple]:
    rows: list[tuple] = []
    with csv_path.open(newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)  # handles embedded commas/quotes in label/situation correctly
        for row in reader:
            site_code = (row.get("name") or "").strip()
            if not site_code:
                continue
            rows.append((
                site_code,
                (row.get("label") or "").strip() or None,
                (row.get("catchment") or "").strip() or None,
                (row.get("river") or "").strip() or None,
                (row.get("situation") or "").strip() or None,
                to_int(row.get("easting")),
                to_int(row.get("northing")),
                to_float(row.get("x")),
                to_float(row.get("y")),
                "site_data_csv",
            ))
    return rows


def main() -> None:
    csv_path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_CSV_PATH
    if not csv_path.exists():
        raise SystemExit(f"CSV not found: {csv_path}")

    database_url = os.environ.get("DATABASE_URL")
    if not database_url:
        raise SystemExit("DATABASE_URL is not set")

    rows = load_rows(csv_path)
    if not rows:
        raise SystemExit(f"No rows parsed from {csv_path}")

    with psycopg2.connect(database_url) as conn:
        with conn.cursor() as cur:
            execute_values(cur, UPSERT_SQL, rows)
        conn.commit()

    print(f"Upserted {len(rows)} sites from {csv_path}")


if __name__ == "__main__":
    main()
