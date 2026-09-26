#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install.sh — interactive launcher for wanforge server scripts.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/install.sh | bash
#   ./install.sh [1-10 | run <name|num> | list | search <term> | help]
#
# Shows a fast, categorized interactive dashboard with search, numeric input,
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

  "AI & Agents|install-ai-agents|script/linux/ai/install-ai-agents.sh|Full AI stack: Hermes, Claude Code, AGY, 9Router, Tmux"
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

# --- script resolver (supports numbers 1-35, exact names, partial names) ---
resolve_script() {
  local target="$1"

  # 1. Numeric global script index (1 to 35)
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

# --- execute a script by path/label --------------------------------------
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
    # 2. Remote download and caching
    local perm_file="${WF_INSTALL_DIR}/${lbl}.sh"
    local raw_url="https://scripts.wanforge.asia/${rel_path}"
    local tmp_dl; tmp_dl="$(mktemp)"

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

  if [ -t 0 ] || [ -c /dev/tty ]; then
    printf "%bTekan Enter untuk melanjutkan...%b" "${C_DIM}" "${C_RESET}" >&2
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

  while true; do
    printf "\033[H\033[2J" >&2
    printf "%b── %s (%d tools) ──%b\n\n" "${C_BOLD}${C_CYAN}" "${target_cat}" "$n" "${C_RESET}" >&2

    for ((i = 0; i < n; i++)); do
      printf "  %b[%2d]%b  %-24s  %b%s%b\n" \
        "${C_YELLOW}" "$((i+1))" "${C_RESET}" \
        "${labels[i]}" \
        "${C_DIM}" "${descs[i]}" "${C_RESET}" >&2
    done
    printf "\n  %b[ 0]%b  ⬅ Kembali ke Menu Kategori\n\n" "${C_CYAN}" "${C_RESET}" >&2

    printf "%b› Masukkan nomor script [1-%d] atau [0] kembali: %b" "${C_YELLOW}" "$n" "${C_RESET}" >&2
    local choice=""
    read -r choice <&3 || break
    choice="$(echo "${choice}" | tr -d '[:space:]')"

    case "${choice}" in
      0|b|B|q|Q) break ;;
      "") ;; # Empty Enter: redraw
      *)
        if [[ "${choice}" =~ ^[0-9]+$ ]] && [ "${choice}" -ge 1 ] && [ "${choice}" -le "$n" ]; then
          run_script "${labels[$((choice-1))]}" || true
        else
          printf "\n%b⚠ Pilihan '%s' tidak valid. Masukkan nomor 1 sampai %d.%b\n" "${C_RED}" "${choice}" "$n" "${C_RESET}" >&2
          sleep 1.2
        fi
        ;;
    esac
  done
}

# --- Search Mode ----------------------------------------------------------
search_interactive() {
  printf "\033[H\033[2J" >&2
  printf "%b── Pencarian Script ──%b\n\n" "${C_BOLD}${C_CYAN}" "${C_RESET}" >&2
  printf "Ketik kata kunci (contoh: 'docker', 'ssh', 'db', 'firewall', 'cloud'): " >&2
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
    printf "%bTekan Enter untuk kembali...%b" "${C_DIM}" "${C_RESET}" >&2
    read -r _ <&3 2>/dev/null || true
    return 0
  fi

  printf "\n%bDitemukan %d script cocok:%b\n\n" "${C_GREEN}" "$m" "${C_RESET}" >&2
  for ((i = 0; i < m; i++)); do
    printf "  %b[%2d]%b  %-24s  %b[%-20s]%b  %s\n" \
      "${C_YELLOW}" "$((i+1))" "${C_RESET}" \
      "${matched_labels[i]}" \
      "${C_CYAN}" "${matched_cats[i]}" "${C_RESET}" \
      "${matched_descs[i]}" >&2
  done
  printf "\n  %b[ 0]%b  Batal / Kembali\n\n" "${C_DIM}" "${C_RESET}" >&2

  printf "Pilih nomor script untuk dijalankan [1-%d]: " "$m" >&2
  local sel; read -r sel <&3 || sel=""
  sel="$(echo "${sel}" | tr -d '[:space:]')"

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
  printf "WANFORGE Server Management & Ops Toolkit\n\n"
  printf "Usage:\n"
  printf "  %s                      Jalankan menu interaktif\n" "$0"
  printf "  %s 1-10                 Buka kategori 1 sampai 10 langsung\n" "$0"
  printf "  %s 1-38                 Jalankan script nomor 1 sampai 38 langsung\n" "$0"
  printf "  %s <script_name>        Jalankan script berdasarkan nama (contoh: docker)\n" "$0"
  printf "  %s list                 Tampilkan seluruh tools (%d) dengan nomor indeks\n" "$0" "${#SCRIPTS[@]}"
  printf "  %s search <keyword>     Cari script berdasarkan nama/deskripsi\n" "$0"
  printf "  %s run <name|number>    Jalankan script spesifik\n" "$0"
  printf "  %s info                 Ringkasan status server (OS, RAM, CPU Load)\n" "$0"
  printf "  %s --help               Tampilkan panduan ini\n\n" "$0"
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
      q|Q|0|exit)
        printf "\n%bSampai jumpa! 👋%b\n\n" "${C_CYAN}" "${C_RESET}" >&2
        break
        ;;
      "") ;; # Empty Enter: redraw cleanly
      *)
        if [[ "${choice}" =~ ^[0-9]+$ ]]; then
          if [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#CATEGORIES[@]}" ]; then
            show_category_menu "${CATEGORIES[$((choice-1))]}"
          elif [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#SCRIPTS[@]}" ]; then
            local target_lbl
            target_lbl="$(resolve_script "${choice}")"
            run_script "${target_lbl}" || true
          else
            printf "\n%b⚠ Nomor '%s' tidak valid. Masukkan 1 sampai %d.%b\n" "${C_RED}" "${choice}" "${#CATEGORIES[@]}" "${C_RESET}" >&2
            sleep 1.2
          fi
        else
          local resolved
          resolved="$(resolve_script "${choice}" 2>/dev/null || echo "")"
          if [ -n "${resolved}" ]; then
            run_script "${resolved}" || true
          else
            printf "\n%b⚠ Pilihan '%s' tidak dikenali. Masukkan nomor kategori [1-%d] atau menu [s/b/h/q].%b\n" "${C_RED}" "${choice}" "${#CATEGORIES[@]}" "${C_RESET}" >&2
            sleep 1.2
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
  search|find)
    shift
    q="$*"
    if [ -z "$q" ]; then err "Masukkan kata kunci pencarian."; exit 1; fi
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
    interactive_main
    ;;
  *)
    # Numeric category index: `./install.sh 1` opens Category 1
    if [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le "${#CATEGORIES[@]}" ] && [ -z "${2:-}" ]; then
      show_category_menu "${CATEGORIES[$(($1-1))]}"
      exit 0
    elif [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le "${#CATEGORIES[@]}" ] && [ -n "${2:-}" ]; then
      # `./install.sh 1 2` -> runs category 1, script 2
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

    # Global resolution (number 1..35 or script name)
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
