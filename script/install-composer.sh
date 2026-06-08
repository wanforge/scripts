#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-composer.sh — install Composer into ~/.local/bin (no sudo),
# verify the installer signature, then run composer self-update.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/wanforge/server-mine/main/script/install-composer.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-composer"

# --- shared library: banner, colors, logging, prompts, checkbox ----------
__LIB="https://raw.githubusercontent.com/wanforge/server-mine/main/script/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/lib.sh" ]; then . "${__d}/lib.sh"
else . <(curl -fsSL "${__LIB}"); fi

# ---- run ----------------------------------------------------------------
banner
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
