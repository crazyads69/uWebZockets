#!/usr/bin/env sh
# Keeps benchmark result directories reviewable: one archive, one README,
# and one checksum manifest. Raw per-sample files belong inside the archive.
set -eu

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$script_dir/.."

[ -d benchmarks/results ] || exit 0

failed=0
for file in $(find benchmarks/results -type f | sort); do
    base=${file##*/}
    case "$base" in
        README.md | manifest.sha256 | *.tgz | *.tar.gz)
            ;;
        *)
            printf '%s\n' "unarchived benchmark artifact: $file"
            failed=1
            ;;
    esac
done

if [ "$failed" -ne 0 ]; then
    printf '%s\n' \
        "package raw benchmark output into one .tgz before committing; keep README.md and manifest.sha256 beside it" >&2
fi
exit "$failed"
