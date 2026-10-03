#!/bin/bash
# lock-pin.sh -- add a numeric PIN to the Sway lock screen
#
# Windows Hello PINs are backed by the TPM; Linux screen lockers have no
# equivalent. This is a plain local PIN check instead:
#
#   - A pam_exec helper runs before the normal password check in the locker's
#     own PAM service (/etc/pam.d/swaylock and/or /etc/pam.d/gtklock).
#   - It only unlocks the lock screen. sudo, login and SDDM still use the
#     account password, and the password keeps working as a fallback.
#   - Five wrong numeric attempts within five minutes temporarily refuse
#     further PIN attempts, and every wrong attempt is delayed one second.
#
# Usage:
#   sudo ./lock-pin.sh set      choose a PIN (4-8 digits)
#   sudo ./lock-pin.sh clear    remove the PIN
#   sudo ./lock-pin.sh setup    prepare PAM without choosing a PIN
#   sudo ./lock-pin.sh status   show the current state
set -euo pipefail

CHECK=/usr/local/sbin/lock-pin-check
PAM_FILES=(/etc/pam.d/swaylock /etc/pam.d/gtklock)
LINE='auth sufficient pam_exec.so expose_authtok quiet /usr/local/sbin/lock-pin-check'

say()  { printf '\n== %s\n' "$*"; }
warn() { printf '\n!! %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this with sudo:  sudo $0 ${1:-set}"
user=${SUDO_USER:-}
[ -n "$user" ] && [ "$user" != root ] || die "run this via sudo from your normal account"
home=$(getent passwd "$user" | cut -d: -f6)
[ -n "$home" ] && [ -d "$home" ] || die "cannot find the home directory of '$user'"
pinf="$home/.config/lock-pin"

install_check() {
    cat > "$CHECK" <<'EOF'
#!/bin/bash
# lock-pin-check -- pam_exec helper accepting a numeric PIN for the lock
# screen. pam_exec runs this with the real UID of the caller, so the hash is
# read from that user's home. Exit 0 accepts; exit 1 falls through to the
# normal password check.
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

# pam_exec replaces the environment with the PAM environment, so HOME and
# XDG_RUNTIME_DIR may be missing; derive them from the real user instead.
user=${PAM_USER:-$(id -un 2>/dev/null)}
home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
[ -n "$home" ] && [ -d "$home" ] || exit 1
pinfile="$home/.config/lock-pin"
[ -f "$pinfile" ] || exit 1

pin=""
IFS= read -r pin || true
pin=${pin%$'\r'}

# Only digit-only input counts as a PIN attempt, so unlocking with the real
# password (which also reaches this script first) is not rate-limited.
case "$pin" in
    ''|*[!0-9]*) exit 1 ;;
esac

rundir=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
[ -d "$rundir" ] && [ -w "$rundir" ] || rundir="$home/.cache"
mkdir -p "$rundir" 2>/dev/null || true
state="$rundir/lock-pin.fails"
now=$(date +%s)
fails=0
if [ -f "$state" ]; then
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        [ $((now - t)) -lt 300 ] && fails=$((fails + 1))
    done < "$state"
fi
if [ "$fails" -ge 5 ]; then
    sleep 1
    exit 1
fi

salt=$(cut -d'$' -f3 "$pinfile")
want=$(cat "$pinfile")
got=$(openssl passwd -6 -salt "$salt" "$pin" 2>/dev/null || true)
if [ -n "$got" ] && [ "$got" = "$want" ]; then
    rm -f "$state"
    exit 0
fi

printf '%s\n' "$now" >> "$state" 2>/dev/null || true
sleep 1
exit 1
EOF
    chmod 755 "$CHECK"
    restorecon -F "$CHECK" 2>/dev/null || true
}

ensure_pam_files() {
    # gtklock's /etc/pam.d file normally arrives with the deployment, but when
    # it is layered with --apply-live only /usr is applied immediately.
    if command -v gtklock >/dev/null 2>&1 && [ ! -f /etc/pam.d/gtklock ]; then
        printf 'auth include login\n' > /etc/pam.d/gtklock
        restorecon -F /etc/pam.d/gtklock 2>/dev/null || true
        say "created /etc/pam.d/gtklock"
    fi
}

pam_add_line() {
    local f
    for f in "${PAM_FILES[@]}"; do
        [ -f "$f" ] || continue
        grep -qF "$LINE" "$f" && continue
        awk -v line="$LINE" '
            !done && /^auth[ \t]+include/ { print line; done = 1 }
            { print }
            END { if (!done) print line }
        ' "$f" > "$f.new"
        mv "$f.new" "$f"
        restorecon -F "$f" 2>/dev/null || true
        say "PIN check enabled in $f"
    done
}

pam_remove_line() {
    local f
    for f in "${PAM_FILES[@]}"; do
        [ -f "$f" ] || continue
        grep -qF "$LINE" "$f" || continue
        grep -vF "$LINE" "$f" > "$f.new"
        mv "$f.new" "$f"
        restorecon -F "$f" 2>/dev/null || true
        say "PIN check removed from $f"
    done
}

case "${1:-}" in
setup)
    install_check
    ensure_pam_files
    pam_add_line
    say "PAM prepared for $user. Set a PIN with: sudo $0 set"
    ;;
set)
    install_check
    ensure_pam_files
    pam_add_line
    while :; do
        read -rsp "New PIN (4-8 digits): " p1; echo
        read -rsp "Repeat PIN: " p2; echo
        [ "$p1" = "$p2" ] || { warn "PINs do not match; try again"; continue; }
        case "$p1" in
            ''|*[!0-9]*) warn "PIN must be digits only"; continue ;;
        esac
        if [ "${#p1}" -lt 4 ] || [ "${#p1}" -gt 8 ]; then
            warn "PIN must be 4-8 digits"; continue
        fi
        break
    done
    salt=$(openssl rand -hex 8)
    hash=$(openssl passwd -6 -salt "$salt" "$p1")
    install -d -o "$user" -g "$user" -m 700 "$home/.config"
    printf '%s\n' "$hash" > "$pinf"
    chown "$user:$user" "$pinf"
    chmod 600 "$pinf"
    say "PIN set for $user. It unlocks the lock screen; the password still works."
    ;;
clear)
    rm -f "$pinf"
    pam_remove_line
    say "PIN cleared. The lock screen uses the account password again."
    ;;
status)
    if [ -f "$pinf" ]; then
        echo "PIN:      set for $user ($pinf)"
    else
        echo "PIN:      not set for $user"
    fi
    for f in "${PAM_FILES[@]}"; do
        [ -f "$f" ] || continue
        if grep -qF "$LINE" "$f"; then
            echo "enabled:  $f"
        else
            echo "disabled: $f"
        fi
    done
    ;;
*)
    die "usage: sudo $0 [set|clear|setup|status]"
    ;;
esac
