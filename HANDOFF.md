# Handoff: Dashboard restructure + historic records integration

Written 2026-08-19, end of a planning/mockup session, for whichever chat picks this up next. Read this before touching `shiny_app/` or starting the historic-data work — the two are now one combined piece of work, not two separate ones.

## What happened this session

The user said the Shiny reporting app (`shiny_app/`) felt "disjointed and not very useful." We produced an approved plan plus four rounds of a static HTML mockup (`mockups/dashboard-restructure-v4.html` — **only v4 is kept, v1–v3 were superseded and deleted**), iterating live against the user's feedback. **No code in `shiny_app/` has been touched yet** — this was mockup-only, explicitly gated before real implementation.

The approved plan lives at `C:\Users\graem\.claude\plans\yes-create-a-mockup-lucky-gray.md` (readable by any Claude Code session on this machine — the "Phase 2" section there is the real-implementation plan, written *before* the nav-restructure and per-survey-summary rounds below, so treat it as background on the original 8-flat-tabs → dashboard rationale, not as the current target IA).

### Current target IA (as of v4, this is what's actually approved — supersedes Phase 2's flat-tab description in the plan file)

Three top-level nav items only:
1. **Projects** — cumulative/aggregate view across every survey in the current filter. Internally has 6 sub-tabs (reusing the same `.tabset`/`.subpanel` pattern as Survey Detail): Overview, Density & Trends (merged former Depletion+Trends tabs, table/chart toggle), Length-Frequency, QC Review (list only, no inline photo gallery — see below), Project Tagging, NEPS Tool Export/Import.
2. **Survey Detail** — single-survey view. Now opens on a **Summary** sub-tab by default (catch/N-estimate/density KPIs + salmon/trout length-frequency scoped to just that one survey), then Site Details, Fish Records, Photos.
3. **Site Map** — unchanged, standalone.

**Drill-down is the connective tissue**: click any survey row anywhere under Projects (recent surveys, needs-attention, the density table, the flagged-QC list) → jumps to Survey Detail with that exact survey pre-selected, landing on Summary. This is why QC Review's old inline photo gallery was deleted from the mockup — it was pure duplication once drill-down opens the real Survey Detail (which already has a Photos sub-tab). `mod_qc_review.R`'s and `mod_survey_detail.R`'s duplicated gallery `renderUI` code (noted in the original plan as a dedup candidate) should probably just become "QC Review has no gallery of its own, only Survey Detail does" rather than a shared component — reconsider that part of the plan's Phase 2 section in light of this.

Real app modules this maps onto (all still exist as separate files today — the mockup's tab consolidation is a *UI* grouping, not a proposal to merge the R files themselves, though `mod_depletion.R`+`mod_trends.R` merging into one `mod_density_trends.R` was already part of the original plan):
- Projects → sub-tabs wrap `mod_depletion.R`+`mod_trends.R` (merge), `mod_length_condition.R`, `mod_qc_review.R`, `mod_project_tagging.R`, `mod_neps_tool.R`
- Survey Detail → `mod_survey_detail.R` (needs a new Summary sub-tab added — doesn't exist in the real app yet, only in the mockup)
- Site Map → `mod_site_map.R`

Three tabs are write-capable and higher-risk to restyle: Survey Detail, Project Tagging (now a Projects sub-tab), NEPS Tool (now a Projects sub-tab). Per the original plan, these get card-wrapping only, last, most carefully — do not touch `fn_db_writes.R`, `upsert_project()`, `assign_project_to_events()`, `import_neps_results()`, or any `observeEvent`/cell-edit/modal/file-upload logic during the visual restructure.

## New scope: historic records integration (previously deferred, now active)

Old electrofishing survey data (pre-dating this pipeline) lives in a separate system, **Rockpool/SFCC** (`https://sfcc.rockpool.solutions/home.asp`). This was investigated and deliberately deferred earlier in the project ("let's save tokens for another time") — the user is now raising it again, explicitly to be handled *together* with the dashboard restructure, not as a separate follow-up.

What's already known about it (re-verify before relying on it, this is prior-session knowledge, not re-checked today):
- SFCC has built-in CSV/GIS/Fish-Density export tools (Site/Event/Fish Profiler) requiring no raw DB access — confirmed via the SFCC training manual in an earlier session.
- The user already has these exports sitting somewhere (ask them where, or check recent Downloads/project folders — not confirmed in this repo).
- No migration script, schema mapping, or import path exists yet. This is greenfield.

**Open questions the next session needs to resolve, not decided yet:**
- Do historic records become real rows in `electrofishing_events`/`electrofishing_runs`/`fish_records` (with some `source = 'rockpool_migration'` marker), or a separate read-path/table that the app treats specially?
- Historic records almost certainly have much sparser structured data than a Survey123 submission (no `qc_status`/`qc_flags` workflow, possibly no per-pass breakdown, possibly no photos, possibly different or missing site codes needing reconciliation against `sites`). Survey Detail's Summary/Site Details/Fish Records tabs assume the modern shape — decide how a historic record degrades gracefully in that same UI (empty states per section? a "Historic record — limited detail available" banner? a different, simpler read-only view reusing the same nav slot?).
- Does "Site Map" need to distinguish historic vs. modern-survey sites visually?
- Does "Projects" cumulative reporting (Density & Trends, Length-Frequency) pool historic and modern data together, or filter separately? This has real statistical implications (different collection methodologies/eras shouldn't necessarily be pooled into one Carle-Strub estimate without thought).
- Whatever the shape, it has to land inside the **same 3-tab IA** approved this session (Projects / Survey Detail / Site Map) — don't reintroduce a 4th top-level "Historic" tab without checking with the user first, since the whole point of this session's restructure was consolidating tabs, not adding one back.

## Critical files & context

- Repo root: `C:\Users\graem\OneDrive - Argyll Fisheries Trust\EF data pipeline and DB\` (git, GitHub `gandersonaft/ef-data-pipeline`, public repo — current `HEAD` as of this handoff: `9756744`, clean working tree apart from `mockups/`).
- Mockup: `mockups/dashboard-restructure-v4.html` — self-contained static HTML, open directly in a browser, no server needed. This is the visual reference for Phase 2 implementation.
- Real app: `shiny_app/` — `ui.R`, `global.R`, `server.R`, `R/*.R` (8 `mod_*.R` files, `fn_db_queries.R`, `fn_db_writes.R`, `fn_depletion.R`, `fn_neps_export.R`, `utils.R`).
- Schema: `supabase/schema.sql`, `supabase/roles.sql` (two DB roles: `shiny_reader` read-only, `shiny_editor` used by the 3 write-capable tabs), `supabase/migrations/`.
- Supabase project ref: `uhjbnhgttiqpdppntext`.
- Deploy: `shiny_app/deploy.R` (`rsconnect::deployApp`, manual/human-triggered only — never run this without the user's explicit go-ahead).
- `README.md`'s Layout section is stale (still says "3 tabs") — worth fixing whenever `shiny_app/` next gets touched, not urgent on its own.

## Suggested first steps for the next session

1. Read the mockup (`mockups/dashboard-restructure-v4.html`) and the original plan file to get full context on *why* each IA decision was made — don't re-derive from scratch.
2. Ask the user where the Rockpool/SFCC exports actually are, and get a sample file to inspect its real shape before designing a schema mapping.
3. Given the sample, come back with a proposed data model for historic records (new column(s) on existing tables vs. a parallel table) and how Survey Detail/Projects/Site Map should degrade for them, **before** writing migration code — this is a plan-mode-worthy decision, not a quick call.
4. Only after historic-records data modeling is settled, proceed with the Phase 2 Shiny restructure (theme, KPI row, card-wrapping, the 3-tab nav) so the new views are built against the final schema instead of needing a second pass.
