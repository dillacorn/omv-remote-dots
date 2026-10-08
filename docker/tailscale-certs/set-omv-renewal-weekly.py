#!/usr/bin/env python3
"""Set an existing OMV Tailscale certificate-renewal scheduled task to weekly.

Read-only unless --apply. Updates the OMV database through omv-confdbadm,
then asks OMV to regenerate its own cron files; never edits generated cron.
"""

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

MODEL = "conf.system.cron.job"
COMMAND = "bash /docker/tailscale-certs/renew.sh"
CONFIG_XML = Path("/etc/openmediavault/config.xml")
CRON_FILE = Path("/etc/cron.d/openmediavault-userdefined")
WRAPPERS = Path("/var/lib/openmediavault/cron.d")
BACKUP_PARENT = Path("/root/omv-renewal-weekly-backups")


def fail(message):
    raise RuntimeError(message)


def call(args):
    return subprocess.run(args, text=True, capture_output=True, check=True).stdout


def jobs():
    data = json.loads(call(["omv-confdbadm", "read", MODEL]))
    if not isinstance(data, list):
        fail("OMV cron database did not return a list")
    return data


def matching_job(entries):
    found = [entry for entry in entries if entry.get("command", "").strip() == COMMAND]
    if len(found) != 1:
        fail(f"Expected exactly one OMV job matching {COMMAND}; found {len(found)}")
    task = found[0]
    if task.get("type") != "userdefined" or task.get("username") != "root":
        fail("Unexpected OMV job type or user")
    if task.get("enable") not in (True, 1, "1"):
        fail("Certificate-renewal job is not enabled")
    if not re.fullmatch(r"[0-9a-fA-F-]{36}", str(task.get("uuid", ""))):
        fail("Invalid OMV job UUID")
    if task.get("execution") not in ("monthly", "weekly"):
        fail("Expected monthly or weekly execution mode")
    return task


def cron_line(uuid, schedule):
    if not CRON_FILE.is_file():
        fail("Missing OMV generated cron file")
    lines = CRON_FILE.read_text().splitlines()
    pattern = re.compile(
        rf"^\s*{re.escape(schedule)}\s+root\s+"
        rf"{re.escape(str(WRAPPERS / ('userdefined-' + uuid)))}(?=\s|$)"
    )
    matched = [line for line in lines if pattern.search(line)]
    if len(matched) != 1:
        fail(f"Expected one {schedule} generated cron entry for this UUID; found {len(matched)}")
    return matched[0]


def same_except_execution(original, updated):
    old = original.copy()
    new = updated.copy()
    old.pop("execution", None)
    new.pop("execution", None)
    return old == new


def apply():
    entries = jobs()
    original = matching_job(entries)
    uuid = original["uuid"]
    current = original["execution"]
    cron_line(uuid, "@" + current)
    print("OMV scheduled task:", uuid)
    print("Command:", COMMAND)
    print("Current schedule:", "@" + current)
    print("Requested schedule: @weekly (Sunday 00:00, local server time)")
    print("Notifications: preserved")

    if current == "weekly":
        print("Already weekly; no changes needed")
        return

    # Back up the OMV configuration and generated cron before updating the
    # database. config.xml may contain credentials; never print its contents.
    if not CONFIG_XML.is_file() or not CRON_FILE.is_file():
        fail("Missing OMV configuration or managed cron file")
    if CONFIG_XML.is_symlink() or CRON_FILE.is_symlink():
        fail("Unexpected symbolic link in OMV managed files")
    if not WRAPPERS.joinpath("userdefined-" + uuid).is_file():
        fail("OMV scheduled-task wrapper is missing")

    backup = BACKUP_PARENT / datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    backup.mkdir(parents=True, mode=0o700, exist_ok=False)
    backup.chmod(0o700)
    for source, name in ((CONFIG_XML, "config.xml"), (CRON_FILE, "openmediavault-userdefined")):
        target = backup / name
        shutil.copy2(source, target)
        target.chmod(0o600)
    print("Protected backup:", backup)

    changed = dict(original)
    changed["execution"] = "weekly"
    try:
        call(["omv-confdbadm", "update", MODEL, json.dumps(changed, separators=(",", ":"))])
        call(["omv-salt", "deploy", "run", "cron"])
        updated_entries = jobs()
        final = matching_job(updated_entries)
        if final.get("execution") != "weekly" or not same_except_execution(original, final):
            fail("OMV database verification failed")
        remaining_before = {x["uuid"]: x for x in entries if x["uuid"] != uuid}
        remaining_after = {x["uuid"]: x for x in updated_entries if x["uuid"] != uuid}
        if remaining_before != remaining_after:
            fail("Unrelated OMV job configurations changed")
        cron_line(uuid, "@weekly")
    except Exception as exc:
        print("ERROR: weekly update was not fully verified:", str(exc), file=sys.stderr)
        print("Attempting to restore the original monthly OMV job", file=sys.stderr)
        try:
            call(["omv-confdbadm", "update", MODEL, json.dumps(original, separators=(",", ":"))])
            call(["omv-salt", "deploy", "run", "cron"])
            cron_line(uuid, "@monthly")
            print("Original monthly schedule restored", file=sys.stderr)
        except Exception:
            print("WARNING: automatic rollback failed; inspect the protected backup and OMV job", file=sys.stderr)
        raise

    print("Updated OMV job: @weekly")
    print("OMV generated cron entry verified")
    print("No certificates renewed; no Docker containers restarted")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Apply weekly schedule via OMV configuration database")
    args = parser.parse_args()
    if os.geteuid() != 0:
        fail("Run as root")
    if shutil.which("omv-confdbadm") is None or shutil.which("omv-salt") is None:
        fail("OMV configuration and Salt commands are required")
    if not args.apply:
        entry = matching_job(jobs())
        cron_line(entry["uuid"], "@" + entry["execution"])
        print("OMV task:", entry["uuid"])
        print("Current:", "@" + entry["execution"])
        print("Proposed: @weekly (Sunday 00:00, local server time)")
        print("Other task settings and all Docker services stay unchanged")
        print("Dry run complete. No changes made")
    else:
        apply()


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError, ValueError) as error:
        print("ERROR:", str(error), file=sys.stderr)
        sys.exit(1)