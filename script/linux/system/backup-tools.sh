#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# backup-tools.sh — multi-destination backup manager: S3, FTP, SFTP.
# Manages named backup profiles stored in ~/.config/wanforge-scripts/backup-profiles/.
# Each profile holds source path, destination type, and credentials.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/system/backup-tools.sh | bash
#   bash backup-tools.sh --run <profile>   # non-interactive run (for cron)
#
# Requirements by type:
#   S3   — aws CLI v2 (auto-installed from awscli.amazonaws.com)
#   FTP  — lftp     (apt install lftp)
#   SFTP — rsync    (apt install rsync)
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan

set -euo pipefail
TASK="backup-tools"

# --- shared library -------------------------------------------------------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if   [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
elif command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}")
else . <(wget -qO- "${__LIB}"); fi
cfg_load
wf_log_init   # sets WF_LOG_DIR, WF_LOG_FILE, LOG_FILE

# --- engine detection -----------------------------------------------------
# backup-engine.py: Python engine with SQLite resume, parallel workers.
# Lives alongside this script; falls back to native tools if absent.
ENGINE="${__d}/backup-engine.py"
_has_engine() { [ -f "${ENGINE}" ] && have python3; }

# State dir for engine SQLite DB (per-profile, under WF_DATA_DIR)
_bt_state_dir() { printf '%s/backup-state/%s' "${WF_DATA_DIR}" "$1"; }

# --- profile store --------------------------------------------------------
BT_DIR="${XDG_CONFIG_HOME:-${HOME:-/root}/.config}/wanforge-scripts/backup-profiles"
HOSTNAME_S="$(hostname -s)"

_bt_dir()  { mkdir -p "${BT_DIR}"; chmod 700 "${BT_DIR}"; }
_bt_file() { printf '%s/%s.conf' "${BT_DIR}" "$1"; }

_bt_list() {
  local f
  _bt_dir
  while IFS= read -r f; do
    f="${f##*/}"; printf '%s\n' "${f%.conf}"
  done < <(find "${BT_DIR}" -maxdepth 1 -name "*.conf" 2>/dev/null | sort)
}

_bt_load() {
  local file; file="$(_bt_file "$1")"
  [ -f "$file" ] || { err "Profile not found: $1"; return 1; }
  unset BT_NAME BT_TYPE BT_SOURCE BT_SOURCE_TYPE BT_DELETE
  unset BT_S3_ENDPOINT BT_S3_ACCESS_KEY BT_S3_SECRET_KEY BT_S3_BUCKET BT_S3_PREFIX
  unset BT_FTP_HOST BT_FTP_PORT BT_FTP_USER BT_FTP_PASS BT_FTP_DEST BT_FTP_SSL
  unset BT_SFTP_HOST BT_SFTP_PORT BT_SFTP_USER BT_SFTP_KEY BT_SFTP_DEST
  unset BT_DB_TYPE BT_DB_HOST BT_DB_PORT BT_DB_USER BT_DB_PASS BT_DB_SOCKET BT_DB_NAME
  unset BT_ENCRYPT BT_ENCRYPT_PASS
  # shellcheck source=/dev/null
  . "$file"
}

_bt_save() {
  # _bt_save <name> KEY val KEY val ...
  local name="$1"; shift
  local file; file="$(_bt_file "$name")"
  _bt_dir
  : > "$file"; chmod 600 "$file"
  while [ $# -ge 2 ]; do
    printf '%s=%q\n' "$1" "$2" >> "$file"
    shift 2
  done
  ok "Profile '${name}' saved: ${file}"
}

_bt_pick() {
  # Sets BT_PICKED; returns 1 if no profiles or user aborts.
  local names=() n
  while IFS= read -r n; do names+=("$n"); done < <(_bt_list)
  [ ${#names[@]} -gt 0 ] || { warn "No profiles. Add one first."; return 1; }
  if [ ${#names[@]} -eq 1 ]; then BT_PICKED="${names[0]}"; return 0; fi
  MENU=()
  local i; for i in "${!names[@]}"; do
    MENU+=("Profiles|${names[$i]}|${names[$i]}")
  done
  menu_select "Select profile:" || return 1
  BT_PICKED="${MENU_KEY}"
}

# list /home/* dirs (and /root) as backup source candidates
_bt_home_users() {
  local _d
  for _d in /home/*/; do [ -d "${_d}" ] && printf '%s\n' "${_d%/}"; done
  [ -d /root ] && printf '/root\n'
}

# --- tool checks ----------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }
_try_install() {
  local cmd="$1"; shift
  have "$cmd" && return 0
  warn "'${cmd}' not found."
  local ans; ans="$(ask "Install now? ($*) [Y/n]:" "y")"
  [[ "${ans,,}" =~ ^n ]] && { err "Cannot continue without '${cmd}'."; return 1; }
  "$@" || { err "Install failed. Run manually: $*"; return 1; }
  have "$cmd" || { err "'${cmd}' not in PATH after install. Try: hash -r"; return 1; }
  ok "'${cmd}' installed."
}
_need_aws() {
  have aws && return 0
  warn "'aws' not found."
  local ans; ans="$(ask "Install AWS CLI v2 now? [Y/n]:" "y")"
  [[ "${ans,,}" =~ ^n ]] && { err "Cannot continue without 'aws'."; return 1; }
  (
    set -e
    cd /tmp
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
    unzip -q -o awscliv2.zip
    ./aws/install --update
    rm -rf awscliv2.zip aws
  ) || { err "AWS CLI v2 install failed. See https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"; return 1; }
  hash -r
  have aws || { err "'aws' not in PATH. Open new shell or: export PATH=\$PATH:/usr/local/bin"; return 1; }
  ok "AWS CLI v2 installed."
}
_need_lftp()      { _try_install lftp      apt install -y lftp; }
_need_rsync()     { _try_install rsync     apt install -y rsync; }
_need_mysqldump() { _try_install mysqldump apt install -y mysql-client; }
_need_pg_dump()   { _try_install pg_dump   apt install -y postgresql-client; }
_need_sqlite3()   { _try_install sqlite3   apt install -y sqlite3; }
_need_mongodump() { have mongodump || { err "'mongodump' required. See: mongodb.com/try/download/database-tools"; return 1; }; }
_need_openssl()   { _try_install openssl   apt install -y openssl; }

# --- DB dump / encrypt -------------------------------------------------------
_bt_db_dump() {
  # _bt_db_dump <tmp_base> → echoes path of created dump file
  local base="$1" outfile args
  case "${BT_DB_TYPE:-}" in
    mysql|mariadb)
      _need_mysqldump || return 1
      outfile="${base}.sql.gz"; args=()
      [ -n "${BT_DB_HOST:-}"   ] && args+=(-h "${BT_DB_HOST}")
      [ -n "${BT_DB_PORT:-}"   ] && args+=(-P "${BT_DB_PORT}")
      [ -n "${BT_DB_USER:-}"   ] && args+=(-u "${BT_DB_USER}")
      [ -n "${BT_DB_PASS:-}"   ] && args+=("--password=${BT_DB_PASS}")
      [ -n "${BT_DB_SOCKET:-}" ] && args+=(-S "${BT_DB_SOCKET}")
      if [ "${BT_DB_NAME:-all}" = "all" ] || [ -z "${BT_DB_NAME:-}" ]; then
        args+=(--all-databases)
      else
        args+=("${BT_DB_NAME}")
      fi
      args+=(--single-transaction --routines --triggers --events --skip-lock-tables)
      info "Dumping MySQL/MariaDB → $(basename "${outfile}")"
      mysqldump "${args[@]}" | gzip -9 > "${outfile}"
      ;;
    postgresql|postgres|pg)
      _need_pg_dump || return 1
      outfile="${base}.sql.gz"; args=()
      [ -n "${BT_DB_HOST:-}" ] && args+=(-h "${BT_DB_HOST}")
      [ -n "${BT_DB_PORT:-}" ] && args+=(-p "${BT_DB_PORT}")
      [ -n "${BT_DB_USER:-}" ] && args+=(-U "${BT_DB_USER}")
      if [ "${BT_DB_NAME:-all}" = "all" ] || [ -z "${BT_DB_NAME:-}" ]; then
        info "Dumping all PostgreSQL DBs → $(basename "${outfile}")"
        PGPASSWORD="${BT_DB_PASS:-}" pg_dumpall "${args[@]}" | gzip -9 > "${outfile}"
      else
        info "Dumping PostgreSQL '${BT_DB_NAME}' → $(basename "${outfile}")"
        PGPASSWORD="${BT_DB_PASS:-}" pg_dump "${args[@]}" "${BT_DB_NAME}" | gzip -9 > "${outfile}"
      fi
      ;;
    sqlite|sqlite3)
      _need_sqlite3 || return 1
      [ -f "${BT_DB_NAME:-}" ] || { err "SQLite file not found: ${BT_DB_NAME:-}"; return 1; }
      outfile="${base}.sql.gz"
      info "Dumping SQLite '${BT_DB_NAME}' → $(basename "${outfile}")"
      sqlite3 "${BT_DB_NAME}" ".dump" | gzip -9 > "${outfile}"
      ;;
    mongodb|mongo)
      _need_mongodump || return 1
      outfile="${base}.tar.gz"; args=(--out "$(mktemp -d)")
      [ -n "${BT_DB_HOST:-}" ] && args+=(--host "${BT_DB_HOST}")
      [ -n "${BT_DB_PORT:-}" ] && args+=(--port "${BT_DB_PORT}")
      [ -n "${BT_DB_USER:-}" ] && args+=(--username "${BT_DB_USER}")
      [ -n "${BT_DB_PASS:-}" ] && args+=(--password "${BT_DB_PASS}")
      [ "${BT_DB_NAME:-all}" = "all" ] || args+=(--db "${BT_DB_NAME}")
      info "Dumping MongoDB → $(basename "${outfile}")"
      local mongo_tmp="${args[1]}"
      mongodump "${args[@]}" 2>/dev/null
      tar czf "${outfile}" -C "${mongo_tmp}" .
      rm -rf "${mongo_tmp}"
      ;;
    redis)
      have redis-cli || { err "'redis-cli' required. Install: apt install redis-tools"; return 1; }
      outfile="${base}.rdb.gz"
      local rcli_args=()
      [ -n "${BT_DB_HOST:-}" ] && rcli_args+=(-h "${BT_DB_HOST}")
      [ -n "${BT_DB_PORT:-}" ] && rcli_args+=(-p "${BT_DB_PORT}")
      [ -n "${BT_DB_PASS:-}" ] && rcli_args+=(-a "${BT_DB_PASS}")
      local rdb_dir rdb_fn
      rdb_dir="$(redis-cli "${rcli_args[@]}" CONFIG GET dir        2>/dev/null | tail -1 || true)"
      rdb_fn="$( redis-cli "${rcli_args[@]}" CONFIG GET dbfilename 2>/dev/null | tail -1 || true)"
      redis-cli "${rcli_args[@]}" BGSAVE >/dev/null 2>&1 || true; sleep 2
      local rdb_path="${rdb_dir}/${rdb_fn}"
      [ -f "${rdb_path}" ] || { err "Redis RDB not found: ${rdb_path}"; return 1; }
      info "Dumping Redis RDB → $(basename "${outfile}")"
      gzip -9 -c "${rdb_path}" > "${outfile}"
      ;;
    *)
      err "Unknown DB type '${BT_DB_TYPE:-}'. Supported: mysql, mariadb, postgresql, sqlite, mongodb, redis"
      return 1 ;;
  esac
  printf '%s\n' "${outfile}"
}

_bt_encrypt_file() {
  # encrypts <file> AES-256-CBC, removes original, echoes new path
  local inp="$1"
  _need_openssl || return 1
  local enc="${inp}.enc"
  openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
    -pass pass:"${BT_ENCRYPT_PASS:-}" -in "${inp}" -out "${enc}"
  rm -f "${inp}"
  printf '%s\n' "${enc}"
}

_run_db_s3() {
  local dumpfile="$1" fname prefix
  prefix="${BT_S3_PREFIX:-${HOSTNAME_S}/${BT_NAME}}"; fname="$(basename "${dumpfile}")"
  _need_aws || return 1
  info "Uploading → s3://${BT_S3_BUCKET}/${prefix}/${fname}"
  AWS_ACCESS_KEY_ID="${BT_S3_ACCESS_KEY}" AWS_SECRET_ACCESS_KEY="${BT_S3_SECRET_KEY}" \
    aws s3 cp "${dumpfile}" "s3://${BT_S3_BUCKET}/${prefix}/${fname}" \
      --endpoint-url "${BT_S3_ENDPOINT}" --no-progress
}

_run_db_ftp() {
  local dumpfile="$1" fname port dest ssl_opts="" protocol="ftp"
  port="${BT_FTP_PORT:-21}"; dest="${BT_FTP_DEST:-/backups}"; fname="$(basename "${dumpfile}")"
  _need_lftp || return 1
  case "${BT_FTP_SSL:-off}" in
    explicit) ssl_opts="set ftp:ssl-force true; set ftp:ssl-protect-data true;" ;;
    implicit) ssl_opts="set ftp:ssl-force true;"; protocol="ftps" ;;
    *)        ssl_opts="set ftp:ssl-allow false;" ;;
  esac
  info "Uploading → ftp://${BT_FTP_HOST}:${port}${dest}/${fname}"
  lftp -u "${BT_FTP_USER},${BT_FTP_PASS}" "${protocol}://${BT_FTP_HOST}:${port}" \
    -e "${ssl_opts} mkdir -p '${dest}'; put '${dumpfile}' -o '${dest}/${fname}'; quit"
}

_run_db_sftp() {
  local dumpfile="$1" port dest ssh_e
  port="${BT_SFTP_PORT:-22}"; dest="${BT_SFTP_DEST:-/backups}"
  _need_rsync || return 1
  ssh_e="ssh -o StrictHostKeyChecking=accept-new -p ${port}"
  [ -n "${BT_SFTP_KEY:-}" ] && ssh_e="${ssh_e} -i ${BT_SFTP_KEY}"
  info "Uploading → ${BT_SFTP_USER}@${BT_SFTP_HOST}:${dest}/"
  # shellcheck disable=SC2086
  rsync -avz --progress -e "${ssh_e}" "${dumpfile}" "${BT_SFTP_USER}@${BT_SFTP_HOST}:${dest}/"
}

_run_db() {
  local dry="${1:-}"
  local ts; ts="$(date +%Y%m%d_%H%M%S)"
  local tmp_base="/tmp/wf-db-${BT_NAME}-${ts}-$$"

  hd "DB Backup — ${BT_NAME} [${BT_DB_TYPE:-?}${dry:+, dry-run}]"
  info "DB type : ${BT_DB_TYPE:-?}"
  info "DB name : ${BT_DB_NAME:-all}"
  info "Dest    : ${BT_TYPE:-?}"
  [ "${BT_ENCRYPT:-0}" = "1" ] && info "Encrypt : AES-256-CBC"

  if [ -n "${dry}" ]; then
    info "[dry-run] would dump ${BT_DB_TYPE:-?} '${BT_DB_NAME:-all}' and upload to ${BT_TYPE:-?}"
    return 0
  fi

  local dump_file
  dump_file="$(_bt_db_dump "${tmp_base}")" || { rm -f "${tmp_base}"* 2>/dev/null; return 1; }
  ok "Dump: $(basename "${dump_file}")"

  if [ "${BT_ENCRYPT:-0}" = "1" ]; then
    hd "Encrypting"
    dump_file="$(_bt_encrypt_file "${dump_file}")" || { rm -f "${dump_file}"; return 1; }
    ok "Encrypted: $(basename "${dump_file}")"
  fi

  # rename to <profile>_<timestamp>.<ext>  before uploading
  local bn ext upload_file
  bn="$(basename "${dump_file}")"; ext="${bn#*.}"
  upload_file="/tmp/${BT_NAME}_${ts}.${ext}"
  mv "${dump_file}" "${upload_file}"

  local rc=0
  case "${BT_TYPE:-}" in
    s3)   _run_db_s3   "${upload_file}" || rc=$? ;;
    ftp)  _run_db_ftp  "${upload_file}" || rc=$? ;;
    sftp) _run_db_sftp "${upload_file}" || rc=$? ;;
    *)    err "Unknown destination type: ${BT_TYPE}"; rc=1 ;;
  esac
  rm -f "${upload_file}"
  return $rc
}

# --- backup runners -------------------------------------------------------
# Each runner tries backup-engine.py first (SQLite resume, parallel, delete-sync).
# Falls back to native tool if engine or its deps are missing.

_run_engine() {
  # _run_engine [--dry-run] [--force] [--skip-scan] [--status]
  local state_dir; state_dir="$(_bt_state_dir "${BT_NAME}")"
  mkdir -p "${state_dir}"; chmod 700 "${state_dir}"
  BACKUP_PROFILE="${BT_NAME}"       \
  BACKUP_TYPE="${BT_TYPE}"          \
  BACKUP_SOURCE="${BT_SOURCE}"      \
  BACKUP_DELETE="${BT_DELETE:-0}"   \
  BACKUP_STATE_DIR="${state_dir}"   \
  BACKUP_LOG_FILE="${WF_LOG_FILE:-}" \
  BACKUP_S3_ENDPOINT="${BT_S3_ENDPOINT:-}"   \
  BACKUP_S3_ACCESS_KEY="${BT_S3_ACCESS_KEY:-}" \
  BACKUP_S3_SECRET_KEY="${BT_S3_SECRET_KEY:-}" \
  BACKUP_S3_BUCKET="${BT_S3_BUCKET:-}"         \
  BACKUP_S3_PREFIX="${BT_S3_PREFIX:-${HOSTNAME_S}/${BT_NAME}}" \
  BACKUP_FTP_HOST="${BT_FTP_HOST:-}"  BACKUP_FTP_PORT="${BT_FTP_PORT:-21}" \
  BACKUP_FTP_USER="${BT_FTP_USER:-}"  BACKUP_FTP_PASS="${BT_FTP_PASS:-}"   \
  BACKUP_FTP_DEST="${BT_FTP_DEST:-/}" BACKUP_FTP_SSL="${BT_FTP_SSL:-off}"  \
  BACKUP_SFTP_HOST="${BT_SFTP_HOST:-}"  BACKUP_SFTP_PORT="${BT_SFTP_PORT:-22}" \
  BACKUP_SFTP_USER="${BT_SFTP_USER:-}"  BACKUP_SFTP_KEY="${BT_SFTP_KEY:-}"     \
  BACKUP_SFTP_DEST="${BT_SFTP_DEST:-}"  \
    python3 "${ENGINE}" "$@"
}

_run_s3() {
  local dry="${1:-}"
  local prefix="${BT_S3_PREFIX:-${HOSTNAME_S}/${BT_NAME}}"
  info "Source  : ${BT_SOURCE}"
  info "Target  : s3://${BT_S3_BUCKET}/${prefix}"
  info "Endpoint: ${BT_S3_ENDPOINT}"

  if _has_engine; then
    info "Engine  : backup-engine.py (SQLite resume, parallel)"
    local args=(); [ -n "$dry" ] && args+=("--dry-run")
    _run_engine "${args[@]+"${args[@]}"}"
    return $?
  fi

  # fallback: aws s3 sync
  _need_aws || return 1
  info "Engine  : aws s3 sync (fallback)"
  local args=()
  [ "${BT_DELETE:-0}" = "1" ] && args+=("--delete")
  [ -n "$dry" ] && args+=("--dryrun")
  AWS_ACCESS_KEY_ID="${BT_S3_ACCESS_KEY}" \
  AWS_SECRET_ACCESS_KEY="${BT_S3_SECRET_KEY}" \
    aws s3 sync "${BT_SOURCE}/" "s3://${BT_S3_BUCKET}/${prefix}" \
      --endpoint-url "${BT_S3_ENDPOINT}" \
      --no-progress \
      "${args[@]+"${args[@]}"}"
}

_run_ftp() {
  local dry="${1:-}"
  local port="${BT_FTP_PORT:-21}"
  local dest="${BT_FTP_DEST:-/}"
  info "Source  : ${BT_SOURCE}"
  info "Target  : ftp://${BT_FTP_HOST}:${port}${dest}"
  info "SSL     : ${BT_FTP_SSL:-off}"

  if _has_engine; then
    info "Engine  : backup-engine.py (SQLite resume, parallel)"
    local args=(); [ -n "$dry" ] && args+=("--dry-run")
    _run_engine "${args[@]+"${args[@]}"}"
    return $?
  fi

  # fallback: lftp
  _need_lftp || return 1
  info "Engine  : lftp (fallback)"
  local ssl_opts="" protocol="ftp"
  case "${BT_FTP_SSL:-off}" in
    explicit) ssl_opts="set ftp:ssl-force true; set ftp:ssl-protect-data true;" ;;
    implicit) ssl_opts="set ftp:ssl-force true;"; protocol="ftps" ;;
    *)        ssl_opts="set ftp:ssl-allow false;" ;;
  esac
  local mirror_opts="-R --parallel=4 --verbose=1"
  [ "${BT_DELETE:-0}" = "1" ] && mirror_opts="${mirror_opts} --delete"
  [ -n "$dry" ] && mirror_opts="${mirror_opts} --dry-run"
  lftp -u "${BT_FTP_USER},${BT_FTP_PASS}" \
    "${protocol}://${BT_FTP_HOST}:${port}" \
    -e "${ssl_opts} mirror ${mirror_opts} '${BT_SOURCE}/' '${dest}'; quit"
}

_run_sftp() {
  local dry="${1:-}"
  local port="${BT_SFTP_PORT:-22}"
  info "Source  : ${BT_SOURCE}"
  info "Target  : ${BT_SFTP_USER}@${BT_SFTP_HOST}:${port}${BT_SFTP_DEST}"
  [ -n "${BT_SFTP_KEY:-}" ] && info "Key     : ${BT_SFTP_KEY}"

  if _has_engine; then
    info "Engine  : backup-engine.py (SQLite resume, parallel)"
    local args=(); [ -n "$dry" ] && args+=("--dry-run")
    _run_engine "${args[@]+"${args[@]}"}"
    return $?
  fi

  # fallback: rsync
  _need_rsync || return 1
  info "Engine  : rsync (fallback)"
  local ssh_e="ssh -o StrictHostKeyChecking=accept-new -p ${port}"
  [ -n "${BT_SFTP_KEY:-}" ] && ssh_e="${ssh_e} -i ${BT_SFTP_KEY}"
  local rflags="-avz --progress"
  [ "${BT_DELETE:-0}" = "1" ] && rflags="${rflags} --delete"
  [ -n "$dry" ] && rflags="${rflags} --dry-run"
  # shellcheck disable=SC2086
  rsync ${rflags} -e "${ssh_e}" \
    "${BT_SOURCE}/" "${BT_SFTP_USER}@${BT_SFTP_HOST}:${BT_SFTP_DEST}"
}

_run_one() {
  local name="$1" dry="${2:-}"
  _bt_load "$name" || return 1
  local rc=0
  if [ "${BT_SOURCE_TYPE:-dir}" = "db" ]; then
    _run_db "$dry" || rc=$?
  else
    local type_label; type_label="$(printf '%s' "${BT_TYPE:-?}" | tr '[:lower:]' '[:upper:]')"
    hd "${type_label} Backup — ${name}${dry:+ (dry-run)}"
    case "${BT_TYPE:-}" in
      s3)   _run_s3   "$dry" || rc=$? ;;
      ftp)  _run_ftp  "$dry" || rc=$? ;;
      sftp) _run_sftp "$dry" || rc=$? ;;
      *)    err "Unknown type '${BT_TYPE}' in profile '${name}'"; return 1 ;;
    esac
  fi
  [ $rc -eq 0 ] && ok "Done: ${name}" || { err "Failed: ${name} (exit ${rc})"; return 1; }
}

# --- actions --------------------------------------------------------------

_a_add_db() {
  hd "Add database backup profile"
  local name; name="$(ask "Profile name (e.g. mysql-daily):" "")"; name="${name//[^a-zA-Z0-9_-]/}"
  [ -n "${name}" ] || { err "Profile name required."; return 1; }
  local file; file="$(_bt_file "${name}")"
  if [ -f "${file}" ]; then
    local ow; ow="$(ask "Profile '${name}' exists. Overwrite? [y/N]:" "n")"
    [[ "${ow}" =~ ^[Yy] ]] || return 0
  fi

  MENU=(
    "DB|mysql|MySQL / MariaDB — mysqldump, all DBs or single"
    "DB|postgresql|PostgreSQL — pg_dump / pg_dumpall"
    "DB|sqlite|SQLite — .dump to SQL"
    "DB|mongodb|MongoDB — mongodump (tar.gz)"
    "DB|redis|Redis — BGSAVE + RDB copy"
  )
  menu_select "Database type:" || return 0

  local db_type="${MENU_KEY}" db_host="" db_port="" db_user="" db_pass="" db_name="" db_socket=""
  case "$db_type" in
    mysql)
      db_host="$(ask_cfg   CFG_BT_DB_HOST   "DB Host:"                        "localhost")"
      db_port="$(ask_cfg   CFG_BT_DB_PORT   "DB Port:"                        "3306")"
      db_user="$(ask_cfg   CFG_BT_DB_USER   "DB Username:"                    "root")"
      db_pass="$(asks_cfg  CFG_BT_DB_PASS   "DB Password:")"
      db_socket="$(ask_cfg CFG_BT_DB_SOCK   "MySQL socket (blank=use tcp):"   "")"
      db_name="$(ask_cfg   CFG_BT_DB_NAME   "Database name ('all'=all DBs):"  "all")"
      ;;
    postgresql)
      db_host="$(ask_cfg  CFG_BT_DB_HOST   "DB Host:"                         "localhost")"
      db_port="$(ask_cfg  CFG_BT_DB_PORT   "DB Port:"                         "5432")"
      db_user="$(ask_cfg  CFG_BT_DB_USER   "DB Username:"                     "postgres")"
      db_pass="$(asks_cfg CFG_BT_DB_PASS   "DB Password:")"
      db_name="$(ask_cfg  CFG_BT_DB_NAME   "Database name ('all'=dump all DBs, requires admin):" "all")"
      ;;
    sqlite)
      info "Provide the full path to the .db / .sqlite file on this server."
      db_name="$(ask_cfg  CFG_BT_DB_NAME   "SQLite file path:"                "")"
      ;;
    mongodb)
      db_host="$(ask_cfg  CFG_BT_DB_HOST   "DB Host:"                         "localhost")"
      db_port="$(ask_cfg  CFG_BT_DB_PORT   "DB Port:"                         "27017")"
      db_user="$(ask_cfg  CFG_BT_DB_USER   "DB Username (blank=no auth):"     "")"
      db_pass="$(asks_cfg CFG_BT_DB_PASS   "DB Password:")"
      db_name="$(ask_cfg  CFG_BT_DB_NAME   "Database name ('all'=all DBs):"   "all")"
      ;;
    redis)
      db_host="$(ask_cfg  CFG_BT_DB_HOST   "Redis Host:"                      "127.0.0.1")"
      db_port="$(ask_cfg  CFG_BT_DB_PORT   "Redis Port:"                      "6379")"
      db_pass="$(asks_cfg CFG_BT_DB_PASS   "Redis Password (blank=none):")"
      ;;
  esac

  hd "Encryption"
  info "Dump is encrypted before upload. Passphrase stored in profile (chmod 600)."
  info "Encrypted filename: <profile>_<timestamp>.sql.gz.enc  (decrypt: openssl enc -d -aes-256-cbc -pbkdf2)"
  MENU=(
    "Encryption|none|None — store dump as-is"
    "Encryption|aes|AES-256-CBC (openssl pbkdf2, passphrase-based)"
  )
  menu_select "Encryption:" || return 0
  local do_enc=0 enc_pass=""
  if [ "${MENU_KEY}" = "aes" ]; then
    do_enc=1; enc_pass="$(asks_cfg CFG_BT_ENCRYPT_PASS "Encryption passphrase:")"
  fi

  MENU=(
    "Destination|s3|S3 / S3-compatible (AWS, IDCloudHost, MinIO…)"
    "Destination|ftp|FTP / FTPS"
    "Destination|sftp|SFTP (SSH + rsync)"
  )
  menu_select "Destination type:" || return 0
  local tc="${MENU_KEY}"

  local ep ak sk bkt pfx host port user pass dest ssl key
  case "$tc" in
    s3)
      ep="$(ask_cfg  CFG_BT_S3_ENDPOINT   "S3 Endpoint URL:"   "https://is3.cloudhost.id")"
      ak="$(ask_cfg  CFG_BT_S3_ACCESS_KEY "S3 Access Key:"     "")"
      sk="$(asks_cfg CFG_BT_S3_SECRET_KEY "S3 Secret Key:")"
      bkt="$(ask_cfg CFG_BT_S3_BUCKET     "S3 Bucket name:"    "")"
      pfx="$(ask_cfg CFG_BT_S3_PREFIX     "S3 Prefix:"         "${HOSTNAME_S}/${name}")"
      ;;
    ftp)
      host="$(ask_cfg  CFG_BT_FTP_HOST "FTP Host:"      "")"; port="$(ask_cfg CFG_BT_FTP_PORT "FTP Port:" "21")"
      user="$(ask_cfg  CFG_BT_FTP_USER "FTP Username:"  "")"; pass="$(asks_cfg CFG_BT_FTP_PASS "FTP Password:")"
      dest="$(ask_cfg  CFG_BT_FTP_DEST "Remote path:"   "/backups")"
      MENU=(
        "SSL|off|No SSL"
        "SSL|explicit|Explicit TLS (STARTTLS)"
        "SSL|implicit|Implicit TLS (port 990)"
      )
      menu_select "FTP SSL mode:" || return 0
      ssl="${MENU_KEY}"
      ;;
    sftp)
      host="$(ask_cfg  CFG_BT_SFTP_HOST "SFTP Host:"                  "")"; port="$(ask_cfg CFG_BT_SFTP_PORT "SFTP Port:" "22")"
      user="$(ask_cfg  CFG_BT_SFTP_USER "SFTP Username:"              "")"; key="$(ask_cfg CFG_BT_SFTP_KEY "SSH key (blank=agent):" "")"
      dest="$(ask_cfg  CFG_BT_SFTP_DEST "Remote destination path:"    "/backups")"
      ;;
  esac

  local bt_src
  case "$db_type" in
    mysql|mariadb) bt_src="mysql://${db_user:-root}@${db_host:-localhost}/${db_name:-all}" ;;
    postgresql)    bt_src="pg://${db_user:-postgres}@${db_host:-localhost}/${db_name:-all}" ;;
    sqlite)        bt_src="sqlite://${db_name:-?}" ;;
    mongodb)       bt_src="mongodb://${db_host:-localhost}/${db_name:-all}" ;;
    redis)         bt_src="redis://${db_host:-127.0.0.1}:${db_port:-6379}" ;;
    *)             bt_src="${db_type}://${db_name:-?}" ;;
  esac

  case "$tc" in
    s3) _bt_save "${name}" \
         BT_NAME "${name}" BT_TYPE "s3"   BT_SOURCE_TYPE "db" BT_SOURCE "${bt_src}" BT_DELETE "0" \
         BT_DB_TYPE "${db_type}" BT_DB_HOST "${db_host}" BT_DB_PORT "${db_port}" \
         BT_DB_USER "${db_user}" BT_DB_PASS "${db_pass}" BT_DB_NAME "${db_name}" BT_DB_SOCKET "${db_socket}" \
         BT_ENCRYPT "${do_enc}" BT_ENCRYPT_PASS "${enc_pass}" \
         BT_S3_ENDPOINT "${ep}" BT_S3_ACCESS_KEY "${ak}" BT_S3_SECRET_KEY "${sk}" \
         BT_S3_BUCKET "${bkt}" BT_S3_PREFIX "${pfx}" ;;
    ftp) _bt_save "${name}" \
         BT_NAME "${name}" BT_TYPE "ftp"  BT_SOURCE_TYPE "db" BT_SOURCE "${bt_src}" BT_DELETE "0" \
         BT_DB_TYPE "${db_type}" BT_DB_HOST "${db_host}" BT_DB_PORT "${db_port}" \
         BT_DB_USER "${db_user}" BT_DB_PASS "${db_pass}" BT_DB_NAME "${db_name}" BT_DB_SOCKET "${db_socket}" \
         BT_ENCRYPT "${do_enc}" BT_ENCRYPT_PASS "${enc_pass}" \
         BT_FTP_HOST "${host}" BT_FTP_PORT "${port}" BT_FTP_USER "${user}" \
         BT_FTP_PASS "${pass}" BT_FTP_DEST "${dest}" BT_FTP_SSL "${ssl:-off}" ;;
    sftp) _bt_save "${name}" \
         BT_NAME "${name}" BT_TYPE "sftp" BT_SOURCE_TYPE "db" BT_SOURCE "${bt_src}" BT_DELETE "0" \
         BT_DB_TYPE "${db_type}" BT_DB_HOST "${db_host}" BT_DB_PORT "${db_port}" \
         BT_DB_USER "${db_user}" BT_DB_PASS "${db_pass}" BT_DB_NAME "${db_name}" BT_DB_SOCKET "${db_socket}" \
         BT_ENCRYPT "${do_enc}" BT_ENCRYPT_PASS "${enc_pass}" \
         BT_SFTP_HOST "${host}" BT_SFTP_PORT "${port}" BT_SFTP_USER "${user}" \
         BT_SFTP_KEY "${key:-}" BT_SFTP_DEST "${dest}" ;;
  esac

  local tr; tr="$(ask "Run dry-run test now? [y/N]:" "n")"
  [[ "$tr" =~ ^[Yy] ]] && _run_one "${name}" "dry"
}

a_add() {
  hd "Add backup profile(s)"

  # --- step 0: source type ---
  MENU=(
    "Source|dir|Directory / files — sync a folder to S3/FTP/SFTP"
    "Source|db|Database — dump MySQL, MariaDB, PostgreSQL, SQLite, MongoDB, or Redis"
  )
  menu_select "What do you want to back up?" || return 0
  if [ "${MENU_KEY}" = "db" ]; then _a_add_db; return $?; fi

  # --- step 1: select source(s) via checkbox ---
  local _hdir _homes=()
  while IFS= read -r _hdir; do _homes+=("$_hdir"); done < <(_bt_home_users)

  # sources array: interleaved (name, path) pairs
  local _sources=()

  if [ ${#_homes[@]} -gt 0 ]; then
    MENU=()
    local _hi
    for _hi in "${!_homes[@]}"; do
      local _uname="${_homes[$_hi]##*/}"
      MENU+=("User|${_uname}|${_homes[$_hi]}")
    done
    MENU+=("User|__custom__|enter custom path")

    checkbox "Select users / home directories to backup:" || { info "Cancelled."; return 0; }
    [ "${#CHOSEN_KEYS[@]}" -eq 0 ] && { info "Nothing selected."; return 0; }

    info "Suffix is appended to each selected username to form the profile name."
    info "  Example: suffix 'daily'  →  alice-daily, deploy-daily, root-daily"
    local _sfx
    _sfx="$(ask "Suffix [backup]:" "backup")"
    _sfx="${_sfx:-backup}"

    local _key
    for _key in "${CHOSEN_KEYS[@]}"; do
      if [ "${_key}" = "__custom__" ]; then
        local _cn _cp
        _cn="$(ask "Custom profile name:" "")"; _cn="${_cn//[^a-zA-Z0-9_-]/}"
        [ -n "${_cn}" ] || { warn "Skipping: empty profile name."; continue; }
        _cp="$(ask_cfg CFG_BT_SOURCE "Custom source path:" "/home")"
        _sources+=("${_cn}" "${_cp}")
      else
        local _src=""
        for _hdir in "${_homes[@]}"; do
          [ "${_hdir##*/}" = "${_key}" ] && _src="${_hdir}" && break
        done
        _sources+=("${_key}-${_sfx}" "${_src}")
      fi
    done
  else
    local _n _p
    _n="$(ask "Profile name (e.g. web-daily):" "")"; _n="${_n//[^a-zA-Z0-9_-]/}"
    [ -n "${_n}" ] || { err "Profile name required."; return 1; }
    _p="$(ask_cfg CFG_BT_SOURCE "Source directory to backup:" "/home")"
    _sources+=("${_n}" "${_p}")
  fi

  [ "${#_sources[@]}" -eq 0 ] && { warn "No sources selected."; return 0; }

  # --- step 2: common options ---
  info "Sync-delete: files removed from source are also removed from the destination."
  warn "Enable only when source is the single authoritative copy — dangerous for incremental backups."
  local del do_del=0
  del="$(ask "Enable sync-delete? [y/N]:" "n")"
  [[ "$del" =~ ^[Yy] ]] && do_del=1

  # --- step 3: destination (asked once, applied to all profiles) ---
  MENU=(
    "Destination|s3|S3 / S3-compatible (AWS, IDCloudHost, MinIO…)"
    "Destination|ftp|FTP / FTPS"
    "Destination|sftp|SFTP (SSH + rsync)"
  )
  menu_select "Destination type (applies to all selected profiles):" || return 0
  local tc="${MENU_KEY}"

  local ep ak sk bkt pfx_base host port user pass dest ssl key
  case "$tc" in
    s3)
      ep="$(ask_cfg  CFG_BT_S3_ENDPOINT   "S3 Endpoint URL:"                        "https://is3.cloudhost.id")"
      ak="$(ask_cfg  CFG_BT_S3_ACCESS_KEY "S3 Access Key:"                          "")"
      sk="$(asks_cfg CFG_BT_S3_SECRET_KEY "S3 Secret Key:")"
      bkt="$(ask_cfg CFG_BT_S3_BUCKET     "S3 Bucket name:"                         "")"
      pfx_base="$(ask_cfg CFG_BT_S3_PREFIX "S3 Prefix base (profile name appended):" "${HOSTNAME_S}")"
      ;;
    ftp)
      host="$(ask_cfg  CFG_BT_FTP_HOST "FTP Host:"                                  "")"
      port="$(ask_cfg  CFG_BT_FTP_PORT "FTP Port:"                                  "21")"
      user="$(ask_cfg  CFG_BT_FTP_USER "FTP Username:"                              "")"
      pass="$(asks_cfg CFG_BT_FTP_PASS "FTP Password:")"
      dest="$(ask_cfg  CFG_BT_FTP_DEST "Remote base path (profile name appended):"  "/backups")"
      MENU=(
        "SSL|off|No SSL"
        "SSL|explicit|Explicit TLS (STARTTLS)"
        "SSL|implicit|Implicit TLS (port 990)"
      )
      menu_select "FTP SSL mode:" || return 0
      ssl="${MENU_KEY}"
      ;;
    sftp)
      host="$(ask_cfg  CFG_BT_SFTP_HOST "SFTP Host:"                                "")"
      port="$(ask_cfg  CFG_BT_SFTP_PORT "SFTP Port:"                                "22")"
      user="$(ask_cfg  CFG_BT_SFTP_USER "SFTP Username:"                            "")"
      key="$(ask_cfg   CFG_BT_SFTP_KEY  "SSH key path (blank=agent):"               "")"
      dest="$(ask_cfg  CFG_BT_SFTP_DEST "Remote base path (profile name appended):" "/backups")"
      ;;
  esac

  # --- step 4: create one profile per source ---
  local _name _src _i=0
  while [ "${_i}" -lt "${#_sources[@]}" ]; do
    _name="${_sources[$_i]}"; _src="${_sources[$((_i+1))]}"; _i=$((_i+2))
    local _file; _file="$(_bt_file "${_name}")"
    if [ -f "${_file}" ]; then
      local _ow; _ow="$(ask "Profile '${_name}' exists. Overwrite? [y/N]:" "n")"
      [[ "${_ow}" =~ ^[Yy] ]] || { info "Skipping ${_name}."; continue; }
    fi
    case "$tc" in
      s3) _bt_save "${_name}" \
           BT_NAME "${_name}" BT_TYPE "s3"   BT_SOURCE "${_src}" BT_DELETE "${do_del}" \
           BT_S3_ENDPOINT "${ep}" BT_S3_ACCESS_KEY "${ak}" BT_S3_SECRET_KEY "${sk}" \
           BT_S3_BUCKET "${bkt}" BT_S3_PREFIX "${pfx_base}/${_name}" ;;
      ftp) _bt_save "${_name}" \
           BT_NAME "${_name}" BT_TYPE "ftp"  BT_SOURCE "${_src}" BT_DELETE "${do_del}" \
           BT_FTP_HOST "${host}" BT_FTP_PORT "${port}" BT_FTP_USER "${user}" \
           BT_FTP_PASS "${pass}" BT_FTP_DEST "${dest}/${_name}" BT_FTP_SSL "${ssl}" ;;
      sftp) _bt_save "${_name}" \
           BT_NAME "${_name}" BT_TYPE "sftp" BT_SOURCE "${_src}" BT_DELETE "${do_del}" \
           BT_SFTP_HOST "${host}" BT_SFTP_PORT "${port}" BT_SFTP_USER "${user}" \
           BT_SFTP_KEY "${key}" BT_SFTP_DEST "${dest}/${_name}" ;;
    esac
  done

  local tr; tr="$(ask "Run dry-run test for all created profiles? [y/N]:" "n")"
  if [[ "$tr" =~ ^[Yy] ]]; then
    _i=0
    while [ "${_i}" -lt "${#_sources[@]}" ]; do
      _name="${_sources[$_i]}"; _i=$((_i+2))
      [ -f "$(_bt_file "${_name}")" ] && _run_one "${_name}" "dry"
    done
  fi
}

a_list() {
  hd "Backup profiles (${BT_DIR})"
  local names=() n
  while IFS= read -r n; do names+=("$n"); done < <(_bt_list)
  if [ ${#names[@]} -eq 0 ]; then
    warn "No profiles configured."
    return 0
  fi
  for n in "${names[@]}"; do
    (
      _bt_load "$n" 2>/dev/null || exit 0
      local target=""
      case "${BT_TYPE:-}" in
        s3)   target="s3://${BT_S3_BUCKET:-?}/${BT_S3_PREFIX:-?}" ;;
        ftp)  target="ftp://${BT_FTP_HOST:-?}:${BT_FTP_PORT:-21}${BT_FTP_DEST:-/}" ;;
        sftp) target="${BT_SFTP_USER:-?}@${BT_SFTP_HOST:-?}:${BT_SFTP_PORT:-22}${BT_SFTP_DEST:-/}" ;;
      esac
      printf "  %b●%b %-22s %b[%s]%b  %s → %s\n" \
        "${C_GREEN}" "${C_RESET}" "${n}" \
        "${C_CYAN}" "${BT_TYPE:-?}" "${C_RESET}" \
        "${BT_SOURCE:-?}" "${target}" >&2
    )
  done
}

a_delete() {
  hd "Delete backup profile(s)"
  local names=() n
  while IFS= read -r n; do names+=("$n"); done < <(_bt_list)
  [ ${#names[@]} -gt 0 ] || { warn "No profiles configured."; return 0; }

  MENU=()
  for n in "${names[@]}"; do
    local _desc
    _desc="$(
      _bt_load "${n}" 2>/dev/null || true
      case "${BT_TYPE:-}" in
        s3)   printf '[s3]   %s → s3://%s' "${BT_SOURCE:-?}" "${BT_S3_BUCKET:-?}" ;;
        ftp)  printf '[ftp]  %s → %s' "${BT_SOURCE:-?}" "${BT_FTP_HOST:-?}" ;;
        sftp) printf '[sftp] %s → %s@%s' "${BT_SOURCE:-?}" "${BT_SFTP_USER:-?}" "${BT_SFTP_HOST:-?}" ;;
        *)    printf '[?] %s' "${BT_SOURCE:-?}" ;;
      esac
    )"
    MENU+=("Profile|${n}|${_desc}")
  done

  checkbox "Select profiles to delete:" 0 || { info "Cancelled."; return 0; }
  [ "${#CHOSEN_KEYS[@]}" -eq 0 ] && { info "Nothing selected."; return 0; }

  confirm_critical "permanently delete ${#CHOSEN_KEYS[@]} profile(s): ${CHOSEN_KEYS[*]}" "delete" || return 0

  for n in "${CHOSEN_KEYS[@]}"; do
    rm -f "$(_bt_file "${n}")"
    ok "Deleted: ${n}"
  done
}

a_dump() {
  BT_PICKED=""; _bt_pick || return 0
  _bt_load "${BT_PICKED}" || return 0
  [ "${BT_SOURCE_TYPE:-dir}" = "db" ] || { warn "'${BT_PICKED}' is not a DB profile (source_type=dir)."; return 0; }
  local ts; ts="$(date +%Y%m%d_%H%M%S)"
  local out_dir; out_dir="$(ask "Output directory [${HOME}]:" "${HOME}")"; out_dir="${out_dir:-${HOME}}"
  local tmp_base="${out_dir}/wf-db-${BT_NAME}-${ts}-$$"
  hd "Dump — ${BT_PICKED} [${BT_DB_TYPE:-?}]"
  local dump_file; dump_file="$(_bt_db_dump "${tmp_base}")" || return 1
  ok "Dump: $(basename "${dump_file}")"
  if [ "${BT_ENCRYPT:-0}" = "1" ]; then
    dump_file="$(_bt_encrypt_file "${dump_file}")" || return 1
    ok "Encrypted: $(basename "${dump_file}")"
  fi
  local bn; bn="$(basename "${dump_file}")"; local ext="${bn#*.}"
  local final="${out_dir}/${BT_NAME}_${ts}.${ext}"
  mv "${dump_file}" "${final}"
  ok "Saved: ${final}"
}
a_run()  { BT_PICKED=""; _bt_pick || return 0; _run_one "${BT_PICKED}"; }
a_test() { BT_PICKED=""; _bt_pick || return 0; _run_one "${BT_PICKED}" "dry"; }

a_run_all() {
  local names=() n ok_c=0 fail_c=0
  while IFS= read -r n; do names+=("$n"); done < <(_bt_list)
  [ ${#names[@]} -gt 0 ] || { warn "No profiles configured."; return 0; }
  hd "Running all ${#names[@]} profile(s)"
  for n in "${names[@]}"; do
    printf "\n%b── %s ──%b\n" "${C_BOLD}" "$n" "${C_RESET}" >&2
    _run_one "$n" \
      && ok_c=$((ok_c+1)) \
      || fail_c=$((fail_c+1))
  done
  printf "\n%b═══════════════════════════════════%b\n" "${C_CYAN}" "${C_RESET}" >&2
  printf "  %b✔ %d succeeded%b   %b✖ %d failed%b\n" \
    "${C_GREEN}" "$ok_c" "${C_RESET}" "${C_RED}" "$fail_c" "${C_RESET}" >&2
}

a_status() {
  hd "Backup status"
  local names=() n
  while IFS= read -r n; do names+=("$n"); done < <(_bt_list)
  [ ${#names[@]} -gt 0 ] || { warn "No profiles configured."; return 0; }
  if ! _has_engine; then
    warn "backup-engine.py not found — status requires SQLite state (engine mode only)"
    return 0
  fi
  for n in "${names[@]}"; do
    _bt_load "$n" 2>/dev/null || continue
    printf "\n  %b●%b %b%s%b  [%s]\n" "${C_GREEN}" "${C_RESET}" "${C_BOLD}" "$n" "${C_RESET}" "${BT_TYPE:-?}" >&2
    _run_engine --status 2>/dev/null || true
  done
}

a_cron() {
  BT_PICKED=""; _bt_pick || return 0
  local p="${BT_PICKED}"
  hd "Cron schedule — ${p}"
  local existing; existing="$(crontab -l 2>/dev/null | grep "backup-tools.*${p}" || true)"
  if [ -n "$existing" ]; then
    info "Existing: ${existing}"
    local r; r="$(ask "Replace existing entry? [y/N]:" "n")"
    [[ "$r" =~ ^[Yy] ]] || return 0
    crontab -l 2>/dev/null | grep -v "backup-tools.*${p}" | crontab - 2>/dev/null || true
  fi
  local hour; hour="$(ask "Backup hour 0-23 [2]:" "2")"; hour="${hour:-2}"
  # Logs go to the standard WF_LOG_DIR (set by wf_log_init in lib.sh)
  local log_dir="${WF_DATA_DIR}/logs/backup-tools"
  mkdir -p "$log_dir"
  local this; this="$(realpath "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "/path/to/backup-tools.sh")"
  local entry="0 ${hour} * * * bash '${this}' --run '${p}' >> '${log_dir}/${p}_\$(date +\%Y\%m\%d).log' 2>&1"
  if (crontab -l 2>/dev/null; echo "$entry") | crontab -; then
    ok "Cron added — daily at ${hour}:00 for '${p}'"
    info "Log dir : ${log_dir}"
    info "${entry}"
  else
    err "crontab update failed. Add manually:"
    printf "  %b%s%b\n" "${C_YELLOW}" "$entry" "${C_RESET}" >&2
  fi
}

# --- non-interactive mode (cron / scripted) -------------------------------
#
# Flags:
#   --run       <profile>       run backup for one profile (dir sync OR db dump+upload)
#   --run-all                   run all profiles (auto dump+encrypt for DB profiles)
#   --test      <profile>       dry-run for one profile
#   --dump      <profile> [dir] dump DB to local file only, no upload (auto-encrypts if profile has BT_ENCRYPT=1)
#   --dump-all  [dir]           dump all DB profiles to local files
#   --list                      list all configured profiles
#   --status    [profile]       show engine status (all or one profile)
#   --cron      <profile> [h]   register daily cron entry (hour h, default 2)
#   --remove-cron [profile]     remove matching cron entries from crontab
#   --delete    <profile> [..]  delete one or more profiles
case "${1:-}" in
  --run)
    [ -n "${2:-}" ] || { printf "Usage: %s --run <profile>\n" "$0" >&2; exit 1; }
    _run_one "$2"; exit $? ;;
  --run-all)
    a_run_all; exit $? ;;
  --test)
    [ -n "${2:-}" ] || { printf "Usage: %s --test <profile>\n" "$0" >&2; exit 1; }
    _run_one "$2" "dry"; exit $? ;;
  --list)
    a_list; exit 0 ;;
  --status)
    if [ -n "${2:-}" ]; then
      _bt_load "$2" && _run_engine --status; exit $?
    else
      a_status; exit 0
    fi ;;
  --cron)
    [ -n "${2:-}" ] || { printf "Usage: %s --cron <profile> [hour 0-23]\n" "$0" >&2; exit 1; }
    BT_CRON_PROF="$2"; BT_CRON_HOUR="${3:-2}"
    hd "Cron schedule — ${BT_CRON_PROF}"
    _bt_load "${BT_CRON_PROF}" || exit 1
    crontab -l 2>/dev/null | grep -v "backup-tools.*${BT_CRON_PROF}" | crontab - 2>/dev/null || true
    BT_CRON_LOGDIR="${WF_DATA_DIR}/logs/backup-tools"
    mkdir -p "${BT_CRON_LOGDIR}"
    BT_CRON_THIS="$(realpath "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo "$0")"
    BT_CRON_ENTRY="0 ${BT_CRON_HOUR} * * * bash '${BT_CRON_THIS}' --run '${BT_CRON_PROF}' >> '${BT_CRON_LOGDIR}/${BT_CRON_PROF}_\$(date +\%Y\%m\%d).log' 2>&1"
    (crontab -l 2>/dev/null; echo "${BT_CRON_ENTRY}") | crontab -
    ok "Cron set: daily at ${BT_CRON_HOUR}:00 for '${BT_CRON_PROF}'"
    info "${BT_CRON_ENTRY}"
    exit 0 ;;
  --remove-cron)
    hd "Remove Cron — Backup"
    if [ -n "${2:-}" ]; then
      wf_cron_remove "backup-tools.*${2}"
    else
      wf_cron_remove "backup-tools"
    fi
    exit 0 ;;
  --dump)
    [ -n "${2:-}" ] || { printf "Usage: %s --dump <db-profile> [output_dir]\n" "$0" >&2; exit 1; }
    _bt_load "$2" || exit 1
    [ "${BT_SOURCE_TYPE:-dir}" = "db" ] || { err "Profile '$2' is not a DB profile (source_type=dir)."; exit 1; }
    BT_DUMP_DIR="${3:-${HOME}}"
    BT_DUMP_TS="$(date +%Y%m%d_%H%M%S)"
    hd "Dump — ${BT_NAME} [${BT_DB_TYPE:-?}]"
    BT_DUMP_FILE="$(_bt_db_dump "${BT_DUMP_DIR}/wf-db-${BT_NAME}-${BT_DUMP_TS}-$$")" || exit 1
    ok "Dump: $(basename "${BT_DUMP_FILE}")"
    if [ "${BT_ENCRYPT:-0}" = "1" ]; then
      BT_DUMP_FILE="$(_bt_encrypt_file "${BT_DUMP_FILE}")" || exit 1
      ok "Encrypted: $(basename "${BT_DUMP_FILE}")"
    fi
    BT_DUMP_EXT="$(basename "${BT_DUMP_FILE}")"; BT_DUMP_EXT="${BT_DUMP_EXT#*.}"
    BT_DUMP_FINAL="${BT_DUMP_DIR}/${BT_NAME}_${BT_DUMP_TS}.${BT_DUMP_EXT}"
    mv "${BT_DUMP_FILE}" "${BT_DUMP_FINAL}"
    ok "Saved: ${BT_DUMP_FINAL}"
    exit 0 ;;
  --dump-all)
    BT_DUMPALL_DIR="${2:-${HOME}}"
    BT_DUMPALL_TS="$(date +%Y%m%d_%H%M%S)"
    BT_DUMPALL_OK=0; BT_DUMPALL_FAIL=0
    while IFS= read -r BT_DUMPALL_N; do
      _bt_load "${BT_DUMPALL_N}" 2>/dev/null || { warn "Cannot load: ${BT_DUMPALL_N}"; BT_DUMPALL_FAIL=$((BT_DUMPALL_FAIL+1)); continue; }
      [ "${BT_SOURCE_TYPE:-dir}" = "db" ] || continue
      hd "Dump — ${BT_NAME} [${BT_DB_TYPE:-?}]"
      BT_DUMPALL_FILE="$(_bt_db_dump "${BT_DUMPALL_DIR}/wf-db-${BT_NAME}-${BT_DUMPALL_TS}-$$")" \
        || { BT_DUMPALL_FAIL=$((BT_DUMPALL_FAIL+1)); continue; }
      if [ "${BT_ENCRYPT:-0}" = "1" ]; then
        BT_DUMPALL_FILE="$(_bt_encrypt_file "${BT_DUMPALL_FILE}")" \
          || { BT_DUMPALL_FAIL=$((BT_DUMPALL_FAIL+1)); continue; }
      fi
      BT_DUMPALL_EXT="$(basename "${BT_DUMPALL_FILE}")"; BT_DUMPALL_EXT="${BT_DUMPALL_EXT#*.}"
      BT_DUMPALL_FINAL="${BT_DUMPALL_DIR}/${BT_NAME}_${BT_DUMPALL_TS}.${BT_DUMPALL_EXT}"
      mv "${BT_DUMPALL_FILE}" "${BT_DUMPALL_FINAL}"
      ok "Saved: ${BT_DUMPALL_FINAL}"; BT_DUMPALL_OK=$((BT_DUMPALL_OK+1))
    done < <(_bt_list)
    ok "Dump-all: ${BT_DUMPALL_OK} saved, ${BT_DUMPALL_FAIL} failed."
    exit 0 ;;
  --delete)
    [ -n "${2:-}" ] || { printf "Usage: %s --delete <profile> [profile2 ...]\n" "$0" >&2; exit 1; }
    hd "Delete profile(s)"
    for _dp in "${@:2}"; do
      if [ -f "$(_bt_file "${_dp}")" ]; then
        rm -f "$(_bt_file "${_dp}")"; ok "Deleted: ${_dp}"
      else
        warn "Profile not found: ${_dp}"
      fi
    done
    exit 0 ;;
esac

# --- menu -----------------------------------------------------------------
MENU=(
  "Profile|add|add new backup profile"
  "Profile|list|list all profiles"
  "Profile|delete|remove a profile"
  "Run|run|run backup (dir sync or DB dump + upload)"
  "Run|run_all|run ALL profiles (auto dump+encrypt for DB)"
  "Run|test|dry-run — no actual transfer"
  "Run|dump|dump DB to local file only (no upload)"
  "Run|status|show upload progress (engine mode)"
  "Schedule|cron|setup daily cron job for a profile"
  "Schedule|remove_cron|remove backup cron entries"
  "Config|clear_cfg|clear saved wizard defaults"
)

banner
while true; do
  printf "\n" >&2
  menu_select "Backup tools — S3 / FTP / SFTP:" || break
  case "${MENU_KEY}" in
    add)       a_add || true ;;
    list)      a_list || true ;;
    delete)    a_delete || true ;;
    run)       a_run || true ;;
    run_all)   a_run_all || true ;;
    test)      a_test || true ;;
    dump)      a_dump || true ;;
    status)    a_status || true ;;
    cron)        a_cron || true ;;
    remove_cron) wf_cron_remove "backup-tools" || true ;;
    clear_cfg)   cfg_clear && ok "Saved defaults cleared." ;;
  esac
done

printf "\n%b✔ backup-tools done.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
