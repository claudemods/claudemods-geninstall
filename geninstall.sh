#!/bin/bash

# Gentoo Installation Script - install the running live environment to disk
# Copies the Gentoo live ISO's system (its read-only squashfs) onto the target disk instead of
# extracting a stage3 and compiling. Everything comes from the ISO: the system, the running kernel
# and its modules, and the initramfs (dracut if the live system has it, otherwise the ISO's own).
# The only download is a last resort: GRUB as a binary package if the live system has none.
set -e

# Verify root and parameters
[ "$(id -u)" -ne 0 ] && echo "Run as root!" && exit 1
[ -z "$1" ] && echo "Usage: $0 <target_disk> (e.g., /dev/sda or /dev/nvme0n1)" && exit 1

# Configuration
TARGET_DISK="$1"
SWAP_SIZE_GIB=4
TARGET=/mnt/gentoo
[ -b "$TARGET_DISK" ] || { echo "$TARGET_DISK is not a disk!"; exit 1; }

# /dev/sda -> /dev/sda1, /dev/nvme0n1 -> /dev/nvme0n1p1
case "$TARGET_DISK" in *[0-9]) P="${TARGET_DISK}p" ;; *) P="$TARGET_DISK" ;; esac
BIOS_PART="${P}1"     # 2 MiB bios_grub, lets the same disk boot on BIOS machines
EFI_PART="${P}2"      # 512 MiB EFI system partition, mounted at /boot/efi
ROOT_PART="${P}3"
SWAP_PART="${P}4"

UEFI=0
[ -d /sys/firmware/efi ] && UEFI=1
KV=$(uname -r)

# Find the live system: the read-only squashfs the live ISO runs from
LIVE_ROOT=$(awk '$3=="squashfs"{print $2}' /proc/mounts | while read -r m; do
    [ -d "$m/etc" ] && [ -d "$m/usr" ] && echo "$m" && break
done)
[ -z "$LIVE_ROOT" ] && echo "No live squashfs mounted - run this from the Gentoo live ISO!" && exit 1
[ -d "$LIVE_ROOT/lib/modules/$KV" ] || [ -d "$LIVE_ROOT/usr/lib/modules/$KV" ] || {
    echo "The live system has no modules for the running kernel $KV!"; exit 1; }

# Refuse the disk the live ISO was booted from
for dev in $(awk '$2 ~ "^/(mnt/cdrom|run/initramfs/live|mnt/livecd)" {print $1}' /proc/mounts); do
    case "$dev" in "$TARGET_DISK"*) echo "$TARGET_DISK holds the live ISO you booted from!"; exit 1 ;; esac
done

# Questions first, so the rest runs unattended
read -p "Hostname [gentoo]: " NEW_HOSTNAME
NEW_HOSTNAME="${NEW_HOSTNAME:-gentoo}"
read -p "Timezone [Europe/London]: " NEW_TZ
NEW_TZ="${NEW_TZ:-Europe/London}"
[ -f "/usr/share/zoneinfo/$NEW_TZ" ] || { echo "Unknown timezone $NEW_TZ"; exit 1; }
read -p "New user name (blank = keep the live user): " NEW_USER

# Confirmation
echo "WARNING: This will DESTROY ALL DATA on ${TARGET_DISK}!"
read -p "Continue? (y/N): " answer
[[ "$answer" != "y" && "$answer" != "Y" ]] && exit

cleanup() {
    swapoff "$SWAP_PART" 2>/dev/null || true
    umount -R "$TARGET" 2>/dev/null || true
}
trap cleanup EXIT

# Partitioning (GPT: bios_grub + ESP + root + swap at the end)
echo "Partitioning ${TARGET_DISK}..."
for p in $(awk '{print $1}' /proc/mounts | grep "^$TARGET_DISK" || true); do umount "$p" 2>/dev/null || true; done
parted -s "$TARGET_DISK" mklabel gpt
parted -s "$TARGET_DISK" mkpart bios 1MiB 3MiB
parted -s "$TARGET_DISK" set 1 bios_grub on
parted -s "$TARGET_DISK" mkpart efi fat32 3MiB 515MiB
parted -s "$TARGET_DISK" set 2 esp on
# "--" so parted does not read the negative (from the end of the disk) size as an option
parted -s -- "$TARGET_DISK" mkpart root ext4 515MiB "-${SWAP_SIZE_GIB}GiB"
parted -s -- "$TARGET_DISK" mkpart swap linux-swap "-${SWAP_SIZE_GIB}GiB" 100%
partprobe "$TARGET_DISK" 2>/dev/null || true
udevadm settle 2>/dev/null || sleep 2

# Formatting
echo "Formatting..."
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -F "$ROOT_PART"
mkswap "$SWAP_PART"
swapon "$SWAP_PART"

# Mounting
echo "Mounting..."
mkdir -p "$TARGET"
mount "$ROOT_PART" "$TARGET"
mkdir -p "$TARGET/boot/efi"
mount "$EFI_PART" "$TARGET/boot/efi"

# Copy the live system (instead of extracting a stage3)
echo "Copying the live system from ${LIVE_ROOT} (this takes a while)..."
if command -v rsync >/dev/null 2>&1; then
    rsync -aHAX --info=progress2 "$LIVE_ROOT/" "$TARGET/"
else
    cp -a "$LIVE_ROOT/." "$TARGET/"
fi
for d in proc sys dev run tmp mnt media; do mkdir -p "$TARGET/$d"; done
chmod 1777 "$TARGET/tmp"

# Kernel: the one the live ISO is running (its modules are already in the copy)
echo "Installing kernel ${KV}..."
KERNEL_SRC=""
for k in "$TARGET/boot/vmlinuz-$KV" "$TARGET/usr/lib/modules/$KV/vmlinuz" "$TARGET/lib/modules/$KV/vmlinuz" \
         /mnt/cdrom/boot/gentoo /run/initramfs/live/boot/gentoo /run/initramfs/live/boot/vmlinuz; do
    if [ -f "$k" ]; then KERNEL_SRC="$k"; break; fi
done
[ -z "$KERNEL_SRC" ] && echo "Could not find the kernel for $KV!" && exit 1
[ "$KERNEL_SRC" = "$TARGET/boot/vmlinuz-$KV" ] || cp "$KERNEL_SRC" "$TARGET/boot/vmlinuz-$KV"

# The ISO's own initramfs, used when the live system has no dracut (it boots root=UUID too)
LIVE_INITRD=""
for i in /mnt/cdrom/boot/gentoo.igz /run/initramfs/live/boot/gentoo.igz \
         /mnt/cdrom/boot/initramfs* /run/initramfs/live/boot/initramfs*; do
    if [ -f "$i" ]; then LIVE_INITRD="$i"; break; fi
done
if [ -n "$LIVE_INITRD" ]; then cp "$LIVE_INITRD" "$TARGET/root/.cdb-live-initrd"; fi

# fstab
echo "Configuring..."
uuid() { blkid -s UUID -o value "$1"; }
cat > "$TARGET/etc/fstab" << EOF
UUID=$(uuid "$ROOT_PART")	/	ext4	defaults,noatime	0 1
UUID=$(uuid "$EFI_PART")	/boot/efi	vfat	defaults,noatime,umask=0077	0 2
UUID=$(uuid "$SWAP_PART")	none	swap	sw	0 0
EOF

# Only used if GRUB is missing and has to be downloaded (binary package, no compiling)
cp /etc/resolv.conf "$TARGET/etc/" 2>/dev/null || true
mkdir -p "$TARGET/etc/portage"
grep -q '^GRUB_PLATFORMS=' "$TARGET/etc/portage/make.conf" 2>/dev/null ||
    echo 'GRUB_PLATFORMS="efi-64 pc"' >> "$TARGET/etc/portage/make.conf"

# Mount for chroot
mount -t proc /proc "$TARGET/proc"
mount --rbind /sys "$TARGET/sys"
mount --make-rslave "$TARGET/sys"
mount --rbind /dev "$TARGET/dev"
mount --make-rslave "$TARGET/dev"
mount --bind /run "$TARGET/run"
mount --make-slave "$TARGET/run"

# Chroot setup
echo "Chrooting..."
chroot "$TARGET" /bin/bash -s "$KV" "$UEFI" "$TARGET_DISK" "$NEW_HOSTNAME" "$NEW_TZ" "$NEW_USER" <<'CHROOT_EOF'
set -e
source /etc/profile
KV="$1"; UEFI="$2"; DISK="$3"; NEW_HOSTNAME="$4"; NEW_TZ="$5"; NEW_USER="$6"

# Last resort only: a live system without GRUB would leave the disk unbootable
if ! command -v grub-install >/dev/null 2>&1; then
    echo "grub-install is not on the live system, fetching sys-boot/grub (binary package)..."
    emerge-webrsync || emerge --sync
    emerge --oneshot --getbinpkg --usepkg sys-boot/grub
fi

# System configuration
echo "$NEW_HOSTNAME" > /etc/hostname
[ -f /etc/conf.d/hostname ] && sed -i "s/^hostname=.*/hostname=\"$NEW_HOSTNAME\"/" /etc/conf.d/hostname
echo "$NEW_TZ" > /etc/timezone
ln -sf "/usr/share/zoneinfo/$NEW_TZ" /etc/localtime

# A fresh machine id for the new install
rm -f /etc/machine-id /var/lib/dbus/machine-id
if command -v systemd-machine-id-setup >/dev/null 2>&1; then systemd-machine-id-setup; fi
if command -v dbus-uuidgen >/dev/null 2>&1; then dbus-uuidgen --ensure; fi

# Live-session leftovers: autologin and the livecd helper services
rm -f /etc/sddm.conf.d/*autologin* 2>/dev/null || true
for f in /etc/sddm.conf /etc/sddm.conf.d/*.conf /etc/lightdm/lightdm.conf; do
    if [ -f "$f" ]; then sed -i -E '/^(User|Session|autologin-user|autologin-session)=/d' "$f"; fi
done
for f in /etc/conf.d/agetty*; do
    if [ -f "$f" ]; then sed -i -E 's/--autologin[[:space:]]+[^[:space:]"]+//g' "$f"; fi
done
if command -v rc-update >/dev/null 2>&1; then
    for s in autoconfig fixinittab livecd; do rc-update del "$s" 2>/dev/null || true; done
fi

# Initramfs: build one with dracut if the live system has it, otherwise use the ISO's own
if command -v dracut >/dev/null 2>&1; then
    echo "Building initramfs for ${KV} with dracut..."
    dracut --force --no-hostonly --kver "$KV" "/boot/initramfs-$KV.img"
elif [ -f /root/.cdb-live-initrd ]; then
    echo "No dracut on the live system, using the ISO's initramfs..."
    cp /root/.cdb-live-initrd "/boot/initramfs-$KV.img"
else
    echo "No dracut and no initramfs on the ISO - cannot make the disk bootable!"
    exit 1
fi
rm -f /root/.cdb-live-initrd

# Bootloader (UEFI with a removable fallback, and BIOS via the bios_grub partition)
if [ "$UEFI" = 1 ]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=gentoo ||
        echo "Could not add a UEFI boot entry, using the removable EFI path only"
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable
else
    grub-install --target=i386-pc "$DISK"
fi
grub-mkconfig -o /boot/grub/grub.cfg

# Users (passwords are set after this heredoc: passwd here would read the script, not the keyboard)
if [ -n "$NEW_USER" ]; then
    if ! id "$NEW_USER" >/dev/null 2>&1; then
        useradd -m -G users,wheel,audio,video,plugdev -s /bin/bash "$NEW_USER" ||
            useradd -m -G users,wheel,audio,video -s /bin/bash "$NEW_USER"
    fi
    # The live ISO's own user is not needed any more
    for live in gentoo livecd; do
        if [ "$live" != "$NEW_USER" ] && id "$live" >/dev/null 2>&1; then userdel -r "$live" 2>/dev/null || true; fi
    done
fi
CHROOT_EOF

# Passwords, typed at the keyboard
echo "Set root password:"
chroot "$TARGET" passwd
if [ -n "$NEW_USER" ]; then
    echo "Set password for ${NEW_USER}:"
    chroot "$TARGET" passwd "$NEW_USER"
fi

# Cleanup
trap - EXIT
cleanup
echo "Installation complete! Remove the live ISO and reboot."
echo "Check remaining news items with 'eselect news list' after the first boot."
