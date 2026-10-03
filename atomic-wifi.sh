#!/bin/bash
# atomic-wifi.sh -- get the Broadcom BCM4360 (wl) wifi working on Fedora Atomic
#
# Companion to atomic-playbook.md, for Fedora Atomic (rpm-ostree) systems.
#
# Differences from the original fedora-air runbook's Workstation instructions:
#   - packages are layered with `rpm-ostree install`, not dnf
#   - akmod-wl builds wl inside the new deployment via akmods-ostree-post
#     (the same mechanism RPMFusion uses for akmod-nvidia on Silverblue)
#   - /usr is read-only on Atomic, so the sleep hook goes to
#     /etc/systemd/system-sleep/ (systemd reads hooks from both places)
#
# No base upgrade is needed: `rpm-ostree install --dry-run akmod-wl
# broadcom-wl` resolves kernel-devel-matched for the *running* kernel
# (6.19.10-300.fc44) from the fedora repo. The base can be upgraded later;
# after a kernel change, check `modinfo wl` and re-run this script if needed.
#
# Run with sudo. Idempotent: after each reboot run it again; it detects its
# stage and tells you what to do next.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODEL_EXPECTED=MacBookAir7,2
RF_BASE=https://download1.rpmfusion.org
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say()  { printf '\n== %s\n' "$*"; }
warn() { printf '\n!! %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this with sudo:  sudo $0"
[ -e /run/ostree-booted ] || die "this script is for Fedora Atomic (rpm-ostree) systems"

model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
[ "$model" = "$MODEL_EXPECTED" ] || warn "model is '$model', not '$MODEL_EXPECTED'; continuing anyway"

need_net() {
    curl -sfI --max-time 20 "$RF_BASE/" >/dev/null 2>&1 \
        || die "no internet; plug in the USB ethernet adapter first"
}

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

# Prints the path of the built wl module inside the pending deployment, if any.
pending_module_path() {
    local root kver
    root=$(pending_deploy_root)
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

install_rpmfusion_repos() {
    if [ -f /etc/yum.repos.d/rpmfusion-free.repo ] \
    && [ -f /etc/yum.repos.d/rpmfusion-nonfree.repo ]; then
        say "RPMFusion repos already configured"
        return 0
    fi
    need_net
    local rel
    rel=$(rpm -E %fedora)
    say "Fetching RPMFusion release packages (free + nonfree) for Fedora $rel"
    curl -sfL --max-time 120 -o "$TMP/free.rpm" \
        "$RF_BASE/free/fedora/rpmfusion-free-release-$rel.noarch.rpm"
    curl -sfL --max-time 120 -o "$TMP/nonfree.rpm" \
        "$RF_BASE/nonfree/fedora/rpmfusion-nonfree-release-$rel.noarch.rpm"
    ( cd "$TMP" && rpm2cpio free.rpm | cpio -idm --quiet \
                  && rpm2cpio nonfree.rpm | cpio -idm --quiet )
    install -m 644 "$TMP"/etc/yum.repos.d/*.repo /etc/yum.repos.d/
    install -m 644 "$TMP"/etc/pki/rpm-gpg/RPM-GPG-KEY-rpmfusion-* /etc/pki/rpm-gpg/
    restorecon -F /etc/yum.repos.d /etc/pki/rpm-gpg 2>/dev/null || true
    say "RPMFusion repos installed"
}

install_local_files() {
    say "Installing local wl workarounds (Atomic-friendly paths)"
    install -D -m 644 "$REPO/etc/NetworkManager/conf.d/91-wl-no-pmf.conf" \
        /etc/NetworkManager/conf.d/91-wl-no-pmf.conf
    install -D -m 755 "$REPO/usr/local/sbin/wl-fix-wifi-profiles" \
        /usr/local/sbin/wl-fix-wifi-profiles
    install -D -m 644 "$REPO/etc/systemd/system/wl-fix-wifi-profiles.path" \
        /etc/systemd/system/wl-fix-wifi-profiles.path
    install -D -m 644 "$REPO/etc/systemd/system/wl-fix-wifi-profiles.service" \
        /etc/systemd/system/wl-fix-wifi-profiles.service
    # Sleep hook: /usr is read-only, so use the /etc copy systemd also reads.
    install -D -m 755 "$REPO/usr/lib/systemd/system-sleep/wl-reload" \
        /etc/systemd/system-sleep/wl-reload

    # Hooks under /usr/lib are labelled bin_t; /etc/systemd/system-sleep has no
    # file_contexts entry, so add one, otherwise SELinux may refuse to run it.
    if ! semanage fcontext -l 2>/dev/null | grep -q 'system-sleep'; then
        semanage fcontext -a -t bin_t '/etc/systemd/system-sleep(/.*)?'
    fi
    restorecon -F /etc/systemd/system-sleep/wl-reload \
        /usr/local/sbin/wl-fix-wifi-profiles \
        /etc/systemd/system/wl-fix-wifi-profiles.path \
        /etc/systemd/system/wl-fix-wifi-profiles.service \
        /etc/NetworkManager/conf.d/91-wl-no-pmf.conf 2>/dev/null || true

    # Belt and braces: load wl at boot even if udev does not autoload it.
    printf 'wl\n' > /etc/modules-load.d/wl.conf

    systemctl daemon-reload
    systemctl enable --now wl-fix-wifi-profiles.path
    say "Local workarounds installed"
}

verify_and_connect() {
    say "wl module present:"
    modinfo wl | grep -E '^(filename|license)' || true

    if ! lsmod | grep -q '^wl '; then
        say "Loading wl"
        modprobe wl || die "modprobe wl failed; run: journalctl -b | grep -iE 'akmod|wl' | tail -50"
    fi

    for _ in $(seq 1 50); do
        nmcli -t -f DEVICE,TYPE,STATE device | grep -q '^wlp3s0:wifi' && break
        sleep 0.2
    done

    say "Network devices:"
    nmcli -t -f DEVICE,TYPE,STATE device

    if ! nmcli -t -f DEVICE,TYPE,STATE device | grep -q '^wlp3s0:wifi'; then
        warn "wlp3s0 did not appear."
        echo "Diagnostics to try:"
        echo "  rfkill list wifi"
        echo "  ls /usr/lib/modules/\$(uname -r)/extra/wl/ 2>&1"
        echo "  journalctl -b | grep -iE 'wl|b43|brcm' | tail -40"
        exit 1
    fi

    say "Wifi networks visible:"
    nmcli -f SSID,SIGNAL,SECURITY device wifi list || true

    if nmcli -t -f DEVICE,STATE,CONNECTION device | grep -q '^wlp3s0:connected'; then
        say "wlp3s0 is already connected."
        return 0
    fi

    if [ ! -t 0 ]; then
        echo
        echo "Not running on a terminal. To connect, run:"
        echo "  nmcli device wifi connect '<SSID>' --ask"
        return 0
    fi

    local ssid
    read -rp $'\nSSID to connect to: ' ssid || true
    [ -n "${ssid:-}" ] || die "no SSID given"

    if nmcli -g NAME connection show | grep -qxF "$ssid"; then
        nmcli --ask connection up id "$ssid"
    else
        # The runbook's recipe: wl cannot do SAE or PMF, so create WPA2-PSK
        # with PMF disabled instead of letting NetworkManager pick SAE.
        nmcli connection add type wifi con-name "$ssid" ssid "$ssid" \
            wifi-sec.key-mgmt wpa-psk wifi-sec.pmf disable
        nmcli --ask connection up id "$ssid" \
            || warn "connection failed. If this SSID is WPA3-only, wl cannot use it (runbook section 3)."
    fi

    say "Result:"
    nmcli -t -f DEVICE,STATE,CONNECTION device
    ip -4 addr show wlp3s0 2>/dev/null || true
}

# ---------------------------------------------------------------- main

install_rpmfusion_repos

if modinfo wl >/dev/null 2>&1; then
    verify_and_connect
    exit 0
fi

# Is there already a prepared deployment that contains wl? (Gate on the
# module itself rather than rpm-ostree's pending-deployment exit code, which
# proved unreliable while the daemon was cold-starting.)
if module=$(pending_module_path); then
    # /run is tmpfs, so this marker only survives within one boot. If a
    # deployment with wl is pending but the marker is missing, a reboot failed
    # to boot it -- do not loop on rebooting.
    if [ ! -f /run/atomic-wifi-pending-created ]; then
        warn "A deployment with wl is pending but was not prepared during this boot."
        echo "Either a reboot did not boot it, or it is left over from an earlier attempt."
        echo "Do not keep rebooting. Collect these and get help:"
        echo "  rpm-ostree status"
        echo "  ls /boot/loader/entries/"
        echo "  sudo bootupctl status"
        exit 1
    fi
    install_local_files
    say "A deployment with wl is already prepared:"
    rpm-ostree status
    echo
    echo "wl was built into it:"
    echo "  $module"
    echo "Reboot now, then run this script again:  sudo $0"
    exit 0
fi

say "Layering akmod-wl + broadcom-wl from RPMFusion"
echo "This installs ~140 packages (gcc, kernel-devel for the running kernel) and"
echo "compiles wl inside the new deployment. It takes a few minutes."
rpm-ostree install --idempotent akmod-wl broadcom-wl

install_local_files

if module=$(pending_module_path); then
    touch /run/atomic-wifi-pending-created
    say "New deployment prepared:"
    rpm-ostree status
    echo
    echo "wl was built into it:"
    echo "  $module"
    echo
    echo "Reboot now, then run this script again to check and connect:  sudo $0"
else
    warn "No pending deployment contains wl -- the akmod build likely failed."
    echo "Inspect the build:  journalctl -b | grep -i akmod | tail -50"
    exit 1
fi
