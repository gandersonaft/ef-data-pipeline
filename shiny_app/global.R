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
# jsonlite is deliberately NOT attached with library() -- it masks
# shiny::validate() with jsonlite::validate(), silently breaking every
# empty-state validate(need(...)) call in the mod_*.R files. Used namespaced
# (jsonlite::fromJSON) in R/mod_qc_review.R instead.

# Read-only shiny_reader role (see supabase/roles.sql). Use Supabase's pooled
# transaction-mode endpoint (port 6543), not the direct port (5432) -- shinyapps.io
# does not handle many concurrent long-lived direct connections well.
db_pool <- pool::dbPool(
  drv = RPostgres::Postgres(),
  host = Sys.getenv("SUPABASE_DB_HOST"),
  port = as.integer(Sys.getenv("SUPABASE_DB_PORT", "6543")),
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
