#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# secure-ssh.sh — harden SSH: change port (default 22), disable root login,
# optionally disable password auth, enable pubkey auth. Opens the new port in
# the firewall BEFORE restarting sshd to avoid lockout.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/security/secure-ssh.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="secure-ssh"

# --- shared library: banner, colors, logging, prompts, checkbox ----------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load
wf_log_init
DEFAULT_PORT="22"

SSHD_MAIN="/etc/ssh/sshd_config"
DROPIN_DIR="/etc/ssh/sshd_config.d"
DROPIN="${DROPIN_DIR}/99-wanforge-hardening.conf"

# set_opt KEY VALUE FILE — replace commented/uncommented line, or append
set_opt() {
  local key="$1" val="$2" file="$3"
  if ${SUDO} grep -qE "^[#[:space:]]*${key}\b" "${file}" 2>/dev/null; then
    run ${SUDO} sed -i "s|^[#[:space:]]*${key}\b.*|${key} ${val}|" "${file}"
  else
    echo "${key} ${val}" | run ${SUDO} tee -a "${file}" >/dev/null
  fi
}

a_uninstall() {
  hd "Restore SSH Config"
  local backup
  backup="$(ls -t "${SSHD_MAIN}.bak."* 2>/dev/null | head -1 || true)"
  if [ -z "${backup}" ] && [ ! -f "${DROPIN}" ]; then
    info "No wanforge SSH backup or drop-in found. Nothing to restore."; return 0
  fi
  [ -n "${backup}" ] && warn "Will restore ${SSHD_MAIN} from: ${backup##*/}"
  [ -f "${DROPIN}" ]  && warn "Will remove drop-in: ${DROPIN}"
  confirm_critical "restore original SSH config (overwrites current sshd_config)" || return 0
  [ -n "${backup}" ] && run ${SUDO} cp "${backup}" "${SSHD_MAIN}"
  [ -f "${DROPIN}" ]  && run ${SUDO} rm -f "${DROPIN}"
  if ${SUDO} sshd -t; then
    run ${SUDO} systemctl restart ssh 2>/dev/null || run ${SUDO} systemctl restart sshd 2>/dev/null || true
    ok "SSH config restored. Test your connection before closing this session."
  else
    err "sshd config test FAILED after restore. Check ${SSHD_MAIN} manually."; return 1
  fi
}

# ---- run ----------------------------------------------------------------
a_install() {
  hd "Install OpenSSH Server"
  if ${SUDO} systemctl is-active ssh >/dev/null 2>&1 || ${SUDO} systemctl is-active sshd >/dev/null 2>&1; then
    ok "OpenSSH server already running."; return 0
  fi
  info "Installing openssh-server..."
  if have apt-get; then
    run ${SUDO} apt-get update -qq
    run ${SUDO} apt-get install -y openssh-server
  elif have dnf; then
    run ${SUDO} dnf install -y openssh-server
  elif have yum; then
    run ${SUDO} yum install -y openssh-server
  elif have pacman; then
    run ${SUDO} pacman -S --noconfirm openssh
  else
    err "Unsupported package manager."; return 1
  fi
  run ${SUDO} systemctl enable ssh 2>/dev/null || run ${SUDO} systemctl enable sshd 2>/dev/null || true
  run ${SUDO} systemctl start ssh 2>/dev/null || run ${SUDO} systemctl start sshd 2>/dev/null || true
  ok "OpenSSH server installed and started."
}

# ---- run ----------------------------------------------------------------
[ "${1:-}" = "--uninstall" ] && { a_uninstall; exit $?; }
banner
if [ -z "${1:-}" ]; then
  MENU=(
    "Setup|install|install and enable SSH server"
    "Manage|configure|harden SSH configuration"
    "Manage|rollback|restore original sshd_config from backup"
  )
  menu_select "SSH Management — choose action:" || exit 0
  case "${MENU_KEY}" in
    install)     a_install; exit $? ;;
    rollback)    a_uninstall; exit $? ;;
    configure|*) ;;
  esac
fi
[ -f "${SSHD_MAIN}" ] || { err "${SSHD_MAIN} not found. Is OpenSSH server installed?"; exit 1; }

warn "Changing the SSH port and disabling password auth can LOCK YOU OUT."
warn "Keep your CURRENT session open. Only close it after logging in on the new port."

# port
PORT="$(ask_cfg CFG_SSH_PORT "New SSH port:" "${DEFAULT_PORT}")"
if ! [[ "${PORT}" =~ ^[0-9]+$ ]] || [ "${PORT}" -lt 1 ] || [ "${PORT}" -gt 65535 ]; then
  err "Invalid port: ${PORT}"; exit 1
fi

# policy choices
ROOT_ANS="$(ask_cfg CFG_SSH_ROOT_LOGIN "Disable root login (PermitRootLogin no)? [Y/n]:" "y")"
PUBKEY_ANS="$(ask_cfg CFG_SSH_PUBKEY "Enable pubkey auth (PubkeyAuthentication yes)? [Y/n]:" "y")"
PWAUTH_ANS="$(ask_cfg CFG_SSH_PWAUTH "Disable password auth (key-only login)? [y/N]:" "n")"

# safety: if disabling passwords, make sure a key is present
if [[ "${PWAUTH_ANS}" =~ ^(y|Y|yes)$ ]]; then
  KEYFOUND=0
  for f in "${HOME}/.ssh/authorized_keys" /root/.ssh/authorized_keys; do
    [ -s "$f" ] && KEYFOUND=1
  done
  if [ "${KEYFOUND}" -eq 0 ]; then
    warn "No authorized_keys found. Disabling password auth now may lock you out."
    CONFIRM="$(ask "Type 'yes' to proceed anyway:" "no")"
    [ "${CONFIRM}" = "yes" ] || { info "Keeping password auth enabled."; PWAUTH_ANS="n"; }
  fi
fi

# choose target file: drop-in if Include is active, else the main config
if ${SUDO} grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' "${SSHD_MAIN}"; then
  run ${SUDO} mkdir -p "${DROPIN_DIR}"
  TARGET="${DROPIN}"
  run ${SUDO} touch "${TARGET}"
  info "Using drop-in: ${TARGET}"
else
  TARGET="${SSHD_MAIN}"
  info "Editing main config: ${TARGET}"
fi

# backup
BACKUP="${SSHD_MAIN}.bak.$(date +%s 2>/dev/null || echo bak)"
run ${SUDO} cp "${SSHD_MAIN}" "${BACKUP}"
[ "${TARGET}" != "${SSHD_MAIN}" ] && ${SUDO} cp "${TARGET}" "${TARGET}.bak" 2>/dev/null || true
info "Backup: ${BACKUP}"

# apply settings
set_opt "Port" "${PORT}" "${TARGET}"
[[ "${ROOT_ANS}"   =~ ^(n|N|no)$ ]] || set_opt "PermitRootLogin" "no" "${TARGET}"
[[ "${PUBKEY_ANS}" =~ ^(n|N|no)$ ]] || set_opt "PubkeyAuthentication" "yes" "${TARGET}"
[[ "${PWAUTH_ANS}" =~ ^(y|Y|yes)$ ]] && set_opt "PasswordAuthentication" "no" "${TARGET}"
ok "Applied SSH settings."

# open the new port in the firewall BEFORE restarting sshd
if command -v ufw >/dev/null 2>&1; then
  info "Allowing ${PORT}/tcp in ufw (before restart)..."
  ${SUDO} ufw allow "${PORT}/tcp" || warn "Failed to add ufw rule for ${PORT}."
else
  warn "ufw not installed. Make sure ${PORT}/tcp is open in your firewall/security group."
fi

# validate config before restarting
if ! ${SUDO} sshd -t; then
  err "sshd config test FAILED. Restoring backup; NOT restarting."
  run ${SUDO} cp "${BACKUP}" "${SSHD_MAIN}"
  [ "${TARGET}" != "${SSHD_MAIN}" ] && ${SUDO} rm -f "${TARGET}"
  exit 1
fi
ok "sshd -t passed."

RESTART="$(ask "Restart SSH now to apply port ${PORT}? [y/N]:" "n")"
case "${RESTART}" in
  y|Y|yes)
    run ${SUDO} systemctl restart ssh 2>/dev/null || run ${SUDO} systemctl restart sshd 2>/dev/null || warn "Could not restart ssh; restart manually."
    ok "SSH restarted on port ${PORT}."
    ;;
  *) info "Not restarted. Apply later with: run ${SUDO} systemctl restart ssh" ;;
esac

# optionally remove the old port 22 rule (ask, default keep to avoid lockout)
if command -v ufw >/dev/null 2>&1 && [ "${PORT}" != "22" ]; then
  DROP22="$(ask "Remove the old ufw rule for 22/tcp / OpenSSH? (only after the new port works) [y/N]:" "n")"
  case "${DROP22}" in
    y|Y|yes)
      ${SUDO} ufw delete allow OpenSSH 2>/dev/null || true
      ${SUDO} ufw delete allow 22/tcp 2>/dev/null || true
      ok "Removed old SSH (22) rules."
      ;;
    *) info "Kept port 22 rule. Remove it later once ${PORT} is verified." ;;
  esac
fi

printf "\n%b✔ SSH hardening applied.%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
printf "%b  TEST NOW in a new terminal: ssh -p %s <user>@<host>%b\n" "${C_YELLOW}" "${PORT}" "${C_RESET}" >&2
printf "%b  Keep this session open until the new port works.%b\n\n" "${C_DIM}" "${C_RESET}" >&2
