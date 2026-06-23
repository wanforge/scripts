#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-composer.sh — install Composer into ~/.local/bin (no sudo),
# verify the installer signature, then run composer self-update.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/runtime/install-composer.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-composer"

# --- shared library: banner, colors, logging, prompts, checkbox ----------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi

# run as a target user (e.g. a CloudPanel site user) when invoked as root
maybe_switch_user "https://scripts.wanforge.asia/script/linux/runtime/install-composer.sh"

a_uninstall() {
  hd "Uninstall Composer"
  local bin_dir="${HOME}/.local/bin"
  if [ ! -f "${bin_dir}/composer" ]; then
    info "Composer not found at ${bin_dir}/composer."; return 0
  fi
  warn "Will remove ${bin_dir}/composer."
  local yn; yn="$(ask "Remove composer? [y/N]:" "n")"
  case "${yn}" in y|Y|yes) ;; *) info "Cancelled."; return 0 ;; esac
  rm -f "${bin_dir}/composer"
  ok "Composer removed."
}

# ---- run ----------------------------------------------------------------
[ "${1:-}" = "--uninstall" ] && { a_uninstall; exit $?; }
banner
if [ -z "${1:-}" ]; then
  MENU=(
    "Manage|install|install Composer"
    "Manage|uninstall|remove Composer"
  )
  menu_select "Composer — choose action:" || exit 0
  case "${MENU_KEY}" in
    uninstall) a_uninstall; exit $? ;;
    install|*) ;;
  esac
fi
command -v php >/dev/null 2>&1 || { err "PHP is required for Composer. Install PHP first."; exit 1; }

BIN_DIR="${HOME}/.local/bin"
mkdir -p "${BIN_DIR}"
TMP_DIR="$(mktemp -d)"; trap 'rm -rf "${TMP_DIR}"' EXIT
cd "${TMP_DIR}"

info "Downloading Composer installer..."
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"

info "Verifying installer signature..."
EXPECTED="$(curl -fsSL https://composer.github.io/installer.sig)"
ACTUAL="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"
if [ "${EXPECTED}" != "${ACTUAL}" ]; then
  err "Installer signature mismatch — refusing to run untrusted installer."
  info "expected: ${EXPECTED}"
  info "actual:   ${ACTUAL}"
  exit 1
fi
ok "Signature verified."

info "Installing composer to ${BIN_DIR}/composer ..."
php composer-setup.php --quiet --install-dir="${BIN_DIR}" --filename=composer
export PATH="${BIN_DIR}:${PATH}"

# ensure ~/.local/bin is on PATH for future shells
if ! grep -qs 'HOME/.local/bin' "${HOME}/.bashrc" 2>/dev/null; then
  printf '\n# add user-local bin to PATH\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "${HOME}/.bashrc"
  info "Added ~/.local/bin to PATH in ~/.bashrc"
fi

info "Running composer self-update..."
composer self-update || warn "self-update failed (offline or already latest)."

ok "$(composer --version 2>/dev/null || echo 'composer installed')"
printf "\n%b✔ Composer ready.%b  %bopen a new shell or run: source ~/.bashrc%b\n\n" \
  "${C_BOLD}${C_GREEN}" "${C_RESET}" "${C_DIM}" "${C_RESET}" >&2
