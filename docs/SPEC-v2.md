# EF Data Pipeline v2: Specification (DRAFT for sign-off)

Status: **planning only. No code, schema, or infrastructure changes are made until the Decision Register (section 14) is signed off.**
Drafted: 2026-10-03. Baseline reviewed: `main` @ `5b256cd` (NEPS-only pipeline + historical SFCC migration).

Conventions: **[REC]** = recommended option. **[CONFIRM]** = something I could not verify from the repo; you know the answer. **[BASELINE]** = how the current build does it.

---

## 1. Goals and non-goals

### Goals
1. One system that captures, stores, QCs, analyses and reports **three survey types**: Timed, SFCC 1mm, NEPS.
2. NEPS and SFCC each supported as **single-run** or **multi-run**.
3. Each survey type gets the analysis that is *statistically valid for it*. No silent pooling of incompatible methods.
4. One storage model that also holds legacy SFCC/Rockpool history, so old and new surveys are queryable the same way.
5. Outputs: dashboard, NEPS tool export/import round-trip, SFCC/Rockpool-compatible export, KML/GPS waypoints, CSV.

### Non-goals (unless you say otherwise)
- Replacing the Marine Directorate NEPS tool or Rockpool as systems of record for their own modelled outputs.
- Public-facing access. This is an internal AFT tool.
- Habitat-only or non-electrofishing surveys.

---

## 2. What the current build does (baseline) and what we keep or change

| Area | Baseline | v2 stance |
|---|---|---|
| Capture | One Survey123 form `efish_neps_v8` (main event, `rep_pass`, `rep_fish`, `rep_photos`, `rep_widths`) | Keep Survey123 as default, but protocol-aware (section 5) |
| Ingestion | AGOL webhook never delivered (zero attempts). Hourly GitHub Actions poller is the real path. New submissions only, no edit capture | Poller becomes the designed path, add edit capture (section 6) |
| Backend | FastAPI on Render (webhook + shared `processing.py`), Supabase Postgres/PostGIS/Storage | Re-evaluate whether FastAPI is still needed (section 7) |
| Data model | NEPS multi-pass only. Passes are rows in `electrofishing_runs`. Historical SFCC kept in 5 separate `historical_*` tables | Generalise to protocol + run mode, decide on historical unification (section 4) |
| Analysis | Carle-Strub via `FSA::removal` for every event, NEPS tool import | Per-protocol analysis (section 8) |
| QC | Pass progression, condition factor, incomplete fish rows | Per-protocol rule sets (section 9) |
| UI | R Shiny, 3 tabs: Projects / Survey Detail / Site Map | Keep IA, add protocol awareness (section 10) |

**Lessons from the baseline that must be designed in, not rediscovered:**
- AGOL relationship IDs can silently change on republish and `queryRelatedRecords` returns empty, not an error. v2 needs an assertion: "an event with N fish rows reported by the form must not ingest as 0 fish."
- One bad child row must never lose the whole submission (skip + flag).
- Supabase direct host is IPv6-only; Render, GitHub Actions and similar need the Supavisor pooler.
- Form-reported totals are cross-checks only. Server-derived counts from raw fish rows are the source of truth.
- `calc_stage` on the form is dead. Only the user-selected `lifestage` is trusted.

---

## 3. Survey types and run modes

### 3.1 Definitions

| | Timed | SFCC 1mm | NEPS |
|---|---|---|---|
| Intent | Semi-quantitative: relative abundance / presence | Quantitative site survey to the SFCC standard, lengths to 1 mm [CONFIRM what "1mm" denotes] | Quantitative survey feeding the national programme (Marine Directorate NEPS tool) |
| Run modes | **Single only** (one timed fishing effort). Multi-timed is an option, see D3 | Single or multi | Single or multi |
| Area measured | Optional (effort is time, not area) | Required | Required |
| Effort metric | Fishing time (seconds) per run | Area, plus pass times | Area, plus pass times |
| Individual lengths | Optional (option: counts only) | Required for salmonids [CONFIRM] | Required for salmonids [CONFIRM] |
| Lifestage | Optional | Fry/parr (or SFCC age class 0-4, see D6) | Fry/parr with species-specific length cutoffs |
| Primary output | CPUE (fish per minute), presence/absence, species richness | Density (fish/100 m2) via depletion (multi) or assumed capture probability (single) | NEPS tool output: density, benchmark, EQR-style comparison |
| Poolable with others? | No (different metric) | Only with other SFCC quantitative | Only with other NEPS, and with SFCC quantitative by explicit choice |

### 3.2 Valid combinations (5)

| protocol | run_mode | Notes |
|---|---|---|
| `timed` | `single` | one effort, time-based |
| `sfcc_1mm` | `single` | one pass, density needs an assumed capture probability or a minimum-density label |
| `sfcc_1mm` | `multi` | 2+ passes, depletion estimate |
| `neps` | `single` | density comes from the NEPS tool's model, not depletion |
| `neps` | `multi` | depletion locally + NEPS tool |

Everything else is rejected at capture time and by a DB `CHECK`.

### 3.3 Run-mode semantics to settle (feeds D3)
- `planned_runs` vs `actual_runs`: a multi-run survey can end early (e.g. zero catch on pass 2 ends it). Store both, flag mismatch as info, not error.
- A survey planned as multi but only one pass done: store `run_mode='multi'`, `actual_runs=1`, and mark analysis as "not estimable".
- A site fished with a different protocol on the same date: allowed (two events, same site and date). The NEPS-results join key `(site, date, species, lifestage)` from the baseline breaks here; v2 must key on `event_id` (see 4.4).

---

## 4. Data model

### 4.1 Options

| Option | Description | Pros | Cons |
|---|---|---|---|
| **A. One wide set + discriminator** | `events.protocol`, `events.run_mode`, protocol-specific columns nullable | Simplest queries, one UI path | Wide table with many NULLs, protocol rules only in app/CHECKs |
| **B. Table per protocol** | `timed_events`, `sfcc_events`, `neps_events` | Strict per-protocol constraints | Triplicated child tables, painful cross-protocol queries and map |
| **C. Core + protocol extension tables** **[REC]** | `events` (shared fields + `protocol`, `run_mode`) plus 1:1 `event_neps`, `event_sfcc`, `event_timed` for protocol-only fields. Shared `runs`, `fish_records`, `photos`, `widths` | Shared plumbing, strict per-protocol fields, easy cross-protocol views | A few more joins; need a view per protocol |

### 4.2 Proposed core entities (Option C)

```
sites ─┬─< events >─┬─< runs >─< fish_records
       │            ├─< site_photos
       │            ├─< width_measurements
       │            ├── event_neps   (1:1, protocol='neps')
       │            ├── event_sfcc   (1:1, protocol='sfcc_1mm')
       │            └── event_timed  (1:1, protocol='timed')
survey_projects ─< events
```

**events** (shared): `event_id`, `source_system` (`survey123` | `rockpool_migration` | `manual`), `source_id` (globalid or SFCC EventId, unique per source), `site_id`, `site_code`, `protocol`, `run_mode`, `planned_runs`, `actual_runs`, `project_id`, survey date and times, captured location (4326 + 27700), water chemistry, crew, equipment, substrate and flow percentages, reach length, widths, area (nullable), pollution/stocking, comments, `qc_status`, `qc_flags`, `raw_payload`, timestamps.

**runs** (shared): `run_id`, `event_id`, `run_no`, `effort_seconds` (anode time; for Timed this *is* the timed effort), `total_run_seconds`, form-reported totals (cross-check only). Unique `(event_id, run_no)`. Timed always has exactly one run, so the timed effort lives in the same column and nothing needs a special case.

**fish_records** (shared): `fish_id`, `run_id`, `species`, `length_mm` (nullable), `lifestage` (nullable), `age_class` (nullable 0-4, SFCC resolution), `count` (bulk count, default 1), `weight_g`, `condition_factor` (trigger), `scaled`, `tissue_tube`, `entry_mode`, `qc_flag`, soft-delete `deleted_at`.

**Protocol extension examples**
- `event_neps`: fry/parr cutoffs per species, NEPS tool inputs not already in events, HA/CTM metadata if captured at survey time.
- `event_sfcc`: SFCC event id if known, length-resolution flag, SFCC fishing-type label, published status.
- `event_timed`: target species, habitat type fished, whether lengths were taken.

### 4.3 Historical SFCC data: unify or keep separate? (D5)

| Option | Pros | Cons |
|---|---|---|
| **Keep `historical_*` tables (baseline)** | Zero risk to live data; SFCC SiteCode non-uniqueness handled separately | Every report needs a UNION; two read paths forever; v2's protocol model duplicated |
| **Unify into `events` with `source_system='rockpool_migration'`** **[REC]** | One model, one query path, protocol filter works across eras | Needs a one-off remap of 1,961 events / 66,627 fish; pre-aggregated-only events (~300 with no individual fish) need a place to live (see below) |
| **Unify, but keep `historical_density_estimates` as a side table** | Preserves SFCC's own Zippin/Carle-Strub numbers as a cross-check | Small extra table |

Pre-aggregated-only legacy events (counts per run, no individual fish): represent as `fish_records` with `count = n` and `length_mm = NULL` (this is exactly the existing bulk mode). That removes the need for `historical_run_counts`. **[REC]**

Legacy method labels map to protocol as: `Quantitative (1mm)` -> `sfcc_1mm`; `Timed` -> `timed`; `Quantitative (5mm)` and `Presence/Absence` have no v2 protocol. Options: (a) add `sfcc_5mm` and `presence_absence` as read-only legacy protocols **[REC]**, (b) collapse to a generic `legacy_other`. Needs your call (D6).

### 4.4 NEPS tool results
Re-key `neps_tool_results` on `event_id` instead of `(site_name, survey_date, species, lifestage)`. Import matches on the old key and writes `event_id`; unmatched or ambiguous rows (same site and date, two events) go to a review queue, not a silent guess.

### 4.5 Constraints that encode the protocol rules
- `CHECK (protocol, run_mode) IN (the 5 valid pairs)` plus legacy pairs.
- `timed`: `actual_runs = 1`.
- `neps`, `sfcc_1mm`: `area_m2 IS NOT NULL` once `qc_status <> 'pending'` (enforced as QC flag, not a hard insert failure, so partial field data can still land).
- Species, lifestage and protocol enums as lookup tables, not inline `CHECK` lists, so adding a species is data, not DDL. **[REC]**

### 4.6 Other model decisions
- **IDs**: keep Esri `globalid` (normalised) as the idempotency key via `(source_system, source_id)`.
- **Geometry**: keep dual 4326 + 27700, generated columns.
- **Audit**: add an `edit_log` (who, when, table, row, before/after JSON) for any post-ingest edit. The baseline only has `updated_at` and soft-delete. **[REC]**
- **Projects**: keep `survey_projects` tagging, independent of site.
- **Sites**: keep CSV-seeded master plus "new site" from form. Add a promotion workflow for form-created sites (see 6.4).

---

## 5. Field capture

### 5.1 Platform options

| Option | Offline | Cost/effort | Notes |
|---|---|---|---|
| **Survey123 (baseline)** **[REC]** | Yes | Already built, you know it; XLSForm | The webhook problem is an AGOL org/admin issue, solved by polling |
| ArcGIS Field Maps | Yes | Higher setup, map-centric | Better for map-driven site selection, weaker for repeat-heavy forms |
| ODK / KoboToolbox (XLSForm) | Yes | New stack; export via API | Open, no AGOL dependency, webhooks (REST services) are reliable. Reuses XLSForm skills |
| Custom PWA | Yes if built well | Highest | Total control; you maintain it |
| Spreadsheet/paper then entry | n/a | Lowest | Keep as a documented fallback import path regardless (6.5) |

### 5.2 One form or several (D2)

| Option | Pros | Cons |
|---|---|---|
| **One form, protocol + run mode chosen first, `relevant` logic drives the rest** **[REC]** | One submission schema, one service, one poller, one set of AGOL relationship IDs | Larger form, relevance logic must be tested per protocol |
| Three forms (Timed / SFCC / NEPS) | Simple per-form UX | 3 services, 3 pollers, 3 relationship-ID maps, duplicated site lists |
| Two forms (Quantitative vs Timed) | Middle ground; NEPS and SFCC share fish/pass structure | Protocol still needs a selector inside the quantitative form |

### 5.3 Form behaviour by protocol (for the XLSForm)

| Section | Timed | SFCC 1mm | NEPS |
|---|---|---|---|
| Protocol, run mode | required | required | required |
| Site select / new site | yes | yes | yes |
| Site dimensions (widths, lengths, area) | optional | required | required |
| Pass loop | exactly 1 (timer) | 1 if single, repeat if multi | 1 if single, repeat if multi |
| Pass-level timer | countdown/stopwatch for effort | per pass | per pass |
| Fish entry | species + count; length optional | individual (length mm) or bulk | individual or bulk, cutoff-driven lifestage |
| Fry/parr cutoffs | n/a | default per species, editable | default per species, editable |
| Weight, scale, tissue | optional | optional | optional |
| Habitat (substrate, flow %) | optional | required | required |
| Photos | yes | yes | yes |

Form-side requirements (carry over): required-field validation must be **on** in production (baseline had it stripped for testing, which is why QC flagged incomplete fish rows), calculated fields from the baseline (`dep_*`, `den_*`, `catch_summary*`) stay presentation-only and are never ingested.

### 5.4 Accessing the existing form
The XLSForm lives on your Windows machine (`C:\Users\graem\ArcGIS\My Survey Designs\...`), which this cloud session cannot see. To base v2 form logic on it, I need the `.xlsx` (or a pasted export) in the repo or attached. [CONFIRM]

---

## 6. Ingestion

### 6.1 Options

| Option | Reliability | Captures edits | Notes |
|---|---|---|---|
| AGOL feature-layer webhook (baseline) | Failed: zero deliveries across 2 mechanisms | Yes in theory | Needs org admin; do not depend on it |
| **Scheduled polling (GitHub Actions / Render cron)** **[REC]** | High | Yes if using `editDate` | Known-good in baseline; hourly lag is fine for this data |
| Extract Changes on a schedule | High | Yes, includes deletes | More complex; async job pattern already written in `esri.py` |
| Manual "pull now" button/CLI | Highest control | n/a | Keep as an admin tool alongside polling |
| ODK/Kobo REST service | High | Edits via update | Only if platform changes (5.1) |

### 6.2 Polling design (REC)
- High-water mark per layer on `editDate`, not just `objectid`, so edits to already-ingested events re-sync (baseline gap).
- Each cycle: query changed main-layer features, fetch the full tree (event -> runs -> fish, photos, widths) with relationship IDs **resolved dynamically from layer metadata**, never hard-coded (baseline bug).
- Whole-event upsert in one transaction; `ON CONFLICT (source_system, source_id)`.
- Sanity assertion: if the main-layer record's form-reported fish total > 0 and ingested fish = 0, mark event `qc_status='flagged'` with `ingest_mismatch` and alert.
- Soft-deleted AGOL features: mark event `source_deleted_at`, do not hard-delete.

### 6.3 Photos
Download attachments to a private Supabase Storage bucket at `electrofishing/{year}/{site_code}/{global_id}.{ext}`; signed URLs generated at read time, never cached as permanent values.

### 6.4 New-site promotion
A survey that creates a new site enters `sites` as `source='survey_new_site'` with `needs_review=true`; a Shiny/admin action promotes it (confirms code, coordinates, river, catchment) and updates `site_data.csv` or replaces the CSV with the table as master. Decide the master in D8.

### 6.5 Non-form imports (all in scope as options)
1. SFCC/Rockpool export CSVs (historical, section 4.3), re-runnable and idempotent.
2. Paper/spreadsheet entry via a validated CSV template per protocol.
3. NEPS tool result CSV (section 4.4).

### 6.6 Operations
- Poll run log table (`ingest_run`: started, finished, events seen/upserted/failed, errors) replacing `webhook_log` as the audit trail; failed events retained for replay.
- Alert on: poll failure, 0 events in N days during survey season, ingest mismatch.
- GitHub Actions concurrency group so overlapping runs cannot race.

---

## 7. Backend and hosting

| Layer | Options | Rec |
|---|---|---|
| DB | Supabase Postgres + PostGIS (baseline); self-hosted PG; Neon | Keep Supabase |
| Ingest runtime | GH Actions cron (baseline); Render cron; Supabase Edge Function + pg_cron; keep FastAPI webhook | GH Actions or Render cron. Drop the FastAPI web service unless webhooks are revived. Saves a running service |
| Storage | Supabase Storage private bucket | Keep |
| Dashboard | R Shiny on Posit Connect Cloud (baseline); Shiny on Render; Python (Streamlit/Dash); Metabase/Superset | Keep Shiny: the analysis stack (FSA, NEPS tool format) is R |
| Secrets | `.env` + Actions secrets + Render env | Same, but never commit real values; note repo is **public** |

Roles (least privilege), extending baseline: `ingest_writer` (insert/update everything ingest touches), `shiny_reader` (select), `shiny_editor` (fish edits, project tagging, NEPS import, site promotion; no hard DELETE anywhere), plus RLS review per `supabase/rls_recommendations.sql`.

---

## 8. Analysis specification (per protocol)

### 8.1 Estimator options

| Method | Needs | Use for |
|---|---|---|
| Minimum density (first-pass or total catch / area) | 1+ pass, area | Labelled "minimum", always available for quantitative |
| Zippin (maximum likelihood removal) | 2+ passes | SFCC legacy comparability |
| Carle-Strub (`FSA::removal`) **[REC for local multi]** | 2+ passes | SFCC and NEPS multi-run, matches baseline and the form's on-device calc |
| Seber-Le Cren / Moran | 2-3 passes | Optional alternative; only if you want sensitivity checks |
| Assumed capture probability (single run) | 1 pass + a defensible p | SFCC single: **explicitly labelled as assumption**; p configurable per species/lifestage/year |
| NEPS tool model (hierarchical capture probability) | Event metadata, counts, area | **Primary for all NEPS** incl. single-run; import results (4.4) |
| CPUE (fish/min), presence/absence, richness | Effort seconds | Timed only |

### 8.2 Output matrix

| Output | Timed | SFCC single | SFCC multi | NEPS single | NEPS multi |
|---|---|---|---|---|---|
| Catch by species / lifestage | yes | yes | yes | yes | yes |
| CPUE | **yes (primary)** | optional | optional | optional | optional |
| Minimum density | no | yes | yes | yes | yes |
| Carle-Strub N and density | no | no | yes | no | yes (cross-check) |
| Assumed-p density | no | optional | no | no | no |
| NEPS tool density + benchmark | no | no | no | **yes (primary)** | **yes (primary)** |
| Length-frequency | if lengths taken | yes | yes | yes | yes |
| Condition factor | if weights | if weights | if weights | if weights | if weights |

### 8.3 Pooling and comparison rules (D7)
Default behaviour in cumulative views:
- Timed is **never** pooled with quantitative; shown on its own CPUE panels.
- SFCC and NEPS quantitative are shown **separately by default**, with an explicit "combine quantitative methods" toggle plus a visible caveat banner. **[REC]**
- Legacy and modern surveys of the same protocol may be pooled, shown by era on the trend axis.
- Fry/parr: derived from length vs cutoff when lifestage unanswered (baseline commit `9756744`); retain, record `lifestage_source` (`observed` | `derived`).

### 8.4 Computation location
Options: (a) compute in R at read time (baseline), (b) compute in Postgres views/materialised views, (c) compute at ingest and store results in `event_estimates`. **[REC] (c)**: ingest/analysis step writes `event_estimates(event_id, species, lifestage, method, n_est, se, p, density_100m2, ci_low, ci_high, assumptions_json, computed_at)`. Pros: Shiny stays fast, results are auditable and versioned by method; recompute is a script. Cons: must recompute on fish edits (trigger or job).

---

## 9. QC specification

Severity: `error` (blocks "ok"), `warn`, `info`. Event `qc_status`: `pending` -> `ok` | `flagged` -> `reviewed` (human sign-off, who and when stored).

| Rule | Applies to | Severity |
|---|---|---|
| Pass progression: later pass catch > earlier (per species and lifestage) | multi only | warn |
| Missing area | sfcc, neps | error |
| Missing effort seconds | all runs; Timed especially | error (timed), warn (others) |
| `actual_runs` vs `planned_runs` mismatch | multi | info |
| Single-run NEPS/SFCC flagged "density: minimum only" | single | info |
| Zero fish, whole event | all | warn |
| Species missing or invalid on a fish row (skipped row) | all | warn, count recorded |
| Length missing on salmonid | sfcc, neps | warn |
| Length outlier per species (configurable bounds) | all | warn |
| Lifestage vs cutoff disagreement | sfcc, neps | warn |
| Condition factor outside 0.6-1.8 | if weights | warn |
| Water temperature/conductivity implausible | all | warn |
| Substrate or flow % does not total ~100 | sfcc, neps | warn |
| Location > N m from the site's canonical point | all | warn |
| Same site, same date, same protocol duplicate | all | warn |
| Ingest mismatch (form total > 0, ingested 0) | all | error |
| Form-reported vs server-derived totals disagree | all | info |
| Retired/unknown site code | all | error |

Thresholds live in a `qc_config` table (editable), not code constants. Every flag stores rule id, severity, detail, and the offending row id.

---

## 10. Dashboard and UX

### 10.1 Information architecture
Keep the approved 3 top-level tabs (Projects / Survey Detail / Site Map). v2 changes are inside them:

- **Global filter bar**: protocol (multi-select), run mode, date range, catchment/river, project, source (live/legacy), QC status.
- **Projects**: Overview (counts by protocol), Density & Trends (quantitative), **CPUE & Presence (Timed)**, Length-Frequency, QC Review, Project Tagging, NEPS Tool.
- **Survey Detail**: Site-first picker as built. The Summary tab adapts: Timed shows catch, effort, CPUE; quantitative shows the three-tier density table; single-run shows the "minimum / assumed-p" labelling and hides depletion. Legacy events show a "legacy record" banner and hide sections with no data.
- **Site Map**: colour by protocol (and shape by run mode); legend; OS Open Rivers overlay kept.

### 10.2 Write-capable features (keep guarded)
Fish record edit (soft delete), project tagging, NEPS import, site promotion, QC "mark reviewed". All writes through `shiny_editor`, all logged to `edit_log`, estimates recomputed after edits.

### 10.3 Degradation rules
Any panel whose prerequisites are absent shows an explicit empty state naming the reason ("Timed survey: density not applicable", "Single run: depletion needs 2+ passes") rather than a blank or an `NA`.

### 10.4 Exports (all options)
1. NEPS tool input workbook (baseline `fn_neps_export.R`, extend to single-run).
2. **SFCC/Rockpool upload-format CSV** (new). Options: just CSV matching their import template, or also a validation report. [CONFIRM Rockpool upload format]
3. Plain CSV per table / filtered view.
4. KML waypoints with site size data (existing `efish-site-kml-export` skill).
5. Chart/table export buttons (baseline).
6. Scheduled PDF/Excel annual report per project: optional phase.

---

## 11. Security, privacy, compliance
- Repo is public: no secrets, no project data, no real passwords in migrations (baseline used `CHANGE_ME`; keep). Review whether the Supabase project ref and client names (e.g. Mowi) in the repo should remain public.
- Enable RLS on all tables; roles grant only what each component needs.
- Photos: private bucket, signed URLs only.
- Landowner/site location sensitivity for exports: option to round coordinates in exports shared outside AFT.
- Backups: Supabase PITR or scheduled `pg_dump` to storage. [CONFIRM plan tier]

---

## 12. Testing and quality
- Unit: pydantic models and the per-protocol validators; QC rules; estimators (golden values vs FSA/known datasets, including single-run and zero-catch edge cases).
- Fixtures: **one sample payload per valid combination (5)**, plus malformed variants (missing species, orphan child, zero fish).
- Integration: poller against a recorded AGOL fixture; idempotency (run twice, no diff); edit re-sync.
- Migration test: restore a Supabase branch, apply migrations, verify counts (events, fish, runs) before and after.
- Shiny: smoke tests per protocol, with `shinytest2` as an option.
- CI: GitHub Actions runs pytest + SQL lint + R `lintr` on PR.

---

## 13. Delivery plan (phases, each with an exit test)

| Phase | Scope | Exit criteria |
|---|---|---|
| 0. Decisions | Resolve section 14; obtain XLSForm, Rockpool upload template, sample single-run/timed data | Sign-off recorded here |
| 1. Data model | Migrations for events/runs/fish/extension tables, lookups, constraints, `edit_log`, `qc_config`, `event_estimates`; apply on a Supabase **branch** first | Migrations pass on branch; constraint tests pass |
| 2. Historical remap | Move `historical_*` into unified model (if D5 = unify) | Row counts reconcile exactly with baseline; spot-check 20 events |
| 3. Form v9 | Protocol-aware XLSForm | Field-tested on all 5 combinations offline |
| 4. Ingest | Poller with `editDate`, dynamic relationship IDs, mismatch assertion | Each of the 5 combos ingests end to end; edit round-trips |
| 5. QC + estimates | Rule engine, estimator jobs | Golden-value tests pass; QC table reviewed by you |
| 6. Dashboard | Filters, protocol-aware panels, map encodings | Walk-through per protocol |
| 7. Exports | NEPS (single + multi), SFCC CSV, KML | Round-trip into the NEPS tool succeeds |
| 8. Cutover | Switch form, retire unused services, docs, runbook | One full field week ingested without manual intervention |

Rollback: every phase's migration is additive until Phase 8; the baseline keeps running untouched until cutover.

---

## 14. Decision Register

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D0 | Where does v2 live? | New repo; new branch/folder in this repo; in-place evolution | New long-lived branch in this repo (keeps history and lessons), merge at cutover |
| D1 | Capture platform | Survey123 / Field Maps / ODK-Kobo / PWA | Survey123 |
| D2 | Forms | One / two / three | One protocol-aware form |
| D3 | Timed multi-run? Single-run termination rules? | Timed single only / allow multi-timed | Timed single only |
| D4 | Data model | A wide / B per-protocol / C core + extensions | C |
| D5 | Legacy SFCC data | Keep separate / unify / unify + side table for SFCC estimates | Unify + side table |
| D6 | Legacy protocols (5mm, Presence/Absence) and SFCC age class 0-4 | Read-only legacy protocols / collapse to `legacy_other`; keep age class or collapse to fry/parr | Read-only legacy protocols; store age class and derive lifestage |
| D7 | Pooling default | Always separate / separate with toggle / always pooled | Separate with explicit toggle and caveat |
| D8 | Site master | CSV file / `sites` table with promotion workflow | Table is master; CSV becomes an export |
| D9 | Ingest | Webhook / polling / Extract Changes | Polling on `editDate` |
| D10 | FastAPI service | Keep / retire | Retire unless webhooks are revived |
| D11 | Analysis location | R at read time / SQL views / precomputed `event_estimates` | Precomputed |
| D12 | Single-run SFCC density | Minimum only / assumed capture probability (configurable) | Show both, label clearly |
| D13 | Required-field validation in form | On / off | On in production |
| D14 | SFCC/Rockpool export | None / CSV matching template / CSV + validation | CSV + validation (needs the template) |
| D15 | Public repo hygiene | Keep public / make private | Make private if feasible, otherwise scrub client names and project ref |

---

## 15. Information I need from you (cannot be derived from the repo)

1. **What does "SFCC 1mm" mean in your protocol?** (Length recorded to 1 mm vs 5 mm bins? Anything else that changes data capture?)
2. **Timed**: how is a timed survey run in practice? (Fixed duration, e.g. 5 min? One habitat or several? Are lengths taken? Is area recorded?)
3. **Single-run NEPS/SFCC**: how are these used? (Always one pass by design, or sometimes a planned-multi cut short?) Do you want density for single-run SFCC at all, or only catch and minimum density?
4. The current **XLSForm** (`efish_neps_v8`) as a file in the repo or attached, so form v9 builds on the real structure.
5. The **Rockpool upload template** if you need to submit data back to SFCC.
6. Whether v2 is replacing the current system for everyone at AFT, or running alongside it.
7. Any survey seasons or deadlines the cutover must avoid.

---

## 16. Risks

| Risk | Mitigation |
|---|---|
| Protocol-specific rules misunderstood | Section 15 answers before Phase 1; per-protocol golden datasets |
| Historical remap loses or duplicates data | Branch rehearsal, reconciliation counts, baseline tables kept until cutover |
| AGOL relationship IDs change after a republish | Dynamic resolution + ingest-mismatch assertion |
| Mixed-method pooling produces misleading trends | Separate-by-default, visible caveats, `method` carried on every estimate |
| Estimates stale after a fish edit | Recompute job triggered on write; `computed_at` shown |
| Single-run density over-interpreted | Always labelled minimum or assumed-p, with the assumption stored |
| Scope creep from "include all options" | Options are recorded here; only the signed-off choices go into Phase 1 |
