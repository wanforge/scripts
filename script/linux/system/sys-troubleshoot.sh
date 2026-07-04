#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# sys-troubleshoot.sh — diagnostic and troubleshooting script for Linux servers.
# Audits system health, failed services, OOM events, web logs, and firewall bans.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/system/sys-troubleshoot.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="sys-troubleshoot"

# --- shared library ------------------------------------------------------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load
wf_log_init

check_system_health() {
  hd "System Health Check"
  
  # Load average
  local load; load="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "unknown")"
  info "CPU Load Average: ${load}"
  
  # CPU Usage
  if command -v top >/dev/null 2>&1; then
    local cpu_idle; cpu_idle="$(top -bn1 | grep -i '%Cpu' | awk -F, '{print $4}' | awk '{print $1}' || echo "")"
    if [ -n "${cpu_idle}" ]; then
      local cpu_used; cpu_used="$(echo "100 - ${cpu_idle}" | bc -l 2>/dev/null || echo "unknown")"
      info "CPU Utilization: ${cpu_used}%"
    fi
  fi

  # RAM
  if [ -f /proc/meminfo ]; then
    local total; total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local free; free=$(grep MemFree /proc/meminfo | awk '{print $2}')
    local avail; avail=$(grep -i MemAvailable /proc/meminfo | awk '{print $2}' || echo "0")
    if [ "${avail}" -eq 0 ]; then avail=$free; fi
    local used; used=$((total - avail))
    local pct; pct=$((used * 100 / total))
    info "RAM Usage: $((used / 1024)) MB / $((total / 1024)) MB (${pct}%)"
  else
    free -h || true
  fi

  # Disk usage
  info "Disk usage (critical partitions):"
  df -hT -x tmpfs -x devtmpfs 2>/dev/null | grep -E "/$|/boot|/data|/home" || df -h | head -5
}

check_failed_services() {
  hd "Failed Services Check"
  if command -v systemctl >/dev/null 2>&1; then
    local failed; failed=$(systemctl list-units --failed --state=failed -q --no-legend | wc -l || echo 0)
    if [ "${failed}" -gt 0 ]; then
      warn "Found ${failed} failed systemd unit(s):"
      systemctl list-units --failed --state=failed --no-pager
    else
      ok "All systemd units are running successfully."
    fi
  else
    info "systemd not detected; skipping service audit."
  fi
}

check_oom_killer() {
  hd "Out-Of-Memory (OOM) Audit"
  info "Checking kernel logs for OOM killer events..."
  local oom_dmesg=""
  if command -v dmesg >/dev/null 2>&1; then
    oom_dmesg=$(${SUDO} dmesg -T 2>/dev/null | grep -i -E "oom[-_]killer|out of memory" || true)
  fi
  local oom_journal=""
  if command -v journalctl >/dev/null 2>&1; then
    oom_journal=$(${SUDO} journalctl -k -b --no-pager -g "OOM" 2>/dev/null || true)
  fi

  if [ -n "${oom_dmesg}" ] || [ -n "${oom_journal}" ]; then
    warn "OOM Killer events detected! Your applications are exceeding system memory limits."
    if [ -n "${oom_dmesg}" ]; then
      info "Recent OOM events from dmesg (last 5):"
      echo "${oom_dmesg}" | tail -5
    fi
    if [ -n "${oom_journal}" ]; then
      info "Recent OOM events from journalctl (last 5):"
      echo "${oom_journal}" | tail -5
    fi
  else
    ok "No Out-Of-Memory (OOM) events found in current boot logs."
  fi
}

check_nginx_logs() {
  hd "Nginx Gateway & Error Diagnostics"
  local log_paths=("/var/log/nginx/error.log")
  
  if [ -d /var/log/nginx ]; then
    while IFS= read -r f; do
      [ -f "$f" ] && log_paths+=("$f")
    done < <(find /var/log/nginx -name "*error.log" 2>/dev/null)
  fi

  # remove duplicates
  local unique_logs=()
  for l in "${log_paths[@]}"; do
    local dup=0
    for u in "${unique_logs[@]:-}"; do
      [ "${u}" = "${l}" ] && dup=1
    done
    [ "${dup}" -eq 0 ] && unique_logs+=("${l}")
  done

  local checked=0
  for log in "${unique_logs[@]}"; do
    if [ -r "${log}" ]; then
      checked=1
      local cnt; cnt=$(${SUDO} grep -c -E "502|504|connection refused|timeout|directory index of.*is forbidden" "${log}" 2>/dev/null || echo 0)
      if [ "${cnt}" -gt 0 ]; then
        warn "Found ${cnt} issues in Nginx error log: ${log}"
        info "Recent log entries (last 5):"
        ${SUDO} grep -E "502|504|connection refused|timeout|directory index of.*is forbidden" "${log}" | tail -5
      else
        ok "No common Nginx errors found in ${log}."
      fi
    fi
  done
  [ "${checked}" -eq 0 ] && info "Nginx log directory not found or unreadable."
}

check_database() {
  hd "Database Port Reachability"
  local ports=(3306 5432)
  local names=("MySQL/MariaDB" "PostgreSQL")
  local i=0
  for port in "${ports[@]}"; do
    local name="${names[$i]}"
    if command -v ss >/dev/null 2>&1; then
      if ss -tuln | grep -q ":${port} " 2>/dev/null; then
        ok "${name} is listening on port ${port}."
      else
        info "${name} port ${port} is NOT active/listening."
      fi
    elif command -v netstat >/dev/null 2>&1; then
      if netstat -tuln | grep -q ":${port} " 2>/dev/null; then
        ok "${name} is listening on port ${port}."
      else
        info "${name} port ${port} is NOT active/listening."
      fi
    else
      info "ss/netstat not available; skipping socket check."
    fi
    i=$((i + 1))
  done
}

check_fail2ban() {
  hd "Fail2ban Ban Audit"
  if command -v fail2ban-client >/dev/null 2>&1; then
    local status; status=$(${SUDO} fail2ban-client ping 2>/dev/null || echo "")
    if [ "${status}" = "Server replied: pong" ]; then
      local jails; jails=$(${SUDO} fail2ban-client status | grep "Jail list:" | sed "s/.*Jail list://; s/,//g")
      info "Jail list: ${jails}"
      for jail in ${jails}; do
        local banned; banned=$(${SUDO} fail2ban-client status "${jail}" | grep "Banned IP list:" | sed "s/.*Banned IP list://")
        if [ -n "${banned// /}" ]; then
          warn "Jail '${jail}' has banned IPs: ${banned}"
        else
          ok "Jail '${jail}' has no banned IPs."
        fi
      done
      
      # Option to unban
      local ip; ip="$(ask "Enter an IP to UNBAN (leave empty to skip):" "")"
      if [ -n "${ip}" ]; then
        for jail in ${jails}; do
          if ${SUDO} fail2ban-client set "${jail}" unbanip "${ip}" >/dev/null 2>&1; then
            ok "Successfully unbanned ${ip} from jail '${jail}'."
          fi
        done
      fi
    else
      warn "Fail2ban is installed but server is not running."
    fi
  else
    info "Fail2ban is not installed."
  fi
}

check_network() {
  hd "Network & DNS Diagnostics"
  
  # DNS check
  if host google.com >/dev/null 2>&1 || nslookup google.com >/dev/null 2>&1 || ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    ok "DNS resolution and public internet connection is working."
  else
    err "Internet connection or DNS resolution is offline!"
  fi

  # Ping latency
  if command -v ping >/dev/null 2>&1; then
    info "Testing latency to 1.1.1.1..."
    ping -c 3 -q 1.1.1.1 || warn "Ping to 1.1.1.1 failed."
  fi
}

run_all() {
  check_system_health
  check_failed_services
  check_oom_killer
  check_nginx_logs
  check_database
  check_fail2ban
  check_network
  printf "\n%b✔ All diagnostics finished.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
}

# --- run -----------------------------------------------------------------
banner
while true; do
  MENU=(
    "Diagnostics|all|Run all diagnostics & health audits"
    "Health|health|Check CPU, memory, and disk usage"
    "Health|failed|Check failed systemd units"
    "Logs|oom|Check kernel logs for OOM killer events"
    "Logs|nginx|Inspect Nginx error logs for 502/504 gateways"
    "Database|db|Verify MySQL and PostgreSQL listening ports"
    "Firewall|fail2ban|Check Fail2ban jails and unban IPs"
    "Network|net|Test DNS and public ping latency"
  )
  printf "\n" >&2
  menu_select "Diagnostics & Troubleshooting Toolkit:" || break
  case "${MENU_KEY}" in
    all) run_all; pause ;;
    health) check_system_health; pause ;;
    failed) check_failed_services; pause ;;
    oom) check_oom_killer; pause ;;
    nginx) check_nginx_logs; pause ;;
    db) check_database; pause ;;
    fail2ban) check_fail2ban; pause ;;
    net) check_network; pause ;;
  esac
done

printf "\n%b✔ sys-troubleshoot finished.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
