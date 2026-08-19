# One-off loader: OS Open Rivers (WatercourseLink.shp) -> river_network
# (migration 0003_river_network.sql -- run that migration first).
#
# Source: C:\Users\graem\OneDrive - Argyll Fisheries Trust\sfcc aft export\
#         dig riv network\WatercourseLink.shp
# Open Government Licence -- free to use/redistribute with attribution. This
# is deliberately NOT the AFT_CEH network in the same folder, which is
# separately licensed and must never be loaded anywhere (see migration
# 0003's header comment and the plan addendum "River Network Map Overlay").
#
# Clipped to the AFT_CEH network's own extent (+5km buffer, so lines near
# the edge of AFT's area aren't visibly truncated right where a border site
# sits) and simplified (ST_SimplifyPreserveTopology, 30m tolerance -- picked
# because it's imperceptible at the regional/catchment zoom levels Site Map
# is actually used at, and roughly halves the rendered GeoJSON payload).
# Idempotent: deletes and reloads the full table each run (same pattern as
# historical_fish in migrate_sfcc_historical.py) -- no natural per-row dedup
# key finer than os_identifier, and this is a rarely-rerun batch load, not
# part of any live pipeline.
#
# Usage:
#   DATABASE_URL=postgresql://webhook_writer.<ref>:<pw>@<host>:5432/postgres \
#       Rscript scripts/load_river_network.R

suppressMessages({
  library(sf)
  library(DBI)
  library(RPostgres)
})

SHAPEFILE_PATH <- r"(C:\Users\graem\OneDrive - Argyll Fisheries Trust\sfcc aft export\dig riv network\WatercourseLink.shp)"

# AFT_CEH network's own bounding box (EPSG:27700), confirmed via
# sf::st_bbox(st_read("AFT_CEH/ceh05_aft.shp")) -- kept as a literal here
# rather than re-reading that (separately licensed) shapefile at load time,
# since only its extent, not its content, is needed.
CEH_BBOX <- c(xmin = 93842.0, ymin = 605894.5, xmax = 242629.0, ymax = 763496.3)
BUFFER_M <- 5000
SIMPLIFY_TOLERANCE_M <- 30

parse_database_url <- function(url) {
  # postgresql://user:password@host:port/dbname
  m <- regmatches(url, regexec("^postgres(?:ql)?://([^:]+):([^@]+)@([^:/]+):(\\d+)/(.+)$", url))[[1]]
  if (length(m) != 6) stop("DATABASE_URL doesn't match postgresql://user:password@host:port/dbname")
  list(user = m[2], password = m[3], host = m[4], port = as.integer(m[5]), dbname = m[6])
}

main <- function() {
  db_url <- Sys.getenv("DATABASE_URL")
  if (identical(db_url, "")) stop("Set DATABASE_URL (webhook_writer connection string) -- see this file's header comment.")
  conn_info <- parse_database_url(db_url)

  cat("Reading", SHAPEFILE_PATH, "...\n")
  os_rivers <- st_read(SHAPEFILE_PATH, quiet = TRUE)
  cat("  ", nrow(os_rivers), "features nationally\n")

  # unname() each value before re-combining under a new name -- c(xmin =
  # named_vec["xmin"]) silently produces the name "xmin.xmin" (R pastes the
  # outer and inner names together), not "xmin", which breaks st_bbox()'s
  # name-based lookup downstream (confirmed: manifested as a cryptic
  # "!anyNA(x) is not TRUE" deep in sf's internals).
  bbox <- st_bbox(
    c(xmin = unname(CEH_BBOX["xmin"]) - BUFFER_M, ymin = unname(CEH_BBOX["ymin"]) - BUFFER_M,
      xmax = unname(CEH_BBOX["xmax"]) + BUFFER_M, ymax = unname(CEH_BBOX["ymax"]) + BUFFER_M),
    crs = st_crs(os_rivers)
  )
  clipped <- suppressWarnings(st_crop(os_rivers, bbox))
  cat("  ", nrow(clipped), "features after clipping to AFT_CEH extent +", BUFFER_M, "m buffer\n")

  simplified <- st_simplify(clipped, dTolerance = SIMPLIFY_TOLERANCE_M)
  # A handful of features can collapse to empty/non-LINESTRING geometry under
  # simplification (very short segments) -- drop them, they're not visually
  # meaningful at this tolerance anyway.
  simplified <- simplified[!st_is_empty(simplified), ]
  simplified <- simplified[st_geometry_type(simplified) == "LINESTRING", ]
  cat("  ", nrow(simplified), "features after simplification (", SIMPLIFY_TOLERANCE_M, "m tolerance)\n")

  con <- dbConnect(
    RPostgres::Postgres(), host = conn_info$host, port = conn_info$port,
    dbname = conn_info$dbname, user = conn_info$user, password = conn_info$password,
    sslmode = "require"
  )
  on.exit(dbDisconnect(con))

  dbExecute(con, "delete from river_network")

  wkt <- st_as_text(st_geometry(simplified))
  insert_sql <- "
    insert into river_network (os_identifier, name1, name2, form, flow, fictitious, length_m, geom_27700)
    values ($1, $2, $3, $4, $5, $6, $7, ST_GeomFromText($8, 27700))
    on conflict (os_identifier) do nothing
  "
  df <- st_drop_geometry(simplified)
  dbBegin(con)
  for (i in seq_len(nrow(simplified))) {
    dbExecute(con, insert_sql, params = list(
      df$identifier[i], df$name1[i], df$name2[i], df$form[i], df$flow[i],
      as.logical(df$fictitious[i] == "true"), as.numeric(df$length[i]), wkt[i]
    ))
  }
  dbCommit(con)

  # count(*) comes back as bit64::integer64 -- printing it directly via cat()
  # doesn't dispatch to bit64's own print method and silently reinterprets
  # the 64-bit bit pattern as a double (same recurring bug class documented
  # elsewhere in this app, e.g. fn_db_queries.R's event_id handling).
  n <- as.integer(dbGetQuery(con, "select count(*) as n from river_network")$n)
  cat("Loaded", n, "rows into river_network.\n")
}

main()
