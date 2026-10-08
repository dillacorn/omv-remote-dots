# Seerr

Maintained media-request application for Jellyfin, Sonarr and Radarr.

## Deployment template

- Image: `ghcr.io/seerr-team/seerr:v3.5.0`
- Database: SQLite at `/app/config/db/db.sqlite3`
- App configuration: `./seerr/config` on the host, mounted at `/app/config`
- Application service: `seerr`, with Docker init enabled and image user UID/GID 1000
- Tailscale sidecar: `tailscale-seerr`, with persistent `./ts/state`
- Internal Tailscale Serve endpoint: HTTPS -> `http://127.0.0.1:5055` (tailnet only)

Set `TS_AUTHKEY` locally, or reuse the existing Tailscale state when upgrading. Do not commit real credentials. For optional LAN access through the Pi-hole/Nginx reverse proxy, include `compose.local-webapps.yml` when deploying and configure the corresponding certificate mount.

Open `https://<machine>.<tailnet>.ts.net` with Tailscale connected. The machine name is managed by Tailscale; renaming it in the Tailscale admin console does **not** rename the Docker containers or directories.

## Existing Jellyseerr installations

**This directory is the clean-name template, not an in-place migration script.** A live Seerr installation upgraded from Jellyseerr can legitimately still be running under its older Compose project, service, container names and `/docker/jellyseerr` directory.

Before adopting `/docker/seerr` on such a host:

1. Confirm the actual running image, Compose files (including any `compose.override.yml`), volume mounts and Tailscale node identity. Back up the live Seerr SQLite database, `settings.json`, all application configuration, the Compose files, and persistent Tailscale `ts/state`.
2. Plan the directory and Compose project rename together. Point `SEERR_CONFIG_PATH` at the **existing, verified** Seerr data; do not allow a fresh empty database to replace the migrated one. Keep the old data and database backups for rollback.
3. Preserve the existing Tailscale state so the renamed sidecar retains its identity and MagicDNS address. Never run two Tailscale sidecars simultaneously against the same state. Review local reverse-proxy, certificate-renewal, Watchtower and restart-script references before renaming containers.
4. Apply only the intended Compose project once the old containers are safely stopped. Verify the HTTPS endpoint, Jellyfin login, preserved requests/users, and Sonarr/Radarr integration before removing unused containers or paths.

New installations require a writable app configuration directory for UID/GID 1000. Seerr uses SQLite without a MariaDB service.

The [official migration guide](https://docs.seerr.dev/migration-guide/) covers application-level Jellyseerr-to-Seerr upgrades.
