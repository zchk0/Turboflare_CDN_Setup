#!/usr/bin/env bash
set -Eeuo pipefail

# Runs against real nginx syntax validation; systemctl is mocked so no service
# or system configuration is changed. Run with sudo on Linux/WSL.
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "${EUID}" -eq 0 ]] || { printf 'Run this test as root\n' >&2; exit 1; }
REAL_NGINX="$(command -v nginx)"
export REAL_NGINX
TEST_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TEST_DIR}"' EXIT
mkdir "${TEST_DIR}/bin"
export NGINX_CONF_PATH="${TEST_DIR}/nginx.conf"
export NGINX_SYSTEMD_DROP_IN="${TEST_DIR}/limits.conf"
export SERVICE_LOG="${TEST_DIR}/service.log"
export FAIL_MARKER="${TEST_DIR}/fail-restart"
export PATH="${TEST_DIR}/bin:${PATH}"

cat > "${TEST_DIR}/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SERVICE_LOG"
if [[ "$*" == 'restart nginx' && -f "$FAIL_MARKER" ]]; then
  rm "$FAIL_MARKER"
  exit 1
fi
EOF
chmod +x "${TEST_DIR}/bin/systemctl"

fixture() {
  cat > "${NGINX_CONF_PATH}" <<EOF
error_log stderr;
pid ${TEST_DIR}/nginx.pid;
worker_processes 1; # retain this comment
events {
    worker_connections 768;
    multi_accept off;
}
http {
    server {
        listen 127.0.0.1:18080;
        location / { return 200 'kept {content}'; }
    }
}
EOF
}
tune() {
  bash "${PROJECT_DIR}/scripts/tune-nginx-limits.sh" "$@" > "${TEST_DIR}/output.log" 2>&1
}
fail() { cat "${TEST_DIR}/output.log" >&2; printf 'FAIL: %s\n' "$*" >&2; exit 1; }

fixture
tune || fail 'initial application'
grep -Fq 'worker_processes auto; # retain this comment' "${NGINX_CONF_PATH}"
grep -Fq 'worker_connections 65536;' "${NGINX_CONF_PATH}"
grep -Fq 'worker_rlimit_nofile 131072;' "${NGINX_CONF_PATH}"
grep -Fq "location / { return 200 'kept {content}'; }" "${NGINX_CONF_PATH}"
grep -Fxq 'LimitNOFILE=131072' "${NGINX_SYSTEMD_DROP_IN}"
grep -Fxq 'restart nginx' "${SERVICE_LOG}"
compgen -G "${NGINX_CONF_PATH}.bak-*" >/dev/null
cp "${SERVICE_LOG}" "${TEST_DIR}/before.log"
tune || fail 'repeated application'
cmp "${SERVICE_LOG}" "${TEST_DIR}/before.log" || fail 'repeat restarted service'

tune 32768 131072 || fail 'connections-only application'
[[ "$(tail -n 1 "${SERVICE_LOG}")" == 'reload nginx' ]] || fail 'expected reload'

cp "${NGINX_CONF_PATH}" "${TEST_DIR}/before.conf"
if tune 131072 131072; then fail 'accepted invalid limits'; fi
cmp "${NGINX_CONF_PATH}" "${TEST_DIR}/before.conf"

# An included directive cannot safely be overwritten in the main file. Real
# nginx detects the duplicate after the edit, and the script must roll back.
fixture
printf 'worker_rlimit_nofile 4096;\n' > "${TEST_DIR}/included.conf"
printf 'include %s/included.conf;\n' "${TEST_DIR}" >> "${NGINX_CONF_PATH}"
cp "${NGINX_CONF_PATH}" "${TEST_DIR}/before.conf"
cp "${SERVICE_LOG}" "${TEST_DIR}/before.log"
if tune; then fail 'accepted duplicate included directive'; fi
cmp "${NGINX_CONF_PATH}" "${TEST_DIR}/before.conf" || fail 'syntax failure rollback'
cmp "${SERVICE_LOG}" "${TEST_DIR}/before.log" || fail 'service touched on syntax failure'

# Rollback must restore the target of a symlink and a previous systemd drop-in.
fixture
mv "${NGINX_CONF_PATH}" "${TEST_DIR}/target.conf"
ln -s "${TEST_DIR}/target.conf" "${NGINX_CONF_PATH}"
printf '[Service]\nLimitNOFILE=4096\n' > "${NGINX_SYSTEMD_DROP_IN}"
cp "${NGINX_CONF_PATH}" "${TEST_DIR}/before.conf"
cp "${NGINX_SYSTEMD_DROP_IN}" "${TEST_DIR}/before-drop-in.conf"
touch "${FAIL_MARKER}"
if tune; then fail 'ignored restart failure'; fi
[[ -L "${NGINX_CONF_PATH}" ]] || fail 'lost configuration symlink'
cmp "${NGINX_CONF_PATH}" "${TEST_DIR}/before.conf" || fail 'restart failure config rollback'
cmp "${NGINX_SYSTEMD_DROP_IN}" "${TEST_DIR}/before-drop-in.conf" || fail 'drop-in rollback'

# Missing main directives and worker_connections should be inserted once.
awk '!/worker_processes|worker_connections/' "${TEST_DIR}/before.conf" > "${TEST_DIR}/target.conf"
tune || fail 'missing directives'
"${REAL_NGINX}" -t -c "${NGINX_CONF_PATH}"
printf 'PASS: Nginx limits, real syntax validation, idempotence, reload, validation and rollback\n'
