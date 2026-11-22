#!/usr/bin/env bash
# shellcheck disable=SC2054  # commas inside QEMU options are intentional
# Boot an AttackFrame ISO in QEMU to test it.
#
#   ./scripts/test-iso.sh                    # newest out/*.iso, UEFI, with a blank 60G disk attached
#   ./scripts/test-iso.sh --secureboot       # UEFI with Secure Boot enforced (Microsoft keys enrolled)
#   ./scripts/test-iso.sh --bios             # legacy BIOS
#   ./scripts/test-iso.sh --boot-disk        # boot the test disk you installed to (no ISO)
#   ./scripts/test-iso.sh --fresh-disk       # wipe the test disk first
#   ./scripts/test-iso.sh --iso path.iso --mem 12G --cpus 6 --headless
#
# Typical run:   ./build.sh && ./scripts/test-iso.sh
# then in the VM: try the desktop, `kali nmap --version`, `blackarch katana -h`,
#                 `sudo attackframe-install /dev/vda --user test`, power off,
#                 and:            ./scripts/test-iso.sh --boot-disk
# (use the same --secureboot/--bios flag for --boot-disk as for the install)
#
# Needs: sudo apt install qemu-system-x86 ovmf     (+ KVM: your user in the 'kvm' group)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STATE=$HERE/.work/test-vm
mkdir -p "$STATE"

FW=uefi ISO="" MEM=8G CPUS=$(( $(nproc) > 4 ? 4 : $(nproc) )) DISK_SIZE=60G
BOOT_DISK=0 FRESH=0 HEADLESS=0
while (($#)); do
  case $1 in
    --uefi) FW=uefi ;;
    --secureboot|--sb) FW=secureboot ;;
    --bios|--legacy) FW=bios ;;
    --boot-disk) BOOT_DISK=1 ;;
    --fresh-disk) FRESH=1 ;;
    --iso) ISO=${2:?}; shift ;;
    --mem) MEM=${2:?}; shift ;;
    --cpus) CPUS=${2:?}; shift ;;
    --disk-size) DISK_SIZE=${2:?}; shift ;;
    --headless) HEADLESS=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done

die() { echo "!! $*" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || die "QEMU missing: sudo apt install qemu-system-x86 ovmf"

# ---- firmware ---------------------------------------------------------------
fw_args=()
pick() { local f; for f in "$@"; do [[ -f $f ]] && { echo "$f"; return; }; done; }
case $FW in
  uefi)
    code=$(pick /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/ovmf/OVMF_CODE.fd)
    vars=$(pick /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/ovmf/OVMF_VARS.fd)
    [[ -n $code && -n $vars ]] || die "UEFI firmware missing: sudo apt install ovmf"
    [[ -f $STATE/vars-uefi.fd ]] || cp "$vars" "$STATE/vars-uefi.fd"
    fw_args=(-machine q35,accel=kvm:tcg
      -drive "if=pflash,format=raw,unit=0,file=$code,readonly=on"
      -drive "if=pflash,format=raw,unit=1,file=$STATE/vars-uefi.fd") ;;
  secureboot)
    code=$(pick /usr/share/OVMF/OVMF_CODE_4M.secboot.fd /usr/share/OVMF/OVMF_CODE.secboot.fd /usr/share/edk2/x64/OVMF_CODE.secboot.4m.fd)
    vars=$(pick /usr/share/OVMF/OVMF_VARS_4M.ms.fd /usr/share/OVMF/OVMF_VARS.ms.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd)
    [[ -n $code && -n $vars ]] || die "Secure Boot firmware missing: sudo apt install ovmf"
    [[ -f $STATE/vars-secureboot.fd ]] || cp "$vars" "$STATE/vars-secureboot.fd"
    fw_args=(-machine q35,smm=on,accel=kvm:tcg -global driver=cfi.pflash01,property=secure,value=on
      -drive "if=pflash,format=raw,unit=0,file=$code,readonly=on"
      -drive "if=pflash,format=raw,unit=1,file=$STATE/vars-secureboot.fd") ;;
  bios)
    fw_args=(-machine pc,accel=kvm:tcg) ;;
esac

# ---- media -------------------------------------------------------------------
DISK=$STATE/disk.qcow2
if ((FRESH)); then rm -f "$DISK" "$STATE"/vars-*.fd; fi
media=()
if ((BOOT_DISK)); then
  [[ -f $DISK ]] || die "no test disk yet — boot the ISO and run attackframe-install /dev/vda first"
  media=(-drive "file=$DISK,if=virtio,format=qcow2")
else
  if [[ -z $ISO ]]; then
    ISO=$(ls -t "$HERE"/out/attackframe-*.iso 2>/dev/null | head -1 || true)
    [[ -n $ISO ]] || die "no ISO in out/ — run ./build.sh first"
  fi
  [[ -r $ISO ]] || die "can't read $ISO"
  if [[ -f $ISO.sha256 ]]; then
    echo ">> verifying $(basename "$ISO")…"
    (cd "$(dirname "$ISO")" && sha256sum -c --quiet "$(basename "$ISO").sha256") || die "checksum mismatch"
  fi
  [[ -f $DISK ]] || qemu-img create -q -f qcow2 "$DISK" "$DISK_SIZE"
  media=(-drive "file=$ISO,media=cdrom,readonly=on" -drive "file=$DISK,if=virtio,format=qcow2" -boot order=d)
fi

# ---- acceleration / display ---------------------------------------------------
accel=(-cpu host)
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
  echo "!! no KVM access — it will be VERY slow (sudo usermod -aG kvm $(id -un), then log in again)"
  accel=(-cpu max)
fi
if ((HEADLESS)); then
  display=(-display none -vnc 127.0.0.1:1 -device virtio-vga)
  echo ">> headless: connect a VNC viewer to 127.0.0.1:5901"
else
  display=(-display gtk,zoom-to-fit=on -device virtio-vga)
fi

echo ">> $( ((BOOT_DISK)) && echo "installed disk" || basename "$ISO" )  firmware=$FW  mem=$MEM  cpus=$CPUS"
echo "   test disk: $DISK (in the VM: /dev/vda)"
exec qemu-system-x86_64 "${fw_args[@]}" "${accel[@]}" -smp "$CPUS" -m "$MEM" \
  "${media[@]}" "${display[@]}" \
  -nic user,model=virtio-net-pci \
  -device qemu-xhci -device usb-tablet \
  -audiodev none,id=snd0 -name "AttackFrame test ($FW)"
