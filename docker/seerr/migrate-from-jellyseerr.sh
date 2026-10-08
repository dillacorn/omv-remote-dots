#!/usr/bin/env bash
# Migrate the supported Jellyseerr Docker Compose layout to Seerr in place.
# Optional Pi-hole DNS/Nginx hostname correction is separate and opt-in.
set -Eeuo pipefail
umask 077

SOURCE_DIR=/docker/jellyseerr
PIHOLE_DIR=/docker/pihole
IMAGE=ghcr.io/seerr-team/seerr:v3.5.0
MODE=dry-run
PHASE=app
RENAME_PIHOLE=0
BACKUP_ROOT=
STOPPED=0
ARMED=0
APP_SUCCESS=0
PIHOLE_ARMED=0
PIHOLE_SUCCESS=0
PIHOLE_BACKUP=
PIHOLE_COMPOSE_FILE=
NGINX_FILE=
OLD_FQDN=
NEW_FQDN=
SEERR_CONTAINER=jellyseerr
TS_CONTAINER=tailscale-jellyseerr
DC=()
PDC=()

say() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }
usage() {
  printf '%s\n' \
    'Usage: migrate-from-jellyseerr.sh [--dry-run | --apply] [--rename-pihole]' \
    '       migrate-from-jellyseerr.sh --pihole-only [--dry-run | --apply]' \
    '       [--source-dir DIR] [--pihole-dir DIR]' \
    '' \
    'Default: read-only dry run for app migration.' \
    '--apply: migrate in place, retaining legacy container/project/Tailscale names.' \
    '--rename-pihole: after app migration, update local Pi-hole DNS and Nginx FQDN.' \
    '--pihole-only: do only the optional Pi-hole rename (for already-migrated hosts).' \
    'Rename the Tailscale machine from jellyseerr to seerr first when using Pi-hole option.' \
    'No secrets, database files, or Tailscale state are deleted.'
}
while (($#)); do
  case "$1" in
    --dry-run) MODE=dry-run ;;
    --apply) MODE=apply ;;
    --rename-pihole) RENAME_PIHOLE=1 ;;
    --pihole-only) PHASE=pihole ;;
    --source-dir|--pihole-dir)
      opt=$1
      shift
      (($#)) || fail "Missing value for $opt"
      case "$opt" in
        --source-dir) SOURCE_DIR=$1 ;;
        --pihole-dir) PIHOLE_DIR=$1 ;;
      esac
      ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; fail "Unknown option: $1" ;;
  esac
  shift
done
if [[ $PHASE == pihole && $RENAME_PIHOLE == 1 ]]; then
  fail '--pihole-only and --rename-pihole are mutually exclusive'
fi

for cmd in docker python3 cp stat mktemp realpath grep mv; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing command: $cmd"
done
[[ $EUID == 0 ]] || fail 'Run as root (backups and protected Compose paths require root)'
[[ $SOURCE_DIR == /* && $PIHOLE_DIR == /* ]] || fail 'Directories must be absolute paths'
[[ -d $SOURCE_DIR ]] || fail "Missing $SOURCE_DIR"
SOURCE_DIR="$(realpath "$SOURCE_DIR")"
[[ $SOURCE_DIR != / ]] || fail 'Invalid source directory'
[[ -d $PIHOLE_DIR || $PHASE != pihole && $RENAME_PIHOLE != 1 ]] || fail "Missing $PIHOLE_DIR"
if [[ -d $PIHOLE_DIR ]]; then PIHOLE_DIR="$(realpath "$PIHOLE_DIR")"; fi

# Use the exact Compose files reported by the live container. Never assume
# overlays can be omitted or recompose unrelated services.
compose_files() {
  local name=$1 dir=$2 list item
  list="$(docker inspect "$name" --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}')" || return 1
  [[ -n $list && $list != '<no value>' ]] || fail "No Compose file labels on $name"
  local -a paths=()
  IFS=',' read -r -a paths <<< "$list"
  ((${#paths[@]})) || fail "No Compose files for $name"
  for item in "${paths[@]}"; do
    [[ -f $item ]] || fail "Missing active Compose file: $item"
    [[ "$(realpath "$(dirname "$item")")" == "$dir" ]] || fail "Unexpected Compose directory for $name: $item"
    printf '%s\n' "$item"
  done
}
compose_args() {
  local name=$1 dir=$2 file project
  project="$(docker inspect "$name" --format '{{index .Config.Labels "com.docker.compose.project"}}')" || return 1
  [[ -n $project && $project != '<no value>' ]] || fail "Missing Compose project for $name"
  local -a files=()
  mapfile -t files < <(compose_files "$name" "$dir")
  ((${#files[@]})) || fail "No Compose files for $name"
  local -n dest=$3
  dest=(docker compose --project-directory "$dir" -p "$project")
  for file in "${files[@]}"; do dest+=(-f "$file"); done
}

# All database reads below are read-only. A MySQL-configured install is allowed
# only if the configured MariaDB database is confirmed to have no tables.
check_source_db() {
  local path="$SOURCE_DIR/jellyseerr/config/db/db.sqlite3"
  [[ -f $path ]] || fail "Missing SQLite DB: $path. Manual database migration required."
  python3 - "$path" <<'PY'
import sqlite3,sys
path=sys.argv[1]
with sqlite3.connect(f'file:{path}?mode=ro',uri=True) as db:
    ok=db.execute('PRAGMA integrity_check').fetchone()[0]
    if ok!='ok': raise SystemExit(f'SQLite integrity check: {ok}')
    for table in ('user','media_request'):
        n=db.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0]
        print(f'Existing {table}: {n}')
PY
}

app_preflight() {
  [[ -f $SOURCE_DIR/compose.yml && -f $SOURCE_DIR/.env ]] || fail 'Missing Compose or .env'
  [[ ! -e $SOURCE_DIR/seerr ]] || fail "Target already exists: $SOURCE_DIR/seerr (never overwrite)"
  [[ $(docker inspect "$SEERR_CONTAINER" --format '{{.State.Running}}') == true ]] || fail 'Jellyseerr is not running'
  [[ $(docker inspect "$SEERR_CONTAINER" --format '{{.Config.Image}}') == fallenbagel/jellyseerr:* ]] || fail 'Source is not the supported fallenbagel/jellyseerr image; do not rerun after migration'
  [[ $(docker inspect "$SEERR_CONTAINER" --format '{{index .Config.Labels "com.docker.compose.service"}}') == jellyseerr ]] || fail 'Unexpected Compose service'
  [[ $(docker inspect "$SEERR_CONTAINER" --format '{{index .Config.Labels "com.docker.compose.project"}}') == jellyseerr ]] || fail 'Unexpected Compose project'
  [[ $(docker inspect "$SEERR_CONTAINER" --format '{{.HostConfig.NetworkMode}}') == container:* ]] || fail 'Expected shared Tailscale network namespace'
  [[ $(docker inspect "$TS_CONTAINER" --format '{{.State.Running}}') == true ]] || fail 'Tailscale sidecar not running'
  compose_args "$SEERR_CONTAINER" "$SOURCE_DIR" DC
  "${DC[@]}" config --format json | python3 -c '
import json,os,sys
app=json.load(sys.stdin)["services"]["jellyseerr"]
source=sys.argv[1]
assert app["image"].startswith("fallenbagel/jellyseerr:"),"Unexpected app image"
assert app.get("network_mode")=="service:tailscale","Unexpected network namespace"
assert any(v["source"]==source+"/jellyseerr/config" and v["target"]=="/app/config" for v in app["volumes"]),"Unexpected configuration mount"
assert app.get("environment",{}).get("DB_TYPE") in ("sqlite","mysql"),"Unsupported database type"
print("Configured DB_TYPE:",app["environment"]["DB_TYPE"])
' "$SOURCE_DIR"
  check_source_db
  local dbtype
  dbtype="$("${DC[@]}" config --format json | python3 -c 'import json,sys;print(json.load(sys.stdin)["services"]["jellyseerr"]["environment"]["DB_TYPE"])')"
  if [[ $dbtype == mysql ]]; then
    [[ $(docker inspect mariadb_jellyseerr --format '{{.State.Running}}') == true ]] || fail 'Configured for MySQL but MariaDB is not running; refusing SQLite substitution'
    local tablecount
    tablecount="$(docker exec mariadb_jellyseerr sh -ec '
       db="${MYSQL_DATABASE:-}"; usr="${MYSQL_USER:-}"; pwd="${MYSQL_PASSWORD:-}"
       [ -n "$db" ] && [ -n "$usr" ] && [ -n "$pwd" ]
       MYSQL_PWD="$pwd" mariadb -u "$usr" "$db" -N -B -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()"
     ')" || fail 'Cannot check MariaDB tables; manual migration required'
    [[ $tablecount == 0 ]] || fail "MariaDB contains $tablecount tables; cannot automatically migrate MySQL data to SQLite"
    say 'MariaDB: configured database has zero tables (SQLite data will be used)'
  fi
  # The strict anchors avoid rewriting unknown or heavily customized layouts.
  python3 - "$SOURCE_DIR/compose.yml" "$SOURCE_DIR/.env" <<'PY'
from pathlib import Path
import sys
c=Path(sys.argv[1]).read_text();e=Path(sys.argv[2]).read_text()
marker='\n  jellyseerr:\n'
assert c.count(marker)==1,'Service block missing or duplicated'
_,app=c.split(marker,1)
for s in ('    image: ${IMAGE_URL}\n','    network_mode: "service:tailscale"\n',
          '      - DB_HOST=${DB_HOST}\n','      - DB_NAME=${DB_NAME}\n',
          '      - DB_USER=${DB_USER}\n','      - DB_PASS=${DB_PASS}\n',
          '      - ${JELLYSEERR_CONFIG_PATH}:/app/config\n',
          '      mariadb_jellyseerr:\n        condition: service_started\n'):
    assert app.count(s)==1, f'Unsupported Compose service structure: {s.strip()}'
for k in ('IMAGE_URL','DB_TYPE','JELLYSEERR_CONFIG_PATH'):
    assert sum(line.startswith(k+'=') for line in e.splitlines())==1,f'Missing/duplicate .env key: {k}'
assert 'JELLYSEERR_CONFIG_PATH=./jellyseerr/config' in e,'Unsupported config path'
assert 'IMAGE_URL=fallenbagel/jellyseerr:' in e,'Unexpected .env image'
print('Compose edit anchors: OK')
PY
  docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    if [[ $MODE == apply ]]; then docker pull "$IMAGE"; else say "Image not cached: $IMAGE (will pull on apply)"; fi
  }
}

rollback_app() {
  if (( ! ARMED || APP_SUCCESS )); then return 0; fi
  say 'ROLLBACK: restoring original Jellyseerr Compose and .env'
  if [[ -n $BACKUP_ROOT && -f $BACKUP_ROOT/compose.yml && -f $BACKUP_ROOT/.env ]]; then
    cp -a "$BACKUP_ROOT/compose.yml" "$SOURCE_DIR/compose.yml" || true
    cp -a "$BACKUP_ROOT/.env" "$SOURCE_DIR/.env" || true
  fi
  if ((${#DC[@]})); then
    "${DC[@]}" up -d --no-deps --force-recreate jellyseerr || say 'ROLLBACK WARNING: could not restart original service'
  fi
  say "Original application data retained; backup: ${BACKUP_ROOT:-not-created}"
}

backup_sqlite_counts() {
  python3 - "$1" "$2" <<'PY'
import sqlite3,sys
old,new=sys.argv[1:]
def inspect(path):
    with sqlite3.connect(f'file:{path}?mode=ro',uri=True) as db:
        assert db.execute('PRAGMA integrity_check').fetchone()[0]=='ok'
        return {t:db.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0] for t in ('user','media_request')}
a=inspect(old);b=inspect(new)
for t in a:
    print(f'{t}: {a[t]} -> {b[t]}')
    assert b[t]>=a[t],f'Data loss in {t}'
print('SQLite integrity and row counts: OK')
PY
}

app_apply() {
  local backupdir="$SOURCE_DIR/../jellyseerr-migration-backups"
  mkdir -p -m 700 "$backupdir"
  BACKUP_ROOT="$(mktemp -d "$backupdir/precutover-XXXXXXXX")"
  say "Cold backup location: $BACKUP_ROOT"
  ARMED=1
  "${DC[@]}" stop jellyseerr
  STOPPED=1
  # An incomplete backup is not a reason to touch the original data.
  cp -a "$SOURCE_DIR/compose.yml" "$SOURCE_DIR/.env" "$BACKUP_ROOT/"
  if [[ -f $SOURCE_DIR/compose.override.yml ]]; then cp -a "$SOURCE_DIR/compose.override.yml" "$BACKUP_ROOT/"; fi
  cp -a "$SOURCE_DIR/jellyseerr/config" "$BACKUP_ROOT/old-config"
  if [[ -d $SOURCE_DIR/ts/state ]]; then cp -a "$SOURCE_DIR/ts/state" "$BACKUP_ROOT/tailscale-state"; fi
  backup_sqlite_counts "$SOURCE_DIR/jellyseerr/config/db/db.sqlite3" "$BACKUP_ROOT/old-config/db/db.sqlite3"
  mkdir -p "$SOURCE_DIR/seerr/config"
  cp -a "$SOURCE_DIR/jellyseerr/config/." "$SOURCE_DIR/seerr/config/"
  chown -R 1000:1000 "$SOURCE_DIR/seerr/config"
  chmod -R u+rwX "$SOURCE_DIR/seerr/config"
  python3 - "$SOURCE_DIR/compose.yml" "$SOURCE_DIR/.env" <<'PY'
from pathlib import Path
import sys
p,q=(Path(x) for x in sys.argv[1:])
c=p.read_text();e=q.read_text()
pre,service=c.split('\n  jellyseerr:\n',1)
for a,b in (
    ('    image: ${IMAGE_URL}\n','    image: ${IMAGE_URL}\n    init: true\n'),
    ('      - DB_HOST=${DB_HOST}\n',''),('      - DB_NAME=${DB_NAME}\n',''),
    ('      - DB_USER=${DB_USER}\n',''),('      - DB_PASS=${DB_PASS}\n',''),
    ('      mariadb_jellyseerr:\n        condition: service_started\n','')):
    assert service.count(a)==1
    service=service.replace(a,b,1)
e=e.replace(next(line for line in e.splitlines() if line.startswith('IMAGE_URL=')),
            'IMAGE_URL=ghcr.io/seerr-team/seerr:v3.5.0',1)
e=e.replace(next(line for line in e.splitlines() if line.startswith('DB_TYPE=')),
            'DB_TYPE=sqlite',1)
e=e.replace('JELLYSEERR_CONFIG_PATH=./jellyseerr/config',
            'JELLYSEERR_CONFIG_PATH=./seerr/config',1)
# Write the complete replacement only after all structure assertions passed.
p.write_text(pre+'\n  jellyseerr:\n'+service)
q.write_text(e)
PY
  "${DC[@]}" config --format json | python3 -c '
import json,sys
x=json.load(sys.stdin)["services"]["jellyseerr"]
assert x["image"]=="ghcr.io/seerr-team/seerr:v3.5.0"
assert x["init"] is True
assert x["environment"]["DB_TYPE"]=="sqlite"
assert "mariadb_jellyseerr" not in x.get("depends_on",{})
assert x["network_mode"]=="service:tailscale"
print("Updated Compose configuration: OK")'
  "${DC[@]}" up -d --no-deps --force-recreate jellyseerr
  local ready=0 state attempts=${SEERR_MIGRATION_STARTUP_ATTEMPTS:-60}
  [[ $attempts =~ ^[1-9][0-9]*$ ]] || fail "Invalid startup attempts"
  for ((i=0;i<attempts;i++)); do
    if docker exec "$SEERR_CONTAINER" node -e 'fetch("http://127.0.0.1:5055/api/v1/settings/public").then(r=>{if(!r.ok)process.exitCode=1}).catch(()=>{process.exitCode=1})' >/dev/null 2>&1; then
      ready=1; break
    fi
    state="$(docker inspect "$SEERR_CONTAINER" --format '{{.State.Running}}' || true)"
    [[ $state == true ]] || break
    sleep 2
  done
  ((ready)) || { docker logs --tail 60 "$SEERR_CONTAINER" || true; fail 'Seerr startup check failed'; }
  backup_sqlite_counts "$BACKUP_ROOT/old-config/db/db.sqlite3" "$SOURCE_DIR/seerr/config/db/db.sqlite3"
  [[ $(docker inspect "$SEERR_CONTAINER" --format '{{.Config.Image}}') == "$IMAGE" ]] || fail 'Unexpected final application image'
  APP_SUCCESS=1
  say "Seerr running, app backup: $BACKUP_ROOT"
}

get_ts_name() {
  docker exec "$TS_CONTAINER" tailscale status --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))'
}

pihole_preflight() {
  [[ $(docker inspect pihole --format '{{.State.Running}}') == true ]] || fail 'Pi-hole is not running'
  [[ $(docker inspect nginx-pihole --format '{{.State.Running}}') == true ]] || fail 'nginx-pihole is not running'
  [[ $(docker inspect "$TS_CONTAINER" --format '{{.State.Running}}') == true ]] || fail 'Tailscale sidecar not running'
  NEW_FQDN="$(get_ts_name)" || fail 'Could not get Tailscale DNS name'
  [[ $NEW_FQDN == seerr.*.ts.net ]] || fail "Tailscale machine is '$NEW_FQDN', not renamed to seerr. Rename it in Tailscale first."
  OLD_FQDN="jellyseerr.${NEW_FQDN#seerr.}"
  compose_args pihole "$PIHOLE_DIR" PDC
  NGINX_FILE="$PIHOLE_DIR/conf.d/jellyseerr.conf"
  [[ -f $NGINX_FILE ]] || fail "Expected legacy Nginx file missing: $NGINX_FILE"
  [[ ! -e $PIHOLE_DIR/conf.d/seerr.conf ]] || fail 'New nginx seerr.conf already exists; manual inspection required'
  [[ -f $SOURCE_DIR/ts/state/certs/$NEW_FQDN.crt && -f $SOURCE_DIR/ts/state/certs/$NEW_FQDN.key ]] || fail 'New Seerr certificate files missing'
  local -a files=()
  mapfile -t files < <(compose_files pihole "$PIHOLE_DIR")
  local hits=0 f
  for f in "${files[@]}"; do
    if grep -Fq "$OLD_FQDN" "$f"; then
      PIHOLE_COMPOSE_FILE=$f
      ((hits+=1))
    fi
  done
  ((hits==1)) || fail "Expected exactly one active Compose file containing $OLD_FQDN (got $hits)"
  grep -Fq "$OLD_FQDN" "$NGINX_FILE" || fail 'Old Nginx hostname not found'
  grep -Fq 'http://tailscale-jellyseerr:5055' "$NGINX_FILE" || fail 'Nginx backend differs from the preserved Docker name; do not modify automatically'
  # The new certificate paths must already be exposed by nginx's existing mount.
  docker inspect nginx-pihole --format '{{range .Mounts}}{{printf "%s|%s\n" .Source .Destination}}{{end}}' | grep -Fx "$SOURCE_DIR/ts/state/certs|/etc/nginx/jellyseerr-certs" >/dev/null || fail 'Nginx certificate mount differs from expected path'
  docker inspect pihole | python3 -c '
import json,sys
container=json.load(sys.stdin)[0]
match=[x.split("=",1)[1] for x in container["Config"]["Env"] if x.startswith("FTLCONF_dns_hosts=")]
assert len(match)==1 and sys.argv[1] in match[0],"Live Pi-hole environment does not contain legacy hostname"
print("Live Pi-hole environment: legacy hostname found")
' "$OLD_FQDN"
  # Never assume that Compose overlays / environment at deployment time remain the same.
  "${PDC[@]}" config --format json | python3 -c '
import json,subprocess,sys
services=json.load(sys.stdin)["services"]
assert "pihole" in services and "dnsproxy" in services,"Expected pihole and dnsproxy services"
app=services["pihole"]
assert sys.argv[1] in app["environment"]["FTLCONF_dns_hosts"],"Current Compose is missing old hostname"
observed=json.loads(subprocess.check_output(["docker","inspect","pihole"]))[0]
proxy=json.loads(subprocess.check_output(["docker","inspect","dnsproxy"]))[0]
for name, runtime in (("pihole",observed),("dnsproxy",proxy)):
    declared=services[name]
    assert declared.get("image")==runtime["Config"].get("Image"),f"{name} runtime image differs from current Compose"
    if "command" in declared:
        assert declared["command"]==runtime["Config"].get("Cmd"),f"{name} runtime command differs from current Compose"
    declared_mounts={(v["source"],v["target"]) for v in declared.get("volumes",[]) if isinstance(v,dict)}
    running_mounts={(v["Source"],v["Destination"]) for v in runtime.get("Mounts",[])}
    assert declared_mounts.issubset(running_mounts),f"{name} Compose volume mounts differ from live container"
live={x.split("=",1)[0]:x.split("=",1)[1] for x in observed["Config"]["Env"] if "=" in x}
for k,v in app.get("environment",{}).items():
    if k.startswith("FTLCONF_"):
        assert str(v)==live.get(k),f"{k} differs from live Pi-hole; do not recreate with unknown environment"
# A missing runtime-only network/port variable can silently change a recreated
# Pi-hole. Compare declared Compose bindings to actual container bindings.
for port in app.get("ports",[]):
    if port.get("published"):
        key=str(port["target"])+"/"+port.get("protocol","tcp")
        bindings=observed["HostConfig"].get("PortBindings",{}).get(key,[])
        assert any(b.get("HostPort")==str(port["published"]) and b.get("HostIp") in (port.get("host_ip",""),"", "0.0.0.0") for b in bindings),f"Port binding {key} not equal to running Pi-hole"
print("Pi-hole Compose environment/ports matched to runtime")
' "$OLD_FQDN"
  [[ $(docker inspect dnsproxy --format '{{.State.Running}}') == true ]] || fail 'dnsproxy is not running; automatic Pi-hole service recreate unsupported'
  [[ $(docker inspect dnsproxy --format '{{index .Config.Labels "com.docker.compose.service"}}') == dnsproxy ]] || fail 'Unexpected DNS proxy Compose service'
  [[ $(docker inspect dnsproxy --format '{{index .Config.Labels "com.docker.compose.project"}}') == "$(docker inspect pihole --format '{{index .Config.Labels "com.docker.compose.project"}}')" ]] || fail 'DNS proxy belongs to another Compose project'
  say "Local DNS: $OLD_FQDN -> $NEW_FQDN"
  say "Nginx: $NGINX_FILE (backend stays tailscale-jellyseerr:5055)"
  say 'Pi-hole Compose file:' "$PIHOLE_COMPOSE_FILE"
}

rollback_pihole() {
  if (( ! PIHOLE_ARMED || PIHOLE_SUCCESS )); then return 0; fi
  say 'ROLLBACK: restoring Pi-hole and Nginx files'
  if [[ -n $PIHOLE_BACKUP && -d $PIHOLE_BACKUP ]]; then
    [[ -f $PIHOLE_BACKUP/dns-compose.yml ]] && cp -a "$PIHOLE_BACKUP/dns-compose.yml" "$PIHOLE_COMPOSE_FILE" || true
    [[ -f $PIHOLE_BACKUP/jellyseerr.conf ]] && cp -a "$PIHOLE_BACKUP/jellyseerr.conf" "$NGINX_FILE" || true
    if [[ -f $PIHOLE_BACKUP/jellyseerr.conf && -f $PIHOLE_DIR/conf.d/seerr.conf ]]; then
      # Only remove the newly created path when original backup exists.
      rm -f -- "$PIHOLE_DIR/conf.d/seerr.conf" || true
    fi
  fi
  if ((${#PDC[@]})); then
    "${PDC[@]}" up -d --no-deps --force-recreate pihole dnsproxy || say 'ROLLBACK WARNING: Pi-hole/dnsproxy restart failed'
  fi
  docker exec nginx-pihole nginx -t >/dev/null 2>&1 && docker exec nginx-pihole nginx -s reload || true
  say "Original Pi-hole/Nginx file backup: $PIHOLE_BACKUP"
  say 'Check Pi-hole DNS state before retrying.'
}

pihole_apply() {
  local bdir="$PIHOLE_DIR/seerr-migration-backups"
  mkdir -p -m 700 "$bdir"
  PIHOLE_BACKUP="$(mktemp -d "$bdir/rename-XXXXXXXX")"
  cp -a "$PIHOLE_COMPOSE_FILE" "$PIHOLE_BACKUP/dns-compose.yml"
  cp -a "$NGINX_FILE" "$PIHOLE_BACKUP/jellyseerr.conf"
  PIHOLE_ARMED=1
  # Replace only the hostnames: preserve the old container name and nginx mount.
  python3 - "$PIHOLE_COMPOSE_FILE" "$NGINX_FILE" "$OLD_FQDN" "$NEW_FQDN" <<'PY'
from pathlib import Path
import re,sys
c,n,old,new=sys.argv[1:]
for name in (c,n):
    p=Path(name);text=p.read_text()
    assert text.count(old)>0
    assert not re.search(r'(?<![a-z0-9-])'+re.escape(new),text), f'New FQDN already in {name}'
    p.write_text(text.replace(old,new))
PY
  # Rename conf only after successful content transformation.
  mv -- "$NGINX_FILE" "$PIHOLE_DIR/conf.d/seerr.conf"
  "${PDC[@]}" config --format json | python3 -c '
import json,sys
x=json.load(sys.stdin)["services"]["pihole"]["environment"]["FTLCONF_dns_hosts"]
assert sys.argv[1] in x and sys.argv[2] not in x
print("Pi-hole Compose DNS host update: OK")' "$NEW_FQDN" "$OLD_FQDN"
  docker exec nginx-pihole nginx -t
  # Preserve all active Compose overlays. The project's dnsproxy shares the
  # Pi-hole network namespace, so recreate them together and no other service.
  "${PDC[@]}" up -d --no-deps --force-recreate pihole dnsproxy
  docker inspect pihole | python3 -c '
import json,sys
x=json.load(sys.stdin)[0]["Config"]["Env"]
hosts=[z.split("=",1)[1] for z in x if z.startswith("FTLCONF_dns_hosts=")]
assert len(hosts)==1 and sys.argv[1] in hosts[0] and sys.argv[2] not in hosts[0],"New Pi-hole DNS hostname not loaded"
print("Running Pi-hole DNS host update: OK")' "$NEW_FQDN" "$OLD_FQDN"
  [[ $(docker inspect dnsproxy --format '{{.State.Running}}') == true ]] || fail 'DNS proxy not running after recreate'
  docker exec nginx-pihole nginx -s reload
  PIHOLE_SUCCESS=1
  say 'Pi-hole local DNS and Nginx routing updated and activated.'
  say "Pi-hole/Nginx backup: $PIHOLE_BACKUP"
}

on_error() {
  local status=$?
  trap - ERR INT TERM
  ((PIHOLE_SUCCESS)) || rollback_pihole
  ((APP_SUCCESS)) || rollback_app
  if ((APP_SUCCESS && ! PIHOLE_SUCCESS && PIHOLE_ARMED)); then say "Seerr migration completed, but Pi-hole update failed and was rolled back."; fi
  return "$status"
}
trap on_error ERR
on_signal() {
  trap - ERR INT TERM
  ((PIHOLE_SUCCESS)) || rollback_pihole
  ((APP_SUCCESS)) || rollback_app
  return 130
}
trap on_signal INT TERM

if [[ $PHASE == app ]]; then
  say "App migration ($MODE): $SOURCE_DIR"
  app_preflight
  if [[ $MODE == apply ]]; then app_apply; fi
fi
if [[ $PHASE == pihole || $RENAME_PIHOLE == 1 ]]; then
  say "Optional Pi-hole hostname rename ($MODE)"
  pihole_preflight
  if [[ $MODE == apply ]]; then pihole_apply; fi
fi

if [[ $MODE == dry-run ]]; then
  say 'Dry run complete. Nothing changed.'
else
  say 'Migration steps finished. Check Jellyfin sign-in, existing requests, Sonarr/Radarr and HTTPS.'
fi
if docker inspect "$TS_CONTAINER" >/dev/null 2>&1; then
  fqdn="$(get_ts_name 2>/dev/null || true)"
  [[ -n $fqdn ]] && say "Tailscale URL: https://$fqdn" || true
fi
if [[ $RENAME_PIHOLE == 0 && $PHASE == app ]]; then
  say 'Optional: rename the Tailscale machine to seerr, then run --pihole-only --apply if local Pi-hole DNS/Nginx still uses jellyseerr.'
fi