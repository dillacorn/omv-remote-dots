# pihm-web

`pihm-web` is the optional browser interface for the same Pi-hole profiles managed by `pihm`.

Pi-hole does not require pihm. pihm does not require pihm-web. The TUI remains fully usable over SSH when the web service is not installed.

## What it manages

The web interface supports normal pihm management:

- profile creation, rename, and cloning;
- profile descriptions;
- blocklist selection and extra blocklist URLs;
- allow/deny domains and blocked TLDs;
- current Default fallback;
- explicit LAN/Tailscale client assignments, edits, and removal;
- local Tailscale device linking with confident LAN-address pairing;
- recent DNS clients actually seen by Pi-hole;
- LAN IPv4 and MAC discovery;
- router DHCP-reservation guidance;
- local and optional secondary-tailnet device discovery;
- Arachnidium endpoint metadata and runtime/connection information;
- normal sync and sync + blocklist refresh;
- blocklist refresh and daily-update timer controls;
- import of existing Pi-hole groups;
- pihm update from the browser;
- browser-local Awtarchy-style themes.

Writes continue to use the existing pihm manager for live Pi-hole changes, backups, reloads, and group ownership.

## Dashboard

The main page stays compact.

Each profile card exposes:

- `Edit` for the floating profile editor;
- `Devices N` for saved devices tied to that profile;
- `Active N` for source addresses that queried Pi-hole using that live policy within the previous hour; opening it also shows the rolling 24-hour history;
- `Sync`;
- `Make default` when the profile is not the fallback.

Device discovery, all-device inspection, profile creation, maintenance, secondary tailnets, and help open in floating modal overlays instead of separate pages. Lists that can grow include local search/filter fields.

The interface uses rectangular panels and controls. Theme selection changes the palette only.

## Install and manage

Install pihm first:

```bash
curl -fsSL https://raw.githubusercontent.com/dillacorn/omv-remote-dots/main/docker/pihole/pihm-installer | bash
```

Then launch:

```bash
pihm
```

Use:

```text
Web interface
-> Install web interface
```

The same menu handles update, status, restart, access instructions, and removal.

Direct installer commands remain available:

```bash
pihm-web-installer install
pihm-web-installer update
pihm-web-installer status
pihm-web-installer uninstall
```

## Themes

The theme selector is available in the dashboard toolbar and applies to the dashboard and every modal.

Current palettes match the Awtarchy theme families:

- Carbon Night;
- Catppuccin Frappé;
- Crimson Red;
- Electric Blue;
- Gruvbox;
- Iron Forge;
- Obsidian Night;
- Pink;
- Pip-Boy.

Iron Forge is the default.

The selected theme is stored only in the browser's `pihm_theme` cookie. It does not change Awtarchy, Pi-hole, pihm profiles, or server configuration.

## Authentication

By default, pihm-web reuses the existing Pi-hole web password.

It validates the supplied password against Pi-hole v6 through the local `/api/auth` endpoint, immediately closes the temporary API session, and does not generate or store a duplicate Pi-hole password.

Default login:

```text
username: admin
password: existing Pi-hole web password
```

The settings file is:

```text
/etc/pihm-web.env
```

The service listens only on:

```text
127.0.0.1:8091
```

by default.

## Access over SSH

From another machine:

```bash
ssh -o ExitOnForwardFailure=yes -N \
  -L 8091:127.0.0.1:8091 \
  root@your-omv-host
```

Leave that terminal running, then open:

```text
http://127.0.0.1:8091
```

If the SSH server disables TCP forwarding, enable only the minimum forwarding needed instead of exposing pihm-web directly.

## Active DNS clients

The profile cards distinguish two different counts:

- `Active N`: source IP addresses that queried Pi-hole using that live policy within the previous hour; the activity popup also shows unique sources from the rolling previous 24 hours;
- `explicit client addresses`: addresses saved directly in that profile INI.

For the Default fallback profile, otherwise-unassigned DNS source addresses count toward that fallback because they receive its mirrored policy.

This is recent activity, not a count of devices currently online. It is a source-address count, not a perfect physical-device count. A router can represent downstream IPv6 clients, and one physical device can legitimately appear once by LAN IPv4 and once by Tailscale IPv4.

## LAN addresses and router reservations

For a permanent LAN assignment, reserve the client's LAN IPv4 to its MAC address on the router.

pihm-web displays the MAC when it is visible in the OMV neighbor table, but Pi-hole policy continues to use the stable LAN IPv4 as the local identity.

A device can therefore have:

```text
LAN IPv4       -> profile
Tailscale IPv4 -> same profile
```

## Multiple tailnets

The OMV host stays logged into its normal/local tailnet.

Additional tailnets are optional read-only discovery sources. Do not run multiple `tailscaled` instances merely to list devices.

For each secondary tailnet:

1. In that tailnet's Tailscale admin console, create an OAuth client under Trust credentials.
2. Grant only **Devices > Core: Read**.
3. Copy the tailnet ID from the tailnet General page.
4. In pihm-web, add a secondary tailnet with:
   - a display name;
   - tailnet ID;
   - OAuth client ID;
   - OAuth client secret.

pihm-web validates the credentials before saving them.

Secondary-tailnet credentials are stored only on the OMV host in:

```text
/var/lib/pihm-web/tailnets.json
```

with mode `0600`. Client secrets are never displayed again by the web interface.

Adding a secondary tailnet provides **discovery only**. It does not automatically give those devices network access to Pi-hole.

Tailscale IPv4 addresses are only guaranteed unique inside a tailnet, and machine sharing can remap addresses. For that reason, pihm-web does not enable one-click assignment for a secondary-tailnet device until that exact source address has actually appeared in Pi-hole's recent query history.

For a user who remains in another tailnet:

1. share the OMV/Pi-hole Tailscale machine to that user;
2. have the remote device send DNS traffic to Pi-hole;
3. confirm the secondary device row changes to `Verified DNS source`;
4. assign the verified address to the desired profile.

If the API-reported address does not become the Pi-hole source address, use the Recent DNS clients table to identify the source Pi-hole actually receives instead of guessing.

An alternative is to invite that user into the same tailnet instead of using machine sharing.

## Optional Tailscale Serve

Tailscale Serve can expose the localhost web service to the tailnet over HTTPS without making it public.

Inspect existing Serve configuration first:

```bash
tailscale serve status
```

For a dedicated test port:

```bash
tailscale serve --bg --https=8444 8091
```

Do not use Tailscale Funnel for pihm-web.

## Security

pihm-web performs privileged profile changes through the existing pihm manager.

- Keep the backend localhost-only by default.
- Do not expose it publicly.
- Do not use Tailscale Funnel.
- Do not put `/var/run/docker.sock` in a web-facing container.
- Keep secondary-tailnet OAuth credentials read-only and root-only.
- Prefer an SSH tunnel or authenticated HTTPS front end such as Tailscale Serve.

The backend refuses a non-loopback bind unless `PIHM_WEB_ALLOW_REMOTE_BIND=1` is explicitly set.
