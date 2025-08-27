#!/usr/bin/env Rscript
# wipe_omop_iris.R — IRIS "Nuke & Pave" for my-iris
# Drops ALL views/ALL FKs/ALL tables in CDM + RESULTS; then (optionally) busts WebAPI caches
# NOTE: This removes tables — you'll need to recreate CDM/RESULTS DDL afterwards (e.g., via CommonDataModel/Achilles).

local({

suppressPackageStartupMessages({
  if (!requireNamespace("DatabaseConnector", quietly = TRUE)) install.packages("DatabaseConnector")
  if (!requireNamespace("RPostgres", quietly = TRUE)) install.packages("RPostgres")
  library(DatabaseConnector); library(DBI); library(RPostgres)
})

# ========= Parameters (safe defaults per your environment) =========
irisServer       <- get0("irisServer",       ifnotfound = "host.docker.internal")
irisPort         <- get0("irisPort",         ifnotfound = 1972L)
irisNamespace    <- get0("irisNamespace",    ifnotfound = "USER")
irisUser         <- get0("irisUser",         ifnotfound = "_SYSTEM")
irisPassword     <- get0("irisPassword",     ifnotfound = "_SYSTEM")
jdbcDriverFolder <- get0("jdbcDriverFolder", ifnotfound = "/opt/hades/jdbc_drivers")

cdmSchema        <- get0("cdmSchema",        ifnotfound = "OMOPCDM53")
resultsSchema    <- get0("resultsSchema",    ifnotfound = "OMOPCDM55_RESULTS")

# WebAPI (Postgres) cache-bust defaults
bustCache     <- isTRUE(get0("bustCache", ifnotfound = TRUE))
pgHost        <- get0("pgHost",        ifnotfound = "broadsea-atlasdb")
pgPort        <- get0("pgPort",        ifnotfound = 5432L)
pgDatabase    <- get0("pgDatabase",    ifnotfound = "postgres")
pgUser        <- get0("pgUser",        ifnotfound = "postgres")
pgPassword    <- get0("pgPassword",    ifnotfound = "mypass")
atlasSourceId <- get0("atlasSourceId", ifnotfound = 2L)

qname <- function(schema, name) sprintf('"%s"."%s"', schema, name)

# ========= Connect to IRIS =========
message("Connecting to IRIS …")
details <- DatabaseConnector::createConnectionDetails(
  dbms             = "iris",
  connectionString = sprintf("jdbc:IRIS://%s:%s/%s", irisServer, as.integer(irisPort), irisNamespace),
  user             = irisUser,
  password         = irisPassword,
  pathToDriver     = jdbcDriverFolder
)
conn <- DatabaseConnector::connect(details)
on.exit(try(DatabaseConnector::disconnect(conn), silent = TRUE), add = TRUE)

# ========= Helpers =========
exec_sql  <- function(sql) DatabaseConnector::executeSql(conn, sql)
query_sql <- function(sql) DatabaseConnector::querySql(conn, sql)

schema_exists <- function(schema) {
  out <- query_sql(sprintf("
    SELECT COUNT(*) AS N
    FROM INFORMATION_SCHEMA.SCHEMATA
    WHERE UPPER(SCHEMA_NAME)=UPPER('%s');", schema))
  isTRUE(as.integer(out$N[1]) > 0L)
}

list_tables <- function(schema) {
  if (!schema_exists(schema)) return(character(0))
  out <- query_sql(sprintf("
    SELECT TABLE_NAME
    FROM INFORMATION_SCHEMA.TABLES
    WHERE UPPER(TABLE_SCHEMA)=UPPER('%s') AND TABLE_TYPE IN ('BASE TABLE','TABLE')
    ORDER BY TABLE_NAME;", schema))
  if (nrow(out)) out$TABLE_NAME else character(0)
}

list_views <- function(schema) {
  if (!schema_exists(schema)) return(character(0))
  out <- query_sql(sprintf("
    SELECT TABLE_NAME AS VIEW_NAME
    FROM INFORMATION_SCHEMA.TABLES
    WHERE UPPER(TABLE_SCHEMA)=UPPER('%s') AND TABLE_TYPE='VIEW'
    ORDER BY TABLE_NAME;", schema))
  if (nrow(out)) out$VIEW_NAME else character(0)
}

# FK list via TABLE_CONSTRAINTS + REFERENTIAL_CONSTRAINTS
list_fks <- function(schema) {
  if (!schema_exists(schema)) return(data.frame())
  query_sql(sprintf("
    SELECT tc.CONSTRAINT_NAME, tc.TABLE_NAME
    FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
    JOIN INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS rc
      ON rc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
     AND rc.CONSTRAINT_NAME   = tc.CONSTRAINT_NAME
    WHERE UPPER(tc.CONSTRAINT_SCHEMA)=UPPER('%s')
      AND tc.CONSTRAINT_TYPE='FOREIGN KEY'
    ORDER BY tc.TABLE_NAME, tc.CONSTRAINT_NAME;", schema))
}

drop_all_in_schema <- function(schema) {
  if (!schema_exists(schema)) {
    message("Schema ", schema, " does not exist; skipping.")
    return(invisible())
  }

  # 1) Drop views first
  message(">>> Dropping ALL views in ", schema)
  views <- list_views(schema)
  if (length(views)) {
    for (v in views) {
      stmt <- sprintf("DROP VIEW %s;", qname(schema, v))
      message("DROP VIEW: ", qname(schema, v))
      try(exec_sql(stmt), silent = TRUE)
    }
  } else message("No views found in ", schema)

  # 2) Drop all FKs
  message(">>> Dropping ALL foreign keys in ", schema)
  fks <- list_fks(schema)
  if (nrow(fks)) {
    for (i in seq_len(nrow(fks))) {
      cn <- fks$CONSTRAINT_NAME[i]; tn <- fks$TABLE_NAME[i]
      stmt <- sprintf('ALTER TABLE %s DROP CONSTRAINT "%s";', qname(schema, tn), cn)
      message("DROP FK: ", cn, " on ", tn)
      try(exec_sql(stmt), silent = TRUE)
    }
  } else message("No foreign keys found in ", schema)

  # 3) Drop all base tables
  message(">>> Dropping ALL tables in ", schema)
  tabs <- list_tables(schema)
  if (length(tabs)) {
    for (t in tabs) {
      stmt <- sprintf("DROP TABLE %s;", qname(schema, t))
      message("DROP TABLE: ", qname(schema, t))
      try(exec_sql(stmt), silent = FALSE)
    }
  } else message("No tables found in ", schema)

  # 4) Re-materialize empty schema marker (optional)
  try(exec_sql(sprintf('CREATE TABLE %s ("x" INT);', qname(schema, "__SCHEMA_PING"))), silent=TRUE)
  try(exec_sql(sprintf('DROP TABLE %s;', qname(schema, "__SCHEMA_PING"))), silent=TRUE)

  # 5) Assert zero base tables
  n <- query_sql(sprintf("
    SELECT COUNT(*) AS N
    FROM INFORMATION_SCHEMA.TABLES
    WHERE UPPER(TABLE_SCHEMA)=UPPER('%s') AND TABLE_TYPE IN ('BASE TABLE','TABLE');", schema))$N[1]
  if (as.integer(n) != 0) stop(sprintf("Schema %s still has %s base tables", schema, n))
}

# ========= Execute wipes =========
message("=== Wipe starting ===")
drop_all_in_schema(cdmSchema)
drop_all_in_schema(resultsSchema)
message(">>> Wipe complete: ", cdmSchema, " and ", resultsSchema, " contain 0 tables.")

# ========= Optional: WebAPI cache-bust =========
if (isTRUE(bustCache)) {
  message("Clearing WebAPI caches (source_id=", atlasSourceId, ") via Postgres …")
  try({
    pg <- DBI::dbConnect(RPostgres::Postgres(),
                         host=pgHost, port=as.integer(pgPort),
                         dbname=pgDatabase, user=pgUser, password=pgPassword)
    DBI::dbExecute(pg, paste0("DELETE FROM webapi.achilles_cache WHERE source_id = ", atlasSourceId))
    DBI::dbExecute(pg, paste0("DELETE FROM webapi.cdm_cache      WHERE source_id = ", atlasSourceId))
    DBI::dbDisconnect(pg)
    message("WebAPI caches cleared.")
  }, silent = TRUE)
} else {
  message("bustCache = FALSE; skipping WebAPI cache clear.")
}

message("=== Done. You can now recreate CDM/RESULTS DDL and reseed. ===")

}) # end local()
