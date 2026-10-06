# pihm-web

`pihm-web` is an optional browser interface for frequent Pi-hole profile/client management.

It is separate from the existing `pihm` TUI. The TUI remains the dependable SSH/admin interface.

## First version

The first web version intentionally stays small:

- shows profiles and the current Default fallback;
- shows assigned client addresses;
- discovers recent LAN IPv4 clients;
- displays the LAN MAC address when the server neighbor table knows it;
- discovers Tailscale clients;
- assigns/removes client addresses;
- changes the Default fallback;
- syncs a profile to Pi-hole;
- shows whether the active encrypted upstream appears to be Quad9 or NextDNS.

Writes still go through the existing `pihole-profile-manager`, so pihm keeps ownership of database backups, profile rules, and DNS reload behavior.

## Install from the testing branch

```bash
curl -fsSL \
  https://raw.githubusercontent.com/dillacorn/omv-remote-dots/feat/pihm-web/docker/pihole/pihm-web-installer \
  -o /tmp/pihm-web-installer

PIHM_WEB_REF=feat/pihm-web bash /tmp/pihm-web-installer
```

By default, pihm-web reuses the existing Pi-hole web password. It reads the configured Pi-hole password from the running Pi-hole container at startup, so no second password is generated or stored.

The pihm-web settings file is:

```text
/etc/pihm-web.env
```

It stores bind/port/username/auth-source settings, not a duplicate Pi-hole password.

The backend listens only on:

```text
127.0.0.1:8091
```

by default.

## Test locally over SSH

From another machine:

```bash
ssh -L 8091:127.0.0.1:8091 root@your-omv-host
```

Then open:

```text
http://127.0.0.1:8091
```

Use username `admin` and the same password you already use for the Pi-hole web interface.

## Optional Tailscale Serve

Tailscale Serve can expose a localhost web service to the tailnet over HTTPS without making it public.

Before changing Serve configuration, inspect what is already active:

```bash
tailscale serve status
```

For branch testing, use a dedicated tailnet HTTPS port so an existing root Serve route is not replaced:

```bash
tailscale serve --bg --https=8444 8091
```

Then use the HTTPS URL reported by `tailscale serve status`.

Do not use Tailscale Funnel for pihm-web.

If the OMV node already has Tailscale Serve configuration, review it first instead of replacing it blindly.

## LAN addresses and router reservations

For a permanent LAN profile assignment, reserve the client's LAN IPv4 address to its MAC address on the router.

pihm-web displays the MAC when it is visible in the OMV neighbor table, but Pi-hole policy continues to use the stable LAN IPv4 address as the local client identity.

A typical device can therefore have:

```text
LAN IPv4       -> profile
Tailscale IPv4 -> same profile
```

The router reservation keeps the LAN IPv4 stable.

## Security

pihm-web performs privileged profile changes through the existing pihm manager, so the service is intentionally localhost-only by default and requires HTTP Basic authentication.

Do not bind it publicly.

Do not expose it with Tailscale Funnel.

The testing branch does not automatically modify nginx, firewall rules, Tailscale Serve, or router configuration.

The backend also refuses a non-loopback bind unless `PIHM_WEB_ALLOW_REMOTE_BIND=1` is explicitly set. Prefer leaving it on localhost and putting an authenticated/encrypted reverse proxy such as Tailscale Serve in front of it.
