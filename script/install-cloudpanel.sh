#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-cloudpanel.sh — install CloudPanel CE v2 (Debian/Ubuntu only).
# Docs: https://www.cloudpanel.io/docs/v2/getting-started/other/
#
# Usage (public repo, no auth needed):
#   curl -fsSL https://raw.githubusercontent.com/wanforge/server-mine/main/script/install-cloudpanel.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail

# =========================================================================
# colors
# =========================================================================

STEP=0; TOTAL=3
step() { STEP=$((STEP + 1)); printf "\n%b==> [%d/%d] %s%b\n" "${C_BOLD}${C_CYAN}" "${STEP}" "${TOTAL}" "$1" "${C_RESET}" >&2; }

# =========================================================================
# run
# =========================================================================
banner

# CloudPanel is Debian/Ubuntu only.
if ! command -v apt-get >/dev/null 2>&1; then
  err "CloudPanel supports only Debian/Ubuntu (apt). Aborting."
  exit 1
fi

# ---- step 1: prerequisites ----------------------------------------------
step "Update system & install prerequisites"
info "apt update && upgrade"
${SUDO} apt-get update
${SUDO} apt-get -y upgrade
info "Installing curl wget sudo"
${SUDO} apt-get -y install curl wget sudo
ok "Prerequisites ready."

# ---- step 2: choose database engine -------------------------------------
step "Choose database engine"
ENGINES=(MARIADB_11.4 MARIADB_10.11 MYSQL_8.4 MYSQL_8.0)
idx=1
for e in "${ENGINES[@]}"; do
  printf "    %b%d%b) %s\n" "${C_YELLOW}" "${idx}" "${C_RESET}" "${e}" >&2
  idx=$((idx + 1))
done
DB_CHOICE="$(ask "Select DB engine [1-${#ENGINES[@]}] (default 1 = MARIADB_11.4):" "1")"
if ! [[ "${DB_CHOICE}" =~ ^[0-9]+$ ]] || [ "${DB_CHOICE}" -lt 1 ] || [ "${DB_CHOICE}" -gt "${#ENGINES[@]}" ]; then
  warn "Invalid choice; using default MARIADB_11.4."
  DB_CHOICE=1
fi
DB_ENGINE="${ENGINES[$((DB_CHOICE - 1))]}"
ok "Database engine: ${DB_ENGINE}"

# ---- step 3: download, verify checksum, install -------------------------
step "Download & install CloudPanel"
# Official checksum from CloudPanel docs (changes per installer release).
EXPECTED_SHA="6eac061df80f08b75224fcd7fce2f115e201696d8a6122e31abf7259a813b462"
INSTALLER="https://installer.cloudpanel.io/ce/v2/install.sh"
TMP_DIR="$(mktemp -d)"; trap 'rm -rf "${TMP_DIR}"' EXIT
cd "${TMP_DIR}"

info "Downloading installer..."
curl -sS "${INSTALLER}" -o install.sh

info "Verifying SHA-256 checksum..."
ACTUAL_SHA="$(sha256sum install.sh | awk '{print $1}')"
# Fail closed: a mismatch means the file is untrusted (tampered) OR the pinned
# hash is stale for a new release. Either way we refuse to run unverified code.
# To install a newer release, update EXPECTED_SHA from the official CloudPanel
# docs after confirming the published hash.
if [ "${ACTUAL_SHA}" != "${EXPECTED_SHA}" ]; then
  err "Checksum mismatch — refusing to run unverified installer."
  info "expected: ${EXPECTED_SHA}"
  info "actual:   ${ACTUAL_SHA}"
  info "If a new CloudPanel release shipped, update EXPECTED_SHA from:"
  info "  https://www.cloudpanel.io/docs/v2/getting-started/other/"
  exit 1
fi
ok "Checksum verified."

info "Running CloudPanel installer (DB_ENGINE=${DB_ENGINE})..."
${SUDO} DB_ENGINE="${DB_ENGINE}" bash install.sh

printf "\n%b✔ CloudPanel installation finished.%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
printf "%b  Access: https://<server-ip>:8443%b\n\n" "${C_DIM}" "${C_RESET}" >&2
