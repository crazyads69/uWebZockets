#!/usr/bin/env sh

set -eu

if command -v zon2nix >/dev/null 2>&1; then
    zon2nix \
        --nix=build.zig.zon.nix \
        --json=build.zig.zon.json \
        --txt=build.zig.zon.txt \
        build.zig.zon
elif command -v nix >/dev/null 2>&1; then
    nix develop -c zon2nix \
        --nix=build.zig.zon.nix \
        --json=build.zig.zon.json \
        --txt=build.zig.zon.txt \
        build.zig.zon
else
    echo "zon2nix and nix not found, skipping generation"
    exit 0
fi

zon_tmp_file=$(mktemp "${TMPDIR:-/tmp}/uwebzockets-zon.XXXXXX")
trap 'rm -f "$zon_tmp_file"' 0 1 2 15

# zon2nix before 0.9 used a single TMPDIR; newer releases use a per-package
# work directory and already emit the Zig 0.16 names. Normalize only the old
# layout so the generated views stay compatible with the pinned flake.
if ! grep -Fq 'touch "$work/src/build.zig"' build.zig.zon.nix; then
    awk '
    {
        gsub(/zig_0_15/, "zig_0_16")

        if (index($0, "        hash=\"$(cd \"$TMPDIR\" && zig fetch") == 1) {
            print "        # workaround https://codeberg.org/ziglang/zig/issues/31866"
            print "        # https://github.com/Cloudef/zig2nix/issues/54"
            print "        touch \"$TMPDIR/build.zig\""
        }

        if ($0 == "        mv \"$TMPDIR/p/$hash\" \"$out\"")
            $0 = "        mv \"$TMPDIR/p/$hash.tar.gz\" \"$out\""

        print
    }
    ' build.zig.zon.nix > "$zon_tmp_file"

    mv "$zon_tmp_file" build.zig.zon.nix
fi
trap - 0 1 2 15

grep -Fq 'zig_0_16' build.zig.zon.nix
if grep -Fq 'zig_0_15' build.zig.zon.nix; then
    echo "zon2nix normalization retained zig_0_15" >&2
    exit 1
fi
if grep -Fq 'touch "$work/src/build.zig"' build.zig.zon.nix; then
    grep -Fq 'touch "$work/cache/p"' build.zig.zon.nix
else
    grep -Fq 'touch "$TMPDIR/build.zig"' build.zig.zon.nix
    grep -Fq 'mv "$TMPDIR/p/$hash.tar.gz" "$out"' build.zig.zon.nix
fi
