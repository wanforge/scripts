#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install.sh — Portable TUI dashboard & launcher for WanForge server scripts.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/install.sh | bash
#   ./install.sh [1-10 | run <name|num> | list | search <term> | help]
#   ./wf (symlink to install.sh)
#
# Features:
#   - 100% Portable: runs in-place from cloned repo or user-space cache
#   - Zero system pollution: never touches /opt or /usr without explicit instruction
#   - Rock-solid TUI: keyboard-driven (arrows, numeric, Enter, search, batch)
#   - Pure Bash & ANSI: no external curses, python, or package dependencies
#   - Dual-view hierarchy: Category Dashboard -> Script Submenu -> Action
#   - Realtime search filter across all 39 tools
#   - Code viewer (v) to inspect source before running
#   - Batch multi-select runner (b)
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
elif command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}")
elif command -v wget >/dev/null 2>&1; then . <(wget -qO- "${__LIB}")
elif [ -r "${HOME:-}/.cache/wanforge-scripts/lib.sh" ]; then . "${HOME:-}/.cache/wanforge-scripts/lib.sh"
elif [ -r "${HOME:-}/.local/lib/wanforge-scripts/lib.sh" ]; then . "${HOME:-}/.local/lib/wanforge-scripts/lib.sh"
fi

# Defensive fallback in case an older cached lib.sh was sourced
command -v sub >/dev/null 2>&1 || sub() { [ "${LOG_LEVEL:-1}" -ge 1 ] || return 0; [ -n "${C_DIM:-}" ] && printf "    %b↳%b %s\n" "${C_DIM}" "${C_RESET}" "$1" || printf "    ↳ %s\n" "$1"; }

# ANSI Colors defensive defaults
C_RESET="${C_RESET:-\033[0m}"
C_BOLD="${C_BOLD:-\033[1m}"
C_DIM="${C_DIM:-\033[2m}"
C_CYAN="${C_CYAN:-\033[36m}"
C_GREEN="${C_GREEN:-\033[32m}"
C_YELLOW="${C_YELLOW:-\033[33m}"
C_RED="${C_RED:-\033[31m}"
C_WHITE="${C_WHITE:-\033[97m}"
C_REV="${C_REV:-\033[7m}"

# --- safe TTY initialization (FD 3) ---------------------------------------
if [ -t 0 ]; then
  exec 3<&0
elif (exec 3</dev/tty) 2>/dev/null; then
  exec 3</dev/tty
else
  exec 3<&0
fi

# --- portable directory setup (Zero system pollution) ---------------------
if [ -r "${__d}/script/linux/lib.sh" ]; then
  # Local cloned repo mode — 100% in-place execution!
  WF_INSTALL_DIR="${__d}"
  WF_PORTABLE_MODE="repo"
else
  # Remote curl mode — isolated user-space cache, no root pollution!
  WF_INSTALL_DIR="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/wanforge-scripts"
  WF_PORTABLE_MODE="cache"
  mkdir -p "${WF_INSTALL_DIR}" 2>/dev/null || WF_INSTALL_DIR="/tmp/wanforge-$UID-scripts"
  mkdir -p "${WF_INSTALL_DIR}" 2>/dev/null || true
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${__LIB}" -o "${WF_INSTALL_DIR}/lib.sh" 2>/dev/null || true
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "${WF_INSTALL_DIR}/lib.sh" "${__LIB}" 2>/dev/null || true
  fi
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

# --- script registry (39 tools across 10 categories) ----------------------
# Format: "group|label|path-in-repo|description"
SCRIPTS=(
  "System|install-packages|script/linux/system/install-packages.sh|Update system + install base essentials (micro, curl, wget, git, tmux)"
  "System|set-timezone|script/linux/system/set-timezone.sh|Set timezone (UTC recommended for servers)"
  "System|backup-tools|script/linux/system/backup-tools.sh|Backup manager: S3 / FTP / SFTP — named profiles, cron, dry-run"
  "System|sys-troubleshoot|script/linux/system/sys-troubleshoot.sh|Diagnostics: CPU, RAM, services, OOM, logs, firewall, network"
  "System|hardware-info|script/linux/system/hardware-info.sh|Hardware audit: CPU, RAM, disks, GPU, NIC, sensors, virtualization"
  "System|setup-motd|script/linux/system/setup-motd.sh|Custom dynamic SSH login banner (MOTD) with live system KPIs"

  "Security|install-firewall|script/linux/system/install-firewall.sh|Install & configure ufw firewall with base ports"
  "Security|firewall-manager|script/linux/security/firewall-manager.sh|Interactive firewall manager: allow/deny IP/port, rich rules"
  "Security|install-fail2ban|script/linux/security/install-fail2ban.sh|Install & enable Fail2Ban with sane jail defaults"
  "Security|secure-ssh|script/linux/security/secure-ssh.sh|Harden SSH: audit, port change, root/pw lockdown, SELinux & firewall"
  "Security|generate-ssh-key|script/linux/security/generate-ssh-key.sh|Generate an ed25519 SSH key (user-local)"
  "Security|manage-users|script/linux/security/manage-users.sh|Manage Linux users, sudo access & SSH keys"
  "Security|ssl-toolkit|script/linux/security/ssl-toolkit.sh|SSL/TLS certificates: Certbot Let's Encrypt & self-signed"

  "Database|install-postgresql|script/linux/database/install-postgresql.sh|Install PostgreSQL + create roles + remote access"
  "Database|enable-mysql-remote|script/linux/database/enable-mysql-remote.sh|Allow remote MySQL/MariaDB access securely"
  "Database|database-toolkit|script/linux/database/database-toolkit.sh|Monitor, optimize, config, datetime (MySQL/PostgreSQL)"

  "App Runtime|install-docker|script/linux/runtime/install-docker.sh|Container runtimes: Docker & Podman, docker CLI alias/socket, diagnostics & UFW patch"
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

  "AI & Agents|install-ai-agents|script/linux/ai/install-ai-agents.sh|Modular AI stack: Hermes, Claude Code, AGY, 9Router"
  "AI & Agents|setup-hermes-telegram|script/linux/ai/setup-hermes-telegram.sh|Configure Hermes Telegram bot: token, allowed users, groups & topics"
  "AI & Agents|setup-9router-tunnel|script/linux/ai/setup-9router-tunnel.sh|Integrate 9Router with Cloudflare Tunnel & custom domain proxy"
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

# Category summaries for TUI overview
cat_summary() {
  case "$1" in
    "System") echo "Utilitas dasar OS, audit hardware & MOTD" ;;
    "Security") echo "Firewall, Fail2Ban, SSH hardening & SSL" ;;
    "Database") echo "PostgreSQL, MariaDB/MySQL remote & tools" ;;
    "App Runtime") echo "Docker/Podman, Node.js, Python, Composer" ;;
    "Panel & Console") echo "CloudPanel CE v2, clpctl, Cockpit" ;;
    "Network & Tunnel") echo "Cloudflared, net-tools, Proxmox toolkit" ;;
    "Monitoring & Metrics") echo "Monitor realtime, Prometheus, GoAccess" ;;
    "Observability Stack") echo "Grafana, Uptime Kuma, Loki, Zabbix" ;;
    "CI/CD Runners") echo "GitHub Actions & GitLab CI runners" ;;
    "AI & Agents") echo "Hermes Agent, Claude Code, 9Router" ;;
    *) echo "Kumpulan tools otomatisasi server" ;;
  esac
}

# --- script resolver ------------------------------------------------------
resolve_script() {
  local target="$1"

  # 1. Numeric global index (1 to 39)
  if [[ "${target}" =~ ^[0-9]+$ ]] && [ "${target}" -ge 1 ] && [ "${target}" -le "${#SCRIPTS[@]}" ]; then
    IFS='|' read -r _ lbl _ _ <<< "${SCRIPTS[$((target-1))]}"
    echo "${lbl}"
    return 0
  fi

  # 2. Exact or normalized label match
  for row in "${SCRIPTS[@]}"; do
    IFS='|' read -r g lbl rel_path dsc <<< "${row}"
    if [ "${lbl}" = "${target}" ] || [ "${lbl}" = "install-${target}" ] || [ "${target}" = "${rel_path}" ]; then
      echo "${lbl}"
      return 0
    fi
  done

  # 3. Substring match
  local target_lower; target_lower="$(echo "${target}" | tr '[:upper:]' '[:lower:]')"
  for row in "${SCRIPTS[@]}"; do
    IFS='|' read -r g lbl rel_path dsc <<< "${row}"
    if [[ "${lbl}" == *"${target_lower}"* ]]; then
      echo "${lbl}"
      return 0
    fi
  done
  return 1
}

# --- execute a script portably --------------------------------------------
run_script() {
  local target_input="$1"
  local lbl
  lbl="$(resolve_script "${target_input}" 2>/dev/null || echo "")"

  if [ -z "${lbl}" ]; then
    err "Script '${target_input}' tidak ditemukan. Gunakan './wf list' untuk melihat daftar."
    return 1
  fi

  local found=0 g rel_path dsc
  for row in "${SCRIPTS[@]}"; do
    IFS='|' read -r g l rel_path dsc <<< "${row}"
    if [ "${l}" = "${lbl}" ]; then
      found=1
      break
    fi
  done

  local exec_file=""
  local local_candidate="${__d}/${rel_path}"

  # 1. Local execution if running inside cloned repository
  if [ -r "${local_candidate}" ]; then
    exec_file="${local_candidate}"
    chmod +x "${exec_file}" 2>/dev/null || true
  else
    # 2. Remote download and caching into user-space cache
    local perm_file="${WF_INSTALL_DIR}/${lbl}.sh"
    local raw_url="https://scripts.wanforge.asia/${rel_path}"
    local tmp_dl; tmp_dl="$(mktemp 2>/dev/null || echo "/tmp/wf_dl_$$")"

    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "${raw_url}" -o "${tmp_dl}" &
    else
      wget -qO "${tmp_dl}" "${raw_url}" &
    fi
    spinner $! "Mengunduh ${lbl}"
    if ! wait $!; then
      err "Gagal mengunduh: ${raw_url}"
      rm -f "${tmp_dl}"
      return 1
    fi
    mv -f "${tmp_dl}" "${perm_file}"
    chmod +x "${perm_file}"
    exec_file="${perm_file}"
  fi

  printf "\n%b▶ Menjalankan %s...%b\n" "${C_BOLD}${C_GREEN}" "${lbl}" "${C_RESET}" >&2
  printf "%b  %s%b\n\n" "${C_DIM}" "${dsc}" "${C_RESET}" >&2

  export WF_INSTALL_DIR="${WF_INSTALL_DIR}"
  local rc=0
  bash "${exec_file}" || rc=$?

  if [ $rc -eq 0 ]; then
    printf "\n%b✔ %s selesai dengan sukses.%b\n" "${C_GREEN}" "${lbl}" "${C_RESET}" >&2
  else
    printf "\n%b✖ %s keluar dengan kode status %d.%b\n" "${C_RED}" "${lbl}" "$rc" "${C_RESET}" >&2
  fi

  return $rc
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
      printf "%b──────────────────────────────────────────────────────────────────────────%b\n" "${C_DIM}" "${C_RESET}" >&2
    done
    printf "\n%bTekan Enter untuk melanjutkan...%b" "${C_DIM}" "${C_RESET}" >&2
    read -r _ <&3 2>/dev/null || true
  fi
}

# --- Code Viewer / Inspector ----------------------------------------------
tui_view_code() {
  local rel_path="$1"
  local abs_path="${__d}/${rel_path}"
  if [ ! -r "${abs_path}" ]; then
    abs_path="${WF_INSTALL_DIR}/${rel_path##*/}"
  fi

  # Temporarily exit alternate buffer for standard pager
  printf "\033[?1049l\033[?25h" >&2
  stty sane 2>/dev/null || true

  if [ -r "${abs_path}" ]; then
    if command -v less >/dev/null 2>&1; then
      less -N "${abs_path}"
    elif command -v more >/dev/null 2>&1; then
      more "${abs_path}"
    else
      cat -n "${abs_path}" | head -n 45
      printf "\n%bTekan Enter untuk kembali...%b" "${C_DIM}" "${C_RESET}" >&2
      read -r _ <&3 2>/dev/null || true
    fi
  else
    printf "\n%bFile script belum terunduh secara lokal: %s%b\n" "${C_RED}" "${rel_path}" "${C_RESET}" >&2
    printf "%bTekan Enter untuk kembali...%b" "${C_DIM}" "${C_RESET}" >&2
    read -r _ <&3 2>/dev/null || true
  fi

  # Return to alternate buffer
  printf "\033[?1049h\033[?25l" >&2
  stty -echo -icanon min 1 time 0 2>/dev/null || true
}

# --- System Snapshot Modal ------------------------------------------------
tui_sys_info() {
  printf "\033[?1049l\033[?25h" >&2
  stty sane 2>/dev/null || true

  printf "\033[H\033[2J" >&2
  hd "Audit & Snapshot Sistem Server"
  sys_snapshot
  if command -v df >/dev/null 2>&1; then
    printf "\n%bDisk Usage:%b\n" "${C_BOLD}" "${C_RESET}" >&2
    df -h / >&2
  fi
  if command -v free >/dev/null 2>&1; then
    printf "\n%bMemory Usage:%b\n" "${C_BOLD}" "${C_RESET}" >&2
    free -h >&2
  fi
  printf "\n%bTekan Enter untuk kembali ke WanForge TUI...%b" "${C_BOLD}${C_CYAN}" "${C_RESET}" >&2
  read -r _ <&3 2>/dev/null || true

  printf "\033[?1049h\033[?25l" >&2
  stty -echo -icanon min 1 time 0 2>/dev/null || true
}

# --- CLI List -------------------------------------------------------------
cli_list() {
  printf "\n%bWANFORGE SCRIPTS REPOSITORY — AVAILABLE TOOLS (%d TOOLS)%b\n" "${C_BOLD}${C_CYAN}" "${#SCRIPTS[@]}" "${C_RESET}"
  local cur_g="" idx=0
  for row in "${SCRIPTS[@]}"; do
    idx=$((idx + 1))
    IFS='|' read -r g lbl rel_path dsc <<< "${row}"
    if [ "$g" != "$cur_g" ]; then
      printf "\n%b── %s ──%b\n" "${C_BOLD}${C_YELLOW}" "$g" "${C_RESET}"
      cur_g="$g"
    fi
    printf "  %b[%2d]%b  %-24s  %s\n" "${C_YELLOW}" "$idx" "${C_RESET}" "${lbl}" "${dsc}"
  done
  printf "\n"
}

# --- CLI Help -------------------------------------------------------------
cli_help() {
  printf "WANFORGE Server Ops Toolkit v2.5 (Portable TUI & CLI)\n\n"
  printf "Penggunaan:\n"
  printf "  %s                      Jalankan TUI interaktif keyboard\n" "$0"
  printf "  %s 1-10                 Buka kategori 1 sampai 10 langsung\n" "$0"
  printf "  %s 1-39                 Jalankan script nomor 1 sampai 39 langsung\n" "$0"
  printf "  %s <script_name>        Jalankan script berdasarkan nama (contoh: setup-motd)\n" "$0"
  printf "  %s list                 Tampilkan seluruh tools (%d) dalam daftar rapi\n" "$0" "${#SCRIPTS[@]}"
  printf "  %s search <keyword>     Cari script berdasarkan kata kunci\n" "$0"
  printf "  %s run <name|number>    Jalankan script tertentu secara non-interaktif\n" "$0"
  printf "  %s info                 Audit ringkas status server (OS, Load, RAM, IP)\n" "$0"
  printf "  %s --classic            Gunakan antarmuka menu prompt klasik\n" "$0"
  printf "  %s --help               Tampilkan bantuan ini\n\n" "$0"
}

# --- Single Key Input Reader ----------------------------------------------
read_tui_key() {
  local k rest
  IFS= read -rsn1 k <&3 || return 1
  if [ "$k" = $'\x1b' ]; then
    IFS= read -rsn2 -t 0.05 rest <&3 || rest=""
    k+="$rest"
    if [ "$k" = $'\x1b[' ]; then
      IFS= read -rsn1 -t 0.05 rest <&3 || rest=""
      k+="$rest"
    fi
  fi
  printf "%s" "$k"
}

# --- TUI Level 3: Realtime Search Screen ----------------------------------
tui_search_screen() {
  local query=""
  local cursor=0
  local scroll=0

  while true; do
    local matched=() m_labels=() m_paths=() m_descs=() m_cats=()
    local q_lower; q_lower="$(echo "${query}" | tr '[:upper:]' '[:lower:]')"

    for row in "${SCRIPTS[@]}"; do
      IFS='|' read -r g lbl rel dsc <<< "${row}"
      local search_space; search_space="$(echo "${g} ${lbl} ${dsc}" | tr '[:upper:]' '[:lower:]')"
      if [ -z "${query}" ] || [[ "${search_space}" == *"${q_lower}"* ]]; then
        matched+=("${row}")
        m_cats+=("${g}")
        m_labels+=("${lbl}")
        m_paths+=("${rel}")
        m_descs+=("${dsc}")
      fi
    done

    local total=${#matched[@]}
    if [ "$cursor" -ge "$total" ]; then
      cursor=$(( total > 0 ? total - 1 : 0 ))
    fi

    local lines; lines="$(tput lines 2>/dev/null || echo 24)"
    local max_items=$(( lines - 14 ))
    [ "$max_items" -lt 6 ] && max_items=6

    if [ "$cursor" -lt "$scroll" ]; then
      scroll=$cursor
    elif [ "$cursor" -ge "$((scroll + max_items))" ]; then
      scroll=$(( cursor - max_items + 1 ))
    fi

    # Render frame
    local frame="\033[H"
    append_frame() { local _l; printf -v _l "$@"; frame+="${_l}"; }

    append_frame " %b╔════════════════════════════════════════════════════════════════════════╗%b\033[K\n" "${C_CYAN}" "${C_RESET}"
    append_frame " %b║%b  %bPENCARIAN MODUL TOOLKIT%b                            %b● REALTIME FILTER%b  %b║%b\033[K\n" \
      "${C_CYAN}" "${C_RESET}" "${C_BOLD}${C_WHITE}" "${C_RESET}" "${C_BOLD}${C_YELLOW}" "${C_RESET}" "${C_CYAN}" "${C_RESET}"
    append_frame " %b╚════════════════════════════════════════════════════════════════════════╝%b\033[K\n" "${C_CYAN}" "${C_RESET}"
    append_frame "  %bKetik kata kunci untuk memfilter tools:%b\033[K\n" "${C_DIM}" "${C_RESET}"
    local q_display="${query}█"
    append_frame "  %b🔍 Query:%b [%-45.45s] %b(%d ditemukan)%b\033[K\n" \
      "${C_BOLD}${C_YELLOW}" "${C_RESET}" "${q_display}" "${C_CYAN}" "$total" "${C_RESET}"
    append_frame " %b──────────────────────────────────────────────────────────────────────────%b\033[K\n" "${C_DIM}" "${C_RESET}"

    for ((i = 0; i < max_items; i++)); do
      local idx=$(( scroll + i ))
      if [ "$idx" -lt "$total" ]; then
        local lbl="${m_labels[idx]}"
        local cat="${m_cats[idx]}"
        local dsc="${m_descs[idx]}"
        local is_sel=0; [ "$idx" -eq "$cursor" ] && is_sel=1

        local max_d=26
        local short_dsc="${dsc:0:max_d}"
        [ "${#dsc}" -gt "$max_d" ] && short_dsc="${short_dsc:0:$((max_d-1))}…"

        if [ "$is_sel" -eq 1 ]; then
          append_frame "%b❯ %2d) %-20.20s %b[%-13.13s]%b %b%s%b\033[K\n" \
            "${C_BOLD}${C_GREEN}" "$((idx+1))" "$lbl" \
            "${C_CYAN}" "$cat" "${C_RESET}" \
            "${C_WHITE}" "$short_dsc" "${C_RESET}"
        else
          append_frame "  %2d) %-20.20s %b[%-13.13s]%b %b%s%b\033[K\n" \
            "$((idx+1))" "$lbl" \
            "${C_DIM}" "$cat" "${C_RESET}" \
            "${C_DIM}" "$short_dsc" "${C_RESET}"
        fi
      else
        append_frame "\033[K\n"
      fi
    done

    append_frame " %b──────────────────────────────────────────────────────────────────────────%b\033[K\n" "${C_DIM}" "${C_RESET}"
    if [ "$total" -gt 0 ] && [ "$cursor" -lt "$total" ]; then
      local sel_lbl="${m_labels[cursor]}"
      local sel_rel="${m_paths[cursor]}"
      append_frame "  %bPath :%b %-60.60s\033[K\n" "${C_DIM}" "${C_RESET}" "${sel_rel}"
    else
      append_frame "  %bInfo : Tidak ada tools yang cocok dengan kata kunci '%s'%b\033[K\n" "${C_YELLOW}" "${query}" "${C_RESET}"
    fi
    append_frame " %b──────────────────────────────────────────────────────────────────────────%b\033[K\n" "${C_DIM}" "${C_RESET}"
    append_frame "  %b[Enter]%b Jalankan   %b[v]%b Lihat Kode   %b[↑/↓]%b Pindah   %b[Esc / 0]%b Kembali\033[K\n" \
      "${C_GREEN}" "${C_RESET}" "${C_CYAN}" "${C_RESET}" "${C_YELLOW}" "${C_RESET}" "${C_RED}" "${C_RESET}"
    append_frame "\033[J"

    printf "%b" "$frame" >&2

    local k
    k="$(read_tui_key)" || break

    case "$k" in
      $'\x1b'|$'\x1b\x1b')
        if [ -n "${query}" ]; then
          query=""
          cursor=0; scroll=0
        else
          return 0
        fi
        ;;

      $'\x1b[A'|k) # UP
        [ "$cursor" -gt 0 ] && cursor=$((cursor - 1))
        ;;

      $'\x1b[B'|j) # DOWN
        [ "$cursor" -lt "$((total - 1))" ] && cursor=$((cursor + 1))
        ;;

      $'\n'|$'\r') # ENTER
        if [ "$total" -gt 0 ] && [ "$cursor" -lt "$total" ]; then
          local chosen="${m_labels[cursor]}"
          printf "\033[?1049l\033[?25h" >&2
          stty sane 2>/dev/null || true
          run_script "${chosen}" || true
          printf "\n%bTekan Enter untuk kembali ke WanForge TUI...%b" "${C_BOLD}${C_CYAN}" "${C_RESET}" >&2
          read -r _ <&3 2>/dev/null || true
          printf "\033[?1049h\033[?25l" >&2
          stty -echo -icanon min 1 time 0 2>/dev/null || true
        fi
        ;;

      v|V) # VIEW CODE
        if [ "$total" -gt 0 ] && [ "$cursor" -lt "$total" ]; then
          tui_view_code "${m_paths[cursor]}"
        fi
        ;;

      $'\x7f'|$'\x08') # BACKSPACE
        if [ ${#query} -gt 0 ]; then
          query="${query:0:-1}"
          cursor=0; scroll=0
        else
          return 0
        fi
        ;;

      [[:print:]])
        query+="$k"
        cursor=0; scroll=0
        ;;
    esac
  done
}

# --- TUI Level 2: Submenu (Category Tools) --------------------------------
tui_category_submenu() {
  local target_cat="$1"
  local items=() labels=() paths=() descs=()

  for row in "${SCRIPTS[@]}"; do
    IFS='|' read -r g lbl rel dsc <<< "${row}"
    if [ "$g" = "$target_cat" ]; then
      items+=("${row}")
      labels+=("${lbl}")
      paths+=("${rel}")
      descs+=("${dsc}")
    fi
  done

  local n=${#items[@]}
  local cursor=0
  local scroll=0

  while true; do
    local lines; lines="$(tput lines 2>/dev/null || echo 24)"
    local max_items=$(( lines - 14 ))
    [ "$max_items" -lt 6 ] && max_items=6

    if [ "$cursor" -lt "$scroll" ]; then
      scroll=$cursor
    elif [ "$cursor" -ge "$((scroll + max_items))" ]; then
      scroll=$(( cursor - max_items + 1 ))
    fi

    # Render frame
    local frame="\033[H"
    append_frame() { local _l; printf -v _l "$@"; frame+="${_l}"; }

    local cat_title="KATEGORI: ${target_cat^^} (${n} TOOLS)"
    local t_len=${#cat_title}
    local cat_spaces=$(( 72 - 4 - t_len - 15 ))
    [ "$cat_spaces" -lt 2 ] && cat_spaces=2
    local cat_sp; cat_sp="$(printf "%*s" "$cat_spaces" "")"

    append_frame " %b╔════════════════════════════════════════════════════════════════════════╗%b\033[K\n" "${C_CYAN}" "${C_RESET}"
    append_frame " %b║%b  %b%s%b%s%b● PORTABLE MODE%b  %b║%b\033[K\n" \
      "${C_CYAN}" "${C_RESET}" "${C_BOLD}${C_WHITE}" "${cat_title}" "${C_RESET}" "${cat_sp}" "${C_BOLD}${C_GREEN}" "${C_RESET}" "${C_CYAN}" "${C_RESET}"
    append_frame " %b╚════════════════════════════════════════════════════════════════════════╝%b\033[K\n" "${C_CYAN}" "${C_RESET}"
    append_frame "  %b[1-%d] Nomor · ↑/↓ Pindah · ENTER Jalankan · V Lihat Kode · 0 Kembali%b\033[K\n\n" \
      "${C_DIM}" "$n" "${C_RESET}"
    append_frame "  %b── Daftar Script ──%b\033[K\n" "${C_BOLD}${C_YELLOW}" "${C_RESET}"

    for ((i = 0; i < max_items; i++)); do
      local idx=$(( scroll + i ))
      if [ "$idx" -lt "$n" ]; then
        local lbl="${labels[idx]}"
        local dsc="${descs[idx]}"
        local is_sel=0; [ "$idx" -eq "$cursor" ] && is_sel=1

        local max_d=40
        local short_dsc="${dsc:0:max_d}"
        [ "${#dsc}" -gt "$max_d" ] && short_dsc="${short_dsc:0:$((max_d-1))}…"

        if [ "$is_sel" -eq 1 ]; then
          append_frame "%b❯ %2d) %-22.22s %b%s%b\033[K\n" \
            "${C_BOLD}${C_GREEN}" "$((idx+1))" "$lbl" "${C_WHITE}" "$short_dsc" "${C_RESET}"
        else
          append_frame "  %2d) %-22.22s %b%s%b\033[K\n" \
            "$((idx+1))" "$lbl" "${C_DIM}" "$short_dsc" "${C_RESET}"
        fi
      else
        append_frame "\033[K\n"
      fi
    done

    local sel_lbl="${labels[cursor]}"
    local sel_rel="${paths[cursor]}"
    local sel_dsc="${descs[cursor]}"

    append_frame " %b──────────────────────────────────────────────────────────────────────────%b\033[K\n" "${C_DIM}" "${C_RESET}"
    append_frame "  %bPath :%b %-60.60s\033[K\n" "${C_DIM}" "${C_RESET}" "${sel_rel}"
    append_frame "  %bDesc :%b %-60.60s\033[K\n" "${C_DIM}" "${C_RESET}" "${sel_dsc}"
    append_frame " %b──────────────────────────────────────────────────────────────────────────%b\033[K\n" "${C_DIM}" "${C_RESET}"
    append_frame "  %b[Enter]%b Jalankan Tool   %b[v]%b Lihat Source Code   %b[0 / q]%b Kembali\033[K\n" \
      "${C_GREEN}" "${C_RESET}" "${C_CYAN}" "${C_RESET}" "${C_RED}" "${C_RESET}"
    append_frame "\033[J"

    printf "%b" "$frame" >&2

    local k
    k="$(read_tui_key)" || break

    case "$k" in
      $'\x1b[A'|k) # UP
        [ "$cursor" -gt 0 ] && cursor=$((cursor - 1))
        ;;

      $'\x1b[B'|j) # DOWN
        [ "$cursor" -lt "$((n - 1))" ] && cursor=$((cursor + 1))
        ;;

      [1-9])
        local num_str="${k}"
        if [ "$n" -ge 10 ]; then
          local next_ch=""
          if IFS= read -rsn1 -t 0.2 next_ch <&3 2>/dev/null; then
            if [[ "${next_ch}" =~ ^[0-9]$ ]]; then
              num_str="${k}${next_ch}"
            fi
          fi
        fi
        local target_idx=$(( 10#${num_str} - 1 ))
        if [ "$target_idx" -ge 0 ] && [ "$target_idx" -lt "$n" ]; then
          cursor=$target_idx
        fi
        ;;

      $'\n'|$'\r') # ENTER
        local chosen="${labels[cursor]}"
        printf "\033[?1049l\033[?25h" >&2
        stty sane 2>/dev/null || true
        run_script "${chosen}" || true
        printf "\n%bTekan Enter untuk kembali ke WanForge TUI...%b" "${C_BOLD}${C_CYAN}" "${C_RESET}" >&2
        read -r _ <&3 2>/dev/null || true
        printf "\033[?1049h\033[?25l" >&2
        stty -echo -icanon min 1 time 0 2>/dev/null || true
        ;;

      v|V) # VIEW CODE
        tui_view_code "${paths[cursor]}"
        ;;

      0|q|Q|$'\x1b'|$'\x1b\x1b') # BACK
        return 0
        ;;
    esac
  done
}

# --- TUI Level 1: Category Dashboard (Main Entry) -------------------------
tui_cleanup() {
  printf "\033[?1049l\033[?25h\033[0m" >&2
  stty sane 2>/dev/null || true
}

tui_main() {
  local orig_stty=""
  orig_stty="$(stty -g 2>/dev/null || true)"
  trap 'tui_cleanup; [ -n "${orig_stty:-}" ] && stty "${orig_stty:-}" 2>/dev/null || true; exit 0' EXIT INT TERM

  # Switch to alternate buffer and hide cursor
  printf "\033[?1049h\033[?25l" >&2
  stty -echo -icanon min 1 time 0 2>/dev/null || true

  local cursor=0
  local num_cats=${#CATEGORIES[@]}

  # Fast system KPI lookup (cached for TUI header strip)
  local kpi_host; kpi_host="$(hostname -s 2>/dev/null || echo "host")"
  local kpi_ip; kpi_ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' || echo "127.0.0.1")"
  local kpi_os; kpi_os="$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' | sed -E 's/\s*\((KDE|GNOME|Plasma|XFCE|Workstation|Server)[^\)]*\)//gI' || uname -s)"
  local kpi_ram; kpi_ram="$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2}' || echo "N/A")"

  while true; do
    # Render frame
    local frame="\033[H"
    append_frame() { local _l; printf -v _l "$@"; frame+="${_l}"; }

    append_frame " %b╔════════════════════════════════════════════════════════════════════════╗%b\033[K\n" "${C_CYAN}" "${C_RESET}"
    append_frame " %b║%b  %bWANFORGE SERVER OPS TOOLKIT%b                           %b● PORTABLE TUI%b  %b║%b\033[K\n" \
      "${C_CYAN}" "${C_RESET}" "${C_BOLD}${C_WHITE}" "${C_RESET}" "${C_BOLD}${C_GREEN}" "${C_RESET}" "${C_CYAN}" "${C_RESET}"
    append_frame " %b╚════════════════════════════════════════════════════════════════════════╝%b\033[K\n" "${C_CYAN}" "${C_RESET}"
    append_frame "  %b•%b Host: %b%-12.12s%b (%s)  %b•%b OS: %b%-16.16s%b  %b•%b RAM: %b%s%b\033[K\n" \
      "${C_CYAN}" "${C_RESET}" "${C_BOLD}${C_WHITE}" "${kpi_host}" "${C_RESET}" "${kpi_ip}" \
      "${C_CYAN}" "${C_RESET}" "${C_WHITE}" "${kpi_os}" "${C_RESET}" \
      "${C_CYAN}" "${C_RESET}" "${C_GREEN}" "${kpi_ram}" "${C_RESET}"
    append_frame " %b──────────────────────────────────────────────────────────────────────────%b\033[K\n" "${C_DIM}" "${C_RESET}"
    append_frame "  %bPILIH KATEGORI TOOLKIT:%b\033[K\n" "${C_BOLD}${C_YELLOW}" "${C_RESET}"
    append_frame "  %b[1-10] Nomor · ↑/↓ Pindah · ENTER Buka · / Cari · B Batch · Q Keluar%b\033[K\n\n" "${C_DIM}" "${C_RESET}"
    append_frame "  %b── Kategori Modul ──%b\033[K\n" "${C_BOLD}${C_YELLOW}" "${C_RESET}"

    for ((i = 0; i < num_cats; i++)); do
      local c="${CATEGORIES[i]}"
      local cnt=0
      for s in "${SCRIPTS[@]}"; do IFS='|' read -r cg _ <<< "$s"; [ "$cg" = "$c" ] && cnt=$((cnt + 1)); done
      local sum; sum="$(cat_summary "$c")"
      local is_sel=0; [ "$i" -eq "$cursor" ] && is_sel=1

      local cat_fmt="[${c}]"
      if [ "$is_sel" -eq 1 ]; then
        append_frame "%b❯ %2d) %-23.23s %b(%d tools)%b  %b%s%b\033[K\n" \
          "${C_BOLD}${C_CYAN}" "$((i+1))" "$cat_fmt" \
          "${C_GREEN}" "$cnt" "${C_RESET}" \
          "${C_WHITE}" "$sum" "${C_RESET}"
      else
        append_frame "  %2d) %-23.23s %b(%d tools)%b  %b%s%b\033[K\n" \
          "$((i+1))" "$cat_fmt" \
          "${C_DIM}" "$cnt" "${C_RESET}" \
          "${C_DIM}" "$sum" "${C_RESET}"
      fi
    done

    append_frame "\n %b──────────────────────────────────────────────────────────────────────────%b\033[K\n" "${C_DIM}" "${C_RESET}"
    append_frame "  %b[ /]%b Cari Tools   %b[ b]%b Batch Mode   %b[ i]%b Audit Server   %b[ q]%b Keluar\033[K\n" \
      "${C_YELLOW}" "${C_RESET}" "${C_YELLOW}" "${C_RESET}" "${C_CYAN}" "${C_RESET}" "${C_RED}" "${C_RESET}"
    append_frame " %b──────────────────────────────────────────────────────────────────────────%b\033[K\n" "${C_DIM}" "${C_RESET}"
    append_frame "\033[J"

    printf "%b" "$frame" >&2

    local k
    k="$(read_tui_key)" || break

    case "$k" in
      $'\x1b[A'|k) # UP
        [ "$cursor" -gt 0 ] && cursor=$((cursor - 1))
        ;;

      $'\x1b[B'|j) # DOWN
        [ "$cursor" -lt "$((num_cats - 1))" ] && cursor=$((cursor + 1))
        ;;

      [1-9])
        local num_str="${k}"
        if [ "$num_cats" -ge 10 ]; then
          local next_ch=""
          if IFS= read -rsn1 -t 0.2 next_ch <&3 2>/dev/null; then
            if [[ "${next_ch}" =~ ^[0-9]$ ]]; then
              num_str="${k}${next_ch}"
            fi
          fi
        fi
        local target_idx=$(( 10#${num_str} - 1 ))
        if [ "$target_idx" -ge 0 ] && [ "$target_idx" -lt "$num_cats" ]; then
          cursor=$target_idx
          tui_category_submenu "${CATEGORIES[cursor]}"
        fi
        ;;

      0)
        if [ "$num_cats" -ge 10 ]; then
          cursor=9
          tui_category_submenu "${CATEGORIES[cursor]}"
        fi
        ;;

      $'\n'|$'\r') # ENTER
        tui_category_submenu "${CATEGORIES[cursor]}"
        ;;

      /|s|S) # SEARCH
        tui_search_screen
        ;;

      b|B) # BATCH SELECT
        printf "\033[?1049l\033[?25h" >&2
        stty sane 2>/dev/null || true
        batch_select_mode || true
        printf "\033[?1049h\033[?25l" >&2
        stty -echo -icanon min 1 time 0 2>/dev/null || true
        ;;

      i|I) # SYS INFO
        tui_sys_info
        ;;

      q|Q|$'\x1b'|$'\x1b\x1b') # QUIT
        break
        ;;
    esac
  done

  tui_cleanup
  printf "\n%bSampai jumpa! WanForge Ops Toolkit selesai. 👋%b\n\n" "${C_BOLD}${C_CYAN}" "${C_RESET}" >&2
}

# --- Classic Prompt Menu Fallback -----------------------------------------
classic_menu() {
  while true; do
    printf "\033[H\033[2J" >&2
    banner "Server Toolkit v2.5"
    sys_snapshot

    printf "\n%bKATEGORI SCRIPT:%b\n" "${C_BOLD}${C_YELLOW}" "${C_RESET}" >&2
    for ((i = 0; i < ${#CATEGORIES[@]}; i++)); do
      local c="${CATEGORIES[i]}"
      local count=0
      for r in "${SCRIPTS[@]}"; do
        IFS='|' read -r g _ <<< "${r}"
        [ "$g" = "$c" ] && count=$((count + 1))
      done
      printf "  %b[%2d]%b  %-24s  %b(%d tools)%b\n" \
        "${C_CYAN}" "$((i+1))" "${C_RESET}" \
        "$c" "${C_DIM}" "$count" "${C_RESET}" >&2
    done

    printf "\n%bNAVIGASI CEPAT:%b\n" "${C_DIM}" "${C_RESET}" >&2
    printf "  %b[ s]%b  Cari Script (Search keyword)\n" "${C_YELLOW}" "${C_RESET}" >&2
    printf "  %b[ b]%b  Batch Mode (Jalankan banyak script sekaligus)\n" "${C_YELLOW}" "${C_RESET}" >&2
    printf "  %b[ h]%b  Audit Sistem Cepat\n" "${C_YELLOW}" "${C_RESET}" >&2
    printf "  %b[ q]%b  Keluar (Exit)\n\n" "${C_RED}" "${C_RESET}" >&2

    printf "%b› Masukkan nomor kategori [1-%d] atau menu [s/b/h/q]: %b" "${C_YELLOW}" "${#CATEGORIES[@]}" "${C_RESET}" >&2

    local choice=""
    read -r choice <&3 || break
    choice="$(echo "${choice}" | tr -d '[:space:]')"

    case "${choice}" in
      s|S|/) tui_search_screen ;;
      b|B)   batch_select_mode ;;
      h|H)   tui_sys_info ;;
      q|Q|0|exit)
        printf "\n%bSampai jumpa! 👋%b\n\n" "${C_CYAN}" "${C_RESET}" >&2
        break
        ;;
      "") ;;
      *)
        if [[ "${choice}" =~ ^[0-9]+$ ]] && [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#CATEGORIES[@]}" ]; then
          tui_category_submenu "${CATEGORIES[$((choice-1))]}"
        else
          local resolved
          resolved="$(resolve_script "${choice}" 2>/dev/null || echo "")"
          if [ -n "${resolved}" ]; then
            run_script "${resolved}" || true
          fi
        fi
        ;;
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
  --classic|classic)
    classic_menu
    exit 0
    ;;
  search|find)
    shift
    q="$*"
    if [ -z "$q" ]; then
      cli_help
      exit 0
    fi
    cli_list | grep -iE "$q" || echo "Tidak ada script yang cocok dengan '$q'"
    exit 0
    ;;
  run)
    shift
    if [ -z "${1:-}" ]; then err "Nama atau nomor script diperlukan. Contoh: $0 run docker"; exit 1; fi
    target_lbl="$(resolve_script "$1" 2>/dev/null || echo "")"
    if [ -z "${target_lbl}" ]; then err "Script '$1' tidak ditemukan."; exit 1; fi
    run_script "${target_lbl}"
    exit $?
    ;;
  "")
    if [ ! -t 0 ] && [ ! -c /dev/tty ]; then
      cli_list
      exit 0
    fi
    tui_main
    ;;
  *)
    # Numeric category index: `./wf 1` opens Category 1
    if [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le "${#CATEGORIES[@]}" ] && [ -z "${2:-}" ]; then
      tui_category_submenu "${CATEGORIES[$(($1-1))]}"
      exit 0
    elif [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le "${#CATEGORIES[@]}" ] && [ -n "${2:-}" ]; then
      target_cat="${CATEGORIES[$(($1-1))]}"
      sub_items=()
      for row in "${SCRIPTS[@]}"; do
        IFS='|' read -r g lbl _ _ <<< "${row}"
        [ "$g" = "${target_cat}" ] && sub_items+=("${lbl}")
      done
      if [ "$2" -ge 1 ] && [ "$2" -le "${#sub_items[@]}" ]; then
        run_script "${sub_items[$(($2-1))]}"
        exit $?
      else
        err "Nomor script $2 tidak valid untuk kategori $1 (1-${#sub_items[@]})."
        exit 1
      fi
    fi

    # Global resolution (number 1..39 or script name)
    target_lbl="$(resolve_script "$1" 2>/dev/null || echo "")"
    if [ -n "${target_lbl}" ]; then
      run_script "${target_lbl}"
      exit $?
    else
      err "Pilihan '$1' tidak ditemukan. Gunakan './wf list' untuk melihat daftar script."
      exit 1
    fi
    ;;
esac
