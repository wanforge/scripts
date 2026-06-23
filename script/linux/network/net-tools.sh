#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# net-tools.sh — network toolkit: local/public IP, gateway, DNS, ports,
# connections, port checks, speedtest, ping/traceroute/dig/whois, and more.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/network/net-tools.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="net-tools"

# --- shared library: banner, colors, logging, prompts, menus -------------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load
wf_log_init

pm_install() {
  local pm; for pm in apt-get dnf yum pacman zypper apk; do command -v "$pm" >/dev/null 2>&1 && break; done
  case "$pm" in
    apt-get) run ${SUDO} apt-get update && run ${SUDO} apt-get install -y "$@" ;;
    dnf) run ${SUDO} dnf -y install "$@" ;; yum) run ${SUDO} yum -y install "$@" ;;
    pacman) run ${SUDO} pacman -S --noconfirm --needed "$@" ;; zypper) run ${SUDO} zypper --non-interactive install "$@" ;;
    apk) run ${SUDO} apk add "$@" ;; *) warn "No package manager found." ;;
  esac
}
have() { command -v "$1" >/dev/null 2>&1; }

# ---- Addresses ----------------------------------------------------------
a_local_ip() {
  hd "Local interfaces & IPs"
  ip -br a 2>/dev/null >&2 || ifconfig -a >&2 || cat /proc/net/dev >&2
  hd "Primary local IPv4"; ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src")print $(i+1)}' >&2 || true
}
a_public_ip() {
  hd "Public IP"
  local v4 v6
  v4="$(curl -fsS --max-time 6 https://api.ipify.org 2>/dev/null || echo '-')"
  v6="$(curl -fsS --max-time 6 https://api6.ipify.org 2>/dev/null || echo '-')"
  printf "IPv4: %s\nIPv6: %s\n" "$v4" "$v6" >&2
  hd "Geo / ISP (ipinfo.io)"; curl -fsS --max-time 6 https://ipinfo.io/json 2>/dev/null >&2 || warn "geo lookup failed"
}
a_gateway() { hd "Routes / default gateway"; ip route 2>/dev/null >&2 || route -n >&2 || true; }
a_dns() {
  hd "DNS resolvers"
  if have resolvectl; then resolvectl status 2>/dev/null | grep -iE 'DNS Servers|Current DNS' >&2 || resolvectl dns >&2
  else grep -E '^nameserver' /etc/resolv.conf >&2 || cat /etc/resolv.conf >&2; fi
}
a_arp() { hd "ARP / neighbours"; ip neigh 2>/dev/null >&2 || arp -a >&2 || true; }

# ---- Ports & connections ------------------------------------------------
a_listening()   { hd "Listening sockets"; ${SUDO} ss -tulpn 2>/dev/null >&2 || ss -tuln >&2 || netstat -tulpn >&2; }
a_established() { hd "Established connections"; ${SUDO} ss -tnp state established 2>/dev/null >&2 || ss -tn >&2; }
a_portcheck_local() {
  local p; p="$(ask "Local port to check:" "")"; [ -n "$p" ] || { err "Port required."; return; }
  if ${SUDO} ss -tulpn 2>/dev/null | grep -qE "[:.]${p}\b"; then ok "Port ${p} is OPEN / listening."; ${SUDO} ss -tulpn 2>/dev/null | grep -E "[:.]${p}\b" >&2
  else warn "Port ${p} is not listening locally."; fi
}
a_portcheck_remote() {
  local h p; h="$(ask_cfg CFG_NT_RHOST "Host:" "")"; p="$(ask_cfg CFG_NT_RPORT "Port:" "")"; [ -n "$h" ] && [ -n "$p" ] || { err "Host and port required."; return; }
  hd "Reach ${h}:${p}"
  if have nc; then nc -zv -w5 "$h" "$p" >&2 2>&1 && ok "Reachable." || warn "Closed/filtered."
  elif timeout 5 bash -c "echo > /dev/tcp/${h}/${p}" 2>/dev/null; then ok "${h}:${p} reachable."
  else warn "${h}:${p} closed/unreachable."; fi
}
a_portscan() {
  local h ports; h="$(ask_cfg CFG_NT_SCAN_HOST "Host to scan:" "127.0.0.1")"
  if have nmap; then
    ports="$(ask_cfg CFG_NT_SCAN_PORTS "Ports/range (e.g. 1-1024 or 22,80,443):" "1-1024")"
    hd "nmap ${h} (${ports})"; nmap -p "${ports}" "${h}" >&2 || true
  else
    hd "Quick scan of common ports on ${h} (nmap not installed)"
    for p in 21 22 25 53 80 110 143 443 3306 5432 6379 8080 8443 9090; do
      if timeout 2 bash -c "echo > /dev/tcp/${h}/${p}" 2>/dev/null; then printf "  open   %s\n" "$p" >&2; fi
    done
    ok "Done (install nmap for full scans)."
  fi
}

# ---- Diagnostics --------------------------------------------------------
a_ping()    { local h; h="$(ask_cfg CFG_NT_PING_HOST "Host to ping:" "1.1.1.1")"; hd "ping ${h}"; ping -c 4 "$h" >&2 || true; }
a_trace()   { local h; h="$(ask_cfg CFG_NT_TRACE_HOST "Host to trace:" "1.1.1.1")"; hd "traceroute ${h}"; if have mtr; then ${SUDO} mtr -rwc 5 "$h" >&2 || true; elif have traceroute; then traceroute "$h" >&2 || true; else warn "Install mtr or traceroute."; fi; }
a_dig()     { local h; h="$(ask_cfg CFG_NT_DIG_HOST "Domain to resolve:" "wanforge.asia")"; hd "DNS lookup ${h}"; if have dig; then dig +short "$h" A "$h" AAAA "$h" MX >&2; dig "$h" >&2 2>&1 | sed -n '/ANSWER SECTION/,/^$/p' >&2; elif have host; then host "$h" >&2; else nslookup "$h" >&2 || warn "Install dnsutils/bind-utils."; fi; }
a_whois()   { local h; h="$(ask_cfg CFG_NT_WHOIS_HOST "Domain/IP for whois:" "")"; [ -n "$h" ] || { err "Required."; return; }; hd "whois ${h}"; if have whois; then whois "$h" >&2 || true; else warn "Install whois."; fi; }
a_http()    { local u; u="$(ask_cfg CFG_NT_HTTP_URL "URL for HTTP headers:" "https://wanforge.asia")"; hd "HTTP headers ${u}"; curl -fsSIL --max-time 10 "$u" >&2 || warn "request failed"; }
a_ifstats() { hd "Interface traffic"; ip -s -h link 2>/dev/null >&2 || ip -s link >&2 || true; }

# ---- Speed --------------------------------------------------------------
a_speedtest() {
  hd "Speed test"
  if have speedtest; then speedtest >&2 || true
  elif have speedtest-cli; then speedtest-cli >&2 || true
  else
    warn "speedtest not installed."
    case "$(ask "Install speedtest-cli now? [Y/n]:" "y")" in n|N|no) return ;; esac
    pm_install speedtest-cli || pip3 install --user speedtest-cli 2>/dev/null || true
    have speedtest-cli && speedtest-cli >&2 || warn "Could not run speedtest."
  fi
}

# ---- Tools --------------------------------------------------------------
a_install() {
  hd "Installing network tools"
  pm_install iproute2 net-tools dnsutils traceroute mtr nmap whois curl speedtest-cli \
    || pm_install bind-utils net-tools traceroute mtr nmap whois curl \
    || warn "Some packages differ per distro; install what you need."
}

# ---- menu (single-select TUI) -------------------------------------------
MENU=(
  "Addresses|local_ip|local interfaces & IPs"
  "Addresses|public_ip|public IP + geo/ISP"
  "Addresses|gateway|routes / default gateway"
  "Addresses|dns|DNS resolvers"
  "Addresses|arp|ARP / neighbours"
  "Ports & connections|listening|listening sockets"
  "Ports & connections|established|established connections"
  "Ports & connections|portcheck_local|check a local port"
  "Ports & connections|portcheck_remote|check a remote host:port"
  "Ports & connections|portscan|scan ports on a host"
  "Diagnostics|ping|ping a host"
  "Diagnostics|trace|traceroute / mtr"
  "Diagnostics|dig|DNS lookup (dig)"
  "Diagnostics|whois|whois lookup"
  "Diagnostics|http|HTTP headers (curl -I)"
  "Diagnostics|ifstats|interface traffic stats"
  "Speed|speedtest|internet speed test"
  "Tools|install|install network tools"
  "Config|clear_cfg|clear saved config (hosts, URLs, ports)"
)

# ---- run ----------------------------------------------------------------
banner
while true; do
  printf "\n" >&2
  menu_select "Network tools:" || break
  case "${MENU_KEY}" in
    local_ip) a_local_ip ;;   public_ip) a_public_ip ;; gateway) a_gateway ;;
    dns) a_dns ;;             arp) a_arp ;;
    listening) a_listening ;; established) a_established ;;
    portcheck_local) a_portcheck_local ;; portcheck_remote) a_portcheck_remote ;; portscan) a_portscan ;;
    ping) a_ping ;;          trace) a_trace ;;          dig) a_dig ;;
    whois) a_whois ;;        http) a_http ;;            ifstats) a_ifstats ;;
    speedtest) a_speedtest ;; install) a_install ;;
    clear_cfg) cfg_clear && ok "Saved config cleared." ;;
  esac
done

printf "\n%b✔ net-tools finished.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
