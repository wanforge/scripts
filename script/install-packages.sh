#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-packages.sh — update system & install base packages (multi-distro),
# with a grouped checkbox menu to pick exactly which actions/packages to run.
# Package managers: apt, dnf, yum, pacman, zypper, apk.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/wanforge/server-mine/main/script/install-packages.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-packages"

# --- shared library: banner, colors, logging, prompts, checkbox ----------
__LIB="https://raw.githubusercontent.com/wanforge/server-mine/main/script/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/lib.sh" ]; then . "${__d}/lib.sh"
else . <(curl -fsSL "${__LIB}"); fi

# ---- package manager ----------------------------------------------------
detect_pm() { for pm in apt-get dnf yum pacman zypper apk; do command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return 0; }; done; return 1; }
PM="$(detect_pm)" || { err "No supported package manager found."; exit 1; }

pm_update()  { case "${PM}" in apt-get) ${SUDO} apt-get update ;; dnf) ${SUDO} dnf -y makecache ;; yum) ${SUDO} yum -y makecache ;; pacman) ${SUDO} pacman -Sy --noconfirm ;; zypper) ${SUDO} zypper --non-interactive refresh ;; apk) ${SUDO} apk update ;; esac; }
pm_upgrade() { case "${PM}" in apt-get) ${SUDO} apt-get upgrade -y ;; dnf) ${SUDO} dnf -y upgrade --refresh ;; yum) ${SUDO} yum -y update ;; pacman) ${SUDO} pacman -Su --noconfirm ;; zypper) ${SUDO} zypper --non-interactive update ;; apk) ${SUDO} apk upgrade ;; esac; }
pm_install() { local pkgs="$*"; [ -z "$pkgs" ] && return 0; case "${PM}" in apt-get) ${SUDO} apt-get install -y ${pkgs} ;; dnf) ${SUDO} dnf -y install ${pkgs} ;; yum) ${SUDO} yum -y install ${pkgs} ;; pacman) ${SUDO} pacman -S --noconfirm --needed ${pkgs} ;; zypper) ${SUDO} zypper --non-interactive install ${pkgs} ;; apk) ${SUDO} apk add ${pkgs} ;; esac; }
pm_cleanup() { case "${PM}" in apt-get) ${SUDO} apt-get autoremove -y; ${SUDO} apt-get autoclean ;; dnf) ${SUDO} dnf -y autoremove; ${SUDO} dnf clean all ;; yum) ${SUDO} yum -y autoremove || true; ${SUDO} yum clean all ;; pacman) ${SUDO} pacman -Qtdq 2>/dev/null | ${SUDO} pacman -Rns --noconfirm - 2>/dev/null || true ;; zypper) ${SUDO} zypper clean --all ;; apk) : ;; esac; }

# resolve a logical package key to the distro package name (empty = skip)
pkg_name() {
  case "$1" in
    micro|curl|wget|git) echo "$1" ;;
    speedtest-cli) case "${PM}" in apk) echo "" ;; *) echo speedtest-cli ;; esac ;;
    python3) case "${PM}" in pacman) echo python ;; *) echo python3 ;; esac ;;
    pip) case "${PM}" in apt-get|dnf|yum|zypper) echo python3-pip ;; pacman) echo python-pip ;; apk) echo py3-pip ;; esac ;;
    dev) case "${PM}" in apt-get|apk) echo python3-dev ;; dnf|yum|zypper) echo python3-devel ;; pacman) echo "" ;; esac ;;
    venv) case "${PM}" in apt-get|dnf|yum|zypper) echo python3-virtualenv ;; pacman) echo python-virtualenv ;; apk) echo py3-virtualenv ;; esac ;;
  esac
}

# ---- menu ---------------------------------------------------------------
MENU=(
  "System|update|Refresh package index"
  "System|upgrade|Upgrade installed packages"
  "System|cleanup|Autoremove + clean cache"
  "Editor|micro|Modern terminal text editor"
  "Network|curl|Transfer data / fetch URLs"
  "Network|wget|Download files over HTTP/FTP"
  "VCS|git|Distributed version control"
  "Diagnostics|speedtest-cli|Internet speed test (CLI)"
  "Python|python3|Python 3 interpreter"
  "Python|pip|Python package manager (pip)"
  "Python|dev|Python headers for building modules"
  "Python|venv|Isolated Python environments (virtualenv)"
)

# ---- run ----------------------------------------------------------------
banner
info "Package manager: ${C_BOLD}${PM}${C_RESET}"
checkbox "Select actions & packages to install:" || { warn "Cancelled."; exit 0; }
[ "${#CHOSEN_KEYS[@]}" -eq 0 ] && { warn "Nothing selected."; exit 0; }

has_key update  && { info "Refreshing package index..."; pm_update; }
has_key upgrade && { info "Upgrading installed packages..."; pm_upgrade; }

# collect selected packages (resolved per distro)
PKGS=""
for key in micro curl wget git speedtest-cli python3 pip dev venv; do
  if has_key "$key"; then p="$(pkg_name "$key")"; [ -n "$p" ] && PKGS="${PKGS} ${p}"; fi
done
if [ -n "${PKGS# }" ]; then info "Installing:${PKGS}"; pm_install ${PKGS}; fi

# speedtest-cli pip fallback where the package is unavailable
if has_key speedtest-cli && ! command -v speedtest-cli >/dev/null 2>&1 && command -v pip3 >/dev/null 2>&1; then
  info "speedtest-cli not in repo; installing via pip3"; pip3 install --user speedtest-cli >/dev/null 2>&1 || true
fi

has_key cleanup && { info "Cleaning up..."; pm_cleanup; }

printf "\n%b✔ Packages ready.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
