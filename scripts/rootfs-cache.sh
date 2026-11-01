#!/usr/bin/env bash

build_environment() {
    local option cc_path loader path
    for option in CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS ACLOCAL_PATH; do
        printf '%s=%s\0' "$option" "${!option-}"
    done
    cc_path="$(command -v "${CC:-gcc}" || true)"
    [[ ! -f "$cc_path" ]] || sha256sum "$cc_path"
    "${CC:-gcc}" --version 2>/dev/null || true
    "${CC:-gcc}" -dumpmachine 2>/dev/null || true
    ld --version 2>/dev/null || true
    loader="$(gcc -print-file-name=ld-linux-x86-64.so.2)"
    # Runtime dependency selection depends on installed host libraries.
    stat -Lc '%n %s %Y %Z' /usr/lib/lib*.so* /lib/x86_64-linux-gnu/lib*.so* "$loader" 2>/dev/null || true
    if [[ "${ENABLE_NET:-1}" == 1 ]]; then
        path="$(command -v openssl || true)"
        [[ ! -f "$path" ]] || sha256sum "$path"
        [[ ! -f "${CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}" ]] ||
            sha256sum "${CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
    fi
}

package_input_hash() (
    set -euo pipefail
    cd "$PROJECT_DIR"
    {
        printf '%s\0' "profile=${ROOTFS_PROFILE:-full}" "net=${ENABLE_NET:-1}" \
            "busybox=${ENABLE_BUSYBOX:-0}" \
            "busybox_version=${BUSYBOX_VERSION:-1.36.1}" \
            "busybox_sha256=${BUSYBOX_SHA256:-b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314}"
        build_environment
        local files=(rootfs.sh scripts/rootfs-cache.sh)
        for file in scripts/build-common.sh scripts/copy-libraries.sh; do
            [[ ! -f "$file" ]] || files+=("$file")
        done
        tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - "${files[@]}"
    } | sha256sum | cut -d ' ' -f 1
)

rootfs_input_hash() (
    set -euo pipefail
    cd "$PROJECT_DIR"
    {
        package_input_hash
        printf '%s\0' "version=$CHERRY_VERSION"
        tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
            -cf - VERSION utils overlay scripts
    } | sha256sum | cut -d ' ' -f 1
)
