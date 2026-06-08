#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# set-timezone.sh — set the system timezone (interactive, default Asia/Jakarta).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/wanforge/server-mine/main/script/set-timezone.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="set-timezone"

# --- shared library: banner, colors, logging, prompts, checkbox ----------
__LIB="https://raw.githubusercontent.com/wanforge/server-mine/main/script/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/lib.sh" ]; then . "${__d}/lib.sh"
else . <(curl -fsSL "${__LIB}"); fi

# ---- run ----------------------------------------------------------------
banner
if ! command -v timedatectl >/dev/null 2>&1; then
  err "timedatectl not available on this system."; exit 1
fi
TZ_ANS="$(ask "Timezone? [Asia/Jakarta] (Enter=set, 's'=skip, or type a zone):" "Asia/Jakarta")"
case "${TZ_ANS}" in
  s|S|skip) info "Skipped timezone." ;;
  *)
    info "Setting timezone to ${TZ_ANS}"
    if ${SUDO} timedatectl set-timezone "${TZ_ANS}"; then
      ${SUDO} timedatectl || true
      printf "\n%b✔ Timezone set to %s.%b\n\n" "${C_BOLD}${C_GREEN}" "${TZ_ANS}" "${C_RESET}" >&2
    else
      err "Failed to set timezone '${TZ_ANS}' (invalid zone?)."; exit 1
    fi
    ;;
esac
