"""
One-off ETL: loads historical electrofishing data exported from the legacy
SFCC/Rockpool national database into the historical_* tables (migration
0002_historical_sfcc_data.sql -- run that migration first).

Source files, all in `C:\\Users\\graem\\OneDrive - Argyll Fisheries Trust\\sfcc aft export\\`:
    Report.csv              -- site register -> historical_sites
    GISExport (1).csv       -- event/method/habitat identity + per-run
                                salmon/trout counts -> historical_events,
                                historical_run_counts
    HABExport (1).csv       -- detailed habitat/crew/equipment/water-quality,
                                joined onto historical_events by EventId
    Report (1).csv          -- Fishing Type (Method), joined onto
                                historical_events by Event ID
    FDExport (1).csv        -- per-event/species/age-class Zippin/Carle&Strub
                                density estimates -> historical_density_estimates
    Report (8).csv          -- individual fish (the former "missing"
                                Individual_Fish_Export) -> historical_fish

Deliberately NOT loaded this pass (see plan addendum for why -- lower value,
schema/complexity mismatch): TRA1Export/TRA2Export (per-transect width/
landuse detail, coarser summary already captured via HABExport's averages),
OTHExport.csv (1-row stub, Report (6) already covers other-species totals
at a coarser grain if ever wanted), Report (2).csv/Report (6).csv (their
raw-tally and broader-species-total formats don't fit this pass's tables
cleanly and cover only a handful of non-salmonid events).

Idempotent: every insert is ON CONFLICT ... DO UPDATE keyed on the natural
SFCC id (sfcc_site_id / sfcc_event_id / the historical_fish composite isn't
naturally deduplicable per-row, so historical_fish is truncated and
reloaded each run instead -- see load_fish()).

Usage:
    DATABASE_URL=postgresql://webhook_writer.<ref>:<pw>@<host>:5432/postgres \\
        python scripts/migrate_sfcc_historical.py
"""

from __future__ import annotations

import csv
import os
import sys
from datetime import date, datetime

import psycopg2
import psycopg2.extras

SFCC_DIR = r"C:\Users\graem\OneDrive - Argyll Fisheries Trust\sfcc aft export"

SPECIES_MAP = {
    "Atlantic Salmon (Salmo salar)": "sal",
    "Brown Trout (Sea Trout) (Salmo trutta)": "trt",
    "Common Minnow (Phoxinus phoxinus)": "min",
    "Flounder (Platichthys flesus)": "flo",
    "European Eel (Anguilla anguilla)": "eel",
}


def parse_date(s: str) -> date | None:
    s = (s or "").strip()
    if not s:
        return None
    for fmt in ("%d/%m/%Y", "%d/%m/%y"):
        try:
            return datetime.strptime(s, fmt).date()
        except ValueError:
            continue
    return None


def parse_int(s: str) -> int | None:
    s = (s or "").strip()
    if not s:
        return None
    try:
        return int(round(float(s)))
    except ValueError:
        return None


def parse_float(s: str) -> float | None:
    s = (s or "").strip()
    if not s:
        return None
    try:
        return float(s)
    except ValueError:
        return None


def parse_bool(s: str) -> bool | None:
    s = (s or "").strip().lower()
    if s in ("true", "yes", "1"):
        return True
    if s in ("false", "no", "0"):
        return False
    return None


def read_csv(filename: str) -> list[dict]:
    """A few of these exports have stray embedded NUL bytes in individual
    fields (confirmed 2026-08-19, e.g. one row in GISExport/HABExport) --
    psycopg2 can't bind a string containing \\x00 at all ("A string literal
    cannot contain NUL characters"), so strip them here, once, rather than
    in every downstream field-parsing call."""
    path = os.path.join(SFCC_DIR, filename)
    with open(path, encoding="utf-8-sig", newline="") as f:
        rows = list(csv.DictReader(f))
    for row in rows:
        for key, value in row.items():
            if value and "\x00" in value:
                row[key] = value.replace("\x00", "")
    return rows


def load_sites(cur) -> int:
    rows = read_csv("Report.csv")
    values = []
    for r in rows:
        site_id = (r.get("Site ID") or "").strip()
        if not site_id:
            continue
        values.append((
            site_id,
            (r.get("Site Code") or "").strip() or None,
            parse_int(r.get("Easting")),
            parse_int(r.get("Northing")),
            (r.get("Salmon Fishery District") or "").strip() or None,
            (r.get("Statistical District") or "").strip() or None,
            (r.get("Catchment") or "").strip() or None,
            (r.get("River Order 1") or "").strip() or None,
            parse_date(r.get("Date Registered")),
        ))
    psycopg2.extras.execute_values(
        cur,
        """insert into historical_sites
             (sfcc_site_id, site_code, easting, northing, salmon_fishery_district,
              statistical_district, catchment, river_order_1, date_registered)
           values %s
           on conflict (sfcc_site_id) do update set
             site_code = excluded.site_code, easting = excluded.easting,
             northing = excluded.northing, catchment = excluded.catchment""",
        values,
    )
    return len(values)


def load_events(cur) -> int:
    gis_rows = read_csv("GISExport (1).csv")
    hab_by_event = {r["EventId"]: r for r in read_csv("HABExport (1).csv")}
    method_by_event = {r["Event ID"]: r["Fishing Type"] for r in read_csv("Report (1).csv")}

    # sfcc_site_id -> historical_site_id, resolved after historical_sites is loaded
    cur.execute("select sfcc_site_id, historical_site_id from historical_sites")
    site_id_map = dict(cur.fetchall())

    values = []
    for r in gis_rows:
        event_id = r["EventId"]
        hab = hab_by_event.get(event_id, {})
        values.append((
            event_id,
            site_id_map.get(r.get("SiteId", "").strip()),
            (r.get("SiteCode") or "").strip() or None,
            parse_date(r.get("Date")),
            parse_int(r.get("Easting")),
            parse_int(r.get("Northing")),
            method_by_event.get(event_id),
            parse_int(r.get("Runs")),
            parse_float(r.get("Reach")),
            parse_float(hab.get("AvgWeWth")),
            parse_float(hab.get("AvgBeWth")),
            parse_float(hab.get("AvgBaWth")),
            parse_float(r.get("Area")),
            parse_int(hab.get("HO")), parse_int(hab.get("BO")), parse_int(hab.get("CO")),
            parse_int(hab.get("PE")), parse_int(hab.get("GR")), parse_int(hab.get("SA")),
            parse_int(hab.get("SI")), parse_int(hab.get("BE")),
            parse_int(hab.get("SM")), parse_int(hab.get("DP")), parse_int(hab.get("SP")),
            parse_int(hab.get("DG")), parse_int(hab.get("SG")), parse_int(hab.get("RU")),
            parse_int(hab.get("RI")), parse_int(hab.get("TO")),
            parse_int(hab.get("COND")),
            parse_float(hab.get("TEMP")),
            (hab.get("HEIGHT") or "").strip() or None,
            (hab.get("CLARITY") or "").strip() or None,
            (hab.get("TEAM_LEAD") or "").strip() or None,
            parse_int(hab.get("STAFF")),
            (hab.get("Equip") or "").strip() or None,
            parse_int(hab.get("VOLTS")),
            parse_bool(hab.get("POLL")),
            (hab.get("POLL_NOTES") or "").strip() or None,
            parse_bool(hab.get("STOCK")),
            (hab.get("STOCK_NOTES") or "").strip() or None,
            (r.get("EventTrust") or "").strip() or None,
            (r.get("EventStatus") or "").strip() or None,
        ))

    psycopg2.extras.execute_values(
        cur,
        """insert into historical_events
             (sfcc_event_id, historical_site_id, site_code, survey_date, easting, northing,
              method, planned_runs, reach_length_m, wetted_width_m, bed_width_m, bank_width_m,
              area_m2, sub_ho, sub_bo, sub_co, sub_pe, sub_gr, sub_sa, sub_si, sub_be,
              flow_sm, flow_dp, flow_sp, flow_dg, flow_sg, flow_ru, flow_ri, flow_to,
              conductivity_us, water_temp_c, water_height, water_clarity, team_lead, staff_count,
              equipment, volts, pollution_observed, pollution_notes, stocking_observed,
              stocking_notes, event_trust, event_status)
           values %s
           on conflict (sfcc_event_id) do update set
             survey_date = excluded.survey_date, area_m2 = excluded.area_m2""",
        values,
    )
    return len(values)


def load_run_counts(cur) -> int:
    """Flattens GISExport's wide S0_R1..S4_R5 / T0_R1..T4_R5 columns into one
    row per (event, species, age_class, run). Salmon/trout only -- these are
    the only species GISExport's per-run breakdown covers."""
    gis_rows = read_csv("GISExport (1).csv")
    cur.execute("select sfcc_event_id, historical_event_id from historical_events")
    event_id_map = dict(cur.fetchall())

    values = []
    for r in gis_rows:
        hist_event_id = event_id_map.get(r["EventId"])
        if hist_event_id is None:
            continue
        for species_code, prefix in (("sal", "S"), ("trt", "T")):
            for age_class in range(5):
                for run_no in range(1, 6):
                    col = f"{prefix}{age_class}_R{run_no}"
                    count = parse_int(r.get(col))
                    if count is None:
                        continue
                    values.append((hist_event_id, species_code, age_class, run_no, count))

    psycopg2.extras.execute_values(
        cur,
        """insert into historical_run_counts (historical_event_id, species, age_class, run_no, count)
           values %s
           on conflict (historical_event_id, species, age_class, run_no) do update set count = excluded.count""",
        values,
        page_size=1000,
    )
    return len(values)


def load_density_estimates(cur) -> int:
    rows = read_csv("FDExport (1).csv")
    cur.execute("select sfcc_event_id, historical_event_id from historical_events")
    event_id_map = dict(cur.fetchall())

    values = []
    skipped_species = set()
    for r in rows:
        hist_event_id = event_id_map.get(r["EventId"])
        if hist_event_id is None:
            continue
        species = SPECIES_MAP.get(r["Species"])
        if species not in ("sal", "trt"):
            skipped_species.add(r["Species"])
            continue
        age_str = (r.get("Age Class") or "").strip().rstrip("+")
        age_class = parse_int(age_str)
        if age_class is None:
            continue
        age_class = min(age_class, 4)
        values.append((
            hist_event_id, species, age_class,
            parse_float(r.get("Zippin Estimate")), parse_float(r.get("Z Lower Confidence")),
            parse_float(r.get("Z Upper Confidence")),
            parse_float(r.get("Carle & Strub Estimate")), parse_float(r.get("CS Lower Estimate")),
            parse_float(r.get("CS Upper Confidence")),
            parse_float(r.get("Average Length")), parse_float(r.get("Length Std Dev")),
        ))
    if skipped_species:
        print(f"  (FDExport: skipped non-salmon/trout species: {skipped_species})")

    psycopg2.extras.execute_values(
        cur,
        """insert into historical_density_estimates
             (historical_event_id, species, age_class, zippin_estimate, zippin_lower_cl,
              zippin_upper_cl, carle_strub_estimate, carle_strub_lower_cl, carle_strub_upper_cl,
              average_length_mm, length_std_dev)
           values %s
           on conflict (historical_event_id, species, age_class) do update set
             carle_strub_estimate = excluded.carle_strub_estimate""",
        values,
    )
    return len(values)


def load_fish(cur) -> int:
    """historical_fish has no natural per-row dedup key, so this truncates
    and reloads in full each run rather than upserting row-by-row."""
    rows = read_csv("Report (8).csv")
    cur.execute("select sfcc_event_id, historical_event_id from historical_events")
    event_id_map = dict(cur.fetchall())

    cur.execute("delete from historical_fish")

    values = []
    unmapped_species: dict[str, int] = {}
    unmatched_events = 0
    for r in rows:
        hist_event_id = event_id_map.get(r["Event ID"])
        if hist_event_id is None:
            unmatched_events += 1
            continue
        species = SPECIES_MAP.get(r["Species"])
        if species is None:
            unmapped_species[r["Species"]] = unmapped_species.get(r["Species"], 0) + 1
            species = "oth"
        length_mm = parse_int(r.get("Length"))
        age_class = parse_int(r.get("Assigned Age"))
        lifestage = None
        if age_class is not None:
            age_class = min(age_class, 4)
            lifestage = "fry" if age_class == 0 else "parr"
        run_no = parse_int(r.get("Run Number"))
        values.append((hist_event_id, run_no, species, length_mm, age_class, lifestage))

    psycopg2.extras.execute_values(
        cur,
        """insert into historical_fish
             (historical_event_id, run_no, species, length_mm, age_class, lifestage)
           values %s""",
        values,
        page_size=2000,
    )
    if unmapped_species:
        print(f"  (Report(8): unmapped species collapsed to 'oth': {unmapped_species})")
    if unmatched_events:
        print(f"  (Report(8): {unmatched_events} fish rows had no matching historical_event, skipped)")
    return len(values)


def update_has_fish_flag(cur) -> int:
    cur.execute(
        """update historical_events set has_individual_fish_data = true
           where historical_event_id in (select distinct historical_event_id from historical_fish)"""
    )
    return cur.rowcount


def main() -> None:
    database_url = os.environ.get("DATABASE_URL")
    if not database_url:
        print("DATABASE_URL not set", file=sys.stderr)
        sys.exit(1)

    conn = psycopg2.connect(database_url)
    try:
        with conn.cursor() as cur:
            print("Loading historical_sites...")
            n = load_sites(cur)
            conn.commit()
            print(f"  {n} rows")

            print("Loading historical_events...")
            n = load_events(cur)
            conn.commit()
            print(f"  {n} rows")

            print("Loading historical_run_counts...")
            n = load_run_counts(cur)
            conn.commit()
            print(f"  {n} rows")

            print("Loading historical_density_estimates...")
            n = load_density_estimates(cur)
            conn.commit()
            print(f"  {n} rows")

            print("Loading historical_fish...")
            n = load_fish(cur)
            conn.commit()
            print(f"  {n} rows")

            print("Updating has_individual_fish_data flag...")
            n = update_has_fish_flag(cur)
            conn.commit()
            print(f"  {n} events flagged")

        print("Done.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
