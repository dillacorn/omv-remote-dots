# Pi-hole agent instructions

Read `README.md` and `NETWORKING.md` before changing anything in this directory.

## Safety and discovery

- Re-confirm the current host, container names, Compose project/service names, active Compose files, network names, and paths from live evidence before modifying a server.
- The repository default and recommended upstream is Quad9 DoH through `dnsproxy`.
- NextDNS is optional only. Never assume a live host follows the repository default; inspect the running `dnsproxy` command before changing it.
- Do not configure Quad9/NextDNS in parallel as alternate client resolvers around Pi-hole. Pi-hole must remain the policy/filtering layer in front of the chosen upstream.
- Do not disable IPv6 as a shortcut. Native IPv6 is intentional and useful for direct Tailscale connectivity.
- Do not expose raw DNS publicly.
- Do not publish user-specific public IPv6 prefixes, tailnet names, passwords, API keys, or other deployment secrets into this repository.
- Back up live Compose/config files before modifying them and validate the merged Compose configuration before recreation.

## Identity matters

Pi-hole profiles depend on the DNS source address.

Preferred stable client identities are:

- LAN IPv4
- Tailscale IPv4

Do not silently guess that a rotating IPv6 privacy address belongs to a particular profile.

For one physical device, it is normal for one profile to contain both stable identities, for example a LAN IPv4 address plus the device's Tailscale 100.x address. `pihm` should discover/link these instead of making the user manually understand both address spaces.

Stock ASUSWRT may advertise the router itself as IPv6 RDNSS even when a custom Pi-hole IPv6 upstream is configured. DNS filtering can still work while per-device IPv6 identity collapses to the router. A direct Pi-hole IPv6 macvlan endpoint does not, by itself, fix this stock-ASUS RDNSS behavior. See `NETWORKING.md`.

Do not attribute every query logged as the router to a specific downstream device. The router generates its own DNS queries too. Use a unique test hostname and/or packet evidence before assigning causality.

## Docker networking

The normal Pi-hole bridge is IPv4-only.

Use the optional IPv6-only macvlan overlay for direct LAN IPv6 reachability. The macvlan gives Pi-hole a real LAN IPv6 address, but stock ASUSWRT may still advertise the ASUS itself as RDNSS and proxy IPv6 DNS to Pi-hole.

Future Compose recreations must include every active overlay. Before recreating the stack, inspect `com.docker.compose.project.config_files` on the running container and preserve the active overlay set. Typical overlays are Tailscale DNS and IPv6 DNS; NextDNS is optional.

Residential DHCPv6-PD prefixes can change. Keep the public overlay variable-driven rather than hard-coding one deployment's global prefix. When the delegated prefix changes, update the macvlan subnet/gateway/Pi-hole IPv6 and the router's custom IPv6 DNS target together.

The public repository contains examples/generic overlays. A live `/docker/pihole/compose.yml` may contain deployment-specific hosts, mounts, certificates, addresses, or secrets. Never overwrite it from an example without first comparing the live stack.

## Evidence discipline and validation

Useful checks include:

```bash
docker inspect pihole --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}'
docker inspect pihole
docker exec pihole sh -c 'ip -br addr'
docker exec pihole sh -c 'ss -lnptu | grep ":53 "'
docker exec pihole pihole -t
rdisc6 enp3s0
tailscale netcheck
```

Build the `docker compose ... config` validation command from the overlays that are actually active on the live host; do not blindly assume a fixed file list.

Important interpretation rules:

- DNS silence while browsing is not proof of failure. DNS answers and HTTP/2/HTTP/3 connections may be cached. Use a unique intentionally nonexistent hostname to force a fresh lookup.
- A browser can bypass system DNS through DoH even when Android/system DNS is correct. Firefox DoH must be checked separately.
- Android Wi-Fi proxy should remain `None` unless Arachnidium is intentionally being used. `Auto-config` is not a DNS fix.
- A host-side capture on OMV cannot see a phone-to-router DNS packet that terminates at the router. Do not use that capture alone to rule out router DNS proxying.
- `rdisc6` shows what RDNSS the router is advertising. Do not infer the advertiser from the IPv6 prefix alone; use the RA source/link-layer evidence.
- After a Compose recreation, wait for Pi-hole/FTL readiness and confirm `[::]:53`/port 53 listeners before diagnosing an immediate connection-refused result as a network-design failure.
- `tailscale netcheck` shows NAT/UDP/IPv4/IPv6 capability, not whether every peer connection is direct. Use `tailscale ping <peer>` to distinguish direct vs DERP for a specific peer.

If a change affects client identity, validate both the LAN path and the Tailscale path before calling it complete.

## pihm invariants

- Pi-hole group id 0 is the built-in `Default` group. Do not manage it as a normal captured profile.
- One normal `pihm` profile may be marked as the persistent default fallback. Its blocklist and allow/deny/TLD assignments mirror into Pi-hole `Default`; client assignments do not.
- Keep the fallback marker persistent in the profile INI. Cloning a profile must not clone default status.
- If sync/apply behavior changes, preserve the invariant that syncing the selected fallback profile also refreshes the built-in `Default` policy.
- The recommended fallback for a general home deployment is a balanced home policy such as `Home Router`, while specifically assigned clients may use stricter profiles.
- Arachnidium remains optional and opt-in. Reserving an endpoint is metadata only; it does not deploy/start a proxy or force a profile through one.

## Validated router pattern

For the validated AT&T BGW320-500 + stock ASUSWRT arrangement:

- BGW320: IPv6 on, DHCPv6 on, DHCPv6 Prefix Delegation on, IPv4 IP Passthrough left intact.
- ASUS: IPv6 `Native`, DHCP-PD enabled, Stateless LAN autoconfiguration, Router Advertisement enabled, IPv6 firewall enabled.
- ASUS IPv4 DHCP should advertise Pi-hole directly and should not additionally advertise the router as IPv4 DNS.
- Stock ASUSWRT may still advertise its own LAN IPv6 address as RDNSS even when the configured upstream IPv6 DNS is Pi-hole. Treat this as a client-identity limitation, not a filtering failure.
- Keep IPv6 enabled. Native IPv6 was validated with working external IPv6 reachability and Tailscale IPv6 capability.
