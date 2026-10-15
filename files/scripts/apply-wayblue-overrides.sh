#!/usr/bin/env bash
# Apply the overrides that adapt the wayblue base image to Caelestia.
#
# Runs at image build time inside BlueBuild.  Everything here is idempotent.

set -euo pipefail

echo "==> Caelestia: applying wayblue overrides"

# ---------------------------------------------------------------------------
# 1. Remove wayblue's waybar configuration.
#
#    Caelestia draws its own bar.  Nothing in the caelestia hypr config ever
#    launches waybar, so leaving these files behind only risks a stray waybar
#    picking up wayblue's config if something else autostarts it.
# ---------------------------------------------------------------------------
rm -fv /etc/xdg/waybar/config.jsonc /etc/xdg/waybar/config.jsonc.rpmnew \
       /etc/xdg/waybar/style.css /etc/xdg/waybar/style.css.rpmnew \
       /etc/xdg/waybar/waybar_config_source.txt || true

# wayblue's Hyprland plugin lua. The user's ~/.config/hypr takes precedence, so
# this is cosmetic - it only avoids confusion about which lua is live.
rm -fv /usr/share/hyprland/hyprland.lua || true

# ---------------------------------------------------------------------------
# 2. Strip the theming overrides that would silently defeat Caelestia.
#
#    wayblue sets:
#        QT_STYLE_OVERRIDE=adwaita-dark
#        GTK_THEME=Adwaita:dark
#
#    QT_STYLE_OVERRIDE forces Qt apps to the Adwaita style, which bypasses
#    qtengine entirely.  The CLI writes ~/.config/qtengine/config.json to apply
#    the Darkly style + generated colour scheme; with the override in place all
#    of that work is thrown away and Qt apps stay Adwaita-dark regardless of the
#    active Caelestia colour scheme.
# ---------------------------------------------------------------------------
if [ -f /etc/environment ]; then
    sed -i -E '/^[[:space:]]*(export[[:space:]]+)?(QT_STYLE_OVERRIDE|GTK_THEME)=/d' /etc/environment
fi
for f in /etc/environment.d/*.conf; do
    [ -e "$f" ] || continue
    sed -i -E '/^[[:space:]]*(export[[:space:]]+)?(QT_STYLE_OVERRIDE|GTK_THEME)=/d' "$f"
done

# ---------------------------------------------------------------------------
# 3. Make sure the uinput kernel module is available for ydotool.
# ---------------------------------------------------------------------------
cat > /etc/modules-load.d/caelestia-uinput.conf <<'EOF'
uinput
EOF

echo "==> Caelestia: wayblue overrides applied"