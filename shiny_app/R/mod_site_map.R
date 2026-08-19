# Tab: Site Map. Plots every site among the currently-filtered events as a
# leaflet marker using sites.lon/sites.lat (WGS84, no conversion needed).
# Deliberately simple -- markers + popups only, no clustering/choropleth.

mod_site_map_ui <- function(id) {
  ns <- NS(id)
  tagList(
    leaflet::leafletOutput(ns("map"), height = "650px")
  )
}

mod_site_map_server <- function(id, filtered_events, pool) {
  moduleServer(id, function(input, output, session) {
    map_sites <- reactive({
      sites_for_events(pool, filtered_events())
    })

    output$map <- leaflet::renderLeaflet({
      df <- map_sites()
      validate(need(nrow(df) > 0, "No sites with coordinates match the current filters."))

      leaflet::leaflet(df) |>
        leaflet::addTiles() |>
        leaflet::addMarkers(
          lng = ~lon, lat = ~lat,
          popup = ~paste0(
            "<b>", site_label, "</b><br/>",
            "Catchment: ", humanize_slug(catchment), "<br/>",
            "Last survey: ", format(last_survey_date, "%Y-%m-%d"), "<br/>",
            "Events: ", event_count
          )
        )
    })

    # Same hidden-tab rendering issue as every other DT/htmlwidget output in
    # this app (see ui.R's shown.bs.tab script) -- applies to leaflet's
    # htmlwidget too.
    outputOptions(output, "map", suspendWhenHidden = FALSE)
  })
}
