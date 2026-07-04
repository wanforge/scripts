#!/usr/bin/env bash
#
# install.sh — interactive launcher for wanforge server scripts.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/install.sh | bash
#
# Shows a grouped checkbox menu, then fetches and runs the chosen scripts
# from this public repo (no authentication needed).
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail

# --- shared library: colors, banner, logging, prompts --------------------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/script/linux/lib.sh" ]; then . "${__d}/script/linux/lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi

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
REPO_NAME="scripts"
REPO_BRANCH="main"

# Script registry — "group|label|path-in-repo|description". Keep groups contiguous.
SCRIPTS=(
  "System|install-packages|script/linux/system/install-packages.sh|Update system + install base essentials (micro, curl, wget, git)"
  "System|set-timezone|script/linux/system/set-timezone.sh|Set timezone (UTC recommended for servers)"
  "System|backup-tools|script/linux/system/backup-tools.sh|Backup manager: S3 / FTP / SFTP — named profiles, cron, dry-run"
  "Security|install-firewall|script/linux/system/install-firewall.sh|Install & configure ufw firewall"
  "Security|firewall-manager|script/linux/security/firewall-manager.sh|Full ufw manager: allow/deny IP/port, multiple, rate-limit"
  "Security|install-fail2ban|script/linux/security/install-fail2ban.sh|Install & enable Fail2Ban"
  "Security|secure-ssh|script/linux/security/secure-ssh.sh|Harden SSH: change port, disable root/password, pubkey"
  "Security|generate-ssh-key|script/linux/security/generate-ssh-key.sh|Generate an ed25519 SSH key (user-local)"
  "Security|manage-users|script/linux/security/manage-users.sh|Manage Linux users, sudo access & SSH keys"
  "Panel & Console|install-cloudpanel|script/linux/cloud/install-cloudpanel.sh|Install CloudPanel CE v2 (Debian/Ubuntu only)"
  "Panel & Console|clpctl-manager|script/linux/cloud/clpctl-manager.sh|Manage CloudPanel via clpctl (sites, db, users, certs)"
  "Panel & Console|install-cockpit|script/linux/cloud/install-cockpit.sh|Install Cockpit web console + modules (Debian/Ubuntu)"
  "Database|install-postgresql|script/linux/database/install-postgresql.sh|Install PostgreSQL + create roles + remote access"
  "Database|enable-mysql-remote|script/linux/database/enable-mysql-remote.sh|Allow remote MySQL/MariaDB access (sensitive)"
  "Database|database-toolkit|script/linux/database/database-toolkit.sh|Monitor, optimize, config, datetime (MySQL/PostgreSQL)"
  "App Runtime|install-nodejs|script/linux/runtime/install-nodejs.sh|Install Node.js via nvm (user-local) + PM2"
  "App Runtime|install-python|script/linux/runtime/install-python.sh|Install Python 3 + pip, venv, dev, pipx (multi-distro)"
  "App Runtime|install-composer|script/linux/runtime/install-composer.sh|Install Composer (user-local, signature-verified)"
  "App Runtime|setup-pm2-app|script/linux/runtime/setup-pm2-app.sh|Configure pm2-logrotate + register an app (ecosystem)"
  "Monitoring|monitor-system|script/linux/monitoring/monitor-system.sh|CPU, RAM, storage, processes, network (snapshot or realtime)"
  "Network|net-tools|script/linux/network/net-tools.sh|Local/public IP, ports, speedtest, ping, dig, scan"
  "Proxmox|proxmox-toolkit|script/linux/network/proxmox-toolkit.sh|PVE: node/VM/CT resources, storage, realtime dashboard"
  "CI/CD|install-github-runner|script/linux/cicd/install-github-runner.sh|Manage GitHub Actions self-hosted runners: install/list/status/logs/remove (avoid billed minutes)"
  "CI/CD|install-gitlab-runner|script/linux/cicd/install-gitlab-runner.sh|Manage GitLab CI/CD self-hosted runners: install/list/status/logs/remove"
  "Observability|install-prometheus|script/linux/monitoring/install-prometheus.sh|Prometheus + node_exporter (+ Alertmanager)"
  "Observability|install-grafana|script/linux/monitoring/install-grafana.sh|Grafana + Prometheus data source"
  "Observability|install-zabbix|script/linux/monitoring/install-zabbix.sh|Zabbix agent or server (official repo)"
  "Observability|install-uptime-kuma|script/linux/monitoring/install-uptime-kuma.sh|Uptime Kuma — beautiful self-hosted status page and service monitor"
  "Observability|install-loki|script/linux/monitoring/install-loki.sh|Loki + Promtail log aggregator & forwarding agent"
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
      if [ "$i" -eq "$cursor" ]; then
        printf "\033[2K%b❯ %s %-20s%b  %b%s%b\n" "${C_CYAN}${C_BOLD}" "$box" "$lbl" "${C_RESET}" "${C_DIM}" "$dsc" "${C_RESET}" >&2
      else
        printf "\033[2K  %b%s%b %-20s  %b%s%b\n" "${C_GREEN}" "$box" "${C_RESET}" "$lbl" "${C_DIM}" "$dsc" "${C_RESET}" >&2
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

  SELECTED=()   # reset each call — otherwise selections accumulate across the loop
  for ((i = 0; i < n; i++)); do [ "${checked[i]}" -eq 1 ] && SELECTED+=("$i"); done
  return 0
}

banner

# Permanent install dir — scripts run from here so BASH_SOURCE[0] is stable (needed for cron).
if [ "$(id -u)" -eq 0 ]; then
  WF_INSTALL_DIR="/opt/wanforge-scripts"
else
  WF_INSTALL_DIR="${HOME}/.local/lib/wanforge-scripts"
fi
mkdir -p "${WF_INSTALL_DIR}"

TMP_DL="$(mktemp)"
trap 'rm -f "${TMP_DL}"' EXIT

# --- launcher loop: menu -> run selection -> back to menu (Q quits) -------
while true; do
  printf "\n" >&2
  checkbox_menu || { printf "\n%bBye.%b\n\n" "${C_DIM}" "${C_RESET}" >&2; break; }
  [ "${#SELECTED[@]}" -eq 0 ] && continue   # nothing picked → back to menu

  printf "\n%bRunning %d script(s).%b\n\n" "${C_GREEN}" "${#SELECTED[@]}" "${C_RESET}" >&2
  for sel in "${SELECTED[@]}"; do
    IFS='|' read -r _ SEL_LABEL SCRIPT_PATH _ <<< "${SCRIPTS[$sel]}"
    RAW_URL="https://scripts.wanforge.asia/${SCRIPT_PATH}"
    PERM_SCRIPT="${WF_INSTALL_DIR}/${SEL_LABEL}.sh"

    dlo "${RAW_URL}" "${TMP_DL}" &
    spinner $! "Fetching ${SEL_LABEL}"
    wait $! || { printf "%b✖ Download failed: %s%b\n" "${C_RED}" "${SCRIPT_PATH}" "${C_RESET}" >&2; continue; }

    cp "${TMP_DL}" "${PERM_SCRIPT}" && chmod +x "${PERM_SCRIPT}"

    printf "%b▶ running %s...%b\n" "${C_BOLD}${C_GREEN}" "${SEL_LABEL}" "${C_RESET}" >&2
    bash "${PERM_SCRIPT}" || printf "%b✖ %s exited non-zero%b\n" "${C_BOLD}" "${SEL_LABEL}" "${C_RESET}" >&2
  done

  printf "\n%b✔ Done. Press Enter to return to the menu (Q there to quit)…%b" "${C_DIM}${C_GREEN}" "${C_RESET}" >&2
  read -r _ <&3 || break
done
