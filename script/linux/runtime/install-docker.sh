#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2155
#
# install-docker.sh — Install & Manage Container Runtimes (Docker & Podman)
# Supports Ubuntu, Debian, Fedora, RHEL, CentOS, AlmaLinux, Rocky, Arch.
# Includes:
#   - Official Docker Engine + Compose
#   - Podman + Podman Compose
#   - Podman as Docker CLI wrapper & socket emulation
#   - Container diagnostics & crash-loop detection
#   - Storage prune & UFW security bypass patch
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan

set -euo pipefail
TASK="install-docker"

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

# Detect active container engine
detect_engine() {
  if command -v docker >/dev/null 2>&1; then
    echo "docker"
  elif command -v podman >/dev/null 2>&1; then
    echo "podman"
  else
    echo "none"
  fi
}

# --- Action 1: Install Docker Engine & Compose ----------------------------
a_install_docker() {
  hd "Install Docker Engine & Docker Compose (Official Repo)"

  local os_id="" os_like="" os_codename="" os_version=""
  if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    os_id="$(. /etc/os-release && echo "${ID:-}")"
    os_like="$(. /etc/os-release && echo "${ID_LIKE:-}")"
    os_codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
    os_version="$(. /etc/os-release && echo "${VERSION_ID:-}")"
  fi

  sub "Mendeteksi sistem operasi: ${os_id} (${os_like:-standalone})..."

  if [[ "${os_id}" =~ ^(ubuntu|debian|pop|mint|kali)$ ]] || [[ "${os_like}" =~ (ubuntu|debian) ]]; then
    step "Memasang dependencies APT..."
    run ${SUDO} apt-get update
    run ${SUDO} apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

    step "Menyiapkan keyring repository resmi Docker..."
    run ${SUDO} mkdir -p /etc/apt/keyrings
    local repo_id="ubuntu"
    [[ "${os_id}" =~ ^(debian|kali)$ ]] && repo_id="debian"

    # Fallback codename if empty
    if [ -z "${os_codename}" ]; then
      os_codename="$(lsb_release -cs 2>/dev/null || echo 'noble')"
    fi

    curl -fsSL "https://download.docker.com/linux/${repo_id}/gpg" | ${SUDO} gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes 2>/dev/null || true
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${repo_id} ${os_codename} stable" \
      | run ${SUDO} tee /etc/apt/sources.list.d/docker.list >/dev/null

    step "Memasang Docker packages..."
    run ${SUDO} apt-get update
    run ${SUDO} apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  elif [[ "${os_id}" =~ ^(fedora|rhel|centos|rocky|almalinux)$ ]] || [[ "${os_like}" =~ (fedora|rhel) ]]; then
    step "Memasang Docker di sistem berbasis RHEL/Fedora..."
    if command -v dnf >/dev/null 2>&1; then
      run ${SUDO} dnf install -y dnf-plugins-core
      local repo_dist="fedora"
      [[ "${os_id}" =~ ^(rhel|centos|rocky|almalinux)$ ]] && repo_dist="centos"
      run ${SUDO} dnf config-manager --add-repo "https://download.docker.com/linux/${repo_dist}/docker-ce.repo" 2>/dev/null || true
      run ${SUDO} dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    elif command -v yum >/dev/null 2>&1; then
      run ${SUDO} yum install -y yum-utils
      run ${SUDO} yum-config-manager --add-repo "https://download.docker.com/linux/centos/docker-ce.repo" 2>/dev/null || true
      run ${SUDO} yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

  elif [[ "${os_id}" =~ ^(arch|manjaro)$ ]] || [[ "${os_like}" =~ arch ]]; then
    step "Memasang Docker via Pacman..."
    run ${SUDO} pacman -Sy --noconfirm docker docker-compose

  elif [ "${os_id}" = "alpine" ]; then
    step "Memasang Docker via APK..."
    run ${SUDO} apk add docker docker-cli-compose

  else
    warn "Distro ${os_id} tidak didukung langsung oleh script ini. Mencoba instalasi via generic docker script..."
    curl -fsSL https://get.docker.com | run ${SUDO} sh
  fi

  # Enable & start service
  step "Mengaktifkan dan menjalankan layanan Docker..."
  run ${SUDO} systemctl enable --now docker 2>/dev/null || true

  # Add current user to docker group
  local cur_u; cur_u="$(id -un)"
  if [ "${cur_u}" != "root" ]; then
    if ask_yn "Tambahkan user aktif (${cur_u}) ke grup 'docker' (menjalankan docker tanpa sudo)?" "y"; then
      run ${SUDO} groupadd -f docker
      run ${SUDO} usermod -aG docker "${cur_u}"
      ok "User ${cur_u} dimasukkan ke grup 'docker'. (Perlu relogin/su - ${cur_u} untuk efek aktif)."
    fi
  fi

  if command -v docker >/dev/null 2>&1; then
    ok "Docker Engine berhasil dipasang: $(docker --version 2>/dev/null || echo 'Installed')"
  else
    err "Instalasi Docker selesai tetapi biner 'docker' tidak ditemukan di PATH."
  fi
}

# --- Action 2: Install Podman & Podman Compose ----------------------------
a_install_podman() {
  hd "Install Podman & Podman Compose (Rootless/Daemonless)"

  local os_id="" os_like=""
  if [ -f /etc/os-release ]; then
    # shellcheck source=/dev/null
    os_id="$(. /etc/os-release && echo "${ID:-}")"
    os_like="$(. /etc/os-release && echo "${ID_LIKE:-}")"
  fi

  sub "Memasang paket Podman..."
  if [[ "${os_id}" =~ ^(ubuntu|debian|pop|mint|kali)$ ]] || [[ "${os_like}" =~ (ubuntu|debian) ]]; then
    run ${SUDO} apt-get update
    run ${SUDO} apt-get install -y podman podman-compose podman-docker || run ${SUDO} apt-get install -y podman podman-compose || run ${SUDO} apt-get install -y podman
  elif [[ "${os_id}" =~ ^(fedora|rhel|centos|rocky|almalinux)$ ]] || [[ "${os_like}" =~ (fedora|rhel) ]]; then
    if command -v dnf >/dev/null 2>&1; then
      run ${SUDO} dnf install -y podman podman-compose podman-docker || run ${SUDO} dnf install -y podman
    elif command -v yum >/dev/null 2>&1; then
      run ${SUDO} yum install -y podman podman-compose podman-docker || run ${SUDO} yum install -y podman
    fi
  elif [[ "${os_id}" =~ ^(arch|manjaro)$ ]] || [[ "${os_like}" =~ arch ]]; then
    run ${SUDO} pacman -Sy --noconfirm podman podman-compose podman-docker
  elif [ "${os_id}" = "alpine" ]; then
    run ${SUDO} apk add podman podman-compose
  else
    err "Manajer paket untuk distro ${os_id} tidak dikenali."; return 1
  fi

  if command -v podman >/dev/null 2>&1; then
    ok "Podman berhasil dipasang: $(podman --version)"
    printf "\n"
    if ask_yn "Konfigurasi Podman sebagai pengganti perintah 'docker' sekarang?" "y"; then
      a_setup_podman_as_docker
    fi
  else
    err "Pemasangan Podman gagal."; return 1
  fi
}

# --- Action 3: Configure Podman as Docker CLI & Socket --------------------
a_setup_podman_as_docker() {
  hd "Konfigurasi Podman sebagai Perintah 'docker' & Emulasi Socket"

  if ! command -v podman >/dev/null 2>&1; then
    err "Podman belum terpasang. Jalankan instalasi Podman terlebih dahulu."; return 1
  fi

  sub "1. Konfigurasi wrapper CLI 'docker'..."
  # If podman-docker package is available, attempt to install it
  if ! command -v docker >/dev/null 2>&1; then
    if command -v dnf >/dev/null 2>&1; then
      run ${SUDO} dnf install -y podman-docker 2>/dev/null || true
    elif command -v apt-get >/dev/null 2>&1; then
      run ${SUDO} apt-get install -y podman-docker 2>/dev/null || true
    fi
  fi

  # If docker binary still not in path or doesn't invoke podman, create symlink
  local podman_bin; podman_bin="$(command -v podman)"
  if ! command -v docker >/dev/null 2>&1; then
    run ${SUDO} ln -sf "${podman_bin}" /usr/local/bin/docker
    ok "Symlink dibuat: /usr/local/bin/docker -> ${podman_bin}"
  fi

  # Alias fallback in /etc/profile.d
  sub "2. Memasang profile alias global di /etc/profile.d/wanforge-podman-docker.sh..."
  local profile_alias="/etc/profile.d/wanforge-podman-docker.sh"
  cat << 'EOF' | run ${SUDO} tee "${profile_alias}" >/dev/null
# WanForge Podman as Docker Compatibility Wrapper
if command -v podman >/dev/null 2>&1; then
  alias docker="podman"
  if command -v podman-compose >/dev/null 2>&1; then
    alias docker-compose="podman-compose"
  fi
fi
EOF
  run ${SUDO} chmod 644 "${profile_alias}"
  ok "Profile alias aktif di ${profile_alias}."

  # Quiet podman emulation notice
  sub "3. Mematikan pesan peringatan emulasi podman (/etc/containers/nodocker)..."
  run ${SUDO} mkdir -p /etc/containers
  run ${SUDO} touch /etc/containers/nodocker
  ok "Pesan emulasi dinonaktifkan via /etc/containers/nodocker."

  # Shortnames config to avoid interactive registry prompts
  sub "4. Mengonfigurasi default search registry (docker.io, quay.io)..."
  local reg_conf="/etc/containers/registries.conf.d/00-wanforge-search.conf"
  run ${SUDO} mkdir -p /etc/containers/registries.conf.d
  cat << 'EOF' | run ${SUDO} tee "${reg_conf}" >/dev/null
# WanForge Podman Registry Search
unqualified-search-registries = ["docker.io", "quay.io"]
EOF
  ok "Registry search dikonfigurasi ke docker.io & quay.io."

  # Podman socket emulation (/var/run/docker.sock)
  sub "5. Mengaktifkan Podman API Socket untuk kompatibilitas Docker tools..."
  if systemctl list-unit-files | grep -q 'podman.socket'; then
    run ${SUDO} systemctl enable --now podman.socket 2>/dev/null || true

    # Symlink /var/run/docker.sock if docker.service is not running
    if [ ! -S /var/run/docker.sock ] && [ -S /run/podman/podman.sock ]; then
      run ${SUDO} ln -sf /run/podman/podman.sock /var/run/docker.sock
      ok "Docker socket emulated: /var/run/docker.sock -> /run/podman/podman.sock"
    fi

    # Rootless socket guidance
    local cur_u; cur_u="$(id -un)"
    if [ "${cur_u}" != "root" ]; then
      systemctl --user enable --now podman.socket 2>/dev/null || true
      info "Untuk user non-root (${cur_u}), tambahkan ke ~/.bashrc jika dibutuhkan:"
      info "  export DOCKER_HOST=\"unix:///run/user/$(id -u)/podman/podman.sock\""
    fi
  fi

  printf "\n%b✔ KONFIGURASI PODMAN SEBAGAI DOCKER SELESAI%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
  printf "  • CLI Executable       : %s\n" "$(command -v docker 2>/dev/null || echo 'alias docker=podman')"
  printf "  • Engine Version       : %s\n" "$(podman --version 2>/dev/null || echo 'Unknown')"
  printf "  • Registry Search      : docker.io, quay.io (tanpa prompt)\n"
  printf "  • Docker Socket        : /var/run/docker.sock -> /run/podman/podman.sock\n\n"
}

# --- Action 4: Diagnostics & Troubleshooting ------------------------------
a_diagnostics() {
  hd "Container Diagnostics & Troubleshooting"

  local eng; eng="$(detect_engine)"
  if [ "${eng}" = "none" ]; then
    err "Tidak ditemukan Docker maupun Podman di sistem."; return 1
  fi

  info "Engine aktif terdeteksi: ${C_BOLD}${eng}${C_RESET}"

  # Show running containers
  printf "\n%b[1] Daftar Container:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  ${eng} ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || ${eng} ps -a || true

  # Check for restarting or crash loops
  printf "\n%b[2] Cek Container Crash-Loop:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  local is_podman=0
  if ${eng} --version 2>&1 | grep -qi 'podman'; then
    is_podman=1
  fi

  local restarts=0
  if [ "${is_podman}" -eq 0 ]; then
    restarts="$(${eng} ps -a --filter "status=restarting" -q 2>/dev/null | grep -c . || true)"
    restarts="${restarts//[^0-9]/}"
    restarts="${restarts:-0}"
    if [ "${restarts}" -gt 0 ]; then
      warn "Ditemukan ${restarts} container dalam loop restart/crash!"
      ${eng} ps -a --filter "status=restarting" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>/dev/null || true
    fi
  fi

  local failed=""
  failed="$(${eng} ps -a --filter "status=exited" --format "{{.Names}} exited {{.Status}}" 2>/dev/null | grep -i -v -E 'exited \([0]\)|exited 0' || true)"
  if [ -n "${failed}" ]; then
    warn "Container yang berhenti dengan status error:"
    echo "${failed}"
  elif [ "${restarts}" -eq 0 ]; then
    ok "Semua container berjalan normal atau berhenti dengan exit code 0."
  fi

  # Stats snapshot
  printf "\n%b[3] Penggunaan Resource Container (Snapshot):%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  ${eng} stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" 2>/dev/null || true
  printf "\n"
}

# --- Action 5: Storage Cleanup --------------------------------------------
a_cleanup() {
  hd "Container Storage & Cache Cleanup"

  local eng; eng="$(detect_engine)"
  if [ "${eng}" = "none" ]; then
    err "Tidak ditemukan Docker maupun Podman."; return 1
  fi

  warn "Tindakan ini akan menghapus container yang stopped, unused networks, dangling images, dan build cache."
  if ! ask_yn "Lanjutkan pembersihan penyimpanan ${eng}?" "n"; then
    info "Dibatalkan."; return 0
  fi

  step "Menjalankan ${eng} system prune..."
  ${eng} system prune -f --volumes 2>/dev/null || ${eng} system prune -f
  ok "Pembersihan selesai."
}

# --- Action 6: UFW Firewall Security Patch --------------------------------
a_ufw_patch() {
  hd "UFW Firewall Security Patch (Docker Bypass Fix)"

  if [ ! -f /etc/ufw/after.rules ]; then
    err "UFW tidak terpasang atau berkas /etc/ufw/after.rules tidak ditemukan."; return 1
  fi

  if grep -q "docker-user" /etc/ufw/after.rules; then
    ok "Patch UFW-Docker sudah terpasang di /etc/ufw/after.rules."; return 0
  fi

  warn "Secara default, Docker melakukan manipulasi iptables dan mem-bypass aturan UFW."
  warn "Patch ini memastikan traffic ke port container melewati filter UFW."
  if ! ask_yn "Terapkan patch keamanan UFW-Docker?" "y"; then
    info "Dibatalkan."; return 0
  fi

  step "Membuat backup /etc/ufw/after.rules..."
  run ${SUDO} cp /etc/ufw/after.rules /etc/ufw/after.rules.bak

  step "Menulis aturan docker-user ke /etc/ufw/after.rules..."
  local patch="
# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:docker-user - [0:0]
-A docker-user -j ufw-user-forward
-A docker-user -j RETURN
COMMIT
# END UFW AND DOCKER"

  printf "%s\n" "${patch}" | run ${SUDO} tee -a /etc/ufw/after.rules >/dev/null

  step "Me-reload UFW..."
  run ${SUDO} ufw reload
  ok "Patch keamanan berhasil diterapkan. Port container kini mematuhi aturan UFW."
}

# --- Action 7: Uninstall Runtimes -----------------------------------------
a_uninstall() {
  hd "Uninstall Container Runtime"

  local eng; eng="$(detect_engine)"
  warn "Pilih komponen yang ingin dihapus:"
  printf "  [1] Uninstall Docker Engine\n"
  printf "  [2] Uninstall Podman & Wrapper\n"
  printf "  [3] Hapus Keduanya (Docker & Podman)\n"
  printf "  [0] Batal\n"
  local choice; choice="$(ask "Pilihan Anda" "0")"

  case "${choice}" in
    1|3)
      if command -v docker >/dev/null 2>&1; then
        sub "Menghapus paket Docker..."
        if command -v apt-get >/dev/null 2>&1; then
          run ${SUDO} apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
          run ${SUDO} apt-get autoremove -y 2>/dev/null || true
          run ${SUDO} rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg
        elif command -v dnf >/dev/null 2>&1; then
          run ${SUDO} dnf remove -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
        elif command -v pacman >/dev/null 2>&1; then
          run ${SUDO} pacman -Rns --noconfirm docker docker-compose 2>/dev/null || true
        fi
        if ask_yn "Hapus direktori data Docker (/var/lib/docker)?" "n"; then
          run ${SUDO} rm -rf /var/lib/docker /etc/docker /var/lib/containerd
        fi
        ok "Docker berhasil dihapus."
      fi
      ;;
  esac

  case "${choice}" in
    2|3)
      if command -v podman >/dev/null 2>&1; then
        sub "Menghapus paket Podman..."
        if command -v apt-get >/dev/null 2>&1; then
          run ${SUDO} apt-get purge -y podman podman-compose podman-docker 2>/dev/null || true
        elif command -v dnf >/dev/null 2>&1; then
          run ${SUDO} dnf remove -y podman podman-compose podman-docker 2>/dev/null || true
        elif command -v pacman >/dev/null 2>&1; then
          run ${SUDO} pacman -Rns --noconfirm podman podman-compose podman-docker 2>/dev/null || true
        fi
        run ${SUDO} rm -f /etc/profile.d/wanforge-podman-docker.sh /etc/containers/nodocker /etc/containers/registries.conf.d/00-wanforge-search.conf
        [ -L /usr/local/bin/docker ] && run ${SUDO} rm -f /usr/local/bin/docker
        [ -L /var/run/docker.sock ] && run ${SUDO} rm -f /var/run/docker.sock
        ok "Podman dan konfigurasinya berhasil dihapus."
      fi
      ;;
  esac
}

# --- CLI Dispatch ---------------------------------------------------------
case "${1:-}" in
  install-docker|docker)        a_install_docker; exit $? ;;
  install-podman|podman)        a_install_podman; exit $? ;;
  setup-podman-docker|podman-docker) a_setup_podman_as_docker; exit $? ;;
  diagnostics|diag)             a_diagnostics; exit $? ;;
  cleanup|clean)                a_cleanup; exit $? ;;
  ufw|ufw-patch)                a_ufw_patch; exit $? ;;
  --uninstall|uninstall)        a_uninstall; exit $? ;;
  status)
    if systemctl is-active docker >/dev/null 2>&1; then
      systemctl status docker --no-pager
    elif systemctl is-active podman.socket >/dev/null 2>&1; then
      systemctl status podman.socket --no-pager
    else
      echo "Layanan docker / podman tidak aktif."
    fi
    exit $?
    ;;
  restart)
    systemctl restart docker 2>/dev/null || systemctl restart podman.socket 2>/dev/null || true
    ok "Restart selesai."; exit 0
    ;;
esac

# --- Interactive Main Menu ------------------------------------------------
banner
MENU=(
  "Engine|install_docker|Pasang Docker Engine & Docker Compose (Official Repo)"
  "Engine|install_podman|Pasang Podman & Podman Compose (Rootless/Daemonless)"
  "Engine|podman_docker|Konfigurasi Podman sebagai Perintah 'docker' & Socket"
  "Audit|diagnostics|Audit container aktif, port binding & crash-loop"
  "Audit|cleanup|Bersihkan container stopped, dangling images & build cache"
  "Audit|ufw_patch|Terapkan patch keamanan bypass UFW Firewall (Docker)"
  "Layanan|status|Lihat status layanan Docker / Podman Socket"
  "Layanan|restart|Restart layanan Docker / Podman Socket"
  "Layanan|stop|Hentikan layanan Docker / Podman Socket"
  "Hapus|uninstall|Uninstall Docker / Podman & konfigurasi"
)

while true; do
  if menu_select "PILIH AKSI CONTAINER RUNTIME (DOCKER & PODMAN):"; then
    case "${MENU_KEY}" in
      install_docker) a_install_docker ;;
      install_podman) a_install_podman ;;
      podman_docker)  a_setup_podman_as_docker ;;
      diagnostics)    a_diagnostics; pause ;;
      cleanup)        a_cleanup; pause ;;
      ufw_patch)      a_ufw_patch; pause ;;
      status)
        if systemctl is-active docker >/dev/null 2>&1; then
          ${SUDO} systemctl status docker --no-pager || true
        elif systemctl is-active podman.socket >/dev/null 2>&1; then
          ${SUDO} systemctl status podman.socket --no-pager || true
        else
          info "Tidak ada layanan docker atau podman.socket yang aktif."
        fi
        pause
        ;;
      restart)
        run ${SUDO} systemctl restart docker 2>/dev/null || run ${SUDO} systemctl restart podman.socket 2>/dev/null || true
        ok "Restart layanan selesai."
        ;;
      stop)
        run ${SUDO} systemctl stop docker 2>/dev/null || run ${SUDO} systemctl stop podman.socket 2>/dev/null || true
        ok "Layanan dihentikan."
        ;;
      uninstall) a_uninstall ;;
      *) warn "Pilihan tidak valid: ${MENU_KEY}" ;;
    esac
  else
    break
  fi
done

ok "Script ${TASK} selesai."
