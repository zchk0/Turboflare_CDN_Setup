#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONNECTIONS="${1:-${NGINX_WORKER_CONNECTIONS:-65536}}"
NOFILE="${2:-${NGINX_WORKER_RLIMIT_NOFILE:-131072}}"
CONFIG="${NGINX_CONF_PATH:-/etc/nginx/nginx.conf}"
DROP_IN="${NGINX_SYSTEMD_DROP_IN:-/etc/systemd/system/nginx.service.d/99-cdn-limits.conf}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

(( $# <= 2 )) || die "Usage: sudo bash scripts/tune-nginx-limits.sh [connections [nofile]]"
[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo bash scripts/tune-nginx-limits.sh"
for value in "${CONNECTIONS}" "${NOFILE}"; do
  [[ "${value}" =~ ^[1-9][0-9]{0,8}$ ]] || die "Limits must be positive integers (at most 9 digits)"
done
(( NOFILE > CONNECTIONS )) || die "nofile must exceed connections to leave room for logs and other files"
if [[ -r /proc/sys/fs/nr_open ]]; then
  read -r kernel_max < /proc/sys/fs/nr_open
  (( NOFILE <= kernel_max )) || die "nofile exceeds fs.nr_open (${kernel_max})"
fi
[[ -f "${CONFIG}" ]] || die "Nginx configuration not found: ${CONFIG}"
for command_name in nginx systemctl awk; do
  command -v "${command_name}" >/dev/null || die "Missing command: ${command_name}"
done

# Check the existing configuration before making any changes.
nginx -t -c "${CONFIG}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "${WORK_DIR}"' EXIT
awk -v connections="${CONNECTIONS}" -v nofile="${NOFILE}" \
  -f "${SCRIPT_DIR}/nginx-limits.awk" "${CONFIG}" > "${WORK_DIR}/nginx.conf"
printf '[Service]\nLimitNOFILE=%s\n' "${NOFILE}" > "${WORK_DIR}/limits.conf"

config_changed=false
drop_in_changed=false
cmp -s "${CONFIG}" "${WORK_DIR}/nginx.conf" || config_changed=true
cmp -s "${DROP_IN}" "${WORK_DIR}/limits.conf" || drop_in_changed=true
if [[ "${config_changed}" == false && "${drop_in_changed}" == false ]]; then
  printf 'Nginx limits already configured: connections=%s, nofile=%s\n' "${CONNECTIONS}" "${NOFILE}"
  exit 0
fi

TIMESTAMP="$(date +%Y%m%d-%H%M%S)-$$"
CONFIG_BACKUP="${CONFIG}.bak-${TIMESTAMP}"
DROP_IN_BACKUP="${DROP_IN}.bak-${TIMESTAMP}"
drop_in_existed=false
service_attempted=false
cp -pL -- "${CONFIG}" "${CONFIG_BACKUP}"
if [[ -e "${DROP_IN}" ]]; then
  cp -pL -- "${DROP_IN}" "${DROP_IN_BACKUP}"
  drop_in_existed=true
fi

rollback() {
  local status=$?
  trap - ERR
  set +e
  cp -p -- "${CONFIG_BACKUP}" "${CONFIG}"
  if [[ "${drop_in_changed}" == true ]]; then
    if [[ "${drop_in_existed}" == true ]]; then
      cp -p -- "${DROP_IN_BACKUP}" "${DROP_IN}"
    else
      rm -f -- "${DROP_IN}"
    fi
    systemctl daemon-reload
  fi
  if [[ "${service_attempted}" == true ]]; then
    nginx -t -c "${CONFIG}" && systemctl restart nginx
  fi
  printf 'ERROR: Could not apply Nginx limits; restored configuration from %s\n' "${CONFIG_BACKUP}" >&2
  exit "${status}"
}
trap rollback ERR

# Write through an existing symlink and retain nginx.conf ownership/mode.
if [[ "${config_changed}" == true ]]; then
  cat "${WORK_DIR}/nginx.conf" > "${CONFIG}"
fi
nginx -t -c "${CONFIG}"
if [[ "${drop_in_changed}" == true ]]; then
  install -d -m 755 "$(dirname -- "${DROP_IN}")"
  install -m 644 "${WORK_DIR}/limits.conf" "${DROP_IN}"
  systemctl daemon-reload
fi

service_attempted=true
if [[ "${drop_in_changed}" == true ]]; then
  # systemd resource limits are inherited when the service starts.
  printf 'Restarting Nginx to apply LimitNOFILE; active connections may be interrupted.\n'
  systemctl restart nginx
else
  systemctl reload nginx
fi
trap - ERR
printf 'Applied Nginx limits: worker_processes=auto, connections=%s, nofile=%s\n' "${CONNECTIONS}" "${NOFILE}"
printf 'Nginx configuration backup: %s\n' "${CONFIG_BACKUP}"
