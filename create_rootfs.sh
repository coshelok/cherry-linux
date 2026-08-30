#!/bin/bash
set -e
set -o pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$PROJECT_DIR/rootfs"
BUILD_DIR="$PROJECT_DIR/sources"
THREADS=$(nproc)

log() { printf "\033[1;34m[BUILD]\033[0m %s\n" "$*"; }
die() { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*"; exit 1; }

# ========== FHS Setup ==========
log "Creating FHS directory structure in $TARGET_DIR..."
rm -rf "$TARGET_DIR"
mkdir -p "$TARGET_DIR"/{bin,sbin,lib,lib64,etc,proc,sys,dev,root,home,tmp,mnt,run,srv,opt,cdrom}
mkdir -p "$TARGET_DIR"/usr/{bin,sbin,lib,include,share}
mkdir -p "$TARGET_DIR"/var/{log,run,tmp,cache,lib/chepm/manifests}

ln -sf usr/bin  "$TARGET_DIR/bin"
ln -sf usr/sbin "$TARGET_DIR/sbin"
ln -sf usr/lib  "$TARGET_DIR/lib"
ln -sf usr/lib  "$TARGET_DIR/lib64"

# ========== Build Environment ==========
export CFLAGS="-std=gnu11 -fpermissive -Wno-error -Wno-error=implicit-function-declaration -Wno-error=incompatible-pointer-types -Wno-error=old-style-definition -Wno-error=return-type -Wno-implicit-int -Wno-error=strict-prototypes"
export CXXFLAGS="$CFLAGS"
export CC=gcc
export CXX=g++

# ========== Package List (name|url|conf|post_install) ==========
PKGS=(
    "bash|https://ftp.gnu.org/gnu/bash/bash-5.2.32.tar.gz|--without-curses|ln -sf bash $TARGET_DIR/usr/bin/sh"
    "coreutils|https://ftp.gnu.org/gnu/coreutils/coreutils-9.5.tar.xz|--enable-install-program=hostname|"
    "grep|https://ftp.gnu.org/gnu/grep/grep-3.11.tar.xz||"
    "sed|https://ftp.gnu.org/gnu/sed/sed-4.9.tar.xz||"
    "gawk|https://ftp.gnu.org/gnu/gawk/gawk-5.3.0.tar.xz||"
    "findutils|https://ftp.gnu.org/gnu/findutils/findutils-4.10.0.tar.xz||"
    "diffutils|https://ftp.gnu.org/gnu/diffutils/diffutils-3.11.tar.xz||"
    "tar|https://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz|--without-xattrs --without-posix-acls|"
    "gzip|https://ftp.gnu.org/gnu/gzip/gzip-1.13.tar.xz||"
    "bzip2|https://sourceware.org/ftp/bzip2/bzip2-1.0.8.tar.gz|--prefix=/usr|"
    "xz|https://github.com/tukaani-project/xz/releases/download/v5.6.3/xz-5.6.3.tar.xz||"
    "make|https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz||"
    "patch|https://ftp.gnu.org/gnu/patch/patch-2.7.6.tar.gz||"
    )

mkdir -p "$BUILD_DIR"

# ========== Build Process ==========
for entry in "${PKGS[@]}"; do
    name=$(echo "$entry" | cut -d'|' -f1)
    url=$(echo "$entry" | cut -d'|' -f2)
    conf=$(echo "$entry" | cut -d'|' -f3)
    post=$(echo "$entry" | cut -d'|' -f4)
    log ">>> Processing $name"
    
    archive_name=$(basename "$url")
    archive="$BUILD_DIR/$archive_name"
    
    WAS_DOWNLOADED=0
    if [ ! -f "$archive" ]; then
        log "  [$name] Downloading from $url..."
        wget -q "$url" -O "$archive"
        WAS_DOWNLOADED=1
    else
        log "  [$name] Archive already exists ($archive_name), skipping download."
    fi
    
    dir="$BUILD_DIR/$name"
    NEED_CONFIGURE=0
    
    if [ "$WAS_DOWNLOADED" -eq 1 ] || [ ! -d "$dir" ]; then
        log "  [$name] Extracting archive..."
        rm -rf "$dir" && mkdir -p "$dir"
        tar -xf "$archive" -C "$dir" --strip-components=1
        NEED_CONFIGURE=1
    else
        log "  [$name] Source directory already exists, using incremental build."
    fi
    
    pushd "$dir" > /dev/null
    
    if [ -f configure ]; then
        if [ "$NEED_CONFIGURE" -eq 1 ] || [ ! -f Makefile ]; then
            log "  [$name] Running configure..."
            ./configure --prefix=/usr --sysconfdir=/etc $conf
        fi
        log "  [$name] Running make -j$THREADS..."
        make -j"$THREADS"
        log "  [$name] Running make install..."
        make DESTDIR="$TARGET_DIR" install
    elif [ -f configure.ac ]; then
        if [ "$NEED_CONFIGURE" -eq 1 ] || [ ! -f Makefile ]; then
            log "  [$name] Autotools project detected. Running autoreconf & configure..."
            autoreconf -fi
            ./configure --prefix=/usr --sysconfdir=/etc $conf
        fi
        log "  [$name] Running make -j$THREADS..."
        make -j"$THREADS"
        log "  [$name] Running make install..."
        make DESTDIR="$TARGET_DIR" install
    elif [ -f Makefile ]; then
        log "  [$name] Simple Makefile project detected. Building..."
        log "  [$name] Running make -j$THREADS..."
        make -j"$THREADS"
        log "  [$name] Attempting installation via DESTDIR..."
        if make DESTDIR="$TARGET_DIR" install; then
            log "  [$name] Standard DESTDIR install successful."
        else
            log "  [$name] Standard DESTDIR install failed. Attempting manual copy..."
            if [ "$name" = "bzip2" ]; then
                mkdir -p "$TARGET_DIR/usr/bin" "$TARGET_DIR/usr/lib"
                cp -v bzip2 "$TARGET_DIR/usr/bin/"
                cp -v libbz2.a "$TARGET_DIR/usr/lib/"
                cp -v libbz2.so "$TARGET_DIR/usr/lib/" 2>/dev/null || true
                log "  [$name] Manual copy successful."
            else
                die "  [$name] Installation failed and no fallback implemented."
            fi
        fi
    else
        die "  [$name] No configure or Makefile found!"
    fi

    [ -n "$post" ] && eval "$post"
    popd > /dev/null
    log ">>> Finished processing $name"
done

# ========== Shared Libraries ==========
log "Copying shared libraries from host (safe method)..."
while IFS= read -r bin_file; do
    if file "$bin_file" | grep -q "ELF"; then
        ldd "$bin_file" 2>/dev/null | awk '/=> \// {print $3}' | while read -r lib; do
            if [ -f "$lib" ] && [ ! -f "$TARGET_DIR/usr/lib/$(basename "$lib")" ]; then
                cp -v "$lib" "$TARGET_DIR/usr/lib/"
            fi
        done
    fi
done < <(find "$TARGET_DIR"/usr/bin "$TARGET_DIR"/usr/sbin -type f -executable 2>/dev/null)
ld_linux=$(ls /lib64/ld-linux-x86-64.so.2 2>/dev/null || ls /lib/ld-linux*.so* 2>/dev/null || true)
[ -n "$ld_linux" ] && cp -v "$ld_linux" "$TARGET_DIR/usr/lib/"

# ========== Cherry Utilities ==========
log "Installing custom Cherry utilities..."

if [ -f "$PROJECT_DIR/cherry_utils/chepm" ]; then
    cp -v "$PROJECT_DIR/cherry_utils/chepm" "$TARGET_DIR/bin/chepm"
    chmod +x "$TARGET_DIR/bin/chepm"
fi

if [ -f "$PROJECT_DIR/cherry_utils/cherryfetch" ]; then
    cp -v "$PROJECT_DIR/cherry_utils/cherryfetch" "$TARGET_DIR/bin/cherryfetch"
    chmod +x "$TARGET_DIR/bin/cherryfetch"
fi

# ========== System Config ==========
log "Generating system configuration..."
cat > "$TARGET_DIR/etc/passwd" <<EOF
root:x:0:0:root:/root:/bin/sh
cherry:x:1000:1000:User,,,:/home/cherry:/bin/sh
EOF

cat > "$TARGET_DIR/etc/shadow" <<EOF
root::19701:0:99999:7:::
cherry::19701:0:99999:7:::
EOF

cat > "$TARGET_DIR/etc/fstab" <<EOF
tmpfs    /run      tmpfs       defaults        0  0
tmpfs    /tmp      tmpfs       defaults        0  0
EOF

echo "cherrylinux" > "$TARGET_DIR/etc/hostname"
echo "/usr/lib" > "$TARGET_DIR/etc/ld.so.conf"

log "Rootfs build complete! Target: $TARGET_DIR"