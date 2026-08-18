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
