#!/bin/bash
# Verification suite for the caelestia stack.
#
# The suite runs in BOTH images:
#   * the builder image (deps + compiled components)  -> BUILD_ENV=1
#   * the assembled runtime image                       -> BUILD_ENV=0
# Checks that only make sense while compiling (pkg-config exports, headers,
# luac) are skipped in the runtime image, and the runtime image instead gets
# the checks that actually matter there: every shipped .so resolves against
# libraries the image really contains.

FAILURES=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILURES=$((FAILURES+1)); }
skip(){ printf '  \033[33mSKIP\033[0m %s\n' "$*"; }
sec() { echo; echo "== $* =="; }

# Build-only tooling exists in the builder image but must NOT be in the runtime
# image, so its presence is how we tell the two apart.
if [ -f /usr/include/cava/cavacore.h ]; then BUILD_ENV=1; else BUILD_ENV=0; fi
if [ "$BUILD_ENV" = 1 ]; then echo "(build environment)"; else echo "(runtime image)"; fi

# ============================================================ always valid ===
sec "T3a quickshell binary"
/usr/bin/qs --version >/dev/null 2>&1 && ok "qs: $(/usr/bin/qs --version 2>&1|head -1)" || bad "qs --version"
[ -L /usr/bin/qs ] && ok "qs symlink" || bad "qs symlink"

sec "T3b caelestia CLI"
command -v caelestia >/dev/null && ok "on PATH: $(command -v caelestia)" || bad "not on PATH"
caelestia --help >/dev/null 2>&1 && ok "--help" || bad "--help"
if caelestia -v >/tmp/cv.out 2>/tmp/cv.err; then
  ok "caelestia -v (exit 0)"
  grep -q "not on Arch" /tmp/cv.out && ok "degrades gracefully off-Arch" || warn "no 'not on Arch' marker"
  grep -q "Quickshell 0.3" /tmp/cv.out && ok "reports quickshell 0.3.x" || bad "no quickshell 0.3.x"
else
  bad "caelestia -v failed: $(head -c 200 /tmp/cv.err)"
fi

sec "T3c QML modules"
for m in Caelestia M3Shapes Quickshell; do
  [ -d "/usr/lib64/qt6/qml/$m" ] && ok "qml/$m" || bad "qml/$m"
done
nso=$(find /usr/lib64/qt6/qml/Caelestia -name '*.so' 2>/dev/null | wc -l)
[ "$nso" -ge 1 ] && ok "$nso native QML plugin(s) installed" || bad "no native QML plugin .so found"

sec "T2b EVERY shipped .so resolves against libs the image contains"
# This is the check that catches "it compiled but the runtime lib was never
# installed" - the exact failure mode that build-only verification misses.
scan_targets=$(find /usr/lib64/qt6/qml/Caelestia /usr/lib64/qt6/qml/Quickshell \
                      -name '*.so' 2>/dev/null
              echo /usr/bin/quickshell
              command -v lazygit 2>/dev/null
              command -v gpu-screen-recorder 2>/dev/null)
miss=0
for so in $scan_targets; do
  [ -e "$so" ] || continue
  for lib in $(ldd "$so" 2>/dev/null | awk '/=> not found/{print $1}'); do
    bad "missing $lib required by $(basename "$so")"
    miss=$((miss+1))
  done
done
[ "$miss" -eq 0 ] && ok "all shipped binaries/plugins resolve (no missing libs)" \
                 || bad "$miss unresolved shared-library reference(s)"

sec "T3d quickshell config at XDG path"
[ -f /etc/xdg/quickshell/caelestia/shell.qml ] && ok "shell.qml" || bad "shell.qml"
[ -d /etc/xdg/quickshell/caelestia/modules ] && ok "modules/" || bad "modules/"
grep -q 'watchFiles: false' /etc/xdg/quickshell/caelestia/shell.qml 2>/dev/null \
  && ok "watchFiles rewrite applied" || bad "watchFiles rewrite"

sec "T7 extra from-source components"
command -v lazygit >/dev/null 2>&1 && ok "lazygit present" || bad "lazygit missing"
if command -v sass >/dev/null 2>&1; then
  if out=$(sass --version 2>&1); then ok "sass: $out"; else bad "sass present but BROKEN: $out"; fi
else
  bad "sass missing"
fi
command -v gpu-screen-recorder >/dev/null 2>&1 \
  && ok "gpu-screen-recorder: $(command -v gpu-screen-recorder)" \
  || bad "gpu-screen-recorder missing"
if ls /usr/share/fonts/rubik/*.ttf >/dev/null 2>&1; then
  ok "rubik font installed: $(ls /usr/share/fonts/rubik/ | tr '\n' ' ')"
  command -v fc-match >/dev/null && ok "fc-match Rubik -> $(fc-match Rubik 2>/dev/null | head -1 | cut -d: -f1)"
else
  bad "rubik font not installed"
fi

# ========================================================== build-env only ===
if [ "$BUILD_ENV" = 1 ]; then
  sec "T3b python imports"
  python3 -c "import caelestia, materialyoucolor, PIL" 2>/dev/null \
    && ok "caelestia, materialyoucolor, PIL" || bad "python imports"

  sec "T4 pkg-config consumed by the plugin"
  pkg-config --exists libcava && ok "libcava.pc" || { pkg-config --exists cava && ok "cava.pc" || bad "no cava pkg-config"; }
  for p in libqalculate libpipewire-0.3 aubio; do
    pkg-config --exists "$p" && ok "$p" || bad "$p"
  done
  [ -f /usr/include/cava/cavacore.h ] && ok "cava/cavacore.h" || bad "cava/cavacore.h"

  sec "T6 hyprland lua syntax"
  HYPR_SRC="${HYPR_SRC:-/dots/hypr}"
  [ -d "$HYPR_SRC" ] || HYPR_SRC=/work/caelestia/hypr
  if [ -d "$HYPR_SRC" ] && command -v luac >/dev/null 2>&1; then
    for f in "$HYPR_SRC"/hyprland.lua "$HYPR_SRC"/variables.lua \
             "$HYPR_SRC"/utils/*.lua "$HYPR_SRC"/scheme/*.lua; do
      [ -e "$f" ] || continue
      luac -p "$f" 2>/dev/null && ok "lua: $(basename $f)" || bad "lua: $(basename $f)"
    done
  else
    skip "lua sources not mounted / luac unavailable"
  fi
else
  sec "build-env-only checks"
  skip "T4 pkg-config (build-time only - correctly absent at runtime)"
  skip "T6 lua syntax (needs luac, which must not ship)"
  [ -e /usr/include/cava ] && bad "build headers leaked into the runtime image" \
                           || ok "no build headers leaked into the runtime image"
  # Build leakage = artefacts NOT owned by any RPM. Legitimate packages do ship
  # .a files (python3-numpy ships libnpymath.a), so only unowned ones count.
  leaked=$(find /usr/lib64 /usr/lib -name '*.a' 2>/dev/null | while read -r f; do
             rpm -qf "$f" >/dev/null 2>&1 || echo "$f"; done | head -10)
  if [ -n "$leaked" ]; then
    bad "unowned static archives in the runtime image:"
    echo "$leaked" | sed 's/^/      /'
  else
    ok "no unowned build artefacts in the runtime image"
  fi
  # A dereferenced symlink would silently duplicate the 240 MiB quickshell binary.
  if [ -f /usr/bin/qs ] && [ ! -L /usr/bin/qs ]; then
    bad "/usr/bin/qs is a $(stat -c%s /usr/bin/qs)-byte regular file, not a symlink"
  else
    ok "/usr/bin/qs is a symlink (no duplicated binary)"
  fi
fi

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "==== VERIFICATION: ALL TESTS PASSED ===="
else
  echo "==== VERIFICATION: $FAILURES FAILED ===="
fi
exit $FAILURES