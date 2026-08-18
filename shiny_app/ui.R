ui <- bslib::page_navbar(
  title = "NEPS Electrofishing",
  theme = bslib::bs_theme(version = 5),
  sidebar = bslib::sidebar(
    title = "Filters",
    selectInput("catchment", "Catchment", choices = NULL, multiple = TRUE),
    selectInput("site_code", "Site", choices = NULL, multiple = TRUE),
    dateRangeInput("date_range", "Survey date range", start = NA, end = NA),
    checkboxGroupInput(
      "species", "Species",
      choices = setNames(names(species_labels), species_labels),
      selected = c("sal", "trt")
    ),
    actionButton("reset_filters", "Reset filters")
  ),
  bslib::nav_panel("Depletion & Density", mod_depletion_ui("depletion")),
  bslib::nav_panel("Length-Frequency & Condition", mod_length_condition_ui("length_condition")),
  bslib::nav_panel("QC & Photo Review", mod_qc_review_ui("qc_review")),
  header = tags$head(tags$link(rel = "stylesheet", type = "text/css", href = "styles.css"))
)
