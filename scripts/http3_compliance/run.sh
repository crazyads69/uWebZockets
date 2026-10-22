#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_dir="$(cd -- "${script_dir}/../.." && pwd)"
expectations="${script_dir}/expectations.json"
artifact_dir="${HTTP3_ARTIFACT_DIR:-${RUNNER_TEMP:-/tmp}/uwebzockets-http3-compliance}"
server_binary="${HTTP3_SERVER_BIN:-${repository_dir}/zig-out/bin/http3_server}"
server_dynamic_linker="${HTTP3_SERVER_DYNAMIC_LINKER:-${UWEBZOCKETS_RUNTIME_DYNAMIC_LINKER:-}}"
server_library_path="${HTTP3_SERVER_LIBRARY_PATH:-${UWEBZOCKETS_RUNTIME_LIBRARY_PATH:-}}"
server_pid=""
runtime_dir=""

mkdir -p "${artifact_dir}/qlog"
artifact_dir="$(cd -- "${artifact_dir}" && pwd)"

cleanup() {
  exit_code=$?
  trap - EXIT
  server_exit=""
  if [[ -n "${server_pid}" ]] && kill -0 "${server_pid}" 2>/dev/null; then
    kill -TERM "${server_pid}" 2>/dev/null || true
    for _ in $(seq 1 50); do
      if ! kill -0 "${server_pid}" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "${server_pid}" 2>/dev/null; then
      printf '%s\n' "HTTP/3 server did not exit after SIGTERM; killing" >&2
      kill -KILL "${server_pid}" 2>/dev/null || true
    fi
  fi
  if [[ -n "${server_pid}" ]]; then
    server_exit=0
    wait "${server_pid}" 2>/dev/null || server_exit=$?
  fi
  # A clean request path is not enough: deinit must drain every engine pool.
  if [[ -n "${server_exit}" && "${server_exit}" -ne 0 && "${exit_code}" -eq 0 ]]; then
    printf 'HTTP/3 server exited uncleanly with status %s\n' "${server_exit}" >&2
    exit_code="${server_exit}"
  fi
  if [[ -n "${runtime_dir}" && -d "${runtime_dir}" ]]; then
    rm -rf -- "${runtime_dir}"
  fi
  exit "${exit_code}"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

cd "${repository_dir}"
test -x "${server_binary}"
server_binary="$(realpath "${server_binary}")"

runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/uwebzockets-http3.XXXXXX")"
mkdir -p "${runtime_dir}/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=localhost' \
  -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
  -keyout "${runtime_dir}/certs/key.pem" \
  -out "${runtime_dir}/certs/cert.pem" \
  >"${artifact_dir}/certificate_generation.log" 2>&1
openssl x509 -in "${runtime_dir}/certs/cert.pem" \
  -noout -sha256 -fingerprint -dates \
  >"${artifact_dir}/test_certificate.log"

server_command=("${server_binary}")
# A glob in the linker override means the Nix shell exports a mutable loader
# path; the artifact runs directly, matching the build's fallback.
if [[ -n "${server_dynamic_linker}" && "${server_dynamic_linker}" != *"*"* ]]; then
  test -x "${server_dynamic_linker}"
  test -n "${server_library_path}"
  server_command=(
    "${server_dynamic_linker}"
    --library-path "${server_library_path}"
    "${server_binary}"
  )
fi

curl --version >"${artifact_dir}/client_versions.log"
python3 -c 'import aioquic; print("aioquic " + aioquic.__version__)' \
  >>"${artifact_dir}/client_versions.log"

curl_version="$(jq -r '.clients.curl.version' "${expectations}")"
curl_quic="$(jq -r '.clients.curl.quic' "${expectations}")"
curl_http3="$(jq -r '.clients.curl.http3' "${expectations}")"
grep -q "^curl ${curl_version} " "${artifact_dir}/client_versions.log"
grep -q "${curl_quic}" "${artifact_dir}/client_versions.log"
grep -q "${curl_http3}" "${artifact_dir}/client_versions.log"
grep -q 'Features:.*HTTP3' "${artifact_dir}/client_versions.log"

(
  cd -- "${runtime_dir}"
  exec "${server_command[@]}"
) >"${artifact_dir}/server.log" 2>&1 &
server_pid=$!
printf '%s\n' "${server_pid}" >"${artifact_dir}/server.pid"

endpoint="$(jq -r '.endpoint' "${expectations}")"
ready=false
for _ in $(seq 1 80); do
  if ! kill -0 "${server_pid}" 2>/dev/null; then
    printf '%s\n' "HTTP/3 server exited before becoming ready" >&2
    exit 1
  fi
  if curl --http3-only --insecure --silent --show-error \
    --connect-timeout 1 --max-time 2 --output "${artifact_dir}/readiness.body" \
    "${endpoint}" 2>>"${artifact_dir}/readiness.log"; then
    ready=true
    break
  fi
  sleep 0.25
done
test "${ready}" = true

curl --http3-only --insecure --fail-with-body --silent --show-error \
  --connect-timeout 5 --max-time 10 \
  --trace-time --trace-ascii "${artifact_dir}/curl.trace" \
  --dump-header "${artifact_dir}/curl.headers" \
  --output "${artifact_dir}/curl.body" \
  --write-out '%{http_version}\n%{response_code}\n' \
  "${endpoint}" >"${artifact_dir}/curl.metadata"

expected_http_version="$(jq -r '.response.http_version' "${expectations}")"
expected_status="$(jq -r '.response.status' "${expectations}")"
expected_digest="$(jq -r '.response.body_sha256' "${expectations}")"
test "$(sed -n '1p' "${artifact_dir}/curl.metadata")" = "${expected_http_version}"
test "$(sed -n '2p' "${artifact_dir}/curl.metadata")" = "${expected_status}"
test "$(sha256sum "${artifact_dir}/curl.body" | cut -d ' ' -f 1)" = "${expected_digest}"

python3 "${script_dir}/aioquic_probe.py" \
  --expectations "${expectations}" \
  --output "${artifact_dir}/aioquic_results.json" \
  --qlog-dir "${artifact_dir}/qlog" \
  >"${artifact_dir}/aioquic.log" 2>&1

kill -0 "${server_pid}"
jq -e '.trailers.outcome == "response" and .trailers.status == 200' \
  "${artifact_dir}/aioquic_results.json" >/dev/null
malformed_count="$(jq '.malformed_cases | length' "${expectations}")"
stream_error="$(jq '.malformed_stream_error' "${expectations}")"
# The example server uses App(128); the soak sends more than its 2*128 header
# pool slots and a fresh connection must still be served. The oversized QPACK
# case must stay stream-scoped and leave its sibling request healthy.
jq -e --argjson count "${malformed_count}" --argjson stream_error "${stream_error}" \
  '(.malformed | length) == $count and
   (.malformed_siblings | length) == $count and
   ([.malformed_siblings[] |
      .outcome == "response" and .status == 200] | all) and
   (.oversized_qpack.outcome == "stream_reset") and
   (.oversized_qpack.error_code == $stream_error) and
   (.oversized_qpack_sibling.outcome == "response") and
   (.oversized_qpack_sibling.status == 200) and
   (.post_malformed_health.outcome == "response") and
   (.post_malformed_health.status == 200) and
   (.soak.requests > 0) and
   (.soak.rejected == .soak.requests) and
   (.soak_fresh_connection.outcome == "response") and
   (.soak_fresh_connection.status == 200)' \
  "${artifact_dir}/aioquic_results.json" >/dev/null
printf '%s\n' "HTTP/3 cross-implementation compliance passed"
