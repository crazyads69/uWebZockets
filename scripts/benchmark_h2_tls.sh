#!/usr/bin/env sh
set -eu

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_directory/../benchmarks/h2_tls_scaling_v1.env"

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    printf '%s\n' "usage: benchmark_h2_tls.sh <label> <server-binary> <output-directory> [url]" >&2
    exit 2
fi

label=$1
server_binary=$2
output_directory=$3
url=${4:-$H2LOAD_URL}
mode=${UWZ_MODE:-tls-cluster}
max_clients=${UWZ_MAX_CLIENTS:-128}
extra_args=${UWZ_H2LOAD_EXTRA_ARGS:-}

fail()
{
    printf '%s\n' "$1" >&2
    exit 1
}

case "$label" in
    '' | *[!a-z0-9_-]*)
        fail "benchmark label must contain only lowercase letters, digits, dashes, or underscores"
        ;;
esac

case "$url" in
    https://* | http://*) ;;
    *) fail "benchmark URL must use http or https" ;;
esac

case "$mode" in
    tls-cluster | plaintext-cluster | tls-single) ;;
    *) fail "UWZ_MODE must be tls-cluster, plaintext-cluster, or tls-single" ;;
esac

if [ "$mode" = "plaintext-cluster" ]; then
    case "$url" in
        https://*) fail "plaintext-cluster requires an http:// URL" ;;
    esac
else
    case "$url" in
        http://*) fail "$mode requires an https:// URL" ;;
    esac
    [ -n "${UWZ_TLS_CERT:-}" ] || fail "$mode requires UWZ_TLS_CERT with real PEM credentials"
    [ -n "${UWZ_TLS_KEY:-}" ] || fail "$mode requires UWZ_TLS_KEY with real PEM credentials"
    [ -r "$UWZ_TLS_CERT" ] || fail "UWZ_TLS_CERT is not readable: $UWZ_TLS_CERT"
    [ -r "$UWZ_TLS_KEY" ] || fail "UWZ_TLS_KEY is not readable: $UWZ_TLS_KEY"
fi

if [ ! -x "$server_binary" ]; then
    fail "benchmark server is not executable: $server_binary"
fi

if ! command -v h2load >/dev/null 2>&1; then
    fail "h2load is required for the $BENCHMARK_ID contract"
fi

peak_connections=0
for connections in $H2LOAD_CONNECTIONS; do
    if [ "$connections" -gt "$peak_connections" ]; then
        peak_connections=$connections
    fi
done
if [ "$max_clients" -lt "$peak_connections" ]; then
    fail "UWZ_MAX_CLIENTS=$max_clients is below the peak connection level $peak_connections"
fi
fd_limit=$(ulimit -n)
if [ "$fd_limit" -lt $((peak_connections + 128)) ]; then
    fail "open-file limit $fd_limit cannot hold $peak_connections connections; raise ulimit -n"
fi

mkdir -p "$output_directory"
metadata_file="$output_directory/${label}_metadata.txt"
server_log="$output_directory/${label}_server.log"
expected_body="$output_directory/${label}_expected_body.bin"
cpu_file="$output_directory/${label}_cpu_rss.tsv"
summary_file="$output_directory/${label}_summary.tsv"
failure_file="$output_directory/${label}_failure.txt"
cert_fingerprint=unknown
if [ -n "${UWZ_TLS_CERT:-}" ] && command -v openssl >/dev/null 2>&1; then
    cert_fingerprint=$(openssl x509 -in "$UWZ_TLS_CERT" -noout -fingerprint -sha256 2>/dev/null |
        sed 's/^.*=//' || printf 'unknown')
fi
flake_hash=unknown
if [ -f "$script_directory/../flake.lock" ]; then
    flake_hash=$(sha256sum "$script_directory/../flake.lock" | awk '{print $1}')
fi
{
    printf 'benchmark_id=%s\n' "$BENCHMARK_ID"
    printf 'schema_version=%s\n' "$SCHEMA_VERSION"
    printf 'recorded_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'label=%s\n' "$label"
    printf 'mode=%s\n' "$mode"
    printf 'server_binary=%s\n' "$server_binary"
    printf 'server_command=%s\n' "$server_binary"
    printf 'hostname=%s\n' "$(hostname 2>/dev/null || printf 'unknown')"
    printf 'h2load_version=%s\n' "$(h2load --version 2>&1 | head -n 1)"
    printf 'h2load_extra_args=%s\n' "$extra_args"
    printf 'zig_version=%s\n' "$(zig version 2>/dev/null || printf 'unknown')"
    printf 'uname=%s\n' "$(uname -a 2>/dev/null || printf 'unknown')"
    printf 'cpu_model=%s\n' "$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null | head -n 1)"
    printf 'nproc=%s\n' "$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 'unknown')"
    printf 'physical_cores=%s\n' "$(lscpu -p=core,socket 2>/dev/null | sed '/^#/d' | sort -u | wc -l | tr -d ' ')"
    printf 'smt_state=%s\n' "$(sed -n 's/^.*SMT[[:space:]]*\(.*\)$/\1/p' /proc/cpuinfo 2>/dev/null | head -n 1)"
    printf 'cpu_governor=%s\n' "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || printf 'unknown')"
    printf 'kernel=%s\n' "$(uname -r 2>/dev/null || printf 'unknown')"
    printf 'memlock_kb=%s\n' "$(ulimit -l 2>/dev/null || printf 'unknown')"
    printf 'open_files=%s\n' "$fd_limit"
    printf 'git_revision=%s\n' "$(git -C "$script_directory/.." rev-parse HEAD 2>/dev/null || printf 'unknown')"
    printf 'git_describe=%s\n' "$(git -C "$script_directory/.." describe --tags --always 2>/dev/null || printf 'unknown')"
    printf 'flake_lock_sha256=%s\n' "$flake_hash"
    printf 'dependency_manifest_sha256=%s\n' "$(sha256sum "$script_directory/../build.zig.zon" 2>/dev/null | awk '{print $1}')"
    printf 'tls_min_version=%s\n' "$TLS_MIN_VERSION"
    printf 'certificate_sha256=%s\n' "$cert_fingerprint"
    printf 'workers=%s\n' "${UWZ_WORKERS:-4}"
    printf 'max_clients=%s\n' "$max_clients"
    printf 'cpu_affinity=%s\n' "${UWZ_CPU_AFFINITY:-1}"
    printf 'connections=%s\n' "$H2LOAD_CONNECTIONS"
    printf 'streams=%s\n' "$H2LOAD_STREAMS"
    printf 'duration_seconds=%s\n' "$H2LOAD_DURATION_SECONDS"
    printf 'warmup_seconds=%s\n' "$H2LOAD_WARMUP_SECONDS"
    printf 'samples=%s\n' "$H2LOAD_SAMPLES"
    printf 'url=%s\n' "$url"
} >"$metadata_file"

printf '%s' "$H2LOAD_RESPONSE_BODY" >"$expected_body"

server_pid=
sampler_pid=

stop_sampler()
{
    if [ -n "$sampler_pid" ]; then
        kill "$sampler_pid" 2>/dev/null || true
        wait "$sampler_pid" 2>/dev/null || true
        sampler_pid=
    fi
}

cleanup()
{
    stop_sampler
    if [ -n "$server_pid" ]; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

start_sampler()
{
    clock_ticks=$(getconf CLK_TCK 2>/dev/null || printf '100')
    (
        printf 'timestamp_ms\tcpu_seconds\trss_kb\n'
        while kill -0 "$server_pid" 2>/dev/null; do
            stat_line=$(cat "/proc/$server_pid/stat" 2>/dev/null) || break
            trimmed=${stat_line##*) }
            ticks=$(printf '%s\n' "$trimmed" | awk '{print $12 + $13}')
            rss_kb=$(awk '/^VmRSS:/{print $2}' "/proc/$server_pid/status" 2>/dev/null || printf '0')
            cpu_seconds=$(awk -v ticks="$ticks" -v hz="$clock_ticks" 'BEGIN{printf "%.3f", ticks / hz}')
            printf '%s\t%s\t%s\n' "$(date +%s%3N 2>/dev/null || date +%s)" "$cpu_seconds" "${rss_kb:-0}"
            sleep 1
        done
    ) >"$cpu_file" &
    sampler_pid=$!
}

detect_backend()
{
    for fd_path in "/proc/$server_pid/fd"/*; do
        target=$(readlink "$fd_path" 2>/dev/null || true)
        case "$target" in
            *io_uring*) printf '%s\n' "io_uring"; return ;;
            *eventpoll*) printf '%s\n' "epoll"; return ;;
        esac
    done
    printf '%s\n' "unknown"
}

record_failure()
{
    {
        printf 'cohort=%s sample=%s\n' "${cohort:-unknown}" "${sample:-unknown}"
        printf 'url=%s\n' "$url"
        printf 'h2load_extra_args=%s\n' "$extra_args"
        printf '%s\n' '--- server status ---'
        sed -n '1,40p' "/proc/$server_pid/status" 2>/dev/null || true
        printf '%s\n' '--- socket states ---'
        ss -tanp 2>/dev/null | head -n 80 || true
        printf '%s\n' '--- server log tail ---'
        tail -n 80 "$server_log" 2>/dev/null || true
    } >"$failure_file"
}

"$server_binary" >"$server_log" 2>&1 &
server_pid=$!
start_sampler

ready=false
attempt=0
while [ "$attempt" -lt 1200 ]; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
        cat "$server_log" >&2
        fail "benchmark server exited before becoming ready"
    fi
    # h2load exits zero even when every request fails to connect, so require
    # one successful request in the summary instead of trusting the status.
    # shellcheck disable=SC2086
    if readiness_output=$(h2load -n 1 -c 1 -m 1 -t 1 --warm-up-time=0 $extra_args "$url" 2>&1); then
        if printf '%s\n' "$readiness_output" | grep -q '^requests:.*1 succeeded'; then
            ready=true
            break
        fi
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done

if [ "$ready" != true ]; then
    record_failure
    fail "benchmark server did not become ready"
fi

backend=$(detect_backend)
printf 'backend=%s\n' "$backend" >>"$metadata_file"

curl_args=
if [ "$mode" != "plaintext-cluster" ] && [ "${UWZ_CURL_INSECURE:-0}" = "1" ]; then
    curl_args=--insecure
fi
if command -v curl >/dev/null 2>&1; then
    body_file="$output_directory/${label}_body.bin"
    # shellcheck disable=SC2086
    if ! curl --silent --show-error --fail $curl_args --http1.1 \
        --output "$body_file" "$url"; then
        record_failure
        fail "response body check failed"
    fi
    if ! cmp -s "$body_file" "$expected_body"; then
        record_failure
        fail "response body does not match $H2LOAD_RESPONSE_BODY"
    fi
fi

printf 'cohort\tconnections\tstreams\tsample\trate\tsucceeded\tfailed\terrored\ttimeout\tnon_2xx\tmin\tmax\tmedian\tp95\tp99\tmean\tsd\n' >"$summary_file"

for connections in $H2LOAD_CONNECTIONS; do
    for streams in $H2LOAD_STREAMS; do
        cohort="${label}_c${connections}_m${streams}"
        rates_file="$output_directory/${cohort}_rates.txt"
        : >"$rates_file"
        sample=1
        while [ "$sample" -le "$H2LOAD_SAMPLES" ]; do
            result_file="$output_directory/${cohort}_${sample}.txt"
            # shellcheck disable=SC2086
            if ! h2load \
                -t"$H2LOAD_THREADS" \
                -c"$connections" \
                -m"$streams" \
                -n"$H2LOAD_REQUESTS" \
                -D"$H2LOAD_DURATION_SECONDS" \
                --warm-up-time="$H2LOAD_WARMUP_SECONDS" \
                $extra_args \
                "$url" >"$result_file" 2>&1; then
                cat "$result_file" >&2
                record_failure
                fail "$cohort sample $sample: h2load exited nonzero"
            fi
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
                /^request[ \t]*:/ {
                    for (i = 1; i <= NF; ++i) {
                        if ($i == ":") {
                            min = $(i + 1)
                            max = $(i + 2)
                            median = $(i + 3)
                            p95 = $(i + 4)
                            p99 = $(i + 5)
                            mean = $(i + 6)
                            sd = $(i + 7)
                            break
                        }
                    }
                }
                END {
                    printf "%s %s %s %s %s %s %s %s %s %s %s %s %s\n", \
                        rate, succeeded, failed, errored, timeout, bad, \
                        min, max, median, p95, p99, mean, sd
                }
            ' "$result_file")

            set -- $summary
            rate=${1-}
            succeeded=${2-}
            failed=${3-}
            errored=${4-}
            timeout=${5-}
            bad_status=${6-}
            req_min=${7-unknown}
            req_max=${8-unknown}
            req_median=${9-unknown}
            req_p95=${10-unknown}
            req_p99=${11-unknown}
            req_mean=${12-unknown}
            req_sd=${13-unknown}

            if [ -z "$rate" ] || [ -z "$failed" ] || [ -z "$bad_status" ]; then
                record_failure
                fail "h2load summary could not be parsed"
            fi
            if [ "$succeeded" -eq 0 ]; then
                record_failure
                fail "h2load reported no successful requests"
            fi
            if [ "$failed" -ne 0 ] || [ "$errored" -ne 0 ] || [ "$timeout" -ne 0 ] || [ "$bad_status" -ne 0 ]; then
                record_failure
                fail "$cohort failed=$failed errored=$errored timeout=$timeout non_2xx=$bad_status"
            fi

            printf '%s\n' "$rate" >>"$rates_file"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$cohort" "$connections" "$streams" "$sample" "$rate" "$succeeded" \
                "$failed" "$errored" "$timeout" "$bad_status" "$req_min" "$req_max" \
                "$req_median" "$req_p95" "$req_p99" "$req_mean" "$req_sd" >>"$summary_file"
            sample=$((sample + 1))
        done

        median_line=$((H2LOAD_SAMPLES / 2 + 1))
        median=$(sort -n "$rates_file" | sed -n "${median_line}p")
        printf '%s %s requests/s\n' "$cohort" "$median"
    done
done

stop_sampler
kill -TERM "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=

if [ -f "$server_log" ]; then
    grep 'worker_accepts' "$server_log" >"$output_directory/${label}_workers.tsv" || true
fi

printf '%s\n' "benchmark artifacts written to $output_directory"
