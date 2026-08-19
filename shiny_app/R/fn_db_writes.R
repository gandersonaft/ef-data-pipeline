# All DB WRITES go through this file, using db_pool_editor (role
# shiny_editor -- see supabase/roles.sql and global.R). Every function here
# is timestamp-only-audit for now (updated_at, no reviewer identity) -- this
# is a tech-demo phase; full user identity + an audit-log table are
# explicitly deferred to a later phase. Functions are written parameterized
# and isolated on purpose so adding an actor_id column later doesn't require
# restructuring how they're called.

update_fish_record <- function(pool_editor, fish_id, species, lifestage, length_mm,
                                wet_weight_g, scaled, tissue_tube, count_bulk, fish_multiplier) {
  DBI::dbExecute(
    pool_editor,
    "update fish_records set species = $1, lifestage = $2, length_mm = $3,
       wet_weight_g = $4, scaled = $5, tissue_tube = $6, count_bulk = $7, fish_multiplier = $8
     where fish_id = $9",
    params = list(species, lifestage, length_mm, wet_weight_g, scaled, tissue_tube,
                   count_bulk, fish_multiplier, fish_id)
  )
  # trg_fish_condition_factor and trg_fish_records_touch_updated_at
  # (supabase/schema.sql) recompute condition_factor and updated_at
  # automatically -- do not set either here.
}

#' Manually-added fish have no Esri GlobalID -- synthesize a distinguishable
#' one (prefixed "shiny-manual-") so it's obviously not from Survey123 if
#' ever cross-referenced against raw_payload/webhook_log.
insert_fish_record <- function(pool_editor, run_id, species, lifestage, length_mm,
                                wet_weight_g, scaled, tissue_tube, count_bulk, fish_multiplier) {
  run_global_id <- DBI::dbGetQuery(
    pool_editor, "select global_id from electrofishing_runs where run_id = $1", params = list(run_id)
  )$global_id
  new_global_id <- sprintf("shiny-manual-%s-%06d", format(Sys.time(), "%Y%m%dT%H%M%OS3"), sample.int(1e6, 1))

  DBI::dbExecute(
    pool_editor,
    "insert into fish_records (global_id, parent_global_id, run_id, entry_mode, species, lifestage,
       length_mm, wet_weight_g, scaled, tissue_tube, count_bulk, fish_multiplier)
     values ($1, $2, $3, 'individual', $4, $5, $6, $7, $8, $9, $10, $11)",
    params = list(new_global_id, run_global_id, run_id, species, lifestage, length_mm,
                   wet_weight_g, scaled, tissue_tube, count_bulk, fish_multiplier)
  )
}

#' Soft delete only -- shiny_editor has no DELETE grant on fish_records at
#' all (see supabase/roles.sql). Nothing is ever unrecoverable; a restore UI
#' isn't built in this round, but the data survives a mis-click and can be
#' un-hidden later with one SQL statement if ever needed.
delete_fish_record <- function(pool_editor, fish_id) {
  DBI::dbExecute(
    pool_editor,
    "update fish_records set deleted_at = now() where fish_id = $1",
    params = list(fish_id)
  )
}

#' One UPDATE per event_id, not a single `= any($2)` call -- RPostgres's
#' dbBind() treats every element of `params` as a same-length batch-execution
#' vector, not "this one param is itself an array", so passing a multi-
#' element event_ids vector alongside a length-1 project_id fails with
#' "Parameter 2 does not have length 1" (confirmed 2026-08-19). A loop is
#' simple and avoids relying on RPostgres's array-literal binding at all.
assign_project_to_events <- function(pool_editor, event_ids, project_id) {
  for (event_id in event_ids) {
    DBI::dbExecute(
      pool_editor,
      "update electrofishing_events set project_id = $1 where event_id = $2",
      params = list(project_id, event_id)
    )
  }
}

#' Import a row of the Marine Directorate NEPS tool's results export (its
#' exact column names, confirmed via the tool's own "Data Dictionary for
#' results export" section) into neps_tool_results. Upserted on
#' (site_name, survey_date, species, lifestage) since the external tool's
#' output carries no event_id/global_id of ours to join on.
import_neps_results <- function(pool_editor, df) {
  for (i in seq_len(nrow(df))) {
    r <- df[i, ]
    site_id <- DBI::dbGetQuery(
      pool_editor, "select site_id from sites where site_code = $1", params = list(trimws(r$Site_Name))
    )$site_id
    site_id <- if (length(site_id) == 1) site_id else NA_integer_

    cols <- c(
      "site_name", "site_id", "easting", "northing", "ha_name", "ctm_name", "ctm_code", "river_order",
      "survey_date", "species", "lifestage", "area", "mean_length", "mean_width",
      "density_predictions_successful", "total_number_passes_warning", "missing_pass_warning",
      "nearest_river_distance", "distance_warning", "confluence_warning", "organisation",
      "organisation_team", "organisation_warnings", "predictor_warnings", "predictor_warnings_detailed",
      "fished_area_warnings", "total_number_passes", "counts", "probs", "observed_density", "benchmark",
      "density_difference", "density_per_difference", "benchmark_warnings"
    )
    vals <- list(r$Site_Name, site_id, r$Easting, r$Northing, r$HAName, r$CTMName, r$CTMCode,
                 r$River_Order, r$date, r$species, r$lifestage, r$area, r$mean_length, r$mean_width,
                 r$Density_Predictions_Successful, r$Total_Number_Passes_Warning, r$Missing_Pass_Warning,
                 r$Nearest_River_Distance, r$Distance_Warning, r$Confluence_Warning, r$Organisation,
                 r$Organisation_Team, r$Organisation_Warnings, r$Predictor_Warnings,
                 r$Predictor_Warnings_Detailed, r$Fished_Area_Warnings, r$total_number_passes,
                 as.character(r$counts), as.character(r$probs), r$Observed_Density, r$Benchmark,
                 r$density_difference, r$density_per_difference, r$Benchmark_Warnings)
    # Column list and placeholder count generated from the SAME `cols`
    # vector, not hand-counted separately -- a 34-column hand-count mismatch
    # ($1..$33 for 34 columns) caused "INSERT has more target columns than
    # expressions" (confirmed 2026-08-19). Building both from one source
    # makes that class of bug impossible to reintroduce.
    stopifnot(length(cols) == length(vals))
    placeholders <- paste0("$", seq_along(vals), collapse = ", ")

    DBI::dbExecute(
      pool_editor,
      paste0(
        "insert into neps_tool_results (", paste(cols, collapse = ", "), ")
         values (", placeholders, ")
         on conflict (site_name, survey_date, species, lifestage) do update set
           easting = excluded.easting, northing = excluded.northing, area = excluded.area,
           observed_density = excluded.observed_density, benchmark = excluded.benchmark,
           density_difference = excluded.density_difference, density_per_difference = excluded.density_per_difference,
           imported_at = now()"
      ),
      params = vals
    )
  }
}

upsert_project <- function(pool_editor, project_code, project_name, client_name, start_date, end_date, notes) {
  DBI::dbGetQuery(
    pool_editor,
    "insert into survey_projects (project_code, project_name, client_name, start_date, end_date, notes)
     values ($1, $2, $3, $4, $5, $6)
     on conflict (project_code) do update set
       project_name = excluded.project_name, client_name = excluded.client_name,
       start_date = excluded.start_date, end_date = excluded.end_date, notes = excluded.notes,
       updated_at = now()
     returning project_id",
    params = list(project_code, project_name, client_name, start_date, end_date, notes)
  )$project_id
}
