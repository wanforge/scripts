#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-prometheus.sh — Prometheus + node_exporter (+ optional Alertmanager)
# via the distro packages, with scrape config and firewall. Debian/Ubuntu.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/monitoring/install-prometheus.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-prometheus"

# --- shared library ------------------------------------------------------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load
wf_log_init

svc() { run ${SUDO} systemctl enable --now "$1" 2>/dev/null || warn "Could not enable ${1}."; }
ufw_allow() {  # ufw_allow <port> <cidr>
  command -v ufw >/dev/null 2>&1 || { info "ufw not installed; open ${1}/tcp manually."; return; }
  if [ "${2}" = "0.0.0.0/0" ]; then run ${SUDO} ufw allow "${1}/tcp"
  else run ${SUDO} ufw allow from "${2}" to any port "${1}" proto tcp; fi
}

a_uninstall() {
  hd "Uninstall Prometheus Stack"
  warn "This will stop and remove Prometheus, node_exporter, and Alertmanager."
  local yn; yn="$(ask "Remove Prometheus components? [y/N]:" "n")"
  case "${yn}" in y|Y|yes) ;; *) info "Cancelled."; return 0 ;; esac
  for svc in prometheus prometheus-node-exporter prometheus-alertmanager; do
    run ${SUDO} systemctl stop "${svc}" 2>/dev/null || true
    run ${SUDO} systemctl disable "${svc}" 2>/dev/null || true
  done
  run ${SUDO} apt-get purge -y prometheus prometheus-node-exporter prometheus-alertmanager 2>/dev/null || true
  run ${SUDO} apt-get autoremove -y
  command -v ufw >/dev/null 2>&1 && {
    for port in 9090 9100 9093; do
      run ${SUDO} ufw delete allow "${port}/tcp" 2>/dev/null || true
    done
  }
  ok "Prometheus stack removed."
}

# ---- run ----------------------------------------------------------------
wf_svc_dispatch "${1:-}" "Prometheus" "prometheus" prometheus prometheus-node-exporter prometheus-alertmanager && exit $?
[ "${1:-}" = "--uninstall" ] && { a_uninstall; exit $?; }
banner
if [ -z "${1:-}" ]; then
  _WF_RC=0; wf_svc_menu "Prometheus" "prometheus" prometheus prometheus-node-exporter prometheus-alertmanager || _WF_RC=$?
  [ "${_WF_RC}" -eq 99 ] && { a_uninstall; exit $?; }
fi
command -v apt-get >/dev/null 2>&1 || { err "This script targets Debian/Ubuntu (apt)."; exit 1; }

MENU=(
  "Prometheus|prometheus|Prometheus server (port 9090)"
  "Exporters|node|Node exporter — host CPU/RAM/disk metrics (port 9100)"
  "Alerting|alertmanager|Alertmanager — routes alerts (port 9093)"
  "Firewall|firewall|open selected ports in ufw"
)
checkbox "Select Prometheus components:" || { warn "Cancelled."; exit 0; }
[ "${#CHOSEN_KEYS[@]}" -eq 0 ] && { warn "Nothing selected."; exit 0; }

step() { printf "\n%b==> %s%b\n" "${C_BOLD}${C_CYAN}" "$1" "${C_RESET}" >&2; }

step "Update package index"
run ${SUDO} apt-get update

PKGS=""
has_key prometheus    && PKGS="${PKGS} prometheus"
has_key node          && PKGS="${PKGS} prometheus-node-exporter"
has_key alertmanager  && PKGS="${PKGS} prometheus-alertmanager"
if [ -n "${PKGS# }" ]; then step "Install:${PKGS}"; run ${SUDO} apt-get install -y ${PKGS}; fi

has_key prometheus   && svc prometheus
has_key node         && svc prometheus-node-exporter
has_key alertmanager && svc prometheus-alertmanager

# add a node_exporter scrape target to Prometheus if both are selected
CFG="/etc/prometheus/prometheus.yml"
if has_key prometheus && has_key node && [ -f "${CFG}" ]; then
  if ${SUDO} grep -qE "job_name:\s*'?node" "${CFG}" 2>/dev/null; then
    info "Scrape job for node_exporter already present."
  else
    step "Add node_exporter scrape target"
    printf "\n  - job_name: 'node'\n    static_configs:\n      - targets: ['localhost:9100']\n" \
      | run ${SUDO} tee -a "${CFG}" >/dev/null
    run ${SUDO} systemctl restart prometheus || true
    ok "Added node job and restarted Prometheus."
  fi
fi

# add alerting rules to Prometheus if selected
if has_key prometheus; then
  step "Configure Prometheus alerting rules"
  RULES_CFG="/etc/prometheus/alert.rules.yml"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] would create alert rules file at ${RULES_CFG}"
  else
    printf "groups:\n  - name: system_alerts\n    rules:\n      - alert: InstanceDown\n        expr: up == 0\n        for: 1m\n        labels:\n          severity: critical\n        annotations:\n          summary: \"Instance {{ \$labels.instance }} down\"\n          description: \"Instance {{ \$labels.instance }} has been down for more than 1 minute.\"\n\n      - alert: HostCpuHigh\n        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100) > 85\n        for: 5m\n        labels:\n          severity: warning\n        annotations:\n          summary: \"Host CPU high (instance {{ \$labels.instance }})\"\n          description: \"CPU usage is above 85%% (current value: {{ \$value }}%%)\"\n\n      - alert: HostOutOfMemory\n        expr: (1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)) * 100 > 90\n        for: 2m\n        labels:\n          severity: warning\n        annotations:\n          summary: \"Host Out of Memory (instance {{ \$labels.instance }})\"\n          description: \"Node memory usage is above 90%% (current value: {{ \$value }}%%)\"\n\n      - alert: HostDiskSpaceLow\n        expr: (node_filesystem_free_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"}) * 100 < 15\n        for: 5m\n        labels:\n          severity: warning\n        annotations:\n          summary: \"Host Disk Space Low (instance {{ \$labels.instance }})\"\n          description: \"Disk usage on / is above 85%% (current value: {{ \$value }}%%)\"\n" \
      | run ${SUDO} tee "${RULES_CFG}" >/dev/null
  fi

  # Include rules file in prometheus.yml
  if [ -f "${CFG}" ]; then
    if ${SUDO} grep -q "alert.rules.yml" "${CFG}" 2>/dev/null; then
      info "Alerting rules file already linked in prometheus.yml"
    else
      step "Link alerting rules in prometheus.yml"
      if [ "${DRY_RUN:-0}" = "1" ]; then
        info "[dry-run] would link alert rules in ${CFG}"
      else
        if ${SUDO} grep -q "^rule_files:" "${CFG}" 2>/dev/null; then
          run ${SUDO} sed -i '/^rule_files:/a \  - "/etc/prometheus/alert.rules.yml"' "${CFG}"
        else
          printf "\nrule_files:\n  - \"/etc/prometheus/alert.rules.yml\"\n" | run ${SUDO} tee -a "${CFG}" >/dev/null
        fi
      fi
      run ${SUDO} systemctl restart prometheus || true
      ok "Linked alerting rules and restarted Prometheus."
    fi
  fi
fi

# configure Alertmanager integration if selected
AM_CFG="/etc/prometheus/alertmanager.yml"
if has_key alertmanager && [ -f "${AM_CFG}" ]; then
  case "$(ask_cfg CFG_AM_SETUP "Configure Alertmanager notifications integration? [y/N]:" "n")" in
    y|Y|yes)
      MENU=(
        "Receiver|discord|Discord or Slack Webhook"
        "Receiver|telegram|Telegram Bot"
        "Receiver|webhook|Generic Webhook URL"
        "Receiver|email|SMTP Email"
      )
      if menu_select "Choose notification integration:"; then
        AM_REC="${MENU_KEY}"
        case "${AM_REC}" in
          discord)
            URL="$(asks_cfg CFG_AM_SLACK_URL "Webhook URL:")"
            if [ -n "${URL}" ]; then
              if [[ "${URL}" == *"discord.com/api/webhooks"* ]] && [[ "${URL}" != */slack ]]; then
                URL="${URL}/slack"
                info "Discord webhook detected. Appended '/slack' for compatibility."
              fi
              if [ "${DRY_RUN:-0}" = "1" ]; then
                info "[dry-run] would write Slack/Discord receiver config to ${AM_CFG}"
              else
                run ${SUDO} cp -b "${AM_CFG}" "${AM_CFG}.bak"
                printf "global:\n  resolve_timeout: 5m\nroute:\n  group_by: ['alertname']\n  group_wait: 10s\n  group_interval: 10s\n  repeat_interval: 1h\n  receiver: 'slack-notifications'\nreceivers:\n- name: 'slack-notifications'\n  slack_configs:\n  - api_url: '%s'\n    send_resolved: true\n" "${URL}" \
                  | run ${SUDO} tee "${AM_CFG}" >/dev/null
                ok "Configured Discord/Slack integration."
              fi
            else
              warn "Webhook URL cannot be empty. Skipping."
            fi
            ;;
          telegram)
            TOKEN="$(asks_cfg CFG_AM_TELEGRAM_TOKEN "Telegram Bot Token (e.g. 12345:ABC-DEF...):")"
            CHAT_ID="$(ask_cfg CFG_AM_TELEGRAM_CHAT_ID "Telegram Chat ID (e.g. -1001234567 or user ID):" "")"
            if [ -n "${TOKEN}" ] && [ -n "${CHAT_ID}" ]; then
              if [ "${DRY_RUN:-0}" = "1" ]; then
                info "[dry-run] would write Telegram receiver config to ${AM_CFG}"
              else
                run ${SUDO} cp -b "${AM_CFG}" "${AM_CFG}.bak"
                printf "global:\n  resolve_timeout: 5m\nroute:\n  group_by: ['alertname']\n  group_wait: 10s\n  group_interval: 10s\n  repeat_interval: 1h\n  receiver: 'telegram-notifications'\nreceivers:\n- name: 'telegram-notifications'\n  telegram_configs:\n  - bot_token: '%s'\n    chat_id: %s\n    send_resolved: true\n" "${TOKEN}" "${CHAT_ID}" \
                  | run ${SUDO} tee "${AM_CFG}" >/dev/null
                ok "Configured Telegram integration."
              fi
            else
              warn "Token and Chat ID are required. Skipping."
            fi
            ;;
          webhook)
            URL="$(asks_cfg CFG_AM_WEBHOOK_URL "Generic Webhook URL:")"
            if [ -n "${URL}" ]; then
              if [ "${DRY_RUN:-0}" = "1" ]; then
                info "[dry-run] would write generic Webhook receiver config to ${AM_CFG}"
              else
                run ${SUDO} cp -b "${AM_CFG}" "${AM_CFG}.bak"
                printf "global:\n  resolve_timeout: 5m\nroute:\n  group_by: ['alertname']\n  group_wait: 10s\n  group_interval: 10s\n  repeat_interval: 1h\n  receiver: 'webhook-notifications'\nreceivers:\n- name: 'webhook-notifications'\n  webhook_configs:\n  - url: '%s'\n    send_resolved: true\n" "${URL}" \
                  | run ${SUDO} tee "${AM_CFG}" >/dev/null
                ok "Configured Webhook integration."
              fi
            else
              warn "Webhook URL cannot be empty. Skipping."
            fi
            ;;
          email)
            SMTP_HOST="$(ask_cfg CFG_AM_SMTP_HOST "SMTP Server Host & Port (e.g. smtp.gmail.com:587):" "")"
            SMTP_FROM="$(ask_cfg CFG_AM_SMTP_FROM "Sender Email (From):" "")"
            SMTP_USER="$(ask_cfg CFG_AM_SMTP_USER "SMTP Username:" "")"
            SMTP_PASS="$(asks_cfg CFG_AM_SMTP_PASS "SMTP Password:")"
            SMTP_TO="$(ask_cfg CFG_AM_SMTP_TO "Recipient Email (To):" "")"
            if [ -n "${SMTP_HOST}" ] && [ -n "${SMTP_FROM}" ] && [ -n "${SMTP_TO}" ]; then
              if [ "${DRY_RUN:-0}" = "1" ]; then
                info "[dry-run] would write Email receiver config to ${AM_CFG}"
              else
                run ${SUDO} cp -b "${AM_CFG}" "${AM_CFG}.bak"
                printf "global:\n  resolve_timeout: 5m\n  smtp_smarthost: '%s'\n  smtp_from: '%s'\n  smtp_auth_username: '%s'\n  smtp_auth_password: '%s'\n  smtp_require_tls: true\nroute:\n  group_by: ['alertname']\n  group_wait: 10s\n  group_interval: 10s\n  repeat_interval: 1h\n  receiver: 'email-notifications'\nreceivers:\n- name: 'email-notifications'\n  email_configs:\n  - to: '%s'\n    send_resolved: true\n" "${SMTP_HOST}" "${SMTP_FROM}" "${SMTP_USER}" "${SMTP_PASS}" "${SMTP_TO}" \
                  | run ${SUDO} tee "${AM_CFG}" >/dev/null
                ok "Configured Email integration."
              fi
            else
              warn "Host, From, and To emails are required. Skipping."
            fi
            ;;
        esac
        run ${SUDO} systemctl restart prometheus-alertmanager || true
      fi
      ;;
  esac
fi

# configure prometheus.yml alerting target
if has_key prometheus && has_key alertmanager && [ -f "${CFG}" ]; then
  if ${SUDO} grep -qE "\-\s*localhost:9093" "${CFG}" 2>/dev/null; then
    info "Alertmanager alerting target already configured."
  else
    step "Configure Alertmanager alerting target in prometheus.yml"
    if [ "${DRY_RUN:-0}" = "1" ]; then
      info "[dry-run] would uncomment Alertmanager target in prometheus.yml"
    else
      run ${SUDO} sed -i 's/#\s*-\s*localhost:9093/-\ localhost:9093/g' "${CFG}"
      run ${SUDO} systemctl restart prometheus || true
      ok "Configured alerting targets and restarted Prometheus."
    fi
  fi
fi

# firewall
if has_key firewall; then
  step "Firewall"
  CIDR="$(ask_cfg CFG_PROM_CIDR "Allow from which source CIDR? ('0.0.0.0/0'=anywhere):" "0.0.0.0/0")"
  has_key prometheus   && ufw_allow 9090 "${CIDR}"
  has_key node         && ufw_allow 9100 "${CIDR}"
  has_key alertmanager && ufw_allow 9093 "${CIDR}"
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<server-ip>')"
printf "\n%b✔ Prometheus stack ready.%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
has_key prometheus   && printf "%b  Prometheus:   http://%s:9090   (Status → Targets to verify)%b\n" "${C_DIM}" "${IP}" "${C_RESET}" >&2
has_key node         && printf "%b  Node metrics: http://%s:9100/metrics%b\n" "${C_DIM}" "${IP}" "${C_RESET}" >&2
has_key alertmanager && printf "%b  Alertmanager: http://%s:9093%b\n" "${C_DIM}" "${IP}" "${C_RESET}" >&2
printf "%b  Next: add Prometheus as a Grafana data source (install-grafana.sh).%b\n\n" "${C_DIM}" "${C_RESET}" >&2
