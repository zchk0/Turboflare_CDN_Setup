#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${1:-${PROJECT_DIR}/.env}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

command -v envsubst >/dev/null 2>&1 || die "envsubst is required (Debian/Ubuntu: apt install gettext-base)"
command -v jq >/dev/null 2>&1 || die "jq is required (Debian/Ubuntu: apt install jq)"

[[ -f "${ENV_FILE}" ]] || die "Environment file not found: ${ENV_FILE}. Run: cp .env.example .env"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

required_variables=(
  DOMAIN ORIGIN_IP ORIGIN_PORT NGINX_INTERNAL_PORT XRAY_LISTEN_IP
  XRAY_XHTTP_PORT XRAY_INBOUND_TAG XHTTP_PATH ORIGIN_CERT_DAYS
  COVER_ROOT COVER_TITLE STREAM_MAP_DIR STREAM_MAP_FILE
  CONFIG_PROFILE_NAME SQUAD_NAME REALITY_LISTEN_IP REALITY_PORT
  REALITY_INBOUND_TAG REALITY_XHTTP_PATH REALITY_TARGET
  REALITY_SERVER_NAMES REALITY_PRIVATE_KEY REALITY_PASSWORD
  REALITY_SHORT_IDS
)

for variable_name in "${required_variables[@]}"; do
  [[ -n "${!variable_name:-}" ]] || die "${variable_name} is empty"
done

[[ "${DOMAIN}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] \
  || die "DOMAIN is invalid: ${DOMAIN}"

[[ "${ORIGIN_IP}" =~ ^[0-9A-Fa-f:.]+$ ]] || die "ORIGIN_IP contains unsupported characters"
[[ "${XRAY_LISTEN_IP}" =~ ^[0-9A-Fa-f:.]+$ ]] || die "XRAY_LISTEN_IP contains unsupported characters"
[[ "${REALITY_LISTEN_IP}" =~ ^[0-9A-Fa-f:.]+$ ]] || die "REALITY_LISTEN_IP contains unsupported characters"
[[ "${XRAY_INBOUND_TAG}" =~ ^[A-Za-z0-9_-]+$ ]] || die "XRAY_INBOUND_TAG may contain only A-Z, a-z, 0-9, _ and -"
[[ "${REALITY_INBOUND_TAG}" =~ ^[A-Za-z0-9_-]+$ ]] || die "REALITY_INBOUND_TAG may contain only A-Z, a-z, 0-9, _ and -"
[[ "${XRAY_INBOUND_TAG}" != "${REALITY_INBOUND_TAG}" ]] || die "XRAY_INBOUND_TAG and REALITY_INBOUND_TAG must differ"
[[ "${XHTTP_PATH}" =~ ^/[A-Za-z0-9._~/-]+$ ]] || die "XHTTP_PATH must start with / and contain only URL-safe path characters"
[[ "${REALITY_XHTTP_PATH}" =~ ^/[A-Za-z0-9._~/-]+$ ]] || die "REALITY_XHTTP_PATH must start with / and contain only URL-safe path characters"
[[ "${COVER_ROOT}" =~ ^/var/www/[A-Za-z0-9._/-]+$ ]] || die "COVER_ROOT must be a path below /var/www"
[[ "${STREAM_MAP_DIR}" =~ ^/etc/nginx/[A-Za-z0-9._/-]+$ ]] || die "STREAM_MAP_DIR must be a path below /etc/nginx"
[[ "${COVER_ROOT}" != *".."* ]] || die "COVER_ROOT may not contain .."
[[ "${STREAM_MAP_DIR}" != *".."* ]] || die "STREAM_MAP_DIR may not contain .."
[[ "${STREAM_MAP_FILE}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.map$ ]] || die "STREAM_MAP_FILE must be a simple filename ending in .map"
SAFE_LABEL_REGEX='^[[:alnum:]_. -]+$'
[[ "${COVER_TITLE}" =~ ${SAFE_LABEL_REGEX} ]] || die "COVER_TITLE contains unsupported characters"
[[ "${CONFIG_PROFILE_NAME}" =~ ${SAFE_LABEL_REGEX} ]] || die "CONFIG_PROFILE_NAME contains unsupported characters"
[[ "${SQUAD_NAME}" =~ ${SAFE_LABEL_REGEX} ]] || die "SQUAD_NAME contains unsupported characters"

for port_name in ORIGIN_PORT NGINX_INTERNAL_PORT XRAY_XHTTP_PORT REALITY_PORT; do
  port_value="${!port_name}"
  [[ "${port_value}" =~ ^[0-9]+$ ]] || die "${port_name} must be numeric"
  (( port_value >= 1 && port_value <= 65535 )) || die "${port_name} must be between 1 and 65535"
done

[[ "${NGINX_INTERNAL_PORT}" != "${XRAY_XHTTP_PORT}" ]] || die "NGINX_INTERNAL_PORT and XRAY_XHTTP_PORT must differ"
[[ "${NGINX_INTERNAL_PORT}" != "${REALITY_PORT}" ]] || die "NGINX_INTERNAL_PORT and REALITY_PORT must differ"
[[ "${XRAY_XHTTP_PORT}" != "${REALITY_PORT}" ]] || die "XRAY_XHTTP_PORT and REALITY_PORT must differ"

[[ "${REALITY_LISTEN_IP}" == "127.0.0.1" || "${REALITY_LISTEN_IP}" == "::1" ]] \
  || die "REALITY_LISTEN_IP must be a loopback address (127.0.0.1 or ::1)"

REALITY_TARGET_HOST="${REALITY_TARGET%:*}"
REALITY_TARGET_PORT="${REALITY_TARGET##*:}"
[[ "${REALITY_TARGET_HOST}" != "${REALITY_TARGET}" ]] || die "REALITY_TARGET must use host:port format"
[[ "${REALITY_TARGET_HOST}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] \
  || die "REALITY_TARGET host is invalid: ${REALITY_TARGET_HOST}"
[[ "${REALITY_TARGET_PORT}" =~ ^[0-9]+$ ]] || die "REALITY_TARGET port must be numeric"
(( REALITY_TARGET_PORT >= 1 && REALITY_TARGET_PORT <= 65535 )) || die "REALITY_TARGET port must be between 1 and 65535"

[[ "${REALITY_PRIVATE_KEY}" != REPLACE_WITH_* ]] || die "Set REALITY_PRIVATE_KEY in .env (generate it with: xray x25519)"
[[ "${REALITY_PASSWORD}" != REPLACE_WITH_* ]] || die "Set REALITY_PASSWORD in .env (generate it with: xray x25519)"
[[ "${REALITY_PRIVATE_KEY}" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "REALITY_PRIVATE_KEY must be a 43-character X25519 base64url key"
[[ "${REALITY_PASSWORD}" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "REALITY_PASSWORD must be a 43-character X25519 base64url value"

IFS=',' read -r -a reality_server_names <<< "${REALITY_SERVER_NAMES}"
(( ${#reality_server_names[@]} > 0 )) || die "REALITY_SERVER_NAMES must contain at least one domain"
for server_name in "${reality_server_names[@]}"; do
  [[ "${server_name}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] \
    || die "Invalid domain in REALITY_SERVER_NAMES: ${server_name}"
  [[ "${server_name,,}" != "${DOMAIN,,}" ]] || die "DOMAIN and Reality server names must differ for SNI routing"
done

declare -A seen_reality_server_names=()
for server_name in "${reality_server_names[@]}"; do
  normalized_server_name="${server_name,,}"
  [[ -z "${seen_reality_server_names[${normalized_server_name}]:-}" ]] \
    || die "Duplicate domain in REALITY_SERVER_NAMES: ${server_name}"
  seen_reality_server_names["${normalized_server_name}"]=1
done

IFS=',' read -r -a reality_short_ids <<< "${REALITY_SHORT_IDS}"
(( ${#reality_short_ids[@]} > 0 )) || die "REALITY_SHORT_IDS must contain at least one short ID"
for short_id in "${reality_short_ids[@]}"; do
  [[ "${short_id}" != REPLACE_WITH_* ]] || die "Set REALITY_SHORT_IDS in .env (generate one with: openssl rand -hex 8)"
  [[ "${short_id}" =~ ^([0-9A-Fa-f]{2}){1,8}$ ]] \
    || die "Each Reality short ID must contain 2-16 hexadecimal characters and have even length"
done

declare -A seen_reality_short_ids=()
for short_id in "${reality_short_ids[@]}"; do
  normalized_short_id="${short_id,,}"
  [[ -z "${seen_reality_short_ids[${normalized_short_id}]:-}" ]] \
    || die "Duplicate value in REALITY_SHORT_IDS: ${short_id}"
  seen_reality_short_ids["${normalized_short_id}"]=1
done

REALITY_SERVER_NAMES_JSON="$(printf '%s\n' "${reality_server_names[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
REALITY_SHORT_IDS_JSON="$(printf '%s\n' "${reality_short_ids[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
REALITY_PRIMARY_SERVER_NAME="${reality_server_names[0]}"
REALITY_PRIMARY_SHORT_ID="${reality_short_ids[0]}"
if [[ "${REALITY_LISTEN_IP}" == "::1" ]]; then
  REALITY_NGINX_BACKEND="[::1]"
else
  REALITY_NGINX_BACKEND="${REALITY_LISTEN_IP}"
fi

[[ "${ORIGIN_CERT_DAYS}" =~ ^[0-9]+$ ]] || die "ORIGIN_CERT_DAYS must be numeric"
(( ORIGIN_CERT_DAYS >= 1 && ORIGIN_CERT_DAYS <= 36500 )) || die "ORIGIN_CERT_DAYS must be between 1 and 36500"

BUILD_DIR="${PROJECT_DIR}/build/${DOMAIN}"
mkdir -p "${BUILD_DIR}"

export DOMAIN ORIGIN_IP ORIGIN_PORT NGINX_INTERNAL_PORT XRAY_LISTEN_IP
export XRAY_XHTTP_PORT XRAY_INBOUND_TAG XHTTP_PATH ORIGIN_CERT_DAYS
export COVER_ROOT COVER_TITLE STREAM_MAP_DIR STREAM_MAP_FILE
export CONFIG_PROFILE_NAME SQUAD_NAME
export REALITY_LISTEN_IP REALITY_PORT REALITY_INBOUND_TAG REALITY_XHTTP_PATH
export REALITY_TARGET REALITY_SERVER_NAMES_JSON REALITY_SHORT_IDS_JSON
export REALITY_PRIVATE_KEY REALITY_PASSWORD REALITY_PRIMARY_SERVER_NAME
export REALITY_PRIMARY_SHORT_ID REALITY_NGINX_BACKEND

SUBST_VARIABLES='${DOMAIN} ${ORIGIN_IP} ${ORIGIN_PORT} ${NGINX_INTERNAL_PORT} ${XRAY_LISTEN_IP} ${XRAY_XHTTP_PORT} ${XRAY_INBOUND_TAG} ${XHTTP_PATH} ${ORIGIN_CERT_DAYS} ${COVER_ROOT} ${COVER_TITLE} ${STREAM_MAP_DIR} ${STREAM_MAP_FILE} ${CONFIG_PROFILE_NAME} ${SQUAD_NAME} ${REALITY_LISTEN_IP} ${REALITY_PORT} ${REALITY_INBOUND_TAG} ${REALITY_XHTTP_PATH} ${REALITY_TARGET} ${REALITY_SERVER_NAMES_JSON} ${REALITY_SHORT_IDS_JSON} ${REALITY_PRIVATE_KEY} ${REALITY_PASSWORD} ${REALITY_PRIMARY_SERVER_NAME} ${REALITY_PRIMARY_SHORT_ID} ${REALITY_NGINX_BACKEND}'

render() {
  local source_file="$1"
  local destination_file="$2"
  envsubst "${SUBST_VARIABLES}" < "${source_file}" > "${destination_file}"
}

render "${PROJECT_DIR}/templates/nginx-site.conf.template" "${BUILD_DIR}/nginx-site.conf"
render "${PROJECT_DIR}/templates/nginx-stream-map-entry.conf.template" "${BUILD_DIR}/nginx-stream-map-entry.map"
render "${PROJECT_DIR}/templates/xray-inbound.json.template" "${BUILD_DIR}/xray-inbound.json"
render "${PROJECT_DIR}/templates/xray-reality-inbound.json.template" "${BUILD_DIR}/xray-reality-inbound.json"
render "${PROJECT_DIR}/templates/remnawave-xhttp-extra.json.template" "${BUILD_DIR}/remnawave-xhttp-extra.json"
render "${PROJECT_DIR}/templates/remnawave-host-values.md.template" "${BUILD_DIR}/remnawave-host-values.md"
render "${PROJECT_DIR}/templates/remnawave-reality-host-values.md.template" "${BUILD_DIR}/remnawave-reality-host-values.md"
render "${PROJECT_DIR}/templates/reality-client-credentials.json.template" "${BUILD_DIR}/reality-client-credentials.json"

for server_name in "${reality_server_names[@]}"; do
  printf '%s %s:%s; # Direct Reality\n' "${server_name}" "${REALITY_NGINX_BACKEND}" "${REALITY_PORT}" \
    >> "${BUILD_DIR}/nginx-stream-map-entry.map"
done

jq -s '.' \
  "${BUILD_DIR}/xray-inbound.json" \
  "${BUILD_DIR}/xray-reality-inbound.json" \
  > "${BUILD_DIR}/xray-inbounds.json"

jq empty "${BUILD_DIR}/xray-inbound.json"
jq empty "${BUILD_DIR}/xray-reality-inbound.json"
jq 'length == 2' -e "${BUILD_DIR}/xray-inbounds.json" >/dev/null
jq empty "${BUILD_DIR}/remnawave-xhttp-extra.json"
jq empty "${BUILD_DIR}/reality-client-credentials.json"

chmod 600 "${BUILD_DIR}"/*

printf 'Generated configuration: %s\n' "${BUILD_DIR}"
printf '  - nginx-site.conf\n'
printf '  - nginx-stream-map-entry.map\n'
printf '  - xray-inbound.json\n'
printf '  - xray-reality-inbound.json\n'
printf '  - xray-inbounds.json\n'
printf '  - remnawave-xhttp-extra.json\n'
printf '  - remnawave-host-values.md\n'
printf '  - remnawave-reality-host-values.md\n'
printf '  - reality-client-credentials.json\n'
