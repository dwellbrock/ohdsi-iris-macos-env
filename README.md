# OHDSI IRIS macOS Env (Apple Silicon)

One-click, preconfigured **InterSystems IRIS + OHDSI Broadsea** stack for macOS (M1/M2).  
Images are pulled from GHCR; database state is restored from volume snapshots.

## What’s included
- **IRIS** with Eunomia/OMOP CDM + vocab + results (persisted in `dbvolume`)
- **OHDSI WebAPI & ATLAS** (prebuilt images)
- **RStudio/HADES** with preinstalled packages for Apple Silicon
- **Traefik** reverse proxy (HTTP/HTTPS)

## Prerequisites
- Docker Desktop for macOS (Apple Silicon)
- (If images are private) a GHCR Personal Access Token with `read:packages`

## Quick start

1. Clone and enter the repo:
   git clone https://github.com/dwellbrock/ohdsi-iris-macos-env.git
   cd ohdsi-iris-macos-env

2. Login to GHCR (skip if images are public):
   echo "<YOUR_GHCR_TOKEN>" | docker login ghcr.io -u dwellbrock --password-stdin

3. Download volume snapshots from Releases and place them here:
   ./bundle/volumes/dbvolume.tar
   ./bundle/volumes/atlasdb-postgres-data.tar
   ./bundle/volumes/rstudio-home-data.tar
   ./bundle/volumes/rstudio-tmp-data.tar

4. Restore data & start the stack:
   ./scripts/restore.sh

   If you get a permission error, make the script executable then re-run:
   chmod +x scripts/restore.sh
   ./scripts/restore.sh

## URLs
- IRIS Portal → http://localhost:52773/csp/sys/UtilHome.csp
- WebAPI Info → http://localhost/webapi/WebAPI/info
- ATLAS → http://localhost/atlas
- RStudio → http://localhost:8787
  - User: ohdsi
  - Pass: mypass

## Notes
- .env is committed for zero-touch setup; adjust values if needed.
- Do not commit volume tarballs to the repo—upload them to a GitHub Release.
- Apple Silicon only: images/services are configured for linux/arm64.

## Troubleshooting
- View logs for a service:
  docker compose logs -f <service-name>

- Re-run restore (if a volume was created empty):
  docker compose down
  docker volume rm dbvolume atlasdb-postgres-data rstudio-home-data rstudio-tmp-data
  ./scripts/restore.sh

- IRIS permission issues: the restore script runs a chown fix for /durable (uid/gid 51773).
