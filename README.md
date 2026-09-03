# Umbraco CMS on Railway

Deployment sources for running [Umbraco CMS](https://umbraco.com) — the open-source
ASP.NET Core content management system — on [Railway](https://railway.com), as two
services built from this one repository.

| Service | Dockerfile | Public | Volume |
|---|---|---|---|
| `umbraco` | `Dockerfile` | yes | `/data` |

`sqlserver/` holds a SQL Server Express service that is **not deployed on Railway** — see
below — but is kept because it is a working image for platforms whose block storage SQL
Server supports.

## Why this shape

- **SQLite on the volume, with SQL Server as an override.** Umbraco supports exactly two
  databases: SQL Server and SQLite. SQL Server **cannot run on a Railway volume**: it starts,
  opens `master`, logs `There have been 256 misaligned log IOs which required falling back to
  synchronous IO` against `master.mdf`, and then dies with `This program has encountered a
  fatal error and cannot continue running` — measured 2026-09-03 on `2022-latest`. So the
  default database here is SQLite, kept on the volume. Point `ConnectionStrings__umbracoDbDSN`
  (or the `DB_*` variables) at a managed SQL Server — Azure SQL, or a SQL Server you host
  elsewhere — for a write-heavy or multi-editor site.
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
