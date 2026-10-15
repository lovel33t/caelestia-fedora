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
chsh -l "$USERNAME" -s "$LOGIN_SHELL" 2>/dev/null || true

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

mkdir -p "$(dirname "$MARKER")"
touch "$MARKER"
echo "==> provisioning complete"