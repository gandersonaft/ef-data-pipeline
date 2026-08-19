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

#' Build one record's fish-count/density table for Survey Detail's Site
#' Details tab: three density tiers per species x lifestage group (a plain
#' first-pass count is itself a valid MINIMUM population estimate -- more
#' fish may simply not have been caught -- the multi-pass total is a looser
#' minimum still, and the modelled Carle & Strub estimate is the only one
#' that accounts for capture probability), plus "All Salmon"/"All Trout"/
#' "All Fish" total rows modelled the same way as any other group (always
#' present, even at zero catch, so the table's shape doesn't shift record to
#' record).
#'
#' Deliberately decoupled from any one raw data shape (unlike
#' build_depletion_table(), which is fish_for_events()-specific) -- three
#' different callers in mod_survey_detail.R adapt live fish_records,
#' historical individual fish, and historical aggregate run-counts into this
#' shared `catch_df` shape.
#'
#' @param catch_df  columns: species, lifestage, pass_no, catch -- already
#'   summed to one row per species x lifestage x pass actually caught in.
#' @param n_passes  total passes conducted at this record (from the record's
#'   own pass/run count, NOT inferred from catch_df's own pass_no values --
#'   a pass with zero catch for a group must still count as an explicit
#'   zero, same reasoning as build_depletion_table()'s pass_grid).
#' @param area_m2   this record's own site area, for density.
build_site_density_table <- function(catch_df, n_passes, area_m2) {
  if (nrow(catch_df) == 0 || n_passes == 0) {
    return(tibble::tibble())
  }

  sum_by_pass <- function(df, species_val) {
    df |>
      dplyr::group_by(pass_no) |>
      dplyr::summarise(catch = sum(catch), .groups = "drop") |>
      dplyr::mutate(species = species_val, lifestage = "ALL")
  }
  all_salmon <- sum_by_pass(dplyr::filter(catch_df, species == "sal"), "sal")
  all_trout  <- sum_by_pass(dplyr::filter(catch_df, species == "trt"), "trt")
  all_fish   <- sum_by_pass(catch_df, "ALL")

  # Force the three total rows to exist even when zero-catch (e.g. no salmon
  # caught this pass) -- otherwise a species/lifestage combo with no rows in
  # catch_df would never enter the pass grid at all, and the totals would
  # silently vanish from the table instead of reading as a real zero.
  species_combos <- catch_df |>
    dplyr::distinct(species, lifestage) |>
    dplyr::bind_rows(tibble::tibble(species = c("sal", "trt", "ALL"), lifestage = "ALL")) |>
    dplyr::distinct()

  pass_grid <- tidyr::expand_grid(pass_no = seq_len(n_passes), species_combos)

  # area_m2 is a single scalar for the whole table (one record's own area) --
  # guard it once here rather than inside mutate(), where dplyr::if_else()'s
  # condition (length 1) can't broadcast against the per-row `true`/`false`
  # vectors (confirmed: errors "Can't recycle `true` (size N) to size 1").
  # Division by NA_real_ below then naturally propagates NA, no per-row
  # if_else() needed at all.
  area_m2 <- if (is.na(area_m2) || area_m2 <= 0) NA_real_ else area_m2

  pass_grid |>
    dplyr::left_join(
      dplyr::bind_rows(catch_df, all_salmon, all_trout, all_fish),
      by = c("pass_no", "species", "lifestage")
    ) |>
    dplyr::mutate(catch = dplyr::coalesce(catch, 0)) |>
    dplyr::arrange(species, lifestage, pass_no) |>
    dplyr::group_by(species, lifestage) |>
    dplyr::summarise(
      pass1_catch = catch[pass_no == 1][1],
      total_catch = sum(catch),
      depletion = list(compute_depletion(catch)),
      .groups = "drop"
    ) |>
    dplyr::mutate(
      n_est = purrr::map_dbl(depletion, "n_est"),
      n_se = purrr::map_dbl(depletion, "n_se"),
      min_density = pass1_catch / area_m2 * 100,
      multi_pass_density = total_catch / area_m2 * 100,
      depletion_density = n_est / area_m2 * 100,
      species_label = dplyr::case_when(
        species == "ALL" ~ "All Fish",
        lifestage == "ALL" ~ paste("All", label_species(species)),
        TRUE ~ label_species(species)
      ),
      lifestage_label = dplyr::if_else(lifestage == "ALL", "—", label_lifestage(lifestage))
    ) |>
    dplyr::select(-depletion) |>
    # Real species/lifestage rows first (species, then lifestage), the three
    # totals last, "All Fish" as the very last row (grand total).
    dplyr::arrange(species == "ALL", species, lifestage == "ALL", lifestage)
}
