-- ============================================================================
-- Least-privilege Postgres roles for direct (non-PostgREST) connections.
--
-- The FastAPI webhook receiver and the R Shiny app both connect straight to
-- Postgres (asyncpg / RPostgres), bypassing Supabase's PostgREST/RLS layer,
-- so access control here is plain Postgres GRANTs rather than RLS policies.
--
-- Replace the placeholder passwords before running, and put the real values
-- only in .env / .Renviron — never commit them.
-- ============================================================================

-- Used by the FastAPI webhook receiver (app/db.py) — can write submissions,
-- never needs DDL or DELETE (rows are updated via ON CONFLICT upserts, and
-- deletes should go through a human, not the webhook path).
create role webhook_writer login password 'CHANGE_ME';
grant usage on schema public to webhook_writer;
grant select, insert, update on all tables in schema public to webhook_writer;
grant usage, select on all sequences in schema public to webhook_writer;
alter default privileges in schema public
    grant select, insert, update on tables to webhook_writer;
alter default privileges in schema public
    grant usage, select on sequences to webhook_writer;

-- Used by the R Shiny app (shiny_app/global.R) — read-only.
create role shiny_reader login password 'CHANGE_ME';
grant usage on schema public to shiny_reader;
grant select on all tables in schema public to shiny_reader;
alter default privileges in schema public
    grant select on tables to shiny_reader;

-- Used by the R Shiny app's write paths only (shiny_app/global.R's
-- db_pool_editor — fish record editing, project tagging, NEPS tool import).
-- Deliberately scoped tightly, NOT a blanket "all tables" grant like the two
-- roles above get — each writable table is explicit, and there is no DELETE
-- anywhere (fish "deletion" is a soft delete via UPDATE ... SET deleted_at).
create role shiny_editor login password 'CHANGE_ME';
grant usage on schema public to shiny_editor;
grant select, insert, update on fish_records to shiny_editor;
grant select on electrofishing_events to shiny_editor;
grant update (project_id) on electrofishing_events to shiny_editor;
grant select, insert, update on survey_projects to shiny_editor;
grant select, insert, update on neps_tool_results to shiny_editor;
grant select on electrofishing_runs, sites to shiny_editor;
