#!/usr/bin/env sh
set -eu

if ! command -v rg >/dev/null 2>&1; then
    printf '%s\n' "ripgrep is required for convention checks" >&2
    exit 1
fi

failed=0

bad_files=$(
    rg --files .github builds src examples tests scripts fuzz oss-fuzz benchmarks include misc |
        while IFS= read -r file; do
            base=${file##*/}
            case "$base" in
                build.zig | build.zig.zon | *.schema.json | CODE_OF_CONDUCT.md | COMMIT_CONVENTION.md | Dockerfile | FUNDING.yml | PULL_REQUEST_TEMPLATE.md | README.md | uWebZockets.h)
                    continue
                    ;;
            esac
            stem=${base%.*}
            case "$stem" in
                *[!a-z0-9_]*)
                    printf '%s\n' "$file"
                    ;;
            esac
        done
)

if [ -n "$bad_files" ]; then
    printf '%s\n' "file names must use snake_case:"
    printf '%s\n' "$bad_files"
    failed=1
fi

if rg -n -g '*.zig' --pcre2 '\b(?:(?:pub|export|inline|noinline)\s+)*fn\s+(?!LLVMFuzzerTestOneInput\b)(?:[A-Za-z_][A-Za-z0-9]*[A-Z][A-Za-z0-9]*|[A-Z][A-Za-z0-9_]*)\b' build.zig builds src examples tests fuzz; then
    printf '%s\n' "function names must use snake_case"
    failed=1
fi

if rg -n -g '*.zig' --pcre2 '\b(?:const|var)\s+[a-z][A-Za-z0-9]*[A-Z][A-Za-z0-9]*\b' build.zig builds src examples tests fuzz; then
    printf '%s\n' "variable names must use snake_case"
    failed=1
fi

if rg -n -g '*.zig' --pcre2 '^(?:pub\s+)?const\s+[a-z][a-z0-9_]*\s*=\s*(?:packed\s+|extern\s+)?(?:(?:struct|enum|union)\s*[({]|error\s*\{)|^\s+pub\s+const\s+[a-z][a-z0-9_]*\s*=\s*(?:packed\s+|extern\s+)?(?:(?:struct|enum|union)\s*[({]|error\s*\{)' build.zig builds src examples tests fuzz; then
    printf '%s\n' "type names must use PascalCase"
    failed=1
fi

if rg -n -g '*.zig' --pcre2 '(?:^\s*|[,(]\s*)[a-z][a-z0-9_]*[A-Z][A-Za-z0-9_]*\s*:' build.zig builds src examples tests fuzz; then
    printf '%s\n' "field and parameter names must use snake_case"
    failed=1
fi

if rg -n -g '*.zig' 'std\.debug\.print' src -g '!src/tests/**'; then
    printf '%s\n' "library code must use std.log.scoped instead of std.debug.print"
    failed=1
fi

if rg -n -g '*.zig' 'std\.io\.getStdOut|std\.io\.getStdErr' src; then
    printf '%s\n' "library code must not write directly to stdout or stderr"
    failed=1
fi

if rg -n -g '*.zig' -g '*.zon' --pcre2 '\b(?:TODO|FIXME|XXX|HACK)\b' build.zig builds src examples tests fuzz; then
    printf '%s\n' "TODO, FIXME, XXX, and HACK markers are not permitted"
    failed=1
fi

if rg -n --pcre2 '[\x{1F1E6}-\x{1FAFF}\x{2600}-\x{27BF}]' . -g '*.{c,h,json,md,nix,sh,ts,yaml,yml,zig,zon}' -g '!.agents/**' -g '!.git/**' -g '!.zig-cache/**' -g '!vendor/**' -g '!zig-out/**' -g '!zig-pkg/**'; then
    printf '%s\n' "emoji characters are not permitted"
    failed=1
fi

if ! sh scripts/check_benchmark_results.sh; then
    failed=1
fi

exit "$failed"
