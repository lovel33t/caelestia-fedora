#!/bin/bash
# Layer packages that should exist on every deployment, on top of the
# ostree image.
#
# rpm-ostree runs this once per deployment with the new root mounted at $1.
# Packages installed this way survive rebases, which packages installed by
# hand with `rpm-ostree install` do not.
set -euo pipefail

ROOT="${1:?usage: prepare-root <rootdir>}"
PKGS="e2fsprogs util-linux gdisk smartmontools nvim"

rpm-ostree install --apply-live --idempotent \
    --root="$ROOT" $PKGS 2>&1 | sed 's/^/  /'
