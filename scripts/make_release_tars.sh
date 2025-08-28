#!/usr/bin/env bash
set -euo pipefail

# make_release_tars.sh — Export Broadsea/IRIS volumes to tar files for release uploads.
#
# Volumes:
#   - dbvolume              (IRIS database: CDM, vocab, results)
#   - atlasdb-postgres-data (Postgres WebAPI metadata + source config)
#   - rstudio-home-data     (RStudio packages, scripts, configs)
#   - rstudio-tmp-data      (RStudio tmp)
#   - rstudio-rsite-data    (RStudio site cache/config)
#
# Usage:
#   chmod +x make_release_tars.sh
#   ./make_release_tars.sh                   # writes to ./bundle by default
#   ./make_release_tars.sh --outdir ./dist   # choose output directory
#   ./make_release_tars.sh --no-stop         # do NOT stop the broadsea-hades container
#
# Notes:
# - By default, we stop the 'broadsea-hades' container during the export to avoid
#   in-flight writes. It will be started again afterward.
# - The tars are *uncompressed* to match the restore logic in replica.sh (tar -xf).
# - The script prints SHA256 checksums you can paste into replica.sh's SHAS array.

OUTDIR="./bundle"
STOP_CONTAINERS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --outdir)
      OUTDIR="${2:-}"; shift 2 ;;
    --no-stop)
      STOP_CONTAINERS=0; shift ;;
    -h|--help)
      sed -n '1,60p' "$0"
      exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1 ;;
  esac
done

VOLS=(
  "dbvolume"
  "atlasdb-postgres-data"
  "rstudio-home-data"
  "rstudio-tmp-data"
  "rstudio-rsite-data"
)

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found"; exit 1; }; }
need docker

mkdir -p "$OUTDIR"

HADES="broadsea-hades"
START_HADES_AFTER=0

cleanup() {
  if [[ "$START_HADES_AFTER" == "1" ]]; then
    echo ">>> Starting ${HADES} again"
    docker start "$HADES" >/dev/null || true
  fi
}
trap cleanup EXIT

if (( STOP_CONTAINERS )); then
  if docker ps --format '{{.Names}}' | grep -q "^${HADES}\$"; then
    echo ">>> Stopping ${HADES} (to quiesce writes)…"
    docker stop -t 10 "$HADES" >/dev/null || true
    START_HADES_AFTER=1
  else
    echo ">>> ${HADES} not running (no need to stop)."
  fi
else
  echo ">>> --no-stop provided: not stopping ${HADES}."
fi

echo ">>> Exporting volumes to: ${OUTDIR}"
for vol in "${VOLS[@]}"; do
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    echo "WARN: volume '$vol' not found — skipping."
    continue
  fi
  out="${OUTDIR}/${vol}.tar"
  echo ">>> Creating ${out}"
  docker run --rm -v "${vol}:/src:ro" -v "${OUTDIR}:/dest" alpine sh -lc "cd /src && tar -cf \"/dest/$(basename "$out")\" ."
done

# Print SHA256 checksums
echo
echo ">>> SHA256 checksums:"
HAS_SHASUM=0
if command -v shasum >/dev/null 2>&1; then HAS_SHASUM=1; fi

for vol in "${VOLS[@]}"; do
  f="${OUTDIR}/${vol}.tar"
  [[ -f "$f" ]] || continue
  if [[ "$HAS_SHASUM" -eq 1 ]]; then
    sum=$(shasum -a 256 "$f" | awk '{print $1}')
  else
    sum=$(sha256sum "$f" | awk '{print $1}')
  fi
  printf "  %s  %s\n" "$sum" "$(basename "$f")"
done

echo
echo ">>> Done. Upload the tar files in ${OUTDIR} to your GitHub Release."
echo ">>> IMPORTANT - Remember to update the SHAS array in scripts/replica.sh!"