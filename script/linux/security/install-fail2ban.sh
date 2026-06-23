#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-fail2ban.sh — install & enable Fail2Ban (interactive, multi-distro).
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/security/install-fail2ban.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-fail2ban"

# --- shared library: banner, colors, logging, prompts, checkbox ----------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi

detect_pm() { for pm in apt-get dnf yum pacman zypper apk; do command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return 0; }; done; return 1; }
pm_install() {
  local pkgs="$*"
  case "${PM}" in
    apt-get) run ${SUDO} apt-get install -y ${pkgs} ;; dnf) run ${SUDO} dnf -y install ${pkgs} ;; yum) run ${SUDO} yum -y install ${pkgs} ;;
    pacman) run ${SUDO} pacman -S --noconfirm --needed ${pkgs} ;; zypper) run ${SUDO} zypper --non-interactive install ${pkgs} ;; apk) run ${SUDO} apk add ${pkgs} ;;
  esac
}
svc_enable_start() {
  local svc="$1"
  if command -v systemctl >/dev/null 2>&1; then
    run ${SUDO} systemctl enable "${svc}" >/dev/null 2>&1 || true
    run ${SUDO} systemctl start "${svc}" || true
  elif command -v rc-update >/dev/null 2>&1; then
    run ${SUDO} rc-update add "${svc}" default >/dev/null 2>&1 || true
    run ${SUDO} rc-service "${svc}" start || true
  else
    warn "No init system detected; start ${svc} manually."
  fi
}

a_uninstall() {
  hd "Uninstall Fail2Ban"
  warn "This will stop and remove Fail2Ban from this system."
  local yn; yn="$(ask "Remove fail2ban? [y/N]:" "n")"
  case "${yn}" in y|Y|yes) ;; *) info "Cancelled."; return 0 ;; esac
  local pm; pm="$(detect_pm)" || { err "No supported package manager."; return 1; }
  run ${SUDO} systemctl stop fail2ban 2>/dev/null || true
  run ${SUDO} systemctl disable fail2ban 2>/dev/null || true
  case "${pm}" in
    apt-get) run ${SUDO} apt-get purge -y fail2ban; run ${SUDO} apt-get autoremove -y ;;
    dnf|yum) run ${SUDO} "${pm}" -y remove fail2ban ;;
    pacman)  run ${SUDO} pacman -Rns --noconfirm fail2ban ;;
    zypper)  run ${SUDO} zypper --non-interactive remove fail2ban ;;
    apk)     run ${SUDO} apk del fail2ban ;;
  esac
  ok "Fail2Ban removed."
}

# ---- run ----------------------------------------------------------------
wf_svc_dispatch "${1:-}" "Fail2Ban" "fail2ban" fail2ban && exit $?
[ "${1:-}" = "--uninstall" ] && { a_uninstall; exit $?; }
banner
if [ -z "${1:-}" ]; then
  _WF_RC=0; wf_svc_menu "Fail2Ban" "fail2ban" fail2ban || _WF_RC=$?
  [ "${_WF_RC}" -eq 99 ] && { a_uninstall; exit $?; }
fi
PM="$(detect_pm)" || { err "No supported package manager found."; exit 1; }
ANS="$(ask "Install & enable Fail2Ban? [Y/n]:" "y")"
case "${ANS}" in
  n|N|no) info "Skipped Fail2Ban."; exit 0 ;;
esac
info "Installing fail2ban..."
pm_install fail2ban || { err "Failed to install fail2ban."; exit 1; }
svc_enable_start fail2ban
printf "\n%b✔ Fail2Ban installed and started.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
