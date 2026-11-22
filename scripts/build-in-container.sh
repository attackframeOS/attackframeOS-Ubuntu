#!/usr/bin/env bash
# Runs inside the ubuntu:<suite> container started by build.sh.
#
#   1. debootstrap an Ubuntu root filesystem and install GNOME + casper (live boot)
#   2. overlay the AttackFrame files (profile/airootfs) and branding
#   3. build the Kali and BlackArch layer images on the host's Docker daemon
#      (socket mounted by docker-compose.yml) and save them into the rootfs
#   4. squash it and wrap it in a hybrid BIOS/UEFI GRUB ISO
set -euo pipefail

AF=/af
WORK=/work
ROOT=$WORK/rootfs
ISO=$WORK/iso
SUITE=${UBUNTU_SUITE:-noble}
MIRROR=${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}
TOOLSET=${TOOLSET:-core}
IMGDIR=$ROOT/usr/share/attackframe/images
export DEBIAN_FRONTEND=noninteractive

log()  { printf '\e[1;36m[AF]\e[0m %s\n' "$*" >&2; }
warn() { printf '\e[1;35m[AF:warn]\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31m[AF:error]\e[0m %s\n' "$*" >&2; exit 1; }

in_chroot() { chroot "$ROOT" /usr/bin/env -i HOME=/root TERM="${TERM:-xterm}" LC_ALL=C.UTF-8 \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin DEBIAN_FRONTEND=noninteractive "$@"; }

MOUNTS=()
bind() { mkdir -p "$2"; mount "${@:3}" --bind "$1" "$2"; MOUNTS+=("$2"); }
unmount_all() {
  local i
  for ((i=${#MOUNTS[@]}-1; i>=0; i--)); do umount -lf "${MOUNTS[i]}" 2>/dev/null || true; done
  MOUNTS=()
  # anything left behind by an earlier aborted run
  local m
  for m in $(awk -v r="$ROOT" '$2 == r || index($2, r "/") == 1 {print $2}' /proc/mounts | sort -r); do
    umount -lf "$m" 2>/dev/null || true
  done
  return 0
}
trap unmount_all EXIT

# Strip comments/blank lines, keep names that exist in the chroot's apt repos.
resolve_apt() {
  local p pol found=() missing=()
  while read -r p; do
    p=${p%%#*}; p=${p//[[:space:]]/}
    [[ -z $p ]] && continue
    # no pipe into grep -q here: under pipefail its early exit (SIGPIPE) reads as "missing"
    pol=$(in_chroot apt-cache policy "$p" 2>/dev/null || true)
    if [[ $pol == *"Candidate: "* && $pol != *"Candidate: (none)"* ]]; then found+=("$p"); else missing+=("$p"); fi
  done < <(cat "$@")
  ((${#missing[@]})) && warn "not in ubuntu:$SUITE, skipped: ${missing[*]}"
  printf '%s\n' "${found[@]}" | sort -u
}

# ======================================================================= toolchain
log "Installing build toolchain"
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  debootstrap squashfs-tools xorriso grub-pc-bin grub-efi-amd64-bin grub-common mtools \
  dosfstools librsvg2-bin fontconfig curl ca-certificates xz-utils \
  docker.io docker-buildx >/dev/null
if [[ $TOOLSET != minimal ]] && ! docker info >/dev/null 2>&1; then
  die "can't reach the host Docker daemon — is /var/run/docker.sock mounted? (run ./build.sh, not this script)"
fi

# JetBrains Mono Nerd Font — needed for rendering artwork and shipped in the image
FONTS=$AF/.cache/fonts
if [[ ! -f $FONTS/JetBrainsMono.tar.xz ]]; then
  log "Downloading JetBrains Mono Nerd Font"
  curl -fsSL -o "$FONTS/JetBrainsMono.tar.xz" \
    https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz \
    || warn "could not download the Nerd Font; artwork falls back to other fonts"
fi
if [[ -f $FONTS/JetBrainsMono.tar.xz ]]; then
  mkdir -p /usr/local/share/fonts/jetbrains-nerd
  tar -xJf "$FONTS/JetBrainsMono.tar.xz" -C /usr/local/share/fonts/jetbrains-nerd --wildcards '*.ttf'
  fc-cache -f >/dev/null
fi

# ======================================================================= rootfs
log "Preparing work area"
unmount_all
rm -rf "$ROOT" "$ISO" "$WORK/ctx-"*
mkdir -p "$ROOT" "$ISO"

log "debootstrap ubuntu:$SUITE (this takes a few minutes)"
debootstrap --arch=amd64 --components=main,restricted,universe,multiverse \
  --cache-dir="$AF/.cache/debootstrap" "$SUITE" "$ROOT" "$MIRROR"

bind /dev "$ROOT/dev"
bind /dev/pts "$ROOT/dev/pts"
mount -t proc proc "$ROOT/proc";  MOUNTS+=("$ROOT/proc")
mount -t sysfs sys "$ROOT/sys";   MOUNTS+=("$ROOT/sys")
mount -t tmpfs tmpfs "$ROOT/run"; MOUNTS+=("$ROOT/run")
mkdir -p "$AF/.cache/apt/partial"
bind "$AF/.cache/apt" "$ROOT/var/cache/apt/archives"

# real resolv.conf while building; restored to the resolved stub at the end
rm -f "$ROOT/etc/resolv.conf"; cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf"
# don't start services inside the chroot
printf '#!/bin/sh\nexit 101\n' > "$ROOT/usr/sbin/policy-rc.d"; chmod +x "$ROOT/usr/sbin/policy-rc.d"
echo attackframe > "$ROOT/etc/hostname"
printf '127.0.0.1 localhost\n127.0.1.1 attackframe\n::1 localhost ip6-localhost ip6-loopback\n' > "$ROOT/etc/hosts"

log "Configuring apt sources"
rm -f "$ROOT/etc/apt/sources.list"
cat > "$ROOT/etc/apt/sources.list.d/ubuntu.sources" <<EOF
Types: deb
URIs: $MIRROR
Suites: $SUITE $SUITE-updates $SUITE-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu
Suites: $SUITE-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
# no snaps on AttackFrame: Firefox comes from Mozilla's deb repository instead
mkdir -p "$ROOT/etc/apt/preferences.d" "$ROOT/etc/apt/keyrings"
cat > "$ROOT/etc/apt/preferences.d/attackframe-no-snap" <<'EOF'
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF
# Ubuntu's own "firefox" is a snap wrapper, so Firefox is only added when
# Mozilla's repository is reachable.
FIREFOX=0
if curl -fsSL -m 30 https://packages.mozilla.org/apt/repo-signing-key.gpg \
     -o "$ROOT/etc/apt/keyrings/packages.mozilla.org.asc"; then
  echo 'deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main' \
    > "$ROOT/etc/apt/sources.list.d/mozilla.list"
  cat > "$ROOT/etc/apt/preferences.d/attackframe-mozilla" <<'EOF'
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF
  FIREFOX=1
else
  rm -f "$ROOT/etc/apt/keyrings/packages.mozilla.org.asc"
  warn "packages.mozilla.org unreachable — building without Firefox"
fi

in_chroot apt-get update -qq
in_chroot apt-get -y -qq full-upgrade
in_chroot apt-get -y -qq install --no-install-recommends ca-certificates locales apt-utils
in_chroot locale-gen en_US.UTF-8 >/dev/null
in_chroot update-locale LANG=en_US.UTF-8

# ======================================================================= packages
if [[ -z $KERNEL_PKG ]]; then
  KERNEL_PKG=linux-generic
  [[ $SUITE == noble ]] && KERNEL_PKG=linux-generic-hwe-24.04
fi
log "Resolving package lists (kernel: $KERNEL_PKG)"
pkgs=$(mktemp)
{ echo "$KERNEL_PKG"; cat "$AF/packages/base.txt" "$AF/packages/desktop.txt"; ((FIREFOX)) && echo firefox; true; } > "$pkgs.in"
resolve_apt "$pkgs.in" > "$pkgs"
(( $(wc -l < "$pkgs") >= 50 )) || die "only $(wc -l < "$pkgs") packages resolved — apt in the chroot is broken (check the mirror / sources)"
log "$(wc -l < "$pkgs") packages selected — installing"
# shellcheck disable=SC2046
in_chroot apt-get -y install --no-install-recommends $(cat "$pkgs")
mkdir -p "$ROOT/usr/share/attackframe"
cp "$pkgs" "$ROOT/usr/share/attackframe/packages.txt"

# ======================================================================= overlay
log "Applying AttackFrame overlay"
cp -rT "$AF/profile/airootfs" "$ROOT"
# leftovers from the Arch/archiso build, not used on Ubuntu
rm -rf "$ROOT/etc/pacman.d" "$ROOT/etc/systemd/system/attackframe-resolv.service" \
       "$ROOT/usr/local/bin/attackframe-gem-retry" "$ROOT/usr/local/bin/attackframe-postinstall"
chmod 755 "$ROOT"/usr/local/bin/*
# Ubuntu zsh profile (kept as a non-dot file in the repo; it replaces skel/.zshrc)
if [[ -f $ROOT/usr/share/attackframe/zshrc ]]; then
  mv -f "$ROOT/usr/share/attackframe/zshrc" "$ROOT/usr/share/attackframe/skel/.zshrc"
fi
# Podman-era files (the boxes run on Docker now)
rm -f "$ROOT/etc/sudoers.d/attackframe-podman" "$ROOT/etc/containers/storage.conf"
find "$ROOT/etc/sudoers.d" -name 'attackframe-*' -exec chmod 440 {} + 2>/dev/null || true
install -Dm644 "$AF/packages/kali-core.txt" "$ROOT/usr/share/attackframe/kali-core.txt"
install -Dm644 "$AF/packages/blackarch-core.txt" "$ROOT/usr/share/attackframe/blackarch-core.txt"
if [[ -d /usr/local/share/fonts/jetbrains-nerd ]]; then
  mkdir -p "$ROOT/usr/local/share/fonts"
  cp -r /usr/local/share/fonts/jetbrains-nerd "$ROOT/usr/local/share/fonts/"
  in_chroot fc-cache -f >/dev/null || true
fi

# identity: our os-release, diverted so base-files upgrades keep it
# shellcheck disable=SC1091
VERSION_ID=$(. "$ROOT/usr/lib/os-release"; echo "$VERSION_ID")
# shellcheck disable=SC1091
VERSION_CODENAME=$(. "$ROOT/usr/lib/os-release"; echo "$VERSION_CODENAME")
# base-files is Essential: divert without renaming; future upgrades land in .distrib
in_chroot dpkg-divert --quiet --local --no-rename --divert /usr/lib/os-release.distrib --add /usr/lib/os-release
cat > "$ROOT/usr/lib/os-release" <<EOF
NAME="AttackFrame OS"
PRETTY_NAME="AttackFrame OS ($VERSION_ID, rolling tools)"
ID=attackframe
ID_LIKE="ubuntu debian"
VERSION_ID="$VERSION_ID"
VERSION_CODENAME=$VERSION_CODENAME
UBUNTU_CODENAME=$VERSION_CODENAME
ANSI_COLOR="38;2;0;240;255"
HOME_URL="https://github.com/"
LOGO=attackframe
EOF
ln -sf ../usr/lib/os-release "$ROOT/etc/os-release"

# live session: casper creates the operator account (autologin, passwordless sudo)
cat > "$ROOT/etc/casper.conf" <<'EOF'
export USERNAME="ghost"
export USERFULLNAME="AttackFrame Operator"
export HOST="attackframe"
export BUILD_SYSTEM="Ubuntu"
export FLAVOUR="AttackFrame"
EOF
# new users get zsh and the operator profile
cp -rT "$ROOT/usr/share/attackframe/skel" "$ROOT/etc/skel"
sed -i 's#^\#\?DSHELL=.*#DSHELL=/usr/bin/zsh#' "$ROOT/etc/adduser.conf" 2>/dev/null || true
sed -i 's#^\#\? *SHELL=.*#SHELL=/usr/bin/zsh#' "$ROOT/etc/default/useradd" 2>/dev/null || true

# NetworkManager manages everything (netplan hands over to it)
mkdir -p "$ROOT/etc/netplan" "$ROOT/etc/NetworkManager/conf.d"
printf 'network:\n  version: 2\n  renderer: NetworkManager\n' > "$ROOT/etc/netplan/01-network-manager-all.yaml"
chmod 600 "$ROOT/etc/netplan/01-network-manager-all.yaml"
printf '[keyfile]\nunmanaged-devices=none\n' > "$ROOT/etc/NetworkManager/conf.d/10-globally-managed-devices.conf"

in_chroot systemctl enable attackframe-firstboot.service NetworkManager.service >/dev/null
in_chroot systemctl set-default graphical.target >/dev/null
in_chroot glib-compile-schemas /usr/share/glib-2.0/schemas
in_chroot dconf update || true

# ======================================================================= branding
log "Rendering artwork"
bgdir=$ROOT/usr/share/backgrounds/attackframe
mkdir -p "$bgdir" "$ROOT/usr/share/gnome-background-properties" "$ROOT/usr/share/icons/hicolor/scalable/apps"
install -Dm644 "$AF/assets/gdm-logo.svg" "$ROOT/usr/share/attackframe/gdm-logo.svg"
rsvg-convert -w 3840 -h 2160 "$AF/assets/wallpaper.svg" -o "$bgdir/attackframe-grid.png"
xml=$ROOT/usr/share/gnome-background-properties/attackframe.xml
wp() { printf '  <wallpaper deleted="false"><name>%s</name><filename>%s</filename><filename-dark>%s</filename-dark><options>zoom</options><shade_type>solid</shade_type><pcolor>#05070d</pcolor><scolor>#05070d</scolor></wallpaper>\n' "$1" "$2" "$2"; }
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<!DOCTYPE wallpapers SYSTEM "gnome-wp-list.dtd">'
  echo '<wallpapers>'
  wp "AttackFrame Grid" /usr/share/backgrounds/attackframe/attackframe-grid.png
  while IFS=$'\t' read -r slug name; do
    [[ -z $slug ]] && continue
    if [[ -f $AF/assets/wallpapers/png/$slug.png ]]; then
      cp "$AF/assets/wallpapers/png/$slug.png" "$bgdir/$slug.png"
    else
      rsvg-convert -w 3840 -h 2160 "$AF/assets/wallpapers/$slug.svg" -o "$bgdir/$slug.png"
    fi
    wp "AttackFrame $name" "/usr/share/backgrounds/attackframe/$slug.png"
  done < "$AF/assets/wallpapers/names.tsv"
  echo '</wallpapers>'
} > "$xml"
cp "$AF"/assets/icons/*.svg "$ROOT/usr/share/icons/hicolor/scalable/apps/"
cp -r "$AF"/assets/icon-themes/AttackFrame-* "$ROOT/usr/share/icons/"
for d in "$ROOT"/usr/share/icons/hicolor "$ROOT"/usr/share/icons/AttackFrame-*; do
  in_chroot gtk-update-icon-cache -qf "/usr/share/icons/${d##*/icons/}" 2>/dev/null || true
done

# boot splash + console banner: AttackFrame instead of Ubuntu (diverted so upgrades keep them)
for f in /usr/share/plymouth/ubuntu-logo.png /usr/share/plymouth/themes/spinner/watermark.png; do
  [[ -f $ROOT$f ]] || continue
  in_chroot dpkg-divert --quiet --local --rename --add "$f"
done
if [[ -d $ROOT/usr/share/plymouth/themes/spinner ]]; then
  rsvg-convert -w 160 -h 160 "$AF/assets/icons/attackframe.svg" -o "$ROOT/usr/share/plymouth/ubuntu-logo.png"
  rsvg-convert -h 64 "$AF/assets/gdm-logo.svg" -o "$ROOT/usr/share/plymouth/themes/spinner/watermark.png"
fi
printf 'AttackFrame OS \\n \\l\n\n' > "$ROOT/etc/issue"
echo 'AttackFrame OS' > "$ROOT/etc/issue.net"

# the initramfs carries casper.conf (live user) and the splash: regenerate it now
log "Regenerating the initramfs"
in_chroot update-initramfs -u -k all

# ======================================================================= tool layers
mkdir -p "$IMGDIR" "$ROOT/var/lib/attackframe"

build_layer() {   # build_layer <kali|blackarch> <list> [build-args...]
  local layer=$1 list=$2; shift 2
  local ctx=$WORK/ctx-$layer
  mkdir -p "$ctx"
  cp "$AF/containers/$layer/Containerfile" "$ctx/"
  cp "$list" "$ctx/packages.txt"
  log "Building the $layer layer image (large download, be patient)"
  docker build --network host --pull -f "$ctx/Containerfile" \
    -t "attackframe/$layer:latest" "$@" "$ctx"
}

if [[ $TOOLSET == minimal ]]; then
  log "TOOLSET=minimal: no layer images baked in; they are pulled on first use"
else
  kali_meta=${KALI_META:-}; ba_groups=""
  [[ $TOOLSET == large ]] && { kali_meta=${kali_meta:-kali-linux-default}; ba_groups=$BA_GROUPS; }
  build_layer kali "$AF/packages/kali-core.txt" \
    --build-arg BASE="$KALI_IMAGE" --build-arg META="$kali_meta"
  build_layer blackarch "$AF/packages/blackarch-core.txt" \
    --build-arg BASE="$BLACKARCH_BASE" --build-arg STRAP_SHA1="${STRAP_SHA1:-}" --build-arg GROUPS="$ba_groups"

  # which grid tools each image provides → shims in /usr/local/bin
  log "Indexing layer binaries for app-grid shims"
  mapfile -t tsv_bins < <(awk -F'\t' '!/^#/ && NF>=5 {split($5,a," "); print a[1]}' \
    "$ROOT/usr/share/attackframe/tools.tsv" | sort -u)
  for layer in kali blackarch; do
    docker run --rm --network none --entrypoint sh "attackframe/$layer:latest" \
      -c 'for b; do command -v "$b" >/dev/null 2>&1 && echo "$b"; done; true' _ "${tsv_bins[@]}" \
      | tr -d '\r' | sort -u > "$ROOT/var/lib/attackframe/bins-$layer.txt"
    log "$layer layer: $(wc -l < "$ROOT/var/lib/attackframe/bins-$layer.txt") grid tools"
    log "Saving the $layer image into the ISO"
    docker save -o "$IMGDIR/$layer.tar" "attackframe/$layer:latest"
    chmod 644 "$IMGDIR/$layer.tar"   # docker load reads it client-side, as the user
  done
  bash "$ROOT/usr/local/bin/attackframe-box" sync --root "$ROOT"
fi

# ======================================================================= Secure Boot
# Ubuntu's Microsoft-signed shim + Canonical-signed GRUB, as on Ubuntu's own ISOs.
# The ISO's UEFI path uses them, and attackframe-install puts them on the disk.
SB=0
sbx=$WORK/secureboot
rm -rf "$sbx"; mkdir -p "$sbx/x"
if (cd "$sbx" && apt-get download shim-signed grub-efi-amd64-signed >/dev/null 2>&1); then
  for d in "$sbx"/*.deb; do dpkg-deb -x "$d" "$sbx/x"; done
  SHIM=$sbx/x/usr/lib/shim/shimx64.efi.signed.latest
  MOKMGR=$sbx/x/usr/lib/shim/mmx64.efi
  GRUB_CD=$sbx/x/usr/lib/grub/x86_64-efi-signed/gcdx64.efi.signed
  GRUB_DISK=$sbx/x/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed
  if [[ -f $SHIM && -f $MOKMGR && -f $GRUB_CD && -f $GRUB_DISK ]]; then
    SB=1
    install -Dm644 "$SHIM" "$ROOT/usr/share/attackframe/secureboot/shimx64.efi"
    install -Dm644 "$MOKMGR" "$ROOT/usr/share/attackframe/secureboot/mmx64.efi"
    install -Dm644 "$GRUB_DISK" "$ROOT/usr/share/attackframe/secureboot/grubx64.efi"
    log "Secure Boot: signed shim + GRUB included"
  fi
fi
((SB)) || warn "signed shim/GRUB unavailable — the ISO will need Secure Boot turned off"

# ======================================================================= finalize rootfs
log "Finalising root filesystem"
in_chroot apt-get -y autoremove --purge >/dev/null || true
in_chroot apt-get clean
unmount_all
rm -f "$ROOT/usr/sbin/policy-rc.d"
rm -rf "$ROOT"/tmp/* "$ROOT"/var/lib/apt/lists/* "$ROOT"/root/.bash_history
ln -sf ../run/systemd/resolve/stub-resolv.conf "$ROOT/etc/resolv.conf"
: > "$ROOT/etc/machine-id"; rm -f "$ROOT/var/lib/dbus/machine-id"

# ======================================================================= ISO tree
log "Building ISO tree"
mkdir -p "$ISO/casper" "$ISO/boot/grub" "$ISO/.disk" "$WORK/grub"
kver=$(find "$ROOT/boot" -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' | sed 's/^vmlinuz-//' | sort -V | tail -1)
[[ -n $kver ]] || die "no kernel found in the root filesystem"
cp "$ROOT/boot/vmlinuz-$kver" "$ISO/casper/vmlinuz"
cp "$ROOT/boot/initrd.img-$kver" "$ISO/casper/initrd"
chroot "$ROOT" dpkg-query -W --showformat='${Package} ${Version}\n' > "$ISO/casper/filesystem.manifest"
du -sx --block-size=1 "$ROOT" | cut -f1 > "$ISO/casper/filesystem.size"
echo "AttackFrame OS $(date +%Y.%m.%d) - ubuntu $SUITE amd64" > "$ISO/.disk/info"
touch "$ISO/attackframe"

log "Squashing the root filesystem (zstd -$SQUASHFS_LEVEL)"
mksquashfs "$ROOT" "$ISO/casper/filesystem.squashfs" -noappend -comp zstd \
  -Xcompression-level "${SQUASHFS_LEVEL:-15}" -b 1M -wildcards \
  -e 'proc/*' 'sys/*' 'dev/*' 'run/*' 'tmp/*' 'var/cache/apt/archives/*.deb'

rsvg-convert -w 1920 -h 1080 "$AF/assets/splash.svg" -o "$ISO/boot/grub/splash.png" || true

cat > "$WORK/grub/grub.cfg" <<'EOF'
search --no-floppy --set=root --file /attackframe
# graphical splash on UEFI; legacy BIOS stays in text mode (core image size limit)
if [ "$grub_platform" = "efi" ]; then
  insmod all_video
  insmod gfxterm
  insmod gfxterm_background
  insmod png
  if loadfont unicode ; then
    set gfxmode=auto
    terminal_output gfxterm
    background_image /boot/grub/splash.png
  fi
fi
set menu_color_normal=light-cyan/black
set menu_color_highlight=black/light-cyan
set color_normal=light-cyan/black
set default=0
set timeout=8

menuentry "AttackFrame OS  //  live" {
  linux /casper/vmlinuz boot=casper quiet splash ---
  initrd /casper/initrd
}
menuentry "AttackFrame OS  //  live (copy to RAM)" {
  linux /casper/vmlinuz boot=casper toram quiet splash ---
  initrd /casper/initrd
}
menuentry "AttackFrame OS  //  live (persistent: casper-rw partition)" {
  linux /casper/vmlinuz boot=casper persistent quiet splash ---
  initrd /casper/initrd
}
menuentry "AttackFrame OS  //  live (safe graphics)" {
  linux /casper/vmlinuz boot=casper nomodeset ---
  initrd /casper/initrd
}
if [ "$grub_platform" = "efi" ]; then
  menuentry "UEFI firmware settings" { fwsetup }
fi
EOF
cp "$WORK/grub/grub.cfg" "$ISO/boot/grub/grub.cfg"

log "Building GRUB (BIOS + UEFI)"
grub-mkstandalone --format=x86_64-efi --output="$WORK/grub/bootx64.efi" \
  --locales="" --fonts="unicode" "boot/grub/grub.cfg=$WORK/grub/grub.cfg"
# UEFI boot files: shim -> signed GRUB (finds /.disk/info, reads /boot/grub/grub.cfg),
# or our unsigned standalone GRUB when the signed binaries aren't available
efi=$WORK/grub/efi; rm -rf "$efi"; mkdir -p "$efi"
if ((SB)); then
  cp "$SHIM" "$efi/BOOTX64.EFI"; cp "$GRUB_CD" "$efi/grubx64.efi"; cp "$MOKMGR" "$efi/mmx64.efi"
else
  cp "$WORK/grub/bootx64.efi" "$efi/BOOTX64.EFI"
fi
mkdir -p "$ISO/boot/grub/fonts"
cp /usr/share/grub/unicode.pf2 "$ISO/boot/grub/fonts/" 2>/dev/null || true
rm -f "$WORK/grub/efiboot.img"
dd if=/dev/zero of="$WORK/grub/efiboot.img" bs=1M count=16 status=none
mkfs.vfat -F 16 -n AF_EFI "$WORK/grub/efiboot.img" >/dev/null
LC_CTYPE=C mmd -i "$WORK/grub/efiboot.img" ::/EFI ::/EFI/BOOT
for f in "$efi"/*; do LC_CTYPE=C mcopy -i "$WORK/grub/efiboot.img" "$f" "::/EFI/BOOT/${f##*/}"; done

bios_mods="linux linux16 normal iso9660 biosdisk memdisk search search_fs_file tar ls configfile echo test part_msdos part_gpt"
grub-mkstandalone --format=i386-pc --output="$WORK/grub/core.img" \
  --install-modules="$bios_mods" --modules="linux normal iso9660 biosdisk search" \
  --locales="" --fonts="" "boot/grub/grub.cfg=$WORK/grub/grub.cfg"
cat /usr/lib/grub/i386-pc/cdboot.img "$WORK/grub/core.img" > "$WORK/grub/bios.img"

# plain EFI/BOOT tree too, for USB writers that copy files instead of dd-ing the image
mkdir -p "$ISO/EFI/BOOT"
cp "$efi"/* "$ISO/EFI/BOOT/"

(cd "$ISO" && find . -type f ! -name md5sum.txt ! -path './casper/filesystem.squashfs' -print0 \
  | xargs -0 md5sum > md5sum.txt)

OUTISO=$AF/out/attackframe-$(date +%Y.%m.%d)-amd64.iso
log "Writing $OUTISO"
xorriso -as mkisofs -iso-level 3 -full-iso9660-filenames -joliet -joliet-long -rational-rock \
  -volid "ATTACKFRAME" -output "$OUTISO" \
  -eltorito-boot boot/grub/bios.img -no-emul-boot -boot-load-size 4 -boot-info-table \
  --eltorito-catalog boot/grub/boot.cat --grub2-boot-info \
  --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
  -eltorito-alt-boot -e EFI/efiboot.img -no-emul-boot \
  -append_partition 2 0xef "$WORK/grub/efiboot.img" \
  -graft-points "/EFI/efiboot.img=$WORK/grub/efiboot.img" "/boot/grub/bios.img=$WORK/grub/bios.img" "$ISO"

(cd "$AF/out" && sha256sum "$(basename "$OUTISO")" > "$(basename "$OUTISO").sha256")
chown -R "${HOST_UID:-0}:${HOST_GID:-0}" "$AF/out" "$AF/.cache" 2>/dev/null || true

# ======================================================================= sanity
[[ -s $ROOT/etc/ssl/certs/ca-certificates.crt ]] || warn "CA bundle missing in the image — HTTPS will fail"
[[ $TOOLSET == minimal ]] || [[ -s $IMGDIR/kali.tar && -s $IMGDIR/blackarch.tar ]] || warn "layer images missing from the ISO"
log "Done: $OUTISO ($(du -h "$OUTISO" | cut -f1))"
