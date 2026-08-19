# Unified live + historical read access. Historical data (see
# supabase/migrations/0002_historical_sfcc_data.sql, scripts/migrate_sfcc_historical.py)
# stays in its own tables -- different provenance (no Esri global_id, not
# editable, not part of the live Survey123 pipeline), but the Projects/
# Survey Detail/Site Map UI browses both together, source-tagged, per
# HANDOFF.md's instruction to land historical data inside the same 3-tab IA
# rather than adding a 4th "Historical" tab.
#
# Scope decision (2026-08-19): Projects' aggregate Carle-Strub/density
# reporting stays LIVE-only for now -- pooling historical and live catches
# into one depletion estimate has real statistical implications (different
# eras/methodologies) that deserve a deliberate decision, not a default.
# Historical data is fully browsable via Site Map (see it) and Survey Detail
# (drill into one historical event's real fish data + SFCC's own
# already-computed density estimate from historical_density_estimates --
# never recomputed/pooled with live data).

tbl_historical_sites        <- function(pool) dplyr::tbl(pool, "historical_sites")
tbl_historical_events       <- function(pool) dplyr::tbl(pool, "historical_events")
tbl_historical_run_counts   <- function(pool) dplyr::tbl(pool, "historical_run_counts")
tbl_historical_fish         <- function(pool) dplyr::tbl(pool, "historical_fish")
tbl_historical_density      <- function(pool) dplyr::tbl(pool, "historical_density_estimates")

#' Every historical site with coordinates, for Site Map. Historical sites
#' only have BNG easting/northing (no WGS84 lon/lat column, unlike the live
#' `sites` table) -- transform via PostGIS server-side so the map layer gets
#' plain lon/lat like it already does for live sites. method_label is the
#' MOST RECENT event's `method` at that site (Quantitative (1mm)/(5mm)/
#' Timed/Presence-Absence, always populated on historical data) -- Site Map
#' colours markers by this instead of a flat live/historical split; small
#' enough data volume (1961 events) to pick "most recent per site" in R
#' after collect() rather than a window-function rewrite.
historical_sites_for_map <- function(pool) {
  events_summary <- tbl_historical_events(pool) |>
    dplyr::select(historical_site_id, survey_date, method) |>
    dplyr::collect() |>
    dplyr::filter(!is.na(historical_site_id)) |>
    dplyr::group_by(historical_site_id) |>
    dplyr::arrange(dplyr::desc(survey_date)) |>
    dplyr::summarise(
      last_survey_date = dplyr::first(survey_date), event_count = dplyr::n(),
      method_label = dplyr::first(method), .groups = "drop"
    )

  tbl_historical_sites(pool) |>
    dplyr::filter(!is.na(easting), !is.na(northing)) |>
    dplyr::mutate(
      lon = sql("ST_X(ST_Transform(geom_27700, 4326))"),
      lat = sql("ST_Y(ST_Transform(geom_27700, 4326))")
    ) |>
    dplyr::select(historical_site_id, site_code, catchment, lon, lat) |>
    dplyr::collect() |>
    dplyr::left_join(events_summary, by = "historical_site_id")
}

#' Broad historical event browser, mirroring events_browser()'s shape
#' closely enough that the two can be row-bound in the Survey Detail picker.
#' event_key ("hist-<id>") avoids collisions with live "live-<id>" keys when
#' both appear in the same DT selection table.
historical_events_browser <- function(pool, date_range = NULL) {
  q <- tbl_historical_events(pool)
  if (!is.null(date_range) && length(date_range) == 2) {
    q <- q |> dplyr::filter(survey_date >= !!date_range[1], survey_date <= !!date_range[2])
  }
  # catchment lives on historical_sites, not historical_events -- see
  # supabase/migrations/0002_historical_sfcc_data.sql. Same join
  # historical_sites_for_map() already does for the same reason.
  q |>
    dplyr::left_join(
      tbl_historical_sites(pool) |> dplyr::select(historical_site_id, catchment),
      by = "historical_site_id"
    ) |>
    dplyr::select(historical_event_id, site_code, catchment, survey_date,
                  has_individual_fish_data, event_status) |>
    dplyr::arrange(dplyr::desc(survey_date)) |>
    dplyr::collect() |>
    dplyr::mutate(
      event_key = paste0("hist-", historical_event_id),
      source = "historical"
    )
}

#' Every captured field for one historical event, for read-only display on
#' Survey Detail -- analogous to event_full_detail() but historical's own
#' (different, sparser, no qc_status/crew-per-role) field set. lon/lat for
#' the per-record mini-map, same ST_Transform pattern as historical_sites_for_map().
historical_event_full_detail <- function(pool, historical_event_id) {
  tbl_historical_events(pool) |>
    dplyr::filter(historical_event_id == !!historical_event_id) |>
    dplyr::mutate(
      lon = sql("ST_X(ST_Transform(geom_27700, 4326))"),
      lat = sql("ST_Y(ST_Transform(geom_27700, 4326))")
    ) |>
    dplyr::collect()
}

#' All individual fish for one historical event -- read-only, no edit
#' capability exists or is planned for historical data (it's an archive, not
#' a live submission you can correct).
historical_fish_for_event <- function(pool, historical_event_id) {
  tbl_historical_fish(pool) |>
    dplyr::filter(historical_event_id == !!historical_event_id) |>
    dplyr::select(historical_fish_id, run_no, species, length_mm, age_class, lifestage) |>
    dplyr::arrange(run_no, historical_fish_id) |>
    dplyr::collect()
}

#' SFCC's own Zippin/Carle-Strub density estimate for one historical event --
#' displayed as-is, never recomputed or pooled with live Carle-Strub output.
historical_density_for_event <- function(pool, historical_event_id) {
  tbl_historical_density(pool) |>
    dplyr::filter(historical_event_id == !!historical_event_id) |>
    dplyr::collect()
}

#' Fallback aggregate counts (species x age_class x run) for the ~300
#' historical events with no individual fish data -- same role as
#' electrofishing_runs.form_pass_*: informational, not a depletion input.
historical_run_counts_for_event <- function(pool, historical_event_id) {
  tbl_historical_run_counts(pool) |>
    dplyr::filter(historical_event_id == !!historical_event_id) |>
    dplyr::collect()
}

#' Whole clipped river network (see supabase/migrations/0003_river_network.sql,
#' scripts/load_river_network.R) as one GeoJSON FeatureCollection string,
#' built server-side in PostGIS -- avoids adding an `sf` dependency to the
#' Shiny app just for this one map layer, since leaflet::addGeoJSON() already
#' takes a raw GeoJSON string directly. Unfiltered (not sidebar-scoped) --
#' it's a fixed backdrop on Site Map, same reasoning as historical_sites_for_map().
#' Survey Detail's primary picker: one row per SITE, not one row per event --
#' live and historical records grouped together by normalized (lower/trim)
#' site_code, the same join confirmed at 99.7% coverage (1225/1229 historical
#' sites) against real data during planning; no grid-ref/spatial fallback
#' needed given that coverage. Live side respects the sidebar filters (via
#' events_browser()), historical side doesn't -- same scope decision already
#' in place for every other historical browsing view in this app.
sites_with_records <- function(pool, filtered_event_ids) {
  live <- events_browser(pool, filtered_event_ids)
  hist <- historical_events_browser(pool)

  live_sites <- if (nrow(live) > 0) {
    live |>
      dplyr::filter(!is.na(site_code), trimws(site_code) != "") |>
      dplyr::mutate(site_key = tolower(trimws(site_code))) |>
      dplyr::group_by(site_key) |>
      dplyr::summarise(
        site_code = dplyr::first(site_code), catchment = dplyr::first(catchment),
        live_count = dplyr::n(), live_last = max(survey_date, na.rm = TRUE), .groups = "drop"
      )
  } else {
    tibble::tibble(site_key = character(), site_code = character(), catchment = character(),
                    live_count = integer(), live_last = as.Date(character()))
  }

  hist_sites <- if (nrow(hist) > 0) {
    hist |>
      dplyr::filter(!is.na(site_code), trimws(site_code) != "") |>
      dplyr::mutate(site_key = tolower(trimws(site_code))) |>
      dplyr::group_by(site_key) |>
      dplyr::summarise(
        site_code_hist = dplyr::first(site_code), catchment_hist = dplyr::first(catchment),
        hist_count = dplyr::n(), hist_last = max(survey_date, na.rm = TRUE), .groups = "drop"
      )
  } else {
    tibble::tibble(site_key = character(), site_code_hist = character(), catchment_hist = character(),
                    hist_count = integer(), hist_last = as.Date(character()))
  }

  dplyr::full_join(live_sites, hist_sites, by = "site_key") |>
    dplyr::mutate(
      site_code = dplyr::coalesce(site_code, site_code_hist),
      catchment = dplyr::coalesce(catchment, catchment_hist),
      live_count = dplyr::coalesce(live_count, 0L),
      hist_count = dplyr::coalesce(hist_count, 0L),
      last_survey_date = pmax(live_last, hist_last, na.rm = TRUE)
    ) |>
    dplyr::select(site_key, site_code, catchment, live_count, hist_count, last_survey_date) |>
    dplyr::arrange(dplyr::desc(last_survey_date))
}

#' Survey Detail's secondary picker: every live + historical record at one
#' site, newest first -- shaped like the combined events table the picker
#' used before this rebuild (event_key/source/native_id/...), so the
#' per-record rendering in mod_survey_detail.R barely needed to change, it
#' just now reads "the selected record" instead of "the selected event".
#' Deliberately NOT sidebar-filtered (once a site is drilled into, every
#' year at it should be browsable, same reasoning as historical browsing
#' elsewhere ignoring the sidebar). Raw parameterized SQL rather than
#' dbplyr, since a single exact-match lookup by one key is simpler to get
#' right this way than relying on dbplyr's tolower()/trimws() SQL
#' translation.
#'
#' @param site_key normalized (lower/trim) site_code from sites_with_records().
records_for_site <- function(pool, site_key) {
  live <- DBI::dbGetQuery(pool, "
    select e.event_id, e.site_code, e.catchment, e.survey_date,
           p.project_code, e.qc_status
    from electrofishing_events e
    left join survey_projects p on p.project_id = e.project_id
    where lower(trim(e.site_code)) = $1
    order by e.survey_date desc
  ", params = list(site_key))
  live_df <- if (nrow(live) > 0) {
    live |>
      dplyr::transmute(
        event_key = paste0("live-", event_id), source = "live", native_id = as.integer(event_id),
        site_code, catchment = humanize_slug(catchment), survey_date = as.Date(survey_date),
        project_code = dplyr::coalesce(project_code, "—"), status_label = qc_status
      )
  } else {
    tibble::tibble()
  }

  hist <- DBI::dbGetQuery(pool, "
    select he.historical_event_id, he.site_code, hs.catchment, he.survey_date, he.has_individual_fish_data
    from historical_events he
    left join historical_sites hs on hs.historical_site_id = he.historical_site_id
    where lower(trim(he.site_code)) = $1
    order by he.survey_date desc
  ", params = list(site_key))
  hist_df <- if (nrow(hist) > 0) {
    hist |>
      dplyr::transmute(
        event_key = paste0("hist-", historical_event_id), source = "historical",
        native_id = as.integer(historical_event_id), site_code,
        catchment = dplyr::coalesce(catchment, "—"), survey_date = as.Date(survey_date),
        project_code = "—",
        status_label = dplyr::if_else(has_individual_fish_data, "Archive (fish data)", "Archive (summary only)")
      )
  } else {
    tibble::tibble()
  }

  dplyr::bind_rows(live_df, hist_df) |> dplyr::arrange(dplyr::desc(survey_date))
}

#' River network segments within `radius_m` of one point, for Survey
#' Detail's per-record mini-map -- deliberately NOT river_network_geojson()
#' reused as-is, since sending the whole ~4MB clipped network for a map
#' zoomed to one site would be wasteful when only nearby segments are ever
#' visible at that zoom level.
river_network_geojson_near <- function(pool, lon, lat, radius_m = 1000) {
  DBI::dbGetQuery(pool, "
    select jsonb_build_object(
      'type', 'FeatureCollection',
      'features', coalesce(jsonb_agg(jsonb_build_object(
        'type', 'Feature',
        'geometry', ST_AsGeoJSON(ST_Transform(geom_27700, 4326))::jsonb,
        'properties', jsonb_build_object('name', coalesce(name1, name2))
      )), '[]'::jsonb)
    )::text as geojson
    from river_network
    where ST_DWithin(
      geom_27700,
      ST_Transform(ST_SetSRID(ST_MakePoint($1, $2), 4326), 27700),
      $3
    )
  ", params = list(lon, lat, radius_m))$geojson
}

river_network_geojson <- function(pool) {
  DBI::dbGetQuery(pool, "
    select jsonb_build_object(
      'type', 'FeatureCollection',
      'features', coalesce(jsonb_agg(jsonb_build_object(
        'type', 'Feature',
        'geometry', ST_AsGeoJSON(ST_Transform(geom_27700, 4326))::jsonb,
        'properties', jsonb_build_object('name', coalesce(name1, name2))
      )), '[]'::jsonb)
    )::text as geojson
    from river_network
  ")$geojson
}
