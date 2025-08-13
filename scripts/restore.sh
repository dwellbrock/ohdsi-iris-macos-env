#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/restore.sh [bundle_dir]
# Expects volume tarballs under: <bundle_dir>/volumes/*.tar
# Default bundle_dir is ./bundle

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUNDLE_DIR="${1:-./bundle}"
VOLDIR="$BUNDLE_DIR/volumes"

echo "==> Repo root: $REPO_ROOT"
echo "==> Bundle dir: $BUNDLE_DIR"
echo "==> Volume dir: $VOLDIR"

# 1) Validate volumes bundle
if [ ! -d "$VOLDIR" ]; then
  echo "ERROR: volume bundle dir not found: $VOLDIR"
  echo "Place your tarballs in: $VOLDIR  (e.g., dbvolume.tar, atlasdb-postgres-data.tar, rstudio-home-data.tar, rstudio-tmp-data.tar)"
  exit 1
fi

shopt -s nullglob
tars=( "$VOLDIR"/*.tar )
if [ ${#tars[@]} -eq 0 ]; then
  echo "ERROR: no *.tar files found in $VOLDIR"
  exit 1
fi

# 2) Create external volumes (for each tarball present)
echo ">>> Creating Docker volumes"
for tarfile in "${tars[@]}"; do
  volname="$(basename "$tarfile" .tar)"
  echo "  - $volname"
  docker volume create "$volname" >/dev/null
done

# 3) Restore data into each volume
echo ">>> Restoring data to volumes"
for tarfile in "${tars[@]}"; do
  volname="$(basename "$tarfile" .tar)"
  echo "  - $volname"
  docker run --rm -v "${volname}:/target" -v "$VOLDIR":/backup alpine \
    sh -c "cd /target && tar -xf /backup/${volname}.tar"
done

# 4) IRIS ownership fix (irisowner uid/gid = 51773)
echo ">>> Fixing IRIS volume ownership (dbvolume)"
docker run --rm -u 0 \
  -v dbvolume:/durable \
  --entrypoint /bin/chown \
  intersystems/iris-community:2025.1 \
  -R 51773:51773 /durable || true

# 5) Pull + start
echo ">>> Pulling images"
docker compose pull

echo ">>> Starting stack"
docker compose up -d

echo "Done."
echo "Open:"
echo "  - IRIS:   http://localhost:52773/csp/sys/UtilHome.csp"
echo "  - WebAPI: http://localhost/webapi/WebAPI/info"
echo "  - ATLAS:  http://localhost/atlas"
echo "  - RStudio: http://localhost:8787  (user: ${HADES_USER:-ohdsi} / pass: ${HADES_PASSWORD:-mypass})"
