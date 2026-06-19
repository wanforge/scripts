#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# generate-ssh-key.sh — generate an ed25519 SSH key in the user's ~/.ssh
# (no sudo), fix permissions, and print the public key for GitHub/GitLab.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/security/generate-ssh-key.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="generate-ssh-key"

# --- shared library: banner, colors, logging, prompts, checkbox ----------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load

# ---- run ----------------------------------------------------------------
banner
command -v ssh-keygen >/dev/null 2>&1 || { err "ssh-keygen not found. Install openssh-client first."; exit 1; }

KEYFILE="$(ask_cfg CFG_SSH_KEYFILE "Key file path:" "${HOME}/.ssh/id_ed25519")"
COMMENT="$(ask_cfg CFG_SSH_COMMENT "Key comment:" "wanforge-asia@$(hostname 2>/dev/null || echo wanforge-app)")"

# passphrase (optional)
PASS=""
PP_ANS="$(ask "Protect the key with a passphrase? [y/N]:" "n")"
if [[ "${PP_ANS}" =~ ^(y|Y|yes)$ ]]; then
  P1="$(asks 'Passphrase:')"; P2="$(asks 'Confirm passphrase:')"
  if [ "${P1}" != "${P2}" ]; then err "Passphrases do not match."; exit 1; fi
  PASS="${P1}"; unset P1 P2
fi

mkdir -p "$(dirname "${KEYFILE}")"

# do not silently overwrite an existing key
if [ -e "${KEYFILE}" ]; then
  OW="$(ask "${KEYFILE} exists. Overwrite? [y/N]:" "n")"
  [[ "${OW}" =~ ^(y|Y|yes)$ ]] || { err "Aborted to avoid overwriting the existing key."; exit 1; }
  rm -f "${KEYFILE}" "${KEYFILE}.pub"
fi

info "Generating ed25519 key..."
ssh-keygen -t ed25519 -f "${KEYFILE}" -N "${PASS}" -C "${COMMENT}"

# permissions
chmod 700 "$(dirname "${KEYFILE}")"
chmod 600 "${KEYFILE}"
chmod 644 "${KEYFILE}.pub"
ok "Key generated: ${KEYFILE}"

# fingerprint + public key
info "Fingerprint:"; ssh-keygen -lf "${KEYFILE}.pub" >&2 || true

printf "\n%bPublic key (add to GitHub/GitLab → Settings → Deploy Keys / SSH Keys):%b\n\n" "${C_BOLD}" "${C_RESET}" >&2
printf "%b" "${C_CYAN}" >&2; cat "${KEYFILE}.pub" >&2; printf "%b\n" "${C_RESET}" >&2

printf "\n%b✔ Done.%b  %bTip: eval \"\$(ssh-agent -s)\" && ssh-add %s%b\n\n" \
  "${C_BOLD}${C_GREEN}" "${C_RESET}" "${C_DIM}" "${KEYFILE}" "${C_RESET}" >&2
