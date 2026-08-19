# Tab: Projects. Cumulative/aggregate view -- consolidates the six sub-tabs
# from the app's original flat 8-tab layout (Overview is new; Density &
# Trends merges the old Depletion & Density + Trends & Reports tabs behind a
# table/chart toggle; the rest are the same modules as before, just nested).
# Live-only, deliberately: pooling historical (SFCC archive) catches into
# these aggregate Carle-Strub/density views has real statistical implications
# (different eras/methodologies) that deserve a deliberate decision, not a
# default -- see fn_unified_queries.R's header comment. Historical data is
# browsable via Site Map and Survey Detail instead.
#
# Reuses the existing mod_depletion.R/mod_trends.R/mod_length_condition.R/
# mod_qc_review.R/mod_project_tagging.R/mod_neps_tool.R modules unmodified
# (aside from mod_qc_review.R's gallery removal, see that file) -- nested
# Shiny modules pick up the right namespace automatically as long as the
# child module's _server() is called from inside the parent's moduleServer().

mod_projects_ui <- function(id) {
  ns <- NS(id)
  tabsetPanel(
    tabPanel("Overview", uiOutput(ns("overview_panel"))),
    tabPanel("Density & Trends",
      radioButtons(ns("dt_view"), NULL, choices = c("Table" = "table", "Chart" = "chart"), inline = TRUE),
      conditionalPanel(sprintf("input['%s'] == 'table'", ns("dt_view")), mod_depletion_ui(ns("depletion"))),
      conditionalPanel(sprintf("input['%s'] == 'chart'", ns("dt_view")), mod_trends_ui(ns("trends")))
    ),
    tabPanel("Length-Frequency", mod_length_condition_ui(ns("length_condition"))),
    tabPanel("QC Review", mod_qc_review_ui(ns("qc_review"))),
    tabPanel("Project Tagging", mod_project_tagging_ui(ns("project_tagging"))),
    tabPanel("NEPS Tool Export/Import", mod_neps_tool_ui(ns("neps_tool")))
  )
}

mod_projects_server <- function(id, filtered_events, pool, pool_editor, go_to_survey_detail) {
  moduleServer(id, function(input, output, session) {
    output$overview_panel <- renderUI({
      event_ids <- filtered_events()
      fish_df <- fish_for_events(pool, event_ids)
      projects_df <- distinct_projects(pool)
      bslib::layout_column_wrap(
        width = 1 / 4,
        bslib::value_box(title = "Events (filtered)", value = as.character(length(event_ids)), theme = "primary"),
        bslib::value_box(title = "Fish caught (filtered)", value = as.character(sum(fish_df$fish_multiplier, na.rm = TRUE)), theme = "secondary"),
        bslib::value_box(title = "Sites (filtered)", value = as.character(dplyr::n_distinct(fish_df$site_code)), theme = "bg-light"),
        bslib::value_box(title = "Projects tagged", value = as.character(nrow(projects_df)), theme = "bg-light")
      )
    })
    outputOptions(output, "overview_panel", suspendWhenHidden = FALSE)

    mod_depletion_server("depletion", filtered_events, pool)
    mod_trends_server("trends", filtered_events, pool)
    mod_length_condition_server("length_condition", filtered_events, pool)
    mod_qc_review_server("qc_review", pool, go_to_survey_detail)
    mod_project_tagging_server("project_tagging", filtered_events, pool, pool_editor)
    mod_neps_tool_server("neps_tool", filtered_events, pool, pool_editor)
  })
}
