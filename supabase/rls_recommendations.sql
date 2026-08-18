-- ============================================================================
-- RLS remediation — NOT applied automatically.
--
-- Supabase's advisor flags every table in `public` (including this pipeline's
-- 7 tables) as having Row Level Security disabled, which means anyone with
-- your project's anon/public API key could read or write every row via the
-- auto-generated PostgREST/GraphQL API.
--
-- This pipeline's own components (the FastAPI webhook receiver, the R Shiny
-- app) connect directly to Postgres as the dedicated `webhook_writer` /
-- `shiny_reader` roles (see roles.sql) and never go through PostgREST, so
-- they are unaffected by RLS either way. The risk here is specifically about
-- Supabase's REST/GraphQL API surface — relevant only if the anon/service key
-- is ever used from a browser, mobile app, or other client that talks to
-- Supabase directly.
--
-- Two options:
--   1. If you never intend to use Supabase's REST/GraphQL API for this
--      project (only the direct Postgres connections above), the simplest
--      fix is to enable RLS with NO policies, which blocks all PostgREST/
--      GraphQL access outright while leaving direct-Postgres access (the
--      webhook_writer/shiny_reader roles) completely unaffected:
--
create extension if not exists pgcrypto;  -- already enabled by schema.sql; harmless if re-run

alter table sites                      enable row level security;
alter table electrofishing_events      enable row level security;
alter table site_width_measurements    enable row level security;
alter table site_photos                enable row level security;
alter table electrofishing_runs        enable row level security;
alter table fish_records               enable row level security;
alter table webhook_log                enable row level security;

--   2. If you DO want to query this data through Supabase's REST/GraphQL API
--      (e.g. from a future web/mobile client using the anon key), enable RLS
--      as above AND add explicit policies, e.g. a read-only policy for
--      authenticated users:
--
-- create policy "authenticated read" on electrofishing_events
--     for select using (auth.role() = 'authenticated');
--
-- Design policies per-table based on who should see what before applying.

-- ============================================================================
-- Also flagged by the advisor, unrelated to this pipeline (pre-existing
-- leftover tables from an earlier prototype in this same Supabase project):
--   public.projects, public.fish, public.settings, public.audit_log,
--   public.neps_benchmark_results
-- All are empty (0 rows). If they're not needed, consider dropping them:
--
-- drop table if exists projects, fish, settings, audit_log, neps_benchmark_results cascade;
-- ============================================================================
