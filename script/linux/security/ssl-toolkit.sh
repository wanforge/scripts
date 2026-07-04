#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# ssl-toolkit.sh — inspect remote certificates, parse local cert files,
# generate modern SAN self-signed certs, debug TLS handshakes, and install Certbot.
# Linux.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/security/ssl-toolkit.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="ssl-toolkit"

# --- shared library ------------------------------------------------------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load
wf_log_init

have() { command -v "$1" >/dev/null 2>&1; }

parse_cert_block() {
  local input="$1"
  if [ -z "${input}" ]; then
    err "No certificate data provided."
    return 1
  fi
  
  local issuer; issuer=$(echo "${input}" | openssl x509 -noout -issuer | sed 's/issuer=//')
  local subject; subject=$(echo "${input}" | openssl x509 -noout -subject | sed 's/subject=//')
  local validity; validity=$(echo "${input}" | openssl x509 -noout -dates)
  local sans; sans=$(echo "${input}" | openssl x509 -noout -ext subjectAltName 2>/dev/null || echo "")
  local serial; serial=$(echo "${input}" | openssl x509 -noout -serial | sed 's/serial=//')
  
  info "Certificate Metadata:"
  info "  Subject:       ${subject}"
  info "  Issuer:        ${issuer}"
  info "  Serial Number: ${serial}"
  echo "${validity}" | while read -r line; do info "  ${line}"; done
  
  if [ -n "${sans// /}" ]; then
    info "  SANs:          $(echo "${sans}" | grep -v "Subject Alternative Name" | tr -d '\n' | xargs)"
  fi
  
  # Check if expired
  local end_date; end_date=$(echo "${validity}" | grep "notAfter" | cut -d= -f2)
  local end_epoch; end_epoch=$(date -d "${end_date}" +%s 2>/dev/null || echo 0)
  if [ "${end_epoch}" -gt 0 ]; then
    local now_epoch; now_epoch=$(date +%s)
    local diff; diff=$(( (end_epoch - now_epoch) / 86400 ))
    if [ "${diff}" -lt 0 ]; then
      err "  STATUS:        EXPIRED (${diff#-} days ago) ❌"
    elif [ "${diff}" -lt 30 ]; then
      warn "  STATUS:        Expiring in ${diff} days! ⚠️"
    else
      ok "  STATUS:        Valid for another ${diff} days. (Expires: ${end_date}) ✔"
    fi
  fi
}

a_inspect_remote() {
  hd "Inspect Remote SSL Certificate"
  local domain; domain="$(ask "Enter remote domain (e.g. google.com):" "")"
  [ -n "${domain}" ] || { warn "Cancelled."; return; }
  local port; port="$(ask "Enter port:" "443")"
  
  step "Connecting to ${domain}:${port} via SSL..."
  local cert; cert=$(echo | openssl s_client -connect "${domain}:${port}" -servername "${domain}" 2>/dev/null || echo "")
  
  if [ -n "${cert}" ]; then
    parse_cert_block "${cert}"
  else
    err "Failed to connect to ${domain}:${port} via SSL."
  fi
}

a_inspect_local() {
  hd "Inspect Local Certificate File"
  local path; path="$(ask "Enter path to certificate file (.crt / .pem):" "")"
  [ -n "${path}" ] || { warn "Cancelled."; return; }
  [ -f "${path}" ] || { err "File not found: ${path}"; return; }
  
  step "Parsing local certificate file ${path}"
  local cert; cert=$(cat "${path}")
  parse_cert_block "${cert}"
}

a_generate_self_signed() {
  hd "Generate Modern Self-Signed Certificate"
  local domain; domain="$(ask "Enter primary domain (e.g. app.test or localhost):" "localhost")"
  local days; days="$(ask "Valid days:" "365")"
  
  step "Creating OpenSSL configuration with SANs"
  local cnf; cnf="$(mktemp)"
  cat <<EOF > "${cnf}"
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = ${domain}

[v3_req]
keyUsage = keyEncipherment, dataEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${domain}
DNS.2 = *.${domain}
EOF

  step "Generating private key & certificate"
  openssl req -x509 -nodes -days "${days}" -newkey rsa:2048 \
    -keyout "${domain}.key" -out "${domain}.crt" -config "${cnf}" 2>/dev/null
  
  rm -f "${cnf}"
  ok "Generated self-signed certificate files:"
  info "  Private Key: $(pwd)/${domain}.key"
  info "  Certificate: $(pwd)/${domain}.crt"
}

a_debug_handshake() {
  hd "SSL Handshake Debugger"
  local domain; domain="$(ask "Enter domain to test (e.g. google.com):" "")"
  [ -n "${domain}" ] || { warn "Cancelled."; return; }
  
  step "Testing supported TLS protocol versions"
  for version in tls1 tls1_1 tls1_2 tls1_3; do
    if echo | openssl s_client -connect "${domain}:443" -servername "${domain}" -${version} >/dev/null 2>&1; then
      ok "  ${version}: SUPPORTED"
    else
      info "  ${version}: NOT supported"
    fi
  done
  
  step "Verifying SSL handshake via curl"
  if have curl; then
    curl -Iv "https://${domain}" 2>&1 | grep -E "^\* (TLS|SSL|ALPN|handshake|issuer|subject|start date|expire date|common name|PEM)" || true
  else
    warn "curl not installed; skipping verbose validation."
  fi
}

a_install_certbot() {
  hd "Install Certbot (Let's Encrypt)"
  step "Updating package index & installing Certbot"
  run ${SUDO} apt-get update
  run ${SUDO} apt-get install -y certbot python3-certbot-nginx
  ok "Certbot and Nginx plugin installed successfully."
  info "To generate certificates, run: certbot --nginx -d yourdomain.com"
}

# --- interactive menu ------------------------------------------------------
banner
while true; do
  MENU=(
    "Action|inspect_remote|Inspect remote SSL certificate (domain:port)"
    "Action|inspect_local|Inspect local certificate file (.crt/.pem)"
    "Action|self_signed|Generate self-signed certificate (RSA + SAN)"
    "Action|debug_tls|Debug SSL handshake & check TLS versions"
    "Action|certbot|Install Certbot & Nginx plugin"
  )
  printf "\n" >&2
  menu_select "SSL/TLS Diagnostics & Management Toolkit:" || break
  case "${MENU_KEY}" in
    inspect_remote) a_inspect_remote; pause ;;
    inspect_local) a_inspect_local; pause ;;
    self_signed) a_generate_self_signed; pause ;;
    debug_tls) a_debug_handshake; pause ;;
    certbot) a_install_certbot; pause ;;
  esac
done

printf "\n%b✔ ssl-toolkit finished.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
