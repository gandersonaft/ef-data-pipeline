# Tab: Site Map. Plots every LIVE site among the currently-filtered events
# plus every HISTORICAL SFCC site (see fn_unified_queries.R), colour-coded
# by source rather than pooled into one undifferentiated marker set --
# historical sites are archive data, not something to visually conflate
# with current survey coverage. KPI strip + card wrapper per the approved
# mockup (mockups/dashboard-restructure-v4.html).

mod_site_map_ui <- function(id) {
  ns <- NS(id)
  tagList(
    bslib::layout_column_wrap(
      width = 1/3,
      bslib::value_box(title = "Sites shown", value = textOutput(ns("kpi_sites")), theme = "primary"),
      bslib::value_box(title = "Catchments represented", value = textOutput(ns("kpi_catchments")), theme = "secondary"),
      bslib::value_box(title = "Historical sites (SFCC archive)", value = textOutput(ns("kpi_historical")), theme = "bg-light")
    ),
    bslib::card(
      bslib::card_header("Site Map", span(class = "text-muted small", " — teal = live survey site, grey = historical (SFCC archive) site")),
      leaflet::leafletOutput(ns("map"), height = "600px")
    )
  )
}

mod_site_map_server <- function(id, filtered_events, pool) {
  moduleServer(id, function(input, output, session) {
    live_sites <- reactive({
      sites_for_events(pool, filtered_events()) |>
        dplyr::transmute(
          label = site_label, catchment = humanize_slug(catchment), lon, lat,
          detail = paste0("Last survey: ", format(last_survey_date, "%Y-%m-%d"), "<br/>Events: ", event_count),
          source = "live"
        )
    })

    historical_sites <- reactive({
      df <- historical_sites_for_map(pool)
      if (nrow(df) == 0) return(df)
      df |>
        dplyr::transmute(
          label = site_code, catchment = dplyr::coalesce(catchment, "—"), lon, lat,
          detail = paste0("Last survey: ", format(last_survey_date, "%Y-%m-%d"), "<br/>Events: ", event_count, " (SFCC archive)"),
          source = "historical"
        )
    })

    all_sites <- reactive({
      dplyr::bind_rows(live_sites(), historical_sites())
    })

    output$kpi_sites <- renderText({ nrow(all_sites()) })
    output$kpi_catchments <- renderText({ dplyr::n_distinct(all_sites()$catchment, na.rm = TRUE) })
    output$kpi_historical <- renderText({ nrow(historical_sites()) })
    outputOptions(output, "kpi_sites", suspendWhenHidden = FALSE)
    outputOptions(output, "kpi_catchments", suspendWhenHidden = FALSE)
    outputOptions(output, "kpi_historical", suspendWhenHidden = FALSE)

    output$map <- leaflet::renderLeaflet({
      df <- all_sites()
      validate(need(nrow(df) > 0, "No sites with coordinates match the current filters."))

      leaflet::leaflet(df) |>
        leaflet::addTiles() |>
        leaflet::addCircleMarkers(
          lng = ~lon, lat = ~lat,
          radius = 6, stroke = TRUE, weight = 1, fillOpacity = 0.85,
          color = ~ifelse(source == "live", "#1C6E76", "#5A6B61"),
          fillColor = ~ifelse(source == "live", "#1C6E76", "#93A69B"),
          popup = ~paste0("<b>", label, "</b><br/>Catchment: ", catchment, "<br/>", detail)
        )
    })

    outputOptions(output, "map", suspendWhenHidden = FALSE)
  })
}
