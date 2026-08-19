-- ============================================================================
-- Migration 0001 -- project/contract tagging, fish-record editing, NEPS tool
-- integration. Additive only (no drops) -- safe to run against the live,
-- already-populated Supabase project. Companion changes are also folded into
-- supabase/schema.sql so a fresh (re)init produces the same final shape --
-- but THIS file is what actually gets executed against the live project.
--
-- Named survey_projects, NOT projects -- a pre-existing, unrelated table
-- called `projects` already exists in this Supabase project (a 2025
-- prototype the user built separately for the same goal, confirmed not in
-- active use, real data -- 3 rows: "test", "SoS EMP 2025"/Mowi, "Knapdale
-- Beaver Project"/Nature.Scot -- deliberately left untouched). Do NOT drop
-- or modify public.projects, public.fish, public.settings, public.audit_log,
-- or public.neps_benchmark_results as part of this migration.
-- ============================================================================

create table survey_projects (
    project_id      bigint generated always as identity primary key,
    project_code    text not null unique,
    project_name    text not null,
    client_name     text,
    start_date      date,
    end_date        date,
    notes           text,
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);
create trigger trg_survey_projects_touch_updated_at
    before update on survey_projects for each row execute function fn_touch_updated_at();

alter table electrofishing_events
    add column project_id bigint references survey_projects(project_id) on delete set null;
create index idx_events_project_id on electrofishing_events (project_id);

-- Seed with the real projects recovered from the old (unused) prototype
-- public.projects table, so the tagging UI has real data from day one --
-- must stay in sync with the XLSForm choices-list slugs (see
-- scripts/add_project_question.py).
insert into survey_projects (project_code, project_name, client_name, start_date, end_date) values
    ('unassigned', 'Unassigned', null, null, null),
    ('sos_emp_2025', 'SoS EMP 2025', 'Mowi', '2025-08-13', '2025-10-24'),
    ('knapdale_beaver', 'Knapdale Beaver Project', 'Nature.Scot', '2025-10-03', '2025-11-02');

-- fish_records.updated_at doesn't exist today -- reuses the existing
-- fn_touch_updated_at() trigger function (same one sites/electrofishing_events use).
alter table fish_records add column updated_at timestamptz not null default now();
create trigger trg_fish_records_touch_updated_at
    before update on fish_records for each row execute function fn_touch_updated_at();

-- Soft delete only -- shiny_editor never gets real DELETE on fish_records.
-- A "deleted" fish just gets this set; every read of fish_records must
-- filter deleted_at is null (enforced once, in fn_db_queries.R's tbl_fish()).
alter table fish_records add column deleted_at timestamptz;

-- neps_tool_results: no event_id join available from the external tool's
-- output -- keyed on (site_name, survey_date, species, lifestage) instead.
-- Inherent limitation if two events share the same site+date (rare).
create table neps_tool_results (
    result_id                       bigint generated always as identity primary key,
    site_name                       text not null,
    site_id                         bigint references sites(site_id) on delete set null,
    easting                         integer,
    northing                        integer,
    ha_name                         text,
    ctm_name                        text,
    ctm_code                        text,
    river_order                     integer,
    survey_date                     date not null,
    species                         text check (species in ('salmon','trout')),
    lifestage                       text check (lifestage in ('fry','parr')),
    area                            numeric(8,1),
    mean_length                     numeric(6,1),
    mean_width                      numeric(6,2),
    density_predictions_successful  boolean,
    total_number_passes_warning     text,
    missing_pass_warning            text,
    nearest_river_distance          numeric(10,2),
    distance_warning                text,
    confluence_warning              text,
    organisation                    text,
    organisation_team               text,
    organisation_warnings           text,
    predictor_warnings              text,
    predictor_warnings_detailed     text,
    fished_area_warnings            text,
    total_number_passes             integer,
    counts                          text,
    probs                           text,
    observed_density                numeric(10,4),
    benchmark                       numeric(10,4),
    density_difference              numeric(10,4),
    density_per_difference          numeric(10,4),
    benchmark_warnings              text,
    imported_at                     timestamptz not null default now(),
    unique (site_name, survey_date, species, lifestage)
);
create index idx_neps_results_site_id     on neps_tool_results (site_id);
create index idx_neps_results_survey_date on neps_tool_results (survey_date);

-- shiny_editor: write-capable, scoped tightly (NOT a blanket "all tables"
-- grant like webhook_writer/shiny_reader get -- each writable table below is
-- explicit).
do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'shiny_editor') then
        -- Placeholder -- replace before running, same convention as
        -- webhook_writer/shiny_reader in roles.sql. Never commit the real
        -- password here; this file is in a public repo.
        create role shiny_editor login password 'CHANGE_ME';
    end if;
end
$$;
grant usage on schema public to shiny_editor;
-- No DELETE -- "deleting" a fish is an UPDATE setting deleted_at (soft
-- delete), not a real row removal.
grant select, insert, update on fish_records to shiny_editor;
grant select on electrofishing_events to shiny_editor;
grant update (project_id) on electrofishing_events to shiny_editor;
grant select, insert, update on survey_projects to shiny_editor;
grant select, insert, update on neps_tool_results to shiny_editor;
grant select on electrofishing_runs, sites to shiny_editor;

-- Parity for the other two existing roles
grant select, insert, update on survey_projects, neps_tool_results to webhook_writer;
grant select on survey_projects, neps_tool_results to shiny_reader;
