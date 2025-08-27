#!/usr/bin/env Rscript
# test.R — original working pipeline, wrapped + explicit IRIS connectionString

local({

suppressPackageStartupMessages({
  if (!requireNamespace("remotes", quietly = TRUE)) install.packages("remotes")
  if (!requireNamespace("DatabaseConnector", quietly = TRUE)) install.packages("DatabaseConnector")
  if (!requireNamespace("SqlRender", quietly = TRUE)) remotes::install_github("OHDSI/SqlRender")
  if (!requireNamespace("Achilles", quietly = TRUE))  remotes::install_github("OHDSI/Achilles")
  if (!requireNamespace("Eunomia", quietly = TRUE))   remotes::install_github("OHDSI/Eunomia")
  if (!requireNamespace("RPostgres", quietly = TRUE)) install.packages("RPostgres")
  library(DatabaseConnector); library(SqlRender); library(Achilles); library(Eunomia)
  library(DBI); library(RPostgres)
})
options(rstudio.connectionObserver.errorsSuppressed = TRUE)

# ----- helpers to read params from calling env (or defaults) -----
get0nz <- function(nm, default = NULL) {
  v <- get0(nm, inherits = TRUE, ifnotfound = default)
  if (is.null(v)) return(default)
  s <- as.character(v); if (!nzchar(s)) return(default); v
}
as_int <- function(x, d) { y <- suppressWarnings(as.integer(x)); if (is.na(y)) d else y }
q <- function(x) paste0('"', x, '"')
dir.ensure <- function(p) if (!dir.exists(p)) dir.create(p, recursive = TRUE, showWarnings = FALSE)
exec_sql <- function(conn, sql) DatabaseConnector::executeSql(conn, sql)

# ========= Variables (defaults; can be overridden via sys.source envir) =========
irisConnStr      <- get0nz("irisConnStr", NULL)                # preferred (e.g. "jdbc:IRIS://host.docker.internal:1972/USER")
irisServer       <- get0nz("irisServer", "host.docker.internal")
irisPort         <- as_int(get0nz("irisPort", 1972L), 1972L)
irisNamespace    <- get0nz("irisNamespace", "USER")
irisUser         <- get0nz("irisUser", "_SYSTEM")
irisPassword     <- get0nz("irisPassword", "_SYSTEM")
jdbcDriverFolder <- get0nz("jdbcDriverFolder", "/opt/hades/jdbc_drivers")

cdmSchema        <- get0nz("cdmSchema", "OMOPCDM53")
resultsSchema    <- get0nz("resultsSchema", "OMOPCDM55_RESULTS")
scratchSchema    <- get0nz("scratchSchema", "OMOPCDM55_SCRATCH")
scratchSentinel  <- "__SCRATCH_HEARTBEAT"

sourceName        <- get0nz("sourceName", "Eunomia 5.3 on IRIS")
excludeAnalyses   <- { x <- get0("excludeAnalyses", inherits=TRUE, ifnotfound=c(802)); if (is.null(x)) c(802) else as.integer(x) }
numThreads        <- as_int(get0nz("numThreads", 1L), 1L)
smallCellCount    <- as_int(get0nz("smallCellCount", 5L), 5L)
cdmVersion        <- as.character(get0nz("cdmVersion", "5.3"))
achillesOutputDir <- get0nz("achillesOutputDir", "achilles_output")

forceAchilles     <- isTRUE(get0("forceAchilles", inherits=TRUE, ifnotfound=FALSE))
reloadEunomia     <- isTRUE(get0("reloadEunomia", inherits=TRUE, ifnotfound=FALSE))

pgHost        <- get0nz("pgHost", "broadsea-atlasdb")
pgPort        <- as_int(get0nz("pgPort", 5432L), 5432L)
pgDatabase    <- get0nz("pgDatabase", "postgres")
pgUser        <- get0nz("pgUser", "postgres")
pgPassword    <- get0nz("pgPassword", "mypass")
atlasSourceId <- as_int(get0nz("atlasSourceId", 2L), 2L)

# Pretty dump
cat("== PARAM DUMP ==\n",
    "  irisConnStr      : ", if (!is.null(irisConnStr)) irisConnStr else "(will build from server/port/ns)", "\n",
    "  irisServer       : ", irisServer, "\n",
    "  irisPort         : ", irisPort, "\n",
    "  irisNamespace    : ", irisNamespace, "\n",
    "  irisUser         : ", irisUser, "\n",
    "  irisPassword     : ", if (nzchar(irisPassword)) "•••••••" else '""', "\n",
    "  jdbcDriverFolder : ", jdbcDriverFolder, "\n",
    "  cdmSchema        : ", cdmSchema, "\n",
    "  resultsSchema    : ", resultsSchema, "\n",
    "  scratchSchema    : ", scratchSchema, "\n",
    "  sourceName       : ", sourceName, "\n",
    "  cdmVersion       : ", cdmVersion, "\n",
    "  excludeAnalyses  : ", paste(excludeAnalyses, collapse=","), "\n",
    "  numThreads       : ", numThreads, "\n",
    "  smallCellCount   : ", smallCellCount, "\n",
    "  forceAchilles    : ", forceAchilles, "\n",
    "  reloadEunomia    : ", reloadEunomia, "\n",
    "  atlasSourceId    : ", atlasSourceId, "\n\n", sep="")

# Build connectionString if not provided
if (is.null(irisConnStr) || !nzchar(as.character(irisConnStr))) {
  irisConnStr <- sprintf("jdbc:IRIS://%s:%d/%s", irisServer, irisPort, irisNamespace)
}
dir.ensure(achillesOutputDir); dir.ensure(file.path(achillesOutputDir, "sql")); dir.ensure("output")

# -------- Catalog helpers (original) --------
table_exists <- function(conn, schema, table) {
  sql <- paste0("SELECT COUNT(*) AS N FROM INFORMATION_SCHEMA.TABLES ",
                "WHERE UPPER(TABLE_SCHEMA)=UPPER('", schema, "') AND UPPER(TABLE_NAME)=UPPER('", toupper(table), "')")
  tryCatch(DatabaseConnector::querySql(conn, sql)$N[1] > 0, error=function(e) FALSE)
}
count_rows <- function(conn, schema, table) {
  if (!table_exists(conn, schema, table)) return(0L)
  as.integer(DatabaseConnector::querySql(conn, paste0("SELECT COUNT(*) N FROM ", q(schema), ".", q(toupper(table))))$N[1])
}
schema_exists <- function(conn, schema) {
  n1 <- tryCatch({
    sql <- paste0("SELECT COUNT(*) AS N FROM INFORMATION_SCHEMA.SCHEMATA ",
                  "WHERE UPPER(SCHEMA_NAME)=UPPER('", schema, "')")
    as.integer(DatabaseConnector::querySql(conn, sql)$N[1])
  }, error=function(e) 0L)
  if (!is.na(n1) && n1 > 0L) return(TRUE)
  n2 <- tryCatch({
    sql <- paste0("SELECT COUNT(*) AS N FROM ", q("%Dictionary"), ".", q("Schema"),
                  " WHERE UPPER(", q("Name"), ")=UPPER('", schema, "')")
    as.integer(DatabaseConnector::querySql(conn, sql)$N[1])
  }, error=function(e) 0L)
  isTRUE(n2 > 0L)
}
ensure_scratch_with_sentinel <- function(conn, schema, sentinel) {
  if (table_exists(conn, schema, sentinel)) {
    n <- tryCatch({
      as.integer(DatabaseConnector::querySql(
        conn, paste0("SELECT COUNT(*) AS N FROM ", q(schema), ".", q(sentinel), " WHERE ", q("ID"), " = 1")
      )$N[1])
    }, error=function(e) 0L)
    if (n == 0L) exec_sql(conn, paste0(
      "INSERT INTO ", q(schema), ".", q(sentinel), " (", q("ID"), ",", q("TS"), ") VALUES (1, CURRENT_TIMESTAMP)"
    ))
    return(invisible(TRUE))
  }
  if (!schema_exists(conn, schema)) {
    tryCatch(exec_sql(conn, paste0("CREATE SCHEMA ", q(schema))),
             error=function(e){ if (!grepl("already.*exists|SQLCODE:\\s*<-?476>", conditionMessage(e), TRUE)) stop(e) })
  }
  if (!table_exists(conn, schema, sentinel)) {
    tryCatch(exec_sql(conn, paste0(
      "CREATE TABLE ", q(schema), ".", q(sentinel), " (",
      q("ID"), " INT NOT NULL, ", q("TS"), " TIMESTAMP, PRIMARY KEY (", q("ID"), "))"
    )), error=function(e){ if (!grepl("already.*exists|SQLCODE:\\s*<-?201>", conditionMessage(e), TRUE)) stop(e) })
  }
  n <- tryCatch({
    as.integer(DatabaseConnector::querySql(
      conn, paste0("SELECT COUNT(*) AS N FROM ", q(schema), ".", q(sentinel), " WHERE ", q("ID"), " = 1")
    )$N[1])
  }, error=function(e) 0L)
  if (n == 0L) exec_sql(conn, paste0(
    "INSERT INTO ", q(schema), ".", q(sentinel), " (", q("ID"), ",", q("TS"), ") VALUES (1, CURRENT_TIMESTAMP)"
  ))
  invisible(TRUE)
}
norm_idx <- function(x) gsub("[^A-Z0-9]", "", toupper(x))
list_index_names <- function(conn, schema, table) {
  sql <- paste0("SELECT UPPER(INDEX_NAME) AS IDX FROM INFORMATION_SCHEMA.INDEXES ",
                "WHERE UPPER(TABLE_SCHEMA)=UPPER('", schema, "') AND UPPER(TABLE_NAME)=UPPER('", toupper(table), "')")
  out <- tryCatch(DatabaseConnector::querySql(conn, sql)$IDX, error=function(e) character())
  unique(out)
}
index_exists <- function(conn, schema, table, idxName) {
  existing <- list_index_names(conn, schema, toupper(table))
  if (!length(existing)) return(FALSE)
  nExisting <- norm_idx(existing); nTarget <- norm_idx(idxName)
  any(nExisting == nTarget)
}
index_create_safe <- function(conn, schema, table, idx, cols) {
  if (index_exists(conn, schema, table, idx)) { message("Index ", idx, " already exists — skipping."); return(invisible(TRUE)) }
  alt <- gsub("_","", idx)
  if (!identical(alt, idx) && index_exists(conn, schema, table, alt)) { message("Index ", alt, " exists — skipping."); return(invisible(TRUE)) }
  tryCatch(exec_sql(conn, paste0("CREATE INDEX ", idx, " ON ", q(schema), ".", q(table), " (", cols, ")")),
           error=function(e){ if (!grepl("already.*index|already.*defined|SQLCODE:\\s*<-?324>", conditionMessage(e), TRUE)) stop(e) })
}

# ========= Stage 0: Ensure `conn` (IRIS) — using explicit connectionString =========
message("Creating IRIS connection as `conn` …")
details <- DatabaseConnector::createConnectionDetails(
  dbms             = "iris",
  connectionString = irisConnStr,    # <- same pattern that worked for you
  user             = irisUser,
  password         = irisPassword,
  pathToDriver     = jdbcDriverFolder
)
conn <- DatabaseConnector::connect(details)
on.exit(try(DatabaseConnector::disconnect(conn), silent = TRUE), add = TRUE)

# Sanity prime (accept if either path works)
ok <- FALSE
r1 <- try(DBI::dbGetQuery(conn, "SELECT 1 AS ONE"), silent = TRUE)
if (!inherits(r1, "try-error") && is.data.frame(r1) && identical(as.integer(r1[[1]][1]), 1L)) ok <- TRUE
if (!ok) {
  r2 <- try(DatabaseConnector::querySql(conn, "SELECT 1 AS ONE"), silent = TRUE)
  if (!inherits(r2, "try-error") && is.data.frame(r2) && identical(as.integer(r2[[1]][1]), 1L)) ok <- TRUE
}
if (!ok) stop("IRIS connection established but SELECT 1 failed via both DBI and DatabaseConnector.")

# Ensure RESULTS schema
if (!schema_exists(conn, resultsSchema)) {
  tryCatch(exec_sql(conn, paste0("CREATE SCHEMA ", q(resultsSchema))),
           error=function(e){ if (!grepl("already.*exists|SQLCODE:\\s*<-?476>", conditionMessage(e), TRUE)) stop(e) })
}

# Ensure SCRATCH + sentinel; route temp emulation
ensure_scratch_with_sentinel(conn, scratchSchema, scratchSentinel)
options(sqlRenderTempEmulationSchema = scratchSchema)

# ========= Stage 1: (Optional) Eunomia → OMOPCDM53 =========
personBefore <- count_rows(conn, cdmSchema, "PERSON")
message("PERSON count before load in ", cdmSchema, ": ", personBefore)
if (reloadEunomia || personBefore == 0L) {
  message("Loading Eunomia into ", cdmSchema, " …")
  eunomiaDetails <- Eunomia::getEunomiaConnectionDetails()
  eunomiaConn <- DatabaseConnector::connect(eunomiaDetails)
  on.exit(try(DatabaseConnector::disconnect(eunomiaConn), silent = TRUE), add = TRUE)
  for (t in DatabaseConnector::getTableNames(eunomiaConn)) {
    df <- DatabaseConnector::querySql(eunomiaConn, paste0("SELECT * FROM ", t))
    names(df) <- toupper(names(df))
    DatabaseConnector::insertTable(
      connection        = conn,
      tableName         = paste0(q(cdmSchema), ".", q(toupper(t))),
      data              = df,
      dropTableIfExists = TRUE,
      createTable       = TRUE,
      tempTable         = FALSE,
      progressBar       = TRUE
    )
  }
} else message("Skipping CDM reload (PERSON > 0).")
personAfter <- count_rows(conn, cdmSchema, "PERSON")
message("PERSON count after load in ", cdmSchema, ": ", personAfter)

# ========= Stage 2: Ensure 6 core RESULTS tables =========
ensure_core_results_tables <- function(conn, schema) {
  ddls <- list(
    ACHILLES_ANALYSIS = paste0(
      "CREATE TABLE ", q(schema), ".", q("ACHILLES_ANALYSIS"), " (",
      q("ANALYSIS_ID"), " INT NOT NULL, ",
      q("ANALYSIS_NAME"), " VARCHAR(255), ",
      q("STRATUM_1_NAME"), " VARCHAR(255), ",
      q("STRATUM_2_NAME"), " VARCHAR(255), ",
      q("STRATUM_3_NAME"), " VARCHAR(255), ",
      q("STRATUM_4_NAME"), " VARCHAR(255), ",
      q("STRATUM_5_NAME"), " VARCHAR(255), ",
      q("IS_DEFAULT"), " INT, ",
      q("CATEGORY"), " VARCHAR(50))"
    ),
    ACHILLES_RESULTS = paste0(
      "CREATE TABLE ", q(schema), ".", q("ACHILLES_RESULTS"), " (",
      q("ANALYSIS_ID"), " INT NOT NULL, ",
      q("STRATUM_1"), " VARCHAR(255), ",
      q("STRATUM_2"), " VARCHAR(255), ",
      q("STRATUM_3"), " VARCHAR(255), ",
      q("STRATUM_4"), " VARCHAR(255), ",
      q("STRATUM_5"), " VARCHAR(255), ",
      q("COUNT_VALUE"), " NUMERIC)"
    ),
    ACHILLES_RESULTS_DIST = paste0(
      "CREATE TABLE ", q(schema), ".", q("ACHILLES_RESULTS_DIST"), " (",
      q("ANALYSIS_ID"), " INT NOT NULL, ",
      q("STRATUM_1"), " VARCHAR(255), ",
      q("STRATUM_2"), " VARCHAR(255), ",
      q("STRATUM_3"), " VARCHAR(255), ",
      q("STRATUM_4"), " VARCHAR(255), ",
      q("STRATUM_5"), " VARCHAR(255), ",
      q("MIN_VALUE"), " NUMERIC, ",
      q("P10_VALUE"), " NUMERIC, ",
      q("P25_VALUE"), " NUMERIC, ",
      q("MEDIAN_VALUE"), " NUMERIC, ",
      q("P75_VALUE"), " NUMERIC, ",
      q("P90_VALUE"), " NUMERIC, ",
      q("MAX_VALUE"), " NUMERIC, ",
      q("AVERAGE_VALUE"), " NUMERIC, ",
      q("STDEV_VALUE"), " NUMERIC)"
    ),
    ACHILLES_HEEL_RESULTS = paste0(
      "CREATE TABLE ", q(schema), ".", q("ACHILLES_HEEL_RESULTS"), " (",
      q("HEEL_ID"), " INT, ",
      q("ANALYSIS_ID"), " INT, ",
      q("STRATUM_1"), " VARCHAR(255), ",
      q("STRATUM_2"), " VARCHAR(255), ",
      q("STRATUM_3"), " VARCHAR(255), ",
      q("STRATUM_4"), " VARCHAR(255), ",
      q("STRATUM_5"), " VARCHAR(255), ",
      q("VIOLATION_TYPE"), " VARCHAR(20))"
    ),
    ACHILLES_RESULT_CONCEPT = paste0(
      "CREATE TABLE ", q(schema), ".", q("ACHILLES_RESULT_CONCEPT"), " (",
      q("ANALYSIS_ID"), " INT NOT NULL, ",
      q("CONCEPT_ID"), " INT NOT NULL)"
    ),
    CONCEPT_HIERARCHY = paste0(
      "CREATE TABLE ", q(schema), ".", q("CONCEPT_HIERARCHY"), " (",
      q("CONCEPT_ID"), " INT NOT NULL, ",
      q("CONCEPT_NAME"), " VARCHAR(1024))"
    )
  )
  for (nm in names(ddls)) if (!table_exists(conn, schema, nm)) exec_sql(conn, ddls[[nm]])
}
ensure_core_results_tables(conn, resultsSchema)

# ========= Stage 3: (Optional) Achilles SQL-only generation + exec =========
existingAR  <- count_rows(conn, resultsSchema, "ACHILLES_RESULTS")
existingARD <- count_rows(conn, resultsSchema, "ACHILLES_RESULTS_DIST")
if (!forceAchilles && (existingAR > 0 || existingARD > 0)) {
  message("Skipping Achilles SQL regeneration (RESULTS already present). Set forceAchilles <- TRUE to rebuild.")
} else {
  message("Generating Achilles SQL (sqlOnly=TRUE) → SCRATCH=", scratchSchema)

  # -- IMPORTANT: Achilles checks pathToDriver even in sqlOnly mode.
  # Provide a 'dummy' connectionDetails with a non-empty pathToDriver.
  # It will NOT connect because sqlOnly=TRUE.
  Sys.setenv(DATABASECONNECTOR_JAR_FOLDER = jdbcDriverFolder)  # extra safety
  dummyDetails <- DatabaseConnector::createConnectionDetails(
    dbms         = "sql server",
    server       = "localhost",   # arbitrary; not used
    user         = "dummy",       # arbitrary; not used
    password     = "dummy",       # arbitrary; not used
    pathToDriver = jdbcDriverFolder
  )

  ach_args <- list(
    connectionDetails        = dummyDetails,
    cdmDatabaseSchema        = cdmSchema,
    resultsDatabaseSchema    = resultsSchema,
    vocabDatabaseSchema      = cdmSchema,
    scratchDatabaseSchema    = scratchSchema,
    tempEmulationSchema      = scratchSchema,
    sourceName               = sourceName,
    createTable              = FALSE,
    updateGivenAnalysesOnly  = FALSE,
    smallCellCount           = smallCellCount,
    numThreads               = numThreads,
    cdmVersion               = cdmVersion,
    sqlOnly                  = TRUE,
    outputFolder             = achillesOutputDir,
    verboseMode              = TRUE,
    excludeAnalysisIds       = excludeAnalyses
  )

  supported <- try(names(formals(Achilles::achilles)), silent = TRUE)
  if (!inherits(supported, "try-error")) ach_args <- ach_args[names(ach_args) %in% supported]

  # clean out any prior SQL files then (re)generate
  unlink(list.files(achillesOutputDir, pattern="\\.sql$", full.names=TRUE), recursive=TRUE, force=TRUE)
  invisible(do.call(Achilles::achilles, ach_args))

  # Execute generated SQL (strip index & schema DDL for IRIS)
   # Execute generated SQL (strip index & schema DDL for IRIS)
  patch_ddl <- function(txt) {
    # strip DDL that IRIS doesn't want
    txt <- gsub("(?im)^\\s*drop\\s+index\\b[^;]*;\\s*",                "", txt, perl=TRUE)
    txt <- gsub("(?im)^\\s*create\\s+(unique\\s+)?index\\b[^;]*;\\s*", "", txt, perl=TRUE)
    txt <- gsub("(?im)^\\s*alter\\s+index\\b[^;]*;\\s*",               "", txt, perl=TRUE)
    txt <- gsub("(?im)^\\s*create\\s+schema\\b[^;]*;\\s*",             "", txt, perl=TRUE)
    txt <- gsub("(?im)^\\s*drop\\s+schema\\b[^;]*;\\s*",               "", txt, perl=TRUE)

    # --- T-SQL -> IRIS shims ---
    txt <- gsub("(?i)\\bcount_big\\s*\\(", "COUNT(", txt, perl=TRUE)
    txt <- gsub("(?i)\\bisnull\\s*\\(",   "COALESCE(", txt, perl=TRUE)
    txt <- gsub("(?i)\\bnvarchar\\b",     "VARCHAR",  txt, perl=TRUE)
    txt <- gsub("(?m)^\\s*GO\\s*$",       "",         txt, perl=TRUE)
    txt
  }
} 

# ========= Stage 4: Populate ACHILLES_RESULT_CONCEPT from ALL strata =========
message("Populating ", resultsSchema, ".ACHILLES_RESULT_CONCEPT from RESULTS …")
exec_sql(conn, paste0(
  'DELETE FROM ', q(resultsSchema), '.', q('ACHILLES_RESULT_CONCEPT'), '; ',
  'INSERT INTO ', q(resultsSchema), '.', q('ACHILLES_RESULT_CONCEPT'), ' (', q('ANALYSIS_ID'), ',', q('CONCEPT_ID'), ') ',
  'SELECT DISTINCT r.', q('ANALYSIS_ID'), ', c.', q('CONCEPT_ID'), ' ',
  'FROM ', q(resultsSchema), '.', q('ACHILLES_RESULTS'), ' r ',
  'JOIN ', q(cdmSchema), '.', q('CONCEPT'), ' c ON CAST(c.', q('CONCEPT_ID'), ' AS VARCHAR(50)) = r.', q('STRATUM_1'),
  ' WHERE r.', q('STRATUM_1'), ' IS NOT NULL AND r.', q('STRATUM_1'), " <> '' ",
  'UNION ALL SELECT DISTINCT r.', q('ANALYSIS_ID'), ', c.', q('CONCEPT_ID'),
  ' FROM ', q(resultsSchema), '.', q('ACHILLES_RESULTS'), ' r JOIN ', q(cdmSchema), '.', q('CONCEPT'), ' c ON CAST(c.', q('CONCEPT_ID'), ' AS VARCHAR(50)) = r.', q('STRATUM_2'),
  ' WHERE r.', q('STRATUM_2'), ' IS NOT NULL AND r.', q('STRATUM_2'), " <> '' ",
  'UNION ALL SELECT DISTINCT r.', q('ANALYSIS_ID'), ', c.', q('CONCEPT_ID'),
  ' FROM ', q(resultsSchema), '.', q('ACHILLES_RESULTS'), ' r JOIN ', q(cdmSchema), '.', q('CONCEPT'), ' c ON CAST(c.', q('CONCEPT_ID'), ' AS VARCHAR(50)) = r.', q('STRATUM_3'),
  ' WHERE r.', q('STRATUM_3'), ' IS NOT NULL AND r.', q('STRATUM_3'), " <> '' ",
  'UNION ALL SELECT DISTINCT r.', q('ANALYSIS_ID'), ', c.', q('CONCEPT_ID'),
  ' FROM ', q(resultsSchema), '.', q('ACHILLES_RESULTS'), ' r JOIN ', q(cdmSchema), '.', q('CONCEPT'), ' c ON CAST(c.', q('CONCEPT_ID'), ' AS VARCHAR(50)) = r.', q('STRATUM_4'),
  ' WHERE r.', q('STRATUM_4'), ' IS NOT NULL AND r.', q('STRATUM_4'), " <> '' ",
  'UNION ALL SELECT DISTINCT r.', q('ANALYSIS_ID'), ', c.', q('CONCEPT_ID'),
  ' FROM ', q(resultsSchema), '.', q('ACHILLES_RESULTS'), ' r JOIN ', q(cdmSchema), '.', q('CONCEPT'), ' c ON CAST(c.', q('CONCEPT_ID'), ' AS VARCHAR(50)) = r.', q('STRATUM_5'),
  ' WHERE r.', q('STRATUM_5'), ' IS NOT NULL AND r.', q('STRATUM_5'), " <> '' "
))

# ========= Stage 5: Enforce WebAPI-shaped CONCEPT_HIERARCHY, then populate =========
message("Rebuilding ", resultsSchema, ".CONCEPT_HIERARCHY (WebAPI shape) …")
ch_required <- c("CONCEPT_ID","CONCEPT_NAME","TREEMAP","CONCEPT_HIERARCHY_TYPE",
                 "LEVEL1_CONCEPT_NAME","LEVEL2_CONCEPT_NAME","LEVEL3_CONCEPT_NAME","LEVEL4_CONCEPT_NAME")

ensure_ch_webapi_shape <- function(conn, schema) {
  if (!table_exists(conn, schema, "CONCEPT_HIERARCHY")) {
    exec_sql(conn, paste0(
      "CREATE TABLE ", q(schema), ".", q("CONCEPT_HIERARCHY"), " (",
      q("CONCEPT_ID"), " INT NOT NULL, ",
      q("CONCEPT_NAME"), " VARCHAR(1024), ",
      q("TREEMAP"), " VARCHAR(50), ",
      q("CONCEPT_HIERARCHY_TYPE"), " VARCHAR(50), ",
      q("LEVEL1_CONCEPT_NAME"), " VARCHAR(1024), ",
      q("LEVEL2_CONCEPT_NAME"), " VARCHAR(1024), ",
      q("LEVEL3_CONCEPT_NAME"), " VARCHAR(1024), ",
      q("LEVEL4_CONCEPT_NAME"), " VARCHAR(1024))"
    ))
    return(invisible(TRUE))
  }
  cols <- tryCatch(DatabaseConnector::querySql(conn, paste0(
    "SELECT UPPER(COLUMN_NAME) C FROM INFORMATION_SCHEMA.COLUMNS ",
    "WHERE UPPER(TABLE_SCHEMA)=UPPER('", schema, "') AND UPPER(TABLE_NAME)='CONCEPT_HIERARCHY'"
  ))$C, error=function(e) character())
  missing <- setdiff(ch_required, cols)
  if (length(missing) == 0) return(invisible(TRUE))
  exec_sql(conn, paste0("DROP TABLE ", q(schema), ".", q("CONCEPT_HIERARCHY")))
  exec_sql(conn, paste0(
    "CREATE TABLE ", q(schema), ".", q("CONCEPT_HIERARCHY"), " (",
    q("CONCEPT_ID"), " INT NOT NULL, ",
    q("CONCEPT_NAME"), " VARCHAR(1024), ",
    q("TREEMAP"), " VARCHAR(50), ",
    q("CONCEPT_HIERARCHY_TYPE"), " VARCHAR(50), ",
    q("LEVEL1_CONCEPT_NAME"), " VARCHAR(1024), ",
    q("LEVEL2_CONCEPT_NAME"), " VARCHAR(1024), ",
    q("LEVEL3_CONCEPT_NAME"), " VARCHAR(1024), ",
    q("LEVEL4_CONCEPT_NAME"), " VARCHAR(1024))"
  ))
  invisible(TRUE)
}
ensure_ch_webapi_shape(conn, resultsSchema)
exec_sql(conn, paste0('DELETE FROM ', q(resultsSchema), '.', q('CONCEPT_HIERARCHY')))

ins_flat <- function(label, domain) {
  exec_sql(conn, paste0(
    "INSERT INTO ", q(resultsSchema), ".", q("CONCEPT_HIERARCHY"), " (",
    q("CONCEPT_ID"), ",", q("CONCEPT_NAME"), ",", q("TREEMAP"), ",", q("CONCEPT_HIERARCHY_TYPE"), ",",
    q("LEVEL1_CONCEPT_NAME"), ",", q("LEVEL2_CONCEPT_NAME"), ",", q("LEVEL3_CONCEPT_NAME"), ",", q("LEVEL4_CONCEPT_NAME"), ") ",
    "SELECT DISTINCT arc.", q("CONCEPT_ID"), ", c.", q("CONCEPT_NAME"), ", '", label, "' AS ", q("TREEMAP"), ", ",
    "'None' AS ", q("CONCEPT_HIERARCHY_TYPE"), ", NULL,NULL,NULL,NULL ",
    "FROM ", q(resultsSchema), ".", q("ACHILLES_RESULT_CONCEPT"), " arc ",
    "JOIN ", q(cdmSchema), ".", q("CONCEPT"), " c ON c.", q("CONCEPT_ID"), " = arc.", q("CONCEPT_ID"), " ",
    "WHERE c.", q("DOMAIN_ID"), " = '", domain, "'"
  ))
}
for (d in list(
  list("Condition","Condition"),
  list("Condition Era","Condition"),
  list("Drug","Drug"),
  list("Drug Era","Drug"),
  list("Procedure","Procedure"),
  list("Measurement","Measurement"),
  list("Observation","Observation"),
  list("Visit","Visit"),
  list("Death","Observation"),
  list("Device","Device")
)) ins_flat(d[[1]], d[[2]])

# ========= Stage 6: Indices (skip if exist) =========
index_create_safe(conn, resultsSchema, "ACHILLES_RESULTS",        "IDX_AR_AID",  q("ANALYSIS_ID"))
index_create_safe(conn, resultsSchema, "ACHILLES_RESULTS_DIST",   "IDX_ARD_AID", q("ANALYSIS_ID"))
index_create_safe(conn, resultsSchema, "ACHILLES_RESULT_CONCEPT", "IDX_ARC_AID", q("ANALYSIS_ID"))
index_create_safe(conn, resultsSchema, "CONCEPT_HIERARCHY",       "IDX_CH_CID",  q("CONCEPT_ID"))

# ========= Stage 7: Verification + Cache-bust =========
resCounts <- data.frame(
  table=c("ACHILLES_ANALYSIS","ACHILLES_RESULTS","ACHILLES_RESULTS_DIST","ACHILLES_HEEL_RESULTS","ACHILLES_RESULT_CONCEPT","CONCEPT_HIERARCHY"),
  n=c(
    count_rows(conn, resultsSchema, "ACHILLES_ANALYSIS"),
    count_rows(conn, resultsSchema, "ACHILLES_RESULTS"),
    count_rows(conn, resultsSchema, "ACHILLES_RESULTS_DIST"),
    count_rows(conn, resultsSchema, "ACHILLES_HEEL_RESULTS"),
    count_rows(conn, resultsSchema, "ACHILLES_RESULT_CONCEPT"),
    count_rows(conn, resultsSchema, "CONCEPT_HIERARCHY")
  )
)
print(resCounts)

keyAnalyses <- c(400,401,402, 700,701, 200,201, 600,601)
ka <- tryCatch(DatabaseConnector::querySql(
  conn,
  paste0(
    "SELECT ", q("ANALYSIS_ID"), ", COUNT(*) AS ", q("N"),
    " FROM ", q(resultsSchema), ".", q("ACHILLES_RESULTS"),
    " WHERE ", q("ANALYSIS_ID"), " IN (", paste(keyAnalyses, collapse=","), ") ",
    "GROUP BY ", q("ANALYSIS_ID"), " ORDER BY ", q("ANALYSIS_ID")
  )), error=function(e) data.frame())
if (nrow(ka)) { message("Key ACHILLES_RESULTS counts:"); print(ka) }

dom_cov <- tryCatch(DatabaseConnector::querySql(
  conn, paste0(
    'SELECT c.', q('DOMAIN_ID'), ' AS ', q('DOMAIN_LABEL'), ', COUNT(DISTINCT arc.', q('CONCEPT_ID'), ') AS ', q('N_CONCEPTS'), ' ',
    'FROM ', q(resultsSchema), '.', q('ACHILLES_RESULT_CONCEPT'), ' arc ',
    'JOIN ', q(cdmSchema), '.', q('CONCEPT'), ' c ON c.', q('CONCEPT_ID'), '= arc.', q('CONCEPT_ID'), ' ',
    'GROUP BY c.', q('DOMAIN_ID'), ' ORDER BY ', q('N_CONCEPTS'), ' DESC'
  )), error=function(e) data.frame())
if (nrow(dom_cov)) { message("Result concept coverage by DOMAIN_ID:"); print(dom_cov) }

message("Clearing WebAPI caches via RPostgres (source_id=", atlasSourceId, ") …")
pg <- NULL
try({
  pg <- DBI::dbConnect(RPostgres::Postgres(),
                       host=pgHost, port=pgPort,
                       dbname=pgDatabase, user=pgUser, password=pgPassword)
  DBI::dbExecute(pg, paste0("DELETE FROM webapi.achilles_cache WHERE source_id = ", atlasSourceId))
  DBI::dbExecute(pg, paste0("DELETE FROM webapi.cdm_cache      WHERE source_id = ", atlasSourceId))
  DBI::dbDisconnect(pg)
  message("WebAPI caches cleared.")
}, silent=TRUE)

message("\n===== Summary =====")
message("PERSON rows in ", cdmSchema, ": ", personAfter)
message("RESULTS row counts:"); print(resCounts)
message("Done. Hard-refresh ATLAS (Ctrl/Cmd+Shift+R). ",
        "SCRATCH now carries a persistent sentinel table with one row — existence checks are accurate without CREATE SCHEMA noise.")

}) # end local()
