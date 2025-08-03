#!/bin/bash

# Gentoo Installation Script - Local Stage3 Version
set -e

# Verify root
[ "$(id -u)" -ne 0 ] && echo "Run as root!" && exit 1
[ -z "$1" ] && echo "Usage: $0 <target_disk> (e.g., /dev/sda)" && exit 1

# Configuration
TARGET_DISK="$1"
BOOT_PART="${TARGET_DISK}1"
ROOT_PART="${TARGET_DISK}2"
SWAP_PART="${TARGET_DISK}3"

# Find local stage3
STAGE3_FILE=$(ls stage3-*.tar.xz 2>/dev/null | head -n1)
[ -z "$STAGE3_FILE" ] && echo "No stage3 tarball found!" && exit 1

# Confirmation
echo "WARNING: This will DESTROY ALL DATA on ${TARGET_DISK}!"
read -p "Continue? (y/N): " answer
[[ "$answer" != "y" && "$answer" != "Y" ]] && exit

# Partitioning
echo "Partitioning ${TARGET_DISK}..."
parted -s "$TARGET_DISK" mklabel gpt
parted -s "$TARGET_DISK" mkpart primary fat32 1MiB 513MiB
parted -s "$TARGET_DISK" set 1 esp on
parted -s "$TARGET_DISK" mkpart primary ext4 513MiB 20GiB
parted -s "$TARGET_DISK" mkpart primary linux-swap 20GiB 24GiB

# Formatting
echo "Formatting..."
mkfs.fat -F32 "$BOOT_PART"
mkfs.ext4 -F "$ROOT_PART"
mkswap "$SWAP_PART"
swapon "$SWAP_PART"

# Mounting
echo "Mounting..."
mkdir -p /mnt/gentoo
mount "$ROOT_PART" /mnt/gentoo
mkdir -p /mnt/gentoo/boot
mount "$BOOT_PART" /mnt/gentoo/boot

# Extract stage3
echo "Extracting ${STAGE3_FILE}..."
tar xpf "$STAGE3_FILE" -C /mnt/gentoo --xattrs-include='*.*' --numeric-owner

# Configure system
echo "Configuring..."
cat > /mnt/gentoo/etc/portage/make.conf << EOF
COMMON_FLAGS="-O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
MAKEOPTS="-j$(nproc)"
GENTOO_MIRRORS="https://gentoo.osuosl.org/"
FEATURES="parallel-fetch parallel-install"
EOF

cp /etc/resolv.conf /mnt/gentoo/etc/

# Mount for chroot
mount -t proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev

# Chroot setup
echo "Chrooting..."
chroot /mnt/gentoo /bin/bash <<'CHROOT_EOF'
set -e
source /etc/profile

# Basic setup
emerge-webrsync
eselect profile set default/linux/amd64/17.1
echo "America/New_York" > /etc/timezone
emerge --config sys-libs/timezone-data
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.utf8
env-update && source /etc/profile

# Kernel and tools
emerge sys-kernel/gentoo-sources sys-kernel/genkernel linux-firmware
cd /usr/src/linux
genkernel all --install

# Bootloader
emerge sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/boot
grub-mkconfig -o /boot/grub/grub.cfg

# Final setup
passwd
emerge app-admin/sysklogd sys-process/cronie net-misc/dhcpcd
rc-update add sysklogd default
rc-update add cronie default
rc-update add dhcpcd default
emerge --depclean
CHROOT_EOF

# Cleanup
umount -R /mnt/gentoo
echo "Installation complete! Reboot when ready."
