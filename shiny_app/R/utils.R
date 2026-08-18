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

empty_state <- function(message) {
  div(
    class = "ef-empty-state",
    style = "padding: 2rem; text-align: center; color: #6c757d;",
    icon("circle-info"),
    p(message)
  )
}
