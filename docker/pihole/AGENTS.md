# Pi-hole agent instructions

Read `README.md` and `NETWORKING.md` before changing anything in this directory.

## Safety and discovery

- Re-confirm the current host, container names, Compose project/service names, active Compose files, network names, and paths from live evidence before modifying a server.
- Do not assume the live upstream is Quad9. During migration, `dnsproxy` may still intentionally point at NextDNS.
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

Stock ASUSWRT may advertise the router itself as IPv6 RDNSS even when a custom Pi-hole IPv6 upstream is configured. DNS filtering can still work while per-device IPv6 identity collapses to the router. See `NETWORKING.md`.

## Docker networking

The normal Pi-hole bridge is IPv4-only.

Use the optional IPv6-only macvlan overlay for direct LAN IPv6 reachability. Future Compose recreations must include every active overlay, including Tailscale DNS and IPv6 DNS.

Residential DHCPv6-PD prefixes can change. Keep the public overlay variable-driven rather than hard-coding one deployment's global prefix.

## Validation

Useful checks include:

```bash
docker compose -f compose.yml -f compose.tailscale-dns.yml -f compose.ipv6-dns.yml config
docker inspect pihole
docker exec pihole sh -c 'ip -br addr'
docker exec pihole sh -c 'ss -lnptu | grep ":53 "'
docker exec pihole pihole -t
rdisc6 enp3s0
```

If a change affects client identity, validate both the LAN path and the Tailscale path before calling it complete.
