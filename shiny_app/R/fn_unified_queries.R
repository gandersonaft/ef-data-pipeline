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
#' plain lon/lat like it already does for live sites.
historical_sites_for_map <- function(pool) {
  tbl_historical_sites(pool) |>
    dplyr::filter(!is.na(easting), !is.na(northing)) |>
    dplyr::mutate(
      lon = sql("ST_X(ST_Transform(geom_27700, 4326))"),
      lat = sql("ST_Y(ST_Transform(geom_27700, 4326))")
    ) |>
    dplyr::left_join(
      tbl_historical_events(pool) |>
        dplyr::group_by(historical_site_id) |>
        dplyr::summarise(last_survey_date = max(survey_date, na.rm = TRUE), event_count = dplyr::n(), .groups = "drop"),
      by = "historical_site_id"
    ) |>
    dplyr::select(historical_site_id, site_code, catchment, lon, lat, last_survey_date, event_count) |>
    dplyr::collect()
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
#' (different, sparser, no qc_status/crew-per-role) field set.
historical_event_full_detail <- function(pool, historical_event_id) {
  tbl_historical_events(pool) |>
    dplyr::filter(historical_event_id == !!historical_event_id) |>
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
