#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-cloudflared.sh — Cloudflare Tunnel (cloudflared) installer & manager.
# Supports official package repositories (APT, RPM), direct GitHub release binaries,
# Zero Trust service tokens, quick ephemeral tunnels, and multi-ingress config.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/network/install-cloudflared.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-cloudflared"

# --- shared library -------------------------------------------------------
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

have() { command -v "$1" >/dev/null 2>&1; }

# ---- detect architecture -------------------------------------------------
arch_target() {
  local m; m="$(uname -m)"
  case "$m" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armhf)  echo "arm" ;;
    i386|i686)     echo "386" ;;
    *) echo "amd64" ;;
  esac
}

# ---- binary installation -------------------------------------------------
install_binary_direct() {
  local arch target_bin="/usr/local/bin/cloudflared"
  arch="$(arch_target)"
  info "Downloading official cloudflared binary (${arch})..."
  local tmp_bin; tmp_bin="$(mktemp)"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" -o "${tmp_bin}"
  else
    wget -qO "${tmp_bin}" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  fi
  chmod +x "${tmp_bin}"
  run ${SUDO} mv "${tmp_bin}" "${target_bin}"
  ok "cloudflared installed at ${target_bin}"
}

a_install() {
  hd "Install Cloudflare Tunnel (cloudflared)"
  os_detect

  if have cloudflared; then
    local v; v="$(cloudflared --version 2>/dev/null | awk '{print $3}' || echo "installed")"
    info "cloudflared is already installed (version: ${v})."
    local upg; upg="$(ask "Update / reinstall cloudflared? [y/N]:" "n")"
    [[ "$upg" =~ ^[Yy] ]] || return 0
  fi

  local pm; pm="$(detect_pm 2>/dev/null || echo "unknown")"
  case "$pm" in
    apt-get)
      step 1 3 "Configuring Cloudflare APT repository..."
      run ${SUDO} mkdir -p --mode=0755 /usr/share/keyrings
      curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | run ${SUDO} tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
      echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs 2>/dev/null || echo "${OS_CODENAME}") main" | \
        run ${SUDO} tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
      step 2 3 "Installing package..."
      run ${SUDO} apt-get update -y
      if ! run ${SUDO} apt-get install -y cloudflared; then
        warn "APT package install failed; falling back to direct binary download..."
        install_binary_direct
      fi
      ;;
    dnf|yum)
      step 1 2 "Installing RPM repository..."
      run ${SUDO} rpm -ivh https://pkg.cloudflare.com/cloudflared-ascii.repo 2>/dev/null || true
      if ! run ${SUDO} "$pm" -y install cloudflared; then
        warn "RPM package install failed; falling back to direct binary download..."
        install_binary_direct
      fi
      ;;
    pacman)
      step 1 2 "Installing via pacman..."
      run ${SUDO} pacman -S --noconfirm --needed cloudflared || install_binary_direct
      ;;
    *)
      step 1 2 "Installing direct binary from Cloudflare release..."
      install_binary_direct
      ;;
  esac

  if have cloudflared; then
    ok "cloudflared $(cloudflared --version 2>/dev/null | head -n1)"
  else
    err "Installation failed."
    return 1
  fi
}

a_quick_tunnel() {
  have cloudflared || { err "cloudflared is not installed."; return 1; }
  hd "Start Quick Ephemeral Tunnel"
  info "Exposes a local port directly with a trycloudflare.com URL without DNS or account setup."
  local port; port="$(ask "Local port to expose (e.g. 3000, 8080):" "3000")"
  [ -n "$port" ] || { err "Port required."; return 1; }
  info "Starting tunnel on http://localhost:${port}..."
  info "Press Ctrl+C to terminate the tunnel session."
  cloudflared tunnel --url "http://localhost:${port}"
}

a_token_service() {
  have cloudflared || { err "cloudflared is not installed. Please install it first."; return 1; }
  hd "Install Zero Trust Service with Token"
  info "Paste the tunnel token obtained from Cloudflare Zero Trust Dashboard:"
  info "(Networks > Tunnels > Install and run a connector > token)"
  local token; token="$(ask "Tunnel Run Token:" "")"
  [ -n "$token" ] || { err "Token cannot be empty."; return 1; }
  step 1 2 "Registering systemd service with token..."
  run ${SUDO} cloudflared service install "${token}"
  step 2 2 "Starting service..."
  run ${SUDO} systemctl daemon-reload
  run ${SUDO} systemctl enable --now cloudflared
  ok "cloudflared systemd service installed and active."
}

a_ingress_config() {
  hd "Generate Ingress config.yml"
  local cfg_dir="/etc/cloudflared"
  [ "$(id -u)" -eq 0 ] || cfg_dir="${HOME}/.cloudflared"
  mkdir -p "${cfg_dir}"
  local cfg_file="${cfg_dir}/config.yml"
  info "Writing ingress template to ${cfg_file}..."

  local tun_id; tun_id="$(ask "Tunnel UUID (leave empty if using token service):" "")"
  local hostname; hostname="$(ask "Domain / Hostname (e.g. app.example.com):" "app.example.com")"
  local local_svc; local_svc="$(ask "Local Service URL (e.g. http://localhost:3000):" "http://localhost:3000")"

  cat <<EOF | run ${SUDO} tee "${cfg_file}" >/dev/null
${tun_id:+tunnel: ${tun_id}}
${tun_id:+credentials-file: ${cfg_dir}/${tun_id}.json}
transport-protocol: http2

ingress:
  - hostname: ${hostname}
    service: ${local_svc}
    originRequest:
      noTLSVerify: true
  - service: http_status:404
EOF
  ok "Config created at ${cfg_file}"
  cloudflared tunnel ingress validate --config "${cfg_file}" 2>/dev/null && ok "Ingress rules validated successfully." || true
}

a_status() {
  hd "Cloudflare Tunnel Status"
  if have cloudflared; then
    printf "  %bBinary:%b   %s (%s)\n" "${C_GREEN}" "${C_RESET}" "$(command -v cloudflared)" "$(cloudflared --version 2>/dev/null | head -n1)" >&2
  else
    printf "  %bBinary:%b   %bnot installed%b\n" "${C_RED}" "${C_RESET}" "${C_RED}" "${C_RESET}" >&2
  fi
  if have systemctl; then
    printf "  %bService:%b  " "${C_CYAN}" "${C_RESET}" >&2
    if systemctl is-active cloudflared >/dev/null 2>&1; then
      printf "%bactive (running)%b\n" "${C_GREEN}" "${C_RESET}" >&2
    elif systemctl is-enabled cloudflared >/dev/null 2>&1; then
      printf "%benabled (stopped)%b\n" "${C_YELLOW}" "${C_RESET}" >&2
    else
      printf "%binactive / not installed%b\n" "${C_DIM}" "${C_RESET}" >&2
    fi
  fi
  local configs=("/etc/cloudflared/config.yml" "${HOME}/.cloudflared/config.yml")
  for cf in "${configs[@]}"; do
    if [ -f "$cf" ]; then
      printf "  %bConfig:%b   %s (exists)\n" "${C_CYAN}" "${C_RESET}" "$cf" >&2
    fi
  done
  pause
}

a_uninstall() {
  hd "Uninstall Cloudflare Tunnel"
  confirm_critical "stop service and completely remove cloudflared" "uninstall" || return 0
  if have systemctl && systemctl is-active cloudflared >/dev/null 2>&1; then
    run ${SUDO} systemctl stop cloudflared || true
    run ${SUDO} systemctl disable cloudflared || true
  fi
  if have cloudflared; then
    run ${SUDO} cloudflared service uninstall 2>/dev/null || true
  fi
  run ${SUDO} rm -f /usr/local/bin/cloudflared /usr/bin/cloudflared
  ok "cloudflared uninstalled."
}

# ---- main dispatch -------------------------------------------------------
main() {
  banner "Cloudflare Tunnel"
  while true; do
    MENU=(
      "Action|install|Install / update cloudflared binary"
      "Action|quick|Start quick ephemeral tunnel (trycloudflare.com)"
      "Action|token|Install systemd service via Zero Trust token"
      "Action|ingress|Create / edit local ingress config.yml"
      "Action|status|Check tunnel & service status"
      "Action|uninstall|Uninstall cloudflared & service"
    )
    menu_select "Cloudflare Tunnel Manager:" || break
    case "${MENU_KEY}" in
      install)   a_install ;;
      quick)     a_quick_tunnel ;;
      token)     a_token_service ;;
      ingress)   a_ingress_config ;;
      status)    a_status ;;
      uninstall) a_uninstall ;;
      *) break ;;
    esac
  done
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  printf "Usage: %s [install|quick|token|ingress|status|uninstall]\n" "$0"
  exit 0
fi

case "${1:-}" in
  install)   a_install ;;
  quick)     a_quick_tunnel ;;
  token)     a_token_service ;;
  ingress)   a_ingress_config ;;
  status)    a_status ;;
  uninstall) a_uninstall ;;
  "")        main ;;
  *)         err "Unknown action '$1'. Use --help."; exit 1 ;;
esac
