#!/usr/bin/env sh
set -eu

script_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
cd "$script_dir/.."

fail()
{
    printf '%s\n' "$1" >&2
    exit 1
}

patch_file=$(pwd)/patches/lsquic_h3_message_error.patch
overlay_root=vendor/lsquic_overlay
overlay_files='lsquic_qdec_hdl.h lsquic_qdec_hdl.c lsquic_stream.c'

[ -f "$patch_file" ] || fail "missing $patch_file"
[ -d "$overlay_root" ] || fail "missing $overlay_root"

lsquic_url=$(sed -n \
    's|^[[:space:]]*\.url = "\(git+https://github.com/litespeedtech/lsquic#[0-9a-f]*\)",$|\1|p' \
    build.zig.zon)
[ -n "$lsquic_url" ] || fail "unable to read the pinned lsquic URL from build.zig.zon"

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/uwebzockets-overlay.XXXXXX")
trap 'rm -rf "$tmp_dir"' 0 1 2 15

lsquic_hash=$(zig fetch --global-cache-dir "$tmp_dir/cache" "$lsquic_url" 2>/dev/null | tail -n 1) ||
    fail "unable to fetch the pinned lsquic package"
lsquic_archive=$tmp_dir/cache/p/$lsquic_hash.tar.gz
[ -f "$lsquic_archive" ] || fail "fetch did not produce the pinned lsquic archive"
tar -xzf "$lsquic_archive" -C "$tmp_dir" --strip-components=1

mkdir -p "$tmp_dir/patched/src/liblsquic"
for file in $overlay_files; do
    cp "$tmp_dir/src/liblsquic/$file" "$tmp_dir/patched/src/liblsquic/$file"
done
(
    cd "$tmp_dir/patched"
    git apply -p1 "$patch_file"
)
for file in $overlay_files; do
    cmp -s "$tmp_dir/patched/src/liblsquic/$file" "$overlay_root/src/liblsquic/$file" || fail \
        "vendor/lsquic_overlay/src/liblsquic/$file is stale; regenerate it from the audit patch"
done

generated_file=$overlay_root/lsquic_versions_to_string.c
[ -f "$generated_file" ] || fail "missing $generated_file"
versions=$(sed -n '/^enum lsquic_version/,/^};/p' "$tmp_dir/include/lsquic.h" |
    sed -n 's/^[[:space:]]*\(LSQVER_[A-Za-z0-9_]*\),[[:space:]]*$/\1/p' |
    sort -u)
[ -n "$versions" ] || fail "unable to read the lsquic version enum"
for version in $versions; do
    # LSQVER_RESVED is a reserved slot that gen-verstrs.pl deliberately skips.
    [ "$version" = "LSQVER_RESVED" ] && continue
    grep -q "$version" "$generated_file" || fail \
        "$generated_file does not cover $version; regenerate it with src/liblsquic/gen-verstrs.pl"
done

printf '%s\n' "vendor overlay matches the pinned lsquic revision"
