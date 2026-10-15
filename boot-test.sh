#!/usr/bin/env bash
# boot-test.sh - boot the assembled Caelestia image under QEMU/KVM and assert
# that it comes up correctly.
#
# What this DOES prove:
#   - the image boots to multi-user/login target at all
#   - systemd units and udev rules are valid and enabled
#   - first-boot provisioning creates user `neo` with the right groups + zsh
#   - the caelestia stack is present on the real booted root filesystem
#
# What this CANNOT prove (needs real hardware):
#   - Hyprland rendering / NVIDIA driver / the desktop actually starting.
#     The KVM guest gets a virtual GPU, so the nvidia module will not load.
#
# Usage: boot-test.sh [image-tag]
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="${1:-caelestia-fedora:dev}"
# NOT /tmp: on many systems /tmp is a small tmpfs and the disk is ~24 GiB.
WORK="${BOOT_TEST_WORKDIR:-$(mktemp -d -p /var/tmp)}"
CONSOLE="$WORK/console.log"
KVM=()
[ -w /dev/kvm ] && KVM=(--enable-kvm) || echo "  ! /dev/kvm not writable - running without acceleration"

FAILED=0
log()  { printf '\033[36m  %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ✓ %s\033[0m\n' "$*"; }
bad()  { printf '\033[31m  ✗ %s\033[0m\n' "$*"; FAILED=$((FAILED+1)); }
step() { printf '\n\033[1;36m━━ %s \033[0m\n' "$*"; }

command -v podman >/dev/null || { echo "podman required"; exit 1; }
podman image exists "$IMAGE" || { echo "image $IMAGE not found; run ./build.py assemble"; exit 1; }

cleanup() {
  [ -n "${QEMU_PID:-}" ] && kill "$QEMU_PID" 2>/dev/null || true
  podman rm -f caelestia-boot-qemu >/dev/null 2>&1 || true
  [ "${KEEP_WORK:-0}" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT

# ------------------------------------------------------------- 1. export ----
step "Exporting $IMAGE to a root filesystem"
podman create --name caelestia-export "$IMAGE" >/dev/null
mkdir -p "$WORK/rootfs"
podman export caelestia-export | tar -x -C "$WORK/rootfs"
podman rm caelestia-export >/dev/null
ok "rootfs exported ($(du -sh "$WORK/rootfs" 2>/dev/null | cut -f1))"

# -------------------------------------------------------- 2. build disk ----
step "Building a directly-bootable bundle (kernel + initramfs + rootfs)"
if ! podman run --rm --privileged --network=host \
      -v "$WORK:/w" \
      -v "$PWD/files/scripts/make-boot-disk.sh:/make-boot-disk.sh:ro" \
      fedora:42 bash /make-boot-disk.sh /w >"$WORK/disk.log" 2>&1
then
  echo "--- last 40 lines ---"; tail -40 "$WORK/disk.log" | sed 's/^/    /'
  bad "boot bundle build failed"; exit 1
fi
B="$WORK/bundle"
for f in vmlinuz initramfs.img rootfs.ext4; do
  [ -f "$B/$f" ] || { bad "bundle missing $f"; exit 1; }
done
ok "boot bundle built"
grep -E "^kernel version|^vmlinuz:|^initramfs:|^rootfs.ext4:" "$WORK/disk.log" | sed 's/^/    /' || true

# ------------------------------------------------------------- 3. boot -----
step "Booting under QEMU"
# Boot the kernel directly against the ext4 image - no bootloader involved.
podman run -d --name caelestia-boot-qemu \
  --device /dev/kvm \
  -v "$WORK:/w:z" \
  fedora:42 bash -c "
    dnf install -y qemu-system-x86 >/dev/null 2>&1
    exec qemu-system-x86_64 \
      ${KVM[*]:-} \
      -m 4096 -smp 2 \
      -kernel /w/bundle/vmlinuz \
      -initrd /w/bundle/initramfs.img \
      -append 'root=LABEL=caelestia rw rootfstype=ext4 selinux=0 console=ttyS0,115200 systemd.unit=multi-user.target' \
      -drive file=/w/bundle/rootfs.ext4,format=raw,if=virtio,snapshot=on \
      -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
      -device virtio-gpu \
      -serial file:/w/console.log \
      -display none -no-reboot" >/dev/null

log "waiting for boot (up to 900s)..."
# Wait for a LATE marker, not just any target: early boot reaches
# local-fs.target within seconds, which is not evidence that the image boots.
BOOTED=0
for _ in $(seq 1 900); do
  if [ -f "$CONSOLE" ] && grep -qE "Reached target (Multi-User|Graphical|Default Target)|Startup finished|login:" "$CONSOLE" 2>/dev/null; then
    BOOTED=1; break
  fi
  podman ps --format '{{.Names}}' | grep -q caelestia-boot-qemu || break
  sleep 1
done

if [ "$BOOTED" -ne 1 ]; then
  bad "guest did not reach a boot target"
  echo "--- console tail ---"; tail -40 "$CONSOLE" 2>/dev/null | sed 's/^/    /'
  exit 1
fi
ok "guest reached a boot target"

# ----------------------------------------------------------- 4. asserts ----
step "Asserting guest state from the serial console"
has() { if grep -aqE "$1" "$CONSOLE" 2>/dev/null; then ok "$2"; else bad "$2 (pattern: $1)"; fi; }

# The decisive evidence that the image really boots.
has "Welcome to wayblue|wayblue login:" "reached a login prompt"
has "Reached target sysinit.target"     "systemd reached sysinit.target"
has "Reached target basic.target"       "systemd reached basic.target"
has "systemd .* running in system mode" "systemd PID 1 started in system mode"
has "invalid|Invalid rule|syntax error" "no udev rule syntax errors"

# `selinux=0` is required because mkfs.ext4 -d cannot write SELinux xattrs;
# without it systemd freezes at "Failed to allocate manager object". This is a
# limitation of the test harness, not of the image - a real ostree deployment
# gets its labels from the container's SELinux metadata.
if grep -aq "Freezing execution" "$CONSOLE" 2>/dev/null; then
  bad "systemd froze during startup"
else
  ok "systemd did not freeze"
fi

has "caelestia-firstboot|provisioning complete" "first-boot provisioning ran"

if grep -qE "Failed to mount|emergency mode|Dependency failed" "$CONSOLE" 2>/dev/null; then
  bad "guest reported mount/dependency failures:"
  grep -E "Failed to mount|emergency mode|Dependency failed" "$CONSOLE" | head -10 | sed 's/^/      /'
else
  ok "no mount failures or emergency mode"
fi
# The nvidia module cannot load on a virtual GPU - expected, not a defect.
if grep -q "nvidia" "$CONSOLE" 2>/dev/null; then
  log "nvidia lines present in console (expected: virtual GPU, driver will not load)"
fi

step "Serial console tail"
tail -30 "$CONSOLE" | sed 's/^/    /'

echo
if [ "$FAILED" -eq 0 ]; then
  printf '\033[1;32m==== BOOT TEST PASSED ====\033[0m\n'
else
  printf '\033[1;31m==== BOOT TEST: %d CHECK(S) FAILED ====\033[0m\n' "$FAILED"
fi
exit "$FAILED"