#!/usr/bin/env python3
"""Safely reconcile maintenance references on an in-place Seerr upgrade.

Defaults to read-only dry-run. Does not restart/recreate Docker containers.
"""
import argparse
import datetime
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


def fail(message):
    raise SystemExit("ERROR: " + message)


def docker_inspect(name):
    import json
    try:
        return json.loads(subprocess.check_output(
            ["docker", "inspect", name],
            text=True, stderr=subprocess.DEVNULL
        ))[0]
    except (subprocess.CalledProcessError, IndexError, ValueError):
        fail("Missing or invalid Docker container: " + name)


def replace_once(content, old, new, desc):
    if content.count(old) != 1:
        fail("Expected exactly one " + desc + " entry. Manual review required.")
    return content.replace(old, new, 1)


def main():
    parser = argparse.ArgumentParser(
        description="Update legacy Seerr references in OMV maintenance files without restarting services."
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--apply", action="store_true", help="Back up and apply compatible file changes")
    group.add_argument("--dry-run", action="store_true", help="Read-only check (default)")
    args = parser.parse_args()
    if os.geteuid() != 0:
        fail("Run as root")
    mode = "apply" if args.apply else "dry-run"

    app = docker_inspect("jellyseerr")
    sidecar = docker_inspect("tailscale-jellyseerr")
    if not app["State"]["Running"] or not sidecar["State"]["Running"]:
        fail("The migrated Seerr application and Tailscale sidecar must be running.")
    image = app["Config"]["Image"]
    if not image.startswith("ghcr.io/seerr-team/seerr:"):
        fail("Expected a migrated Seerr image under the legacy jellyseerr container.")
    labels = app["Config"]["Labels"]
    if (labels.get("com.docker.compose.project") != "jellyseerr"
            or labels.get("com.docker.compose.service") != "jellyseerr"):
        fail("Unexpected app Compose project/service; refusing to guess.")
    if not any(
        m["Source"] == "/docker/jellyseerr/ts/state"
        and m["Destination"] == "/var/lib/tailscale"
        for m in sidecar["Mounts"]
    ):
        fail("Unexpected Tailscale state mount; no changes made.")

    changes = {}
    notes = []
    cert_path = Path("/docker/tailscale-certs/renew.sh")
    if cert_path.is_file():
        old = cert_path.read_text()
        new = old
        if "Seerr: migrated sidecar" in old or "Seerr: detected migrated sidecar" in old:
            notes.append("Certificate renewal: migration-aware fallback already present")
        elif re.search(r'EXTRA_SERVICES=\([^\n]*"jellyseerr"', old):
            notes.append("Certificate renewal: existing jellyseerr service entry retained")
        elif re.search(r'EXTRA_SERVICES=\([^\n]*"seerr"', old):
            if '[seerr]="tailscale-seerr"' in old and '[seerr]="/docker/seerr/ts/state/certs"' in old:
                new = replace_once(new, '[seerr]="tailscale-seerr"',
                                   '[seerr]="tailscale-jellyseerr"', "Seerr renewal container")
                new = replace_once(new, '[seerr]="/docker/seerr/ts/state/certs"',
                                   '[seerr]="/docker/jellyseerr/ts/state/certs"', "Seerr renewal certificate path")
                notes.append("Certificate renewal: align existing seerr entry with migrated sidecar")
            else:
                fail("Certificate renewal Seerr entries are customized; inspect manually.")
        else:
            notes.append("Certificate renewal: no seerr/jellyseerr entry found; inspect manually")
        if new != old:
            changes[cert_path] = new
    else:
        notes.append("Certificate renewal: file not found; skipped")

    restart_path = Path("/docker/restart_defined_compose.sh")
    if restart_path.is_file():
        old = restart_path.read_text()
        new = old
        if '"@active-seerr"' in old:
            notes.append("Restart script: active Seerr detection already present")
        elif re.search(r'(?m)^\s*"/docker/jellyseerr"\s*$', old):
            notes.append("Restart script: existing legacy directory already configured")
        elif re.search(r'(?m)^\s*"/docker/seerr"\s*$', old):
            new, count = re.subn(r'(?m)^([ \t]*)"/docker/seerr"([ \t]*)$',
                                 r'\1"/docker/jellyseerr"\2', old)
            if count != 1:
                fail("Restart script: multiple Seerr directory entries")
            notes.append("Restart script: use active legacy Compose directory")
        else:
            notes.append("Restart script: no recognized Seerr entry; inspect manually")
        if new != old:
            changes[restart_path] = new
    else:
        notes.append("Restart script: file not found; skipped")

    watchtower_path = Path("/docker/watchtower/compose.yml")
    if watchtower_path.is_file():
        old = watchtower_path.read_text()
        lines = old.splitlines(keepends=True)
        active = [i for i, line in enumerate(lines)
                  if re.match(r'^[ \t]*command:[ \t]*', line)]
        if len(active) != 1:
            notes.append("Watchtower: unsupported/missing inline command; left unchanged")
        else:
            i = active[0]
            line = lines[i]
            if not ("jellyseerr" in line and "tailscale-jellyseerr" in line):
                line = re.sub(r'(?<=\s)tailscale-seerr(?=\s|$)',
                              "tailscale-jellyseerr", line)
                line = re.sub(r'(?<=\s)seerr(?=\s|$)', "jellyseerr", line)
            line = re.sub(r'(?<=\s)mariadb_seerr(?=\s|$)', "", line)
            if line != lines[i]:
                lines[i] = line
                changes[watchtower_path] = "".join(lines)
                notes.append("Watchtower: preserve schedule and use live migrated container names")
            else:
                notes.append("Watchtower: inline command requires no change")
    else:
        notes.append("Watchtower: Compose file not found; skipped")

    print("Migrated Seerr maintenance (" + mode + ")")
    for note in notes:
        print(" - " + note)
    if not changes:
        print("No recognized file edits required.")
    else:
        print("Files to update:")
        for path in changes:
            print(" - " + str(path))

    # Never display file contents: Compose may contain plaintext passwords.
    if not args.apply:
        print("Dry run complete. Nothing changed.")
        return

    # Validate all prospective shell edits before writing anything.
    for path, value in changes.items():
        if path.suffix == ".sh":
            check = subprocess.run(["bash", "-n"], input=value, text=True,
                                   capture_output=True)
            if check.returncode:
                fail("Shell syntax rejected for " + str(path))

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    backups = {}
    changed = []
    try:
        for path, value in changes.items():
            current = path.read_text()
            backup = path.with_name(path.name + ".backup-" + stamp)
            if backup.exists():
                fail("Backup path already exists: " + str(backup))
            shutil.copy2(path, backup)
            backup.chmod(0o600)
            backups[path] = backup
            metadata = path.stat()
            fd, tempname = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
            try:
                with os.fdopen(fd, "w") as output:
                    output.write(value)
                os.chown(tempname, metadata.st_uid, metadata.st_gid)
                os.chmod(tempname, stat.S_IMODE(metadata.st_mode))
                os.replace(tempname, path)
            finally:
                if os.path.exists(tempname):
                    os.unlink(tempname)
            changed.append(path)
    except Exception:
        for path in reversed(changed):
            shutil.copy2(backups[path], path)
        raise

    for path in changed:
        print("Updated:", str(path))
        print("Backup:", str(backups[path]))
    print("No containers recreated or restarted.")
    print("If Watchtower Compose changed, its running command remains unchanged until separately recreated.")
    print("Pi-hole, Seerr data and Tailscale state were not modified.")


if __name__ == "__main__":
    main()
