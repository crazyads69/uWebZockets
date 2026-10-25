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
platform=$(uname -s)
curl_insecure=${UWZ_CURL_INSECURE:-0}

fail()
{
    printf '%s\n' "$1" >&2
    exit 1
}

require_positive_integer()
{
    case "$2" in
        '' | *[!0-9]*) fail "$1 must be a positive integer: $2" ;;
    esac
    [ "$2" -gt 0 ] || fail "$1 must be a positive integer: $2"
}

require_non_negative_integer()
{
    case "$2" in
        '' | *[!0-9]*) fail "$1 must be a non-negative integer: $2" ;;
    esac
}

case "$platform" in
    Linux | Darwin) ;;
    *) fail "benchmark platform is unsupported: $platform" ;;
esac

if [ "$platform" = "Darwin" ]; then
    listener_tool=lsof
elif command -v ss >/dev/null 2>&1; then
    listener_tool=ss
elif command -v lsof >/dev/null 2>&1; then
    listener_tool=lsof
else
    fail "ss or lsof is required to verify the benchmark listener"
fi

case "$curl_insecure" in
    0 | 1) ;;
    *) fail "UWZ_CURL_INSECURE must be 0 or 1" ;;
esac

sha256_file()
{
    [ -r "$1" ] || return 1
    if [ "$platform" = "Darwin" ]; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

listener_lines()
{
    if [ "$listener_tool" = "ss" ]; then
        ss -H -ltnp "sport = :$1" 2>/dev/null || true
    else
        lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null || true
    fi
}

listener_present()
{
    listener_lines "$1" | grep -q .
}

listener_owned()
{
    if [ "$listener_tool" = "ss" ]; then
        ss -H -ltnp "sport = :$target_port" 2>/dev/null | grep -Fq "pid=$server_pid,"
    else
        lsof -nP -iTCP:"$target_port" -sTCP:LISTEN -a -p "$server_pid" 2>/dev/null |
            grep -q .
    fi
}

cpu_quota()
{
    if [ -r /sys/fs/cgroup/cpu.max ]; then
        quota_line=$(cat /sys/fs/cgroup/cpu.max)
        set -- $quota_line
        if [ "${1:-}" = "max" ]; then
            printf '%s\n' "unlimited"
        else
            printf '%s %s\n' "$1" "$2" | awk '{printf "%.3f cores\n", $1 / $2}'
        fi
        return
    fi

    if [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
        quota_value=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
        period_value=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
        if [ "$quota_value" -lt 0 ]; then
            printf '%s\n' "unlimited"
        else
            printf '%s %s\n' "$quota_value" "$period_value" | awk '{printf "%.3f cores\n", $1 / $2}'
        fi
        return
    fi

    printf '%s\n' "unknown"
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
alpn_value=h2
if [ "$mode" = plaintext-cluster ]; then
    alpn_value=not_applicable
fi

case "$url" in
    https://*) default_port=443 ;;
    *) default_port=80 ;;
esac
authority=${url#*://}
authority=${authority%%/*}
case "$authority" in
    \[*\]:*) target_port=${authority##*:} ;;
    \[*\]) target_port=$default_port ;;
    *:*) target_port=${authority##*:} ;;
    *) target_port=$default_port ;;
esac
case "$target_port" in
    '' | *[!0-9]*) fail "benchmark URL has an invalid port: $url" ;;
esac
if [ "$target_port" -lt 1 ] || [ "$target_port" -gt 65535 ]; then
    fail "benchmark URL port is out of range: $target_port"
fi

if [ ! -x "$server_binary" ]; then
    fail "benchmark server is not executable: $server_binary"
fi

if ! command -v h2load >/dev/null 2>&1; then
    fail "h2load is required for the $BENCHMARK_ID contract"
fi
if ! h2load_version_line=$(h2load --version 2>&1 | head -n 1); then
    fail "could not query the h2load version"
fi
h2load_version=$(printf '%s\n' "$h2load_version_line" |
    sed -n 's#.*nghttp2/\([0-9][0-9]*\)\.\([0-9][0-9]*\)\.\([0-9][0-9]*\).*#\1 \2 \3#p')
[ -n "$h2load_version" ] ||
    fail "could not parse the h2load version: $h2load_version_line"
h2load_major=${h2load_version%% *}
h2load_rest=${h2load_version#* }
h2load_minor=${h2load_rest%% *}
if [ "$h2load_major" -lt 1 ] ||
    { [ "$h2load_major" -eq 1 ] && [ "$h2load_minor" -lt 69 ]; }
then
    fail "h2load nghttp2 1.69.0 or newer is required for p99 statistics: $h2load_version_line"
fi

if ! command -v curl >/dev/null 2>&1; then
    fail "curl is required to verify the exact response body"
fi

if [ "$platform" = "Darwin" ] && ! command -v lsof >/dev/null 2>&1; then
    fail "lsof is required to verify the selected Darwin backend"
fi

require_positive_integer H2LOAD_THREADS "$H2LOAD_THREADS"
require_positive_integer H2LOAD_REQUESTS "$H2LOAD_REQUESTS"
require_positive_integer H2LOAD_DURATION_SECONDS "$H2LOAD_DURATION_SECONDS"
require_non_negative_integer H2LOAD_WARMUP_SECONDS "$H2LOAD_WARMUP_SECONDS"
require_positive_integer H2LOAD_SAMPLES "$H2LOAD_SAMPLES"
if [ $((H2LOAD_SAMPLES % 2)) -eq 0 ]; then
    fail "H2LOAD_SAMPLES must be odd so the median is a measured sample"
fi
[ -n "$H2LOAD_CONNECTIONS" ] || fail "H2LOAD_CONNECTIONS must not be empty"
[ -n "$H2LOAD_STREAMS" ] || fail "H2LOAD_STREAMS must not be empty"
for connections in $H2LOAD_CONNECTIONS; do
    require_positive_integer "H2LOAD_CONNECTIONS entry" "$connections"
done
for streams in $H2LOAD_STREAMS; do
    require_positive_integer "H2LOAD_STREAMS entry" "$streams"
done

peak_connections=0
for connections in $H2LOAD_CONNECTIONS; do
    if [ "$connections" -gt "$peak_connections" ]; then
        peak_connections=$connections
    fi
done
require_positive_integer UWZ_MAX_CLIENTS "$max_clients"
if [ "$max_clients" -lt "$peak_connections" ]; then
    fail "UWZ_MAX_CLIENTS=$max_clients is below the peak connection level $peak_connections"
fi
mkdir -p "$output_directory"
metadata_file="$output_directory/${label}_metadata.txt"
server_log="$output_directory/${label}_server.log"
expected_body="$output_directory/${label}_expected_body.bin"
cpu_file="$output_directory/${label}_cpu_rss.tsv"
summary_file="$output_directory/${label}_summary.tsv"
cohort_medians_file="$output_directory/${label}_cohort_medians.tsv"
workers_file="$output_directory/${label}_workers.tsv"
status_file="$output_directory/${label}_run.status"
failure_file="$output_directory/${label}_failure.txt"
: >"$failure_file"
: >"$workers_file"
printf 'cohort\tconnections\tstreams\tsample\trate\tsucceeded\tfailed\terrored\ttimeout\tnon_2xx\tmin\tmax\tmedian\tp95\tp99\tmean\tsd\n' \
    >"$summary_file"
printf 'cohort\trate_median\trate_min\trate_max\tp99_median_us\tp99_min_us\tp99_max_us\n' \
    >"$cohort_medians_file"
printf '%s\n' "in_progress" >"$status_file"
cert_fingerprint=unknown
if [ -n "${UWZ_TLS_CERT:-}" ] && command -v openssl >/dev/null 2>&1; then
    cert_fingerprint=$(openssl x509 -in "$UWZ_TLS_CERT" -noout -fingerprint -sha256 2>/dev/null |
        sed 's/^.*=//')
    cert_fingerprint=${cert_fingerprint:-unknown}
fi
flake_hash=unknown
if [ -f "$script_directory/../flake.lock" ]; then
    flake_hash=$(sha256_file "$script_directory/../flake.lock" || true)
    flake_hash=${flake_hash:-unknown}
fi
dependency_hash=$(sha256_file "$script_directory/../build.zig.zon" || true)
dependency_hash=${dependency_hash:-unknown}

required_fds=$((peak_connections + 128))
fd_limit=$(ulimit -n)
case "$fd_limit" in
    unlimited) ;;
    '' | *[!0-9]*) fail "open-file limit is not numeric: $fd_limit" ;;
    *)
        if [ "$fd_limit" -lt "$required_fds" ]; then
            fail "open-file limit $fd_limit cannot hold $peak_connections connections; raise ulimit -n"
        fi
        ;;
esac

workers_value=unknown
workers_source=default_runtime
if [ "$mode" = "tls-single" ]; then
    workers_value=1
    workers_source=mode
elif [ -n "${UWEBZOCKETS_WORKERS:-}" ]; then
    workers_value=$UWEBZOCKETS_WORKERS
    workers_source=UWEBZOCKETS_WORKERS
elif [ -n "${UWZ_WORKERS:-}" ]; then
    workers_value=$UWZ_WORKERS
    workers_source=UWZ_WORKERS
fi

git_dirty=unknown
if git_status=$(git -C "$script_directory/.." status --porcelain 2>/dev/null); then
    if [ -n "$git_status" ]; then
        git_dirty=yes
    else
        git_dirty=no
    fi
fi

case "$platform" in
    Darwin)
        cpu_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || printf 'unknown')
        logical_cores=$(sysctl -n hw.logicalcpu 2>/dev/null || printf 'unknown')
        physical_cores=$(sysctl -n hw.physicalcpu 2>/dev/null || printf 'unknown')
        smt_state=not_exposed
        cpu_governor=not_exposed
        cpu_quota_value=not_applicable_native_host
        cpu_observation=ps_cpu_percent_rolling_average
        ;;
    Linux)
        cpu_model=$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null | head -n 1)
        cpu_model=${cpu_model:-unknown}
        logical_cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 'unknown')
        if command -v lscpu >/dev/null 2>&1; then
            physical_cores=$(lscpu -p=core,socket 2>/dev/null |
                sed '/^#/d' | sort -u | wc -l | tr -d ' ')
            physical_cores=${physical_cores:-unknown}
            if [ "$physical_cores" = "0" ]; then
                physical_cores=unknown
            fi
        else
            physical_cores=unknown
        fi
        smt_state=$(cat /sys/devices/system/cpu/smt/active 2>/dev/null || printf 'unknown')
        cpu_governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || printf 'unknown')
        cpu_quota_value=$(cpu_quota)
        cpu_observation=process_cpu_seconds
        ;;
esac
{
    printf 'benchmark_id=%s\n' "$BENCHMARK_ID"
    printf 'schema_version=%s\n' "$SCHEMA_VERSION"
    printf 'recorded_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'label=%s\n' "$label"
    printf 'mode=%s\n' "$mode"
    printf 'server_binary=%s\n' "$server_binary"
    printf 'server_command=%s\n' "$server_binary"
    printf 'hostname=%s\n' "$(hostname 2>/dev/null || printf 'unknown')"
    printf 'h2load_version=%s\n' "$h2load_version_line"
    printf 'h2load_extra_args=%s\n' "$extra_args"
    printf 'zig_version=%s\n' "$(zig version 2>/dev/null || printf 'unknown')"
    printf 'uname=%s\n' "$(uname -a 2>/dev/null || printf 'unknown')"
    printf 'cpu_model=%s\n' "$cpu_model"
    printf 'nproc=%s\n' "$logical_cores"
    printf 'physical_cores=%s\n' "$physical_cores"
    printf 'smt_state=%s\n' "$smt_state"
    printf 'cpu_governor=%s\n' "$cpu_governor"
    printf 'cpu_quota=%s\n' "$cpu_quota_value"
    printf 'cpu_observation=%s\n' "$cpu_observation"
    printf 'kernel=%s\n' "$(uname -r 2>/dev/null || printf 'unknown')"
    printf 'memlock_kb=%s\n' "$(ulimit -l 2>/dev/null || printf 'unknown')"
    printf 'open_files=%s\n' "$fd_limit"
    printf 'open_files_required=%s\n' "$required_fds"
    printf 'listener_port=%s\n' "$target_port"
    printf 'listener_tool=%s\n' "$listener_tool"
    printf 'git_revision=%s\n' "$(git -C "$script_directory/.." rev-parse HEAD 2>/dev/null || printf 'unknown')"
    printf 'git_describe=%s\n' "$(git -C "$script_directory/.." describe --tags --always 2>/dev/null || printf 'unknown')"
    printf 'git_dirty=%s\n' "$git_dirty"
    printf 'flake_lock_sha256=%s\n' "$flake_hash"
    printf 'dependency_manifest_sha256=%s\n' "$dependency_hash"
    printf 'tls_min_version=%s\n' "$TLS_MIN_VERSION"
    printf 'certificate_sha256=%s\n' "$cert_fingerprint"
    printf 'curl_insecure=%s\n' "$curl_insecure"
    printf 'alpn=%s\n' "$alpn_value"
    printf 'workers=%s\n' "$workers_value"
    printf 'workers_source=%s\n' "$workers_source"
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
        if ! shutdown_server; then
            printf '%s\n' "benchmark server did not shut down cleanly; see $failure_file" >&2
            exit 1
        fi
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

start_sampler()
{
    (
        printf 'timestamp_s\tcpu_seconds\tcpu_percent_rolling_average\trss_kb\n'
        while kill -0 "$server_pid" 2>/dev/null; do
            timestamp=$(date -u +%s)
            if [ "$platform" = "Darwin" ]; then
                process_metrics=$(ps -p "$server_pid" -o %cpu= -o rss= 2>/dev/null) || break
                set -- $process_metrics
                [ "$#" -ge 2 ] || break
                printf '%s\t\t%s\t%s\n' "$timestamp" "$1" "$2"
            else
                stat_line=$(cat "/proc/$server_pid/stat" 2>/dev/null) || break
                trimmed=${stat_line##*) }
                ticks=$(printf '%s\n' "$trimmed" | awk '{print $12 + $13}')
                rss_kb=$(awk '/^VmRSS:/{print $2}' "/proc/$server_pid/status" 2>/dev/null || printf '0')
                clock_ticks=$(getconf CLK_TCK 2>/dev/null || printf '100')
                cpu_seconds=$(awk -v ticks="$ticks" -v hz="$clock_ticks" 'BEGIN{printf "%.3f", ticks / hz}')
                printf '%s\t%s\t\t%s\n' "$timestamp" "$cpu_seconds" "${rss_kb:-0}"
            fi
            sleep 1
        done
    ) >"$cpu_file" &
    sampler_pid=$!
}

detect_backend()
{
    if [ "$platform" = "Darwin" ]; then
        if lsof -n -p "$server_pid" 2>/dev/null | awk '$5 == "KQUEUE" { found = 1 } END { exit !found }'; then
            printf '%s\n' "kqueue"
            return 0
        fi
        return 1
    fi

    for fd_path in "/proc/$server_pid/fd"/*; do
        target=$(readlink "$fd_path" 2>/dev/null || true)
        case "$target" in
            *io_uring*) printf '%s\n' "io_uring"; return 0 ;;
            *eventpoll*) printf '%s\n' "epoll"; return 0 ;;
        esac
    done
    return 1
}

record_failure()
{
    {
        printf 'cohort=%s sample=%s\n' "${cohort:-unknown}" "${sample:-unknown}"
        printf 'url=%s\n' "$url"
        printf 'h2load_extra_args=%s\n' "$extra_args"
        if [ "$platform" = "Darwin" ]; then
            printf '%s\n' '--- server process ---'
            ps -p "$server_pid" -o pid=,ppid=,state=,%cpu=,rss=,command= 2>/dev/null || true
            printf '%s\n' '--- server descriptors ---'
            lsof -n -p "$server_pid" 2>/dev/null | head -n 80 || true
            if command -v sample >/dev/null 2>&1; then
                printf '%s\n' '--- server thread sample ---'
                sample "$server_pid" 1 2>/dev/null || true
            fi
        else
            printf '%s\n' '--- server status ---'
            sed -n '1,40p' "/proc/$server_pid/status" 2>/dev/null || true
            printf '%s\n' '--- socket states ---'
            ss -tanp 2>/dev/null | head -n 80 || true
        fi
        printf '%s\n' '--- server log tail ---'
        tail -n 80 "$server_log" 2>/dev/null || true
    } >>"$failure_file"
}

check_server_log()
{
    check_stage=$1
    if [ ! -f "$server_log" ] || [ ! -r "$server_log" ]; then
        record_failure
        fail "server log is missing or unreadable during $check_stage; see $failure_file"
    fi
    if matches=$(grep -Ein 'panic|protocol[ _-]*error|libxev.*invalid state' "$server_log"); then
        record_failure
        {
            printf 'server_log_check=%s\n' "$check_stage"
            printf '%s\n' "$matches"
        } >>"$failure_file"
        fail "server log contains panic, protocol error, or libxev invalid state during $check_stage; see $failure_file"
    else
        grep_status=$?
        if [ "$grep_status" -ne 1 ]; then
            record_failure
            fail "server log scan failed during $check_stage (grep status $grep_status); see $failure_file"
        fi
    fi
}

shutdown_server()
{
    shutdown_pid=$server_pid
    kill -TERM "$shutdown_pid" 2>/dev/null || true
    shutdown_attempt=0
    while [ "$shutdown_attempt" -lt 10 ]; do
        shutdown_state=$(ps -p "$shutdown_pid" -o stat= 2>/dev/null | tr -d '[:space:]')
        case "$shutdown_state" in
            '' | Z* | z*) break ;;
        esac
        sleep 1
        shutdown_attempt=$((shutdown_attempt + 1))
    done

    shutdown_state=$(ps -p "$shutdown_pid" -o stat= 2>/dev/null | tr -d '[:space:]')
    case "$shutdown_state" in
        '' | Z* | z*) ;;
        *)
            cohort=shutdown
            sample=timeout
            record_failure
            printf 'server_shutdown=failed\n' >>"$metadata_file"
            kill -KILL "$shutdown_pid" 2>/dev/null || true
            shutdown_attempt=0
            while [ "$shutdown_attempt" -lt 2 ]; do
                shutdown_state=$(ps -p "$shutdown_pid" -o stat= 2>/dev/null | tr -d '[:space:]')
                case "$shutdown_state" in
                    '' | Z* | z*) break ;;
                esac
                sleep 1
                shutdown_attempt=$((shutdown_attempt + 1))
            done
            shutdown_state=$(ps -p "$shutdown_pid" -o stat= 2>/dev/null | tr -d '[:space:]')
            case "$shutdown_state" in
                '' | Z* | z*) wait "$shutdown_pid" 2>/dev/null || true ;;
                *)
                    printf 'server_reap=still_running_after_sigkill\n' >>"$metadata_file"
                    printf '%s\n' 'process remained alive after SIGKILL' >>"$failure_file"
                    ;;
            esac
            server_pid=
            return 1
            ;;
    esac

    if wait "$shutdown_pid"; then
        shutdown_status=0
    else
        shutdown_status=$?
    fi
    case "$shutdown_status" in
        0) printf 'server_shutdown=clean\n' >>"$metadata_file" ;;
        *)
            cohort=shutdown
            sample=exit
            record_failure
            printf 'server_shutdown=failed\n' >>"$metadata_file"
            ;;
    esac
    server_pid=
    [ "$shutdown_status" -eq 0 ]
}

if listener_present "$target_port"; then
    fail "TCP port $target_port already has a listener; refusing to benchmark a stale server"
fi

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
    if readiness_output=$(h2load -n 1 -c 1 -m 1 -t 1 --warm-up-time=0 $extra_args --alpn-list=h2 "$url" 2>&1); then
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
if ! listener_owned; then
    record_failure
    fail "server pid $server_pid does not own the listener on TCP port $target_port"
fi
check_server_log readiness

if ! backend=$(detect_backend); then
    record_failure
    fail "could not verify the selected event-loop backend"
fi
printf 'backend=%s\n' "$backend" >>"$metadata_file"
if [ "$backend" = "kqueue" ]; then
    printf 'backend_fallback_status=not_applicable_static_backend\n' >>"$metadata_file"
else
    printf 'backend_fallback_status=not_exposed\n' >>"$metadata_file"
fi

curl_args=
if [ "$mode" != "plaintext-cluster" ] && [ "$curl_insecure" = "1" ]; then
    curl_args=--insecure
fi
curl_http2_args=--http2
if [ "$mode" = "plaintext-cluster" ]; then
    # The clear listen path has no h2c Upgrade; use prior knowledge instead.
    curl_http2_args=--http2-prior-knowledge
fi
body_file="$output_directory/${label}_body.bin"
# shellcheck disable=SC2086
if ! curl_http_version=$(curl --silent --show-error --fail $curl_args \
    "$curl_http2_args" --output "$body_file" --write-out '%{http_version}' "$url"); then
    record_failure
    fail "response body check failed"
fi
case "$curl_http_version" in
    2 | 2.0) ;;
    *)
        record_failure
        fail "response body check negotiated HTTP/$curl_http_version instead of HTTP/2"
        ;;
esac
if ! cmp -s "$body_file" "$expected_body"; then
    record_failure
    fail "response body does not match $H2LOAD_RESPONSE_BODY"
fi

cohort_medians=

for connections in $H2LOAD_CONNECTIONS; do
    for streams in $H2LOAD_STREAMS; do
        cohort="${label}_c${connections}_m${streams}"
        rates_file="$output_directory/${cohort}_rates.txt"
        p99_file="$output_directory/${cohort}_p99_us.txt"
        : >"$rates_file"
        : >"$p99_file"
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
                --alpn-list=h2 \
                "$url" >"$result_file" 2>&1; then
                cat "$result_file" >&2
                record_failure
                fail "$cohort sample $sample: h2load exited nonzero"
            fi
            cat "$result_file" >&2
            check_server_log "$cohort sample $sample"

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
                function field(value) { return value == "" ? "-" : value }
                /^TLS Protocol:/ { tls_protocol = $3 }
                END {
                    printf "%s %s %s %s %s %s %s %s %s %s %s %s %s %s\n", \
                        field(rate), field(succeeded), field(failed), field(errored), \
                        field(timeout), field(bad), field(min), field(max), \
                        field(median), field(p95), field(p99), field(mean), field(sd), \
                        field(tls_protocol)
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
            tls_protocol=${14-}

            for counter in "$succeeded" "$failed" "$errored" "$timeout" "$bad_status"; do
                case "$counter" in
                    '' | *[!0-9]*)
                        record_failure
                        fail "h2load summary is missing a request counter (parsed: $summary)"
                        ;;
                esac
            done
            if [ -z "$rate" ] || [ "$rate" = "-" ]; then
                record_failure
                fail "h2load summary could not be parsed"
            fi
            if ! awk -v rate="$rate" 'BEGIN {
                exit !(rate ~ /^[0-9]+([.][0-9]+)?$/ && rate + 0 > 0)
            }'; then
                record_failure
                fail "$cohort sample $sample reported an invalid request rate: $rate"
            fi
            if [ "$mode" != "plaintext-cluster" ] && [ "$tls_protocol" != "TLSv1.3" ]; then
                record_failure
                fail "$cohort sample $sample negotiated TLS protocol '$tls_protocol' instead of TLSv1.3"
            fi
            if [ "$succeeded" -eq 0 ]; then
                record_failure
                fail "h2load reported no successful requests"
            fi
            if [ "$failed" -ne 0 ] || [ "$errored" -ne 0 ] || [ "$timeout" -ne 0 ] || [ "$bad_status" -ne 0 ]; then
                record_failure
                fail "$cohort failed=$failed errored=$errored timeout=$timeout non_2xx=$bad_status"
            fi
            if ! req_p99_us=$(awk -v value="$req_p99" 'BEGIN {
                if (sub(/us$/, "", value)) scale = 1
                else if (sub(/ms$/, "", value)) scale = 1000
                else if (sub(/s$/, "", value)) scale = 1000000
                else exit 1
                if (value !~ /^[0-9]+([.][0-9]+)?$/) exit 1
                printf "%.3f", value * scale
            }'); then
                record_failure
                fail "h2load p99 latency could not be parsed: $req_p99"
            fi

            printf '%s\n' "$rate" >>"$rates_file"
            printf '%s\n' "$req_p99_us" >>"$p99_file"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$cohort" "$connections" "$streams" "$sample" "$rate" "$succeeded" \
                "$failed" "$errored" "$timeout" "$bad_status" "$req_min" "$req_max" \
                "$req_median" "$req_p95" "$req_p99" "$req_mean" "$req_sd" >>"$summary_file"
            sample=$((sample + 1))
        done

        median_line=$((H2LOAD_SAMPLES / 2 + 1))
        sorted_rates=$(sort -n "$rates_file")
        sorted_p99=$(sort -n "$p99_file")
        median=$(printf '%s\n' "$sorted_rates" | sed -n "${median_line}p")
        minimum_rate=$(printf '%s\n' "$sorted_rates" | sed -n '1p')
        maximum_rate=$(printf '%s\n' "$sorted_rates" | tail -n 1)
        median_p99=$(printf '%s\n' "$sorted_p99" | sed -n "${median_line}p")
        minimum_p99=$(printf '%s\n' "$sorted_p99" | sed -n '1p')
        maximum_p99=$(printf '%s\n' "$sorted_p99" | tail -n 1)
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$cohort" "$median" "$minimum_rate" "$maximum_rate" \
            "$median_p99" "$minimum_p99" "$maximum_p99" >>"$cohort_medians_file"
        cohort_medians="${cohort_medians}${cohort} rate_median=${median} requests/s rate_range=${minimum_rate}-${maximum_rate} requests/s p99_median=${median_p99}us p99_range=${minimum_p99}-${maximum_p99}us
"
    done
done

stop_sampler
rss_summary=$(awk -F '\t' 'NR > 1 && $4 ~ /^[0-9]+$/ {
    if (samples == 0) first = $4
    if ($4 > peak) peak = $4
    last = $4
    samples++
} END { if (samples > 0) printf "%d %d %d %d", samples, first, peak, last }' "$cpu_file")
if [ -z "$rss_summary" ]; then
    record_failure
    fail "resource sampler produced no RSS samples; see $cpu_file"
fi
set -- $rss_summary
if [ "$3" -le 0 ]; then
    record_failure
    fail "resource sampler recorded a non-positive peak RSS; see $cpu_file"
fi
{
    printf 'rss_samples=%s\n' "$1"
    printf 'rss_first_kb=%s\n' "$2"
    printf 'rss_peak_kb=%s\n' "$3"
    printf 'rss_last_kb=%s\n' "$4"
} >>"$metadata_file"
if ! shutdown_server; then
    fail "benchmark server did not shut down cleanly; see $failure_file"
fi
check_server_log shutdown
printf 'server_log_shutdown=clean\n' >>"$metadata_file"
printf '%s' "$cohort_medians"

if [ -f "$server_log" ]; then
    grep 'worker_accepts' "$server_log" >"$workers_file" || true
fi

printf 'run_status=complete\n' >>"$metadata_file"
printf '%s\n' "complete" >"$status_file"
printf '%s\n' "benchmark artifacts written to $output_directory"
