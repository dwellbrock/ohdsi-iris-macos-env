#!/usr/bin/env bash
set -euo pipefail

# Usage: ./scripts/restore.sh [bundle_dir]
# Expects volume tarballs under: <bundle_dir>/volumes/*.tar
# Default bundle_dir is ./bundle

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUNDLE_DIR="${1:-./bundle}"
VOLDIR="$BUNDLE_DIR/volumes"
SECRETS_DIR="./secrets"

echo "==> Repo root: $REPO_ROOT"
echo "==> Bundle dir: $BUNDLE_DIR"
echo "==> Volume dir: $VOLDIR"
echo "==> Secrets dir: $SECRETS_DIR"

# 0) Ensure required secret files exist (Compose will fail hard if missing)
mkdir -p "$SECRETS_DIR"

# Load .env if present to pick up *_FILE paths and HADES_PASSWORD
if [ -f ".env" ]; then
  # shellcheck disable=SC1091
  . ./.env 2>/dev/null || true
fi

# Helper: ensure a secret file exists with content
ensure_secret() {
  local path="$1"
  local value="$2"
  if [ ! -f "$path" ]; then
    printf "%s" "$value" > "$path"
  fi
}

# Defaults if *_FILE vars are unset
: "${HADES_PASSWORD:=mypass}"
: "${HADES_PASSWORD_FILE:=./secrets/hades_password.txt}"
: "${GITHUB_PAT_SECRET_FILE:=./secrets/github_pat.txt}"
: "${WEBAPI_DATASOURCE_PASSWORD_FILE:=./secrets/webapi_datasource_password.txt}"
: "${SECURITY_LDAP_SYSTEM_PASSWORD_FILE:=./secrets/openldap_admin_password.txt}"
: "${SECURITY_DB_DATASOURCE_PASSWORD_FILE:=./secrets/security_db_password.txt}"
: "${SECURITY_AD_SYSTEM_PASSWORD_FILE:=./secrets/security_ad_password.txt}"
: "${SECURITY_OAUTH_GOOGLE_APISECRET_FILE:=./secrets/google_api_secret.txt}"
: "${SECURITY_OAUTH_FACEBOOK_APISECRET_FILE:=./secrets/facebook_api_secret.txt}"
: "${SECURITY_OAUTH_GITHUB_APISECRET_FILE:=./secrets/github_oauth_secret.txt}"
: "${SECURITY_SAML_KEYMANAGER_STOREPASSWORD_FILE:=./secrets/saml_store_password.txt}"
: "${SECURITY_SAML_KEYMANAGER_PASSWORDS_ARACHNENETWORK_FILE:=./secrets/saml_arachne_password.txt}"
: "${SOLR_VOCAB_JDBC_PASSWORD_FILE:=./secrets/solr_vocab_jdbc_password.txt}"
: "${VOCAB_PG_PASSWORD_FILE:=./secrets/vocab_pg_password.txt}"
: "${OPENLDAP_ADMIN_PASSWORD_FILE:=./secrets/openldap_admin_password.txt}"
: "${OPENLDAP_ACCOUNT_PASSWORDS_FILE:=./secrets/openldap_accounts_passwords.txt}"
: "${PHOEBE_PG_PASSWORD_FILE:=./secrets/phoebe_pg_password.txt}"
: "${UMLS_API_KEY_FILE:=./secrets/umls_api_key.txt}"
: "${CDM_CONNECTIONDETAILS_PASSWORD_FILE:=./secrets/cdm_connectiondetails_password.txt}"
: "${WEBAPI_CDM_SNOWFLAKE_PRIVATE_KEY_FILE:=./secrets/webapi_cdm_snowflake_private_key.txt}"
: "${PGADMIN_DEFAULT_PASSWORD_FILE:=./secrets/pgadmin_default_password.txt}"

# Create secrets (real values where we know them; placeholders elsewhere)
ensure_secret "$HADES_PASSWORD_FILE"                 "$HADES_PASSWORD"
ensure_secret "$WEBAPI_DATASOURCE_PASSWORD_FILE"     "mypass"
ensure_secret "$GITHUB_PAT_SECRET_FILE"              "placeholder"
ensure_secret "$SECURITY_LDAP_SYSTEM_PASSWORD_FILE"  "placeholder"
ensure_secret "$SECURITY_DB_DATASOURCE_PASSWORD_FILE" "placeholder"
ensure_secret "$SECURITY_AD_SYSTEM_PASSWORD_FILE"    "placeholder"
ensure_secret "$SECURITY_OAUTH_GOOGLE_APISECRET_FILE" "placeholder"
ensure_secret "$SECURITY_OAUTH_FACEBOOK_APISECRET_FILE" "placeholder"
ensure_secret "$SECURITY_OAUTH_GITHUB_APISECRET_FILE" "placeholder"
ensure_secret "$SECURITY_SAML_KEYMANAGER_STOREPASSWORD_FILE" "placeholder"
ensure_secret "$SECURITY_SAML_KEYMANAGER_PASSWORDS_ARACHNENETWORK_FILE" "placeholder"
ensure_secret "$SOLR_VOCAB_JDBC_PASSWORD_FILE"       "placeholder"
ensure_secret "$VOCAB_PG_PASSWORD_FILE"              "placeholder"
ensure_secret "$OPENLDAP_ADMIN_PASSWORD_FILE"        "placeholder"
ensure_secret "$OPENLDAP_ACCOUNT_PASSWORDS_FILE"     "placeholder"
ensure_secret "$PHOEBE_PG_PASSWORD_FILE"             "placeholder"
ensure_secret "$UMLS_API_KEY_FILE"                   "placeholder"
ensure_secret "$CDM_CONNECTIONDETAILS_PASSWORD_FILE" "placeholder"
ensure_secret "$WEBAPI_CDM_SNOWFLAKE_PRIVATE_KEY_FILE" "placeholder"
ensure_secret "$PGADMIN_DEFAULT_PASSWORD_FILE"       "placeholder"

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

# 4) IRIS ownership fix (irisowner uid/gid = 51773) — override image entrypoint
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
echo "  - RStudio: http://localhost:8787  (user: ${HADES_USER:-ohdsi} / pass: ${HADES_PASSWORD})"
