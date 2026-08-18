# Tab 1: Depletion & Density -- server-computed Carle & Strub population
# estimates and density (fish per 100m^2), grouped by site/species/lifestage.

mod_depletion_ui <- function(id) {
  ns <- NS(id)
  tagList(
    DT::dataTableOutput(ns("table"))
  )
}

mod_depletion_server <- function(id, filtered_events, pool) {
  moduleServer(id, function(input, output, session) {
    depletion_data <- reactive({
      event_ids <- filtered_events()
      fish_df <- fish_for_events(pool, event_ids)
      runs_df <- runs_for_events(pool, event_ids)
      build_depletion_table(fish_df, runs_df)
    })

    output$table <- DT::renderDataTable({
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
          `Density /100m2` = round(density_per_100m2, 2)
        ) |>
        DT::datatable(rownames = FALSE, filter = "top", options = list(pageLength = 15))
    })

    # See mod_length_condition.R for why this is needed: outputs in a
    # non-default bslib::nav_panel tab can otherwise never receive the signal
    # to start computing. This tab defaults to active so isn't currently
    # affected, but keep it consistent in case that ever changes.
    outputOptions(output, "table", suspendWhenHidden = FALSE)
  })
}
