#!/usr/bin/env bash
# Sourced by rootfs.sh after restoring the cached package tree.
# Package staging has just been renamed. Bash may have cached executables
# from that old directory; configuration uses the host tools again.
if [[ "${PATH%%:*}" == "$BUILD_DIR"/rootfs-stage.*/usr/bin ]]; then
    PATH="${PATH#*:}"
    PATH="${PATH#*:}"
    export PATH
fi
hash -r
# OpenSSL's compiled trust directory differs across build hosts (for example,
# /usr/lib/ssl on Debian and /etc/ssl on Arch). Point it at the shipped bundle.
if [[ "$ENABLE_NET" == "1" ]]; then
    openssl_dir="$(openssl version -d | sed -n 's/^OPENSSLDIR: "\(.*\)"$/\1/p')"
    [[ "$openssl_dir" == /* ]] || die "Cannot determine OpenSSL trust directory"
    if [[ "$openssl_dir" != /etc/ssl ]]; then
        mkdir -p "$TARGET_DIR$openssl_dir"
        ln -sfn /etc/ssl/certs/ca-certificates.crt "$TARGET_DIR$openssl_dir/cert.pem"
    fi
fi
log "Installing Cherry utilities"
for util in chepm cherryfetch cherry-help cherry-status; do
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
wheel:x:10:cherry
video:x:18:cherry
audio:x:29:cherry
input:x:33:cherry
cherry:x:1000:
EOF_GROUP

cat > "$TARGET_DIR/etc/shadow" <<'EOF_SHADOW'
root:!:19701:0:99999:7:::
cherry:!:19701:0:99999:7:::
EOF_SHADOW
chmod 600 "$TARGET_DIR/etc/shadow"

cat > "$TARGET_DIR/etc/fstab" <<'EOF_FSTAB'
tmpfs /tmp tmpfs defaults,mode=1777 0 0
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

    if udhcpc -i "$iface" -n -p "/run/udhcpc-$iface.pid" -t 3 -T 2 \
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


install -Dm755 "$PROJECT_DIR/scripts/live-login" "$TARGET_DIR/usr/lib/cherry/live-login"
cat > "$TARGET_DIR/etc/issue" <<EOF_ISSUE
Cherry Linux $CHERRY_VERSION — local live console
EOF_ISSUE
# GNU tar and package metadata remain available in every profile.
mkdir -p "$TARGET_DIR/etc/chepm"
printf '%s\n' '# Experimental; only trusted archives with an explicit SHA256.' > "$TARGET_DIR/etc/chepm/README"
overlay_dir="$PROJECT_DIR/overlay"

log "Applying Cherry Linux overlay"
if [[ -d "$overlay_dir" ]]; then
    (
        cd "$overlay_dir"
        shopt -s dotglob nullglob
        for f in *; do
            [[ -e "$f" ]] || continue
            [[ "$f" == "README.md" ]] && continue
            cp -a "$f" "$TARGET_DIR/"
        done
    )
    find "$TARGET_DIR/etc" -type f -name '*.sh' -exec chmod 755 {} +
    chmod 755 "$TARGET_DIR/etc/rc.shutdown" 2>/dev/null || true
fi

