#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${PROJECT_DIR}/.env"
COMPONENTS_OVERRIDE=""
ENV_FILE_SET=false

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/render.sh [--env PATH] [--only COMPONENTS]

COMPONENTS is a comma-separated list containing turboflare, beeline and/or
reality. --only overrides DEPLOY_COMPONENTS for this run without editing .env.
For compatibility, a single positional argument is treated as the env path.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --env)
      (( $# >= 2 )) || die "--env requires a path"
      ENV_FILE="$2"
      ENV_FILE_SET=true
      shift 2
      ;;
    --env=*)
      ENV_FILE="${1#*=}"
      ENV_FILE_SET=true
      shift
      ;;
    --only)
      (( $# >= 2 )) || die "--only requires a component list"
      COMPONENTS_OVERRIDE="$2"
      shift 2
      ;;
    --only=*)
      COMPONENTS_OVERRIDE="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      die "Unknown option: $1"
      ;;
    *)
      [[ "${ENV_FILE_SET}" == false ]] || die "Unexpected argument: $1"
      ENV_FILE="$1"
      ENV_FILE_SET=true
      shift
      ;;
  esac
done

command -v envsubst >/dev/null 2>&1 || die "envsubst is required (Debian/Ubuntu: apt install gettext-base)"
command -v jq >/dev/null 2>&1 || die "jq is required (Debian/Ubuntu: apt install jq)"
[[ -f "${ENV_FILE}" ]] || die "Environment file not found: ${ENV_FILE}. Run: cp .env.example .env"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

declare -A ENABLED_COMPONENTS=()
parse_components() {
  local raw_components="$1"
  local component
  local -a requested_components

  IFS=',' read -r -a requested_components <<< "${raw_components}"
  for component in "${requested_components[@]}"; do
    component="${component//[[:space:]]/}"
    component="${component,,}"
    [[ -n "${component}" ]] || continue
    case "${component}" in
      turboflare|beeline|reality)
        ENABLED_COMPONENTS["${component}"]=1
        ;;
      *)
        die "Unsupported component: ${component}. Use turboflare, beeline and/or reality"
        ;;
    esac
  done

  (( ${#ENABLED_COMPONENTS[@]} > 0 )) || die "At least one deployment component must be enabled"
}

parse_components "${COMPONENTS_OVERRIDE:-${DEPLOY_COMPONENTS:-turboflare,reality}}"

component_enabled() {
  [[ -n "${ENABLED_COMPONENTS[$1]:-}" ]]
}

effective_components=()
for component in turboflare beeline reality; do
  if component_enabled "${component}"; then
    effective_components+=("${component}")
  fi
done
DEPLOY_COMPONENTS_EFFECTIVE="$(IFS=,; printf '%s' "${effective_components[*]}")"

TURBOFLARE_STREAM_MAP_FILE="${TURBOFLARE_STREAM_MAP_FILE:-${STREAM_MAP_FILE:-turboflare.map}}"
BEELINE_STREAM_MAP_FILE="${BEELINE_STREAM_MAP_FILE:-beeline.map}"
REALITY_STREAM_MAP_FILE="${REALITY_STREAM_MAP_FILE:-reality.map}"

require_variables() {
  local variable_name
  for variable_name in "$@"; do
    [[ -n "${!variable_name:-}" ]] || die "${variable_name} is empty"
  done
}

validate_domain() {
  local variable_name="$1"
  local value="${!variable_name}"
  [[ "${value}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] \
    || die "${variable_name} is invalid: ${value}"
}

validate_port() {
  local variable_name="$1"
  local value="${!variable_name}"
  [[ "${value}" =~ ^[0-9]+$ ]] || die "${variable_name} must be numeric"
  (( value >= 1 && value <= 65535 )) || die "${variable_name} must be between 1 and 65535"
}

validate_url_path() {
  local variable_name="$1"
  local value="${!variable_name}"
  [[ "${value}" =~ ^/[A-Za-z0-9._~/-]+$ ]] \
    || die "${variable_name} must start with / and contain only URL-safe path characters"
}

validate_var_www_path() {
  local variable_name="$1"
  local value="${!variable_name}"
  [[ "${value}" =~ ^/var/www/[A-Za-z0-9._/-]+$ ]] || die "${variable_name} must be a path below /var/www"
  [[ "${value}" != *".."* ]] || die "${variable_name} may not contain .."
}

validate_map_file() {
  local variable_name="$1"
  local value="${!variable_name}"
  [[ "${value}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.map$ ]] \
    || die "${variable_name} must be a simple filename ending in .map"
}

validate_safe_label() {
  local variable_name="$1"
  local value="${!variable_name}"
  local safe_label_regex='^[[:alnum:]_. -]+$'
  [[ "${value}" =~ ${safe_label_regex} ]] || die "${variable_name} contains unsupported characters"
}

nginx_backend_for() {
  case "$1" in
    127.0.0.1) printf '127.0.0.1' ;;
    ::1) printf '[::1]' ;;
    *) die "Xray/Reality listen addresses must be loopback (127.0.0.1 or ::1): $1" ;;
  esac
}

declare -A USED_PORTS=()
claim_port() {
  local variable_name="$1"
  local label="$2"
  local value="${!variable_name}"
  validate_port "${variable_name}"
  if [[ -n "${USED_PORTS[${value}]:-}" ]]; then
    die "Port ${value} is used by both ${USED_PORTS[${value}]} and ${label}"
  fi
  USED_PORTS["${value}"]="${label}"
}

declare -A USED_TAGS=()
claim_tag() {
  local variable_name="$1"
  local value="${!variable_name}"
  [[ "${value}" =~ ^[A-Za-z0-9_-]+$ ]] || die "${variable_name} may contain only A-Z, a-z, 0-9, _ and -"
  if [[ -n "${USED_TAGS[${value}]:-}" ]]; then
    die "Inbound tag ${value} is used by both ${USED_TAGS[${value}]} and ${variable_name}"
  fi
  USED_TAGS["${value}"]="${variable_name}"
}

declare -A USED_MAP_FILES=()
claim_map_file() {
  local variable_name="$1"
  local value="${!variable_name}"
  validate_map_file "${variable_name}"
  if [[ -n "${USED_MAP_FILES[${value}]:-}" ]]; then
    die "Stream map file ${value} is used by both ${USED_MAP_FILES[${value}]} and ${variable_name}"
  fi
  USED_MAP_FILES["${value}"]="${variable_name}"
}

declare -A USED_ORIGIN_SNI=()
claim_origin_sni() {
  local value="${1,,}"
  local label="$2"
  if [[ -n "${USED_ORIGIN_SNI[${value}]:-}" ]]; then
    die "Origin SNI ${1} is used by both ${USED_ORIGIN_SNI[${value}]} and ${label}"
  fi
  USED_ORIGIN_SNI["${value}"]="${label}"
}

require_variables ORIGIN_IP STREAM_MAP_DIR CONFIG_PROFILE_NAME
[[ "${ORIGIN_IP}" =~ ^[0-9A-Fa-f:.]+$ ]] || die "ORIGIN_IP contains unsupported characters"
[[ "${STREAM_MAP_DIR}" =~ ^/etc/nginx/[A-Za-z0-9._/-]+$ ]] || die "STREAM_MAP_DIR must be a path below /etc/nginx"
[[ "${STREAM_MAP_DIR}" != *".."* ]] || die "STREAM_MAP_DIR may not contain .."
validate_safe_label CONFIG_PROFILE_NAME

if component_enabled turboflare; then
  require_variables DOMAIN ORIGIN_PORT NGINX_INTERNAL_PORT XRAY_LISTEN_IP XRAY_XHTTP_PORT \
    XRAY_INBOUND_TAG XHTTP_PATH ORIGIN_CERT_DAYS COVER_ROOT COVER_TITLE SQUAD_NAME
  validate_domain DOMAIN
  validate_port ORIGIN_PORT
  validate_url_path XHTTP_PATH
  validate_var_www_path COVER_ROOT
  validate_safe_label COVER_TITLE
  validate_safe_label SQUAD_NAME
  claim_map_file TURBOFLARE_STREAM_MAP_FILE
  [[ "${ORIGIN_CERT_DAYS}" =~ ^[0-9]+$ ]] || die "ORIGIN_CERT_DAYS must be numeric"
  (( ORIGIN_CERT_DAYS >= 1 && ORIGIN_CERT_DAYS <= 36500 )) || die "ORIGIN_CERT_DAYS must be between 1 and 36500"
  XRAY_NGINX_BACKEND="$(nginx_backend_for "${XRAY_LISTEN_IP}")"
  claim_port NGINX_INTERNAL_PORT "TurboFlare Nginx"
  claim_port XRAY_XHTTP_PORT "TurboFlare Xray"
  claim_tag XRAY_INBOUND_TAG
  claim_origin_sni "${DOMAIN}" "TurboFlare"
fi

if component_enabled beeline; then
  require_variables BEELINE_ORIGIN_DOMAIN BEELINE_CDN_SYSTEM_DOMAIN BEELINE_ORIGIN_PORT \
    BEELINE_NGINX_INTERNAL_PORT BEELINE_XRAY_LISTEN_IP BEELINE_XRAY_XHTTP_PORT \
    BEELINE_XRAY_INBOUND_TAG BEELINE_XHTTP_PATH BEELINE_ORIGIN_CERT_MODE \
    BEELINE_ORIGIN_CERT_DAYS BEELINE_COVER_ROOT BEELINE_COVER_TITLE \
    BEELINE_ACME_ROOT BEELINE_SQUAD_NAME
  validate_domain BEELINE_ORIGIN_DOMAIN
  validate_domain BEELINE_CDN_SYSTEM_DOMAIN
  if [[ -n "${BEELINE_CDN_CUSTOM_DOMAIN:-}" ]]; then
    validate_domain BEELINE_CDN_CUSTOM_DOMAIN
    [[ "${BEELINE_CDN_CUSTOM_DOMAIN,,}" != "${BEELINE_CDN_SYSTEM_DOMAIN,,}" ]] \
      || die "BEELINE_CDN_CUSTOM_DOMAIN and BEELINE_CDN_SYSTEM_DOMAIN must differ"
  fi
  validate_port BEELINE_ORIGIN_PORT
  validate_url_path BEELINE_XHTTP_PATH
  validate_var_www_path BEELINE_COVER_ROOT
  validate_var_www_path BEELINE_ACME_ROOT
  validate_safe_label BEELINE_COVER_TITLE
  validate_safe_label BEELINE_SQUAD_NAME
  claim_map_file BEELINE_STREAM_MAP_FILE
  [[ "${BEELINE_ORIGIN_CERT_DAYS}" =~ ^[0-9]+$ ]] || die "BEELINE_ORIGIN_CERT_DAYS must be numeric"
  (( BEELINE_ORIGIN_CERT_DAYS >= 1 && BEELINE_ORIGIN_CERT_DAYS <= 36500 )) \
    || die "BEELINE_ORIGIN_CERT_DAYS must be between 1 and 36500"

  case "${BEELINE_ORIGIN_CERT_MODE}" in
    selfsigned)
      BEELINE_TLS_CERT_PATH="/etc/nginx/ssl/${BEELINE_ORIGIN_DOMAIN}/origin.crt"
      BEELINE_TLS_KEY_PATH="/etc/nginx/ssl/${BEELINE_ORIGIN_DOMAIN}/origin.key"
      ;;
    existing)
      require_variables BEELINE_ORIGIN_CERT BEELINE_ORIGIN_KEY
      [[ "${BEELINE_ORIGIN_CERT}" =~ ^/[A-Za-z0-9._/-]+$ && "${BEELINE_ORIGIN_CERT}" != *".."* ]] \
        || die "BEELINE_ORIGIN_CERT must be a safe absolute path without .."
      [[ "${BEELINE_ORIGIN_KEY}" =~ ^/[A-Za-z0-9._/-]+$ && "${BEELINE_ORIGIN_KEY}" != *".."* ]] \
        || die "BEELINE_ORIGIN_KEY must be a safe absolute path without .."
      BEELINE_TLS_CERT_PATH="${BEELINE_ORIGIN_CERT}"
      BEELINE_TLS_KEY_PATH="${BEELINE_ORIGIN_KEY}"
      ;;
    *)
      die "BEELINE_ORIGIN_CERT_MODE must be selfsigned or existing"
      ;;
  esac

  BEELINE_HOST_DOMAIN="${BEELINE_CDN_CUSTOM_DOMAIN:-${BEELINE_CDN_SYSTEM_DOMAIN}}"
  BEELINE_CDN_CUSTOM_DOMAIN_DISPLAY="${BEELINE_CDN_CUSTOM_DOMAIN:-not configured}"
  BEELINE_XRAY_NGINX_BACKEND="$(nginx_backend_for "${BEELINE_XRAY_LISTEN_IP}")"
  claim_port BEELINE_NGINX_INTERNAL_PORT "Beeline Nginx"
  claim_port BEELINE_XRAY_XHTTP_PORT "Beeline Xray"
  claim_tag BEELINE_XRAY_INBOUND_TAG
  claim_origin_sni "${BEELINE_ORIGIN_DOMAIN}" "Beeline"
fi

if component_enabled reality; then
  require_variables REALITY_LISTEN_IP REALITY_PORT REALITY_INBOUND_TAG REALITY_XHTTP_PATH \
    REALITY_TARGET REALITY_SERVER_NAMES REALITY_PRIVATE_KEY REALITY_PASSWORD REALITY_SHORT_IDS
  validate_url_path REALITY_XHTTP_PATH
  claim_map_file REALITY_STREAM_MAP_FILE
  REALITY_NGINX_BACKEND="$(nginx_backend_for "${REALITY_LISTEN_IP}")"
  claim_port REALITY_PORT "Reality Xray"
  claim_tag REALITY_INBOUND_TAG

  REALITY_TARGET_HOST="${REALITY_TARGET%:*}"
  REALITY_TARGET_PORT="${REALITY_TARGET##*:}"
  [[ "${REALITY_TARGET_HOST}" != "${REALITY_TARGET}" ]] || die "REALITY_TARGET must use host:port format"
  validate_domain REALITY_TARGET_HOST
  [[ "${REALITY_TARGET_PORT}" =~ ^[0-9]+$ ]] || die "REALITY_TARGET port must be numeric"
  (( REALITY_TARGET_PORT >= 1 && REALITY_TARGET_PORT <= 65535 )) || die "REALITY_TARGET port must be between 1 and 65535"

  [[ "${REALITY_PRIVATE_KEY}" != REPLACE_WITH_* ]] || die "Set REALITY_PRIVATE_KEY in .env (generate it with: xray x25519)"
  [[ "${REALITY_PASSWORD}" != REPLACE_WITH_* ]] || die "Set REALITY_PASSWORD in .env (generate it with: xray x25519)"
  [[ "${REALITY_PRIVATE_KEY}" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "REALITY_PRIVATE_KEY must be a 43-character X25519 base64url key"
  [[ "${REALITY_PASSWORD}" =~ ^[A-Za-z0-9_-]{43}$ ]] || die "REALITY_PASSWORD must be a 43-character X25519 base64url value"

  IFS=',' read -r -a reality_server_names <<< "${REALITY_SERVER_NAMES}"
  (( ${#reality_server_names[@]} > 0 )) || die "REALITY_SERVER_NAMES must contain at least one domain"
  declare -A seen_reality_server_names=()
  REALITY_SERVER_NAMES_MAP=""
  for server_name in "${reality_server_names[@]}"; do
    validate_domain server_name
    normalized_server_name="${server_name,,}"
    [[ -z "${seen_reality_server_names[${normalized_server_name}]:-}" ]] \
      || die "Duplicate domain in REALITY_SERVER_NAMES: ${server_name}"
    seen_reality_server_names["${normalized_server_name}"]=1
    claim_origin_sni "${server_name}" "Reality"
    map_line="${server_name} ${REALITY_NGINX_BACKEND}:${REALITY_PORT}; # Direct Reality"
    if [[ -n "${REALITY_SERVER_NAMES_MAP}" ]]; then
      REALITY_SERVER_NAMES_MAP+=$'\n'
    fi
    REALITY_SERVER_NAMES_MAP+="${map_line}"
  done

  IFS=',' read -r -a reality_short_ids <<< "${REALITY_SHORT_IDS}"
  (( ${#reality_short_ids[@]} > 0 )) || die "REALITY_SHORT_IDS must contain at least one short ID"
  declare -A seen_reality_short_ids=()
  for short_id in "${reality_short_ids[@]}"; do
    [[ "${short_id}" != REPLACE_WITH_* ]] || die "Set REALITY_SHORT_IDS in .env (generate one with: openssl rand -hex 8)"
    [[ "${short_id}" =~ ^([0-9A-Fa-f]{2}){1,8}$ ]] \
      || die "Each Reality short ID must contain 2-16 hexadecimal characters and have even length"
    normalized_short_id="${short_id,,}"
    [[ -z "${seen_reality_short_ids[${normalized_short_id}]:-}" ]] \
      || die "Duplicate value in REALITY_SHORT_IDS: ${short_id}"
    seen_reality_short_ids["${normalized_short_id}"]=1
  done

  REALITY_SERVER_NAMES_JSON="$(printf '%s\n' "${reality_server_names[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  REALITY_SHORT_IDS_JSON="$(printf '%s\n' "${reality_short_ids[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')"
  REALITY_PRIMARY_SERVER_NAME="${reality_server_names[0]}"
  REALITY_PRIMARY_SHORT_ID="${reality_short_ids[0]}"
fi

BUILD_ROOT="${PROJECT_DIR}/build"
SHARED_BUILD_DIR="${BUILD_ROOT}/shared"
mkdir -p "${SHARED_BUILD_DIR}"

export DEPLOY_COMPONENTS_EFFECTIVE ORIGIN_IP STREAM_MAP_DIR CONFIG_PROFILE_NAME
export TURBOFLARE_STREAM_MAP_FILE BEELINE_STREAM_MAP_FILE REALITY_STREAM_MAP_FILE
export DOMAIN ORIGIN_PORT NGINX_INTERNAL_PORT XRAY_LISTEN_IP XRAY_NGINX_BACKEND
export XRAY_XHTTP_PORT XRAY_INBOUND_TAG XHTTP_PATH ORIGIN_CERT_DAYS
export COVER_ROOT COVER_TITLE SQUAD_NAME
export BEELINE_ORIGIN_DOMAIN BEELINE_CDN_SYSTEM_DOMAIN BEELINE_CDN_CUSTOM_DOMAIN
export BEELINE_CDN_CUSTOM_DOMAIN_DISPLAY
export BEELINE_HOST_DOMAIN BEELINE_ORIGIN_PORT BEELINE_NGINX_INTERNAL_PORT
export BEELINE_XRAY_LISTEN_IP BEELINE_XRAY_NGINX_BACKEND BEELINE_XRAY_XHTTP_PORT
export BEELINE_XRAY_INBOUND_TAG BEELINE_XHTTP_PATH BEELINE_ORIGIN_CERT_MODE
export BEELINE_TLS_CERT_PATH BEELINE_TLS_KEY_PATH BEELINE_ORIGIN_CERT_DAYS
export BEELINE_COVER_ROOT BEELINE_COVER_TITLE BEELINE_ACME_ROOT BEELINE_SQUAD_NAME
export REALITY_LISTEN_IP REALITY_NGINX_BACKEND REALITY_PORT REALITY_INBOUND_TAG
export REALITY_XHTTP_PATH REALITY_TARGET REALITY_SERVER_NAMES_JSON REALITY_SHORT_IDS_JSON
export REALITY_PRIVATE_KEY REALITY_PASSWORD REALITY_PRIMARY_SERVER_NAME
export REALITY_PRIMARY_SHORT_ID REALITY_SERVER_NAMES_MAP

SUBST_VARIABLES='${DEPLOY_COMPONENTS_EFFECTIVE} ${ORIGIN_IP} ${STREAM_MAP_DIR} ${CONFIG_PROFILE_NAME} ${TURBOFLARE_STREAM_MAP_FILE} ${BEELINE_STREAM_MAP_FILE} ${REALITY_STREAM_MAP_FILE} ${DOMAIN} ${ORIGIN_PORT} ${NGINX_INTERNAL_PORT} ${XRAY_LISTEN_IP} ${XRAY_NGINX_BACKEND} ${XRAY_XHTTP_PORT} ${XRAY_INBOUND_TAG} ${XHTTP_PATH} ${ORIGIN_CERT_DAYS} ${COVER_ROOT} ${COVER_TITLE} ${SQUAD_NAME} ${BEELINE_ORIGIN_DOMAIN} ${BEELINE_CDN_SYSTEM_DOMAIN} ${BEELINE_CDN_CUSTOM_DOMAIN} ${BEELINE_CDN_CUSTOM_DOMAIN_DISPLAY} ${BEELINE_HOST_DOMAIN} ${BEELINE_ORIGIN_PORT} ${BEELINE_NGINX_INTERNAL_PORT} ${BEELINE_XRAY_LISTEN_IP} ${BEELINE_XRAY_NGINX_BACKEND} ${BEELINE_XRAY_XHTTP_PORT} ${BEELINE_XRAY_INBOUND_TAG} ${BEELINE_XHTTP_PATH} ${BEELINE_ORIGIN_CERT_MODE} ${BEELINE_TLS_CERT_PATH} ${BEELINE_TLS_KEY_PATH} ${BEELINE_ORIGIN_CERT_DAYS} ${BEELINE_COVER_ROOT} ${BEELINE_COVER_TITLE} ${BEELINE_ACME_ROOT} ${BEELINE_SQUAD_NAME} ${REALITY_LISTEN_IP} ${REALITY_NGINX_BACKEND} ${REALITY_PORT} ${REALITY_INBOUND_TAG} ${REALITY_XHTTP_PATH} ${REALITY_TARGET} ${REALITY_SERVER_NAMES_JSON} ${REALITY_SHORT_IDS_JSON} ${REALITY_PRIVATE_KEY} ${REALITY_PASSWORD} ${REALITY_PRIMARY_SERVER_NAME} ${REALITY_PRIMARY_SHORT_ID} ${REALITY_SERVER_NAMES_MAP}'

generated_files=()
inbound_files=()

render() {
  local source_file="$1"
  local destination_file="$2"
  envsubst "${SUBST_VARIABLES}" < "${source_file}" > "${destination_file}"
  generated_files+=("${destination_file}")
}

if component_enabled turboflare; then
  TURBOFLARE_BUILD_DIR="${BUILD_ROOT}/turboflare/${DOMAIN}"
  mkdir -p "${TURBOFLARE_BUILD_DIR}"
  render "${PROJECT_DIR}/templates/nginx-site.conf.template" "${TURBOFLARE_BUILD_DIR}/nginx-site.conf"
  render "${PROJECT_DIR}/templates/nginx-stream-map-entry.conf.template" "${TURBOFLARE_BUILD_DIR}/nginx-stream-map-entry.map"
  render "${PROJECT_DIR}/templates/xray-inbound.json.template" "${TURBOFLARE_BUILD_DIR}/xray-inbound.json"
  render "${PROJECT_DIR}/templates/remnawave-xhttp-extra.json.template" "${TURBOFLARE_BUILD_DIR}/remnawave-xhttp-extra.json"
  render "${PROJECT_DIR}/templates/remnawave-host-values.md.template" "${TURBOFLARE_BUILD_DIR}/remnawave-host-values.md"
  jq empty "${TURBOFLARE_BUILD_DIR}/xray-inbound.json"
  jq empty "${TURBOFLARE_BUILD_DIR}/remnawave-xhttp-extra.json"
  inbound_files+=("${TURBOFLARE_BUILD_DIR}/xray-inbound.json")
fi

if component_enabled beeline; then
  BEELINE_BUILD_DIR="${BUILD_ROOT}/beeline/${BEELINE_ORIGIN_DOMAIN}"
  mkdir -p "${BEELINE_BUILD_DIR}"
  render "${PROJECT_DIR}/templates/nginx-beeline-site.conf.template" "${BEELINE_BUILD_DIR}/nginx-site.conf"
  render "${PROJECT_DIR}/templates/nginx-beeline-stream-map-entry.conf.template" "${BEELINE_BUILD_DIR}/nginx-stream-map-entry.map"
  render "${PROJECT_DIR}/templates/xray-beeline-inbound.json.template" "${BEELINE_BUILD_DIR}/xray-inbound.json"
  render "${PROJECT_DIR}/templates/remnawave-beeline-xhttp-extra.json.template" "${BEELINE_BUILD_DIR}/remnawave-xhttp-extra.json"
  render "${PROJECT_DIR}/templates/remnawave-beeline-host-values.md.template" "${BEELINE_BUILD_DIR}/remnawave-host-values.md"
  render "${PROJECT_DIR}/templates/beeline-cdn-settings.md.template" "${BEELINE_BUILD_DIR}/beeline-cdn-settings.md"
  jq empty "${BEELINE_BUILD_DIR}/xray-inbound.json"
  jq empty "${BEELINE_BUILD_DIR}/remnawave-xhttp-extra.json"
  inbound_files+=("${BEELINE_BUILD_DIR}/xray-inbound.json")
fi

if component_enabled reality; then
  REALITY_BUILD_DIR="${BUILD_ROOT}/reality"
  mkdir -p "${REALITY_BUILD_DIR}"
  render "${PROJECT_DIR}/templates/nginx-reality-stream-map-entry.conf.template" "${REALITY_BUILD_DIR}/nginx-stream-map-entry.map"
  render "${PROJECT_DIR}/templates/xray-reality-inbound.json.template" "${REALITY_BUILD_DIR}/xray-inbound.json"
  render "${PROJECT_DIR}/templates/remnawave-reality-host-values.md.template" "${REALITY_BUILD_DIR}/remnawave-host-values.md"
  render "${PROJECT_DIR}/templates/reality-client-credentials.json.template" "${REALITY_BUILD_DIR}/client-credentials.json"
  jq empty "${REALITY_BUILD_DIR}/xray-inbound.json"
  jq empty "${REALITY_BUILD_DIR}/client-credentials.json"
  inbound_files+=("${REALITY_BUILD_DIR}/xray-inbound.json")
fi

jq -s '.' "${inbound_files[@]}" > "${SHARED_BUILD_DIR}/xray-inbounds.json"
generated_files+=("${SHARED_BUILD_DIR}/xray-inbounds.json")
jq -e --argjson expected "${#inbound_files[@]}" 'length == $expected' \
  "${SHARED_BUILD_DIR}/xray-inbounds.json" >/dev/null

printf '%s\n' "${DEPLOY_COMPONENTS_EFFECTIVE}" > "${SHARED_BUILD_DIR}/components.txt"
generated_files+=("${SHARED_BUILD_DIR}/components.txt")
chmod 600 "${generated_files[@]}"

printf 'Generated components: %s\n' "${DEPLOY_COMPONENTS_EFFECTIVE}"
printf 'Combined Xray inbounds: %s\n' "${SHARED_BUILD_DIR}/xray-inbounds.json"
if component_enabled turboflare; then
  printf 'TurboFlare files: %s\n' "${TURBOFLARE_BUILD_DIR}"
fi
if component_enabled beeline; then
  printf 'Beeline files: %s\n' "${BEELINE_BUILD_DIR}"
fi
if component_enabled reality; then
  printf 'Reality files: %s\n' "${REALITY_BUILD_DIR}"
fi
