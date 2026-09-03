#!/bin/bash
# SQL Server for Umbraco on Railway — container entrypoint.
#
# Takes ownership of the Railway volume, bootstraps Umbraco's database and its scoped login
# in the background, then runs SQL Server as the image's own unprivileged mssql user.
set -euo pipefail

MSSQL_UID=10001
MSSQL_GID=0
DATA_ROOT=/var/opt/mssql
PORT_TCP="${MSSQL_TCP_PORT:-1433}"

DB_NAME="${UMBRACO_DB_NAME:-umbraco}"
DB_USER="${UMBRACO_DB_USER:-umbraco}"
DB_PASS="${UMBRACO_DB_PASSWORD:-}"

log() { echo "[entrypoint] $*"; }

if [ -z "${MSSQL_SA_PASSWORD:-}" ]; then
  log "FATAL: MSSQL_SA_PASSWORD is not set."
  exit 1
fi

# ---------------------------------------------------------------------------
# Volume ownership. The image runs as uid 10001 and never chowns its data directory, so a
# freshly mounted Railway volume is unwritable until this runs.
# ---------------------------------------------------------------------------
mkdir -p "$DATA_ROOT/data" "$DATA_ROOT/log" "$DATA_ROOT/backup" "$DATA_ROOT/secrets"
if [ "$(stat -c '%u' "$DATA_ROOT")" != "$MSSQL_UID" ]; then
  chown -R "$MSSQL_UID:$MSSQL_GID" "$DATA_ROOT"
  log "took ownership of $DATA_ROOT"
fi
chmod 0750 "$DATA_ROOT"

# ---------------------------------------------------------------------------
# Bootstrap Umbraco's database in the background so SQL Server stays the container's main
# process. Idempotent, and bounded so a genuine failure still surfaces in the log.
# ---------------------------------------------------------------------------
bootstrap() {
  if [ -z "$DB_PASS" ]; then
    log "UMBRACO_DB_PASSWORD is unset — skipping database bootstrap."
    return 0
  fi
  case "$DB_PASS$DB_NAME$DB_USER" in
    *'"'*|*"'"*|*'`'*)
      log "FATAL: database name, user and password must not contain quotes or backticks."
      return 1
      ;;
  esac

  export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"
  local sqlcmd=/opt/mssql-tools18/bin/sqlcmd
  local i
  for i in $(seq 1 120); do
    if "$sqlcmd" -S "127.0.0.1,$PORT_TCP" -U sa -C -b -Q "SELECT 1" >/dev/null 2>&1; then
      log "SQL Server accepting connections after ${i} attempt(s)."
      break
    fi
    sleep 5
  done

  local script
  script="$(mktemp /tmp/umbraco-setup.XXXXXX.sql)"
  chmod 600 "$script"
  {
    printf ':setvar DBNAME "%s"\n' "$DB_NAME"
    printf ':setvar DBUSER "%s"\n' "$DB_USER"
    printf ':setvar DBPASS "%s"\n' "$DB_PASS"
    cat /usr/local/share/umbraco-setup.sql
  } > "$script"

  for i in $(seq 1 20); do
    if "$sqlcmd" -S "127.0.0.1,$PORT_TCP" -U sa -C -b -d master -i "$script"; then
      log "database bootstrap complete for [$DB_NAME] / login [$DB_USER]."
      rm -f "$script"
      return 0
    fi
    log "database bootstrap attempt $i failed; retrying."
    sleep 10
  done

  rm -f "$script"
  log "ERROR: database bootstrap did not complete."
  return 1
}
bootstrap &

# ---------------------------------------------------------------------------
# Railway's private network is IPv6-first. SQL Server on Linux binds IPv4 only unless told
# otherwise, so add an IPv6 listener alongside it. If SQL Server already answers on [::],
# the bind fails and this exits quietly — it is a fallback, not a requirement.
# ---------------------------------------------------------------------------
(
  sleep 20
  if socat "TCP6-LISTEN:$PORT_TCP,ipv6only=1,fork,reuseaddr" "TCP4:127.0.0.1:$PORT_TCP" 2>/tmp/socat.err; then
    :
  else
    echo "[entrypoint] IPv6 relay not started (SQL Server is probably already dual-stack): $(cat /tmp/socat.err 2>/dev/null)"
  fi
) &

log "starting SQL Server (edition ${MSSQL_PID:-developer}) as uid $MSSQL_UID"
exec setpriv --reuid="$MSSQL_UID" --regid="$MSSQL_GID" --init-groups "$@"
