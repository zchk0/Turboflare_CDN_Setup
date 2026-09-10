#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${1:-${PROJECT_DIR}/.env}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -f "${ENV_FILE}" ]] || die "Environment file not found: ${ENV_FILE}"
command -v awk >/dev/null 2>&1 || die "awk is required"
command -v openssl >/dev/null 2>&1 || die "openssl is required"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

write_env_value() {
  local variable_name="$1"
  local variable_value="$2"
  local temporary_file

  temporary_file="$(mktemp "${ENV_FILE}.tmp.XXXXXX")"
  chmod 600 "${temporary_file}"

  if ! awk -v key="${variable_name}" -v value="${variable_value}" '
    BEGIN { replaced = 0 }
    index($0, key "=") == 1 {
      if (!replaced) {
        print key "=" value
        replaced = 1
      }
      next
    }
    { print }
    END {
      if (!replaced) {
        print key "=" value
      }
    }
  ' "${ENV_FILE}" > "${temporary_file}"; then
    rm -f -- "${temporary_file}"
    die "Could not update ${variable_name} in ${ENV_FILE}"
  fi

  mv -f -- "${temporary_file}" "${ENV_FILE}"
  chmod 600 "${ENV_FILE}"
  printf -v "${variable_name}" '%s' "${variable_value}"
  export "${variable_name}"
}

set_default() {
  local variable_name="$1"
  local default_value="$2"

  if [[ -z "${!variable_name:-}" ]]; then
    write_env_value "${variable_name}" "${default_value}"
  fi
}

is_placeholder() {
  [[ -z "$1" || "$1" == REPLACE_WITH_* ]]
}

run_xray_keygen() {
  if command -v xray >/dev/null 2>&1; then
    xray x25519 "$@"
    return
  fi

  local container_name="${XRAY_KEYGEN_CONTAINER:-remnanode}"
  if command -v docker >/dev/null 2>&1 \
    && docker inspect "${container_name}" >/dev/null 2>&1; then
    docker exec "${container_name}" xray x25519 "$@"
    return
  fi

  die "Cannot find Xray. Install the xray command or set XRAY_KEYGEN_CONTAINER to a running Remnawave container"
}

parse_private_key() {
  awk -F': *' '/^(PrivateKey|Private key):/ { print $2; exit }'
}

parse_password() {
  awk -F': *' '/^(Password \(PublicKey\)|Password|Public key):/ { print $2; exit }'
}

# Migrate an older .env automatically when the two-inbound installer is run.
set_default REALITY_LISTEN_IP 127.0.0.1
set_default REALITY_PORT 2443
set_default REALITY_INBOUND_TAG xHTTP-Yandexcloud
set_default REALITY_TARGET functions.yandexcloud.net:443
set_default REALITY_SERVER_NAMES functions.yandexcloud.net,api-maps.yandex.ru,mediafeeds.yandex.ru
set_default XRAY_KEYGEN_CONTAINER remnanode

if [[ -z "${REALITY_XHTTP_PATH:-}" || "${REALITY_XHTTP_PATH}" == "/replace-with-a-random-path" ]]; then
  write_env_value REALITY_XHTTP_PATH "/$(openssl rand -hex 16)"
  printf 'Generated REALITY_XHTTP_PATH in %s\n' "${ENV_FILE}"
fi

if is_placeholder "${REALITY_PRIVATE_KEY:-}"; then
  keygen_output="$(run_xray_keygen)"
  generated_private_key="$(printf '%s\n' "${keygen_output}" | parse_private_key)"
  generated_password="$(printf '%s\n' "${keygen_output}" | parse_password)"

  [[ "${generated_private_key}" =~ ^[A-Za-z0-9_-]{43}$ ]] \
    || die "Could not parse PrivateKey from xray x25519 output"
  [[ "${generated_password}" =~ ^[A-Za-z0-9_-]{43}$ ]] \
    || die "Could not parse Password/PublicKey from xray x25519 output"

  write_env_value REALITY_PRIVATE_KEY "${generated_private_key}"
  write_env_value REALITY_PASSWORD "${generated_password}"
  printf 'Generated REALITY_PRIVATE_KEY and REALITY_PASSWORD in %s\n' "${ENV_FILE}"
elif is_placeholder "${REALITY_PASSWORD:-}"; then
  keygen_output="$(run_xray_keygen -i "${REALITY_PRIVATE_KEY}")"
  generated_password="$(printf '%s\n' "${keygen_output}" | parse_password)"

  [[ "${generated_password}" =~ ^[A-Za-z0-9_-]{43}$ ]] \
    || die "Could not derive Password/PublicKey from REALITY_PRIVATE_KEY"

  write_env_value REALITY_PASSWORD "${generated_password}"
  printf 'Derived REALITY_PASSWORD from the existing private key in %s\n' "${ENV_FILE}"
fi

if is_placeholder "${REALITY_SHORT_IDS:-}"; then
  write_env_value REALITY_SHORT_IDS "$(openssl rand -hex 8)"
  printf 'Generated one REALITY_SHORT_ID in %s\n' "${ENV_FILE}"
fi

printf 'Reality credentials are ready. Existing values were preserved.\n'
