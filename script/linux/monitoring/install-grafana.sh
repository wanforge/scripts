#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-grafana.sh — Install, optimize, and manage Grafana Observability Dashboard.
#
# Features:
#   - Official Grafana APT repository setup with modern gpg keyrings
#   - Automated Prometheus data source provisioning (http://localhost:9090 default)
#   - Automated Node Exporter Full dashboard provisioning (ID 1860) with datasource auto-binding
#   - Reverse Proxy setup helper for CloudPanel / Nginx / Caddy (/etc/grafana/grafana.ini domain & root_url)
#   - One-click Admin password reset via grafana-cli
#   - Multi-firewall support (UFW & Firewalld port 3000/tcp)
#   - Service status audit, port inspection, and provisioning diagnostics
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/monitoring/install-grafana.sh | bash
#   ./install-grafana.sh status
#   ./install-grafana.sh proxy [domain]
#   ./install-grafana.sh reset-pass [newpass]
#   ./install-grafana.sh install
#   ./install-grafana.sh --uninstall
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-grafana"

# --- shared library ------------------------------------------------------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if   [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
elif [ -r "${__d}/lib.sh" ]; then . "${__d}/lib.sh"
elif [ -n "${WF_INSTALL_DIR:-}" ] && [ -r "${WF_INSTALL_DIR}/lib.sh" ]; then . "${WF_INSTALL_DIR}/lib.sh"
elif [ -r "/opt/wanforge-scripts/lib.sh" ]; then . "/opt/wanforge-scripts/lib.sh"
elif [ -r "${HOME:-}/.local/lib/wanforge-scripts/lib.sh" ]; then . "${HOME}/.local/lib/wanforge-scripts/lib.sh"
elif command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}")
else . <(wget -qO- "${__LIB}"); fi
cfg_load
wf_log_init

SUDO=""
[ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

GRAFANA_INI="/etc/grafana/grafana.ini"

fw_allow_3000() {
  local cidr="${1:-0.0.0.0/0}"
  if command -v ufw >/dev/null 2>&1 && ${SUDO} ufw status 2>/dev/null | grep -qi "Status: active"; then
    if [ "${cidr}" = "0.0.0.0/0" ]; then
      run ${SUDO} ufw allow 3000/tcp comment "Grafana Web UI"
    else
      run ${SUDO} ufw allow from "${cidr}" to any port 3000 proto tcp comment "Grafana Web UI"
    fi
    ok "UFW: Port 3000/tcp allowed (source: ${cidr})."
  elif command -v firewall-cmd >/dev/null 2>&1 && ${SUDO} firewall-cmd --state >/dev/null 2>&1; then
    run ${SUDO} firewall-cmd --permanent --add-port=3000/tcp
    run ${SUDO} firewall-cmd --reload
    ok "Firewalld: Port 3000/tcp opened."
  else
    if command -v ufw >/dev/null 2>&1; then
      run ${SUDO} ufw allow 3000/tcp comment "Grafana Web UI"
      ok "UFW rule added (firewall inactive)."
    else
      info "No active UFW or Firewalld found. Ensure port 3000 is open in your cloud firewall."
    fi
  fi
}

# --- Action: Status & Audit -----------------------------------------------
a_status() {
  hd "Grafana Service & Provisioning Audit"

  if ! command -v grafana-server >/dev/null 2>&1; then
    warn "Grafana binary 'grafana-server' not found in PATH."
    info "Run the installer to set up Grafana."
    return 1
  fi

  local g_ver
  g_ver="$(grafana-server -v 2>/dev/null | head -1 || echo 'Grafana')"
  ok "Version: ${g_ver}"

  local svc_st="inactive"
  if command -v systemctl >/dev/null 2>&1; then
    svc_st="$(systemctl is-active grafana-server 2>/dev/null || echo 'inactive')"
  fi

  printf "\n%bService Status:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  if [ "${svc_st}" = "active" ]; then
    ok "grafana-server : Active & Running"
  else
    warn "grafana-server : ${svc_st}"
  fi

  printf "\n%bPort 3000 Listener:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  if command -v ss >/dev/null 2>&1; then
    local p3000; p3000="$(ss -tlnp 2>/dev/null | grep ':3000' || true)"
    if [ -n "${p3000}" ]; then
      ok "Port 3000 listening: ${p3000}"
    else
      warn "Port 3000 is NOT listening. Service might be starting or failed."
    fi
  fi

  printf "\n%bProvisioned Datasources:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  if [ -d /etc/grafana/provisioning/datasources ]; then
    local ds_count=0
    for f in /etc/grafana/provisioning/datasources/*.yml /etc/grafana/provisioning/datasources/*.yaml; do
      [ -f "$f" ] || continue
      local ds_name; ds_name="$(grep -E '^\s*- name:' "$f" | awk '{print $NF}' | tr -d '"' || basename "$f")"
      local ds_url; ds_url="$(grep -E '^\s*url:' "$f" | awk '{print $NF}' | tr -d '"' || '')"
      printf "  • %b%-18s%b -> %s (%s)\n" "${C_BOLD}" "${ds_name}" "${C_RESET}" "${ds_url}" "$(basename "$f")"
      ds_count=$(( ds_count + 1 ))
    done
    [ "${ds_count}" -eq 0 ] && info "  No datasources currently provisioned."
  else
    info "  No provisioning directory found."
  fi

  printf "\n%bProvisioned Dashboards:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  if [ -d /var/lib/grafana/dashboards ]; then
    local d_count=0
    for f in /var/lib/grafana/dashboards/*.json; do
      [ -f "$f" ] || continue
      printf "  • %b%s%b\n" "${C_BOLD}" "$(basename "$f")" "${C_RESET}"
      d_count=$(( d_count + 1 ))
    done
    [ "${d_count}" -eq 0 ] && info "  No dashboard JSON files present in /var/lib/grafana/dashboards."
  else
    info "  Dashboard directory /var/lib/grafana/dashboards does not exist yet."
  fi

  printf "\n%bReverse Proxy Domain in config:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  if [ -f "${GRAFANA_INI}" ]; then
    local r_url; r_url="$(grep -E '^[[:space:]]*root_url[[:space:]]*=' "${GRAFANA_INI}" | head -1 || echo '')"
    if [ -n "${r_url}" ]; then
      ok "${r_url}"
    else
      info "Default standalone root_url (no custom reverse proxy root_url set)."
    fi
  fi
  printf "\n"
}

# --- Action: Configure Reverse Proxy Domain -------------------------------
a_proxy() {
  hd "Configure Grafana Reverse Proxy Domain"

  if [ ! -f "${GRAFANA_INI}" ]; then
    err "${GRAFANA_INI} not found. Please install Grafana first."
    return 1
  fi

  local domain="${1:-}"
  if [ -z "${domain}" ]; then
    domain="$(ask "Enter your public domain for Grafana (e.g. grafana.example.com):" "")"
  fi
  domain="$(echo "${domain}" | sed -E 's|^https?://||; s|/.*$||; s/^[[:space:]]+//; s/[[:space:]]+$//')"

  if [ -z "${domain}" ]; then
    warn "No domain provided. Skipping proxy setup."
    return 0
  fi

  local proto="https"
  if ask_yn "Is TLS/SSL terminated on your reverse proxy (HTTPS)?" "y"; then
    proto="https"
  else
    proto="http"
  fi

  sub "Backing up ${GRAFANA_INI}..."
  run ${SUDO} cp -b "${GRAFANA_INI}" "${GRAFANA_INI}.bak.$(date +%s)"

  sub "Updating server settings in ${GRAFANA_INI}..."
  # Set domain
  if grep -qE '^[#;]?[[:space:]]*domain[[:space:]]*=' "${GRAFANA_INI}"; then
    run ${SUDO} sed -i "s|^[#;]*[[:space:]]*domain[[:space:]]*=.*|domain = ${domain}|" "${GRAFANA_INI}"
  fi
  # Set root_url
  if grep -qE '^[#;]?[[:space:]]*root_url[[:space:]]*=' "${GRAFANA_INI}"; then
    run ${SUDO} sed -i "s|^[#;]*[[:space:]]*root_url[[:space:]]*=.*|root_url = ${proto}://${domain}/|" "${GRAFANA_INI}"
  fi

  sub "Restarting grafana-server..."
  run ${SUDO} systemctl restart grafana-server || true
  ok "Grafana configured for reverse proxy: ${proto}://${domain}/"
}

# --- Action: Reset Admin Password -----------------------------------------
a_reset_pass() {
  hd "Reset Grafana Admin Password"

  if ! command -v grafana-cli >/dev/null 2>&1; then
    err "grafana-cli binary not found."
    return 1
  fi

  local new_pass="${1:-}"
  if [ -z "${new_pass}" ]; then
    new_pass="$(asks "Enter new password for 'admin' user:")"
  fi

  if [ -z "${new_pass}" ]; then
    err "Password cannot be empty."
    return 1
  fi

  sub "Resetting admin password via grafana-cli..."
  if run ${SUDO} grafana-cli admin reset-admin-password "${new_pass}"; then
    ok "Admin password reset successfully."
  else
    err "Failed to reset password via grafana-cli."
    return 1
  fi
}

# --- Action: Provision Prometheus Datasource ------------------------------
a_provision_datasource() {
  local purl="${1:-http://localhost:9090}"
  sub "Provisioning Prometheus datasource (${purl})..."
  run ${SUDO} mkdir -p /etc/grafana/provisioning/datasources
  local tmp_ds; tmp_ds="$(mktemp)"
  cat > "${tmp_ds}" <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: ${purl}
    isDefault: true
    jsonData:
      timeInterval: 15s
EOF
  run ${SUDO} cp -f "${tmp_ds}" /etc/grafana/provisioning/datasources/prometheus.yml
  run ${SUDO} chown -R root:grafana /etc/grafana/provisioning/datasources 2>/dev/null || true
  rm -f "${tmp_ds}"
  ok "Prometheus datasource provisioned."
}

# --- Action: Provision Node Exporter Dashboard ----------------------------
a_provision_dashboard() {
  sub "Provisioning Node Exporter Full dashboard (ID 1860)..."
  run ${SUDO} mkdir -p /etc/grafana/provisioning/dashboards
  run ${SUDO} mkdir -p /var/lib/grafana/dashboards

  local tmp_dash_conf; tmp_dash_conf="$(mktemp)"
  cat > "${tmp_dash_conf}" <<EOF
apiVersion: 1
providers:
  - name: "default"
    orgId: 1
    folder: ""
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    options:
      path: /var/lib/grafana/dashboards
EOF
  run ${SUDO} cp -f "${tmp_dash_conf}" /etc/grafana/provisioning/dashboards/node-exporter.yaml
  rm -f "${tmp_dash_conf}"

  local tmp_json; tmp_json="$(mktemp)"
  if curl -4 -fsSL "https://grafana.com/api/dashboards/1860/revisions/latest/download" -o "${tmp_json}" 2>/dev/null || \
     wget -qO "${tmp_json}" "https://grafana.com/api/dashboards/1860/revisions/latest/download" 2>/dev/null; then
    # Bind datasource inputs cleanly to "Prometheus"
    sed -i 's/\${DS_PROMETHEUS}/Prometheus/g' "${tmp_json}"
    run ${SUDO} cp -f "${tmp_json}" /var/lib/grafana/dashboards/node-exporter.json
    run ${SUDO} chown -R grafana:grafana /etc/grafana/provisioning/dashboards /var/lib/grafana/dashboards 2>/dev/null || true
    ok "Node Exporter dashboard provisioned."
  else
    warn "Could not download dashboard 1860 JSON from grafana.com. You can import ID 1860 manually in the web UI."
  fi
  rm -f "${tmp_json}"
}

# --- Action: Install Full Suite -------------------------------------------
a_install() {
  hd "Install & Optimize Grafana"

  if ! command -v apt-get >/dev/null 2>&1; then
    err "This script currently targets Debian/Ubuntu systems with APT."
    return 1
  fi

  sub "Installing prerequisites..."
  run ${SUDO} apt-get install -y apt-transport-https software-properties-common wget gpg curl

  sub "Configuring official Grafana repository keyrings..."
  run ${SUDO} mkdir -p /etc/apt/keyrings
  wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor 2>/dev/null | run ${SUDO} tee /etc/apt/keyrings/grafana.gpg >/dev/null
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    | run ${SUDO} tee /etc/apt/sources.list.d/grafana.list >/dev/null

  sub "Updating package index and installing grafana..."
  run ${SUDO} apt-get update
  run ${SUDO} apt-get install -y grafana

  sub "Enabling and starting grafana-server..."
  run ${SUDO} systemctl enable grafana-server
  run ${SUDO} systemctl restart grafana-server || true

  # Auto-add Prometheus data source
  if ask_yn "Auto-provision local Prometheus data source (http://localhost:9090)?" "y"; then
    local p_url; p_url="$(ask "Prometheus URL:" "http://localhost:9090")"
    a_provision_datasource "${p_url}"
    if ask_yn "Auto-provision Node Exporter dashboard (ID 1860)?" "y"; then
      a_provision_dashboard
    fi
    run ${SUDO} systemctl restart grafana-server || true
  fi

  # Reverse proxy setup
  if ask_yn "Configure a custom reverse proxy domain for Grafana now?" "n"; then
    a_proxy
  fi

  # Firewall port
  if ask_yn "Open port 3000/tcp in the system firewall?" "y"; then
    local cidr; cidr="$(ask "Allow from which source CIDR? ('0.0.0.0/0'=anywhere):" "0.0.0.0/0")"
    fw_allow_3000 "${cidr}"
  fi

  local ip; ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<server-ip>')"
  printf "\n%b=================================================================%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
  printf "%b✔ GRAFANA INSTALLED & READY%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
  printf "  • Web UI URL         : %bhttp://%s:3000%b\n" "${C_BOLD}${C_CYAN}" "${ip}" "${C_RESET}"
  printf "  • Default Login      : %badmin%b / %badmin%b (prompts for new password)\n" "${C_BOLD}" "${C_RESET}" "${C_BOLD}" "${C_RESET}"
  printf "  • Quick Pass Reset   : %b./install-grafana.sh reset-pass%b\n" "${C_YELLOW}" "${C_RESET}"
  printf "  • Reverse Proxy CLI  : %b./install-grafana.sh proxy <domain>%b\n" "${C_YELLOW}" "${C_RESET}"
  printf "%b=================================================================%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
}

# --- Action: Uninstall ----------------------------------------------------
a_uninstall() {
  hd "Uninstall Grafana"
  warn "This will stop Grafana, remove packages, APT repositories, and configuration."
  local yn; yn="$(ask "Remove Grafana completely? [y/N]:" "n")"
  case "${yn}" in y|Y|yes) ;; *) info "Cancelled."; return 0 ;; esac

  sub "Stopping and disabling grafana-server..."
  run ${SUDO} systemctl stop grafana-server 2>/dev/null || true
  run ${SUDO} systemctl disable grafana-server 2>/dev/null || true

  sub "Purging Grafana packages..."
  run ${SUDO} apt-get purge -y grafana 2>/dev/null || true
  run ${SUDO} apt-get autoremove -y

  sub "Removing APT repository and keyrings..."
  run ${SUDO} rm -f /etc/apt/sources.list.d/grafana.list /etc/apt/keyrings/grafana.gpg
  run ${SUDO} apt-get update 2>/dev/null || true

  if command -v ufw >/dev/null 2>&1; then
    run ${SUDO} ufw delete allow 3000/tcp 2>/dev/null || true
  elif command -v firewall-cmd >/dev/null 2>&1; then
    run ${SUDO} firewall-cmd --permanent --remove-port=3000/tcp 2>/dev/null || true
    run ${SUDO} firewall-cmd --reload 2>/dev/null || true
  fi

  ok "Grafana removed."
}

# --- CLI Dispatch ---------------------------------------------------------
wf_svc_dispatch "${1:-}" "Grafana" "grafana" grafana-server && exit $?
case "${1:-}" in
  status|audit)
    a_status; exit $?
    ;;
  install)
    a_install; exit $?
    ;;
  proxy)
    a_proxy "${2:-}"; exit $?
    ;;
  reset-pass|reset-password)
    a_reset_pass "${2:-}"; exit $?
    ;;
  --uninstall|uninstall)
    a_uninstall; exit $?
    ;;
esac

# --- Interactive Main Menu ------------------------------------------------
banner
MENU=(
  "Status|status|Audit Grafana Status, Port 3000 & Provisioned Dashboards"
  "Install|install|Install Grafana from Official Repo & Auto-Provision Prometheus"
  "Proxy|proxy|Configure Reverse Proxy Domain (/etc/grafana/grafana.ini)"
  "Security|reset-pass|Reset Grafana 'admin' User Password"
  "Remove|uninstall|Uninstall Grafana & Clean Repository"
)

while true; do
  if menu_select "Grafana Observability Dashboard:"; then
    case "${MENU_KEY}" in
      status)     a_status; pause ;;
      install)    a_install; pause ;;
      proxy)      a_proxy; pause ;;
      reset-pass) a_reset_pass; pause ;;
      uninstall)  a_uninstall; pause ;;
      *) break ;;
    esac
  else
    break
  fi
done

ok "Script install-grafana completed."
