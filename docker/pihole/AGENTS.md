# Pi-hole agent instructions

Read `README.md`, `SETUP.md`, and `NETWORKING.md` before changing anything in this directory.

## Core rule

Inspect the live deployment before acting.

A running Pi-hole stack may differ from repository examples. Re-confirm the current host, container names, Compose project/service names, active Compose files, networks, paths, and running `dnsproxy` command before making changes.

Use the live stack as implementation truth. Use repository examples as templates, not as proof of current state.

## Keep it simple

User-facing instructions should be short, direct, and ordered around what the user actually needs to do.

Follow the same documentation discipline used in Awtarchy:

- start with a one-sentence purpose;
- use a small number of clear sections;
- describe user-visible behavior before implementation detail;
- keep normal procedures in `SETUP.md`;
- keep deep troubleshooting and networking detail in `NETWORKING.md`;
- keep durable agent rules here;
- do not dump debugging chronology into user-facing docs;
- do not repeat the same procedure across multiple files unless the extra context is necessary;
- do not add decorative meta-commentary such as "inspired by", implementation-history references, or self-referential design notes to user-facing UI unless they provide real operational value.

Prefer one safe command block over several fragmented commands when a server change is required.

## Recommended DNS design

Default and recommended:

```text
client -> Pi-hole profile/group -> dnsproxy -> Quad9 DoH
```

Pi-hole is the self-hosted filtering and per-client policy layer. `dnsproxy` is encrypted upstream transport. Quad9 is the default recursive resolver.

NextDNS remains optional through `compose.nextdns-upstream.yml`.

Never configure Quad9 and NextDNS as parallel client-side resolvers around Pi-hole. That creates a policy bypass path.

Never assume the live host follows the repository default. Inspect the running `dnsproxy` command first.

## pihm invariants

Pi-hole group id 0 is the built-in `Default` group. Do not treat it as an ordinary captured profile.

One normal `pihm` profile may be the persistent fallback. When that profile is synced:

- its blocklist assignments mirror into Pi-hole `Default`;
- its allow/deny/TLD rules mirror into Pi-hole `Default`;
- client assignments do not mirror.

Cloning a profile must not clone its fallback status.

A balanced profile such as `Home Router` is the recommended fallback for otherwise-unassigned home clients. Explicitly assigned devices may use stricter profiles.

## Client identity

Pi-hole profile selection depends on the DNS source address.

Preferred stable identities:

- LAN IPv4;
- Tailscale IPv4.

One physical device may legitimately have both identities in the same profile. `pihm` should discover/link them instead of making the user manually understand both address spaces.

Do not silently guess device identity from a rotating Android IPv6 privacy address.

Do not assume every query logged from the router came from a downstream client. Routers generate their own DNS traffic.

## Tailscale

For the validated design:

- tailnet global DNS points to the OMV Tailscale IPv4 address;
- MagicDNS remains enabled;
- Tailscale DNS override remains enabled for clients that should use Pi-hole while connected;
- direct NextDNS global DNS is removed rather than left in parallel.

Before relying on per-device policies, verify Pi-hole logs show the real Tailscale `100.x` client address.

`tailscale netcheck` shows NAT/UDP/IPv4/IPv6 capability. It does not prove every peer is direct. Use `tailscale ping <peer>` to distinguish direct connectivity from DERP for a specific peer.

## IPv6 and validated router pattern

Do not disable IPv6 as a shortcut.

The validated AT&T BGW320-500 + stock ASUSWRT setup is:

- BGW320 IPv4 IP Passthrough left intact;
- BGW320 IPv6 enabled;
- BGW320 DHCPv6 enabled;
- BGW320 DHCPv6 Prefix Delegation enabled;
- ASUS IPv6 mode `Native`;
- ASUS DHCP-PD enabled;
- ASUS LAN autoconfiguration `Stateless`;
- ASUS Router Advertisement enabled;
- ASUS IPv6 firewall enabled.

This preserved native IPv6 and Tailscale IPv6 capability.

Stock ASUSWRT may still advertise its own LAN IPv6 address as RDNSS even when Pi-hole is configured as the IPv6 DNS target. DNS filtering can still work while Pi-hole sees the ASUS/router instead of the original client.

Treat that as a client-identity limitation, not a filtering failure.

## Docker networking

The normal Pi-hole bridge is IPv4-only.

Use `compose.ipv6-dns.yml` for direct LAN IPv6 reachability. It attaches Pi-hole to an IPv6-only macvlan on the physical LAN.

The macvlan solves Pi-hole IPv6 reachability. It does not force stock ASUSWRT to advertise Pi-hole itself as RDNSS.

Before any Compose recreation, inspect:

```bash
docker inspect pihole --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}'
```

Preserve every active overlay.

Residential DHCPv6-PD prefixes can change. If the delegated prefix changes, update the macvlan subnet, gateway, Pi-hole IPv6 address, and router DNS target together.

Never overwrite a live `/docker/pihole/compose.yml` from the public example without comparing deployment-specific hosts, mounts, certificates, addresses, and secrets first.

## Troubleshooting lessons

Do not over-interpret a single log or capture.

- DNS silence while browsing is not proof of failure. DNS answers and HTTP/2/HTTP/3 connections may be cached.
- A unique intentionally nonexistent hostname is useful for forcing and correlating a fresh DNS lookup.
- Firefox DoH is independent of Android Private DNS. Browser DoH can bypass Pi-hole even when system DNS is correct.
- Android Wi-Fi proxy should remain `None` unless Arachnidium is intentionally being used. `Auto-config` is not a DNS fix.
- A packet capture on OMV cannot see a phone-to-router DNS packet if that packet terminates at the router.
- `rdisc6` shows the actual IPv6 RDNSS advertisement. Use its source/link-layer evidence instead of inferring the advertiser from the IPv6 prefix alone.
- After recreating Pi-hole, wait for FTL readiness and confirm port-53 listeners before treating an immediate connection failure as a networking-design problem.

Useful checks:

```bash
docker inspect pihole --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}'
docker inspect pihole
docker exec pihole sh -c 'ip -br addr'
docker exec pihole sh -c 'ss -lnptu | grep ":53 "'
docker exec pihole pihole -t
rdisc6 enp3s0
tailscale netcheck
```

Build `docker compose ... config` from the overlays that are actually active on the live host. Do not assume a fixed file list.

If a change affects client identity, validate both the LAN path and the Tailscale path before calling it complete.

## Arachnidium

Arachnidium is optional and opt-in.

A reserved endpoint is metadata only. It does not deploy/start Arachnidium and does not force a Pi-hole profile through a proxy.

Do not mix Arachnidium troubleshooting into normal Pi-hole DNS troubleshooting unless a client is intentionally configured to use the proxy.

## Security

- Never expose raw Pi-hole DNS publicly without an explicit access-control design.
- Keep the router IPv6 firewall enabled.
- Do not commit or repeat deployment secrets, passwords, API keys, tailnet names, or residential public IPv6 prefixes.
- The Pi-hole web/API password is sensitive. Rotate it if it has been pasted into a chat, ticket, or public location.
- Back up live Compose/config/database state before modifying it.

## pihm-web

pihm-web is optional and must remain separate from the pihm TUI. Do not make the TUI depend on the web service.

The web interface should cover normal pihm/TUI management so browser users are not forced back to SSH for profile administration. When a new profile-management action is added, audit both TUI and web parity. Do not clone unrelated Pi-hole administration features that pihm itself does not own.

Shared operations that change live Pi-hole identity/state, such as profile rename, should live in `pihole-profile-manager` and be called by both TUI and web. Web mutations should reuse pihm/pihole-profile-manager operations so database backups, profile ownership, Default fallback behavior, and Pi-hole reload behavior stay centralized.

Keep the browser UI compact:

- the main page is a dashboard, not a long stacked admin document;
- profile cards show only high-value state and compact actions;
- profile editing, device lists, recent activity, device discovery, maintenance, tailnets, creation, and help open as bordered modal overlays instead of separate detail pages;
- device/discovery/profile lists should have search/filter controls when they can grow;
- use rectangular controls and panels; do not reintroduce rounded-corner styling;
- `Devices N` means saved devices grouped from explicit identities;
- `Recent N` means DNS source addresses actually seen using that live policy in the rolling previous 24 hours;
- help content should teach common workflows step by step rather than merely describe features.

The web backend is localhost-only by default. Do not expose it publicly or enable Tailscale Funnel. Any Tailscale Serve integration must be opt-in and must inspect existing Serve configuration before changing it.

Do not put the Docker socket inside a pihm-web container. The initial implementation runs on the OMV host and reuses the existing manager.

For LAN client assignments, display a discovered MAC address when available, but keep the stable LAN IPv4 address as the Pi-hole client identity. Recommend a router DHCP reservation for that IPv4/MAC pair before treating the assignment as permanent.

Recent-client counts should come from Pi-hole query history and be described as DNS source addresses, not guaranteed physical-device counts. Unassigned querying addresses inherit the selected pihm Default fallback.

Browser themes are presentation-only. Keep them browser-local and do not couple theme selection to Pi-hole, pihm profile state, or the host desktop theme. The current theme families mirror Awtarchy's managed palettes.

### Secondary tailnets

Keep the OMV host on its normal Tailscale login. Do not run multiple tailscaled instances merely for discovery.

Additional tailnets may be configured as read-only discovery sources through Tailscale OAuth clients with Devices/Core Read permission. Store those credentials only in the pihm-web private state directory with root-only permissions.

A secondary tailnet's API-reported 100.x address is discovery metadata, not proof of the source identity Pi-hole will observe across tailnet sharing. Tailscale IPv4 addresses can be tailnet-local and sharing can remap addresses. Only enable direct profile assignment for a secondary-tailnet address after Pi-hole has actually observed that exact source address.

Discovery does not grant connectivity. A device in another tailnet must still be able to reach the OMV/Pi-hole machine, for example through supported Tailscale machine sharing, and the observed DNS source identity must be validated before relying on per-device policy.

### pihm-web authentication

By default, pihm-web must reuse the existing Pi-hole web password instead of generating a second credential. Validate the supplied password against Pi-hole v6 through its local `/api/auth` endpoint and close the temporary API session immediately. Do not read the password from `FTLCONF_webserver_api_password`, and do not print, duplicate, or commit it.

A separate pihm-web password should exist only as an explicit opt-in custom-auth mode.
