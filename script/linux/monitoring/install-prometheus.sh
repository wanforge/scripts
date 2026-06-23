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
  "Firewall|firewall|Open the selected ports in ufw"
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
