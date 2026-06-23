#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-postgresql.sh — install PostgreSQL, create login roles (interactive,
# no hardcoded secrets), optionally enable remote access.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/database/install-postgresql.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-postgresql"

# --- shared library: banner, colors, logging, prompts, checkbox ----------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load
wf_log_init

psql_super() { ${SUDO} -u postgres psql -v ON_ERROR_STOP=1 "$@"; }

# ---- run ----------------------------------------------------------------
banner
if ! command -v apt-get >/dev/null 2>&1; then err "This script targets Debian/Ubuntu (apt)."; exit 1; fi

# Add the official PostgreSQL APT repository (PGDG) to get the latest version.
add_pgdg_repo() {
  info "Configuring PGDG repository for the latest PostgreSQL..."
  run ${SUDO} apt-get install -y curl ca-certificates gnupg
  run ${SUDO} install -d /usr/share/postgresql-common/pgdg
  ${SUDO} curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    https://www.postgresql.org/media/keys/ACCC4CF8.asc
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
    | run ${SUDO} tee /etc/apt/sources.list.d/pgdg.list >/dev/null
}

info "Installing the latest PostgreSQL..."
if add_pgdg_repo; then
  run ${SUDO} apt-get update
else
  warn "PGDG repo setup failed; falling back to the distro package."
  run ${SUDO} apt-get update
fi
# 'postgresql' meta-package pulls the newest available major version.
run ${SUDO} apt-get install -y postgresql postgresql-contrib
run ${SUDO} systemctl enable postgresql >/dev/null 2>&1 || true
run ${SUDO} systemctl start postgresql || true
PG_VER="$(${SUDO} -u postgres psql -tAc 'SHOW server_version;' 2>/dev/null || echo '?')"
ok "PostgreSQL ${PG_VER} installed and running."

# ---- create login roles (interactive, no hardcoded secrets) -------------
info "Create login roles. Passwords are entered interactively, never stored in this script."
while true; do
  ADD="$(ask "Create a database role now? [y/N]:" "n")"
  case "${ADD}" in y|Y|yes) ;; *) break ;; esac

  ROLE="$(ask "Role name:" "")"
  if ! [[ "${ROLE}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    warn "Invalid role name (use letters, digits, underscore; must not start with a digit)."; continue
  fi
  PW1="$(asks "Password for ${ROLE}:")"
  PW2="$(asks "Confirm password:")"
  if [ -z "${PW1}" ] || [ "${PW1}" != "${PW2}" ]; then warn "Empty or mismatched password; skipping."; continue; fi

  SUPER="$(ask "Grant SUPERUSER? (powerful, default no) [y/N]:" "n")"
  PRIV="LOGIN CREATEDB CREATEROLE"
  case "${SUPER}" in y|Y|yes) PRIV="SUPERUSER ${PRIV}"; warn "Granting SUPERUSER to ${ROLE}." ;; esac

  # escape single quotes in the password for the SQL string literal
  PW_ESC="${PW1//\'/\'\'}"
  if psql_super -c "CREATE ROLE \"${ROLE}\" WITH ${PRIV} PASSWORD '${PW_ESC}';" 2>/dev/null; then
    ok "Created role ${ROLE} (${PRIV})."
  else
    warn "Could not create ${ROLE} (already exists?). Trying to update password..."
    psql_super -c "ALTER ROLE \"${ROLE}\" WITH ${PRIV} PASSWORD '${PW_ESC}';" && ok "Updated role ${ROLE}." || err "Failed for ${ROLE}."
  fi
  unset PW1 PW2 PW_ESC
done

# ---- remote access (optional, security-sensitive) -----------------------
REMOTE="$(ask_cfg CFG_PG_REMOTE "Enable remote access (network listen + pg_hba)? [y/N]:" "n")"
case "${REMOTE}" in
  y|Y|yes)
    warn "Exposing PostgreSQL to the network. Restrict the source range whenever possible."
    CIDR="$(ask_cfg CFG_PG_CIDR "Allowed source CIDR (e.g. 10.0.0.0/8; '0.0.0.0/0'=anywhere, NOT recommended):" "0.0.0.0/0")"
    PG_HBA="$(psql_super -tAc 'SHOW hba_file;')"
    PG_CONF="$(psql_super -tAc 'SHOW config_file;')"
    info "hba_file:    ${PG_HBA}"
    info "config_file: ${PG_CONF}"

    HBA_LINE="host    all             all             ${CIDR}            scram-sha-256"
    if ${SUDO} grep -qF "${CIDR}" "${PG_HBA}"; then
      info "pg_hba already has a rule for ${CIDR}."
    else
      echo "${HBA_LINE}" | run ${SUDO} tee -a "${PG_HBA}" >/dev/null
      ok "Appended pg_hba rule for ${CIDR}."
    fi

    if ${SUDO} grep -qE "^[#[:space:]]*listen_addresses" "${PG_CONF}"; then
      run ${SUDO} sed -i "s|^[#[:space:]]*listen_addresses.*|listen_addresses = '*'|" "${PG_CONF}"
    else
      echo "listen_addresses = '*'" | run ${SUDO} tee -a "${PG_CONF}" >/dev/null
    fi
    ok "Set listen_addresses = '*'."

    run ${SUDO} systemctl restart postgresql && ok "PostgreSQL restarted."

    if command -v ufw >/dev/null 2>&1; then
      if [ "${CIDR}" = "0.0.0.0/0" ]; then ${SUDO} ufw allow 5432/tcp
      else ${SUDO} ufw allow from "${CIDR}" to any port 5432 proto tcp; fi
      ok "Firewall: allowed 5432/tcp from ${CIDR}."
    else
      info "ufw not installed; open port 5432 manually if needed."
    fi
    ;;
  *) info "Remote access left disabled (local only)." ;;
esac

printf "\n%b✔ PostgreSQL setup complete.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
