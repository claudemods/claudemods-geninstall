#!/bin/bash

# Gentoo Installation Script - Corrected Version
# This script automates the installation of Gentoo Linux with:
# - FAT32 boot partition (for UEFI systems)
# - EXT4 root partition
# - Basic system configuration

# Safety checks and setup
set -e  # Exit on error
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root!"
    exit 1
fi

if [ -z "$1" ]; then
    echo "Usage: $0 <target_disk> (e.g., /dev/sda)"
    exit 1
fi

TARGET_DISK="$1"
BOOT_PART="${TARGET_DISK}1"
ROOT_PART="${TARGET_DISK}2"
SWAP_PART="${TARGET_DISK}3"  # Optional swap partition

# Verify disk exists
if [ ! -e "$TARGET_DISK" ]; then
    echo "Disk $TARGET_DISK does not exist!"
    exit 1
fi

# Confirm with user
echo "WARNING: This will erase ALL data on $TARGET_DISK!"
echo -n "Are you sure you want to continue? (y/N) "
read -r answer
if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
    echo "Aborting installation."
    exit 1
fi

# Create directory structure
mkdir -p /mnt/gentoo

# Set up partitions
echo "Partitioning $TARGET_DISK..."
parted -s "$TARGET_DISK" mklabel gpt
parted -s "$TARGET_DISK" mkpart primary fat32 1MiB 513MiB
parted -s "$TARGET_DISK" set 1 esp on
parted -s "$TARGET_DISK" mkpart primary ext4 513MiB 20GiB
parted -s "$TARGET_DISK" mkpart primary linux-swap 20GiB 24GiB

# Format partitions
echo "Formatting partitions..."
mkfs.fat -F32 "$BOOT_PART"
mkfs.ext4 -F "$ROOT_PART"
mkswap "$SWAP_PART"
swapon "$SWAP_PART"

# Mount partitions
echo "Mounting partitions..."
mount "$ROOT_PART" /mnt/gentoo
mkdir -p /mnt/gentoo/boot
mount "$BOOT_PART" /mnt/gentoo/boot

# Get latest stage3 URL
echo "Fetching latest stage3 URL..."
STAGE3_BASE_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds"
LATEST_STAGE3=$(curl -s "${STAGE3_BASE_URL}/latest-stage3-amd64-openrc.txt" | grep -v "^#" | awk '{print $1}')
STAGE3_URL="${STAGE3_BASE_URL}/${LATEST_STAGE3}"
STAGE3_FILENAME=$(basename "$LATEST_STAGE3")

# Download and extract stage3
echo "Downloading stage3 tarball..."
cd /mnt/gentoo || exit
wget "$STAGE3_URL"
if [ ! -f "$STAGE3_FILENAME" ]; then
    echo "Failed to download stage3 tarball!"
    exit 1
fi

echo "Extracting stage3..."
tar xpvf "$STAGE3_FILENAME" --xattrs-include='*.*' --numeric-owner
if [ $? -ne 0 ]; then
    echo "Failed to extract stage3 tarball!"
    exit 1
fi

# Configure make.conf
echo "Configuring make.conf..."
mkdir -p /mnt/gentoo/etc/portage
CPU_FLAGS=$(cpuid2cpuflags 2>/dev/null | cut -d: -f2 || echo "")
NUM_JOBS=$(nproc)

cat > /mnt/gentoo/etc/portage/make.conf << EOF
COMMON_FLAGS="-O2 -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"

MAKEOPTS="-j${NUM_JOBS}"
${CPU_FLAGS:+CPU_FLAGS_X86="${CPU_FLAGS}"}

# Mirrors
GENTOO_MIRRORS="https://gentoo.osuosl.org/ https://mirrors.rit.edu/gentoo/ https://gentoo.mirrors.evowise.com/"

# Features
FEATURES="parallel-fetch parallel-install candy"
EMERGE_DEFAULT_OPTS="--jobs=${NUM_JOBS} --load-average=$(nproc)"

# Portage
PORTAGE_TMPDIR="/var/tmp"
EOF

# DNS config
echo "Copying DNS info..."
mkdir -p /mnt/gentoo/etc
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

# Mount necessary filesystems
echo "Mounting proc/sys/dev..."
mkdir -p /mnt/gentoo/proc /mnt/gentoo/sys /mnt/gentoo/dev
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev

# Chroot into the new environment
echo "Chrooting into the new system..."
cat << EOF | chroot /mnt/gentoo /bin/bash
#!/bin/bash

set -e  # Exit on error

# Basic system setup
source /etc/profile
export PS1="(chroot) \$PS1"

# Update portage tree
emerge-webrsync || emerge --sync

# Select profile
eselect profile set default/linux/amd64/17.1

# Timezone (change as needed)
echo "America/New_York" > /etc/timezone
emerge --config sys-libs/timezone-data

# Locale (change as needed)
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set en_US.utf8
env-update && source /etc/profile

# Install kernel sources
emerge sys-kernel/gentoo-sources sys-kernel/linux-firmware

# Install genkernel
emerge sys-kernel/genkernel

# Configure and compile kernel
cd /usr/src/linux
genkernel all --menuconfig --kernel-config=/proc/config.gz --install

# Install necessary tools
emerge app-admin/sysklogd sys-process/cronie net-misc/dhcpcd

# Install GRUB bootloader
emerge sys-boot/grub
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Gentoo
grub-mkconfig -o /boot/grub/grub.cfg

# Set root password
echo "Set root password:"
passwd

# Enable services
rc-update add sysklogd default
rc-update add cronie default
rc-update add dhcpcd default

# Clean up
emerge --depclean
EOF

# Final steps
echo "Installation complete!"
umount -R /mnt/gentoo
echo "You can now reboot into your new Gentoo system."
echo "Don't forget to:"
echo "1. Create a user account (useradd -m -G users,wheel,audio,video username)"
echo "2. Configure your network if needed"
echo "3. Install any additional packages you need"
