-- ============================================================================
-- EF Data Pipeline — Supabase schema
--
-- Maps the NEPS electrofishing Survey123 form (form_id=efish_neps_v8) onto
-- Postgres/PostGIS. Field names in comments are the XLSForm `name` values from
-- the live form at:
--   C:\Users\graem\ArcGIS\My Survey Designs\8533e51b881b43b4b7281ff5753d42e2\
--
-- Real submission nesting: main event -> rep_pass[] -> rep_fish[], plus
-- sibling child tables rep_photos[] and rep_widths[] off the main event.
--
-- Destructive: drops and recreates all tables in this schema. Run against a
-- project you intend to (re)initialize.
-- ============================================================================

create extension if not exists postgis;
create extension if not exists pgcrypto;

drop table if exists
    webhook_log,
    fish_records,
    electrofishing_runs,
    site_photos,
    site_width_measurements,
    electrofishing_events,
    sites
cascade;

-- ============================================================================
-- sites — canonical site master, seeded/upserted from data/site_data.csv
-- (columns: name,label,catchment,river,situation,easting,northing,x,y)
-- ============================================================================
create table sites (
    site_id         bigint generated always as identity primary key,
    site_code       text not null unique,          -- csv 'name' == site_select / new_site_name
    site_label      text,                            -- csv 'label'
    catchment       text,                            -- csv 'catchment' slug
    river           text,                            -- csv 'river'
    situation       text,                            -- csv 'situation'
    easting         integer,                         -- OSGB (EPSG:27700), csv 'easting'
    northing        integer,                         -- OSGB (EPSG:27700), csv 'northing'
    lon             double precision,                -- WGS84, csv 'x'
    lat             double precision,                -- WGS84, csv 'y'
    geom_27700      geometry(Point, 27700)
        generated always as (
            case when easting is not null and northing is not null
                 then st_setsrid(st_makepoint(easting, northing), 27700)
            end
        ) stored,
    geom_4326       geometry(Point, 4326)
        generated always as (
            case when lon is not null and lat is not null
                 then st_setsrid(st_makepoint(lon, lat), 4326)
            end
        ) stored,
    source          text not null default 'site_data_csv'
                        check (source in ('site_data_csv', 'survey_new_site')),
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);
create index idx_sites_geom_27700 on sites using gist (geom_27700);
create index idx_sites_geom_4326  on sites using gist (geom_4326);
create index idx_sites_catchment  on sites (catchment);

-- ============================================================================
-- electrofishing_events — main survey layer (1 row per Survey123 submission)
-- ============================================================================
create table electrofishing_events (
    event_id                bigint generated always as identity primary key,
    global_id               text not null unique,     -- main layer globalid, normalized (no braces, lowercase)
    object_id               integer,                   -- main layer objectid, informational

    site_id                 bigint references sites(site_id) on delete set null,
    site_code               text not null,             -- denormalized: site_code (calc)
    site_type               text not null check (site_type in ('existing', 'new')),

    catchment                text,                       -- catchment (event's own answer, independent of site)
    river_name               text,                       -- river_name (calc)

    survey_date              date not null,              -- survey_date
    start_time                time,                       -- start_time
    end_time                  time,                       -- end_time

    -- this visit's captured location (distinct from the site's canonical geometry in `sites`)
    location                 geometry(Point, 4326),      -- from lon_wgs84/lat_wgs84
    easting                   integer,                    -- easting (BNG, this visit, via bng.js)
    northing                  integer,                    -- northing (BNG, this visit)
    geom_27700                geometry(Point, 27700)
        generated always as (
            case when easting is not null and northing is not null
                 then st_setsrid(st_makepoint(easting, northing), 27700)
            end
        ) stored,

    water_temp_c              numeric(4,1),               -- temp_water
    conductivity_us           integer,                    -- conductivity
    water_level                text check (water_level in ('lo', 'me', 'hi')),      -- water_lvl
    water_color                 text check (water_color in ('clr', 'col', 'turb')),  -- water_clr
    water_sample                 text,                       -- water_sample

    anode_op   text, bucket_op  text, banner_net text, hand_net text,
    scribe     text, processing text, other_staff text,
    eq_type    text, eq_model   text,
    volts      integer,
    stop_nets  text,
    anaesthetic text,

    site_length_lb    numeric(6,1),
    site_length_rb    numeric(6,1),
    reach_length_m    numeric(6,1),               -- site_length (calc avg)
    wetted_width_m    numeric(6,2),                -- final_avg_width
    area_m2           numeric(8,1),                -- final_site_area

    sub_be smallint, sub_bo smallint, sub_co smallint, sub_pe smallint,
    sub_gr smallint, sub_sa smallint, sub_si smallint, sub_ho smallint,
    sub_total smallint,
    flow_sm smallint, flow_dp smallint, flow_sp smallint, flow_dg smallint,
    flow_sg smallint, flow_ru smallint, flow_ri smallint, flow_to smallint,
    flow_total smallint,

    sal_fry_parr_cutoff_mm  integer,     -- sal_fry_parr_cutoff
    trt_fry_parr_cutoff_mm  integer,     -- trt_fry_parr_cutoff

    pollution         boolean,
    pollution_notes   text,
    stocking          boolean,
    stocking_notes    text,
    final_comments    text,

    -- form's own self-reported site-level totals/depletion estimates: cross-check only, never
    -- treated as the source of truth (see electrofishing_runs.form_pass_* below and qc.py)
    form_reported_summary   jsonb,

    qc_status   text not null default 'pending'
                    check (qc_status in ('pending', 'ok', 'flagged', 'reviewed')),
    qc_flags    jsonb not null default '[]'::jsonb,

    raw_payload  jsonb,          -- full original webhook body, for audit/replay

    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);
create index idx_events_site_id     on electrofishing_events (site_id);
create index idx_events_survey_date on electrofishing_events (survey_date);
create index idx_events_catchment   on electrofishing_events (catchment);
create index idx_events_qc_status   on electrofishing_events (qc_status);
create index idx_events_location    on electrofishing_events using gist (location);
create index idx_events_geom_27700  on electrofishing_events using gist (geom_27700);

-- ============================================================================
-- site_width_measurements — rep_widths repeat (direct child of main layer)
-- ============================================================================
create table site_width_measurements (
    width_id           bigint generated always as identity primary key,
    event_id           bigint not null references electrofishing_events(event_id) on delete cascade,
    global_id          text not null unique,
    parent_global_id   text not null,
    position_no        integer,        -- width_id calc = position(..) on the form
    wet_width          numeric(6,2),
    bed_width          numeric(6,2),
    bankfull_width     numeric(6,2),
    created_at         timestamptz not null default now()
);
create index idx_widths_event_id on site_width_measurements (event_id);

-- ============================================================================
-- site_photos — rep_photos repeat (direct child of main layer). Photos are
-- SITE-LEVEL ONLY in this form — there is no per-fish photo field anywhere.
-- ============================================================================
create table site_photos (
    photo_id             bigint generated always as identity primary key,
    event_id             bigint not null references electrofishing_events(event_id) on delete cascade,
    global_id            text not null unique,
    parent_global_id     text not null,
    caption              text,             -- photo_caption
    storage_path         text not null,    -- electrofishing/{year}/{site_code}/{global_id}.{ext}
    photo_url            text,             -- short-lived signed URL cache; re-sign via storage.sign_url()
                                            -- rather than treating this as a permanent value (private bucket)
    esri_attachment_id   text,
    content_type         text,
    created_at           timestamptz not null default now()
);
create index idx_photos_event_id on site_photos (event_id);

-- ============================================================================
-- electrofishing_runs — rep_pass repeat (direct child of main layer)
-- ============================================================================
create table electrofishing_runs (
    run_id              bigint generated always as identity primary key,
    event_id            bigint not null references electrofishing_events(event_id) on delete cascade,
    global_id           text not null unique,
    parent_global_id    text not null,
    pass_no             integer not null,
    anode_time_s        integer,
    total_pass_time_s   integer,

    -- form's own self-reported per-pass totals: cross-check only, never trusted as source of
    -- truth. Authoritative counts are always derived server-side from fish_records (see qc.py).
    form_pass_sal_fry   integer,
    form_pass_trt_fry   integer,
    form_pass_sal_parr  integer,
    form_pass_trt_parr  integer,
    form_pass_eel       integer,
    form_pass_other     integer,
    form_pass_total     integer,

    created_at   timestamptz not null default now(),
    unique (event_id, pass_no)
);
create index idx_runs_event_id on electrofishing_runs (event_id);

-- ============================================================================
-- fish_records — rep_fish repeat, NESTED inside rep_pass (not a direct child
-- of the main layer)
-- ============================================================================
create table fish_records (
    fish_id             bigint generated always as identity primary key,
    run_id              bigint not null references electrofishing_runs(run_id) on delete cascade,
    global_id           text not null unique,
    parent_global_id    text not null,

    entry_mode          text check (entry_mode in ('individual', 'bulk')),
    species              text not null
                             check (species in ('sal','trt','eel','lam','min','sto','sti','flo','oth')),
    length_mm            integer,           -- length (fork length, mm)

    -- lifestage is the real, user-selected answer (fry/parr only). calc_stage is a confirmed
    -- dead/unwired field on the form (see project memory calc_stage_unused.md) — never read it.
    lifestage             text check (lifestage in ('fry', 'parr')),

    wet_weight_g          numeric(6,2),      -- nullable: no `weight` field exists on the form today
    condition_factor       numeric(5,3),      -- trigger-computed; NULL unless wet_weight_g present

    scaled                 boolean,
    tissue_tube             text,              -- scale sample id ("Tube#")
    count_bulk               integer default 1,
    fish_multiplier           integer not null default 1,   -- count_bulk or 1

    photo_url                 text,              -- forward-compat only; no per-fish photos exist today

    qc_flag                    jsonb not null default '[]'::jsonb,

    created_at                  timestamptz not null default now()
);
create index idx_fish_records_run_id            on fish_records (run_id);
create index idx_fish_records_species           on fish_records (species);
create index idx_fish_records_species_lifestage on fish_records (species, lifestage);

-- ============================================================================
-- webhook_log — operational log/replay queue for /webhook/survey123 deliveries
-- ============================================================================
create table webhook_log (
    id                bigint generated always as identity primary key,
    received_at       timestamptz not null default now(),
    event_global_id   text,
    payload           jsonb,
    status            text not null default 'received'
                          check (status in ('received', 'processed', 'error')),
    error_detail      text
);
create index idx_webhook_log_status on webhook_log (status);

-- ============================================================================
-- Fulton's condition factor trigger
--
-- K = 100 * weight_g / length_cm^3
--
-- length_mm on the form is millimetres; Fulton's K conventionally uses
-- centimetres, so we divide by 10 before cubing. Only computed when both
-- weight and length are present — NULL otherwise (no weight field exists on
-- the form today, so this will be NULL for essentially all current data).
-- ============================================================================
create or replace function fn_fish_condition_factor() returns trigger as $$
begin
    if new.wet_weight_g is not null and new.length_mm is not null and new.length_mm > 0 then
        new.condition_factor := round(
            (100.0 * new.wet_weight_g / power(new.length_mm::numeric / 10.0, 3))::numeric, 3
        );
    else
        new.condition_factor := null;
    end if;
    return new;
end;
$$ language plpgsql set search_path = public, pg_temp;

create trigger trg_fish_condition_factor
    before insert or update of wet_weight_g, length_mm on fish_records
    for each row execute function fn_fish_condition_factor();

-- ============================================================================
-- updated_at maintenance (sites, electrofishing_events)
-- ============================================================================
create or replace function fn_touch_updated_at() returns trigger as $$
begin
    new.updated_at := now();
    return new;
end;
$$ language plpgsql set search_path = public, pg_temp;

create trigger trg_sites_touch_updated_at
    before update on sites
    for each row execute function fn_touch_updated_at();

create trigger trg_events_touch_updated_at
    before update on electrofishing_events
    for each row execute function fn_touch_updated_at();
