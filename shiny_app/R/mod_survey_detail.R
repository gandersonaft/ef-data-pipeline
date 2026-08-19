# Tab: Survey Detail. Site-first picker (2026-08-19 rebuild): pick a SITE
# (live+historical records grouped together by normalized site_code, see
# fn_unified_queries.R::sites_with_records()), then pick a RECORD (year) at
# that site -- defaults to the newest. Sub-tabs (Site Details/Fish Records/
# Site History/Photos) operate on the selected record; Site History is the
# one exception, showing every record at the site together.
#
# Historical records are READ-ONLY: no fish editing, no project tagging, no
# photos (the legacy Rockpool workflow never captured them).
#
# Site Details folds in what used to be a separate "Summary" sub-tab (now
# removed, along with the KPI strip) plus new pieces: a per-site mini-map,
# a fish count/density table (three tiers -- see build_site_density_table()
# in fn_depletion.R), a length-frequency chart (salmon/trout only, fixed
# colours), an other-species count table, and substrate/flow composition
# bar charts. All six are shared between live and historical records via
# build_record_analysis()'s adapters, since the underlying display logic
# doesn't care which raw schema the catch data came from.
#
# Timestamp-only audit (updated_at) for live edits -- no reviewer identity or
# audit log yet (tech-demo phase; see fn_db_writes.R header comment for why
# this isn't a blocker). "Delete" is a soft delete (deleted_at) -- labelled
# "Hide" in the UI, not "Delete", so that's not misleading.

#' Shared row-label/value renderer for the Site Details grouped display.
kv <- function(label, value) {
  if (is.null(value) || length(value) == 0 || is.na(value)) value <- "—"
  tags$div(
    class = "row mb-1",
    tags$div(class = "col-5 col-md-4 text-muted", label),
    tags$div(class = "col-7 col-md-8", as.character(value))
  )
}
section <- function(title, ...) tagList(h5(title, class = "mt-3"), ...)

#' The block shared identically between live and historical records: mini
#' map, density table, length-frequency chart, other-species table,
#' substrate/flow charts. Output ids are the same regardless of source --
#' the server-side renderers (see mod_survey_detail_server) branch on
#' selected_record()$source internally via build_record_analysis().
record_analysis_block <- function(ns) {
  tagList(
    leaflet::leafletOutput(ns("site_mini_map"), height = "300px"),
    h5("Fish Count & Density (Salmon & Trout)", class = "mt-3"),
    DT::dataTableOutput(ns("density_table")),
    plotOutput(ns("length_freq_plot"), height = "300px"),
    h5("Other Species Caught", class = "mt-3"),
    DT::dataTableOutput(ns("other_fish_table")),
    h5("Habitat Composition", class = "mt-3"),
    bslib::layout_column_wrap(
      width = 1 / 2,
      plotOutput(ns("substrate_chart"), height = "250px"),
      plotOutput(ns("flow_chart"), height = "250px")
    )
  )
}

#' @param row A single-row tibble from event_full_detail().
render_event_detail <- function(row, ns) {
  tagList(
    section("Site Details",
      kv("Site", row$site_code), kv("Site type", row$site_type),
      kv("Catchment", humanize_slug(row$catchment)), kv("River", row$river_name),
      kv("Survey date", format(row$survey_date, "%Y-%m-%d")),
      kv("Start time", as.character(row$start_time)), kv("End time", as.character(row$end_time)),
      kv("Easting", row$easting), kv("Northing", row$northing)
    ),
    record_analysis_block(ns),
    section("Team & Equipment",
      kv("Water temp (°C)", row$water_temp_c), kv("Conductivity (µS/cm)", row$conductivity_us),
      kv("Water level", row$water_level), kv("Water clarity", row$water_color),
      kv("Water sample #", row$water_sample),
      kv("Anode operator", row$anode_op), kv("Bucket operator", row$bucket_op),
      kv("Banner net", row$banner_net), kv("Hand net", row$hand_net),
      kv("Scribe", row$scribe), kv("Processing", row$processing), kv("Other staff", row$other_staff),
      kv("Equipment type", row$eq_type), kv("Equipment model", row$eq_model),
      kv("Volts", row$volts), kv("Stop nets", row$stop_nets), kv("Anaesthetic", row$anaesthetic)
    ),
    section("Site Dimensions",
      kv("Length (left bank, m)", row$site_length_lb), kv("Length (right bank, m)", row$site_length_rb),
      kv("Reach length (m)", row$reach_length_m), kv("Wetted width (m)", row$wetted_width_m),
      kv("Area (m²)", row$area_m2)
    ),
    # Substrate/flow raw percentages dropped here -- now shown as the charts
    # in record_analysis_block() above instead of duplicating the same data
    # as both a chart and a wall of numbers.
    section("Habitat",
      kv("Salmon fry/parr cutoff (mm)", row$sal_fry_parr_cutoff_mm),
      kv("Trout fry/parr cutoff (mm)", row$trt_fry_parr_cutoff_mm)
    ),
    section("Notes",
      kv("Pollution observed", row$pollution), kv("Pollution notes", row$pollution_notes),
      kv("Stocking observed", row$stocking), kv("Stocking notes", row$stocking_notes),
      kv("Final comments", row$final_comments),
      kv("QC status", row$qc_status)
    )
  )
}

#' @param row A single-row tibble from historical_event_full_detail().
render_historical_event_detail <- function(row, ns) {
  tagList(
    section("Site Details",
      kv("Site", row$site_code), kv("Method", row$method), kv("Planned runs", row$planned_runs),
      kv("Survey date", format(row$survey_date, "%Y-%m-%d")),
      kv("Easting", row$easting), kv("Northing", row$northing)
    ),
    record_analysis_block(ns),
    section("Team & Equipment",
      kv("Water temp (°C)", row$water_temp_c), kv("Conductivity (µS/cm)", row$conductivity_us),
      kv("Water height", row$water_height), kv("Water clarity", row$water_clarity),
      kv("Team lead", row$team_lead), kv("Staff count", row$staff_count),
      kv("Equipment", row$equipment), kv("Volts", row$volts)
    ),
    section("Site Dimensions",
      kv("Reach length (m)", row$reach_length_m), kv("Wetted width (m)", row$wetted_width_m),
      kv("Bed width (m)", row$bed_width_m), kv("Bank width (m)", row$bank_width_m),
      kv("Area (m²)", row$area_m2)
    ),
    section("Notes",
      kv("Pollution observed", row$pollution_observed), kv("Pollution notes", row$pollution_notes),
      kv("Stocking observed", row$stocking_observed), kv("Stocking notes", row$stocking_notes)
    ),
    section("Provenance (SFCC archive)",
      kv("SFCC event trust", row$event_trust), kv("SFCC event status", row$event_status),
      kv("Individual fish data available", row$has_individual_fish_data)
    )
  )
}

#' Turn one record (a row from records_for_site(), live or historical) into
#' the shared shape every analysis output consumes: the full detail row
#' (with lon/lat), how many passes were conducted, the site area, a
#' salmon/trout-only catch_df (species/lifestage/pass_no/catch, ready for
#' build_site_density_table()), raw length data for the length-frequency
#' chart (NULL where unavailable -- historical aggregate-only records have
#' no individual lengths), and an other-species count table.
#'
#' Deliberately a plain function, not a reactive -- Site History needs to
#' call this once per record at a site (a handful of DB round-trips, small
#' data volumes), not just for whichever one is currently selected.
build_record_analysis <- function(pool, rec) {
  if (rec$source == "live") {
    row <- event_full_detail(pool, rec$native_id)
    fish_raw <- fish_for_event_detail(pool, rec$native_id)
    n_passes <- dplyr::n_distinct(runs_for_events(pool, rec$native_id)$pass_no)

    sal_trt <- fish_raw |> dplyr::filter(species %in% c("sal", "trt"))
    catch_df <- sal_trt |>
      dplyr::group_by(species, lifestage, pass_no) |>
      dplyr::summarise(catch = sum(fish_multiplier, na.rm = TRUE), .groups = "drop")
    length_freq_df <- if (nrow(sal_trt) > 0) sal_trt |> dplyr::transmute(species, length_mm, weight = fish_multiplier) else NULL
    other_fish_df <- fish_raw |>
      dplyr::filter(!species %in% c("sal", "trt")) |>
      dplyr::group_by(species) |>
      dplyr::summarise(count = sum(fish_multiplier, na.rm = TRUE), .groups = "drop")
  } else {
    row <- historical_event_full_detail(pool, rec$native_id)
    fish_raw <- historical_fish_for_event(pool, rec$native_id)
    has_fish <- nrow(fish_raw) > 0

    run_counts <- if (!has_fish) historical_run_counts_for_event(pool, rec$native_id) else tibble::tibble()
    n_passes_seen <- if (has_fish) {
      suppressWarnings(max(fish_raw$run_no, na.rm = TRUE))
    } else if (nrow(run_counts) > 0) {
      suppressWarnings(max(run_counts$run_no, na.rm = TRUE))
    } else {
      0L
    }
    n_passes <- if (!is.na(row$planned_runs) && row$planned_runs > 0) row$planned_runs else max(n_passes_seen, 0, na.rm = TRUE)

    if (has_fish) {
      sal_trt <- fish_raw |> dplyr::filter(species %in% c("sal", "trt")) |> dplyr::rename(pass_no = run_no)
      catch_df <- sal_trt |>
        dplyr::group_by(species, lifestage, pass_no) |>
        dplyr::summarise(catch = dplyr::n(), .groups = "drop")
      length_freq_df <- if (nrow(sal_trt) > 0) sal_trt |> dplyr::transmute(species, length_mm, weight = 1) else NULL
      other_fish_df <- fish_raw |>
        dplyr::filter(!species %in% c("sal", "trt")) |>
        dplyr::group_by(species) |>
        dplyr::summarise(count = dplyr::n(), .groups = "drop")
    } else {
      # Aggregate-only: no individual lengths exist, so no length-frequency
      # chart is possible -- collapse age_class to lifestage the same way
      # the ETL does (0 -> fry, 1-4 -> parr, see migration 0002's comment).
      rc <- run_counts |> dplyr::mutate(lifestage = dplyr::if_else(age_class == 0, "fry", "parr"), pass_no = run_no)
      sal_trt <- rc |> dplyr::filter(species %in% c("sal", "trt"))
      catch_df <- sal_trt |>
        dplyr::group_by(species, lifestage, pass_no) |>
        dplyr::summarise(catch = sum(count, na.rm = TRUE), .groups = "drop")
      length_freq_df <- NULL
      other_fish_df <- rc |>
        dplyr::filter(!species %in% c("sal", "trt")) |>
        dplyr::group_by(species) |>
        dplyr::summarise(count = sum(count, na.rm = TRUE), .groups = "drop")
    }
  }

  list(row = row, n_passes = n_passes, area_m2 = row$area_m2,
       catch_df = catch_df, length_freq_df = length_freq_df, other_fish_df = other_fish_df)
}

#' Single-column 100%-stacked bar for one habitat composition field group
#' (substrate or flow) -- field_labels is substrate_labels/flow_labels from
#' utils.R, whose name order is the stacking order.
render_habitat_bar <- function(row, field_labels, chart_title) {
  vals <- vapply(names(field_labels), function(f) {
    v <- row[[f]]
    if (is.null(v) || length(v) == 0 || is.na(v)) 0 else as.numeric(v)
  }, numeric(1))
  df <- tibble::tibble(category = factor(unname(field_labels), levels = unname(field_labels)), value = vals)
  validate(need(sum(df$value, na.rm = TRUE) > 0, paste("No", tolower(chart_title), "data recorded for this record.")))

  ggplot2::ggplot(df, ggplot2::aes(x = chart_title, y = value, fill = category)) +
    ggplot2::geom_col(position = ggplot2::position_stack(reverse = TRUE), width = 0.4) +
    ggplot2::labs(x = NULL, y = "% of streambed", fill = NULL, title = chart_title) +
    ggplot2::theme_minimal() +
    ggplot2::theme(axis.text.x = ggplot2::element_blank(), axis.ticks.x = ggplot2::element_blank())
}

mod_survey_detail_ui <- function(id) {
  ns <- NS(id)
  picker_id <- ns("picker_wrapper")
  tagList(
    div(
      style = "display: flex; justify-content: space-between; align-items: center;",
      h4("Select a site"),
      # Plain client-side toggle (display:none), not a Shiny actionButton --
      # keeps the DT outputs permanently mounted so their row-selection
      # inputs (and the currently selected site/record) survive collapsing
      # the picker, rather than resetting on every show/hide the way
      # removing and re-rendering via renderUI would.
      tags$button(
        "Hide site list", type = "button", class = "btn btn-sm btn-outline-secondary",
        onclick = sprintf(
          "var el = document.getElementById('%s'); var hidden = el.style.display === 'none';
           el.style.display = hidden ? '' : 'none';
           this.textContent = hidden ? 'Hide site list' : 'Show site list';",
          picker_id
        )
      )
    ),
    div(class = "text-muted small mb-1", "One row per site (live + historical records grouped together). Select a site, then a record (year) below it -- defaults to the newest."),
    div(
      id = picker_id,
      DT::dataTableOutput(ns("sites_table")),
      hr(),
      h5("Records for this site"),
      DT::dataTableOutput(ns("records_table"))
    ),
    hr(),
    uiOutput(ns("detail_panel"))
  )
}

#' @param jump_to_site Reactive (reactiveVal from server.R) holding a
#'   normalized (lower/trim) site_code set by another tab's drill-down click
#'   (see go_to_survey_detail() in server.R, currently Site Map's marker
#'   click and server.R's own tab-return restoration). Selects that row in
#'   the site picker; the newest record at the site is then auto-selected
#'   the same way it is on any ordinary site selection.
#' @return A reactive holding the currently selected site's key (or NULL) --
#'   server.R uses this to restore the selection via jump_to_site whenever
#'   the user returns to this tab from elsewhere (see that file for why).
mod_survey_detail_server <- function(id, filtered_events, pool, pool_editor, jump_to_site) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns

    sites_df <- reactive({ sites_with_records(pool, filtered_events()) })

    output$sites_table <- DT::renderDataTable({
      df <- sites_df()
      validate(need(nrow(df) > 0, "No sites available."))
      df |>
        dplyr::transmute(
          site_key, Site = site_code, Catchment = humanize_slug(catchment),
          `Live records` = live_count, `Historical records` = hist_count,
          `Last survey` = format(last_survey_date, "%Y-%m-%d")
        ) |>
        DT::datatable(
          rownames = FALSE, selection = "single",
          options = list(pageLength = 10, columnDefs = list(list(visible = FALSE, targets = 0)))
        )
    })
    outputOptions(output, "sites_table", suspendWhenHidden = FALSE)

    sites_proxy <- DT::dataTableProxy("sites_table")
    observeEvent(jump_to_site(), {
      key <- jump_to_site()
      req(key)
      df <- sites_df()
      idx <- which(df$site_key == key)
      if (length(idx) == 1) {
        DT::selectRows(sites_proxy, idx)
      } else {
        showNotification(
          "That site is outside the current sidebar filters -- widen Catchment/Site/Date/Species to find it here.",
          type = "warning"
        )
      }
    }, ignoreInit = TRUE)

    selected_site <- reactive({
      idx <- input$sites_table_rows_selected
      df <- sites_df()
      if (is.null(idx) || nrow(df) == 0) return(NULL)
      df[idx, ]
    })

    records_df <- reactive({
      site <- selected_site()
      if (is.null(site)) return(tibble::tibble())
      records_for_site(pool, site$site_key)
    })

    output$records_table <- DT::renderDataTable({
      df <- records_df()
      validate(need(nrow(df) > 0, "Select a site above to see its records."))
      df |>
        dplyr::transmute(
          event_key, Date = format(survey_date, "%Y-%m-%d"), Project = project_code,
          Status = status_label, Source = dplyr::if_else(source == "live", "Live", "Historical (SFCC)")
        ) |>
        DT::datatable(
          rownames = FALSE, selection = "single",
          options = list(pageLength = 5, columnDefs = list(list(visible = FALSE, targets = 0)))
        )
    })
    outputOptions(output, "records_table", suspendWhenHidden = FALSE)

    # Auto-select the newest record (row 1 -- records_for_site() is already
    # sorted newest-first) whenever the underlying data changes, i.e. every
    # time a different site is chosen. Tied to the DATA changing rather than
    # the site-selection event directly, so it fires after records_table has
    # something real to select from.
    records_proxy <- DT::dataTableProxy("records_table")
    observeEvent(records_df(), {
      req(nrow(records_df()) > 0)
      DT::selectRows(records_proxy, 1)
    })

    selected_record <- reactive({
      idx <- input$records_table_rows_selected
      df <- records_df()
      if (is.null(idx) || nrow(df) == 0) return(NULL)
      df[idx, ]
    })

    # Live-only id, NULL for a historical selection -- every write-capable
    # observer below (fish edit/add/hide) gates on this exactly as it did
    # before this rebuild.
    selected_event_id <- reactive({
      ev <- selected_record()
      if (is.null(ev) || ev$source != "live") return(NULL)
      ev$native_id
    })

    output$detail_panel <- renderUI({
      ev <- selected_record()
      if (is.null(ev)) {
        return(empty_state("Select a site and record above to view its details."))
      }
      if (ev$source == "live") {
        tabsetPanel(
          tabPanel("Site Details", uiOutput(ns("site_details"))),
          tabPanel("Fish Records",
            DT::dataTableOutput(ns("fish_table")),
            br(),
            actionButton(ns("add_fish"), "Add fish"),
            actionButton(ns("hide_fish"), "Hide selected row", class = "btn-outline-danger")
          ),
          tabPanel("Site History", uiOutput(ns("site_history_panel"))),
          tabPanel("Photos", uiOutput(ns("photo_gallery")))
        )
      } else {
        tagList(
          div(class = "alert alert-secondary mt-2",
              "This is a historical (SFCC archive) record migrated from the legacy Rockpool database. It's read-only -- editing, project tagging, and photos aren't available for archive events."),
          tabsetPanel(
            tabPanel("Site Details", uiOutput(ns("site_details"))),
            tabPanel("Fish Records", uiOutput(ns("fish_table_historical_wrap"))),
            tabPanel("Site History", uiOutput(ns("site_history_panel"))),
            tabPanel("Photos", uiOutput(ns("photo_gallery")))
          )
        )
      }
    })

    ## -- Site Details sub-tab (both sources) --------------------------------

    record_analysis <- reactive({
      ev <- selected_record()
      req(ev)
      build_record_analysis(pool, ev)
    })

    output$site_details <- renderUI({
      ev <- selected_record()
      req(ev)
      row <- record_analysis()$row
      validate(need(nrow(row) > 0, "Record not found."))
      if (ev$source == "live") render_event_detail(row, ns) else render_historical_event_detail(row, ns)
    })

    output$site_mini_map <- leaflet::renderLeaflet({
      row <- record_analysis()$row
      validate(need(!is.null(row$lon) && !is.na(row$lon), "No coordinates available for this record."))
      river_gj <- river_network_geojson_near(pool, row$lon, row$lat)
      leaflet::leaflet() |>
        leaflet::addTiles() |>
        leaflet::setView(lng = row$lon, lat = row$lat, zoom = 15) |>
        leaflet::addGeoJSON(river_gj, weight = 1, color = "#5A8FBE", opacity = 0.5, fillOpacity = 0) |>
        leaflet::addMarkers(lng = row$lon, lat = row$lat)
    })

    output$density_table <- DT::renderDataTable({
      ad <- record_analysis()
      dt <- build_site_density_table(ad$catch_df, ad$n_passes, ad$area_m2)
      validate(need(nrow(dt) > 0, "No salmon/trout catch data for this record."))
      dt |>
        dplyr::transmute(
          Species = species_label, Lifestage = lifestage_label, Passes = ad$n_passes,
          `Catch (pass 1)` = pass1_catch, `Catch (total)` = total_catch,
          `Min density (pass 1)` = round(min_density, 1),
          `Multi-pass density` = round(multi_pass_density, 1),
          `Depletion est. (N)` = round(n_est, 1),
          `Depletion density` = round(depletion_density, 1)
        ) |>
        DT::datatable(rownames = FALSE, options = list(dom = "t", pageLength = 20))
    })

    output$length_freq_plot <- renderPlot({
      df <- record_analysis()$length_freq_df
      validate(need(!is.null(df) && nrow(df) > 0 && any(!is.na(df$length_mm)), "No length data available for this record."))
      ggplot2::ggplot(df, ggplot2::aes(x = length_mm, weight = weight, fill = species)) +
        ggplot2::geom_histogram(binwidth = 5, position = "identity", alpha = 0.7) +
        ggplot2::scale_fill_manual(values = species_colors, labels = unname(species_labels[names(species_colors)]), name = "Species") +
        ggplot2::labs(x = "Length (mm)", y = "Count") +
        ggplot2::theme_minimal()
    })

    output$other_fish_table <- DT::renderDataTable({
      df <- record_analysis()$other_fish_df
      validate(need(!is.null(df) && nrow(df) > 0, "No other species recorded for this record."))
      df |>
        dplyr::transmute(Species = label_species(species), Count = count) |>
        DT::datatable(rownames = FALSE, options = list(dom = "t", pageLength = 10))
    })

    output$substrate_chart <- renderPlot({
      render_habitat_bar(record_analysis()$row, substrate_labels, "Substrate")
    })
    output$flow_chart <- renderPlot({
      render_habitat_bar(record_analysis()$row, flow_labels, "Flow")
    })

    ## -- Site History sub-tab (both sources, all records at the site) ------

    output$site_history_panel <- renderUI({
      df <- records_df()
      if (nrow(df) <= 1) {
        return(empty_state("No other records exist for this site yet."))
      }
      tagList(
        plotOutput(ns("site_history_plot"), height = "350px"),
        DT::dataTableOutput(ns("site_history_table"))
      )
    })

    site_history_data <- reactive({
      df <- records_df()
      req(nrow(df) > 1)
      purrr::map_dfr(seq_len(nrow(df)), function(i) {
        r <- df[i, ]
        ad <- build_record_analysis(pool, r)
        dt <- build_site_density_table(ad$catch_df, ad$n_passes, ad$area_m2)
        if (nrow(dt) == 0) return(tibble::tibble())
        dt |>
          dplyr::filter(lifestage != "ALL") |>
          dplyr::mutate(
            survey_date = r$survey_date, source = r$source,
            density = dplyr::coalesce(depletion_density, multi_pass_density)
          )
      })
    })

    output$site_history_plot <- renderPlot({
      history <- site_history_data()
      validate(need(nrow(history) > 0, "No salmon/trout catch data across this site's other records."))
      ggplot2::ggplot(history, ggplot2::aes(x = survey_date, y = density, color = species, shape = source)) +
        ggplot2::geom_point(size = 3) +
        ggplot2::geom_line(ggplot2::aes(group = interaction(species, lifestage)), na.rm = TRUE) +
        ggplot2::facet_wrap(~lifestage_label, scales = "free_y") +
        ggplot2::scale_color_manual(values = species_colors, labels = unname(species_labels[names(species_colors)]), name = "Species") +
        ggplot2::scale_shape_discrete(labels = c(live = "Live", historical = "Historical (SFCC)"), name = "Source") +
        ggplot2::labs(x = NULL, y = "Density (fish/100m²) -- depletion estimate where available, else multi-pass total") +
        ggplot2::theme_minimal()
    })

    output$site_history_table <- DT::renderDataTable({
      history <- site_history_data()
      validate(need(nrow(history) > 0, "No salmon/trout catch data across this site's other records."))
      history |>
        dplyr::arrange(dplyr::desc(survey_date)) |>
        dplyr::transmute(
          Date = format(survey_date, "%Y-%m-%d"), Source = dplyr::if_else(source == "live", "Live", "Historical (SFCC)"),
          Species = species_label, Lifestage = lifestage_label,
          `Density (fish/100m²)` = round(density, 1)
        ) |>
        DT::datatable(rownames = FALSE, options = list(pageLength = 15))
    })

    ## -- Fish Records sub-tab: LIVE (editable) ------------------------------

    fish_df <- reactiveVal(tibble::tibble())
    observeEvent(selected_event_id(), {
      req(selected_event_id())
      fish_df(fish_for_event_detail(pool, selected_event_id()))
    })

    fish_proxy <- DT::dataTableProxy("fish_table")

    output$fish_table <- DT::renderDataTable({
      df <- fish_df()
      validate(need(nrow(df) > 0, "No fish records for this event."))
      df |>
        dplyr::transmute(
          fish_id, run_id, Pass = pass_no, Species = species, Lifestage = lifestage,
          `Length (mm)` = length_mm, `Weight (g)` = wet_weight_g, K = condition_factor,
          Scaled = scaled, Tissue = tissue_tube, `Bulk count` = count_bulk,
          Multiplier = fish_multiplier, `Last edited` = format(updated_at, "%Y-%m-%d %H:%M")
        ) |>
        DT::datatable(
          rownames = FALSE, selection = "single",
          # fish_id(0)/run_id(1) hidden; Pass(2)/K(7)/Last edited(12) shown
          # but not editable -- server-computed or structural, not user data.
          editable = list(target = "cell", disable = list(columns = c(0, 1, 2, 7, 12))),
          options = list(pageLength = 15, columnDefs = list(list(visible = FALSE, targets = c(0, 1))))
        )
    })
    outputOptions(output, "fish_table", suspendWhenHidden = FALSE)

    observeEvent(input$fish_table_cell_edit, {
      info <- input$fish_table_cell_edit
      df <- fish_df()
      fish_id <- df$fish_id[info$row]
      row <- df[info$row, ]
      col_names <- c("fish_id", "run_id", "pass_no", "species", "lifestage", "length_mm",
                      "wet_weight_g", "condition_factor", "scaled", "tissue_tube",
                      "count_bulk", "fish_multiplier", "updated_at")
      edited_col <- col_names[info$col + 1]  # DT is 0-indexed; +1 for R
      new_val <- DT::coerceValue(info$value, row[[edited_col]])
      row[[edited_col]] <- new_val

      update_fish_record(
        pool_editor, fish_id, row$species, row$lifestage, row$length_mm,
        row$wet_weight_g, row$scaled, row$tissue_tube, row$count_bulk, row$fish_multiplier
      )
      fish_df(fish_for_event_detail(pool, selected_event_id()))  # re-pull for trigger-computed condition_factor/updated_at
      DT::replaceData(fish_proxy, fish_df(), resetPaging = FALSE, rownames = FALSE)
    })

    observeEvent(input$add_fish, {
      df <- fish_df()
      req(nrow(df) > 0)
      run_choices <- df |> dplyr::distinct(run_id, pass_no)
      showModal(modalDialog(
        title = "Add fish",
        selectInput(ns("new_run_id"), "Pass",
                    choices = setNames(run_choices$run_id, paste("Pass", run_choices$pass_no))),
        selectInput(ns("new_species"), "Species", choices = setNames(names(species_labels), species_labels)),
        selectInput(ns("new_lifestage"), "Lifestage", choices = setNames(names(lifestage_labels), lifestage_labels)),
        numericInput(ns("new_length"), "Length (mm)", value = NA),
        numericInput(ns("new_weight"), "Weight (g)", value = NA),
        footer = tagList(modalButton("Cancel"), actionButton(ns("confirm_add"), "Add", class = "btn-primary"))
      ))
    })

    observeEvent(input$confirm_add, {
      insert_fish_record(
        pool_editor, as.integer(input$new_run_id), input$new_species, input$new_lifestage,
        input$new_length, input$new_weight, scaled = FALSE, tissue_tube = NA_character_,
        count_bulk = 1L, fish_multiplier = 1L
      )
      fish_df(fish_for_event_detail(pool, selected_event_id()))
      removeModal()
    })

    observeEvent(input$hide_fish, {
      idx <- input$fish_table_rows_selected
      req(idx)
      showModal(modalDialog(
        title = "Hide this fish record?",
        "The record is hidden from every view but not permanently deleted -- it can be restored later if this was a mistake.",
        footer = tagList(modalButton("Cancel"), actionButton(ns("confirm_hide"), "Hide", class = "btn-danger"))
      ))
    })

    observeEvent(input$confirm_hide, {
      idx <- input$fish_table_rows_selected
      fish_id <- fish_df()$fish_id[idx]
      delete_fish_record(pool_editor, fish_id)
      fish_df(fish_for_event_detail(pool, selected_event_id()))
      removeModal()
    })

    ## -- Fish Records sub-tab: HISTORICAL (read-only) -----------------------

    output$fish_table_historical_wrap <- renderUI({
      ev <- selected_record()
      req(ev, ev$source == "historical")
      fish_n <- nrow(historical_fish_for_event(pool, ev$native_id))
      run_n <- nrow(historical_run_counts_for_event(pool, ev$native_id))
      if (fish_n == 0 && run_n == 0) {
        return(empty_state("No fish or catch-count data available for this historical event."))
      }
      DT::dataTableOutput(ns("fish_table_historical"))
    })

    output$fish_table_historical <- DT::renderDataTable({
      ev <- selected_record()
      req(ev, ev$source == "historical")
      fish_df <- historical_fish_for_event(pool, ev$native_id)
      if (nrow(fish_df) > 0) {
        fish_df |>
          dplyr::transmute(
            Run = run_no, Species = label_species(species), `Length (mm)` = length_mm,
            `Age class` = age_class, Lifestage = unname(lifestage_labels[lifestage])
          ) |>
          DT::datatable(rownames = FALSE, options = list(pageLength = 15))
      } else {
        historical_run_counts_for_event(pool, ev$native_id) |>
          dplyr::transmute(Species = label_species(species), `Age class` = age_class, Run = run_no, Count = count) |>
          DT::datatable(rownames = FALSE, options = list(pageLength = 15))
      }
    })

    ## -- Photos sub-tab (live only) ------------------------------------------

    output$photo_gallery <- renderUI({
      ev <- selected_record()
      req(ev)
      if (ev$source != "live") {
        return(empty_state("Historical (SFCC archive) events have no photos -- photo capture wasn't part of the legacy Rockpool workflow."))
      }
      photos <- site_photos_for_event(pool, ev$native_id)
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

    # Returned so server.R can restore the site selection after a round trip
    # to another top-level tab (e.g. Site Map) and back -- confirmed
    # 2026-08-19: Bootstrap re-showing this pane resets DT's client-side row
    # selection even though the underlying widget itself is never destroyed
    # (a plain CSS show/hide, not a DOM removal), so the server-side
    # input$sites_table_rows_selected genuinely goes NULL on return.
    #
    # Tracked as its OWN reactiveVal (last_known_site_key), not read live off
    # selected_site() -- confirmed the naive version of this (returning
    # selected_site()$site_key directly) races the reset above: the DT reset
    # and the input$main_nav change that triggers server.R's restore both
    # land in the same batched message, so by the time the restore observer
    # runs, selected_site() already reflects the already-cleared selection.
    # last_known_site_key only ever gets written on a REAL selection, so it
    # survives the reset unaffected -- restoration reuses the exact
    # jump_to_site mechanism already built for Site Map's marker-click
    # drill-down.
    last_known_site_key <- reactiveVal(NULL)
    observeEvent(selected_site(), {
      site <- selected_site()
      if (!is.null(site)) last_known_site_key(site$site_key)
    })

    reactive({ last_known_site_key() })
  })
}
