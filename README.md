# OHDSI IRIS macOS Env (Apple Silicon)

Turn-key **InterSystems IRIS + OHDSI Broadsea** environment for macOS (M1/M2) with all databases, RStudio packages, and configuration pre-restored from **saved Docker volumes**.

Instead of setting up Broadsea and IRIS manually, this project:

1. Clones the official [OHDSI/Broadsea](https://github.com/OHDSI/Broadsea) repository.
2. Applies working `.env`, `docker-compose.yml`, and JDBC drivers for Apple Silicon.
3. Downloads pre-built **volume snapshots** from this repository’s GitHub Release  
   ([v2025-08-13](https://github.com/dwellbrock/ohdsi-iris-macos-env/releases/tag/v2025-08-13)).
4. Restores:
   - **`dbvolume`** → IRIS database with OMOP CDM, vocabularies, and results.
   - **`atlasdb-postgres-data`** → WebAPI metadata and source configuration.
   - **`rstudio-home-data`** / **`rstudio-tmp-data`** → Preinstalled R packages + HADES setup.
5. Brings up the full Broadsea stack via Docker Compose.

## What’s included
- **InterSystems IRIS** — Preloaded CDM schema (OMOPCDM53 → CDM v5.3) and RESULTS schema (OMOPCDM55_RESULTS, WebAPI-compatible).
- **OHDSI WebAPI & ATLAS** — Built from upstream source via Broadsea.
- **RStudio/HADES** — Apple Silicon compatible, with JDBC driver and packages installed.
- **Traefik** — Reverse proxy for consistent `http://localhost/...` URLs.

## Prerequisites
- [Docker Desktop for macOS (Apple Silicon)](https://www.docker.com/products/docker-desktop/)
- [Homebrew](https://brew.sh/)

### Install Git (via Homebrew)
```bash
brew install git && git config --global user.name "Your Name" && git config --global user.email "you@example.com" && git config --global init.defaultBranch main && git config --global color.ui auto && git config --list
```

## Quick start

All commands below should be run in your macOS Terminal.

1. **Clone the repo and enter it:**
   ```bash
   git clone https://github.com/dwellbrock/ohdsi-iris-macos-env.git
   cd ohdsi-iris-macos-env
   ```

2. **Make the replica script executable and run it:**
   ```bash
   chmod +x scripts/replica.sh
   ./scripts/replica.sh
   ```
   - To **force fresh downloads** of the prebuilt volume tarballs (handy if you hit a `curl 416` or suspect a stale/corrupt cache):
     ```bash
     ./scripts/replica.sh --fresh
     ```

   This will:
   - Clone the official Broadsea repository fresh.
   - Apply the preconfigured `.env`, `docker-compose.yml`, and JDBC drivers.
   - Download the required Docker volume snapshots from the release.
   - Restore the volumes into Docker.
   - Start the IRIS + Broadsea stack with the correct profiles for Apple Silicon.
   - Install the Results initializer script at:
     - `/home/rstudio/initialize_results_iris.R`
     - Symlink: `/opt/hades/scripts/initialize_results_iris.R`
   - Install the Wipe script at:
     - `/home/rstudio/wipe_omop_iris.R`
     - Symlink: `/opt/hades/scripts/wipe_omop_iris.R`

3. **Access the services:**
   - IRIS Portal → <http://localhost:52773/csp/sys/UtilHome.csp>  
     - User: `_SYSTEM`  
     - Pass: `_SYSTEM`
   - ATLAS → <http://127.0.0.1/atlas>  
   - WebAPI Info → <http://127.0.0.1/WebAPI/info>  
   - RStudio → <http://127.0.0.1/hades>  
     - User: `ohdsi`  
     - Pass: `mypass`

4. **(From RStudio) Run Achilles on IRIS**

   Open **RStudio** at `http://127.0.0.1/hades`, then run **one** of:

   ### A) Default mode (no params)
   Uses defaults (IRIS at `host.docker.internal:1972/USER`, CDM `OMOPCDM53`, RESULTS `OMOPCDM55_RESULTS`, SCRATCH `OMOPCDM55_SCRATCH`). It:
   - Ensures the IRIS connection
   - Ensures core RESULTS tables
   - Skips Achilles SQL regeneration if RESULTS already exist
   - Populates `ACHILLES_RESULT_CONCEPT` and a WebAPI-shaped `CONCEPT_HIERARCHY`
   - Adds small IRIS-safe indexes
   - Always clears WebAPI caches (silently skipped if WebAPI database isn’t reachable).

   ```r
   # Either path works (symlink points to the same file):
   source("~/scripts/hades/initialize_results_iris.R")
   # or
   source("/opt/hades/scripts/initialize_results_iris.R")
   ```

   ### B) With parameters (override defaults)
   ```r
   sys.source(
     "~/scripts/hades/initialize_results_iris.R",
     envir = list2env(list(
       # IRIS connection
       irisConnStr      = "jdbc:IRIS://host.docker.internal:1972/USER",
       irisUser         = "_SYSTEM",
       irisPassword     = "_SYSTEM",
       jdbcDriverFolder = "/opt/hades/jdbc_drivers",

       # Schemas and labels
       cdmSchema        = "OMOPCDM53",
       resultsSchema    = "OMOPCDM55_RESULTS",
       scratchSchema    = "OMOPCDM55_SCRATCH",
       sourceName       = "Client CDM on IRIS",

       # Achilles controls
       cdmVersion       = "5.3",
       excludeAnalyses  = c(802),
       numThreads       = 1L,
       smallCellCount   = 5L,
       forceAchilles    = FALSE,

       atlasSourceId    = 2L,
       pgHost           = "broadsea-atlasdb",
       pgPort           = 5432L,
       pgDatabase       = "postgres",
       pgUser           = "postgres",
       pgPassword       = "mypass"
     ))
   )
   ```

5. **(From RStudio) Wipe CDM + RESULTS**

   The **wipe script** (`wipe_omop_iris.R`) will:
   - Connect to IRIS via JDBC
   - Drop **all views, all foreign keys, and all tables** in both the CDM schema (`OMOPCDM53`) and RESULTS schema (`OMOPCDM55_RESULTS`)
   - Recreate the schema shells (empty markers) so they remain visible
   - Bust ATLAS/WebAPI caches in Postgres

   **Usage (RStudio console):**
   ```r
   # Either path works:
   source("~/scripts/hades/wipe_omop_iris.R")
   # or
   source("/opt/hades/scripts/wipe_omop_iris.R")
   ```

   This will **completely remove all data and tables** in CDM + RESULTS.  
   You must re-run `initialize_results_iris.R` afterwards to re-create the tables and repopulate data.

## Notes
- `.env` is committed for zero-touch setup; adjust values if needed.
- `bundle/` is not in the repo — volume tarballs are Release assets.
- Apple Silicon only: images/services are configured for `linux/arm64`.
- The IRIS JDBC driver is automatically placed in `/opt/hades/jdbc_drivers` inside the HADES container.

## Troubleshooting (run from repo root: `ohdsi-iris-macos-env`)
- **View logs for a service**
  ```bash
  docker compose -f Broadsea/docker-compose.yml --env-file Broadsea/.env logs -f <service-name>
  ```
- **Force fresh volume downloads**
  ```bash
  ./scripts/replica.sh --fresh
  ```
- **Re-run full restore** (tear down containers, remove volumes, fresh rebuild)
  ```bash
  # Stop and remove the stack (uses the compose files inside Broadsea/)
  docker compose -f Broadsea/docker-compose.yml --env-file Broadsea/.env down

  # Remove the data volumes
  docker volume rm dbvolume atlasdb-postgres-data rstudio-home-data rstudio-tmp-data rstudio-rsite-data

  # Rebuild everything with fresh volume downloads
  ./scripts/replica.sh --fresh
  ```
