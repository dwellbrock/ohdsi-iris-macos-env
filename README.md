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
- [GitHub CLI (`gh`)](https://cli.github.com/) for automated release downloads  
  *(Alternatively, download volume tarballs manually from the [Releases](https://github.com/dwellbrock/ohdsi-iris-macos-env/releases) page)*

## Quick start

1. Clone the repo and enter it:
   ```bash
   git clone https://github.com/dwellbrock/ohdsi-iris-macos-env.git
   cd ohdsi-iris-macos-env
   ```

2. Install GitHub CLI (if not already installed) and download volume snapshots:
   ```bash
   brew install gh
   mkdir -p ./bundle/volumes
   gh release download --repo dwellbrock/ohdsi-iris-macos-env --pattern "*.tar" --dir bundle/volumes --clobber
   ```

3. Restore data & start the stack:
   ```bash
   ./scripts/restore.sh
   If you get a permission error:
   chmod +x scripts/restore.sh
   ./scripts/restore.sh
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
