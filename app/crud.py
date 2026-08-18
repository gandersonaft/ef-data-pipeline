"""
Database access. Every write is an idempotent `ON CONFLICT (global_id) DO
UPDATE`, so a webhook retry (AGOL redelivering the same submission) upserts
in place rather than duplicating rows.
"""

from __future__ import annotations

import json

import asyncpg

from app.esri import normalize_guid
from app.models import EventAttributes, NormalizedSubmission, PhotoAttributes, WidthAttributes


async def upsert_site(conn: asyncpg.Connection, event: EventAttributes) -> int:
    if event.site_type == "existing":
        code = event.site_select or event.site_code
        row = await conn.fetchrow("select site_id from sites where site_code = $1", code)
        if row:
            return row["site_id"]
        # defensive fallback: an "existing" site not found in the master list — create it
        # from whatever coordinates this submission captured rather than dropping the event
        code = event.site_code

    else:
        code = event.new_site_name or event.site_code

    row = await conn.fetchrow(
        """
        insert into sites (site_code, catchment, river, easting, northing, lon, lat, source)
        values ($1, $2, $3, $4, $5, $6, $7, 'survey_new_site')
        on conflict (site_code) do update set updated_at = now()
        returning site_id
        """,
        code,
        event.catchment,
        event.new_river_name or event.river_name,
        event.easting,
        event.northing,
        event.lon_wgs84,
        event.lat_wgs84,
    )
    return row["site_id"]


async def upsert_event(conn: asyncpg.Connection, submission: NormalizedSubmission, site_id: int) -> int:
    event = submission.event
    location_wkt = (
        f"SRID=4326;POINT({event.lon_wgs84} {event.lat_wgs84})"
        if event.lon_wgs84 is not None and event.lat_wgs84 is not None
        else None
    )

    row = await conn.fetchrow(
        """
        insert into electrofishing_events (
            global_id, object_id, site_id, site_code, site_type, catchment, river_name,
            survey_date, start_time, end_time, location, easting, northing,
            water_temp_c, conductivity_us, water_level, water_color, water_sample,
            anode_op, bucket_op, banner_net, hand_net, scribe, processing, other_staff,
            eq_type, eq_model, volts, stop_nets, anaesthetic,
            site_length_lb, site_length_rb, reach_length_m, wetted_width_m, area_m2,
            sub_be, sub_bo, sub_co, sub_pe, sub_gr, sub_sa, sub_si, sub_ho, sub_total,
            flow_sm, flow_dp, flow_sp, flow_dg, flow_sg, flow_ru, flow_ri, flow_to, flow_total,
            sal_fry_parr_cutoff_mm, trt_fry_parr_cutoff_mm,
            pollution, pollution_notes, stocking, stocking_notes, final_comments,
            form_reported_summary, raw_payload
        ) values (
            $1, $2, $3, $4, $5, $6, $7,
            $8, $9, $10, st_geomfromewkt($11), $12, $13,
            $14, $15, $16, $17, $18,
            $19, $20, $21, $22, $23, $24, $25,
            $26, $27, $28, $29, $30,
            $31, $32, $33, $34, $35,
            $36, $37, $38, $39, $40, $41, $42, $43, $44,
            $45, $46, $47, $48, $49, $50, $51, $52, $53,
            $54, $55,
            $56, $57, $58, $59, $60,
            $61, $62
        )
        on conflict (global_id) do update set
            site_id = excluded.site_id, site_code = excluded.site_code,
            catchment = excluded.catchment, river_name = excluded.river_name,
            survey_date = excluded.survey_date, start_time = excluded.start_time,
            end_time = excluded.end_time, location = excluded.location,
            easting = excluded.easting, northing = excluded.northing,
            water_temp_c = excluded.water_temp_c, conductivity_us = excluded.conductivity_us,
            water_level = excluded.water_level, water_color = excluded.water_color,
            water_sample = excluded.water_sample,
            final_comments = excluded.final_comments,
            form_reported_summary = excluded.form_reported_summary,
            raw_payload = excluded.raw_payload,
            updated_at = now()
        returning event_id
        """,
        normalize_guid(event.globalid), event.objectid, site_id, event.effective_site_code(),
        event.site_type, event.catchment, event.river_name,
        event.survey_date, event.start_time, event.end_time, location_wkt, event.easting, event.northing,
        event.temp_water, event.conductivity, event.water_lvl, event.water_clr, event.water_sample,
        event.anode_op, event.bucket_op, event.banner_net, event.hand_net, event.scribe,
        event.processing, event.other_staff,
        event.eq_type, event.eq_model, event.volts, event.stop_nets, event.anaesthetic,
        event.site_length_lb, event.site_length_rb, event.site_length, event.final_avg_width,
        event.final_site_area,
        event.sub_be, event.sub_bo, event.sub_co, event.sub_pe, event.sub_gr, event.sub_sa,
        event.sub_si, event.sub_ho, event.sub_total,
        event.flow_sm, event.flow_dp, event.flow_sp, event.flow_dg, event.flow_sg, event.flow_ru,
        event.flow_ri, event.flow_to, event.flow_total,
        event.sal_fry_parr_cutoff, event.trt_fry_parr_cutoff,
        event.pollution in ("yes", "true", "1", True), event.pollution_notes,
        event.stocking in ("yes", "true", "1", True), event.stocking_notes, event.final_comments,
        json.dumps(event.form_reported_summary()), json.dumps(submission.raw_payload),
    )
    return row["event_id"]


async def upsert_runs(conn: asyncpg.Connection, event_id: int, runs) -> dict[str, int]:
    run_id_map: dict[str, int] = {}
    for rwf in runs:
        run = rwf.run
        row = await conn.fetchrow(
            """
            insert into electrofishing_runs (
                global_id, parent_global_id, event_id, pass_no, anode_time_s, total_pass_time_s,
                form_pass_sal_fry, form_pass_trt_fry, form_pass_sal_parr, form_pass_trt_parr,
                form_pass_eel, form_pass_other, form_pass_total
            ) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
            on conflict (global_id) do update set
                pass_no = excluded.pass_no, anode_time_s = excluded.anode_time_s,
                total_pass_time_s = excluded.total_pass_time_s,
                form_pass_sal_fry = excluded.form_pass_sal_fry,
                form_pass_trt_fry = excluded.form_pass_trt_fry,
                form_pass_sal_parr = excluded.form_pass_sal_parr,
                form_pass_trt_parr = excluded.form_pass_trt_parr,
                form_pass_eel = excluded.form_pass_eel,
                form_pass_other = excluded.form_pass_other,
                form_pass_total = excluded.form_pass_total
            returning run_id
            """,
            normalize_guid(run.globalid), normalize_guid(run.parentglobalid), event_id, run.pass_no,
            run.anode_time, run.total_pass_time,
            run.pass_sal_fry, run.pass_trt_fry, run.pass_sal_parr, run.pass_trt_parr,
            run.pass_eel, run.pass_other, run.pass_total,
        )
        run_id_map[normalize_guid(run.globalid)] = row["run_id"]
    return run_id_map


async def upsert_fish(conn: asyncpg.Connection, run_id_map: dict[str, int], runs) -> list[dict]:
    inserted: list[dict] = []
    for rwf in runs:
        run_id = run_id_map[normalize_guid(rwf.run.globalid)]
        for fish in rwf.fish:
            row = await conn.fetchrow(
                """
                insert into fish_records (
                    global_id, parent_global_id, run_id, entry_mode, species, length_mm,
                    lifestage, scaled, tissue_tube, count_bulk, fish_multiplier
                ) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
                on conflict (global_id) do update set
                    entry_mode = excluded.entry_mode, species = excluded.species,
                    length_mm = excluded.length_mm, lifestage = excluded.lifestage,
                    scaled = excluded.scaled, tissue_tube = excluded.tissue_tube,
                    count_bulk = excluded.count_bulk, fish_multiplier = excluded.fish_multiplier
                returning fish_id, run_id, species, lifestage, length_mm, wet_weight_g,
                          condition_factor, fish_multiplier
                """,
                normalize_guid(fish.globalid), normalize_guid(fish.parentglobalid), run_id,
                fish.entry_mode, fish.species, fish.length, fish.lifestage,
                fish.scaled in ("yes", "true", "1", True), fish.tissue_tube,
                fish.count_bulk or 1, fish.fish_multiplier or 1,
            )
            inserted.append(dict(row))
    return inserted


async def upsert_widths(conn: asyncpg.Connection, event_id: int, widths: list[WidthAttributes]) -> None:
    for w in widths:
        await conn.execute(
            """
            insert into site_width_measurements (
                global_id, parent_global_id, event_id, position_no, wet_width, bed_width, bankfull_width
            ) values ($1, $2, $3, $4, $5, $6, $7)
            on conflict (global_id) do update set
                position_no = excluded.position_no, wet_width = excluded.wet_width,
                bed_width = excluded.bed_width, bankfull_width = excluded.bankfull_width
            """,
            normalize_guid(w.globalid), normalize_guid(w.parentglobalid), event_id,
            w.width_id, w.wet_width, w.bed_width, w.bankfull_width,
        )


async def upsert_photos(conn: asyncpg.Connection, event_id: int, photo_uploads: list[tuple]) -> None:
    """photo_uploads: list of (PhotoAttributes, storage_path, signed_url, content_type)."""
    for photo, storage_path, url, content_type in photo_uploads:
        await conn.execute(
            """
            insert into site_photos (
                global_id, parent_global_id, event_id, caption, storage_path, photo_url, content_type
            ) values ($1, $2, $3, $4, $5, $6, $7)
            on conflict (global_id) do update set
                caption = excluded.caption, storage_path = excluded.storage_path,
                photo_url = excluded.photo_url, content_type = excluded.content_type
            """,
            normalize_guid(photo.globalid), normalize_guid(photo.parentglobalid), event_id,
            photo.photo_caption, storage_path, url, content_type,
        )


async def update_qc(conn: asyncpg.Connection, event_id: int, status: str, flags: list[dict]) -> None:
    await conn.execute(
        "update electrofishing_events set qc_status = $1, qc_flags = $2 where event_id = $3",
        status, json.dumps(flags), event_id,
    )
