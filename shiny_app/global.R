# Loaded once when the app starts (both interactively and on Posit Connect /
# shinyapps.io). Sets up the DB connection pool and sources the modules.

library(shiny)
library(bslib)
library(pool)
library(RPostgres)
library(dplyr)
library(dbplyr)
library(DT)
library(ggplot2)
library(FSA)
library(glue)
library(httr2)
library(tidyr)
library(purrr)
library(leaflet)
# jsonlite is deliberately NOT attached with library() -- it masks
# shiny::validate() with jsonlite::validate(), silently breaking every
# empty-state validate(need(...)) call in the mod_*.R files. Used namespaced
# (jsonlite::fromJSON) in R/mod_qc_review.R instead.

# Read-only shiny_reader role (see supabase/roles.sql). Use Supabase's
# Supavisor SESSION-mode pooler (port 5432), not the direct host (IPv6-only,
# most hosting has no IPv6 egress) and not transaction mode (port 6543,
# doesn't support everything a persistent app session needs) -- see
# .Renviron.example and the main README for the full story. The port default
# below matches that decision so a missing SUPABASE_DB_PORT fails toward the
# right pooler mode instead of silently landing on the wrong one.
db_pool <- pool::dbPool(
  drv = RPostgres::Postgres(),
  host = Sys.getenv("SUPABASE_DB_HOST"),
  port = as.integer(Sys.getenv("SUPABASE_DB_PORT", "5432")),
  dbname = Sys.getenv("SUPABASE_DB_NAME", "postgres"),
  user = Sys.getenv("SUPABASE_DB_USER", "shiny_reader"),
  password = Sys.getenv("SUPABASE_DB_PASSWORD"),
  sslmode = "require"
)

onStop(function() {
  pool::poolClose(db_pool)
})

source("R/utils.R")
source("R/fn_db_queries.R")
source("R/fn_depletion.R")
source("R/mod_depletion.R")
source("R/mod_length_condition.R")
source("R/mod_qc_review.R")
source("R/mod_site_map.R")
