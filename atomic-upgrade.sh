#!/bin/bash
# atomic-upgrade.sh -- Fedora Atomic base upgrade with a Broadcom wl check
#
# The wl driver is a layered akmod. rpm-ostree rebuilds it for the new kernel
# as part of the upgrade (verified 2026-10-01 on this machine: the staged
# deployment contained wl.ko.xz for kernel 7.2.8-200.fc44), but that is the one
# step worth verifying before rebooting -- if it ever fails, wifi is gone on
# the new kernel.
#
# This wrapper runs the upgrade, finds the staged deployment, verifies wl was
# built for its kernel, and only then tells you to reboot. A clean reboot is
# required: the staged deployment is finalized (new kernel written into /boot)
# during shutdown.
#
# Run with sudo. Safe to re-run.
set -euo pipefail

say()  { printf '\n== %s\n' "$*"; }
warn() { printf '\n!! %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this with sudo:  sudo $0"
[ -e /run/ostree-booted ] || die "this script is for Fedora Atomic (rpm-ostree) systems"

# Physical root of the staged (next-boot) deployment, or empty.
staged_root() {
    rpm-ostree status --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for dep in d.get("deployments", []):
    if dep.get("staged") and not dep.get("booted"):
        print("/ostree/deploy/%s/deploy/%s.0" % (dep.get("osname", "fedora"), dep.get("checksum", "")))
        break
' 2>/dev/null
}

# Prints the path of the wl module inside the staged deployment, if present.
staged_wl_module() {
    local root kver
    root=$(staged_root)
    [ -n "$root" ] && [ -d "$root/usr/lib/modules" ] || return 1
    for kver in "$root"/usr/lib/modules/*; do
        [ -d "$kver" ] || continue
        if [ -f "$kver/extra/wl/wl.ko.xz" ]; then
            echo "$kver/extra/wl/wl.ko.xz"; return 0
        elif [ -f "$kver/extra/wl/wl.ko" ]; then
            echo "$kver/extra/wl/wl.ko"; return 0
        fi
    done
    return 1
}

say "Upgrading the base image (rpm-ostree upgrade)"
if ! rpm-ostree upgrade; then
    warn "upgrade failed -- clearing cached repo metadata and retrying once"
    rpm-ostree cleanup -m
    rpm-ostree upgrade || die "upgrade failed again; nothing further was changed"
fi

root=$(staged_root)
if [ -z "$root" ]; then
    say "No staged deployment -- the system is already up to date."
    echo "Nothing to do."
    exit 0
fi

say "Staged deployment prepared:"
rpm-ostree status | head -18

if module=$(staged_wl_module); then
    # Tell atomic-wifi.sh this staged deployment was prepared on purpose, so it
    # is not mistaken for one that survived a reboot without booting.
    touch /run/atomic-wifi-pending-created
    echo
    echo "wl is built for the new kernel:"
    echo "  $module"
    echo
    echo "Reboot normally now (a clean shutdown finalizes the deployment):"
    echo "  sudo reboot"
else
    warn "The staged deployment does NOT contain wl -- rebooting would lose wifi."
    echo
    echo "Recovery: reboot and pick the previous deployment in GRUB, or try forcing"
    echo "a rebuild with:"
    echo "  sudo rpm-ostree uninstall akmod-wl broadcom-wl"
    echo "  sudo rpm-ostree install akmod-wl broadcom-wl"
    echo "then re-run this script to re-check before rebooting."
    exit 1
fi
