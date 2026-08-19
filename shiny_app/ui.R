ui <- bslib::page_navbar(
  id = "main_nav",
  title = "EF database frontend beta",
  theme = ef_theme,
  sidebar = bslib::sidebar(
    title = "Filters",
    selectInput("catchment", "Catchment", choices = NULL, multiple = TRUE),
    selectInput("site_code", "Site", choices = NULL, multiple = TRUE),
    dateRangeInput(
      "date_range", "Survey date range",
      # Wide default covering all realistic survey dates, not start/end = NA:
      # NA silently fails Shiny's date coercion and falls back to today for
      # both ends, which filters out every real (necessarily past-dated)
      # survey on first load -- confirmed 2026-08-18 against real data.
      start = "2000-01-01", end = Sys.Date() + 1
    ),
    checkboxGroupInput(
      "species", "Species",
      choices = setNames(names(species_labels), species_labels),
      selected = c("sal", "trt")
    ),
    actionButton("reset_filters", "Reset filters")
  ),
  # Projects tab hidden 2026-08-19 -- user says it's "not really useful at
  # present," rethinking how to display that data. mod_projects.R and its
  # sub-modules are left intact (Overview/QC Review/Project Tagging/NEPS
  # Tool), just not wired into the nav -- re-add the line below to bring it
  # back. Density & Trends / Length-Frequency were deleted outright from
  # mod_projects.R, not just hidden -- their content moved into Survey
  # Detail's per-site view instead.
  # bslib::nav_panel("Projects", mod_projects_ui("projects")),
  bslib::nav_panel("Survey Detail", mod_survey_detail_ui("survey_detail")),
  bslib::nav_panel("Site Map", mod_site_map_ui("site_map")),
  header = tags$head(
    tags$link(rel = "stylesheet", type = "text/css", href = "styles.css"),
    # Confirmed 2026-08-18: a DT output inside a bslib::nav_panel that isn't
    # the initially-active tab never renders, even with
    # outputOptions(suspendWhenHidden = FALSE) (see mod_*.R) -- the server
    # computes and sends the real htmlwidget value (confirmed via server-
    # side logging), but the container is left holding only Shiny's
    # placeholder ("&nbsp;"), with zero <table> markup ever inserted, even
    # after the tab is clicked. This isn't a DataTables column-width problem
    # (columns.adjust() on shown.bs.tab did not help, because there is no
    # table to adjust) -- it's that the htmlwidget's client-side binding
    # never actually applied the value while its container was hidden, and
    # nothing re-triggers that application on becoming visible. Force it by
    # having Shiny fully re-bind the newly-shown pane's outputs, which
    # re-requests and re-applies their current values from scratch.
    #
    # ONE TIME per pane only (efInitialized flag) -- confirmed 2026-08-19:
    # doing this on EVERY shown.bs.tab (including revisits, e.g. Site Map ->
    # Survey Detail -> Site Map) destroys and recreates each DT widget from
    # scratch, silently losing its row selection (selecting a site, checking
    # Site Map, then coming back to Survey Detail reset the site picker).
    # The underlying problem only ever needs fixing the FIRST time a pane
    # becomes visible; once a widget has bound correctly once, Bootstrap's
    # own show/hide (a plain CSS toggle, not a DOM removal) doesn't disturb
    # it again.
    #
    # invalidateSize(), below, is the opposite case -- it DOES need to run
    # every visit, not just once. Confirmed 2026-08-19 (added the
    # per-record mini-map on Survey Detail's Site Details sub-tab): with
    # two leaflet map instances now on the page, whichever one wasn't
    # visible at its own initial render can end up permanently stuck at a
    # 0x0 viewport (SVG viewBox '... 0 0') -- Leaflet caches its
    # container's pixel size at construction time and doesn't re-measure
    # on its own just because the container became visible again.
    tags$script(HTML(
      "document.addEventListener('shown.bs.tab', function(e) {
         var targetSel = e.target.getAttribute('href') || e.target.getAttribute('data-bs-target');
         if (!targetSel) return;
         var pane = document.querySelector(targetSel);
         if (!pane || !window.Shiny) return;

         if (!pane.dataset.efInitialized) {
           pane.dataset.efInitialized = '1';
           Shiny.unbindAll(pane);
           Shiny.bindAll(pane);
         }

         // setTimeout(...,0) lets the pane's own display/layout actually
         // apply first -- invalidating synchronously (while still
         // mid-transition) sometimes measures the old, hidden size.
         pane.querySelectorAll('.leaflet-container').forEach(function(el) {
           var widget = window.HTMLWidgets && window.HTMLWidgets.find('#' + el.id);
           if (widget && widget.getMap) {
             setTimeout(function() { widget.getMap().invalidateSize(); }, 0);
           }
         });
       });"
    ))
  )
)
