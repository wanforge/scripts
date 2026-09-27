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
#   - Interactive keyboard-driven dual-pane TUI (Zero external dependencies)
#   - 100% Portable: runs in-place from repo or isolated user-space cache
#   - Real-time search filter across all 39 ops tools
#   - Direct tool runner, code inspector (v), batch mode (b), sys snapshot (i)
#   - Full CLI fallback for CI/CD and automated terminal pipelines
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
  # Remote curl mode — user-space portable cache, no root pollution!
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

# --- script registry ------------------------------------------------------
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
    err "Script '${target_input}' tidak ditemukan. Gunakan './install.sh list' untuk melihat daftar."
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
    printf "\n%bFile script belum terunduh: %s%b\n" "${C_RED}" "${rel_path}" "${C_RESET}" >&2
    printf "%bTekan Enter untuk kembali...%b" "${C_DIM}" "${C_RESET}" >&2
    read -r _ <&3 2>/dev/null || true
  fi

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
  printf "  %s                      Jalankan TUI interaktif keyboard (Dual-Pane)\n" "$0"
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

# --- TUI Engine (Interactive Dual-Pane, Zero-Dependency) -------------------
tui_cleanup() {
  printf "\033[?1049l\033[?25h\033[0m" >&2
  stty sane 2>/dev/null || true
}

tui_main() {
  local orig_stty
  orig_stty="$(stty -g 2>/dev/null || true)"
  trap 'tui_cleanup; [ -n "${orig_stty}" ] && stty "${orig_stty}" 2>/dev/null || true; exit 0' EXIT INT TERM

  # Switch to alternate buffer and hide cursor
  printf "\033[?1049h\033[?25l" >&2
  stty -echo -icanon min 1 time 0 2>/dev/null || true

  local focus=0 # 0=left (categories), 1=right (tools)
  local cat_idx=0
  local tool_idx=0
  local tool_scroll=0
  local search_mode=0
  local search_query=""
  local status_toast=""

  while true; do
    # Terminal dimensions
    local lines cols
    lines="$(tput lines 2>/dev/null || echo 24)"
    cols="$(tput cols 2>/dev/null || echo 80)"
    [ "$lines" -lt 16 ] && lines=16
    [ "$cols" -lt 60 ] && cols=60

    local w_total=$cols
    [ "$w_total" -gt 96 ] && w_total=96
    local w_left=25
    local w_right=$(( w_total - w_left - 3 ))
    local h_list=$(( lines - 14 ))
    [ "$h_list" -lt 6 ] && h_list=6

    # Current Category Tools
    local cur_cat="${CATEGORIES[cat_idx]}"
    local cur_tools=() cur_labels=() cur_paths=() cur_descs=()

    if [ "$search_mode" -eq 1 ] && [ -n "${search_query}" ]; then
      local q_lower; q_lower="$(echo "${search_query}" | tr '[:upper:]' '[:lower:]')"
      for row in "${SCRIPTS[@]}"; do
        IFS='|' read -r g lbl rel dsc <<< "${row}"
        local hay; hay="$(echo "${g} ${lbl} ${dsc}" | tr '[:upper:]' '[:lower:]')"
        if [[ "${hay}" == *"${q_lower}"* ]]; then
          cur_tools+=("${row}")
          cur_labels+=("${lbl}")
          cur_paths+=("${rel}")
          cur_descs+=("${dsc}")
        fi
      done
    else
      for row in "${SCRIPTS[@]}"; do
        IFS='|' read -r g lbl rel dsc <<< "${row}"
        if [ "$g" = "$cur_cat" ]; then
          cur_tools+=("${row}")
          cur_labels+=("${lbl}")
          cur_paths+=("${rel}")
          cur_descs+=("${dsc}")
        fi
      done
    fi

    local num_tools=${#cur_tools[@]}
    if [ "$tool_idx" -ge "$num_tools" ]; then
      tool_idx=$(( num_tools > 0 ? num_tools - 1 : 0 ))
    fi

    # Adjust scroll offset
    if [ "$tool_idx" -lt "$tool_scroll" ]; then
      tool_scroll=$tool_idx
    elif [ "$tool_idx" -ge "$((tool_scroll + h_list))" ]; then
      tool_scroll=$(( tool_idx - h_list + 1 ))
    fi

    # --- Render Full Atomic Frame -----------------------------------------
    local frame=""
    frame+="\033[H"

    # Top Box
    local inner_w=$(( w_total - 2 ))
    local title="⚡ WANFORGE OPS TOOLKIT v2.5"
    local badge="● PORTABLE RUNNER"
    local spaces=$(( inner_w - 29 - 17 ))
    [ "$spaces" -lt 2 ] && spaces=2
    local sp_str; sp_str="$(printf "%*s" "$spaces" "")"

    frame+=" ${C_CYAN}╔$(printf '═%.0s' $(seq 1 $inner_w))╗${C_RESET}\n"
    frame+=" ${C_CYAN}║${C_RESET}  ${C_BOLD}${C_WHITE}${title}${C_RESET}${sp_str}${C_BOLD}${C_GREEN}${badge}${C_RESET}  ${C_CYAN}║${C_RESET}\n"
    frame+=" ${C_CYAN}╚$(printf '═%.0s' $(seq 1 $inner_w))╝${C_RESET}\n"

    # Pane Headers
    local l_hdr_text="── Kategori "
    local l_hdr_dashes=$(( w_left - 12 ))
    [ "$l_hdr_dashes" -lt 1 ] && l_hdr_dashes=1
    local l_hdr="${l_hdr_text}$(printf '─%.0s' $(seq 1 $l_hdr_dashes))"

    local r_hdr_title
    if [ "$search_mode" -eq 1 ] && [ -n "${search_query}" ]; then
      r_hdr_title="── Cari: '${search_query}' (${num_tools}) "
    else
      r_hdr_title="── ${cur_cat} (${num_tools}) "
    fi
    local r_hdr_len=${#r_hdr_title}
    local r_hdr_dashes=$(( w_right - r_hdr_len ))
    [ "$r_hdr_dashes" -lt 1 ] && r_hdr_dashes=1
    local r_hdr="${r_hdr_title}$(printf '─%.0s' $(seq 1 $r_hdr_dashes))"

    if [ "$focus" -eq 0 ]; then
      frame+=" ${C_BOLD}${C_CYAN}${l_hdr}${C_RESET} ${C_DIM}┬${C_RESET} ${C_DIM}${r_hdr}${C_RESET}\n"
    else
      frame+=" ${C_DIM}${l_hdr}${C_RESET} ${C_DIM}┬${C_RESET} ${C_BOLD}${C_CYAN}${r_hdr}${C_RESET}\n"
    fi

    # Body Rows
    for ((r = 0; r < h_list; r++)); do
      # --- Left Column (Category) ---
      local cell_left=""
      if [ "$r" -lt "${#CATEGORIES[@]}" ]; then
        local cat_name="${CATEGORIES[r]}"
        local cnt=0
        for s in "${SCRIPTS[@]}"; do IFS='|' read -r cg _ <<< "$s"; [ "$cg" = "$cat_name" ] && cnt=$((cnt + 1)); done
        
        local is_c_sel=0; [ "$r" -eq "$cat_idx" ] && is_c_sel=1
        local num_str="$((r+1))"
        [ "$r" -eq 9 ] && num_str="0"

        if [ "$is_c_sel" -eq 1 ] && [ "$focus" -eq 0 ]; then
          cell_left="$(printf "%b❯ [%2s] %-12.12s (%d)%b" "${C_BOLD}${C_CYAN}" "$num_str" "$cat_name" "$cnt" "${C_RESET}")"
        elif [ "$is_c_sel" -eq 1 ]; then
          cell_left="$(printf "%b▸ [%2s] %-12.12s (%d)%b" "${C_CYAN}" "$num_str" "$cat_name" "$cnt" "${C_RESET}")"
        else
          cell_left="$(printf "  [%2s] %-12.12s %b(%d)%b" "$num_str" "$cat_name" "${C_DIM}" "$cnt" "${C_RESET}")"
        fi
      fi

      # --- Right Column (Tools) ---
      local cell_right=""
      local t_row_idx=$(( tool_scroll + r ))
      if [ "$t_row_idx" -lt "$num_tools" ]; then
        local t_lbl="${cur_labels[t_row_idx]}"
        local t_dsc="${cur_descs[t_row_idx]}"
        local is_t_sel=0; [ "$t_row_idx" -eq "$tool_idx" ] && is_t_sel=1

        local max_dsc_len=$(( w_right - ${#t_lbl} - 12 ))
        [ "$max_dsc_len" -lt 5 ] && max_dsc_len=5
        local short_dsc="${t_dsc:0:max_dsc_len}"
        [ "${#t_dsc}" -gt "$max_dsc_len" ] && short_dsc="${short_dsc:0:$((max_dsc_len-1))}…"

        if [ "$is_t_sel" -eq 1 ] && [ "$focus" -eq 1 ]; then
          cell_right="$(printf "%b❯ [%2d] %-20.20s %b%s%b" "${C_BOLD}${C_GREEN}" "$((t_row_idx+1))" "$t_lbl" "${C_WHITE}" "$short_dsc" "${C_RESET}")"
        elif [ "$is_t_sel" -eq 1 ]; then
          cell_right="$(printf "%b▸ [%2d] %-20.20s %b%s%b" "${C_GREEN}" "$((t_row_idx+1))" "$t_lbl" "${C_DIM}" "$short_dsc" "${C_RESET}")"
        else
          cell_right="$(printf "  [%2d] %-20.20s %b%s%b" "$((t_row_idx+1))" "$t_lbl" "${C_DIM}" "$short_dsc" "${C_RESET}")"
        fi
      fi

      frame+=$(printf " %-25b ${C_DIM}│${C_RESET} %b\033[K\n" "$cell_left" "$cell_right")
    done

    # Inspector Box Header
    local sel_label="none" sel_path="-" sel_desc="Pilih tools untuk melihat informasi."
    if [ "$num_tools" -gt 0 ] && [ "$tool_idx" -lt "$num_tools" ]; then
      sel_label="${cur_labels[tool_idx]}"
      sel_path="${cur_paths[tool_idx]}"
      sel_desc="${cur_descs[tool_idx]}"
    fi

    local ins_title="── [ Detail: ${sel_label} ] "
    local ins_dashes=$(( w_total - ${#ins_title} - 1 ))
    [ "$ins_dashes" -lt 1 ] && ins_dashes=1
    frame+=" ${C_DIM}┴${C_RESET}${C_CYAN}${ins_title:2}$(printf '─%.0s' $(seq 1 $ins_dashes))${C_RESET}\n"
    frame+=$(printf "  %bPath:%b %-42.42s  %bMode:%b %bPortable In-Place%b\033[K\n" \
      "${C_DIM}" "${C_RESET}" "${sel_path}" "${C_DIM}" "${C_RESET}" "${C_BOLD}${C_GREEN}" "${C_RESET}")
    frame+=$(printf "  %bDesc:%b %-70.70s\033[K\n" "${C_DIM}" "${C_RESET}" "${sel_desc}")
    frame+=" ${C_DIM}$(printf '─%.0s' $(seq 1 $inner_w))${C_RESET}\n"

    # Keybindings / Status Footer
    if [ "$search_mode" -eq 1 ]; then
      frame+=$(printf " %b🔍 CARI:%b %b%-30s%b  %b[Enter] Pilih  [Esc] Bersihkan%b\033[K\n" \
        "${C_BOLD}${C_YELLOW}" "${C_RESET}" "${C_BOLD}${C_WHITE}" "${search_query}█" "${C_RESET}" "${C_DIM}" "${C_RESET}")
    elif [ -n "${status_toast}" ]; then
      frame+=$(printf " %bℹ %s%b\033[K\n" "${C_BOLD}${C_YELLOW}" "${status_toast}" "${C_RESET}")
      status_toast=""
    else
      frame+=$(printf "  %b[↑/↓]%b Pindah  %b[Tab/←/→]%b Ganti Panel  %b[Enter]%b Jalankan  %b[v]%b Kode  %b[/]%b Cari  %b[b]%b Batch  %b[q]%b Keluar\033[K\n" \
        "${C_YELLOW}" "${C_RESET}" "${C_YELLOW}" "${C_RESET}" "${C_GREEN}" "${C_RESET}" "${C_CYAN}" "${C_RESET}" "${C_YELLOW}" "${C_RESET}" "${C_YELLOW}" "${C_RESET}" "${C_RED}" "${C_RESET}")
    fi

    # Output atomic frame
    printf "%b" "$frame" >&2

    # --- Read Single Key Input --------------------------------------------
    local k rest
    IFS= read -rsn1 k <&3 || break

    # Handle Escape Sequences
    if [ "$k" = $'\x1b' ]; then
      IFS= read -rsn2 -t 0.05 rest <&3 || rest=""
      k+="$rest"
      if [ "$k" = $'\x1b[' ]; then
        IFS= read -rsn1 -t 0.05 rest <&3 || rest=""
        k+="$rest"
      fi
    fi

    # --- Search Input Handling --------------------------------------------
    if [ "$search_mode" -eq 1 ]; then
      case "$k" in
        $'\x1b'|$'\x1b\x1b')
          search_mode=0
          search_query=""
          focus=0
          ;;
        $'\n'|$'\r')
          search_mode=0
          if [ "$num_tools" -gt 0 ]; then
            focus=1
          fi
          ;;
        $'\x7f'|$'\x08')
          if [ ${#search_query} -gt 0 ]; then
            search_query="${search_query:0:-1}"
            tool_idx=0
            tool_scroll=0
          else
            search_mode=0
            focus=0
          fi
          ;;
        $'\x1b[A'|k) # Up in search results
          [ "$tool_idx" -gt 0 ] && tool_idx=$((tool_idx - 1))
          ;;
        $'\x1b[B'|j) # Down in search results
          [ "$tool_idx" -lt "$((num_tools - 1))" ] && tool_idx=$((tool_idx + 1))
          ;;
        [[:print:]])
          search_query+="$k"
          tool_idx=0
          tool_scroll=0
          ;;
      esac
      continue
    fi

    # --- Normal Mode Key Handling -----------------------------------------
    case "$k" in
      $'\x1b[A'|k) # UP
        if [ "$focus" -eq 0 ]; then
          [ "$cat_idx" -gt 0 ] && cat_idx=$((cat_idx - 1))
          tool_idx=0; tool_scroll=0
        else
          [ "$tool_idx" -gt 0 ] && tool_idx=$((tool_idx - 1))
        fi
        ;;

      $'\x1b[B'|j) # DOWN
        if [ "$focus" -eq 0 ]; then
          [ "$cat_idx" -lt "$(( ${#CATEGORIES[@]} - 1 ))" ] && cat_idx=$((cat_idx + 1))
          tool_idx=0; tool_scroll=0
        else
          [ "$tool_idx" -lt "$(( num_tools - 1 ))" ] && tool_idx=$((tool_idx + 1))
        fi
        ;;

      $'\x1b[C'|l|$'\t') # RIGHT / TAB
        if [ "$focus" -eq 0 ]; then
          focus=1
        else
          focus=0
        fi
        ;;

      $'\x1b[D'|h) # LEFT
        focus=0
        ;;

      $'\n'|$'\r') # ENTER
        if [ "$focus" -eq 0 ]; then
          focus=1
        else
          if [ "$num_tools" -gt 0 ] && [ "$tool_idx" -lt "$num_tools" ]; then
            local target_lbl="${cur_labels[tool_idx]}"

            # Exit alternate screen buffer temporarily
            printf "\033[?1049l\033[?25h" >&2
            stty sane 2>/dev/null || true

            run_script "${target_lbl}" || true

            printf "\n%bTekan Enter untuk kembali ke WanForge TUI...%b" "${C_BOLD}${C_CYAN}" "${C_RESET}" >&2
            read -r _ <&3 2>/dev/null || true

            # Re-enter alternate buffer
            printf "\033[?1049h\033[?25l" >&2
            stty -echo -icanon min 1 time 0 2>/dev/null || true
          fi
        fi
        ;;

      v|V) # VIEW CODE
        if [ "$num_tools" -gt 0 ] && [ "$tool_idx" -lt "$num_tools" ]; then
          tui_view_code "${cur_paths[tool_idx]}"
        fi
        ;;

      /|s|S) # SEARCH
        search_mode=1
        search_query=""
        focus=1
        tool_idx=0
        tool_scroll=0
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

      [1-9]) # DIRECT CATEGORY JUMP
        local jumped=$(( k - 1 ))
        if [ "$jumped" -lt "${#CATEGORIES[@]}" ]; then
          cat_idx=$jumped
          tool_idx=0; tool_scroll=0; focus=0
        fi
        ;;

      0) # JUMP TO 10TH CATEGORY
        if [ "${#CATEGORIES[@]}" -ge 10 ]; then
          cat_idx=9
          tool_idx=0; tool_scroll=0; focus=0
        fi
        ;;

      q|Q) # QUIT
        break
        ;;
    esac
  done

  tui_cleanup
  printf "\n%bSampai jumpa! WanForge Ops Toolkit selesai. 👋%b\n\n" "${C_BOLD}${C_CYAN}" "${C_RESET}" >&2
}

# --- Category Submenu (Classic Fallback) ----------------------------------
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

  while true; do
    printf "\033[H\033[2J" >&2
    printf "%b── %s (%d tools) ──%b\n\n" "${C_BOLD}${C_CYAN}" "${target_cat}" "$n" "${C_RESET}" >&2

    for ((i = 0; i < n; i++)); do
      printf "  %b[%2d]%b  %-24s  %b%s%b\n" \
        "${C_YELLOW}" "$((i+1))" "${C_RESET}" \
        "${labels[i]}" \
        "${C_DIM}" "${descs[i]}" "${C_RESET}" >&2
    done
    printf "\n  %b[ 0]%b  ⬅ Kembali ke Menu Kategori (Back)\n" "${C_CYAN}" "${C_RESET}" >&2
    printf "  %b[ q]%b  Keluar dari Program (Quit)\n\n" "${C_RED}" "${C_RESET}" >&2

    printf "%b› Masukkan nomor script [1-%d], [0] kembali, [q] keluar: %b" "${C_YELLOW}" "$n" "${C_RESET}" >&2
    local choice=""
    read -r choice <&3 || break
    choice="$(echo "${choice}" | tr -d '[:space:]')"

    case "${choice}" in
      0|b|B|back|BACK) break ;;
      q|Q|exit|EXIT)
        printf "\n%bSampai jumpa! 👋%b\n\n" "${C_CYAN}" "${C_RESET}" >&2
        exit 0
        ;;
      "") ;;
      *)
        if [[ "${choice}" =~ ^[0-9]+$ ]] && [ "${choice}" -ge 1 ] && [ "${choice}" -le "$n" ]; then
          run_script "${labels[$((choice-1))]}" || true
          printf "\n%bTekan Enter untuk melanjutkan...%b" "${C_DIM}" "${C_RESET}" >&2
          read -r _ <&3 2>/dev/null || true
        else
          printf "\n%b⚠ Pilihan '%s' tidak valid. Masukkan nomor 1 sampai %d.%b\n" "${C_RED}" "${choice}" "$n" "${C_RESET}" >&2
          sleep 1.2
        fi
        ;;
    esac
  done
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
      s|S|/) search_interactive ;;
      b|B)   batch_select_mode ;;
      h|H)   tui_sys_info ;;
      q|Q|0|exit)
        printf "\n%bSampai jumpa! 👋%b\n\n" "${C_CYAN}" "${C_RESET}" >&2
        break
        ;;
      "") ;;
      *)
        if [[ "${choice}" =~ ^[0-9]+$ ]] && [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#CATEGORIES[@]}" ]; then
          show_category_menu "${CATEGORIES[$((choice-1))]}"
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
    # Numeric category index: `./install.sh 1` opens Category 1 in submenu
    if [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le "${#CATEGORIES[@]}" ] && [ -z "${2:-}" ]; then
      show_category_menu "${CATEGORIES[$(($1-1))]}"
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
      err "Pilihan '$1' tidak ditemukan. Gunakan './install.sh list' untuk melihat daftar script."
      exit 1
    fi
    ;;
esac
