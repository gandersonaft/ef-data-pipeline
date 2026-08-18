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
    updateDateRangeInput(session, "date_range", start = NA, end = NA)
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

  mod_depletion_server("depletion", filtered_events, db_pool)
  mod_length_condition_server("length_condition", filtered_events, db_pool)
  mod_qc_review_server("qc_review", db_pool)
}
