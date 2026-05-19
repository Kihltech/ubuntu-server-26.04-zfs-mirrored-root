# Ubuntu Server 26.04 Root on ZFS — Mirrored

Install Ubuntu Server 26.04 LTS ("Resolute Raccoon") with the root filesystem on
a two-disk ZFS mirror, booting via UEFI. Modelled on the
[OpenZFS Ubuntu 22.04 Root on ZFS guide](https://openzfs.github.io/openzfs-docs/Getting%20Started/Ubuntu/Ubuntu%2022.04%20Root%20on%20ZFS.html),
adapted for the changes in 26.04 that broke the older flow.

A 24.04 sibling repository following the same structure is at
[ubuntu-server-24.04-zfs-mirrored-root](https://github.com/Kihltech/ubuntu-server-24.04-zfs-mirrored-root).

This first release covers a **two-disk mirror only**. No encryption, no
single-disk, no raidz; those branches will potentially come in later releases.

> **Status:** originally end-to-end verified on 26.04 hardware. Recent edits
> (ported from the 24.04 work) are pending re-verification — review the
> CONFIGURATION block and the manual procedure before relying on them.

There are two ways to use this repository:

1. **Automated** — edit the configuration block in
   [`install-zfs-ubuntu.sh`](install-zfs-ubuntu.sh) and run it from a live
   Ubuntu session.
2. **Manual** — follow the [step-by-step guide](#system-installation) below.
   The script does the same things, in the same order, with the same commands.

## What 26.04 changed (and why this guide exists)

The OpenZFS 22.04 guide recommends a separate `/usr` dataset. On Ubuntu 26.04
that produces a system that does not boot, in an unusually silent way:

`/etc/os-release` on 26.04 is a symlink to `../usr/lib/os-release`.
`grub-mkconfig`'s `/etc/grub.d/10_linux_zfs` reads `os-release` to identify
each candidate root dataset by mounting that dataset alone at a temporary
directory and sourcing `${mntdir}/etc/os-release`. If `/usr` is a separate
ZFS dataset, the temp mount has an empty `/usr/`, the symlink fails to
resolve, and `set -e` aborts the function silently. The resulting `grub.cfg`
contains no Linux menu entries, and with `GRUB_DEFAULT=0` the firmware ends up
selecting the "UEFI Firmware Settings" entry from `30_uefi-firmware`.

The fix is structural: **keep `/usr` inside the root dataset**. `/var` and its
subtrees as separate datasets are fine — nothing `10_linux_zfs` reads lives
under `/var`.

A second small change: 26.04's `10_linux_zfs` already injects
`root=ZFS=<dataset>` into each menuentry, so `GRUB_CMDLINE_LINUX` is left
empty to avoid a duplicate `root=` parameter.

# Preparation

## 1. Boot a live environment

Boot the machine from an Ubuntu 26.04 live USB (Desktop or Server installer
in "Try Ubuntu" mode). A network connection to `archive.ubuntu.com` is
required.

UEFI is required. Secure Boot is fine — the install uses the signed `shim`
and signed GRUB, the same chain Ubuntu's own installer uses.

## 2. Become root

```sh
sudo -i
```

The rest of this guide assumes a root shell.

## 3. (Optional) Enable SSH into the live environment

Strongly recommended — copy-pasting commands from a workstation beats typing
them at the console.

```sh
apt-get update
apt-get install -y openssh-server
passwd ubuntu      # set a temporary password for the live user
```

Find the live system's IP (`ip -4 a`), then from your workstation:

```sh
ssh ubuntu@<live-ip>
sudo -i
```

## 4. Install setup prerequisites

```sh
apt-get install -y --no-install-recommends \
    debootstrap zfsutils-linux rsync openssl
modprobe zfs
```

## 5. Set installation variables

These are referenced throughout the rest of the guide. Edit the values for
your machine.

```sh
# Block-device paths and their stable by-id names.
# Find them with: ls -l /dev/disk/by-id/ | grep -v part
DISK1=/dev/nvme0n1
DISK2=/dev/nvme1n1
DISK1_ID=nvme-Manufacturer_Model_Serial1
DISK2_ID=nvme-Manufacturer_Model_Serial2

# Identity of the installed system
HOST=myserver
USER=admin
TIMEZONE=UTC

MNT=/mnt/install
```

Verify the two by-id paths really point at the two disks you intend to wipe:

```sh
ls -l "/dev/disk/by-id/$DISK1_ID" "/dev/disk/by-id/$DISK2_ID"
```

# System installation

## Step 1 — Partition the disks

Both disks are partitioned identically:

| Part | Size    | Type            | Purpose                                  |
|------|---------|-----------------|------------------------------------------|
| `p1` | 512 MiB | EFI System      | FAT32, mirrored byte-for-byte with rsync |
| `p2` | 1 GiB   | Linux swap      | Independent on each disk                 |
| `p3` | 4 GiB   | ZFS `bpool`     | GRUB2-compatible features only           |
| `p4` | rest    | ZFS `rpool`     | Full feature set                         |

```sh
for D in "$DISK1" "$DISK2"; do
    wipefs -af "$D"
    sgdisk --zap-all "$D"
    sgdisk \
        -n1:1M:+512M  -t1:EF00 -c1:"EFI-System" \
        -n2:0:+1G     -t2:8200 -c2:"Linux-swap" \
        -n3:0:+4G     -t3:BF01 -c3:"ZFS-bpool" \
        -n4:0:0       -t4:BF00 -c4:"ZFS-rpool" \
        "$D"
done
udevadm settle
```

Format the EFI System partitions and the swap partitions:

```sh
mkfs.vfat -F32 -n EFI "${DISK1}p1"
mkfs.vfat -F32 -n EFI "${DISK2}p1"
mkswap -L swap0 "${DISK1}p2"
mkswap -L swap1 "${DISK2}p2"
```

## Step 2 — Create the pools

### `bpool` (boot pool, GRUB2-compatible)

`-o compatibility=grub2` restricts pool features to those GRUB can read.

```sh
zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -o compatibility=grub2 \
    -o cachefile=/etc/zfs/zpool.cache \
    -O devices=off -O atime=off -O compression=lz4 \
    -O canmount=off -O mountpoint=/boot \
    -R "$MNT" \
    bpool mirror \
    "/dev/disk/by-id/${DISK1_ID}-part3" \
    "/dev/disk/by-id/${DISK2_ID}-part3"
```

### `rpool` (root pool, full feature set)

```sh
zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -o cachefile=/etc/zfs/zpool.cache \
    -O atime=off -O compression=zstd -O xattr=sa -O dnodesize=auto \
    -O canmount=off -O mountpoint=/ \
    -R "$MNT" \
    rpool mirror \
    "/dev/disk/by-id/${DISK1_ID}-part4" \
    "/dev/disk/by-id/${DISK2_ID}-part4"
```

## Step 3 — Create the datasets

```sh
# Root container, then the actual root dataset, mounted at /
zfs create -o canmount=off  -o mountpoint=none      rpool/ROOT
zfs create -o canmount=noauto -o mountpoint=/        rpool/ROOT/ubuntu_$HOST
zfs mount rpool/ROOT/ubuntu_$HOST
zpool set "bootfs=rpool/ROOT/ubuntu_$HOST" rpool

# System subtrees. /usr is intentionally NOT a separate dataset (see top).
zfs create                                           rpool/ROOT/ubuntu_$HOST/srv
zfs create -o com.sun:auto-snapshot=false \
           -o sync=disabled \
           -o setuid=off                             rpool/ROOT/ubuntu_$HOST/tmp
zfs create -o setuid=off                             rpool/ROOT/ubuntu_$HOST/var
zfs create                                           rpool/ROOT/ubuntu_$HOST/var/lib
zfs create                                           rpool/ROOT/ubuntu_$HOST/var/lib/apt
zfs create                                           rpool/ROOT/ubuntu_$HOST/var/lib/dpkg
zfs create -o com.sun:auto-snapshot=false            rpool/ROOT/ubuntu_$HOST/var/lib/docker
zfs create -o com.sun:auto-snapshot=false \
           -o exec=off                               rpool/ROOT/ubuntu_$HOST/var/log
zfs create -o com.sun:auto-snapshot=false \
           -o exec=off                               rpool/ROOT/ubuntu_$HOST/var/spool
zfs create -o com.sun:auto-snapshot=false \
           -o exec=off -o sync=disabled              rpool/ROOT/ubuntu_$HOST/var/tmp
zfs create                                           rpool/ROOT/ubuntu_$HOST/var/www
chmod 1777 "$MNT/tmp" "$MNT/var/tmp"

# Home directories
zfs create -o canmount=off -o mountpoint=/home       rpool/USERDATA
zfs create -o mountpoint=/home/$USER                 rpool/USERDATA/${USER}_${HOST}
zfs create -o mountpoint=/root                       rpool/USERDATA/root_${HOST}
chmod 700 "$MNT/root"

# Boot
zfs create -o canmount=off -o mountpoint=none        bpool/BOOT
zfs create -o mountpoint=/boot                       bpool/BOOT/ubuntu_$HOST
zfs create -o mountpoint=/boot/grub                  bpool/grub
```

## Step 4 — Mount disk 1's EFI partition

The second disk's ESP is synced byte-for-byte from disk 1 after install.

```sh
mkdir -p "$MNT/boot/efi"
mount "${DISK1}p1" "$MNT/boot/efi"
```

## Step 5 — Debootstrap Ubuntu 26.04

```sh
debootstrap resolute "$MNT" http://archive.ubuntu.com/ubuntu
```

This takes a few minutes. It puts the base system in place; we configure
and finish the installation inside a chroot.

## Step 6 — Base system configuration

ZFS pool cache (so the installed system can re-import the pools):

```sh
mkdir -p "$MNT/etc/zfs"
cp /etc/zfs/zpool.cache "$MNT/etc/zfs/"
```

Hostname (debootstrap's `/etc/hosts` is left as-is; `sudo` may emit a one-time
"unable to resolve host" warning, which goes away if you add a `127.0.1.1
$HOST` line later):

```sh
echo "$HOST" > "$MNT/etc/hostname"
```

APT sources:

```sh
cat > "$MNT/etc/apt/sources.list" <<'EOF'
deb http://archive.ubuntu.com/ubuntu resolute main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu resolute-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu resolute-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu resolute-security main restricted universe multiverse
EOF
```

`/etc/fstab` — ZFS mounts itself; only the EFI and swap entries go here.
`LABEL=EFI` is set on both ESPs by `mkfs.vfat -n EFI`, so if DISK1 dies and
the firmware falls back to DISK2's NVRAM entry, `/boot/efi` mounts whichever
ESP is present. Both swaps are listed with `nofail` so a dead disk doesn't
hang the boot.

```sh
cat > "$MNT/etc/fstab" <<'EOF'
# ZFS datasets are mounted by systemd ZFS services.
LABEL=EFI    /boot/efi  vfat  defaults,noatime,nofail  0  2
LABEL=swap0  none       swap  sw,nofail                0  0
LABEL=swap1  none       swap  sw,nofail                0  0
EOF
```

Netplan (DHCP on any `en*` interface):

```sh
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
```

SSH public key for `$USER`:

```sh
mkdir -p "$MNT/home/$USER/.ssh"
chmod 700 "$MNT/home/$USER/.ssh"
echo 'ssh-ed25519 AAAA... you@host' \
    > "$MNT/home/$USER/.ssh/authorized_keys"
chmod 600 "$MNT/home/$USER/.ssh/authorized_keys"
# ownership is fixed after useradd inside the chroot
```

Hash a password now so the plaintext does not leave the live session. A
password is required: even with SSH key login it's needed for `sudo`, which
uses Ubuntu's default policy (members of the `sudo` group authenticate with
their own password).

```sh
PWHASH=$(openssl passwd -6 'YourPasswordHere')
```

## Step 7 — Bind-mount and chroot

Bind the live system's `/dev`, `/proc`, `/sys` (and EFI variables, on UEFI
hosts) into `$MNT` so the chroot can see real kernel interfaces:

```sh
mount --bind /dev          "$MNT/dev"
mount -t devpts devpts     "$MNT/dev/pts"
mount --bind /proc         "$MNT/proc"
mount --bind /sys          "$MNT/sys"
[ -d /sys/firmware/efi/efivars ] && \
    mount -t efivarfs efivarfs "$MNT/sys/firmware/efi/efivars"
```

Verify the bind mounts succeeded before chrooting:

```sh
mount | grep "$MNT"
```

You should see entries for `$MNT/dev`, `$MNT/dev/pts`, `$MNT/proc`,
`$MNT/sys` (and `$MNT/sys/firmware/efi/efivars` on UEFI). If any are
missing, fix them before proceeding — installing GRUB without `/sys` or
`efivars` will fail or produce a broken installation.

Enter the chroot:

```sh
chroot "$MNT" /usr/bin/env -i \
    HOME=/root TERM="$TERM" DEBIAN_FRONTEND=noninteractive \
    HOST="$HOST" USER="$USER" PWHASH="$PWHASH" \
    TIMEZONE="$TIMEZONE" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    /bin/bash
```

Everything from here until "Exit the chroot" runs inside the chroot.

### Timezone

Locale stays at the debootstrap default (C.UTF-8); set yours later with
`sudo dpkg-reconfigure locales` if you care about a specific one.

```sh
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
dpkg-reconfigure -f noninteractive tzdata
```

### Install packages

```sh
apt-get update
apt-get install -y \
    linux-image-generic linux-headers-generic \
    zfsutils-linux zfs-initramfs \
    grub-efi-amd64 grub-efi-amd64-signed shim-signed \
    openssh-server sudo curl wget vim nano \
    net-tools iproute2 dosfstools netplan.io \
    systemd-resolved chrony bash-completion \
    man-db manpages
```

### User account

Standard Ubuntu sudoer: `$USER` joins the `sudo` and `adm` groups, so `sudo`
prompts for the user's own password (Ubuntu's default
`%sudo ALL=(ALL:ALL) ALL`). Root account permanently locked:

`/home/$USER` already exists as its own ZFS dataset, so `useradd -m` skips
copying `/etc/skel`. We copy it manually with `--no-clobber` so the
`.ssh/authorized_keys` written earlier is preserved.

```sh
useradd -m -s /bin/bash -G sudo,adm "$USER"
echo "${USER}:${PWHASH}" | chpasswd -e
cp -a --update=none /etc/skel/. "/home/${USER}/"
chown -R "${USER}:${USER}" "/home/${USER}"
passwd -l root
```

### Enable SSH

Ubuntu's defaults — `PasswordAuthentication yes` (or commented, same effect)
and `PermitRootLogin prohibit-password` — are kept as-is. The root password
is locked above, so prohibit-password effectively means no root login.
Tighten `sshd_config` later if you want.

```sh
systemctl enable ssh
```

### ZFS services

```sh
systemctl enable zfs-import-cache.service zfs-import-scan.service \
                  zfs-mount.service zfs.target zfs-zed.service
```

A dedicated unit imports `bpool` early so `/boot` is available before the
main mount step:

```sh
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
```

## Step 8 — GRUB installation

Write the GRUB defaults:

```sh
cat > /etc/default/grub <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
# On ZFS root, GRUB can't reliably clear the recordfail flag in grubenv,
# so every boot is treated as "previous boot failed" and
# GRUB_RECORDFAIL_TIMEOUT (Ubuntu default: 30s, sometimes -1 = wait forever)
# overrides GRUB_TIMEOUT. Pin it to the same 5s for predictable behaviour.
GRUB_RECORDFAIL_TIMEOUT=5
GRUB_DISTRIBUTOR="Ubuntu"
GRUB_CMDLINE_LINUX_DEFAULT=""
# 10_linux_zfs injects root=ZFS=<dataset> per menuentry; keep this empty.
GRUB_CMDLINE_LINUX=""
GRUB_TERMINAL=console
GRUB_DISABLE_OS_PROBER=true
EOF
```

Build the initramfs (the `zfs-initramfs` package installed earlier hooks
into this so `zfs.ko` and `spl.ko` are included):

```sh
update-initramfs -c -k all
```

Verify the resulting image contains ZFS:

```sh
lsinitramfs /boot/initrd.img-* | grep -E 'zfs|spl'
```

Install the bootloader files to disk 1's ESP. `--no-nvram` skips creating
a generic "Ubuntu" firmware entry; descriptively-labelled per-disk entries
are registered from outside the chroot after mirroring the ESP to disk 2.

```sh
grub-install --target=x86_64-efi \
             --efi-directory=/boot/efi \
             --bootloader-id=ubuntu \
             --no-nvram --recheck
```

Confirm the bootloader files landed in the ESP:

```sh
ls /boot/efi/EFI/ubuntu/
```

You should see at minimum `shimx64.efi`, `grubx64.efi`, `mmx64.efi`, and a
small stub `grub.cfg`.

Generate `/boot/grub/grub.cfg`:

```sh
update-grub
```

`update-grub` should report:

```
Found linux image: vmlinuz-7.0.0-NN-generic in rpool/ROOT/ubuntu_<host>
Found initrd image: initrd.img-7.0.0-NN-generic in rpool/ROOT/ubuntu_<host>
```

If you see no such lines, `10_linux_zfs` is failing — see
[Troubleshooting](#troubleshooting). Fix it before exiting the chroot.

### Exit the chroot

```sh
exit
```

## Step 9 — Mirror the ESP and register UEFI boot entries

Back in the live session:

```sh
mkdir -p /mnt/esp2
mount "${DISK2}p1" /mnt/esp2
rsync -a --delete "$MNT/boot/efi/" /mnt/esp2/
umount /mnt/esp2
rmdir /mnt/esp2
```

Register both disks with descriptive labels (so multiple machines in one
fleet are unambiguous in firmware menus). Existing NVRAM entries are
**not** touched, so dual-boot setups keep their other-OS entries intact —
remove duplicates manually with `efibootmgr -b <num> -B` if you ever re-run
this installer on the same machine:

```sh
B1=$(efibootmgr --create --disk "$DISK1" --part 1 \
        --label "Ubuntu 26.04 LTS - $HOST" \
        --loader '\EFI\ubuntu\shimx64.efi' \
        | awk '/^BootOrder:/{print $2; exit}' | cut -d, -f1)
B2=$(efibootmgr --create --disk "$DISK2" --part 1 \
        --label "Ubuntu 26.04 LTS - $HOST (mirror)" \
        --loader '\EFI\ubuntu\shimx64.efi' \
        | awk '/^BootOrder:/{print $2; exit}' | cut -d, -f1)
```

Boot order: disk 1, then disk 2, then everything else (USB, firmware
settings, PXE) preserved after:

```sh
CUR=$(efibootmgr | awk '/^BootOrder:/{print $2}')
REST=$(echo "$CUR" | tr ',' '\n' | grep -vxE "$B1|$B2" | paste -sd,)
efibootmgr -o "${B1},${B2}${REST:+,$REST}"
```

## Step 10 — Unmount and reboot

```sh
for mp in \
    "$MNT/sys/firmware/efi/efivars" \
    "$MNT/dev/pts" "$MNT/dev" \
    "$MNT/sys" "$MNT/proc" \
    "$MNT/boot/efi"; do
    mountpoint -q "$mp" && umount "$mp"
done
zpool export bpool
zpool export rpool
```

Remove the live USB and reboot.

## Step 11 — First boot

SSH in:

```sh
ssh "$USER@<ip>"
```

Ubuntu's stock sshd accepts both key and password authentication; either
works. `sudo` will then prompt for the user's password.

# Verification

A preflight check from the live USB before the first reboot is worthwhile.
After completing Step 10 but before rebooting, re-import the pools (in the
order in [Troubleshooting](#troubleshooting)) and verify:

- `zpool get -H -o value compatibility bpool` → `grub2`
- `zpool get -H -o value bootfs rpool` → `rpool/ROOT/ubuntu_<host>`
- `/mnt/boot/efi/EFI/ubuntu/` contains `shimx64.efi`, `grubx64.efi`,
  `grub.cfg` (the stub), `mmx64.efi`, `BOOTX64.CSV`
- The stub `grub.cfg`'s `search.fs_uuid` line matches
  `printf '%016x' "$(zpool get -H -o value guid bpool)"`
- `rsync -rc --dry-run /mnt/boot/efi/ <disk2-mountpoint>/` reports no
  differences (the two ESPs are identical)
- `/mnt/boot/grub/grub.cfg` contains a `menuentry 'Ubuntu …'` block with a
  `linux  "/BOOT/ubuntu_<host>@/vmlinuz-…"` line and a matching `initrd` line
- The referenced kernel and initrd actually exist in `/mnt/boot`
- `lsinitramfs /mnt/boot/initrd.img-*` contains `zfs.ko.zst` and `spl.ko.zst`
- `efibootmgr -v` lists two `Ubuntu 26.04 LTS - <host>` entries pointing at
  the two EFI partitions, and they are first in `BootOrder`

# Troubleshooting

## `update-grub` produces no Linux menu entries

The most common cause on 26.04 is a separate `/usr` dataset. Run
`update-grub` and look for:

```
Found linux image: vmlinuz-... in rpool/ROOT/ubuntu_<host>
```

If you see only:

```
Adding boot menu entry for UEFI Firmware Settings ...
done
```

then `10_linux_zfs` aborted. The smoking-gun error appears earlier in the
output:

```
/etc/grub.d/10_linux_zfs: NNN: .: cannot open /tmp/zfsmnt.XXXXXX/etc/os-release: No such file
```

Fix: do not create a separate `/usr` dataset; let `/usr` live inside
`rpool/ROOT/ubuntu_<host>`. The `/etc/os-release → ../usr/lib/os-release`
symlink then resolves correctly when `10_linux_zfs` mounts the dataset alone
at its temp directory.

## Re-importing the pools from a live USB

Order matters. Import `rpool` first, mount its root dataset, mount the rest,
**then** import `bpool`:

```sh
zpool import -f -N -R /mnt rpool
zfs mount rpool/ROOT/ubuntu_<host>
zfs mount -a
zpool import -f -N -R /mnt bpool
zfs mount -a
mount "${DISK1}p1" /mnt/boot/efi
mount --bind /dev /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys
chroot /mnt
```

Importing `bpool` before `rpool`'s root is mounted attaches its `/boot`
mount to the live system's directory node. When `rpool` then mounts at
`/mnt`, `/mnt/boot` resolves through `rpool`'s filesystem and `bpool`'s
mount becomes invisible — `zfs mount` reports it as mounted but `ls
/mnt/boot` is empty.

# License

MIT.
