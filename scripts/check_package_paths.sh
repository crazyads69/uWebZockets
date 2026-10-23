#!/usr/bin/env sh
set -eu

# A path dependency includes the whole repository, so it cannot catch a file
# omitted from build.zig.zon `.paths`. Fetch the tracked tree as a tarball,
# which applies the manifest filter, and compile the downstream fixture from
# that package instead.
script_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
repo_root=$(CDPATH='' cd "$script_dir/.." && pwd)
cd "$repo_root"

fail()
{
    printf '%s\n' "$1" >&2
    exit 1
}

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/uwebzockets-package.XXXXXX")
trap 'rm -rf "$tmp_dir"' 0 1 2 15

archive=$tmp_dir/uwebzockets.tar.gz
git ls-files -z | tar --null --no-recursion -C "$repo_root" -czf "$archive" -T -
[ -s "$archive" ] || fail "unable to archive the tracked tree"

package_hash=$(zig fetch "$archive" | tail -n 1)
[ -n "$package_hash" ] || fail "zig fetch did not return a package hash"

consumer_dir=$tmp_dir/consumer
mkdir -p "$consumer_dir"
cp tests/package_consumer/build.zig tests/package_consumer/main.zig "$consumer_dir/"
cat > "$consumer_dir/build.zig.zon" <<EOF
.{
    .name = .package_paths_probe,
    .version = "0.0.0",
    .fingerprint = 0xf93e5743ca333ffa,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .uwebzockets = .{
            .url = "file://$archive",
            .hash = "$package_hash",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "main.zig",
    },
}
EOF

(
    cd "$consumer_dir"
    zig build check -Doptimize=ReleaseSafe
)

printf '%s\n' "package .paths covers a clean downstream build"
