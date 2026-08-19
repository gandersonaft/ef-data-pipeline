# Tab: Projects. Currently HIDDEN from the nav (see ui.R, 2026-08-19 --
# "not really useful at present," being rethought) -- this file is left
# intact, just unreachable, so it can come back without a rebuild.
#
# Density & Trends and Length-Frequency were deleted outright (not just
# hidden) in the same pass -- their content moved into Survey Detail's
# per-site view (mini density table + length-frequency chart per record,
# see mod_survey_detail.R) rather than staying as filtered aggregate views
# here. mod_depletion.R/mod_trends.R/mod_length_condition.R still exist,
# just unused by this file now.
#
# Overview/QC Review/Project Tagging/NEPS Tool Export-Import are otherwise
# unchanged, still live-only, deliberately: pooling historical (SFCC
# archive) catches into these aggregate Carle-Strub/density views has real
# statistical implications (different eras/methodologies) that deserve a
# deliberate decision, not a default -- see fn_unified_queries.R's header
# comment. Historical data is browsable via Site Map and Survey Detail
# instead.
#
# NOTE for whoever re-enables this tab: mod_qc_review_server()'s
# go_to_survey_detail() call below still passes an event key
# ("live-<event_id>"), but Survey Detail's picker is now site-first (see
# mod_survey_detail.R) and go_to_survey_detail()/jump_to_site in server.R
# now expects a normalized site_code, not an event key -- QC Review's
# drill-down needs updating to match before this tab comes back, not just
# re-adding the nav_panel line in ui.R.

mod_projects_ui <- function(id) {
  ns <- NS(id)
  tabsetPanel(
    tabPanel("Overview", uiOutput(ns("overview_panel"))),
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

    mod_qc_review_server("qc_review", pool, go_to_survey_detail)
    mod_project_tagging_server("project_tagging", filtered_events, pool, pool_editor)
    mod_neps_tool_server("neps_tool", filtered_events, pool, pool_editor)
  })
}
