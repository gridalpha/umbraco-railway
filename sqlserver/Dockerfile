# SQL Server for Umbraco on Railway.
#
# Umbraco supports SQL Server and SQLite only, and documents SQLite as a development
# database — so the production topology needs a SQL Server instance. Build context is the
# repository root.

FROM mcr.microsoft.com/mssql/server:2022-latest

USER root

# setpriv drops back to the image's own mssql user after the volume is chowned; socat is a
# fallback IPv6 listener, because Railway's private network is IPv6-first.
RUN apt-get update \
 && apt-get install -y --no-install-recommends socat \
 && rm -rf /var/lib/apt/lists/* \
 && command -v setpriv >/dev/null \
 && command -v socat >/dev/null \
 && command -v taskset >/dev/null \
 && test -x /opt/mssql-tools18/bin/sqlcmd

COPY sqlserver/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY sqlserver/setup.sql /usr/local/share/umbraco-setup.sql
RUN chmod +x /usr/local/bin/entrypoint.sh \
 && bash -n /usr/local/bin/entrypoint.sh

# Keep the databases one level below the volume mount root, beside Railway's lost+found.
ENV ACCEPT_EULA=Y \
    MSSQL_PID=Express \
    MSSQL_DATA_DIR=/var/opt/mssql/data \
    MSSQL_LOG_DIR=/var/opt/mssql/log \
    MSSQL_BACKUP_DIR=/var/opt/mssql/backup

EXPOSE 1433
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/opt/mssql/bin/sqlservr"]
