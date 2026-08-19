# Tab: Survey Detail. Pick a survey event -- LIVE (any qc_status, unlike the
# QC tab's flagged-only picker) or HISTORICAL (SFCC/Rockpool archive, see
# fn_unified_queries.R) -- then see everything about it. Opens on a Summary
# sub-tab (KPIs + scoped length-frequency) by default, per the approved
# mockup (mockups/dashboard-restructure-v4.html), then Site Details, Fish
# Records, Photos.
#
# Historical events are READ-ONLY: no fish editing, no project tagging, no
# photos (the legacy Rockpool workflow never captured them). They're listed
# alongside live events in the same picker (event_key "live-<id>"/"hist-<id>"
# avoids collisions), not a separate 4th tab, per HANDOFF.md's instruction.
# The picker does NOT apply the sidebar's catchment/site filters to
# historical rows -- those dropdowns are populated from live slugs that don't
# map onto SFCC's own free-text catchment values -- only live events respect
# the full sidebar filter set (same scope decision already made for Site Map
# in fn_unified_queries.R).
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

#' @param row A single-row tibble from event_full_detail().
render_event_detail <- function(row) {
  tagList(
    section("Site Details",
      kv("Site", row$site_code), kv("Site type", row$site_type),
      kv("Catchment", humanize_slug(row$catchment)), kv("River", row$river_name),
      kv("Survey date", format(row$survey_date, "%Y-%m-%d")),
      kv("Start time", as.character(row$start_time)), kv("End time", as.character(row$end_time)),
      kv("Easting", row$easting), kv("Northing", row$northing)
    ),
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
    section("Habitat",
      kv("Substrate: bedrock", row$sub_be), kv("Substrate: boulder", row$sub_bo),
      kv("Substrate: cobble", row$sub_co), kv("Substrate: pebble", row$sub_pe),
      kv("Substrate: gravel", row$sub_gr), kv("Substrate: sand", row$sub_sa),
      kv("Substrate: silt", row$sub_si), kv("Substrate: hollow/other", row$sub_ho),
      kv("Flow: smooth", row$flow_sm), kv("Flow: deep pool", row$flow_dp),
      kv("Flow: shallow pool", row$flow_sp), kv("Flow: deep glide", row$flow_dg),
      kv("Flow: shallow glide", row$flow_sg), kv("Flow: run", row$flow_ru),
      kv("Flow: riffle", row$flow_ri), kv("Flow: torrent", row$flow_to),
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
render_historical_event_detail <- function(row) {
  tagList(
    section("Site Details",
      kv("Site", row$site_code), kv("Method", row$method), kv("Planned runs", row$planned_runs),
      kv("Survey date", format(row$survey_date, "%Y-%m-%d")),
      kv("Easting", row$easting), kv("Northing", row$northing)
    ),
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
    section("Habitat",
      kv("Substrate: bedrock", row$sub_be), kv("Substrate: boulder", row$sub_bo),
      kv("Substrate: cobble", row$sub_co), kv("Substrate: pebble", row$sub_pe),
      kv("Substrate: gravel", row$sub_gr), kv("Substrate: sand", row$sub_sa),
      kv("Substrate: silt", row$sub_si), kv("Substrate: hollow/other", row$sub_ho),
      kv("Flow: smooth", row$flow_sm), kv("Flow: deep pool", row$flow_dp),
      kv("Flow: shallow pool", row$flow_sp), kv("Flow: deep glide", row$flow_dg),
      kv("Flow: shallow glide", row$flow_sg), kv("Flow: run", row$flow_ru),
      kv("Flow: riffle", row$flow_ri), kv("Flow: torrent", row$flow_to)
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

mod_survey_detail_ui <- function(id) {
  ns <- NS(id)
  picker_id <- ns("picker_wrapper")
  tagList(
    div(
      style = "display: flex; justify-content: space-between; align-items: center;",
      h4("Select a survey event"),
      # Plain client-side toggle (display:none), not a Shiny actionButton --
      # keeps the DT output permanently mounted so input$events_table_rows_selected
      # (and the currently selected event) survives collapsing the picker,
      # rather than resetting on every show/hide the way removing and
      # re-rendering the table via renderUI would.
      tags$button(
        "Hide event list", type = "button", class = "btn btn-sm btn-outline-secondary",
        onclick = sprintf(
          "var el = document.getElementById('%s'); var hidden = el.style.display === 'none';
           el.style.display = hidden ? '' : 'none';
           this.textContent = hidden ? 'Hide event list' : 'Show event list';",
          picker_id
        )
      )
    ),
    div(class = "text-muted small mb-1", "Teal = live survey event, grey = historical (SFCC archive) event."),
    div(id = picker_id, DT::dataTableOutput(ns("events_table"))),
    hr(),
    uiOutput(ns("detail_panel"))
  )
}

#' @param jump_to_event Reactive (reactiveVal from server.R) holding an
#'   event_key ("live-<id>"/"hist-<id>") set by another tab's drill-down
#'   click (see go_to_survey_detail() in server.R). Pre-selects that row in
#'   the picker once it's present in combined_events_df() -- a NULL/no-op
#'   value on ordinary loads.
mod_survey_detail_server <- function(id, filtered_events, pool, pool_editor, jump_to_event) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns

    live_events_df <- reactive({
      df <- events_browser(pool, filtered_events())
      if (nrow(df) == 0) return(tibble::tibble())
      df |>
        dplyr::transmute(
          event_key = paste0("live-", event_id), source = "live", native_id = event_id,
          site_code, catchment = humanize_slug(catchment), survey_date,
          project_code = dplyr::coalesce(project_code, "—"), status_label = qc_status
        )
    })

    # No sidebar-filter dependency -- see file header comment. Computed once
    # per session (no reactive inputs to invalidate it), not re-pulled on
    # every filter change.
    historical_events_df <- reactive({
      df <- historical_events_browser(pool)
      if (nrow(df) == 0) return(tibble::tibble())
      df |>
        dplyr::transmute(
          event_key, source, native_id = historical_event_id,
          site_code, catchment = dplyr::coalesce(catchment, "—"), survey_date,
          project_code = "—",
          status_label = dplyr::if_else(has_individual_fish_data, "Archive (fish data)", "Archive (summary only)")
        )
    })

    combined_events_df <- reactive({
      dplyr::bind_rows(live_events_df(), historical_events_df()) |>
        dplyr::arrange(dplyr::desc(survey_date))
    })

    output$events_table <- DT::renderDataTable({
      df <- combined_events_df()
      validate(need(nrow(df) > 0, "No events available."))
      df |>
        dplyr::transmute(
          event_key, native_id,
          Site = site_code, Catchment = catchment,
          Date = format(survey_date, "%Y-%m-%d"),
          Project = project_code, Status = status_label,
          Source = dplyr::if_else(source == "live", "Live", "Historical (SFCC)")
        ) |>
        DT::datatable(
          rownames = FALSE, selection = "single",
          options = list(pageLength = 10, columnDefs = list(list(visible = FALSE, targets = c(0, 1))))
        )
    })
    outputOptions(output, "events_table", suspendWhenHidden = FALSE)

    events_proxy <- DT::dataTableProxy("events_table")
    observeEvent(jump_to_event(), {
      key <- jump_to_event()
      req(key)
      df <- combined_events_df()
      idx <- which(df$event_key == key)
      if (length(idx) == 1) {
        DT::selectRows(events_proxy, idx)
      } else {
        showNotification(
          "That event is outside the current sidebar filters -- widen Catchment/Site/Date/Species to find it here.",
          type = "warning"
        )
      }
    }, ignoreInit = TRUE)

    selected_event <- reactive({
      idx <- input$events_table_rows_selected
      df <- combined_events_df()
      if (is.null(idx) || nrow(df) == 0) return(NULL)
      df[idx, ]
    })

    # Live-only id, NULL for a historical selection -- every write-capable
    # observer below (fish edit/add/hide) gates on this exactly as it did
    # before historical events existed, so none of that logic needed to
    # change.
    selected_event_id <- reactive({
      ev <- selected_event()
      if (is.null(ev) || ev$source != "live") return(NULL)
      ev$native_id
    })

    output$detail_panel <- renderUI({
      ev <- selected_event()
      if (is.null(ev)) {
        return(empty_state("Select an event above to view its details."))
      }
      if (ev$source == "live") {
        tabsetPanel(
          tabPanel("Summary", uiOutput(ns("summary_panel"))),
          tabPanel("Site Details", uiOutput(ns("site_details"))),
          tabPanel("Fish Records",
            DT::dataTableOutput(ns("fish_table")),
            br(),
            actionButton(ns("add_fish"), "Add fish"),
            actionButton(ns("hide_fish"), "Hide selected row", class = "btn-outline-danger")
          ),
          tabPanel("Photos", uiOutput(ns("photo_gallery")))
        )
      } else {
        tagList(
          div(class = "alert alert-secondary mt-2",
              "This is a historical (SFCC archive) record migrated from the legacy Rockpool database. It's read-only -- editing, project tagging, and photos aren't available for archive events."),
          tabsetPanel(
            tabPanel("Summary", uiOutput(ns("summary_panel"))),
            tabPanel("Site Details", uiOutput(ns("site_details"))),
            tabPanel("Fish Records", uiOutput(ns("fish_table_historical_wrap"))),
            tabPanel("Photos", uiOutput(ns("photo_gallery")))
          )
        )
      }
    })

    ## -- Summary sub-tab (both sources) ------------------------------------

    output$summary_panel <- renderUI({
      ev <- selected_event()
      req(ev)
      if (ev$source == "live") {
        fish_df <- fish_for_events(pool, ev$native_id)
        runs_df <- runs_for_events(pool, ev$native_id)
        dep <- build_depletion_table(fish_df, runs_df)
        tagList(
          bslib::layout_column_wrap(
            width = 1 / 3,
            bslib::value_box(title = "Total fish caught", value = as.character(sum(fish_df$fish_multiplier, na.rm = TRUE)), theme = "primary"),
            bslib::value_box(title = "Species x lifestage groups", value = as.character(nrow(dep)), theme = "secondary"),
            bslib::value_box(title = "Passes", value = as.character(dplyr::n_distinct(fish_df$pass_no)), theme = "bg-light")
          ),
          if (nrow(dep) > 0) {
            DT::datatable(
              dep |> dplyr::transmute(
                Species = species_label, Lifestage = lifestage_label, Catch = total_catch,
                `N est` = round(n_est, 1), `N se` = round(n_se, 1),
                `Density (fish/100m²)` = round(density_per_100m2, 1)
              ),
              rownames = FALSE, options = list(dom = "t")
            )
          } else {
            empty_state("No fish records to summarise.")
          },
          if (nrow(fish_df) > 0) plotOutput(ns("summary_length_freq"), height = "300px")
        )
      } else {
        fish_df <- historical_fish_for_event(pool, ev$native_id)
        density_df <- historical_density_for_event(pool, ev$native_id)
        run_counts_df <- historical_run_counts_for_event(pool, ev$native_id)
        has_fish <- nrow(fish_df) > 0
        tagList(
          bslib::layout_column_wrap(
            width = 1 / 3,
            bslib::value_box(title = "Individual fish records", value = if (has_fish) as.character(nrow(fish_df)) else "None", theme = "primary"),
            bslib::value_box(title = "Data available", value = if (has_fish) "Per-fish (SFCC export)" else "Aggregate counts only", theme = "secondary"),
            bslib::value_box(title = "SFCC density estimates", value = as.character(nrow(density_df)), theme = "bg-light")
          ),
          if (nrow(density_df) > 0) {
            tagList(
              h5("SFCC's own Zippin / Carle-Strub estimates"),
              DT::datatable(
                density_df |> dplyr::transmute(
                  Species = label_species(species), `Age class` = age_class,
                  Zippin = round(zippin_estimate, 1), `Carle-Strub` = round(carle_strub_estimate, 1),
                  `Avg length (mm)` = average_length_mm
                ),
                rownames = FALSE, options = list(dom = "t")
              )
            )
          },
          if (has_fish) {
            plotOutput(ns("summary_length_freq"), height = "300px")
          } else if (nrow(run_counts_df) > 0) {
            tagList(
              h5("Aggregate catch counts (no individual fish data for this event)"),
              DT::datatable(
                run_counts_df |> dplyr::transmute(Species = label_species(species), `Age class` = age_class, Run = run_no, Count = count),
                rownames = FALSE, options = list(dom = "t")
              )
            )
          } else {
            empty_state("No catch data available for this historical event.")
          }
        )
      }
    })

    output$summary_length_freq <- renderPlot({
      ev <- selected_event()
      req(ev)
      fish_df <- if (ev$source == "live") fish_for_events(pool, ev$native_id) else historical_fish_for_event(pool, ev$native_id)
      validate(need(nrow(fish_df) > 0 && any(!is.na(fish_df$length_mm)), "No length data to plot."))
      plot_df <- fish_df |> dplyr::mutate(species_label = label_species(species))
      ggplot2::ggplot(plot_df, ggplot2::aes(x = length_mm, fill = species_label)) +
        ggplot2::geom_histogram(binwidth = 5, position = "identity", alpha = 0.6) +
        ggplot2::labs(x = "Length (mm)", y = "Count", fill = "Species") +
        ggplot2::theme_minimal()
    })

    ## -- Site Details sub-tab (both sources) --------------------------------

    output$site_details <- renderUI({
      ev <- selected_event()
      req(ev)
      if (ev$source == "live") {
        row <- event_full_detail(pool, ev$native_id)
        validate(need(nrow(row) > 0, "Event not found."))
        render_event_detail(row)
      } else {
        row <- historical_event_full_detail(pool, ev$native_id)
        validate(need(nrow(row) > 0, "Event not found."))
        render_historical_event_detail(row)
      }
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
      ev <- selected_event()
      req(ev, ev$source == "historical")
      fish_n <- nrow(historical_fish_for_event(pool, ev$native_id))
      run_n <- nrow(historical_run_counts_for_event(pool, ev$native_id))
      if (fish_n == 0 && run_n == 0) {
        return(empty_state("No fish or catch-count data available for this historical event."))
      }
      DT::dataTableOutput(ns("fish_table_historical"))
    })

    output$fish_table_historical <- DT::renderDataTable({
      ev <- selected_event()
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
      ev <- selected_event()
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
  })
}
