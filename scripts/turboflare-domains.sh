#!/usr/bin/env bash
# Shared by render.sh and install.sh. The caller provides die().
parse_turboflare_domains() {
  local remaining="${DOMAIN:-}" domain normalized
  local -A seen=()
  TURBOFLARE_DOMAINS=()
  while :; do
    domain="${remaining%%,*}"
    # Allow whitespace around comma-separated names, but never inside a name.
    domain="${domain#"${domain%%[![:space:]]*}"}"
    domain="${domain%"${domain##*[![:space:]]}"}"
    [[ -n "${domain}" ]] || die "DOMAIN contains an empty domain"
    [[ ${#domain} -le 253 && "${domain}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] \
      || die "DOMAIN contains an invalid domain: ${domain}"
    normalized="${domain,,}"
    [[ -z "${seen[${normalized}]:-}" ]] || die "Duplicate domain in DOMAIN: ${domain}"
    seen["${normalized}"]=1
    TURBOFLARE_DOMAINS+=("${domain}")
    [[ "${remaining}" == *,* ]] || break
    remaining="${remaining#*,}"
  done
  # Keep the first domain stable when adding aliases to an existing deployment.
  TURBOFLARE_PRIMARY_DOMAIN="${TURBOFLARE_DOMAINS[0]}"
}
