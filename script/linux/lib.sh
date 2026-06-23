#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2034
#
# lib.sh — shared UI for wanforge/scripts scripts: colors, the WANFORGE
# banner, logging helpers, interactive prompts, and a grouped checkbox menu.
# Sourced by every script so the look & feel is defined in one place.
#
# A script sets TASK="<name>" before sourcing; the banner subtitle uses it.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan

# ---- colors -------------------------------------------------------------
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET="\033[0m"; C_BOLD="\033[1m"; C_DIM="\033[2m"
  C_RED="\033[38;5;196m"; C_GREEN="\033[38;5;46m"; C_YELLOW="\033[38;5;226m"; C_CYAN="\033[38;5;45m"
  USE_COLOR=1
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; USE_COLOR=0
fi

# ---- verbosity / mode ---------------------------------------------------
# Levels: 0 silent (errors + result only, no banner), 1 normal (default),
# 2 verbose (+ dbg + extra detail), 3 debug (verbose + shell trace).
# Set via:  MODE=silent|normal|verbose|debug
#       or  QUIET=1 / VERBOSE=1 / DEBUG=1
#       or  flags  -q|--silent  -v|--verbose  --debug
case "${MODE:-}" in
  silent|quiet) LOG_LEVEL=0 ;; normal) LOG_LEVEL=1 ;;
  verbose)      LOG_LEVEL=2 ;; debug)  LOG_LEVEL=3 ;;
  *)
    LOG_LEVEL=1
    [ "${QUIET:-0}"   = "1" ] && LOG_LEVEL=0
    [ "${VERBOSE:-0}" = "1" ] && LOG_LEVEL=2
    [ "${DEBUG:-0}"   = "1" ] && LOG_LEVEL=3 ;;
esac
for __a in "$@"; do case "$__a" in
  -q|--silent|--quiet) LOG_LEVEL=0 ;;
  -v|--verbose)        LOG_LEVEL=2 ;;
  --debug)             LOG_LEVEL=3 ;;
esac; done
[ "${LOG_LEVEL}" -ge 3 ] && set -x

# ---- dry-run ------------------------------------------------------------
# DRY_RUN=1 (or --dry-run / -n) makes run() PRINT a command instead of
# executing it. Wrap state-changing commands with `run`:  run ${SUDO} apt-get …
DRY_RUN="${DRY_RUN:-0}"
for __a in "$@"; do case "$__a" in --dry-run|-n) DRY_RUN=1 ;; esac; done
run() {
  if [ "${DRY_RUN}" = "1" ]; then
    printf "    %b[dry-run]%b %s\n" "${C_YELLOW}" "${C_RESET}" "$*" >&2
    return 0
  fi
  "$@"
}

# ---- download helper (works with curl OR wget) --------------------------
dl()  { if command -v curl >/dev/null 2>&1; then curl -fsSL "$1"; else wget -qO- "$1"; fi; }       # to stdout
dlo() { if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"; else wget -qO "$2" "$1"; fi; }  # to file $2

# ---- assume-yes ---------------------------------------------------------
# ASSUME_YES=1 (or YES=1, or -y/--yes) makes ask() return the default answer
# without prompting — for non-interactive / automated runs.
ASSUME_YES="${ASSUME_YES:-${YES:-0}}"
for __a in "$@"; do case "$__a" in -y|--yes|--assume-yes) ASSUME_YES=1 ;; esac; done

# ---- log file -----------------------------------------------------------
# LOG_FILE=/path appends a plain-text (no-color) copy of every log line.
LOG_FILE="${LOG_FILE:-}"
if [ -n "${LOG_FILE}" ]; then : >> "${LOG_FILE}" 2>/dev/null || { printf "    cannot write LOG_FILE: %s\n" "${LOG_FILE}" >&2; LOG_FILE=""; }; fi
__log() {  # __log "<line with color escapes>"
  printf '%b\n' "$1" >&2
  [ -n "${LOG_FILE}" ] && printf '[%s] %b\n' "$(date +%H:%M:%S)" "$1" | sed 's/\x1b\[[0-9;]*m//g' >> "${LOG_FILE}" 2>/dev/null || true
}

# ---- banner (random single-hue gradient) --------------------------------
banner() {
  [ "${LOG_LEVEL:-1}" -ge 1 ] || return 0
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
  printf "\n" >&2; local i=0 l
  for l in "${lines[@]}"; do
    if [ "${USE_COLOR}" -eq 1 ]; then printf "\033[1;38;5;%sm%s\033[0m\n" "${grad[$i]}" "$l" >&2
    else printf "%s\n" "$l" >&2; fi
    i=$((i + 1)); sleep 0.04
  done
  if [ "${USE_COLOR}" -eq 1 ]; then
    printf "\033[38;5;240m%s\033[0m\n" "$(printf '%.0s─' {1..72})" >&2
    printf "\033[38;5;240m  wanforge.asia%s  ·  GPLv3 © 2026 Sugeng Sulistiyawan\033[0m\n\n" \
      "${TASK:+  ·  ${TASK}}" >&2
  else
    printf "  wanforge.asia%s  ·  GPLv3 © 2026 Sugeng Sulistiyawan\n\n" \
      "${TASK:+  ·  ${TASK}}" >&2
  fi
}

# ---- logging (gated by LOG_LEVEL; err always prints; mirrored to LOG_FILE)
hd() {
  [ "${LOG_LEVEL:-1}" -ge 1 ] || return 0
  local label=" $1 " w=72 pad="" ll lr
  if [ "${USE_COLOR}" -eq 1 ]; then
    ll=$(( (w - ${#label}) / 2 )); lr=$(( w - ll - ${#label} ))
    pad() { local i=0 s=""; while [ $i -lt "$1" ]; do s="${s}─"; i=$((i+1)); done; printf '%s' "$s"; }
    __log "\n${C_BOLD}${C_CYAN}$(pad $ll)${label}$(pad $lr)${C_RESET}"
  else
    __log "\n── $1 ──"
  fi
}
info()  { [ "${LOG_LEVEL:-1}" -ge 1 ] || return 0; __log "  ${C_CYAN}•${C_RESET} $1"; }
ok()    { [ "${LOG_LEVEL:-1}" -ge 1 ] || return 0; __log "  ${C_GREEN}✓${C_RESET} $1"; }
warn()  { [ "${LOG_LEVEL:-1}" -ge 1 ] || return 0; __log "  ${C_YELLOW}⚠${C_RESET} $1"; }
err()   { __log "  ${C_RED}✖${C_RESET} $1"; }
dbg()   { [ "${LOG_LEVEL:-1}" -ge 2 ] || return 0; __log "  ${C_DIM}⋯${C_RESET} $1"; }
step()  { [ "${LOG_LEVEL:-1}" -ge 1 ] || return 0; __log "\n  ${C_BOLD}${C_YELLOW}[$1]${C_RESET} $2"; }
hr()    { [ "${LOG_LEVEL:-1}" -ge 1 ] || return 0; __log "${C_DIM}$(printf '%.0s─' {1..72})${C_RESET}"; }
pause() { printf "  %b↵ Press Enter to continue…%b" "${C_DIM}" "${C_RESET}" >&2; read -r _ <&3 2>/dev/null || true; }

# ---- prompts (read from the terminal even under `curl | bash`) -----------
# Open the terminal on FD 3; fall back to stdin if /dev/tty is not available.
if ! { [ -e /dev/tty ] && exec 3</dev/tty; } 2>/dev/null; then exec 3<&0; fi
ask()  { local p="$1" d="${2:-}" a; if [ "${ASSUME_YES:-0}" = "1" ]; then echo "${d}"; return 0; fi; if [ -n "${d}" ]; then printf "%b›%b %s %b[%s]%b " "${C_YELLOW}" "${C_RESET}" "${p}" "${C_DIM}" "${d}" "${C_RESET}" >&2; else printf "%b›%b %s " "${C_YELLOW}" "${C_RESET}" "${p}" >&2; fi; read -r a <&3 || a=""; echo "${a:-$d}"; }
asks() { local p="$1" a; printf "%b›%b %s " "${C_YELLOW}" "${C_RESET}" "${p}" >&2; read -rs a <&3 || a=""; printf "\n" >&2; echo "${a}"; }

# ---- config persistence -------------------------------------------------
# Per-script config saved at ~/.config/wanforge-scripts/<TASK>.conf (chmod 600).
# Secrets and plain values share the same file; the file itself is the guard.
#
# Usage pattern in a script (after sourcing lib.sh):
#   cfg_load                            # restore prior session values
#   VAR="$(ask_cfg  KEY "prompt" def)"  # plain value — saved default on re-run
#   VAR="$(asks_cfg KEY "prompt")"      # secret  — hidden; Enter = keep saved
#   cfg_clear                           # wipe saved config for this script
#
# Direct helpers:
#   cfg_set KEY VALUE    write one key
#   cfg_del KEY          remove one key

CFG_DIR="${XDG_CONFIG_HOME:-${HOME:-/root}/.config}/wanforge-scripts"
CFG_FILE=""

cfg_init() {
  local name="${1:-${TASK:-unnamed}}"
  CFG_FILE="${CFG_DIR}/${name}.conf"
}

cfg_load() {
  [ -n "${CFG_FILE}" ] || cfg_init
  [ -f "${CFG_FILE}" ] || return 0
  dbg "Loading saved config: ${CFG_FILE}"
  # shellcheck source=/dev/null
  . "${CFG_FILE}"
}

cfg_set() {
  [ -n "${CFG_FILE}" ] || cfg_init
  local key="$1" val="$2" tmp
  mkdir -p "${CFG_DIR}" && chmod 700 "${CFG_DIR}"
  [ -f "${CFG_FILE}" ] || { touch "${CFG_FILE}" && chmod 600 "${CFG_FILE}"; }
  tmp="$(mktemp)"
  grep -v "^${key}=" "${CFG_FILE}" > "${tmp}" 2>/dev/null || true
  printf '%s=%q\n' "${key}" "${val}" >> "${tmp}"
  mv "${tmp}" "${CFG_FILE}" && chmod 600 "${CFG_FILE}"
}

cfg_del() {
  [ -n "${CFG_FILE}" ] || cfg_init
  [ -f "${CFG_FILE}" ] || return 0
  local tmp; tmp="$(mktemp)"
  grep -v "^${1}=" "${CFG_FILE}" > "${tmp}" 2>/dev/null || true
  mv "${tmp}" "${CFG_FILE}" && chmod 600 "${CFG_FILE}"
}

cfg_clear() {
  [ -n "${CFG_FILE}" ] || cfg_init
  [ -f "${CFG_FILE}" ] && rm -f "${CFG_FILE}"
  return 0
}

# ask_cfg KEY "prompt" [default]  — show saved value as default; save on answer
ask_cfg() {
  local key="$1" prompt="$2" default="${3:-}"
  local saved; saved="${!key:-}"
  local val; val="$(ask "${prompt}" "${saved:-${default}}")"
  cfg_set "${key}" "${val}"
  printf '%s\n' "${val}"
}

# asks_cfg KEY "prompt"  — hidden input; press Enter to keep the saved secret
asks_cfg() {
  local key="$1" prompt="$2"
  local saved; saved="${!key:-}"
  if [ -n "${saved}" ]; then
    info "${C_DIM}${key}: saved value on file — press Enter to keep, or type to replace${C_RESET}"
    local val; val="$(asks "${prompt}")"
    if [ -n "${val}" ]; then cfg_set "${key}" "${val}"; printf '%s\n' "${val}"
    else printf '%s\n' "${saved}"; fi
  else
    local val; val="$(asks "${prompt}")"
    [ -n "${val}" ] && cfg_set "${key}" "${val}"
    printf '%s\n' "${val}"
  fi
}

# auto-init when lib.sh is sourced (TASK must be set before sourcing)
[ -n "${TASK:-}" ] && cfg_init

# ---- standard data / log directories ------------------------------------
# WF_DATA_DIR  — persistent data root  (~/.local/share/wanforge-scripts)
# WF_LOG_DIR   — log dir for this TASK (~/.local/share/wanforge-scripts/logs/<TASK>)
# Scripts may write logs here; LOG_FILE can be pointed at it.
# mkdir is intentionally lazy — only called when a script actually needs it.
WF_DATA_DIR="${XDG_DATA_HOME:-${HOME:-/root}/.local/share}/wanforge-scripts"
WF_LOG_DIR="${WF_DATA_DIR}/logs/${TASK:-misc}"

wf_log_init() {
  mkdir -p "${WF_LOG_DIR}" && chmod 700 "${WF_LOG_DIR}"
  WF_LOG_FILE="${WF_LOG_DIR}/$(date +%Y-%m-%d).log"
  LOG_FILE="${WF_LOG_FILE}"
  printf '\n── %s  run started %s ──\n' "${TASK:-?}" "$(date +%H:%M:%S)" >> "${LOG_FILE}" 2>/dev/null || true
}

# ---- privilege ----------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# ---- grouped checkbox menu ----------------------------------------------
# Caller fills MENU=("group|key|description" ...). Default all ON; uncheck to
# skip. Result keys land in CHOSEN_KEYS. ↑/↓ move, SPACE toggle, A all,
# ENTER confirm, Q quit (returns 1).
CHOSEN_KEYS=()
checkbox() {
  # checkbox <title> [default: 1=all-checked 0=all-unchecked]
  local title="${1:-Select:}" _def="${2:-1}"
  local n=${#MENU[@]} i cursor=0 first=1 key rest prev g lbl dsc
  local -a checked
  for ((i = 0; i < n; i++)); do checked[i]="${_def}"; done
  local groups=0 pg=""
  for ((i = 0; i < n; i++)); do IFS='|' read -r g _ <<< "${MENU[i]}"; [ "$g" != "$pg" ] && { groups=$((groups + 1)); pg="$g"; }; done
  local total=$((n + groups))
  printf "%b%s%b\n%b  ↑/↓ move · SPACE toggle · A all · ENTER confirm · Q quit%b\n\n" \
    "${C_BOLD}${C_CYAN}" "${title}" "${C_RESET}" "${C_DIM}" "${C_RESET}" >&2
  while true; do
    [ "$first" -eq 0 ] && printf "\033[%dA" "$total" >&2
    first=0; prev=""
    for ((i = 0; i < n; i++)); do
      IFS='|' read -r g lbl dsc <<< "${MENU[i]}"
      if [ "$g" != "$prev" ]; then printf "\033[2K%b  ── %s ──%b\n" "${C_BOLD}${C_YELLOW}" "$g" "${C_RESET}" >&2; prev="$g"; fi
      local box="[ ]"; [ "${checked[i]}" -eq 1 ] && box="[✓]"
      if [ "$i" -eq "$cursor" ]; then
        printf "\033[2K%b❯ %s %-20s  %s%b\n" "${C_BOLD}${C_CYAN}" "$box" "$lbl" "$dsc" "${C_RESET}" >&2
      else
        printf "\033[2K  %b%s%b %-20s  %b%s%b\n" "${C_GREEN}" "$box" "${C_RESET}" "$lbl" "${C_DIM}" "$dsc" "${C_RESET}" >&2
      fi
    done
    IFS= read -rsn1 key <&3 || break
    [ "$key" = $'\x1b' ] && { IFS= read -rsn2 -t 0.01 rest <&3 || rest=""; key+="$rest"; }
    case "$key" in
      $'\x1b[A'|k) cursor=$(( (cursor - 1 + n) % n )) ;;
      $'\x1b[B'|j) cursor=$(( (cursor + 1) % n )) ;;
      ' ') checked[cursor]=$(( 1 - checked[cursor] )) ;;
      a|A) local all=1; for ((i = 0; i < n; i++)); do [ "${checked[i]}" -eq 0 ] && all=0; done; for ((i = 0; i < n; i++)); do checked[i]=$(( 1 - all )); done ;;
      q|Q) CHOSEN_KEYS=(); return 1 ;;
      '') break ;;
    esac
  done
  CHOSEN_KEYS=()
  for ((i = 0; i < n; i++)); do
    if [ "${checked[i]}" -eq 1 ]; then IFS='|' read -r _ lbl _ <<< "${MENU[i]}"; CHOSEN_KEYS+=("$lbl"); fi
  done
  return 0
}
has_key() { local x; for x in "${CHOSEN_KEYS[@]:-}"; do [ "$x" = "$1" ] && return 0; done; return 1; }

# ---- single-select TUI menu ---------------------------------------------
# Caller fills MENU=("group|key|label" ...). ↑/↓ move, ENTER select, Q back.
# The chosen key lands in MENU_KEY; returns 1 (and empty MENU_KEY) on quit.
MENU_KEY=""
menu_select() {
  local title="${1:-Select:}"
  local n=${#MENU[@]} i cursor=0 first=1 key rest prev g k lbl
  local groups=0 pg=""
  for ((i = 0; i < n; i++)); do IFS='|' read -r g _ <<< "${MENU[i]}"; [ "$g" != "$pg" ] && { groups=$((groups + 1)); pg="$g"; }; done
  local total=$((n + groups))
  printf "%b%s%b\n%b  ↑/↓ move · ENTER select · Q back%b\n\n" "${C_BOLD}${C_CYAN}" "${title}" "${C_RESET}" "${C_DIM}" "${C_RESET}" >&2
  while true; do
    [ "$first" -eq 0 ] && printf "\033[%dA" "$total" >&2
    first=0; prev=""
    for ((i = 0; i < n; i++)); do
      IFS='|' read -r g k lbl <<< "${MENU[i]}"
      if [ "$g" != "$prev" ]; then printf "\033[2K%b  ── %s ──%b\n" "${C_BOLD}${C_YELLOW}" "$g" "${C_RESET}" >&2; prev="$g"; fi
      if [ "$i" -eq "$cursor" ]; then
        printf "\033[2K%b❯ %-20s  %s%b\n" "${C_BOLD}${C_CYAN}" "$k" "$lbl" "${C_RESET}" >&2
      else
        printf "\033[2K  %-20s  %b%s%b\n" "$k" "${C_DIM}" "$lbl" "${C_RESET}" >&2
      fi
    done
    IFS= read -rsn1 key <&3 || break
    [ "$key" = $'\x1b' ] && { IFS= read -rsn2 -t 0.01 rest <&3 || rest=""; key+="$rest"; }
    case "$key" in
      $'\x1b[A'|k) cursor=$(( (cursor - 1 + n) % n )) ;;
      $'\x1b[B'|j) cursor=$(( (cursor + 1) % n )) ;;
      q|Q) MENU_KEY=""; return 1 ;;
      '') IFS='|' read -r _ MENU_KEY _ <<< "${MENU[cursor]}"; return 0 ;;
    esac
  done
  MENU_KEY=""; return 1
}

# ---- target user (run user-local installs as a CloudPanel/site user) -----
# When run as root, re-exec the whole script as TARGET_USER so installs land in
# that user's home. Set TARGET_USER=name (or AS_USER), or you are prompted.
TARGET_USER="${TARGET_USER:-${AS_USER:-}}"
for __a in "$@"; do case "$__a" in --user=*) TARGET_USER="${__a#--user=}" ;; esac; done
maybe_switch_user() {  # maybe_switch_user "<self raw url>"
  local self="$1"
  [ "$(id -u)" -eq 0 ] || return 0                    # only relevant as root
  if [ -z "${TARGET_USER}" ]; then
    TARGET_USER="$(ask 'Install for which user? (e.g. a CloudPanel site user; Enter = root):' '')"
  fi
  [ -z "${TARGET_USER}" ] && return 0                 # stay as root
  id "${TARGET_USER}" >/dev/null 2>&1 || { err "User '${TARGET_USER}' not found."; exit 1; }
  info "Switching to user ${TARGET_USER} (home: $(home_of "${TARGET_USER}"))..."
  exec sudo -u "${TARGET_USER}" -H bash -c \
    "export MODE='${MODE:-}' DRY_RUN='${DRY_RUN:-0}' VERBOSE='${VERBOSE:-0}' QUIET='${QUIET:-0}' ASSUME_YES='${ASSUME_YES:-0}'; curl -fsSL '${self}' | bash"
}
home_of() { getent passwd "${1:-${TARGET_USER}}" 2>/dev/null | cut -d: -f6; }

# ---- service / cron management helpers -----------------------------------
# confirm_critical <description> [keyword=yes]
# 2-step guard for irreversible actions: first y/N, then type the keyword exactly.
# Returns 0 if both pass, 1 if either is cancelled.
confirm_critical() {
  local desc="${1:-this action}" kw="${2:-yes}"
  warn "IRREVERSIBLE: ${desc}"
  local yn; yn="$(ask "Are you sure? [y/N]:" "n")"
  [[ "${yn}" =~ ^[Yy] ]] || { info "Cancelled."; return 1; }
  local typed; typed="$(ask "Type '${kw}' to confirm:" "")"
  [ "${typed}" = "${kw}" ] || { warn "Confirmation mismatch — cancelled."; return 1; }
  return 0
}

# wf_svc_dispatch <cmd> <title> <cron_pat> <svc...>
# Handles --stop|--start|--restart|--enable|--disable|--status|--remove-cron
# for systemd-based services. Returns 0 if cmd was handled (call `&& exit $?`
# after), returns 1 if cmd is unknown (script continues to normal install).
#
# Example in install-*.sh (placed before banner):
#   wf_svc_dispatch "${1:-}" "Grafana" "grafana" grafana-server && exit $?
#   [ "${1:-}" = "--uninstall" ] && { a_uninstall; exit $?; }
wf_svc_dispatch() {
  local cmd="$1" title="$2" cron_pat="$3"; shift 3
  case "${cmd}" in
    --stop)
      hd "Stop — ${title}"
      for s in "$@"; do info "stop ${s}"; run ${SUDO} systemctl stop    "${s}" 2>/dev/null || true; done
      ok "Stopped."; return 0 ;;
    --start)
      hd "Start — ${title}"
      for s in "$@"; do info "start ${s}"; run ${SUDO} systemctl start   "${s}" 2>/dev/null || true; done
      ok "Started."; return 0 ;;
    --restart)
      hd "Restart — ${title}"
      for s in "$@"; do info "restart ${s}"; run ${SUDO} systemctl restart "${s}" 2>/dev/null || true; done
      ok "Restarted."; return 0 ;;
    --enable)
      hd "Enable — ${title}"
      for s in "$@"; do info "enable ${s}"; run ${SUDO} systemctl enable --now "${s}" 2>/dev/null || true; done
      ok "Enabled and started."; return 0 ;;
    --disable)
      hd "Disable — ${title}"
      for s in "$@"; do
        info "disable ${s}"
        run ${SUDO} systemctl stop    "${s}" 2>/dev/null || true
        run ${SUDO} systemctl disable "${s}" 2>/dev/null || true
      done
      ok "Stopped and disabled."; return 0 ;;
    --status)
      hd "Status — ${title}"
      for s in "$@"; do
        ${SUDO} systemctl status "${s}" --no-pager 2>/dev/null \
          || warn "${s}: not found or inactive"
      done; return 0 ;;
    --remove-cron)
      hd "Remove Cron — ${title}"
      wf_cron_remove "${cron_pat}"; return 0 ;;
    *) return 1 ;;
  esac
}

# wf_cron_remove <grep-E pattern> — remove matching lines from crontab.
# Checks both the current user's crontab and root's crontab (via sudo).
wf_cron_remove() {
  local pat="$1" found=0 tmp
  tmp="$(mktemp)"
  if crontab -l 2>/dev/null | grep -qE "${pat}"; then
    found=1
    crontab -l 2>/dev/null | grep -vE "${pat}" > "${tmp}" || true
    crontab "${tmp}" 2>/dev/null && info "Removed cron entries ($(id -un)) matching: ${pat}"
  else
    info "No cron entries for $(id -un) matching: ${pat}"
  fi
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    if sudo crontab -l 2>/dev/null | grep -qE "${pat}"; then
      found=1
      sudo crontab -l 2>/dev/null | grep -vE "${pat}" > "${tmp}" || true
      sudo crontab "${tmp}" 2>/dev/null && info "Removed cron entries (root) matching: ${pat}"
    else
      info "No cron entries for root matching: ${pat}"
    fi
  fi
  rm -f "${tmp}"
  [ "${found}" -eq 1 ] && ok "Cron cleanup done." || info "No matching cron entries found."
}

# wf_svc_menu <title> <cron_pat> <svc...>
# Interactive management menu for systemd-based install scripts.
# Call after banner, gated by [ -z "${1:-}" ].
#   Returns 0   → proceed with install flow.
#   Returns 99  → caller must run a_uninstall.
#   (exits directly for stop/start/restart/enable/disable/status/remove_cron)
#
# Typical usage:
#   if [ -z "${1:-}" ]; then
#     _WF_RC=0; wf_svc_menu "Grafana" "grafana" grafana-server || _WF_RC=$?
#     [ "${_WF_RC}" -eq 99 ] && { a_uninstall; exit $?; }
#   fi
wf_svc_menu() {
  local title="$1" cron_pat="$2"; shift 2
  local _svcs=("$@")
  MENU=(
    "Manage|install|install / configure ${title}"
    "Manage|stop|stop ${title}"
    "Manage|start|start ${title}"
    "Manage|restart|restart ${title}"
    "Manage|enable|enable ${title} (autostart on boot)"
    "Manage|disable|disable ${title}"
    "Manage|status|show service status"
    "Manage|remove_cron|remove related cron entries"
    "Manage|uninstall|uninstall / remove ${title}"
  )
  menu_select "${title} — choose action:" || exit 0
  case "${MENU_KEY}" in
    stop|start|restart|enable|disable|status)
      wf_svc_dispatch "--${MENU_KEY}" "${title}" "${cron_pat}" "${_svcs[@]}"; exit $? ;;
    remove_cron) wf_cron_remove "${cron_pat}"; exit 0 ;;
    uninstall)
      confirm_critical "uninstall / remove ${title}" || exit 0
      return 99 ;;
    install|*)   return 0 ;;
  esac
}
