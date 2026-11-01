#!/usr/bin/env bash
# Source in the builder after TARGET_DIR and die() have been defined.
copy_runtime_libraries() {
    local loader bin output lib dest
    loader="$(gcc -print-file-name=ld-linux-x86-64.so.2)"
    [[ -f "$loader" ]] || die "Cannot locate x86_64 dynamic loader"
    install -Dm755 "$loader" "$TARGET_DIR/usr/lib/ld-linux-x86-64.so.2"
    # ldd uses the host loader, but target libraries must win its search.
    # Never overwrite a target SONAME or replace a target symlink.
    while IFS= read -r -d '' bin; do
        readelf -h "$bin" >/dev/null 2>&1 || continue
        output="$(LD_LIBRARY_PATH="$TARGET_DIR/usr/lib" ldd "$bin" 2>&1 || true)"
        [[ "$output" != *'not found'* ]] || die "Unresolved dependency: $bin: $output"
        while IFS= read -r lib; do
            [[ -f "$lib" ]] || continue
            dest="$TARGET_DIR/usr/lib/$(basename "$lib")"
            if [[ ! -e "$dest" && ! -L "$dest" ]]; then
                install -Dm755 "$lib" "$dest"
            fi
        done < <(awk '$1 ~ /^\// {print $1} $3 ~ /^\// {print $3}' <<< "$output" | sort -u)
    done < <(find "$TARGET_DIR/usr/bin" "$TARGET_DIR/usr/sbin" "$TARGET_DIR/usr/lib" -type f -print0)
    # Verify the whole closure with the target loader, disallowing host fallback.
    while IFS= read -r -d '' bin; do
        readelf -l "$bin" 2>/dev/null | grep -q INTERP || continue
        output="$("$TARGET_DIR/usr/lib/ld-linux-x86-64.so.2" --inhibit-cache \
            --library-path "$TARGET_DIR/usr/lib" --list "$bin")" || die "Cannot load $bin"
        while IFS= read -r lib; do
            case "$lib" in "$TARGET_DIR"/*) ;; *) die "Host dependency leaked into $bin: $lib" ;; esac
        done < <(awk '$3 ~ /^\// {print $3}' <<< "$output")
    done < <(find "$TARGET_DIR/usr/bin" "$TARGET_DIR/usr/sbin" -type f -print0)
}
