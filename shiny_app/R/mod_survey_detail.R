# Tab: Survey Detail. Pick a survey event (any qc_status -- unlike the QC
# tab's flagged-only picker), then see/edit everything about it: full site
# details (every field captured on the form, displayed read-only, grouped by
# the form's own section headings), editable fish records across all passes,
# and its photo gallery (reusing mod_qc_review.R's pattern, now reachable
# for any event, not just flagged ones).
#
# Timestamp-only audit (updated_at) -- no reviewer identity or audit log yet
# (tech-demo phase; see fn_db_writes.R header comment for why this isn't a
# blocker). "Delete" is a soft delete (deleted_at) -- labelled "Hide" in the
# UI, not "Delete", so that's not misleading.

#' @param row A single-row tibble from event_full_detail().
render_event_detail <- function(row) {
  kv <- function(label, value) {
    if (is.null(value) || length(value) == 0 || is.na(value)) value <- "—"
    tags$div(
      class = "row mb-1",
      tags$div(class = "col-5 col-md-4 text-muted", label),
      tags$div(class = "col-7 col-md-8", as.character(value))
    )
  }
  section <- function(title, ...) {
    tagList(h5(title, class = "mt-3"), ...)
  }

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
    div(id = picker_id, DT::dataTableOutput(ns("events_table"))),
    hr(),
    uiOutput(ns("detail_panel"))
  )
}

mod_survey_detail_server <- function(id, filtered_events, pool, pool_editor) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns

    events_df <- reactive({ events_browser(pool, filtered_events()) })

    output$events_table <- DT::renderDataTable({
      df <- events_df()
      validate(need(nrow(df) > 0, "No events match the current filters."))
      df |>
        dplyr::transmute(
          event_id, Site = site_code, Catchment = humanize_slug(catchment),
          Date = format(survey_date, "%Y-%m-%d"), Project = dplyr::coalesce(project_code, "—"),
          QC = qc_status
        ) |>
        DT::datatable(
          rownames = FALSE, selection = "single",
          options = list(pageLength = 10, columnDefs = list(list(visible = FALSE, targets = 0)))
        )
    })
    outputOptions(output, "events_table", suspendWhenHidden = FALSE)

    selected_event_id <- reactive({
      idx <- input$events_table_rows_selected
      df <- events_df()
      if (is.null(idx) || nrow(df) == 0) return(NULL)
      df$event_id[idx]
    })

    output$detail_panel <- renderUI({
      event_id <- selected_event_id()
      if (is.null(event_id)) {
        return(empty_state("Select an event above to view its details."))
      }
      tabsetPanel(
        tabPanel("Site Details", uiOutput(ns("site_details"))),
        tabPanel("Fish Records",
          DT::dataTableOutput(ns("fish_table")),
          br(),
          actionButton(ns("add_fish"), "Add fish"),
          actionButton(ns("hide_fish"), "Hide selected row", class = "btn-outline-danger")
        ),
        tabPanel("Photos", uiOutput(ns("photo_gallery")))
      )
    })

    output$site_details <- renderUI({
      event_id <- selected_event_id()
      req(event_id)
      row <- event_full_detail(pool, event_id)
      validate(need(nrow(row) > 0, "Event not found."))
      render_event_detail(row)
    })

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

    output$photo_gallery <- renderUI({
      event_id <- selected_event_id()
      req(event_id)
      photos <- site_photos_for_event(pool, event_id)
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
