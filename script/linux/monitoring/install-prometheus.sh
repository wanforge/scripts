#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-prometheus.sh — Prometheus + node_exporter (+ Alertmanager)
# Multi-component installation, alerting rules, integrations, and health audit. Debian/Ubuntu.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/monitoring/install-prometheus.sh | bash
#   ./install-prometheus.sh status
#   ./install-prometheus.sh install
#   ./install-prometheus.sh rules
#   ./install-prometheus.sh alertmanager
#   ./install-prometheus.sh --uninstall
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-prometheus"

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

CFG="/etc/prometheus/prometheus.yml"
RULES_CFG="/etc/prometheus/alert.rules.yml"
AM_CFG="/etc/prometheus/alertmanager.yml"

svc_enable_start() {
  local s="$1"
  if command -v systemctl >/dev/null 2>&1; then
    run ${SUDO} systemctl enable "$s" >/dev/null 2>&1 || true
    run ${SUDO} systemctl restart "$s" || run ${SUDO} systemctl start "$s" || true
  fi
}

fw_allow() { # fw_allow <port> <cidr> <label>
  local port="$1"
  local cidr="${2:-0.0.0.0/0}"
  local label="${3:-Prometheus}"

  if command -v ufw >/dev/null 2>&1 && ${SUDO} ufw status 2>/dev/null | grep -qi "Status: active"; then
    if [ "${cidr}" = "0.0.0.0/0" ]; then
      run ${SUDO} ufw allow "${port}/tcp" comment "${label}"
    else
      run ${SUDO} ufw allow from "${cidr}" to any port "${port}" proto tcp comment "${label}"
    fi
    ok "UFW: Port ${port}/tcp opened (${cidr})."
  elif command -v firewall-cmd >/dev/null 2>&1 && ${SUDO} firewall-cmd --state >/dev/null 2>&1; then
    run ${SUDO} firewall-cmd --permanent --add-port="${port}/tcp"
    run ${SUDO} firewall-cmd --reload
    ok "Firewalld: Port ${port}/tcp opened."
  else
    if command -v ufw >/dev/null 2>&1; then
      run ${SUDO} ufw allow "${port}/tcp" comment "${label}"
      ok "UFW rule added (firewall inactive)."
    else
      info "No active firewall found. Ensure port ${port} is opened in your cloud firewall."
    fi
  fi
}

# --- Action: Status & Audit -----------------------------------------------
a_status() {
  hd "Prometheus & Exporter Stack Audit"

  local prom_bin; prom_bin="$(command -v prometheus || echo '')"
  local node_bin; node_bin="$(command -v prometheus-node-exporter || echo '')"
  local am_bin; am_bin="$(command -v prometheus-alertmanager || echo '')"

  if [ -z "${prom_bin}" ] && [ -z "${node_bin}" ]; then
    warn "Prometheus or node_exporter are not installed on this system."
    info "Run the installer to set up the metrics stack."
    return 1
  fi

  printf "\n%bService Statuses:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  for s in prometheus prometheus-node-exporter prometheus-alertmanager; do
    if systemctl list-unit-files "${s}.service" >/dev/null 2>&1; then
      local st; st="$(systemctl is-active "$s" 2>/dev/null || echo 'inactive')"
      if [ "${st}" = "active" ]; then
        ok "%-26s : Active & Running" "${s}"
      else
        warn "%-26s : %s" "${s}" "${st}"
      fi
    fi
  done

  printf "\n%bPort Listeners:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  if command -v ss >/dev/null 2>&1; then
    for p in 9090 9100 9093; do
      local p_out; p_out="$(ss -tlnp 2>/dev/null | grep ":${p}\b" || true)"
      if [ -n "${p_out}" ]; then
        ok "Port %-4s : %s" "${p}" "${p_out}"
      else
        info "Port %-4s : Not listening" "${p}"
      fi
    done
  fi

  printf "\n%bScrape Targets (%s):%b\n" "${C_BOLD}${C_CYAN}" "${CFG}" "${C_RESET}"
  if [ -f "${CFG}" ]; then
    grep -E 'job_name:|targets:' "${CFG}" | sed 's/^/  /' || info "  No scrape jobs found."
  else
    info "  Config ${CFG} not present."
  fi

  printf "\n%bAlerting Rules (%s):%b\n" "${C_BOLD}${C_CYAN}" "${RULES_CFG}" "${C_RESET}"
  if [ -f "${RULES_CFG}" ]; then
    grep -E 'alert:' "${RULES_CFG}" | sed 's/^/  • /' || info "  No rules found."
  else
    info "  No rules file found at ${RULES_CFG}."
  fi
  printf "\n"
}

# --- Action: Provision Default Alert Rules --------------------------------
a_rules() {
  hd "Configure Prometheus Alerting Rules"

  if [ ! -f "${CFG}" ]; then
    err "Prometheus config ${CFG} not found. Please install Prometheus first."
    return 1
  fi

  sub "Writing production alert rules to ${RULES_CFG}..."
  run ${SUDO} mkdir -p /etc/prometheus
  local tmp_rules; tmp_rules="$(mktemp)"
  cat > "${tmp_rules}" <<'EOF'
groups:
  - name: system_alerts
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Instance {{ $labels.instance }} down"
          description: "Instance {{ $labels.instance }} has been unreachable for more than 1 minute."

      - alert: HostCpuHigh
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Host CPU high (instance {{ $labels.instance }})
          description: "CPU usage is above 85% (current: {{ $value }}%)"

      - alert: HostOutOfMemory
        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 90
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Host Out of Memory (instance {{ $labels.instance }})"
          description: "Memory usage is above 90% (current: {{ $value }}%)"

      - alert: HostDiskSpaceLow
        expr: (node_filesystem_free_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100 < 15
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Host Disk Space Low (instance {{ $labels.instance }})"
          description: "Root partition disk free is below 15% (current free: {{ $value }}%)"
EOF
  run ${SUDO} cp -f "${tmp_rules}" "${RULES_CFG}"
  run ${SUDO} chmod 644 "${RULES_CFG}"
  rm -f "${tmp_rules}"

  # Link rules in prometheus.yml if not already linked
  if ! ${SUDO} grep -q "alert.rules.yml" "${CFG}" 2>/dev/null; then
    sub "Linking ${RULES_CFG} into ${CFG}..."
    if ${SUDO} grep -q "^rule_files:" "${CFG}" 2>/dev/null; then
      run ${SUDO} sed -i '/^rule_files:/a \  - "/etc/prometheus/alert.rules.yml"' "${CFG}"
    else
      printf "\nrule_files:\n  - \"/etc/prometheus/alert.rules.yml\"\n" | run ${SUDO} tee -a "${CFG}" >/dev/null
    fi
  fi

  sub "Validating & restarting Prometheus..."
  run ${SUDO} systemctl restart prometheus || true
  ok "Alert rules configured and active."
}

# --- Action: Alertmanager Integration -------------------------------------
a_alertmanager_integration() {
  hd "Configure Alertmanager Notifications"

  if [ ! -f "${AM_CFG}" ]; then
    err "Alertmanager config ${AM_CFG} not found. Please install Alertmanager first."
    return 1
  fi

  MENU=(
    "Telegram|telegram|Telegram Bot (Token & Chat ID)"
    "Discord|discord|Discord Webhook (URL)"
    "Slack|slack|Slack Webhook (URL)"
    "Email|email|SMTP Email Notifications"
    "Webhook|webhook|Generic JSON Webhook"
  )

  menu_select "Select Alertmanager Notification Channel:" || return 0
  local chan="${MENU_KEY}"
  local tmp_am; tmp_am="$(mktemp)"

  case "${chan}" in
    telegram)
      local token; token="$(ask "Telegram Bot Token:" "")"
      local chat_id; chat_id="$(ask "Telegram Chat ID (e.g. -100... or user ID):" "")"
      [ -z "${token}" ] || [ -z "${chat_id}" ] && { err "Token and Chat ID required."; rm -f "${tmp_am}"; return 1; }
      cat > "${tmp_am}" <<EOF
global:
  resolve_timeout: 5m
route:
  group_by: ['alertname']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'telegram-alerts'
receivers:
  - name: 'telegram-alerts'
    telegram_configs:
      - bot_token: '${token}'
        chat_id: ${chat_id}
        send_resolved: true
EOF
      ;;
    discord|slack)
      local url; url="$(ask "Webhook URL:" "")"
      [ -z "${url}" ] && { err "Webhook URL required."; rm -f "${tmp_am}"; return 1; }
      if [[ "${url}" == *"discord.com/api/webhooks"* ]] && [[ "${url}" != */slack ]]; then
        url="${url}/slack"
      fi
      cat > "${tmp_am}" <<EOF
global:
  resolve_timeout: 5m
route:
  group_by: ['alertname']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'slack-alerts'
receivers:
  - name: 'slack-alerts'
    slack_configs:
      - api_url: '${url}'
        send_resolved: true
EOF
      ;;
    email)
      local smtp_host; smtp_host="$(ask "SMTP Server Host & Port (e.g. smtp.gmail.com:587):" "")"
      local smtp_from; smtp_from="$(ask "Sender Email (From):" "")"
      local smtp_user; smtp_user="$(ask "SMTP Username:" "")"
      local smtp_pass; smtp_pass="$(asks "SMTP Password:")"
      local smtp_to; smtp_to="$(ask "Recipient Email (To):" "")"
      [ -z "${smtp_host}" ] || [ -z "${smtp_to}" ] && { err "Host and Recipient required."; rm -f "${tmp_am}"; return 1; }
      cat > "${tmp_am}" <<EOF
global:
  resolve_timeout: 5m
  smtp_smarthost: '${smtp_host}'
  smtp_from: '${smtp_from}'
  smtp_auth_username: '${smtp_user}'
  smtp_auth_password: '${smtp_pass}'
  smtp_require_tls: true
route:
  group_by: ['alertname']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'email-alerts'
receivers:
  - name: 'email-alerts'
    email_configs:
      - to: '${smtp_to}'
        send_resolved: true
EOF
      ;;
    webhook)
      local wh_url; wh_url="$(ask "Webhook URL:" "")"
      [ -z "${wh_url}" ] && { err "URL required."; rm -f "${tmp_am}"; return 1; }
      cat > "${tmp_am}" <<EOF
global:
  resolve_timeout: 5m
route:
  group_by: ['alertname']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'custom-webhook'
receivers:
  - name: 'custom-webhook'
    webhook_configs:
      - url: '${wh_url}'
        send_resolved: true
EOF
      ;;
  esac

  sub "Backing up ${AM_CFG}..."
  run ${SUDO} cp -b "${AM_CFG}" "${AM_CFG}.bak.$(date +%s)"
  run ${SUDO} cp -f "${tmp_am}" "${AM_CFG}"
  run ${SUDO} chmod 644 "${AM_CFG}"
  rm -f "${tmp_am}"

  sub "Restarting prometheus-alertmanager..."
  run ${SUDO} systemctl restart prometheus-alertmanager || true
  ok "Alertmanager notification integration configured."
}

# --- Action: Install Full Suite -------------------------------------------
a_install() {
  hd "Install Prometheus & Observability Stack"

  if ! command -v apt-get >/dev/null 2>&1; then
    err "This script targets Debian/Ubuntu systems with APT."; return 1
  fi

  MENU=(
    "Core|prometheus|Prometheus Server (TSDB & PromQL Engine, Port 9090)"
    "Agent|node|Node Exporter (Host CPU, RAM, Disk, Network Metrics, Port 9100)"
    "Alerting|alertmanager|Alertmanager (Alert routing, Telegram, Discord, Email, Port 9093)"
    "Firewall|firewall|Configure system firewall (UFW / Firewalld rules)"
  )

  checkbox "Select components to install:" || { warn "Cancelled."; return 0; }
  [ "${#CHOSEN_KEYS[@]}" -eq 0 ] && { warn "Nothing selected."; return 0; }

  sub "Updating package list..."
  run ${SUDO} apt-get update

  local pkgs=""
  has_key prometheus   && pkgs="${pkgs} prometheus"
  has_key node         && pkgs="${pkgs} prometheus-node-exporter"
  has_key alertmanager && pkgs="${pkgs} prometheus-alertmanager"

  if [ -n "${pkgs# }" ]; then
    sub "Installing packages:${pkgs}..."
    run ${SUDO} apt-get install -y ${pkgs}
  fi

  has_key prometheus   && svc_enable_start prometheus
  has_key node         && svc_enable_start prometheus-node-exporter
  has_key alertmanager && svc_enable_start prometheus-alertmanager

  # Configure node_exporter scrape job in prometheus.yml
  if has_key prometheus && has_key node && [ -f "${CFG}" ]; then
    if ! ${SUDO} grep -qE "job_name:\s*'?node" "${CFG}" 2>/dev/null; then
      sub "Adding node_exporter scrape target to ${CFG}..."
      printf "\n  - job_name: 'node'\n    static_configs:\n      - targets: ['localhost:9100']\n" \
        | run ${SUDO} tee -a "${CFG}" >/dev/null
      run ${SUDO} systemctl restart prometheus || true
      ok "Added node scrape target."
    fi
  fi

  # Configure Alertmanager target in prometheus.yml
  if has_key prometheus && has_key alertmanager && [ -f "${CFG}" ]; then
    sub "Configuring Alertmanager target in ${CFG}..."
    run ${SUDO} sed -i 's/#\s*-\s*localhost:9093/-\ localhost:9093/g' "${CFG}" 2>/dev/null || true
    run ${SUDO} systemctl restart prometheus || true
  fi

  # Auto-provision system alert rules
  if has_key prometheus; then
    a_rules
  fi

  # Optional Alertmanager notification wizard
  if has_key alertmanager; then
    if ask_yn "Configure notification channel (Telegram/Discord/Email) now?" "n"; then
      a_alertmanager_integration
    fi
  fi

  # Firewall rules
  if has_key firewall; then
    local cidr; cidr="$(ask "Allow from source CIDR ('0.0.0.0/0'=anywhere):" "0.0.0.0/0")"
    has_key prometheus   && fw_allow 9090 "${cidr}" "Prometheus Server"
    has_key node         && fw_allow 9100 "${cidr}" "Node Exporter"
    has_key alertmanager && fw_allow 9093 "${cidr}" "Alertmanager"
  fi

  local ip; ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<server-ip>')"
  printf "\n%b=================================================================%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
  printf "%b✔ PROMETHEUS STACK READY%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
  has_key prometheus   && printf "  • Prometheus Server : %bhttp://%s:9090%b\n" "${C_BOLD}${C_CYAN}" "${ip}" "${C_RESET}"
  has_key node         && printf "  • Node Exporter     : %bhttp://%s:9100/metrics%b\n" "${C_CYAN}" "${ip}" "${C_RESET}"
  has_key alertmanager && printf "  • Alertmanager UI   : %bhttp://%s:9093%b\n" "${C_CYAN}" "${ip}" "${C_RESET}"
  printf "  • Next Step         : Connect Prometheus to Grafana via %b./wf run install-grafana%b\n" "${C_YELLOW}" "${C_RESET}"
  printf "%b=================================================================%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
}

# --- Action: Uninstall ----------------------------------------------------
a_uninstall() {
  hd "Uninstall Prometheus Stack"
  warn "This will stop and remove Prometheus, node_exporter, Alertmanager, and configurations."
  local yn; yn="$(ask "Are you sure you want to remove the stack? [y/N]:" "n")"
  case "${yn}" in y|Y|yes) ;; *) info "Cancelled."; return 0 ;; esac

  sub "Stopping and disabling services..."
  for s in prometheus prometheus-node-exporter prometheus-alertmanager; do
    run ${SUDO} systemctl stop "$s" 2>/dev/null || true
    run ${SUDO} systemctl disable "$s" 2>/dev/null || true
  done

  sub "Purging packages..."
  run ${SUDO} apt-get purge -y prometheus prometheus-node-exporter prometheus-alertmanager 2>/dev/null || true
  run ${SUDO} apt-get autoremove -y

  if command -v ufw >/dev/null 2>&1; then
    for p in 9090 9100 9093; do
      run ${SUDO} ufw delete allow "${p}/tcp" 2>/dev/null || true
    done
  elif command -v firewall-cmd >/dev/null 2>&1; then
    for p in 9090 9100 9093; do
      run ${SUDO} firewall-cmd --permanent --remove-port="${p}/tcp" 2>/dev/null || true
    done
    run ${SUDO} firewall-cmd --reload 2>/dev/null || true
  fi

  ok "Prometheus stack uninstalled."
}

# --- CLI Dispatch ---------------------------------------------------------
wf_svc_dispatch "${1:-}" "Prometheus" "prometheus" prometheus prometheus-node-exporter prometheus-alertmanager && exit $?
case "${1:-}" in
  status|audit)
    a_status; exit $?
    ;;
  install)
    a_install; exit $?
    ;;
  rules|alert-rules)
    a_rules; exit $?
    ;;
  alertmanager|notifications)
    a_alertmanager_integration; exit $?
    ;;
  --uninstall|uninstall)
    a_uninstall; exit $?
    ;;
esac

# --- Interactive Main Menu ------------------------------------------------
banner
MENU=(
  "Status|status|Audit Prometheus Services, Scrape Targets & Alert Rules"
  "Install|install|Install Prometheus, Node Exporter & Alertmanager"
  "Rules|rules|Configure Production System Alert Rules (CPU, RAM, Disk, Down)"
  "Alertmanager|alertmanager|Configure Notification Integrations (Telegram, Discord, Email)"
  "Remove|uninstall|Uninstall Prometheus Stack & Clean Ports"
)

while true; do
  if menu_select "Prometheus Observability Toolkit:"; then
    case "${MENU_KEY}" in
      status)       a_status; pause ;;
      install)      a_install; pause ;;
      rules)        a_rules; pause ;;
      alertmanager) a_alertmanager_integration; pause ;;
      uninstall)    a_uninstall; pause ;;
      *) break ;;
    esac
  else
    break
  fi
done

ok "Script install-prometheus completed."
