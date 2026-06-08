#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# monitor-system.sh — CLI system snapshot: CPU, RAM, storage, processes,
# network, sensors. Grouped checkbox to pick sections; can install CLI tools.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/wanforge/server-mine/main/script/monitor-system.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="monitor-system"

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
warn() { printf "    %b!%b %s\n" "${C_YELLOW}" "${C_RESET}" "$1" >&2; }
if [ -e /dev/tty ]; then exec 3</dev/tty; else exec 3<&0; fi
ask() { local p="$1" d="${2:-}" a; printf "%b?%b %s " "${C_YELLOW}" "${C_RESET}" "${p}" >&2; read -r a <&3 || a=""; echo "${a:-$d}"; }
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# ---- generic checkbox menu (items: "group|key|description"; default ON) --
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
        printf "%b❯ %s %-12s%b %b%s%b\n" "${C_CYAN}${C_BOLD}" "$box" "$lbl" "${C_RESET}" "${C_DIM}" "$dsc" "${C_RESET}" >&2
      else
        printf "  %b%s%b %-12s %b%s%b\n" "${C_GREEN}" "$box" "${C_RESET}" "$lbl" "${C_DIM}" "$dsc" "${C_RESET}" >&2
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
has_key() { local x; for x in "${CHOSEN_KEYS[@]}"; do [ "$x" = "$1" ] && return 0; done; return 1; }

pm_install() {
  local pm; for pm in apt-get dnf yum pacman zypper apk; do command -v "$pm" >/dev/null 2>&1 && break; done
  case "$pm" in
    apt-get) ${SUDO} apt-get update && ${SUDO} apt-get install -y "$@" ;;
    dnf) ${SUDO} dnf -y install "$@" ;; yum) ${SUDO} yum -y install "$@" ;;
    pacman) ${SUDO} pacman -S --noconfirm --needed "$@" ;; zypper) ${SUDO} zypper --non-interactive install "$@" ;;
    apk) ${SUDO} apk add "$@" ;; *) warn "No package manager found." ;;
  esac
}

# ---- menu ---------------------------------------------------------------
MENU=(
  "Overview|uptime|Uptime, load average, logged-in users"
  "CPU|cpu|CPU model, cores, current load"
  "Memory|memory|RAM and swap usage"
  "Storage|disk|Disk usage + inodes"
  "Storage|bigdirs|Largest directories under a path"
  "Processes|topcpu|Top processes by CPU"
  "Processes|topmem|Top processes by memory"
  "Network|net|Interfaces and listening sockets"
  "Sensors|temp|Temperatures (needs lm-sensors)"
  "Tools|tools|Install htop, btop, ncdu, glances, iotop"
)

# ---- run ----------------------------------------------------------------
banner
checkbox "Select monitoring sections:" || { warn "Cancelled."; exit 0; }
[ "${#CHOSEN_KEYS[@]}" -eq 0 ] && { warn "Nothing selected."; exit 0; }

if has_key uptime; then hd "Uptime & load"; uptime >&2; who >&2 || true; fi
if has_key cpu; then
  hd "CPU"
  { grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ //'; echo "cores: $(nproc 2>/dev/null || echo '?')"; echo "loadavg: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"; } >&2
  command -v mpstat >/dev/null 2>&1 && mpstat 1 1 >&2 || top -bn1 2>/dev/null | grep -i '%Cpu' >&2 || true
fi
if has_key memory; then hd "Memory"; free -h >&2; fi
if has_key disk; then
  hd "Disk usage"; df -hT -x tmpfs -x devtmpfs 2>/dev/null >&2 || df -h >&2
  hd "Inodes"; df -i -x tmpfs -x devtmpfs 2>/dev/null >&2 || df -i >&2
fi
if has_key bigdirs; then
  P="$(ask "Path to scan for largest dirs:" "/var")"
  hd "Largest directories in ${P}"
  ${SUDO} du -h --max-depth=1 "${P}" 2>/dev/null | sort -h | tail -15 >&2 || warn "du failed for ${P}"
fi
if has_key topcpu; then hd "Top by CPU"; ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu 2>/dev/null | head -11 >&2; fi
if has_key topmem; then hd "Top by memory"; ps -eo pid,user,%cpu,%mem,comm --sort=-%mem 2>/dev/null | head -11 >&2; fi
if has_key net; then
  hd "Interfaces"; ip -br a 2>/dev/null >&2 || ip a >&2 || true
  hd "Listening sockets"; ${SUDO} ss -tulpn 2>/dev/null >&2 || ss -tuln >&2 || true
fi
if has_key temp; then
  hd "Temperatures"
  if command -v sensors >/dev/null 2>&1; then sensors >&2; else warn "lm-sensors not installed (apt install lm-sensors)."; fi
fi
if has_key tools; then
  hd "Installing CLI tools"
  pm_install htop btop ncdu glances iotop || warn "Some tools may be unavailable on this distro."
fi

printf "\n%b✔ System snapshot done.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
