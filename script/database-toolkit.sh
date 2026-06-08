#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# database-toolkit.sh — monitor, inspect, optimize, and check config for
# MySQL/MariaDB and PostgreSQL via an interactive action menu.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/wanforge/server-mine/main/script/database-toolkit.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="database-toolkit"

# ---- common preamble ----------------------------------------------------
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET="\033[0m"; C_BOLD="\033[1m"; C_DIM="\033[2m"
  C_RED="\033[38;5;196m"; C_GREEN="\033[38;5;46m"; C_YELLOW="\033[38;5;226m"; C_CYAN="\033[38;5;45m"
  USE_COLOR=1
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; USE_COLOR=0
fi
banner() {
  local lines=(
'██╗    ██╗ █████╗ ███╗   ██╗███████╗ ██████╗ ██████╗  ██████╗ ███████╗'
'██║    ██║██╔══██╗████╗  ██║██╔════╝██╔═══██╗██╔══██╗██╔════╝ ██╔════╝'
'██║ █╗ ██║███████║██╔██╗ ██║█████╗  ██║   ██║██████╔╝██║  ███╗█████╗  '
'██║███╗██║██╔══██║██║╚██╗██║██╔══╝  ██║   ██║██╔══██╗██║   ██║██╔══╝  '
'╚███╔███╔╝██║  ██║██║ ╚████║██║     ╚██████╔╝██║  ██║╚██████╔╝███████╗'
' ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝      ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚══════╝'
  )
  local themes=("51 50 44 38 37 31" "45 39 33 32 26 21" "48 42 36 35 29 28" \
    "141 135 134 98 92 91" "218 212 211 205 199 198" "215 214 208 202 173 166")
  local pick=$(( RANDOM % ${#themes[@]} )); read -r -a grad <<< "${themes[$pick]}"
  printf "\n" >&2; local i=0
  for l in "${lines[@]}"; do
    if [ "${USE_COLOR}" -eq 1 ]; then printf "\033[1;38;5;%sm%s\033[0m\n" "${grad[$i]}" "$l" >&2
    else printf "%s\n" "$l" >&2; fi
    i=$((i + 1)); sleep 0.04
  done
  printf "%b        wanforge.asia · %s • GPLv3 © 2026 Sugeng Sulistiyawan%b\n\n" "${C_DIM}" "${TASK}" "${C_RESET}" >&2
}
hd()   { printf "\n%b▸ %s%b\n" "${C_BOLD}${C_CYAN}" "$1" "${C_RESET}" >&2; }
info() { printf "    %b•%b %s\n" "${C_DIM}" "${C_RESET}" "$1" >&2; }
ok()   { printf "    %b✔%b %s\n" "${C_GREEN}" "${C_RESET}" "$1" >&2; }
warn() { printf "    %b!%b %s\n" "${C_YELLOW}" "${C_RESET}" "$1" >&2; }
err()  { printf "    %b✖%b %s\n" "${C_RED}" "${C_RESET}" "$1" >&2; }
if [ -e /dev/tty ]; then exec 3</dev/tty; else exec 3<&0; fi
ask()  { local p="$1" d="${2:-}" a; printf "%b?%b %s " "${C_YELLOW}" "${C_RESET}" "${p}" >&2; read -r a <&3 || a=""; echo "${a:-$d}"; }
asks() { local p="$1" a; printf "%b?%b %s " "${C_YELLOW}" "${C_RESET}" "${p}" >&2; read -rs a <&3 || a=""; printf "\n" >&2; echo "${a}"; }
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# ---- connection helpers -------------------------------------------------
MYSQL_CMD=(); MYCHK_CMD=(); PSQL_CMD=()
connect_mysql() {
  MYSQL_CMD=(${SUDO} mysql); MYCHK_CMD=(${SUDO} mysqlcheck)
  if ! "${MYSQL_CMD[@]}" -e 'SELECT 1' >/dev/null 2>&1; then
    local pw; pw="$(asks 'MySQL/MariaDB root password:')"
    MYSQL_CMD=(mysql -uroot -p"${pw}"); MYCHK_CMD=(mysqlcheck -uroot -p"${pw}")
  fi
  "${MYSQL_CMD[@]}" -e 'SELECT 1' >/dev/null 2>&1
}
myq() { "${MYSQL_CMD[@]}" -t -e "$1" >&2; }
connect_pg() { PSQL_CMD=(${SUDO} -u postgres psql); "${PSQL_CMD[@]}" -tAc 'SELECT 1' >/dev/null 2>&1; }
pgq() { "${PSQL_CMD[@]}" -c "$1" >&2; }

# ---- MySQL/MariaDB actions ----------------------------------------------
my_status() {
  hd "MySQL status"
  myq "SELECT VERSION() AS version;"
  myq "SHOW GLOBAL STATUS WHERE Variable_name IN ('Uptime','Threads_connected','Threads_running','Questions','Slow_queries','Aborted_connects','Max_used_connections');"
}
my_databases() {
  hd "Databases by size"
  myq "SELECT table_schema AS db, ROUND(SUM(data_length+index_length)/1024/1024,2) AS size_mb, COUNT(*) AS tables FROM information_schema.tables GROUP BY table_schema ORDER BY size_mb DESC;"
}
my_processlist() { hd "Process list"; myq "SHOW FULL PROCESSLIST;"; }
my_datetime() {
  hd "Date / time"
  myq "SELECT NOW() AS db_time, @@global.time_zone AS tz, @@system_time_zone AS system_tz;"
  info "System time: $(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)"
}
my_variables() {
  hd "Key configuration"
  myq "SHOW VARIABLES WHERE Variable_name IN ('max_connections','innodb_buffer_pool_size','max_allowed_packet','wait_timeout','interactive_timeout','slow_query_log','long_query_time','character_set_server','collation_server','table_open_cache','tmp_table_size');"
}
my_slowlog() {
  hd "Slow query log"
  myq "SHOW VARIABLES WHERE Variable_name IN ('slow_query_log','slow_query_log_file','long_query_time','log_queries_not_using_indexes');"
  myq "SHOW GLOBAL STATUS LIKE 'Slow_queries';"
}
my_optimize() {
  local db; db="$(ask "Database to optimize ('all' for every DB):" "all")"
  hd "Optimizing ${db}"
  if [ "${db}" = "all" ]; then "${MYCHK_CMD[@]}" -o --all-databases >&2 || warn "optimize failed"
  else "${MYCHK_CMD[@]}" -o --databases "${db}" >&2 || warn "optimize failed"; fi
  info "Analyzing tables..."
  if [ "${db}" = "all" ]; then "${MYCHK_CMD[@]}" -a --all-databases >&2 || true
  else "${MYCHK_CMD[@]}" -a --databases "${db}" >&2 || true; fi
  ok "Done."
}
my_tuner() {
  hd "MySQLTuner"
  if ! command -v mysqltuner >/dev/null 2>&1; then
    info "Fetching mysqltuner..."
    curl -fsSL https://raw.githubusercontent.com/major/MySQLTuner-perl/master/mysqltuner.pl -o /tmp/mysqltuner.pl || { err "download failed"; return; }
    ${SUDO} perl /tmp/mysqltuner.pl >&2 || warn "mysqltuner needs perl + access."
  else
    ${SUDO} mysqltuner >&2 || true
  fi
}

# ---- PostgreSQL actions -------------------------------------------------
pg_status() {
  hd "PostgreSQL status"
  pgq "SELECT version();"
  pgq "SELECT pg_postmaster_start_time() AS started, now()-pg_postmaster_start_time() AS uptime;"
  pgq "SELECT count(*) AS connections FROM pg_stat_activity;"
}
pg_databases() {
  hd "Databases by size"
  pgq "SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size FROM pg_database ORDER BY pg_database_size(datname) DESC;"
}
pg_activity() { hd "Activity"; pgq "SELECT pid, usename, datname, state, wait_event_type, left(query,60) AS query FROM pg_stat_activity ORDER BY state;"; }
pg_datetime() {
  hd "Date / time"
  pgq "SELECT now() AS db_time, current_setting('TimeZone') AS tz;"
  info "System time: $(date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null)"
}
pg_settings() {
  hd "Key configuration"
  pgq "SELECT name, setting, unit FROM pg_settings WHERE name IN ('max_connections','shared_buffers','work_mem','maintenance_work_mem','effective_cache_size','wal_level','max_wal_size','listen_addresses') ORDER BY name;"
}
pg_cache() {
  hd "Cache hit ratio"
  pgq "SELECT sum(blks_hit)*100.0/NULLIF(sum(blks_hit+blks_read),0) AS cache_hit_pct FROM pg_stat_database;"
}
pg_optimize() {
  local db; db="$(ask "Database to VACUUM ANALYZE:" "postgres")"
  hd "VACUUM ANALYZE ${db}"
  ${SUDO} -u postgres psql -d "${db}" -c "VACUUM (ANALYZE, VERBOSE);" >&2 || warn "vacuum failed"
  local rx; rx="$(ask "Also REINDEX database ${db}? [y/N]:" "n")"
  case "${rx}" in y|Y|yes) ${SUDO} -u postgres psql -d "${db}" -c "REINDEX DATABASE \"${db}\";" >&2 || warn "reindex failed" ;; esac
  ok "Done."
}

# ---- menus --------------------------------------------------------------
menu_mysql() {
  printf "%bMySQL/MariaDB — choose an action (q to quit):%b\n" "${C_BOLD}" "${C_RESET}" >&2
  printf "  1) status        2) databases+size   3) process list\n  4) date/time     5) config vars      6) slow query log\n  7) optimize      8) mysqltuner\n" >&2
}
menu_pg() {
  printf "%bPostgreSQL — choose an action (q to quit):%b\n" "${C_BOLD}" "${C_RESET}" >&2
  printf "  1) status        2) databases+size   3) activity\n  4) date/time     5) config settings  6) cache hit ratio\n  7) VACUUM/REINDEX\n" >&2
}

# ---- run ----------------------------------------------------------------
banner
HAVE_MY=0; HAVE_PG=0
command -v mysql >/dev/null 2>&1 && HAVE_MY=1
command -v psql  >/dev/null 2>&1 && HAVE_PG=1
[ "${HAVE_MY}" -eq 0 ] && [ "${HAVE_PG}" -eq 0 ] && { err "No mysql/psql client found. Install a database first."; exit 1; }

ENGINE=""
if [ "${HAVE_MY}" -eq 1 ] && [ "${HAVE_PG}" -eq 1 ]; then
  ENGINE="$(ask "Engine? [mysql/postgres]:" "mysql")"
elif [ "${HAVE_MY}" -eq 1 ]; then ENGINE="mysql"; else ENGINE="postgres"; fi

case "${ENGINE}" in
  mysql|mariadb)
    connect_mysql || { err "Cannot connect to MySQL/MariaDB."; exit 1; }
    ok "Connected to MySQL/MariaDB."
    while true; do
      printf "\n" >&2; menu_mysql
      case "$(ask 'Action:' '')" in
        1) my_status ;; 2) my_databases ;; 3) my_processlist ;; 4) my_datetime ;;
        5) my_variables ;; 6) my_slowlog ;; 7) my_optimize ;; 8) my_tuner ;;
        q|Q|quit|"") break ;; *) warn "Unknown choice." ;;
      esac
    done
    ;;
  postgres|postgresql|pg)
    connect_pg || { err "Cannot connect to PostgreSQL (need sudo to user postgres)."; exit 1; }
    ok "Connected to PostgreSQL."
    while true; do
      printf "\n" >&2; menu_pg
      case "$(ask 'Action:' '')" in
        1) pg_status ;; 2) pg_databases ;; 3) pg_activity ;; 4) pg_datetime ;;
        5) pg_settings ;; 6) pg_cache ;; 7) pg_optimize ;;
        q|Q|quit|"") break ;; *) warn "Unknown choice." ;;
      esac
    done
    ;;
  *) err "Unknown engine: ${ENGINE}"; exit 1 ;;
esac

printf "\n%b✔ database-toolkit finished.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
