# Deploy to shinyapps.io / Posit Connect.
#
# .Renviron is NOT uploaded as part of the deployment bundle -- DB and
# Supabase credentials must be set separately via the target platform's own
# environment-variable configuration UI (shinyapps.io: Application Settings ->
# Environment Variables; Posit Connect: the app's Vars pane), using the same
# variable names as .Renviron.example.

library(rsconnect)

rsconnect::setAccountInfo(
  name = Sys.getenv("SHINYAPPS_ACCOUNT"),
  token = Sys.getenv("SHINYAPPS_TOKEN"),
  secret = Sys.getenv("SHINYAPPS_SECRET")
)

rsconnect::deployApp(
  appDir = ".",
  appName = "ef-neps-dashboard",
  forceUpdate = TRUE
)
