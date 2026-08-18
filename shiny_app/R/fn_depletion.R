# Server-side depletion/density estimation, computed from raw fish_records
# rather than trusted from the form's own dep_*/den_* self-reported fields
# (per design decision -- those are shown only as an informational comparison,
# never as the primary number).
#
# FSA::removal(method = "CarleStrub") implements the same Carle & Strub (1978)
# algorithm as the form's own media/depletion.js (confirmed by that script's
# own header comment), so server-side and on-device numbers should agree.

#' @param catch Numeric vector of per-pass catch counts, in pass order.
compute_depletion <- function(catch) {
  catch <- catch[!is.na(catch)]

  if (length(catch) < 2 || sum(catch) == 0) {
    return(list(n_passes = length(catch), n_est = NA_real_, n_se = NA_real_, capture_prob = NA_real_))
  }

  res <- tryCatch(FSA::removal(catch, method = "CarleStrub"), error = function(e) NULL)
  if (is.null(res)) {
    return(list(n_passes = length(catch), n_est = NA_real_, n_se = NA_real_, capture_prob = NA_real_))
  }

  list(
    n_passes = length(catch),
    n_est = unname(res$est[["No"]]),
    n_se = unname(res$est[["No.se"]]),
    capture_prob = unname(res$est[["p"]])
  )
}

#' Build the Tab 1 summary table: one row per event x species x lifestage,
#' with the server-computed Carle & Strub population estimate and density.
#'
#' @param fish_df  output of fn_db_queries.R::fish_for_events()
#' @param runs_df  output of fn_db_queries.R::runs_for_events() -- (event_id,
#'   run_id, pass_no) for every pass actually conducted, used to build the
#'   zero-catch-filled pass grid PER EVENT. Deliberately not derived from
#'   fish_df's own pass_no values alone: an event with 2 passes must not
#'   inherit a phantom pass 3 just because another event in the filtered set
#'   had 3 passes.
build_depletion_table <- function(fish_df, runs_df) {
  if (nrow(fish_df) == 0 || nrow(runs_df) == 0) {
    return(tibble::tibble())
  }

  event_meta <- fish_df |>
    dplyr::distinct(event_id, site_code, catchment, survey_date, area_m2)

  species_combos <- fish_df |>
    dplyr::distinct(event_id, species, lifestage)

  # Deliberate many-to-many join: every pass gets crossed with every
  # species/lifestage combo observed at that same event, so a pass where a
  # given species/lifestage caught nothing still contributes an explicit
  # zero rather than being silently absent from that group's catch vector.
  pass_grid <- runs_df |>
    dplyr::distinct(event_id, pass_no) |>
    dplyr::inner_join(species_combos, by = "event_id", relationship = "many-to-many")

  catch_by_pass <- fish_df |>
    dplyr::group_by(event_id, species, lifestage, pass_no) |>
    dplyr::summarise(catch = sum(fish_multiplier, na.rm = TRUE), .groups = "drop")

  pass_grid |>
    dplyr::left_join(catch_by_pass, by = c("event_id", "species", "lifestage", "pass_no")) |>
    dplyr::mutate(catch = dplyr::coalesce(catch, 0)) |>
    dplyr::arrange(event_id, species, lifestage, pass_no) |>
    dplyr::group_by(event_id, species, lifestage) |>
    dplyr::summarise(
      passes = dplyr::n(),
      total_catch = sum(catch),
      depletion = list(compute_depletion(catch)),
      .groups = "drop"
    ) |>
    dplyr::left_join(event_meta, by = "event_id") |>
    dplyr::mutate(
      n_est = purrr::map_dbl(depletion, "n_est"),
      n_se = purrr::map_dbl(depletion, "n_se"),
      capture_prob = purrr::map_dbl(depletion, "capture_prob"),
      density_per_100m2 = dplyr::if_else(
        !is.na(n_est) & !is.na(area_m2) & area_m2 > 0,
        n_est / area_m2 * 100,
        NA_real_
      ),
      species_label = label_species(species),
      lifestage_label = label_lifestage(lifestage)
    ) |>
    dplyr::select(-depletion) |>
    dplyr::arrange(dplyr::desc(survey_date), site_code, species, lifestage)
}
