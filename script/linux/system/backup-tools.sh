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
#   S3   — aws CLI  (pip3 install awscli)
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
  unset BT_NAME BT_TYPE BT_SOURCE BT_DELETE
  unset BT_S3_ENDPOINT BT_S3_ACCESS_KEY BT_S3_SECRET_KEY BT_S3_BUCKET BT_S3_PREFIX
  unset BT_FTP_HOST BT_FTP_PORT BT_FTP_USER BT_FTP_PASS BT_FTP_DEST BT_FTP_SSL
  unset BT_SFTP_HOST BT_SFTP_PORT BT_SFTP_USER BT_SFTP_KEY BT_SFTP_DEST
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
  hd "Select profile"
  local i; for i in "${!names[@]}"; do
    printf "  %b%d)%b %s\n" "${C_CYAN}" "$((i+1))" "${C_RESET}" "${names[$i]}" >&2
  done
  local ch; ch="$(ask "Profile number [1]:" "1")"; ch="${ch:-1}"
  [[ "$ch" =~ ^[0-9]+$ ]] && [ "$ch" -ge 1 ] && [ "$ch" -le "${#names[@]}" ] \
    || { err "Invalid selection."; return 1; }
  BT_PICKED="${names[$((ch-1))]}"
}

# list /home/* dirs (and /root) as backup source candidates
_bt_home_users() {
  local _d
  for _d in /home/*/; do [ -d "${_d}" ] && printf '%s\n' "${_d%/}"; done
  [ -d /root ] && printf '/root\n'
}

# --- tool checks ----------------------------------------------------------
have()        { command -v "$1" >/dev/null 2>&1; }
_need_aws()   { have aws   || { err "'aws' CLI required. Install: pip3 install awscli"; return 1; }; }
_need_lftp()  { have lftp  || { err "'lftp' required.   Install: apt install lftp";     return 1; }; }
_need_rsync() { have rsync || { err "'rsync' required.  Install: apt install rsync";    return 1; }; }

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
  local type_label; type_label="$(printf '%s' "${BT_TYPE:-?}" | tr '[:lower:]' '[:upper:]')"
  hd "${type_label} Backup — ${name}${dry:+ (dry-run)}"
  local rc=0
  case "${BT_TYPE:-}" in
    s3)   _run_s3   "$dry" || rc=$? ;;
    ftp)  _run_ftp  "$dry" || rc=$? ;;
    sftp) _run_sftp "$dry" || rc=$? ;;
    *)    err "Unknown type '${BT_TYPE}' in profile '${name}'"; return 1 ;;
  esac
  [ $rc -eq 0 ] && ok "Done: ${name}" || { err "Failed: ${name} (exit ${rc})"; return 1; }
}

# --- actions --------------------------------------------------------------

a_add() {
  hd "Add backup profile(s)"

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

    local _sfx
    _sfx="$(ask "Profile name suffix (e.g. 'daily' → alice-daily) [backup]:" "backup")"
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
  local del do_del=0
  del="$(ask "Delete dest files missing from source? [y/N]:" "n")"
  [[ "$del" =~ ^[Yy] ]] && do_del=1

  # --- step 3: destination (asked once, applied to all profiles) ---
  hd "Destination type (applies to all selected users)"
  printf "  %b1)%b S3 / S3-compatible (AWS, IDCloudHost, MinIO…)\n" "${C_CYAN}" "${C_RESET}" >&2
  printf "  %b2)%b FTP / FTPS\n"                                     "${C_CYAN}" "${C_RESET}" >&2
  printf "  %b3)%b SFTP (SSH + rsync)\n"                             "${C_CYAN}" "${C_RESET}" >&2
  local tc; tc="$(ask "Type [1]:" "1")"; tc="${tc:-1}"

  local ep ak sk bkt pfx_base host port user pass dest ssl_c ssl key
  case "$tc" in
    1)
      ep="$(ask_cfg  CFG_BT_S3_ENDPOINT   "S3 Endpoint URL:"                        "https://is3.cloudhost.id")"
      ak="$(ask_cfg  CFG_BT_S3_ACCESS_KEY "S3 Access Key:"                          "")"
      sk="$(asks_cfg CFG_BT_S3_SECRET_KEY "S3 Secret Key:")"
      bkt="$(ask_cfg CFG_BT_S3_BUCKET     "S3 Bucket name:"                         "")"
      pfx_base="$(ask_cfg CFG_BT_S3_PREFIX "S3 Prefix base (profile name appended):" "${HOSTNAME_S}")"
      ;;
    2)
      host="$(ask_cfg  CFG_BT_FTP_HOST "FTP Host:"                                  "")"
      port="$(ask_cfg  CFG_BT_FTP_PORT "FTP Port:"                                  "21")"
      user="$(ask_cfg  CFG_BT_FTP_USER "FTP Username:"                              "")"
      pass="$(asks_cfg CFG_BT_FTP_PASS "FTP Password:")"
      dest="$(ask_cfg  CFG_BT_FTP_DEST "Remote base path (profile name appended):"  "/backups")"
      printf "  %b1)%b No SSL   %b2)%b Explicit TLS   %b3)%b Implicit TLS\n" \
        "${C_CYAN}" "${C_RESET}" "${C_CYAN}" "${C_RESET}" "${C_CYAN}" "${C_RESET}" >&2
      ssl_c="$(ask "SSL mode [1]:" "1")"; ssl_c="${ssl_c:-1}"
      case "$ssl_c" in 2) ssl="explicit" ;; 3) ssl="implicit" ;; *) ssl="off" ;; esac
      ;;
    3)
      host="$(ask_cfg  CFG_BT_SFTP_HOST "SFTP Host:"                                "")"
      port="$(ask_cfg  CFG_BT_SFTP_PORT "SFTP Port:"                                "22")"
      user="$(ask_cfg  CFG_BT_SFTP_USER "SFTP Username:"                            "")"
      key="$(ask_cfg   CFG_BT_SFTP_KEY  "SSH key path (blank=agent):"               "")"
      dest="$(ask_cfg  CFG_BT_SFTP_DEST "Remote base path (profile name appended):" "/backups")"
      ;;
    *) err "Invalid type choice."; return 1 ;;
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
      1) _bt_save "${_name}" \
           BT_NAME "${_name}" BT_TYPE "s3"   BT_SOURCE "${_src}" BT_DELETE "${do_del}" \
           BT_S3_ENDPOINT "${ep}" BT_S3_ACCESS_KEY "${ak}" BT_S3_SECRET_KEY "${sk}" \
           BT_S3_BUCKET "${bkt}" BT_S3_PREFIX "${pfx_base}/${_name}" ;;
      2) _bt_save "${_name}" \
           BT_NAME "${_name}" BT_TYPE "ftp"  BT_SOURCE "${_src}" BT_DELETE "${do_del}" \
           BT_FTP_HOST "${host}" BT_FTP_PORT "${port}" BT_FTP_USER "${user}" \
           BT_FTP_PASS "${pass}" BT_FTP_DEST "${dest}/${_name}" BT_FTP_SSL "${ssl}" ;;
      3) _bt_save "${_name}" \
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

  checkbox "Select profiles to delete:" || { info "Cancelled."; return 0; }
  [ "${#CHOSEN_KEYS[@]}" -eq 0 ] && { info "Nothing selected."; return 0; }

  warn "Will permanently delete ${#CHOSEN_KEYS[@]} profile(s): ${CHOSEN_KEYS[*]}"
  local cf; cf="$(ask "Confirm? [y/N]:" "n")"
  [[ "$cf" =~ ^[Yy] ]] || { info "Cancelled."; return 0; }

  for n in "${CHOSEN_KEYS[@]}"; do
    rm -f "$(_bt_file "${n}")"
    ok "Deleted: ${n}"
  done
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
#   --run       <profile>       run backup for one profile
#   --run-all                   run all profiles
#   --test      <profile>       dry-run for one profile
#   --list                      list all configured profiles
#   --status    [profile]       show engine status (all or one profile)
#   --cron      <profile> [h]   register daily cron entry (hour h, default 2)
#   --remove-cron [profile]     remove matching cron entries from crontab
#   --delete    <profile>       delete a profile (with confirmation)
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
  "Run|run|run backup for one profile"
  "Run|run_all|run ALL profiles"
  "Run|test|dry-run — no actual transfer"
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
    add)       a_add ;;
    list)      a_list ;;
    delete)    a_delete ;;
    run)       a_run ;;
    run_all)   a_run_all ;;
    test)      a_test ;;
    status)    a_status ;;
    cron)        a_cron ;;
    remove_cron) wf_cron_remove "backup-tools" ;;
    clear_cfg)   cfg_clear && ok "Saved defaults cleared." ;;
  esac
done

printf "\n%b✔ backup-tools done.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
