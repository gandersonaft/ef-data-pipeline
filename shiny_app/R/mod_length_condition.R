# Tab 2: Length-Frequency & Condition. The weight/condition panels use
# shiny::validate(need(...)) empty states rather than blank charts, because
# essentially no current submission has wet_weight_g populated -- the form
# has no weight field today (see supabase/schema.sql comments).

mod_length_condition_ui <- function(id) {
  ns <- NS(id)
  tagList(
    h4("Length-frequency"),
    plotOutput(ns("length_hist"), height = "350px"),
    hr(),
    h4("Length-weight"),
    plotOutput(ns("weight_scatter"), height = "300px"),
    hr(),
    h4("Condition factor (K)"),
    plotOutput(ns("condition_box"), height = "300px")
  )
}

mod_length_condition_server <- function(id, filtered_events, pool) {
  moduleServer(id, function(input, output, session) {
    fish_data <- reactive({
      fish_for_events(pool, filtered_events())
    })

    output$length_hist <- renderPlot({
      df <- fish_data()
      validate(need(nrow(df) > 0, "No fish records match the current filters."))

      df <- df |>
        dplyr::filter(!is.na(length_mm), species %in% c("sal", "trt")) |>
        dplyr::mutate(lifestage_label = label_lifestage(lifestage))
      validate(need(nrow(df) > 0, "No salmon/trout length measurements match the current filters."))

      cutoffs <- df |>
        dplyr::distinct(species, sal_fry_parr_cutoff_mm, trt_fry_parr_cutoff_mm) |>
        dplyr::mutate(cutoff = dplyr::if_else(species == "sal", sal_fry_parr_cutoff_mm, trt_fry_parr_cutoff_mm)) |>
        dplyr::filter(!is.na(cutoff)) |>
        dplyr::group_by(species) |>
        dplyr::summarise(cutoff = mean(cutoff), .groups = "drop")

      p <- ggplot(df, aes(x = length_mm, fill = lifestage_label)) +
        geom_histogram(binwidth = 5, position = "stack", color = "white") +
        facet_wrap(~species, scales = "free", labeller = ggplot2::as_labeller(species_labels)) +
        labs(x = "Fork length (mm)", y = "Count", fill = "Life stage") +
        theme_minimal()

      if (nrow(cutoffs) > 0) {
        p <- p + geom_vline(data = cutoffs, aes(xintercept = cutoff), linetype = "dashed", color = "grey30")
      }
      p
    })

    output$weight_scatter <- renderPlot({
      df <- fish_data() |> dplyr::filter(!is.na(wet_weight_g))
      validate(need(
        nrow(df) > 0,
        "No weight data recorded yet -- this panel will populate automatically once wet_weight_g values start arriving from field scale samples."
      ))

      ggplot(df, aes(x = length_mm, y = wet_weight_g, color = species)) +
        geom_point(alpha = 0.6) +
        labs(x = "Fork length (mm)", y = "Weight (g)", color = "Species") +
        theme_minimal()
    })

    output$condition_box <- renderPlot({
      df <- fish_data() |> dplyr::filter(!is.na(condition_factor))
      validate(need(
        nrow(df) > 0,
        "No condition factor data recorded yet -- this panel will populate automatically once wet_weight_g values start arriving from field scale samples."
      ))

      ggplot(df, aes(x = species, y = condition_factor)) +
        geom_boxplot() +
        labs(x = "Species", y = "Condition factor (K)") +
        theme_minimal()
    })
  })
}
