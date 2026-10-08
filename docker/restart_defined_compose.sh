#!/usr/bin/env bash
# restart_defined_compose.sh
# User-maintained list of directories containing Compose projects to restart.

set -euo pipefail

# Add one directory per Compose application you want to restart.
# Each directory should contain either docker-compose.yml or compose.yml.
COMPOSE_DIRS=(
  "/docker/jellyfin"
  "/docker/immich"
  "/docker/seerr"
  "/docker/ntfy"
  "/docker/brave"
  "/docker/freshrss"
  "/docker/flame"
  "/docker/diun"
  "/docker/watchtower"
  "/docker/calibre"
  "/docker/karakeep"
  "/docker/privacy"
  "/docker/vaultwarden"
  "/docker/mumble"
  "/docker/homeassistant"
  # "/docker/app_name"
)

for dir in "${COMPOSE_DIRS[@]}"; do
  if [ ! -d "$dir" ]; then
    echo "Skipping $dir. Directory does not exist."
    continue
  fi

  cd "$dir"

  if [ -f docker-compose.yml ]; then
    echo "Restarting Compose project in $dir (docker-compose.yml)"
    docker compose restart
  elif [ -f compose.yml ]; then
    echo "Restarting Compose project in $dir (compose.yml)"
    docker compose -f compose.yml restart
  else
    echo "Skipping $dir. No compose file found."
  fi
done