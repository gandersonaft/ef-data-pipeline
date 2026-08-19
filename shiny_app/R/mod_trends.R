# Tab: Trends & Reports. Reuses fn_depletion.R::build_depletion_table()
# exactly as Tab 1 (Depletion & Density) already does -- no new query logic
# for the underlying numbers, just a time-series view over the same data so
# multi-year comparison at a site/catchment is legible. To see a year-over-
# year comparison, widen the sidebar's date range and pick a catchment/site
# -- no new filter UI needed here, this reuses the existing global sidebar
# exactly like every other tab.

mod_trends_ui <- function(id) {
  ns <- NS(id)
  tagList(
    selectInput(ns("group_by"), "Group by", choices = c("Site" = "site_code", "Catchment" = "catchment")),
    plotOutput(ns("trend_plot"), height = "500px"),
    downloadButton(ns("download_plot"), "Download chart (PNG)"),
    hr(),
    DT::dataTableOutput(ns("trend_table")),
    downloadButton(ns("download_table"), "Download table (CSV)")
  )
}

mod_trends_server <- function(id, filtered_events, pool) {
  moduleServer(id, function(input, output, session) {
    trend_data <- reactive({
      event_ids <- filtered_events()
      fish_df <- fish_for_events(pool, event_ids)
      runs_df <- runs_for_events(pool, event_ids)
      build_depletion_table(fish_df, runs_df)
    })

    trend_plot_obj <- reactive({
      df <- trend_data()
      validate(need(nrow(df) > 0, "No data matches the current filters."))
      ggplot2::ggplot(df, ggplot2::aes(x = survey_date, y = density_per_100m2,
                                        color = .data[[input$group_by]])) +
        ggplot2::geom_point() + ggplot2::geom_line() +
        ggplot2::facet_wrap(~ species_label + lifestage_label, scales = "free_y") +
        ggplot2::labs(x = NULL, y = "Density (fish / 100 m²)", color = NULL) +
        ggplot2::theme_minimal()
    })

    output$trend_plot <- renderPlot({ trend_plot_obj() })
    outputOptions(output, "trend_plot", suspendWhenHidden = FALSE)

    output$download_plot <- downloadHandler(
      filename = function() paste0("ef_trends_", Sys.Date(), ".png"),
      content = function(file) ggplot2::ggsave(file, plot = trend_plot_obj(), width = 10, height = 6, dpi = 150)
    )

    output$trend_table <- DT::renderDataTable({
      df <- trend_data()
      validate(need(nrow(df) > 0, "No data matches the current filters."))
      df |> dplyr::arrange(site_code, species, lifestage, survey_date) |>
        DT::datatable(rownames = FALSE, options = list(pageLength = 15))
    })
    outputOptions(output, "trend_table", suspendWhenHidden = FALSE)

    output$download_table <- downloadHandler(
      filename = function() paste0("ef_trends_", Sys.Date(), ".csv"),
      content = function(file) write.csv(trend_data(), file, row.names = FALSE, na = "")
    )
  })
}
