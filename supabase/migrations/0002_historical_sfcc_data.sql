-- ============================================================================
-- Migration 0002 -- historical electrofishing data migrated from the legacy
-- SFCC/Rockpool national database (https://sfcc.rockpool.solutions/home.asp).
-- Additive only. Deliberately SEPARATE from sites/electrofishing_events/
-- electrofishing_runs/fish_records, not commingled with live Survey123 data --
-- see the plan addendum ("SFCC/Rockpool Historical Data Migration") for the
-- full reasoning: live tables' global_id is tied to Esri's ArcGIS Online
-- object model (idempotent upserts, webhook/poll reconciliation), SFCC's
-- SiteCode is documented as NOT unique (unlike sites.site_code), and SFCC's
-- own Zippin/Carle&Strub density estimates are a different modelling
-- methodology than neps_tool_results (Marine Directorate NEPS tool output).
--
-- Source data: C:\Users\graem\OneDrive - Argyll Fisheries Trust\sfcc aft export\
-- EventTrust 2000003 = Argyll Fisheries Trust (confirmed: 96.8% of GISExport
-- rows, matches every Argyll-district sample row) -- other trusts' data is
-- commingled in these exports (7 distinct EventTrust values seen) and is
-- imported here too (harmless, just not AFT's own), filterable by
-- historical_events.event_trust in any query/view that needs AFT-only.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- historical_sites -- from Report.csv (SFCC's site register, 1228 rows).
-- SiteCode is NOT unique in SFCC (confirmed in the data dictionary), so
-- unlike sites.site_code this is NOT a unique constraint -- sfcc_site_id
-- (SFCC's own SiteId) is the real natural key.
-- ----------------------------------------------------------------------------
create table historical_sites (
    historical_site_id  bigint generated always as identity primary key,
    sfcc_site_id        text not null unique,       -- SFCC "Site ID"
    site_code           text,                        -- SFCC "Site Code" -- NOT unique, see above
    site_id             bigint references sites(site_id) on delete set null,  -- best-effort match to a live site, nullable
    easting             integer,
    northing            integer,
    geom_27700          geometry(Point, 27700)
        generated always as (
            case when easting is not null and northing is not null
                 then st_setsrid(st_makepoint(easting, northing), 27700)
            end
        ) stored,
    salmon_fishery_district  text,
    statistical_district     text,
    catchment                text,
    river_order_1            text,
    date_registered          date,
    created_at               timestamptz not null default now()
);
create index idx_historical_sites_site_code on historical_sites (site_code);
create index idx_historical_sites_geom      on historical_sites using gist (geom_27700);

-- ----------------------------------------------------------------------------
-- historical_events -- from GISExport (site/method/habitat identity) +
-- HABExport (detailed habitat/crew/equipment/water-quality, joined 1:1 on
-- EventId). One row per historical survey visit, analogous to
-- electrofishing_events but never treated as if it were a Survey123
-- submission.
-- ----------------------------------------------------------------------------
create table historical_events (
    historical_event_id  bigint generated always as identity primary key,
    sfcc_event_id        text not null unique,        -- GISExport/HABExport "EventId"
    historical_site_id   bigint references historical_sites(historical_site_id) on delete set null,
    site_code            text,                          -- denormalized
    survey_date           date,
    easting                integer,
    northing               integer,
    geom_27700             geometry(Point, 27700)
        generated always as (
            case when easting is not null and northing is not null
                 then st_setsrid(st_makepoint(easting, northing), 27700)
            end
        ) stored,

    method                  text,       -- "Quantitative (1mm)" / "Quantitative (5mm)" / "Presence/Absence" / "Timed"
    planned_runs             integer,    -- GISExport "Runs"

    -- habitat / water quality / crew / equipment (HABExport) -- same
    -- substrate/flow taxonomy as electrofishing_events, kept as separate
    -- columns here rather than reusing that table (this is a different
    -- provenance, not a live submission)
    reach_length_m          numeric(6,1),
    wetted_width_m          numeric(6,2),
    bed_width_m             numeric(6,2),
    bank_width_m            numeric(6,2),
    area_m2                  numeric(8,1),
    sub_be smallint, sub_bo smallint, sub_co smallint, sub_pe smallint,
    sub_gr smallint, sub_sa smallint, sub_si smallint, sub_ho smallint,
    flow_sm smallint, flow_dp smallint, flow_sp smallint, flow_dg smallint,
    flow_sg smallint, flow_ru smallint, flow_ri smallint, flow_to smallint,
    conductivity_us          integer,
    water_temp_c              numeric(4,1),
    water_height              text,
    water_clarity              text,
    team_lead                   text,
    staff_count                  integer,
    equipment                     text,
    volts                          integer,
    pollution_observed              boolean,
    pollution_notes                  text,
    stocking_observed                 boolean,
    stocking_notes                     text,

    -- provenance / cross-check fields (never treated as authoritative counts
    -- once historical_fish has real per-fish rows for the event)
    event_trust                text,    -- SFCC owning-organisation id, see migration header comment
    event_status                text,    -- SFCC "EventStatus": published/unpublished
    has_individual_fish_data     boolean not null default false,  -- true once historical_fish has rows for this event

    created_at                     timestamptz not null default now()
);
create index idx_historical_events_site_code   on historical_events (site_code);
create index idx_historical_events_survey_date on historical_events (survey_date);
create index idx_historical_events_event_trust on historical_events (event_trust);
create index idx_historical_events_geom        on historical_events using gist (geom_27700);

-- ----------------------------------------------------------------------------
-- historical_run_counts -- from GISExport's wide S0_R1..S4_R5/T0_R1..T4_R5
-- columns (flattened) and Report(6)'s per-event/species/age-class totals.
-- Pre-aggregated by SFCC, analogous to electrofishing_runs.form_pass_* --
-- "cross-check only" in spirit, EXCEPT this is the primary/only count source
-- for the ~300 events with no historical_fish rows.
-- ----------------------------------------------------------------------------
create table historical_run_counts (
    id                     bigint generated always as identity primary key,
    historical_event_id    bigint not null references historical_events(historical_event_id) on delete cascade,
    species                text not null check (species in ('sal','trt','eel','lam','min','sto','sti','flo','oth')),
    age_class               smallint not null,   -- SFCC's raw 0-4 (0 = age-0+/fry-equivalent), NOT collapsed to fry/parr here
    run_no                    smallint not null,
    count                       integer not null default 0,
    unique (historical_event_id, species, age_class, run_no)
);
create index idx_historical_run_counts_event on historical_run_counts (historical_event_id);

-- ----------------------------------------------------------------------------
-- historical_fish -- from Report (8).csv, the data dictionary's
-- "Individual_Fish_Export" (66,627 rows, one row per fish, ~85% of events).
-- This is what makes real depletion/length-frequency reporting possible for
-- historical events -- see the plan addendum. age_class preserves SFCC's
-- full 0-4 resolution (richer than the modern fry/parr binary); lifestage
-- is also stored as a direct fry/parr collapse (0->fry, 1-4->parr) so
-- existing reporting code that only understands fry/parr can still use it.
-- ----------------------------------------------------------------------------
create table historical_fish (
    historical_fish_id     bigint generated always as identity primary key,
    historical_event_id    bigint not null references historical_events(historical_event_id) on delete cascade,
    run_no                  smallint,
    species                   text not null check (species in ('sal','trt','eel','lam','min','sto','sti','flo','oth')),
    length_mm                  integer,
    age_class                   smallint,             -- SFCC's raw 0-4, nullable (~0.8% of rows have no Assigned Age)
    lifestage                    text check (lifestage in ('fry','parr')),  -- derived: age_class 0 -> fry, 1-4 -> parr
    created_at                     timestamptz not null default now()
);
create index idx_historical_fish_event             on historical_fish (historical_event_id);
create index idx_historical_fish_species           on historical_fish (species);
create index idx_historical_fish_species_lifestage on historical_fish (species, lifestage);

-- ----------------------------------------------------------------------------
-- historical_density_estimates -- SFCC's own Zippin/Carle&Strub modelled
-- density estimates (from GISExport's Z_*/CS_* columns and FDExport),
-- preserved as a cross-check against whatever Carle-Strub gets recomputed
-- server-side from historical_fish -- NOT written into neps_tool_results,
-- which is shaped for the Marine Directorate NEPS tool's own output format,
-- a different methodology.
-- ----------------------------------------------------------------------------
create table historical_density_estimates (
    id                     bigint generated always as identity primary key,
    historical_event_id    bigint not null references historical_events(historical_event_id) on delete cascade,
    species                text not null check (species in ('sal','trt')),
    age_class               smallint not null,
    zippin_estimate           numeric(10,3),
    zippin_lower_cl            numeric(10,3),
    zippin_upper_cl              numeric(10,3),
    carle_strub_estimate           numeric(10,3),
    carle_strub_lower_cl             numeric(10,3),
    carle_strub_upper_cl               numeric(10,3),
    average_length_mm                    numeric(6,1),
    length_std_dev                        numeric(6,2),
    unique (historical_event_id, species, age_class)
);
create index idx_historical_density_event on historical_density_estimates (historical_event_id);

-- shiny_reader gets read access, matching the live-data read-only convention.
-- No shiny_editor write access -- this is a one-time migration, not an
-- ongoing write path; re-running the ETL script handles corrections.
grant select on historical_sites, historical_events, historical_run_counts,
                historical_fish, historical_density_estimates to shiny_reader;

-- webhook_writer doesn't need this data at all (it's not part of the live
-- submission pipeline), but grant parity for future flexibility, same as
-- migration 0001 did for survey_projects/neps_tool_results. historical_fish
-- also gets DELETE -- the ETL script (scripts/migrate_sfcc_historical.py)
-- deletes and reloads it in full each run rather than upserting row-by-row,
-- since it has no natural per-row dedup key.
grant select, insert, update on historical_sites, historical_events, historical_run_counts,
                                 historical_fish, historical_density_estimates to webhook_writer;
grant delete on historical_fish to webhook_writer;
