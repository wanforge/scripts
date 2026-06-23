#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# enable-mysql-remote.sh — allow remote access to MySQL/MariaDB by setting
# bind-address and opening the firewall (security-sensitive).
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/database/enable-mysql-remote.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="enable-mysql-remote"

# --- shared library: banner, colors, logging, prompts, checkbox ----------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load
wf_log_init

a_uninstall() {
  hd "Rollback MySQL Remote Access"
  local conf
  conf="$(${SUDO} grep -rlE '^[[:space:]]*bind-address' /etc/mysql 2>/dev/null | head -1 || true)"
  if [ -z "${conf}" ]; then
    info "MySQL config not found. Nothing to rollback."; return 0
  fi
  warn "Will set bind-address = 127.0.0.1 in ${conf} and close ufw port 3306."
  confirm_critical "rollback MySQL to local-only access (bind-address = 127.0.0.1)" || return 0
  run ${SUDO} sed -i 's|^[[:space:]]*bind-address.*|bind-address = 127.0.0.1|' "${conf}"
  ok "bind-address restored to 127.0.0.1 in ${conf}."
  run ${SUDO} systemctl restart mysql 2>/dev/null || run ${SUDO} systemctl restart mariadb 2>/dev/null || true
  command -v ufw >/dev/null 2>&1 && {
    run ${SUDO} ufw delete allow 3306/tcp 2>/dev/null || true
    run ${SUDO} ufw delete allow from any to any port 3306 proto tcp 2>/dev/null || true
  }
  ok "MySQL remote access rolled back."
}

# ---- run ----------------------------------------------------------------
[ "${1:-}" = "--uninstall" ] && { a_uninstall; exit $?; }
banner
if [ -z "${1:-}" ]; then
  MENU=(
    "Manage|configure|enable MySQL remote access"
    "Manage|rollback|restore local-only access"
  )
  menu_select "MySQL Remote Access — choose action:" || exit 0
  case "${MENU_KEY}" in
    rollback)    a_uninstall; exit $? ;;
    configure|*) ;;
  esac
fi
if [ ! -d /etc/mysql ]; then err "/etc/mysql not found. Install MySQL/MariaDB first."; exit 1; fi

warn "This exposes the database to the network. Restrict the source range when possible."

# locate the config file that defines bind-address
CONF="$(${SUDO} grep -rlE '^[[:space:]]*bind-address' /etc/mysql 2>/dev/null | head -1 || true)"
if [ -z "${CONF}" ]; then
  for c in /etc/mysql/mysql.conf.d/mysqld.cnf /etc/mysql/mariadb.conf.d/50-server.cnf; do
    [ -f "$c" ] && { CONF="$c"; break; }
  done
fi
[ -z "${CONF}" ] && { err "Could not find a MySQL/MariaDB config file."; exit 1; }
info "Config file: ${CONF}"

CIDR="$(ask_cfg CFG_MYSQL_REMOTE_CIDR "Allowed source CIDR (e.g. 10.0.0.0/8; '0.0.0.0/0'=anywhere, NOT recommended):" "0.0.0.0/0")"

PROCEED="$(ask "Set bind-address = 0.0.0.0 in ${CONF}? [y/N]:" "n")"
case "${PROCEED}" in
  y|Y|yes)
    run ${SUDO} cp "${CONF}" "${CONF}.bak.$(date +%s 2>/dev/null || echo bak)" 2>/dev/null || true
    if ${SUDO} grep -qE '^[[:space:]]*bind-address' "${CONF}"; then
      run ${SUDO} sed -i 's|^[[:space:]]*bind-address.*|bind-address = 0.0.0.0|' "${CONF}"
    else
      printf '\n[mysqld]\nbind-address = 0.0.0.0\n' | run ${SUDO} tee -a "${CONF}" >/dev/null
    fi
    ok "Set bind-address = 0.0.0.0."

    # restart whichever service exists
    if run ${SUDO} systemctl restart mysql 2>/dev/null; then ok "Restarted mysql."
    elif run ${SUDO} systemctl restart mariadb 2>/dev/null; then ok "Restarted mariadb."
    else warn "Could not restart mysql/mariadb; restart manually."; fi

    if command -v ufw >/dev/null 2>&1; then
      if [ "${CIDR}" = "0.0.0.0/0" ]; then ${SUDO} ufw allow 3306/tcp
      else ${SUDO} ufw allow from "${CIDR}" to any port 3306 proto tcp; fi
      ok "Firewall: allowed 3306/tcp from ${CIDR}."
    else
      info "ufw not installed; open port 3306 manually if needed."
    fi
    warn "Remember to grant DB users a host that matches remote clients (e.g. 'user'@'%')."
    ;;
  *) info "Skipped bind-address change." ;;
esac

# ---- create remote DB users (optional, independent of bind-address) -----
ADDU="$(ask "Create remote database user(s) now? [y/N]:" "n")"
case "${ADDU}" in
  y|Y|yes)
    # admin connection: try root socket auth via sudo, else ask root password
    MYSQL=(${SUDO} mysql)
    if ! ${SUDO} mysql -e 'SELECT 1' >/dev/null 2>&1; then
      RPW="$(asks_cfg CFG_MYSQL_ROOT_PW 'MySQL/MariaDB root password:')"
      MYSQL=(mysql -uroot -p"${RPW}")
    fi
    if ! "${MYSQL[@]}" -e 'SELECT 1' >/dev/null 2>&1; then
      err "Cannot connect as admin. Skipping user creation."
    else
      while true; do
        MORE="$(ask 'Add a user? [y/N]:' 'n')"; case "${MORE}" in y|Y|yes) ;; *) break ;; esac
        DU="$(ask 'New DB username:')"
        if ! [[ "${DU}" =~ ^[a-zA-Z0-9_]+$ ]]; then warn "Invalid username (letters/digits/underscore)."; continue; fi
        DPW="$(asks "Password for ${DU}:")"; [ -z "${DPW}" ] && { warn "Empty password; skipping."; continue; }
        HOSTP="$(ask_cfg CFG_MYSQL_USER_HOST "Allowed host ('%'=any, or a specific client IP):" '%')"
        DBN="$(ask_cfg CFG_MYSQL_USER_DB "Grant on database ('*'=all databases):" '*')"
        DPW_ESC="${DPW//\'/\'\'}"   # escape single quotes for the SQL literal
        if [ "${DBN}" = "*" ]; then GRANTOBJ='*.*'; else GRANTOBJ="\`${DBN}\`.*"; fi
        SQL="CREATE USER IF NOT EXISTS '${DU}'@'${HOSTP}' IDENTIFIED BY '${DPW_ESC}'; GRANT ALL PRIVILEGES ON ${GRANTOBJ} TO '${DU}'@'${HOSTP}'; FLUSH PRIVILEGES;"
        if printf '%s\n' "${SQL}" | "${MYSQL[@]}" 2>/dev/null; then
          ok "Created '${DU}'@'${HOSTP}' with privileges on ${GRANTOBJ}."
        else
          err "Failed to create ${DU} (admin access? duplicate user?)."
        fi
        unset DPW DPW_ESC
      done
    fi
    ;;
  *) info "No remote users created." ;;
esac

printf "\n%b✔ MySQL remote-access step finished.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
