#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/turboflare-render-test.XXXXXXXX")"
trap 'rm -rf -- "${TEST_DIR}"' EXIT
mkdir -p "${TEST_DIR}/scripts"
cp "${PROJECT_DIR}/scripts/"{render.sh,turboflare-domains.sh} "${TEST_DIR}/scripts/"
cp -R "${PROJECT_DIR}/templates" "${TEST_DIR}/templates"
sed \
  -e 's/^DOMAIN=.*/DOMAIN=meowbot.lol/' \
  -e 's/^BEGET_ORIGIN_CERT_MODE=.*/BEGET_ORIGIN_CERT_MODE=selfsigned/' \
  -e 's/^BEELINE_ORIGIN_CERT_MODE=.*/BEELINE_ORIGIN_CERT_MODE=selfsigned/' \
  -e 's/^REALITY_PRIVATE_KEY=.*/REALITY_PRIVATE_KEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/' \
  -e 's/^REALITY_PASSWORD=.*/REALITY_PASSWORD=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB/' \
  -e 's/^REALITY_SHORT_IDS=.*/REALITY_SHORT_IDS=0123456789abcdef/' \
  "${PROJECT_DIR}/.env.example" > "${TEST_DIR}/base.env"
set_domains() {
  cp "${TEST_DIR}/base.env" "${TEST_DIR}/fixture.env"
  printf '\nDOMAIN="%s"\n' "$1" >> "${TEST_DIR}/fixture.env"
}
render() {
  bash "${TEST_DIR}/scripts/render.sh" --env "${TEST_DIR}/fixture.env" --only "${1:-turboflare}" > "${TEST_DIR}/render.log" 2>&1 \
    || { cat "${TEST_DIR}/render.log" >&2; return 1; }
}
set_domains meowbot.lol
render
cp "${TEST_DIR}/build/shared/xray-inbounds.json" "${TEST_DIR}/single.json"
cp "${TEST_DIR}/build/turboflare/meowbot.lol/nginx-site.conf" "${TEST_DIR}/single.conf"
cmp "${TEST_DIR}/build/turboflare/meowbot.lol/nginx-stream-map-entry.map" \
  "${TEST_DIR}/build/shared/turboflare-stream-map-entry.map"

set_domains 'meowbot.lol, meowow.lol, third.example.com'
render
cmp "${TEST_DIR}/single.json" "${TEST_DIR}/build/shared/xray-inbounds.json"
cmp "${TEST_DIR}/single.conf" "${TEST_DIR}/build/turboflare/meowbot.lol/nginx-site.conf"
jq -e 'length == 1 and .[0].streamSettings.xhttpSettings.host == "meowbot.lol"' \
  "${TEST_DIR}/build/shared/xray-inbounds.json" >/dev/null
for domain in meowbot.lol meowow.lol third.example.com; do
  dir="${TEST_DIR}/build/turboflare/${domain}"
  grep -Fq "${domain} 127.0.0.1:8443; # TurboFlare CDN" "${TEST_DIR}/build/shared/turboflare-stream-map-entry.map"
  grep -Fq "server_name ${domain};" "${dir}/nginx-site.conf"
  grep -Fq "/etc/nginx/ssl/${domain}/origin.crt" "${dir}/nginx-site.conf"
  grep -Fq 'proxy_set_header Host meowbot.lol;' "${dir}/nginx-site.conf"
  grep -Fq "| SNI | \`${domain}\` |" "${dir}/remnawave-host-values.md"
  grep -Fq "| Host | \`${domain}\` |" "${dir}/remnawave-host-values.md"
done
[[ ! -f "${TEST_DIR}/build/turboflare/meowow.lol/xray-inbound.json" ]]
cp "${TEST_DIR}/build/shared/turboflare-stream-map-entry.map" "${TEST_DIR}/map.before"
render
cmp "${TEST_DIR}/map.before" "${TEST_DIR}/build/shared/turboflare-stream-map-entry.map"
render turboflare,beeline,beget,reality
jq -e 'length == 4 and ([.[].tag] | unique | length == 4)' "${TEST_DIR}/build/shared/xray-inbounds.json" >/dev/null

# Removal must replace, not append to, the aggregate map.
set_domains meowbot.lol
render
cmp "${TEST_DIR}/build/turboflare/meowbot.lol/nginx-stream-map-entry.map" \
  "${TEST_DIR}/build/shared/turboflare-stream-map-entry.map"

for invalid in '' ',meowbot.lol' 'meowbot.lol,' 'meowbot.lol,,meowow.lol' \
  'meowbot.lol,MEOWBOT.LOL' 'meowbot.lol,meow ow.lol' 'meowbot.lol,../bad.lol' \
  'meowbot.lol,https://meowow.lol'; do
  set_domains "${invalid}"
  if render 2>/dev/null; then
    printf 'FAIL: accepted invalid DOMAIN=%s\n' "${invalid}" >&2
    exit 1
  fi
done
# Conflicts with another component must be checked for every domain.
set_domains 'meowbot.lol,node-beget.example.net'
if render turboflare,beget 2>/dev/null; then
  printf 'FAIL: accepted conflicting origin SNI\n' >&2
  exit 1
fi
grep -Fq 'Origin SNI' "${TEST_DIR}/render.log"
# A bad TurboFlare domain must not block unrelated components.
set_domains 'invalid,'
render beget
printf 'PASS: single/multiple TurboFlare domains, migration, shared inbound, SNI conflicts and validation\n'
