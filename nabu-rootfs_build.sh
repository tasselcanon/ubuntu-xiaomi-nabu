#!/bin/sh

set -eu

if [ "$(id -u)" -ne 0 ]
then
  echo "rootfs can only be built as root" >&2
  exit 1
fi

DESKTOP="${1:?desktop package is required}"
KERNEL_VERSION="${2:?kernel version is required}"
BASE_SERIES="${UBUNTU_BASE_SERIES:-24.04}"
BASE_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/$BASE_SERIES/release"
BASE_TARBALL="$(wget -qO- "$BASE_URL/" | grep -o 'ubuntu-base-[0-9.]*-base-arm64.tar.gz' | sort -V | tail -n1)"
WORKSPACE_DIR="${GITHUB_WORKSPACE:-$(pwd)}"

if [ -z "$BASE_TARBALL" ]
then
  echo "failed to resolve an ubuntu-base arm64 tarball from $BASE_URL" >&2
  exit 1
fi

cleanup() {
  mountpoint -q rootdir/sys 2>/dev/null && umount rootdir/sys || true
  mountpoint -q rootdir/proc 2>/dev/null && umount rootdir/proc || true
  mountpoint -q rootdir/dev/pts 2>/dev/null && umount rootdir/dev/pts || true
  mountpoint -q rootdir/dev 2>/dev/null && umount rootdir/dev || true
  mountpoint -q rootdir 2>/dev/null && umount rootdir || true
  [ -d rootdir ] && rmdir rootdir 2>/dev/null || true
}

chroot_apt_install() {
  if chroot rootdir apt install -y "$@"
  then
    return 0
  fi

  chroot rootdir dpkg --configure -a || true
  chroot rootdir apt -f install -y || true
  chroot rootdir apt install -y "$@"
}

trap cleanup EXIT

rm -f rootfs.img rootfs.7z
truncate -s 8G rootfs.img
mkfs.ext4 rootfs.img
mkdir rootdir
mount -o loop rootfs.img rootdir

wget "$BASE_URL/$BASE_TARBALL"
tar xzvf "$BASE_TARBALL" -C rootdir
rm -f "$BASE_TARBALL"

mkdir -p rootdir/dev/pts rootdir/proc rootdir/sys rootdir/tmp rootdir/usr/sbin

mount --bind /dev rootdir/dev
mount --bind /dev/pts rootdir/dev/pts
mount --bind /proc rootdir/proc
mount --bind /sys rootdir/sys

echo "nameserver 1.1.1.1" > rootdir/etc/resolv.conf
echo "xiaomi-nabu" > rootdir/etc/hostname
printf "127.0.0.1 localhost\n127.0.1.1 xiaomi-nabu\n" > rootdir/etc/hosts

printf "#!/bin/sh\nexit 101\n" > rootdir/usr/sbin/policy-rc.d
chmod 755 rootdir/usr/sbin/policy-rc.d

if uname -m | grep -q aarch64
then
  echo "native arm64 runner detected; qemu setup skipped"
else
  if ! command -v qemu-aarch64-static >/dev/null 2>&1
  then
    echo "qemu-aarch64-static not found; install qemu-user-static first" >&2
    exit 1
  fi

  install -D -m755 "$(command -v qemu-aarch64-static)" rootdir/usr/bin/qemu-aarch64-static

  if command -v update-binfmts >/dev/null 2>&1
  then
    update-binfmts --enable qemu-aarch64 || true
  fi

  if ! chroot rootdir /usr/bin/env true
  then
    echo "arm64 chroot failed; qemu-aarch64 binfmt is not registered correctly" >&2
    exit 1
  fi
fi

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
export DEBIAN_FRONTEND=noninteractive

chroot rootdir apt update
chroot rootdir apt upgrade -y

# u-boot-tools breaks grub installation, so keep it removed while installing desktops.
chroot_apt_install bash-completion sudo ssh nano dpkg-dev u-boot-tools-
chroot_apt_install u-boot-tools- "$DESKTOP"

chroot_apt_install rmtfs protection-domain-mapper tqftpserv

if [ -f rootdir/lib/systemd/system/pd-mapper.service ]
then
  sed -i '/ConditionKernelVersion/d' rootdir/lib/systemd/system/pd-mapper.service
fi

cp "$WORKSPACE_DIR"/xiaomi-nabu-debs_"$KERNEL_VERSION"/*-xiaomi-nabu.deb rootdir/tmp/
chroot rootdir dpkg -i /tmp/linux-xiaomi-nabu.deb
chroot rootdir dpkg -i /tmp/firmware-xiaomi-nabu.deb
chroot rootdir dpkg -i /tmp/alsa-xiaomi-nabu.deb
rm rootdir/tmp/*-xiaomi-nabu.deb

chroot_apt_install grub-efi-arm64

sed --in-place 's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' rootdir/etc/default/grub
sed --in-place 's/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/GRUB_CMDLINE_LINUX_DEFAULT=""/' rootdir/etc/default/grub

printf "PARTLABEL=linux / ext4 errors=remount-ro,x-systemd.growfs 0 1\nPARTLABEL=esp /boot/efi vfat umask=0077 0 1\n" > rootdir/etc/fstab

mkdir -p rootdir/var/lib/gdm
touch rootdir/var/lib/gdm/run-initial-setup

chroot rootdir apt clean
rm -f rootdir/usr/sbin/policy-rc.d
rm -f rootdir/usr/bin/qemu-aarch64-static

umount rootdir/sys
umount rootdir/proc
umount rootdir/dev/pts
umount rootdir/dev
umount rootdir
rmdir rootdir

echo 'cmdline for legacy boot: "root=PARTLABEL=linux"'

if command -v 7zz >/dev/null 2>&1
then
  SEVENZIP=7zz
elif command -v 7z >/dev/null 2>&1
then
  SEVENZIP=7z
else
  echo "7zip binary not found; install either 7zip or p7zip-full" >&2
  exit 1
fi

"$SEVENZIP" a rootfs.7z rootfs.img
