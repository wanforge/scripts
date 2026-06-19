#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# proxmox-toolkit.sh — Proxmox VE management & resource monitoring:
# node status (CPU/RAM/disk), storage, VMs (qm) & containers (pct), cluster,
# tasks, and a realtime resource dashboard.
#
# Usage (run on a Proxmox VE node):
#   curl -fsSL https://scripts.wanforge.asia/script/linux/network/proxmox-toolkit.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="proxmox-toolkit"

# --- shared library: banner, colors, logging, prompts, menus -------------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load

have() { command -v "$1" >/dev/null 2>&1; }
NODE="$(hostname 2>/dev/null || echo localhost)"

# ---- Overview -----------------------------------------------------------
a_version() { hd "Proxmox version"; pveversion -v 2>/dev/null >&2 || pveversion >&2 || warn "pveversion not found"; }
a_node() {
  hd "Node status (${NODE})"
  pvesh get "/nodes/${NODE}/status" 2>/dev/null >&2 || { uptime >&2; free -h >&2; }
}
a_cluster() {
  hd "Cluster"
  if have pvecm; then ${SUDO} pvecm status 2>/dev/null >&2 && ${SUDO} pvecm nodes 2>/dev/null >&2 || warn "Standalone node (no cluster)."; else warn "pvecm not available."; fi
}
a_tasks() { hd "Recent tasks"; pvenode task list 2>/dev/null | head -20 >&2 || pvesh get "/nodes/${NODE}/tasks" 2>/dev/null | head -20 >&2 || warn "no task list"; }
a_ha()    { hd "HA status"; have ha-manager && ${SUDO} ha-manager status >&2 || warn "ha-manager not configured."; }

# ---- Resources ----------------------------------------------------------
a_memory() {
  hd "Memory"; free -h >&2
  hd "From node API"; pvesh get "/nodes/${NODE}/status" 2>/dev/null | grep -iE 'memory|swap' >&2 || true
}
a_cpu() {
  hd "CPU"
  printf "cores: %s   loadavg: %s\n" "$(nproc 2>/dev/null || echo '?')" "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)" >&2
  have mpstat && mpstat 1 1 >&2 || top -bn1 2>/dev/null | grep -i '%Cpu' >&2 || true
}
a_disk() {
  hd "Filesystems"; df -hT -x tmpfs -x devtmpfs 2>/dev/null >&2 || df -h >&2
  hd "Proxmox storage"; have pvesm && ${SUDO} pvesm status >&2 || warn "pvesm not available."
}
a_top() { hd "Top by CPU"; ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu 2>/dev/null | head -11 >&2; hd "Top by memory"; ps -eo pid,user,%cpu,%mem,comm --sort=-%mem 2>/dev/null | head -11 >&2; }
a_io()  { hd "Disk I/O"; have iostat && iostat -dx 1 2 >&2 || { warn "iostat not installed (sysstat)."; cat /proc/diskstats >&2; }; }

# ---- Guests (VMs / containers) ------------------------------------------
a_vms()  { hd "Virtual machines (qm)"; ${SUDO} qm list >&2 2>/dev/null || warn "qm not available."; }
a_cts()  { hd "Containers (pct)"; ${SUDO} pct list >&2 2>/dev/null || warn "pct not available."; }
a_vm_manage() {
  ${SUDO} qm list >&2 2>/dev/null || { warn "qm not available."; return; }
  local id; id="$(ask 'VMID to manage (Enter to skip):' '')"; [ -n "$id" ] || return
  MENU=("Action|status|status" "Action|start|start" "Action|shutdown|shutdown (graceful)" "Action|stop|stop (force)" "Action|reboot|reboot" "Action|config|config" "Action|backup|backup (vzdump)")
  menu_select "VM ${id}:" || return
  case "${MENU_KEY}" in
    status) ${SUDO} qm status "$id" >&2 ;;
    start) run ${SUDO} qm start "$id" ;;
    shutdown) run ${SUDO} qm shutdown "$id" ;;
    stop) run ${SUDO} qm stop "$id" ;;
    reboot) run ${SUDO} qm reboot "$id" ;;
    config) ${SUDO} qm config "$id" >&2 ;;
    backup) local st; st="$(ask_cfg CFG_PVE_VM_STORAGE 'Storage for backup:' 'local')"; run ${SUDO} vzdump "$id" --storage "$st" --mode snapshot ;;
  esac
}
a_ct_manage() {
  ${SUDO} pct list >&2 2>/dev/null || { warn "pct not available."; return; }
  local id; id="$(ask 'CTID to manage (Enter to skip):' '')"; [ -n "$id" ] || return
  MENU=("Action|status|status" "Action|start|start" "Action|shutdown|shutdown (graceful)" "Action|stop|stop (force)" "Action|reboot|reboot" "Action|config|config" "Action|backup|backup (vzdump)")
  menu_select "CT ${id}:" || return
  case "${MENU_KEY}" in
    status) ${SUDO} pct status "$id" >&2 ;;
    start) run ${SUDO} pct start "$id" ;;
    shutdown) run ${SUDO} pct shutdown "$id" ;;
    stop) run ${SUDO} pct stop "$id" ;;
    reboot) run ${SUDO} pct reboot "$id" ;;
    config) ${SUDO} pct config "$id" >&2 ;;
    backup) local st; st="$(ask_cfg CFG_PVE_CT_STORAGE 'Storage for backup:' 'local')"; run ${SUDO} vzdump "$id" --storage "$st" --mode snapshot ;;
  esac
}

# ---- realtime dashboard -------------------------------------------------
pvm_render() {
  local vrun vtot crun ctot
  vrun="$(${SUDO} qm list 2>/dev/null | awk 'NR>1 && $3=="running"' | wc -l)"
  vtot="$(${SUDO} qm list 2>/dev/null | awk 'NR>1' | wc -l)"
  crun="$(${SUDO} pct list 2>/dev/null | awk 'NR>1 && $2=="running"' | wc -l)"
  ctot="$(${SUDO} pct list 2>/dev/null | awk 'NR>1' | wc -l)"
  hd "CPU & load"; printf "cores: %s   loadavg: %s\n" "$(nproc 2>/dev/null || echo '?')" "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)" >&2
  hd "Memory"; free -h >&2
  hd "Root filesystem"; df -hT / 2>/dev/null >&2 || df -h / >&2
  hd "Proxmox storage"; ${SUDO} pvesm status 2>/dev/null >&2 || true
  hd "Guests"; printf "VMs running: %s/%s    Containers running: %s/%s\n" "${vrun}" "${vtot}" "${crun}" "${ctot}" >&2
}
a_watch() {
  local iv; iv="$(ask_cfg CFG_PVE_WATCH_IV "Refresh interval (seconds):" "2")"; [[ "$iv" =~ ^[0-9]+$ ]] || iv=2
  printf '\033[2J\033[?25l' >&2
  trap 'printf "\033[?25h\n" >&2; return 0' INT
  while true; do
    FRAME="$( {
      printf "%bwanforge.asia · proxmox (%s)%b  %b%s%b  %brefresh %ss · Ctrl-C to stop%b\n" \
        "${C_BOLD}${C_CYAN}" "${NODE}" "${C_RESET}" "${C_GREEN}" "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "${C_RESET}" "${C_DIM}" "${iv}" "${C_RESET}"
      pvm_render
    } 2>&1 )"
    printf '\033[H' >&2
    while IFS= read -r __ln; do printf '%s\033[K\n' "${__ln}" >&2; done <<< "${FRAME}"
    printf '\033[J' >&2
    sleep "${iv}"
  done
}

# ---- menu (single-select TUI) -------------------------------------------
MENU=(
  "Overview|version|Proxmox version"
  "Overview|node|Node status (CPU/RAM/disk)"
  "Overview|cluster|Cluster status"
  "Overview|tasks|Recent tasks"
  "Overview|ha|HA status"
  "Resources|memory|Memory (RAM + swap)"
  "Resources|cpu|CPU load & usage"
  "Resources|disk|Disk & Proxmox storage"
  "Resources|top|Top processes"
  "Resources|io|Disk I/O"
  "Guests|vms|List VMs"
  "Guests|cts|List containers"
  "Guests|vm_manage|Manage a VM (start/stop/backup…)"
  "Guests|ct_manage|Manage a container"
  "Realtime|watch|Live resource dashboard"
  "Config|clear_cfg|Clear saved config (storage, interval)"
)

# ---- run ----------------------------------------------------------------
banner
if ! have pvesh && ! have qm && [ ! -d /etc/pve ]; then
  err "This does not look like a Proxmox VE node (no pvesh/qm /etc/pve)."
  exit 1
fi
info "Proxmox node: ${C_BOLD}${NODE}${C_RESET}"

while true; do
  printf "\n" >&2
  menu_select "Proxmox toolkit:" || break
  case "${MENU_KEY}" in
    version) a_version ;;  node) a_node ;;      cluster) a_cluster ;;
    tasks) a_tasks ;;      ha) a_ha ;;
    memory) a_memory ;;    cpu) a_cpu ;;        disk) a_disk ;;
    top) a_top ;;          io) a_io ;;
    vms) a_vms ;;          cts) a_cts ;;        vm_manage) a_vm_manage ;;  ct_manage) a_ct_manage ;;
    watch) a_watch ;;
    clear_cfg) cfg_clear && ok "Saved config cleared." ;;
  esac
done

printf "\n%b✔ proxmox-toolkit finished.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
