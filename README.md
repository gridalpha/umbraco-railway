# Umbraco CMS on Railway

Deployment sources for running [Umbraco CMS](https://umbraco.com) — the open-source
ASP.NET Core content management system — on [Railway](https://railway.com), as two
services built from this one repository.

| Service | Dockerfile | Public | Volume |
|---|---|---|---|
| `umbraco` | `Dockerfile` | yes | `/data` |
| `sqlserver` | `sqlserver/Dockerfile` (`RAILWAY_DOCKERFILE_PATH`) | no | `/var/opt/mssql` |

## Why this shape

- **SQL Server, not SQLite.** Umbraco supports exactly two databases, and its own
  documentation positions SQLite as a development database. SQL Server runs here in the
  free **Express** edition (`MSSQL_PID=Express`), which is licensed for production use.
- **Umbraco 17 LTS, floating.** `Umbraco.Cms` is referenced as `17.*`, so every rebuild
  picks up the newest patch on the long-term-support line (fixes to 2027-11, security to
  2028-11). Umbraco's own project template offers the same `17.*` choice for LTS.
- **One volume per service.** Railway volumes are 1:1, so everything Umbraco writes —
  media, `umbraco/Data`, logs, Data Protection keys, and the backoffice-editable Views,
  css and scripts folders — lives under `/data` and is symlinked into place at boot.
- **Single instance.** Umbraco scales out by load balancing, which requires shared file
  storage across instances; Umbraco ships a first-party provider for Azure Blob only, and
  a Railway volume cannot be shared. Run one replica.

## Configuration

`umbraco` composes its connection string from discrete variables, all of which have
private-network defaults:

| Variable | Default | Notes |
|---|---|---|
| `DB_HOST` | `sqlserver.railway.internal` | |
| `DB_PORT` | `1433` | |
| `DB_NAME` | `umbraco` | must match `UMBRACO_DB_NAME` on `sqlserver` |
| `DB_USER` | `umbraco` | must match `UMBRACO_DB_USER` on `sqlserver` |
| `DB_PASSWORD` | — | required; reference `sqlserver`'s `UMBRACO_DB_PASSWORD` |
| `ConnectionStrings__umbracoDbDSN` | — | set this to bypass all of the above and use an external SQL Server |

Umbraco's own settings are supplied as standard .NET configuration environment
variables, for example `Umbraco__CMS__Unattended__UnattendedUserEmail`. The first
backoffice user is created by Umbraco's unattended install on first boot; the backoffice
has no public sign-up.

`sqlserver` creates the database and a login scoped to it (`db_owner` on that database
only, no rights elsewhere on the instance) from `UMBRACO_DB_NAME`, `UMBRACO_DB_USER` and
`UMBRACO_DB_PASSWORD`. The login's password is re-applied on every boot, so rotating the
Railway variable rotates the credential.

## Health

`umbraco` serves `GET /healthz`, which returns 200 only once Umbraco's runtime level is
`Run` — that is, the database is reachable and the schema is installed. `sqlserver` serves
no HTTP and therefore has no Railway health check; its liveness is proved by that probe.

## Licence

Umbraco CMS is MIT licensed. The `sqlserver` service uses Microsoft's SQL Server container
image; deploying it sets `ACCEPT_EULA=Y`, which accepts the
[Microsoft SQL Server licence terms](https://go.microsoft.com/fwlink/?linkid=857698) on
your behalf, and selects the free Express edition.
