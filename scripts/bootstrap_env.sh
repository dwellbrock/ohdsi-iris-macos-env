#!/usr/bin/env bash
set -euo pipefail

# ───────────────────────── Repo/Release (fixed to your tag) ─────────────────────────
REPO_OWNER="dwellbrock"
REPO_NAME="ohdsi-iris-macos-env"
REPO_ROOT="$(pwd)"
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
  "fc5ba39582b8d8727322a755afbf861b50557b9bbf0959f18a07c360c7976ad4" \
  "bf27595a223ea21dc0d53619d01bf7761f456970966af00da9ca258b03d4f3a9" \
  "e7ce51fbd0fb68e3cb2a500c2801e645ffd9257f73677ca106d547af58cf4e3d" \
  "d3516c1b288fb3c65126e6cb6e72b7fd10bc25d464c250faf0fff3b220e53941" \
  "682b240386bcc7ef2044836fba6a11bd4b2f0920cae5dfb621f91bc808b47502" \
)

# ───────────────────────── Flags ─────────────────────────
FRESH=0
for arg in "$@"; do
  [[ "$arg" == "--fresh" ]] && FRESH=1
done

# ───────────────────────── Helpers ─────────────────────────
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found"; exit 1; }; }
compose_cmd() { command -v docker-compose >/dev/null 2>&1 && echo "docker-compose" || echo "docker compose"; }

dl() { # resumable curl download
  local url="$1" out="$2"
  mkdir -p "$(dirname "$out")"
  echo ">>> Downloading: $url"
  # Try resume; if that fails (e.g., 416) we'll retry fresh in the caller
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

# Non-exiting check for cached files
valid_sha256() {
  local file="$1" expected="$2"
  if command -v shasum >/dev/null 2>&1; then
    local got
    got="$(shasum -a 256 "$file" | awk '{print $1}')"
    [[ "$got" == "$expected" ]]
    return
  elif command -v sha256sum >/dev/null 2>&1; then
    local got
    got="$(sha256sum "$file" | awk '{print $1}')"
    [[ "$got" == "$expected" ]]
    return
  fi
  # If no tool is available, treat as not valid to force a fresh verify later.
  return 1
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

wait_for_container() {
  local name="$1" ; local t0
  t0=$(date +%s)
  echo ">>> Waiting for container: $name"
  while true; do
    if docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -q true; then
      break
    fi
    sleep 1
    if [ $(( $(date +%s) - t0 )) -gt 120 ]; then
      echo "WARN: $name not running after 120s; continuing anyway."
      break
    fi
  done
}

bootstrap_hades_java() {
  echo ">>> Bootstrapping Java (rJava) inside broadsea-hades"
  wait_for_container broadsea-hades
  docker exec -u root broadsea-hades bash -lc '
    set -e
    NEED_JAVA=0
    if ! command -v javac >/dev/null 2>&1; then
      NEED_JAVA=1
    fi

    if [ "$NEED_JAVA" -eq 1 ]; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y default-jdk
      R CMD javareconf
    else
      R CMD javareconf || true
    fi

    touch /etc/R/Renviron.site
    grep -q "^JAVA_HOME=" /etc/R/Renviron.site || echo "JAVA_HOME=/usr/lib/jvm/default-java" >> /etc/R/Renviron.site
    grep -q "LD_LIBRARY_PATH=.*lib/server" /etc/R/Renviron.site || echo "LD_LIBRARY_PATH=\${JAVA_HOME}/lib/server:\${LD_LIBRARY_PATH}" >> /etc/R/Renviron.site

    R -q -e "library(rJava); .jinit(); sessionInfo()" >/dev/null 2>&1 || { echo "WARN: rJava sanity check failed"; exit 0; }
  '
  docker restart broadsea-hades >/dev/null 2>&1 || true
}

bootstrap_hades_jdbc() {
  echo ">>> Installing IRIS JDBC into broadsea-hades"

  local CANDIDATES=(
    "./jdbc/intersystems-jdbc-3.10.3.jar"
    "$REPO_ROOT/config/jdbc/intersystems-jdbc-3.10.3.jar"
    "$REPO_ROOT/Broadsea/jdbc/intersystems-jdbc-3.10.3.jar"
  )
  local JAR=""
  for p in "${CANDIDATES[@]}"; do
    if [ -f "$p" ]; then JAR="$p"; break; fi
  done

  if [ -z "$JAR" ]; then
    echo ">>> JDBC jar not found locally; downloading to ./jdbc/"
    mkdir -p ./jdbc
    JAR="./jdbc/intersystems-jdbc-3.10.3.jar"
    curl -fsSL -o "$JAR" \
      https://repo1.maven.org/maven2/com/intersystems/intersystems-jdbc/3.10.3/intersystems-jdbc-3.10.3.jar
  fi

  docker exec -u root broadsea-hades bash -lc 'mkdir -p /opt/hades/jdbc_drivers'
  docker cp "$JAR" broadsea-hades:/opt/hades/jdbc_drivers/

  docker exec -u root broadsea-hades bash -lc '
    if id -u rstudio >/dev/null 2>&1; then
      chown -R rstudio:$(id -gn rstudio) /opt/hades || true
    else
      echo "NOTE: user \"rstudio\" not found in image; leaving ownership as-is"
    fi
  '
}

bootstrap_hades_scripts() {
  echo ">>> Installing initialize_results_iris.R (home is canonical: ~/scripts/hades; /opt is symlink)"

  local SRC="${CONFIG_DIR}/hades/initialize_results_iris.R"
  if [ ! -f "$SRC" ]; then
    echo "ERROR: Script not found at ${SRC}"
    exit 1
  fi

  wait_for_container broadsea-hades
  docker cp "$SRC" broadsea-hades:/tmp/initialize_results_iris.R.new

  docker exec -u root broadsea-hades bash -lc '
    set -euo pipefail

    pick_user() {
      local u
      if [ -n "${HADES_USER:-}" ] && id -u "$HADES_USER" >/dev/null 2>&1; then echo "$HADES_USER"; return; fi
      for u in rstudio ohdsi; do
        if id -u "$u" >/dev/null 2>&1; then echo "$u"; return; fi
      done
      getent passwd | awk -F: '"'"'$3>=1000{print $1; exit}'"'"'
    }

    RS_USER="$(pick_user)"
    [ -n "$RS_USER" ] || { echo "ERROR: Could not detect UI login user."; exit 1; }
    RS_HOME="$(getent passwd "$RS_USER" | awk -F: '"'"'{print $6}'"'"')"
    [ -n "$RS_HOME" ] || { echo "ERROR: Could not resolve home for $RS_USER."; exit 1; }
    RS_GROUP="$(id -gn "$RS_USER" 2>/dev/null || echo "$RS_USER")"

    DEST_DIR="$RS_HOME/scripts/hades"
    mkdir -p "$DEST_DIR" /opt/hades/scripts

    tgt="$DEST_DIR/initialize_results_iris.R"
    mv -f /tmp/initialize_results_iris.R.new "$tgt"
    chown "$RS_USER:$RS_GROUP" "$tgt" || true
    chmod 0644 "$tgt" || true

    rm -f /opt/hades/scripts/initialize_results_iris.R
    ln -s "$tgt" /opt/hades/scripts/initialize_results_iris.R
    chown -h "$RS_USER:$RS_GROUP" /opt/hades/scripts/initialize_results_iris.R || true

    echo ">>> Script installed to: $tgt"
    ls -l "$tgt"
    echo ">>> /opt shortcut:"
    ls -l /opt/hades/scripts/initialize_results_iris.R
  '

  echo ">>> Edit in RStudio:   ~/scripts/hades/initialize_results_iris.R"
  echo ">>> CLI shortcut:      /opt/hades/scripts/initialize_results_iris.R"
}

# Copy any single R script by filename from config/hades/ → ~/scripts/hades/ and symlink under /opt/hades/scripts/
bootstrap_copy_script() {
  local FILENAME="$1"   # e.g., wipe_omop_iris.R
  local SRC="${CONFIG_DIR}/hades/${FILENAME}"

  echo ">>> Installing ${FILENAME} (home is canonical: ~/scripts/hades; /opt is symlink)"
  if [ ! -f "$SRC" ]; then
    echo "WARN: ${SRC} not found — skipping."
    return 0
  fi

  wait_for_container broadsea-hades
  docker cp "$SRC" broadsea-hades:/tmp/"${FILENAME}".new

  docker exec -u root broadsea-hades bash -lc '
    set -euo pipefail

    pick_user() {
      local u
      if [ -n "${HADES_USER:-}" ] && id -u "$HADES_USER" >/dev/null 2>&1; then echo "$HADES_USER"; return; fi
      for u in rstudio ohdsi; do if id -u "$u" >/dev/null 2>&1; then echo "$u"; return; fi; done
      getent passwd | awk -F: '"'"'$3>=1000{print $1; exit}'"'"'
    }

    RS_USER="$(pick_user)"
    RS_HOME="$(getent passwd "$RS_USER" | awk -F: '"'"'{print $6}'"'"')"
    RS_GROUP="$(id -gn "$RS_USER" 2>/dev/null || echo "$RS_USER")"

    DEST_DIR="$RS_HOME/scripts/hades"
    mkdir -p "$DEST_DIR" /opt/hades/scripts

    tgt="$DEST_DIR/'"$FILENAME"'"
    mv -f /tmp/'"$FILENAME"'.new "$tgt"
    chown "$RS_USER:$RS_GROUP" "$tgt" || true
    chmod 0644 "$tgt" || true

    rm -f /opt/hades/scripts/'"$FILENAME"'
    ln -s "$tgt" /opt/hades/scripts/'"$FILENAME"'
    chown -h "$RS_USER:$RS_GROUP" /opt/hades/scripts/'"$FILENAME"' || true

    ls -l "$tgt"
    ls -l /opt/hades/scripts/'"$FILENAME"'
  '
}

fix_rstudio_home_permissions() {
  echo ">>> Ensuring detected RStudio home is writable by the login user"
  wait_for_container broadsea-hades
  docker exec -u root broadsea-hades bash -lc '
    set -euo pipefail

    pick_user() {
      local u
      if [ -n "${HADES_USER:-}" ] && id -u "$HADES_USER" >/dev/null 2>&1; then
        echo "$HADES_USER"; return
      fi
      for u in rstudio ohdsi; do
        if id -u "$u" >/dev/null 2>&1; then echo "$u"; return; fi
      done
      getent passwd | awk -F: '"'"'$3>=1000{print $1; exit}'"'"'
    }

    RS_USER="$(pick_user)"
    if [ -z "$RS_USER" ]; then
      echo "ERROR: Could not detect RStudio user for permission fix."
      exit 1
    fi
    RS_HOME="$(getent passwd "$RS_USER" | awk -F: '"'"'{print $6}'"'"')"
    RS_GROUP="$(id -gn "$RS_USER" 2>/dev/null || echo "$RS_USER")"

    echo ">>> Detected user: $RS_USER (home: $RS_HOME, group: $RS_GROUP)"
    mkdir -p "$RS_HOME"
    chown -R "$RS_USER:$RS_GROUP" "$RS_HOME"
    find "$RS_HOME" -type d -exec chmod u+rwx,go+rx {} +
    find "$RS_HOME" -type f -exec chmod u+rw,go+r {} +
  '
}

# ───────────────────────── Preflight ─────────────────────────
need git; need docker; need curl
CMD="$(compose_cmd)"

# ───────────────────────── Download volume tarballs ─────────────────────────
echo "==> Using release tag: $VOLS_RELEASE_TAG"
if [[ "$FRESH" -eq 1 ]]; then
  echo ">>> --fresh: removing cached downloads at $DOWNLOAD_DIR"
  rm -rf "$DOWNLOAD_DIR"
fi
mkdir -p "$DOWNLOAD_DIR"

for i in "${!VOLS[@]}"; do
  vol="${VOLS[$i]}"
  sha="${SHAS[$i]}"
  url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${VOLS_RELEASE_TAG}/${vol}.tar"
  out="${DOWNLOAD_DIR}/${vol}.tar"

  if [[ -f "$out" && -s "$out" ]]; then
    if valid_sha256 "$out" "$sha"; then
      echo ">>> Using cached ${vol}.tar (checksum OK) — skipping download"
      continue
    else
      echo ">>> Cached ${vol}.tar failed checksum — removing and re-downloading"
      rm -f "$out"
    fi
  fi

  if ! dl "$url" "$out"; then
    echo ">>> Download resume failed; retrying with a fresh full download…"
    rm -f "$out"
    curl -fL --retry 3 --retry-delay 2 -o "$out" "$url"
  fi

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
restore_volume_from_tar "rstudio-rsite-data"       "${DOWNLOAD_DIR}/rstudio-rsite-data.tar"

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
echo ">>> Starting stack"
$CMD --env-file .env "${PROFILE_FLAGS[@]}" up -d

echo ">>> Bootstrapping Java (for rJava + DatabaseConnector in broadsea-hades)"
bootstrap_hades_java

echo ">>> Installing JDBC driver for HADES"
bootstrap_hades_jdbc

echo ">>> Installing initialize_results_iris.R script for HADES"
bootstrap_hades_scripts

echo ">>> Installing Wipe (Nuke & Pave) R script for HADES"
bootstrap_copy_script "wipe_omop_iris.R"

echo ">>> Fixing /home/rstudio permissions"
fix_rstudio_home_permissions

echo ""
echo "Done."
echo "  - IRIS:     http://localhost:52773/csp/sys/UtilHome.csp"
echo "  - WebAPI:   http://127.0.0.1/WebAPI/info"
echo "  - ATLAS:    http://127.0.0.1/atlas"
echo "  - HADES:    http://127.0.0.1/hades  (user: ${HADES_USER:-ohdsi} / pass: ${HADES_PASSWORD:-mypass})"
