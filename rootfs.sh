#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
TARGET_DIR="${ROOTFS_DIR:-$BUILD_DIR/rootfs}"
SOURCE_DIR="${SOURCES_DIR:-$BUILD_DIR/sources}"
THREADS="${THREADS:-$(nproc)}"
ROOTFS_PROFILE="${ROOTFS_PROFILE:-full}"

log()  { printf '\033[1;34m[ROOTFS]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

for cmd in gcc make wget tar file ldd find awk cut grep install tr; do
    need "$cmd"
done

VERSION_FILE="$PROJECT_DIR/VERSION"
if [[ -z "${CHERRY_VERSION:-}" ]]; then
    [[ -f "$VERSION_FILE" ]] || die "Missing version file: $VERSION_FILE"
    CHERRY_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
fi
[[ "$CHERRY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || \
    die "Invalid Cherry Linux version: $CHERRY_VERSION"

mkdir -p "$BUILD_DIR" "$SOURCE_DIR"

log "Creating root filesystem in $TARGET_DIR"
rm -rf "$TARGET_DIR"
mkdir -p \
    "$TARGET_DIR"/{etc,dev,proc,sys,root,home,tmp,run,mnt,srv,opt,cdrom} \
    "$TARGET_DIR/home/cherry" \
    "$TARGET_DIR/usr"/{bin,sbin,lib,include,share} \
    "$TARGET_DIR/var"/{log,tmp,cache,lib/chepm/manifests}

chmod 1777 "$TARGET_DIR/tmp" "$TARGET_DIR/var/tmp"

export CC="${CC:-gcc}"
export CXX="${CXX:-g++}"

# Bash 5.2.x contains pre-C23 function declarations/definitions.
# GCC 15+ defaults to GNU C23, where declarations such as `foo()`
# mean "takes no arguments" instead of "parameters unspecified".
# Keep the userspace build on GNU C17 unless the caller explicitly
# selected another C dialect.
export CFLAGS="${CFLAGS:--O2 -pipe}"
if [[ "$CFLAGS" != *-std=* ]]; then
    CFLAGS+=" -std=gnu17"
fi
export CXXFLAGS="${CXXFLAGS:-$CFLAGS}"

PKGS=(
    "bash|https://ftp.gnu.org/gnu/bash/bash-5.2.32.tar.gz|--without-curses"
    "coreutils|https://ftp.gnu.org/gnu/coreutils/coreutils-9.5.tar.xz|--enable-install-program=hostname"
    "grep|https://ftp.gnu.org/gnu/grep/grep-3.11.tar.xz|"
    "sed|https://ftp.gnu.org/gnu/sed/sed-4.9.tar.xz|"
    "gawk|https://ftp.gnu.org/gnu/gawk/gawk-5.3.0.tar.xz|"
    "findutils|https://ftp.gnu.org/gnu/findutils/findutils-4.10.0.tar.xz|"
    "diffutils|https://ftp.gnu.org/gnu/diffutils/diffutils-3.11.tar.xz|"
    "tar|https://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz|--without-xattrs --without-posix-acls"
    "gzip|https://ftp.gnu.org/gnu/gzip/gzip-1.13.tar.xz|"
    "bzip2|https://sourceware.org/ftp/bzip2/bzip2-1.0.8.tar.gz|"
    "xz|https://github.com/tukaani-project/xz/releases/download/v5.6.3/xz-5.6.3.tar.xz|"
)

if [[ "$ROOTFS_PROFILE" != "minimal" ]]; then
    PKGS+=(
        "make|https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz|"
        "patch|https://ftp.gnu.org/gnu/patch/patch-2.7.6.tar.gz|"
    )
fi

for entry in "${PKGS[@]}"; do
    IFS='|' read -r name url conf <<< "$entry"
    log "Processing $name"

    archive="$SOURCE_DIR/$(basename "$url")"
    src="$SOURCE_DIR/$name"

    if [[ ! -f "$archive" ]]; then
        log "  downloading $url"
        wget -q --tries=3 --timeout=30 -O "$archive" "$url"
    else
        log "  using cached archive $(basename "$archive")"
    fi

    if [[ ! -d "$src" ]]; then
        log "  extracting source"
        mkdir -p "$src"
        tar -xf "$archive" -C "$src" --strip-components=1
    fi

    pushd "$src" >/dev/null

    if [[ ! -f Makefile ]]; then
        if [[ -f configure ]]; then
            log "  configuring"
            read -r -a conf_args <<< "$conf"
            ./configure --prefix=/usr --sysconfdir=/etc "${conf_args[@]}"
        elif [[ -f configure.ac ]]; then
            need autoreconf
            log "  generating configure script"
            autoreconf -fi
            read -r -a conf_args <<< "$conf"
            ./configure --prefix=/usr --sysconfdir=/etc "${conf_args[@]}"
        fi
    fi

    [[ -f Makefile ]] || die "$name: no Makefile or configure script available"
    log "  building with $THREADS jobs"
    make -j"$THREADS"

    if [[ "$name" == "bzip2" ]]; then
        make PREFIX="$TARGET_DIR/usr" install
    else
        make DESTDIR="$TARGET_DIR" install
    fi

    popd >/dev/null
done

log "Creating usr-merge layout"
for path in bin sbin lib lib64; do
    rm -rf "$TARGET_DIR/$path"
done
ln -s usr/bin  "$TARGET_DIR/bin"
ln -s usr/sbin "$TARGET_DIR/sbin"
ln -s usr/lib  "$TARGET_DIR/lib"
ln -s usr/lib  "$TARGET_DIR/lib64"
ln -sfn ../run "$TARGET_DIR/var/run"
ln -sfn bash "$TARGET_DIR/usr/bin/sh"

log "Copying runtime shared-library dependencies"
copy_lib() {
    local src="$1"
    [[ -f "$src" ]] || return 0
    install -Dm755 "$src" "$TARGET_DIR/usr/lib/$(basename "$src")"
}

while IFS= read -r bin_file; do
    file "$bin_file" 2>/dev/null | grep -q 'ELF' || continue

    ldd_out="$(ldd "$bin_file" 2>&1 || true)"
    if grep -q 'not found' <<< "$ldd_out"; then
        die "Unresolved runtime dependency in $bin_file:\n$ldd_out"
    fi

    while IFS= read -r lib; do
        [[ -n "$lib" && "$lib" == /* ]] || continue
        copy_lib "$lib"
    done < <(printf '%s\n' "$ldd_out" | awk '$1 ~ /^\// {print $1} $3 ~ /^\// {print $3}' | sort -u)
done < <(find "$TARGET_DIR/usr/bin" "$TARGET_DIR/usr/sbin" -type f -executable 2>/dev/null)

ld_linux="$(gcc -print-file-name=ld-linux-x86-64.so.2)"
[[ -f "$ld_linux" ]] || die "Could not locate host x86_64 dynamic loader"
copy_lib "$ld_linux"

for lib in libnss_files.so.2 libnss_dns.so.2; do
    found="$(find /lib /usr/lib -name "$lib" -print -quit 2>/dev/null || true)"
    [[ -n "$found" ]] && copy_lib "$found"
done

log "Installing Cherry utilities"
for util in chepm cherryfetch; do
    if [[ -f "$PROJECT_DIR/utils/$util" ]]; then
        install -Dm755 "$PROJECT_DIR/utils/$util" "$TARGET_DIR/usr/bin/$util"
    fi
done

log "Writing system configuration"
cat > "$TARGET_DIR/etc/passwd" <<'EOF_PASSWD'
root:x:0:0:root:/root:/bin/sh
cherry:x:1000:1000:Cherry User:/home/cherry:/bin/sh
EOF_PASSWD

cat > "$TARGET_DIR/etc/group" <<'EOF_GROUP'
root:x:0:
cherry:x:1000:
EOF_GROUP

cat > "$TARGET_DIR/etc/shadow" <<'EOF_SHADOW'
root:!:19701:0:99999:7:::
cherry:!:19701:0:99999:7:::
EOF_SHADOW
chmod 600 "$TARGET_DIR/etc/shadow"

cat > "$TARGET_DIR/etc/fstab" <<'EOF_FSTAB'
tmpfs /run tmpfs defaults 0 0
tmpfs /tmp tmpfs defaults 0 0
EOF_FSTAB

cat > "$TARGET_DIR/etc/os-release" <<EOF_OS
NAME="Cherry Linux"
ID=cherrylinux
VERSION="${CHERRY_VERSION}"
VERSION_ID="${CHERRY_VERSION}"
PRETTY_NAME="Cherry Linux ${CHERRY_VERSION}"
EOF_OS

echo "cherrylinux" > "$TARGET_DIR/etc/hostname"
printf '%s\n' '/usr/lib' > "$TARGET_DIR/etc/ld.so.conf"

if [[ "$ROOTFS_PROFILE" == "minimal" ]]; then
    log "Applying minimal profile cleanup"
    rm -rf \
        "$TARGET_DIR/usr/include" \
        "$TARGET_DIR/usr/share/man" \
        "$TARGET_DIR/usr/share/info" \
        "$TARGET_DIR/usr/share/doc"
    find "$TARGET_DIR/usr/lib" -type f -name '*.a' -delete
fi

log "Rootfs build complete: $TARGET_DIR"
