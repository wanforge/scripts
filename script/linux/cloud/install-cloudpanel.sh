#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-cloudpanel.sh — install CloudPanel CE v2.
# Supported: Ubuntu 24.04/22.04 LTS, Debian 11/12/13 (NOT Ubuntu 25/26).
# Docs: https://www.cloudpanel.io/docs/v2/getting-started/other/
#
# Usage (public repo, no auth needed):
#   curl -fsSL https://scripts.wanforge.asia/script/linux/cloud/install-cloudpanel.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-cloudpanel"

# --- shared library ------------------------------------------------------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load

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

# ---- supported OS check -------------------------------------------------
# Per https://www.cloudpanel.io/docs/v2/getting-started/other/
# Supported: Ubuntu 24.04 / 22.04 LTS, Debian 11 / 12 / 13.  (Ubuntu 25/26: NO)
# TODO: re-check the docs above periodically — when Ubuntu 26.04 becomes
#       supported, add `ubuntu:26.04` to the case below and to the ENGINES case.
# shellcheck disable=SC1091
. /etc/os-release 2>/dev/null || true
OS_ID="${ID:-}"; OS_VER="${VERSION_ID:-}"
info "Detected OS: ${OS_ID} ${OS_VER}"
case "${OS_ID}:${OS_VER}" in
  ubuntu:24.04|ubuntu:22.04|debian:11|debian:12|debian:13) ;;
  *)
    warn "CloudPanel officially supports Ubuntu 24.04/22.04 LTS and Debian 11/12/13."
    warn "${OS_ID} ${OS_VER} is NOT supported (e.g. Ubuntu 25/26 not yet supported)."
    warn "Docs: https://www.cloudpanel.io/docs/v2/getting-started/other/"
    case "$(ask "Try installing anyway? (likely to fail) [y/N]:" "n")" in
      y|Y|yes) warn "Proceeding on an unsupported OS at your own risk." ;;
      *) err "Aborting on unsupported OS."; exit 1 ;;
    esac
    ;;
esac

# ---- step 1: prerequisites ----------------------------------------------
step "Update system & install prerequisites"
info "apt update && upgrade"
run ${SUDO} apt-get update
run ${SUDO} apt-get -y upgrade
info "Installing curl wget sudo"
run ${SUDO} apt-get -y install curl wget sudo
ok "Prerequisites ready."

# ---- step 2: choose database engine (options vary per OS, per docs) ------
step "Choose database engine"
case "${OS_ID}:${OS_VER}" in
  ubuntu:24.04) ENGINES=(MARIADB_11.4 MARIADB_10.11 MYSQL_8.4 MYSQL_8.0) ;;
  ubuntu:22.04) ENGINES=(MARIADB_11.4 MARIADB_10.11 MARIADB_10.6 MYSQL_8.0) ;;
  debian:13)    ENGINES=(MARIADB_11.8 MYSQL_8.4 MYSQL_8.0) ;;
  debian:12)    ENGINES=(MARIADB_11.4 MARIADB_10.11 MYSQL_8.4 MYSQL_8.0) ;;
  debian:11)    ENGINES=(MARIADB_10.6 MYSQL_8.0 MYSQL_5.7) ;;
  *)            ENGINES=(MARIADB_11.4 MARIADB_10.11 MYSQL_8.4 MYSQL_8.0) ;;
esac
idx=1
for e in "${ENGINES[@]}"; do
  printf "    %b%d%b) %s\n" "${C_YELLOW}" "${idx}" "${C_RESET}" "${e}" >&2
  idx=$((idx + 1))
done
DB_CHOICE="$(ask_cfg CFG_DB_ENGINE_CHOICE "Select DB engine [1-${#ENGINES[@]}] (default 1 = ${ENGINES[0]}):" "1")"
if ! [[ "${DB_CHOICE}" =~ ^[0-9]+$ ]] || [ "${DB_CHOICE}" -lt 1 ] || [ "${DB_CHOICE}" -gt "${#ENGINES[@]}" ]; then
  warn "Invalid choice; using default ${ENGINES[0]}."
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
