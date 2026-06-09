#!/usr/bin/env bash
#
# install.sh — interactive launcher for wanforge server scripts.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/wanforge/server-mine/main/install.sh | bash
#
# Shows a grouped checkbox menu, then fetches and runs the chosen scripts
# from this public repo (no authentication needed).
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail

# --- shared library: colors, banner, logging, prompts --------------------
__LIB="https://raw.githubusercontent.com/wanforge/server-mine/main/script/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/script/lib.sh" ]; then . "${__d}/script/lib.sh"
else . <(curl -fsSL "${__LIB}"); fi

spinner() {
  # spinner PID "message"
  local pid=$1 msg=$2
  local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i + 1) % ${#frames} ))
    printf "\r%b%s%b %s" "${C_YELLOW}" "${frames:$i:1}" "${C_RESET}" "$msg" >&2
    sleep 0.08
  done
  printf "\r%b✔%b %s\n" "${C_GREEN}" "${C_RESET}" "$msg" >&2
}

# --- config: source repo -------------------------------------------------
REPO_OWNER="wanforge"
REPO_NAME="server-mine"
REPO_BRANCH="main"

# Script registry — "group|label|path-in-repo|description". Keep groups contiguous.
SCRIPTS=(
  "System|install-packages|script/install-packages.sh|Update system + install base packages (multi-distro)"
  "System|set-timezone|script/set-timezone.sh|Set timezone (default Asia/Jakarta)"
  "Security|install-firewall|script/install-firewall.sh|Install & configure ufw firewall"
  "Security|firewall-manager|script/firewall-manager.sh|Full ufw manager: allow/deny IP/port, multiple, rate-limit"
  "Security|install-fail2ban|script/install-fail2ban.sh|Install & enable Fail2Ban"
  "Security|secure-ssh|script/secure-ssh.sh|Harden SSH: change port, disable root/password, pubkey"
  "Security|generate-ssh-key|script/generate-ssh-key.sh|Generate an ed25519 SSH key (user-local)"
  "Panel & Console|install-cloudpanel|script/install-cloudpanel.sh|Install CloudPanel CE v2 (Debian/Ubuntu only)"
  "Panel & Console|clpctl-manager|script/clpctl-manager.sh|Manage CloudPanel via clpctl (sites, db, users, certs)"
  "Panel & Console|install-cockpit|script/install-cockpit.sh|Install Cockpit web console + modules (Debian/Ubuntu)"
  "Database|install-postgresql|script/install-postgresql.sh|Install PostgreSQL + create roles + remote access"
  "Database|enable-mysql-remote|script/enable-mysql-remote.sh|Allow remote MySQL/MariaDB access (sensitive)"
  "Database|database-toolkit|script/database-toolkit.sh|Monitor, optimize, config, datetime (MySQL/PostgreSQL)"
  "App Runtime|install-nodejs|script/install-nodejs.sh|Install Node.js via nvm (user-local) + PM2"
  "App Runtime|install-composer|script/install-composer.sh|Install Composer (user-local, signature-verified)"
  "App Runtime|setup-pm2-app|script/setup-pm2-app.sh|Configure pm2-logrotate + register an app (ecosystem)"
  "Monitoring|monitor-system|script/monitor-system.sh|CPU, RAM, storage, processes, network (snapshot or realtime)"
  "Network|net-tools|script/net-tools.sh|Local/public IP, ports, speedtest, ping, dig, scan"
)
# ------------------------------------------------------------------------

# When run via `curl | bash`, stdin is the pipe, so read from the terminal.
if [ -e /dev/tty ]; then
  exec 3</dev/tty
else
  echo "No TTY available; cannot prompt interactively." >&2
  exit 1
fi

# --- checkbox multi-select menu ------------------------------------------
# Populates the global array SELECTED with chosen indices. ↑/↓ move,
# SPACE toggle, A toggle-all, ENTER confirm, Q quit.
SELECTED=()
checkbox_menu() {
  local n=${#SCRIPTS[@]} i cursor=0 first=1 key rest prev g lbl dsc
  local -a checked
  for ((i = 0; i < n; i++)); do checked[i]=0; done

  # total rendered lines = items + one header per distinct (contiguous) group
  local groups=0 pg=""
  for ((i = 0; i < n; i++)); do
    IFS='|' read -r g _ <<< "${SCRIPTS[i]}"
    [ "$g" != "$pg" ] && { groups=$((groups + 1)); pg="$g"; }
  done
  local total=$((n + groups))

  printf "%bSelect scripts to run:%b  %b↑/↓ move · SPACE toggle · A all · ENTER run · Q quit%b\n\n" \
    "${C_BOLD}" "${C_RESET}" "${C_DIM}" "${C_RESET}" >&2

  while true; do
    [ "$first" -eq 0 ] && printf "\033[%dA" "$total" >&2
    first=0
    prev=""
    for ((i = 0; i < n; i++)); do
      IFS='|' read -r g lbl _ dsc <<< "${SCRIPTS[i]}"
      if [ "$g" != "$prev" ]; then
        printf "\033[2K%b── %s ──%b\n" "${C_BOLD}${C_YELLOW}" "$g" "${C_RESET}" >&2
        prev="$g"
      fi
      local box="[ ]"; [ "${checked[i]}" -eq 1 ] && box="[x]"
      printf "\033[2K" >&2
      if [ "$i" -eq "$cursor" ]; then
        printf "%b❯ %s %-20s%b %b%s%b\n" "${C_CYAN}${C_BOLD}" "$box" "$lbl" "${C_RESET}" "${C_DIM}" "$dsc" "${C_RESET}" >&2
      else
        printf "  %b%s%b %-20s %b%s%b\n" "${C_GREEN}" "$box" "${C_RESET}" "$lbl" "${C_DIM}" "$dsc" "${C_RESET}" >&2
      fi
    done

    IFS= read -rsn1 key <&3 || break
    if [ "$key" = $'\x1b' ]; then IFS= read -rsn2 -t 0.01 rest <&3 || rest=""; key+="$rest"; fi
    case "$key" in
      $'\x1b[A'|k) cursor=$(( (cursor - 1 + n) % n )) ;;
      $'\x1b[B'|j) cursor=$(( (cursor + 1) % n )) ;;
      ' ') checked[cursor]=$(( 1 - checked[cursor] )) ;;
      a|A)
        local all=1; for ((i = 0; i < n; i++)); do [ "${checked[i]}" -eq 0 ] && all=0; done
        for ((i = 0; i < n; i++)); do checked[i]=$(( 1 - all )); done ;;
      q|Q) SELECTED=(); return 1 ;;
      '') break ;;  # Enter
    esac
  done

  for ((i = 0; i < n; i++)); do [ "${checked[i]}" -eq 1 ] && SELECTED+=("$i"); done
  return 0
}

banner
checkbox_menu || { printf "\n%bCancelled.%b\n" "${C_YELLOW}" "${C_RESET}" >&2; exit 0; }

if [ "${#SELECTED[@]}" -eq 0 ]; then
  printf "\n%bNothing selected.%b\n" "${C_YELLOW}" "${C_RESET}" >&2
  exit 0
fi

printf "\n%bSelected %d script(s).%b\n\n" "${C_GREEN}" "${#SELECTED[@]}" "${C_RESET}" >&2

# --- fetch + run each selected script, in menu order ---------------------
TMP_SCRIPT="$(mktemp)"
trap 'rm -f "${TMP_SCRIPT}"' EXIT

for sel in "${SELECTED[@]}"; do
  IFS='|' read -r _ SEL_LABEL SCRIPT_PATH _ <<< "${SCRIPTS[$sel]}"
  RAW_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/${SCRIPT_PATH}"

  curl -fsSL "${RAW_URL}" -o "${TMP_SCRIPT}" &
  spinner $! "Fetching ${SEL_LABEL}"
  wait $! || { echo "Download failed: ${SCRIPT_PATH} (check repo / network)." >&2; exit 1; }

  printf "%b▶ running %s...%b\n" "${C_BOLD}${C_GREEN}" "${SEL_LABEL}" "${C_RESET}" >&2
  bash "${TMP_SCRIPT}" || { err_msg="${SEL_LABEL} exited non-zero"; printf "%b✖ %s%b\n" "${C_BOLD}" "${err_msg}" "${C_RESET}" >&2; }
done

printf "\n%b✔ All selected scripts finished.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
