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

# --- shared library: banner, colors, logging, prompts, checkbox ----------
__LIB="https://raw.githubusercontent.com/wanforge/server-mine/main/script/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/lib.sh" ]; then . "${__d}/lib.sh"
else . <(curl -fsSL "${__LIB}"); fi

pm_install() {
  local pm; for pm in apt-get dnf yum pacman zypper apk; do command -v "$pm" >/dev/null 2>&1 && break; done
  case "$pm" in
    apt-get) run ${SUDO} apt-get update && run ${SUDO} apt-get install -y "$@" ;;
    dnf) run ${SUDO} dnf -y install "$@" ;; yum) run ${SUDO} yum -y install "$@" ;;
    pacman) run ${SUDO} pacman -S --noconfirm --needed "$@" ;; zypper) run ${SUDO} zypper --non-interactive install "$@" ;;
    apk) run ${SUDO} apk add "$@" ;; *) warn "No package manager found." ;;
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

# render the live sections (used once, or repeatedly in watch mode)
render() {
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
}

# ---- run ----------------------------------------------------------------
banner
checkbox "Select monitoring sections:" || { warn "Cancelled."; exit 0; }
[ "${#CHOSEN_KEYS[@]}" -eq 0 ] && { warn "Nothing selected."; exit 0; }

# one-time: install CLI tools if selected (also great for realtime: htop/btop/glances)
if has_key tools; then
  hd "Installing CLI tools"
  pm_install htop btop ncdu glances iotop || warn "Some tools may be unavailable on this distro."
fi

# realtime / watch mode: WATCH=1 (or -w/--watch), refresh every INTERVAL seconds
WATCH="${WATCH:-0}"
for __a in "$@"; do case "$__a" in -w|--watch) WATCH=1 ;; esac; done
if [ "${WATCH}" != "1" ]; then
  case "$(ask "Realtime refresh (watch)? [y/N]:" "n")" in y|Y|yes) WATCH=1 ;; esac
fi
INTERVAL="${INTERVAL:-2}"

if [ "${WATCH}" = "1" ]; then
  IV="$(ask "Refresh interval (seconds):" "${INTERVAL}")"; [[ "${IV}" =~ ^[0-9]+$ ]] && INTERVAL="${IV}"
  has_key bigdirs && warn "bigdirs is skipped in watch mode (run a one-shot snapshot for it)."
  trap 'printf "\n"; exit 0' INT
  while true; do
    printf '\033[H\033[2J' >&2
    printf "%bwanforge.asia · monitor%b  %b%s%b  %brefresh %ss · Ctrl-C to stop%b\n" \
      "${C_BOLD}${C_CYAN}" "${C_RESET}" "${C_GREEN}" "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "${C_RESET}" \
      "${C_DIM}" "${INTERVAL}" "${C_RESET}" >&2
    render
    sleep "${INTERVAL}"
  done
fi

# one-shot
if has_key bigdirs; then
  P="$(ask "Path to scan for largest dirs:" "/var")"
  hd "Largest directories in ${P}"
  ${SUDO} du -h --max-depth=1 "${P}" 2>/dev/null | sort -h | tail -15 >&2 || warn "du failed for ${P}"
fi
render
printf "\n%b✔ System snapshot done.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
