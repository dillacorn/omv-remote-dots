# Pi-hole local HTTPS routing

This setup keeps local web-app access working even when the Internet or the Tailscale control plane is unavailable.

## Traffic paths

Local LAN clients:

```text
service.example-tailnet.ts.net
  -> Pi-hole local DNS
  -> LAN server IP
  -> nginx-pihole:443
  -> local-webapps Docker network
  -> application HTTP port
```

Remote Tailscale clients continue using each service's normal remote path. Most services use a Tailscale Serve sidecar. Obico is intentionally different: its web app shares the Tailscale container's network namespace and is reached locally on port `3334` without requiring Tailscale Serve.

The important rule is that `nginx-pihole` must **not** proxy LAN traffic back to a Tailscale `100.x` address. Doing that makes the local path depend on the Tailscale overlay even though DNS already resolved locally.

## One-time shared Docker network

Create the network before starting the Pi-hole stack:

```bash
docker network inspect local-webapps >/dev/null 2>&1 ||
    docker network create local-webapps
```

`nginx-pihole` joins this network in `compose_example.yml`.

For each application that should be reachable through Pi-hole while offline, also load that application's `compose.local-webapps.yml` overlay:

```bash
docker compose \
    -f compose.yml \
    -f compose.local-webapps.yml \
    up -d
```

The overlay only adds the application's backend network namespace to `local-webapps`; it does not change Tailscale Serve or publish another host port.

## Customize the examples

Replace these example values before use:

- `192.168.1.10` with the LAN IP of the Docker host
- `example-tailnet.ts.net` with your Tailscale tailnet DNS suffix
- certificate paths with the paths used by your deployment
- local upstream container names if you changed a Compose `container_name`

Example Pi-hole host entry:

```text
192.168.1.10 jellyfin.example-tailnet.ts.net
```

Example local Nginx upstream:

```nginx
set $local_backend "http://tailscale-jellyfin:8096";
proxy_pass $local_backend;
```

The application shares the Tailscale sidecar's network namespace, so Jellyfin's port `8096` is reachable through the sidecar container on `local-webapps`. This path never uses the sidecar's Tailscale `100.x` address.

The shared `00-docker-resolver.conf` uses Docker's embedded DNS and the per-service configs resolve backend container names at request time. A stopped optional service therefore returns a gateway error for that service instead of preventing all of `nginx-pihole` from starting.

## Local backend map

| Service | Local Docker upstream |
|---|---|
| Audiobookshelf | `tailscale-audiobookshelf:80` |
| Dockge | `tailscale-dockge:5001` |
| Flame | `tailscale-flame:5005` |
| FreshRSS | `tailscale-freshrss:80` |
| Immich | `tailscale-immich:2283` |
| Jellyfin | `tailscale-jellyfin:8096` |
| Jellyseerr | `tailscale-jellyseerr:5055` |
| Karakeep | `tailscale-karakeep:3000` |
| ntfy | `tailscale-ntfy:80` |
| Obico | `tailscale-obico:3334` |
| Owncast | `owncast-tailscale:8080` |
| Transmission | `gluetun:9091` |
| Mullvad Browser | `gluetun:3000` |
| Vaultwarden | `tailscale-vaultwarden:80` |

Transmission and Mullvad Browser share Gluetun's network namespace, so their LAN proxy target is `gluetun` rather than their Tailscale sidecars.

Obico does not need a Tailscale Serve handler for the local path. Its web process listens on port `3334` in the same network namespace as `tailscale-obico`, so `nginx-pihole` can reach `tailscale-obico:3334` directly over `local-webapps`.

## HTTPS certificates

Nginx still uses the file-based Tailscale certificates already mounted from the service state directories. An Internet outage does not invalidate an existing certificate. Internet access is only required later when a certificate actually needs renewal.

## IPv6

Do not copy an ISP-delegated global IPv6 address into the local Pi-hole host overrides if offline LAN access is a requirement. That prefix can disappear or become unusable when the WAN is down.

Use one of these instead:

- LAN IPv4 only, which is the default in this example
- a stable local ULA IPv6 prefix that remains routed with the WAN disconnected

## Validation

Check Pi-hole directly rather than relying on the Docker host's resolver, because the host may itself use Tailscale DNS:

```bash
dig @192.168.1.10 jellyfin.example-tailnet.ts.net A +short
```

It should return the LAN server IP, not a Tailscale `100.x` address.

Then force the HTTPS request through the LAN IP to prove the proxy path is local:

```bash
curl -k \
    --resolve jellyfin.example-tailnet.ts.net:443:192.168.1.10 \
    https://jellyfin.example-tailnet.ts.net/
```

A real application response proves Nginx reached the local Docker backend. `502`, `503`, and `504` indicate the local backend path is not working.
