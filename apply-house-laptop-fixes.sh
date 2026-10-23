#!/bin/bash
# apply-house-laptop-fixes.sh -- apply the pending root-only fixes in one go.
#
#   1. Remove the old lock-screen numeric PIN from PAM (password-only lock).
#   2. Arm only the keyboard/trackpad USB root hub; keep the USB 3 card reader
#      from waking the machine immediately after lid-close suspend.
#   3. Boot straight into the Sway session via SDDM autologin.
#
# Run as your normal user; the script re-execs itself with sudo.
#
# Autologin takes effect on the next boot (or the next time SDDM starts).  The
# script deliberately does not restart SDDM, because that would kill the
# currently running graphical session.
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TARGET_USER=${SUDO_USER:-jack}
SESSION=sway.desktop

if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$(readlink -f "$0")" "$@"
fi

TARGET_USER=${SUDO_USER:-$TARGET_USER}
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
[ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME" ] || {
    echo "ERROR: cannot find home directory for user '$TARGET_USER'" >&2
    exit 1
}
[ -f "/usr/share/wayland-sessions/$SESSION" ] || {
    echo "ERROR: SDDM session file /usr/share/wayland-sessions/$SESSION not found" >&2
    exit 1
}

say() { printf '\n== %s\n' "$*"; }

say "Removing the old lock-screen PIN"
SUDO_USER="$TARGET_USER" "$REPO/lock-pin.sh" clear

say "Fixing USB wake (keyboard only; card reader disarmed)"
"$REPO/usb-wakeup.sh" on

say "Enabling SDDM autologin for $TARGET_USER"
install -d -m 0755 /etc/sddm.conf.d
cat > /etc/sddm.conf.d/50-autologin.conf <<EOF
# House laptop: boot straight into the Sway session.
# Relogin=false keeps the greeter reachable after an explicit logout.
[Autologin]
User=$TARGET_USER
Session=$SESSION
Relogin=false
EOF
chmod 0644 /etc/sddm.conf.d/50-autologin.conf
restorecon -F /etc/sddm.conf.d/50-autologin.conf 2>/dev/null || true

say "Verification"
if grep -Rqs 'lock-pin-check' /etc/pam.d; then
    echo "PIN PAM:    still present (unexpected)"
else
    echo "PIN PAM:    removed"
fi
echo "usb1 wake:  $(cat /sys/bus/usb/devices/usb1/power/wakeup 2>/dev/null || echo '?')"
echo "usb2 wake:  $(cat /sys/bus/usb/devices/usb2/power/wakeup 2>/dev/null || echo '?')"
echo "autologin:  $(grep -E '^(User|Session|Relogin)=' /etc/sddm.conf.d/50-autologin.conf | paste -sd' ' -)"

echo
echo "Autologin will take effect on the next reboot.  SDDM was not restarted,"
echo "so the current session is untouched."
