#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# set-timezone.sh — set the system timezone (interactive). UTC is recommended
# for servers (no DST, consistent logs); convert to local time in the app.
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
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi

# ---- run ----------------------------------------------------------------
banner
if ! command -v timedatectl >/dev/null 2>&1; then
  err "timedatectl not available on this system."; exit 1
fi
info "Recommended: UTC for servers/databases (no DST, consistent logs); show local time in your app."
printf "    %bCurrent: %s%b\n" "${C_DIM}" "$(timedatectl show -p Timezone --value 2>/dev/null || echo '?')" "${C_RESET}" >&2

MENU=(
  "Timezone|UTC|UTC — recommended for servers & databases"
  "Timezone|Asia/Jakarta|Asia/Jakarta (WIB, UTC+7)"
  "Timezone|custom|Enter a custom zone…"
  "Timezone|skip|Skip (leave unchanged)"
)
menu_select "Set system timezone:" || { info "Skipped."; exit 0; }
TZ_ANS="${MENU_KEY}"
[ "${TZ_ANS}" = "custom" ] && TZ_ANS="$(ask "Timezone (e.g. Europe/London, America/New_York):" "UTC")"

case "${TZ_ANS}" in
  skip|"") info "Skipped timezone." ;;
  *)
    info "Setting timezone to ${TZ_ANS}"
    if run ${SUDO} timedatectl set-timezone "${TZ_ANS}"; then
      ${SUDO} timedatectl 2>/dev/null || true
      printf "\n%b✔ Timezone set to %s.%b\n\n" "${C_BOLD}${C_GREEN}" "${TZ_ANS}" "${C_RESET}" >&2
    else
      err "Failed to set timezone '${TZ_ANS}' (invalid zone?)."; exit 1
    fi
    ;;
esac
