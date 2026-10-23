#!/bin/bash
# usb-wakeup.sh -- let the internal keyboard/trackpad wake the machine from S3
#
# On this MacBookAir7,2 the only thing that wakes the system out of S3 (deep)
# is the lid switch (ACPI LID0).  A keypress does not, even though the firmware
# leaves the xHCI controller (ACPI XHC1) armed: the two USB root hubs come up
# with power/wakeup=disabled, so with the lid shut -- or when a suspend race has
# left logind's idea of the lid stale -- there is no way back from sleep except
# the power button.
#
# Arming the USB 2.0 root hub (usb1) and the internal HID device itself gives
# the keyboard and trackpad a wake path.  The state has to be re-applied on
# every boot, so it lives in a udev rule rather than a one-shot write to
# /proc/acpi/wakeup.
#
# Scope: this arms wake sources only.  The USB 3.0 root hub (usb2) is left
# disarmed because its card reader started waking the machine immediately after
# lid-close suspend on kernel 7.2.11 ("usb usb2-port3: unable to enumerate USB
# device").  Bluetooth is also left disabled.
#
# Usage: sudo ./usb-wakeup.sh [on|off|status]     (default: on)
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RULE=/etc/udev/rules.d/90-usb-wakeup.rules
KEYBOARD=05ac:0291    # Apple Internal Keyboard / Trackpad

say() { printf '\n== %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this with sudo:  sudo $0"

install_rule() {
    install -D -m 644 "$REPO/etc/udev/rules.d/90-usb-wakeup.rules" "$RULE"
    restorecon -F "$RULE" 2>/dev/null || true
    udevadm control --reload
    # Re-run the rule against what is already plugged in, so it applies without
    # a reboot.
    udevadm trigger --subsystem-match=usb --action=change
    udevadm settle --timeout=5 2>/dev/null || true
    # Belt and braces: make the runtime state match even if the trigger raced
    # the hub's own add/change event.  usb1 carries the keyboard/trackpad;
    # usb2 carries the card reader that must not wake the machine.
    [ -e /sys/bus/usb/devices/usb1/power/wakeup ] && \
        echo enabled > /sys/bus/usb/devices/usb1/power/wakeup 2>/dev/null || true
    [ -e /sys/bus/usb/devices/usb2/power/wakeup ] && \
        echo disabled > /sys/bus/usb/devices/usb2/power/wakeup 2>/dev/null || true
    sleep 0.5
}

remove_rule() {
    rm -f "$RULE"
    udevadm control --reload
    # Put the runtime state back: the hubs are what we turned on, so turn them
    # back off.  The keyboard device is left as the kernel found it.
    local h
    for h in /sys/bus/usb/devices/usb[0-9]*; do
        [ -e "$h/power/wakeup" ] || continue
        echo disabled > "$h/power/wakeup" 2>/dev/null || true
    done
}

keyboard_dev() {
    local dev v p
    for dev in /sys/bus/usb/devices/*/; do
        v=$(cat "$dev/idVendor" 2>/dev/null || true)
        p=$(cat "$dev/idProduct" 2>/dev/null || true)
        if [ "$v:$p" = "$KEYBOARD" ]; then
            printf '%s' "$dev"
            return 0
        fi
    done
    return 1
}

status() {
    local h dev
    if [ -f "$RULE" ]; then
        echo "udev rule:  installed ($RULE)"
    else
        echo "udev rule:  not installed"
    fi
    echo "ACPI XHC1:  $(awk '$1=="XHC1"{print $3}' /proc/acpi/wakeup 2>/dev/null)"
    for h in /sys/bus/usb/devices/usb[0-9]*; do
        [ -e "$h/power/wakeup" ] || continue
        printf 'roothub:    %-5s wakeup=%s\n' "$(basename "$h")" "$(cat "$h/power/wakeup")"
    done
    if dev=$(keyboard_dev); then
        printf 'keyboard:   %-5s wakeup=%s (has woken the machine %s times)\n' \
            "$(basename "$dev")" "$(cat "$dev/power/wakeup")" \
            "$(cat "$dev/power/wakeup_count" 2>/dev/null || echo '?')"
    else
        echo "keyboard:   not found"
    fi
}

case "${1:-on}" in
on)
    install_rule
    say "USB wake armed: the keyboard and trackpad can now wake the system from S3."
    status
    echo
    echo "Test it:  systemctl suspend, then tap a key (the lid can stay closed)."
    echo "Undo with:  sudo $0 off"
    ;;
off)
    remove_rule
    say "USB wake disarmed: only the lid switch wakes the system again."
    ;;
status)
    status
    ;;
*)
    die "usage: sudo $0 [on|off|status]"
    ;;
esac
