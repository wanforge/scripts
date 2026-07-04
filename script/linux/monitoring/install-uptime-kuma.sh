#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-uptime-kuma.sh — install & manage Uptime Kuma status pages and monitors
# via Node.js + PM2 + optional ufw firewall.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/monitoring/install-uptime-kuma.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-uptime-kuma"

# --- shared library ------------------------------------------------------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load
wf_log_init

# --- check Node & PM2 environment -----------------------------------------
nvm_load() {
  export NVM_DIR="${HOME}/.nvm"
  # shellcheck source=/dev/null
  [ -s "${NVM_DIR}/nvm.sh" ] && . "${NVM_DIR}/nvm.sh"
}
nvm_load

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1 || ! command -v pm2 >/dev/null 2>&1; then
  err "This script requires Node.js, npm, and PM2."
  info "Please run install-nodejs.sh first to install the Node environment for the current user."
  exit 1
fi

# Root directory for Uptime Kuma installation
if [ "$(id -u)" -eq 0 ]; then
  KUMA_ROOT="${KUMA_ROOT:-/opt/uptime-kuma}"
else
  KUMA_ROOT="${KUMA_ROOT:-${HOME}/.local/lib/uptime-kuma}"
fi

ufw_allow() {  # ufw_allow <port> <cidr>
  command -v ufw >/dev/null 2>&1 || { info "ufw not installed; open ${1}/tcp manually."; return; }
  if [ "${2}" = "0.0.0.0/0" ]; then run ${SUDO} ufw allow "${1}/tcp"
  else run ${SUDO} ufw allow from "${2}" to any port "${1}" proto tcp; fi
}

a_uninstall() {
  hd "Uninstall Uptime Kuma"
  warn "This will stop, delete from PM2, and optionally remove Uptime Kuma files."
  local yn; yn="$(ask "Uninstall Uptime Kuma? [y/N]:" "n")"
  case "${yn}" in y|Y|yes) ;; *) info "Cancelled."; return 0 ;; esac

  if pm2 show uptime-kuma >/dev/null 2>&1; then
    run pm2 delete uptime-kuma
    run pm2 save
    ok "Deleted uptime-kuma from PM2."
  else
    info "Uptime Kuma is not registered in PM2."
  fi

  local rm_dir; rm_dir="$(ask "Delete the Uptime Kuma installation directory (${KUMA_ROOT})? [y/N]:" "n")"
  case "${rm_dir}" in
    y|Y|yes) run rm -rf "${KUMA_ROOT}" && ok "Removed files." ;;
  esac

  if command -v ufw >/dev/null 2>&1; then
    local port; port="${CFG_KUMA_PORT:-3001}"
    run ${SUDO} ufw delete allow "${port}/tcp" 2>/dev/null || true
    ok "Removed firewall rule for port ${port}."
  fi

  ok "Uptime Kuma uninstalled."
}

a_install() {
  hd "Install Uptime Kuma"
  info "Installing Uptime Kuma under: ${KUMA_ROOT}"

  # Check git is installed
  if ! command -v git >/dev/null 2>&1; then
    err "git is required. Please run install-packages.sh or install git manually."
    return 1
  fi

  # Ask for Port
  local PORT; PORT="$(ask_cfg CFG_KUMA_PORT "Set Uptime Kuma Port:" "3001")"

  if [ -d "${KUMA_ROOT}" ]; then
    warn "Directory ${KUMA_ROOT} already exists."
    local overwrite; overwrite="$(ask "Update/re-install Uptime Kuma here? [y/N]:" "n")"
    case "${overwrite}" in y|Y|yes) ;; *) info "Cancelled."; return 0 ;; esac
  else
    run git clone https://github.com/louislam/uptime-kuma.git "${KUMA_ROOT}"
  fi

  step "Running Uptime Kuma installation setup (npm run setup)"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] would run npm install & npm run setup"
  else
    cd "${KUMA_ROOT}"
    run npm install
    run npm run setup
  fi

  step "Register and start in PM2"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] would run: PORT=${PORT} pm2 start server/server.js --name uptime-kuma"
  else
    cd "${KUMA_ROOT}"
    # Delete first if already exists to prevent duplicates
    pm2 delete uptime-kuma >/dev/null 2>&1 || true
    run env PORT="${PORT}" pm2 start server/server.js --name uptime-kuma
    run pm2 save
  fi

  # Firewall
  if command -v ufw >/dev/null 2>&1; then
    case "$(ask_cfg CFG_KUMA_UFW "Open port ${PORT} in ufw? [Y/n]:" "y")" in
      n|N|no) info "Firewall unchanged." ;;
      *)
        local CIDR; CIDR="$(ask_cfg CFG_KUMA_CIDR "Allow from which source CIDR? ('0.0.0.0/0'=anywhere):" "0.0.0.0/0")"
        ufw_allow "${PORT}" "${CIDR}"
        ;;
    esac
  fi

  IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<server-ip>')"
  printf "\n%b✔ Uptime Kuma ready.%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
  printf "%b  Open:  http://%s:%s%b\n\n" "${C_DIM}" "${IP}" "${PORT}" "${C_RESET}" >&2
}

# --- dispatch flags --------------------------------------------------------
for __a in "$@"; do
  case "${__a}" in
    --uninstall) a_uninstall; exit $? ;;
    --start) pm2 start uptime-kuma; exit $? ;;
    --stop) pm2 stop uptime-kuma; exit $? ;;
    --restart) pm2 restart uptime-kuma; exit $? ;;
    --status) pm2 show uptime-kuma; exit $? ;;
    --logs) pm2 logs uptime-kuma; exit $? ;;
  esac
done

# --- interactive menu ------------------------------------------------------
banner
while true; do
  MENU=(
    "Action|install|Install / Update Uptime Kuma"
    "Action|start|Start service in PM2"
    "Action|stop|Stop service in PM2"
    "Action|restart|Restart service in PM2"
    "Action|status|View PM2 status"
    "Action|logs|View PM2 logs"
    "Action|uninstall|Uninstall / Remove Uptime Kuma"
  )
  printf "\n" >&2
  menu_select "Uptime Kuma Manager:" || break
  case "${MENU_KEY}" in
    install) a_install ;;
    start) pm2 start uptime-kuma ;;
    stop) pm2 stop uptime-kuma ;;
    restart) pm2 restart uptime-kuma ;;
    status) pm2 show uptime-kuma || true; pause ;;
    logs) pm2 logs uptime-kuma ;;
    uninstall) a_uninstall ;;
  esac
done

printf "\n%b✔ uptime-kuma manager finished.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
