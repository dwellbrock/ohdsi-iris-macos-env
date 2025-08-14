# OHDSI IRIS macOS Env (Apple Silicon)

Turn-key **InterSystems IRIS + OHDSI Broadsea** environment for macOS (M1/M2)  
with all databases, RStudio packages, and configuration pre-restored from  
**saved Docker volumes**.

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
- **InterSystems IRIS** — Preloaded OMOP CDM 5.4 + vocabularies + results schema.
- **OHDSI WebAPI & ATLAS** — Built from upstream source via Broadsea.
- **RStudio/HADES** — Apple Silicon compatible, with JDBC driver and packages installed.
- **Traefik** — Reverse proxy for consistent `http://localhost/...` URLs.


## Prerequisites
- [Docker Desktop for macOS (Apple Silicon)](https://www.docker.com/products/docker-desktop/)
- [Homebrew](https://brew.sh/) (package manager for macOS, required for installing `gh`)
- # Git Quick Install & Setup (macOS with Homebrew)

  This guide installs Git using [Homebrew](https://brew.sh/) and configures essential global settings so you can start committing right away.

  ## Install Git
  Ensure [Homebrew](https://brew.sh/) is installed on your system, then run:

  ```bash
  brew install git && \
  git config --global user.name "Your Name" && \
  git config --global user.email "you@example.com" && \
  git config --global init.defaultBranch main && \
  git config --global color.ui auto && \
  git config --list
  ```

## Quick start

All commands below should be run in your macOS Terminal.

1. Clone the repo and enter it:
   ```bash
   git clone https://github.com/dwellbrock/ohdsi-iris-macos-env.git
   cd ohdsi-iris-macos-env
   ```

2. Make the replica script executable and run it:
   ```bash
   chmod +x scripts/replica.sh
   ./scripts/replica.sh
   ```
   
   This will:
   - Clone the official Broadsea repository fresh.
   - Apply the preconfigured `.env`, `docker-compose.yml`, and JDBC drivers.
   - Download the four required Docker volume snapshots from  
      [v2025-08-13 release](https://github.com/dwellbrock/ohdsi-iris-macos-env/releases/tag/v2025-08-13).
   - Restore the volumes into Docker.
   - Start the IRIS + Broadsea stack with the correct profiles for Apple Silicon.

3. **Access the services:**
   - IRIS Portal → http://localhost:52773/csp/sys/UtilHome.csp  
     - User: `_SYSTEM`  
     - Pass: `_SYSTEM`
   - ATLAS → http://localhost/atlas  
   - WebAPI Info → http://localhost/WebAPI/info  
   - RStudio → http://localhost/hades  
     - User: `ohdsi`  
     - Pass: `mypass`

## Notes
- `.env` is committed for zero-touch setup; adjust values if needed.
- `bundle/` is not in the repo — volume tarballs are Release assets.
- Apple Silicon only: images/services are configured for `linux/arm64`.

## Troubleshooting
- View logs for a service:
  docker compose logs -f <service-name>

- Re-run restore (if a volume was created empty):
  docker compose down
  docker volume rm dbvolume atlasdb-postgres-data rstudio-home-data rstudio-tmp-data
  ./scripts/restore.sh

- IRIS permission issues: the restore script runs a chown fix for /durable (uid/gid 51773).
