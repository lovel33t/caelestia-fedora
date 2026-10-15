#!/usr/bin/env bash
# Create the groups referenced by 70-caelestia-input.rules.
# uinput has no packaged group on Fedora, so create it explicitly.
set -euo pipefail

getent group input    >/dev/null || groupadd -r input
getent group uinput   >/dev/null || groupadd -r uinput
getent group video    >/dev/null || groupadd -r video
getent group render   >/dev/null || groupadd -r render

# Make sure an already-created admin account picks up input/uinput too.
if getent group wheel >/dev/null; then
    for u in $(getent group wheel | cut -d: -f4 | tr ',' ' '); do
        [ -n "$u" ] || continue
        usermod -a -G input,uinput "$u" 2>/dev/null || true
    done
fi

echo "==> caelestia: input/uinput groups ready"