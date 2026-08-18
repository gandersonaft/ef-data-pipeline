# All read-only queries against the Supabase schema (see supabase/schema.sql).
# Uses dbplyr lazy tbl()s so filtering happens in Postgres, and only the
# already-filtered rows are pulled into R via collect().

tbl_events <- function(pool) dplyr::tbl(pool, "electrofishing_events")
tbl_runs <- function(pool) dplyr::tbl(pool, "electrofishing_runs")
tbl_fish <- function(pool) dplyr::tbl(pool, "fish_records")
tbl_sites <- function(pool) dplyr::tbl(pool, "sites")
tbl_site_photos <- function(pool) dplyr::tbl(pool, "site_photos")

distinct_catchments <- function(pool) {
  tbl_events(pool) |>
    dplyr::filter(!is.na(catchment)) |>
    dplyr::distinct(catchment) |>
    dplyr::arrange(catchment) |>
    dplyr::pull(catchment)
}

distinct_sites <- function(pool, catchment = NULL) {
  q <- tbl_events(pool)
  if (!is.null(catchment) && length(catchment) > 0) {
    q <- q |> dplyr::filter(catchment %in% !!catchment)
  }
  q |>
    dplyr::filter(!is.na(site_code)) |>
    dplyr::distinct(site_code) |>
    dplyr::arrange(site_code) |>
    dplyr::pull(site_code)
}

#' Filtered event_ids driving every tab's `filtered_events()` reactive.
filtered_event_ids <- function(pool, catchment = NULL, site_code = NULL,
                                date_range = NULL, species = NULL) {
  q <- tbl_events(pool)

  if (!is.null(catchment) && length(catchment) > 0) {
    q <- q |> dplyr::filter(catchment %in% !!catchment)
  }
  if (!is.null(site_code) && length(site_code) > 0) {
    q <- q |> dplyr::filter(site_code %in% !!site_code)
  }
  if (!is.null(date_range) && length(date_range) == 2) {
    q <- q |> dplyr::filter(survey_date >= !!date_range[1], survey_date <= !!date_range[2])
  }

  event_ids <- q |> dplyr::pull(event_id)

  if (!is.null(species) && length(species) > 0 && length(event_ids) > 0) {
    fish_event_ids <- tbl_fish(pool) |>
      dplyr::inner_join(tbl_runs(pool), by = "run_id") |>
      dplyr::filter(event_id %in% !!event_ids, species %in% !!species) |>
      dplyr::distinct(event_id) |>
      dplyr::pull(event_id)
    event_ids <- intersect(event_ids, fish_event_ids)
  }

  event_ids
}

#' Fish records joined up to run (pass_no) and event (site/date/area/cutoffs),
#' for the given event_ids. This is the authoritative source for Tabs 1 and 2 --
#' never derive counts from electrofishing_events.form_reported_summary or
#' electrofishing_runs.form_pass_* (those are the form's own self-reported
#' totals, kept only for QC cross-checking).
fish_for_events <- function(pool, event_ids) {
  if (length(event_ids) == 0) {
    return(tibble::tibble())
  }

  tbl_fish(pool) |>
    dplyr::inner_join(tbl_runs(pool), by = "run_id", suffix = c("", "_run")) |>
    dplyr::inner_join(tbl_events(pool), by = "event_id", suffix = c("", "_event")) |>
    dplyr::filter(event_id %in% !!event_ids) |>
    dplyr::select(
      fish_id, run_id, event_id, pass_no, species, lifestage, length_mm,
      wet_weight_g, condition_factor, fish_multiplier,
      site_code, survey_date, catchment, area_m2,
      sal_fry_parr_cutoff_mm, trt_fry_parr_cutoff_mm
    ) |>
    dplyr::collect()
}

#' Every pass actually conducted for the given events -- (event_id, run_id,
#' pass_no). Used to build a per-event zero-catch-filled pass grid in
#' fn_depletion.R::build_depletion_table(), rather than inferring the set of
#' passes from fish_records alone (which would silently omit a pass where a
#' given species/lifestage caught nothing).
runs_for_events <- function(pool, event_ids) {
  if (length(event_ids) == 0) {
    return(tibble::tibble())
  }

  tbl_runs(pool) |>
    dplyr::filter(event_id %in% !!event_ids) |>
    dplyr::select(event_id, run_id, pass_no) |>
    dplyr::collect()
}

flagged_events <- function(pool) {
  tbl_events(pool) |>
    dplyr::filter(qc_status == "flagged") |>
    dplyr::select(event_id, site_code, catchment, survey_date, qc_flags, final_comments) |>
    dplyr::arrange(dplyr::desc(survey_date)) |>
    dplyr::collect()
}

site_photos_for_event <- function(pool, event_id) {
  tbl_site_photos(pool) |>
    dplyr::filter(event_id == !!event_id) |>
    dplyr::select(photo_id, storage_path, caption, content_type) |>
    dplyr::collect()
}

#' Sign a Storage object path for display. The bucket is private (per design
#' decision), so a fresh signed URL is generated at query time rather than
#' relying on a possibly-expired cached photo_url from the DB.
sign_photo_url <- function(storage_path) {
  supabase_url <- Sys.getenv("SUPABASE_URL")
  service_key <- Sys.getenv("SUPABASE_SERVICE_KEY")
  bucket <- Sys.getenv("STORAGE_BUCKET", "ef-photos")

  if (identical(supabase_url, "") || identical(service_key, "")) {
    return(NA_character_)
  }

  resp <- tryCatch(
    httr2::request(supabase_url) |>
      httr2::req_url_path_append("storage/v1/object/sign", bucket, storage_path) |>
      httr2::req_headers(Authorization = paste("Bearer", service_key), apikey = service_key) |>
      httr2::req_body_json(list(expiresIn = 3600L)) |>
      httr2::req_perform(),
    error = function(e) NULL
  )
  if (is.null(resp)) {
    return(NA_character_)
  }

  signed_path <- httr2::resp_body_json(resp)$signedURL
  if (is.null(signed_path)) {
    return(NA_character_)
  }
  paste0(supabase_url, "/storage/v1", signed_path)
}
