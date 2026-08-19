# Tab: Project Tagging. Retroactively (or for any event) assign a
# project/contract tag -- independent dimension from catchment/site, browse
# via the SAME global sidebar filters as every other tab, multi-select, and
# assign. Also supports creating a new project inline. This is what makes
# historical analysis by project possible -- most existing data predates
# project tagging and needs to be assigned after the fact.

mod_project_tagging_ui <- function(id) {
  ns <- NS(id)
  tagList(
    fluidRow(
      column(8, selectInput(ns("project_pick"), "Project", choices = NULL)),
      column(4, actionButton(ns("new_project"), "+ New project", class = "mt-4"))
    ),
    actionButton(ns("assign"), "Assign selected events to this project", class = "btn-primary"),
    hr(),
    DT::dataTableOutput(ns("events_table"))
  )
}

mod_project_tagging_server <- function(id, filtered_events, pool, pool_editor) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    refresh_projects <- reactiveVal(0)

    observe({
      refresh_projects()
      projects <- distinct_projects(pool)
      updateSelectInput(session, "project_pick",
                         choices = setNames(projects$project_id, projects$project_code))
    })

    events_df <- reactiveVal(tibble::tibble())
    observe({ events_df(events_browser(pool, filtered_events())) })

    output$events_table <- DT::renderDataTable({
      df <- events_df()
      validate(need(nrow(df) > 0, "No events match the current filters."))
      df |>
        dplyr::transmute(
          event_id, Site = site_code, Catchment = humanize_slug(catchment),
          Date = format(survey_date, "%Y-%m-%d"), Project = dplyr::coalesce(project_code, "—")
        ) |>
        DT::datatable(
          rownames = FALSE, selection = "multiple",
          options = list(pageLength = 15, columnDefs = list(list(visible = FALSE, targets = 0)))
        )
    })
    outputOptions(output, "events_table", suspendWhenHidden = FALSE)

    observeEvent(input$new_project, {
      showModal(modalDialog(
        title = "New project",
        textInput(ns("np_code"), "Project code (short, unique)"),
        textInput(ns("np_name"), "Project name"),
        textInput(ns("np_client"), "Client (optional)"),
        dateInput(ns("np_start"), "Start date", value = NA),
        dateInput(ns("np_end"), "End date", value = NA),
        textAreaInput(ns("np_notes"), "Notes"),
        footer = tagList(modalButton("Cancel"), actionButton(ns("confirm_new_project"), "Create", class = "btn-primary"))
      ))
    })

    observeEvent(input$confirm_new_project, {
      # dateInput(value = NA) -- an untouched optional date field -- reports
      # back as a zero-length value, not a length-1 NA (confirmed 2026-08-19:
      # DBI::dbBind errored "Parameter 4 does not have length 1"). Same class
      # of NA-handling quirk as dateRangeInput elsewhere in this app; guard
      # here rather than force the user to pick dates that don't apply yet.
      safe_date <- function(x) if (length(x) == 0 || is.na(x)) NA_character_ else as.character(x)

      new_id <- upsert_project(pool_editor, input$np_code, input$np_name, input$np_client,
                                safe_date(input$np_start), safe_date(input$np_end), input$np_notes)
      refresh_projects(refresh_projects() + 1)
      updateSelectInput(session, "project_pick", selected = new_id)
      removeModal()
    })

    observeEvent(input$assign, {
      idx <- input$events_table_rows_selected
      req(idx, input$project_pick)
      event_ids <- events_df()$event_id[idx]
      assign_project_to_events(pool_editor, event_ids, as.integer(input$project_pick))
      events_df(events_browser(pool, filtered_events()))  # refresh Project column
      showNotification(paste("Assigned", length(event_ids), "event(s)."), type = "message")
    })
  })
}
