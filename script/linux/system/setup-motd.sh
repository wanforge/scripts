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
UPTIME_STR=""
[ "${DAYS}" -gt 0 ] && UPTIME_STR="${DAYS}h "
UPTIME_STR="${UPTIME_STR}${HOURS}j ${MINS}m"

# OS Name
OS_NAME="Linux"
if [ -f /etc/os-release ]; then
  # shellcheck source=/dev/null
  OS_NAME="$(. /etc/os-release && echo "${PRETTY_NAME:-$NAME}")"
fi

# CPU Load & Cores
CPU_CORES="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"
LOAD="$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null || echo 'N/A')"

# Memory Usage
MEM_TOTAL_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
MEM_AVAIL_KB="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
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
else
  MEM_STR="N/A"
fi

# Disk Usage (Root filesystem /)
DISK_INFO="$(df -h / 2>/dev/null | awk 'NR==2 {print $3" / "$2" ("$5")"}')"
[ -z "${DISK_INFO}" ] && DISK_INFO="N/A"

# Network IP
LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -z "${LOCAL_IP}" ] && LOCAL_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')"
[ -z "${LOCAL_IP}" ] && LOCAL_IP="127.0.0.1"

# SSH Port
SSH_PORT="22"
if command -v ss >/dev/null 2>&1; then
  SSH_PORT="$(ss -tlpn 2>/dev/null | grep -iE 'sshd|ssh' | awk '{print $4}' | awk -F: '{print $NF}' | head -1)"
fi
[ -z "${SSH_PORT}" ] && SSH_PORT="22"

# Active Users
SESS_COUNT="$(who 2>/dev/null | wc -l || echo 1)"

# Service Badges
svc_badge() {
  local s="$1" name="$2"
  if systemctl is-active --quiet "$s" 2>/dev/null; then
    printf "%b●%b %s  " "${C_GREEN}" "${C_RESET}" "${name}"
  else
    printf "%b○%b %s  " "${C_DIM}" "${C_RESET}" "${name}"
  fi
}

printf "\n"
printf " %bWANFORGE SECURE INFRASTRUCTURE NODE%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
printf " %b──────────────────────────────────────────────────────────────────────────%b\n" "${C_DIM}" "${C_RESET}"
printf "  %b•%b %-13s: %b%-22s%b %b•%b %-13s: %b%-20s%b\n" \
  "${C_CYAN}" "${C_RESET}" "Hostname" "${C_BOLD}${C_WHITE}" "${HOSTNAME:0:22}" "${C_RESET}" \
  "${C_CYAN}" "${C_RESET}" "Sistem Operasi" "${C_WHITE}" "${OS_NAME:0:20}" "${C_RESET}"
printf "  %b•%b %-13s: %b%-22s%b %b•%b %-13s: %b%-20s%b\n" \
  "${C_CYAN}" "${C_RESET}" "Linux Kernel" "${C_WHITE}" "${KERNEL:0:22}" "${C_RESET}" \
  "${C_CYAN}" "${C_RESET}" "Uptime" "${C_GREEN}" "${UPTIME_STR}" "${C_RESET}"
printf "  %b•%b %-13s: %b%-22s%b %b•%b %-13s: %b%-20s%b\n" \
  "${C_CYAN}" "${C_RESET}" "Load Average" "${C_WHITE}" "${LOAD} (${CPU_CORES} vCPU)" "${C_RESET}" \
  "${C_CYAN}" "${C_RESET}" "Memory (RAM)" "${C_YELLOW}" "${MEM_STR}" "${C_RESET}"
printf "  %b•%b %-13s: %b%-22s%b %b•%b %-13s: %b%-20s%b\n" \
  "${C_CYAN}" "${C_RESET}" "Disk Usage (/)" "${C_WHITE}" "${DISK_INFO}" "${C_RESET}" \
  "${C_CYAN}" "${C_RESET}" "IP Lokal (LAN)" "${C_WHITE}" "${LOCAL_IP}" "${C_RESET}"
printf "  %b•%b %-13s: %b%-22s%b %b•%b %-13s: %b%-20s%b\n" \
  "${C_CYAN}" "${C_RESET}" "SSH Port" "${C_YELLOW}" "${SSH_PORT}" "${C_RESET}" \
  "${C_CYAN}" "${C_RESET}" "Sesi Login" "${C_WHITE}" "${SESS_COUNT} user aktif" "${C_RESET}"
printf " %b──────────────────────────────────────────────────────────────────────────%b\n" "${C_DIM}" "${C_RESET}"
printf "  %bLayanan : %b" "${C_DIM}" "${C_RESET}"
svc_badge sshd sshd
svc_badge ssh ssh
svc_badge docker docker
svc_badge podman podman
svc_badge ufw ufw
svc_badge firewalld firewalld
svc_badge 9router 9router
printf "\n"
printf " %b──────────────────────────────────────────────────────────────────────────%b\n\n" "${C_DIM}" "${C_RESET}"
EOF
}

# --- Action 1: Preview MOTD ------------------------------------------------
a_preview() {
  hd "Pratinjau Tampilan MOTD Login SSH"
  local tmp; tmp="$(mktemp)"
  render_motd_content > "${tmp}"
  chmod +x "${tmp}"
  WANFORGE_MOTD_FORCE=1 "${tmp}"
  rm -f "${tmp}"
}

# --- Action 2: Install WanForge MOTD ---------------------------------------
a_install() {
  hd "Pasang WanForge Dynamic SSH Login Banner"

  local target_path=""
  if [ -d "/etc/update-motd.d" ]; then
    target_path="${MOTD_UBUNTU_PATH}"
    sub "Mendeteksi Debian/Ubuntu update-motd.d framework..."
  else
    target_path="${MOTD_PROFILE_PATH}"
    sub "Mendeteksi Linux profile.d framework (/etc/profile.d)..."
  fi

  sub "Menulis skrip dinamis ke ${target_path}..."
  local tmp; tmp="$(mktemp)"
  render_motd_content > "${tmp}"
  chmod 755 "${tmp}"
  run ${SUDO} cp "${tmp}" "${target_path}"
  run ${SUDO} chmod 755 "${target_path}"
  rm -f "${tmp}"

  # Silence Ubuntu Pro / ESM advertising scripts if present
  if [ -d "/etc/update-motd.d" ]; then
    sub "Menonaktifkan iklan Ubuntu Pro / ESM / Help text..."
    local noisy=(
      "/etc/update-motd.d/10-help-text"
      "/etc/update-motd.d/50-motd-news"
      "/etc/update-motd.d/88-esm-announce"
      "/etc/update-motd.d/91-release-upgrade"
      "/etc/update-motd.d/95-hwe-eol"
    )
    for f in "${noisy[@]}"; do
      if [ -f "$f" ] && [ -x "$f" ]; then
        run ${SUDO} chmod -x "$f" 2>/dev/null || true
      fi
    done
  fi

  # Clear static /etc/motd if present so it doesn't double print
  if [ -f "/etc/motd" ] && [ -s "/etc/motd" ]; then
    if [ ! -f "/etc/motd.bak" ]; then
      run ${SUDO} cp "/etc/motd" "/etc/motd.bak"
    fi
    run ${SUDO} truncate -s 0 "/etc/motd" 2>/dev/null || true
  fi

  ok "WanForge dynamic MOTD berhasil dipasang di ${target_path}."
  info "Tampilan ini akan otomatis muncul setiap kali login via SSH."

  printf "\n"
  a_preview
}

# --- Action 3: Silence Ubuntu Advertising Only -----------------------------
a_clean_spam() {
  hd "Bersihkan Iklan Ubuntu Pro / ESM pada SSH Login"
  if [ ! -d "/etc/update-motd.d" ]; then
    info "Sistem ini bukan Debian/Ubuntu update-motd. Tidak ada iklan Ubuntu Pro."; return 0
  fi

  local noisy=(
    "/etc/update-motd.d/10-help-text"
    "/etc/update-motd.d/50-motd-news"
    "/etc/update-motd.d/88-esm-announce"
    "/etc/update-motd.d/91-release-upgrade"
    "/etc/update-motd.d/95-hwe-eol"
  )
  for f in "${noisy[@]}"; do
    if [ -f "$f" ]; then
      run ${SUDO} chmod -x "$f" 2>/dev/null || true
      sub "Dinonaktifkan: ${f##*/}"
    fi
  done
  ok "Iklan dan notifikasi promosi pada SSH login berhasil dinonaktifkan."
}

# --- Action 4: Restore Original MOTD ---------------------------------------
a_uninstall() {
  hd "Kembalikan Tampilan MOTD Original Sistem"

  if [ -f "${MOTD_UBUNTU_PATH}" ]; then
    run ${SUDO} rm -f "${MOTD_UBUNTU_PATH}"
    sub "Dihapus: ${MOTD_UBUNTU_PATH}"
  fi
  if [ -f "${MOTD_PROFILE_PATH}" ]; then
    run ${SUDO} rm -f "${MOTD_PROFILE_PATH}"
    sub "Dihapus: ${MOTD_PROFILE_PATH}"
  fi

  # Restore permissions of stock scripts
  if [ -d "/etc/update-motd.d" ]; then
    local noisy=(
      "/etc/update-motd.d/10-help-text"
      "/etc/update-motd.d/50-motd-news"
    )
    for f in "${noisy[@]}"; do
      [ -f "$f" ] && run ${SUDO} chmod +x "$f" 2>/dev/null || true
    done
  fi

  # Restore /etc/motd if backup exists
  if [ -f "/etc/motd.bak" ]; then
    run ${SUDO} cp "/etc/motd.bak" "/etc/motd"
    run ${SUDO} rm -f "/etc/motd.bak"
  fi

  ok "Tampilan MOTD dikembalikan ke standar bawaan OS."
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
  "Tampilan|preview|Pratinjau tampilan banner login SSH sekarang"
  "Pasang|install|Pasang WanForge dynamic MOTD banner sistem"
  "Bersihkan|clean_spam|Nonaktifkan iklan promosi Ubuntu Pro/ESM di SSH"
  "Pulihkan|uninstall|Kembalikan tampilan MOTD standar bawaan OS"
)

while true; do
  if menu_select "PILIH AKSI LOGIN BANNER (MOTD):"; then
    case "${MENU_KEY}" in
      preview)    a_preview ;;
      install)    a_install ;;
      clean_spam) a_clean_spam ;;
      uninstall)  a_uninstall ;;
      *) warn "Pilihan tidak valid: ${MENU_KEY}" ;;
    esac
  else
    break
  fi
done

ok "Script ${TOOL_NAME} selesai."
