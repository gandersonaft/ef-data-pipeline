# Tab: Site Map. Plots every LIVE site among the currently-filtered events
# plus every HISTORICAL SFCC site (see fn_unified_queries.R), coloured by
# survey METHOD (Quantitative (1mm)/(5mm), Timed, Presence/Absence for
# historical; pass-count as the closest live proxy, since live submissions
# don't capture a method field at all) rather than a flat live/historical
# split -- 2026-08-19, replacing the earlier teal/grey scheme. KPI strip +
# card wrapper per the approved mockup (mockups/dashboard-restructure-v4.html).
#
# Also draws the OS Open Rivers network (river_network table, see migration
# 0003_river_network.sql) underneath the site markers for hydrological
# context -- unfiltered, same "fixed backdrop" reasoning as historical sites.
# Deliberately NOT the AFT_CEH network also found in this data drop -- that
# one's licensed via SFCC/CEH and must never be loaded into this app at all,
# see fn_unified_queries.R::river_network_geojson()'s header comment.
#
# Clicking a marker jumps into that site on Survey Detail (see
# go_to_survey_detail() in server.R) -- the site's most recent record shows
# by default, per Survey Detail's own site-first picker.

method_categories <- c(
  "Quantitative (1mm)", "Quantitative (5mm)", "Timed", "Presence/Absence",
  "Live: 1 pass", "Live: 2 passes", "Live: 3 passes", "Live: 4+ passes", "Live: unknown"
)
method_colors <- c(
  "#1C6E76", "#5C8A48", "#B06B1B", "#8B5FBF",
  "#457B9D", "#E76F51", "#6D6875", "#264653", "#ADB5BD"
)
method_palette <- leaflet::colorFactor(palette = method_colors, domain = method_categories)

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
      bslib::card_header(
        "Site Map",
        span(class = "text-muted small", " — coloured by survey method (see marker popup for detail); blue lines = river network (OS Open Rivers); click a marker to open that site in Survey Detail")
      ),
      leaflet::leafletOutput(ns("map"), height = "600px")
    )
  )
}

mod_site_map_server <- function(id, filtered_events, pool, go_to_survey_detail) {
  moduleServer(id, function(input, output, session) {
    live_sites <- reactive({
      df <- sites_for_events(pool, filtered_events())
      if (nrow(df) == 0) return(tibble::tibble())
      df |>
        dplyr::transmute(
          label = site_label, site_key = tolower(trimws(site_code)),
          catchment = humanize_slug(catchment), lon, lat, method_label,
          detail = paste0("Last survey: ", format(last_survey_date, "%Y-%m-%d"), "<br/>Events: ", event_count),
          source = "live"
        )
    })

    historical_sites <- reactive({
      df <- historical_sites_for_map(pool)
      if (nrow(df) == 0) return(df)
      df |>
        dplyr::transmute(
          label = site_code, site_key = tolower(trimws(site_code)),
          catchment = dplyr::coalesce(catchment, "—"), lon, lat, method_label,
          detail = paste0("Last survey: ", format(last_survey_date, "%Y-%m-%d"), "<br/>Events: ", event_count, " (SFCC archive)"),
          source = "historical"
        )
    })

    all_sites <- reactive({
      dplyr::bind_rows(live_sites(), historical_sites())
    })

    river_geojson <- reactive({ river_network_geojson(pool) })

    output$kpi_sites <- renderText({ nrow(all_sites()) })
    output$kpi_catchments <- renderText({ dplyr::n_distinct(all_sites()$catchment, na.rm = TRUE) })
    output$kpi_historical <- renderText({ nrow(historical_sites()) })
    outputOptions(output, "kpi_sites", suspendWhenHidden = FALSE)
    outputOptions(output, "kpi_catchments", suspendWhenHidden = FALSE)
    outputOptions(output, "kpi_historical", suspendWhenHidden = FALSE)

    output$map <- leaflet::renderLeaflet({
      df <- all_sites()
      validate(need(nrow(df) > 0, "No sites with coordinates match the current filters."))

      # click_input_id built server-side via session$ns() rather than
      # relying on leaflet's automatic <outputId>_marker_click Shiny
      # binding -- confirmed 2026-08-19: with a second leaflet widget now on
      # the page (Survey Detail's per-record mini-map), marker clicks here
      # were registering under the literal key "undefined_marker_click"
      # instead of the properly namespaced one (the click payload itself
      # was correct -- {id: "<site_key>", ...} -- only the output-id prefix
      # resolved wrong), so input$map_marker_click never fired. Binding the
      # click handler explicitly inside this widget's own onRender() scopes
      # it to this specific map instance and sets the Shiny input under a
      # name computed once, correctly, in R -- no ambiguity for the JS side
      # to get wrong.
      click_input_id <- session$ns("map_click_fix")

      leaflet::leaflet(df) |>
        leaflet::addTiles() |>
        leaflet::addGeoJSON(
          river_geojson(), weight = 1, color = "#5A8FBE", opacity = 0.5, fillOpacity = 0,
          options = leaflet::pathOptions(interactive = FALSE)
        ) |>
        leaflet::addCircleMarkers(
          lng = ~lon, lat = ~lat, layerId = ~site_key,
          radius = 6, stroke = TRUE, weight = 1, fillOpacity = 0.85,
          color = ~method_palette(method_label), fillColor = ~method_palette(method_label),
          popup = ~paste0(
            "<b>", label, "</b><br/>Catchment: ", catchment,
            "<br/>Method: ", method_label, "<br/>", detail
          )
        ) |>
        leaflet::addLegend(
          position = "bottomright", pal = method_palette, values = method_categories,
          title = "Survey method", opacity = 0.9
        ) |>
        htmlwidgets::onRender(sprintf(
          "function(el, x) {
             // A CircleMarker's own click handling stops the event from
             // propagating up to the map's click handler (confirmed
             // 2026-08-19: this.on('click', ...) on the MAP itself never
             // saw marker clicks at all, e.layer was never populated --
             // Leaflet path layers stop propagation before their bound
             // popup opens). Binding directly to each marker layer's own
             // click event, instead of the map's, sidesteps that entirely.
             var map = this;
             map.eachLayer(function(layer) {
               if (layer.options && layer.options.layerId) {
                 layer.on('click', function(e) {
                   Shiny.setInputValue('%s', {id: layer.options.layerId, nonce: Math.random()});
                 });
               }
             });
           }",
          click_input_id
        ))
    })

    outputOptions(output, "map", suspendWhenHidden = FALSE)

    observeEvent(input$map_click_fix, {
      site_key <- input$map_click_fix$id
      req(site_key)
      go_to_survey_detail(site_key)
    })
  })
}
