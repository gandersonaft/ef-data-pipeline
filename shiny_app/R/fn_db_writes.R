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
