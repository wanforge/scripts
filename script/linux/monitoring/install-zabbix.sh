#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-zabbix.sh — Install, optimize, and manage Zabbix 7.0 LTS Enterprise Monitoring.
#
# Features:
#   - Official Zabbix repository setup for Debian & Ubuntu (24.04 Noble, 22.04 Jammy, Debian 12/11)
#   - Full Server deployment: zabbix-server-mysql, zabbix-frontend-php, Apache/Nginx web UI, SQL schema import
#   - Lightweight Agent deployment: zabbix-agent2 with plugins, automated server IP binding
#   - Live health check & service audit (Server, Agent, Web, MySQL connectivity)
#   - Multi-firewall support (UFW & Firewalld ports 10051, 10050, 80/tcp)
#   - Clean uninstaller with optional database drop
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/monitoring/install-zabbix.sh | bash
#   ./install-zabbix.sh status
#   ./install-zabbix.sh server
#   ./install-zabbix.sh agent
#   ./install-zabbix.sh --uninstall
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-zabbix"

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

ZABBIX_SERVER_CONF="/etc/zabbix/zabbix_server.conf"
ZABBIX_AGENT_CONF="/etc/zabbix/zabbix_agent2.conf"

fw_allow() { # fw_allow <port> <proto> <comment>
  local port="$1"
  local proto="${2:-tcp}"
  local comment="${3:-Zabbix}"

  if command -v ufw >/dev/null 2>&1 && ${SUDO} ufw status 2>/dev/null | grep -qi "Status: active"; then
    run ${SUDO} ufw allow "${port}/${proto}" comment "${comment}"
    ok "UFW: Port ${port}/${proto} opened."
  elif command -v firewall-cmd >/dev/null 2>&1 && ${SUDO} firewall-cmd --state >/dev/null 2>&1; then
    run ${SUDO} firewall-cmd --permanent --add-port="${port}/${proto}"
    run ${SUDO} firewall-cmd --reload
    ok "Firewalld: Port ${port}/${proto} opened."
  else
    if command -v ufw >/dev/null 2>&1; then
      run ${SUDO} ufw allow "${port}/${proto}" comment "${comment}"
      ok "UFW rule added (firewall inactive)."
    else
      info "No active firewall found. Ensure port ${port} is opened in your cloud security group."
    fi
  fi
}

detect_distro_repo() {
  local os_id os_ver zver
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  os_id="${ID:-ubuntu}"
  os_ver="${VERSION_ID:-}"
  [ "${os_id}" = "debian" ] && os_ver="${os_ver%%.*}"

  zver="7.0"
  local rel="zabbix-release_latest_${zver}+${os_id}${os_ver}_all.deb"
  local url="https://repo.zabbix.com/zabbix/${zver}/${os_id}/pool/main/z/zabbix-release/${rel}"
  echo "${url}|${rel}"
}

setup_repo() {
  sub "Configuring official Zabbix 7.0 LTS APT repository..."
  local repo_info; repo_info="$(detect_distro_repo)"
  local url="${repo_info%|*}"
  local rel="${repo_info#*|}"

  local tmp_d; tmp_d="$(mktemp -d)"
  if curl -4 -fsSL "${url}" -o "${tmp_d}/${rel}" 2>/dev/null; then
    run ${SUDO} dpkg -i "${tmp_d}/${rel}"
    run ${SUDO} apt-get update
    rm -rf "${tmp_d}"
    ok "Zabbix 7.0 LTS repository configured."
  else
    rm -rf "${tmp_d}"
    err "Failed to download Zabbix release package from ${url}."
    return 1
  fi
}

# --- Action: Status & Audit -----------------------------------------------
a_status() {
  hd "Zabbix Service & System Audit"

  local has_agent=0
  local has_server=0
  command -v zabbix_agent2 >/dev/null 2>&1 && has_agent=1
  command -v zabbix_server >/dev/null 2>&1 && has_server=1

  if [ "${has_agent}" -eq 0 ] && [ "${has_server}" -eq 0 ]; then
    warn "Neither Zabbix Agent nor Zabbix Server is installed on this host."
    info "Run the installer to set up Zabbix."
    return 1
  fi

  printf "\n%bInstalled Binaries:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  [ "${has_server}" -eq 1 ] && ok "Zabbix Server : $(zabbix_server -V 2>/dev/null | head -1 || echo 'Installed')"
  [ "${has_agent}" -eq 1 ]  && ok "Zabbix Agent2 : $(zabbix_agent2 -V 2>/dev/null | head -1 || echo 'Installed')"

  printf "\n%bService Statuses:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  for s in zabbix-server zabbix-agent2 apache2 nginx mariadb mysql; do
    if systemctl list-unit-files "${s}.service" >/dev/null 2>&1; then
      local st; st="$(systemctl is-active "$s" 2>/dev/null || echo 'inactive')"
      if [ "${st}" = "active" ]; then
        ok "%-20s : Active & Running" "${s}"
      else
        warn "%-20s : %s" "${s}" "${st}"
      fi
    fi
  done

  printf "\n%bPort Listeners:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  if command -v ss >/dev/null 2>&1; then
    for p in 10051 10050 80; do
      local p_out; p_out="$(ss -tlnp 2>/dev/null | grep ":${p}\b" || true)"
      if [ -n "${p_out}" ]; then
        ok "Port %-5s : %s" "${p}" "${p_out}"
      else
        info "Port %-5s : Not listening" "${p}"
      fi
    done
  fi

  if [ "${has_server}" -eq 1 ] && [ -f "${ZABBIX_SERVER_CONF}" ]; then
    printf "\n%bDatabase Configuration (%s):%b\n" "${C_BOLD}${C_CYAN}" "${ZABBIX_SERVER_CONF}" "${C_RESET}"
    local db_host; db_host="$(grep -E '^[[:space:]]*DBHost=' "${ZABBIX_SERVER_CONF}" | head -1 | awk -F= '{print $2}' || echo 'localhost')"
    local db_name; db_name="$(grep -E '^[[:space:]]*DBName=' "${ZABBIX_SERVER_CONF}" | head -1 | awk -F= '{print $2}' || echo 'zabbix')"
    local db_user; db_user="$(grep -E '^[[:space:]]*DBUser=' "${ZABBIX_SERVER_CONF}" | head -1 | awk -F= '{print $2}' || echo 'zabbix')"
    info "  • DB Host : ${db_host:-localhost}"
    info "  • DB Name : ${db_name:-zabbix}"
    info "  • DB User : ${db_user:-zabbix}"
  fi
  printf "\n"
}

# --- Action: Install Agent ------------------------------------------------
a_install_agent() {
  hd "Install Zabbix Agent 2 (Monitoring Client)"

  if ! command -v apt-get >/dev/null 2>&1; then
    err "This script targets Debian/Ubuntu systems with APT."; return 1
  fi

  setup_repo || return 1

  sub "Installing zabbix-agent2..."
  run ${SUDO} apt-get install -y zabbix-agent2 zabbix-agent2-plugin-*

  local srv; srv="$(ask "Zabbix Server IP or Hostname (polling server):" "127.0.0.1")"
  local hn; hn="$(ask "This host's name (as displayed in Zabbix Server UI):" "$(hostname 2>/dev/null || echo host)")"

  if [ -f "${ZABBIX_AGENT_CONF}" ]; then
    sub "Configuring ${ZABBIX_AGENT_CONF}..."
    run ${SUDO} sed -i "s/^Server=.*/Server=${srv}/" "${ZABBIX_AGENT_CONF}"
    run ${SUDO} sed -i "s/^ServerActive=.*/ServerActive=${srv}/" "${ZABBIX_AGENT_CONF}"
    run ${SUDO} sed -i "s/^Hostname=.*/Hostname=${hn}/" "${ZABBIX_AGENT_CONF}"
  fi

  sub "Starting and enabling zabbix-agent2..."
  run ${SUDO} systemctl enable --now zabbix-agent2
  run ${SUDO} systemctl restart zabbix-agent2 || true

  if ask_yn "Open port 10050/tcp in the firewall for Zabbix Agent?" "y"; then
    fw_allow 10050 "tcp" "Zabbix Agent"
  fi

  printf "\n%b✔ ZABBIX AGENT 2 READY%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
  printf "  • Monitored Hostname : %b%s%b\n" "${C_BOLD}${C_CYAN}" "${hn}" "${C_RESET}"
  printf "  • Polling Server IP  : %b%s%b\n" "${C_BOLD}" "${srv}" "${C_RESET}"
  printf "  • Agent Port         : 10050/tcp\n\n"
}

# --- Action: Install Server -----------------------------------------------
a_install_server() {
  hd "Install Zabbix 7.0 LTS Full Server Suite"

  if ! command -v apt-get >/dev/null 2>&1; then
    err "This script targets Debian/Ubuntu systems with APT."; return 1
  fi

  setup_repo || return 1

  sub "Installing Zabbix Server, Web Frontend, and Apache..."
  run ${SUDO} apt-get install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent2

  # Check or install MariaDB
  if ! command -v mysql >/dev/null 2>&1; then
    info "Database server not found. Installing MariaDB Server..."
    run ${SUDO} apt-get install -y mariadb-server
    run ${SUDO} systemctl enable --now mariadb
  fi

  local dbpass; dbpass="$(asks "Enter password for Zabbix database user ('zabbix'):")"
  [ -z "${dbpass}" ] && { err "Password cannot be empty."; return 1; }
  local dbpass_esc="${dbpass//\'/\'\'}"

  sub "Initializing Zabbix MySQL database..."
  ${SUDO} mysql <<SQL
CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED BY '${dbpass_esc}';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
SET GLOBAL log_bin_trust_function_creators = 1;
FLUSH PRIVILEGES;
SQL

  sub "Importing Zabbix initial database schema (this may take ~1 minute)..."
  local schema_gz="/usr/share/zabbix/sql-scripts/mysql/server.sql.gz"
  if [ -f "${schema_gz}" ]; then
    zcat "${schema_gz}" | ${SUDO} mysql --default-character-set=utf8mb4 -uzabbix -p"${dbpass}" zabbix
    ok "Database schema imported successfully."
  else
    warn "Schema file ${schema_gz} not found. Check /usr/share/zabbix/sql-scripts/."
  fi

  ${SUDO} mysql <<SQL
SET GLOBAL log_bin_trust_function_creators = 0;
SQL

  sub "Configuring DBPassword in ${ZABBIX_SERVER_CONF}..."
  run ${SUDO} sed -i "s/^# DBPassword=.*/DBPassword=${dbpass_esc}/; s/^DBPassword=.*/DBPassword=${dbpass_esc}/" "${ZABBIX_SERVER_CONF}"

  sub "Enabling and starting Zabbix Server, Agent, and Apache..."
  run ${SUDO} systemctl enable --now zabbix-server zabbix-agent2
  run ${SUDO} systemctl restart zabbix-server zabbix-agent2 || true
  if systemctl list-unit-files apache2.service >/dev/null 2>&1; then
    run ${SUDO} systemctl enable --now apache2
    run ${SUDO} systemctl restart apache2 || true
  fi

  if ask_yn "Open firewall ports for Zabbix Server (80/tcp and 10051/tcp)?" "y"; then
    fw_allow 80 "tcp" "Zabbix Web UI"
    fw_allow 10051 "tcp" "Zabbix Server Trapper"
  fi

  local ip; ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<server-ip>')"
  printf "\n%b=================================================================%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
  printf "%b✔ ZABBIX 7.0 LTS SERVER READY%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
  printf "  • Web Frontend       : %bhttp://%s/zabbix%b\n" "${C_BOLD}${C_CYAN}" "${ip}" "${C_RESET}"
  printf "  • Default Login      : %bAdmin%b / %bzabbix%b\n" "${C_BOLD}" "${C_RESET}" "${C_BOLD}" "${C_RESET}"
  printf "  • Database User/Name : zabbix / zabbix\n"
  printf "  • Next Step          : Open the web frontend to complete the 4-step setup wizard\n"
  printf "%b=================================================================%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
}

# --- Action: Uninstall ----------------------------------------------------
a_uninstall() {
  hd "Uninstall Zabbix"
  warn "This will remove Zabbix packages, repository, and optionally database."
  local yn; yn="$(ask "Are you sure you want to remove Zabbix? [y/N]:" "n")"
  case "${yn}" in y|Y|yes) ;; *) info "Cancelled."; return 0 ;; esac

  sub "Stopping and disabling Zabbix services..."
  for s in zabbix-server zabbix-agent2; do
    run ${SUDO} systemctl stop "$s" 2>/dev/null || true
    run ${SUDO} systemctl disable "$s" 2>/dev/null || true
  done

  sub "Purging packages and repository..."
  run ${SUDO} apt-get purge -y 'zabbix-*' 2>/dev/null || true
  run ${SUDO} apt-get autoremove -y
  run ${SUDO} dpkg --purge zabbix-release 2>/dev/null || true
  run ${SUDO} rm -f /etc/apt/sources.list.d/zabbix.list
  run ${SUDO} apt-get update 2>/dev/null || true

  if ask_yn "Drop the 'zabbix' MySQL database and database user?" "n"; then
    ${SUDO} mysql -e "DROP DATABASE IF EXISTS zabbix; DROP USER IF EXISTS 'zabbix'@'localhost';" 2>/dev/null \
      && ok "Database dropped." || warn "Could not drop database."
  fi

  if command -v ufw >/dev/null 2>&1; then
    run ${SUDO} ufw delete allow 10050/tcp 2>/dev/null || true
    run ${SUDO} ufw delete allow 10051/tcp 2>/dev/null || true
  elif command -v firewall-cmd >/dev/null 2>&1; then
    run ${SUDO} firewall-cmd --permanent --remove-port=10050/tcp 2>/dev/null || true
    run ${SUDO} firewall-cmd --permanent --remove-port=10051/tcp 2>/dev/null || true
    run ${SUDO} firewall-cmd --reload 2>/dev/null || true
  fi

  ok "Zabbix uninstalled."
}

# --- CLI Dispatch ---------------------------------------------------------
wf_svc_dispatch "${1:-}" "Zabbix" "zabbix" zabbix-agent2 zabbix-server && exit $?
case "${1:-}" in
  status|audit)
    a_status; exit $?
    ;;
  server)
    a_install_server; exit $?
    ;;
  agent)
    a_install_agent; exit $?
    ;;
  --uninstall|uninstall)
    a_uninstall; exit $?
    ;;
esac

# --- Interactive Main Menu ------------------------------------------------
banner
MENU=(
  "Status|status|Audit Zabbix Status (Server, Agent, Ports & Database)"
  "Server|server|Install Full Zabbix 7.0 LTS Server (Server + Web + MySQL)"
  "Agent|agent|Install Zabbix Agent 2 on Monitored Client Node (Port 10050)"
  "Remove|uninstall|Uninstall Zabbix & Clean Repository / Database"
)

while true; do
  if menu_select "Zabbix 7.0 LTS Enterprise Monitoring:"; then
    case "${MENU_KEY}" in
      status)    a_status; pause ;;
      server)    a_install_server; pause ;;
      agent)     a_install_agent; pause ;;
      uninstall) a_uninstall; pause ;;
      *) break ;;
    esac
  else
    break
  fi
done

ok "Script install-zabbix completed."
