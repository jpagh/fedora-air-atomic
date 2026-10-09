#!/usr/bin/env bash
# gtklock-wakekey.sh -- make gtklock stop typing the key that wakes the screen
#
# When the display has blanked (idle, or after resume) the first key press is
# only meant to wake the screen.  gtklock, though, passes that key through to
# the password field, so pressing Space to unblank it inserts a leading space
# and the password fails.  Its idle handler deliberately returns FALSE:
#
#     static gboolean window_idle_key(...) {
#         gtklock_idle_show(gtklock);
#         return FALSE;   /* <- event continues into the input field */
#     }
#
# There is no config option for this, so this script builds a one-line patched
# gtklock that returns `gtklock->hidden`, i.e. it swallows exactly the key that
# revealed the hidden form, and nothing else.  It also enables gtklock's
# idle-hide so that handler is actually in play.
#
# Runs as your user (no sudo): the build happens in a throwaway Fedora
# container with podman, and the result is installed to ~/.local/bin/gtklock,
# which shadows /usr/bin/gtklock for the lock wrapper.  The immutable host is
# untouched.  Re-run this after a gtklock update (or use --rebuild).
#
#     ./gtklock-wakekey.sh            build if needed, then wire it up
#     ./gtklock-wakekey.sh --rebuild  force a rebuild
#     ./gtklock-wakekey.sh --check    report the current state, change nothing
set -euo pipefail

VERSION=4.0.0
IMAGE=${GTKLOCK_BUILD_IMAGE:-registry.fedoraproject.org/fedora:44}
SRC="${XDG_DATA_HOME:-$HOME/.local/share}/gtklock/src"
BIN="$HOME/.local/bin/gtklock"
WRAPPER="$HOME/.local/bin/lock-screen"
GTK_CONF="${XDG_CONFIG_HOME:-$HOME/.config}/gtklock/config.ini"
MARKER='gtklock-wakekey-patch'

say()  { printf '\n== %s\n' "$*"; }
warn() { printf '\n!! %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

patched() { [ -x "$BIN" ] && grep -aq "$MARKER" "$BIN"; }

case "${1:-build}" in
--check)
    say "gtklock-wakekey status"
    printf 'source:   %s %s\n' "$SRC" "$([ -d "$SRC/.git" ] && echo present || echo missing)"
    printf 'binary:   %s %s\n' "$BIN" "$(patched && echo 'present (patched)' || echo 'missing/unpatched')"
    printf 'config:   %s\n' "$([ -f "$GTK_CONF" ] && grep -q '^idle-hide' "$GTK_CONF" \
        && echo 'idle-hide set' || echo 'idle-hide missing')"
    printf 'wrapper:  %s\n' "$([ -f "$WRAPPER" ] && grep -q 'local/bin/gtklock' "$WRAPPER" \
        && echo 'uses local gtklock' || echo 'uses system gtklock')"
    exit 0
    ;;
build|--rebuild) ;;
*) die "usage: $0 [--rebuild|--check]" ;;
esac

# --- source -----------------------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
    say "Cloning gtklock v$VERSION"
    mkdir -p "$(dirname "$SRC")"
    git clone --depth 1 --branch "v$VERSION" \
        https://github.com/jovanlanik/gtklock.git "$SRC"
fi

# --- patch ------------------------------------------------------------------
PATCH=$(mktemp)
OUT=$(mktemp -d)
trap 'rm -f "$PATCH"; rm -rf "$OUT"' EXIT
cat > "$PATCH" <<'PATCH_EOF'
diff --git a/src/window.c b/src/window.c
index b5859cb..d220a46 100644
--- a/src/window.c
+++ b/src/window.c
@@ -255,9 +255,15 @@ void window_idle_show(struct Window *ctx) {
 	g_object_unref(cursor);
 }
 
+static const char wakekey_marker[] __attribute__((used)) = "gtklock-wakekey-patch";
+
 static gboolean window_idle_key(GtkWidget *self, GdkEventKey event, gpointer user_data) {
+	/* Swallow the key that reveals the hidden form.  When the display has
+	 * blanked (or resumed from sleep) the first key is only meant to wake
+	 * the screen; without this it lands in the password field. */
+	gboolean was_hidden = gtklock->hidden;
 	gtklock_idle_show(gtklock);
-	return FALSE;
+	return was_hidden;
 }
 static gboolean window_idle_motion(GtkWidget *self, GdkEventMotion event, gpointer user_data) {
 	gtklock_idle_show(gtklock);
PATCH_EOF

if ! grep -q wakekey_marker "$SRC/src/window.c"; then
    say "Applying wake-key patch"
    git -C "$SRC" checkout -q -- .
    git -C "$SRC" apply "$PATCH"
fi

# --- build ------------------------------------------------------------------
if [ "${1:-build}" = --rebuild ] || ! patched; then
    command -v podman >/dev/null 2>&1 || die "podman is required for the build"
    say "Building in $IMAGE (first run pulls the GTK dev headers)"
    podman run --rm \
        -v "$SRC:/src:ro,Z" \
        -v "$OUT:/out:Z" \
        "$IMAGE" \
        bash -c 'set -euo pipefail
            dnf -y -q --setopt=install_weak_deps=False install \
                gcc meson ninja-build pkgconf-pkg-config \
                gtk3-devel gtk-session-lock-devel pam-devel glib2-devel gettext
            cd /src
            meson setup /build --buildtype=release -Dman-pages=disabled
            ninja -C /build
            install -m755 /build/gtklock /out/gtklock'
    install -m755 "$OUT/gtklock" "$BIN"
    patched || die "the built binary is missing the patch marker"
    say "Installed $BIN"
else
    say "Already built and patched (use --rebuild to force)"
fi

# --- enable idle-hide so the patched handler is used ------------------------
if [ -f "$GTK_CONF" ] && ! grep -q '^idle-hide' "$GTK_CONF"; then
    say "Enabling gtklock idle-hide in $GTK_CONF"
    cat >> "$GTK_CONF" <<'EOF'

# Hide the form after 45s idle; the patched gtklock then swallows the first
# key, so waking a blanked screen does not type into the password box.  Keep
# this below swayidle's screen_timeout so the form hides before the screen.
idle-hide=true
idle-timeout=45
EOF
elif [ ! -f "$GTK_CONF" ]; then
    warn "$GTK_CONF not found; run lock-screen-setup.sh gtklock first"
fi

# --- point the lock wrapper at the local binary -----------------------------
if [ -f "$WRAPPER" ] && ! grep -q 'local/bin/gtklock' "$WRAPPER"; then
    say "Pointing $WRAPPER at the local gtklock"
    sed -i 's#^exec gtklock -d$#if [ -x "$HOME/.local/bin/gtklock" ]; then\n    exec "$HOME/.local/bin/gtklock" -d\nfi\nexec gtklock -d#' "$WRAPPER"
fi

say "Done"
echo "Check any time:  $0 --check"
echo "Test:  loginctl lock-session, let the form hide, then press Space"
