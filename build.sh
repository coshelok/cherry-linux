#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
ROOTFS_DIR="${ROOTFS_DIR:-$BUILD_DIR/rootfs}"
SOURCES_DIR="${SOURCES_DIR:-$BUILD_DIR/sources}"
HOST_TOOLS_DIR="${HOST_TOOLS_DIR:-$BUILD_DIR/host-tools}"
INITRAMFS="${INITRAMFS:-$BUILD_DIR/init.cpio.gz}"
ROOTFS_SFS="${ROOTFS_SFS:-$BUILD_DIR/rootfs.sfs}"
STAGING_DIR="${STAGING_DIR:-$BUILD_DIR/iso-staging}"
OUTPUT_ISO="${OUTPUT_ISO:-$BUILD_DIR/cherrylinux-v0.4.iso}"

INIT_SOURCE="$PROJECT_DIR/src/init.c"
ROOTFS_SCRIPT="$PROJECT_DIR/rootfs.sh"
KERNEL_IMAGE="$PROJECT_DIR/kernel/linux-7.0.10/arch/x86/boot/bzImage"
LIMINE_DIR="$PROJECT_DIR/tools/limine-src"

# Set ENABLE_BUSYBOX=1 to keep the old BusyBox fallback/rescue helpers.
ENABLE_BUSYBOX="${ENABLE_BUSYBOX:-0}"
REBUILD_ROOTFS="${REBUILD_ROOTFS:-0}"

log()  { printf '\033[1;34m[BUILD]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

for cmd in gcc cpio make tar wget nproc chmod cp rm find install; do
    need "$cmd"
done

[[ -f "$ROOTFS_SCRIPT" ]] || die "Missing $ROOTFS_SCRIPT"
[[ -f "$INIT_SOURCE" ]] || die "Missing $INIT_SOURCE"
[[ -f "$KERNEL_IMAGE" ]] || die "Missing kernel image: $KERNEL_IMAGE"
[[ -x "$LIMINE_DIR/limine" ]] || die "Missing Limine executable: $LIMINE_DIR/limine"
[[ -f "$LIMINE_DIR/limine-bios.sys" ]] || die "Missing Limine BIOS binary"
[[ -f "$LIMINE_DIR/limine-bios-cd.bin" ]] || die "Missing Limine BIOS CD binary"
[[ -f "$LIMINE_DIR/limine-uefi-cd.bin" ]] || die "Missing Limine UEFI CD binary"

mkdir -p "$BUILD_DIR" "$HOST_TOOLS_DIR/bin" "$SOURCES_DIR"
export PATH="$HOST_TOOLS_DIR/bin:$PATH"

build_mksquashfs() {
    if command -v mksquashfs >/dev/null 2>&1; then
        return
    fi

    log "mksquashfs not found; building SquashFS tools 4.6.1 in $HOST_TOOLS_DIR"
    local src_root="$HOST_TOOLS_DIR/src/squashfs-tools-4.6.1"
    local archive="$HOST_TOOLS_DIR/src/squashfs-tools-4.6.1.tar.gz"

    mkdir -p "$(dirname "$archive")"
    wget -q --tries=3 --timeout=30 \
        "https://github.com/plougher/squashfs-tools/archive/refs/tags/4.6.1.tar.gz" \
        -O "$archive"

    rm -rf "$src_root"
    mkdir -p "$HOST_TOOLS_DIR/src"
    tar -xf "$archive" -C "$HOST_TOOLS_DIR/src"

    make -C "$src_root/squashfs-tools" \
        GZIP_SUPPORT=1 XZ_SUPPORT=0 LZO_SUPPORT=0 LZ4_SUPPORT=0 ZSTD_SUPPORT=0 \
        mksquashfs >/dev/null

    install -Dm755 \
        "$src_root/squashfs-tools/mksquashfs" \
        "$HOST_TOOLS_DIR/bin/mksquashfs"
}

build_xorriso() {
    if command -v xorriso >/dev/null 2>&1; then
        return
    fi

    log "xorriso not found; building xorriso 1.5.6.pl02 in $HOST_TOOLS_DIR"
    local src_dir="$HOST_TOOLS_DIR/src/xorriso"
    local archive="$HOST_TOOLS_DIR/src/xorriso-1.5.6.pl02.tar.gz"

    mkdir -p "$HOST_TOOLS_DIR/src"
    wget -q --tries=3 --timeout=30 \
        "https://ftp.gnu.org/gnu/xorriso/xorriso-1.5.6.pl02.tar.gz" \
        -O "$archive"

    rm -rf "$src_dir"
    mkdir -p "$src_dir"
    tar -xf "$archive" -C "$src_dir" --strip-components=1

    pushd "$src_dir" >/dev/null
    ./configure --prefix="$HOST_TOOLS_DIR" --disable-shared --enable-static >/dev/null
    make -j"$(nproc)" >/dev/null
    make install >/dev/null
    popd >/dev/null
}

build_mksquashfs
build_xorriso
need mksquashfs
need xorriso

if [[ ! -d "$ROOTFS_DIR" || ! -x "$ROOTFS_DIR/bin/sh" || "$REBUILD_ROOTFS" == "1" ]]; then
    log "Building rootfs"
    "$ROOTFS_SCRIPT"
else
    log "Using existing rootfs at $ROOTFS_DIR"
    log "Set REBUILD_ROOTFS=1 to rebuild it from scratch"
fi

[[ -x "$ROOTFS_DIR/bin/sh" ]] || die "rootfs/bin/sh is missing or not executable"
[[ -f "$ROOTFS_DIR/etc/os-release" ]] || die "rootfs/etc/os-release is missing"

if [[ "$ENABLE_BUSYBOX" == "1" ]]; then
    BUSYBOX_SRC="$PROJECT_DIR/tools/busybox"
    if [[ ! -f "$BUSYBOX_SRC" ]]; then
        log "Downloading optional static BusyBox"
        mkdir -p "$PROJECT_DIR/tools"
        wget -q --tries=3 --timeout=30 -O "$BUSYBOX_SRC" \
            "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
        chmod +x "$BUSYBOX_SRC"
    fi

    chmod +x "$BUSYBOX_SRC"
    "$BUSYBOX_SRC" --help >/dev/null 2>&1 || die "Invalid BusyBox binary"
    install -Dm755 "$BUSYBOX_SRC" "$ROOTFS_DIR/usr/bin/busybox"

    (
        cd "$ROOTFS_DIR/usr/bin"
        while IFS= read -r cmd; do
            [[ -n "$cmd" ]] || continue
            [[ -e "$cmd" ]] || ln -s busybox "$cmd"
        done < <(./busybox --list)
    )
    log "Optional BusyBox compatibility layer enabled"
else
    rm -f "$ROOTFS_DIR/usr/bin/busybox"
    log "BusyBox disabled (GNU userspace is the default)"
fi

log "Building SquashFS image"
rm -f "$ROOTFS_SFS"
mksquashfs "$ROOTFS_DIR" "$ROOTFS_SFS" \
    -comp gzip \
    -all-root \
    -no-xattrs \
    -noappend >/dev/null

log "Compiling static Cherry init"
INIT_BINARY="$BUILD_DIR/init"
gcc -static -std=gnu11 -Os -Wall -Wextra -Wpedantic \
    "$INIT_SOURCE" -o "$INIT_BINARY"

log "Packing initramfs"
rm -f "$INITRAMFS"
INITRAMFS_STAGE="$BUILD_DIR/initramfs-stage"
rm -rf "$INITRAMFS_STAGE"
mkdir -p "$INITRAMFS_STAGE"
install -Dm755 "$INIT_BINARY" "$INITRAMFS_STAGE/init"
(
    cd "$INITRAMFS_STAGE"
    printf '%s\n' init | cpio -o -H newc --owner=0:0 --reproducible
) | gzip -9 -n > "$INITRAMFS"
rm -rf "$INITRAMFS_STAGE" "$INIT_BINARY"

log "Creating ISO staging directory"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/boot"

cp "$KERNEL_IMAGE" "$STAGING_DIR/boot/bzImage"
cp "$INITRAMFS" "$STAGING_DIR/boot/init.cpio.gz"
cp "$ROOTFS_SFS" "$STAGING_DIR/boot/rootfs.sfs"
cp "$LIMINE_DIR/limine-bios.sys" "$STAGING_DIR/"
cp "$LIMINE_DIR/limine-bios-cd.bin" "$STAGING_DIR/"
cp "$LIMINE_DIR/limine-uefi-cd.bin" "$STAGING_DIR/"

cat > "$STAGING_DIR/limine.conf" <<'EOF_CFG'
timeout: 3
default_entry: 1

/Cherry Linux
    protocol: linux
    kernel_path: boot():/boot/bzImage
    module_path: boot():/boot/init.cpio.gz
    cmdline: loglevel=4 console=tty0
EOF_CFG

log "Packaging ISO"
rm -f "$OUTPUT_ISO"
xorriso -as mkisofs \
    -iso-level 3 \
    -R -J -joliet-long \
    -V CHERRYLINUX \
    -b limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    --efi-boot limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    "$STAGING_DIR" -o "$OUTPUT_ISO" >/dev/null

log "Installing Limine BIOS boot record"
"$LIMINE_DIR/limine" bios-install "$OUTPUT_ISO"

log "ISO ready: $OUTPUT_ISO"
ls -lh "$OUTPUT_ISO"
