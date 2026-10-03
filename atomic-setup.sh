#!/bin/bash
# atomic-setup.sh -- guided setup for Fedora Atomic on a MacBookAir7,2
#
# Run this as your NORMAL USER, not with sudo. It asks for your preferences
# once, then calls sudo only where it needs root. It is safe to stop and
# re-run at any point: it inspects the machine and does whatever is still
# missing, including resuming across the reboot that the wifi and camera
# drivers need.
#
# Only the wifi and camera steps are REQUIRED to make this hardware work on
# Atomic. Everything else is a personal preference and is asked for, not
# assumed -- answer no to any of it and nothing changes.
#
# It is the conductor. The per-feature work lives in the scripts beside it,
# which you can also run on their own:
#
#   atomic-wifi.sh         Broadcom wl wifi: layer akmod-wl + 3 workarounds
#   atomic-camera.sh       FaceTime HD camera: local akmod + firmware + hook
#   swap-fn-ctrl.sh        Fn <-> left Ctrl (hid_apple, live)
#   swap-caps-tilde.sh     Caps Lock <-> `/~ (udev hwdb; personal taste)
#   keyboard-backlight.sh  F5/F6 keyboard backlight (Sway)
#   trackpad.sh            tap-to-click / corner right-click (Sway)
#   lock-screen-setup.sh   swaylock (ring) or gtklock (login-style) (Sway)
#   lock-pin.sh            numeric PIN for the lock screen (PAM)
#
# See atomic-playbook.md for why each piece exists and how to undo it.
#
# Usage: ./atomic-setup.sh [--help|--reset]
#   --reset   forget the saved preferences and ask again
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
MODEL_EXPECTED=MacBookAir7,2
STATE_DIR="$HOME/.config/atomic-setup"
STATE_FILE="$STATE_DIR/choices"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
step() { printf '\n\033[1m-- %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '\n!! %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
--help|-h) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
--reset)   rm -f "$STATE_FILE"; echo "Preferences cleared."; exit 0 ;;
esac
[ $# -eq 0 ] || die "usage: $0 [--help|--reset]"

[ "$(id -u)" -ne 0 ] || die "run me as your normal user, not with sudo (I call sudo when needed)"

# ---------------------------------------------------------------- state probes

wifi_ok()      { modinfo wl         >/dev/null 2>&1; }
camera_ok()    { modinfo facetimehd >/dev/null 2>&1; }
gtklock_ok()   { command -v gtklock >/dev/null 2>&1; }
fnctrl_ok()    { systemctl is-enabled hid-apple-swap-fn-ctrl.service >/dev/null 2>&1; }
capstilde_ok() { [ -f /etc/udev/hwdb.d/90-swap-caps-tilde.hwdb ]; }
kbdback_ok()   { [ -f "$HOME/.config/sway/config.d/80-keyboard-backlight.conf" ]; }
trackpad_ok()  { [ -f "$HOME/.config/sway/config.d/70-touchpad.conf" ]; }
pin_ok()       { [ -f "$HOME/.config/lock-pin" ]; }
lock_mode() {
    if [ -f "$HOME/.config/gtklock/config.ini" ]; then echo gtklock
    elif [ -f "$HOME/.local/bin/lock-screen" ]; then echo blur
    else echo none; fi
}
in_sway()      { [ -n "${SWAYSOCK:-}" ] && command -v swaymsg >/dev/null 2>&1; }

has_pending() {
    rpm-ostree status --json 2>/dev/null | python3 -c '
import json, sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if any(x.get("staged") for x in d.get("deployments", [])) else 1)
'
}

ask_yn() {  # ask_yn "question" [y|n]   -> returns 0 for yes
    local q=$1 def=${2:-n} ans
    if [ "$def" = y ]; then read -rp "$q [Y/n] " ans || true; ans=${ans:-y}
    else                    read -rp "$q [y/N] " ans || true; ans=${ans:-n}; fi
    case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------- preflight

say "Fedora Atomic setup for a MacBookAir7,2"
[ -e /run/ostree-booted ] || die "this is not Fedora Atomic (no /run/ostree-booted)"
model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
[ "$model" = "$MODEL_EXPECTED" ] \
    || warn "this machine is '$model', not '$MODEL_EXPECTED' -- the wifi and camera steps are model-specific."
for s in atomic-wifi.sh atomic-camera.sh swap-fn-ctrl.sh swap-caps-tilde.sh \
         keyboard-backlight.sh trackpad.sh lock-screen-setup.sh lock-pin.sh; do
    [ -x "$REPO/$s" ] || die "missing script: $REPO/$s (run me from inside the repo)"
done

# ---------------------------------------------------------------- preferences

WANT_FNCTRL=no WANT_CAPS=no WANT_KBD=no WANT_TRACKPAD=no WANT_LOCK=none WANT_PIN=no
if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
else
    say "Optional tweaks"
    info "None of these are needed for the hardware to work; they are personal"
    info "preferences. Answer no to any you do not want (change later with --reset)."

    if kbdback_ok; then WANT_KBD=yes
    elif ask_yn "Bind the keyboard-backlight keys (F5/F6)?" y; then WANT_KBD=yes; fi

    if trackpad_ok; then WANT_TRACKPAD=yes
    elif ask_yn "Trackpad: tap-to-click + corner right-click?" n; then WANT_TRACKPAD=yes; fi

    if fnctrl_ok; then WANT_FNCTRL=yes
    elif ask_yn "Swap Fn and left Ctrl?" n; then WANT_FNCTRL=yes; fi

    if capstilde_ok; then WANT_CAPS=yes
    elif ask_yn "Swap Caps Lock and \`/~?" n; then WANT_CAPS=yes; fi

    case "$(lock_mode)" in
        gtklock) WANT_LOCK=gtklock ;;
        blur)    WANT_LOCK=blur ;;
        none)
            if ask_yn "Set up a custom lock screen (instead of the stock one)?" n; then
                if ask_yn "  use the login-style one (gtklock) rather than the ring?" y; then
                    WANT_LOCK=gtklock
                else
                    WANT_LOCK=blur
                fi
            fi ;;
    esac

    if [ "$WANT_LOCK" != none ]; then
        if pin_ok; then WANT_PIN=yes
        elif ask_yn "Set a numeric PIN to unlock it?" y; then WANT_PIN=yes; fi
    fi

    mkdir -p "$STATE_DIR"
    {
        echo "WANT_FNCTRL=$WANT_FNCTRL"
        echo "WANT_CAPS=$WANT_CAPS"
        echo "WANT_KBD=$WANT_KBD"
        echo "WANT_TRACKPAD=$WANT_TRACKPAD"
        echo "WANT_LOCK=$WANT_LOCK"
        echo "WANT_PIN=$WANT_PIN"
    } > "$STATE_FILE"
fi

# ---------------------------------------------------------------- 1. core (required)

step "Wifi (Broadcom BCM4360) -- required"
wifi_ok && info "wl already installed; will check the connection." \
        || info "Layering akmod-wl + broadcom-wl from RPMFusion (needs one reboot)."
sudo "$REPO/atomic-wifi.sh"

step "Camera (FaceTime HD) -- required"
camera_ok && info "facetimehd already installed; will verify." \
          || info "Layering the camera akmod + firmware (needs the same reboot)."
sudo "$REPO/atomic-camera.sh"

if [ "$WANT_LOCK" = gtklock ] && ! gtklock_ok; then
    step "Lock screen package (gtklock)"
    sudo rpm-ostree install --idempotent gtklock
fi

if has_pending; then
    say "Packages are staged."
    echo "Reboot now, then run me again to finish:"
    echo "    $REPO/atomic-setup.sh"
    exit 0
fi

# ---------------------------------------------------------------- 2. optional keyboard tweaks

if [ "$WANT_FNCTRL" = yes ]; then
    step "Keyboard: Fn <-> left Ctrl"
    sudo "$REPO/swap-fn-ctrl.sh" on
fi
if [ "$WANT_CAPS" = yes ]; then
    step "Keyboard: Caps Lock <-> \`/~"
    sudo "$REPO/swap-caps-tilde.sh" on
fi

# ---------------------------------------------------------------- 3. optional Sway bits

if in_sway; then
    if [ "$WANT_KBD" = yes ]; then
        step "Keyboard backlight keys (F5/F6)"
        "$REPO/keyboard-backlight.sh" on
    fi
    if [ "$WANT_TRACKPAD" = yes ]; then
        step "Trackpad: tap-to-click + corner right-click"
        "$REPO/trackpad.sh" on
    fi
    if [ "$WANT_LOCK" = gtklock ]; then
        step "Lock screen: login-style (gtklock)"
        "$REPO/lock-screen-setup.sh" gtklock
    elif [ "$WANT_LOCK" = blur ]; then
        step "Lock screen: blurred ring (swaylock)"
        "$REPO/lock-screen-setup.sh" blur
    fi
    if [ "$WANT_PIN" = yes ] && ! pin_ok; then
        step "Numeric PIN for the lock screen"
        sudo "$REPO/lock-pin.sh" set
    fi
elif [ "$WANT_KBD" = yes ] || [ "$WANT_TRACKPAD" = yes ] \
     || [ "$WANT_LOCK" != none ] || [ "$WANT_PIN" = yes ]; then
    warn "Not in a Sway session -- run these after logging into Sway:"
    [ "$WANT_KBD" = yes ]      && info "  $REPO/keyboard-backlight.sh on"
    [ "$WANT_TRACKPAD" = yes ] && info "  $REPO/trackpad.sh on"
    [ "$WANT_LOCK" = gtklock ] && info "  $REPO/lock-screen-setup.sh gtklock"
    [ "$WANT_LOCK" = blur ]    && info "  $REPO/lock-screen-setup.sh blur"
    [ "$WANT_PIN" = yes ]      && info "  sudo $REPO/lock-pin.sh set"
fi

# ---------------------------------------------------------------- 4. health check

step "Health check"
ok()  { info "ok       $1"; }
bad() { warn "MISSING  $1"; }
wifi_ok            && ok "wl module"         || bad "wl module"
camera_ok          && ok "facetimehd module" || bad "facetimehd module"
[ -e /dev/video0 ] && ok "/dev/video0"       || bad "/dev/video0"
nmcli -t -f DEVICE,STATE device 2>/dev/null | grep -q '^wlp3s0:connected' \
                   && ok "wifi connected (wlp3s0)" || bad "wifi not connected"
if [ "$WANT_FNCTRL" = yes ];   then fnctrl_ok    && ok "Fn/Ctrl swap"          || bad "Fn/Ctrl swap"; fi
if [ "$WANT_CAPS" = yes ];     then capstilde_ok && ok "Caps/tilde swap"       || bad "Caps/tilde swap"; fi
if [ "$WANT_KBD" = yes ];      then kbdback_ok   && ok "keyboard backlight"    || bad "keyboard backlight"; fi
if [ "$WANT_TRACKPAD" = yes ]; then trackpad_ok  && ok "trackpad"              || bad "trackpad"; fi
if [ "$WANT_LOCK" != none ];   then [ "$(lock_mode)" != none ] && ok "lock screen ($WANT_LOCK)" || bad "lock screen"; fi
if [ "$WANT_PIN" = yes ];      then pin_ok       && ok "lock-screen PIN"       || bad "lock-screen PIN"; fi

say "Done."
echo "For what each piece does, and how to undo any of it, read atomic-playbook.md."
echo
echo "Before your next kernel upgrade, run atomic-upgrade.sh -- it checks that wl and"
echo "facetimehd were rebuilt for the new kernel before you reboot:"
echo "    sudo $REPO/atomic-upgrade.sh"
