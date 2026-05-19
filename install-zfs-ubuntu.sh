#!/usr/bin/env bash
# install-zfs-ubuntu.sh
# Debootstrap Ubuntu 26.04 (Resolute) onto two NVMe disks as a ZFS mirror.
# Run from a live Ubuntu session: sudo bash install-zfs-ubuntu.sh
set -euo pipefail

#══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION — adjust before running
#══════════════════════════════════════════════════════════════════════════════
# Block-device paths and their stable by-id names (without -partN suffix).
# Find them with: ls -l /dev/disk/by-id/ | grep -v part
DISK1=/dev/nvme0n1
DISK2=/dev/nvme1n1
DISK1_ID=""
DISK2_ID=""

# Identity of the installed system
NEW_HOSTNAME=""
USERNAME=""
# Suffix for the per-user dataset names (e.g. ${USERNAME}_${USER_SUFFIX} →
# rpool/USERDATA/alice_myserver). Defaults to NEW_HOSTNAME if left empty.
USER_SUFFIX=""

# Login credentials installed for $USERNAME.
# USER_PASSWORD is required (used for login if SSH_PUBKEY is unset, and always
# used by sudo). SSH_PUBKEY is optional.
SSH_PUBKEY=""    # optional; e.g. "ssh-ed25519 AAAA... you@host"
USER_PASSWORD="" # required; plain text, hashed at install time and written via chpasswd -e.
                 # Leave blank to be prompted interactively (entered twice for confirmation).

UBUNTU_CODENAME=resolute   # 26.04 LTS "Resolute Raccoon"
UBUNTU_MIRROR=http://archive.ubuntu.com/ubuntu
TIMEZONE=UTC

# Hostnames that this script MUST refuse to install onto. Add your production
# servers here so an accidentally-set CURRENT_HOSTNAME doesn't trigger a wipe.
BLOCKED_HOSTNAMES=()

BPOOL=bpool
RPOOL=rpool
MNT=/mnt/install

#══════════════════════════════════════════════════════════════════════════════
# Helpers
#══════════════════════════════════════════════════════════════════════════════
info()  { echo ">>> $*"; }
fatal() { echo "FATAL: $* (line ${BASH_LINENO[0]})" >&2; exit 1; }

unmount_all() {
    for mp in \
        "$MNT/sys/firmware/efi/efivars" \
        "$MNT/dev/pts" \
        "$MNT/dev" \
        "$MNT/sys" \
        "$MNT/proc" \
        "$MNT/boot/efi"
    do
        mountpoint -q "$mp" && umount "$mp" || true
    done
    zpool export "$BPOOL" 2>/dev/null || true
    zpool export "$RPOOL" 2>/dev/null || true
}

trap 'echo "FAILED at line $LINENO" >&2; unmount_all; exit 1' ERR

#══════════════════════════════════════════════════════════════════════════════
# SAFEGUARDS — independent checks before anything is touched
#══════════════════════════════════════════════════════════════════════════════

[[ "$(id -u)" -eq 0 ]] || fatal "Must run as root"

# 0. Required configuration is set
for v in DISK1_ID DISK2_ID NEW_HOSTNAME USERNAME; do
    [[ -n "${!v}" ]] || fatal "$v is empty — edit the CONFIGURATION section"
done
if [[ -z "$USER_PASSWORD" ]]; then
    [[ -t 0 ]] || fatal "USER_PASSWORD is empty and stdin is not a TTY — set it in CONFIGURATION or run interactively"
    while :; do
        read -rsp "Set password for ${USERNAME} (input hidden): " _p1; echo
        [[ -n "$_p1" ]] || { echo "  Password cannot be empty."; continue; }
        read -rsp "Confirm password: " _p2; echo
        if [[ "$_p1" == "$_p2" ]]; then
            USER_PASSWORD="$_p1"
            unset _p1 _p2
            break
        fi
        echo "  Passwords did not match — try again."
    done
fi
: "${USER_SUFFIX:=$NEW_HOSTNAME}"

# 1. Refuse to run on any known production host
CURRENT_HOSTNAME=$(hostname -s)
for blocked in "${BLOCKED_HOSTNAMES[@]}"; do
    [[ "$CURRENT_HOSTNAME" == "$blocked" ]] && \
        fatal "Refusing to run on production host '$CURRENT_HOSTNAME'"
done

# 2. Verify the exact target disks are present by their serial-based by-id paths.
#    The by-id names are unique to specific hardware — the script simply can't
#    find them on any other machine, making this the strongest portability guard.
for id in "$DISK1_ID" "$DISK2_ID"; do
    [[ -e "/dev/disk/by-id/$id" ]] || \
        fatal "Expected disk not found: /dev/disk/by-id/$id — wrong machine?"
done

# 3. Cross-verify: confirm each by-id resolves to the expected /dev path.
#    Guards against a collision where a different disk happens to be present.
DISK1_ACTUAL=$(readlink -f "/dev/disk/by-id/$DISK1_ID")
DISK2_ACTUAL=$(readlink -f "/dev/disk/by-id/$DISK2_ID")
[[ "$DISK1_ACTUAL" == "$DISK1" ]] || \
    fatal "DISK1_ID resolves to $DISK1_ACTUAL but DISK1=$DISK1 — check configuration"
[[ "$DISK2_ACTUAL" == "$DISK2" ]] || \
    fatal "DISK2_ID resolves to $DISK2_ACTUAL but DISK2=$DISK2 — check configuration"

# 4. Verify we are running from a live environment, not an installed system.
#    An installed system would have ZFS as the root filesystem type.
ROOT_FS_TYPE=$(stat -f -c '%T' /)
[[ "$ROOT_FS_TYPE" == "zfs" ]] && \
    fatal "Root filesystem is ZFS — this looks like an installed system, not a live session"

# 5. Verify neither target disk has any currently mounted partitions.
for DISK in "$DISK1" "$DISK2"; do
    if grep -q "^${DISK}" /proc/mounts; then
        MOUNTED=$(grep "^${DISK}" /proc/mounts | awk '{print $1, "→", $2}' | tr '\n' ' ')
        fatal "$DISK has mounted partitions: $MOUNTED"
    fi
done

# 6. Interactive confirmation — operator must type the target hostname exactly.
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  !! WARNING: ALL DATA ON THE FOLLOWING DISKS WILL BE LOST !!"
echo ""
printf "    %s  (%s)  by-id: %s\n" "$DISK1" "$(lsblk -dno SIZE "$DISK1")" "$DISK1_ID"
printf "    %s  (%s)  by-id: %s\n" "$DISK2" "$(lsblk -dno SIZE "$DISK2")" "$DISK2_ID"
echo ""
echo "  Target hostname : $NEW_HOSTNAME"
echo "  Running on host : $CURRENT_HOSTNAME"
echo "════════════════════════════════════════════════════════════════"
echo ""
read -rp "  Type the target hostname to confirm (or anything else to abort): " CONFIRM
echo ""
[[ "$CONFIRM" == "$NEW_HOSTNAME" ]] || { echo "Aborted."; exit 1; }

#══════════════════════════════════════════════════════════════════════════════
# 0. Prerequisites; hash the password before chroot so the plaintext never
#    leaves the live session.
#══════════════════════════════════════════════════════════════════════════════
info "Installing prerequisites..."
apt-get install -y --no-install-recommends debootstrap zfsutils-linux rsync openssl
modprobe zfs

# SHA-512 crypt ($6$). PAM on modern Ubuntu accepts it; yescrypt is
# preferred but needs the whois package (mkpasswd) which isn't standard.
USER_PASSWORD_HASH=$(openssl passwd -6 "$USER_PASSWORD")

#══════════════════════════════════════════════════════════════════════════════
# 1. Partition both disks identically
#    p1: 512 MiB  EFI System (EF00)
#    p2:   1 GiB  Linux swap  (8200)
#    p3:   4 GiB  ZFS bpool   (BF01)
#    p4: rest     ZFS rpool   (BF00)
#══════════════════════════════════════════════════════════════════════════════
info "Partitioning disks..."
for DISK in "$DISK1" "$DISK2"; do
    wipefs -af "$DISK"
    sgdisk --zap-all "$DISK"
    sgdisk \
        -n1:1M:+512M  -t1:EF00 -c1:"EFI-System" \
        -n2:0:+1G     -t2:8200 -c2:"Linux-swap" \
        -n3:0:+4G     -t3:BF01 -c3:"ZFS-bpool" \
        -n4:0:0       -t4:BF00 -c4:"ZFS-rpool" \
        "$DISK"
done
udevadm settle

#══════════════════════════════════════════════════════════════════════════════
# 2. EFI (FAT32) and swap partitions
#══════════════════════════════════════════════════════════════════════════════
info "Formatting EFI and swap..."
mkfs.vfat -F32 -n EFI "${DISK1}p1"
mkfs.vfat -F32 -n EFI "${DISK2}p1"
mkswap -L swap0 "${DISK1}p2"
mkswap -L swap1 "${DISK2}p2"

#══════════════════════════════════════════════════════════════════════════════
# 3. bpool — GRUB2-compatible feature set, mirrored
#══════════════════════════════════════════════════════════════════════════════
info "Creating bpool..."
zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -o compatibility=grub2 \
    -o cachefile=/etc/zfs/zpool.cache \
    -O devices=off \
    -O atime=off \
    -O compression=lz4 \
    -O canmount=off \
    -O mountpoint=/boot \
    -R "$MNT" \
    "$BPOOL" mirror \
    "/dev/disk/by-id/${DISK1_ID}-part3" \
    "/dev/disk/by-id/${DISK2_ID}-part3"

#══════════════════════════════════════════════════════════════════════════════
# 4. rpool — full feature set, mirrored
#══════════════════════════════════════════════════════════════════════════════
info "Creating rpool..."
zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -o cachefile=/etc/zfs/zpool.cache \
    -O atime=off \
    -O compression=zstd \
    -O xattr=sa \
    -O dnodesize=auto \
    -O canmount=off \
    -O mountpoint=/ \
    -R "$MNT" \
    "$RPOOL" mirror \
    "/dev/disk/by-id/${DISK1_ID}-part4" \
    "/dev/disk/by-id/${DISK2_ID}-part4"

#══════════════════════════════════════════════════════════════════════════════
# 5. ZFS datasets
#══════════════════════════════════════════════════════════════════════════════
info "Creating ZFS datasets..."

# Root filesystem
zfs create -o canmount=off  -o mountpoint=none      "$RPOOL/ROOT"
zfs create -o canmount=noauto -o mountpoint=/        "$RPOOL/ROOT/ubuntu_$NEW_HOSTNAME"
zfs mount "$RPOOL/ROOT/ubuntu_$NEW_HOSTNAME"
zpool set "bootfs=$RPOOL/ROOT/ubuntu_$NEW_HOSTNAME" "$RPOOL"

# System subtrees — each a separate dataset so root snapshots stay lean
# and each subtree can be snapshotted or rolled back independently.
zfs create                                           "$RPOOL/ROOT/ubuntu_$NEW_HOSTNAME/srv"
# sync=disabled: temp files have no persistence requirement, skip fsync overhead
zfs create -o com.sun:auto-snapshot=false \
           -o sync=disabled \
           -o setuid=off                             "$RPOOL/ROOT/ubuntu_$NEW_HOSTNAME/tmp"

# /usr must stay in the root dataset on Ubuntu 26.04+: /etc/os-release is a
# symlink to /usr/lib/os-release, and grub-mkconfig's 10_linux_zfs mounts the
# root dataset alone at a temp dir to read os-release. A separate /usr dataset
# leaves /usr empty in that temp mount, breaking symlink resolution and
# producing a grub.cfg with no Linux entries.

# /var and its subtrees — parent dataset created first so children
# are proper ZFS children rather than path-embedded datasets.
# setuid=off on /var itself is inherited by all children: nothing in /var
# should ever run setuid, and the property costs nothing on normal binaries.
zfs create -o setuid=off                             "$RPOOL/ROOT/ubuntu_$NEW_HOSTNAME/var"
zfs create                                           "$RPOOL/ROOT/ubuntu_$NEW_HOSTNAME/var/lib"
zfs create                                           "$RPOOL/ROOT/ubuntu_$NEW_HOSTNAME/var/lib/apt"
zfs create                                           "$RPOOL/ROOT/ubuntu_$NEW_HOSTNAME/var/lib/dpkg"
zfs create -o com.sun:auto-snapshot=false            "$RPOOL/ROOT/ubuntu_$NEW_HOSTNAME/var/lib/docker"
zfs create -o com.sun:auto-snapshot=false \
           -o exec=off                               "$RPOOL/ROOT/ubuntu_$NEW_HOSTNAME/var/log"
zfs create -o com.sun:auto-snapshot=false \
           -o exec=off                               "$RPOOL/ROOT/ubuntu_$NEW_HOSTNAME/var/spool"
zfs create -o com.sun:auto-snapshot=false \
           -o exec=off \
           -o sync=disabled                          "$RPOOL/ROOT/ubuntu_$NEW_HOSTNAME/var/tmp"
zfs create                                           "$RPOOL/ROOT/ubuntu_$NEW_HOSTNAME/var/www"

chmod 1777 "$MNT/tmp" "$MNT/var/tmp"

# User home directories
zfs create -o canmount=off -o mountpoint=/home       "$RPOOL/USERDATA"
zfs create -o mountpoint="/home/$USERNAME"           "$RPOOL/USERDATA/${USERNAME}_${USER_SUFFIX}"
zfs create -o mountpoint=/root                       "$RPOOL/USERDATA/root_${USER_SUFFIX}"
chmod 700 "$MNT/root"

# Boot datasets
zfs create -o canmount=off -o mountpoint=none        "$BPOOL/BOOT"
zfs create -o mountpoint=/boot                       "$BPOOL/BOOT/ubuntu_$NEW_HOSTNAME"
zfs create -o mountpoint=/boot/grub                  "$BPOOL/grub"

#══════════════════════════════════════════════════════════════════════════════
# 6. Mount EFI partition from disk 1 (disk 2 is synced later)
#══════════════════════════════════════════════════════════════════════════════
mkdir -p "$MNT/boot/efi"
mount "${DISK1}p1" "$MNT/boot/efi"

#══════════════════════════════════════════════════════════════════════════════
# 7. Debootstrap Ubuntu 26.04
#══════════════════════════════════════════════════════════════════════════════
info "Running debootstrap (this will take a few minutes)..."
debootstrap "$UBUNTU_CODENAME" "$MNT" "$UBUNTU_MIRROR"

#══════════════════════════════════════════════════════════════════════════════
# 8. Base system configuration
#══════════════════════════════════════════════════════════════════════════════
info "Configuring base system..."

# ZFS pool cache
mkdir -p "$MNT/etc/zfs"
cp /etc/zfs/zpool.cache "$MNT/etc/zfs/"

# Hostname. /etc/hosts is left at debootstrap's default (which has localhost
# but no 127.0.1.1 line for $NEW_HOSTNAME); sudo may print a one-time
# "unable to resolve host" warning, which the user can silence by adding
# the 127.0.1.1 entry themselves after first boot.
echo "$NEW_HOSTNAME" > "$MNT/etc/hostname"

# APT sources
cat > "$MNT/etc/apt/sources.list" <<EOF
deb $UBUNTU_MIRROR $UBUNTU_CODENAME main restricted universe multiverse
deb $UBUNTU_MIRROR ${UBUNTU_CODENAME}-updates main restricted universe multiverse
deb $UBUNTU_MIRROR ${UBUNTU_CODENAME}-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${UBUNTU_CODENAME}-security main restricted universe multiverse
EOF

# fstab — ZFS mounts itself; only EFI and swap go here.
# LABEL=EFI on /boot/efi: both ESPs share the label, so if DISK1 dies and we
# boot from DISK2's NVRAM entry, /boot/efi mounts whichever ESP exists.
# Both swap partitions are listed with nofail so a dead disk doesn't hang boot.
cat > "$MNT/etc/fstab" <<EOF
# ZFS datasets are mounted by systemd ZFS services.
LABEL=EFI    /boot/efi  vfat  defaults,noatime,nofail  0  2
LABEL=swap0  none       swap  sw,nofail                0  0
LABEL=swap1  none       swap  sw,nofail                0  0
EOF

# Netplan — DHCP on all ethernet interfaces (server defaults)
mkdir -p "$MNT/etc/netplan"
cat > "$MNT/etc/netplan/01-ethernet.yaml" <<'EOF'
network:
  version: 2
  renderer: networkd
  ethernets:
    all-eth:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: false
EOF
chmod 600 "$MNT/etc/netplan/01-ethernet.yaml"

# SSH authorized_keys from the SSH_PUBKEY variable (skipped if empty).
# Ownership is fixed up after useradd inside the chroot.
if [[ -n "$SSH_PUBKEY" ]]; then
    mkdir -p "$MNT/home/$USERNAME/.ssh"
    chmod 700 "$MNT/home/$USERNAME/.ssh"
    echo "$SSH_PUBKEY" > "$MNT/home/$USERNAME/.ssh/authorized_keys"
    chmod 600 "$MNT/home/$USERNAME/.ssh/authorized_keys"
fi

#══════════════════════════════════════════════════════════════════════════════
# 9. Bind-mount virtual filesystems for chroot
#══════════════════════════════════════════════════════════════════════════════
mount --bind /dev     "$MNT/dev"
mount -t devpts devpts "$MNT/dev/pts"
mount --bind /proc    "$MNT/proc"
mount --bind /sys     "$MNT/sys"
if [[ -d /sys/firmware/efi/efivars ]]; then
    mount -t efivarfs efivarfs "$MNT/sys/firmware/efi/efivars"
fi

#══════════════════════════════════════════════════════════════════════════════
# 10. Chroot: install packages and configure the installed system
#══════════════════════════════════════════════════════════════════════════════
info "Entering chroot to install packages and configure system..."

chroot "$MNT" /usr/bin/env -i \
    HOME=/root \
    TERM="$TERM" \
    DEBIAN_FRONTEND=noninteractive \
    NEW_HOSTNAME="$NEW_HOSTNAME" \
    USERNAME="$USERNAME" \
    USER_SUFFIX="$USER_SUFFIX" \
    USER_PASSWORD_HASH="$USER_PASSWORD_HASH" \
    RPOOL="$RPOOL" \
    BPOOL="$BPOOL" \
    TIMEZONE="$TIMEZONE" \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    /bin/bash -xe <<'CHROOT'

# Timezone. Locale is left at the default (C.UTF-8 from debootstrap) — set
# with `sudo dpkg-reconfigure locales` after first boot if you want a specific one.
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
dpkg-reconfigure -f noninteractive tzdata

# Main package installation
apt-get update
apt-get install -y \
    linux-image-generic \
    linux-headers-generic \
    zfsutils-linux \
    zfs-initramfs \
    grub-efi-amd64 \
    grub-efi-amd64-signed \
    shim-signed \
    openssh-server \
    sudo \
    curl \
    wget \
    vim \
    nano \
    net-tools \
    iproute2 \
    dosfstools \
    netplan.io \
    systemd-resolved \
    chrony \
    bash-completion \
    man-db \
    manpages

# User creation. Standard Ubuntu sudoer: member of sudo,adm; sudo prompts
# for the user's own password (Ubuntu's default %sudo ALL=(ALL:ALL) ALL).
# Root account permanently locked.
useradd -m -s /bin/bash -G sudo,adm "$USERNAME"
echo "${USERNAME}:${USER_PASSWORD_HASH}" | chpasswd -e
# /home/$USERNAME pre-exists as its own ZFS dataset, so useradd -m skips
# /etc/skel. Copy it ourselves with --no-clobber so anything we wrote
# earlier (notably .ssh/authorized_keys) is preserved.
cp -an /etc/skel/. "/home/${USERNAME}/"
chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}"
passwd -l root

# SSH: enable the service. Configuration is left at Ubuntu's defaults
# (PasswordAuthentication yes, PermitRootLogin prohibit-password). The root
# password is locked further down, so prohibit-password is effectively no
# root login. Tighten sshd_config later to taste.
systemctl enable ssh

# ZFS services
systemctl enable zfs-import-cache.service
systemctl enable zfs-import-scan.service
systemctl enable zfs-mount.service
systemctl enable zfs.target
systemctl enable zfs-zed.service

# Dedicated bpool import service — runs before the main ZFS import
# so /boot is available when systemd processes the remaining fstab entries.
cat > /etc/systemd/system/zfs-import-bpool.service <<'SVC'
[Unit]
Description=Import ZFS boot pool (bpool)
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/zpool import -N -o cachefile=none bpool

[Install]
WantedBy=zfs-import.target
SVC
systemctl enable zfs-import-bpool.service

# GRUB — note: unquoted heredoc so $RPOOL and $NEW_HOSTNAME expand here
cat > /etc/default/grub <<GRUBEOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
# On ZFS root, GRUB can't reliably clear the recordfail flag in grubenv,
# so every boot is treated as "previous boot failed" and GRUB_RECORDFAIL_TIMEOUT
# (Ubuntu default: 30s, sometimes -1 = wait forever) overrides GRUB_TIMEOUT.
# Pin it to the same 5s so the boot menu behaves predictably.
GRUB_RECORDFAIL_TIMEOUT=5
GRUB_DISTRIBUTOR="Ubuntu"
GRUB_CMDLINE_LINUX_DEFAULT=""
# 10_linux_zfs injects root=ZFS=<dataset> into each menuentry from the dataset
# itself; leave GRUB_CMDLINE_LINUX empty so we don't duplicate it.
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL=console
GRUB_DISABLE_OS_PROBER=true
GRUBEOF

update-initramfs -c -k all
# --no-nvram: grub-install would otherwise create a generic "Ubuntu" EFI entry.
# We create both disk1 and disk2 entries explicitly with descriptive labels
# (hostname-tagged) after exiting the chroot.
grub-install \
    --target=x86_64-efi \
    --efi-directory=/boot/efi \
    --bootloader-id=ubuntu \
    --no-nvram \
    --recheck
update-grub

CHROOT

#══════════════════════════════════════════════════════════════════════════════
# 11. Mirror the ESP to the second disk, then register both as UEFI boot options
#     Both disks hold a bootable EFI partition; firmware can be pointed to
#     either one so the system boots if a disk fails. Labels include the
#     hostname so they are unambiguous in efibootmgr output across a fleet.
#══════════════════════════════════════════════════════════════════════════════
info "Syncing ESP to second disk..."
mkdir -p /mnt/esp2
mount "${DISK2}p1" /mnt/esp2
rsync -a --delete "$MNT/boot/efi/" /mnt/esp2/
umount /mnt/esp2
rmdir /mnt/esp2

# We add our two entries but do NOT touch any existing NVRAM entries, so a
# dual-boot setup keeps its other-OS entries intact. Re-running this script
# will accumulate duplicate "Ubuntu 26.04 LTS - <hostname>" entries; remove
# the stale ones manually with: efibootmgr -b <num> -B
EFI_LABEL_DISK1="Ubuntu 26.04 LTS - $NEW_HOSTNAME"
EFI_LABEL_DISK2="Ubuntu 26.04 LTS - $NEW_HOSTNAME (mirror)"

BOOT_DISK1=$(efibootmgr --create --disk "$DISK1" --part 1 \
    --label "$EFI_LABEL_DISK1" \
    --loader '\EFI\ubuntu\shimx64.efi' \
    | awk '/^BootOrder:/{print $2; exit}' | cut -d, -f1)

BOOT_DISK2=$(efibootmgr --create --disk "$DISK2" --part 1 \
    --label "$EFI_LABEL_DISK2" \
    --loader '\EFI\ubuntu\shimx64.efi' \
    | awk '/^BootOrder:/{print $2; exit}' | cut -d, -f1)

info "  EFI entries: Boot${BOOT_DISK1} (disk1), Boot${BOOT_DISK2} (disk2)"

# Boot order: disk1 first, disk2 second, other entries (live USB, firmware
# settings, PXE) preserved after them.
if [[ -n "$BOOT_DISK1" && -n "$BOOT_DISK2" ]]; then
    CUR=$(efibootmgr | awk '/^BootOrder:/{print $2}')
    REST=$(echo "$CUR" | tr ',' '\n' | grep -vxE "$BOOT_DISK1|$BOOT_DISK2" | paste -sd,)
    NEW="${BOOT_DISK1},${BOOT_DISK2}${REST:+,$REST}"
    efibootmgr -o "$NEW" >/dev/null
    info "  Boot order: $NEW"
fi

#══════════════════════════════════════════════════════════════════════════════
# 12. Unmount everything and export pools
#══════════════════════════════════════════════════════════════════════════════
info "Cleaning up..."
unmount_all
trap - ERR

echo "
══════════════════════════════════════════════════════
  Installation complete!

  ZFS pools exported. Remove the live USB and reboot.

  First boot: SSH in as $USERNAME@<ip>
              SSH key login: $( [[ -n "$SSH_PUBKEY" ]] && echo enabled || echo "disabled (no SSH_PUBKEY)" )
              Password login: enabled (sudo will prompt for the user's password)
              Root login is disabled in any case.
══════════════════════════════════════════════════════"
