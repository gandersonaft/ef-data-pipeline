# Shared lookups/helpers. Species and lifestage codes are the exact values
# from the efish_neps_v8 form's `species`/`lifestage` choice lists -- do not
# add an "adult" lifestage or other species codes without checking the form.

species_labels <- c(
  sal = "Salmon", trt = "Trout", eel = "Eel", lam = "Lamprey",
  min = "Minnow", sto = "Loach", sti = "Stickleback", flo = "Flounder", oth = "Other"
)

lifestage_labels <- c(fry = "Fry (0+)", parr = "Parr (1+)")

label_species <- function(code) unname(species_labels[code])
label_lifestage <- function(code) unname(lifestage_labels[code])

# Catchment slugs (e.g. "river_awe", "appin_coastal") aren't hardcoded here --
# there are ~29 of them defined in the form's `catchment` choices list, and the
# authoritative set/label mapping can drift over time. Filter dropdowns should
# populate catchment choices dynamically from distinct DB values (see
# fn_db_queries.R::distinct_catchments()) and prettify with this helper rather
# than maintaining a second copy of the choices list here.
humanize_slug <- function(slug) {
  slug |>
    gsub("_", " ", x = _) |>
    tools::toTitleCase()
}

#' Derive fry/parr where the real answer is missing but can be inferred from
#' length vs this event's own cutoff -- confirmed with the user 2026-08-19:
#' fry is strictly below the cutoff, parr is at or above it. Only salmon/trout
#' have a fry/parr concept at all (sal_fry_parr_cutoff_mm/trt_fry_parr_cutoff_mm
#' are the only two cutoffs captured on the form); every other species passes
#' through unchanged. A real, user-entered lifestage is NEVER overridden --
#' this only fills the gap for the ~802/803 salmon/trout records that have
#' none (confirmed 2026-08-19: the form's own fry/parr question is almost
#' never actually answered in the field). Deliberately query-time only, not
#' written back to fish_records.lifestage -- the raw stored NULL still
#' honestly reflects "never directly answered"; only display/export/grouping
#' see the derived value.
derive_lifestage <- function(species, lifestage, length_mm, sal_cutoff, trt_cutoff) {
  cutoff <- dplyr::case_when(
    species == "sal" ~ sal_cutoff,
    species == "trt" ~ trt_cutoff,
    TRUE ~ NA_real_
  )
  derived <- dplyr::if_else(!is.na(length_mm) & !is.na(cutoff),
                             dplyr::if_else(length_mm < cutoff, "fry", "parr"),
                             NA_character_)
  dplyr::coalesce(lifestage, derived)
}

empty_state <- function(message) {
  div(
    class = "ef-empty-state",
    style = "padding: 2rem; text-align: center; color: #6c757d;",
    icon("circle-info"),
    p(message)
  )
}
