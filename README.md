# OHDSI IRIS macOS Env (Apple Silicon)

One-click, preconfigured **InterSystems IRIS + OHDSI Broadsea** stack for macOS (M1/M2).  
Images are pulled from GHCR; database state is restored from volume snapshots.

## What’s included
- **IRIS** with Eunomia/OMOP CDM + vocab + results (persisted in `dbvolume`)
- **OHDSI WebAPI & ATLAS** (prebuilt images)
- **RStudio/HADES** with preinstalled packages for Apple Silicon
- **Traefik** reverse proxy (HTTP/HTTPS)

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

2. Restore data & run replica.sh script:
   ```bash
   chmod +x scripts/replica.sh
   ./scripts/replica.sh
   ```
   
## URLs
- IRIS Portal → http://localhost:52773/csp/sys/UtilHome.csp  
  - User: `_SYSTEM`  
  - Pass: `_SYSTEM`
- WebAPI Info → http://localhost/webapi/WebAPI/info  
- ATLAS → http://localhost/atlas  
- RStudio → http://localhost:8787  
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
