#!/bin/bash
# lock-screen-setup.sh -- choose how the Sway lock screen looks
#
#   blur      (default) blurred + darkened screenshot, swaylock ring
#   solid     clean dark background, swaylock ring
#   gtklock   login-style screen (clock + password box) over a blurred screenshot
#   stock     Fedora's default wallpaper look
#   status    show what is configured now
#
# Runs as your user (no sudo). Changes apply immediately by restarting swayidle,
# and persist for future sessions.
#
# gtklock must be installed before its mode can be used:
#   sudo rpm-ostree install --apply-live gtklock
#   sudo <repo>/lock-pin.sh setup    (creates its PAM file)
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

CONF_DIR="$HOME/.config/swaylock"
CONF="$CONF_DIR/config"
GTK_CONF_DIR="$HOME/.config/gtklock"
GTK_CONF="$GTK_CONF_DIR/config.ini"
GTK_CSS="$GTK_CONF_DIR/style.css"
SWAY_CONF_D="$HOME/.config/sway/config.d"
OVERRIDE="$SWAY_CONF_D/90-swayidle.conf"
BIN_DIR="$HOME/.local/bin"
LOCKER="$BIN_DIR/lock-screen"

say()  { printf '\n== %s\n' "$*"; }
warn() { printf '\n!! %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Shared swaylock appearance: big visible ring + useful feedback.
indicator_conf() {
    cat <<'EOF'
# Show the ring even before typing, so it is obvious where the password goes.
indicator-idle-visible
# Bigger, higher-contrast ring, with clear feedback while typing.
indicator-radius=140
indicator-thickness=14
ring-color=89b4fa
ring-ver-color=a6e3a1
ring-wrong-color=d20f39
ring-clear-color=89b4fa
inside-color=1e1e2ecc
inside-ver-color=1e1e2ecc
inside-wrong-color=1e1e2ecc
inside-clear-color=1e1e2ecc
key-hl-color=a6e3a1
bs-hl-color=f38ba8
line-color=1e1e2e00
text-color=cdd6f4
text-ver-color=cdd6f4
text-wrong-color=d20f39
text-clear-color=cdd6f4
# Show "Wrong" / failed attempt count, the keyboard layout and Caps Lock.
show-failed-attempts
show-keyboard-layout
indicator-caps-lock
EOF
}

# Fedora's 90-swayidle.conf, but locking through our wrapper.
write_swayidle_override() {
    mkdir -p "$SWAY_CONF_D"
    cat > "$OVERRIDE" <<'EOF'
# Overrides /usr/share/sway/config.d/90-swayidle.conf (layered by filename).
# Same as Fedora's, but locks through the blurred-screenshot wrapper.
exec LT="$lock_timeout" ST="$screen_timeout" LT=${LT:-300} ST=${ST:-60} && \
    swayidle -w \
        timeout $LT '$HOME/.local/bin/lock-screen' \
        timeout $((LT + ST)) 'swaymsg "output * power off"' \
                      resume 'swaymsg "output * power on"'  \
        timeout $ST 'pgrep -xu "$USER" swaylock >/dev/null && swaymsg "output * power off"' \
             resume 'pgrep -xu "$USER" swaylock >/dev/null && swaymsg "output * power on"'  \
        before-sleep '$HOME/.local/bin/lock-screen' \
        lock '$HOME/.local/bin/lock-screen' \
        unlock 'pkill -xu "$USER" -SIGUSR1 swaylock'
EOF
}

# Restart swayidle with the given locker command so the change applies now.
restart_swayidle() {
    local locker=$1
    if [ -z "${SWAYSOCK:-}" ]; then
        warn "not in a Sway session; the change will apply at your next login"
        return 0
    fi
    pkill -x swayidle 2>/dev/null || true
    sleep 0.2
    local LT="${lock_timeout:-300}" ST="${screen_timeout:-60}"
    setsid swayidle -w \
        timeout "$LT" "$locker" \
        timeout $((LT + ST)) 'swaymsg "output * power off"' \
        resume 'swaymsg "output * power on"' \
        timeout "$ST" 'pgrep -xu "$USER" swaylock >/dev/null && swaymsg "output * power off"' \
        resume 'pgrep -xu "$USER" swaylock >/dev/null && swaymsg "output * power on"' \
        before-sleep "$locker" \
        lock "$locker" \
        unlock 'pkill -xu "$USER" -SIGUSR1 swaylock' \
        </dev/null >/dev/null 2>&1 &
    sleep 0.3
    if pgrep -x swayidle >/dev/null; then
        say "swayidle restarted with the new locker"
    else
        warn "swayidle did not start; log out and back in to apply"
    fi
}

# Blurred screenshot written to a fixed path; used by both wrappers.
blurred_background() {   # blurred_background <output-path>
    local img=$1
    mkdir -p "$(dirname "$img")"
    grim "$img" 2>/dev/null \
        && magick "$img" -blur 0x12 -fill black -colorize 20% "$img.tmp" 2>/dev/null \
        && mv "$img.tmp" "$img"
}

set_blur() {
    command -v grim >/dev/null 2>&1 || die "grim is required for blur mode"
    command -v magick >/dev/null 2>&1 || die "ImageMagick (magick) is required for blur mode"
    mkdir -p "$CONF_DIR" "$BIN_DIR" "$SWAY_CONF_D"

    cat > "$CONF" <<'EOF'
# Blurred-screenshot lock screen. lock-screen passes the image with -i;
# scaling makes it fill the screen.
scaling=fill
EOF
    indicator_conf >> "$CONF"

    cat > "$LOCKER" <<'EOF'
#!/bin/sh
# lock-screen -- lock with swaylock over a blurred, darkened screenshot.
set -u
img="${XDG_CACHE_HOME:-$HOME/.cache}/lock-screen.png"
if grim "$img" 2>/dev/null \
   && magick "$img" -blur 0x12 -fill black -colorize 20% "$img.tmp" 2>/dev/null; then
    mv "$img.tmp" "$img"
    exec swaylock -f -i "$img"
else
    rm -f "$img.tmp"
    exec swaylock -f -c 1e1e2e
fi
EOF
    chmod 755 "$LOCKER"

    write_swayidle_override
    restart_swayidle "$LOCKER"
    say "Lock screen: blurred screenshot"
}

set_solid() {
    mkdir -p "$CONF_DIR"
    cat > "$CONF" <<'EOF'
# Clean dark lock screen (no screenshot).
scaling=solid_color
color=1e1e2e
EOF
    indicator_conf >> "$CONF"
    rm -f "$OVERRIDE" "$LOCKER"
    restart_swayidle 'swaylock -f'
    say "Lock screen: dark background"
}

set_gtklock() {
    command -v gtklock >/dev/null 2>&1 || die \
        "gtklock is not installed. Run:  sudo rpm-ostree install --apply-live gtklock"
    if [ ! -f /etc/pam.d/gtklock ]; then
        die "gtklock's PAM file is missing. Run:  sudo $REPO/lock-pin.sh setup"
    fi
    command -v grim >/dev/null 2>&1 || die "grim is required for gtklock mode"
    command -v magick >/dev/null 2>&1 || die "ImageMagick (magick) is required for gtklock mode"
    mkdir -p "$GTK_CONF_DIR" "$BIN_DIR" "$SWAY_CONF_D"

    # gtklock resolves the CSS path from its config, and relative url()s in the
    # CSS from the CSS file's own directory.
    cat > "$GTK_CONF" <<EOF
[main]
style=$GTK_CSS
EOF

    cat > "$GTK_CSS" <<'EOF'
window {
	background-image: url("background.png");
	background-size: cover;
	background-position: center;
	background-color: #1e1e2e;
}
#clock-label {
	font-size: 72px;
	font-weight: 300;
	color: #cdd6f4;
}
#date-label {
	font-size: 18px;
	color: #a6adc8;
}
#input-label {
	font-size: 16px;
	color: #cdd6f4;
}
#input-field {
	background-color: rgba(17, 17, 27, 0.85);
	color: #cdd6f4;
	border: 2px solid #89b4fa;
	border-radius: 8px;
	padding: 8px 12px;
	font-size: 18px;
	caret-color: #89b4fa;
}
#unlock-button {
	background-color: #89b4fa;
	background-image: none;
	color: #1e1e2e;
	border: none;
	border-radius: 8px;
	padding: 8px 24px;
	font-size: 16px;
	font-weight: bold;
}
#unlock-button:hover {
	background-color: #a6e3a1;
}
#warning-label, #error-label {
	color: #f38ba8;
}
EOF

    cat > "$LOCKER" <<'EOF'
#!/bin/sh
# lock-screen -- gtklock over a blurred, darkened screenshot.
set -u
img="${XDG_CONFIG_HOME:-$HOME/.config}/gtklock/background.png"
if grim "$img" 2>/dev/null \
   && magick "$img" -blur 0x12 -fill black -colorize 20% "$img.tmp" 2>/dev/null; then
    mv "$img.tmp" "$img"
else
    rm -f "$img.tmp"
fi
exec gtklock -d
EOF
    chmod 755 "$LOCKER"

    write_swayidle_override
    restart_swayidle "$LOCKER"
    say "Lock screen: gtklock (login-style)"
}

set_stock() {
    rm -f "$CONF" "$OVERRIDE" "$LOCKER"
    restart_swayidle 'swaylock -f'
    say "Lock screen: Fedora default (wallpaper)"
}

show_status() {
    if [ -x "$LOCKER" ] && grep -q gtklock "$LOCKER" 2>/dev/null; then
        echo "mode:     gtklock (login-style)"
    elif [ -f "$OVERRIDE" ] && [ -x "$LOCKER" ]; then
        echo "mode:     blur (blurred screenshot)"
    elif [ -f "$CONF" ] && grep -q '^scaling=solid_color' "$CONF"; then
        echo "mode:     solid (dark background)"
    elif [ -f "$CONF" ]; then
        echo "mode:     custom (config exists)"
    else
        echo "mode:     stock (Fedora wallpaper)"
    fi
    echo "gtklock:  $(command -v gtklock >/dev/null 2>&1 && echo installed || echo 'not installed')"
    for f in "$CONF" "$GTK_CONF" "$LOCKER" "$OVERRIDE"; do
        if [ -e "$f" ]; then echo "present:  $f"; else echo "absent:   $f"; fi
    done
    if pgrep -x swayidle >/dev/null; then
        echo "swayidle: running"
    else
        echo "swayidle: not running"
    fi
}

case "${1:-blur}" in
blur)    set_blur ;;
solid)   set_solid ;;
gtklock) set_gtklock ;;
stock)   set_stock ;;
status)  show_status ;;
*)       die "usage: $0 [blur|solid|gtklock|stock|status]" ;;
esac

echo
echo "See it now with:  loginctl lock-session"
echo "Switch any time:  $0 blur|solid|gtklock|stock     Check: $0 status"
