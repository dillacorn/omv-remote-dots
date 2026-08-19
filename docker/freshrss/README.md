## Setup

Rename the example files and add a Tailscale auth key:

```bash
mv compose_example.yml compose.yml
cp .env_example .env
```

Set `TS_AUTHKEY` in `.env`, then start the stack:

```bash
docker compose up -d
```

FreshRSS uses its persistent SQLite database under `./data`; MariaDB is not required.

## Access

Tailscale:

```text
https://freshrss.<your-tailnet>.ts.net
```

Direct LAN port:

```text
http://<server-ip>:5015
```

The Pi-hole example in this repo can provide the same HTTPS hostname on LAN.

I use Capy Reader on Android and the FreshRSS web interface on desktop.

Extensions I currently use:

- Colorful list
- Sticky Feeds
- Title-Wrap
- YouTube Video Feed
