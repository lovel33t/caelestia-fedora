#!/usr/bin/env bash
# Inside a privileged container: turn the exported Caelestia rootfs into a
# directly-bootable bundle (kernel + initramfs + ext4 root image).
#
# Fedora Atomic *container* images ship kernel modules but no vmlinuz and no
# bootloader - those normally come from the ostree deployment that `bootc image
# build` creates. That subcommand is unavailable here (and it would need
# loop devices, which are not exposed in this container), so we skip the disk
# partitioning and bootloader entirely and let QEMU boot the kernel directly:
#
#   mkfs.ext4 -d  populates a filesystem image straight from a directory, so
#               no loop device and no mount is required.
#   qemu -kernel -initrd  boots straight to the root image via root=LABEL=.
set -euxo pipefail

WORK="${1:?workdir}"
ROOTFS="$WORK/rootfs"
OUT="$WORK/bundle"
mkdir -p "$OUT"

echo "### 0. install tooling in the BUILD container (not the target rootfs) ###"
# mkfs.ext4 -d and the rest run in this container, so they need e2fsprogs here.
dnf install -y --setopt=install_weak_deps=False e2fsprogs >/dev/null 2>&1

echo "### 1. install a kernel + initramfs tooling into the rootfs ###"
dnf install -y --setopt=install_weak_deps=False \
    --installroot="$ROOTFS" \
    kernel-core >/dev/null 2>&1

echo "### 2. locate the kernel image ###"
# Search every module dir for a vmlinuz rather than assuming the newest dir
# has one: the image ships module trees for host kernels with no vmlinuz.
KVER=""
for d in $(ls -1 "$ROOTFS/usr/lib/modules" 2>/dev/null | sort -Vr); do
    if [ -f "$ROOTFS/usr/lib/modules/$d/vmlinuz" ]; then KVER="$d"; break; fi
done
if [ -z "$KVER" ]; then
    echo "!! no vmlinuz in any module dir:"; ls -1 "$ROOTFS/usr/lib/modules"
    exit 1
fi
echo "kernel version: $KVER"
cp "$ROOTFS/usr/lib/modules/$KVER/vmlinuz" "$OUT/vmlinuz"
echo "vmlinuz: $(du -h "$OUT/vmlinuz" | cut -f1)"

echo "### 3. build the initramfs with the virtio/ext4 drivers ###"
# The root lives on a virtio block device, so the initramfs must be able to
# mount it without any hardware detection. Build *inside* the chroot - a
# destination under /w is not visible from inside the chroot - then move it out.
chroot "$ROOTFS" /usr/bin/dracut \
    --force --no-hostonly --kver "$KVER" \
    --add-drivers "virtio_blk virtio_pci virtio_scsi ext4" \
    /boot/initramfs.img "$KVER"
mv "$ROOTFS/boot/initramfs.img" "$OUT/initramfs.img"
echo "initramfs: $(du -h "$OUT/initramfs.img" | cut -f1)"

echo "### 4. fstab for the label-based root ###"
printf 'LABEL=caelestia / ext4 defaults 0 1\n' > "$ROOTFS/etc/fstab"
mkdir -p "$ROOTFS"/{dev,proc,sys,run,tmp,boot}
chmod 1777 "$ROOTFS/tmp"

echo "### 5. build the ext4 root image straight from the directory ###"
# -d populates the filesystem from a directory: no loop device, no mount.
truncate -s 16G "$OUT/rootfs.ext4"
mkfs.ext4 -F -L caelestia -d "$ROOTFS" "$OUT/rootfs.ext4" >/dev/null
echo "rootfs.ext4: $(du -h "$OUT/rootfs.ext4" | cut -f1)"

echo "### bundle ready: $(ls -1 "$OUT" | tr '\n' ' ')"