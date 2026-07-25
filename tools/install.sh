#!/usr/bin/env bash
#
# Builds whetuu from this checkout and installs the optimized binary.
#
#   tools/install.sh
#   WHETUU_INSTALL_DIR="$HOME/bin" tools/install.sh
#
# Environment:
#   WHETUU_INSTALL_DIR   where to put the binary
#                        (default: $HOME/.local/bin)

set -euo pipefail

tmp=

die() {
    printf 'install: %s\n' "$1" >&2
    exit 1
}

say() {
    printf 'install: %s\n' "$1"
}

cleanup() {
    [[ -z $tmp ]] || rm -f "$tmp"
}
trap cleanup EXIT INT TERM

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 not found on PATH"
}

need git
need install
need mktemp
need mv
need sed

root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
cd "$root"

required_zig=$(sed -n 's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' build.zig.zon)
[[ -n $required_zig ]] || die "could not read minimum_zig_version from build.zig.zon"

# Zig's build API changes between releases, so a nearby stable compiler can
# fail before it reaches whetuu's source. Prefer the exact compiler on PATH,
# then an installed mise copy even when mise has not activated it in this shell.
zig_bin=
found_zig=
if command -v zig >/dev/null 2>&1; then
    candidate=$(command -v zig)
    found_zig=$("$candidate" version 2>/dev/null || true)
    if [[ $found_zig == "$required_zig" ]]; then
        zig_bin=$candidate
    fi
fi

if [[ -z $zig_bin ]] && command -v mise >/dev/null 2>&1; then
    mise_dir=$(mise where "zig@$required_zig" 2>/dev/null || true)
    if [[ -x $mise_dir/zig ]] && [[ $("$mise_dir/zig" version 2>/dev/null || true) == "$required_zig" ]]; then
        zig_bin=$mise_dir/zig
    fi
fi

if [[ -z $zig_bin ]]; then
    found=${found_zig:-none}
    die "Zig $required_zig is required, found $found. Put it on PATH or run: mise install zig@$required_zig"
fi

if [[ -n ${WHETUU_INSTALL_DIR:-} ]]; then
    install_dir=$WHETUU_INSTALL_DIR
elif [[ -n ${HOME:-} ]]; then
    install_dir=$HOME/.local/bin
else
    die "HOME is unset. Set WHETUU_INSTALL_DIR to choose an install directory."
fi

say "building release binary with Zig $required_zig"
"$zig_bin" build --release=fast

binary=zig-out/bin/whetuu
[[ -f $binary ]] || die "$binary was not produced"

mkdir -p "$install_dir" 2>/dev/null ||
    die "could not create $install_dir. Set WHETUU_INSTALL_DIR to a directory you can write to."
[[ -w $install_dir ]] ||
    die "$install_dir is not writable. Set WHETUU_INSTALL_DIR to a directory you can write to."

# Stage beside the destination so the final rename is atomic. A build or copy
# failure leaves an existing installation untouched.
tmp=$(mktemp "$install_dir/.whetuu.XXXXXX") || die "could not create a temporary file in $install_dir"
install -m 755 "$binary" "$tmp" || die "could not copy the binary to $install_dir"
mv -f "$tmp" "$install_dir/whetuu" || die "could not replace $install_dir/whetuu"
tmp=

say "installed $install_dir/whetuu"

case ":${PATH:-}:" in
    *":$install_dir:"*) ;;
    *) say "note: add $install_dir to PATH" ;;
esac
