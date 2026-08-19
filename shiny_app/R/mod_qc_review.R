# Sub-tab: QC Review (inside Projects, see mod_projects.R). Read-only in v1
# (per design decision) -- a "mark reviewed" write-back is deferred: it needs
# a write-capable DB role, a reviewer identity, and an audit trail, none of
# which exist yet.
#
# List-only, no inline photo gallery -- clicking a flagged event drills down
# into the Survey Detail tab instead (which already has its own Photos
# sub-tab), per the approved dashboard restructure: "drill-down is the
# connective tissue" replacing duplicated inline detail views. See
# go_to_survey_detail() in server.R for the actual nav-switch + event
# preselect mechanism.

format_qc_flags <- function(flags_json) {
  flags <- tryCatch(jsonlite::fromJSON(flags_json), error = function(e) NULL)
  if (is.null(flags) || length(flags) == 0) {
    return("")
  }
  if (is.data.frame(flags)) {
    paste(flags$type, collapse = "; ")
  } else {
    paste(vapply(flags, function(f) f$type %||% "flag", character(1)), collapse = "; ")
  }
}

mod_qc_review_ui <- function(id) {
  ns <- NS(id)
  tagList(
    p(class = "text-muted small", "Click a flagged event to open it in Survey Detail (site details, fish records, photos)."),
    DT::dataTableOutput(ns("flagged_table"))
  )
}

mod_qc_review_server <- function(id, pool, go_to_survey_detail) {
  moduleServer(id, function(input, output, session) {
    flagged <- reactive({
      flagged_events(pool)
    })

    output$flagged_table <- DT::renderDataTable({
      df <- flagged()
      validate(need(nrow(df) > 0, "No flagged events right now."))

      df |>
        dplyr::transmute(
          event_id,
          Site = site_code,
          Catchment = humanize_slug(catchment),
          Date = format(survey_date, "%Y-%m-%d"),
          Flags = purrr::map_chr(qc_flags, format_qc_flags),
          Comments = final_comments
        ) |>
        DT::datatable(
          rownames = FALSE,
          selection = "single",
          options = list(pageLength = 10, columnDefs = list(list(visible = FALSE, targets = 0)))
        )
    })
    outputOptions(output, "flagged_table", suspendWhenHidden = FALSE)

    observeEvent(input$flagged_table_rows_selected, {
      idx <- input$flagged_table_rows_selected
      req(idx)
      event_id <- flagged()$event_id[idx]
      go_to_survey_detail(paste0("live-", event_id))
    })
  })
}
