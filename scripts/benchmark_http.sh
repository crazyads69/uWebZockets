#!/usr/bin/env sh
set -eu

script_directory=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck disable=SC1091
. "$script_directory/../benchmarks/http_throughput_v1.env"

if [ "$#" -ne 3 ]; then
    printf '%s\n' "usage: benchmark_http.sh <label> <server-binary> <output-directory>" >&2
    exit 2
fi

label=$1
server_binary=$2
output_directory=$3

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

require_positive_integer() {
    case "$2" in
        '' | *[!0-9]*) fail "$1 must be a positive integer: $2" ;;
    esac
    [ "$2" -gt 0 ] || fail "$1 must be a positive integer: $2"
}

case "$label" in
    '' | *[!a-z0-9_-]*)
        printf '%s\n' "benchmark label must contain only lowercase letters, digits, dashes, or underscores" >&2
        exit 2
        ;;
esac

case "$TARGET_URL" in
    http://*) ;;
    *) fail "TARGET_URL must use http://: $TARGET_URL" ;;
esac

if [ ! -x "$server_binary" ]; then
    printf 'benchmark server is not executable: %s\n' "$server_binary" >&2
    exit 2
fi

if ! command -v wrk >/dev/null 2>&1; then
    fail "wrk is required for the HTTP throughput contract"
fi

if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 is required for the HTTP readiness probe"
fi

mkdir -p "$output_directory"
server_log="$output_directory/$label-server.log"
rates_file="$output_directory/$label-rates.txt"
failure_file="$output_directory/$label-failure.txt"
status_file="$output_directory/$label-run.status"
: >"$rates_file"
: >"$failure_file"
printf '%s\n' "in_progress" >"$status_file"

server_pid=

check_server_log() {
    check_stage=$1
    if [ ! -f "$server_log" ] || [ ! -r "$server_log" ]; then
        fail "benchmark server log is missing or unreadable during $check_stage"
    fi
    if matches=$(grep -Ein 'panic|protocol[ _-]*error|libxev.*invalid state' "$server_log"); then
        record_failure
        printf 'server log contains a panic, protocol error, or libxev invalid state during %s:\n%s\n' \
            "$check_stage" "$matches" >&2
        exit 1
    else
        grep_status=$?
        if [ "$grep_status" -ne 1 ]; then
            record_failure
            fail "server log scan failed during $check_stage (grep status $grep_status)"
        fi
    fi
}

record_failure()
{
    {
        printf 'url=%s\n' "$TARGET_URL"
        printf '%s\n' '--- server process ---'
        if [ -n "${server_pid:-}" ]; then
            ps -p "$server_pid" -o pid=,ppid=,state=,%cpu=,rss=,command= 2>/dev/null || true
        fi
        printf '%s\n' '--- server log tail ---'
        tail -n 80 "$server_log" 2>/dev/null || true
    } >>"$failure_file"
}

shutdown_server() {
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
            printf '%s\n' "benchmark server did not stop after SIGTERM; sending SIGKILL" >&2
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
                *) printf '%s\n' 'benchmark server remains alive after SIGKILL' >&2 ;;
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
    server_pid=
    case "$shutdown_status" in
        0 | 143) return 0 ;;
        *) return 1 ;;
    esac
}

cleanup() {
    if [ -n "$server_pid" ]; then
        if ! shutdown_server; then
            printf '%s\n' "benchmark server did not shut down cleanly" >&2
            exit 1
        fi
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_positive_integer WRK_THREADS "$WRK_THREADS"
require_positive_integer WRK_CONNECTIONS "$WRK_CONNECTIONS"
require_positive_integer WRK_DURATION_SECONDS "$WRK_DURATION_SECONDS"
require_positive_integer WRK_SAMPLES "$WRK_SAMPLES"
if [ $((WRK_SAMPLES % 2)) -eq 0 ]; then
    fail "WRK_SAMPLES must be odd so the median is a measured sample"
fi

"$server_binary" >"$server_log" 2>&1 &
server_pid=$!

ready=false
attempt=0
while [ "$attempt" -lt 100 ]; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
        cat "$server_log" >&2
        exit 1
    fi
    if python3 -c '
import http.client
import sys
import urllib.parse
target = urllib.parse.urlsplit(sys.argv[1])
connection = http.client.HTTPConnection(target.hostname, target.port or 80, timeout=0.5)
connection.request("GET", target.path or "/", headers={"Connection": "close"})
response = connection.getresponse()
response.read()
connection.close()
if response.status != 200:
    raise SystemExit(1)
' "$TARGET_URL" 2>/dev/null; then
        ready=true
        break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done

if [ "$ready" != true ]; then
    record_failure
    fail "benchmark server did not become ready"
fi
check_server_log readiness

run=1
while [ "$run" -le "$WRK_SAMPLES" ]; do
    result_file="$output_directory/$label-$run.txt"
    if ! wrk \
        -t"$WRK_THREADS" \
        -c"$WRK_CONNECTIONS" \
        -d"${WRK_DURATION_SECONDS}s" \
        --latency \
        "$TARGET_URL" >"$result_file"
    then
        cat "$result_file" >&2
        record_failure
        fail "wrk exited nonzero for sample $run"
    fi
    cat "$result_file" >&2
    rate=$(awk '/Requests\/sec:/ { print $2 }' "$result_file")
    if [ -z "$rate" ]; then
        printf '%s\n' "wrk did not report requests per second" >&2
        exit 1
    fi
    if ! awk -v rate="$rate" 'BEGIN {
        exit !(rate ~ /^[0-9]+([.][0-9]+)?$/ && rate + 0 > 0)
    }'; then
        printf 'wrk reported an invalid requests per second value: %s\n' "$rate" >&2
        exit 1
    fi
    if ! awk '
        BEGIN { failed = 0 }
        /Socket errors:/ {
            # wrk omits this line when every counter is zero.
            if (NF < 8) failed = 1
            for (field = 4; field <= NF; field += 2) {
                if ($field + 0 != 0) failed = 1
            }
        }
        END { exit failed }
    ' "$result_file"; then
        printf '%s\n' "wrk reported socket errors or a malformed socket-error line" >&2
        exit 1
    fi
    if ! awk '
        BEGIN { failed = 0 }
        /^[[:space:]]*Non-2xx or 3xx responses:/ {
            # wrk omits this line when the counter is zero.
            responses = $NF
            if (responses !~ /^[0-9]+$/ || responses + 0 != 0) failed = 1
        }
        END { exit failed }
    ' "$result_file"; then
        printf '%s\n' "wrk reported Non-2xx/3xx responses or a malformed counter" >&2
        exit 1
    fi
    check_server_log "sample $run"
    printf '%s\n' "$rate" >>"$rates_file"
    run=$((run + 1))
done

if ! shutdown_server; then
    fail "benchmark server did not shut down cleanly"
fi
check_server_log shutdown
printf '%s\n' "complete" >"$status_file"

median_line=$((WRK_SAMPLES / 2 + 1))
sort -n "$rates_file" | sed -n "${median_line}p"
