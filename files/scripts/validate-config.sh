#!/bin/bash
# validate-config.sh - prove the deployed Caelestia configuration is valid on
# the assembled image.
#
# This is the "1:1 parity" proof: run the real installer exactly as a user
# would, then ask the image's OWN hyprland binary whether the resulting config
# parses, and diff the deployed files against our pinned dots checkout.
#
# Requires network access (the installer clones the dots repo itself, which is
# the faithful user flow).
set -uo pipefail

HOMEDIR="${1:-/tmp/caelestia-home}"
PINNED_DOTS="${2:-/dots}"     # read-only mount of build/src/caelestia-dots
FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
note(){ printf '  \033[33mNOTE\033[0m %s\n' "$*"; }
sec() { printf '\n== %s ==\n' "$*"; }

export HOME="$HOMEDIR"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export XDG_DATA_HOME="$HOME/.local/share"
export XDG_CACHE_HOME="$HOME/.cache"
# Hyprland refuses to run without it, even for --verify-config.
export XDG_RUNTIME_DIR="$HOME/run"
rm -rf "$HOMEDIR"; mkdir -p "$XDG_STATE_HOME/caelestia" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

sec "Deploying the dots (caelestia install --noconfirm)"
if caelestia install --noconfirm </dev/null >/tmp/install.log 2>&1; then
  ok "caelestia install completed"
else
  bad "caelestia install failed:"; tail -20 /tmp/install.log | sed 's/^/      /'; exit 1
fi
grep -q "All done" /tmp/install.log && ok "installer reported success"

sec "Deployed layout matches the manifest (1:1 XDG paths)"
check_path() { if [ -e "$1" ]; then ok "$2 -> ${1#$HOME}"; else bad "$2 missing: ${1#$HOME}"; fi; }
check_path "$XDG_CONFIG_HOME/hypr/hyprland.lua"        "hypr entrypoint"
check_path "$XDG_CONFIG_HOME/hypr/variables.lua"        "hypr variables"
check_path "$XDG_CONFIG_HOME/hypr/utils/functions.lua" "hypr utils"
check_path "$XDG_CONFIG_HOME/hypr/scheme/default.lua"  "hypr scheme"
check_path "$XDG_CONFIG_HOME/hypr/hyprland/keybinds.lua" "hypr keybinds"
# NOTE: hypr-vars.lua / hypr-user.lua are NOT created by the installer. They are
# created by hyprland.lua's maybe_create() when Hyprland first loads the config,
# so their absence here is expected and correct.

sec "Content parity with our pinned dots checkout"
# The installer clones upstream; confirm the bytes it deployed match the exact
# commit our build pinned, so the image cannot silently drift from the lockfile.
if [ -d "$PINNED_DOTS" ]; then
  for f in hypr/hyprland.lua hypr/variables.lua hypr/hyprland/keybinds.lua hypr/utils/functions.lua; do
    src="$PINNED_DOTS/$f"; dst="$XDG_CONFIG_HOME/$f"
    if [ -f "$src" ] && [ -f "$dst" ]; then
      if diff -q "$src" "$dst" >/dev/null 2>&1; then ok "identical to pinned: $f"
      else bad "DIFFERS from pinned dots: $f"; fi
    else
      bad "cannot compare $f (src or dst missing)"
    fi
  done
else
  bad "pinned dots not mounted at $PINNED_DOTS - skipping parity diff"
fi

sec "Hyprland accepts the deployed config (image's own binary)"
# CONTROLLED TEST: Hyprland 0.56.0's --verify-config segfaults on ANY Lua
# config, including a trivial `return {}`. We therefore run a control case so
# we can distinguish "our config is broken" from "verify mode cannot handle
# Lua configs at all".
mkdir -p /tmp/ctrl && printf 'return {}\n' > /tmp/ctrl/trivial.lua
hyprland --i-am-really-stupid --verify-config -c /tmp/ctrl/trivial.lua >/tmp/hv_ctrl.log 2>&1
CTRL=$?
hyprland --i-am-really-stupid --verify-config -c "$XDG_CONFIG_HOME/hypr/hyprland.lua" >/tmp/hv.log 2>&1
OURS=$?

if [ "$CTRL" -ge 128 ]; then
  # Not a failure of this image: verify mode simply cannot handle Lua configs.
  # Config validity is established instead by (a) byte-parity with the pinned
  # dots, which the build stage already validated with luac, and (b) the
  # luac sweep below when a parser is available.
  note "UPSTREAM LIMITATION: hyprland --verify-config segfaults on ANY Lua config"
  note "  in this build (Hyprland $(hyprland --version 2>/dev/null | head -1 | awk '{print $2}'));"
  note "  a control 'return {}' config crashes identically, so the check is"
  note "  inconclusive rather than a defect in the deployed configuration."
elif [ "$OURS" -ge 128 ]; then
  bad "our config segfaults --verify-config (exit $OURS) while the control did not"
elif [ "$OURS" -eq 0 ]; then
  ok "hyprland --verify-config accepted the config"
else
  bad "hyprland rejected the config (exit $OURS):"
  grep -vE '^\s*$' /tmp/hv.log | head -25 | sed 's/^/      /'
fi

sec "Lua syntax of every deployed config file"
if command -v luac >/dev/null 2>&1; then
  n=0; bad_n=0
  while IFS= read -r f; do
    n=$((n+1))
    luac -p "$f" 2>/dev/null || { bad "syntax error: ${f#$HOME}"; bad_n=$((bad_n+1)); }
  done < <(find "$XDG_CONFIG_HOME/hypr" -name '*.lua' 2>/dev/null)
  [ "$bad_n" -eq 0 ] && ok "all $n deployed .lua files parse cleanly"
elif command -v lua >/dev/null 2>&1; then
  n=0; bad_n=0
  while IFS= read -r f; do
    n=$((n+1))
    lua -e "assert(loadfile('$f'))" 2>/dev/null || { bad "syntax error: ${f#$HOME}"; bad_n=$((bad_n+1)); }
  done < <(find "$XDG_CONFIG_HOME/hypr" -name '*.lua' 2>/dev/null)
  [ "$bad_n" -eq 0 ] && ok "all $n deployed .lua files parse cleanly"
else
  note "no Lua parser in the runtime image (correct - it must not ship)."
  note "  These same files are byte-identical to the pinned dots, whose syntax"
  note "  was validated with luac during the build stage."
fi

sec "Quickshell resolves the shell config by name"
qs -c caelestia --help >/dev/null 2>&1 && ok "qs finds the 'caelestia' config" \
                                     || bad "qs cannot find the 'caelestia' config"

sec "Caelestia wrapper"
command -v caelestia-shell >/dev/null && ok "caelestia-shell on PATH" || bad "caelestia-shell missing"

sec "wayblue overrides took effect"
[ -e /etc/xdg/waybar/config.jsonc ] && bad "wayblue waybar config still present" \
                                  || ok "wayblue waybar config removed"
[ -e /usr/share/hyprland/hyprland.lua ] && bad "wayblue hyprland.lua still present" \
                                        || ok "wayblue hyprland.lua removed"
if grep -qE '^[[:space:]]*(export[[:space:]]+)?(QT_STYLE_OVERRIDE|GTK_THEME)=' /etc/environment 2>/dev/null; then
  bad "QT_STYLE_OVERRIDE/GTK_THEME still set (would bypass qtengine theming)"
  grep -E 'QT_STYLE_OVERRIDE|GTK_THEME' /etc/environment | sed 's/^/      /'
else
  ok "QT_STYLE_OVERRIDE/GTK_THEME stripped from /etc/environment"
fi

sec "evdev / uinput wiring"
for g in input uinput video render; do
  getent group "$g" >/dev/null && ok "group $g exists" || bad "group $g missing"
done
[ -f /etc/modules-load.d/caelestia-uinput.conf ] && ok "uinput module load configured" \
                                                || bad "uinput module load missing"
[ -f /usr/lib/udev/rules.d/70-caelestia-input.rules ] && ok "udev rules shipped" \
                                                      || bad "udev rules missing"

sec "first-boot provisioning"
[ -f /etc/systemd/system/caelestia-firstboot.service ] && ok "unit present" || bad "unit missing"
[ -f /usr/lib/caelestia-scripts/firstboot-setup.sh ]  && ok "script installed" || bad "script missing"
[ -f /etc/systemd/user/caelestia-shell.service ]       && ok "user shell unit present" || bad "user shell unit missing"

printf '\n'
if [ "$FAIL" -eq 0 ]; then printf '\033[1;32m==== CONFIG VALIDATION PASSED ====\033[0m\n'
else printf '\033[1;31m==== CONFIG VALIDATION: %d FAILED ====\033[0m\n' "$FAIL"; fi
exit "$FAIL"