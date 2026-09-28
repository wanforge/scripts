#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-fail2ban.sh — Install, optimize, and manage Fail2Ban with aggressive security presets.
#
# Features:
#   - Automatic package installation across Debian, Ubuntu, RHEL/Fedora, Arch, SUSE, Alpine
#   - High-performance systemd journal backend detection (immune to log rotation)
#   - Dynamic SSH port discovery (protects standard 22 and any custom SSH ports)
#   - Exponential progressive banning (bantime.increment = true, scales up to 4 weeks for recidivists)
#   - Sane hardened defaults: 1h default ban, 15m window, max 4 retries
#   - Active SSH session IP and private RFC 1918 subnet auto-whitelisting (avoids accidental lockouts)
#   - Firewall-aware banaction detection: UFW, Firewalld rich-rules, nftables, or iptables
#   - Production jails enabled: [sshd], [recidive], and optional Nginx / CloudPanel jails
#   - Interactive management: Live jail audit, unban IP wizard, manual ban, and ban logs viewer
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/security/install-fail2ban.sh | bash
#   ./install-fail2ban.sh status
#   ./install-fail2ban.sh optimize
#   ./install-fail2ban.sh unban <ip>
#   ./install-fail2ban.sh ban <ip> [jail]
#   ./install-fail2ban.sh logs
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-fail2ban"

# --- shared library: banner, colors, logging, prompts, checkbox ----------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if   [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
elif [ -r "${__d}/lib.sh" ]; then . "${__d}/lib.sh"
elif [ -n "${WF_INSTALL_DIR:-}" ] && [ -r "${WF_INSTALL_DIR}/lib.sh" ]; then . "${WF_INSTALL_DIR}/lib.sh"
elif [ -r "/opt/wanforge-scripts/lib.sh" ]; then . "/opt/wanforge-scripts/lib.sh"
elif [ -r "${HOME:-}/.local/lib/wanforge-scripts/lib.sh" ]; then . "${HOME}/.local/lib/wanforge-scripts/lib.sh"
elif command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}")
else . <(wget -qO- "${__LIB}"); fi
cfg_load
wf_log_init

SUDO=""
[ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

F2B_DIR="/etc/fail2ban"
JAIL_LOCAL="${F2B_DIR}/jail.local"
F2B_LOCAL="${F2B_DIR}/fail2ban.local"

# --- Environment & System Detectors ---------------------------------------
detect_pm() {
  for pm in apt-get dnf yum pacman zypper apk; do
    command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return 0; };
  done
  return 1
}

detect_firewall_action() {
  if command -v ufw >/dev/null 2>&1 && ${SUDO} ufw status 2>/dev/null | grep -qi "Status: active"; then
    echo "ufw"
  elif command -v firewall-cmd >/dev/null 2>&1 && ${SUDO} firewall-cmd --state >/dev/null 2>&1; then
    echo "firewallcmd-richrules"
  elif command -v nft >/dev/null 2>&1 && systemctl is-active --quiet nftables 2>/dev/null; then
    echo "nftables-multiport"
  elif command -v iptables >/dev/null 2>&1; then
    echo "iptables-multiport"
  else
    echo "iptables-multiport"
  fi
}

detect_backend() {
  if command -v systemctl >/dev/null 2>&1 && command -v journalctl >/dev/null 2>&1; then
    echo "systemd"
  else
    echo "auto"
  fi
}

detect_ssh_ports() {
  local ports="ssh,22"
  local custom_ports=()

  # Check active listening SSH sockets
  if command -v ss >/dev/null 2>&1; then
    while read -r p; do
      [ -n "${p}" ] && custom_ports+=("${p}")
    done < <(ss -tlnp 2>/dev/null | grep -E 'sshd|/ssh\b' | grep -oE ':[0-9]+' | tr -d ':' | sort -u || true)
  fi

  # Check sshd_config files
  for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [ -f "$f" ] || continue
    while read -r p; do
      [ -n "${p}" ] && custom_ports+=("${p}")
    done < <(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' "$f" 2>/dev/null | awk '{print $2}' || true)
  done

  for cp in "${custom_ports[@]:-}"; do
    if [ "${cp}" != "22" ] && [[ ! ",${ports}," =~ ,${cp}, ]]; then
      ports+=",${cp}"
    fi
  done
  echo "${ports}"
}

detect_client_ip() {
  local client_ip=""
  if [ -n "${SSH_CLIENT:-}" ]; then
    client_ip="$(echo "${SSH_CLIENT}" | awk '{print $1}')"
  elif [ -n "${SSH_CONNECTION:-}" ]; then
    client_ip="$(echo "${SSH_CONNECTION}" | awk '{print $1}')"
  fi
  echo "${client_ip}"
}

# --- Action 1: Audit Status & Active Jails --------------------------------
a_status() {
  hd "Fail2Ban Service Status & Active Jail Audit"

  if ! command -v fail2ban-client >/dev/null 2>&1; then
    warn "Fail2Ban binary 'fail2ban-client' is not installed."
    info "Run the installer to set up Fail2Ban."
    return 1
  fi

  local is_active=0
  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    is_active=1
    ok "Service status: Active & Running (systemd)"
  else
    warn "Service status: Inactive or Stopped"
  fi

  local ping_out
  ping_out="$(${SUDO} fail2ban-client ping 2>/dev/null || echo "")"
  if [ "${ping_out}" = "Server replied: pong" ]; then
    ok "Server socket: Responding (${ping_out})"
  else
    warn "Server socket: Not responding (daemon might be stopped or starting)"
    return 0
  fi

  local status_out
  status_out="$(${SUDO} fail2ban-client status 2>/dev/null || echo "")"
  local jail_list
  jail_list="$(echo "${status_out}" | grep -i "Jail list:" | sed -E 's/.*Jail list:[[:space:]]*//' | tr -d '\r')"

  if [ -z "${jail_list}" ]; then
    warn "No active jails found. The daemon is running without monitored jails."
    info "Run 'Optimize Fail2Ban Configuration' to activate standard jails."
    return 0
  fi

  printf "\n%bActive Jails & Banned Counters:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  IFS=',' read -r -a jails <<< "${jail_list}"
  local total_banned_sum=0
  local current_banned_sum=0

  for j in "${jails[@]}"; do
    local jail_clean; jail_clean="$(echo "${j}" | tr -d ' ')"
    [ -z "${jail_clean}" ] && continue

    local j_status
    j_status="$(${SUDO} fail2ban-client status "${jail_clean}" 2>/dev/null || echo "")"
    local cur_ban; cur_ban="$(echo "${j_status}" | grep -i "Currently banned:" | awk '{print $NF}' | tr -d '\r' || echo "0")"
    local tot_ban; tot_ban="$(echo "${j_status}" | grep -i "Total banned:" | awk '{print $NF}' | tr -d '\r' || echo "0")"
    local banned_ips; banned_ips="$(echo "${j_status}" | grep -i "Banned IP list:" | sed -E 's/.*Banned IP list:[[:space:]]*//' | tr -d '\r')"

    cur_ban="${cur_ban:-0}"
    tot_ban="${tot_ban:-0}"
    current_banned_sum=$(( current_banned_sum + cur_ban ))
    total_banned_sum=$(( total_banned_sum + tot_ban ))

    printf "  • %b%-18s%b : %b%d%b currently banned (Total: %d)\n" \
      "${C_BOLD}${C_WHITE}" "[${jail_clean}]" "${C_RESET}" \
      "$([ "${cur_ban}" -gt 0 ] && echo "${C_BOLD}${C_RED}" || echo "${C_GREEN}")" \
      "${cur_ban}" "${C_RESET}" "${tot_ban}"

    if [ -n "${banned_ips}" ] && [ "${cur_ban}" -gt 0 ]; then
      printf "    %bBanned IPs%b: %b%s%b\n" "${C_DIM}" "${C_RESET}" "${C_YELLOW}" "${banned_ips}" "${C_RESET}"
    fi
  done

  printf "\n  %bSummary:%b %d currently banned across %d active jails (Lifetime total: %d)\n" \
    "${C_BOLD}${C_CYAN}" "${C_RESET}" "${current_banned_sum}" "${#jails[@]}" "${total_banned_sum}"

  if [ -f "${JAIL_LOCAL}" ]; then
    local inc_active; inc_active="$(grep -E '^[[:space:]]*bantime\.increment[[:space:]]*=[[:space:]]*true' "${JAIL_LOCAL}" || true)"
    if [ -n "${inc_active}" ]; then
      ok "Progressive exponential bantime: Enabled (recidive protection active)"
    else
      info "Progressive exponential bantime: Not enabled"
    fi
  fi
  printf "\n"
}

# --- Action 2: Install Fail2Ban Package ------------------------------------
a_install() {
  hd "Install Fail2Ban Service"

  local pm; pm="$(detect_pm)" || { err "No supported package manager found (apt, dnf, yum, pacman, zypper, apk)."; return 1; }
  sub "Installing Fail2Ban package via ${pm}..."

  case "${pm}" in
    apt-get)
      run ${SUDO} apt-get update
      run ${SUDO} apt-get install -y fail2ban
      ;;
    dnf|yum)
      if [ "${pm}" = "dnf" ] && dnf list --available fail2ban-systemd >/dev/null 2>&1; then
        run ${SUDO} dnf install -y fail2ban fail2ban-systemd
      else
        run ${SUDO} "${pm}" install -y fail2ban || true
      fi
      ;;
    pacman)
      run ${SUDO} pacman -S --noconfirm --needed fail2ban
      ;;
    zypper)
      run ${SUDO} zypper --non-interactive install fail2ban
      ;;
    apk)
      run ${SUDO} apk add fail2ban
      ;;
  esac

  if ! command -v fail2ban-client >/dev/null 2>&1; then
    err "Installation finished but 'fail2ban-client' binary was not found in PATH."
    return 1
  fi

  ok "Fail2Ban package installed successfully: $(${SUDO} fail2ban-client --version 2>/dev/null || echo 'Installed')"
  if command -v systemctl >/dev/null 2>&1; then
    run ${SUDO} systemctl enable fail2ban >/dev/null 2>&1 || true
    run ${SUDO} systemctl start fail2ban || true
  fi
  ok "Fail2Ban service enabled."
}

# --- Action 3: Optimize Configuration (Sane & Hardened Jails) -------------
a_optimize() {
  hd "Optimize Fail2Ban Configuration & Jails"

  if ! command -v fail2ban-client >/dev/null 2>&1; then
    info "Fail2Ban is not installed. Installing it first..."
    a_install || return 1
  fi

  local ssh_ports; ssh_ports="$(detect_ssh_ports)"
  local client_ip; client_ip="$(detect_client_ip)"
  local banaction; banaction="$(detect_firewall_action)"
  local backend; backend="$(detect_backend)"

  info "Detected environment parameters:"
  info "  • Monitored SSH Ports  : ${ssh_ports}"
  info "  • Firewall Banaction   : ${banaction}"
  info "  • Log Journal Backend  : ${backend}"
  if [ -n "${client_ip}" ]; then
    info "  • Active Admin SSH IP  : ${client_ip} (will be whitelisted)"
  fi

  printf "\n"
  local extra_whitelist; extra_whitelist="$(ask "Enter additional IPs or CIDRs to whitelist (space-separated, or leave blank):" "")"

  local ignore_list="127.0.0.1/8 ::1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
  [ -n "${client_ip}" ] && ignore_list="${ignore_list} ${client_ip}"
  [ -n "${extra_whitelist}" ] && ignore_list="${ignore_list} ${extra_whitelist}"

  # Prompt for bantime preset or accept defaults
  printf "\n%bSelect Protection Preset:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  printf "  [1] Aggressive VPS Standard (1h ban, 4 retries, exponential recidive up to 4w) [Default]\n"
  printf "  [2] High-Security Lockdown   (24h ban, 3 retries, exponential recidive up to 8w)\n"
  printf "  [3] Moderate / Developer     (30m ban, 5 retries, 1w recidive)\n"
  local preset; preset="$(ask "Choose preset" "1")"

  local bantime="1h"
  local findtime="15m"
  local maxretry="4"
  local recidive_bantime="2w"
  local recidive_findtime="1d"
  local recidive_maxretry="3"
  local bantime_maxtime="4w"

  case "${preset}" in
    2)
      bantime="24h"
      findtime="30m"
      maxretry="3"
      recidive_bantime="4w"
      recidive_maxtime="8w"
      recidive_maxretry="2"
      ;;
    3)
      bantime="30m"
      findtime="10m"
      maxretry="5"
      recidive_bantime="1w"
      recidive_maxtime="2w"
      recidive_maxretry="4"
      ;;
    *)
      bantime="1h"
      findtime="15m"
      maxretry="4"
      recidive_bantime="2w"
      recidive_maxtime="4w"
      recidive_maxretry="3"
      ;;
  esac

  # Backup existing jail.local if present
  if [ -f "${JAIL_LOCAL}" ]; then
    local ts; ts="$(date +%Y%m%d_%H%M%S)"
    sub "Backing up existing ${JAIL_LOCAL} to ${JAIL_LOCAL}.bak.${ts}..."
    run ${SUDO} cp -f "${JAIL_LOCAL}" "${JAIL_LOCAL}.bak.${ts}"
  fi

  sub "Configuring ${F2B_LOCAL}..."
  run ${SUDO} mkdir -p "${F2B_DIR}"
  local tmp_f2b_local; tmp_f2b_local="$(mktemp)"
  cat > "${tmp_f2b_local}" <<EOF
# Fail2Ban Local Logging Configuration
# Generated by WanForge Server Ops Toolkit

[DEFAULT]
loglevel = INFO
logtarget = /var/log/fail2ban.log
dbpurgeage = 1d
EOF
  run ${SUDO} cp -f "${tmp_f2b_local}" "${F2B_LOCAL}"
  run ${SUDO} chmod 644 "${F2B_LOCAL}"
  rm -f "${tmp_f2b_local}"

  sub "Generating optimized ${JAIL_LOCAL}..."
  local tmp_jail; tmp_jail="$(mktemp)"
  cat > "${tmp_jail}" <<EOF
# ==============================================================================
# Fail2Ban Local Jail Configuration
# Generated by WanForge Server Ops Toolkit
# ==============================================================================

[DEFAULT]
# Whitelist local loopback, RFC1918 private subnets, and current admin IP
ignoreip = ${ignore_list}

# Default timing & failure thresholds
bantime  = ${bantime}
findtime = ${findtime}
maxretry = ${maxretry}

# Progressive exponential bantime for repeat offenders
bantime.increment = true
bantime.factor = 2
bantime.formula = ban.Time * (1<<(ban.Count if ban.Count<20 else 20)) * (banner_opt_factor if banner_opt_factor else 1)
bantime.maxtime = ${bantime_maxtime}
bantime.rndtime = 8m

# Firewall and backend integration
banaction = ${banaction}
banaction_allports = ${banaction}
backend = ${backend}

# ==============================================================================
# JAILS
# ==============================================================================

# SSH brute-force defense
[sshd]
enabled = true
port    = ${ssh_ports}
backend = ${backend}
maxretry = ${maxretry}
bantime = 24h
findtime = 30m

# Repeat offender trap (bans persistent attackers across all services)
[recidive]
enabled = true
logpath = /var/log/fail2ban.log
backend = auto
bantime  = ${recidive_bantime}
findtime = ${recidive_findtime}
maxretry = ${recidive_maxretry}
EOF

  # Optional Nginx jails if web server is installed
  if command -v nginx >/dev/null 2>&1 || [ -d /etc/nginx ] || [ -d /home/cloudpanel ]; then
    info "Web server / CloudPanel detected. Adding Nginx defense jails..."
    cat >> "${tmp_jail}" <<'EOF'

[nginx-http-auth]
enabled = true
port    = http,https
logpath = /var/log/nginx/*error.log

[nginx-botsearch]
enabled = true
port     = http,https
logpath  = /var/log/nginx/*access.log
maxretry = 3
findtime = 10m
bantime  = 24h

[nginx-bad-request]
enabled = true
port    = http,https
logpath = /var/log/nginx/*access.log
maxretry = 5
findtime = 10m
bantime  = 12h
EOF
  fi

  run ${SUDO} cp -f "${tmp_jail}" "${JAIL_LOCAL}"
  run ${SUDO} chmod 644 "${JAIL_LOCAL}"
  rm -f "${tmp_jail}"

  sub "Restarting Fail2Ban daemon to apply changes..."
  if run ${SUDO} systemctl restart fail2ban; then
    ok "Fail2Ban restarted successfully."
  else
    warn "systemctl restart failed. Attempting reload..."
    run ${SUDO} fail2ban-client reload || true
  fi

  # Verify socket ping
  sleep 1
  if ${SUDO} fail2ban-client ping >/dev/null 2>&1; then
    ok "Fail2Ban daemon active and responding: ping -> pong."
  else
    warn "Fail2Ban daemon did not reply immediately. Check 'journalctl -u fail2ban' for syntax errors."
  fi

  printf "\n%b=================================================================%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
  printf "%b✔ FAIL2BAN OPTIMIZATION APPLIED SUCCESSFULLY%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
  printf "  • Default Bantime      : %b%s%b (Exponential increment enabled, max: %s)\n" "${C_BOLD}${C_YELLOW}" "${bantime}" "${C_RESET}" "${bantime_maxtime}"
  printf "  • Detection Window     : %b%s%b (Max failures: %s)\n" "${C_YELLOW}" "${findtime}" "${C_RESET}" "${maxretry}"
  printf "  • Active Jails         : %b%s%b\n" "${C_BOLD}${C_CYAN}" "$(${SUDO} fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*Jail list:[[:space:]]*//' || echo 'sshd, recidive')" "${C_RESET}"
  printf "  • Whitelisted CIDRs    : %b%s%b\n" "${C_DIM}" "${ignore_list}" "${C_RESET}"
  printf "  • Monitored SSH Ports  : %b%s%b\n" "${C_YELLOW}" "${ssh_ports}" "${C_RESET}"
  printf "%b=================================================================%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
}

# --- Action 4: Unban IP Wizard --------------------------------------------
a_unban() {
  hd "Unban IP Address"

  if ! command -v fail2ban-client >/dev/null 2>&1; then
    err "fail2ban-client not found."; return 1
  fi

  local target_ip="${1:-}"
  if [ -z "${target_ip}" ]; then
    target_ip="$(ask "Enter the IP address to unban:" "")"
  fi

  if [ -z "${target_ip}" ]; then
    info "No IP provided. Cancelled."; return 0
  fi

  sub "Attempting to unban IP ${target_ip} across all jails..."
  local unban_res
  unban_res="$(${SUDO} fail2ban-client unban "${target_ip}" 2>/dev/null || true)"

  if [ -n "${unban_res}" ] && [ "${unban_res}" != "0" ]; then
    ok "IP ${target_ip} unbanned successfully (${unban_res} jail(s) unbanned)."
  else
    # Fallback: iterate over all individual jails
    local jails_raw
    jails_raw="$(${SUDO} fail2ban-client status 2>/dev/null | grep -i "Jail list:" | sed -E 's/.*Jail list:[[:space:]]*//' | tr -d '\r' || true)"
    local count=0
    IFS=',' read -r -a j_arr <<< "${jails_raw}"
    for j in "${j_arr[@]}"; do
      local j_clean; j_clean="$(echo "${j}" | tr -d ' ')"
      [ -z "${j_clean}" ] && continue
      if ${SUDO} fail2ban-client set "${j_clean}" unbanip "${target_ip}" >/dev/null 2>&1; then
        count=$(( count + 1 ))
      fi
    done
    if [ "${count}" -gt 0 ]; then
      ok "IP ${target_ip} unbanned from ${count} jail(s)."
    else
      warn "IP ${target_ip} was not found in any active ban lists."
    fi
  fi
}

# --- Action 5: Manual Ban IP ----------------------------------------------
a_ban() {
  hd "Manually Ban IP Address"

  if ! command -v fail2ban-client >/dev/null 2>&1; then
    err "fail2ban-client not found."; return 1
  fi

  local target_ip="${1:-}"
  local target_jail="${2:-sshd}"

  if [ -z "${target_ip}" ]; then
    target_ip="$(ask "Enter the IP address to ban:" "")"
  fi
  [ -z "${target_ip}" ] && { info "No IP entered. Cancelled."; return 0; }

  if [ -z "${2:-}" ]; then
    target_jail="$(ask "Enter target jail (sshd, recidive, etc.):" "sshd")"
  fi

  sub "Banning IP ${target_ip} in jail [${target_jail}]..."
  if ${SUDO} fail2ban-client set "${target_jail}" banip "${target_ip}" >/dev/null 2>&1; then
    ok "IP ${target_ip} banned in [${target_jail}]."
  else
    err "Failed to ban IP ${target_ip}. Ensure jail [${target_jail}] is active."
  fi
}

# --- Action 6: View Ban Logs ----------------------------------------------
a_logs() {
  hd "Fail2Ban Ban / Unban Activity Logs"

  local log_file="/var/log/fail2ban.log"
  if [ -f "${log_file}" ]; then
    printf "%bLast 35 Ban / Unban events from %s:%b\n\n" "${C_BOLD}${C_CYAN}" "${log_file}" "${C_RESET}"
    grep -E '\[.*\] (Ban|Unban|Restore Ban)' "${log_file}" 2>/dev/null | tail -n 35 || info "No recent Ban/Unban events in ${log_file}."
  elif command -v journalctl >/dev/null 2>&1; then
    printf "%bLast 35 Ban / Unban events from systemd journal:%b\n\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
    journalctl -u fail2ban --no-pager -n 100 2>/dev/null | grep -E '(Ban|Unban)' | tail -n 35 || info "No recent Ban/Unban events found."
  else
    warn "Log file ${log_file} not found and journalctl unavailable."
  fi
  printf "\n"
}

# --- Action 7: Uninstall Fail2Ban -----------------------------------------
a_uninstall() {
  hd "Uninstall Fail2Ban"
  warn "This will stop and remove Fail2Ban and its active firewall rules from this system."
  local yn; yn="$(ask "Are you sure you want to remove Fail2Ban? [y/N]:" "n")"
  case "${yn}" in y|Y|yes) ;; *) info "Cancelled."; return 0 ;; esac

  local pm; pm="$(detect_pm)" || { err "No supported package manager."; return 1; }
  sub "Stopping Fail2Ban service..."
  run ${SUDO} systemctl stop fail2ban 2>/dev/null || true
  run ${SUDO} systemctl disable fail2ban 2>/dev/null || true

  sub "Removing Fail2Ban package via ${pm}..."
  case "${pm}" in
    apt-get)
      run ${SUDO} apt-get purge -y fail2ban
      run ${SUDO} apt-get autoremove -y
      ;;
    dnf|yum)
      run ${SUDO} "${pm}" -y remove fail2ban fail2ban-systemd fail2ban-firewalld || run ${SUDO} "${pm}" -y remove fail2ban
      ;;
    pacman)
      run ${SUDO} pacman -Rns --noconfirm fail2ban
      ;;
    zypper)
      run ${SUDO} zypper --non-interactive remove fail2ban
      ;;
    apk)
      run ${SUDO} apk del fail2ban
      ;;
  esac

  if ask_yn "Delete Fail2Ban configuration files (/etc/fail2ban)?" "n"; then
    run ${SUDO} rm -rf /etc/fail2ban /var/lib/fail2ban
  fi
  ok "Fail2Ban uninstalled successfully."
}

# --- CLI Dispatch ---------------------------------------------------------
case "${1:-}" in
  status|audit)
    a_status; exit $?
    ;;
  optimize|harden|configure)
    a_optimize; exit $?
    ;;
  install)
    a_install; a_optimize; exit $?
    ;;
  unban)
    a_unban "${2:-}"; exit $?
    ;;
  ban)
    a_ban "${2:-}" "${3:-sshd}"; exit $?
    ;;
  logs|log)
    a_logs; exit $?
    ;;
  --uninstall|uninstall)
    a_uninstall; exit $?
    ;;
esac

# --- Interactive Main Menu ------------------------------------------------
banner
MENU=(
  "Status|status|Audit Fail2Ban Status & View Active Jails"
  "Optimize|optimize|Apply Production Hardening & Sane Jails (1h Ban, Exponential Recidive)"
  "Install|install|Install & Enable Fail2Ban Service"
  "Manage|unban|Unban an IP Address"
  "Manage|ban|Manually Ban an IP Address"
  "Logs|logs|View Recent Ban & Unban Activity Logs"
  "Remove|uninstall|Uninstall Fail2Ban & Clean Configurations"
)

while true; do
  if menu_select "Fail2Ban Management & Security Hardening:"; then
    case "${MENU_KEY}" in
      status)    a_status; pause ;;
      optimize)  a_optimize; pause ;;
      install)   a_install; a_optimize; pause ;;
      unban)     a_unban; pause ;;
      ban)       a_ban; pause ;;
      logs)      a_logs; pause ;;
      uninstall) a_uninstall; pause ;;
      *) break ;;
    esac
  else
    break
  fi
done

ok "Script install-fail2ban completed."
