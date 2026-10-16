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

BOOT_INIT_SOURCE="$PROJECT_DIR/src/boot_init.c"
RUNTIME_INIT_SOURCE="$PROJECT_DIR/src/init.c"
ROOTFS_SCRIPT="$PROJECT_DIR/rootfs.sh"
KERNEL_VERSION="${KERNEL_VERSION:-7.0.10}"
KERNEL_DIR_DEFAULT="$PROJECT_DIR/kernel/linux-$KERNEL_VERSION"
KERNEL_DIR="${KERNEL_DIR:-$KERNEL_DIR_DEFAULT}"
KERNEL_TARBALL_URL="${KERNEL_TARBALL_URL:-https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VERSION%%.*}.x/linux-${KERNEL_VERSION}.tar.xz}"
KERNEL_TARBALL_SHA256="${KERNEL_TARBALL_SHA256:-094977eb62c20e3d1939fe81a92958a1f987f339446e532fa86963b2804e32dc}"
KERNEL_CONFIG="$PROJECT_DIR/cherry.config"
KERNEL_IMAGE="$KERNEL_DIR/arch/x86/boot/bzImage"
LIMINE_DIR="$PROJECT_DIR/tools/limine-src"

SQUASHFS_TOOLS_VERSION="4.6.1"
SQUASHFS_TOOLS_SHA256="9c4974e07c61547dae14af4ed1f358b7d04618ae194e54d6be72ee126f0d2f53"
XORRISO_VERSION="1.5.6.pl02"
XORRISO_SHA256="786f9f5df9865cc5b0c1fecee3d2c0f5e04cab8c9a859bd1c9c7ccd4964fdae1"

ENABLE_BUSYBOX="${ENABLE_BUSYBOX:-0}"
ENABLE_NET="${ENABLE_NET:-1}"
REBUILD_ROOTFS="${REBUILD_ROOTFS:-0}"

export ENABLE_BUSYBOX ENABLE_NET

log()  { printf '\033[1;34m[BUILD]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

verify_sha256() {
    local file="$1" expected="$2"

    printf '%s  %s\n' "$expected" "$file" | sha256sum -c --status - \
        || die "Checksum mismatch for $(basename "$file"); remove it and retry"
}

# Download url to dest unless a valid copy is already cached there.
fetch_source() {
    local url="$1" dest="$2" sha="$3"

    if [[ -f "$dest" ]]; then
        verify_sha256 "$dest" "$sha"
        log "Using cached $(basename "$dest")"
        return 0
    fi

    log "Downloading $(basename "$dest")"
    wget -q --tries=3 --timeout=60 -O "$dest.part" "$url" \
        || die "$(basename "$dest"): download failed: $url"
    mv "$dest.part" "$dest"
    verify_sha256 "$dest" "$sha"
}

VERSION_FILE="$PROJECT_DIR/VERSION"
[[ -f "$VERSION_FILE" ]] || die "Missing version file: $VERSION_FILE"
CHERRY_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$CHERRY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || \
    die "Invalid Cherry Linux version: $CHERRY_VERSION"
OUTPUT_ISO="${OUTPUT_ISO:-$BUILD_DIR/cherrylinux-v${CHERRY_VERSION}.iso}"

cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

for cmd in gcc cpio make tar wget nproc chmod cp rm find install tr sha256sum; do
    need "$cmd"
done

[[ -f "$ROOTFS_SCRIPT" ]] || die "Missing $ROOTFS_SCRIPT"
[[ -f "$BOOT_INIT_SOURCE" ]] || die "Missing $BOOT_INIT_SOURCE"
[[ -f "$RUNTIME_INIT_SOURCE" ]] || die "Missing $RUNTIME_INIT_SOURCE"
[[ -f "$KERNEL_CONFIG" ]] || die "Missing kernel config: $KERNEL_CONFIG"
[[ -x "$LIMINE_DIR/limine" ]] || die "Missing Limine executable: $LIMINE_DIR/limine"
[[ -f "$LIMINE_DIR/limine-bios.sys" ]] || die "Missing Limine BIOS binary"
[[ -f "$LIMINE_DIR/limine-bios-cd.bin" ]] || die "Missing Limine BIOS CD binary"
[[ -f "$LIMINE_DIR/limine-uefi-cd.bin" ]] || die "Missing Limine UEFI CD binary"

mkdir -p "$BUILD_DIR" "$HOST_TOOLS_DIR/bin" "$HOST_TOOLS_DIR/src" "$SOURCES_DIR"
export PATH="$HOST_TOOLS_DIR/bin:$PATH"

build_kernel() {
    if [[ ! -d "$KERNEL_DIR" ]]; then
        [[ "$KERNEL_DIR" == "$KERNEL_DIR_DEFAULT" ]] || \
            die "KERNEL_DIR=$KERNEL_DIR does not exist (auto-download supports only the default path)"

        log "Kernel source tree not found; fetching Linux $KERNEL_VERSION"
        local tarball="$SOURCES_DIR/linux-$KERNEL_VERSION.tar.xz"
        fetch_source "$KERNEL_TARBALL_URL" "$tarball" "$KERNEL_TARBALL_SHA256"
        mkdir -p "$(dirname "$KERNEL_DIR")"
        tar -xf "$tarball" -C "$(dirname "$KERNEL_DIR")"
    fi

    log "Installing Cherry kernel config"
    cp "$KERNEL_CONFIG" "$KERNEL_DIR/.config"

    log "Normalizing kernel config"
    make -C "$KERNEL_DIR" olddefconfig >/dev/null

    log "Building Linux 7.0.10"
    make -C "$KERNEL_DIR" -j"$(nproc)" bzImage

    [[ -f "$KERNEL_IMAGE" ]] || die "Kernel build finished but bzImage was not produced: $KERNEL_IMAGE"
}

build_mksquashfs() {
    if command -v mksquashfs >/dev/null 2>&1; then
        return
    fi

    log "mksquashfs not found; building SquashFS tools $SQUASHFS_TOOLS_VERSION in $HOST_TOOLS_DIR"
    local src_root="$HOST_TOOLS_DIR/src/squashfs-tools-$SQUASHFS_TOOLS_VERSION"
    local archive="$HOST_TOOLS_DIR/src/squashfs-tools-$SQUASHFS_TOOLS_VERSION.tar.gz"

    fetch_source \
        "https://github.com/plougher/squashfs-tools/archive/refs/tags/$SQUASHFS_TOOLS_VERSION.tar.gz" \
        "$archive" "$SQUASHFS_TOOLS_SHA256"

    rm -rf "$src_root"
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

    log "xorriso not found; building xorriso $XORRISO_VERSION in $HOST_TOOLS_DIR"
    local src_dir="$HOST_TOOLS_DIR/src/xorriso"
    local archive="$HOST_TOOLS_DIR/src/xorriso-$XORRISO_VERSION.tar.gz"

    fetch_source "https://ftp.gnu.org/gnu/xorriso/xorriso-$XORRISO_VERSION.tar.gz" \
        "$archive" "$XORRISO_SHA256"

    rm -rf "$src_dir"
    mkdir -p "$src_dir"
    tar -xf "$archive" -C "$src_dir" --strip-components=1

    pushd "$src_dir" >/dev/null
    ./configure --prefix="$HOST_TOOLS_DIR" --disable-shared --enable-static >/dev/null
    make -j"$(nproc)" >/dev/null
    make install >/dev/null
    popd >/dev/null
}

build_kernel
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

if [[ "$ENABLE_NET" == "1" || "$ENABLE_BUSYBOX" == "1" ]]; then
    [[ -x "$ROOTFS_DIR/usr/bin/busybox" ]] || \
        die "rootfs is missing BusyBox; rebuild it with REBUILD_ROOTFS=1"
    log "BusyBox networking toolset present (built from source by rootfs.sh)"
fi

log "Compiling static Cherry bootstrap init"
BOOT_INIT_BINARY="$BUILD_DIR/boot-init"
gcc -static -std=gnu11 -Os -Wall -Wextra -Wpedantic \
    "$BOOT_INIT_SOURCE" -o "$BOOT_INIT_BINARY"

log "Compiling static Cherry runtime init"
RUNTIME_INIT_BINARY="$BUILD_DIR/runtime-init"
gcc -static -std=gnu11 -Os -Wall -Wextra -Wpedantic \
    "$RUNTIME_INIT_SOURCE" -o "$RUNTIME_INIT_BINARY"

log "Installing runtime init into rootfs"
install -Dm755 "$RUNTIME_INIT_BINARY" "$ROOTFS_DIR/usr/sbin/init"

log "Building SquashFS image"
rm -f "$ROOTFS_SFS"
mksquashfs "$ROOTFS_DIR" "$ROOTFS_SFS" \
    -comp gzip \
    -all-root \
    -no-xattrs \
    -noappend >/dev/null

log "Packing initramfs"
rm -f "$INITRAMFS"
INITRAMFS_STAGE="$BUILD_DIR/initramfs-stage"
rm -rf "$INITRAMFS_STAGE"
mkdir -p "$INITRAMFS_STAGE/bin"
install -Dm755 "$BOOT_INIT_BINARY" "$INITRAMFS_STAGE/init"
cpio_files=(init)
# The bootstrap init needs blkid to resolve the persistence store by
# label/UUID before the rootfs is live (no udev/mdev symlinks exist yet).
if [[ -x "$ROOTFS_DIR/usr/bin/busybox" ]]; then
    install -Dm755 "$ROOTFS_DIR/usr/bin/busybox" "$INITRAMFS_STAGE/bin/busybox"
    cpio_files+=(bin bin/busybox)
fi
(
    cd "$INITRAMFS_STAGE"
    printf '%s\n' "${cpio_files[@]}" | cpio -o -H newc --owner=0:0 --reproducible
) | gzip -9 -n > "$INITRAMFS"
rm -rf "$INITRAMFS_STAGE" "$BOOT_INIT_BINARY" "$RUNTIME_INIT_BINARY"

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
