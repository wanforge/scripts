#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# manage-users.sh — interactive Linux user manager for server and SSH access.
# Covers create/delete users, reset passwords, lock/unlock accounts, shell
# changes, sudo access, and SSH public-key management.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/security/manage-users.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="manage-users"

# --- shared library: banner, colors, logging, prompts, menus --------------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load
wf_log_init

[ "$(id -u)" -eq 0 ] || command -v sudo >/dev/null 2>&1 || { err "sudo is required when not running as root."; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }
req() { [ -n "$1" ] || { err "$2 is required."; return 1; }; }
user_exists() { id "$1" >/dev/null 2>&1; }
passwd_state() { passwd -S "$1" 2>/dev/null | awk 'NR==1 {print $2}'; }
is_locked() { [ "$(passwd_state "$1")" = "L" ]; }
user_home() { getent passwd "$1" | cut -d: -f6; }
user_shell() { getent passwd "$1" | cut -d: -f7; }
user_gecos() { getent passwd "$1" | cut -d: -f5; }
primary_group() { id -gn "$1" 2>/dev/null || echo "$1"; }
sudo_group() {
  if getent group sudo >/dev/null 2>&1; then echo sudo
  elif getent group wheel >/dev/null 2>&1; then echo wheel
  else echo ""; fi
}
in_group() { id -nG "$1" 2>/dev/null | tr ' ' '\n' | grep -Fxq "$2"; }
is_sudo_user() { local g; g="$(sudo_group)"; [ -n "$g" ] && in_group "$1" "$g"; }
ssh_dir() { printf '%s/.ssh' "$(user_home "$1")"; }
ssh_key_file() { printf '%s/authorized_keys' "$(ssh_dir "$1")"; }
has_ssh_keys() { [ -s "$(ssh_key_file "$1")" ]; }

ensure_user() {
  local u="$1"
  user_exists "$u" || { err "User '${u}' not found."; return 1; }
}

add_sudo() {
  local u="$1" g
  g="$(sudo_group)"
  [ -n "$g" ] || { err "No sudo or wheel group found on this system."; return 1; }
  if in_group "$u" "$g"; then
    info "${u} already has ${g} access."
  else
    run ${SUDO} usermod -aG "$g" "$u"
    ok "Granted ${g} access to ${u}."
  fi
}

remove_sudo() {
  local u="$1" g
  g="$(sudo_group)"
  [ -n "$g" ] || { err "No sudo or wheel group found on this system."; return 1; }
  if in_group "$u" "$g"; then
    run ${SUDO} gpasswd -d "$u" "$g"
    ok "Removed ${u} from ${g}."
  else
    info "${u} is not a member of ${g}."
  fi
}

set_password() {
  local u="$1" p c
  p="$(asks "New password for ${u}:")"
  req "$p" password || return 1
  c="$(asks "Confirm password for ${u}:")"
  [ "$p" = "$c" ] || { err "Passwords do not match."; return 1; }
  printf '%s:%s\n' "$u" "$p" | run ${SUDO} chpasswd
  ok "Password updated for ${u}."
}

add_ssh_key() {
  local u="$1" key dir file grp
  key="$(ask "Paste SSH public key for ${u}:" "")"
  req "$key" ssh-key || return 1
  dir="$(ssh_dir "$u")"
  file="$(ssh_key_file "$u")"
  grp="$(primary_group "$u")"
  run ${SUDO} install -d -m 700 -o "$u" -g "$grp" "$dir"
  if ${SUDO} test -f "$file" && ${SUDO} grep -Fxq "$key" "$file"; then
    info "Key already exists for ${u}."
    return 0
  fi
  printf '%s\n' "$key" | run ${SUDO} tee -a "$file" >/dev/null
  run ${SUDO} chown "$u:$grp" "$file"
  run ${SUDO} chmod 600 "$file"
  ok "SSH key added for ${u}."
}

clear_ssh_keys() {
  local u="$1" file ans
  file="$(ssh_key_file "$u")"
  [ -e "$file" ] || { info "No authorized_keys file for ${u}."; return 0; }
  confirm_critical "delete all SSH keys for ${u} (${file})" || return 0
  run ${SUDO} rm -f "$file"; ok "SSH keys removed for ${u}."
}

list_users() {
  hd "Linux users"
  local any=0 u uid shell home gecos flag sshflag
  while IFS=: read -r u _ uid _ gecos home shell; do
    [ "$u" = "root" ] || [ "$uid" -ge 1000 ] || continue
    any=1
    flag=""
    is_sudo_user "$u" && flag="${flag}${flag:+ }sudo"
    is_locked "$u" && flag="${flag}${flag:+ }locked"
    has_ssh_keys "$u" && flag="${flag}${flag:+ }ssh"
    [ -n "$flag" ] || flag="user"
    printf "  %b●%b %-16s uid=%-5s %-18s shell=%-18s home=%-24s %s\n" \
      "${C_GREEN}" "${C_RESET}" "$u" "$uid" "${flag}" "${shell}" "${home}" >&2
    [ -n "$gecos" ] && printf "      %bname:%b %s\n" "${C_DIM}" "${C_RESET}" "${gecos}" >&2
  done < <(getent passwd | sort -t: -k3,3n)
  [ "$any" -eq 1 ] || warn "No users found."
}

# ---- actions -------------------------------------------------------------
a_user_add() {
  local u gecos shell home_yn pass sudo_yn ssh_yn key grp
  u="$(ask 'Username:')"
  req "$u" username || return 1
  user_exists "$u" && { err "User '${u}' already exists."; return 1; }
  gecos="$(ask 'Full name / comment:' "$u")"
  shell="$(ask_cfg CFG_MU_SHELL 'Login shell:' '/bin/bash')"
  home_yn="$(ask 'Create home directory? [Y/n]:' 'y')"
  pass="$(asks 'Initial password (blank = no password):')"
  sudo_yn="$(ask_cfg CFG_MU_SUDO 'Grant sudo access? [y/N]:' 'n')"
  ssh_yn="$(ask 'Add SSH public key now? [y/N]:' 'n')"

  case "$ssh_yn" in y|Y|yes)
    case "$home_yn" in n|N|no)
      warn "SSH keys need a home directory; creating one."
      home_yn="y"
      ;;
    esac
  esac

  if [ "$home_yn" = "n" ] || [ "$home_yn" = "N" ] || [ "$home_yn" = "no" ]; then
    run ${SUDO} useradd -M -s "$shell" -c "$gecos" "$u"
  else
    run ${SUDO} useradd -m -s "$shell" -c "$gecos" "$u"
  fi
  [ -n "$pass" ] && printf '%s:%s\n' "$u" "$pass" | run ${SUDO} chpasswd
  case "$sudo_yn" in y|Y|yes) add_sudo "$u" ;; esac
  case "$ssh_yn" in y|Y|yes) add_ssh_key "$u" ;; esac
  if [ -d "$(user_home "$u")" ]; then
    grp="$(primary_group "$u")"
    run ${SUDO} chown -R "$u:$grp" "$(user_home "$u")"
  fi
  ok "User ${u} created."
}

a_user_delete() {
  local u home_yn kill_yn
  u="$(ask 'Username to delete:')"
  req "$u" username || return 1
  ensure_user "$u" || return 1
  [ "$u" = "root" ] && { err "Refusing to delete root."; return 1; }
  confirm_critical "permanently delete user account '${u}' from this system" || return 0
  home_yn="$(ask 'Remove home directory too? [y/N]:' 'n')"
  kill_yn="$(ask 'Kill running processes for this user first? [y/N]:' 'n')"
  case "$kill_yn" in y|Y|yes) run ${SUDO} bash -c "pkill -u '$u' || true" ;; esac
  case "$home_yn" in y|Y|yes) run ${SUDO} userdel -r "$u" ;; *) run ${SUDO} userdel "$u" ;; esac
  ok "User ${u} deleted."
}

a_password() { local u; u="$(ask 'Username:')"; req "$u" username || return 1; ensure_user "$u" || return 1; set_password "$u"; }
a_lock() { local u; u="$(ask 'Username:')"; req "$u" username || return 1; ensure_user "$u" || return 1; run ${SUDO} usermod -L "$u"; ok "Locked ${u}."; }
a_unlock() { local u; u="$(ask 'Username:')"; req "$u" username || return 1; ensure_user "$u" || return 1; run ${SUDO} usermod -U "$u"; ok "Unlocked ${u}."; }
a_shell() {
  local u sh
  u="$(ask 'Username:')"
  req "$u" username || return 1
  ensure_user "$u" || return 1
  sh="$(ask 'New login shell:' '/bin/bash')"
  [ -x "$sh" ] || warn "Shell ${sh} does not exist or is not executable."
  run ${SUDO} usermod -s "$sh" "$u"
  ok "Shell updated for ${u}."
}
a_sudo_add() { local u; u="$(ask 'Username:')"; req "$u" username || return 1; ensure_user "$u" || return 1; add_sudo "$u"; }
a_sudo_remove() { local u; u="$(ask 'Username:')"; req "$u" username || return 1; ensure_user "$u" || return 1; remove_sudo "$u"; }

a_sudo_nopasswd() {
  local u file
  u="$(ask 'Username for passwordless sudo:')"
  req "$u" username || return 1
  ensure_user "$u" || return 1
  is_sudo_user "$u" || { warn "${u} has no sudo access. Granting first..."; add_sudo "$u" || return 1; }
  file="/etc/sudoers.d/90-nopasswd-${u}"
  if ${SUDO} test -f "$file"; then
    info "Passwordless sudo already configured for ${u} (${file})."; return 0
  fi
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$u" | run ${SUDO} tee "$file" >/dev/null
  run ${SUDO} chmod 440 "$file"
  if ${SUDO} visudo -cf "$file" >/dev/null 2>&1; then
    ok "Passwordless sudo enabled for ${u}."
  else
    err "Sudoers syntax check failed. Removing ${file}."
    run ${SUDO} rm -f "$file"; return 1
  fi
}

a_sudo_nopasswd_remove() {
  local u file
  u="$(ask 'Username to remove passwordless sudo:')"
  req "$u" username || return 1
  ensure_user "$u" || return 1
  file="/etc/sudoers.d/90-nopasswd-${u}"
  if ! ${SUDO} test -f "$file"; then
    info "No passwordless sudoers file for ${u}."; return 0
  fi
  run ${SUDO} rm -f "$file"
  ok "Passwordless sudo removed for ${u}. Normal sudo still active if in $(sudo_group) group."
}
a_ssh_add() { local u; u="$(ask 'Username:')"; req "$u" username || return 1; ensure_user "$u" || return 1; add_ssh_key "$u"; }
a_ssh_clear() { local u; u="$(ask 'Username:')"; req "$u" username || return 1; ensure_user "$u" || return 1; clear_ssh_keys "$u"; }
a_view() {
  local u
  u="$(ask 'Username:')"
  req "$u" username || return 1
  ensure_user "$u" || return 1
  hd "User details: ${u}"
  printf "  %buid:%b %s\n" "${C_DIM}" "${C_RESET}" "$(id -u "$u")" >&2
  printf "  %bgroup:%b %s\n" "${C_DIM}" "${C_RESET}" "$(id -gn "$u")" >&2
  printf "  %bhome:%b %s\n" "${C_DIM}" "${C_RESET}" "$(user_home "$u")" >&2
  printf "  %bshell:%b %s\n" "${C_DIM}" "${C_RESET}" "$(user_shell "$u")" >&2
  printf "  %bstate:%b %s\n" "${C_DIM}" "${C_RESET}" "$(is_locked "$u" && echo locked || echo active)" >&2
  if is_sudo_user "$u"; then printf "  %bsudo:%b yes (%s)\n" "${C_DIM}" "${C_RESET}" "$(sudo_group)" >&2; else printf "  %bsudo:%b no\n" "${C_DIM}" "${C_RESET}" >&2; fi
  if has_ssh_keys "$u"; then printf "  %bssh:%b yes\n" "${C_DIM}" "${C_RESET}" >&2; ${SUDO} sed -n '1,5p' "$(ssh_key_file "$u")" >&2; else printf "  %bssh:%b no\n" "${C_DIM}" "${C_RESET}" >&2; fi
  [ -n "$(user_gecos "$u")" ] && printf "  %bname:%b %s\n" "${C_DIM}" "${C_RESET}" "$(user_gecos "$u")" >&2
}

# ---- menu ---------------------------------------------------------------
MENU=(
  "Users|list|list users"
  "Users|add|create user"
  "Users|delete|delete user"
  "Users|password|change password"
  "Users|lock|lock account"
  "Users|unlock|unlock account"
  "Users|shell|change login shell"
  "Privileges|sudo_add|grant sudo access"
  "Privileges|sudo_remove|remove sudo access"
  "Privileges|nopasswd|enable passwordless sudo"
  "Privileges|nopasswd_rm|remove passwordless sudo"
  "SSH|ssh_add|add SSH public key"
  "SSH|ssh_clear|remove SSH keys"
  "Info|view|show user details"
  "Config|clear_cfg|clear saved config (shell default, sudo default)"
)

# ---- run ----------------------------------------------------------------
banner
while true; do
  printf "\n" >&2
  menu_select "Manage Linux users:" || break
  case "${MENU_KEY}" in
    list) list_users ;;
    add) a_user_add ;;
    delete) a_user_delete ;;
    password) a_password ;;
    lock) a_lock ;;
    unlock) a_unlock ;;
    shell) a_shell ;;
    sudo_add) a_sudo_add ;;
    sudo_remove) a_sudo_remove ;;
    nopasswd) a_sudo_nopasswd ;;
    nopasswd_rm) a_sudo_nopasswd_remove ;;
    ssh_add) a_ssh_add ;;
    ssh_clear) a_ssh_clear ;;
    view) a_view ;;
    clear_cfg) cfg_clear && ok "Saved config cleared." ;;
  esac
done

printf "\n%b✔ manage-users finished.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
