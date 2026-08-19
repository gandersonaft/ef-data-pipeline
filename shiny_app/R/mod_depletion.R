# Tab 1: Depletion & Density -- server-computed Carle & Strub population
# estimates and density (fish per 100m^2), grouped by site/species/lifestage.

mod_depletion_ui <- function(id) {
  ns <- NS(id)
  tagList(
    DT::dataTableOutput(ns("table")),
    downloadButton(ns("download_table"), "Download table (CSV)")
  )
}

mod_depletion_server <- function(id, filtered_events, pool) {
  moduleServer(id, function(input, output, session) {
    depletion_data <- reactive({
      event_ids <- filtered_events()
      fish_df <- fish_for_events(pool, event_ids)
      runs_df <- runs_for_events(pool, event_ids)
      base <- build_depletion_table(fish_df, runs_df)
      # Comparison against the Marine Directorate's own tool, where a
      # matching import exists (see mod_neps_tool.R) -- NA for most rows
      # until that tool's results have actually been imported, which is
      # expected/normal, not an error.
      neps <- neps_results_for_events(pool, fish_df |> dplyr::distinct(event_id, site_code, survey_date))
      base |> dplyr::left_join(neps, by = c("event_id", "species", "lifestage"))
    })

    # Shared between the on-screen table and the CSV download, so the export
    # has the same readable column names/rounding as what's displayed.
    display_table <- reactive({
      df <- depletion_data()
      validate(need(nrow(df) > 0, "No electrofishing passes match the current filters."))

      df |>
        dplyr::transmute(
          Site = site_code,
          Catchment = humanize_slug(catchment),
          Date = format(survey_date, "%Y-%m-%d"),
          Species = species_label,
          `Life stage` = lifestage_label,
          Passes = passes,
          `Total catch` = total_catch,
          `N estimate` = round(n_est, 1),
          `N SE` = round(n_se, 2),
          `Capture prob.` = round(capture_prob, 3),
          `Density /100m2` = round(density_per_100m2, 2),
          `MD Density` = round(observed_density, 2),
          `MD Benchmark` = round(benchmark, 2)
        )
    })

    output$table <- DT::renderDataTable({
      display_table() |>
        DT::datatable(rownames = FALSE, filter = "top", options = list(pageLength = 15))
    })

    output$download_table <- downloadHandler(
      filename = function() paste0("depletion_density_", Sys.Date(), ".csv"),
      content = function(file) write.csv(display_table(), file, row.names = FALSE, na = "")
    )

    # See mod_length_condition.R for why this is needed: outputs in a
    # non-default bslib::nav_panel tab can otherwise never receive the signal
    # to start computing. This tab defaults to active so isn't currently
    # affected, but keep it consistent in case that ever changes.
    outputOptions(output, "table", suspendWhenHidden = FALSE)
  })
}
