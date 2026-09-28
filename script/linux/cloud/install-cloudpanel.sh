#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-cloudpanel.sh — install CloudPanel CE v2.
# Supported: Ubuntu 24.04 LTS (Mandatory).
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
if   [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
elif [ -r "${__d}/lib.sh" ]; then . "${__d}/lib.sh"
elif [ -n "${WF_INSTALL_DIR:-}" ] && [ -r "${WF_INSTALL_DIR}/lib.sh" ]; then . "${WF_INSTALL_DIR}/lib.sh"
elif [ -r "/opt/wanforge-scripts/lib.sh" ]; then . "/opt/wanforge-scripts/lib.sh"
elif [ -r "${HOME:-}/.local/lib/wanforge-scripts/lib.sh" ]; then . "${HOME}/.local/lib/wanforge-scripts/lib.sh"
elif command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}")
else . <(wget -qO- "${__LIB}"); fi
cfg_load
wf_log_init

STEP=0; TOTAL=3
step() { STEP=$((STEP + 1)); printf "\n%b==> [%d/%d] %s%b\n" "${C_BOLD}${C_CYAN}" "${STEP}" "${TOTAL}" "$1" "${C_RESET}" >&2; }

a_uninstall() {
  hd "Uninstall CloudPanel"
  warn "CloudPanel does not have an automated uninstaller."
  info "Manual steps to remove CloudPanel:"
  info "  1. systemctl stop clp nginx 'php*' mysql mariadb"
  info "  2. apt purge -y 'clp*' && apt autoremove -y"
  info "  3. rm -rf /home/cloudpanel /etc/nginx /etc/clp /var/clp"
  info "  4. Docs: https://www.cloudpanel.io/docs/v2/"
  warn "No automated action taken — proceed manually."
}

# =========================================================================
# run
# =========================================================================
[ "${1:-}" = "--uninstall" ] && { a_uninstall; exit $?; }
banner
if [ -z "${1:-}" ]; then
  MENU=(
    "Manage|install|install CloudPanel"
    "Manage|uninstall|show uninstall instructions"
  )
  menu_select "CloudPanel — choose action:" || exit 0
  case "${MENU_KEY}" in
    uninstall) a_uninstall; exit $? ;;
    install|*) ;;
  esac
fi

# CloudPanel requires Ubuntu 24.
if ! command -v apt-get >/dev/null 2>&1; then
  err "CloudPanel requires Ubuntu 24 (apt-get not found). Aborting."
  exit 1
fi

# ---- supported OS check (Strict Ubuntu 24 enforcement) -------------------
# shellcheck disable=SC1091
. /etc/os-release 2>/dev/null || true
OS_ID="${ID:-}"; OS_VER="${VERSION_ID:-}"
info "Detected OS: ${OS_ID} ${OS_VER}"
case "${OS_ID}:${OS_VER}" in
  ubuntu:24.04|ubuntu:24.*)
    ok "OS check passed: Ubuntu 24 (${VERSION_CODENAME:-noble})"
    ;;
  *)
    err "CloudPanel strictly requires Ubuntu 24.04 LTS. Detected OS: ${OS_ID} ${OS_VER}."
    err "Aborting: installation is restricted strictly to Ubuntu 24."
    exit 1
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

# ---- step 2: choose database engine --------------------------------------
step "Choose database engine"
ENGINES=(MARIADB_12.3 MARIADB_11.8 MARIADB_11.4 MARIADB_10.11 MYSQL_8.4 MYSQL_8.0)
MENU=(
  "DB Engine|MARIADB_12.3|MariaDB 12.3 (Recommended / Default)"
  "DB Engine|MARIADB_11.8|MariaDB 11.8 (Rolling)"
  "DB Engine|MARIADB_11.4|MariaDB 11.4 (LTS)"
  "DB Engine|MARIADB_10.11|MariaDB 10.11 (LTS)"
  "DB Engine|MYSQL_8.4|MySQL 8.4 (LTS)"
  "DB Engine|MYSQL_8.0|MySQL 8.0"
)

if [ -n "${DB_ENGINE:-}" ]; then
  ok "Using database engine from environment: ${DB_ENGINE}"
else
  menu_select "Select database engine for CloudPanel:" || exit 0
  DB_ENGINE="${MENU_KEY:-MARIADB_12.3}"
fi
ok "Database engine: ${DB_ENGINE}"

# ---- step 3: download, verify checksum, install -------------------------
step "Download, verify checksum & install CloudPanel"
# Official checksum from CloudPanel docs (https://www.cloudpanel.io/docs/v2/getting-started/other/)
EXPECTED_SHA="8146dbe0a488e7088b04071b0c34d59aa0ab1fe9dcec382d395fd155c9e6c476"
INSTALLER="https://installer.cloudpanel.io/ce/v2/install.sh"
TMP_DIR="$(mktemp -d)"; trap 'rm -rf "${TMP_DIR}"' EXIT
cd "${TMP_DIR}"

info "Downloading installer..."
curl -sS "${INSTALLER}" -o install.sh

info "Verifying SHA-256 checksum..."
if ! echo "${EXPECTED_SHA}  install.sh" | sha256sum -c - >/dev/null 2>&1; then
  err "Checksum mismatch — refusing to run unverified installer."
  info "Expected: ${EXPECTED_SHA}"
  info "Actual:   $(sha256sum install.sh | awk '{print $1}')"
  exit 1
fi
ok "Checksum verified (${EXPECTED_SHA:0:16}...)."

info "Running CloudPanel installer (DB_ENGINE=${DB_ENGINE})..."
${SUDO} DB_ENGINE="${DB_ENGINE}" bash install.sh

printf "\n%b✔ CloudPanel installation finished.%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
printf "%b  Access: https://<server-ip>:8443%b\n\n" "${C_DIM}" "${C_RESET}" >&2
