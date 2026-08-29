# Karakeep

Karakeep was previously named Hoarder.

The current example uses a Tailscale sidecar and Tailscale Serve for remote HTTPS access. The Karakeep web service shares the sidecar's network namespace and listens on port `3000`.

## Setup

Copy the examples:

```bash
cp compose_example.yml compose.yml
cp .env_example .env
```

Set the values in `.env`, especially:

- `TS_AUTHKEY`
- `MEILI_MASTER_KEY`
- `NEXTAUTH_URL`
- `NEXTAUTH_SECRET`

For a tailnet hostname such as `karakeep.example-tailnet.ts.net`, set:

```text
NEXTAUTH_URL=https://karakeep.example-tailnet.ts.net
```

Start normally:

```bash
docker compose up -d
```

## Offline LAN path through Pi-hole

Create the shared network once:

```bash
docker network inspect local-webapps >/dev/null 2>&1 ||
    docker network create local-webapps
```

Then start Karakeep with the optional LAN overlay:

```bash
docker compose \
    -f compose.yml \
    -f compose.local-webapps.yml \
    up -d
```

This leaves Tailscale Serve intact for remote clients while allowing `nginx-pihole` to reach Karakeep directly at `tailscale-karakeep:3000` over Docker when the WAN is unavailable.
