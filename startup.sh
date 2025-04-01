#!/bin/bash
set -e

# --- Boot mode detection ---
BOOT_MODE="BIOS"
if [[ -f /sys/firmware/efi/fw_platform_size ]]; then
    EFI_BITNESS=$(cat /sys/firmware/efi/fw_platform_size)
    [[ "$EFI_BITNESS" == "64" ]] && BOOT_MODE="UEFI-64"
    [[ "$EFI_BITNESS" == "32" ]] && BOOT_MODE="UEFI-32"
fi
echo "Detected boot mode: $BOOT_MODE"

# --- Disk selection ---
echo "Available disks:"
lsblk -d -o NAME,SIZE,MODEL,TYPE | grep disk
read -rp "Enter disk to partition (e.g., sda, nvme0n1): " DISK
DEVICE="/dev/$DISK"
if [[ ! -b "/dev/$DISK" ]]; then
    echo "Invalid disk: $DISK"
    exit 1
fi

# Confirm wipe
echo "WARNING: This will erase ALL data on $DEVICE."
read -rp "Type 'yes' to confirm: " confirm
[[ "$confirm" != "yes" ]] && echo "Aborted." && exit 1

# --- RAM and partition sizes ---
RAM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print int($2 / 1024)}')
SWAP_SIZE=$((RAM_TOTAL / 2))
ESP_SIZE=512
SWAP_END=$((ESP_SIZE + SWAP_SIZE))

# --- Partition the disk ---
parted -s "$DEVICE" mklabel gpt
PART_NUM=1
if [[ "$BOOT_MODE" == UEFI* ]]; then
    parted -s "$DEVICE" mkpart primary fat32 1MiB "${ESP_SIZE}MiB"
    parted -s "$DEVICE" set $PART_NUM esp on
    ((PART_NUM++))
fi
parted -s "$DEVICE" mkpart primary linux-swap "${ESP_SIZE}MiB" "${SWAP_END}MiB"
((PART_NUM++))
parted -s "$DEVICE" mkpart primary ext4 "${SWAP_END}MiB" 100%

# --- Format partitions ---
PART_SUFFIX=""
[[ "$DISK" == nvme* ]] && PART_SUFFIX="p"

PART_NUM=1
if [[ "$BOOT_MODE" == UEFI* ]]; then
    EFI_PART="${DEVICE}${PART_SUFFIX}${PART_NUM}"
    mkfs.fat -F32 "$EFI_PART"
    ((PART_NUM++))
fi
SWAP_PART="${DEVICE}${PART_SUFFIX}${PART_NUM}"
mkswap "$SWAP_PART"
((PART_NUM++))
ROOT_PART="${DEVICE}${PART_SUFFIX}${PART_NUM}"
mkfs.ext4 "$ROOT_PART"

# --- Mount partitions ---
mount "$ROOT_PART" /mnt
[[ "$BOOT_MODE" == UEFI* ]] && mount --mkdir "$EFI_PART" /mnt/boot
swapon "$SWAP_PART"

# --- Mirror selection ---
reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# --- Base install ---
pacstrap -K /mnt base linux linux-firmware networkmanager

# --- fstab ---
genfstab -U /mnt >> /mnt/etc/fstab

# --- chroot ---
arch-chroot /mnt /bin/bash <<EOF
# Time setup
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc
systemctl enable systemd-timesyncd

# Locale
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Console keymap
echo "KEYMAP=de-latin1" > /etc/vconsole.conf

# Hostname
echo "archbox" > /etc/hostname
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1       localhost" >> /etc/hosts
echo "127.0.1.1 archbox.localdomain archbox" >> /etc/hosts

# Networking
systemctl enable NetworkManager

# Initramfs
mkinitcpio -P

# Root password
echo "Set root password:"
passwd

# GRUB installation
if [[ "$BOOT_MODE" == UEFI* ]]; then
  pacman -Sy --noconfirm grub efibootmgr
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
else
  pacman -Sy --noconfirm grub
  grub-install --target=i386-pc $DEVICE
fi

grub-mkconfig -o /boot/grub/grub.cfg

# NVIDIA drivers
# X11 and graphics stack
pacman -Sy --noconfirm xorg-server xorg-apps xorg-xinit mesa

# NVIDIA proprietary drivers
pacman -Sy --noconfirm nvidia nvidia-utils nvidia-settings
nvidia-xconfig
echo "nvidia" >> /etc/modules-load.d/nvidia.conf
EOF