#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2155
#
# hardware-info.sh — comprehensive hardware audit & system specifications inspector.
# Audits CPU, RAM, storage, GPU, motherboard/BIOS, network, PCI/USB, sensors & virtualization.
# Supports detailed colored CLI, 1-page summary, JSON, and Markdown formats.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/system/hardware-info.sh | bash
#   curl -fsSL https://scripts.wanforge.asia/script/linux/system/hardware-info.sh | bash -s -- --summary
#   curl -fsSL https://scripts.wanforge.asia/script/linux/system/hardware-info.sh | bash -s -- --json
#   curl -fsSL https://scripts.wanforge.asia/script/linux/system/hardware-info.sh | bash -s -- --markdown
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="hardware-info"

# --- shared library ------------------------------------------------------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi

# --- helper functions ----------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

priv_cmd() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@" 2>/dev/null || return 1
  elif have sudo; then
    sudo -n "$@" 2>/dev/null || return 1
  else
    return 1
  fi
}

json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

trim() {
  local var="$*"
  var="${var#"${var%%[![:space:]]*}"}"
  var="${var%"${var##*[![:space:]]}"}"
  printf '%s' "$var"
}

decode_chassis_type() {
  case "${1:-}" in
    1) echo "Other" ;;
    2) echo "Unknown" ;;
    3) echo "Desktop" ;;
    4) echo "Low Profile Desktop" ;;
    5) echo "Pizza Box" ;;
    6) echo "Mini Tower" ;;
    7) echo "Tower" ;;
    8) echo "Portable" ;;
    9) echo "Laptop" ;;
    10) echo "Notebook" ;;
    11) echo "Hand Held" ;;
    12) echo "Docking Station" ;;
    13) echo "All in One" ;;
    14) echo "Sub Notebook" ;;
    15) echo "Space-saving" ;;
    16) echo "Lunch Box" ;;
    17) echo "Main Server Chassis" ;;
    18) echo "Expansion Chassis" ;;
    19) echo "SubChassis" ;;
    20) echo "Bus Expansion Chassis" ;;
    21) echo "Peripheral Chassis" ;;
    22) echo "RAID Chassis" ;;
    23) echo "Rack Mount Chassis" ;;
    24) echo "Sealed-case PC" ;;
    30) echo "Tablet" ;;
    31) echo "Convertible" ;;
    32) echo "Detachable" ;;
    *) echo "Unknown (${1:-?})" ;;
  esac
}

# --- collectors ----------------------------------------------------------
collect_all() {
  # 1. System / Host & Virtualization
  HOST_NAME="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")"
  if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    OS_PRETTY="$(. /etc/os-release && echo "${PRETTY_NAME:-Linux}")"
  else
    OS_PRETTY="Linux $(uname -s 2>/dev/null || echo '')"
  fi
  KERNEL_VER="$(uname -r 2>/dev/null || echo "unknown")"
  ARCH="$(uname -m 2>/dev/null || echo "unknown")"
  UPTIME="$(uptime -p 2>/dev/null || uptime 2>/dev/null || echo "unknown")"
  LOAD_AVG="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo "unknown")"

  VIRT_TYPE="bare-metal"
  if have systemd-detect-virt; then
    local v; v="$(systemd-detect-virt 2>/dev/null || true)"
    v="$(trim "$v")"
    [ -n "$v" ] && [ "$v" != "none" ] && VIRT_TYPE="$v"
  fi
  if [ "$VIRT_TYPE" = "bare-metal" ] && grep -q -i hypervisor /proc/cpuinfo 2>/dev/null; then
    VIRT_TYPE="hypervisor-detected"
  fi

  # 2. Motherboard & BIOS
  DMI_PATH="/sys/class/dmi/id"
  BOARD_VENDOR="unavailable"
  BOARD_NAME="unavailable"
  BOARD_VERSION="unavailable"
  BIOS_VENDOR="unavailable"
  BIOS_VERSION="unavailable"
  BIOS_DATE="unavailable"
  SYS_VENDOR="unavailable"
  PRODUCT_NAME="unavailable"
  CHASSIS="unavailable"

  if [ -d "$DMI_PATH" ]; then
    [ -r "$DMI_PATH/board_vendor" ] && BOARD_VENDOR="$(cat "$DMI_PATH/board_vendor" 2>/dev/null || echo "unavailable")"
    [ -r "$DMI_PATH/board_name" ] && BOARD_NAME="$(cat "$DMI_PATH/board_name" 2>/dev/null || echo "unavailable")"
    [ -r "$DMI_PATH/board_version" ] && BOARD_VERSION="$(cat "$DMI_PATH/board_version" 2>/dev/null || echo "unavailable")"
    [ -r "$DMI_PATH/bios_vendor" ] && BIOS_VENDOR="$(cat "$DMI_PATH/bios_vendor" 2>/dev/null || echo "unavailable")"
    [ -r "$DMI_PATH/bios_version" ] && BIOS_VERSION="$(cat "$DMI_PATH/bios_version" 2>/dev/null || echo "unavailable")"
    [ -r "$DMI_PATH/bios_date" ] && BIOS_DATE="$(cat "$DMI_PATH/bios_date" 2>/dev/null || echo "unavailable")"
    [ -r "$DMI_PATH/sys_vendor" ] && SYS_VENDOR="$(cat "$DMI_PATH/sys_vendor" 2>/dev/null || echo "unavailable")"
    [ -r "$DMI_PATH/product_name" ] && PRODUCT_NAME="$(cat "$DMI_PATH/product_name" 2>/dev/null || echo "unavailable")"
    if [ -r "$DMI_PATH/chassis_type" ]; then
      local c_id; c_id="$(cat "$DMI_PATH/chassis_type" 2>/dev/null || echo "")"
      [ -n "$c_id" ] && CHASSIS="$(decode_chassis_type "$c_id")"
    fi
  fi

  # Fallback to dmidecode for DMI if /sys was unpopulated and root/sudo available
  if [ "$BOARD_VENDOR" = "unavailable" ] || [ -z "$BOARD_VENDOR" ]; then
    local dmi_board; dmi_board="$(priv_cmd dmidecode -s baseboard-manufacturer 2>/dev/null || echo "")"
    [ -n "$dmi_board" ] && BOARD_VENDOR="$dmi_board"
  fi
  if [ "$BOARD_NAME" = "unavailable" ] || [ -z "$BOARD_NAME" ]; then
    local dmi_name; dmi_name="$(priv_cmd dmidecode -s baseboard-product-name 2>/dev/null || echo "")"
    [ -n "$dmi_name" ] && BOARD_NAME="$dmi_name"
  fi
  if [ "$BIOS_VERSION" = "unavailable" ] || [ -z "$BIOS_VERSION" ]; then
    local dmi_bios; dmi_bios="$(priv_cmd dmidecode -s bios-version 2>/dev/null || echo "")"
    [ -n "$dmi_bios" ] && BIOS_VERSION="$dmi_bios"
  fi

  BOOT_MODE="Legacy BIOS"
  [ -d /sys/firmware/efi ] && BOOT_MODE="UEFI"
  SECURE_BOOT="unavailable"
  if have mokutil; then
    SECURE_BOOT="$(mokutil --sb-state 2>/dev/null || echo "unavailable")"
  elif [ -r /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c ]; then
    SECURE_BOOT="Enabled (efivars)"
  fi

  # 3. CPU
  CPU_MODEL="unknown"
  CPU_VENDOR="unknown"
  CPU_FAMILY="unknown"
  CPU_MODEL_NUM="unknown"
  CPU_STEPPING="unknown"
  CPU_SOCKETS="1"
  CPU_CORES="$(nproc 2>/dev/null || echo "1")"
  CPU_THREADS="$CPU_CORES"
  CPU_FREQ_MIN="N/A"
  CPU_FREQ_MAX="N/A"
  CPU_FREQ_CUR="N/A"
  CPU_GOVERNOR="N/A"
  CACHE_L1D="N/A"
  CACHE_L1I="N/A"
  CACHE_L2="N/A"
  CACHE_L3="N/A"
  VIRT_FLAGS="none"

  if have lscpu; then
    local lscpu_out; lscpu_out="$(lscpu 2>/dev/null || true)"
    local v; v="$(echo "$lscpu_out" | grep -i '^Model name:' | head -1 | cut -d: -f2- || true)"; [ -n "$v" ] && CPU_MODEL="$(trim "$v")"
    v="$(echo "$lscpu_out" | grep -i '^Vendor ID:' | head -1 | cut -d: -f2- || true)"; [ -n "$v" ] && CPU_VENDOR="$(trim "$v")"
    v="$(echo "$lscpu_out" | grep -i '^CPU family:' | head -1 | cut -d: -f2- || true)"; [ -n "$v" ] && CPU_FAMILY="$(trim "$v")"
    v="$(echo "$lscpu_out" | grep -i '^Model:' | head -1 | cut -d: -f2- || true)"; [ -n "$v" ] && CPU_MODEL_NUM="$(trim "$v")"
    v="$(echo "$lscpu_out" | grep -i '^Stepping:' | head -1 | cut -d: -f2- || true)"; [ -n "$v" ] && CPU_STEPPING="$(trim "$v")"
    v="$(echo "$lscpu_out" | grep -i '^Socket(s):' | head -1 | cut -d: -f2- || true)"; [ -n "$v" ] && CPU_SOCKETS="$(trim "$v")"
    v="$(echo "$lscpu_out" | grep -i '^Core(s) per socket:' | head -1 | cut -d: -f2- || true)"; [ -n "$v" ] && CPU_CORES="$(trim "$v")"
    v="$(echo "$lscpu_out" | grep -i '^CPU(s):' | head -1 | cut -d: -f2- || true)"; [ -n "$v" ] && CPU_THREADS="$(trim "$v")"
    v="$(echo "$lscpu_out" | grep -i '^CPU max MHz:' | head -1 | cut -d: -f2- || true)"; [ -n "$v" ] && CPU_FREQ_MAX="$(trim "$v") MHz"
    v="$(echo "$lscpu_out" | grep -i '^CPU min MHz:' | head -1 | cut -d: -f2- || true)"; [ -n "$v" ] && CPU_FREQ_MIN="$(trim "$v") MHz"
    v="$(echo "$lscpu_out" | grep -i '^L1d cache:' | head -1 | cut -d: -f2- || true)"; [ -n "$v" ] && CACHE_L1D="$(trim "$v")"
    v="$(echo "$lscpu_out" | grep -i '^L1i cache:' | head -1 | cut -d: -f2- || true)"; [ -n "$v" ] && CACHE_L1I="$(trim "$v")"
    v="$(echo "$lscpu_out" | grep -i '^L2 cache:' | head -1 | cut -d: -f2- || true)"; [ -n "$v" ] && CACHE_L2="$(trim "$v")"
    v="$(echo "$lscpu_out" | grep -i '^L3 cache:' | head -1 | cut -d: -f2- || true)"; [ -n "$v" ] && CACHE_L3="$(trim "$v")"
    v="$(echo "$lscpu_out" | grep -i '^Virtualization:' | head -1 | cut -d: -f2- || true)"; [ -n "$v" ] && VIRT_FLAGS="$(trim "$v")"
  fi

  if [ "$CPU_MODEL" = "unknown" ] && [ -f /proc/cpuinfo ]; then
    CPU_MODEL="$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ //' || echo "unknown")"
    CPU_VENDOR="$(grep -m1 'vendor_id' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ //' || echo "unknown")"
  fi

  # Current frequency & governor from cpufreq or /proc/cpuinfo
  if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq ]; then
    local khz; khz="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo 0)"
    if [ "$khz" -gt 0 ] 2>/dev/null; then
      CPU_FREQ_CUR="$((khz / 1000)) MHz"
    fi
  elif [ -f /proc/cpuinfo ]; then
    local mhz; mhz="$(grep -m1 'cpu MHz' /proc/cpuinfo 2>/dev/null | awk '{print $4}' || echo "")"
    [ -n "$mhz" ] && CPU_FREQ_CUR="${mhz%.*} MHz"
  fi

  if [ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
    CPU_GOVERNOR="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")"
  fi

  # Virtualization extensions flag check
  if [ "$VIRT_FLAGS" = "none" ] && [ -f /proc/cpuinfo ]; then
    local flags; flags="$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null || echo "")"
    if echo "$flags" | grep -q '\bvmx\b'; then
      VIRT_FLAGS="VT-x (Intel VMX)"
    elif echo "$flags" | grep -q '\bsvm\b'; then
      VIRT_FLAGS="AMD-V (SVM)"
    fi
  fi

  NESTED_VIRT="disabled / N/A"
  if [ -r /sys/module/kvm_intel/parameters/nested ]; then
    local n; n="$(cat /sys/module/kvm_intel/parameters/nested 2>/dev/null || echo "N")"
    [ "$n" = "Y" ] || [ "$n" = "1" ] && NESTED_VIRT="enabled (Intel KVM)"
  elif [ -r /sys/module/kvm_amd/parameters/nested ]; then
    local n; n="$(cat /sys/module/kvm_amd/parameters/nested 2>/dev/null || echo "0")"
    [ "$n" = "1" ] || [ "$n" = "Y" ] && NESTED_VIRT="enabled (AMD KVM)"
  fi

  # CPU Vulnerabilities
  CPU_VULNS=()
  if [ -d /sys/devices/system/cpu/vulnerabilities ]; then
    for vpath in /sys/devices/system/cpu/vulnerabilities/*; do
      [ -e "$vpath" ] || continue
      local vname; vname="$(basename "$vpath")"
      local vstatus; vstatus="$(cat "$vpath" 2>/dev/null || echo "unknown")"
      CPU_VULNS+=("${vname}|${vstatus}")
    done
  fi

  # 4. Memory / RAM
  MEM_TOTAL="0"
  MEM_FREE="0"
  MEM_AVAIL="0"
  MEM_USED="0"
  MEM_BUFFERS="0"
  MEM_CACHED="0"
  SWAP_TOTAL="0"
  SWAP_USED="0"
  SWAP_FREE="0"

  if [ -f /proc/meminfo ]; then
    local t; t=$(grep -i '^MemTotal:' /proc/meminfo | awk '{print $2}' || echo 0)
    local f; f=$(grep -i '^MemFree:' /proc/meminfo | awk '{print $2}' || echo 0)
    local a; a=$(grep -i '^MemAvailable:' /proc/meminfo | awk '{print $2}' || echo 0)
    local b; b=$(grep -i '^Buffers:' /proc/meminfo | awk '{print $2}' || echo 0)
    local c; c=$(grep -i '^Cached:' /proc/meminfo | awk '{print $2}' || echo 0)
    local st; st=$(grep -i '^SwapTotal:' /proc/meminfo | awk '{print $2}' || echo 0)
    local sf; sf=$(grep -i '^SwapFree:' /proc/meminfo | awk '{print $2}' || echo 0)

    [ "$a" -eq 0 ] && a=$f
    local u=$((t - a))
    local su=$((st - sf))

    MEM_TOTAL="$((t / 1024)) MB"
    MEM_FREE="$((f / 1024)) MB"
    MEM_AVAIL="$((a / 1024)) MB"
    MEM_USED="$((u / 1024)) MB"
    MEM_BUFFERS="$((b / 1024)) MB"
    MEM_CACHED="$((c / 1024)) MB"
    SWAP_TOTAL="$((st / 1024)) MB"
    SWAP_USED="$((su / 1024)) MB"
    SWAP_FREE="$((sf / 1024)) MB"
  fi

  # Physical DIMM devices via dmidecode
  MEM_DIMMS=()
  MEM_DIMM_STATUS="ok"
  local dmi_mem; dmi_mem="$(priv_cmd dmidecode -t 17 2>/dev/null || true)"
  if [ -n "$dmi_mem" ]; then
    local d_loc="" d_size="" d_type="" d_speed="" d_mfr="" d_part="" in_dev=0
    while IFS= read -r line; do
      if echo "$line" | grep -q '^Memory Device'; then
        if [ "$in_dev" -eq 1 ] && [ -n "$d_loc" ]; then
          MEM_DIMMS+=("${d_loc}|${d_size:-Empty}|${d_type:-N/A}|${d_speed:-N/A}|${d_mfr:-N/A}|${d_part:-N/A}")
        fi
        in_dev=1
        d_loc=""; d_size=""; d_type=""; d_speed=""; d_mfr=""; d_part=""
      elif [ "$in_dev" -eq 1 ]; then
        case "$line" in
          *"Locator:"*) [ -z "$d_loc" ] && d_loc="$(echo "$line" | cut -d: -f2- | sed 's/^[ \t]*//')" ;;
          *"Size:"*) d_size="$(echo "$line" | cut -d: -f2- | sed 's/^[ \t]*//')" ;;
          *"Type:"*) [ -z "$d_type" ] && d_type="$(echo "$line" | cut -d: -f2- | sed 's/^[ \t]*//')" ;;
          *"Speed:"*) [ -z "$d_speed" ] && d_speed="$(echo "$line" | cut -d: -f2- | sed 's/^[ \t]*//')" ;;
          *"Manufacturer:"*) d_mfr="$(echo "$line" | cut -d: -f2- | sed 's/^[ \t]*//')" ;;
          *"Part Number:"*) d_part="$(echo "$line" | cut -d: -f2- | sed 's/^[ \t]*//')" ;;
        esac
      fi
    done <<< "$dmi_mem"
    if [ "$in_dev" -eq 1 ] && [ -n "$d_loc" ]; then
      MEM_DIMMS+=("${d_loc}|${d_size:-Empty}|${d_type:-N/A}|${d_speed:-N/A}|${d_mfr:-N/A}|${d_part:-N/A}")
    fi
  else
    MEM_DIMM_STATUS="unavailable (requires root or passwordless sudo for dmidecode -t 17)"
  fi

  # 5. Storage & Disks
  DISKS=()
  if have lsblk; then
    while IFS='|' read -r name type model tran size rota fstype mount avail use; do
      [ -z "$name" ] && continue
      [ "$type" = "loop" ] && continue
      local r_type="HDD"
      [ "$rota" = "0" ] && r_type="SSD/NVMe"
      model="${model//\\x20/ }"
      [ -z "$model" ] && model="Generic"
      [ -z "$tran" ] && tran="N/A"
      [ -z "$fstype" ] && fstype="none"
      [ -z "$mount" ] && mount="unmounted"
      [ -z "$avail" ] && avail="N/A"
      [ -z "$use" ] && use="N/A"
      DISKS+=("${name}|${type}|${model}|${tran}|${size}|${r_type}|${fstype}|${mount}|${avail}|${use}")
    done < <(lsblk -o NAME,TYPE,MODEL,TRAN,SIZE,ROTA,FSTYPE,MOUNTPOINT,FSAVAIL,FSUSE% -p -n -r 2>/dev/null | tr ' ' '|' || true)
  fi

  DISK_SCHED=()
  for s in /sys/block/*/queue/scheduler; do
    [ -e "$s" ] || continue
    local bdev; bdev="$(basename "$(dirname "$(dirname "$s")")")"
    case "$bdev" in loop*|ram*|zram*) continue ;; esac
    local sched; sched="$(cat "$s" 2>/dev/null || echo "N/A")"
    DISK_SCHED+=("${bdev}|${sched}")
  done

  # SMART health per disk
  SMART_HEALTH=()
  if have smartctl; then
    for dpath in /dev/sd[a-z] /dev/nvme[0-9]n[0-9] /dev/vd[a-z] /dev/hd[a-z]; do
      [ -e "$dpath" ] || continue
      local sm_out; sm_out="$(priv_cmd smartctl -H "$dpath" 2>/dev/null || true)"
      if [ -n "$sm_out" ]; then
        local st; st="$(echo "$sm_out" | grep -iE 'test result:|SMART overall-health' | head -1 | cut -d: -f2- || echo "PASSED")"
        st="$(trim "$st")"
        [ -z "$st" ] && st="Status Available"
        # Check temperature from smartctl -A
        local temp_s; temp_s="$(priv_cmd smartctl -A "$dpath" 2>/dev/null | grep -iE 'temperature|celsius' | head -1 | awk '{print $NF}' || echo "")"
        [ -n "$temp_s" ] && st="${st} (${temp_s}°C)"
        SMART_HEALTH+=("${dpath}|${st}")
      else
        SMART_HEALTH+=("${dpath}|unavailable (permission denied, requires root)")
      fi
    done
  fi

  # 6. GPU & Video
  GPUS=()
  if have lspci; then
    local pci_gpu; pci_gpu="$(lspci -nnk 2>/dev/null | grep -iA3 -E "vga|3d|display" || true)"
    if [ -n "$pci_gpu" ]; then
      local g_slot="" g_name="" g_driver="unknown"
      while IFS= read -r line; do
        if echo "$line" | grep -qE '^[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9a-fA-F]'; then
          if [ -n "$g_slot" ]; then
            GPUS+=("${g_slot}|${g_name}|${g_driver}")
          fi
          g_slot="$(echo "$line" | awk '{print $1}')"
          g_name="$(echo "$line" | cut -d: -f3- | sed 's/^[ \t]*//')"
          g_driver="unknown"
        elif echo "$line" | grep -q 'Kernel driver in use:'; then
          g_driver="$(echo "$line" | cut -d: -f2- | sed 's/^[ \t]*//')"
        fi
      done <<< "$pci_gpu"
      if [ -n "$g_slot" ]; then
        GPUS+=("${g_slot}|${g_name}|${g_driver}")
      fi
    fi
  fi

  GPU_EXTRA_INFO=""
  if have nvidia-smi; then
    local nv; nv="$(nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used,temperature.gpu --format=csv,noheader 2>/dev/null || true)"
    [ -n "$nv" ] && GPU_EXTRA_INFO="NVIDIA: ${nv}"
  elif have rocm-smi; then
    local r_temp; r_temp="$(rocm-smi 2>/dev/null | grep -oE '[0-9]+\.[0-9]+°C' | head -1 || true)"
    [ -n "$r_temp" ] && GPU_EXTRA_INFO="ROCm GPU Temperature: ${r_temp}"
  fi

  # 7. Network Interfaces
  NET_IFACES=()
  for if_path in /sys/class/net/*; do
    [ -e "$if_path" ] || continue
    local if_name; if_name="$(basename "$if_path")"
    [ "$if_name" = "lo" ] && continue
    local is_phys="no"
    [ -d "$if_path/device" ] && is_phys="yes"
    local mac; mac="$(cat "$if_path/address" 2>/dev/null || echo "unknown")"
    local state; state="$(cat "$if_path/operstate" 2>/dev/null || echo "unknown")"
    local speed; speed="$(cat "$if_path/speed" 2>/dev/null || echo "")"
    [ -n "$speed" ] && [ "$speed" -ge 0 ] 2>/dev/null && speed="${speed} Mbps" || speed="N/A"
    local duplex; duplex="$(cat "$if_path/duplex" 2>/dev/null || echo "N/A")"
    local driver="unknown"
    local fw="N/A"
    local bus="N/A"
    if have ethtool; then
      local eth_info; eth_info="$(ethtool -i "$if_name" 2>/dev/null || true)"
      if [ -n "$eth_info" ]; then
        local d; d="$(echo "$eth_info" | grep '^driver:' | awk '{print $2}')"; [ -n "$d" ] && driver="$d"
        local f; f="$(echo "$eth_info" | grep '^firmware-version:' | cut -d: -f2- | sed 's/^[ \t]*//')"; [ -n "$f" ] && fw="$f"
        local b; b="$(echo "$eth_info" | grep '^bus-info:' | awk '{print $2}')"; [ -n "$b" ] && bus="$b"
      fi
    fi
    if [ "$driver" = "unknown" ] && [ -r "$if_path/device/driver/module" ]; then
      driver="$(basename "$(readlink -f "$if_path/device/driver/module" 2>/dev/null || echo "unknown")")"
    fi
    NET_IFACES+=("${if_name}|${is_phys}|${mac}|${state}|${speed}|${duplex}|${driver}|${fw}|${bus}")
  done

  # 8. PCI & USB Peripherals
  PCI_SUMMARY=()
  if have lspci; then
    while IFS= read -r line; do
      [ -n "$line" ] && PCI_SUMMARY+=("$line")
    done < <(lspci 2>/dev/null | head -30 || true)
  fi

  USB_TREE=""
  if have lsusb; then
    USB_TREE="$(lsusb -t 2>/dev/null || lsusb 2>/dev/null || echo "unavailable")"
  fi

  # 9. Sensors, Temperatures & Battery
  CPU_TEMP="N/A"
  GPU_TEMP="N/A"
  NVME_TEMP="N/A"
  FAN_RPM="N/A"

  # Scan hwmon for sensors
  for h in /sys/class/hwmon/hwmon*; do
    [ -e "$h" ] || continue
    local h_name; h_name="$(cat "$h/name" 2>/dev/null || echo "")"
    case "$h_name" in
      k10temp|coretemp|zenpower|cpu*)
        local t_val; t_val="$(cat "$h"/temp1_input 2>/dev/null || echo 0)"
        [ "$t_val" -gt 0 ] 2>/dev/null && CPU_TEMP="$((t_val / 1000))°C"
        ;;
      amdgpu|nouveau|nvidia*)
        local t_val; t_val="$(cat "$h"/temp1_input 2>/dev/null || echo 0)"
        [ "$t_val" -gt 0 ] 2>/dev/null && GPU_TEMP="$((t_val / 1000))°C"
        ;;
      nvme*)
        local t_val; t_val="$(cat "$h"/temp1_input 2>/dev/null || echo 0)"
        [ "$t_val" -gt 0 ] 2>/dev/null && NVME_TEMP="$((t_val / 1000))°C"
        ;;
    esac
    for f in "$h"/fan*_input; do
      [ -e "$f" ] || continue
      local r; r="$(cat "$f" 2>/dev/null || echo 0)"
      [ "$r" -gt 0 ] 2>/dev/null && FAN_RPM="${r} RPM"
    done
  done

  if [ "$CPU_TEMP" = "N/A" ] && [ -r /sys/class/thermal/thermal_zone0/temp ]; then
    local tz; tz="$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0)"
    [ "$tz" -gt 0 ] 2>/dev/null && CPU_TEMP="$((tz / 1000))°C"
  fi

  # Battery status
  BAT_STATUS="None / Desktop"
  BAT_CAPACITY="N/A"
  BAT_HEALTH="N/A"
  BAT_CYCLES="N/A"
  for b in /sys/class/power_supply/BAT*; do
    [ -e "$b" ] || continue
    BAT_STATUS="$(cat "$b/status" 2>/dev/null || echo "Unknown")"
    BAT_CAPACITY="$(cat "$b/capacity" 2>/dev/null || echo "N/A")%"
    BAT_CYCLES="$(cat "$b/cycle_count" 2>/dev/null || echo "N/A")"

    local c_full=0 c_design=0
    if [ -r "$b/charge_full" ] && [ -r "$b/charge_full_design" ]; then
      c_full="$(cat "$b/charge_full" 2>/dev/null || echo 0)"
      c_design="$(cat "$b/charge_full_design" 2>/dev/null || echo 0)"
    elif [ -r "$b/energy_full" ] && [ -r "$b/energy_full_design" ]; then
      c_full="$(cat "$b/energy_full" 2>/dev/null || echo 0)"
      c_design="$(cat "$b/energy_full_design" 2>/dev/null || echo 0)"
    fi
    if [ "$c_design" -gt 0 ] 2>/dev/null && [ "$c_full" -gt 0 ] 2>/dev/null; then
      local h_pct=$((c_full * 100 / c_design))
      local wear=0
      [ "$h_pct" -lt 100 ] && wear=$((100 - h_pct))
      BAT_HEALTH="${h_pct}% (Wear: ${wear}%)"
    fi
    break
  done
}

# --- renderer: CLI (default) ---------------------------------------------
render_cli() {
  banner
  hd "System Host & Virtualization"
  info "Hostname        : ${C_BOLD}${HOST_NAME}${C_RESET}"
  info "Operating System: ${OS_PRETTY}"
  info "Kernel Version  : ${KERNEL_VER} (${ARCH})"
  info "Uptime / Load   : ${UPTIME} | Load avg: ${LOAD_AVG}"
  if [ "$VIRT_TYPE" = "bare-metal" ]; then
    ok   "Environment     : ${C_GREEN}Bare-metal Hardware (no hypervisor detected)${C_RESET}"
  else
    warn "Environment     : ${C_YELLOW}Virtual Machine / Container (${VIRT_TYPE})${C_RESET}"
  fi

  hd "Motherboard & Firmware / BIOS"
  info "Manufacturer    : ${SYS_VENDOR} (${BOARD_VENDOR})"
  info "Board Model     : ${C_BOLD}${BOARD_NAME}${C_RESET} (rev ${BOARD_VERSION})"
  info "Chassis Type    : ${CHASSIS}"
  info "BIOS/UEFI Vendor: ${BIOS_VENDOR}"
  info "BIOS Version    : ${BIOS_VERSION} (Released: ${BIOS_DATE})"
  info "Boot Mode       : ${C_BOLD}${BOOT_MODE}${C_RESET}"
  [ "$SECURE_BOOT" != "unavailable" ] && info "Secure Boot     : ${SECURE_BOOT}"

  hd "CPU Architecture & Specifications"
  info "Processor Model : ${C_BOLD}${C_CYAN}${CPU_MODEL}${C_RESET}"
  info "Vendor & Micro  : ${CPU_VENDOR} (Family ${CPU_FAMILY}, Model ${CPU_MODEL_NUM}, Stepping ${CPU_STEPPING})"
  info "Topology        : ${C_BOLD}${CPU_SOCKETS} Socket(s) · ${CPU_CORES} Core(s) · ${CPU_THREADS} Thread(s)${C_RESET}"
  info "Frequencies     : Current: ${CPU_FREQ_CUR} | Min: ${CPU_FREQ_MIN} | Max: ${CPU_FREQ_MAX}"
  info "Governor        : ${CPU_GOVERNOR}"
  info "Cache Structure : L1d: ${CACHE_L1D} | L1i: ${CACHE_L1I} | L2: ${CACHE_L2} | L3: ${CACHE_L3}"
  info "Hardware Virt   : ${VIRT_FLAGS} (Nested: ${NESTED_VIRT})"

  if [ "${#CPU_VULNS[@]}" -gt 0 ]; then
    hr
    info "CPU Vulnerability Mitigations (${#CPU_VULNS[@]} checked):"
    for v in "${CPU_VULNS[@]}"; do
      IFS='|' read -r vname vstatus <<< "$v"
      if echo "$vstatus" | grep -qi -E 'not affected|mitigation'; then
        printf "    %b✓%b %-26s: %s\n" "${C_GREEN}" "${C_RESET}" "$vname" "$vstatus" >&2
      else
        printf "    %b!%b %-26s: %s\n" "${C_YELLOW}" "${C_RESET}" "$vname" "$vstatus" >&2
      fi
    done
  fi

  hd "Memory & Physical DIMM Slots"
  info "RAM Usage       : ${C_BOLD}${MEM_USED}${C_RESET} used / ${C_BOLD}${MEM_TOTAL}${C_RESET} total (Available: ${MEM_AVAIL}, Free: ${MEM_FREE})"
  info "Buffer / Cache  : Buffers: ${MEM_BUFFERS} | Cached: ${MEM_CACHED}"
  info "Swap Memory     : ${SWAP_USED} used / ${SWAP_TOTAL} total (Free: ${SWAP_FREE})"
  if [ "${#MEM_DIMMS[@]}" -gt 0 ]; then
    hr
    info "Physical DIMM Modules (${#MEM_DIMMS[@]} slots):"
    for d in "${MEM_DIMMS[@]}"; do
      IFS='|' read -r d_loc d_size d_type d_speed d_mfr d_part <<< "$d"
      printf "    %b•%b %-12s: %-10s %-8s %-12s %-12s (Part: %s)\n" \
        "${C_CYAN}" "${C_RESET}" "$d_loc" "$d_size" "$d_type" "$d_speed" "$d_mfr" "$d_part" >&2
    done
  else
    info "DIMM Modules    : ${MEM_DIMM_STATUS}"
  fi

  hd "Storage, Block Devices & SMART Health"
  if [ "${#DISKS[@]}" -gt 0 ]; then
    printf "    %b%-18s %-6s %-18s %-6s %-8s %-8s %-8s %-14s %-8s%b\n" \
      "${C_BOLD}" "DEVICE" "TYPE" "MODEL" "TRAN" "SIZE" "ROTA" "FSTYPE" "MOUNT" "USAGE" "${C_RESET}" >&2
    for d in "${DISKS[@]}"; do
      IFS='|' read -r d_name d_type d_model d_tran d_size d_rota d_fstype d_mount d_avail d_use <<< "$d"
      printf "    %-18s %-6s %-18s %-6s %-8s %-8s %-8s %-14s %-8s\n" \
        "$d_name" "$d_type" "${d_model:0:18}" "$d_tran" "$d_size" "$d_rota" "$d_fstype" "${d_mount:0:14}" "$d_use" >&2
    done
  else
    warn "No block devices found via lsblk."
  fi

  if [ "${#DISK_SCHED[@]}" -gt 0 ]; then
    hr
    info "I/O Schedulers:"
    for s in "${DISK_SCHED[@]}"; do
      IFS='|' read -r bname bsched <<< "$s"
      printf "    %-12s: %s\n" "$bname" "$bsched" >&2
    done
  fi

  if [ "${#SMART_HEALTH[@]}" -gt 0 ]; then
    hr
    info "SMART Status & Health:"
    for sm in "${SMART_HEALTH[@]}"; do
      IFS='|' read -r sm_dev sm_st <<< "$sm"
      if echo "$sm_st" | grep -qi -E 'passed|ok'; then
        ok "${sm_dev}: ${sm_st}"
      else
        warn "${sm_dev}: ${sm_st}"
      fi
    done
  fi

  hd "Graphics / GPU"
  if [ "${#GPUS[@]}" -gt 0 ]; then
    for g in "${GPUS[@]}"; do
      IFS='|' read -r g_slot g_name g_drv <<< "$g"
      info "PCI ${g_slot}: ${C_BOLD}${g_name}${C_RESET} (driver: ${C_CYAN}${g_drv}${C_RESET})"
    done
    [ -n "$GPU_EXTRA_INFO" ] && info "Extra GPU Info  : ${GPU_EXTRA_INFO}"
  else
    info "No dedicated or integrated GPU detected via lspci."
  fi

  hd "Network Interfaces (NIC)"
  if [ "${#NET_IFACES[@]}" -gt 0 ]; then
    for n in "${NET_IFACES[@]}"; do
      IFS='|' read -r if_name is_phys mac state speed duplex driver fw bus <<< "$n"
      local color="${C_GREEN}"
      [ "$state" != "up" ] && color="${C_DIM}"
      info "Interface ${C_BOLD}${if_name}${C_RESET} [${color}${state}${C_RESET}]: MAC ${mac} | Speed: ${speed} (${duplex})"
      printf "      Physical: %s | Driver: %s (FW: %s) | Bus: %s\n" "$is_phys" "$driver" "$fw" "$bus" >&2
    done
  else
    warn "No network interfaces found."
  fi

  hd "Thermal, Fan Sensors & Battery"
  info "CPU Temperature : ${C_BOLD}${CPU_TEMP}${C_RESET}"
  info "GPU Temperature : ${C_BOLD}${GPU_TEMP}${C_RESET}"
  info "NVMe Temperature: ${C_BOLD}${NVME_TEMP}${C_RESET}"
  info "Fan Speed       : ${C_BOLD}${FAN_RPM}${C_RESET}"
  if [ "$BAT_STATUS" != "None / Desktop" ]; then
    info "Battery Status  : ${BAT_STATUS} (${BAT_CAPACITY})"
    info "Battery Health  : ${BAT_HEALTH} | Cycles: ${BAT_CYCLES}"
  fi

  hd "PCI Peripherals Summary"
  if [ "${#PCI_SUMMARY[@]}" -gt 0 ]; then
    for p in "${PCI_SUMMARY[@]}"; do
      printf "    %b•%b %s\n" "${C_CYAN}" "${C_RESET}" "$p" >&2
    done
  else
    info "No PCI devices detected."
  fi

  hd "USB Peripherals Tree"
  if [ -n "$USB_TREE" ] && [ "$USB_TREE" != "unavailable" ]; then
    echo "$USB_TREE" | head -25 >&2
  else
    info "No USB controller or devices detected."
  fi

  printf "\n%b✔ Comprehensive hardware audit completed.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
}

# --- renderer: Summary (1-page) ------------------------------------------
render_summary() {
  banner
  hd "Hardware Audit Summary (1-Page)"
  printf "  %-18s: %s (%s)\n" "Host" "$HOST_NAME" "$OS_PRETTY" >&2
  printf "  %-18s: %s (Virtualization: %s)\n" "Kernel & Platform" "$KERNEL_VER" "$VIRT_TYPE" >&2
  printf "  %-18s: %s %s (BIOS: %s %s)\n" "Motherboard" "$BOARD_VENDOR" "$BOARD_NAME" "$BIOS_VENDOR" "$BIOS_VERSION" >&2
  printf "  %-18s: %s (%s Sockets, %s Cores, %s Threads)\n" "Processor" "$CPU_MODEL" "$CPU_SOCKETS" "$CPU_CORES" "$CPU_THREADS" >&2
  printf "  %-18s: Current: %s | Max: %s | Governor: %s\n" "CPU Frequency" "$CPU_FREQ_CUR" "$CPU_FREQ_MAX" "$CPU_GOVERNOR" >&2
  printf "  %-18s: Used: %s / Total: %s (Avail: %s)\n" "Memory (RAM)" "$MEM_USED" "$MEM_TOTAL" "$MEM_AVAIL" >&2
  printf "  %-18s: Used: %s / Total: %s\n" "Swap" "$SWAP_USED" "$SWAP_TOTAL" >&2

  if [ "${#GPUS[@]}" -gt 0 ]; then
    for g in "${GPUS[@]}"; do
      IFS='|' read -r _ g_name g_drv <<< "$g"
      printf "  %-18s: %s [driver: %s]\n" "Graphics (GPU)" "$g_name" "$g_drv" >&2
    done
  fi

  if [ "${#DISKS[@]}" -gt 0 ]; then
    local d_str=""
    for d in "${DISKS[@]}"; do
      IFS='|' read -r d_name d_type d_model _ d_size d_rota _ d_mount _ d_use <<< "$d"
      [ "$d_type" != "disk" ] && [ "$d_mount" = "unmounted" ] && continue
      [ -n "$d_str" ] && d_str="${d_str}, "
      d_str="${d_str}${d_name} (${d_size}, ${d_rota})"
    done
    printf "  %-18s: %s\n" "Storage Devices" "$d_str" >&2
  fi

  if [ "${#NET_IFACES[@]}" -gt 0 ]; then
    local n_str=""
    for n in "${NET_IFACES[@]}"; do
      IFS='|' read -r if_name _ mac state speed _ _ _ _ <<< "$n"
      [ -n "$n_str" ] && n_str="${n_str}, "
      n_str="${n_str}${if_name} [${state}, ${speed}]"
    done
    printf "  %-18s: %s\n" "Network" "$n_str" >&2
  fi

  printf "  %-18s: CPU: %s | GPU: %s | NVMe: %s | Fan: %s\n" "Temperatures" "$CPU_TEMP" "$GPU_TEMP" "$NVME_TEMP" "$FAN_RPM" >&2
  if [ "$BAT_STATUS" != "None / Desktop" ]; then
    printf "  %-18s: %s (%s) | Health: %s\n" "Battery" "$BAT_STATUS" "$BAT_CAPACITY" "$BAT_HEALTH" >&2
  fi
  hr
  printf "\n" >&2
}

# --- renderer: JSON ------------------------------------------------------
render_json() {
  cat <<EOF
{
  "system": {
    "hostname": "$(json_escape "$HOST_NAME")",
    "os": "$(json_escape "$OS_PRETTY")",
    "kernel": "$(json_escape "$KERNEL_VER")",
    "architecture": "$(json_escape "$ARCH")",
    "uptime": "$(json_escape "$UPTIME")",
    "load_average": "$(json_escape "$LOAD_AVG")",
    "virtualization": "$(json_escape "$VIRT_TYPE")"
  },
  "motherboard": {
    "vendor": "$(json_escape "$SYS_VENDOR")",
    "board_vendor": "$(json_escape "$BOARD_VENDOR")",
    "board_name": "$(json_escape "$BOARD_NAME")",
    "board_version": "$(json_escape "$BOARD_VERSION")",
    "bios_vendor": "$(json_escape "$BIOS_VENDOR")",
    "bios_version": "$(json_escape "$BIOS_VERSION")",
    "bios_date": "$(json_escape "$BIOS_DATE")",
    "chassis": "$(json_escape "$CHASSIS")",
    "boot_mode": "$(json_escape "$BOOT_MODE")",
    "secure_boot": "$(json_escape "$SECURE_BOOT")"
  },
  "cpu": {
    "model": "$(json_escape "$CPU_MODEL")",
    "vendor": "$(json_escape "$CPU_VENDOR")",
    "family": "$(json_escape "$CPU_FAMILY")",
    "model_number": "$(json_escape "$CPU_MODEL_NUM")",
    "stepping": "$(json_escape "$CPU_STEPPING")",
    "sockets": "$(json_escape "$CPU_SOCKETS")",
    "cores": "$(json_escape "$CPU_CORES")",
    "threads": "$(json_escape "$CPU_THREADS")",
    "freq_current": "$(json_escape "$CPU_FREQ_CUR")",
    "freq_min": "$(json_escape "$CPU_FREQ_MIN")",
    "freq_max": "$(json_escape "$CPU_FREQ_MAX")",
    "governor": "$(json_escape "$CPU_GOVERNOR")",
    "cache": {
      "l1d": "$(json_escape "$CACHE_L1D")",
      "l1i": "$(json_escape "$CACHE_L1I")",
      "l2": "$(json_escape "$CACHE_L2")",
      "l3": "$(json_escape "$CACHE_L3")"
    },
    "virtualization_flags": "$(json_escape "$VIRT_FLAGS")",
    "nested_virtualization": "$(json_escape "$NESTED_VIRT")",
    "vulnerabilities": [
$(
      local first=1
      for v in "${CPU_VULNS[@]}"; do
        IFS='|' read -r vname vstatus <<< "$v"
        [ "$first" -eq 0 ] && printf ",\n"
        first=0
        printf '      {"vulnerability": "%s", "status": "%s"}' "$(json_escape "$vname")" "$(json_escape "$vstatus")"
      done
)
    ]
  },
  "memory": {
    "ram_total": "$(json_escape "$MEM_TOTAL")",
    "ram_used": "$(json_escape "$MEM_USED")",
    "ram_free": "$(json_escape "$MEM_FREE")",
    "ram_available": "$(json_escape "$MEM_AVAIL")",
    "buffers": "$(json_escape "$MEM_BUFFERS")",
    "cached": "$(json_escape "$MEM_CACHED")",
    "swap_total": "$(json_escape "$SWAP_TOTAL")",
    "swap_used": "$(json_escape "$SWAP_USED")",
    "swap_free": "$(json_escape "$SWAP_FREE")",
    "dimm_status": "$(json_escape "$MEM_DIMM_STATUS")",
    "dimm_slots": [
$(
      local first=1
      for d in "${MEM_DIMMS[@]}"; do
        IFS='|' read -r d_loc d_size d_type d_speed d_mfr d_part <<< "$d"
        [ "$first" -eq 0 ] && printf ",\n"
        first=0
        printf '      {"locator": "%s", "size": "%s", "type": "%s", "speed": "%s", "manufacturer": "%s", "part_number": "%s"}' \
          "$(json_escape "$d_loc")" "$(json_escape "$d_size")" "$(json_escape "$d_type")" "$(json_escape "$d_speed")" "$(json_escape "$d_mfr")" "$(json_escape "$d_part")"
      done
)
    ]
  },
  "storage": {
    "disks": [
$(
      local first=1
      for d in "${DISKS[@]}"; do
        IFS='|' read -r d_name d_type d_model d_tran d_size d_rota d_fstype d_mount d_avail d_use <<< "$d"
        [ "$first" -eq 0 ] && printf ",\n"
        first=0
        printf '      {"name": "%s", "type": "%s", "model": "%s", "transport": "%s", "size": "%s", "rotation": "%s", "filesystem": "%s", "mountpoint": "%s", "available": "%s", "usage": "%s"}' \
          "$(json_escape "$d_name")" "$(json_escape "$d_type")" "$(json_escape "$d_model")" "$(json_escape "$d_tran")" "$(json_escape "$d_size")" "$(json_escape "$d_rota")" "$(json_escape "$d_fstype")" "$(json_escape "$d_mount")" "$(json_escape "$d_avail")" "$(json_escape "$d_use")"
      done
)
    ],
    "schedulers": [
$(
      local first=1
      for s in "${DISK_SCHED[@]}"; do
        IFS='|' read -r bname bsched <<< "$s"
        [ "$first" -eq 0 ] && printf ",\n"
        first=0
        printf '      {"device": "%s", "scheduler": "%s"}' "$(json_escape "$bname")" "$(json_escape "$bsched")"
      done
)
    ],
    "smart": [
$(
      local first=1
      for sm in "${SMART_HEALTH[@]}"; do
        IFS='|' read -r sm_dev sm_st <<< "$sm"
        [ "$first" -eq 0 ] && printf ",\n"
        first=0
        printf '      {"device": "%s", "status": "%s"}' "$(json_escape "$sm_dev")" "$(json_escape "$sm_st")"
      done
)
    ]
  },
  "gpu": {
    "devices": [
$(
      local first=1
      for g in "${GPUS[@]}"; do
        IFS='|' read -r g_slot g_name g_drv <<< "$g"
        [ "$first" -eq 0 ] && printf ",\n"
        first=0
        printf '      {"slot": "%s", "name": "%s", "driver": "%s"}' "$(json_escape "$g_slot")" "$(json_escape "$g_name")" "$(json_escape "$g_drv")"
      done
)
    ],
    "extra_info": "$(json_escape "$GPU_EXTRA_INFO")"
  },
  "network": {
    "interfaces": [
$(
      local first=1
      for n in "${NET_IFACES[@]}"; do
        IFS='|' read -r if_name is_phys mac state speed duplex driver fw bus <<< "$n"
        [ "$first" -eq 0 ] && printf ",\n"
        first=0
        printf '      {"name": "%s", "physical": "%s", "mac": "%s", "state": "%s", "speed": "%s", "duplex": "%s", "driver": "%s", "firmware": "%s", "bus": "%s"}' \
          "$(json_escape "$if_name")" "$(json_escape "$is_phys")" "$(json_escape "$mac")" "$(json_escape "$state")" "$(json_escape "$speed")" "$(json_escape "$duplex")" "$(json_escape "$driver")" "$(json_escape "$fw")" "$(json_escape "$bus")"
      done
)
    ]
  },
  "peripherals": {
    "pci_devices": [
$(
      local first=1
      for p in "${PCI_SUMMARY[@]}"; do
        [ "$first" -eq 0 ] && printf ",\n"
        first=0
        printf '      "%s"' "$(json_escape "$p")"
      done
)
    ],
    "usb_tree": "$(json_escape "$USB_TREE")"
  },
  "sensors": {
    "cpu_temp": "$(json_escape "$CPU_TEMP")",
    "gpu_temp": "$(json_escape "$GPU_TEMP")",
    "nvme_temp": "$(json_escape "$NVME_TEMP")",
    "fan_speed": "$(json_escape "$FAN_RPM")",
    "battery": {
      "status": "$(json_escape "$BAT_STATUS")",
      "capacity": "$(json_escape "$BAT_CAPACITY")",
      "health": "$(json_escape "$BAT_HEALTH")",
      "cycles": "$(json_escape "$BAT_CYCLES")"
    }
  }
}
EOF
}

# --- renderer: Markdown --------------------------------------------------
render_markdown() {
  cat <<EOF
# Hardware Audit Report

- **Host**: \`${HOST_NAME}\` (\`${OS_PRETTY}\`)
- **Kernel**: \`${KERNEL_VER}\` (\`${ARCH}\`)
- **Environment**: \`${VIRT_TYPE}\`
- **Uptime**: \`${UPTIME}\` (Load: \`${LOAD_AVG}\`)

## Motherboard & BIOS
| Component | Details |
|---|---|
| Vendor | ${SYS_VENDOR} (${BOARD_VENDOR}) |
| Board Model | ${BOARD_NAME} (rev ${BOARD_VERSION}) |
| Chassis | ${CHASSIS} |
| BIOS Vendor & Version | ${BIOS_VENDOR} ${BIOS_VERSION} (${BIOS_DATE}) |
| Boot Mode | ${BOOT_MODE} (Secure Boot: ${SECURE_BOOT}) |

## CPU Specifications
- **Model**: ${CPU_MODEL}
- **Vendor & Family**: ${CPU_VENDOR} (Family ${CPU_FAMILY}, Model ${CPU_MODEL_NUM}, Stepping ${CPU_STEPPING})
- **Topology**: ${CPU_SOCKETS} Socket(s), ${CPU_CORES} Core(s), ${CPU_THREADS} Thread(s)
- **Frequencies**: Current: \`${CPU_FREQ_CUR}\` | Min: \`${CPU_FREQ_MIN}\` | Max: \`${CPU_FREQ_MAX}\`
- **Governor**: \`${CPU_GOVERNOR}\`
- **Caches**: L1d: \`${CACHE_L1D}\`, L1i: \`${CACHE_L1I}\`, L2: \`${CACHE_L2}\`, L3: \`${CACHE_L3}\`
- **Virtualization**: ${VIRT_FLAGS} (Nested: ${NESTED_VIRT})

## Memory (RAM)
- **RAM Total**: ${MEM_TOTAL} (Used: ${MEM_USED}, Free: ${MEM_FREE}, Available: ${MEM_AVAIL})
- **Buffers / Cached**: ${MEM_BUFFERS} buffers, ${MEM_CACHED} cached
- **Swap**: ${SWAP_USED} used / ${SWAP_TOTAL} total

EOF

  if [ "${#MEM_DIMMS[@]}" -gt 0 ]; then
    cat <<EOF
### Physical DIMM Modules
| Slot | Size | Type | Speed | Manufacturer | Part Number |
|---|---|---|---|---|---|
EOF
    for d in "${MEM_DIMMS[@]}"; do
      IFS='|' read -r d_loc d_size d_type d_speed d_mfr d_part <<< "$d"
      printf "| %s | %s | %s | %s | %s | %s |\n" "$d_loc" "$d_size" "$d_type" "$d_speed" "$d_mfr" "$d_part"
    done
    printf "\n"
  fi

  cat <<EOF
## Storage Devices
| Device | Type | Model | Transport | Size | Rotation | Filesystem | Mountpoint | Usage |
|---|---|---|---|---|---|---|---|---|
EOF
  for d in "${DISKS[@]}"; do
    IFS='|' read -r d_name d_type d_model d_tran d_size d_rota d_fstype d_mount d_avail d_use <<< "$d"
    printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s |\n" \
      "$d_name" "$d_type" "$d_model" "$d_tran" "$d_size" "$d_rota" "$d_fstype" "$d_mount" "$d_use"
  done

  cat <<EOF

## Graphics (GPU)
EOF
  if [ "${#GPUS[@]}" -gt 0 ]; then
    for g in "${GPUS[@]}"; do
      IFS='|' read -r g_slot g_name g_drv <<< "$g"
      printf -- "- **%s** (%s) — driver: \`%s\`\n" "$g_name" "$g_slot" "$g_drv"
    done
    [ -n "$GPU_EXTRA_INFO" ] && printf -- "- %s\n" "$GPU_EXTRA_INFO"
  else
    printf "_No GPU detected._\n"
  fi

  cat <<EOF

## Network Interfaces
| Interface | Physical | MAC Address | State | Speed | Duplex | Driver | Firmware |
|---|---|---|---|---|---|---|---|
EOF
  for n in "${NET_IFACES[@]}"; do
    IFS='|' read -r if_name is_phys mac state speed duplex driver fw bus <<< "$n"
    printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n" \
      "$if_name" "$is_phys" "$mac" "$state" "$speed" "$duplex" "$driver" "$fw"
  done

  cat <<EOF

## Sensors & Power
- **CPU Temp**: ${CPU_TEMP}
- **GPU Temp**: ${GPU_TEMP}
- **NVMe Temp**: ${NVME_TEMP}
- **Fan**: ${FAN_RPM}
- **Battery**: ${BAT_STATUS} (${BAT_CAPACITY}) — Health: ${BAT_HEALTH}, Cycles: ${BAT_CYCLES}

## PCI Peripherals Summary
\`\`\`text
EOF
  if [ "${#PCI_SUMMARY[@]}" -gt 0 ]; then
    for p in "${PCI_SUMMARY[@]}"; do
      printf "%s\n" "$p"
    done
  fi
  cat <<EOF
\`\`\`
EOF
}

# --- main ----------------------------------------------------------------
MODE_ARG="${1:-}"
case "$MODE_ARG" in
  -h|--help)
    printf "Usage: %s [OPTION]\n\n" "$0"
    printf "Comprehensive hardware audit & system specifications inspector.\n\n"
    printf "Options:\n"
    printf "  (no option)       Run full interactive colored CLI audit\n"
    printf "  -s, --summary     Display a concise 1-page summary\n"
    printf "  -j, --json        Output clean structured JSON for automation\n"
    printf "  -m, --markdown    Output documentation-ready Markdown format\n"
    printf "  -h, --help        Show this help message\n"
    exit 0
    ;;
  -s|--summary)
    collect_all
    render_summary
    ;;
  -j|--json)
    collect_all
    render_json
    ;;
  -m|--markdown)
    collect_all
    render_markdown
    ;;
  "")
    collect_all
    render_cli
    ;;
  *)
    printf "Unknown option: %s\n" "$MODE_ARG" >&2
    printf "Usage: %s [--summary|-s|--json|-j|--markdown|-m|--help|-h]\n" "$0" >&2
    exit 2
    ;;
esac
