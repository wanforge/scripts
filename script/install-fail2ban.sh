#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-fail2ban.sh — install & enable Fail2Ban (interactive, multi-distro).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/wanforge/server-mine/main/script/install-fail2ban.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-fail2ban"

# --- shared library: banner, colors, logging, prompts, checkbox ----------
__LIB="https://raw.githubusercontent.com/wanforge/server-mine/main/script/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/lib.sh" ]; then . "${__d}/lib.sh"
else . <(curl -fsSL "${__LIB}"); fi

detect_pm() { for pm in apt-get dnf yum pacman zypper apk; do command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return 0; }; done; return 1; }
pm_install() {
  local pkgs="$*"
  case "${PM}" in
    apt-get) ${SUDO} apt-get install -y ${pkgs} ;; dnf) ${SUDO} dnf -y install ${pkgs} ;; yum) ${SUDO} yum -y install ${pkgs} ;;
    pacman) ${SUDO} pacman -S --noconfirm --needed ${pkgs} ;; zypper) ${SUDO} zypper --non-interactive install ${pkgs} ;; apk) ${SUDO} apk add ${pkgs} ;;
  esac
}
svc_enable_start() {
  local svc="$1"
  if command -v systemctl >/dev/null 2>&1; then
    ${SUDO} systemctl enable "${svc}" >/dev/null 2>&1 || true
    ${SUDO} systemctl start "${svc}" || true
  elif command -v rc-update >/dev/null 2>&1; then
    ${SUDO} rc-update add "${svc}" default >/dev/null 2>&1 || true
    ${SUDO} rc-service "${svc}" start || true
  else
    warn "No init system detected; start ${svc} manually."
  fi
}

# ---- run ----------------------------------------------------------------
banner
PM="$(detect_pm)" || { err "No supported package manager found."; exit 1; }
ANS="$(ask "Install & enable Fail2Ban? [Y/n]:" "y")"
case "${ANS}" in
  n|N|no) info "Skipped Fail2Ban."; exit 0 ;;
esac
info "Installing fail2ban..."
pm_install fail2ban || { err "Failed to install fail2ban."; exit 1; }
svc_enable_start fail2ban
printf "\n%b✔ Fail2Ban installed and started.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
