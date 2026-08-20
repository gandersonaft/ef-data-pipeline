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

# Fixed colours for the length-frequency chart on Survey Detail -- deliberately
# NOT ggplot's default hue scale, which reassigns colours depending on which
# species happen to be present in a given record's data, so the same species
# could render a different colour on different records. Reuses the app's own
# theme colours (ef_theme's primary/warning, see theme.R) for visual
# consistency rather than picking new ones. Only salmon/trout ever appear on
# that chart (eels and everything else are excluded there by design).
species_colors <- c(sal = "#1C6E76", trt = "#B06B1B")

# Substrate/flow composition fields on electrofishing_events/historical_events
# are real percentages (confirmed against real data: sub_total/flow_total ==
# 100) -- order here is the stacking order for the single-column 100%-stacked
# bar charts on Survey Detail, coarsest/calmest to finest/fastest.
substrate_labels <- c(
  sub_be = "Bedrock", sub_bo = "Boulder", sub_co = "Cobble", sub_pe = "Pebble",
  sub_gr = "Gravel", sub_sa = "Sand", sub_si = "Silt", sub_ho = "High Organic"
)
flow_labels <- c(
  flow_sm = "Smooth", flow_dp = "Deep pool", flow_sp = "Shallow pool", flow_dg = "Deep glide",
  flow_sg = "Shallow glide", flow_ru = "Run", flow_ri = "Riffle", flow_to = "Torrent"
)

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
