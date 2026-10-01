#!/usr/bin/env bash
set -Eeuo pipefail

# Run without root/network access. Never overwrite the user's .env or build/.
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/beget-render-test.XXXXXXXX")"
trap 'rm -rf -- "${TEST_DIR}"' EXIT
mkdir -p "${TEST_DIR}/scripts"
cp "${PROJECT_DIR}/scripts/render.sh" "${TEST_DIR}/scripts/"
cp -R "${PROJECT_DIR}/templates" "${TEST_DIR}/templates"

# Fixture credentials are only for rendering; no services or certificates start.
sed \
  -e 's/^BEGET_ORIGIN_CERT_MODE=.*/BEGET_ORIGIN_CERT_MODE=selfsigned/' \
  -e 's/^BEELINE_ORIGIN_CERT_MODE=.*/BEELINE_ORIGIN_CERT_MODE=selfsigned/' \
  -e 's/^REALITY_PRIVATE_KEY=.*/REALITY_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/' \
  -e 's/^REALITY_PASSWORD=.*/REALITY_PASSWORD=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/' \
  -e 's/^REALITY_SHORT_IDS=.*/REALITY_SHORT_IDS=0123456789abcdef/' \
  "${PROJECT_DIR}/.env.example" > "${TEST_DIR}/fixture.env"

render() {
  bash "${TEST_DIR}/scripts/render.sh" --env "${TEST_DIR}/fixture.env" --only "$1"
}

check_beget() {
  local expected_path="$1"
  local output_dir="${TEST_DIR}/build/beget/node-beget.example.net"
  jq -e --arg path "${expected_path}" '
    .port == 10085 and .listen == "127.0.0.1" and
    .streamSettings.xhttpSettings.path == $path and
    .streamSettings.xhttpSettings.mode == "packet-up" and
    .streamSettings.xhttpSettings.host == "node-beget.example.net"
  ' "${output_dir}/xray-inbound.json" >/dev/null
  jq -es '
    .[0].streamSettings.xhttpSettings.extra as $server |
    .[1] as $client |
    all([$server, $client][];
      .sessionIdPlacement == "query" and .sessionIdKey == "x_session" and
      .seqPlacement == "query" and .seqKey == "x_seq" and
      .xPaddingPlacement == "header" and .xPaddingHeader == "X-Cache" and
      .xPaddingKey == "_dc" and .xPaddingMethod == "tokenish" and
      .xPaddingObfsMode == true and .uplinkHTTPMethod == "GET") and
    all($server | keys[]; . as $key | $server[$key] == $client[$key]) and
    $client.scMaxEachPostBytes == "500000-1000000" and
    $client.scMinPostsIntervalMs == "50-150" and
    $client.xmux.maxConnections == "1"
  ' "${output_dir}/xray-inbound.json" "${output_dir}/remnawave-xhttp-extra.json" >/dev/null
  grep -Fq -- "${expected_path}" "${output_dir}/remnawave-host-values.md"
  grep -Fq -- "https://node-beget.example.net${expected_path}" "${output_dir}/beget-cdn-settings.md"
}

render beget
check_beget /hls/stream.m3u8
jq -e 'length == 1 and .[0].tag == "xHTTP-Beget"' \
  "${TEST_DIR}/build/shared/xray-inbounds.json" >/dev/null

# Beget changes must not alter the other generated inbounds.
render turboflare,beeline,reality
cp "${TEST_DIR}/build/shared/xray-inbounds.json" "${TEST_DIR}/others.json"
render turboflare,beeline,beget,reality
check_beget /hls/stream.m3u8
jq -es '.[0] == (.[1] | map(select(.tag != "xHTTP-Beget"))) and (.[1] | length == 4)' \
  "${TEST_DIR}/others.json" "${TEST_DIR}/build/shared/xray-inbounds.json" >/dev/null

cp "${TEST_DIR}/fixture.env" "${TEST_DIR}/base.env"
sed -e 's|^BEGET_XHTTP_PATH=.*|BEGET_XHTTP_PATH=/media/live.m3u8|' \
  -e 's/^BEGET_CDN_CUSTOM_DOMAIN=.*/BEGET_CDN_CUSTOM_DOMAIN=edge.example.net/' \
  "${TEST_DIR}/base.env" > "${TEST_DIR}/fixture.env"
render beget
check_beget /media/live.m3u8
grep -Fq 'https://edge.example.net/media/live.m3u8' \
  "${TEST_DIR}/build/beget/node-beget.example.net/beget-cdn-settings.md"

for invalid_path in / /hls/stream.m3u8/; do
  sed "s|^BEGET_XHTTP_PATH=.*|BEGET_XHTTP_PATH=${invalid_path}|" \
    "${TEST_DIR}/base.env" > "${TEST_DIR}/fixture.env"
  if render beget > "${TEST_DIR}/invalid.log" 2>&1; then
    printf 'FAIL: accepted invalid Beget path %s\n' "${invalid_path}" >&2
    exit 1
  fi
  grep -Fq 'BEGET_XHTTP_PATH must not end with /' "${TEST_DIR}/invalid.log"
done
# An invalid Beget setting must not block deployment of another component.
render turboflare
printf 'PASS: Beget render, client/server parity, custom path/domain, migration validation and component isolation\n'
