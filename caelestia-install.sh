#!/usr/bin/env bash
# caelestia-install - rebase a fresh Fedora Atomic system onto a Caelestia image.
#
# Run on a clean Fedora Silverblue/Kinoite install, BEFORE any rebase:
#
#   curl -fsSL https://raw.githubusercontent.com/lovel33t/caelestia-fedora/main/caelestia-install.sh | bash
#
# It checks that you are on Fedora Atomic, detects whether you have NVIDIA,
# AMD, or both, and picks the right image. On NVIDIA it verifies open-driver
# support (Turing or newer). On AMD it uses the default image. Dual-GPU
# laptops (AMD + NVIDIA) assume NVIDIA.
set -euo pipefail

DRY_RUN=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --force)   FORCE=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if ! command -v rpm-ostree >/dev/null 2>&1; then
    echo "This is not a Fedora Atomic system (rpm-ostree missing)." >&2
    exit 1
fi

# --- GPU detection -----------------------------------------------------------
NVIDIA=0; AMD=0
if command -v lspci >/dev/null 2>&1; then
    lspci_out=$(lspci -nn 2>/dev/null || true)
    echo "$lspci_out" | grep -qi "nvidia"  && NVIDIA=1
    echo "$lspci_out" | grep -qiE "amd|ati" && AMD=1
fi

# Dual-GPU laptops (Intel/AMD iGPU + NVIDIA dGPU): assume NVIDIA.
if [ "$NVIDIA" = 1 ] && [ "$AMD" = 1 ]; then
    echo "Dual GPU detected (AMD + NVIDIA). Assuming NVIDIA as the primary."
    AMD=0
fi

if [ "$NVIDIA" = 1 ]; then
    name=$(lspci 2>/dev/null | grep -i nvidia | head -1)
    if echo "$name" | grep -qiE "RTX|GTX 16|Quadro (RTX|T[0-9])|Tesla (T4|V100|A100)|A[0-9]{2,3}"; then
        IMAGE="caelestia-fedora"
        echo "NVIDIA GPU with open-driver support: $name"
    else
        echo "NVIDIA GPU detected but it may not support the open driver:" >&2
        echo "  $name" >&2
        echo "Open driver support starts at Turing (GTX 16xx / RTX 20xx)." >&2
        echo "For older cards, fork this repo and switch the base to a" >&2
        echo "closed-module image. See the README." >&2
        exit 1
    fi
else
    IMAGE="caelestia-fedora-hyprland"
    echo "No NVIDIA GPU detected. Using the default (non-NVIDIA) image."
fi

REG="ostree-image-signed:docker://ghcr.io/lovel33t/$IMAGE:latest"
echo "Target: $REG"

if [ "$DRY_RUN" = 1 ]; then
    echo "Dry run: no changes made."
    exit 0
fi

if [ "$FORCE" != 1 ]; then
    printf "Proceed with rebase to %s? [y/N] " "$REG"
    read -r ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "Aborted."; exit 0; }
fi

sudo rpm-ostree rebase "ostree-unverified-registry:ghcr.io/lovel33t/$IMAGE:latest"
echo "Reboot to complete the first rebase."
echo "Then run again to switch to the signed image:"
echo "  sudo rpm-ostree rebase $REG"
echo "  sudo systemctl reboot"
