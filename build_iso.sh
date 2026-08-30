#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_ISO="$PROJECT_DIR/../cherrylinux-v0.4.iso"

echo "=========================================="
echo "    Building Cherry Linux Bootable ISO    "
echo "=========================================="

HOST_TOOLS_DIR="$PROJECT_DIR/.host_tools"
mkdir -p "$HOST_TOOLS_DIR/bin"
export PATH="$HOST_TOOLS_DIR/bin:$PATH"

if ! command -v mksquashfs >/dev/null 2>&1; then
    echo "[INFO] mksquashfs not found on host. Compiling light version locally..."
    wget -q https://github.com/plougher/squashfs-tools/archive/refs/tags/4.6.1.tar.gz -O "$HOST_TOOLS_DIR/sq.tar.gz"
    tar -xf "$HOST_TOOLS_DIR/sq.tar.gz" -C "$HOST_TOOLS_DIR"
    make -C "$HOST_TOOLS_DIR/squashfs-tools-4.6.1/squashfs-tools" GZIP_SUPPORT=1 XZ_SUPPORT=0 LZO_SUPPORT=0 LZ4_SUPPORT=0 ZSTD_SUPPORT=0 mksquashfs >/dev/null
    cp "$HOST_TOOLS_DIR/squashfs-tools-4.6.1/squashfs-tools/mksquashfs" "$HOST_TOOLS_DIR/bin/"
fi

if ! command -v xorriso >/dev/null 2>&1; then
    echo "[INFO] xorriso not found on host. Compiling from GNU source..."
    wget -q https://ftp.gnu.org/gnu/xorriso/xorriso-1.5.6.pl02.tar.gz -O "$HOST_TOOLS_DIR/xorriso.tar.gz"
    mkdir -p "$HOST_TOOLS_DIR/xorriso_src"
    tar -xf "$HOST_TOOLS_DIR/xorriso.tar.gz" -C "$HOST_TOOLS_DIR/xorriso_src" --strip-components=1
    cd "$HOST_TOOLS_DIR/xorriso_src"
    ./configure --prefix="$HOST_TOOLS_DIR" --disable-shared --enable-static >/dev/null
    make -j$(nproc) >/dev/null
    make install >/dev/null
    cd "$PROJECT_DIR"
fi

echo "[INFO] Injecting standard Linux utilities (BusyBox)..."
mkdir -p "$PROJECT_DIR/rootfs/bin"

if [ ! -f "$PROJECT_DIR/busybox" ]; then
    echo "[INFO] Downloading static BusyBox..."
    wget -q -O "$PROJECT_DIR/busybox" https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox
    chmod +x "$PROJECT_DIR/busybox"
fi

cp "$PROJECT_DIR/busybox" "$PROJECT_DIR/rootfs/bin/busybox"

echo "[INFO] Creating symlinks for missing commands..."
cd "$PROJECT_DIR/rootfs/bin"
./busybox --list | while read -r cmd; do
    if [ ! -f "$cmd" ]; then
        ln -sf busybox "$cmd"
    fi
done
cd "$PROJECT_DIR"

echo "[INFO] Preparing cherryfetch..."
if [ -f "$PROJECT_DIR/cherry_utils/cherryfetch" ]; then
    cp "$PROJECT_DIR/cherry_utils/cherryfetch" "$PROJECT_DIR/rootfs/bin/cherryfetch"
    chmod +x "$PROJECT_DIR/rootfs/bin/cherryfetch"
    echo "[SUCCESS] cherryfetch added to rootfs/bin/cherryfetch"
else
    echo "[WARNING] cherryfetch not found, skipping..."
fi

echo "[INFO] Rebuilding rootfs.sfs image (SquashFS)..."
rm -f "$PROJECT_DIR/rootfs.sfs"
mksquashfs "$PROJECT_DIR/rootfs" "$PROJECT_DIR/rootfs.sfs"

echo "[INFO] Compiling custom init.c and updating initramfs..."
gcc -static "$PROJECT_DIR/init_src/init.c" -o "$PROJECT_DIR/init"

mkdir -p "$PROJECT_DIR/boot"
(cd "$PROJECT_DIR" && echo "init" | cpio -o -H newc) | gzip -9 > "$PROJECT_DIR/boot/init.cpio.gz"
rm -f "$PROJECT_DIR/init"

if [ ! -f "$PROJECT_DIR/kernel/linux-7.0.10/arch/x86/boot/bzImage" ]; then
    echo "[ERROR] Missing bzImage!" && exit 1
fi

echo "[INFO] Creating clean ISO staging directory..."
STAGING_DIR="$PROJECT_DIR/iso_staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/boot"

cp "$PROJECT_DIR/kernel/linux-7.0.10/arch/x86/boot/bzImage" "$STAGING_DIR/boot/"
cp "$PROJECT_DIR/init.cpio.gz" "$STAGING_DIR/boot/"
cp "$PROJECT_DIR/rootfs.sfs" "$STAGING_DIR/boot/"

echo "[INFO] Copying Limine bootloaders..."
cp "$HOST_TOOLS_DIR/limine/limine-bios.sys" "$STAGING_DIR/"
cp "$HOST_TOOLS_DIR/limine/limine-bios-cd.bin" "$STAGING_DIR/"
cp "$HOST_TOOLS_DIR/limine/limine-uefi-cd.bin" "$STAGING_DIR/"

cat << 'EOF' > "$STAGING_DIR/limine.conf"
timeout: 3

/Cherry Linux (Текстовая консоль)
    protocol: linux
    kernel_path: boot():/boot/bzImage
    module_path: boot():/boot/init.cpio.gz
    cmdline: quiet rw console=tty0 loglevel=3
EOF

echo "[INFO] Packaging ISO with xorriso..."
xorriso -as mkisofs -b limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    --efi-boot limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    "$STAGING_DIR" -o "$OUTPUT_ISO"

echo "[INFO] Cleaning up staging..."
rm -rf "$STAGING_DIR"

echo "[INFO] Deploying Limine MBR boot record onto the ISO..."
"$PROJECT_DIR/limine" bios-install "$OUTPUT_ISO"

echo "=========================================="
echo "[SUCCESS] Bootable cross-platform ISO built: $OUTPUT_ISO"
echo "=========================================="