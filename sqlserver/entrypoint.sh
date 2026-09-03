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

# A crash dump is several GB and the default dump directory is on the volume, so one crash
# fills a 5 GB Railway volume and every later boot then fails on ENOSPC. Clear any dump left
# by a previous container and keep new ones off the volume entirely.
rm -rf "$DATA_ROOT"/log/core.* "$DATA_ROOT"/log/*.mdmp "$DATA_ROOT"/log/*.dmp 2>/dev/null || true
mkdir -p /var/opt/mssql-dumps
chown "$MSSQL_UID:$MSSQL_GID" /var/opt/mssql-dumps
export MSSQL_DUMP_DIR=/var/opt/mssql-dumps
log "volume free: $(df -Pk "$DATA_ROOT" | awk 'NR==2 {printf "%d MiB of %d MiB", $4/1024, $2/1024}')"

# ---------------------------------------------------------------------------
# Sizing. SQL Server reads the host's CPU count and memory, not the container's cgroup, so
# on Railway's 48-core hosts it sizes its thread pools and memory target for a machine it
# does not have. Narrow the affinity mask ourselves and give it an explicit memory ceiling.
# ---------------------------------------------------------------------------
CPUS=8
if [ -r /sys/fs/cgroup/cpu.max ]; then
  read -r quota period < /sys/fs/cgroup/cpu.max || true
  if [ "${quota:-max}" != "max" ] && [ -n "${period:-}" ] && [ "$period" -gt 0 ]; then
    CPUS=$(( quota / period ))
    [ "$CPUS" -lt 1 ] && CPUS=1
  fi
fi
MEM_MB="${MSSQL_MEMORY_LIMIT_MB:-}"
if [ -z "$MEM_MB" ] && [ -r /sys/fs/cgroup/memory.max ]; then
  MAXMEM="$(cat /sys/fs/cgroup/memory.max)"
  if [ "$MAXMEM" != "max" ]; then
    MEM_MB=$(( MAXMEM / 1048576 * 40 / 100 ))
  fi
fi
[ -z "$MEM_MB" ] && MEM_MB=2048
export MSSQL_MEMORY_LIMIT_MB="$MEM_MB"

# mssql.conf is instance state written by SQL Server's own setup — never regenerate it.
# The coredump and dump-location settings are reachable through mssql-conf instead, and both
# are best-effort: a failure here must not stop the server from starting.
if [ -f "$DATA_ROOT/mssql.conf" ]; then
  /opt/mssql/bin/mssql-conf set coredump.coredumptype mini >/dev/null 2>&1 || true
  /opt/mssql/bin/mssql-conf set coredump.captureminiandfull false >/dev/null 2>&1 || true
fi

# Print the tail of the previous boot's error log: SQL Server writes the real reason for a
# fatal startup there, while stdout only carries the generic "fatal error" line.
if [ -f "$DATA_ROOT/log/errorlog" ]; then
  log "---- previous errorlog (last 40 lines) ----"
  tail -n 40 "$DATA_ROOT/log/errorlog" | tr -d '\r' | sed 's/^/[errorlog] /' || true
  log "---- end previous errorlog ----"
fi

log "sizing: cpus=$CPUS memorylimitmb=$MEM_MB"

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

log "starting SQL Server (edition ${MSSQL_PID:-developer}) as uid $MSSQL_UID on cpus 0-$((CPUS - 1))"
exec setpriv --reuid="$MSSQL_UID" --regid="$MSSQL_GID" --init-groups taskset -c "0-$((CPUS - 1))" "$@"
