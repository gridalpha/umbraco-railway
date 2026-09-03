#!/bin/bash
# Umbraco CMS on Railway — container entrypoint.
#
# Prepares the single Railway volume, links every writable directory onto it, builds the
# SQL Server connection string from discrete variables, then drops privileges and runs the app.
set -euo pipefail

APP_UID="${APP_UID:-1654}"
DATA_DIR="${DATA_DIR:-/data}"

log() { echo "[entrypoint] $*"; }

# ---------------------------------------------------------------------------
# Persistent layout. Railway allows one volume per service, so everything Umbraco or the
# backoffice writes lives under $DATA_DIR and is symlinked back into the app directory.
# ---------------------------------------------------------------------------
for d in umbraco-data umbraco-logs media views css scripts dataprotection-keys; do
  mkdir -p "$DATA_DIR/$d"
done

# Copy Umbraco's shipped defaults into the volume without overwriting operator edits, so a
# new release's partials also arrive on upgrade. GNU cp: -n is no-clobber.
seed_dir() {
  local src="$1" dst="$2"
  [ -d "$src" ] || return 0
  cp -rn "$src"/. "$dst"/ 2>/dev/null || true
  log "seeded $dst from $src -> $(ls -A "$dst" | wc -l) entries"
}
seed_dir /app/seed/Views   "$DATA_DIR/views"
seed_dir /app/seed/css     "$DATA_DIR/css"
seed_dir /app/seed/scripts "$DATA_DIR/scripts"

link_dir() {
  local src="$1" dst="$2"
  rm -rf "$dst"
  mkdir -p "$(dirname "$dst")"
  ln -sfn "$src" "$dst"
}
link_dir "$DATA_DIR/umbraco-data" /app/umbraco/Data
link_dir "$DATA_DIR/umbraco-logs" /app/umbraco/Logs
link_dir "$DATA_DIR/media"        /app/wwwroot/media
link_dir "$DATA_DIR/views"        /app/Views
link_dir "$DATA_DIR/css"          /app/wwwroot/css
link_dir "$DATA_DIR/scripts"      /app/wwwroot/scripts

export DATAPROTECTION_KEYS_PATH="${DATAPROTECTION_KEYS_PATH:-$DATA_DIR/dataprotection-keys}"

# Telemetry site id. Generated once and kept on the volume so it is stable across deploys
# and unique per installation, instead of every deployment of this repo sharing one id.
if [ -z "${Umbraco__CMS__Global__Id:-}" ]; then
  [ -s "$DATA_DIR/site-id" ] || cat /proc/sys/kernel/random/uuid > "$DATA_DIR/site-id"
  Umbraco__CMS__Global__Id="$(cat "$DATA_DIR/site-id")"
  export Umbraco__CMS__Global__Id
fi

# ---------------------------------------------------------------------------
# Database. An operator can set ConnectionStrings__umbracoDbDSN directly to point at an
# external SQL Server; otherwise it is composed from discrete values whose private-network
# defaults are deterministic and therefore safe on a first-ever (template) deploy.
# ---------------------------------------------------------------------------
if [ -z "${ConnectionStrings__umbracoDbDSN:-}" ]; then
  if [ -n "${DB_PASSWORD:-}" ]; then
    : "${DB_HOST:=sqlserver.railway.internal}"
    : "${DB_PORT:=1433}"
    : "${DB_NAME:=umbraco}"
    : "${DB_USER:=umbraco}"
    export ConnectionStrings__umbracoDbDSN="Server=${DB_HOST},${DB_PORT};Database=${DB_NAME};User Id=${DB_USER};Password=${DB_PASSWORD};Encrypt=true;TrustServerCertificate=true;Connect Timeout=15;"
    export ConnectionStrings__umbracoDbDSN_ProviderName="Microsoft.Data.SqlClient"
    log "database target ${DB_USER}@${DB_HOST},${DB_PORT}/${DB_NAME} (SQL Server)"
  else
    # SQLite lives in Umbraco's own data directory, which is on the volume. |DataDirectory|
    # resolves to umbraco/Data. Set DB_PASSWORD (or the whole connection string) to point at
    # an external SQL Server instead.
    export ConnectionStrings__umbracoDbDSN="Data Source=|DataDirectory|/Umbraco.sqlite.db;Cache=Shared;Foreign Keys=True;Pooling=True"
    export ConnectionStrings__umbracoDbDSN_ProviderName="Microsoft.Data.Sqlite"
    log "database target SQLite at ${DATA_DIR}/umbraco-data/Umbraco.sqlite.db"
  fi
fi
unset DB_PASSWORD

# ---------------------------------------------------------------------------
# Ownership. A Railway volume arrives root-owned and the app runs as $APP_UID. Recurse only
# when the directory itself is still root-owned, so a large media tree is chowned once.
# ---------------------------------------------------------------------------
for d in umbraco-data umbraco-logs media views css scripts dataprotection-keys; do
  if [ "$(stat -c '%u' "$DATA_DIR/$d")" != "$APP_UID" ]; then
    chown -R "$APP_UID:$APP_UID" "$DATA_DIR/$d"
    log "took ownership of $DATA_DIR/$d"
  fi
done
if [ -f "$DATA_DIR/site-id" ]; then chown "$APP_UID:$APP_UID" "$DATA_DIR/site-id"; fi

log "starting Umbraco as uid $APP_UID"
exec gosu "$APP_UID" dotnet /app/UmbracoCms.dll
