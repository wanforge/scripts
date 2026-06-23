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
  printf "%b        wanforge.asia%s • GPLv3 © 2026 Sugeng Sulistiyawan%b\n\n" \
    "${C_DIM}" "${TASK:+ · ${TASK}}" "${C_RESET}" >&2
}

# ---- logging (gated by LOG_LEVEL; err always prints; mirrored to LOG_FILE)
hd()   { [ "${LOG_LEVEL:-1}" -ge 1 ] || return 0; __log "\n${C_BOLD}${C_CYAN}▸ $1${C_RESET}"; }
info() { [ "${LOG_LEVEL:-1}" -ge 1 ] || return 0; __log "    ${C_DIM}•${C_RESET} $1"; }
ok()   { [ "${LOG_LEVEL:-1}" -ge 1 ] || return 0; __log "    ${C_GREEN}✔${C_RESET} $1"; }
warn() { [ "${LOG_LEVEL:-1}" -ge 1 ] || return 0; __log "    ${C_YELLOW}!${C_RESET} $1"; }
err()  { __log "    ${C_RED}✖${C_RESET} $1"; }
dbg()  { [ "${LOG_LEVEL:-1}" -ge 2 ] || return 0; __log "    ${C_DIM}⋯${C_RESET} $1"; }

# ---- prompts (read from the terminal even under `curl | bash`) -----------
# Open the terminal on FD 3; fall back to stdin if /dev/tty is not available.
if ! { [ -e /dev/tty ] && exec 3</dev/tty; } 2>/dev/null; then exec 3<&0; fi
ask()  { local p="$1" d="${2:-}" a; if [ "${ASSUME_YES:-0}" = "1" ]; then echo "${d}"; return 0; fi; if [ -n "${d}" ]; then printf "%b?%b %s %b[%s]%b " "${C_YELLOW}" "${C_RESET}" "${p}" "${C_DIM}" "${d}" "${C_RESET}" >&2; else printf "%b?%b %s " "${C_YELLOW}" "${C_RESET}" "${p}" >&2; fi; read -r a <&3 || a=""; echo "${a:-$d}"; }
asks() { local p="$1" a; printf "%b?%b %s " "${C_YELLOW}" "${C_RESET}" "${p}" >&2; read -rs a <&3 || a=""; printf "\n" >&2; echo "${a}"; }

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
  local title="${1:-Select:}"
  local n=${#MENU[@]} i cursor=0 first=1 key rest prev g lbl dsc
  local -a checked
  for ((i = 0; i < n; i++)); do checked[i]=1; done
  local groups=0 pg=""
  for ((i = 0; i < n; i++)); do IFS='|' read -r g _ <<< "${MENU[i]}"; [ "$g" != "$pg" ] && { groups=$((groups + 1)); pg="$g"; }; done
  local total=$((n + groups))
  printf "%b%s%b  %b↑/↓ move · SPACE toggle · A all · ENTER confirm · Q quit%b\n\n" \
    "${C_BOLD}" "${title}" "${C_RESET}" "${C_DIM}" "${C_RESET}" >&2
  while true; do
    [ "$first" -eq 0 ] && printf "\033[%dA" "$total" >&2
    first=0; prev=""
    for ((i = 0; i < n; i++)); do
      IFS='|' read -r g lbl dsc <<< "${MENU[i]}"
      if [ "$g" != "$prev" ]; then printf "\033[2K%b── %s ──%b\n" "${C_BOLD}${C_YELLOW}" "$g" "${C_RESET}" >&2; prev="$g"; fi
      local box="[ ]"; [ "${checked[i]}" -eq 1 ] && box="[x]"
      printf "\033[2K" >&2
      if [ "$i" -eq "$cursor" ]; then
        printf "%b❯ %s %-22s%b %b%s%b\n" "${C_CYAN}${C_BOLD}" "$box" "$lbl" "${C_RESET}" "${C_DIM}" "$dsc" "${C_RESET}" >&2
      else
        printf "  %b%s%b %-22s %b%s%b\n" "${C_GREEN}" "$box" "${C_RESET}" "$lbl" "${C_DIM}" "$dsc" "${C_RESET}" >&2
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
  printf "%b%s%b  %b↑/↓ move · ENTER select · Q back%b\n\n" "${C_BOLD}" "${title}" "${C_RESET}" "${C_DIM}" "${C_RESET}" >&2
  while true; do
    [ "$first" -eq 0 ] && printf "\033[%dA" "$total" >&2
    first=0; prev=""
    for ((i = 0; i < n; i++)); do
      IFS='|' read -r g k lbl <<< "${MENU[i]}"
      if [ "$g" != "$prev" ]; then printf "\033[2K%b── %s ──%b\n" "${C_BOLD}${C_YELLOW}" "$g" "${C_RESET}" >&2; prev="$g"; fi
      printf "\033[2K" >&2
      if [ "$i" -eq "$cursor" ]; then printf "%b❯ %s%b\n" "${C_CYAN}${C_BOLD}" "$lbl" "${C_RESET}" >&2
      else printf "    %b%s%b\n" "${C_DIM}" "$lbl" "${C_RESET}" >&2; fi
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
