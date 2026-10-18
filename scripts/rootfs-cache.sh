#!/usr/bin/env bash

# Hash the recipe, local files (including modes/symlinks) and build options.
# Ignore timestamps so touching a file alone does not invalidate the rootfs.
rootfs_input_hash() (
    set -euo pipefail
    cd "$PROJECT_DIR"
    {
        printf '%s\0' \
            "version=$CHERRY_VERSION" \
            "profile=${ROOTFS_PROFILE:-full}" \
            "net=${ENABLE_NET:-1}" \
            "busybox=${ENABLE_BUSYBOX:-0}" \
            "busybox_version=${BUSYBOX_VERSION:-1.36.1}" \
            "busybox_sha256=${BUSYBOX_SHA256:-b8cc24c9574d809e7279c3be349795c5d5ceb6fdf19ca709f80cde50e47de314}"
        for option in CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS ACLOCAL_PATH; do
            printf '%s=%s\0' "$option" "${!option-}"
        done
        tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
            -cf - rootfs.sh scripts/rootfs-cache.sh VERSION utils overlay
    } | sha256sum | cut -d ' ' -f 1
)
