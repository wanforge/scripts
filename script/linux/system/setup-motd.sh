#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2155
#
# setup-motd.sh — Install clean, dynamic SSH login banner (MOTD) with system KPIs
# Replaces Ubuntu Pro / ESM spam and stock text with a high-performance WanForge banner.

set -euo pipefail
TASK="setup-motd"

# --- shared library ------------------------------------------------------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if   [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
elif [ -r "${__d}/lib.sh" ]; then . "${__d}/lib.sh"
elif [ -n "${WF_INSTALL_DIR:-}" ] && [ -r "${WF_INSTALL_DIR}/lib.sh" ]; then . "${WF_INSTALL_DIR}/lib.sh"
elif [ -r "/opt/wanforge-scripts/lib.sh" ]; then . "/opt/wanforge-scripts/lib.sh"
elif [ -r "${HOME:-}/.local/lib/wanforge-scripts/lib.sh" ]; then . "${HOME}/.local/lib/wanforge-scripts/lib.sh"
elif command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}")
else . <(wget -qO- "${__LIB}"); fi

# Defensive fallback in case an older cached lib.sh was sourced
command -v sub >/dev/null 2>&1 || sub() { [ "${LOG_LEVEL:-1}" -ge 1 ] || return 0; [ -n "${C_DIM:-}" ] && printf "    %b↳%b %s\n" "${C_DIM}" "${C_RESET}" "$1" || printf "    ↳ %s\n" "$1"; }

TOOL_NAME="setup-motd"
MOTD_UBUNTU_PATH="/etc/update-motd.d/01-wanforge-motd"
MOTD_PROFILE_PATH="/etc/profile.d/wanforge-motd.sh"

# --- Function to generate MOTD payload script ------------------------------
render_motd_content() {
  cat << 'EOF'
#!/usr/bin/env bash
# WanForge Dynamic SSH Login Banner (MOTD)
# Fast, lightweight, zero external bloat.

# Colors
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_CYAN="\033[36m"
C_BLUE="\033[34m"
C_GREEN="\033[32m"
C_YELLOW="\033[33m"
C_RED="\033[31m"
C_WHITE="\033[97m"

# Only exit if truly non-interactive subshell without tty
if [ -z "${TERM:-}" ] && [ ! -t 1 ] && [ "${WANFORGE_MOTD_FORCE:-0}" -ne 1 ]; then
  exit 0
fi

# System Information
HOSTNAME="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo 'localhost')"
KERNEL="$(uname -r 2>/dev/null || echo 'Unknown')"
UPTIME_SEC="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)"
DAYS=$(( UPTIME_SEC / 86400 ))
HOURS=$(( (UPTIME_SEC % 86400) / 3600 ))
MINS=$(( (UPTIME_SEC % 3600) / 60 ))
if [ "${DAYS}" -gt 0 ]; then
  UPTIME_STR="${DAYS}d ${HOURS}h ${MINS}m"
else
  UPTIME_STR="${HOURS}h ${MINS}m"
fi

# OS Name
OS_NAME="Linux"
if [ -f /etc/os-release ]; then
  # shellcheck source=/dev/null
  OS_NAME="$(. /etc/os-release && echo "${PRETTY_NAME:-$NAME}")"
fi
OS_NAME="${OS_NAME%% (*}"

# CPU Load & Cores
CPU_CORES="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"
CPU_MODEL="$(awk -F: '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null | sed -e 's/^[ \t]*//' -e 's/(R)//g' -e 's/(TM)//g' -e 's/ CPU.*//' -e 's/ with Radeon Graphics.*//' -e 's/ @.*//')"
[ -z "${CPU_MODEL}" ] && CPU_MODEL="$(awk -F: '/Model/ {print $2; exit}' /proc/cpuinfo 2>/dev/null | sed -e 's/^[ \t]*//')"
[ -z "${CPU_MODEL}" ] && CPU_MODEL="$(uname -m 2>/dev/null || echo "x86_64")"
CPU_DISP="${CPU_MODEL} (${CPU_CORES}c)"

LOAD="$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null || echo 'N/A')"
LOAD_1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"
LOAD_STR="${LOAD}"
C_LOAD="${C_WHITE}"
awk -v l="${LOAD_1}" -v c="${CPU_CORES}" 'BEGIN { if (l >= c) exit 2; if (l >= c*0.7) exit 1; exit 0 }' 2>/dev/null
rc_load=$?
if [ $rc_load -eq 2 ]; then
  C_LOAD="${C_RED}"
elif [ $rc_load -eq 1 ]; then
  C_LOAD="${C_YELLOW}"
fi

# Memory Usage
MEM_TOTAL_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
MEM_AVAIL_KB="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
C_MEM="${C_WHITE}"
if [ "${MEM_TOTAL_KB}" -gt 0 ]; then
  MEM_USED_KB=$(( MEM_TOTAL_KB - MEM_AVAIL_KB ))
  MEM_PCT=$(( (MEM_USED_KB * 100) / MEM_TOTAL_KB ))
  MEM_USED_MB=$(( MEM_USED_KB / 1024 ))
  MEM_TOTAL_MB=$(( MEM_TOTAL_KB / 1024 ))
  if [ "${MEM_TOTAL_MB}" -ge 2048 ]; then
    MEM_STR="$(awk -v u="${MEM_USED_MB}" -v t="${MEM_TOTAL_MB}" 'BEGIN {printf "%.1fG / %.1fG", u/1024, t/1024}')"
  else
    MEM_STR="${MEM_USED_MB}M / ${MEM_TOTAL_MB}M"
  fi
  MEM_STR="${MEM_STR} (${MEM_PCT}%)"
  if [ "${MEM_PCT}" -ge 90 ]; then
    C_MEM="${C_RED}"
  elif [ "${MEM_PCT}" -ge 75 ]; then
    C_MEM="${C_YELLOW}"
  fi
else
  MEM_STR="N/A"
fi

# Swap Usage
SWAP_TOTAL_KB="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
SWAP_FREE_KB="$(awk '/SwapFree:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
C_SWAP="${C_WHITE}"
if [ "${SWAP_TOTAL_KB}" -gt 0 ]; then
  SWAP_USED_KB=$(( SWAP_TOTAL_KB - SWAP_FREE_KB ))
  SWAP_PCT=$(( (SWAP_USED_KB * 100) / SWAP_TOTAL_KB ))
  SWAP_USED_MB=$(( SWAP_USED_KB / 1024 ))
  SWAP_TOTAL_MB=$(( SWAP_TOTAL_KB / 1024 ))
  if [ "${SWAP_TOTAL_MB}" -ge 2048 ]; then
    SWAP_STR="$(awk -v u="${SWAP_USED_MB}" -v t="${SWAP_TOTAL_MB}" 'BEGIN {printf "%.1fG / %.1fG", u/1024, t/1024}')"
  else
    SWAP_STR="${SWAP_USED_MB}M / ${SWAP_TOTAL_MB}M"
  fi
  SWAP_STR="${SWAP_STR} (${SWAP_PCT}%)"
  if [ "${SWAP_PCT}" -ge 80 ]; then
    C_SWAP="${C_RED}"
  elif [ "${SWAP_PCT}" -ge 50 ]; then
    C_SWAP="${C_YELLOW}"
  fi
else
  SWAP_STR="Disabled (0B)"
  C_SWAP="${C_DIM}"
fi

# Disk Usage (Root filesystem /)
DISK_INFO="$(df -h / 2>/dev/null | awk 'NR==2 {print $3" / "$2" ("$5")"}')"
[ -z "${DISK_INFO}" ] && DISK_INFO="N/A"
DISK_PCT="$(echo "${DISK_INFO}" | grep -o '[0-9]\+%' | tr -d '%' || echo 0)"
C_DISK="${C_WHITE}"
if [ "${DISK_PCT:-0}" -ge 90 ]; then
  C_DISK="${C_RED}"
elif [ "${DISK_PCT:-0}" -ge 80 ]; then
  C_DISK="${C_YELLOW}"
fi

# Network IP (LAN)
LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -z "${LOCAL_IP}" ] && LOCAL_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
[ -z "${LOCAL_IP}" ] && LOCAL_IP="127.0.0.1"

# Public IP (cached for fast login)
IP_CACHE="/tmp/.wanforge_motd_pubip"
PUB_IP=""
if [ -f "${IP_CACHE}" ] && [ $(( $(date +%s 2>/dev/null || echo 0) - $(stat -c %Y "${IP_CACHE}" 2>/dev/null || echo 0) )) -lt 3600 ]; then
  PUB_IP="$(head -n 1 "${IP_CACHE}" 2>/dev/null || echo "")"
fi
if [ -z "${PUB_IP}" ]; then
  PUB_IP="$(curl -4 -s --connect-timeout 1 -m 1.5 https://api.ipify.org 2>/dev/null || curl -4 -s --connect-timeout 1 -m 1.5 https://ifconfig.me 2>/dev/null || echo "N/A")"
  if [ -n "${PUB_IP}" ] && [ "${PUB_IP}" != "N/A" ]; then
    (echo "${PUB_IP}" > "${IP_CACHE}" 2>/dev/null && chmod 644 "${IP_CACHE}" 2>/dev/null) || true
  fi
fi

# SSH Port
SSH_PORT="22"
if command -v ss >/dev/null 2>&1; then
  SSH_PORT="$(ss -tlpn 2>/dev/null | grep -iE 'sshd|ssh' | awk '{print $4}' | awk -F: '{print $NF}' | head -1)"
fi
[ -z "${SSH_PORT}" ] && SSH_PORT="22"

# Firewall Status
FW_STATUS="inactive"
C_FW="${C_RED}"
if systemctl is-active --quiet firewalld 2>/dev/null; then
  FW_STATUS="firewalld (active)"
  C_FW="${C_GREEN}"
elif systemctl is-active --quiet ufw 2>/dev/null; then
  FW_STATUS="ufw (active)"
  C_FW="${C_GREEN}"
elif systemctl is-active --quiet nftables 2>/dev/null; then
  FW_STATUS="nftables (active)"
  C_FW="${C_GREEN}"
elif systemctl is-active --quiet iptables 2>/dev/null; then
  FW_STATUS="iptables (active)"
  C_FW="${C_GREEN}"
fi

# Active Users
SESS_COUNT="$(who 2>/dev/null | wc -l || echo 1)"
SESS_STR="${SESS_COUNT} user"
[ "${SESS_COUNT}" -gt 1 ] && SESS_STR="${SESS_COUNT} users"

# Last login extraction
LAST_LINE="$(last -n 5 -F "${USER:-$(id -un 2>/dev/null || echo '')}" 2>/dev/null | grep -v 'wtmp' | grep -v 'reboot' | sed -n '2p')"
if [ -z "${LAST_LINE}" ]; then
  LAST_LINE="$(last -n 5 -F 2>/dev/null | grep -v 'wtmp' | grep -v 'reboot' | sed -n '2p')"
fi

LAST_STR="First session or not recorded"
if [ -n "${LAST_LINE}" ]; then
  LAST_IP="$(echo "${LAST_LINE}" | awk '{if ($3 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ || $3 ~ /:/ || $3 ~ /\./) print $3; else print ""}')"
  if [[ "${LAST_IP}" =~ ^tmux ]] || [[ "${LAST_IP}" =~ ^: ]] || [[ "${LAST_IP}" =~ ^pts/ ]]; then
    LAST_IP=""
  fi
  LAST_TIME="$(echo "${LAST_LINE}" | awk '{for(i=3;i<=NF;i++) if($i ~ /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$/) {print $i, $(i+1), $(i+2), $(i+3); exit}}')"
  if [ -n "${LAST_IP}" ] && [ -n "${LAST_TIME}" ]; then
    LAST_STR="Last login from ${LAST_IP} on ${LAST_TIME}"
  elif [ -n "${LAST_TIME}" ]; then
    LAST_STR="Last login from local session on ${LAST_TIME}"
  fi
fi

print_row() {
  local l1="$1" c1="$2" v1="$3" l2="$4" c2="$5" v2="$6"
  printf "  %b•%b %-10s: %b%-23.23s%b  %b•%b %-10s: %b%-19.19s%b\n" \
    "${C_CYAN}" "${C_RESET}" "${l1}" "${c1}" "${v1}" "${C_RESET}" \
    "${C_CYAN}" "${C_RESET}" "${l2}" "${c2}" "${v2}" "${C_RESET}"
}

printf "\n"
printf " %b╔════════════════════════════════════════════════════════════════════════╗%b\n" "${C_CYAN}" "${C_RESET}"
printf " %b║%b  %bWANFORGE SECURE INFRASTRUCTURE NODE%b                   %b● SYSTEM READY%b  %b║%b\n" \
  "${C_CYAN}" "${C_RESET}" "${C_BOLD}${C_WHITE}" "${C_RESET}" "${C_BOLD}${C_GREEN}" "${C_RESET}" "${C_CYAN}" "${C_RESET}"
printf " %b╚════════════════════════════════════════════════════════════════════════╝%b\n" "${C_CYAN}" "${C_RESET}"
print_row "Hostname" "${C_BOLD}${C_WHITE}" "${HOSTNAME}" "LAN IP" "${C_WHITE}" "${LOCAL_IP}"
print_row "OS Distro" "${C_WHITE}" "${OS_NAME}" "Public IP" "${C_CYAN}" "${PUB_IP}"
print_row "Kernel" "${C_WHITE}" "${KERNEL}" "SSH Port" "${C_YELLOW}" "${SSH_PORT}"
print_row "CPU Model" "${C_WHITE}" "${CPU_DISP}" "Firewall" "${C_FW}" "${FW_STATUS}"
print_row "CPU Load" "${C_LOAD}" "${LOAD_STR}" "Uptime" "${C_GREEN}" "${UPTIME_STR}"
print_row "RAM (Mem)" "${C_MEM}" "${MEM_STR}" "Active Ssn" "${C_WHITE}" "${SESS_STR}"
print_row "Swap" "${C_SWAP}" "${SWAP_STR}" "Disk (/)" "${C_DISK}" "${DISK_INFO}"
printf " %b──────────────────────────────────────────────────────────────────────────%b\n" "${C_DIM}" "${C_RESET}"
printf "  %bServices :%b  " "${C_DIM}" "${C_RESET}"

if systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd.socket 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null; then
  printf "%b●%b sshd   " "${C_GREEN}" "${C_RESET}"
else
  printf "%b○%b sshd   " "${C_DIM}" "${C_RESET}"
fi

if systemctl is-active --quiet firewalld 2>/dev/null; then
  printf "%b●%b firewalld   " "${C_GREEN}" "${C_RESET}"
elif systemctl is-active --quiet ufw 2>/dev/null; then
  printf "%b●%b ufw   " "${C_GREEN}" "${C_RESET}"
else
  printf "%b○%b firewall   " "${C_DIM}" "${C_RESET}"
fi

if systemctl is-active --quiet fail2ban 2>/dev/null; then
  printf "%b●%b fail2ban   " "${C_GREEN}" "${C_RESET}"
else
  printf "%b○%b fail2ban   " "${C_DIM}" "${C_RESET}"
fi

if systemctl is-active --quiet docker 2>/dev/null; then
  printf "%b●%b docker   " "${C_GREEN}" "${C_RESET}"
else
  printf "%b○%b docker   " "${C_DIM}" "${C_RESET}"
fi

if systemctl is-active --quiet podman 2>/dev/null; then
  printf "%b●%b podman   " "${C_GREEN}" "${C_RESET}"
else
  printf "%b○%b podman   " "${C_DIM}" "${C_RESET}"
fi

if systemctl is-active --quiet 9router 2>/dev/null; then
  printf "%b●%b 9router" "${C_GREEN}" "${C_RESET}"
else
  printf "%b○%b 9router" "${C_DIM}" "${C_RESET}"
fi
printf "\n"
printf "  %bAccess   :%b  %b%s%b\n" "${C_DIM}" "${C_RESET}" "${C_WHITE}" "${LAST_STR}" "${C_RESET}"

if [ -f /var/run/reboot-required ] || [ -f /run/reboot-required ]; then
  printf "  %bStatus   :%b  %b⚠  SYSTEM REBOOT REQUIRED%b\n" \
    "${C_DIM}" "${C_RESET}" "${C_BOLD}${C_RED}" "${C_RESET}"
fi

printf " %b──────────────────────────────────────────────────────────────────────────%b\n\n" "${C_DIM}" "${C_RESET}"
EOF
}

# --- Action 1: Preview MOTD ------------------------------------------------
a_preview() {
  hd "SSH Login MOTD Banner Preview"
  local tmp; tmp="$(mktemp)"
  render_motd_content > "${tmp}"
  chmod +x "${tmp}"
  WANFORGE_MOTD_FORCE=1 "${tmp}"
  rm -f "${tmp}"
}

# --- Action 2: Install WanForge MOTD ---------------------------------------
a_install() {
  hd "Install WanForge Dynamic SSH Login Banner"

  local target_path=""
  if [ -d "/etc/update-motd.d" ]; then
    target_path="${MOTD_UBUNTU_PATH}"
    sub "Detected Debian/Ubuntu update-motd.d framework..."
  else
    target_path="${MOTD_PROFILE_PATH}"
    sub "Detected Linux profile.d framework (/etc/profile.d)..."
  fi

  sub "Writing dynamic script to ${target_path}..."
  local tmp; tmp="$(mktemp)"
  render_motd_content > "${tmp}"
  chmod 755 "${tmp}"
  run ${SUDO} cp "${tmp}" "${target_path}"
  run ${SUDO} chmod 755 "${target_path}"
  rm -f "${tmp}"

  # Silence old update-motd.d scripts & external ads (Ubuntu Pro, ESM, CloudPanel, etc.)
  if [ -d "/etc/update-motd.d" ]; then
    sub "Silencing default MOTD & third-party ads in /etc/update-motd.d/..."
    for f in /etc/update-motd.d/*; do
      [ "$f" = "${MOTD_UBUNTU_PATH}" ] && continue
      if [ -f "$f" ] && [ -x "$f" ]; then
        run ${SUDO} chmod -x "$f" 2>/dev/null || true
        sub "Disabled: ${f##*/}"
      fi
    done
  fi

  # Silence any external profile.d MOTD banners (e.g. cloudpanel, stock)
  for pf in /etc/profile.d/*cloudpanel* /etc/profile.d/*motd*; do
    [ "$pf" = "${MOTD_PROFILE_PATH}" ] && continue
    if [ -f "$pf" ] && [ -x "$pf" ]; then
      run ${SUDO} chmod -x "$pf" 2>/dev/null || true
      sub "Disabled in profile.d: ${pf##*/}"
    fi
  done

  # Clear static /etc/motd and dynamic files so they don't double print
  for m in /etc/motd /var/run/motd /run/motd /var/run/motd.dynamic /run/motd.dynamic; do
    if [ -f "$m" ] && [ -s "$m" ]; then
      if [ "$m" = "/etc/motd" ] && [ ! -f "/etc/motd.bak" ]; then
        run ${SUDO} cp "/etc/motd" "/etc/motd.bak" 2>/dev/null || true
      fi
      run ${SUDO} truncate -s 0 "$m" 2>/dev/null || true
    fi
  done

  # Suppress duplicate unformatted pam lastlog (displayed cleanly in WanForge MOTD)
  if [ -d "/etc/ssh/sshd_config.d" ]; then
    local ssh_cfg="/etc/ssh/sshd_config.d/99-wanforge-motd.conf"
    if [ ! -f "${ssh_cfg}" ] || ! grep -q "PrintLastLog" "${ssh_cfg}" 2>/dev/null; then
      echo "PrintLastLog no" | run ${SUDO} tee "${ssh_cfg}" >/dev/null 2>&1 || true
      if command -v sshd >/dev/null 2>&1 && ${SUDO} sshd -t >/dev/null 2>&1; then
        run ${SUDO} systemctl reload-or-restart ssh 2>/dev/null || run ${SUDO} systemctl reload-or-restart sshd 2>/dev/null || true
        sub "Configured SSH PrintLastLog no for clean login output..."
      else
        run ${SUDO} rm -f "${ssh_cfg}" 2>/dev/null || true
      fi
    fi
  fi

  ok "WanForge dynamic MOTD successfully installed to ${target_path}."
  info "This banner will automatically appear on every SSH login."

  printf "\n"
  a_preview
}

# --- Action 3: Silence Ubuntu Advertising Only -----------------------------
a_clean_spam() {
  hd "Silence Ubuntu Pro / ESM / External Ads on SSH Login"
  if [ -d "/etc/update-motd.d" ]; then
    for f in /etc/update-motd.d/*; do
      [ "$f" = "${MOTD_UBUNTU_PATH}" ] && continue
      if [ -f "$f" ] && [ -x "$f" ]; then
        run ${SUDO} chmod -x "$f" 2>/dev/null || true
        sub "Disabled: ${f##*/}"
      fi
    done
  fi
  for pf in /etc/profile.d/*cloudpanel* /etc/profile.d/*motd*; do
    [ "$pf" = "${MOTD_PROFILE_PATH}" ] && continue
    if [ -f "$pf" ] && [ -x "$pf" ]; then
      run ${SUDO} chmod -x "$pf" 2>/dev/null || true
      sub "Disabled in profile.d: ${pf##*/}"
    fi
  done
  ok "Ads, CloudPanel banner, and third-party promotion scripts successfully disabled."
}

# --- Action 4: Restore Original MOTD ---------------------------------------
a_uninstall() {
  hd "Restore Default System MOTD Banner"

  if [ -f "${MOTD_UBUNTU_PATH}" ]; then
    run ${SUDO} rm -f "${MOTD_UBUNTU_PATH}"
    sub "Removed: ${MOTD_UBUNTU_PATH}"
  fi
  if [ -f "${MOTD_PROFILE_PATH}" ]; then
    run ${SUDO} rm -f "${MOTD_PROFILE_PATH}"
    sub "Removed: ${MOTD_PROFILE_PATH}"
  fi

  # Restore permissions of stock scripts in /etc/update-motd.d
  if [ -d "/etc/update-motd.d" ]; then
    for f in /etc/update-motd.d/*; do
      [ "$f" = "${MOTD_UBUNTU_PATH}" ] && continue
      [ -f "$f" ] && run ${SUDO} chmod +x "$f" 2>/dev/null || true
    done
  fi

  # Restore permissions in /etc/profile.d
  for pf in /etc/profile.d/*cloudpanel* /etc/profile.d/*motd*; do
    [ "$pf" = "${MOTD_PROFILE_PATH}" ] && continue
    [ -f "$pf" ] && run ${SUDO} chmod +x "$pf" 2>/dev/null || true
  done

  # Restore /etc/motd if backup exists
  if [ -f "/etc/motd.bak" ]; then
    run ${SUDO} cp "/etc/motd.bak" "/etc/motd"
    run ${SUDO} rm -f "/etc/motd.bak"
  fi

  # Revert SSH PrintLastLog setting
  if [ -f "/etc/ssh/sshd_config.d/99-wanforge-motd.conf" ]; then
    run ${SUDO} rm -f "/etc/ssh/sshd_config.d/99-wanforge-motd.conf"
    if command -v sshd >/dev/null 2>&1 && ${SUDO} sshd -t >/dev/null 2>&1; then
      run ${SUDO} systemctl reload-or-restart ssh 2>/dev/null || run ${SUDO} systemctl reload-or-restart sshd 2>/dev/null || true
    fi
  fi

  ok "MOTD banner restored to system OS defaults."
}

# --- CLI Dispatch ---------------------------------------------------------
case "${1:-}" in
  preview|show)         a_preview; exit $? ;;
  install)              a_install; exit $? ;;
  clean|clean-spam)     a_clean_spam; exit $? ;;
  --uninstall|uninstall) a_uninstall; exit $? ;;
esac

# --- Interactive Main Menu ------------------------------------------------
banner
MENU=(
  "View|preview|Preview SSH login banner now"
  "Install|install|Install WanForge dynamic MOTD banner to system"
  "Clean|clean_spam|Silence Ubuntu Pro / ESM / third-party ads in SSH"
  "Restore|uninstall|Restore default OS MOTD banner"
)

while true; do
  if menu_select "SELECT MOTD BANNER ACTION:"; then
    case "${MENU_KEY}" in
      preview)    a_preview ;;
      install)    a_install ;;
      clean_spam) a_clean_spam ;;
      uninstall)  a_uninstall ;;
      *) warn "Invalid choice: ${MENU_KEY}" ;;
    esac
  else
    break
  fi
done

ok "Script ${TOOL_NAME} completed."
