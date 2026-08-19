ui <- bslib::page_navbar(
  title = "NEPS Electrofishing",
  theme = bslib::bs_theme(version = 5),
  sidebar = bslib::sidebar(
    title = "Filters",
    selectInput("catchment", "Catchment", choices = NULL, multiple = TRUE),
    selectInput("site_code", "Site", choices = NULL, multiple = TRUE),
    dateRangeInput(
      "date_range", "Survey date range",
      # Wide default covering all realistic survey dates, not start/end = NA:
      # NA silently fails Shiny's date coercion and falls back to today for
      # both ends, which filters out every real (necessarily past-dated)
      # survey on first load -- confirmed 2026-08-18 against real data.
      start = "2000-01-01", end = Sys.Date() + 1
    ),
    checkboxGroupInput(
      "species", "Species",
      choices = setNames(names(species_labels), species_labels),
      selected = c("sal", "trt")
    ),
    actionButton("reset_filters", "Reset filters")
  ),
  bslib::nav_panel("Depletion & Density", mod_depletion_ui("depletion")),
  bslib::nav_panel("Trends & Reports", mod_trends_ui("trends")),
  bslib::nav_panel("Length-Frequency & Condition", mod_length_condition_ui("length_condition")),
  bslib::nav_panel("QC & Photo Review", mod_qc_review_ui("qc_review")),
  bslib::nav_panel("Site Map", mod_site_map_ui("site_map")),
  header = tags$head(
    tags$link(rel = "stylesheet", type = "text/css", href = "styles.css"),
    # Confirmed 2026-08-18: a DT output inside a bslib::nav_panel that isn't
    # the initially-active tab never renders, even with
    # outputOptions(suspendWhenHidden = FALSE) (see mod_*.R) -- the server
    # computes and sends the real htmlwidget value (confirmed via server-
    # side logging), but the container is left holding only Shiny's
    # placeholder ("&nbsp;"), with zero <table> markup ever inserted, even
    # after the tab is clicked. This isn't a DataTables column-width problem
    # (columns.adjust() on shown.bs.tab did not help, because there is no
    # table to adjust) -- it's that the htmlwidget's client-side binding
    # never actually applied the value while its container was hidden, and
    # nothing re-triggers that application on becoming visible. Force it by
    # having Shiny fully re-bind the newly-shown pane's outputs, which
    # re-requests and re-applies their current values from scratch.
    tags$script(HTML(
      "document.addEventListener('shown.bs.tab', function(e) {
         var targetSel = e.target.getAttribute('href') || e.target.getAttribute('data-bs-target');
         if (!targetSel) return;
         var pane = document.querySelector(targetSel);
         if (!pane || !window.Shiny) return;
         Shiny.unbindAll(pane);
         Shiny.bindAll(pane);
       });"
    ))
  )
)
