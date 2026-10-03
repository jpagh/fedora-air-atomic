#!/bin/bash
# swap-fn-ctrl.sh -- swap Fn and left Control on the MacBook's internal keyboard
#
# The kernel's hid_apple driver has a swap_fn_leftctrl option that swaps the
# Fn key and the left Control key (KEY_FN <-> KEY_LEFTCTRL). It is evaluated
# on every key event, so it can be applied live through sysfs.
#
# On Fedora Atomic, hid_apple is loaded from the initramfs (verified: the
# keyboard registers ~2.6s in, before switch-root), so a modprobe.d option in
# the real /etc is never seen at boot. A tiny systemd service re-applies the
# setting on every boot instead.
#
# Usage: sudo ./swap-fn-ctrl.sh [on|off|status]     (default: on)
set -euo pipefail

UNIT=hid-apple-swap-fn-ctrl.service
UNIT_PATH=/etc/systemd/system/$UNIT
SYSFS=/sys/module/hid_apple/parameters/swap_fn_leftctrl

say() { printf '\n== %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this with sudo:  sudo $0"

write_param() {
    [ -e "$SYSFS" ] || die "hid_apple is not loaded (no $SYSFS)"
    echo "$1" > "$SYSFS"
}

install_unit() {
    cat > "$UNIT_PATH" <<'EOF'
[Unit]
Description=Swap Fn and left Control keys (Apple internal keyboard)

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo 1 > /sys/module/hid_apple/parameters/swap_fn_leftctrl'

[Install]
WantedBy=multi-user.target
EOF
    restorecon -F "$UNIT_PATH" 2>/dev/null || true
    systemctl daemon-reload
    systemctl enable --now "$UNIT"
}

remove_unit() {
    systemctl disable --now "$UNIT" 2>/dev/null || true
    rm -f "$UNIT_PATH"
    systemctl daemon-reload
}

case "${1:-on}" in
on)
    write_param 1
    install_unit
    say "Fn and left Ctrl are swapped (now, and again at every boot)."
    echo "The leftmost key now acts as Control; the Ctrl key acts as Fn."
    echo "Test it with:  wev     (press the leftmost key, expect Control_L)"
    echo "Undo with:     sudo $0 off"
    ;;
off)
    write_param 0
    remove_unit
    say "Swap disabled and removed from boot."
    ;;
status)
    if [ -e "$SYSFS" ]; then
        echo "swap_fn_leftctrl = $(cat "$SYSFS")  (1 = swapped, 0 = Mac layout)"
    else
        echo "hid_apple not loaded; no $SYSFS"
    fi
    if systemctl is-enabled "$UNIT" >/dev/null 2>&1; then
        echo "boot service: enabled"
    else
        echo "boot service: not installed"
    fi
    ;;
*)
    die "usage: sudo $0 [on|off|status]"
    ;;
esac
