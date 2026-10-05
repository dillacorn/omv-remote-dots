# Pi-hole

This stack uses Pi-hole as the filtering/policy layer and `dnsproxy` only as an encrypted upstream transport to Quad9.

```text
client -> Pi-hole profile/group -> dnsproxy -> Quad9 DoH
```

The profile manager below keeps groups, lists, allow/deny rules, blocked TLDs, and client assignments editable as normal INI files instead of hand-editing `gravity.db`.

## Profile manager

Files:

- `pihole-profile-manager` - management program
- `profile-catalog.ini` - maintained blocklist URLs
- `profile.example.ini` - editable profile example
- `/docker/pihole/profiles.d/*.ini` - live profile definitions

Install/update the manager into the live Pi-hole directory:

```bash
cd /path/to/omv-remote-dots/docker/pihole
install -m 0755 pihole-profile-manager /docker/pihole/pihole-profile-manager
install -m 0644 profile-catalog.ini /docker/pihole/profile-catalog.ini
mkdir -p /docker/pihole/profiles.d
```

Capture existing non-default Pi-hole groups as editable profiles:

```bash
/docker/pihole/pihole-profile-manager capture --all
```

Inspect them:

```bash
/docker/pihole/pihole-profile-manager list
/docker/pihole/pihole-profile-manager status
/docker/pihole/pihole-profile-manager show "Home Router"
```

Edit and apply a profile:

```bash
/docker/pihole/pihole-profile-manager edit "Home Router"
/docker/pihole/pihole-profile-manager apply "Home Router" --gravity
```

Create a new profile from a preset:

```bash
/docker/pihole/pihole-profile-manager new "Guest" --preset normal
/docker/pihole/pihole-profile-manager edit "Guest"
/docker/pihole/pihole-profile-manager apply "Guest" --gravity
```

Available presets:

- `normal` - HaGeZi Normal + OISD + TIF + DGA30 + device tracker lists
- `strict` - HaGeZi PRO++ + OISD + TIF + DGA30 + device tracker lists
- `parental` - Normal plus NSFW, gambling, piracy, dating, and DynDNS lists

Clone an existing profile:

```bash
/docker/pihole/pihole-profile-manager new "Tablet" --clone "Guest"
```

Assign a normal client or profile-aware proxy by IP:

```bash
/docker/pihole/pihole-profile-manager assign \
    "Guest" 100.64.0.50 --label tablet
```

Return it to Pi-hole's Default group:

```bash
/docker/pihole/pihole-profile-manager unassign 100.64.0.50
```

Every database-changing command creates a timestamped online SQLite backup beside `gravity.db` before writing.

### Profile format

Start from `profile.example.ini`.

```ini
[profile]
name = Example Strict
description = My profile

[lists]
keys =
    proplus
    oisd
    tif
    dga30
extra_urls =

[allow]
domains =
    allowed.example

[deny]
domains =
    blocked.example
tlds =
    zip

[clients]
entries =
    100.64.0.50 | laptop
    172.30.53.101 | arachnidium-personal
```

The manager converts allow/deny domains and TLDs into Pi-hole regex rules that also cover subdomains. It synchronizes its catalog lists and manager-owned rules/clients while leaving unrelated manual Pi-hole data alone.

## Daily blocklist updates

Install a persistent daily Gravity timer. Default run time is 03:15 with a randomized delay of up to 20 minutes:

```bash
/docker/pihole/pihole-profile-manager timer install
```

Use another local time if wanted:

```bash
/docker/pihole/pihole-profile-manager timer install \
    --on-calendar '*-*-* 04:30:00'
```

Status/remove:

```bash
/docker/pihole/pihole-profile-manager timer status
/docker/pihole/pihole-profile-manager timer remove
```

This updates blocklists only. It does not auto-update the Pi-hole container.

## Tailscale DNS endpoint

The base Compose file binds DNS only to the LAN IP. To make the same Pi-hole available as a tailnet DNS resolver without exposing port 53 publicly, add the optional Tailscale overlay:

```bash
cd /docker/pihole
TAILSCALE_IP=100.64.0.10 docker compose \
    -f compose.yml \
    -f compose.tailscale-dns.yml \
    up -d
```

Test it from another Tailscale device before changing tailnet DNS:

```bash
dig @100.64.0.10 example.com
```

Then configure the tailnet resolver to the OMV Tailscale IP. MagicDNS can remain enabled independently.

Before relying on per-device groups over Tailscale, verify Pi-hole's query log shows the real `100.x` client address. If Docker source-NATs the request into one shared address, individual direct-client grouping will not work until that path is changed.

## Profile-aware HTTP proxies

Pi-hole chooses a profile from the DNS client's source IP. A proxy therefore needs a unique, stable Docker IP if different proxy endpoints should use different Pi-hole profiles.

Create the private proxy network once:

```bash
docker network inspect pihole-proxy >/dev/null 2>&1 || \
    docker network create --driver bridge --subnet 172.30.53.0/24 pihole-proxy
```

Attach Pi-hole at `172.30.53.2`:

```bash
cd /docker/pihole
docker compose \
    -f compose.yml \
    -f compose.proxy-profiles.yml \
    up -d
```

Each proxy container uses a unique `172.30.53.x` address, `172.30.53.2` as DNS, and its own host proxy port.

Assign the proxy container IP to the profile:

```bash
/docker/pihole/pihole-profile-manager assign \
    "Personal" 172.30.53.101 --label arachnidium-personal
```

See `../arachnidium/README.md` for the optional Arachnidium regular HTTP proxy example.

### LAN and Tailscale proxy addresses

For a proxy published on port `18101`:

```text
LAN IP:       192.168.1.10:18101
Tailscale IP: 100.64.0.10:18101
```

Both addresses terminate at the same proxy container, so they use the same Pi-hole profile.

The easiest single address is the OMV MagicDNS hostname:

```text
omv.example-tailnet.ts.net:18101
```

On the home LAN, Pi-hole can override that hostname to the OMV LAN IP. Away from home, Tailscale MagicDNS resolves the same hostname to the OMV Tailscale IP. The browser proxy setting therefore stays identical in both places.

If the exact same literal LAN IP is required instead, advertise the OMV LAN IP or LAN subnet as a Tailscale subnet route.

Never expose a MITM proxy on a public/WAN address.

## Local HTTPS routing

Local LAN clients can resolve the normal tailnet service names through Pi-hole and reach `nginx-pihole` directly instead of bouncing through a Tailscale `100.x` address:

```text
service.example-tailnet.ts.net
  -> Pi-hole local DNS
  -> LAN server IP
  -> nginx-pihole:443
  -> local-webapps Docker network
  -> application HTTP port
```

Create the shared network once:

```bash
docker network inspect local-webapps >/dev/null 2>&1 || \
    docker network create local-webapps
```

For each application that should be reachable locally, load its `compose.local-webapps.yml` overlay. Nginx should proxy LAN traffic to the local Docker backend, not back to a Tailscale `100.x` address.

Validate Pi-hole directly:

```bash
dig @192.168.1.10 jellyfin.example-tailnet.ts.net A +short
```

Then force the HTTPS request through the LAN IP:

```bash
curl -k \
    --resolve jellyfin.example-tailnet.ts.net:443:192.168.1.10 \
    https://jellyfin.example-tailnet.ts.net/
```
