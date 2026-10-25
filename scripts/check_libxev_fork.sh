#!/usr/bin/env sh
# Verify the libxev dependency pin is a full fork commit and that every
# dependency view agrees on the URL, revision, Zig package hash, and Nix hash.
#
# Usage: check_libxev_fork.sh [--offline] [--exact-mirrors]
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
exact_mirrors=0
for arg in "$@"; do
    case "$arg" in
        (--offline) offline=1 ;;
        (--exact-mirrors) exact_mirrors=1 ;;
        (*) fail "usage: $0 [--offline] [--exact-mirrors]" ;;
    esac
done
if [ "$offline" -eq 1 ] && [ "$exact_mirrors" -eq 1 ]; then
    fail "--offline cannot verify exact upstream mirror equality"
fi
mirror_mode=
if [ "$exact_mirrors" -eq 1 ]; then
    mirror_mode=--exact
fi

. "$script_dir/dependency_mirrors.env"

zon_url=$(sed -n \
    's|^[[:space:]]*\.url = "\(git+https://github.com/farbenbuilds/libxev#[0-9a-f]*\)",$|\1|p' \
    build.zig.zon)
zon_hash=$(sed -n \
    's|^[[:space:]]*\.hash = "\(libxev-[^"]*\)",$|\1|p' \
    build.zig.zon)
[ -n "$zon_url" ] || fail "build.zig.zon does not pin farbenbuilds/libxev"
[ -n "$zon_hash" ] || fail "build.zig.zon has no libxev package hash"

rev=${zon_url##*#}
case "$rev" in
    (*[!0-9a-f]*|"") fail "libxev revision is not lowercase hexadecimal" ;;
esac
[ "${#rev}" -eq 40 ] || fail "libxev revision must be a full 40-hex commit"

# The mirror branch is never a valid pin.
case "$zon_url" in
    (*'#main'|*'#uwz/zig-0.16') fail "libxev must pin a commit, not a branch" ;;
esac

json_url=$(sed -n \
    's|^[[:space:]]*"url": "\(git+https://github.com/farbenbuilds/libxev#[0-9a-f]*\)",$|\1|p' \
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
    fail "build.zig.zon.json is missing the pinned libxev Zig hash"
nix_hash=$(awk -v rev="$rev" '
    $0 ~ ("rev = \"" rev "\";") { seen = 1 }
    seen && /hash = "sha256-/ {
        sub(/^[[:space:]]*hash = "/, "")
        sub(/";$/, "")
        print
        exit
    }
' build.zig.zon.nix)
[ -n "$nix_hash" ] || fail "build.zig.zon.nix is missing the pinned libxev revision"
[ "$json_hash" = "$nix_hash" ] || fail "build.zig.zon.json and .nix hashes disagree"
grep -Fq "$zon_url" build.zig.zon.txt ||
    fail "build.zig.zon.txt is missing the pinned libxev URL"

if [ "$offline" -eq 0 ]; then
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/uwebzockets-xev.XXXXXX")
    trap 'rm -rf "$tmp_dir"' 0 1 2 15
    git init --quiet --bare "$tmp_dir/repo"
    if ! git -C "$tmp_dir/repo" fetch --quiet --depth 1 \
        https://github.com/farbenbuilds/libxev "$rev" 2>/dev/null; then
        fail "unable to resolve libxev commit $rev from farbenbuilds/libxev"
    fi
    git -C "$tmp_dir/repo" cat-file -e "$rev^{commit}" ||
        fail "pinned libxev revision is not a commit on farbenbuilds/libxev"

    branch_tip=$(git ls-remote --exit-code https://github.com/farbenbuilds/libxev refs/heads/uwz/zig-0.16 2>/dev/null | sed -n '1s/[[:space:]].*//p') ||
        fail "unable to resolve the uwz/zig-0.16 integration branch"
    [ -n "$branch_tip" ] || fail "uwz/zig-0.16 has no tip"
    if [ "$branch_tip" != "$rev" ]; then
        git -C "$tmp_dir/repo" fetch --quiet \
            https://github.com/farbenbuilds/libxev \
            refs/heads/uwz/zig-0.16:refs/heads/uwz 2>/dev/null ||
            fail "unable to fetch the uwz/zig-0.16 history"
        git -C "$tmp_dir/repo" merge-base --is-ancestor "$rev" refs/heads/uwz ||
            fail "pinned libxev revision is not on uwz/zig-0.16"
    fi

    sh "$script_dir/check_mirror_state.sh" \
        libxev \
        https://github.com/farbenbuilds/libxev main \
        https://github.com/mitchellh/libxev main \
        "$libxev_mirror" \
        "$mirror_mode"
fi

stale_files="AGENTS.md CONTRIBUTE.md SKILL.md CODEBASE.md CI_CD_PIPELINE.md CODING_CONVENTION.md docs/architecture.md docs/deployment.md docs/roadmap.md docs/dependency_forks.md docs/callback_lifecycle.md docs/websocket.md docs/api.md docs/http.md docs/adr/0001-http3-datagram-and-webtransport.md docs/adr/0004-windows-iocp-accept-and-queued-close.md docs/adr/0005-libxev-fork.md docs/adr/0006-dependency-forks.md .opencode/agents/build_vendor.md .opencode/agents/transport_io.md .codex/agents/build_vendor.toml .codex/agents/transport_io.toml .github/PULL_REQUEST_TEMPLATE.md THIRD_PARTY_NOTICES.md"
stale_multi='still[[:space:]]+pins[[:space:]]+upstream|overlay[[:space:]]+remains[[:space:]]+authoritative|not[[:space:]]+migrated|no[[:space:]]+integration[[:space:]]+branch|migration[[:space:]]+lands|will[[:space:]]+build[[:space:]]+after[[:space:]]+migration|does[[:space:]]+not[[:space:]]+exist[[:space:]]+until|current[[:space:]]+Windows[[:space:]]+IOCP[[:space:]]+overlay|is[[:space:]]+still[[:space:]]+upstream|next[[:space:]]+libxev[[:space:]]+dependency[[:space:]]+update|current[[:space:]]+overlay[[:space:]]+gate|auditable[[:space:]]+overlay|connection[[:space:]]+sweeper'
if command -v rg >/dev/null 2>&1; then
    if rg -n -U -e "$stale_multi" $stale_files; then
        fail "current-state documentation still contains a pre-migration libxev claim"
    fi
else
    if grep -En -e "$stale_multi" $stale_files; then
        fail "current-state documentation still contains a pre-migration libxev claim"
    fi
fi

printf '%s\n' "libxev pin is a full fork commit and all four views agree"
