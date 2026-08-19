# Builds the exact Data_Template row shape for the Marine Directorate NEPS
# Electrofishing Data Analysis Tool: Site_Name, Easting, Northing, date,
# total_number_passes, species, lifestage, pass, count, area, mean_length,
# mean_width. Confirmed directly against the tool's own "Data Dictionary"
# tab (https://scotland.shinyapps.io/sg-neps-electrofishing-analysis-tool/)
# and the attached Electrofishing_Data_Analysis_Tool_Template.xlsx.
#
# Adapts fn_depletion.R's pass_grid pattern but crosses against a FIXED
# (sal,trt) x (fry,parr) combo set, not what was actually caught -- the
# tool's own rules require a zero-catch row for every species/lifestage
# combo at a site, even ones never observed there, not just the ones
# fn_depletion.R's build_depletion_table() would produce.

neps_species_map <- c(sal = "salmon", trt = "trout")

#' @param fish_df   output of fn_db_queries.R::fish_for_events()
#' @param runs_df   output of fn_db_queries.R::runs_for_events()
#' @param events_df full event rows (must include site_id, site_code,
#'   survey_date, easting, northing, area_m2) for the same event_ids
#' @param sites_df  site_id, easting, northing from the sites master table
build_neps_export_table <- function(fish_df, runs_df, events_df, sites_df) {
  if (nrow(events_df) == 0 || nrow(runs_df) == 0) {
    return(tibble::tibble())
  }

  fish_df <- fish_df |> dplyr::filter(species %in% names(neps_species_map))

  fixed_combos <- tidyr::expand_grid(species = names(neps_species_map), lifestage = c("fry", "parr"))

  pass_grid <- runs_df |>
    dplyr::distinct(event_id, pass_no) |>
    dplyr::inner_join(events_df |> dplyr::distinct(event_id), by = "event_id") |>
    dplyr::cross_join(fixed_combos)

  catch_by_pass <- fish_df |>
    dplyr::group_by(event_id, species, lifestage, pass_no) |>
    dplyr::summarise(catch = sum(fish_multiplier, na.rm = TRUE), .groups = "drop")

  total_passes <- runs_df |>
    dplyr::group_by(event_id) |>
    dplyr::summarise(total_number_passes = dplyr::n_distinct(pass_no), .groups = "drop")

  # Prefer the site's canonical BNG coords; fall back to this visit's own
  # captured easting/northing for brand-new sites not yet in the master list.
  event_coords <- events_df |>
    dplyr::left_join(sites_df, by = "site_id", suffix = c("_event", "_site")) |>
    dplyr::mutate(
      export_easting = dplyr::coalesce(easting_site, easting_event),
      export_northing = dplyr::coalesce(northing_site, northing_event)
    )

  pass_grid |>
    dplyr::left_join(catch_by_pass, by = c("event_id", "species", "lifestage", "pass_no")) |>
    dplyr::mutate(catch = dplyr::coalesce(catch, 0)) |>
    dplyr::left_join(event_coords, by = "event_id") |>
    dplyr::left_join(total_passes, by = "event_id") |>
    dplyr::transmute(
      Site_Name = site_code, Easting = export_easting, Northing = export_northing,
      date = format(survey_date, "%d/%m/%Y"),
      total_number_passes = total_number_passes,
      species = unname(neps_species_map[species]),
      lifestage = lifestage, pass = pass_no, count = catch,
      area = area_m2, mean_length = NA_real_, mean_width = NA_real_
    ) |>
    dplyr::arrange(Site_Name, date, species, lifestage, pass)
}
