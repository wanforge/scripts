#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-loki.sh — install Loki and Promtail from the official Grafana repo,
# enable them, open the firewall, and optionally provision Loki in Grafana.
# Debian/Ubuntu.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/monitoring/install-loki.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-loki"

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
  hd "Uninstall Loki Stack"
  warn "This will stop and remove Loki and Promtail packages, files, and firewall rules."
  local yn; yn="$(ask "Remove Loki stack? [y/N]:" "n")"
  case "${yn}" in y|Y|yes) ;; *) info "Cancelled."; return 0 ;; esac
  for s in loki promtail; do
    run ${SUDO} systemctl stop "${s}" 2>/dev/null || true
    run ${SUDO} systemctl disable "${s}" 2>/dev/null || true
  done
  run ${SUDO} apt-get purge -y loki promtail 2>/dev/null || true
  run ${SUDO} apt-get autoremove -y
  run ${SUDO} rm -rf /etc/loki /etc/promtail /var/lib/loki /var/lib/promtail
  run ${SUDO} rm -f /etc/grafana/provisioning/datasources/loki.yml 2>/dev/null || true
  command -v ufw >/dev/null 2>&1 && {
    run ${SUDO} ufw delete allow 3100/tcp 2>/dev/null || true
  }
  ok "Loki stack removed."
}

# ---- run ----------------------------------------------------------------
wf_svc_dispatch "${1:-}" "Loki" "loki" loki promtail && exit $?
[ "${1:-}" = "--uninstall" ] && { a_uninstall; exit $?; }
banner
if [ -z "${1:-}" ]; then
  _WF_RC=0; wf_svc_menu "Loki" "loki" loki promtail || _WF_RC=$?
  [ "${_WF_RC}" -eq 99 ] && { a_uninstall; exit $?; }
fi
command -v apt-get >/dev/null 2>&1 || { err "This script targets Debian/Ubuntu (apt)."; exit 1; }

MENU=(
  "Loki|loki|Loki log aggregation server (port 3100)"
  "Agent|promtail|Promtail agent — collects and forwards logs"
  "Firewall|firewall|open selected ports in ufw"
)
checkbox "Select Loki stack components:" || { warn "Cancelled."; exit 0; }
[ "${#CHOSEN_KEYS[@]}" -eq 0 ] && { warn "Nothing selected."; exit 0; }

step "Update package index & repositories"
# Add Grafana APT repo if needed
if [ ! -f /etc/apt/sources.list.d/grafana.list ]; then
  run ${SUDO} apt-get install -y apt-transport-https software-properties-common wget gpg
  run ${SUDO} mkdir -p /etc/apt/keyrings
  wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor 2>/dev/null | run ${SUDO} tee /etc/apt/keyrings/grafana.gpg >/dev/null
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    | run ${SUDO} tee /etc/apt/sources.list.d/grafana.list >/dev/null
fi
run ${SUDO} apt-get update

PKGS=""
has_key loki     && PKGS="${PKGS} loki"
has_key promtail && PKGS="${PKGS} promtail"
if [ -n "${PKGS# }" ]; then step "Install:${PKGS}"; run ${SUDO} apt-get install -y ${PKGS}; fi

# ---- configure Loki -----------------------------------------------------
if has_key loki; then
  step "Configure Loki server"
  LCFG="/etc/loki/config.yml"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] would configure Loki server config at ${LCFG}"
  else
    run ${SUDO} mkdir -p /etc/loki /var/lib/loki
    printf "auth_enabled: false\n\nserver:\n  http_listen_port: 3100\n  grpc_listen_port: 9096\n\ncommon:\n  instance_addr: 127.0.0.1\n  path_prefix: /var/lib/loki\n  storage:\n    filesystem:\n      chunks_directory: /var/lib/loki/chunks\n      rules_directory: /var/lib/loki/rules\n  replication_factor: 1\n  ring:\n    kvstore:\n      store: inmemory\n\nschema_config:\n  configs:\n    - from: 2020-10-24\n      store: tsdb\n      object_store: filesystem\n      schema: v11\n      index:\n        prefix: index_\n        period: 24h\n\nlimits_config:\n  reject_old_samples: true\n  reject_old_samples_max_age: 168h\n" \
      | run ${SUDO} tee "${LCFG}" >/dev/null
    run ${SUDO} chown -R loki:loki /var/lib/loki /etc/loki
  fi
  svc loki
fi

# ---- configure Promtail --------------------------------------------------
if has_key promtail; then
  step "Configure Promtail agent"
  PCFG="/etc/promtail/config.yml"
  LURL="$(ask_cfg CFG_PROMTAIL_LOKI_URL "Loki server API URL (for forwarding logs):" "http://localhost:3100/loki/api/v1/push")"
  
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] would configure Promtail config at ${PCFG} targeting ${LURL}"
  else
    run ${SUDO} mkdir -p /etc/promtail /var/lib/promtail
    printf "server:\n  http_listen_port: 9080\n  grpc_listen_port: 0\n\npositions:\n  filename: /var/lib/promtail/positions.yaml\n\nclients:\n  - url: %s\n\nscrape_configs:\n- job_name: system\n  static_configs:\n  - targets:\n      - localhost\n    labels:\n      job: varlogs\n      __path__: /var/log/*log\n- job_name: syslog\n  journal:\n    max_age: 12h\n    labels:\n      job: systemd-journal\n  relabel_configs:\n    - source_labels: ['__journal__systemd_unit']\n      target_label: 'unit'\n" "${LURL}" \
      | run ${SUDO} tee "${PCFG}" >/dev/null
    run ${SUDO} chown -R promtail:promtail /var/lib/promtail /etc/promtail
  fi
  svc promtail
fi

# ---- Grafana integration ------------------------------------------------
if has_key loki && [ -d /etc/grafana/provisioning/datasources ]; then
  case "$(ask_cfg CFG_LOKI_GRAFANA_DS "Auto-provision Loki datasource in Grafana? [Y/n]:" "y")" in
    n|N|no) info "Skipped Grafana integration." ;;
    *)
      step "Provision Loki datasource in Grafana"
      if [ "${DRY_RUN:-0}" = "1" ]; then
        info "[dry-run] would write Grafana loki.yml datasource config"
      else
        printf "apiVersion: 1\ndatasources:\n  - name: Loki\n    type: loki\n    access: proxy\n    url: http://localhost:3100\n    isDefault: false\n" \
          | run ${SUDO} tee /etc/grafana/provisioning/datasources/loki.yml >/dev/null
        run ${SUDO} chown -R grafana:grafana /etc/grafana/provisioning/datasources
        run ${SUDO} systemctl restart grafana-server || true
        ok "Provisioned Loki data source in Grafana."
      fi
      ;;
  esac
fi

# ---- firewall -----------------------------------------------------------
if has_key firewall; then
  step "Firewall"
  CIDR="$(ask_cfg CFG_LOKI_CIDR "Allow Loki access from which source CIDR? ('0.0.0.0/0'=anywhere):" "0.0.0.0/0")"
  has_key loki && ufw_allow 3100 "${CIDR}"
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<server-ip>')"
printf "\n%b✔ Loki stack ready.%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
has_key loki     && printf "%b  Loki Server: http://%s:3100/ready%b\n" "${C_DIM}" "${IP}" "${C_RESET}" >&2
has_key promtail && printf "%b  Promtail:    http://%s:9080/targets%b\n" "${C_DIM}" "${IP}" "${C_RESET}" >&2
if has_key loki && [ -d /etc/grafana/provisioning/datasources ]; then
  printf "%b  Next: view logs in Grafana (http://%s:3000 -> Explore -> choose 'Loki').%b\n\n" "${C_DIM}" "${IP}" "${C_RESET}" >&2
fi
