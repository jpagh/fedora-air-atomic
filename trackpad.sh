#!/bin/bash
# trackpad.sh -- Sway trackpad preferences for the MacBook's bcm5974
#
# Fedora's default has tap-to-click OFF, tap-and-drag ON, and
# click_method=clickfinger (a two-finger *press* is a right click).
#
# This script turns on tap-to-click, keeps two-finger *tap* = right click,
# turns tap-and-drag OFF, and switches the click method to button_areas so a
# hard press in the bottom-right corner is a right click.
#
# Caveat: libinput can do either clickfinger OR button_areas, never both.
# With button_areas a two-finger *press* is no longer a right click (a
# two-finger *tap* still is, via tap_button_map). If you would rather have
# two-finger press, set click_method to clickfinger below.
#
# Usage: ./trackpad.sh [on|off|status]     (default: on)
set -euo pipefail

DROPIN="$HOME/.config/sway/config.d/70-touchpad.conf"

say() { printf '\n== %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run this as your normal user, not with sudo"

reload() {
    if [ -n "${SWAYSOCK:-}" ] && command -v swaymsg >/dev/null; then
        swaymsg reload >/dev/null
        echo "Sway config reloaded."
    else
        echo "Not in a Sway session; reload Sway (or log back in) to apply."
    fi
}

show_state() {
    swaymsg -t get_inputs 2>/dev/null | python3 -c '
import sys, json
for d in json.load(sys.stdin):
    if "Touchpad" in d.get("name", "") or "bcm5974" in d.get("name", ""):
        print("device:", d.get("name"))
        for k in ("tap", "tap_button_map", "tap_drag", "click_method"):
            v = d.get("libinput", {}).get(k)
            if v is not None:
                print("  %-16s %s" % (k, v))
'
}

case "${1:-on}" in
on)
    mkdir -p "$(dirname "$DROPIN")"
    cat > "$DROPIN" <<'EOF'
# Trackpad: tap-to-click on, two-finger tap = right click, tap-and-drag off,
# bottom-right hard press = right click.
# libinput can do clickfinger OR button_areas, not both; this uses button_areas.
input "type:touchpad" {
    tap enabled
    tap_button_map lrm
    drag disabled
    click_method button_areas
}
EOF
    reload
    say "Trackpad settings applied:"
    show_state
    echo
    echo "Undo with:  $0 off"
    ;;
off)
    rm -f "$DROPIN"
    reload
    say "Trackpad drop-in removed; Fedora's defaults apply after the reload."
    ;;
status)
    if [ -f "$DROPIN" ]; then
        echo "drop-in: installed ($DROPIN)"
    else
        echo "drop-in: not installed"
    fi
    show_state
    ;;
*)
    die "usage: $0 [on|off|status]"
    ;;
esac
