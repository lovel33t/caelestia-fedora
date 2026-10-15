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

mkdir -p "$(dirname "$MARKER")"
touch "$MARKER"
echo "==> provisioning complete"