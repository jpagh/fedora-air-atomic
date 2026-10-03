#!/bin/bash
# swap-caps-tilde.sh -- swap the Caps Lock and `/~ keys on the MacBook's
# internal keyboard
#
# Unlike the Fn/Ctrl swap, the kernel's hid_apple driver has no option for
# this (its parameters are only fnmode, iso_layout, swap_ctrl_cmd,
# swap_fn_leftctrl, swap_opt_cmd). Instead we remap the two scancodes in
# udev's hwdb. That happens at the evdev level, below the compositor, so it
# applies everywhere: Sway, the lock screen, SDDM and the text consoles.
#
# The internal keyboard is a USB HID device (Apple 05ac:0291). Its scancodes
# are the HID usages on page 0x07: 0x39 = Caps Lock, 0x35 = grave/tilde.
#
# Usage: sudo ./swap-caps-tilde.sh [on|off|status]     (default: on)
set -euo pipefail

HWDB=/etc/udev/hwdb.d/90-swap-caps-tilde.hwdb
MODEL_ID=Apple_Internal_Keyboard___Trackpad   # udev ID_MODEL for 05ac:0291

say() { printf '\n== %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this with sudo:  sudo $0"

# Find the internal keyboard's event node (its number can change across boots).
find_event() {
    local ev name
    for ev in /dev/input/event*; do
        [ -e "$ev" ] || continue
        name=$(udevadm info -q property -n "$ev" 2>/dev/null \
               | sed -n 's/^ID_MODEL=//p' | head -1)
        if [ "$name" = "$MODEL_ID" ]; then
            printf '%s\n' "$ev"
            return 0
        fi
    done
    return 1
}

# Re-run the input rules so a change takes effect without rebooting.
reload() {
    local ev
    if ev=$(find_event); then
        udevadm trigger "$ev"
    else
        udevadm trigger --subsystem-match=input
    fi
}

install_rule() {
    cat > "$HWDB" <<'EOF'
# Swap Caps Lock and `/~ on the Apple internal keyboard (e.g. MacBookAir7,2).
# HID usages on page 0x07: 0x39 Caps Lock, 0x35 grave/tilde.
evdev:input:b0003v05ACp0291*
 KEYBOARD_KEY_70039=grave
 KEYBOARD_KEY_70035=capslock
EOF
    restorecon -F "$HWDB" 2>/dev/null || true
    systemd-hwdb update
    reload
}

remove_rule() {
    # The keyboard builtin only ever applies mappings, it never resets them,
    # so restore the defaults explicitly for this run, then drop the rule so
    # future boots start from the hardware defaults.
    cat > "$HWDB" <<'EOF'
evdev:input:b0003v05ACp0291*
 KEYBOARD_KEY_70039=capslock
 KEYBOARD_KEY_70035=grave
EOF
    restorecon -F "$HWDB" 2>/dev/null || true
    systemd-hwdb update
    reload
    rm -f "$HWDB"
    systemd-hwdb update
}

case "${1:-on}" in
on)
    install_rule
    say "Caps Lock and \`/~ are swapped (now, and again at every boot)."
    echo "The Caps Lock key now types \` and ~; the \`/~ key now locks Caps."
    echo "Test it with:  wev     (press the Caps Lock key, expect grave)"
    echo "Undo with:     sudo $0 off"
    ;;
off)
    remove_rule
    say "Swap disabled: Caps Lock and \`/~ are back to normal."
    ;;
status)
    if [ -f "$HWDB" ]; then
        echo "hwdb rule: installed ($HWDB)"
        grep -E '^ *KEYBOARD_KEY' "$HWDB" | sed 's/^/  /'
    else
        echo "hwdb rule: not installed"
    fi
    if ev=$(find_event); then
        echo "keyboard:  $ev"
    else
        echo "keyboard:  not found (is the internal keyboard present?)"
    fi
    ;;
*)
    die "usage: sudo $0 [on|off|status]"
    ;;
esac
