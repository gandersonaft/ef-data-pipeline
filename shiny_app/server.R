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

  # Drill-down connective tissue between Projects (e.g. QC Review's flagged
  # events list) and Survey Detail -- jump_to_event carries the target
  # event_key, go_to_survey_detail() both sets it and switches the top-level
  # nav, so any module that's handed the callback can open a specific survey
  # without needing to know about ui.R's tab structure itself.
  jump_to_event <- reactiveVal(NULL)
  go_to_survey_detail <- function(event_key) {
    jump_to_event(event_key)
    bslib::nav_select(id = "main_nav", selected = "Survey Detail", session = session)
  }

  mod_projects_server("projects", filtered_events, db_pool, db_pool_editor, go_to_survey_detail)
  mod_survey_detail_server("survey_detail", filtered_events, db_pool, db_pool_editor, jump_to_event)
  mod_site_map_server("site_map", filtered_events, db_pool)
}
