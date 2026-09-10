#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${1:-${SCRIPT_DIR}/.env}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash install.sh"
[[ -f "${ENV_FILE}" ]] || die "Environment file not found: ${ENV_FILE}. Run: cp .env.example .env"

missing_packages=()
if command -v nginx >/dev/null 2>&1; then
  if ! nginx -V 2>&1 | grep -q -- '--with-stream'; then
    missing_packages+=(libnginx-mod-stream)
  fi
else
  missing_packages+=(nginx libnginx-mod-stream)
fi
command -v openssl >/dev/null 2>&1 || missing_packages+=(openssl)
command -v envsubst >/dev/null 2>&1 || missing_packages+=(gettext-base)
command -v jq >/dev/null 2>&1 || missing_packages+=(jq)
command -v dig >/dev/null 2>&1 || missing_packages+=(dnsutils)

if (( ${#missing_packages[@]} > 0 )); then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y "${missing_packages[@]}"
fi

chmod 600 "${ENV_FILE}"
bash "${SCRIPT_DIR}/scripts/ensure-reality-credentials.sh" "${ENV_FILE}"
"${SCRIPT_DIR}/scripts/render.sh" "${ENV_FILE}"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

BUILD_DIR="${SCRIPT_DIR}/build/${DOMAIN}"
SSL_DIR="/etc/nginx/ssl/${DOMAIN}"
SITE_AVAILABLE="/etc/nginx/sites-available/${DOMAIN}.conf"
SITE_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}.conf"
STREAM_MAP_PATH="${STREAM_MAP_DIR}/${STREAM_MAP_FILE}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

install -d -m 700 "${SSL_DIR}"

if [[ ! -s "${SSL_DIR}/origin.key" || ! -s "${SSL_DIR}/origin.crt" ]]; then
  openssl req -x509 -nodes -newkey rsa:3072 -sha256 \
    -days "${ORIGIN_CERT_DAYS}" \
    -keyout "${SSL_DIR}/origin.key" \
    -out "${SSL_DIR}/origin.crt" \
    -subj "/CN=${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN},DNS:*.${DOMAIN}" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth"
fi

chmod 600 "${SSL_DIR}/origin.key"
chmod 644 "${SSL_DIR}/origin.crt"

install -d -m 755 "${COVER_ROOT}"
if [[ ! -e "${COVER_ROOT}/index.html" ]]; then
  cat > "${COVER_ROOT}/index.html" <<HTML
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${COVER_TITLE}</title>
  <style>
    body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0f172a;color:#e2e8f0;font:16px system-ui,sans-serif}
    main{padding:2rem;text-align:center}h1{font-size:1.5rem}p{color:#94a3b8}
  </style>
</head>
<body><main><h1>${COVER_TITLE}</h1><p>All systems operational.</p></main></body>
</html>
HTML
  chmod 644 "${COVER_ROOT}/index.html"
fi

if [[ -e "${SITE_AVAILABLE}" ]]; then
  cp -a "${SITE_AVAILABLE}" "${SITE_AVAILABLE}.bak-${TIMESTAMP}"
fi
install -m 644 "${BUILD_DIR}/nginx-site.conf" "${SITE_AVAILABLE}"

if [[ -e "${SITE_ENABLED}" && ! -L "${SITE_ENABLED}" ]]; then
  die "${SITE_ENABLED} exists and is not a symlink; refusing to overwrite it"
fi
if [[ ! -e "${SITE_ENABLED}" ]]; then
  ln -s "${SITE_AVAILABLE}" "${SITE_ENABLED}"
fi

install -d -m 755 "${STREAM_MAP_DIR}"
if [[ -e "${STREAM_MAP_PATH}" ]]; then
  cp -a "${STREAM_MAP_PATH}" "${STREAM_MAP_PATH}.bak-${TIMESTAMP}"
fi
install -m 644 "${BUILD_DIR}/nginx-stream-map-entry.map" "${STREAM_MAP_PATH}"

if ! nginx -T 2>&1 | grep -Fq "include ${STREAM_MAP_DIR}/*.map;"; then
  printf '\nACTION REQUIRED:\n'
  printf 'Add this line INSIDE the existing map $ssl_preread_server_name block:\n\n'
  printf '    include %s/*.map;\n\n' "${STREAM_MAP_DIR}"
  printf 'Do not create a second stream{} block and do not create a second public listen 443.\n'
  printf 'After editing nginx.conf, run this installer again.\n'
fi

nginx -t
systemctl reload nginx

printf '\nNginx and the origin certificate are installed.\n'
printf 'Domain: %s\n' "${DOMAIN}"
printf 'Origin for TurboFlare: %s:%s (HTTPS enabled)\n' "${ORIGIN_IP}" "${ORIGIN_PORT}"
printf 'TurboFlare inbound JSON: %s/xray-inbound.json\n' "${BUILD_DIR}"
printf 'Reality inbound JSON: %s/xray-reality-inbound.json\n' "${BUILD_DIR}"
printf 'Both inbound objects: %s/xray-inbounds.json\n' "${BUILD_DIR}"
printf 'Remnawave Host values: %s/remnawave-host-values.md\n' "${BUILD_DIR}"
printf 'Remnawave Reality Host values: %s/remnawave-reality-host-values.md\n' "${BUILD_DIR}"
printf 'Reality client credentials: %s/reality-client-credentials.json\n' "${BUILD_DIR}"
printf 'Remnawave XHTTP Extra: %s/remnawave-xhttp-extra.json\n' "${BUILD_DIR}"

printf '\nDirect origin check:\n'
printf 'curl -4vk --resolve %s:443:%s https://%s/\n' "${DOMAIN}" "${ORIGIN_IP}" "${DOMAIN}"

printf '\nExpected listeners after assigning both inbounds to the node:\n'
printf 'ss -lntp | grep -E ":443|:%s|:%s|:%s"\n' \
  "${NGINX_INTERNAL_PORT}" "${XRAY_XHTTP_PORT}" "${REALITY_PORT}"
