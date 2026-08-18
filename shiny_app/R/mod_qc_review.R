# Tab 3: QC & Photo Review. Read-only in v1 (per design decision) -- a "mark
# reviewed" write-back is deferred: it needs a write-capable DB role, a
# reviewer identity, and an audit trail, none of which exist yet.
#
# Photos are event-level (site_photos), not per-fish -- selecting a flagged
# event shows every photo taken at that site visit, not just the one flagged
# run/fish.

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
    DT::dataTableOutput(ns("flagged_table")),
    hr(),
    h4("Photos for selected event"),
    uiOutput(ns("photo_gallery"))
  )
}

mod_qc_review_server <- function(id, pool) {
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

    selected_event_id <- reactive({
      df <- flagged()
      idx <- input$flagged_table_rows_selected
      if (is.null(idx) || nrow(df) == 0) {
        return(NULL)
      }
      df$event_id[idx]
    })

    output$photo_gallery <- renderUI({
      event_id <- selected_event_id()
      if (is.null(event_id)) {
        return(empty_state("Select a flagged event above to view its site photos."))
      }

      photos <- site_photos_for_event(pool, event_id)
      if (nrow(photos) == 0) {
        return(empty_state("No photos were attached to this site visit."))
      }

      tagList(lapply(seq_len(nrow(photos)), function(i) {
        url <- sign_photo_url(photos$storage_path[i])
        div(
          style = "display: inline-block; margin: 0.5rem; text-align: center;",
          if (!is.na(url)) {
            tags$img(src = url, style = "max-width: 300px; max-height: 300px; border-radius: 4px;")
          } else {
            empty_state("Could not sign photo URL.")
          },
          tags$div(photos$caption[i])
        )
      }))
    })

    # See mod_length_condition.R for why: outputs in a non-default
    # bslib::nav_panel tab can otherwise never receive the signal to start
    # computing at all.
    outputOptions(output, "flagged_table", suspendWhenHidden = FALSE)
    outputOptions(output, "photo_gallery", suspendWhenHidden = FALSE)
  })
}
