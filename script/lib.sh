#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2034
#
# lib.sh — shared UI for wanforge/server-mine scripts: colors, the WANFORGE
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
  [ -n "${LOG_FILE}" ] && printf '%b\n' "$1" | sed 's/\x1b\[[0-9;]*m//g' >> "${LOG_FILE}" 2>/dev/null || true
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
ask()  { local p="$1" d="${2:-}" a; if [ "${ASSUME_YES:-0}" = "1" ]; then echo "${d}"; return 0; fi; printf "%b?%b %s " "${C_YELLOW}" "${C_RESET}" "${p}" >&2; read -r a <&3 || a=""; echo "${a:-$d}"; }
asks() { local p="$1" a; printf "%b?%b %s " "${C_YELLOW}" "${C_RESET}" "${p}" >&2; read -rs a <&3 || a=""; printf "\n" >&2; echo "${a}"; }

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
