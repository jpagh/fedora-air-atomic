#!/bin/bash
# keyboard-backlight.sh -- make the MacBook's keyboard-backlight keys work in Sway
#
# The F5/F6 keys emit XF86KbdBrightnessDown/Up. The kernel already exposes the
# backlight as the LED /sys/class/leds/smc::kbd_backlight (via applesmc), and
# brightnessctl can write it as your normal user (through logind, so no sudo).
# Fedora's Sway config only binds the *display*-brightness keys, so the
# keyboard-backlight keys are simply unbound -- that is the whole problem.
#
# Usage: ./keyboard-backlight.sh [on|off|status]     (default: on)
set -euo pipefail

DROPIN="$HOME/.config/sway/config.d/80-keyboard-backlight.conf"
DEV=smc::kbd_backlight

say() { printf '\n== %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run this as your normal user, not with sudo"

current() { brightnessctl --class=leds --device="$DEV" --percentage get; }

reload() {
    if [ -n "${SWAYSOCK:-}" ] && command -v swaymsg >/dev/null; then
        swaymsg reload >/dev/null
        echo "Sway config reloaded."
    else
        echo "Not in a Sway session; reload Sway (or log back in) to apply."
    fi
}

case "${1:-on}" in
on)
    mkdir -p "$(dirname "$DROPIN")"
    cat > "$DROPIN" <<'EOF'
# Keyboard backlight keys (F5/F6) on the Apple internal keyboard.
# The keys emit XF86KbdBrightnessDown/Up; Fedora binds only the display
# brightness keys, so these do nothing by default. Backlight is the LED
# /sys/class/leds/smc::kbd_backlight, driven by applesmc.
set $kbd_backlight_notification_cmd  command -v notify-send >/dev/null && \
        VALUE=$(brightnessctl --class=leds --device=smc::kbd_backlight --percentage get) && \
        notify-send -e -h string:x-canonical-private-synchronous:kbd-backlight \
            -h "int:value:$VALUE" -t 800 "Keyboard backlight: ${VALUE}%"

bindsym --locked XF86KbdBrightnessDown exec \
        'brightnessctl --class=leds --device=smc::kbd_backlight -q set 5%- && $kbd_backlight_notification_cmd'
bindsym --locked XF86KbdBrightnessUp exec \
        'brightnessctl --class=leds --device=smc::kbd_backlight -q set +5% && $kbd_backlight_notification_cmd'
EOF
    reload
    # If it is currently off, turn it on so there is something to see.
    if [ "$(current)" = "0" ]; then
        brightnessctl --class=leds --device="$DEV" -q set 30%
    fi
    say "Keyboard backlight keys enabled: F5 = dimmer, F6 = brighter."
    echo "Current brightness: $(current)%"
    echo "Undo with:  $0 off"
    ;;
off)
    rm -f "$DROPIN"
    reload
    say "Keyboard backlight keys disabled (the LED is left as it is)."
    ;;
status)
    if [ -f "$DROPIN" ]; then
        echo "sway drop-in: installed ($DROPIN)"
    else
        echo "sway drop-in: not installed"
    fi
    if brightnessctl --class=leds --device="$DEV" info >/dev/null 2>&1; then
        echo "backlight:    $DEV, currently $(current)% (max 255)"
    else
        echo "backlight:    $DEV not found (is applesmc loaded?)"
    fi
    ;;
*)
    die "usage: $0 [on|off|status]"
    ;;
esac
