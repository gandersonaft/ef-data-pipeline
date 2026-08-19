server <- function(input, output, session) {
  observe({
    catchments <- distinct_catchments(db_pool)
    updateSelectInput(
      session, "catchment",
      choices = setNames(catchments, humanize_slug(catchments))
    )
  })

  observeEvent(input$catchment, {
    sites <- distinct_sites(db_pool, catchment = input$catchment)
    updateSelectInput(session, "site_code", choices = sites)
  }, ignoreNULL = FALSE)

  observeEvent(input$reset_filters, {
    updateSelectInput(session, "catchment", selected = character(0))
    updateSelectInput(session, "site_code", selected = character(0))
    updateDateRangeInput(session, "date_range", start = "2000-01-01", end = Sys.Date() + 1)
    updateCheckboxGroupInput(session, "species", selected = c("sal", "trt"))
  })

  filtered_events <- reactive({
    date_range <- NULL
    if (!is.null(input$date_range) && !any(is.na(input$date_range))) {
      date_range <- input$date_range
    }

    filtered_event_ids(
      db_pool,
      catchment = input$catchment,
      site_code = input$site_code,
      date_range = date_range,
      species = input$species
    )
  })

  # Drill-down connective tissue into Survey Detail. jump_to_site carries a
  # normalized (lower/trim) site_code -- Survey Detail's primary picker is
  # site-first (see mod_survey_detail.R), so a jump only ever needs to name a
  # site; it defaults to that site's newest record itself. Originally built
  # for Projects' QC Review flagged-events list (now hidden, see ui.R) --
  # Site Map's marker click is the only live caller today.
  jump_to_site <- reactiveVal(NULL)
  go_to_survey_detail <- function(site_key) {
    jump_to_site(site_key)
    bslib::nav_select(id = "main_nav", selected = "Survey Detail", session = session)
  }

  current_site_key <- mod_survey_detail_server("survey_detail", filtered_events, db_pool, db_pool_editor, jump_to_site)
  mod_site_map_server("site_map", filtered_events, db_pool, go_to_survey_detail)

  # Restore Survey Detail's site selection whenever the user returns to it
  # from another top-level tab -- confirmed 2026-08-19: Bootstrap re-showing
  # a tab-pane resets DT's row selection client-side even though the widget
  # itself was never destroyed, so a real selection was getting silently
  # dropped on every "check Site Map, come back" round trip. Reuses the
  # exact jump_to_site mechanism already built for Site Map's marker-click
  # drill-down -- isolate() since this must only fire on the nav change
  # itself, not every time current_site_key() happens to update.
  observeEvent(input$main_nav, {
    if (input$main_nav == "Survey Detail") {
      key <- isolate(current_site_key())
      if (!is.null(key)) {
        # reactiveVal only invalidates on an actual value CHANGE -- if the
        # same site was already the last one jumped-to (e.g. a second
        # round trip to the same site), setting jump_to_site() straight to
        # that identical key would silently no-op and never re-select it.
        # Clearing to NULL first forces two real changes either way.
        jump_to_site(NULL)
        jump_to_site(key)
      }
    }
  }, ignoreInit = TRUE)
}
