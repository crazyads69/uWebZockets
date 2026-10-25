#!/usr/bin/env sh
# Verify the h1spec compliance submodule is pinned to the maintained fork and
# that the CI job no longer applies a local patch.
#
# Usage: check_h1spec_fork.sh [--offline] [--exact-mirrors]
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

grep -Fq 'url = https://github.com/farbenbuilds/h1spec' .gitmodules ||
    fail ".gitmodules does not use the maintained h1spec fork"

gitlink=$(git ls-files -s vendor/h1spec | awk '{print $2}')
[ -n "$gitlink" ] || fail "vendor/h1spec is not a tracked submodule"
case "$gitlink" in
    (*[!0-9a-f]*|"") fail "h1spec gitlink is not lowercase hexadecimal" ;;
esac
[ "${#gitlink}" -eq 40 ] || fail "h1spec gitlink must be a full 40-hex commit"

head_rev=$(git -C vendor/h1spec rev-parse HEAD 2>/dev/null) ||
    fail "vendor/h1spec is not checked out"
[ "$head_rev" = "$gitlink" ] ||
    fail "vendor/h1spec HEAD does not match the recorded gitlink"

if rg -n 'h1spec_deno_cleanup|patches/h1spec' \
    .github/workflows/h1spec_compliance.yml >/dev/null 2>&1; then
    fail "the h1spec workflow still applies a local patch"
fi

if [ "$offline" -eq 0 ]; then
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/uwebzockets-h1spec.XXXXXX")
    trap 'rm -rf "$tmp_dir"' 0 1 2 15
    git init --quiet --bare "$tmp_dir/repo"
    if ! git -C "$tmp_dir/repo" fetch --quiet --depth 1 \
        https://github.com/farbenbuilds/h1spec "$gitlink" 2>/dev/null; then
        fail "unable to resolve h1spec commit $gitlink from farbenbuilds/h1spec"
    fi
    git -C "$tmp_dir/repo" cat-file -e "$gitlink^{commit}" ||
        fail "pinned h1spec revision is not a commit on farbenbuilds/h1spec"

    branch_tip=$(git ls-remote --exit-code https://github.com/farbenbuilds/h1spec \
        refs/heads/uwz/main 2>/dev/null | sed -n '1s/[[:space:]].*//p') ||
        fail "unable to resolve the h1spec uwz/main integration branch"
    [ -n "$branch_tip" ] || fail "h1spec uwz/main has no tip"
    if [ "$branch_tip" != "$gitlink" ]; then
        git -C "$tmp_dir/repo" fetch --quiet \
            https://github.com/farbenbuilds/h1spec \
            refs/heads/uwz/main:refs/heads/uwz 2>/dev/null ||
            fail "unable to fetch the h1spec uwz/main history"
        git -C "$tmp_dir/repo" merge-base --is-ancestor "$gitlink" refs/heads/uwz ||
            fail "pinned h1spec revision is not on uwz/main"
    fi

    sh "$script_dir/check_mirror_state.sh" \
        h1spec \
        https://github.com/farbenbuilds/h1spec main \
        https://github.com/uNetworking/h1spec main \
        "$h1spec_mirror" \
        "$mirror_mode"
fi

printf '%s\n' "h1spec submodule is a full fork commit with no local patch"
