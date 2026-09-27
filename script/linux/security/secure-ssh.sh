#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# secure-ssh.sh — harden OpenSSH server:
#   - Change SSH port (1-65535) with SELinux & firewall pre-opening
#   - Disable root login (PermitRootLogin no / prohibit-password)
#   - Enforce public key authentication
#   - Safely disable password authentication with authorized_keys lockout guard
#   - Apply CIS benchmark directives (X11Forwarding no, MaxAuthTries 3, LoginGraceTime 30)
#   - Multi-distro firewall support: ufw & firewalld
#   - Handles Ubuntu 24.04 ssh.socket vs ssh.service activation
#   - Automated config backup, sshd -t syntax test, and safe rollback
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
if   [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
elif [ -r "${__d}/lib.sh" ]; then . "${__d}/lib.sh"
elif [ -n "${WF_INSTALL_DIR:-}" ] && [ -r "${WF_INSTALL_DIR}/lib.sh" ]; then . "${WF_INSTALL_DIR}/lib.sh"
elif [ -r "/opt/wanforge-scripts/lib.sh" ]; then . "/opt/wanforge-scripts/lib.sh"
elif [ -r "${HOME:-}/.local/lib/wanforge-scripts/lib.sh" ]; then . "${HOME}/.local/lib/wanforge-scripts/lib.sh"
elif command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}")
else . <(wget -qO- "${__LIB}"); fi
cfg_load
wf_log_init

DEFAULT_PORT="22"
SSHD_MAIN="/etc/ssh/sshd_config"
DROPIN_DIR="/etc/ssh/sshd_config.d"
DROPIN="${DROPIN_DIR}/99-wanforge-hardening.conf"

# --- service & system detection -------------------------------------------
detect_ssh_service() {
  if systemctl is-active ssh.socket >/dev/null 2>&1 || systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    echo "ssh.socket"
  elif systemctl list-unit-files ssh.service >/dev/null 2>&1; then
    echo "ssh"
  elif systemctl list-unit-files sshd.service >/dev/null 2>&1; then
    echo "sshd"
  elif [ -f /etc/init.d/ssh ]; then
    echo "ssh"
  elif [ -f /etc/init.d/sshd ]; then
    echo "sshd"
  else
    echo "sshd"
  fi
}

get_current_ports() {
  local ports=()
  if command -v ss >/dev/null 2>&1; then
    while IFS= read -r p; do
      [ -n "$p" ] && ports+=("$p")
    done < <(ss -tlpn 2>/dev/null | grep -E '\b(sshd|ssh)\b' | awk '{print $4}' | awk -F: '{print $NF}' | sort -un || true)
  fi
  if [ "${#ports[@]}" -eq 0 ] && [ -r "${SSHD_MAIN}" ]; then
    local conf_ports
    conf_ports="$(grep -rE '^[#[:space:]]*Port\s+[0-9]+' /etc/ssh/ 2>/dev/null | grep -v '^[#[:space:]]*#' | awk '{print $2}' | sort -un || true)"
    for cp in ${conf_ports}; do ports+=("${cp}"); done
  fi
  if [ "${#ports[@]}" -eq 0 ]; then
    echo "22"
  else
    echo "${ports[*]}"
  fi
}

detect_firewall() {
  if command -v ufw >/dev/null 2>&1 && ${SUDO} ufw status 2>/dev/null | grep -qi "Status: active"; then
    echo "ufw"
  elif command -v firewall-cmd >/dev/null 2>&1 && ${SUDO} firewall-cmd --state >/dev/null 2>&1; then
    echo "firewalld"
  else
    echo "none"
  fi
}

firewall_allow_port() {
  local p="$1"
  local fw; fw="$(detect_firewall)"
  case "${fw}" in
    ufw)
      sub "Membuka port ${p}/tcp di ufw..."
      run ${SUDO} ufw allow "${p}/tcp" || warn "Gagal menambahkan aturan ufw untuk port ${p}."
      ;;
    firewalld)
      sub "Membuka port ${p}/tcp di firewalld..."
      run ${SUDO} firewall-cmd --permanent --add-port="${p}/tcp" || true
      run ${SUDO} firewall-cmd --reload || true
      ;;
    *)
      warn "Firewall lokal aktif tidak terdeteksi. Pastikan port ${p}/tcp diizinkan di Cloud Security Group (AWS/GCP/DigitalOcean/IDCloudHost)."
      ;;
  esac
}

firewall_delete_port() {
  local p="$1"
  local fw; fw="$(detect_firewall)"
  case "${fw}" in
    ufw)
      sub "Removing old rule for port ${p}/tcp in ufw..."
      run ${SUDO} ufw delete allow "${p}/tcp" 2>/dev/null || true
      [ "${p}" = "22" ] && run ${SUDO} ufw delete allow OpenSSH 2>/dev/null || true
      ;;
    firewalld)
      sub "Removing old rule for port ${p}/tcp in firewalld..."
      run ${SUDO} firewall-cmd --permanent --remove-port="${p}/tcp" 2>/dev/null || true
      [ "${p}" = "22" ] && run ${SUDO} firewall-cmd --permanent --remove-service=ssh 2>/dev/null || true
      run ${SUDO} firewall-cmd --reload 2>/dev/null || true
      ;;
  esac
}

selinux_allow_port() {
  local p="$1"
  [ "${p}" = "22" ] && return 0
  if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null || echo 'Disabled')" != "Disabled" ]; then
    sub "Registering port ${p}/tcp with SELinux policy (ssh_port_t)..."
    if command -v semanage >/dev/null 2>&1; then
      run ${SUDO} semanage port -a -t ssh_port_t -p tcp "${p}" 2>/dev/null || \
      run ${SUDO} semanage port -m -t ssh_port_t -p tcp "${p}" 2>/dev/null || true
    else
      warn "SELinux aktif namun utilitas 'semanage' belum terpasang. Paket policycoreutils-python-utils mungkin diperlukan."
    fi
  fi
}

set_opt() {
  local key="$1" val="$2" file="$3"
  if ${SUDO} grep -qE "^[#[:space:]]*${key}\b" "${file}" 2>/dev/null; then
    run ${SUDO} sed -i "s|^[#[:space:]]*${key}\b.*|${key} ${val}|" "${file}"
  else
    echo "${key} ${val}" | run ${SUDO} tee -a "${file}" >/dev/null
  fi
}

# --- Action 1: Status & Security Audit -------------------------------------
a_status() {
  hd "Audit Keamanan & Status SSH Server"
  local svc; svc="$(detect_ssh_service)"
  local ports; ports="$(get_current_ports)"
  local fw; fw="$(detect_firewall)"

  printf "\n%b[1] Status Layanan Daemon:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  if systemctl is-active "${svc}" >/dev/null 2>&1; then
    ok "Daemon SSH aktif: ${svc} (Running)"
  else
    warn "Daemon SSH tidak aktif atau stopped (${svc})."
  fi
  info "Port aktif listening: ${ports}"

  printf "\n%b[2] Parameter Konfigurasi Efektif:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  local p_root="unknown" p_pubkey="unknown" p_pw="unknown" p_x11="unknown" p_tries="unknown"
  if command -v sshd >/dev/null 2>&1; then
    local sshd_out; sshd_out="$(${SUDO} sshd -T 2>/dev/null || true)"
    if [ -n "${sshd_out}" ]; then
      p_root="$(echo "${sshd_out}" | grep -i '^permitrootlogin' | awk '{print $2}' || echo 'unknown')"
      p_pubkey="$(echo "${sshd_out}" | grep -i '^pubkeyauthentication' | awk '{print $2}' || echo 'unknown')"
      p_pw="$(echo "${sshd_out}" | grep -i '^passwordauthentication' | awk '{print $2}' || echo 'unknown')"
      p_x11="$(echo "${sshd_out}" | grep -i '^x11forwarding' | awk '{print $2}' || echo 'unknown')"
      p_tries="$(echo "${sshd_out}" | grep -i '^maxauthtries' | awk '{print $2}' || echo 'unknown')"
    fi
  fi
  if [ "${p_root}" = "unknown" ]; then
    p_root="$(${SUDO} grep -rhE '^[#[:space:]]*PermitRootLogin\b' /etc/ssh/ 2>/dev/null | grep -v '^[#[:space:]]*#' | awk '{print $2}' | tail -n1 || echo 'prohibit-password (default)')"
    p_pubkey="$(${SUDO} grep -rhE '^[#[:space:]]*PubkeyAuthentication\b' /etc/ssh/ 2>/dev/null | grep -v '^[#[:space:]]*#' | awk '{print $2}' | tail -n1 || echo 'yes (default)')"
    p_pw="$(${SUDO} grep -rhE '^[#[:space:]]*PasswordAuthentication\b' /etc/ssh/ 2>/dev/null | grep -v '^[#[:space:]]*#' | awk '{print $2}' | tail -n1 || echo 'yes (default)')"
    p_x11="$(${SUDO} grep -rhE '^[#[:space:]]*X11Forwarding\b' /etc/ssh/ 2>/dev/null | grep -v '^[#[:space:]]*#' | awk '{print $2}' | tail -n1 || echo 'no (default)')"
    p_tries="$(${SUDO} grep -rhE '^[#[:space:]]*MaxAuthTries\b' /etc/ssh/ 2>/dev/null | grep -v '^[#[:space:]]*#' | awk '{print $2}' | tail -n1 || echo '6 (default)')"
  fi

  printf "  • PermitRootLogin       : %b%s%b\n" "${C_YELLOW}" "${p_root}" "${C_RESET}"
  printf "  • PubkeyAuthentication  : %b%s%b\n" "${C_YELLOW}" "${p_pubkey}" "${C_RESET}"
  printf "  • PasswordAuthentication: %b%s%b\n" "${C_YELLOW}" "${p_pw}" "${C_RESET}"
  printf "  • X11Forwarding         : %b%s%b\n" "${C_YELLOW}" "${p_x11}" "${C_RESET}"
  printf "  • MaxAuthTries          : %b%s%b\n" "${C_YELLOW}" "${p_tries}" "${C_RESET}"

  printf "\n%b[3] Kunci Publik Terdaftar (authorized_keys):%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  local u_auth="${HOME}/.ssh/authorized_keys"
  local r_auth="/root/.ssh/authorized_keys"
  local u_count=0 r_count=0
  [ -f "${u_auth}" ] && u_count="$(grep -cE '^(ssh-|ecdsa-|sk-)' "${u_auth}" 2>/dev/null || echo 0)"
  [ -f "${r_auth}" ] && r_count="$(grep -cE '^(ssh-|ecdsa-|sk-)' "${r_auth}" 2>/dev/null || echo 0)"

  printf "  • User lokal (%s): %d key terdaftar (%s)\n" "$(id -un)" "${u_count}" "${u_auth}"
  if [ "$(id -u)" -eq 0 ] || [ -r "${r_auth}" ]; then
    printf "  • User root       : %d key terdaftar (%s)\n" "${r_count}" "${r_auth}"
  fi
  if [ "${u_count}" -eq 0 ] && [ "${r_count}" -eq 0 ]; then
    warn "PERINGATAN: Tidak ada public key di authorized_keys! Mematikan password auth akan menyebabkan LOCKOUT."
  else
    ok "Kunci public key ditemukan di sistem."
  fi

  printf "\n%b[4] Firewall & Proteksi:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  case "${fw}" in
    ufw)       ok "Firewall aktif: UFW" ;;
    firewalld) ok "Firewall aktif: firewalld" ;;
    none)      warn "Tidak ada firewall lokal aktif (UFW/firewalld)." ;;
  esac

  if command -v getenforce >/dev/null 2>&1; then
    local se_status; se_status="$(getenforce 2>/dev/null || echo 'Unknown')"
    info "Status SELinux: ${se_status}"
  fi

  printf "\n%b[5] Status Akses Sudo (NOPASSWD):%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  if ${SUDO} grep -rhE 'NOPASSWD:\s*ALL' /etc/sudoers /etc/sudoers.d/ 2>/dev/null | grep -v '^[#[:space:]]*#' | grep -q .; then
    ok "Passwordless sudo aktif: 'sudo su' bebas password (standar Cloud VPS)."
  else
    info "Sudo masih memerlukan password (belum diatur NOPASSWD)."
  fi
  printf "\n"
}

# --- Action 2: Install OpenSSH --------------------------------------------
a_install() {
  hd "Install OpenSSH Server"
  local svc; svc="$(detect_ssh_service)"
  if systemctl is-active "${svc}" >/dev/null 2>&1; then
    ok "OpenSSH server sudah terpasang dan berjalan (${svc})."; return 0
  fi
  info "Memasang paket openssh-server..."
  if command -v apt-get >/dev/null 2>&1; then
    run ${SUDO} apt-get update -qq
    run ${SUDO} apt-get install -y openssh-server
  elif command -v dnf >/dev/null 2>&1; then
    run ${SUDO} dnf install -y openssh-server
  elif command -v yum >/dev/null 2>&1; then
    run ${SUDO} yum install -y openssh-server
  elif command -v pacman >/dev/null 2>&1; then
    run ${SUDO} pacman -S --noconfirm openssh
  elif command -v apk >/dev/null 2>&1; then
    run ${SUDO} apk add openssh
  else
    err "Package manager tidak didukung."; return 1
  fi

  svc="$(detect_ssh_service)"
  run ${SUDO} systemctl enable "${svc}" 2>/dev/null || true
  run ${SUDO} systemctl start "${svc}" 2>/dev/null || true
  ok "OpenSSH server installed and enabled successfully."
}

# --- Action 3: Key Management Helper --------------------------------------
a_key_helper() {
  hd "Manage SSH Public Keys (authorized_keys)"
  local auth_file="${HOME}/.ssh/authorized_keys"
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  touch "${auth_file}"
  chmod 600 "${auth_file}"

  printf "Select SSH key action:\n"
  printf "  [1] Paste new Public Key into authorized_keys\n"
  printf "  [2] Generate new SSH Key Pair (ed25519)\n"
  printf "  [3] Display currently authorized Public Keys\n"
  printf "  [0] Back\n\n"

  local opt; opt="$(ask "Your choice" "1")"
  case "${opt}" in
    1)
      printf "\n%bPaste your OpenSSH public key line (e.g. ssh-ed25519 AAAAC3... user@host):%b\n" "${C_YELLOW}" "${C_RESET}"
      local new_key; read -r new_key
      if [[ "${new_key}" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-|«redacted:sk-…») ]]; then
        echo "${new_key}" >> "${auth_file}"
        ok "Public key added to ${auth_file}."
      else
        err "Invalid public key format. Must begin with ssh-ed25519, ssh-rsa, or ecdsa."
      fi
      ;;
    2)
      if [ -f "${__d}/generate-ssh-key.sh" ]; then
        bash "${__d}/generate-ssh-key.sh" || true
      else
        info "Menjalankan ssh-keygen ed25519..."
        local kpath="${HOME}/.ssh/id_ed25519"
        ssh-keygen -t ed25519 -f "${kpath}" -N "" -C "$(id -un)@$(hostname -s 2>/dev/null || hostname)"
        cat "${kpath}.pub" >> "${auth_file}"
        ok "Kunci dibuat dan otomatis didaftarkan ke ${auth_file}."
      fi
      ;;
    3)
      if [ -s "${auth_file}" ]; then
        printf "\n%bKunci di %s:%b\n" "${C_BOLD}" "${auth_file}" "${C_RESET}"
        cat -n "${auth_file}"
      else
        warn "Berkas ${auth_file} masih kosong."
      fi
      ;;
    *) return 0 ;;
  esac
}

# --- Action 4: Configure & Harden SSH -------------------------------------
a_configure() {
  hd "Konfigurasi & Hardening SSH Server"
  [ -f "${SSHD_MAIN}" ] || { err "${SSHD_MAIN} tidak ditemukan. Pasang openssh-server terlebih dahulu."; return 1; }

  warn "PERINGATAN PENTING:"
  warn "Mengubah port SSH dan mematikan autentikasi password berisiko LOCKOUT."
  warn "JANGAN TUTUP SESI INI sampai Anda memverifikasi login di terminal baru."

  # 1. Port SSH
  local cur_ports; cur_ports="$(get_current_ports)"
  info "Port SSH saat ini: ${cur_ports}"
  local port; port="$(ask_cfg CFG_SSH_PORT "Masukkan Port SSH Baru" "${DEFAULT_PORT}")"
  if ! [[ "${port}" =~ ^[0-9]+$ ]] || [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
    err "Port '${port}' tidak valid. Harus angka antara 1 sampai 65535."; return 1
  fi

  # 2. Root login
  printf "\n"
  info "Pengaturan Akses Root:"
  info "  • no: Matikan login root sepenuhnya (Sangat Disarankan, login via user biasa + sudo)"
  info "  • prohibit-password: Hanya izinkan root dengan SSH key (tidak bisa pakai password)"
  info "  • yes: Izinkan root login (Kurang aman)"
  local root_choice; root_choice="$(ask_cfg CFG_SSH_ROOT_LOGIN "PermitRootLogin [no / prohibit-password / yes]" "no")"
  case "${root_choice}" in
    prohibit-password|without-password) root_choice="prohibit-password" ;;
    yes|y|Y) root_choice="yes" ;;
    *) root_choice="no" ;;
  esac

  # 3. Public Key Authentication
  local pubkey_choice="yes"

  # 4. Password Authentication & Lockout Guard
  printf "\n"
  local pwauth_ans; pwauth_ans="$(ask_cfg CFG_SSH_PWAUTH "Matikan autentikasi password (hanya login via SSH Key)? [y/N]" "n")"
  local disable_pw=0
  if [[ "${pwauth_ans}" =~ ^(y|Y|yes)$ ]]; then
    local keyfound=0
    for f in "${HOME}/.ssh/authorized_keys" /root/.ssh/authorized_keys; do
      if [ -s "$f" ] && grep -qE '^(ssh-|ecdsa-|sk-)' "$f" 2>/dev/null; then
        keyfound=1
      fi
    done
    if [ "${keyfound}" -eq 0 ]; then
      warn "⚠ BAHAYA: Tidak ditemukan public key di ~/.ssh/authorized_keys!"
      warn "Jika password dimatikan sekarang, server TIDAK AKAN BISA DIAKSES (LOCKOUT)!"
      printf "\nPilihan Pengamanan:\n"
      printf "  [1] Tambahkan public key sekarang\n"
      printf "  [2] Tetap izinkan login password (Batal matikan password)\n"
      local sec_pick; sec_pick="$(ask "Pilihan Anda" "2")"
      if [ "${sec_pick}" = "1" ]; then
        a_key_helper
        # Re-check
        for f in "${HOME}/.ssh/authorized_keys" /root/.ssh/authorized_keys; do
          [ -s "$f" ] && grep -qE '^(ssh-|ecdsa-|sk-)' "$f" 2>/dev/null && keyfound=1
        done
        if [ "${keyfound}" -eq 1 ]; then
          disable_pw=1
          ok "Public key terverifikasi. Autentikasi password akan dimatikan."
        else
          warn "Kunci masih belum terdeteksi. Autentikasi password TETAP DIAKTIFKAN demi keselamatan."
          disable_pw=0
        fi
      else
        info "Autentikasi password tetap diaktifkan demi keselamatan."
        disable_pw=0
      fi
    else
      disable_pw=1
      ok "SSH public key terverifikasi di authorized_keys."
    fi
  fi

  # 5. Passwordless Sudo (Cloud VPS Standard)
  printf "\n"
  info "Sudoers Policy (Cloud VPS Standard):"
  info "  Mengizinkan 'sudo su' atau perintah root tanpa meminta password lagi (seperti VPS cloud default)."
  local nopasswd_ans; nopasswd_ans="$(ask_cfg CFG_SSH_NOPASSWD "Aktifkan sudo tanpa password (NOPASSWD untuk sudo / sudo su)? [Y/n]" "y")"
  local enable_nopasswd=0
  if [[ "${nopasswd_ans}" =~ ^(y|Y|yes|1)$ ]]; then
    enable_nopasswd=1
  fi

  # 6. Advanced hardening parameters
  local max_tries="3"
  local grace_time="30"
  local x11_fwd="no"
  local alive_interval="300"
  local alive_count="2"

  # 7. Target Config Resolution & Backup
  local target_file=""
  local ts; ts="$(date +%Y%m%d_%H%M%S)"
  local backup_file="${SSHD_MAIN}.bak.${ts}"

  run ${SUDO} cp "${SSHD_MAIN}" "${backup_file}"
  info "Backup sshd_config dibuat: ${backup_file}"

  if [ -d "${DROPIN_DIR}" ] || ${SUDO} grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' "${SSHD_MAIN}"; then
    run ${SUDO} mkdir -p "${DROPIN_DIR}"
    target_file="${DROPIN}"
    if ! ${SUDO} grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' "${SSHD_MAIN}"; then
      # Prepend Include line to main config
      local tmp_conf; tmp_conf="$(mktemp)"
      echo "Include /etc/ssh/sshd_config.d/*.conf" > "${tmp_conf}"
      cat "${SSHD_MAIN}" >> "${tmp_conf}"
      run ${SUDO} cp "${tmp_conf}" "${SSHD_MAIN}"
      rm -f "${tmp_conf}"
    fi
    info "Menulis hardening ke drop-in: ${target_file}"
  else
    target_file="${SSHD_MAIN}"
    info "Menulis hardening langsung ke main config: ${target_file}"
  fi

  # 7. Apply Hardening Directives
  local pw_val="yes"
  [ "${disable_pw}" -eq 1 ] && pw_val="no"

  sub "Menerapkan konfigurasi SSH..."
  if [ "${target_file}" = "${DROPIN}" ]; then
    cat <<EOF | run ${SUDO} tee "${target_file}" >/dev/null
# WanForge SSH Hardening Profile
# Generated: $(date)
Port ${port}
PermitRootLogin ${root_choice}
PubkeyAuthentication ${pubkey_choice}
PasswordAuthentication ${pw_val}
KbdInteractiveAuthentication ${pw_val}
ChallengeResponseAuthentication ${pw_val}
X11Forwarding ${x11_fwd}
MaxAuthTries ${max_tries}
LoginGraceTime ${grace_time}
PermitEmptyPasswords no
ClientAliveInterval ${alive_interval}
ClientAliveCountMax ${alive_count}
EOF
  else
    set_opt "Port" "${port}" "${target_file}"
    set_opt "PermitRootLogin" "${root_choice}" "${target_file}"
    set_opt "PubkeyAuthentication" "${pubkey_choice}" "${target_file}"
    set_opt "PasswordAuthentication" "${pw_val}" "${target_file}"
    set_opt "KbdInteractiveAuthentication" "${pw_val}" "${target_file}"
    set_opt "ChallengeResponseAuthentication" "${pw_val}" "${target_file}"
    set_opt "X11Forwarding" "${x11_fwd}" "${target_file}"
    set_opt "MaxAuthTries" "${max_tries}" "${target_file}"
    set_opt "LoginGraceTime" "${grace_time}" "${target_file}"
    set_opt "PermitEmptyPasswords" "no" "${target_file}"
    set_opt "ClientAliveInterval" "${alive_interval}" "${target_file}"
    set_opt "ClientAliveCountMax" "${alive_count}" "${target_file}"
  fi
  ok "Konfigurasi ditulis ke ${target_file}."

  # 8. Syntax Test BEFORE Firewall / Restart
  sub "Menguji sintaks konfigurasi sshd (-t)..."
  if ! ${SUDO} sshd -t; then
    err "Uji sintaks sshd GAGAL! Mengembalikan konfigurasi awal demi mencegah server mati."
    run ${SUDO} cp "${backup_file}" "${SSHD_MAIN}"
    [ -f "${DROPIN}" ] && run ${SUDO} rm -f "${DROPIN}"
    return 1
  fi
  ok "Uji sintaks sshd -t LULUS."

  # 9. SELinux Registration
  selinux_allow_port "${port}"

  # 10. Open Port in Firewall BEFORE Restart
  firewall_allow_port "${port}"

  # 11. Ubuntu 24.04 ssh.socket handling
  if systemctl is-active ssh.socket >/dev/null 2>&1 || systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    sub "Mendeteksi Ubuntu/Debian ssh.socket. Mengalihkan ke ssh.service standar agar port kustom aktif..."
    run ${SUDO} systemctl stop ssh.socket 2>/dev/null || true
    run ${SUDO} systemctl disable ssh.socket 2>/dev/null || true
    run ${SUDO} systemctl daemon-reload 2>/dev/null || true
    run ${SUDO} systemctl enable ssh 2>/dev/null || true
  fi

  # 12. Restart SSH Service
  printf "\n"
  if ask_yn "Restart SSH service now to apply port ${port}?" "y"; then
    local svc; svc="$(detect_ssh_service)"
    sub "Restarting ${svc} service..."
    if run ${SUDO} systemctl restart "${svc}" 2>/dev/null || run ${SUDO} systemctl restart ssh 2>/dev/null || run ${SUDO} systemctl restart sshd 2>/dev/null; then
      ok "SSH service restarted successfully on port ${port}."
    else
      warn "Automatic restart failed. Run manually: sudo systemctl restart ssh or sudo systemctl restart sshd"
    fi
  else
    info "SSH not restarted. Apply later with: sudo systemctl restart ssh"
  fi

  # 13. Passwordless Sudo Deployment
  if [ "${enable_nopasswd}" -eq 1 ]; then
    sub "Configuring passwordless sudo (/etc/sudoers.d/99-wanforge-nopasswd)..."
    local cur_u; cur_u="$(id -un)"
    local sudoers_file="/etc/sudoers.d/99-wanforge-nopasswd"
    local sudoers_tmp; sudoers_tmp="$(mktemp)"
    cat > "${sudoers_tmp}" << 'EOF'
# WanForge VPS Standard Passwordless Sudo
%sudo ALL=(ALL) NOPASSWD: ALL
%wheel ALL=(ALL) NOPASSWD: ALL
EOF
    if [ "${cur_u}" != "root" ]; then
      echo "${cur_u} ALL=(ALL) NOPASSWD: ALL" >> "${sudoers_tmp}"
    fi
    chmod 440 "${sudoers_tmp}"
    if command -v visudo >/dev/null 2>&1 && ${SUDO} visudo -cf "${sudoers_tmp}" >/dev/null 2>&1; then
      run ${SUDO} mkdir -p /etc/sudoers.d
      run ${SUDO} cp "${sudoers_tmp}" "${sudoers_file}"
      run ${SUDO} chmod 440 "${sudoers_file}"
      ok "Passwordless sudo active ('sudo su' without password, cloud VPS style)."
    else
      warn "visudo validation failed; sudoers configuration aborted for safety."
    fi
    rm -f "${sudoers_tmp}"
  fi

  # 14. Optional Cleanup Old Port 22 Rule
  local fw; fw="$(detect_firewall)"
  if [ "${fw}" != "none" ] && [ "${port}" != "22" ]; then
    printf "\n"
    if ask_yn "Delete firewall rule for old port 22/tcp now? (Choose 'n' if not yet tested)" "n"; then
      firewall_delete_port "22"
      ok "Port 22 rule removed from firewall."
    else
      info "Port 22 rule retained temporarily. Remove later after port ${port} login is confirmed."
    fi
  fi

  printf "\n%b=================================================================%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
  printf "%b✔ SSH HARDENING APPLIED SUCCESSFULLY%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
  printf "  • New Port             : %b%s%b\n" "${C_BOLD}${C_YELLOW}" "${port}" "${C_RESET}"
  printf "  • Root Login           : %b%s%b\n" "${C_YELLOW}" "${root_choice}" "${C_RESET}"
  printf "  • Password Auth        : %b%s%b\n" "${C_YELLOW}" "${pw_val}" "${C_RESET}"
  printf "  • Passwordless Sudo    : %b%s%b\n" "${C_YELLOW}" "$([ "${enable_nopasswd}" -eq 1 ] && echo 'Active (NOPASSWD)' || echo 'Unchanged')" "${C_RESET}"
  printf "\n%bATTENTION: TEST NOW IN A NEW TERMINAL WINDOW:%b\n" "${C_BOLD}${C_RED}" "${C_RESET}"
  printf "  %bssh -p %s %s@<SERVER_IP>%b\n" "${C_BOLD}${C_CYAN}" "${port}" "$(id -un)" "${C_RESET}"
  printf "%bDO NOT CLOSE THIS TERMINAL SESSION until the login above succeeds!%b\n" "${C_DIM}" "${C_RESET}"
  printf "%b=================================================================%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
}

# --- Action 5: Rollback / Restore -----------------------------------------
a_uninstall() {
  hd "Restore Original SSH Configuration from Backup"
  local backup
  backup="$(ls -t "${SSHD_MAIN}.bak."* 2>/dev/null | head -1 || true)"
  if [ -z "${backup}" ] && [ ! -f "${DROPIN}" ]; then
    info "No WanForge backup or drop-in file found. Nothing to restore."; return 0
  fi
  [ -n "${backup}" ] && warn "Will restore ${SSHD_MAIN} from backup: ${backup##*/}"
  [ -f "${DROPIN}" ]  && warn "Will remove hardening drop-in file: ${DROPIN}"

  if ! ask_yn "Proceed with restoring original SSH configuration?" "y"; then
    info "Cancelled."; return 0
  fi

  [ -n "${backup}" ] && run ${SUDO} cp "${backup}" "${SSHD_MAIN}"
  [ -f "${DROPIN}" ]  && run ${SUDO} rm -f "${DROPIN}"

  if [ -f "/etc/sudoers.d/99-wanforge-nopasswd" ]; then
    if ask_yn "Remove passwordless sudo configuration (/etc/sudoers.d/99-wanforge-nopasswd)?" "y"; then
      run ${SUDO} rm -f "/etc/sudoers.d/99-wanforge-nopasswd"
      ok "Passwordless sudo configuration removed."
    fi
  fi

  sub "Testing sshd syntax after restore..."
  if ${SUDO} sshd -t; then
    local svc; svc="$(detect_ssh_service)"
    run ${SUDO} systemctl restart "${svc}" 2>/dev/null || run ${SUDO} systemctl restart ssh 2>/dev/null || run ${SUDO} systemctl restart sshd 2>/dev/null || true
    ok "SSH configuration restored to initial state."
  else
    err "sshd syntax test FAILED after restore. Check ${SSHD_MAIN} manually."; return 1
  fi
}

# --- CLI Dispatch ---------------------------------------------------------
case "${1:-}" in
  --uninstall|rollback|restore) a_uninstall; exit $? ;;
  status|audit)                 a_status; exit $? ;;
  install)                      a_install; exit $? ;;
  key|keys)                     a_key_helper; exit $? ;;
  configure|harden)             a_configure; exit $? ;;
esac

# --- Interactive Main Menu ------------------------------------------------
banner
MENU=(
  "Status|status|Audit SSH Security Status, Port & Firewall"
  "Setup|install|Install & Enable OpenSSH Server"
  "Hardening|configure|Run SSH Hardening Wizard (Port, Root, Key Auth)"
  "Keys|key|Manage SSH Public Keys (authorized_keys)"
  "Rollback|rollback|Restore Original Configuration from Backup"
)

while true; do
  if menu_select "Select SSH management & hardening action:"; then
    case "${MENU_KEY}" in
      status)    a_status; pause ;;
      install)   a_install; pause ;;
      configure) a_configure; pause ;;
      key)       a_key_helper; pause ;;
      rollback)  a_uninstall; pause ;;
      *) break ;;
    esac
  else
    break
  fi
done

ok "Script secure-ssh completed."
