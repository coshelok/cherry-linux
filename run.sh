#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
CHERRY_VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
ISO="${ISO:-$BUILD_DIR/cherrylinux-v${CHERRY_VERSION}.iso}"

MEM="${MEM:-1024}"
CPUS="${CPUS:-2}"

log() { printf '\033[1;34m[RUN]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

command -v qemu-system-x86_64 >/dev/null 2>&1 || die "Required command not found: qemu-system-x86_64"
[[ -f "$ISO" ]] || die "ISO not found: $ISO (run ./build.sh first)"

accel=( -accel tcg )
if [[ -w /dev/kvm ]]; then
    accel=( -enable-kvm )
else
    log "KVM is not available (or not writable); falling back to TCG emulation"
fi

read -r -a extra <<< "${QEMU_EXTRA:-}"

log "Booting $ISO (${CPUS} vCPU, ${MEM} MiB RAM)"
exec qemu-system-x86_64 \
    "${accel[@]}" \
    -m "$MEM" \
    -smp "$CPUS" \
    -cdrom "$ISO" \
    -boot d \
    -vga std \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    "${extra[@]}"
