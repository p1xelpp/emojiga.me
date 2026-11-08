#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
package_dir=$(dirname "$script_dir")
patch_file="$package_dir/Patches/GateEngine-0.2.1-Swift-6.4.patch"
checkout="$package_dir/.build/checkouts/GateEngine"

swift package --package-path "$package_dir" resolve

apply_patch_if_needed() {
    patch_file=$1
    description=$2

    if git -C "$checkout" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
        printf '%s\n' "$description is already applied."
    elif git -C "$checkout" apply --check "$patch_file"; then
        git -C "$checkout" apply "$patch_file"
        printf '%s\n' "Applied $description."
    else
        printf '%s\n' "Could not apply $description; verify the resolved dependency is GateEngine 0.2.1." >&2
        exit 1
    fi
}

apply_patch_if_needed "$patch_file" "GateEngine Swift 6.4 compatibility patch"
apply_patch_if_needed \
    "$package_dir/Patches/GateEngine-0.2.1-X11-mouse-delta.patch" \
    "GateEngine X11 mouse-delta patch"
apply_patch_if_needed \
    "$package_dir/Patches/GateEngine-0.2.1-F11-fullscreen.patch" \
    "GateEngine F11 fullscreen patch"
