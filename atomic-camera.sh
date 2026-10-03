#!/bin/bash
# atomic-camera.sh -- get the FaceTime HD camera working on Fedora Atomic
#
# Companion to atomic-playbook.md, for Fedora Atomic (rpm-ostree) systems.
#
# The camera needs an out-of-tree driver (patjak/facetimehd) plus firmware
# extracted from Apple's own macOS driver. On Atomic neither can be installed
# the runbook's way:
#   - DKMS cannot work: /usr is read-only and dkms is not installed. Instead we
#     layer an *akmod*, which akmods-ostree-post rebuilds for every new kernel,
#     exactly like akmod-wl.
#   - The akmod comes from the COPR mulderje/facetimehd-kmod, BUT its source
#     (upstream tag 0.7.0.1) does not compile on kernel >= 7.2: fthd_v4l2.c
#     calls strncpy() without including <string.h>, which is a hard error on
#     GCC 14+. The copy in atomic-camera/ is that same tag rebuilt with
#     upstream's own fix (guard the call with #if LINUX_VERSION_CODE < 4.2.0).
#   - /usr is read-only, so the sleep hook goes to /etc/systemd/system-sleep/
#     (systemd reads hooks from both places), labelled bin_t.
#
# Run with sudo. Idempotent: it stages the install, tells you to reboot, and
# on the next run verifies the result.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RPMDIR="$REPO/atomic-camera"
MODEL_EXPECTED=MacBookAir7,2

say()  { printf '\n== %s\n' "$*"; }
warn() { printf '\n!! %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this with sudo:  sudo $0"
[ -e /run/ostree-booted ] || die "this script is for Fedora Atomic (rpm-ostree) systems"

model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
[ "$model" = "$MODEL_EXPECTED" ] || warn "model is '$model', not '$MODEL_EXPECTED'; continuing anyway"

# Physical root of the first non-booted deployment, or empty.
pending_deploy_root() {
    rpm-ostree status --json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for dep in d.get("deployments", []):
    if dep.get("staged"):
        print("/ostree/deploy/%s/deploy/%s.0" % (dep.get("osname", "fedora"), dep.get("checksum", "")))
        break
' 2>/dev/null
}

# Prints the path of the built facetimehd module inside the pending deployment.
pending_module_path() {
    local root kver
    root=$(pending_deploy_root)
    [ -n "$root" ] && [ -d "$root/usr/lib/modules" ] || return 1
    for kver in "$root"/usr/lib/modules/*; do
        [ -d "$kver" ] || continue
        if [ -f "$kver/extra/facetimehd/facetimehd.ko.xz" ]; then
            echo "$kver/extra/facetimehd/facetimehd.ko.xz"; return 0
        elif [ -f "$kver/extra/facetimehd/facetimehd.ko" ]; then
            echo "$kver/extra/facetimehd/facetimehd.ko"; return 0
        fi
    done
    return 1
}

install_sleep_hook() {
    # The driver redoes a full hardware bring-up on every resume and is the
    # prime suspect for the 2026-09-17 resume hang; upstream ships this same
    # unload/reload workaround. /usr is read-only, so use /etc, and label it
    # bin_t (as atomic-wifi.sh does for wl-reload) or SELinux will refuse it.
    install -D -m 755 "$REPO/usr/lib/systemd/system-sleep/facetimehd-reload" \
        /etc/systemd/system-sleep/facetimehd-reload
    if ! semanage fcontext -l 2>/dev/null | grep -q 'system-sleep'; then
        semanage fcontext -a -t bin_t '/etc/systemd/system-sleep(/.*)?'
    fi
    restorecon -F /etc/systemd/system-sleep/facetimehd-reload 2>/dev/null || true
}

verify() {
    say "facetimehd module:"
    modinfo facetimehd 2>/dev/null | grep -E '^(filename|firmware|license)' || true

    if ! lsmod | grep -q '^facetimehd '; then
        say "Loading facetimehd"
        modprobe facetimehd || {
            warn "modprobe facetimehd failed."
            echo "  journalctl -k -b | grep -i facetimehd | tail -30"
            echo "  ls /usr/lib/modules/\$(uname -r)/extra/facetimehd/ 2>&1"
            exit 1
        }
    fi

    say "Device node:"
    if [ -e /dev/video0 ]; then
        ls -l /dev/video0
    else
        warn "/dev/video0 did not appear."
        echo "  journalctl -k -b | grep -i facetimehd | tail -30"
        exit 1
    fi

    say "Bring-up log:"
    journalctl -k -b --no-pager 2>/dev/null | grep -i facetimehd | tail -12 || true

    if command -v v4l2-ctl >/dev/null; then
        say "v4l2 devices:"
        v4l2-ctl --list-devices 2>/dev/null || true
    else
        echo
        echo "For an end-to-end test, install v4l-utils and run:"
        echo "  sudo rpm-ostree install v4l-utils   # then reboot"
        echo "  v4l2-ctl --list-devices"
    fi
}

# ---------------------------------------------------------------- main

if modinfo facetimehd >/dev/null 2>&1; then
    verify
    exit 0
fi

for f in "$RPMDIR"/akmod-facetimehd-*.rpm "$RPMDIR"/facetimehd-firmware-*.rpm "$RPMDIR"/facetimehd-[0-9]*.rpm; do
    [ -e "$f" ] || die "missing package: $f"
done

# Already staged but not booted? (module built into the pending deployment)
if module=$(pending_module_path); then
    install_sleep_hook
    say "A deployment with facetimehd is already prepared:"
    rpm-ostree status
    echo
    echo "facetimehd was built into it:"
    echo "  $module"
    echo "Reboot now, then run this script again:  sudo $0"
    exit 0
fi

say "Layering akmod-facetimehd + firmware (built from the COPR, with the"
echo "kernel >= 7.2 build fix) and the facetimehd meta package."
rpm-ostree install --idempotent \
    "$RPMDIR"/akmod-facetimehd-*.rpm \
    "$RPMDIR"/facetimehd-firmware-*.rpm \
    "$RPMDIR"/facetimehd-[0-9]*.rpm

install_sleep_hook

if module=$(pending_module_path); then
    say "New deployment prepared:"
    rpm-ostree status
    echo
    echo "facetimehd was built into it:"
    echo "  $module"
else
    say "New deployment prepared:"
    rpm-ostree status
    echo
    warn "facetimehd.ko is not in the pending deployment yet."
    echo "The akmod build normally runs during this install; if it only runs at"
    echo "shutdown, this is harmless -- reboot and run this script again."
fi
echo
echo "Reboot now, then run this script again to verify:  sudo $0"
