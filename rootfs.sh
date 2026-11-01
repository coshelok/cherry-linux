#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PROJECT_DIR/scripts/build-common.sh"
BUILD_DIR="$(absolute_path "${BUILD_DIR:-$PROJECT_DIR/build}")"
FINAL_DIR="$(absolute_path "${ROOTFS_DIR:-$BUILD_DIR/rootfs}")"
SOURCE_DIR="$(absolute_path "${SOURCES_DIR:-$BUILD_DIR/sources}")"
check_output_path "$FINAL_DIR"
PACKAGE_DIR="$BUILD_DIR/package-rootfs"
THREADS="${THREADS:-$(nproc)}"
ROOTFS_PROFILE="${ROOTFS_PROFILE:-full}"
ENABLE_NET="${ENABLE_NET:-1}"
ENABLE_BUSYBOX="${ENABLE_BUSYBOX:-0}"
BUSYBOX_VERSION="${BUSYBOX_VERSION:-1.36.1}"
BUSYBOX_SHA256="${BUSYBOX_SHA256:-b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314}"

log()  { printf '\033[1;34m[ROOTFS]\033[0m %s\n' "$*"; }
info() { printf '\033[1;34m[ROOTFS]\033[0m   %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

for cmd in gcc make wget tar file ldd find awk cut grep install tr sed sort basename sha256sum realpath flock readelf xargs; do
    need "$cmd"
done

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
        info "using cached $(basename "$dest")"
        return 0
    fi

    log "Downloading $(basename "$dest")"
    wget -q --tries=3 --timeout=60 -O "$dest.part" "$url" \
        || die "$(basename "$dest"): download failed: $url"
    mv "$dest.part" "$dest"
    verify_sha256 "$dest" "$sha"
}

VERSION_FILE="$PROJECT_DIR/VERSION"
if [[ -z "${CHERRY_VERSION:-}" ]]; then
    [[ -f "$VERSION_FILE" ]] || die "Missing version file: $VERSION_FILE"
    CHERRY_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
fi
[[ "$CHERRY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || \
    die "Invalid Cherry Linux version: $CHERRY_VERSION"

source "$PROJECT_DIR/scripts/rootfs-cache.sh"
CA_BUNDLE="${CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
[[ "$ENABLE_NET" != "1" || -s "$CA_BUNDLE" ]] || die "Missing CA bundle: $CA_BUNDLE"
ROOTFS_INPUT_HASH="$(rootfs_input_hash)"
PACKAGE_INPUT_HASH="$(package_input_hash)"

mkdir -p "$BUILD_DIR" "$SOURCE_DIR"
exec 8>"$BUILD_DIR/.rootfs.lock"
flock -n 8 || die "Another rootfs build is running"
TARGET_DIR="$(mktemp -d "$BUILD_DIR/rootfs-stage.XXXXXX")"
trap 'rm -rf -- "$TARGET_DIR"' EXIT
if [[ "${REBUILD_ROOTFS:-0}" == "1" || ! -f "$PACKAGE_DIR/.cherry-package-inputs" ||
      "$(cat "$PACKAGE_DIR/.cherry-package-inputs")" != "$PACKAGE_INPUT_HASH" ]]; then
log "Building package cache in $TARGET_DIR"
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

# Point every build system at the staging root so packages are linked against
# what we have already installed instead of the build host.
export PKG_CONFIG_SYSROOT_DIR="$TARGET_DIR"
export PKG_CONFIG_LIBDIR="$TARGET_DIR/usr/lib/pkgconfig:$TARGET_DIR/usr/share/pkgconfig:$TARGET_DIR/usr/lib64/pkgconfig"
export CPPFLAGS="-I$TARGET_DIR/usr/include ${CPPFLAGS:-}"
export LDFLAGS="-L$TARGET_DIR/usr/lib -Wl,-rpath-link,$TARGET_DIR/usr/lib ${LDFLAGS:-}"
export ACLOCAL_PATH="$TARGET_DIR/usr/share/aclocal${ACLOCAL_PATH:+:$ACLOCAL_PATH}"

# Let build steps of later packages find tools already staged in the rootfs.
# Host tools remain reachable afterwards.
export PATH="$TARGET_DIR/usr/bin:$TARGET_DIR/usr/sbin:$PATH"

# ---------------------------------------------------------------------------
# Generic package builder.
#   build_package <name> <url> [extra configure/make arguments...]
# The build system is detected from the extracted sources.
# ---------------------------------------------------------------------------
build_package() {
    local name="$1" url="$2" sha="$3"
    shift 3
    local -a extra=("$@")
    local archive="$SOURCE_DIR/$(basename "$url")"
    local src="$SOURCE_DIR/$name"
    local pkglog="$BUILD_DIR/pkg-$name.log"

    fetch_source "$url" "$archive" "$sha"

    # A rootfs rebuild must not reuse objects configured for an older recipe.
    rm -rf "$src"
    mkdir -p "$src"
    tar -xf "$archive" -C "$src" --strip-components=1

    pushd "$src" >/dev/null

    if [[ -f meson.build && ! -f configure ]]; then
        need meson
        need ninja
        info "meson build"
        rm -rf _build
        if ! meson setup _build \
                --prefix=/usr --libdir=/usr/lib --sysconfdir=/etc \
                --buildtype=release "${extra[@]}" >"$pkglog" 2>&1; then
            die "$name: meson setup failed:\n$(tail -40 "$pkglog")"
        fi
        if ! DESTDIR="$TARGET_DIR" ninja -C _build install >"$pkglog" 2>&1; then
            die "$name: ninja install failed:\n$(tail -40 "$pkglog")"
        fi
    elif [[ -f configure || -f configure.ac ]]; then
        if [[ ! -f configure ]]; then
            need autoreconf
            info "autoreconf"
            NOCONFIGURE=1 autoreconf -fi >"$pkglog" 2>&1 || true
        fi
        info "configure"
        if ! ./configure --prefix=/usr --sysconfdir=/etc --libdir=/usr/lib \
                --disable-static "${extra[@]}" >"$pkglog" 2>&1; then
            die "$name: configure failed:\n$(tail -40 "$pkglog")"
        fi
        info "make"
        if ! make -j"$THREADS" >"$pkglog" 2>&1; then
            die "$name: make failed:\n$(tail -40 "$pkglog")"
        fi
        if ! make DESTDIR="$TARGET_DIR" install >"$pkglog" 2>&1; then
            die "$name: make install failed:\n$(tail -40 "$pkglog")"
        fi
    elif [[ -f Makefile ]]; then
        info "make (plain)"
        if ! make -j"$THREADS" PREFIX=/usr "${extra[@]}" >"$pkglog" 2>&1; then
            die "$name: make failed:\n$(tail -40 "$pkglog")"
        fi
        if ! make DESTDIR="$TARGET_DIR" PREFIX=/usr "${extra[@]}" install >"$pkglog" 2>&1; then
            die "$name: make install failed:\n$(tail -40 "$pkglog")"
        fi
    else
        die "$name: no supported build system in $src"
    fi

    popd >/dev/null

    # Staged libtool archives embed non-sysrooted absolute paths from the
    # target prefix and confuse downstream libtool links. Shared libraries
    # do not need them; drop them after every package install.
    rm -f "$TARGET_DIR"/usr/lib/*.la \
          "$TARGET_DIR"/usr/lib64/*.la \
          "$TARGET_DIR"/usr/lib/*/lib*.la 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Base GNU userland.
# ---------------------------------------------------------------------------
# Package sources are pinned by sha256; update the hash whenever the
# version/URL changes.
PKGS=(
    "bash|https://ftp.gnu.org/gnu/bash/bash-5.2.32.tar.gz|d3ef80d2b67d8cbbe4d3265c63a72c46f9b278ead6e0e06d61801b58f23f50b5|--without-curses"
    "coreutils|https://ftp.gnu.org/gnu/coreutils/coreutils-9.5.tar.xz|cd328edeac92f6a665de9f323c93b712af1858bc2e0d88f3f7100469470a1b8a|--enable-install-program=hostname"
    "grep|https://ftp.gnu.org/gnu/grep/grep-3.11.tar.xz|1db2aedde89d0dea42b16d9528f894c8d15dae4e190b59aecc78f5a951276eab|"
    "sed|https://ftp.gnu.org/gnu/sed/sed-4.9.tar.xz|6e226b732e1cd739464ad6862bd1a1aba42d7982922da7a53519631d24975181|"
    "gawk|https://ftp.gnu.org/gnu/gawk/gawk-5.3.0.tar.xz|ca9c16d3d11d0ff8c69d79dc0b47267e1329a69b39b799895604ed447d3ca90b|"
    "findutils|https://ftp.gnu.org/gnu/findutils/findutils-4.10.0.tar.xz|1387e0b67ff247d2abde998f90dfbf70c1491391a59ddfecb8ae698789f0a4f5|"
    "diffutils|https://ftp.gnu.org/gnu/diffutils/diffutils-3.11.tar.xz|a73ef05fe37dd585f7d87068e4a0639760419f810138bd75c61ddaa1f9e2131e|"
    "tar|https://ftp.gnu.org/gnu/tar/tar-1.35.tar.xz|4d62ff37342ec7aed748535323930c7cf94acf71c3591882b26a7ea50f3edc16|--without-xattrs --without-posix-acls"
    "gzip|https://ftp.gnu.org/gnu/gzip/gzip-1.13.tar.xz|7454eb6935db17c6655576c2e1b0fabefd38b4d0936e0f87f48cd062ce91a057|"
    "bzip2|https://sourceware.org/ftp/bzip2/bzip2-1.0.8.tar.gz|ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269|"
    "xz|https://github.com/tukaani-project/xz/releases/download/v5.6.3/xz-5.6.3.tar.xz|db0590629b6f0fa36e74aea5f9731dc6f8df068ce7b7bafa45301832a5eebc3a|"
)

if [[ "$ROOTFS_PROFILE" != "minimal" ]]; then
    PKGS+=(
        "make|https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz|dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3|"
        "patch|https://ftp.gnu.org/gnu/patch/patch-2.7.6.tar.gz|8cf86e00ad3aaa6d26aca30640e86b0e3e1f395ed99f189b06d4c9f74bc58a4e|"
    )
fi

for entry in "${PKGS[@]}"; do
    IFS='|' read -r name url sha conf <<< "$entry"
    log "Building $name"

    if [[ "$name" == "bzip2" ]]; then
        # bzip2 has no configure script and a custom install target.
        src="$SOURCE_DIR/bzip2"
        archive="$SOURCE_DIR/$(basename "$url")"
        fetch_source "$url" "$archive" "$sha"
        rm -rf "$src"
        mkdir -p "$src"
        tar -xf "$archive" -C "$src" --strip-components=1
        # bzip2 ships only a static archive; build it PIC so downstream
        # libraries can link it into shared objects.
        make -C "$src" clean >/dev/null 2>&1 || true
        make -C "$src" -j"$THREADS" CFLAGS="$CFLAGS -fPIC" libbz2.a >/dev/null
        make -C "$src" -j"$THREADS" CFLAGS="$CFLAGS -fPIC" >/dev/null
        make -C "$src" PREFIX="$TARGET_DIR/usr" install >/dev/null
        continue
    fi

    read -r -a conf_args <<< "$conf"
    build_package "$name" "$url" "$sha" "${conf_args[@]}"
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

build_busybox_tools() {
    log "Building BusyBox ${BUSYBOX_VERSION}"
    local archive="$SOURCE_DIR/busybox-${BUSYBOX_VERSION}.tar.bz2"
    local src="$SOURCE_DIR/busybox"

    fetch_source "https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2" \
        "$archive" "$BUSYBOX_SHA256"

    rm -rf "$src"
    mkdir -p "$src"
    tar -xf "$archive" -C "$src" --strip-components=1

    (
        cd "$src"
        unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_LIBDIR
        make distclean >/dev/null 2>&1 || true
        make defconfig >/dev/null
        # blkid runs before the live root (and its shared libraries) exists.
        sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
        # The BusyBox tc applet no longer compiles against modern kernel
        # headers and is not needed on a live image.
        sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
        # Require OpenSSL verification; never fall back to unverified TLS.
        sed -i 's/^CONFIG_FEATURE_WGET_HTTPS=y/# CONFIG_FEATURE_WGET_HTTPS is not set/' .config
        # BusyBox 1.36.1 passes host:port to -verify_ip; use the bare IP instead.
        sed -i 's/(char\*)host;         \/\/[[]11[]]/(char*)servername;   \/\/[11]/' networking/wget.c
        # A locked shadow entry is not a crypt salt. Refuse it before calling
        # pw_encrypt, so login reports a normal authentication failure.
        sed -i '/encrypted = pw_encrypt(plaintext/i\
\tif (pw_pass[0] == '\''!'\'' || pw_pass[0] == '\''*'\'')\n\t\treturn 0;' libbb/correct_password.c
        yes "" | make oldconfig >/dev/null 2>&1 || true
        info "compiling BusyBox"
        make -j"$THREADS" >/dev/null
    )

    install -Dm755 "$src/busybox" "$TARGET_DIR/usr/bin/busybox"

    # GNU coreutils remain the default; BusyBox adds the applets the live
    # environment needs (networking, login, logging, device hotplug).
    local applets=(
        vi dmesg ps kill
        login getty passwd su sulogin
        syslogd klogd logread mdev
        mount umount clear reset sync
    )
    if [[ "$ENABLE_NET" == "1" ]]; then
        applets+=(ip udhcpc ping wget nslookup netstat route ifconfig)
    fi
    (
        cd "$TARGET_DIR/usr/bin"
        for applet in "${applets[@]}"; do
            [[ -e "$applet" ]] || ln -s busybox "$applet"
        done
    )

    # Power management applets live in /usr/sbin, as is conventional.
    mkdir -p "$TARGET_DIR/usr/sbin"
    (
        cd "$TARGET_DIR/usr/sbin"
        for applet in halt poweroff reboot; do
            [[ -e "$applet" ]] || ln -s ../bin/busybox "$applet"
        done
    )

    # BusyBox has no `shutdown`, so ship a small wrapper around it.
    cat > "$TARGET_DIR/usr/sbin/shutdown" <<'EOF_SHUTDOWN'
#!/bin/sh
# Cherry Linux shutdown wrapper: reboot, halt or power off.
ACTION=poweroff

for arg in "$@"; do
    case "$arg" in
        -r|--reboot)                ACTION=reboot   ;;
        -h|-H|-P|--halt|--poweroff) ACTION=poweroff ;;
        -c|--cancel)                exit 0          ;;
        *)                          :               ;;
    esac
done

sync
exec "/sbin/$ACTION"
EOF_SHUTDOWN
    chmod 755 "$TARGET_DIR/usr/sbin/shutdown"

    if [[ "$ENABLE_BUSYBOX" == "1" ]]; then
        (
            cd "$TARGET_DIR/usr/bin"
            while IFS= read -r cmd; do
                [[ -n "$cmd" ]] || continue
                [[ -e "$cmd" ]] || ln -s busybox "$cmd"
            done < <(./busybox --list)
        )
        log "BusyBox compatibility layer enabled"
    fi
}

build_busybox_tools

# OpenSSL and the CA bundle are explicit host bootstrap inputs, like libc.
# BusyBox's unverified TLS fallback is disabled below; missing TLS fails closed.
if [[ "$ENABLE_NET" == "1" ]]; then
    need openssl
    install -Dm755 "$(command -v openssl)" "$TARGET_DIR/usr/bin/openssl"
    install -Dm644 "$CA_BUNDLE" "$TARGET_DIR/etc/ssl/certs/ca-certificates.crt"
    ln -s certs/ca-certificates.crt "$TARGET_DIR/etc/ssl/cert.pem"
fi
source "$PROJECT_DIR/scripts/copy-libraries.sh"
copy_runtime_libraries

if [[ "$ROOTFS_PROFILE" == "minimal" ]]; then
    log "Applying minimal profile cleanup"
    rm -rf \
        "$TARGET_DIR/usr/include" \
        "$TARGET_DIR/usr/share/man" \
        "$TARGET_DIR/usr/share/info" \
        "$TARGET_DIR/usr/share/doc" \
        "$TARGET_DIR/usr/share/locale"
    find "$TARGET_DIR/usr/lib" -type f -name '*.a' -delete 2>/dev/null || true
fi

printf '%s\n' "$PACKAGE_INPUT_HASH" > "$TARGET_DIR/.cherry-package-inputs"
# Record imported runtime binaries/libraries and trust store for this build.
(cd "$TARGET_DIR"; find usr/lib -type f -print0 | sort -z | xargs -0 sha256sum) > "$TARGET_DIR/.cherry-runtime-sha256"
publish_tree "$TARGET_DIR" "$PACKAGE_DIR"
TARGET_DIR="$(mktemp -d "$BUILD_DIR/rootfs-stage.XXXXXX")"
else
    log "Using cached packages (overlay/version changes do not recompile userland)"
fi
cp -a "$PACKAGE_DIR/." "$TARGET_DIR/"
source "$PROJECT_DIR/scripts/rootfs-config.sh"
printf '%s\n' "$ROOTFS_INPUT_HASH" > "$TARGET_DIR/.cherry-build-inputs"
publish_tree "$TARGET_DIR" "$FINAL_DIR"
log "Rootfs build complete: $FINAL_DIR"
