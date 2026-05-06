#!/usr/bin/env bash
# /docker/tailscale-certs/renew.sh
#
# Purpose:
#   Renew exported Tailscale cert files only when missing or close to expiry.
#
# Handles:
#   1) Host machine cert in /docker/tailscale-certs
#   2) Optional sidecar services like jellyfin and flame
#
# Dry run:
#   bash /docker/tailscale-certs/renew.sh --dry-run
#
# Normal run:
#   bash /docker/tailscale-certs/renew.sh
#
# Notes:
#   - This script renews FILE-BASED certs created by `tailscale cert`.
#   - It does NOT control Tailscale Serve's built-in HTTPS behavior.
#   - Dry run verifies config, containers, paths, detected domains, current
#     cert expiry, and whether renewal WOULD happen, without changing anything.
#   - Edit only the USER SETTINGS section unless you know what you are doing.

set -euo pipefail

###############################################################################
# USER SETTINGS
###############################################################################

# Host machine cert output directory and filenames.
HOST_CERT_DIR="/docker/tailscale-certs"
HOST_CERT_FILE="cert.crt"
HOST_KEY_FILE="cert.key"

# Renew if cert expires within this many days.
RENEW_BEFORE_DAYS=35

# Restart running nginx containers after any renewal.
# Set to 0 to disable.
RESTART_NGINX=1

# Optional sidecar services to renew.
# Add more names here as needed.
EXTRA_SERVICES=("jellyfin" "flame" "jellyseerr" "audiobookshelf" "brave" "ntfy")

# Optional per-service container overrides.
# Default if omitted: tailscale-<service>
declare -A SERVICE_CONTAINER=(
  [jellyfin]="tailscale-jellyfin"
  [flame]="tailscale-flame"
  [jellyseerr]="tailscale-jellyseerr"
  [audiobookshelf]="tailscale-audiobookshelf"
  [brave]="tailscale-brave"
)

# Optional per-service cert directory overrides.
# Default if omitted: /docker/<service>/ts/state/certs
declare -A SERVICE_CERT_DIR=(
  [jellyfin]="/docker/jellyfin/ts/state/certs"
  [flame]="/docker/flame/ts/state/certs"
  [jellyseerr]="/docker/jellyseerr/ts/state/certs"
  [audiobookshelf]="/docker/audiobookshelf/ts/state/certs"
  [brave]="/docker/brave/ts/state/certs"
)

###############################################################################
# INTERNALS
###############################################################################

SCRIPT_NAME="$(basename "$0")"
RENEW_BEFORE_SECONDS=$(( RENEW_BEFORE_DAYS * 24 * 60 * 60 ))
ANY_RENEWED=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage:
  bash /docker/tailscale-certs/renew.sh [--dry-run] [--help]

Options:
  --dry-run   Validate config and show what would be renewed without changing anything
  --help      Show this help
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

json_dnsname_from_stdin() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))'
  elif command -v jq >/dev/null 2>&1; then
    jq -r '.Self.DNSName' | sed 's/\.$//'
  else
    die "Need python3 or jq to parse tailscale JSON output"
  fi
}

cert_valid_enough() {
  local cert_file="$1"
  [ -f "${cert_file}" ] || return 1
  openssl x509 -checkend "${RENEW_BEFORE_SECONDS}" -noout -in "${cert_file}" >/dev/null 2>&1
}

show_cert_expiry() {
  local label="$1"
  local cert_file="$2"

  if [ -f "${cert_file}" ]; then
    local enddate
    enddate="$(openssl x509 -enddate -noout -in "${cert_file}" 2>/dev/null | sed 's/^notAfter=//')"
    log "${label}: ${enddate}"
  else
    log "${label}: cert file not found"
  fi
}

renew_host_cert() {
  require_cmd tailscale

  mkdir -p "${HOST_CERT_DIR}"

  local fqdn cert_file key_file
  fqdn="$(tailscale status --self --json | json_dnsname_from_stdin)"
  [ -n "${fqdn}" ] || die "Could not detect host MagicDNS name"

  cert_file="${HOST_CERT_DIR}/${HOST_CERT_FILE}"
  key_file="${HOST_CERT_DIR}/${HOST_KEY_FILE}"

  log "Host machine FQDN: ${fqdn}"
  show_cert_expiry "Host cert (${fqdn}) current expiry" "${cert_file}"

  if cert_valid_enough "${cert_file}"; then
    log "Host cert is still valid for more than ${RENEW_BEFORE_DAYS} day(s). Skipping."
    return 0
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    log "[dry-run] Would renew host cert for ${fqdn}"
    log "[dry-run] Would write:"
    log "[dry-run]   ${cert_file}"
    log "[dry-run]   ${key_file}"
    return 0
  fi

  log "Renewing host cert for ${fqdn}"
  tailscale cert --cert-file "${cert_file}" --key-file "${key_file}" "${fqdn}" >/dev/null

  [ -f "${cert_file}" ] || die "Host cert was not written: ${cert_file}"
  [ -f "${key_file}" ] || die "Host key was not written: ${key_file}"

  chmod 640 "${cert_file}" "${key_file}" || true

  show_cert_expiry "Host cert (${fqdn}) new expiry" "${cert_file}"
  ANY_RENEWED=1
}

renew_service_cert() {
  local service="$1"
  local container cert_dir fqdn cert_file key_file

  container="${SERVICE_CONTAINER[${service}]:-tailscale-${service}}"
  cert_dir="${SERVICE_CERT_DIR[${service}]:-/docker/${service}/ts/state/certs}"

  if ! docker inspect "${container}" >/dev/null 2>&1; then
    log "Skipping ${service}: container not found (${container})"
    return 0
  fi

  if [ "$(docker inspect -f '{{.State.Running}}' "${container}" 2>/dev/null || true)" != "true" ]; then
    log "Skipping ${service}: container not running (${container})"
    return 0
  fi

  mkdir -p "${cert_dir}"

  fqdn="$(docker exec "${container}" tailscale status --self --json | json_dnsname_from_stdin || true)"
  if [ -z "${fqdn}" ]; then
    log "Skipping ${service}: could not detect MagicDNS name from ${container}"
    return 0
  fi

  cert_file="${cert_dir}/${fqdn}.crt"
  key_file="${cert_dir}/${fqdn}.key"

  log "Service ${service} container: ${container}"
  log "Service ${service} FQDN: ${fqdn}"
  show_cert_expiry "Service cert (${fqdn}) current expiry" "${cert_file}"

  if cert_valid_enough "${cert_file}"; then
    log "Service cert for ${service} is still valid for more than ${RENEW_BEFORE_DAYS} day(s). Skipping."
    return 0
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    log "[dry-run] Would renew service cert for ${fqdn} via ${container}"
    log "[dry-run] Would write:"
    log "[dry-run]   ${cert_file}"
    log "[dry-run]   ${key_file}"
    return 0
  fi

  log "Renewing service cert for ${fqdn} via ${container}"
  docker exec "${container}" mkdir -p /var/lib/tailscale/certs
  docker exec "${container}" tailscale cert \
    --cert-file "/var/lib/tailscale/certs/${fqdn}.crt" \
    --key-file "/var/lib/tailscale/certs/${fqdn}.key" \
    "${fqdn}" >/dev/null

  [ -f "${cert_file}" ] || die "Service cert was not written: ${cert_file}"
  [ -f "${key_file}" ] || die "Service key was not written: ${key_file}"

  chmod 640 "${cert_file}" "${key_file}" || true

  show_cert_expiry "Service cert (${fqdn}) new expiry" "${cert_file}"
  ANY_RENEWED=1
}

restart_nginx_if_needed() {
  if [ "${RESTART_NGINX}" -ne 1 ]; then
    log "Nginx restart disabled."
    return 0
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    log "[dry-run] Would restart running containers matching name=nginx if any certs required renewal."
    return 0
  fi

  if [ "${ANY_RENEWED}" -ne 1 ]; then
    log "No certs renewed. Skipping nginx restarts."
    return 0
  fi

  local ids
  ids="$(docker ps -q --filter 'name=nginx')"

  if [ -z "${ids}" ]; then
    log "No running nginx containers matched filter."
    return 0
  fi

  log "Restarting nginx containers"
  echo "${ids}" | xargs -r docker restart >/dev/null
}

show_notes() {
  log "Script: ${SCRIPT_NAME}"
  log "Renew threshold: ${RENEW_BEFORE_DAYS} day(s)"
  log "Host cert dir: ${HOST_CERT_DIR}"
  log "Extra services: ${EXTRA_SERVICES[*]:-none}"
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "Mode: dry-run"
  else
    log "Mode: live"
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
    shift
  done
}

main() {
  parse_args "$@"

  require_cmd docker
  require_cmd openssl

  show_notes
  renew_host_cert

  local service
  for service in "${EXTRA_SERVICES[@]}"; do
    renew_service_cert "${service}"
  done

  restart_nginx_if_needed

  if [ "${DRY_RUN}" -eq 1 ]; then
    log "Dry run complete. No changes were made."
  else
    log "Done."
  fi
}

main "$@"