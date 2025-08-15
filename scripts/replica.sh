#!/usr/bin/env bash
set -euo pipefail

# ───────────────────────── Repo/Release (fixed to your tag) ─────────────────────────
REPO_OWNER="dwellbrock"
REPO_NAME="ohdsi-iris-macos-env"
VOLS_RELEASE_TAG="v2025-08-13"

# ───────────────────────── Local layout ─────────────────────────
TARGET_DIR="Broadsea"                   # fresh clone target
CONFIG_DIR="$(pwd)/config"              # contains .env, docker-compose.yml, jdbc/
DOWNLOAD_DIR="$(pwd)/.downloads/volumes"
IRIS_IMAGE="intersystems/iris-community:2025.1"
IRIS_CONTAINER="my-iris"

# Compose profiles (your original bring-up)
PROFILES=(webapi-from-git content hades atlasdb atlas-from-image)

# Release assets + SHA256 (order matters; macOS bash 3.x safe)
VOLS=( \
  "dbvolume" \
  "atlasdb-postgres-data" \
  "rstudio-home-data" \
  "rstudio-tmp-data" \
  "rstudio-rsite-data" \
)

SHAS=( \
  "f8523f1654445f0a9bb41c6503fd978afe713123af3139d5275a391ba9a083f6" \
  "e71652ea8d1249ab2b8652456176e46c8fa85c67d259d88e1feb7dc3a0a8225a" \
  "5e27fea6eb62d159fac70fb1696f98fde8d2a78c0bfc7c34799625a9173288c1" \
  "6331fc108e1014ce8eea3433a1e937a0775c6b5042f9dac1c97ad0ae37ad9135" \
  "a2e9b048972075ce93f86ff9a64ea5df3c8a00beae02bc17be0e1347386f3162" \
)

# ───────────────────────── Helpers ─────────────────────────
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found"; exit 1; }; }
compose_cmd() { command -v docker-compose >/dev/null 2>&1 && echo "docker-compose" || echo "docker compose"; }

dl() { # resumable curl download
  local url="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  echo ">>> Downloading: $url"
  curl -fL --retry 3 --retry-delay 2 -C - -o "$out" "$url"
}

verify_sha256() {
  local file="$1" expected="$2"
  echo ">>> Verifying checksum for $(basename "$file")"
  if command -v shasum >/dev/null 2>&1; then
    local got
    got="$(shasum -a 256 "$file" | awk '{print $1}')"
    [[ "$got" == "$expected" ]] || { echo "ERROR: SHA256 mismatch ($got != $expected)"; exit 1; }
  elif command -v sha256sum >/dev/null 2>&1; then
    local got
    got="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$got" == "$expected" ]] || { echo "ERROR: SHA256 mismatch ($got != $expected)"; exit 1; }
  else
    echo "WARN: no shasum/sha256sum; skipping verification"
  fi
}

restore_volume_from_tar() {
  local vol="$1" tarpath="$2"
  [[ -f "$tarpath" ]] || { echo "WARN: missing $tarpath (skip restore)"; return 0; }
  echo ">>> Restoring volume: ${vol}"
  docker volume create "$vol" >/dev/null
  docker run --rm -v "${vol}:/target" -v "$(dirname "$tarpath")":/backup alpine \
    sh -c "cd /target && tar -xf /backup/$(basename "$tarpath")"
}

up1() {
  local svc="$1"
  $CMD --env-file .env "${PROFILE_FLAGS[@]}" up -d --no-deps "$svc" || {
    echo "ERROR: failed to start $svc"
    $CMD logs --no-log-prefix --tail=120 "$svc" || true
    exit 1
  }
}

wait_healthy() {
  local name="$1" timeout="${2:-150}" elapsed=0
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

# ───────────────────────── Preflight ─────────────────────────
need git; need docker; need curl
CMD="$(compose_cmd)"

# ───────────────────────── Download volume tarballs ─────────────────────────
echo "==> Using release tag: $VOLS_RELEASE_TAG"
mkdir -p "$DOWNLOAD_DIR"
for i in "${!VOLS[@]}"; do
  vol="${VOLS[$i]}"
  sha="${SHAS[$i]}"
  url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${VOLS_RELEASE_TAG}/${vol}.tar"
  out="${DOWNLOAD_DIR}/${vol}.tar"
  dl "$url" "$out"
  verify_sha256 "$out" "$sha"
done

# ───────────────────────── Fresh Broadsea clone ─────────────────────────
[[ -d "$TARGET_DIR" ]] && { echo ">>> Removing old $TARGET_DIR"; rm -rf "$TARGET_DIR"; }
echo ">>> Cloning Broadsea"
git clone "https://github.com/OHDSI/Broadsea.git" "$TARGET_DIR"
cd "$TARGET_DIR"

# Replace config with your known-good versions
cp "$CONFIG_DIR/.env" ./.env
cp "$CONFIG_DIR/docker-compose.yml" ./docker-compose.yml
mkdir -p ./jdbc
if compgen -G "$CONFIG_DIR/jdbc/*" >/dev/null; then cp "$CONFIG_DIR/jdbc/"* ./jdbc/; fi

# Preflight: Traefik files exist for chosen HTTP_TYPE (from .env)
# shellcheck disable=SC1091
. ./.env 2>/dev/null || true
: "${HTTP_TYPE:=http}"
for f in "./traefik/traefik_${HTTP_TYPE}.yml" "./traefik/tls_${HTTP_TYPE}.yml" "./traefik/routers.yml"; do
  [[ -f "$f" ]] || { echo "ERROR: missing Traefik file: $f"; exit 1; }
done

# Validate compose before we start pulling anything
echo ">>> Validating docker-compose.yml"
$CMD --env-file .env config >/dev/null

echo ">>> Services with current profiles:"
PROFILE_FLAGS=(); for p in "${PROFILES[@]}"; do PROFILE_FLAGS+=( --profile "$p" ); done
$CMD --env-file .env "${PROFILE_FLAGS[@]}" config --services

# ───────────────────────── Restore volumes BEFORE containers ─────────────────────────
restore_volume_from_tar "dbvolume"                 "${DOWNLOAD_DIR}/dbvolume.tar"
restore_volume_from_tar "atlasdb-postgres-data"    "${DOWNLOAD_DIR}/atlasdb-postgres-data.tar"
restore_volume_from_tar "rstudio-home-data"        "${DOWNLOAD_DIR}/rstudio-home-data.tar"
restore_volume_from_tar "rstudio-tmp-data"         "${DOWNLOAD_DIR}/rstudio-tmp-data.tar"
restore_volume_from_tar "rstudio-rsite-data"         "${DOWNLOAD_DIR}/rstudio-rsite-data.tar"

# ───────────────────────── IRIS two-step ─────────────────────────
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

# ───────────────────────── Broadsea bring-up (ordered) ─────────────────────────
echo ">>> Pulling images"
$CMD --env-file .env "${PROFILE_FLAGS[@]}" pull

echo ">>> Creating containers (no start)"
$CMD --env-file .env "${PROFILE_FLAGS[@]}" up --no-start

# Traefik early, then DB, then webapi/atlas, then the rest
up1 traefik
up1 broadsea-atlasdb
wait_healthy broadsea-atlasdb 150

up1 ohdsi-webapi-from-git || true
up1 ohdsi-atlas-from-image || true
up1 broadsea-hades || true
up1 broadsea-content || true

# Bring up remaining selected-profile services
$CMD --env-file .env "${PROFILE_FLAGS[@]}" up -d

echo ""
echo "Done."
echo "  - IRIS:     http://localhost:52773/csp/sys/UtilHome.csp"
echo "  - WebAPI:   http://127.0.0.1/WebAPI/info"
echo "  - ATLAS:    http://127.0.0.1/atlas"
echo "  - HADES:    http://127.0.0.1/hades  (user: ${HADES_USER:-ohdsi} / pass: ${HADES_PASSWORD:-mypass})"
