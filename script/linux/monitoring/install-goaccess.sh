#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-goaccess.sh — install GoAccess real-time web log analyzer,
# run it in terminal, or configure it as a real-time background HTML daemon.
# Debian/Ubuntu.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/monitoring/install-goaccess.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-goaccess"

# --- shared library ------------------------------------------------------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load
wf_log_init

have() { command -v "$1" >/dev/null 2>&1; }
ufw_allow() {  # ufw_allow <port> <cidr>
  command -v ufw >/dev/null 2>&1 || { info "ufw not installed; open ${1}/tcp manually."; return; }
  if [ "${2}" = "0.0.0.0/0" ]; then run ${SUDO} ufw allow "${1}/tcp"
  else run ${SUDO} ufw allow from "${2}" to any port "${1}" proto tcp; fi
}

a_uninstall() {
  hd "Uninstall GoAccess"
  warn "This will stop the daemon, remove GoAccess, repository, and service files."
  local yn; yn="$(ask "Remove GoAccess? [y/N]:" "n")"
  case "${yn}" in y|Y|yes) ;; *) info "Cancelled."; return 0 ;; esac

  run ${SUDO} systemctl stop goaccess 2>/dev/null || true
  run ${SUDO} systemctl disable goaccess 2>/dev/null || true
  run ${SUDO} rm -f /etc/systemd/system/goaccess.service
  run ${SUDO} systemctl daemon-reload 2>/dev/null || true
  
  run ${SUDO} apt-get purge -y goaccess 2>/dev/null || true
  run ${SUDO} apt-get autoremove -y
  run ${SUDO} rm -f /etc/apt/sources.list.d/goaccess.list /usr/share/keyrings/goaccess.gpg
  run ${SUDO} apt-get update 2>/dev/null || true
  
  if command -v ufw >/dev/null 2>&1; then
    local port; port="${CFG_GA_PORT:-7890}"
    run ${SUDO} ufw delete allow "${port}/tcp" 2>/dev/null || true
  fi
  ok "GoAccess uninstalled."
}

a_install() {
  hd "Install GoAccess"
  step "Adding official GoAccess repository"
  run ${SUDO} apt-get install -y apt-transport-https software-properties-common wget gpg
  
  # Fetch key
  wget -q -O - https://deb.goaccess.io/gnugpg.key | gpg --dearmor 2>/dev/null | run ${SUDO} tee /usr/share/keyrings/goaccess.gpg >/dev/null
  
  # Add source
  local CODENAME; CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  [ -n "${CODENAME}" ] || CODENAME="stable"
  echo "deb [signed-by=/usr/share/keyrings/goaccess.gpg] https://deb.goaccess.io/ ${CODENAME} main" \
    | run ${SUDO} tee /etc/apt/sources.list.d/goaccess.list >/dev/null
  
  step "Installing GoAccess"
  run ${SUDO} apt-get update
  run ${SUDO} apt-get install -y goaccess
  ok "GoAccess installed."
}

a_live_tui() {
  hd "Live Terminal Analyzer"
  if ! have goaccess; then
    err "GoAccess is not installed. Please select Install first."
    return 1
  fi
  local log_path; log_path="$(ask_cfg CFG_GA_LOG_PATH "Web log file to analyze:" "/var/log/nginx/access.log")"
  [ -f "${log_path}" ] || { err "File ${log_path} not found."; return 1; }
  
  # Run TUI
  ${SUDO} goaccess "${log_path}" --log-format=COMBINED
}

a_configure_daemon() {
  hd "Configure Real-Time HTML Daemon"
  if ! have goaccess; then
    err "GoAccess is not installed. Please select Install first."
    return 1
  fi

  local log_path; log_path="$(ask_cfg CFG_GA_LOG_PATH "Web log file to analyze:" "/var/log/nginx/access.log")"
  [ -f "${log_path}" ] || { err "File ${log_path} not found."; return 1; }

  local html_path; html_path="$(ask_cfg CFG_GA_HTML_PATH "HTML report output path:" "/var/www/html/report.html")"
  local port; port="$(ask_cfg CFG_GA_PORT "WebSocket Port (for live sync):" "7890")"

  step "Writing systemd service file"
  local svc_content="[Unit]
Description=GoAccess Real-Time Web Log Analyzer Daemon
After=network.target Nginx.service

[Service]
Type=simple
ExecStart=/usr/bin/goaccess ${log_path} -o ${html_path} --real-time-html --log-format=COMBINED --port=${port}
Restart=always
User=root

[Install]
WantedBy=multi-user.target"

  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] would create /etc/systemd/system/goaccess.service"
  else
    printf "%s\n" "${svc_content}" | run ${SUDO} tee /etc/systemd/system/goaccess.service >/dev/null
    run ${SUDO} systemctl daemon-reload
    run ${SUDO} systemctl enable --now goaccess
    ok "Real-time HTML daemon started and enabled."
  fi

  # Firewall
  if command -v ufw >/dev/null 2>&1; then
    case "$(ask_cfg CFG_GA_UFW "Open port ${port} in ufw? [Y/n]:" "y")" in
      n|N|no) info "Firewall unchanged." ;;
      *)
        local CIDR; CIDR="$(ask_cfg CFG_GA_CIDR "Allow from which source CIDR? ('0.0.0.0/0'=anywhere):" "0.0.0.0/0")"
        ufw_allow "${port}" "${CIDR}"
        ;;
    esac
  fi

  IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<server-ip>')"
  printf "\n%b✔ Daemon configured.%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
  printf "%b  HTML Report:  ${html_path}%b\n" "${C_DIM}" "${C_RESET}" >&2
  printf "%b  WS Port:      ${port}%b\n" "${C_DIM}" "${C_RESET}" >&2
  printf "%b  Integrate:    Serve this file in Nginx (e.g. proxying to port ${port} for WS).%b\n\n" "${C_DIM}" "${C_RESET}" >&2
}

# --- dispatch flags --------------------------------------------------------
for __a in "$@"; do
  case "${__a}" in
    --uninstall) a_uninstall; exit $? ;;
    --start) run ${SUDO} systemctl start goaccess; exit $? ;;
    --stop) run ${SUDO} systemctl stop goaccess; exit $? ;;
    --restart) run ${SUDO} systemctl restart goaccess; exit $? ;;
    --status) ${SUDO} systemctl status goaccess --no-pager; exit $? ;;
  esac
done

# --- interactive menu ------------------------------------------------------
banner
while true; do
  MENU=(
    "Action|install|Install GoAccess"
    "Action|tui|Run GoAccess inside terminal (TUI)"
    "Action|daemon|Configure real-time background HTML daemon"
    "Service|status|View daemon service status"
    "Service|stop|Stop daemon service"
    "Service|start|Start daemon service"
    "Service|restart|Restart daemon service"
    "Action|uninstall|Uninstall / Remove GoAccess"
  )
  printf "\n" >&2
  menu_select "GoAccess Web Log Analyzer Manager:" || break
  case "${MENU_KEY}" in
    install) a_install ;;
    tui) a_live_tui ;;
    daemon) a_configure_daemon ;;
    status) run ${SUDO} systemctl status goaccess --no-pager || true; pause ;;
    stop) run ${SUDO} systemctl stop goaccess && ok "Stopped daemon." ;;
    start) run ${SUDO} systemctl start goaccess && ok "Started daemon." ;;
    restart) run ${SUDO} systemctl restart goaccess && ok "Restarted daemon." ;;
    uninstall) a_uninstall ;;
  esac
done

printf "\n%b✔ goaccess manager finished.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
