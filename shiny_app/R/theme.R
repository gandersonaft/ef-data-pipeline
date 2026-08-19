# Approved palette from mockups/dashboard-restructure-v4.html (light-mode
# values only -- the mockup also has a dark-mode pair, deliberately not
# wired up here to keep this pass scoped to the layout/IA restructure, not
# a light/dark toggle). Deep teal primary, moss-green secondary accent,
# amber reserved strictly for QC-flag/alert states so "flagged" reads
# consistently everywhere it appears.

ef_theme <- bslib::bs_theme(
  version = 5,
  bg = "#F3F7F4",
  fg = "#16241F",
  primary = "#1C6E76",
  secondary = "#5C8A48",
  warning = "#B06B1B",
  base_font = bslib::font_google("Inter"),
  "border-color" = "#D5E2DA"
)
