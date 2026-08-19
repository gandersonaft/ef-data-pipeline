# All read-only queries against the Supabase schema (see supabase/schema.sql).
# Uses dbplyr lazy tbl()s so filtering happens in Postgres, and only the
# already-filtered rows are pulled into R via collect().

tbl_events <- function(pool) dplyr::tbl(pool, "electrofishing_events")
tbl_runs <- function(pool) dplyr::tbl(pool, "electrofishing_runs")
# Soft-deleted fish (deleted_at is not null -- see supabase/schema.sql and
# fn_db_writes.R::delete_fish_record()) are excluded here, once, so every
# caller automatically gets this without needing to remember it individually.
tbl_fish <- function(pool) dplyr::tbl(pool, "fish_records") |> dplyr::filter(is.na(deleted_at))
tbl_sites <- function(pool) dplyr::tbl(pool, "sites")
tbl_site_photos <- function(pool) dplyr::tbl(pool, "site_photos")
tbl_projects <- function(pool) dplyr::tbl(pool, "survey_projects")

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

  # event_id is a Postgres bigint, so dplyr::pull() returns an integer64
  # (bit64 package) vector, not a base R integer/double. base R's intersect()
  # below is NOT integer64-aware -- it silently reinterprets the 64-bit
  # integer bit pattern as a double, corrupting every id into a near-zero
  # denormal float (confirmed 2026-08-18: real event_ids 1-12 became values
  # like 4.94e-324). Converting to plain integer immediately after pulling
  # sidesteps this entirely -- event_id will never realistically exceed
  # 32-bit range for this application.
  event_ids <- as.integer(q |> dplyr::pull(event_id))

  if (!is.null(species) && length(species) > 0 && length(event_ids) > 0) {
    fish_event_ids <- tbl_fish(pool) |>
      dplyr::inner_join(tbl_runs(pool), by = "run_id") |>
      dplyr::filter(event_id %in% !!event_ids, species %in% !!species) |>
      dplyr::distinct(event_id) |>
      dplyr::pull(event_id)
    fish_event_ids <- as.integer(fish_event_ids)
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

#' One row per site among the given event_ids, with WGS84 lon/lat (already
#' ready for leaflet -- no CRS conversion needed, see sites.lon/sites.lat in
#' supabase/schema.sql) and a small popup summary.
sites_for_events <- function(pool, event_ids) {
  if (length(event_ids) == 0) {
    return(tibble::tibble())
  }

  tbl_events(pool) |>
    dplyr::filter(event_id %in% !!event_ids, !is.na(site_id)) |>
    dplyr::group_by(site_id) |>
    dplyr::summarise(
      last_survey_date = max(survey_date, na.rm = TRUE),
      event_count = dplyr::n(),
      .groups = "drop"
    ) |>
    dplyr::inner_join(tbl_sites(pool), by = "site_id") |>
    dplyr::filter(!is.na(lon), !is.na(lat)) |>
    dplyr::select(site_id, site_code, site_label, catchment, lon, lat, last_survey_date, event_count) |>
    dplyr::collect()
}

#' NEPS tool results matched back to our species codes, for comparison
#' columns on the Depletion & Density tab. Matched on (site_code,
#' survey_date, species, lifestage) since neps_tool_results has no event_id
#' -- the external tool's own output doesn't carry one.
neps_results_for_events <- function(pool, events_df) {
  if (nrow(events_df) == 0) return(tibble::tibble())
  species_reverse_map <- c(salmon = "sal", trout = "trt")

  dplyr::tbl(pool, "neps_tool_results") |>
    dplyr::collect() |>
    dplyr::mutate(species = unname(species_reverse_map[species])) |>
    dplyr::inner_join(
      events_df |> dplyr::select(event_id, site_code, survey_date),
      by = c("site_name" = "site_code", "survey_date" = "survey_date")
    ) |>
    dplyr::select(event_id, species, lifestage, observed_density, benchmark, benchmark_warnings)
}

distinct_projects <- function(pool) {
  tbl_projects(pool) |>
    dplyr::select(project_id, project_code, project_name) |>
    dplyr::arrange(project_code) |>
    dplyr::collect()
}

flagged_events <- function(pool) {
  tbl_events(pool) |>
    dplyr::filter(qc_status == "flagged") |>
    dplyr::select(event_id, site_code, catchment, survey_date, qc_flags, final_comments) |>
    dplyr::arrange(dplyr::desc(survey_date)) |>
    dplyr::collect()
}

#' Broad event browser for the Survey Detail and Project Tagging tabs --
#' same event_ids as filtered_events(), but WITHOUT the species-driven
#' exclusion (an event must be pickable even if none of its fish match the
#' current species checkbox filter) and regardless of qc_status (unlike
#' flagged_events(), which only lists flagged events -- this is what makes a
#' normal/`ok` event's site details and photos reachable at all).
events_browser <- function(pool, event_ids) {
  if (length(event_ids) == 0) {
    return(tibble::tibble())
  }
  df <- tbl_events(pool) |>
    dplyr::filter(event_id %in% !!event_ids) |>
    dplyr::left_join(tbl_projects(pool) |> dplyr::select(project_id, project_code), by = "project_id") |>
    dplyr::select(event_id, site_code, catchment, survey_date, project_id, project_code, qc_status) |>
    dplyr::arrange(dplyr::desc(survey_date)) |>
    dplyr::collect()

  # event_id/project_id are Postgres bigint -> collect() returns them as
  # bit64::integer64. Plain R operations that don't dispatch to bit64's own
  # S3 methods (base for-loops, intersect(), etc.) silently reinterpret the
  # 64-bit bit pattern as a double, corrupting the value (confirmed
  # 2026-08-19: iterating event_ids in a for loop produced
  # "1.2351641146031164e-322" instead of a real id). Converting to plain
  # integer here, once, matches filtered_event_ids()'s established fix for
  # the exact same issue -- neither id will realistically exceed 32-bit
  # range for this application.
  df$event_id <- as.integer(df$event_id)
  df$project_id <- as.integer(df$project_id)
  df
}

#' All fish for one event, across every pass -- deliberately ignores the
#' species sidebar filter (editing must show everything at that event, same
#' reasoning as the QC tab's photo gallery). Excludes soft-deleted rows via
#' the shared tbl_fish() filter.
fish_for_event_detail <- function(pool, event_id) {
  tbl_fish(pool) |>
    dplyr::inner_join(tbl_runs(pool), by = "run_id", suffix = c("", "_run")) |>
    dplyr::filter(event_id == !!event_id) |>
    dplyr::select(fish_id, run_id, pass_no, species, lifestage, length_mm, wet_weight_g,
                  condition_factor, scaled, tissue_tube, count_bulk, fish_multiplier, updated_at) |>
    dplyr::arrange(pass_no, fish_id) |>
    dplyr::collect()
}

#' Every captured field for one event (water/crew/equipment/dimensions/
#' substrate/flow/comments), for read-only display on the Survey Detail tab
#' -- none of this is shown anywhere else in the app today.
event_full_detail <- function(pool, event_id) {
  tbl_events(pool) |>
    dplyr::filter(event_id == !!event_id) |>
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

  # storage_path segments (site_code in particular, e.g. "3 fishfarm") can
  # contain spaces and other characters that aren't valid raw in a URL.
  # req_url_path_append() does NOT auto-encode a single argument containing
  # embedded "/" separators -- confirmed 2026-08-18: passing the whole path
  # as one argument produced a literal space in the built URL, which curl
  # then rejected outright ("Malformed input to a URL function"). Encode
  # each "/"-separated segment individually so slashes stay as directory
  # separators while everything else (spaces included) gets escaped.
  path_segments <- strsplit(storage_path, "/", fixed = TRUE)[[1]]
  encoded_segments <- vapply(path_segments, utils::URLencode, character(1), reserved = TRUE)

  req <- httr2::request(supabase_url) |>
    httr2::req_url_path_append("storage/v1/object/sign", bucket)
  req <- do.call(httr2::req_url_path_append, c(list(req), as.list(encoded_segments)))
  # req_error(is_error = \(resp) FALSE) stops req_perform() throwing on a
  # non-2xx status, so we can read and log the actual response body below --
  # httr2's default error condition only exposes a generic "HTTP 400 Bad
  # Request" summary, not Supabase's own error message, which is what
  # actually explains a failure.
  req <- req |> httr2::req_error(is_error = function(resp) FALSE)

  resp <- tryCatch(
    req |>
      httr2::req_headers(Authorization = paste("Bearer", service_key), apikey = service_key) |>
      httr2::req_body_json(list(expiresIn = 3600L)) |>
      httr2::req_perform(),
    error = function(e) {
      warning("sign_photo_url request for '", storage_path, "' errored: ", conditionMessage(e))
      NULL
    }
  )
  if (is.null(resp)) {
    return(NA_character_)
  }

  if (httr2::resp_status(resp) >= 300) {
    warning(
      "sign_photo_url failed for '", storage_path, "': HTTP ", httr2::resp_status(resp),
      " -- url=", req$url, " body=", httr2::resp_body_string(resp)
    )
    return(NA_character_)
  }

  signed_path <- httr2::resp_body_json(resp)$signedURL
  if (is.null(signed_path)) {
    return(NA_character_)
  }
  paste0(supabase_url, "/storage/v1", signed_path)
}
