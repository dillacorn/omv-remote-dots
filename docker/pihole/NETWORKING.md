# Pi-hole networking guide

This document records the networking design and the failure modes that were validated while moving Pi-hole from a simple LAN DNS server into a profile-aware DNS service that also works over Tailscale and IPv6.

The important goal is not merely "make DNS answer." Pi-hole profiles depend on seeing the real client source address. Any router, proxy, NAT layer, Docker userland proxy, or encrypted-DNS client that hides that address can make multiple devices collapse into one Pi-hole client.

## Validated design

The working design has three DNS paths:

```text
LAN IPv4 client
  -> Pi-hole LAN IPv4
  -> Pi-hole sees the real LAN client IPv4

Tailscale client
  -> OMV Tailscale IPv4
  -> Pi-hole
  -> Pi-hole sees the real 100.x Tailscale client IPv4

LAN IPv6 client
  -> router-advertised IPv6 DNS path
  -> Pi-hole IPv6 endpoint
```

The first two paths preserve per-device identity and are the preferred profile-selection paths.

The IPv6 path needs extra care because stock consumer routers may advertise themselves as the IPv6 Recursive DNS Server (RDNSS) even when a custom upstream IPv6 DNS server is configured. In that case DNS still reaches Pi-hole, but Pi-hole may see the router as the client.

## AT&T BGW320 + stock ASUSWRT findings

The validated upstream/router combination was:

- AT&T BGW320-500
- ASUS RT-AX82U on stock ASUSWRT
- BGW320 IPv4 IP Passthrough enabled
- BGW320 IPv6 enabled
- BGW320 DHCPv6 enabled
- BGW320 DHCPv6 Prefix Delegation enabled
- ASUS IPv6 mode changed from `Passthrough` to `Native`
- ASUS DHCP-PD enabled
- ASUS LAN IPv6 autoconfiguration set to Stateless
- ASUS Router Advertisement enabled
- ASUS IPv6 firewall enabled

### Why Native + DHCP-PD mattered

With ASUS IPv6 set to `Passthrough`, the BGW320 status page did not show a delegated prefix for the downstream router and the LAN inherited upstream IPv6 behavior.

After switching ASUS to `Native` with DHCP-PD enabled:

1. the BGW320 populated its delegated-prefix field;
2. the ASUS received a dedicated /64 for the LAN;
3. the ASUS became the IPv6 default router for the LAN; and
4. normal IPv6 connectivity remained available for applications and Tailscale.

Do not disable IPv6 merely to simplify DNS. DNS can travel over IPv4 and still return AAAA records, and native IPv6 can materially help Tailscale establish direct peer-to-peer paths.

## Stock ASUSWRT IPv6 DNS limitation

A key stock-ASUSWRT behavior was confirmed with `rdisc6`:

- even with "Connect to DNS Server automatically" disabled;
- and even with a custom Pi-hole IPv6 DNS address configured;

the ASUS still advertised its own LAN IPv6 address as the RDNSS server.

Conceptually:

```text
client
  -> ASUS IPv6 DNS address advertised by RDNSS
  -> ASUS forwards to Pi-hole
  -> Pi-hole may see the ASUS/router as the DNS client
```

This is not a DNS-filtering failure. Pi-hole still filters the query. The limitation is client identity: per-device Pi-hole profiles cannot distinguish clients whose IPv6 DNS queries are being proxied by the router.

For devices that need strict per-device policy, the Tailscale DNS path is the reliable identity-preserving path because Pi-hole can see the device's stable Tailscale 100.x address.

Do not add rotating Android IPv6 privacy addresses to `pihm` profiles. Prefer the stable LAN IPv4 address plus the stable Tailscale IPv4 address.

## Pi-hole IPv6 macvlan endpoint

The base Pi-hole Compose network is intentionally IPv4-only. LAN IPv4 and Tailscale DNS are published through host bindings.

For direct IPv6 LAN reachability, use a separate IPv6-only macvlan network attached to the physical LAN interface. This avoids publishing a global IPv6 port into an IPv4-only Docker bridge and gives Pi-hole a real Layer-2 IPv6 presence on the LAN.

Use the repository overlay:

```text
docker/pihole/compose.ipv6-dns.yml
```

Required variables:

```text
LAN_INTERFACE
LAN_IPV6_SUBNET
LAN_IPV6_GATEWAY
PIHOLE_IPV6
```

Example only:

```bash
export LAN_INTERFACE=enp3s0
export LAN_IPV6_SUBNET='2001:db8:1234:5678::/64'
export LAN_IPV6_GATEWAY='2001:db8:1234:5678::1'
export PIHOLE_IPV6='2001:db8:1234:5678::53'

docker compose \
  -f compose.yml \
  -f compose.tailscale-dns.yml \
  -f compose.ipv6-dns.yml \
  config
```

Always validate the merged Compose config before recreating the stack.

Then apply with the same complete overlay set:

```bash
TAILSCALE_IP="$(tailscale ip -4 | head -n1)"

LAN_INTERFACE="$LAN_INTERFACE" \
LAN_IPV6_SUBNET="$LAN_IPV6_SUBNET" \
LAN_IPV6_GATEWAY="$LAN_IPV6_GATEWAY" \
PIHOLE_IPV6="$PIHOLE_IPV6" \
TAILSCALE_IP="$TAILSCALE_IP" \
docker compose \
  -f compose.yml \
  -f compose.tailscale-dns.yml \
  -f compose.ipv6-dns.yml \
  up -d
```

Future Compose recreations must include all active overlays. Omitting the IPv6 overlay will remove the Pi-hole macvlan attachment.

## Prefix changes

Residential delegated IPv6 prefixes are not guaranteed to remain permanent.

Never hard-code a residential global IPv6 prefix into the public repository or into unrelated local-DNS overrides unless there is an explicit mechanism to refresh it.

After a prefix change:

1. read the currently delegated LAN /64 from the router or `rdisc6`;
2. update `LAN_IPV6_SUBNET`;
3. update `LAN_IPV6_GATEWAY`;
4. choose/update `PIHOLE_IPV6` inside that /64;
5. recreate the stack with the IPv6 overlay; and
6. update the router's custom IPv6 DNS target.

Old global addresses may remain on Linux interfaces until their advertised lifetimes expire. That alone is not a reason to restart networking.

## Local DNS overrides

Avoid hard-coded AAAA overrides that point at a residential delegated prefix unless they are maintained automatically.

A stale AAAA record can keep directing clients at an old prefix after DHCP-PD changes the LAN /64.

Stable LAN IPv4 overrides are usually safer for local service names when IPv6 prefix persistence is not guaranteed.

## Tailscale DNS

The tailnet global resolver should point to the OMV Tailscale IPv4 address while MagicDNS remains enabled.

For profile-aware DNS, verify Pi-hole logs show the real 100.x device address:

```bash
docker exec pihole pihole -t
```

If all tailnet queries appear from one shared address, do not assume profile isolation is working.

Do not configure NextDNS and Pi-hole as parallel global tailnet resolvers during migration. That creates a bypass path. Chain the upstream through Pi-hole until migration is complete.

## Android / browser encrypted-DNS bypasses

When debugging a client that appears to skip Pi-hole, check all of these separately:

- Android Private DNS / DNS-over-TLS
- Firefox DNS-over-HTTPS
- browser-specific Secure DNS
- VPN/Tailscale DNS overrides
- cached DNS and already-open HTTP/2 or HTTP/3 connections

A browser can keep loading pages without generating new DNS queries because answers and network connections are cached.

A useful proof test is a unique intentionally nonexistent hostname. If Pi-hole logs the lookup, the browser is using the Pi-hole path even though the page itself fails.

## Useful diagnostics

Show the router advertisement and RDNSS:

```bash
rdisc6 enp3s0
```

Show Pi-hole client traffic:

```bash
docker exec pihole pihole -t
```

Follow one LAN IPv4 client:

```bash
docker exec pihole pihole -t | grep --line-buffered '192.168.1.50'
```

Follow a physical LAN device across IPv4/IPv6 DNS by MAC:

```bash
PHONE_MAC="$(ip neigh show 192.168.1.50 | awk '/lladdr/ {print $5; exit}')"
timeout 30 tcpdump -ni enp3s0 -nn "ether host $PHONE_MAC and (port 53 or port 853)"
```

Check the Pi-hole container's interfaces and DNS listeners:

```bash
docker exec pihole sh -c 'ip -br addr'
docker exec pihole sh -c 'ss -lnptu | grep ":53 "'
```

Check Compose identity before changing a live stack:

```bash
docker inspect pihole --format $'container={{.Name}}\nproject={{index .Config.Labels "com.docker.compose.project"}}\nservice={{index .Config.Labels "com.docker.compose.service"}}\nworkdir={{index .Config.Labels "com.docker.compose.project.working_dir"}}\nfiles={{index .Config.Labels "com.docker.compose.project.config_files"}}'
```

## Security

Never expose raw Pi-hole DNS on public WAN IPv4 or globally routable IPv6 without an explicit access-control design.

For this design:

- ASUS IPv6 firewall stays enabled;
- LAN IPv6 may reach the Pi-hole macvlan endpoint;
- Tailscale reaches Pi-hole through the Tailscale-bound IPv4 DNS port;
- WAN/public DNS is not intentionally opened.

The Pi-hole API/web password is a secret. Do not commit it, quote it into documentation, or leave it exposed in shared logs. Rotate it if it has been pasted into a chat, ticket, or public location.

## Upstream DNS policy

The repository default and recommended design is:

```text
client -> Pi-hole -> dnsproxy -> Quad9 DoH
```

Pi-hole remains the self-hosted filtering and per-client policy layer. `dnsproxy` provides encrypted upstream transport. Quad9 is the default recursive resolver.

NextDNS remains supported as an optional upstream:

```text
client -> Pi-hole -> dnsproxy -> NextDNS DoH
```

Do not configure NextDNS and Quad9 as parallel client-side resolvers around Pi-hole because that creates a policy bypass path. Use exactly one upstream behind Pi-hole.

A live host may differ from the repository default, especially during migrations. Always verify the running `dnsproxy` command before changing upstream DNS.
