# pihm

pihm is the optional Pi-hole profile manager for this stack.

Repository files in this directory install to:

```text
/docker/pihole/pihm/
```

Runtime layout:

```text
/docker/pihole/
├── compose*.yml
├── etc-pihole/
└── pihm/
    ├── pihole-profile-manager
    ├── pihole-profile-tui
    ├── pihm-installer
    ├── pihm-web
    ├── pihm-web-installer
    ├── profile-catalog.ini
    ├── profile.example.ini
    ├── profiles.d/
    └── backups/
```

Pi-hole itself does not depend on pihm. The pihm TUI does not depend on pihm-web.

Install/update:

```bash
curl -fsSL https://raw.githubusercontent.com/dillacorn/omv-remote-dots/main/docker/pihole/pihm/pihm-installer | bash
```

The installer migrates the older flat `/docker/pihole` pihm layout into this subdirectory, preserves profile INIs, archives old managed files/backups under `pihm/backups/`, and refreshes command symlinks under `/usr/local/bin`.

See [WEB.md](WEB.md) for the optional browser interface.
