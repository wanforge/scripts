#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-grafana.sh — install Grafana from the official APT repo, enable it,
# open the firewall, and optionally provision a Prometheus data source.
# Debian/Ubuntu.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/monitoring/install-grafana.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-grafana"

# --- shared library ------------------------------------------------------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load
wf_log_init
step() { printf "\n%b==> %s%b\n" "${C_BOLD}${C_CYAN}" "$1" "${C_RESET}" >&2; }

# ---- run ----------------------------------------------------------------
banner
command -v apt-get >/dev/null 2>&1 || { err "This script targets Debian/Ubuntu (apt)."; exit 1; }

step "Add Grafana APT repository"
run ${SUDO} apt-get install -y apt-transport-https software-properties-common wget gpg
run ${SUDO} mkdir -p /etc/apt/keyrings
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor 2>/dev/null | run ${SUDO} tee /etc/apt/keyrings/grafana.gpg >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  | run ${SUDO} tee /etc/apt/sources.list.d/grafana.list >/dev/null

step "Install Grafana"
run ${SUDO} apt-get update
run ${SUDO} apt-get install -y grafana
run ${SUDO} systemctl enable --now grafana-server || warn "Could not start grafana-server."
ok "Grafana installed."

# optional: provision Prometheus data source
DS="$(ask_cfg CFG_GRAFANA_DS "Auto-add a Prometheus data source? [Y/n]:" "y")"
case "${DS}" in
  n|N|no) info "Skipped data source." ;;
  *)
    PURL="$(ask_cfg CFG_GRAFANA_PURL "Prometheus URL:" "http://localhost:9090")"
    run ${SUDO} mkdir -p /etc/grafana/provisioning/datasources
    printf 'apiVersion: 1\ndatasources:\n  - name: Prometheus\n    type: prometheus\n    access: proxy\n    url: %s\n    isDefault: true\n' "${PURL}" \
      | run ${SUDO} tee /etc/grafana/provisioning/datasources/prometheus.yml >/dev/null
    run ${SUDO} systemctl restart grafana-server || true
    ok "Provisioned Prometheus data source (${PURL})."
    ;;
esac

# firewall
if command -v ufw >/dev/null 2>&1; then
  case "$(ask_cfg CFG_GRAFANA_UFW "Open port 3000 in ufw? [Y/n]:" "y")" in
    n|N|no) info "Firewall unchanged." ;;
    *)
      CIDR="$(ask_cfg CFG_GRAFANA_CIDR "Allow from which source CIDR? ('0.0.0.0/0'=anywhere):" "0.0.0.0/0")"
      if [ "${CIDR}" = "0.0.0.0/0" ]; then run ${SUDO} ufw allow 3000/tcp
      else run ${SUDO} ufw allow from "${CIDR}" to any port 3000 proto tcp; fi ;;
  esac
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<server-ip>')"
printf "\n%b✔ Grafana ready.%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
printf "%b  Open:  http://%s:3000%b\n" "${C_DIM}" "${IP}" "${C_RESET}" >&2
printf "%b  Login: admin / admin  (you'll be asked to change it on first login)%b\n" "${C_DIM}" "${C_RESET}" >&2
printf "%b  Then: Dashboards → Import → e.g. ID 1860 (Node Exporter Full).%b\n\n" "${C_DIM}" "${C_RESET}" >&2
