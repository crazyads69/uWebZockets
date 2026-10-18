#!/usr/bin/env sh
set -eu

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_directory/../benchmarks/h2_tls_scaling_v1.env"

if [ "$#" -ne 3 ]; then
    printf '%s\n' "usage: benchmark_h2_tls.sh <label> <server-binary> <output-directory>" >&2
    exit 2
fi

label=$1
server_binary=$2
output_directory=$3

case "$label" in
    '' | *[!a-z0-9_-]*)
        printf '%s\n' "benchmark label must contain only lowercase letters, digits, dashes, or underscores" >&2
        exit 2
        ;;
esac

if [ ! -x "$server_binary" ]; then
    printf 'benchmark server is not executable: %s\n' "$server_binary" >&2
    exit 2
fi

if ! command -v h2load >/dev/null 2>&1; then
    printf '%s\n' "h2load is required for the $BENCHMARK_ID contract" >&2
    exit 2
fi

mkdir -p "$output_directory"
metadata_file="$output_directory/$label-metadata.txt"
server_log="$output_directory/$label-server.log"
expected_body="$output_directory/$label-expected-body.bin"

{
    printf 'benchmark_id=%s\n' "$BENCHMARK_ID"
    printf 'schema_version=%s\n' "$SCHEMA_VERSION"
    printf 'recorded_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'label=%s\n' "$label"
    printf 'server_binary=%s\n' "$server_binary"
    printf 'server_command=%s\n' "$server_binary"
    printf 'h2load_version=%s\n' "$(h2load --version 2>&1 | head -n 1)"
    printf 'zig_version=%s\n' "$(zig version 2>/dev/null || printf 'unknown')"
    printf 'uname=%s\n' "$(uname -a 2>/dev/null || printf 'unknown')"
    printf 'cpu_model=%s\n' "$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null | head -n 1)"
    printf 'nproc=%s\n' "$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 'unknown')"
    printf 'memlock_kb=%s\n' "$(ulimit -l 2>/dev/null || printf 'unknown')"
    printf 'git_revision=%s\n' "$(git -C "$script_directory/.." rev-parse HEAD 2>/dev/null || printf 'unknown')"
    printf 'tls_min_version=%s\n' "$TLS_MIN_VERSION"
    printf 'connections=%s\n' "$H2LOAD_CONNECTIONS"
    printf 'streams=%s\n' "$H2LOAD_STREAMS"
    printf 'duration_seconds=%s\n' "$H2LOAD_DURATION_SECONDS"
    printf 'warmup_seconds=%s\n' "$H2LOAD_WARMUP_SECONDS"
    printf 'samples=%s\n' "$H2LOAD_SAMPLES"
    printf 'url=%s\n' "$H2LOAD_URL"
} >"$metadata_file"

printf '%s' "$H2LOAD_RESPONSE_BODY" >"$expected_body"

server_pid=
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

"$server_binary" >"$server_log" 2>&1 &
server_pid=$!

ready=false
attempt=0
while [ "$attempt" -lt 200 ]; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
        cat "$server_log" >&2
        exit 1
    fi
    if h2load -n 1 -c 1 -m 1 -t 1 --warm-up-time=0 "$H2LOAD_URL" >/dev/null 2>&1; then
        ready=true
        break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done

if [ "$ready" != true ]; then
    printf '%s\n' "benchmark server did not become ready" >&2
    exit 1
fi

if command -v curl >/dev/null 2>&1; then
    body_file="$output_directory/$label-body.bin"
    if ! curl --silent --show-error --fail --insecure --http1.1 \
        --output "$body_file" "$H2LOAD_URL"; then
        printf '%s\n' "response body check failed" >&2
        exit 1
    fi
    if ! cmp -s "$body_file" "$expected_body"; then
        printf '%s\n' "response body does not match $H2LOAD_RESPONSE_BODY" >&2
        exit 1
    fi
fi

for connections in $H2LOAD_CONNECTIONS; do
    for streams in $H2LOAD_STREAMS; do
        cohort="$label-c$connections-m$streams"
        rates_file="$output_directory/$cohort-rates.txt"
        : >"$rates_file"
        sample=1
        while [ "$sample" -le "$H2LOAD_SAMPLES" ]; do
            result_file="$output_directory/$cohort-$sample.txt"
            h2load \
                -t"$H2LOAD_THREADS" \
                -c"$connections" \
                -m"$streams" \
                -n"$H2LOAD_REQUESTS" \
                -D"$H2LOAD_DURATION_SECONDS" \
                --warm-up-time="$H2LOAD_WARMUP_SECONDS" \
                "$H2LOAD_URL" >"$result_file" 2>&1
            cat "$result_file" >&2

            summary=$(awk '
                /^finished in/ {
                    for (i = 1; i <= NF; ++i) if ($i == "req/s,") rate = $(i - 1)
                }
                /^requests:/ {
                    for (i = 1; i <= NF; ++i) {
                        if ($i == "succeeded,") succeeded = $(i - 1)
                        if ($i == "failed,") failed = $(i - 1)
                        if ($i == "errored,") errored = $(i - 1)
                        if ($i == "timeout") timeout = $(i - 1)
                    }
                }
                /^status codes:/ {
                    line = $0
                    sub(/^status codes: /, "", line)
                    parts = split(line, entries, ",")
                    for (i = 1; i <= parts; ++i) {
                        entry = entries[i]
                        gsub(/^[ \t]+/, "", entry)
                        gsub(/[ \t]+$/, "", entry)
                        split(entry, pair, " ")
                        if (pair[2] !~ /^2/) bad += pair[1]
                    }
                }
                END {
                    printf "%s %s %s %s %s %s\n", rate, succeeded, failed, errored, timeout, bad
                }
            ' "$result_file")

            set -- $summary
            rate=${1-}
            succeeded=${2-}
            failed=${3-}
            errored=${4-}
            timeout=${5-}
            bad_status=${6-}

            if [ -z "$rate" ] || [ -z "$failed" ] || [ -z "$bad_status" ]; then
                printf '%s\n' "h2load summary could not be parsed" >&2
                exit 1
            fi
            if [ "$succeeded" -eq 0 ]; then
                printf '%s\n' "h2load reported no successful requests" >&2
                exit 1
            fi
            if [ "$failed" -ne 0 ] || [ "$errored" -ne 0 ] || [ "$timeout" -ne 0 ] || [ "$bad_status" -ne 0 ]; then
                printf '%s failed=%s errored=%s timeout=%s non_2xx=%s\n' \
                    "$cohort" "$failed" "$errored" "$timeout" "$bad_status" >&2
                exit 1
            fi
            printf '%s\n' "$rate" >>"$rates_file"
            sample=$((sample + 1))
        done

        median_line=$((H2LOAD_SAMPLES / 2 + 1))
        median=$(sort -n "$rates_file" | sed -n "${median_line}p")
        printf '%s %s requests/s\n' "$cohort" "$median"
    done
done
