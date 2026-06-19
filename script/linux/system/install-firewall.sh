#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-firewall.sh — install & configure ufw firewall (interactive).
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/system/install-firewall.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-firewall"

# --- shared library: banner, colors, logging, prompts, checkbox ----------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load

detect_pm() { for pm in apt-get dnf yum pacman zypper apk; do command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return 0; }; done; return 1; }
pm_install() {
  local pkgs="$*"
  case "${PM}" in
    apt-get) run ${SUDO} apt-get install -y ${pkgs} ;; dnf) run ${SUDO} dnf -y install ${pkgs} ;; yum) run ${SUDO} yum -y install ${pkgs} ;;
    pacman) run ${SUDO} pacman -S --noconfirm --needed ${pkgs} ;; zypper) run ${SUDO} zypper --non-interactive install ${pkgs} ;; apk) run ${SUDO} apk add ${pkgs} ;;
  esac
}

# ---- run ----------------------------------------------------------------
banner
PM="$(detect_pm)" || { err "No supported package manager found."; exit 1; }

if ! command -v ufw >/dev/null 2>&1; then
  info "ufw not found; installing..."
  pm_install ufw || { err "Could not install ufw (mainly Debian/Ubuntu)."; exit 1; }
fi

info "Applying base rules: OpenSSH, http, https"
${SUDO} ufw allow OpenSSH 2>/dev/null || ${SUDO} ufw allow 22/tcp
${SUDO} ufw allow http  2>/dev/null || ${SUDO} ufw allow 80/tcp
${SUDO} ufw allow https 2>/dev/null || ${SUDO} ufw allow 443/tcp

PORTS_ANS="$(ask_cfg CFG_UFW_EXTRA_PORTS "Extra ports to allow? (e.g. '8443/tcp 3000/tcp', Enter to skip):" "")"
if [ -n "${PORTS_ANS}" ]; then
  for p in ${PORTS_ANS//,/ }; do
    info "Allowing ${p}"; ${SUDO} ufw allow "${p}" || warn "Failed to allow ${p}"
  done
fi

ENABLE_ANS="$(ask_cfg CFG_UFW_ENABLE "Enable firewall now? [Y/n]:" "y")"
case "${ENABLE_ANS}" in
  n|N|no) info "Rules added but firewall left disabled." ;;
  *) info "Enabling firewall..."; ${SUDO} ufw --force enable; ${SUDO} ufw status verbose || true ;;
esac
printf "\n%b✔ Firewall configured.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
