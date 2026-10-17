# Troubleshooting

Manual fixes for problems that the image should handle but occasionally doesn't.
Every command here is idempotent and safe to run on a provisioned system.

## Firstboot never ran

Symptom: `systemctl status caelestia-firstboot` shows `inactive (dead)` with
`Condition: start condition unmet`. Your groups are wrong, dots are missing,
sudo is passwordless, or the update timer is not armed.

The unit carries `ConditionPathExists=!/var/lib/caelestia/provisioned`. If
the marker exists from an older image, the unit never starts.

```bash
sudo rm -f /var/lib/caelestia/provisioned
sudo systemctl restart caelestia-firstboot.service
sudo systemctl status caelestia-firstboot.service
```

## Missing input, video, render groups

On Fedora Atomic, `/etc/group` is empty by design. Groups live in
`/usr/lib/group`. `usermod` only reads `/etc/group`, so it silently fails
for any group defined only in `/usr/lib/group`.

```bash
# Copy the group definitions into the writable layer
sudo sh -c 'grep "^input:" /usr/lib/group >> /etc/group'
sudo sh -c 'grep "^video:" /usr/lib/group >> /etc/group'
sudo sh -c 'grep "^render:" /usr/lib/group >> /etc/group'

# Create uinput if it is missing (it has no packaged group)
grep -q "^uinput:" /etc/group || sudo sh -c "printf 'uinput:x:960:\n' >> /etc/group"

# Add the user
sudo usermod -aG input,video,render,uinput "$USER"

# Reload udev
sudo udevadm control --reload-rules
sudo udevadm trigger

# Log out and back in for the groups to take effect
```

Verify with `id`. `/dev/input/event*` should be group `input` mode `0660`,
`/dev/uinput` group `uinput` mode `0660`, `/dev/video*` group `video`.

## Sudo is passwordless or missing

The old image shipped a passwordless sudoers drop-in. It persists across
rebases because `/etc` is writable and not part of the ostree commit.

```bash
sudo rm -f /etc/sudoers.d/90-neo
echo "$USER ALL=(ALL) ALL" | sudo tee /etc/sudoers.d/90-neo
sudo chmod 0440 /etc/sudoers.d/90-neo
```


## Dots not deployed

`~/.config/hypr` is missing and Hyprland falls back to
`/usr/share/hyprland/hyprland.lua`, which is not shipped. The result is a
session that exits in under a second and SDDM bounces back to the login
screen.

```bash
install -d -m 0755 ~/.config/hypr
cp -a /usr/share/caelestia/dots/hypr/. ~/.config/hypr/
```

## v4l2loopback not loaded

The module is built into the image but may not be loaded:

```bash
sudo modprobe v4l2loopback
ls /dev/video*   # should show new devices
```

If `modprobe` fails with "module not found", the module was not built for
this kernel. Check with:

```bash
find /lib/modules -name "v4l2loopback.ko"
```

If nothing is found, the kernel moved and the image needs a rebuild.

## Auto-updates not working

`rpm-ostree upgrade` reports "No upgrade available" or "Old and new refs
are equal".

```bash
# Check the remote
cat /etc/ostree/remotes.d/caelestia.conf

# Check what is booted
rpm-ostree status -b

# Check whether an update exists
caelestia-update --check

# Force a fresh pull (clears rpm-ostree's container image cache)
sudo rpm-ostree cleanup
sudo rpm-ostree upgrade
```

If `caelestia-update --check` says "an update is available" but
`rpm-ostree upgrade` says "no upgrade available", the deployment origin
is pinned to an immutable tag. Rebase to `:latest` once:

```bash
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/lovel33t/caelestia-fedora:latest
sudo systemctl reboot
```

## grep behaves strangely

If `grep` is aliased to `rg` (ripgrep), standard `grep -E` flags may
fail. Use `command grep` or `\grep` to bypass the alias:

```bash
command grep -E "pattern" file
```

## Login shell is still bash

```bash
sudo usermod -s /usr/bin/zsh $USER
grep -qxF /usr/bin/zsh /etc/shells || echo /usr/bin/zsh | sudo tee -a /etc/shells
```


## caelestia-install fails on GPU detection

The installer uses `lspci` to detect NVIDIA. If `lspci` is not installed:

```bash
sudo rpm-ostree install pciutils
sudo systemctl reboot
```

For GPUs older than Turing (GTX 10xx and below), the open driver is not
supported. Fork the repo and switch the base to a closed-module image. See
the README.
