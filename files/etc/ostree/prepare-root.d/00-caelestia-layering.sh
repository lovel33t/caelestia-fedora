#!/bin/bash
# Layer packages that should exist on every deployment, on top of the
# ostree image.
#
# rpm-ostree runs this once per deployment with the new root mounted at $1.
# Packages installed this way survive rebases, which packages installed by
# hand with `rpm-ostree install` do not.
set -euo pipefail

ROOT="${1:?usage: prepare-root <rootdir>}"
# These are Fedora package names, not command names. The editor is `neovim`;
# there is no `nvim` package, and a name that does not resolve fails the
# entire deployment.
PKGS="e2fsprogs util-linux gdisk smartmontools neovim"

# Fail loudly on a typo rather than silently layering a partial set.
missing=""
for p in $PKGS; do
    rpm -q "$p" >/dev/null 2>&1 || \
        rpm --root "$ROOT" -q "$p" >/dev/null 2>&1 || missing="$missing $p"
done
if [ -n "$missing" ]; then
    echo "  !! not resolvable:$missing" >&2
    exit 1
fi

rpm-ostree install --apply-live --idempotent \
    --root="$ROOT" $PKGS 2>&1 | sed 's/^/  /'
