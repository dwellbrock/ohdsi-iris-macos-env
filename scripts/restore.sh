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

# 0) Prepare secrets (create files so compose doesn't fail)
mkdir -p "$SECRETS_DIR"

# Map of env var -> file path (from .env)
declare -A SECRET_FILES=(
  [HADES_PASSWORD_FILE]="${HADES_PASSWORD_FILE:-./secrets/hades_password.txt}"
  [GITHUB_PAT_SECRET_FILE]="${GITHUB_PAT_SECRET_FILE:-./secrets/github_pat.txt}"
  [WEBAPI_DATASOURCE_PASSWORD_FILE]="${WEBAPI_DATASOURCE_PASSWORD_FILE:-./secrets/webapi_datasource_password.txt}"
  [SECURITY_LDAP_SYSTEM_PASSWORD_FILE]="${SECURITY_LDAP_SYSTEM_PASSWORD_FILE:-./secrets/openldap_admin_password.txt}"
  [SECURITY_DB_DATASOURCE_PASSWORD_FILE]="${SECURITY_DB_DATASOURCE_PASSWORD_FILE:-./secrets/security_db_password.txt}"
  [SECURITY_AD_SYSTEM_PASSWORD_FILE]="${SECURITY_AD_SYSTEM_PASSWORD_FILE:-./secrets/security_ad_password.txt}"
  [SECURITY_OAUTH_GOOGLE_APISECRET_FILE]="${SECURITY_OAUTH_GOOGLE_APISECRET_FILE:-./secrets/google_api_secret.txt}"
  [SECURITY_OAUTH_FACEBOOK_APISECRET_FILE]="${SECURITY_OAUTH_FACEBOOK_APISECRET_FILE:-./secrets/facebook_api_secret.txt}"
  [SECURITY_OAUTH_GITHUB_APISECRET_FILE]="${SECURITY_OAUTH_GITHUB_APISECRET_FILE:-./secrets/github_oauth_secret.txt}"
  [SECURITY_SAML_KEYMANAGER_STOREPASSWORD_FILE]="${SECURITY_SAML_KEYMANAGER_STOREPASSWORD_FILE:-./secrets/saml_store_password.txt}"
  [SECURITY_SAML_KEYMANAGER_PASSWORDS_ARACHNENETWORK_FILE]="${SECURITY_SAML_KEYMANAGER_PASSWORDS_ARACHNENETWORK_FILE:-./secrets/saml_arachne_password.txt}"
  [SOLR_VOCAB_JDBC_PASSWORD_FILE]="${SOLR_VOCAB_JDBC_PASSWORD_FILE:-./secrets/solr_vocab_jdbc_password.txt}"
  [VOCAB_PG_PASSWORD_FILE]="${VOCAB_PG_PASSWORD_FILE:-./secrets/vocab_pg_password.txt}"
  [OPENLDAP_ADMIN_PASSWORD_FILE]="${OPENLDAP_ADMIN_PASSWORD_FILE:-./secrets/openldap_admin_password.txt}"
  [OPENLDAP_ACCOUNT_PASSWORDS_FILE]="${OPENLDAP_ACCOUNT_PASSWORDS_FILE:-./secrets/openldap_accounts_passwords.txt}"
  [PHOEBE_PG_PASSWORD_FILE]="${PHOEBE_PG_PASSWORD_FILE:-./secrets/phoebe_pg_password.txt}"
  [UMLS_API_KEY_FILE]="${UMLS_API_KEY_FILE:-./secrets/umls_api_key.txt}"
  [CDM_CONNECTIONDETAILS_PASSWORD_FILE]="${CDM_CONNECTIONDETAILS_PASSWORD_FILE:-./secrets/cdm_connectiondetails_password.txt}"
  [WEBAPI_CDM_SNOWFLAKE_PRIVATE_KEY_FILE]="${WEBAPI_CDM_SNOWFLAKE_PRIVATE_KEY_FILE:-./secrets/webapi_cdm_snowflake_private_key.txt}"
  [PGADMIN_DEFAULT_PASSWORD_FILE]="${PGADMIN_DEFAULT_PASSWORD_FILE:-./secrets/pgadmin_default_password.txt}"
)

# Ensure files exist (populate placeholders)
for key in "${!SECRET_FILES[@]}"; do
  f="${SECRET_FILES[$key]}"
  if [ ! -f "$f" ]; then
    # Special-case HADES: write real password from .env (default: mypass)
    if [ "$key" = "HADES_PASSWORD_FILE" ]; then
      printf "%s" "${HADES_PASSWORD:-mypass}" > "$f"
    else
      printf "%s" "placeholder" > "$f"
    fi
  fi
done

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

# 2) Create external volumes (only for the tarballs present)
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
docker run --rm -u 0 -v dbvolume:/durable intersystems/iris-community:2025.1 \
  chown -R 51773:51773 /durable || true

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
