#!/usr/bin/env bash
# First-boot provisioning for the Caelestia image.
#
# Creates the primary user, grants input/uinput access, switches the login
# shell to zsh and seeds /etc/skel.  Runs once as a systemd oneshot.

set -euo pipefail

readonly USERNAME="${CAELESTIA_USERNAME:-neo}"
readonly FULLNAME="${CAELESTIA_FULLNAME:-Caelestia User}"
readonly LOGIN_SHELL="${CAELESTIA_SHELL:-/usr/bin/zsh}"
readonly MARKER=/var/lib/caelestia/provisioned

[ -f "$MARKER" ] && { echo "already provisioned"; exit 0; }

if ! id -u "$USERNAME" >/dev/null 2>&1; then
    echo "==> creating user $USERNAME"
    useradd -m -G wheel,video,render,input,uinput,networkmanager,bluetooth \
            -s "$LOGIN_SHELL" -c "$FULLNAME" "$USERNAME"
    # wheel -> passwordless sudo via the sudoers drop-in below
    install -d -m 0700 -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.ssh"

    # Generate an SSH keypair so the account is usable immediately.
    sudo -u "$USERNAME" ssh-keygen -q -t ed25519 -N '' \
        -f "/home/$USERNAME/.ssh/id_ed25519" 2>/dev/null || true

    # Seed the Caelestia dotfiles into the account's XDG config.
    echo "==> seeding /home/$USERNAME/.config"
    install -d -m 0755 -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.config"

    # Star the version-controlled files so system upgrades cannot clobber them.
    if [ -d /etc/caelestia-dots ]; then
        install -d -m 0755 -o "$USERNAME" -g "$USERNAME" "/home/$USERNAME/.local/state/caelestia"
        echo "/etc/caelestia-dots" > "/home/$USERNAME/.local/state/caelestia/dots-path"
    fi
fi

# Passwordless sudo for the primary user.
install -d -m 0750 -o root -g wheel /etc/sudoers.d
printf 'Defaults:%s !requiretty\n%s ALL=(ALL) NOPASSWD: ALL\n' "$USERNAME" "$USERNAME" \
    > "/etc/sudoers.d/90-$USERNAME"
chmod 0440 "/etc/sudoers.d/90-$USERNAME"

# zsh as the default shell for anyone created later by the display manager.
# It must also be listed in /etc/shells or the display manager treats it as a
# non-login shell and the session falls back to bash.
grep -qxF "$LOGIN_SHELL" /etc/shells 2>/dev/null || \
    printf '%s\n' "$LOGIN_SHELL" >> /etc/shells
chsh -l "$USERNAME" -s "$LOGIN_SHELL" 2>/dev/null || true

# polkit-gnome no longer exists in Fedora 44, but the dots exec its agent by
# that exact path. Give them hyprpolkitagent under the name they expect.
if [ -x /usr/bin/hyprpolkitagent ] && [ ! -e /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 ]; then
    install -d /usr/lib/polkit-gnome
    ln -sf /usr/bin/hyprpolkitagent /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
fi

# Bibata is not packaged for Fedora, so the image ships it from the upstream
# release instead. It installs to /usr/share/icons/Bibata-Modern-Ice.
CURSOR_THEME="${CAELESTIA_CURSOR:-Bibata-Modern-Ice}"

# --- provisioning that must also run for a PRE-EXISTING account -------------
# The original version did all of this inside the useradd branch, so an account
# that already existed (the common case after a rebase) got nothing. The two
# things below are what actually decide whether the user can log in at all.
HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"
[ -d "$HOME_DIR" ] || { echo "no home for $USERNAME"; exit 0; }

install -d -m 0755 -o "$USERNAME" -g "$USERNAME" "$HOME_DIR/.config"

# hyprland.lua does `maybe_create(~/.config/caelestia/hypr-vars.lua)` and then
# `require("hypr-vars")`. maybe_create cannot create the file when the parent
# directory is missing, so the require throws, Hyprland drops into emergency
# mode and registers NO keybinds, no animations and no theme.
install -d -m 0755 -o "$USERNAME" -g "$USERNAME" "$HOME_DIR/.config/caelestia"
# The dots default cursorTheme to "sweet-cursors", which is not shipped, so
# hyprctl setcursor silently fails and XWayland/Qt apps get no cursor. hypr-
# vars.lua is the documented override point and is never touched by updates.
if [ ! -f "$HOME_DIR/.config/caelestia/hypr-vars.lua" ]; then
    cat > "$HOME_DIR/.config/caelestia/hypr-vars.lua" <<EOF
return {
    cursorTheme = "$CURSOR_THEME",
    cursorSize  = 24,
}
EOF
fi
for f in hypr-vars.lua hypr-user.lua; do
    [ -f "$HOME_DIR/.config/caelestia/$f" ] || \
        printf 'return {}\n' > "$HOME_DIR/.config/caelestia/$f"
    chown "$USERNAME:$USERNAME" "$HOME_DIR/.config/caelestia/$f" 2>/dev/null || true
done

# starthyprland runs `hyprland -- -c ~/.config/hypr/hyprland.lua` when that file
# exists and otherwise falls back to /usr/share/hyprland/hyprland.lua, which is
# NOT shipped. With neither present Hyprland exits instantly and SDDM appears
# to reject the password.
if [ ! -f "$HOME_DIR/.config/hypr/hyprland.lua" ] && [ -d /usr/share/caelestia/dots/hypr ]; then
    echo "==> deploying hyprland dots"
    install -d -m 0755 -o "$USERNAME" -g "$USERNAME" "$HOME_DIR/.config/hypr"
    cp -a /usr/share/caelestia/dots/hypr/. "$HOME_DIR/.config/hypr/"
    chown -R "$USERNAME:$USERNAME" "$HOME_DIR/.config/hypr"
fi

# Wallpaper + shell preset. Without shell.json the shell's background module
# stays disabled and the desktop is flat black.
install -d -m 0755 -o "$USERNAME" -g "$USERNAME" "$HOME_DIR/Pictures/Wallpapers"
if [ -f /usr/share/backgrounds/caelestia-default.png ] && \
   [ ! -e "$HOME_DIR/Pictures/Wallpapers/caelestia-default.png" ]; then
    install -m 0644 -o "$USERNAME" -g "$USERNAME" \
        /usr/share/backgrounds/caelestia-default.png \
        "$HOME_DIR/Pictures/Wallpapers/caelestia-default.png"
fi
if [ ! -f "$HOME_DIR/.config/caelestia/shell.json" ]; then
    cat > "$HOME_DIR/.config/caelestia/shell.json" <<'JSON'
{
    "background": {
        "enabled": true,
        "wallpaperEnabled": true
    },
    "paths": {
        "wallpaperDir": "~/Pictures/Wallpapers"
    },
    "general": {
        "apps": {
            "audio": ["pavucontrol"]
        }
    },
    "appearance": {
        "transparency": {
            "enabled": true,
            "base": 0.9,
            "layers": 0.5
        }
    }
}
JSON
    chown "$USERNAME:$USERNAME" "$HOME_DIR/.config/caelestia/shell.json" 2>/dev/null || true
fi

# --- automatic updates -------------------------------------------------------
# The image ships no ostree remote, so `rpm-ostree upgrade` has nothing to pull
# from. Point one at the published image and turn on the daily timer so
# upgrades arrive without the user doing anything.
CAELESTIA_REF="${CAELESTIA_REF:-ostree-image-signed:docker://ghcr.io/lovel33t/caelestia-fedora-hyprland:latest}"
if [ ! -f /etc/ostree/remotes.d/caelestia.conf ]; then
    install -d -m 0755 /etc/ostree/remotes.d
    printf '[caelestia]\nurl=%s\ngpg-verify=false\n' "$CAELESTIA_REF" \
        > /etc/ostree/remotes.d/caelestia.conf
    chmod 0644 /etc/ostree/remotes.d/caelestia.conf
    echo "==> ostree remote 'caelestia' -> $CAELESTIA_REF"
fi

# The image policy (ostree-image-signed) still enforces signature checks; this
# per-remote flag only stops ostree demanding GPG for the container ref itself.
#
# There is no rpm-ostree-upgrade.timer on Fedora Atomic (verified: the shipped
# units are rpm-ostree-countme, rpm-ostree-bootstatus, rpm-ostreed-automatic),
# so enabling one silently did nothing. caelestia-upgrade.timer ships with the
# image and does the same job.
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now caelestia-upgrade.timer 2>/dev/null || true
    systemctl enable --now rpm-ostreed-automatic.timer 2>/dev/null || true
fi

mkdir -p "$(dirname "$MARKER")"
touch "$MARKER"

# --- per-user session setup (run as the user so dconf lands in their DB) ------
if [ -d "$HOME_DIR" ]; then
    su -l "$USERNAME" -c "gsettings set org.gnome.desktop.interface cursor-theme '$CURSOR_THEME'" 2>/dev/null || true
    su -l "$USERNAME" -c "gsettings set org.gnome.desktop.interface cursor-size 24" 2>/dev/null || true
    # GTK4 / libadwaita read this one instead.
    su -l "$USERNAME" -c "gsettings set org.gnome.desktop.interface legacy-cursor-scaling false" 2>/dev/null || true
    cat > "$HOME_DIR/.config/gtkrc-3.0" <<EOF
gtk-cursor-theme-name="$CURSOR_THEME"
gtk-cursor-size=24
EOF
    cat > "$HOME_DIR/.config/gtkrc-4.0" <<EOF
gtk-cursor-theme-name="$CURSOR_THEME"
gtk-cursor-size=24
EOF
    chown -R "$USERNAME:$USERNAME" "$HOME_DIR/.config/gtkrc-3.0" "$HOME_DIR/.config/gtkrc-4.0" 2>/dev/null || true
fi

echo "==> provisioning complete"