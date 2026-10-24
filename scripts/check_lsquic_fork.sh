#!/usr/bin/env sh
# Verify the lsquic dependency pin is a full fork commit and that every
# dependency view agrees on the URL, revision, Zig package hash, and Nix hash.
#
# Usage: check_lsquic_fork.sh [--offline]
#   --offline skips the remote resolution step; lint and release gates run the
#   default online form.

set -eu

script_dir=$(CDPATH='' cd "$(dirname "$0")" && pwd)
cd "$script_dir/.."

fail()
{
    printf '%s\n' "$1" >&2
    exit 1
}

offline=0
if [ "${1:-}" = "--offline" ]; then
    offline=1
elif [ "$#" -ne 0 ]; then
    fail "usage: $0 [--offline]"
fi

zon_url=$(sed -n \
    's|^[[:space:]]*\.url = "\(git+https://github.com/farbenbuilds/lsquic#[0-9a-f]*\)",$|\1|p' \
    build.zig.zon)
[ -n "$zon_url" ] || fail "build.zig.zon does not pin farbenbuilds/lsquic"

rev=${zon_url##*#}
case "$rev" in
    (*[!0-9a-f]*|"") fail "lsquic revision is not lowercase hexadecimal" ;;
esac
[ "${#rev}" -eq 40 ] || fail "lsquic revision must be a full 40-hex commit"

zon_hash=$(awk -v rev="$rev" '
    index($0, "farbenbuilds/lsquic#" rev) { seen = 1 }
    seen && /\.hash = "N-V-/ {
        sub(/^[[:space:]]*\.hash = "/, "")
        sub(/",$/, "")
        print
        exit
    }
' build.zig.zon)
[ -n "$zon_hash" ] || fail "build.zig.zon has no lsquic package hash"

json_url=$(sed -n \
    's|^[[:space:]]*"url": "\(git+https://github.com/farbenbuilds/lsquic#[0-9a-f]*\)",$|\1|p' \
    build.zig.zon.json)
json_hash=$(awk -v key="\"$zon_hash\"" '
    $0 ~ ("^  " key ": \\{") { seen = 1 }
    seen && /"hash": "sha256-/ {
        sub(/^[[:space:]]*"hash": "/, "")
        sub(/",?$/, "")
        print
        exit
    }
' build.zig.zon.json)
[ "$json_url" = "$zon_url" ] || fail "build.zig.zon.json URL disagrees with build.zig.zon"
grep -Fq "\"$zon_hash\"" build.zig.zon.json ||
    fail "build.zig.zon.json is missing the pinned lsquic Zig hash"
nix_hash=$(awk -v rev="$rev" '
    $0 ~ ("rev = \"" rev "\";") { seen = 1 }
    seen && /hash = "sha256-/ {
        sub(/^[[:space:]]*hash = "/, "")
        sub(/";$/, "")
        print
        exit
    }
' build.zig.zon.nix)
[ -n "$nix_hash" ] || fail "build.zig.zon.nix is missing the pinned lsquic revision"
[ "$json_hash" = "$nix_hash" ] || fail "build.zig.zon.json and .nix hashes disagree"
grep -Fq 'url = "https://github.com/farbenbuilds/lsquic";' build.zig.zon.nix ||
    fail "build.zig.zon.nix does not use the maintained lsquic fork"
grep -Fq "$zon_url" build.zig.zon.txt ||
    fail "build.zig.zon.txt is missing the pinned lsquic URL"
if grep -Fq '"patches"' build.zig.zon; then
    fail "build.zig.zon still packages the removed patches directory"
fi
if grep -Fq '"vendor/lsquic_overlay"' build.zig.zon; then
    fail "build.zig.zon still packages the removed lsquic overlay"
fi
if rg -n 'vendor/lsquic_overlay|patches/lsquic' builds/vendor/lsquic.zig >/dev/null 2>&1; then
    fail "builds/vendor/lsquic.zig still references a local overlay or patch"
fi

if [ "$offline" -eq 0 ]; then
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/uwebzockets-lsquic.XXXXXX")
    trap 'rm -rf "$tmp_dir"' 0 1 2 15
    git init --quiet --bare "$tmp_dir/repo"
    if ! git -C "$tmp_dir/repo" fetch --quiet --depth 1 \
        https://github.com/farbenbuilds/lsquic "$rev" 2>/dev/null; then
        fail "unable to resolve lsquic commit $rev from farbenbuilds/lsquic"
    fi
    git -C "$tmp_dir/repo" cat-file -e "$rev^{commit}" ||
        fail "pinned lsquic revision is not a commit on farbenbuilds/lsquic"

    branch_tip=$(git ls-remote --exit-code https://github.com/farbenbuilds/lsquic \
        refs/heads/uwz/main 2>/dev/null | sed -n '1s/[[:space:]].*//p') ||
        fail "unable to resolve the lsquic uwz/main integration branch"
    [ -n "$branch_tip" ] || fail "lsquic uwz/main has no tip"
    if [ "$branch_tip" != "$rev" ]; then
        git -C "$tmp_dir/repo" fetch --quiet \
            https://github.com/farbenbuilds/lsquic \
            refs/heads/uwz/main:refs/heads/uwz 2>/dev/null ||
            fail "unable to fetch the lsquic uwz/main history"
        git -C "$tmp_dir/repo" merge-base --is-ancestor "$rev" refs/heads/uwz ||
            fail "pinned lsquic revision is not on uwz/main"
    fi

    fork_master=$(git ls-remote --exit-code https://github.com/farbenbuilds/lsquic \
        refs/heads/master 2>/dev/null | sed -n '1s/[[:space:]].*//p') ||
        fail "unable to resolve the fork mirror master"
    upstream_master=$(git ls-remote --exit-code https://github.com/litespeedtech/lsquic \
        refs/heads/master 2>/dev/null | sed -n '1s/[[:space:]].*//p') ||
        fail "unable to resolve upstream lsquic master"
    [ "$fork_master" = "$upstream_master" ] ||
        fail "farbenbuilds/lsquic master is not an exact upstream mirror"
fi

printf '%s\n' "lsquic pin is a full fork commit and all four views agree"
