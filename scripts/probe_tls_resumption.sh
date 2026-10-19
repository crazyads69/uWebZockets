#!/usr/bin/env sh
# Counts TLS 1.3 session resumptions against one listener.
#
# Usage: probe_tls_resumption.sh <host:port> [iterations]
#
# TLS 1.3 delivers NewSessionTicket after the handshake. `s_client -reconnect`
# on OpenSSL 3.6 closes before the ticket is usable and prints no New/Reused
# classification. This probe therefore exports one session per iteration, sends
# one HTTP/1.1 request so the ticket arrives, and then imports the session for
# five reconnects. A per-worker ticket key means a reconnect that lands on
# another worker cannot resume.
set -eu

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    printf '%s\n' "usage: probe_tls_resumption.sh <host:port> [iterations]" >&2
    exit 2
fi

target=$1
iterations=${2:-20}
new_handshakes=0
reused_handshakes=0
failed_handshakes=0
unclassified_handshakes=0
session_file=$(mktemp "${TMPDIR:-/tmp}/uwz-session.XXXXXX")
next_session_file=$(mktemp "${TMPDIR:-/tmp}/uwz-session-next.XXXXXX")
trap 'rm -f "$session_file" "$next_session_file"' 0 1 2 15
request='GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n'

classify()
{
    if printf '%s\n' "$1" | grep -q '^New,'; then
        new_handshakes=$((new_handshakes + 1))
    elif printf '%s\n' "$1" | grep -q '^Reused,'; then
        reused_handshakes=$((reused_handshakes + 1))
    else
        unclassified_handshakes=$((unclassified_handshakes + 1))
    fi
}

iteration=0
while [ "$iteration" -lt "$iterations" ]; do
    rm -f "$session_file" "$next_session_file"
    if output=$(printf '%b' "$request" | timeout 15 openssl s_client -connect "$target" \
        -tls1_3 -alpn http/1.1 -ign_eof -sess_out "$session_file" 2>&1); then
        classify "$output"
    else
        failed_handshakes=$((failed_handshakes + 1))
    fi

    if [ ! -s "$session_file" ]; then
        failed_handshakes=$((failed_handshakes + 5))
        iteration=$((iteration + 1))
        continue
    fi

    reconnect=0
    while [ "$reconnect" -lt 5 ]; do
        rm -f "$next_session_file"
        if output=$(printf '%b' "$request" | timeout 15 openssl s_client -connect "$target" \
            -tls1_3 -alpn http/1.1 -ign_eof -sess_in "$session_file" \
            -sess_out "$next_session_file" 2>&1); then
            classify "$output"
            if [ -s "$next_session_file" ]; then
                mv "$next_session_file" "$session_file"
            fi
        else
            failed_handshakes=$((failed_handshakes + 1))
        fi
        reconnect=$((reconnect + 1))
    done
    iteration=$((iteration + 1))
done

printf 'target=%s\n' "$target"
printf 'iterations=%s\n' "$iterations"
printf 'new=%s\n' "$new_handshakes"
printf 'reused=%s\n' "$reused_handshakes"
printf 'failed_handshakes=%s\n' "$failed_handshakes"
printf 'unclassified_handshakes=%s\n' "$unclassified_handshakes"
