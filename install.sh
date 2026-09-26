#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install.sh — interactive launcher for wanforge server scripts.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/install.sh | bash
#   ./install.sh [run <name> | list | search <term> | help]
#
# Shows a fast, categorized interactive dashboard with search, single-key selection,
# batch multi-select, and automatic local-or-remote execution.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail

# --- locate and load shared library ---------------------------------------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

if   [ -r "${__d}/script/linux/lib.sh" ]; then . "${__d}/script/linux/lib.sh"
elif [ -r "${__d}/lib.sh" ]; then . "${__d}/lib.sh"
elif [ -r "/opt/wanforge-scripts/lib.sh" ]; then . "/opt/wanforge-scripts/lib.sh"
elif [ -r "${HOME:-}/.local/lib/wanforge-scripts/lib.sh" ]; then . "${HOME}/.local/lib/wanforge-scripts/lib.sh"
elif command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}")
else . <(wget -qO- "${__LIB}"); fi

# --- safe TTY initialization (FD 3) ---------------------------------------
if [ -t 0 ]; then
  exec 3<&0
elif (exec 3</dev/tty) 2>/dev/null; then
  exec 3</dev/tty
else
  exec 3<&0
fi

# --- installation directories --------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  WF_INSTALL_DIR="/opt/wanforge-scripts"
else
  WF_INSTALL_DIR="${HOME}/.local/lib/wanforge-scripts"
fi
mkdir -p "${WF_INSTALL_DIR}"

# Cache lib.sh locally for fast offline execution of installed scripts
if [ -r "${__d}/script/linux/lib.sh" ]; then
  cp -f "${__d}/script/linux/lib.sh" "${WF_INSTALL_DIR}/lib.sh" 2>/dev/null || true
elif [ ! -f "${WF_INSTALL_DIR}/lib.sh" ]; then
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${__LIB}" -o "${WF_INSTALL_DIR}/lib.sh" 2>/dev/null || true
  fi
fi

# Cache backup engine if present
if [ -r "${__d}/script/linux/system/backup-engine.py" ]; then
  cp -f "${__d}/script/linux/system/backup-engine.py" "${WF_INSTALL_DIR}/backup-engine.py" 2>/dev/null || true
fi

spinner() {
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

# --- script registry ------------------------------------------------------
# Format: "group|label|path-in-repo|description"
SCRIPTS=(
  "System|install-packages|script/linux/system/install-packages.sh|Update system + install base essentials (micro, curl, wget, git, htop)"
  "System|set-timezone|script/linux/system/set-timezone.sh|Set timezone (UTC recommended for servers)"
  "System|backup-tools|script/linux/system/backup-tools.sh|Backup manager: S3 / FTP / SFTP — named profiles, cron, dry-run"
  "System|sys-troubleshoot|script/linux/system/sys-troubleshoot.sh|Diagnostics: CPU, RAM, services, OOM, logs, firewall, network"
  "System|hardware-info|script/linux/system/hardware-info.sh|Hardware audit: CPU, RAM, disks, GPU, NIC, sensors, virtualization"

  "Security|install-firewall|script/linux/system/install-firewall.sh|Install & configure ufw firewall with base ports"
  "Security|firewall-manager|script/linux/security/firewall-manager.sh|Interactive firewall manager: allow/deny IP/port, rich rules"
  "Security|install-fail2ban|script/linux/security/install-fail2ban.sh|Install & enable Fail2Ban with sane jail defaults"
  "Security|secure-ssh|script/linux/security/secure-ssh.sh|Harden SSH: change port, disable root/password, pubkey"
  "Security|generate-ssh-key|script/linux/security/generate-ssh-key.sh|Generate an ed25519 SSH key (user-local)"
  "Security|manage-users|script/linux/security/manage-users.sh|Manage Linux users, sudo access & SSH keys"
  "Security|ssl-toolkit|script/linux/security/ssl-toolkit.sh|SSL/TLS certificates: Certbot Let's Encrypt & self-signed"

  "Database|install-postgresql|script/linux/database/install-postgresql.sh|Install PostgreSQL + create roles + remote access"
  "Database|enable-mysql-remote|script/linux/database/enable-mysql-remote.sh|Allow remote MySQL/MariaDB access securely"
  "Database|database-toolkit|script/linux/database/database-toolkit.sh|Monitor, optimize, config, datetime (MySQL/PostgreSQL)"

  "App Runtime|install-docker|script/linux/runtime/install-docker.sh|Docker Engine & Docker Compose (with UFW security patch)"
  "App Runtime|install-nodejs|script/linux/runtime/install-nodejs.sh|Install Node.js via nvm (user-local) + PM2"
  "App Runtime|install-python|script/linux/runtime/install-python.sh|Install Python 3 + pip, venv, dev, pipx"
  "App Runtime|install-composer|script/linux/runtime/install-composer.sh|Install Composer (user-local, signature-verified)"
  "App Runtime|setup-pm2-app|script/linux/runtime/setup-pm2-app.sh|Configure pm2-logrotate + register an app ecosystem"

  "Panel & Console|install-cloudpanel|script/linux/cloud/install-cloudpanel.sh|Install CloudPanel CE v2 (Debian/Ubuntu only)"
  "Panel & Console|clpctl-manager|script/linux/cloud/clpctl-manager.sh|Manage CloudPanel via clpctl (sites, db, users, certs)"
  "Panel & Console|install-cockpit|script/linux/cloud/install-cockpit.sh|Install Cockpit web console + modules (Debian/Ubuntu)"

  "Network & Tunnel|install-cloudflared|script/linux/network/install-cloudflared.sh|Cloudflare Tunnel: quick tunnels, named tunnels, ingress, systemd"
  "Network & Tunnel|net-tools|script/linux/network/net-tools.sh|Local/public IP, ports, speedtest, ping, dig, traceroute, scan"
  "Network & Tunnel|proxmox-toolkit|script/linux/network/proxmox-toolkit.sh|Proxmox VE helper: disable enterprise repo, CT/VM dashboard"

  "Monitoring & Metrics|monitor-system|script/linux/monitoring/monitor-system.sh|CPU, RAM, storage, processes, network (snapshot or realtime)"
  "Monitoring & Metrics|install-prometheus|script/linux/monitoring/install-prometheus.sh|Prometheus + node_exporter (+ Alertmanager)"
  "Monitoring & Metrics|install-goaccess|script/linux/monitoring/install-goaccess.sh|GoAccess — real-time web log analyzer (terminal & HTML daemon)"

  "Observability Stack|install-grafana|script/linux/monitoring/install-grafana.sh|Grafana + Prometheus data source"
  "Observability Stack|install-uptime-kuma|script/linux/monitoring/install-uptime-kuma.sh|Uptime Kuma — self-hosted status page and service monitor"
  "Observability Stack|install-loki|script/linux/monitoring/install-loki.sh|Loki + Promtail log aggregator & forwarding agent"
  "Observability Stack|install-zabbix|script/linux/monitoring/install-zabbix.sh|Zabbix agent or server (official repo)"

  "CI/CD Runners|install-github-runner|script/linux/cicd/install-github-runner.sh|GitHub Actions self-hosted runner as a systemd service"
  "CI/CD Runners|install-gitlab-runner|script/linux/cicd/install-gitlab-runner.sh|GitLab CI/CD self-hosted runner as a systemd service"
)

# Extract unique categories
CATEGORIES=()
_seen_cat=""
for row in "${SCRIPTS[@]}"; do
  IFS='|' read -r cat _ <<< "${row}"
  if [[ " ${_seen_cat} " != *" ${cat} "* ]]; then
    CATEGORIES+=("${cat}")
    _seen_cat="${_seen_cat} ${cat}"
  fi
done

# --- execute a script by path/label --------------------------------------
run_script() {
  local target_label="$1"
  local found=0 g lbl rel_path dsc
  for row in "${SCRIPTS[@]}"; do
    IFS='|' read -r g lbl rel_path dsc <<< "${row}"
    if [ "${lbl}" = "${target_label}" ] || [ "${lbl}" = "install-${target_label}" ] || [ "${target_label}" = "${rel_path}" ]; then
      found=1
      break
    fi
  done

  if [ "$found" -eq 0 ]; then
    err "Script '${target_label}' not found."
    return 1
  fi

  local exec_file=""
  local local_candidate="${__d}/${rel_path}"

  # 1. Local execution if running inside cloned repository
  if [ -r "${local_candidate}" ]; then
    exec_file="${local_candidate}"
    chmod +x "${exec_file}" 2>/dev/null || true
  else
    # 2. Remote download and caching
    local perm_file="${WF_INSTALL_DIR}/${lbl}.sh"
    local raw_url="https://scripts.wanforge.asia/${rel_path}"
    local tmp_dl; tmp_dl="$(mktemp)"

    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "${raw_url}" -o "${tmp_dl}" &
    else
      wget -qO "${tmp_dl}" "${raw_url}" &
    fi
    spinner $! "Fetching ${lbl}"
    if ! wait $!; then
      err "Download failed: ${raw_url}"
      rm -f "${tmp_dl}"
      return 1
    fi
    mv -f "${tmp_dl}" "${perm_file}"
    chmod +x "${perm_file}"
    exec_file="${perm_file}"
  fi

  printf "\n%b▶ Executing %s...%b\n" "${C_BOLD}${C_GREEN}" "${lbl}" "${C_RESET}" >&2
  printf "%b  %s%b\n\n" "${C_DIM}" "${dsc}" "${C_RESET}" >&2

  export WF_INSTALL_DIR="${WF_INSTALL_DIR}"
  local rc=0
  bash "${exec_file}" || rc=$?

  if [ $rc -eq 0 ]; then
    printf "\n%b✔ %s completed successfully.%b\n" "${C_GREEN}" "${lbl}" "${C_RESET}" >&2
  else
    printf "\n%b✖ %s exited with status %d.%b\n" "${C_RED}" "${lbl}" "$rc" "${C_RESET}" >&2
  fi

  if [ -t 0 ] || [ -c /dev/tty ]; then
    printf "%bPress Enter to continue...%b" "${C_DIM}" "${C_RESET}" >&2
    read -r _ <&3 2>/dev/null || true
  fi
  return $rc
}

# --- Category Submenu -----------------------------------------------------
show_category_menu() {
  local target_cat="$1"
  local items=() labels=() descs=()
  for row in "${SCRIPTS[@]}"; do
    IFS='|' read -r g lbl rel_path dsc <<< "${row}"
    if [ "$g" = "$target_cat" ]; then
      items+=("${row}")
      labels+=("${lbl}")
      descs+=("${dsc}")
    fi
  done

  local n=${#items[@]}
  local cursor=0 key rest first=1
  local h; h="$(term_lines)"

  while true; do
    printf "\033[H\033[2J" >&2
    printf "%b── %s ──%b\n" "${C_BOLD}${C_CYAN}" "${target_cat}" "${C_RESET}" >&2
    printf "%b  [1-%d] Direct run  ·  ↑/↓ Move  ·  ENTER Select  ·  0/b Back%b\n\n" "$n" "${C_DIM}" "${C_RESET}" >&2

    for ((i = 0; i < n; i++)); do
      local pfx="$((i+1))) "
      if [ "$i" -eq "$cursor" ]; then
        printf "%b❯ %s%-22s %s%b\n" "${C_BOLD}${C_CYAN}" "$pfx" "${labels[i]}" "${descs[i]}" "${C_RESET}" >&2
      else
        printf "  %s%-22s %b%s%b\n" "$pfx" "${labels[i]}" "${C_DIM}" "${descs[i]}" "${C_RESET}" >&2
      fi
    done
    printf "\n  %b[0] ⬅ Back to Categories%b\n" "${C_YELLOW}" "${C_RESET}" >&2

    IFS= read -rsn1 key <&3 || break
    [ "$key" = $'\x1b' ] && { IFS= read -rsn2 -t 0.1 rest <&3 || rest=""; key+="$rest"; }

    case "$key" in
      $'\x1b[A'|k) cursor=$(( (cursor - 1 + n) % n )) ;;
      $'\x1b[B'|j) cursor=$(( (cursor + 1) % n )) ;;
      [1-9])
        local idx=$((key - 1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt "$n" ]; then
          run_script "${labels[idx]}" || true
          break
        fi
        ;;
      0|b|B|q|Q) break ;;
      '')
        run_script "${labels[cursor]}" || true
        break
        ;;
    esac
  done
}

# --- Search Mode ----------------------------------------------------------
search_interactive() {
  printf "\033[H\033[2J" >&2
  printf "%b── Search Scripts ──%b\n\n" "${C_BOLD}${C_CYAN}" "${C_RESET}" >&2
  printf "Ketik nama atau kata kunci (contoh: 'docker', 'ssh', 'db', 'firewall'): " >&2
  local query
  read -r query <&3 || query=""
  query="$(echo "${query}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"

  if [ -z "${query}" ]; then
    return 0
  fi

  local matched_labels=() matched_descs=() matched_cats=()
  for row in "${SCRIPTS[@]}"; do
    IFS='|' read -r g lbl rel_path dsc <<< "${row}"
    local search_space; search_space="$(echo "${g} ${lbl} ${rel_path} ${dsc}" | tr '[:upper:]' '[:lower:]')"
    if [[ "${search_space}" == *"${query}"* ]]; then
      matched_cats+=("${g}")
      matched_labels+=("${lbl}")
      matched_descs+=("${dsc}")
    fi
  done

  local m=${#matched_labels[@]}
  if [ "$m" -eq 0 ]; then
    printf "\n%b✖ Tidak ada script yang cocok dengan '%s'.%b\n" "${C_RED}" "${query}" "${C_RESET}" >&2
    printf "%bPress Enter to return...%b" "${C_DIM}" "${C_RESET}" >&2
    read -r _ <&3 2>/dev/null || true
    return 0
  fi

  printf "\n%bDitemukan %d script cocok:%b\n\n" "${C_GREEN}" "$m" "${C_RESET}" >&2
  for ((i = 0; i < m; i++)); do
    printf "  %b[%d]%b %-22s %b[%s]%b %s\n" \
      "${C_YELLOW}" "$((i+1))" "${C_RESET}" \
      "${matched_labels[i]}" \
      "${C_CYAN}" "${matched_cats[i]}" "${C_RESET}" \
      "${matched_descs[i]}" >&2
  done
  printf "\n  %b[0] Batal / Kembali%b\n\n" "${C_DIM}" "${C_RESET}" >&2

  printf "Pilih nomor script untuk dijalankan [1-%d]: " "$m" >&2
  local sel; read -r sel <&3 || sel=""
  if [[ "${sel}" =~ ^[0-9]+$ ]] && [ "${sel}" -ge 1 ] && [ "${sel}" -le "$m" ]; then
    local target="${matched_labels[$((sel-1))]}"
    run_script "${target}" || true
  fi
}

# --- Batch Multi-Select Mode ----------------------------------------------
batch_select_mode() {
  MENU=()
  for row in "${SCRIPTS[@]}"; do
    IFS='|' read -r g lbl _ dsc <<< "${row}"
    MENU+=("${g}|${lbl}|${dsc}")
  done

  if checkbox "Pilih script yang ingin dijalankan berurutan (Batch Mode):" 0; then
    if [ "${#CHOSEN_KEYS[@]}" -eq 0 ]; then
      warn "Tidak ada script yang dipilih."
      sleep 1
      return 0
    fi

    printf "\n%bMenjalankan %d script terpilih...%b\n" "${C_BOLD}${C_CYAN}" "${#CHOSEN_KEYS[@]}" "${C_RESET}" >&2
    for k in "${CHOSEN_KEYS[@]}"; do
      run_script "$k" || true
    done
  fi
}

# --- CLI List -------------------------------------------------------------
cli_list() {
  printf "\n%bWANFORGE SCRIPTS REPOSITORY — AVAILABLE TOOLS%b\n\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  local cur_g=""
  for row in "${SCRIPTS[@]}"; do
    IFS='|' read -r g lbl rel_path dsc <<< "${row}"
    if [ "$g" != "$cur_g" ]; then
      printf "\n%b── %s ──%b\n" "${C_BOLD}${C_YELLOW}" "$g" "${C_RESET}"
      cur_g="$g"
    fi
    printf "  %-24s %s\n" "${lbl}" "${dsc}"
  done
  printf "\n"
}

# --- CLI Help -------------------------------------------------------------
cli_help() {
  printf "WANFORGE Server Management & Ops Toolkit\n\n"
  printf "Usage:\n"
  printf "  %s                      Launch interactive menu\n" "$0"
  printf "  %s list                 List all 35 scripts by category\n" "$0"
  printf "  %s search <keyword>     Search script by name or description\n" "$0"
  printf "  %s run <script_name>    Run specific script directly\n" "$0"
  printf "  %s info                 Display system snapshot (OS, RAM, Load)\n" "$0"
  printf "  %s --help               Show this help\n\n" "$0"
}

# --- Main Interactive Loop ------------------------------------------------
interactive_main() {
  while true; do
    printf "\033[H\033[2J" >&2
    banner "Server Toolkit v2.0"
    sys_snapshot

    printf "\n%bKATEGORI SCRIPT:%b\n" "${C_BOLD}${C_YELLOW}" "${C_RESET}" >&2
    for ((i = 0; i < ${#CATEGORIES[@]}; i++)); do
      local c="${CATEGORIES[i]}"
      local count=0
      for r in "${SCRIPTS[@]}"; do
        IFS='|' read -r g _ <<< "${r}"
        [ "$g" = "$c" ] && count=$((count + 1))
      done
      local icon="📦"
      case "$c" in
        "System") icon="🖥️ " ;;
        "Security") icon="🛡️ " ;;
        "Database") icon="🗄️ " ;;
        "App Runtime") icon="🚀" ;;
        "Panel & Console") icon="☁️ " ;;
        "Network & Tunnel") icon="🌐" ;;
        "Monitoring & Metrics") icon="📊" ;;
        "Observability Stack") icon="📈" ;;
        "CI/CD Runners") icon="🔄" ;;
      esac
      printf "  %b[%d]%b  %s %-24s %b(%d tools)%b\n" \
        "${C_CYAN}" "$((i+1))" "${C_RESET}" \
        "$icon" "$c" "${C_DIM}" "$count" "${C_RESET}" >&2
    done

    printf "\n%bNAVIGASI CEPAT:%b\n" "${C_DIM}" "${C_RESET}" >&2
    printf "  %b[s]%b  🔍  Cari Script (Search keyword)\n" "${C_YELLOW}" "${C_RESET}" >&2
    printf "  %b[b]%b  📋  Batch Mode (Jalankan banyak script sekaligus)\n" "${C_YELLOW}" "${C_RESET}" >&2
    printf "  %b[h]%b  ℹ️   Audit Sistem Cepat\n" "${C_YELLOW}" "${C_RESET}" >&2
    printf "  %b[q]%b  🚪  Keluar (Exit)\n\n" "${C_RED}" "${C_RESET}" >&2

    printf "%b› Pilih kategori [1-%d] atau menu [s/b/h/q]: %b" "${C_YELLOW}" "${#CATEGORIES[@]}" "${C_RESET}" >&2

    local key=""
    IFS= read -rsn1 key <&3 || break
    printf "\n" >&2

    case "$key" in
      [1-9])
        local idx=$((key - 1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#CATEGORIES[@]}" ]; then
          show_category_menu "${CATEGORIES[idx]}"
        fi
        ;;
      s|S|/) search_interactive ;;
      b|B)   batch_select_mode ;;
      h|H)
        printf "\033[H\033[2J" >&2
        hd "System Diagnostic Snapshot"
        sys_snapshot
        if command -v df >/dev/null 2>&1; then
          printf "\n%bDisk Usage:%b\n" "${C_BOLD}" "${C_RESET}" >&2
          df -h / >&2
        fi
        printf "\n" >&2
        pause
        ;;
      q|Q|0)
        printf "\n%bSampai jumpa! 👋%b\n\n" "${C_CYAN}" "${C_RESET}" >&2
        break
        ;;
      *) ;;
    esac
  done
}

# --- CLI Dispatch ---------------------------------------------------------
case "${1:-}" in
  --help|-h|help)
    cli_help
    exit 0
    ;;
  list|ls)
    cli_list
    exit 0
    ;;
  info|status)
    sys_snapshot
    exit 0
    ;;
  search|find)
    shift
    q="$*"
    if [ -z "$q" ]; then err "Please provide a search term."; exit 1; fi
    cli_list | grep -iE "$q" || echo "No scripts matching '$q'"
    exit 0
    ;;
  run)
    shift
    if [ -z "${1:-}" ]; then err "Script name required. Use: $0 run <script_name>"; exit 1; fi
    run_script "$1"
    exit $?
    ;;
  "")
    # If not a terminal and no input available, print help
    if [ ! -t 0 ] && [ ! -c /dev/tty ]; then
      cli_list
      exit 0
    fi
    interactive_main
    ;;
  *)
    # Direct label shorthand, e.g. `./install.sh docker`
    run_script "$1"
    exit $?
    ;;
esac
