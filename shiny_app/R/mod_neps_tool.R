# Tab: NEPS Tool Export/Import. Round-trips data with the Marine
# Directorate's official NEPS Electrofishing Data Analysis Tool
# (https://scotland.shinyapps.io/sg-neps-electrofishing-analysis-tool/):
# export our filtered data in its required upload format, and import its
# results export back in for comparison against our own Carle-Strub
# estimates (surfaced as extra columns on the Depletion & Density tab).

mod_neps_tool_ui <- function(id) {
  ns <- NS(id)
  tagList(
    h4("Export to Marine Directorate NEPS Tool"),
    p(class = "text-muted",
      "Only Salmon and Trout records are included (the NEPS tool doesn't support other species), ",
      "regardless of the Species filter above. Respects the current Catchment/Site/Date filters."),
    downloadButton(ns("download_csv"), "Download NEPS export (.csv)"),
    hr(),
    h4("Import NEPS Tool results"),
    fileInput(ns("results_csv"), "Upload results CSV from the NEPS tool"),
    DT::dataTableOutput(ns("preview_table")),
    actionButton(ns("confirm_import"), "Import previewed rows", class = "btn-primary"),
    hr(),
    h4("All imported NEPS results (raw)"),
    DT::dataTableOutput(ns("raw_results_table"))
  )
}

mod_neps_tool_server <- function(id, filtered_events, pool, pool_editor) {
  moduleServer(id, function(input, output, session) {
    output$download_csv <- downloadHandler(
      filename = function() paste0("neps_export_", Sys.Date(), ".csv"),
      content = function(file) {
        ids <- filtered_events()
        fish_df <- fish_for_events(pool, ids)
        runs_df <- runs_for_events(pool, ids)
        events_df <- tbl_events(pool) |> dplyr::filter(event_id %in% !!ids) |> dplyr::collect()
        sites_df <- tbl_sites(pool) |> dplyr::select(site_id, easting, northing) |> dplyr::collect()
        export_df <- build_neps_export_table(fish_df, runs_df, events_df, sites_df)
        write.csv(export_df, file, row.names = FALSE, na = "")
      }
    )

    uploaded <- reactive({
      req(input$results_csv)
      df <- read.csv(input$results_csv$datapath, stringsAsFactors = FALSE, check.names = FALSE)
      df$date <- as.Date(df$date, format = "%d/%m/%Y")
      df
    })

    output$preview_table <- DT::renderDataTable({
      df <- uploaded()
      DT::datatable(df, options = list(pageLength = 10, scrollX = TRUE), rownames = FALSE)
    })
    outputOptions(output, "preview_table", suspendWhenHidden = FALSE)

    observeEvent(input$confirm_import, {
      import_neps_results(pool_editor, uploaded())
      showNotification(paste("Imported", nrow(uploaded()), "row(s)."), type = "message")
    })

    output$raw_results_table <- DT::renderDataTable({
      df <- dplyr::tbl(pool, "neps_tool_results") |> dplyr::collect()
      validate(need(nrow(df) > 0, "No NEPS tool results imported yet."))
      DT::datatable(df, options = list(pageLength = 10, scrollX = TRUE), rownames = FALSE)
    })
    outputOptions(output, "raw_results_table", suspendWhenHidden = FALSE)
  })
}
