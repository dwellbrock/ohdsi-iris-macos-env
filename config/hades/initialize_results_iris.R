#!/usr/bin/env Rscript
# IRIS Eunomia → Achilles → ATLAS (RESULTS in OMOPCDM55_RESULTS)
# IRIS-safe; open-open; auto-reconnect; INFORMATION_SCHEMA-only; Achilles fallback.

# ========= Variables =========
irisServer       <- "host.docker.internal"
irisPort         <- 1972
irisNamespace    <- "USER"
irisUser         <- "_SYSTEM"
irisPassword     <- "_SYSTEM"
jdbcDriverFolder <- "/opt/hades/jdbc_drivers"

cdmSchema        <- "OMOPCDM53"
resultsSchema    <- "OMOPCDM55_RESULTS"
scratchSchema    <- "OMOPCDM55_SCRATCH"
scratchSentinel  <- "__SCRATCH_HEARTBEAT"

sourceName        <- "Eunomia 5.3 on IRIS"
excludeAnalyses   <- c(802)   # IRIS CTE restriction
numThreads        <- 1
smallCellCount    <- 5
cdmVersion        <- "5.3"
achillesOutputDir <- "achilles_output"

forceAchilles <- FALSE
reloadEunomia <- FALSE

pgHost        <- "broadsea-atlasdb"
pgPort        <- 5432
pgDatabase    <- "postgres"
pgUser        <- "postgres"
pgPassword    <- "mypass"
atlasSourceId <- 2

# ========= Packages =========
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
Sys.setenv(DATABASECONNECTOR_JAR_FOLDER = jdbcDriverFolder)

# ========= Helpers (open-open + auto-reconnect; no errorReport files) =========
q <- function(x) paste0('"', x, '"')
dir.ensure <- function(p) if (!dir.exists(p)) dir.create(p, recursive = TRUE, showWarnings = FALSE)
dir.ensure(achillesOutputDir); dir.ensure(file.path(achillesOutputDir, "sql")); dir.ensure("output")
irisConnStr <- sprintf("jdbc:IRIS://%s:%d/%s", irisServer, irisPort, irisNamespace)

# Single place to ping the connection WITHOUT creating errorReportSql.txt
ping_conn <- function(c) {
  ok <- TRUE
  tryCatch({
    DatabaseConnector::querySql(c, "SELECT 1", errorReportFile = NULL)
  }, error = function(e) ok <<- FALSE)
  ok
}

connect_with_open_check <- function() {
  details <- DatabaseConnector::createConnectionDetails(
    dbms             = "iris",
    connectionString = irisConnStr,
    user             = irisUser,
    password         = irisPassword,
    pathToDriver     = jdbcDriverFolder
  )
  c <- DatabaseConnector::connect(details)
  # quick retry loop to dodge the tiny post-open window
  if (!ping_conn(c)) {
    Sys.sleep(0.25)
    if (!ping_conn(c)) {
      try(DatabaseConnector::disconnect(c), silent = TRUE)
      stop("IRIS connection sanity check failed (ping did not succeed).")
    }
  }
  c
}

conn <- NULL
ensure_conn_alive <- function() {
  if (is.null(conn) || !ping_conn(conn)) {
    message("Connection not open — reconnecting …")
    conn <<- connect_with_open_check()
  }
}

# Always use these wrappers so pings happen automatically and no errorReport files get written
dc_query <- function(sql) {
  ensure_conn_alive()
  DatabaseConnector::querySql(conn, sql, errorReportFile = NULL)
}
dc_exec <- function(sql) {
  ensure_conn_alive()
  DatabaseConnector::executeSql(conn, sql, errorReportFile = NULL)
}

# ======= Catalog + utility helpers (unchanged except they call dc_* now) =======
table_exists <- function(schema, table) {
  sql <- paste0(
    "SELECT COUNT(*) AS N FROM INFORMATION_SCHEMA.TABLES ",
    "WHERE UPPER(TABLE_SCHEMA)=UPPER('", schema, "') AND UPPER(TABLE_NAME)=UPPER('", toupper(table), "')"
  )
  tryCatch(dc_query(sql)$N[1] > 0, error=function(e) FALSE)
}
count_rows <- function(schema, table) {
  if (!table_exists(schema, table)) return(0L)
  as.integer(dc_query(paste0("SELECT COUNT(*) N FROM ", q(schema), ".", q(toupper(table))))$N[1])
}

# INFORMATION_SCHEMA only (no %Dictionary.*)
schema_exists <- function(schema) {
  n1 <- tryCatch(as.integer(dc_query(paste0(
    "SELECT COUNT(*) AS N FROM INFORMATION_SCHEMA.SCHEMATA WHERE UPPER(SCHEMA_NAME)=UPPER('", schema, "')"
  ))$N[1]), error=function(e) 0L)
  isTRUE(!is.na(n1) && n1 > 0L)
}

ensure_scratch_with_sentinel <- function(schema, sentinel) {
  if (table_exists(schema, sentinel)) {
    n <- tryCatch(as.integer(dc_query(paste0(
      "SELECT COUNT(*) AS N FROM ", q(schema), ".", q(sentinel), " WHERE ", q("ID"), " = 1"
    ))$N[1]), error=function(e) 0L)
    if (n == 0L) dc_exec(paste0(
      "INSERT INTO ", q(schema), ".", q(sentinel), " (", q("ID"), ",", q("TS"), ") VALUES (1, CURRENT_TIMESTAMP)"
    ))
    return(invisible(TRUE))
  }
  if (!schema_exists(schema)) {
    tryCatch(dc_exec(paste0("CREATE SCHEMA ", q(schema))),
             error=function(e){ if (!grepl("already.*exists|SQLCODE:\\s*<-?476>", conditionMessage(e), TRUE)) stop(e) })
  }
  if (!table_exists(schema, sentinel)) {
    tryCatch(dc_exec(paste0(
      "CREATE TABLE ", q(schema), ".", q(sentinel), " (",
      q("ID"), " INT NOT NULL, ", q("TS"), " TIMESTAMP, PRIMARY KEY (", q("ID"), "))"
    )), error=function(e){ if (!grepl("already.*exists|SQLCODE:\\s*<-?201>", conditionMessage(e), TRUE)) stop(e) })
  }
  n <- tryCatch(as.integer(dc_query(paste0(
    "SELECT COUNT(*) AS N FROM ", q(schema), ".", q(sentinel), " WHERE ", q("ID"), " = 1"
  ))$N[1]), error=function(e) 0L)
  if (n == 0L) dc_exec(paste0(
    "INSERT INTO ", q(schema), ".", q(sentinel), " (", q("ID"), ",", q("TS"), ") VALUES (1, CURRENT_TIMESTAMP)"
  ))
  invisible(TRUE)
}

norm_idx <- function(x) gsub("[^A-Z0-9]", "", toupper(x))
list_index_names <- function(schema, table) {
  out <- tryCatch(dc_query(paste0(
    "SELECT UPPER(INDEX_NAME) AS IDX FROM INFORMATION_SCHEMA.INDEXES ",
    "WHERE UPPER(TABLE_SCHEMA)=UPPER('", schema, "') AND UPPER(TABLE_NAME)=UPPER('", toupper(table), "')"
  ))$IDX, error=function(e) character())
  unique(out)
}
index_exists <- function(schema, table, idxName) {
  existing <- list_index_names(schema, toupper(table))
  if (!length(existing)) return(FALSE)
  nExisting <- norm_idx(existing); nTarget <- norm_idx(idxName)
  any(nExisting == nTarget)
}
index_create_safe <- function(schema, table, idx, cols) {
  if (index_exists(schema, table, idx)) { message("Index ", idx, " already exists — skipping."); return(invisible(TRUE)) }
  alt <- gsub("_","", idx)
  if (!identical(alt, idx) && index_exists(schema, table, alt)) { message("Index ", alt, " exists — skipping."); return(invisible(TRUE)) }
  tryCatch(dc_exec(paste0("CREATE INDEX ", idx, " ON ", q(schema), ".", q(table), " (", cols, ")")),
           error=function(e){ if (!grepl("already.*index|already.*defined|SQLCODE:\\s*<-?324>", conditionMessage(e), TRUE)) stop(e) })
}

# ========= Stage 0: Connect & prep =========
message("Creating IRIS connection as `conn` …")
conn <- connect_with_open_check()
on.exit(try(DatabaseConnector::disconnect(conn), silent = TRUE), add = TRUE)

# Ensure RESULTS schema (now safe)
if (!schema_exists(resultsSchema)) dc_exec(paste0("CREATE SCHEMA ", q(resultsSchema)))

# Ensure SCRATCH + sentinel; route temp emulation
ensure_scratch_with_sentinel(scratchSchema, scratchSentinel)
options(sqlRenderTempEmulationSchema = scratchSchema)

# ========= Stage 1: (Optional) Eunomia → OMOPCDM53 =========
personBefore <- count_rows(cdmSchema, "PERSON")
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
personAfter <- count_rows(cdmSchema, "PERSON")
message("PERSON count after load in ", cdmSchema, ": ", personAfter)

# ========= Stage 2: Ensure 6 core RESULTS tables =========
ensure_core_results_tables <- function(schema) {
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
  for (nm in names(ddls)) if (!table_exists(schema, nm)) dc_exec(ddls[[nm]])
}
ensure_core_results_tables(resultsSchema)

# ========= Stage 3: Achilles SQL-only (per-file) with fallback =========
existingAR  <- count_rows(resultsSchema, "ACHILLES_RESULTS")
existingARD <- count_rows(resultsSchema, "ACHILLES_RESULTS_DIST")
ranAchillesDirect <- FALSE   # <— NEW FLAG

if (!forceAchilles && (existingAR > 0 || existingARD > 0)) {
  message("Skipping Achilles SQL regeneration (RESULTS already present). Set forceAchilles <- TRUE to rebuild.")
} else {
  message("Generating Achilles SQL (sqlOnly=TRUE) → SCRATCH=", scratchSchema)
  # minimal dummy details; Achilles only needs them present
  dummyDetails <- DatabaseConnector::createConnectionDetails(dbms="sql server", server="ignored")
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
  unlink(list.files(achillesOutputDir, pattern="\\.sql$", full.names=TRUE), recursive=TRUE, force=TRUE)
  invisible(do.call(Achilles::achilles, ach_args))
  
  patch_ddl <- function(txt) {
    txt <- gsub("(?im)^\\s*drop\\s+index\\b[^;]*;\\s*",                "", txt, perl=TRUE)
    txt <- gsub("(?im)^\\s*create\\s+(unique\\s+)?index\\b[^;]*;\\s*", "", txt, perl=TRUE)
    txt <- gsub("(?im)^\\s*alter\\s+index\\b[^;]*;\\s*",               "", txt, perl=TRUE)
    txt <- gsub("(?im)^\\s*create\\s+schema\\b[^;]*;\\s*",             "", txt, perl=TRUE)
    txt <- gsub("(?im)^\\s*drop\\s+schema\\b[^;]*;\\s*",               "", txt, perl=TRUE)
    txt <- gsub("(?i)\\bcount_big\\s*\\(", "COUNT(", txt, perl=TRUE)
    txt <- gsub("(?i)\\bisnull\\s*\\(",   "COALESCE(", txt, perl=TRUE)
    txt <- gsub("(?i)\\bnvarchar\\b",     "VARCHAR",  txt, perl=TRUE)
    txt <- gsub("(?m)^\\s*GO\\s*$",       "",         txt, perl=TRUE)
    txt
  }
  
  # collect per-file SQL (Achilles 1.7.2 may only output achilles.sql; handle that)
  cand_dirs <- c(file.path(achillesOutputDir, "sql"),
                 file.path(achillesOutputDir, "sql_server"),
                 achillesOutputDir)
  sql_files <- unique(unlist(lapply(cand_dirs, function(d)
    if (dir.exists(d)) list.files(d, pattern="\\.(?i)sql$", full.names=TRUE, recursive=TRUE) else character(0)
  )))
  # Exclude the monolithic driver only if we also have per-analysis files:
  if (any(basename(sql_files) != "achilles.sql")) {
    sql_files <- sql_files[basename(sql_files) != "achilles.sql"]
  } else {
    sql_files <- character(0)
  }
  
  if (length(sql_files) > 0) {
    message("Executing ", length(sql_files), " SQL file(s)…")
    for (f in sql_files) {
      cat(sprintf("  - %s … ", basename(f)))
      ok <- TRUE
      tryCatch({
        txt <- readChar(f, file.info(f)$size, useBytes=TRUE)
        txt <- gsub("\r\n", "\n", txt, fixed=TRUE)
        txt <- SqlRender::translate(sql = txt, targetDialect = "sql server",
                                    tempEmulationSchema = scratchSchema)
        txt <- patch_ddl(txt)
        dc_exec(txt)
      }, error=function(e){ ok<<-FALSE; message("\n      -> ", conditionMessage(e)) })
      if (ok) cat("ok\n")
    }
  } else {
    message("No per-file SQL was generated — running Achilles directly against IRIS (sqlOnly=FALSE).")
    # Direct execution path: IRIS conn + temp emulation; no table creation.
    irisDetails <- DatabaseConnector::createConnectionDetails(
      dbms             = "iris",
      connectionString = irisConnStr,
      user             = irisUser,
      password         = irisPassword,
      pathToDriver     = jdbcDriverFolder
    )
    invisible(Achilles::achilles(
      connectionDetails        = irisDetails,
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
      sqlOnly                  = FALSE,
      outputFolder             = achillesOutputDir,
      verboseMode              = TRUE,
      excludeAnalysisIds       = excludeAnalyses
    ))
    ranAchillesDirect <- TRUE   # <— SET FLAG
  }
}

# ========= Stage 4: Populate ACHILLES_RESULT_CONCEPT from ALL strata =========
message("Populating ", resultsSchema, ".ACHILLES_RESULT_CONCEPT from RESULTS …")
dc_exec(paste0(
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

ensure_ch_webapi_shape <- function(schema) {
  if (!table_exists(schema, "CONCEPT_HIERARCHY")) {
    dc_exec(paste0(
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
  cols <- tryCatch(dc_query(paste0(
    "SELECT UPPER(COLUMN_NAME) C FROM INFORMATION_SCHEMA.COLUMNS ",
    "WHERE UPPER(TABLE_SCHEMA)=UPPER('", schema, "') AND UPPER(TABLE_NAME)='CONCEPT_HIERARCHY'"
  ))$C, error=function(e) character())
  missing <- setdiff(ch_required, cols)
  if (length(missing) == 0) return(invisible(TRUE))
  dc_exec(paste0("DROP TABLE ", q(schema), ".", q("CONCEPT_HIERARCHY")))
  dc_exec(paste0(
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
ensure_ch_webapi_shape(resultsSchema)
dc_exec(paste0('DELETE FROM ', q(resultsSchema), '.', q('CONCEPT_HIERARCHY')))

ins_flat <- function(label, domain) {
  dc_exec(paste0(
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

# ========= Stage 6: Indices (skip if Achilles already did them) =========
if (!ranAchillesDirect) {
  index_create_safe(resultsSchema, "ACHILLES_RESULTS",        "IDX_AR_AID",  q("ANALYSIS_ID"))
  index_create_safe(resultsSchema, "ACHILLES_RESULTS_DIST",   "IDX_ARD_AID", q("ANALYSIS_ID"))
  index_create_safe(resultsSchema, "ACHILLES_RESULT_CONCEPT", "IDX_ARC_AID", q("ANALYSIS_ID"))
  index_create_safe(resultsSchema, "CONCEPT_HIERARCHY",       "IDX_CH_CID",  q("CONCEPT_ID"))
} else {
  message("Skipping Stage 6: Achilles (direct) already handled indexes.")
}

# ========= Stage 7: Verification + Cache-bust =========
resCounts <- data.frame(
  table=c("ACHILLES_ANALYSIS","ACHILLES_RESULTS","ACHILLES_RESULTS_DIST","ACHILLES_HEEL_RESULTS","ACHILLES_RESULT_CONCEPT","CONCEPT_HIERARCHY"),
  n=c(
    count_rows(resultsSchema, "ACHILLES_ANALYSIS"),
    count_rows(resultsSchema, "ACHILLES_RESULTS"),
    count_rows(resultsSchema, "ACHILLES_RESULTS_DIST"),
    count_rows(resultsSchema, "ACHILLES_HEEL_RESULTS"),
    count_rows(resultsSchema, "ACHILLES_RESULT_CONCEPT"),
    count_rows(resultsSchema, "CONCEPT_HIERARCHY")
  )
)
print(resCounts)

keyAnalyses <- c(400,401,402, 700,701, 200,201, 600,601)
ka <- tryCatch(dc_query(paste0(
  "SELECT ", q("ANALYSIS_ID"), ", COUNT(*) AS ", q("N"),
  " FROM ", q(resultsSchema), ".", q("ACHILLES_RESULTS"),
  " WHERE ", q("ANALYSIS_ID"), " IN (", paste(keyAnalyses, collapse=","), ") ",
  "GROUP BY ", q("ANALYSIS_ID"), " ORDER BY ", q("ANALYSIS_ID")
)), error=function(e) data.frame())
if (nrow(ka)) { message("Key ACHILLES_RESULTS counts:"); print(ka) }

dom_cov <- tryCatch(dc_query(paste0(
  'SELECT c.', q('DOMAIN_ID'), ' AS ', q('DOMAIN_LABEL'), ', COUNT(DISTINCT arc.', q('CONCEPT_ID'), ') AS ', q('N_CONCEPTS'), ' ',
  'FROM ', q(resultsSchema), '.', q('ACHILLES_RESULT_CONCEPT'), ' arc ',
  'JOIN ', q(cdmSchema), '.', q('CONCEPT'), ' c ON c.', q('CONCEPT_ID'), '= arc.', q('CONCEPT_ID'), ' ',
  'GROUP BY c.', q('DOMAIN_ID'), ' ORDER BY ', q('N_CONCEPTS'), ' DESC'
)), error=function(e) data.frame())
if (nrow(dom_cov)) { message("Result concept coverage by DOMAIN_ID:"); print(dom_cov) }

# Bust WebAPI caches (source_id = 2)
message("Clearing WebAPI caches via RPostgres (source_id=", atlasSourceId, ") …")
try({
  pg <- DBI::dbConnect(RPostgres::Postgres(),
                       host=pgHost, port=pgPort,
                       dbname=pgDatabase, user=pgUser, password=pgPassword)
  DBI::dbExecute(pg, paste0("DELETE FROM webapi.achilles_cache WHERE source_id = ", atlasSourceId))
  DBI::dbExecute(pg, paste0("DELETE FROM webapi.cdm_cache      WHERE source_id = ", atlasSourceId))
  DBI::dbDisconnect(pg)
  message("WebAPI caches cleared.")
}, silent=TRUE)

# ========= Summary =========
message("\n===== Summary =====")
message("PERSON rows in ", cdmSchema, ": ", personAfter)
message("RESULTS row counts:")
print(resCounts)
message("Done. Hard-refresh ATLAS (Ctrl/Cmd+Shift+R). ",
        "SCRATCH now carries a persistent sentinel table with one row — existence checks are accurate without CREATE SCHEMA noise.")
