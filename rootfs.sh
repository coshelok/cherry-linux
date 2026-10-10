#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/build}"
TARGET_DIR="${ROOTFS_DIR:-$BUILD_DIR/rootfs}"
SOURCE_DIR="${SOURCES_DIR:-$BUILD_DIR/sources}"
THREADS="${THREADS:-$(nproc)}"
ROOTFS_PROFILE="${ROOTFS_PROFILE:-full}"
ENABLE_NET="${ENABLE_NET:-1}"
ENABLE_BUSYBOX="${ENABLE_BUSYBOX:-0}"
BUSYBOX_VERSION="${BUSYBOX_VERSION:-1.36.1}"

log()  { printf '\033[1;34m[ROOTFS]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

for cmd in gcc make wget tar file ldd find awk cut grep install tr sed sort basename; do
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

build_busybox_tools() {
    if [[ "$ENABLE_NET" != "1" && "$ENABLE_BUSYBOX" != "1" ]]; then
        return 0
    fi

    log "Building BusyBox ${BUSYBOX_VERSION} (networking toolset)"
    local archive="$SOURCE_DIR/busybox-${BUSYBOX_VERSION}.tar.bz2"
    local src="$SOURCE_DIR/busybox"

    if [[ ! -f "$archive" ]]; then
        log "  downloading $(basename "$archive")"
        wget -q --tries=3 --timeout=30 -O "$archive" \
            "https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2"
    else
        log "  using cached archive $(basename "$archive")"
    fi

    rm -rf "$src"
    mkdir -p "$src"
    tar -xf "$archive" -C "$src" --strip-components=1

    (
        cd "$src"
        unset CFLAGS CXXFLAGS
        make distclean >/dev/null 2>&1 || true
        make defconfig >/dev/null
        # The BusyBox tc applet no longer compiles against modern kernel
        # headers and is not needed on a live image.
        sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
        yes "" | make oldconfig >/dev/null 2>&1 || true
        log "  compiling BusyBox"
        make -j"$THREADS" >/dev/null
    )

    install -Dm755 "$src/busybox" "$TARGET_DIR/usr/bin/busybox"

    # Networking applets only; GNU coreutils remain the default commands.
    local applets=(ip udhcpc ping wget nslookup netstat route ifconfig)
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

if [[ "$ENABLE_NET" == "1" ]]; then
    log "Writing networking configuration"

    cat > "$TARGET_DIR/etc/hosts" <<'EOF_HOSTS'
127.0.0.1 localhost cherrylinux
::1       localhost cherrylinux
EOF_HOSTS

    cat > "$TARGET_DIR/etc/nsswitch.conf" <<'EOF_NSSWITCH'
passwd: files
group:  files
shadow: files
hosts:  files dns
networks: files
services: files
EOF_NSSWITCH

    printf '%s\n' 'nameserver 1.1.1.1' > "$TARGET_DIR/etc/resolv.conf"

    install -d "$TARGET_DIR/usr/share/udhcpc" "$TARGET_DIR/usr/lib/cherry"

    cat > "$TARGET_DIR/usr/share/udhcpc/default.script" <<'EOF_UDHCPC'
#!/bin/sh
# Cherry Linux udhcpc handler: address, default route and DNS.
RESOLV_CONF=/etc/resolv.conf

case "$1" in
    deconfig)
        ip -4 addr flush dev "$interface" 2>/dev/null
        ip link set dev "$interface" up 2>/dev/null
        ;;
    bound|renew)
        # Removing the address also drops the kernel's connected route; never
        # `ip route flush dev` here or the default gateway becomes unreachable.
        ip -4 addr flush dev "$interface" 2>/dev/null
        ip addr add "$ip/$mask" dev "$interface" 2>/dev/null

        ip route del default dev "$interface" 2>/dev/null
        for r in $router; do
            ip route add default via "$r" dev "$interface" 2>/dev/null
        done

        : > "$RESOLV_CONF"
        if [ -n "$domain" ]; then
            echo "search $domain" >> "$RESOLV_CONF"
        fi
        for s in $dns; do
            echo "nameserver $s" >> "$RESOLV_CONF"
        done
        ;;
esac

exit 0
EOF_UDHCPC
    chmod 755 "$TARGET_DIR/usr/share/udhcpc/default.script"

    cat > "$TARGET_DIR/usr/lib/cherry/net-up" <<'EOF_NETUP'
#!/bin/sh
# Bring up link-local interfaces and request a DHCP lease for each physical NIC.
PATH=/usr/bin:/usr/sbin:/bin:/sbin
export PATH

log() { printf '[net] %s\n' "$*"; }

ip link set lo up 2>/dev/null || true

configured=0
for sysif in /sys/class/net/*; do
    [ -e "$sysif" ] || continue
    iface=${sysif##*/}
    [ "$iface" = lo ] && continue
    [ -e "$sysif/device" ] || continue

    ip link set "$iface" up 2>/dev/null || true
    log "requesting DHCP lease on $iface"

    if udhcpc -i "$iface" -n -q -t 3 -T 2 \
            -s /usr/share/udhcpc/default.script; then
        addr=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}')
        gw=$(ip -4 route show dev "$iface" 2>/dev/null | awk '$1=="default"{print $3; exit}')
        log "$iface online: ${addr:-<no address>}${gw:+ via $gw}"
        configured=1
    else
        log "$iface: no DHCP lease"
    fi
done

[ "$configured" = 1 ] || log "no interface obtained a DHCP lease"
exit 0
EOF_NETUP
    chmod 755 "$TARGET_DIR/usr/lib/cherry/net-up"
fi

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
