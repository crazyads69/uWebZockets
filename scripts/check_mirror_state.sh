#!/usr/bin/env sh
# Check one maintained fork mirror against its reviewed commit.
#
# Usage: check_mirror_state.sh NAME FORK_URL FORK_BRANCH UPSTREAM_URL \
#            UPSTREAM_BRANCH REVIEWED [--exact]
#
# Without --exact, the fork branch must equal the reviewed commit. Upstream may
# have advanced; the weekly drift job and release gate run the exact form.
# With --exact, upstream must also equal the reviewed commit.

set -eu

fail()
{
    printf '%s\n' "$1" >&2
    exit 1
}

[ "$#" -eq 6 ] || [ "$#" -eq 7 ] || {
    fail "usage: $0 NAME FORK_URL FORK_BRANCH UPSTREAM_URL UPSTREAM_BRANCH REVIEWED [--exact]"
}

name=$1
fork_url=$2
fork_branch=$3
upstream_url=$4
upstream_branch=$5
reviewed=$6
mode=${7:-}

case "$mode" in
    (""|"--exact") ;;
    (*) fail "usage: $0 NAME FORK_URL FORK_BRANCH UPSTREAM_URL UPSTREAM_BRANCH REVIEWED [--exact]" ;;
esac

case "$reviewed" in
    (*[!0-9a-f]*|"") fail "$name reviewed mirror commit is not lowercase hexadecimal" ;;
esac
[ "${#reviewed}" -eq 40 ] || fail "$name reviewed mirror commit must be a full 40-hex commit"

resolve()
{
    git ls-remote --exit-code "$1" "refs/heads/$2" 2>/dev/null |
        sed -n '1s/[[:space:]].*//p'
}

fork_tip=$(resolve "$fork_url" "$fork_branch") ||
    fail "unable to resolve $name fork mirror $fork_branch"
[ -n "$fork_tip" ] || fail "$name fork mirror $fork_branch has no tip"
[ "$fork_tip" = "$reviewed" ] ||
    fail "$name fork mirror moved to $fork_tip; sync, review, and update scripts/dependency_mirrors.env"

if [ "$mode" = "--exact" ]; then
    upstream_tip=$(resolve "$upstream_url" "$upstream_branch") ||
        fail "unable to resolve $name upstream $upstream_branch"
    [ -n "$upstream_tip" ] || fail "$name upstream $upstream_branch has no tip"
    [ "$upstream_tip" = "$reviewed" ] ||
        fail "$name upstream advanced to $upstream_tip; sync the mirror, review, and update scripts/dependency_mirrors.env"
    printf '%s\n' "$name mirror matches upstream at $reviewed"
else
    printf '%s\n' "$name mirror matches reviewed sync $reviewed"
fi
