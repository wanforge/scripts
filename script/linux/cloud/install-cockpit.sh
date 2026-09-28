#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-cockpit.sh — Install, optimize, and manage Cockpit Web Console.
#
# Features:
#   - Interactive full setup preset & granular modular component selection
#   - Core Cockpit Web Console + socket activation
#   - Full plugin suite:
#       • cockpit-networkmanager (Networking, IP, DNS, Bridges, VLANs)
#       • cockpit-storaged (Disks, LVM, RAID, NFS, SMART partition manager)
#       • cockpit-sosreport (System diagnostic & support report generator)
#       • cockpit-pcp (Performance Co-Pilot historical metrics graphing)
#       • cockpit-machines (KVM / QEMU / libvirt Virtual Machines)
#       • cockpit-podman (Podman containers & images)
#   - Optimized PCP Logger (pmcd, pmlogger, pmlogconf complete metrics, daily rotation)
#   - Persistent systemd journald log storage for complete log history in Cockpit
#   - Reverse Proxy config wizard (/etc/cockpit/cockpit.conf: AllowOrigins, Origins, ProtocolHeader, AllowUnencrypted)
#   - Firewall port 9090 management (UFW & Firewalld support)
#   - Live health check & plugin inspection audit
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/cloud/install-cockpit.sh | bash
#   ./install-cockpit.sh status
#   ./install-cockpit.sh proxy [domain]
#   ./install-cockpit.sh optimize-logger
#   ./install-cockpit.sh install
#   ./install-cockpit.sh --uninstall
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-cockpit"

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

COCKPIT_CONF_DIR="/etc/cockpit"
COCKPIT_CONF="${COCKPIT_CONF_DIR}/cockpit.conf"

detect_pm() {
  for pm in apt-get dnf yum; do
    command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return 0; };
  done
  return 1
}

svc_enable_start() {
  local s="$1"
  if command -v systemctl >/dev/null 2>&1; then
    run ${SUDO} systemctl enable "$s" >/dev/null 2>&1 || true
    run ${SUDO} systemctl start "$s" || true
  fi
}

# --- Action: Status & Audit -----------------------------------------------
a_status() {
  hd "Cockpit Web Console & Metrics Logger Status"

  if ! command -v cockpit-ws >/dev/null 2>&1 && [ ! -d /usr/share/cockpit ]; then
    warn "Cockpit is not installed on this system."
    info "Run the installer to set up Cockpit and monitoring plugins."
    return 1
  fi

  # Service status
  local socket_st="inactive"
  local svc_st="inactive"
  if command -v systemctl >/dev/null 2>&1; then
    socket_st="$(systemctl is-active cockpit.socket 2>/dev/null || true)"
    [ -z "${socket_st}" ] && socket_st="inactive"
    svc_st="$(systemctl is-active cockpit 2>/dev/null || true)"
    [ -z "${svc_st}" ] && svc_st="inactive"
  fi

  printf "\n%bCockpit Services:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  if [ "${socket_st}" = "active" ]; then
    ok "cockpit.socket  : Active (Listening on port 9090)"
  else
    warn "cockpit.socket  : ${socket_st}"
  fi
  info "cockpit.service : ${svc_st}"

  # Installed plugins audit
  printf "\n%bInstalled Cockpit Plugins:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  local plugins_found=0
  for p_dir in /usr/share/cockpit/*; do
    [ -d "${p_dir}" ] || continue
    local p_name; p_name="$(basename "${p_dir}")"
    [ "${p_name}" = "branding" ] || [ "${p_name}" = "static" ] && continue
    printf "  • %b%-22s%b : %bInstalled%b\n" "${C_BOLD}" "${p_name}" "${C_RESET}" "${C_GREEN}" "${C_RESET}"
    plugins_found=$(( plugins_found + 1 ))
  done
  [ "${plugins_found}" -eq 0 ] && info "  No add-on plugins detected in /usr/share/cockpit."

  # Performance Co-Pilot (PCP) Logger status
  printf "\n%bPerformance Metrics Logger (PCP):%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  if command -v systemctl >/dev/null 2>&1; then
    local pmcd_st; pmcd_st="$(systemctl is-active pmcd 2>/dev/null || true)"
    [ -z "${pmcd_st}" ] && pmcd_st="inactive"
    local pmlog_st; pmlog_st="$(systemctl is-active pmlogger 2>/dev/null || true)"
    [ -z "${pmlog_st}" ] && pmlog_st="inactive"
    local timer_daily; timer_daily="$(systemctl is-active pmlogger_daily.timer 2>/dev/null || true)"
    [ -z "${timer_daily}" ] && timer_daily="inactive"

    if [ "${pmcd_st}" = "active" ]; then
      ok "pmcd service     : Active (Collector daemon live)"
    else
      warn "pmcd service     : ${pmcd_st} (Collector daemon stopped)"
    fi

    if [ "${pmlog_st}" = "active" ]; then
      ok "pmlogger service : Active (Recording performance archives)"
    else
      warn "pmlogger service : ${pmlog_st} (Historical metrics recording stopped)"
    fi

    info "daily rotation   : ${timer_daily} (pmlogger_daily.timer)"

    if [ -d /var/log/pcp/pmlogger ]; then
      local log_size; log_size="$(du -sh /var/log/pcp/pmlogger 2>/dev/null | awk '{print $1}' || echo '0B')"
      info "PCP archive size : ${log_size} in /var/log/pcp/pmlogger"
    fi
  fi

  # Reverse Proxy Config
  printf "\n%bReverse Proxy Configuration:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  if [ -f "${COCKPIT_CONF}" ]; then
    ok "Found ${COCKPIT_CONF}:"
    sed 's/^/    /' "${COCKPIT_CONF}"
  else
    info "No ${COCKPIT_CONF} found (Cockpit running with default standalone config)."
  fi

  # Port check
  printf "\n%bPort 9090 Listener:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  if command -v ss >/dev/null 2>&1; then
    local p9090; p9090="$(ss -tlnp 2>/dev/null | grep ':9090' || true)"
    if [ -n "${p9090}" ]; then
      ok "Port 9090 listening: ${p9090}"
    else
      info "Port 9090 not active (socket will open when accessed or started)."
    fi
  fi
  printf "\n"
}

# --- Action: Configure Reverse Proxy --------------------------------------
a_configure_proxy() {
  hd "Configure Cockpit Reverse Proxy"

  local domain="${1:-}"
  if [ -z "${domain}" ]; then
    domain="$(ask "Enter your reverse proxy domain (e.g. cockpit.domain.com):" "")"
  fi

  domain="$(echo "${domain}" | sed -E 's|^https?://||; s|/.*$||; s/^[[:space:]]+//; s/[[:space:]]+$//')"
  if [ -z "${domain}" ]; then
    warn "No domain provided. Skipping reverse proxy configuration."
    return 0
  fi

  warn "AllowUnencrypted = true allows reverse proxy SSL termination (Nginx, CloudPanel, Caddy)."
  run ${SUDO} mkdir -p "${COCKPIT_CONF_DIR}"

  local tmp_conf; tmp_conf="$(mktemp)"
  cat > "${tmp_conf}" <<EOF
[WebService]
Origins = https://${domain} http://${domain} http://127.0.0.1:9090
AllowOrigins = https://${domain} ${domain}
ProtocolHeader = X-Forwarded-Proto
AllowUnencrypted = true
EOF

  if [ -f "${COCKPIT_CONF}" ]; then
    local ts; ts="$(date +%Y%m%d_%H%M%S)"
    sub "Backing up existing ${COCKPIT_CONF} to ${COCKPIT_CONF}.bak.${ts}..."
    run ${SUDO} cp -f "${COCKPIT_CONF}" "${COCKPIT_CONF}.bak.${ts}"
  fi

  sub "Writing ${COCKPIT_CONF}..."
  run ${SUDO} cp -f "${tmp_conf}" "${COCKPIT_CONF}"
  run ${SUDO} chmod 644 "${COCKPIT_CONF}"
  rm -f "${tmp_conf}"

  sub "Restarting Cockpit socket & service to apply proxy configuration..."
  if command -v systemctl >/dev/null 2>&1; then
    run ${SUDO} systemctl restart cockpit.socket 2>/dev/null || true
    run ${SUDO} systemctl restart cockpit 2>/dev/null || true
  fi

  ok "Reverse proxy configured successfully for domain: https://${domain}"
}

# --- Action: Optimize PCP Metrics Logger ----------------------------------
a_optimize_logger() {
  hd "Optimize PCP Metrics Logger (Complete Historical Metrics)"

  local pm; pm="$(detect_pm)" || { err "No supported package manager found."; return 1; }

  sub "Ensuring PCP packages (pcp, cockpit-pcp) are installed..."
  case "${pm}" in
    apt-get)
      run ${SUDO} apt-get update
      run ${SUDO} apt-get install -y pcp cockpit-pcp
      ;;
    dnf|yum)
      run ${SUDO} "${pm}" install -y pcp cockpit-pcp
      ;;
  esac

  sub "Configuring metric collection (non-interactive)..."
  # Remove any leftover temporary file from previous interactive prompts
  run ${SUDO} rm -f /var/lib/pcp/config/pmlogger/config.default.new 2>/dev/null || true

  # If config.default is missing, generate it non-interactively using -c
  if [ ! -f /var/lib/pcp/config/pmlogger/config.default ] || [ ! -s /var/lib/pcp/config/pmlogger/config.default ]; then
    if command -v pmlogconf >/dev/null 2>&1; then
      run ${SUDO} mkdir -p /var/lib/pcp/config/pmlogger
      run ${SUDO} pmlogconf -c /var/lib/pcp/config/pmlogger/config.default 2>/dev/null || true
    fi
  fi
  ok "Metric configuration verified."

  # Ensure control.d/local has canonical valid PCP control syntax ($version=1.1 and LOCALHOSTNAME)
  if [ -d /etc/pcp/pmlogger/control.d ]; then
    sub "Configuring canonical /etc/pcp/pmlogger/control.d/local..."
    local tmp_ctrl; tmp_ctrl="$(mktemp)"
    cat > "${tmp_ctrl}" <<'EOF'
# PCP archive logging configuration/control
$version=1.1

# local primary pmlogger
LOCALHOSTNAME	y   n	PCP_ARCHIVE_DIR/LOCALHOSTNAME	-r -T24h10m -c config.default -v 100Mb
EOF
    run ${SUDO} cp -f "${tmp_ctrl}" /etc/pcp/pmlogger/control.d/local
    run ${SUDO} chmod 644 /etc/pcp/pmlogger/control.d/local
    rm -f "${tmp_ctrl}"
  fi

  # Ensure archive directories and permissions
  run ${SUDO} mkdir -p /var/log/pcp/pmlogger
  if id pcp >/dev/null 2>&1; then
    run ${SUDO} chown -R pcp:pcp /var/log/pcp /var/lib/pcp 2>/dev/null || true
  fi

  # Ensure persistent systemd journal logging for complete system logs in Cockpit
  sub "Ensuring persistent journald storage for Cockpit Logs..."
  run ${SUDO} mkdir -p /var/log/journal
  if command -v systemd-tmpfiles >/dev/null 2>&1; then
    run ${SUDO} systemd-tmpfiles --create --prefix /var/log/journal 2>/dev/null || true
  fi

  sub "Enabling and starting pmcd (Collector Daemon)..."
  if command -v systemctl >/dev/null 2>&1; then
    run ${SUDO} systemctl enable pmcd >/dev/null 2>&1 || true
    run ${SUDO} systemctl restart pmcd || run ${SUDO} systemctl start pmcd || true
    sleep 2

    sub "Enabling and starting pmlogger (Metrics Logger)..."
    run ${SUDO} systemctl enable pmlogger >/dev/null 2>&1 || true
    if ! run ${SUDO} systemctl restart pmlogger 2>/dev/null; then
      warn "pmlogger restart failed; checking fallback start..."
      run ${SUDO} systemctl start pmlogger 2>/dev/null || warn "pmlogger service failed to start. Run 'journalctl -xeu pmlogger' for details."
    fi

    run ${SUDO} systemctl enable --now pmlogger_daily.timer 2>/dev/null || true
    run ${SUDO} systemctl enable --now pmlogger_check.timer 2>/dev/null || true
  fi

  ok "PCP metrics logger configured. Real-time & historical performance graphs will record completely."
}

# --- Action: Firewall Port 9090 -------------------------------------------
a_firewall_port() {
  hd "Firewall Port 9090 Management"

  info "Note: If Cockpit is accessed strictly through a reverse proxy (e.g. CloudPanel / Nginx / Caddy),"
  info "opening port 9090 externally is NOT required."
  printf "\n"

  if ask_yn "Open port 9090/tcp in the system firewall?" "y"; then
    if command -v ufw >/dev/null 2>&1 && ${SUDO} ufw status 2>/dev/null | grep -qi "Status: active"; then
      run ${SUDO} ufw allow 9090/tcp comment "Cockpit Web Console"
      ok "UFW: Port 9090/tcp opened."
    elif command -v firewall-cmd >/dev/null 2>&1 && ${SUDO} firewall-cmd --state >/dev/null 2>&1; then
      run ${SUDO} firewall-cmd --permanent --add-service=cockpit 2>/dev/null || run ${SUDO} firewall-cmd --permanent --add-port=9090/tcp
      run ${SUDO} firewall-cmd --reload
      ok "Firewalld: Cockpit service / port 9090 opened."
    else
      if command -v ufw >/dev/null 2>&1; then
        run ${SUDO} ufw allow 9090/tcp
        ok "UFW rule added (firewall currently inactive)."
      else
        warn "No active UFW or Firewalld detected. Ensure port 9090 is allowed in your cloud security group if accessing directly."
      fi
    fi
  else
    info "Port 9090 firewall rule skipped."
  fi
}

# --- Action: Full Recommended Installation --------------------------------
a_full_install() {
  hd "Cockpit Full Recommended Suite Installation"

  local pm; pm="$(detect_pm)" || { err "No supported package manager found (apt, dnf, yum)."; return 1; }

  info "This will install:"
  info "  1. Cockpit Web Console (Core + Socket Activation)"
  info "  2. Essential Plugins:"
  info "     • cockpit-networkmanager (Network config, IP, bridges, VLANs)"
  info "     • cockpit-storaged       (Disks, LVM, RAID, NFS, SMART partitions)"
  info "     • cockpit-sosreport      (System diagnostics & health reports)"
  info "     • cockpit-pcp            (Performance metrics historical graphing)"
  info "     • cockpit-machines       (KVM / QEMU virtual machines)"
  info "     • cockpit-podman         (Podman container manager)"
  info "  3. Optimized Performance Metrics Logger (pmcd + pmlogger)"
  info "  4. Reverse Proxy Configuration (/etc/cockpit/cockpit.conf)"
  info "  5. Firewall Configuration (Port 9090/tcp)"
  printf "\n"

  if ! ask_yn "Proceed with full recommended Cockpit installation?" "y"; then
    info "Installation cancelled."; return 0
  fi

  sub "Updating package lists..."
  case "${pm}" in
    apt-get) run ${SUDO} apt-get update ;;
  esac

  sub "Installing Cockpit core and recommended plugin suite..."
  local core_pkgs="cockpit cockpit-networkmanager cockpit-storaged cockpit-sosreport cockpit-pcp"
  local extra_pkgs="cockpit-machines cockpit-podman"

  case "${pm}" in
    apt-get)
      run ${SUDO} apt-get install -y ${core_pkgs}
      # Attempt extra pkgs (machines & podman may have release variations)
      run ${SUDO} apt-get install -y ${extra_pkgs} 2>/dev/null || {
        warn "Some container/VM packages could not be installed together; installing available ones individually..."
        for ep in ${extra_pkgs}; do
          run ${SUDO} apt-get install -y "${ep}" 2>/dev/null || info "Package ${ep} not available on this release."
        done
      }
      ;;
    dnf|yum)
      run ${SUDO} "${pm}" install -y ${core_pkgs}
      for ep in ${extra_pkgs}; do
        run ${SUDO} "${pm}" install -y "${ep}" 2>/dev/null || info "Package ${ep} not available."
      done
      ;;
  esac

  sub "Enabling and starting Cockpit socket..."
  svc_enable_start cockpit.socket
  svc_enable_start cockpit

  sub "Optimizing PCP Performance Logger..."
  a_optimize_logger

  printf "\n"
  if ask_yn "Configure Reverse Proxy domain for Cockpit now?" "y"; then
    a_configure_proxy
  fi

  printf "\n"
  a_firewall_port

  printf "\n%b=================================================================%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
  printf "%b✔ COCKPIT FULL SUITE INSTALLED & CONFIGURED SUCCESSFULLY%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
  printf "  • Local Access        : %bhttp://127.0.0.1:9090%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  if [ -f "${COCKPIT_CONF}" ]; then
    local conf_orig; conf_orig="$(grep -E '^[[:space:]]*Origins' "${COCKPIT_CONF}" | head -1 | awk '{print $3}' || echo '')"
    [ -n "${conf_orig}" ] && printf "  • Reverse Proxy URL   : %b%s%b\n" "${C_BOLD}${C_GREEN}" "${conf_orig}" "${C_RESET}"
  fi
  printf "  • Metrics Logger      : %bpmcd & pmlogger active (Complete historical logging)%b\n" "${C_GREEN}" "${C_RESET}"
  printf "%b=================================================================%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
}

# --- Action: Modular Checkbox Installation --------------------------------
a_modular_install() {
  hd "Modular Cockpit Component Selection"

  MENU=(
    "Core|cockpit|Cockpit Web Console: Core service & socket activation"
    "Firewall|ufw-9090|Open port 9090 in system firewall (UFW / Firewalld)"
    "Proxy|cockpit-conf|Reverse-proxy configuration (Origins, AllowOrigins, X-Forwarded-Proto)"
    "Plugins|cockpit-networkmanager|Networking management (Interfaces, IP, DNS, Bridges)"
    "Plugins|cockpit-storaged|Storage management (Disks, LVM, RAID, NFS, SMART)"
    "Plugins|cockpit-sosreport|Diagnostic & SOS support report generator"
    "Plugins|cockpit-pcp|Performance Co-Pilot metrics plugin"
    "Plugins|cockpit-machines|KVM / libvirt Virtual Machines management"
    "Plugins|cockpit-podman|Podman container and image management"
    "Metrics|pmcd-pmlogger|Optimize & enable complete PCP logging (pmcd + pmlogger)"
  )

  checkbox "Select Cockpit components to install & configure:" || { warn "Cancelled."; return 0; }
  [ "${#CHOSEN_KEYS[@]}" -eq 0 ] && { warn "Nothing selected."; return 0; }

  local pm; pm="$(detect_pm)" || { err "No supported package manager found."; return 1; }
  case "${pm}" in apt-get) run ${SUDO} apt-get update ;; esac

  if has_key cockpit; then
    info "Installing Cockpit core..."
    case "${pm}" in
      apt-get) run ${SUDO} apt-get install -y cockpit ;;
      dnf|yum) run ${SUDO} "${pm}" install -y cockpit ;;
    esac
    svc_enable_start cockpit.socket
    svc_enable_start cockpit
    ok "Cockpit core service started."
  fi

  local plugins_to_install=()
  for p in cockpit-networkmanager cockpit-storaged cockpit-sosreport cockpit-pcp cockpit-machines cockpit-podman; do
    if has_key "$p"; then
      plugins_to_install+=("$p")
    fi
  done

  if [ "${#plugins_to_install[@]}" -gt 0 ]; then
    info "Installing selected plugins: ${plugins_to_install[*]}..."
    case "${pm}" in
      apt-get)
        for p in "${plugins_to_install[@]}"; do
          run ${SUDO} apt-get install -y "$p" 2>/dev/null || warn "Plugin $p failed or unavailable."
        done
        ;;
      dnf|yum)
        for p in "${plugins_to_install[@]}"; do
          run ${SUDO} "${pm}" install -y "$p" 2>/dev/null || warn "Plugin $p failed or unavailable."
        done
        ;;
    esac
    ok "Selected plugins installed."
  fi

  if has_key pmcd-pmlogger; then
    a_optimize_logger
  fi

  if has_key cockpit-conf; then
    a_configure_proxy
  fi

  if has_key ufw-9090; then
    a_firewall_port
  fi

  ok "Modular Cockpit configuration completed."
}

# --- Action: Uninstall ----------------------------------------------------
a_uninstall() {
  hd "Uninstall Cockpit & Plugins"
  warn "This will stop and remove Cockpit, its plugins, and optionally configuration files."
  local yn; yn="$(ask "Are you sure you want to remove Cockpit? [y/N]:" "n")"
  case "${yn}" in y|Y|yes) ;; *) info "Cancelled."; return 0 ;; esac

  local pm; pm="$(detect_pm)" || { err "No supported package manager found."; return 1; }

  sub "Stopping Cockpit and PCP services..."
  run ${SUDO} systemctl stop cockpit.socket cockpit pmcd pmlogger 2>/dev/null || true
  run ${SUDO} systemctl disable cockpit.socket cockpit pmcd pmlogger 2>/dev/null || true

  sub "Removing Cockpit packages via ${pm}..."
  local pkgs="cockpit cockpit-networkmanager cockpit-storaged cockpit-sosreport cockpit-pcp cockpit-machines cockpit-podman"
  case "${pm}" in
    apt-get)
      run ${SUDO} apt-get purge -y ${pkgs} 2>/dev/null || true
      run ${SUDO} apt-get autoremove -y 2>/dev/null || true
      ;;
    dnf|yum)
      run ${SUDO} "${pm}" -y remove ${pkgs} 2>/dev/null || true
      ;;
  esac

  if ask_yn "Delete Cockpit configuration files (/etc/cockpit)?" "n"; then
    run ${SUDO} rm -rf "${COCKPIT_CONF_DIR}"
  fi

  if ask_yn "Remove firewall rule for port 9090/tcp?" "y"; then
    if command -v ufw >/dev/null 2>&1; then
      run ${SUDO} ufw delete allow 9090/tcp 2>/dev/null || true
    elif command -v firewall-cmd >/dev/null 2>&1; then
      run ${SUDO} firewall-cmd --permanent --remove-service=cockpit 2>/dev/null || true
      run ${SUDO} firewall-cmd --permanent --remove-port=9090/tcp 2>/dev/null || true
      run ${SUDO} firewall-cmd --reload 2>/dev/null || true
    fi
  fi

  ok "Cockpit and associated packages uninstalled."
}

# --- CLI Dispatch ---------------------------------------------------------
case "${1:-}" in
  status|audit)
    a_status; exit $?
    ;;
  proxy|conf|reverse-proxy)
    a_configure_proxy "${2:-}"; exit $?
    ;;
  optimize-logger|logger|pcp)
    a_optimize_logger; exit $?
    ;;
  install)
    a_full_install; exit $?
    ;;
  --uninstall|uninstall)
    a_uninstall; exit $?
    ;;
esac

# --- Interactive Main Menu ------------------------------------------------
banner
MENU=(
  "Full|full|Recommended Full Suite (Core + All Plugins + Proxy + Optimized Logger + UFW)"
  "Modular|modular|Modular Selection (Customize plugins, firewall, and components)"
  "Proxy|proxy|Configure Reverse Proxy (/etc/cockpit/cockpit.conf: Origins, SSL)"
  "Logger|logger|Optimize PCP Metrics Logger (pmcd, pmlogger complete archive capture)"
  "Status|status|Audit Cockpit Status, Active Plugins & Metrics Logger"
  "Firewall|firewall|Manage Firewall Port (9090/tcp in UFW / Firewalld)"
  "Remove|uninstall|Uninstall Cockpit Web Console & Plugins"
)

while true; do
  if menu_select "Cockpit Web Console & Monitoring Toolkit:"; then
    case "${MENU_KEY}" in
      full)      a_full_install; pause ;;
      modular)   a_modular_install; pause ;;
      proxy)     a_configure_proxy; pause ;;
      logger)    a_optimize_logger; pause ;;
      status)    a_status; pause ;;
      firewall)  a_firewall_port; pause ;;
      uninstall) a_uninstall; pause ;;
      *) break ;;
    esac
  else
    break
  fi
done

ok "Script install-cockpit completed."
