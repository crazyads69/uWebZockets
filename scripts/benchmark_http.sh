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

mkdir -p "$output_directory"
server_log="$output_directory/$label-server.log"
rates_file="$output_directory/$label-rates.txt"
: >"$rates_file"

server_pid=
fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

check_server_log() {
    check_stage=$1
    if [ ! -f "$server_log" ] || [ ! -r "$server_log" ]; then
        fail "benchmark server log is missing or unreadable during $check_stage"
    fi
    if matches=$(grep -Ein 'panic|protocol[ _-]*error|libxev.*invalid state' "$server_log"); then
        printf 'server log contains a panic, protocol error, or libxev invalid state during %s:\n%s\n' \
            "$check_stage" "$matches" >&2
        exit 1
    else
        grep_status=$?
        if [ "$grep_status" -ne 1 ]; then
            fail "server log scan failed during $check_stage (grep status $grep_status)"
        fi
    fi
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
    printf '%s\n' "benchmark server did not become ready" >&2
    exit 1
fi

run=1
while [ "$run" -le "$WRK_SAMPLES" ]; do
    result_file="$output_directory/$label-$run.txt"
    wrk \
        -t"$WRK_THREADS" \
        -c"$WRK_CONNECTIONS" \
        -d"${WRK_DURATION_SECONDS}s" \
        --latency \
        "$TARGET_URL" >"$result_file"
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
        /Socket errors:/ {
            for (field = 4; field <= NF; field += 2) {
                if ($field + 0 != 0) failed = 1
            }
        }
        END { exit failed }
    ' "$result_file"; then
        printf '%s\n' "wrk reported socket errors" >&2
        exit 1
    fi
    if ! awk '
        /^[[:space:]]*Non-2xx or 3xx responses:/ {
            responses = $NF
            if (responses !~ /^[0-9]+$/ || responses + 0 != 0) failed = 1
        }
        END { exit failed }
    ' "$result_file"; then
        printf '%s\n' "wrk reported Non-2xx or 3xx responses" >&2
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

median_line=$((WRK_SAMPLES / 2 + 1))
sort -n "$rates_file" | sed -n "${median_line}p"
