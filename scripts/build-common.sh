#!/usr/bin/env bash

# Resolve paths before package builds change cwd. Never delete a caller's
# arbitrary existing directory: output trees must carry our ownership marker.
absolute_path() { realpath -m -- "$1"; }

check_output_path() {
    local path="$1"
    case "$path" in
        /|/home|/tmp|/usr|/etc|/var|"$HOME"|"$PROJECT_DIR")
            printf 'Unsafe output directory: %s\n' "$path" >&2; return 1 ;;
    esac
}

publish_tree() {
    local stage="$1" target="$2"
    check_output_path "$target"
    if [[ -e "$target.previous" || -L "$target.previous" ]]; then
        printf 'Previous output requires recovery: %s.previous\n' "$target" >&2
        return 1
    fi
    if [[ -e "$target" ]]; then
        [[ -f "$target/.cherry-build-inputs" || -f "$target/.cherry-package-inputs" ]] || {
            printf 'Refusing to replace unmanaged directory: %s\n' "$target" >&2; return 1;
        }
        mv -- "$target" "$target.previous"
    fi
    if mv -- "$stage" "$target"; then
        rm -rf -- "$target.previous"
    else
        [[ ! -d "$target.previous" ]] || mv -- "$target.previous" "$target"
        return 1
    fi
}
