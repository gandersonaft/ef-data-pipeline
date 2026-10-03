# EF Data Pipeline v2: Specification (DRAFT for sign-off)

Status: **planning only. No code, schema, or infrastructure changes are made until the Decision Register (section 14) is signed off.**
Drafted: 2026-10-03. Revision 3: 2026-10-03 (network-wide scale, Timed details, 5 mm retained; see section 17). Baseline reviewed: `main` @ `5b256cd` (NEPS-only pipeline + historical SFCC migration).

Conventions: **[REC]** = recommended option. **[CONFIRM]** = something I could not verify from the repo; you know the answer. **[BASELINE]** = how the current build does it.

---

## 1. Goals and non-goals

### Goals
1. One system that captures, stores, QCs, analyses and reports **three survey types**: Timed, SFCC 1mm, NEPS.
2. NEPS and SFCC each supported as **single-run** or **multi-run**.
3. Each survey type gets the analysis that is *statistically valid for it*. No silent pooling of incompatible methods.
4. One storage model that also holds legacy SFCC/Rockpool history, so old and new surveys are queryable the same way.
5. **Built for SFCC network-wide use: 50-100 users across multiple trusts/organisations, on tablets (some phones), in poor-signal conditions.** This is a design driver for platform, offline behaviour, data ownership and support, not a later add-on (sections 4.7, 5.5, 7.1).
6. Outputs: dashboard, NEPS tool export/import round-trip, SFCC/Rockpool-compatible export, KML/GPS waypoints, CSV.

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
| Intent | Index of abundance: catch per unit effort (time), used to cover many sites quickly or where removal sampling is impractical | Quantitative, area-delimited site survey to the SFCC standard; **fork length recorded in 1 mm bins** (the legacy alternative is 5 mm bins) | Quantitative, area-delimited survey feeding the national programme (Marine Directorate NEPS tool) |
| Run modes | **Single only** (one timed fishing effort). Multi-timed is an option, see D3 | Single or multi | Single or multi. **NEPS national default is single-pass; roughly a third of sites are three-pass**, with identical first-pass effort in both [UNVERIFIED, from search summary] |
| Area measured | Optional (effort is time, not area). **No stop nets** (your answer): stored as `stop_nets=false`, defaulted for Timed | Required | Required (all NEPS data are area-delimited) |
| Effort metric | **Anode-live time** from the equipment timer (time actually fished, not wall-clock). Your answer: a **target duration** applies. Stored per event (`target_duration_s`) with the org/network default configurable (commonly 5 to 10 min in the sources I could find), and the form shows the timer against target | Area, plus pass times | Area, plus pass times |
| Individual lengths | Optional: **may be taken** (your answer), so the form offers a per-survey "lengths taken?" switch | Parr: all measured. Fry: if more than ~50 per run, a measured subsample of at least 50 and the rest counted [UNVERIFIED] | Same measured-subsample pattern [CONFIRM against the NEPS protocol] |
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

### 3.2b Single-run in practice (your answer: all cases occur)
All three occur and must be representable:
1. **Single by design** (e.g. NEPS national single-pass sites): `run_mode='single'`, `run_mode_reason='design'`.
2. **Planned multi, cut short** (e.g. weather, equipment, access): `run_mode='single'` (what was actually done), `planned_runs>=2`, `run_mode_reason='cut_short'`, with a required free-text `termination_reason`. Analysis treats it as single-pass.
3. **Multi that is analysed as single** (first pass of a multi-pass survey used for a single-pass-equivalent density): derived, not captured. Provide a `first_pass_only` analysis view over any multi event (relies on first-pass effort being identical, per NEPS).

You also want density from single-run data, so the output matrix in section 8 includes it for both SFCC and NEPS, always labelled by how it was derived.

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

**fish_records** (shared): `fish_id`, `run_id`, `species`, `length_mm` (nullable; the recorded value, binned per `events.length_bin_mm`), `lifestage` (nullable), `age_class` (nullable 0-4, SFCC resolution), `count` (bulk count, default 1), `measured` (boolean: true = individually measured fish; false = counted-only remainder of a subsampled group), `weight_g`, `condition_factor` (trigger), `scaled`, `tissue_tube`, `entry_mode`, `qc_flag`, soft-delete `deleted_at`.

**Length recording and subsampling (new in rev 2)**
- `events.length_bin_mm` in {1, 5, NULL}. New SFCC 1mm and NEPS surveys use 1; legacy 5 mm surveys carry 5; Timed with no lengths carries NULL. Length-frequency charts bin at `max(length_bin_mm, chart bin)`, never finer than the data.
- Fry subsampling: per run, per species and lifestage, store measured fish as individual rows (`measured=true`) and the remainder as one counted row (`measured=false`, `count=n_remaining`, `length_mm=NULL`). Catch totals sum both; length-frequency uses measured rows only and is expanded to the total by proportion (option: show raw measured only). QC checks that measured count meets the protocol minimum when the group size exceeds the threshold.

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

Legacy method labels map to protocol as: `Quantitative (1mm)` -> `sfcc_1mm` (`length_bin_mm=1`); `Quantitative (5mm)` -> `sfcc_5mm` (`length_bin_mm=5`, same analysis as 1mm but coarser length data); `Timed` -> `timed`; `Presence/Absence` has no v2 protocol. Options: (a) add `sfcc_5mm` and `presence_absence` as read-only legacy protocols **[REC]**, (b) collapse to a generic `legacy_other`, (c) model SFCC quantitative as one protocol `sfcc_quant` with `length_bin_mm` in {1,5} and offer only 1 for new surveys. (c) is cleaner now that 1mm vs 5mm is known to be a recording resolution, not a different method. Needs your call (D6).

### 4.4 NEPS tool results
Re-key `neps_tool_results` on `event_id` instead of `(site_name, survey_date, species, lifestage)`. Import matches on the old key and writes `event_id`; unmatched or ambiguous rows (same site and date, two events) go to a review queue, not a silent guess.

### 4.5 Constraints that encode the protocol rules
- `CHECK (protocol, run_mode) IN (the 5 valid pairs)` plus legacy pairs.
- `timed`: `actual_runs = 1`.
- `neps`, `sfcc_1mm`: `area_m2 IS NOT NULL` once `qc_status <> 'pending'` (enforced as QC flag, not a hard insert failure, so partial field data can still land).
- Species, lifestage and protocol enums as lookup tables, not inline `CHECK` lists, so adding a species is data, not DDL. **[REC]**

### 4.7 Multi-organisation model (new: network-wide use)
Fifty to a hundred users across trusts means ownership and access are data-model concerns:
- `organisations` (trust/board/agency) and `users` (linked to Supabase Auth or the form platform identity), with `memberships(user, org, role)`.
- Every `event` carries `org_id` (who owns the data) and `submitted_by`. `sites` carry an owning `org_id` and a visibility setting.
- Roles: `surveyor` (submit own), `team_lead`, `org_reviewer` (QC and edit their org's data), `org_admin`, `network_admin` (cross-org), `read_only_network`.
- RLS policies enforce org scoping in the database, not just in the UI.
- Sharing policy is a **governance decision (D18)**: org-private, network-shared read, or fully shared. Default **[REC]**: org-private for editing, network-shared read for site-level aggregates, with a per-org opt-in for event detail.
- Reference data (species, protocols, cutoffs, QC thresholds) is network-level; each org may have overrides (e.g. default target duration, default length bin) in `org_settings`.
- Legacy Rockpool data stays attributed to its `event_trust`, mapped to `org_id`.

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

### 5.1b Platform implications of 50-100 users (D17)
| Concern | Survey123 / AGOL | ODK / KoboToolbox / ODK Central |
|---|---|---|
| Licensing | Each submitter needs a named-user AGOL licence (Creator/Field Worker) under a **shared organisation**; 50-100 cross-trust users means someone's AGOL org licenses or invites them all. Cost and admin are real [CONFIRM how SFCC/AFT would license this] | No per-user licence cost; self-host or hosted |
| Cross-org isolation | Via groups/views; clumsy | Projects/users per project in ODK Central |
| Offline | Strong | Strong (Collect app), forms and attachments queue and sync |
| Distribution of form updates | Via AGOL, users re-download | Pull from server on connect |
| Reliable server-to-server data feed | Webhooks failed in your org; polling works | REST service/webhooks work; or poll the OData API |
| Maintenance burden | Esri-managed | You manage a server (or pay a host) |
| Familiarity | You know it | New to learn |

Take-away: for a **network** rollout, ODK Central becomes materially more attractive than for an AFT-only tool. The decision is a genuine fork (D17), not a foregone Survey123. Both can be evaluated with the same XLSForm in Phase 1, since the form is authored as XLSForm either way.

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

### 5.5 Field conditions and scale requirements (new)
| Requirement | Detail |
|---|---|
| Devices | Tablets primarily, phones secondarily; one responsive layout; large touch targets (gloved, wet hands); sunlight-readable; works with a stylus or rubber-tipped touch |
| Offline | 100% of a survey completable with **no signal at all**: site list, choices, basemap/site location, and photo capture all local. Submissions queue and send when signal returns |
| Sync | Resumable uploads of photos; idempotent submissions (a re-sent submission never duplicates); visible "unsent / sent" status; no silent data loss |
| Draft safety | Autosave every entry; recoverable after crash or battery loss; a survey stays open across a field day |
| Reference data on device | Site list filtered to the user's org plus nearby sites; refreshed when online; version stamped |
| Form update rollout | Staged: pilot trust first; `form_version` on every event; older versions accepted by ingest for a defined grace period |
| Time and GPS | Device clock and GPS accuracy stored; warn on large clock drift (poor-signal devices drift); location accuracy captured |
| Training and support | Short field guide, in-form help text, training build of the form with dummy data, a support route for 50-100 users (who answers, how fast) |
| Load | Peak is end of survey day; ingest must handle bursts of tens of events and hundreds of photos; photo size capped or compressed on device |
| Data entry fallback | A paper or spreadsheet route per protocol for device failure, importable later (6.5) |

### 5.4 The form is a clean-sheet redesign (your direction)
`efish_neps_v8` is a working demo. It is treated as **reference material, not a constraint**: v9 is designed from the protocols outward, and the form is a first-class deliverable with its own spec, review and field testing, not an afterthought to the database.

**Principles**
1. **Form and data dictionary are co-designed first.** One data dictionary (field, type, allowed values, protocol applicability, required-when, unit, QC rule links) drives the XLSForm, the database schema, the pydantic models and the QC rules. Schema is derived from it, not the other way round.
2. **Protocol drives the form.** First screen: protocol, run mode (and `run_mode_reason` / `planned_runs` if cut short). Everything downstream uses `relevant` and `constraint` logic from that choice.
3. **Required-field validation is on in production.** Nothing stripped "for testing". A separate training/test build of the form exists for that.
4. **Raw observations only are authoritative.** Calculated helper fields (running totals, depletion previews, summary HTML) are allowed on screen for the operator but are never ingested.
5. **Fast in the field.** Fish entry optimised for gloved, wet, one-handed use: species/lifestage quick buttons, length stepper at the event's bin size (1 or 5 mm), bulk-count mode, subsample-remainder mode, undo of last fish.
6. **Versioned.** Form carries `form_version`; every event stores it; the data dictionary records which version introduced/removed each field. Changing a form after republish requires a checklist (see 6.2 relationship-ID verification).
7. **Offline-first, with robust sync.** Test on the actual devices, with poor signal, before any season.

**Form v9 deliverables**
- Data dictionary (one sheet per entity: event, run, fish, photo, width, plus protocol extensions).
- XLSForm(s) per decision D2, with a choices list for species, lifestage, protocols, sites, projects (generated from the DB so they cannot drift).
- Site list pipeline: DB `sites` -> CSV/feature layer used by the form (D8).
- A test matrix: 5 protocol/run combinations x (online, offline, resume draft, edit after submit) with expected ingested rows.
- Field UX review with the people who will use it, before build is frozen.
- Retirement plan for v8 (D16).

**Existing v8 data**: you describe v8 as a demo, so its submissions may be test data. Options are keep and tag, migrate, or discard (D16). Nothing is deleted without your explicit say-so.

**Reading the old form**: v8 lives at `C:\Users\graem\ArcGIS\My Survey Designs\...`, not visible from this cloud session. It is only needed as a reference for field names and ideas; if you want me to mine it, attach the `.xlsx`. No longer blocking.

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

### 6.2b Scale considerations
- Submissions can arrive days late (offline). `survey_date` is the survey; `received_at` and `submitted_at` are separate fields. Reports use `survey_date`.
- Poll frequency, API rate limits and run duration are sized for ~100 users in season; ingest is incremental and per-event transactional so one failure never blocks the batch.
- Dead-letter queue: events that fail ingest are stored with the error, visible to `network_admin`, and replayable.
- Duplicate guard: same `(source_id)` or same `(site, survey_date, protocol, submitted_by)` with a different id raises a QC warning, since offline devices can double-submit.

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

### 7.1 Scale and operations (new)
- **Authentication**: for the dashboard, Supabase Auth (email/SSO) with org membership; the current shared Shiny DB credentials do not scale to 50-100 people. Options: (a) Shiny behind Posit Connect auth with per-user DB session role, (b) replace Shiny with a stack that supports per-user auth natively, (c) keep Shiny for analysts only and give surveyors a lightweight "my surveys" view elsewhere. Decide in D19.
- **Hosting capacity**: Supabase plan tier (connections, storage for photos at network scale), Posit Connect Cloud limits on concurrent users; estimate photo volume (surveys x photos x size) before choosing tiers.
- **Backups and retention**: PITR on, restore tested; retention policy agreed with participating trusts.
- **Monitoring**: ingest health dashboard, alerting, an owner on call during season.
- **Cost model**: who pays for hosting, AGOL/ODK, storage, and who administers (D20).

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
| First-pass-only (single-equivalent) density from a multi event | no | no | yes | no | yes |
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
| Survey date outside the NEPS sampling window (default 1 Jul-30 Sep) | neps | info |
| Cut-short survey without `termination_reason` | single with planned_runs>=2 | error |
| Measured count below protocol minimum for a subsampled group | sfcc, neps | warn |
| Recorded length not on the event's bin grid (e.g. 5 mm event with length 47) | all with lengths | warn |
| Timed effort far from target duration | timed | warn |

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
| 0. Decisions + census | Resolve section 14; run the network method census (section 15); get protocol PDFs into the repo; governance and licensing answers (D17-D20) | Protocol list locked, platform chosen, sign-off recorded here |
| 1. Data dictionary + form design | Dictionary, XLSForm(s), test matrix, field UX review | You approve the dictionary and a clickable form on a real device |
| 2. Data model | Migrations derived from the dictionary; lookups, constraints, `edit_log`, `qc_config`, `event_estimates`; apply on a Supabase **branch** first | Migrations pass on branch; constraint tests pass |
| 3. Historical remap | Move `historical_*` into the unified model (if D5 = unify) | Row counts reconcile exactly with baseline; spot-check 20 events |
| 4. Ingest | Poller with `editDate`, dynamic relationship IDs, mismatch assertion | Each of the 5 combos ingests end to end; edit round-trips |
| 5. QC + estimates | Rule engine, estimator jobs | Golden-value tests pass; QC table reviewed by you |
| 6. Field pilot | One pilot trust, real surveys on tablets/phones in poor signal, side by side with the old process; then staged rollout trust by trust | Pilot week with zero data loss and offline sync verified; support route tested; feedback applied |
| 7. Dashboard | Filters, protocol-aware panels, map encodings | Walk-through per protocol |
| 8. Exports | NEPS (single + multi), KML, CSV (SFCC upload format deferred, see D14) | Round-trip into the NEPS tool succeeds |
| 9. Cutover | Switch form, retire unused services, docs, runbook | One full field week ingested without manual intervention |

Rollback: every phase's migration is additive until Phase 9; the baseline keeps running untouched until cutover.

---

## 14. Decision Register

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D0 | Where does v2 live? | New repo; new branch/folder in this repo; in-place evolution | New long-lived branch in this repo (keeps history and lessons), merge at cutover |
| D1 | Capture platform | Survey123 / Field Maps / ODK-Kobo / PWA | Survey123 |
| D2 | Forms | One / two / three | One protocol-aware form |
| D3 | Timed multi-run? | Timed single only / allow multi-timed | Timed single only (single-run termination is now handled by `run_mode_reason`, section 3.2b) |
| D4 | Data model | A wide / B per-protocol / C core + extensions | C |
| D5 | Legacy SFCC data | Keep separate / unify / unify + side table for SFCC estimates | Unify + side table |
| D6 | 1mm vs 5mm (**5 mm kept as a selectable option for now**, to be revisited after the method census, section 15), Presence/Absence legacy, SFCC age class 0-4 | (a) separate legacy protocols, (b) `legacy_other`, (c) one `sfcc_quant` protocol with `length_bin_mm`; keep age class or collapse to fry/parr | (c) for SFCC quantitative; Presence/Absence as read-only legacy; store age class and derive lifestage |
| D7 | Pooling default | Always separate / separate with toggle / always pooled | Separate with explicit toggle and caveat |
| D8 | Site master | CSV file / `sites` table with promotion workflow | Table is master; CSV becomes an export |
| D9 | Ingest | Webhook / polling / Extract Changes | Polling on `editDate` |
| D10 | FastAPI service | Keep / retire | Retire unless webhooks are revived |
| D11 | Analysis location | R at read time / SQL views / precomputed `event_estimates` | Precomputed |
| D12 | Single-run density (SFCC and NEPS) | Minimum only / assumed capture probability (configurable) / NEPS tool model | RESOLVED by you: all are wanted. Show each, labelled by derivation; assumptions stored per estimate |
| D13 | Required-field validation in form | On / off | On in production |
| D14 | SFCC/Rockpool export | None / CSV matching template / CSV + validation | CSV + validation (needs the template) |
| D17 | Capture platform at network scale | Survey123 (licensing, shared AGOL org) / ODK Central / Kobo | Evaluate both in Phase 1 with one XLSForm; default ODK Central if per-user AGOL licensing across trusts is impractical |
| D18 | Data sharing between organisations | Org-private / network read / fully shared | Org-private edit, network read of site-level aggregates, per-org opt-in for detail |
| D19 | Dashboard auth and platform | Shiny + Connect auth / different stack / analysts-only Shiny plus simpler surveyor view | Needs input; per-user auth is mandatory either way |
| D20 | Governance and cost | Who hosts, administers, pays, supports; agreements with trusts | SFCC/AFT to decide; blocks Phase 6 pilot scope |
| D16 | Existing v8 demo data | Discard / keep as `source_system='survey123_v8_demo'` / migrate into the new model | Your call (see section 15, Q4). Default: keep, tagged, excluded from reports unless included |
| D15 | Public repo hygiene | Keep public / make private | Make private if feasible, otherwise scrub client names and project ref |

---

## 15. Open items

### Answered so far
| Question | Your answer | Effect |
|---|---|---|
| What is "1mm"? | Bin size for recorded fork length | `length_bin_mm`, section 4.2 |
| Timed specifics | Target duration; no stop nets; lengths maybe taken | Section 3.1: `target_duration_s`, `stop_nets=false` default, "lengths taken?" switch |
| Single-run use | All cases possible; density wanted | Section 3.2b; D12 resolved |
| Existing form (v8) | Demo only, needs complete revision | Section 5.4 |
| 5 mm bins | Some trusts may still use them; keep as option for now | D6; revisit after method census |
| Rockpool upload template | Not available now | D14 deferred |
| Scale and conditions | SFCC network-wide, 50-100 users, tablets/phones, poor signal | Sections 4.7, 5.1b, 5.5, 6.2b, 7.1; D17-D20 |
| Protocol PDFs | Can't provide just now | Rules stay [UNVERIFIED]; Phase 0 gate before form freeze |

**About v8:** `efish_neps_v8` is the Survey123 form this repo currently ingests (main event + pass/fish/photo/width repeats). v2 replaces it with a clean-sheet form. Open question is only whether its existing demo submissions are worth keeping (D16).

### New: network method census (your suggestion)
Before freezing the form, poll SFCC trusts on current practice so the form fits real methods, not assumptions. Proposed short questionnaire (one per trust):
1. Which survey types are run (Timed, quantitative 1mm, 5mm, NEPS, semi-quantitative, presence/absence, other)?
2. Passes used (single, two, three, more) and when.
3. Length recording resolution (1 mm, 5 mm, other), fry subsampling thresholds.
4. Timed duration, stop nets, whether lengths are taken, whether area is recorded.
5. Devices, signal conditions, and current data-entry route (paper, spreadsheet, other app, Rockpool direct).
6. Who needs access to whose data; reporting obligations.
7. Number of staff who would use the form.
Output: a one-page summary that locks the protocol list (D6) and form scope. This becomes a Phase 0 deliverable; I can draft the questionnaire (as a form or document) once you want it.

### Still needed
1. **Protocol documents** (SFCC training and team-leader manuals, Protocols Inventory, NEPS Field Data Collection Protocol) in `docs/sources/` when you can. Not blocking planning, but required before form v9 is frozen.
2. **Timed**: the actual target duration value(s) you use.
3. **v8 data (D16)**: keep, migrate or discard?
4. **Governance (D18, D20)**: who is the "network owner" (SFCC? AFT as pilot?), who pays, and are trusts already agreed to share data?
5. **Licensing**: does anyone already hold an AGOL organisation that could host 50-100 cross-trust submitters, or is that a blocker (D17)?
6. Whether AFT is the pilot trust, and the season timing for a pilot.

---|---|---|
| What is "1mm"? | Bin size for recorded fork length | `length_bin_mm`, section 4.2; 5 mm is the legacy alternative (D6) |
| How are Timed surveys run? | "Check the SFCC docs" | Searched; see section 17. Core facts found, details still to confirm |
| Single-run use | All cases possible; density wanted | Section 3.2b; D12 resolved |
| Existing form | Demo only, needs complete revision and respect | Section 5.4 |
| Rockpool upload template | Not available now | D14 deferred; export designed as a later phase |

### Still needed
1. **SFCC and NEPS protocol documents in the repo.** I could not open `fms.scot`, `gov.scot` or `sfcc.co.uk` (blocked in this environment). Please drop into `docs/sources/`: the SFCC *Introduction to Electrofishing Training Manual (2021)* and *Team Leader Manual (2021)* (available from SFCC on request), the SFCC *Data Collection Protocols Inventory*, and the NEPS *Field Data Collection Protocol*. Then I can replace every [UNVERIFIED] with a quoted rule.
2. **Timed specifics for your practice**: target duration (5 vs 10 min), stop nets or not, whether lengths are taken, area recorded or not, one habitat or several per site.
3. **Existing v8 data**: is any of it real survey data worth keeping (D16)?
4. **5 mm for new surveys**: should the new form ever offer 5 mm bins, or only 1 mm (legacy 5 mm kept read-only)?
5. **Who uses the form and on what devices** (number of staff, phones/tablets, signal conditions). Drives offline and UX requirements.
6. Does v2 replace the current system for everyone at AFT, and are there survey seasons the cutover must avoid?

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
| Per-user licensing/admin cost across trusts blocks Survey123 | Evaluate ODK Central in Phase 1 (D17) |
| Poor-signal sync loses or duplicates data | Idempotent submissions, resumable photo upload, duplicate QC, pilot in worst-signal sites |
| Trusts disagree on methods or data sharing | Method census, governance decision (D18) before pilot |
| Shared DB credentials do not scale to 100 users | Per-user auth + RLS (D19) before any rollout |
| Scope creep from "include all options" | Options are recorded here; only the signed-off choices go into Phase 1 |

---

## 17. Change log and source confidence

### Revision 2 (2026-10-03)
- 1mm defined as fork-length bin size: added `length_bin_mm`, a length-grid QC rule, simplified legacy 5 mm handling (D6 option c).
- Single-run: added `run_mode_reason`, `termination_reason`, first-pass-only analysis view; D12 resolved (all density types shown, labelled).
- Subsampling model for large fry catches (`measured` flag, remainder as counted row).
- Form redesigned as a clean-sheet deliverable; phases reordered so dictionary + form design come before the schema; field pilot added; Rockpool export deferred.
- Open items rewritten (section 15).

### Revision 3 (2026-10-03)
- Network-wide scale (50-100 users, multiple trusts, tablets/phones, poor signal): added multi-organisation model, platform implications (ODK Central vs Survey123), field-conditions requirements, ingest scale notes, auth and operations section, decisions D17-D20.
- Timed: target duration, no stop nets by default, optional lengths.
- 5 mm kept as an option; network method census added as a Phase 0 deliverable.
- Protocol PDFs deferred; unverified rules remain flagged.

### Sources used for protocol facts (web search summaries only; the documents themselves could not be opened)
| Fact | Source | Confidence |
|---|---|---|
| Timed surveys standardise effort or are used where removal sampling is impractical; ~10 min total, equipment timer counts anode-live time | SFCC Data Collection Protocols Inventory (2022), via search summary: https://fms.scot/wp-content/uploads/2023/08/220309-SFCC-Data-Collection-Protocols-Inventory.pdf | Medium |
| Galloway timed surveys are 5 min, two-person team | https://www.gallowayfisheriestrust.org/timed-electrofishing-surveys-luce-urr.php | Medium (one trust's practice) |
| Timed catch is an index of abundance (CPUE) | https://www.sciencedirect.com/science/article/abs/pii/S0165783617302849 and trust pages | High (general method) |
| Semi-quantitative: ~100 m2, no stop nets, fished upstream | SFCC inventory, via search summary | Medium; semi-quantitative is not one of your three types, noted only for context |
| NEPS: single-pass national default, ~1/3 of sites three-pass, equal first-pass effort, all data area-delimited, sampling window 1 Jul-30 Sep | https://www.gov.scot/publications/national-electrofishing-programme-scotland-neps-2021/pages/3/ via search summary | Medium-high |
| Parr measured to nearest mm; if more than 50 fry per run, measure at least 50 | NEPS/SFCC Field Data Collection Protocol, via search summary: https://www.gov.scot/binaries/content/documents/govscot/publications/factsheet/2020/11/electrofishing-programme-for-scotland-standard-operating-procedures/documents/standard-operating-procedures/field-data-collection-protocol/field-data-collection-protocol/govscot:document/Field+Data+Collection+Protocol.pdf | Medium; verify exact rule and which protocol it belongs to |

Everything marked [UNVERIFIED] or [CONFIRM] in this document is unresolved until the source documents are in `docs/sources/`.
