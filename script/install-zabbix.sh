#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-zabbix.sh — install Zabbix from the official repo: agent (zabbix-agent2)
# or server (server + frontend + MySQL/MariaDB schema). Debian/Ubuntu.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/wanforge/server-mine/main/script/install-zabbix.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-zabbix"

# --- shared library ------------------------------------------------------
__LIB="https://raw.githubusercontent.com/wanforge/server-mine/main/script/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/lib.sh" ]; then . "${__d}/lib.sh"
else . <(curl -fsSL "${__LIB}"); fi
step() { printf "\n%b==> %s%b\n" "${C_BOLD}${C_CYAN}" "$1" "${C_RESET}" >&2; }

# ---- run ----------------------------------------------------------------
banner
command -v apt-get >/dev/null 2>&1 || { err "This script targets Debian/Ubuntu (apt)."; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release 2>/dev/null || true
OS_ID="${ID:-ubuntu}"; OS_VER="${VERSION_ID:-}"
[ "${OS_ID}" = "debian" ] && OS_VER="${OS_VER%%.*}"   # debian uses the major number

ZVER="$(ask "Zabbix version:" "7.0")"
REL="zabbix-release_latest_${ZVER}+${OS_ID}${OS_VER}_all.deb"
RELURL="https://repo.zabbix.com/zabbix/${ZVER}/${OS_ID}/pool/main/z/zabbix-release/${REL}"

step "Add Zabbix repository (${ZVER}, ${OS_ID}${OS_VER})"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
if curl -fsSL "${RELURL}" -o "${TMP}/${REL}" 2>/dev/null; then
  run ${SUDO} dpkg -i "${TMP}/${REL}"
  run ${SUDO} apt-get update
else
  err "Could not fetch ${RELURL}"
  warn "Check the version/OS or see https://www.zabbix.com/download for the right URL."
  exit 1
fi

MENU=("Role|agent|Agent only (monitored host, port 10050)" "Role|server|Server + web frontend + database (full monitoring server)")
menu_select "What to install?" || exit 0
ROLE="${MENU_KEY}"

if [ "${ROLE}" = "agent" ]; then
  step "Install Zabbix agent 2"
  run ${SUDO} apt-get install -y zabbix-agent2 zabbix-agent2-plugin-*
  SRV="$(ask "Zabbix server IP/hostname (the server that will poll this host):" "127.0.0.1")"
  HN="$(ask "This host's Hostname (as shown in Zabbix):" "$(hostname 2>/dev/null || echo host)")"
  CONF="/etc/zabbix/zabbix_agent2.conf"
  run ${SUDO} sed -i "s/^Server=.*/Server=${SRV}/" "${CONF}"
  run ${SUDO} sed -i "s/^ServerActive=.*/ServerActive=${SRV}/" "${CONF}"
  run ${SUDO} sed -i "s/^Hostname=.*/Hostname=${HN}/" "${CONF}"
  run ${SUDO} systemctl enable --now zabbix-agent2 || warn "Could not start agent."
  command -v ufw >/dev/null 2>&1 && run ${SUDO} ufw allow 10050/tcp || true
  printf "\n%b✔ Zabbix agent ready.%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
  printf "%b  Add this host in the Zabbix server UI (Hostname: %s, agent port 10050).%b\n\n" "${C_DIM}" "${HN}" "${C_RESET}" >&2
  exit 0
fi

# ---- server (MySQL/MariaDB) ---------------------------------------------
warn "Server install needs a running MySQL/MariaDB. The script will create the DB and import the schema."
step "Install Zabbix server, frontend, agent"
run ${SUDO} apt-get install -y zabbix-server-mysql zabbix-frontend-php zabbix-apache-conf zabbix-sql-scripts zabbix-agent2

if ! command -v mysql >/dev/null 2>&1; then
  case "$(ask "MySQL/MariaDB not found. Install MariaDB now? [Y/n]:" "y")" in
    n|N|no) err "A database is required."; exit 1 ;;
    *) run ${SUDO} apt-get install -y mariadb-server; run ${SUDO} systemctl enable --now mariadb ;;
  esac
fi

DBPASS="$(asks 'Set a password for the zabbix DB user:')"
[ -n "${DBPASS}" ] || { err "DB password required."; exit 1; }
DBPASS_ESC="${DBPASS//\'/\'\'}"

step "Create database & user"
if [ "${DRY_RUN:-0}" = "1" ]; then
  info "[dry-run] would create database 'zabbix' and user 'zabbix'@'localhost'"
else
  ${SUDO} mysql <<SQL
CREATE DATABASE IF NOT EXISTS zabbix CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS 'zabbix'@'localhost' IDENTIFIED BY '${DBPASS_ESC}';
GRANT ALL PRIVILEGES ON zabbix.* TO 'zabbix'@'localhost';
SET GLOBAL log_bin_trust_function_creators = 1;
FLUSH PRIVILEGES;
SQL
  step "Import schema (this can take a minute)"
  zcat /usr/share/zabbix/sql-scripts/mysql/server.sql.gz | ${SUDO} mysql --default-character-set=utf8mb4 -uzabbix -p"${DBPASS}" zabbix
  ${SUDO} mysql <<SQL
SET GLOBAL log_bin_trust_function_creators = 0;
SQL
  ok "Database ready."
fi

step "Configure & start"
run ${SUDO} sed -i "s/^# DBPassword=.*/DBPassword=${DBPASS_ESC}/; s/^DBPassword=.*/DBPassword=${DBPASS_ESC}/" /etc/zabbix/zabbix_server.conf
run ${SUDO} systemctl restart zabbix-server zabbix-agent2 || true
run ${SUDO} systemctl enable zabbix-server zabbix-agent2 || true
if systemctl list-unit-files 2>/dev/null | grep -q apache2; then run ${SUDO} systemctl restart apache2; run ${SUDO} systemctl enable apache2; fi
if command -v ufw >/dev/null 2>&1; then run ${SUDO} ufw allow 80/tcp; run ${SUDO} ufw allow 10051/tcp; fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<server-ip>')"
printf "\n%b✔ Zabbix server ready.%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
printf "%b  Frontend: http://%s/zabbix   (finish setup in the web wizard)%b\n" "${C_DIM}" "${IP}" "${C_RESET}" >&2
printf "%b  Default login: Admin / zabbix%b\n\n" "${C_DIM}" "${C_RESET}" >&2
