#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/OHDSI/Broadsea.git"
TARGET_DIR="Broadsea"
CONFIG_DIR="$(pwd)/config"
VOLDIR="$(pwd)/bundle/volumes"
IRIS_IMAGE="intersystems/iris-community:2025.1"
IRIS_CONTAINER="my-iris"

# Same profiles you use
PROFILES=(webapi-from-git content hades atlasdb atlas-from-image)

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found"; exit 1; }; }
compose_cmd() { command -v docker-compose >/dev/null 2>&1 && echo "docker-compose" || echo "docker compose"; }

restore_volume() {
  local vol="$1" tar="${VOLDIR}/${vol}.tar"
  [[ -f "$tar" ]] || { echo "WARN: missing $tar (skip)"; return; }
  echo ">>> Restoring $vol"
  docker volume create "$vol" >/dev/null
  docker run --rm -v "${vol}:/target" -v "$VOLDIR":/backup alpine \
    sh -c "cd /target && tar -xf /backup/${vol}.tar"
}

# Bring up a single compose service without deps; print logs if it fails
up1() {
  local svc="$1"
  $CMD --env-file .env "${PROFILE_FLAGS[@]}" up -d --no-deps "$svc" || {
    echo "ERROR: failed to start $svc"
    $CMD logs --no-log-prefix --tail=120 "$svc" || true
    exit 1
  }
}

# Wait for a container to reach healthy (or at least running) state
wait_healthy() {
  local name="$1" timeout="${2:-90}" elapsed=0
  echo ">>> Waiting for $name to be healthy (timeout ${timeout}s)"
  while true; do
    local status
    status="$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null || echo running)"
    if [[ "$status" == "healthy" || "$status" == "running" ]]; then
      echo "    $name: $status"
      return 0
    fi
    sleep 3; elapsed=$((elapsed+3))
    if (( elapsed >= timeout )); then
      echo "WARN: $name not healthy after ${timeout}s (status: $status)"
      docker logs --tail=200 "$name" || true
      return 0
    fi
  done
}

# ---------- Preflight ----------
need git; need docker
CMD="$(compose_cmd)"
[[ -d "$VOLDIR" ]] || { echo "ERROR: $VOLDIR not found"; exit 1; }

# Fresh clone
[[ -d "$TARGET_DIR" ]] && { echo ">>> Removing old $TARGET_DIR"; rm -rf "$TARGET_DIR"; }
echo ">>> Cloning Broadsea"; git clone "$REPO_URL" "$TARGET_DIR"
cd "$TARGET_DIR"

# Replace config with your known-good files
cp "$CONFIG_DIR/.env" ./.env
cp "$CONFIG_DIR/docker-compose.yml" ./docker-compose.yml
mkdir -p ./jdbc
if compgen -G "$CONFIG_DIR/jdbc/*" >/dev/null; then cp "$CONFIG_DIR/jdbc/"* ./jdbc/; fi

# Preflight: .env + Traefik files must exist
# shellcheck disable=SC1091
. ./.env 2>/dev/null || true
: "${HTTP_TYPE:=http}"
for f in "./traefik/traefik_${HTTP_TYPE}.yml" "./traefik/tls_${HTTP_TYPE}.yml" "./traefik/routers.yml"; do
  [[ -f "$f" ]] || { echo "ERROR: missing Traefik file: $f"; exit 1; }
done

# Validate compose (env interpolation & mounts)
echo ">>> Validating docker-compose.yml"
$CMD --env-file .env config >/dev/null

# Show what will start (handy on a new Mac)
echo ">>> Services with current profiles:"
PROFILE_FLAGS=(); for p in "${PROFILES[@]}"; do PROFILE_FLAGS+=( --profile "$p" ); done
$CMD --env-file .env "${PROFILE_FLAGS[@]}" config --services

# ---------- Restore replicated volumes BEFORE any containers ----------
restore_volume "dbvolume"
restore_volume "atlasdb-postgres-data"
restore_volume "rstudio-home-data"
restore_volume "rstudio-tmp-data"

# ---------- IRIS two-step (ownership fix -> final run) ----------
echo ">>> Preparing IRIS durable volume permissions"
docker rm -f "$IRIS_CONTAINER" >/dev/null 2>&1 || true
docker pull "$IRIS_IMAGE" >/dev/null
docker run --name "$IRIS_CONTAINER" -d -v dbvolume:/durable "$IRIS_IMAGE"
docker exec -u root "$IRIS_CONTAINER" chown -R irisowner:irisowner /durable || true
docker rm -f "$IRIS_CONTAINER" >/dev/null 2>&1 || true

echo ">>> Starting IRIS"
docker run --name "$IRIS_CONTAINER" -d \
  -p 1972:1972 -p 52773:52773 \
  -v dbvolume:/durable \
  -e ISC_DATA_DIRECTORY=/durable/iris \
  "$IRIS_IMAGE"

# ---------- Broadsea bring-up (sequenced & resilient) ----------
echo ">>> Pulling images"
$CMD --env-file .env "${PROFILE_FLAGS[@]}" pull

echo ">>> Creating containers (no start)"
$CMD --env-file .env "${PROFILE_FLAGS[@]}" up --no-start

# Traefik first (routing ready early)
up1 traefik

# Start DB then wait healthy
up1 broadsea-atlasdb
wait_healthy broadsea-atlasdb 120

# WebAPI (from git) then Atlas (from image)
# If you sometimes switch to -from-image WebAPI or -from-git Atlas, these will just skip the missing one.
( docker ps --format '{{.Names}}' | grep -q '^ohdsi-webapi' ) || true
up1 ohdsi-webapi-from-git || true
up1 ohdsi-atlas-from-image || true

# HADES and Content
up1 broadsea-hades || true
up1 broadsea-content || true

# Finally, bring up any remaining selected-profile services
$CMD --env-file .env "${PROFILE_FLAGS[@]}" up -d

echo ""
echo "Done."
echo "Open:"
echo "  - IRIS:     http://localhost:52773/csp/sys/UtilHome.csp"
echo "  - WebAPI:   http://localhost/webapi/WebAPI/info"
echo "  - ATLAS:    http://localhost/atlas"
echo "  - HADES:    http://localhost/hades  (user: ${HADES_USER:-ohdsi} / pass: ${HADES_PASSWORD:-mypass})"
