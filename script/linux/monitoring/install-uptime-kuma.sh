#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-uptime-kuma.sh — install, update, backup/restore, and manage
# Uptime Kuma via Node.js + PM2, with optional Nginx reverse-proxy and ufw.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/monitoring/install-uptime-kuma.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-uptime-kuma"

# --- shared library ------------------------------------------------------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load
wf_log_init
step() { printf "\n%b==> %s%b\n" "${C_BOLD}${C_CYAN}" "$1" "${C_RESET}" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# --- NVM / Node environment ----------------------------------------------
nvm_load() {
  export NVM_DIR="${HOME}/.nvm"
  # shellcheck source=/dev/null
  [ -s "${NVM_DIR}/nvm.sh" ] && . "${NVM_DIR}/nvm.sh"
}
nvm_load

need_node() {
  if ! have node || ! have npm || ! have pm2; then
    err "This script requires Node.js, npm, and PM2."
    info "Run install-nodejs.sh first to install the Node environment."
    exit 1
  fi
}

need_git() {
  if ! have git; then
    err "git is required. Run install-packages.sh or: apt install git"
    return 1
  fi
}

# --- paths ----------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  KUMA_ROOT="${KUMA_ROOT:-/opt/uptime-kuma}"
  BACKUP_DIR="${BACKUP_DIR:-/opt/uptime-kuma-backups}"
else
  KUMA_ROOT="${KUMA_ROOT:-${HOME}/.local/lib/uptime-kuma}"
  BACKUP_DIR="${BACKUP_DIR:-${HOME}/.local/lib/uptime-kuma-backups}"
fi
KUMA_DATA="${KUMA_ROOT}/data"
PM2_NAME="uptime-kuma"

# --- helpers --------------------------------------------------------------
ufw_allow() {
  have ufw || { info "ufw not installed; open ${1}/tcp manually."; return; }
  if [ "${2}" = "0.0.0.0/0" ]; then run ${SUDO} ufw allow "${1}/tcp"
  else run ${SUDO} ufw allow from "${2}" to any port "${1}" proto tcp; fi
}

pm2_running() { pm2 show "${PM2_NAME}" >/dev/null 2>&1; }

kuma_version() {
  if [ -f "${KUMA_ROOT}/package.json" ]; then
    grep '"version"' "${KUMA_ROOT}/package.json" 2>/dev/null | head -1 | sed 's/.*: *"//;s/".*//'
  else
    echo "not installed"
  fi
}

kuma_port() { echo "${CFG_KUMA_PORT:-3001}"; }

# --- actions --------------------------------------------------------------

a_install() {
  hd "Install Uptime Kuma"
  need_node; need_git || return 1
  info "Install directory: ${KUMA_ROOT}"

  local PORT; PORT="$(ask_cfg CFG_KUMA_PORT "Uptime Kuma port:" "3001")"

  if [ -d "${KUMA_ROOT}/.git" ]; then
    warn "Existing installation found (v$(kuma_version))."
    local ow; ow="$(ask "Re-install / overwrite? [y/N]:" "n")"
    case "${ow}" in y|Y|yes) ;; *) info "Cancelled."; return 0 ;; esac
  fi

  if [ ! -d "${KUMA_ROOT}" ]; then
    step "Clone Uptime Kuma"
    run git clone https://github.com/louislam/uptime-kuma.git "${KUMA_ROOT}"
  fi

  step "Install dependencies"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] would run npm ci --production && npm run setup"
  else
    cd "${KUMA_ROOT}"
    npm ci --production 2>/dev/null || npm install --production
    npm run setup
  fi

  step "Register in PM2"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] PORT=${PORT} pm2 start server/server.js --name ${PM2_NAME}"
  else
    cd "${KUMA_ROOT}"
    pm2 delete "${PM2_NAME}" >/dev/null 2>&1 || true
    run env PORT="${PORT}" pm2 start server/server.js --name "${PM2_NAME}"
    run pm2 save
  fi

  step "PM2 startup (auto-start on reboot)"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] pm2 startup"
  else
    local startup_cmd
    startup_cmd="$(pm2 startup 2>&1 | grep -oP 'sudo .*' || true)"
    if [ -n "${startup_cmd}" ]; then
      info "Running: ${startup_cmd}"
      eval "${startup_cmd}" || warn "PM2 startup command failed — run it manually."
    fi
    run pm2 save
  fi

  a_firewall "${PORT}"
  a_show_access "${PORT}"
}

a_update() {
  hd "Update Uptime Kuma"
  need_node
  [ -d "${KUMA_ROOT}/.git" ] || { err "No installation found at ${KUMA_ROOT}."; return 1; }

  local cur; cur="$(kuma_version)"
  info "Current version: ${cur}"

  step "Pull latest changes"
  cd "${KUMA_ROOT}"
  run git fetch --all --tags
  local latest; latest="$(git describe --tags --abbrev=0 origin/master 2>/dev/null || git describe --tags --abbrev=0 origin/main 2>/dev/null || echo "unknown")"
  info "Latest tag: ${latest}"

  if [ "${cur}" = "${latest#v}" ] || [ "v${cur}" = "${latest}" ]; then
    ok "Already on latest version (${cur})."
    local force; force="$(ask "Force re-install anyway? [y/N]:" "n")"
    case "${force}" in y|Y|yes) ;; *) return 0 ;; esac
  fi

  local bk; bk="$(ask "Backup data before update? [Y/n]:" "y")"
  case "${bk}" in n|N|no) ;; *) a_backup ;; esac

  step "Checkout latest tag"
  run git checkout "${latest}" --force

  step "Reinstall dependencies"
  npm ci --production 2>/dev/null || npm install --production
  npm run setup

  step "Restart PM2 process"
  run pm2 restart "${PM2_NAME}"
  run pm2 save
  ok "Updated to $(kuma_version)."
}

a_backup() {
  hd "Backup Uptime Kuma Data"
  [ -d "${KUMA_DATA}" ] || { err "No data directory at ${KUMA_DATA}."; return 1; }

  run mkdir -p "${BACKUP_DIR}"
  local ts; ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo bak)"
  local dest="${BACKUP_DIR}/kuma-backup-${ts}.tar.gz"

  step "Creating backup"
  run tar -czf "${dest}" -C "${KUMA_ROOT}" data/
  ok "Backup saved: ${dest} ($(du -sh "${dest}" 2>/dev/null | awk '{print $1}'))"
}

a_restore() {
  hd "Restore Uptime Kuma Data"
  run mkdir -p "${BACKUP_DIR}"

  local backups; backups="$(ls -t "${BACKUP_DIR}"/kuma-backup-*.tar.gz 2>/dev/null || true)"
  if [ -z "${backups}" ]; then
    err "No backups found in ${BACKUP_DIR}."; return 1
  fi

  info "Available backups:"
  local i=1 files=()
  while IFS= read -r f; do
    files+=("${f}")
    printf "  %b[%d]%b %s (%s)\n" "${C_CYAN}" "${i}" "${C_RESET}" "$(basename "${f}")" "$(du -sh "${f}" 2>/dev/null | awk '{print $1}')" >&2
    i=$((i + 1))
  done <<< "${backups}"

  local choice; choice="$(ask "Select backup number [1]:" "1")"
  if ! [[ "${choice}" =~ ^[0-9]+$ ]] || [ "${choice}" -lt 1 ] || [ "${choice}" -gt "${#files[@]}" ]; then
    err "Invalid selection."; return 1
  fi
  local src="${files[$((choice - 1))]}"

  confirm_critical "restore data from $(basename "${src}") (overwrites current data)" || return 0

  if pm2_running; then
    step "Stop Uptime Kuma"
    run pm2 stop "${PM2_NAME}"
  fi

  step "Restore data"
  [ -d "${KUMA_DATA}" ] && run mv "${KUMA_DATA}" "${KUMA_DATA}.pre-restore.$(date +%s 2>/dev/null || echo old)"
  run tar -xzf "${src}" -C "${KUMA_ROOT}"
  ok "Data restored from $(basename "${src}")."

  step "Start Uptime Kuma"
  run pm2 start "${PM2_NAME}"
  run pm2 save
  ok "Uptime Kuma restarted with restored data."
}

a_nginx() {
  hd "Configure Nginx Reverse Proxy"
  if ! have nginx; then
    local inst; inst="$(ask "Nginx not installed. Install now? [Y/n]:" "y")"
    case "${inst}" in
      n|N|no) info "Skipped."; return 0 ;;
      *)
        if have apt-get; then run ${SUDO} apt-get update -qq && run ${SUDO} apt-get install -y nginx
        elif have dnf; then run ${SUDO} dnf install -y nginx
        elif have yum; then run ${SUDO} yum install -y nginx
        elif have pacman; then run ${SUDO} pacman -S --noconfirm nginx
        else err "Unsupported package manager."; return 1; fi
        run ${SUDO} systemctl enable --now nginx
        ;;
    esac
  fi

  local domain; domain="$(ask_cfg CFG_KUMA_DOMAIN "Domain for Uptime Kuma (e.g. status.example.com):" "")"
  [ -z "${domain}" ] && { err "Domain is required."; return 1; }

  local port; port="$(kuma_port)"

  # Detect Nginx layout: sites-available (Debian/Ubuntu) vs conf.d (RHEL/Arch/custom)
  local conf enabled="" ng_layout=""
  if [ -d "/etc/nginx/sites-available" ]; then
    ng_layout="sites"
    conf="/etc/nginx/sites-available/${domain}.conf"
    enabled="/etc/nginx/sites-enabled/${domain}.conf"
    info "Detected: sites-available/sites-enabled layout"
  elif [ -d "/etc/nginx/conf.d" ]; then
    ng_layout="confd"
    conf="/etc/nginx/conf.d/${domain}.conf"
    info "Detected: conf.d layout"
  else
    ng_layout="confd"
    run ${SUDO} mkdir -p /etc/nginx/conf.d
    conf="/etc/nginx/conf.d/${domain}.conf"
    info "Created: conf.d layout"
  fi

  if ${SUDO} test -f "${conf}"; then
    warn "Config already exists: ${conf}"
    local ow; ow="$(ask "Overwrite? [y/N]:" "n")"
    case "${ow}" in y|Y|yes) ;; *) info "Skipped."; return 0 ;; esac
  fi

  step "Write Nginx config → ${conf}"
  cat <<NGINX_EOF | run ${SUDO} tee "${conf}" >/dev/null
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
    }
}
NGINX_EOF

  # Enable site (sites-available layout only)
  if [ "${ng_layout}" = "sites" ]; then
    run ${SUDO} ln -sf "${conf}" "${enabled}"
  fi

  if ${SUDO} nginx -t 2>&1; then
    run ${SUDO} systemctl reload nginx
    ok "Nginx reverse proxy: ${domain} → localhost:${port}"
  else
    err "Nginx config test failed. Check ${conf} manually."
    return 1
  fi

  local ssl; ssl="$(ask "Set up SSL with certbot (Let's Encrypt)? [y/N]:" "n")"
  case "${ssl}" in
    y|Y|yes)
      if ! have certbot; then
        info "Installing certbot..."
        if have apt-get; then run ${SUDO} apt-get install -y certbot python3-certbot-nginx
        elif have dnf; then run ${SUDO} dnf install -y certbot python3-certbot-nginx
        else warn "Install certbot manually."; return 0; fi
      fi
      run ${SUDO} certbot --nginx -d "${domain}" --non-interactive --agree-tos --redirect \
        --email "$(ask_cfg CFG_KUMA_EMAIL "Email for Let's Encrypt:" "")" || warn "Certbot failed — run manually."
      ;;
  esac
}

a_firewall() {
  local port="${1:-$(kuma_port)}"
  if have ufw; then
    case "$(ask_cfg CFG_KUMA_UFW "Open port ${port} in ufw? [Y/n]:" "y")" in
      n|N|no) info "Firewall unchanged." ;;
      *)
        local CIDR; CIDR="$(ask_cfg CFG_KUMA_CIDR "Allow from CIDR ('0.0.0.0/0'=anywhere):" "0.0.0.0/0")"
        ufw_allow "${port}" "${CIDR}"
        ;;
    esac
  fi
}

a_show_access() {
  local port="${1:-$(kuma_port)}"
  local IP; IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '<server-ip>')"
  printf "\n%b✔ Uptime Kuma ready.%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
  printf "%b  URL:     http://%s:%s%b\n" "${C_DIM}" "${IP}" "${port}" "${C_RESET}" >&2
  printf "%b  Version: %s%b\n" "${C_DIM}" "$(kuma_version)" "${C_RESET}" >&2
  printf "%b  Data:    %s%b\n\n" "${C_DIM}" "${KUMA_DATA}" "${C_RESET}" >&2
}

a_status() {
  hd "Uptime Kuma Status"
  if pm2_running; then
    pm2 show "${PM2_NAME}" 2>&1 || true
  else
    warn "Uptime Kuma is not running in PM2."
  fi
  printf "\n" >&2
  info "Version: $(kuma_version)"
  info "Install: ${KUMA_ROOT}"
  info "Data:    ${KUMA_DATA}"
  info "Port:    $(kuma_port)"
  local backups; backups="$(ls "${BACKUP_DIR}"/kuma-backup-*.tar.gz 2>/dev/null | wc -l || echo 0)"
  info "Backups: ${backups} file(s) in ${BACKUP_DIR}"
  pause
}

a_logs() {
  hd "Uptime Kuma Logs"
  pm2 logs "${PM2_NAME}" --lines 50 2>&1 || warn "No PM2 logs available."
}

a_uninstall() {
  hd "Uninstall Uptime Kuma"
  warn "This will stop, delete from PM2, and optionally remove all files."
  confirm_critical "uninstall / remove Uptime Kuma" || return 0

  if pm2_running; then
    run pm2 delete "${PM2_NAME}"
    run pm2 save
    ok "Deleted from PM2."
  else
    info "Not registered in PM2."
  fi

  local bk; bk="$(ask "Backup data before removing? [Y/n]:" "y")"
  case "${bk}" in n|N|no) ;; *) [ -d "${KUMA_DATA}" ] && a_backup ;; esac

  local rm_dir; rm_dir="$(ask "Delete installation directory (${KUMA_ROOT})? [y/N]:" "n")"
  case "${rm_dir}" in y|Y|yes) run rm -rf "${KUMA_ROOT}" && ok "Removed ${KUMA_ROOT}." ;; esac

  local rm_bak; rm_bak="$(ask "Delete backups too (${BACKUP_DIR})? [y/N]:" "n")"
  case "${rm_bak}" in y|Y|yes) run rm -rf "${BACKUP_DIR}" && ok "Removed ${BACKUP_DIR}." ;; esac

  if have ufw; then
    local port; port="$(kuma_port)"
    run ${SUDO} ufw delete allow "${port}/tcp" 2>/dev/null || true
    ok "Removed firewall rule for port ${port}."
  fi

  # Remove Nginx config if present (detect layout)
  local domain="${CFG_KUMA_DOMAIN:-}"
  if [ -n "${domain}" ]; then
    local nconf="" nenabled=""
    if [ -f "/etc/nginx/sites-available/${domain}.conf" ]; then
      nconf="/etc/nginx/sites-available/${domain}.conf"
      nenabled="/etc/nginx/sites-enabled/${domain}.conf"
    elif [ -f "/etc/nginx/conf.d/${domain}.conf" ]; then
      nconf="/etc/nginx/conf.d/${domain}.conf"
    fi
    if [ -n "${nconf}" ]; then
      local rm_ng; rm_ng="$(ask "Remove Nginx config for ${domain}? [y/N]:" "n")"
      case "${rm_ng}" in
        y|Y|yes)
          [ -n "${nenabled}" ] && run ${SUDO} rm -f "${nenabled}"
          run ${SUDO} rm -f "${nconf}"
          ${SUDO} nginx -t 2>/dev/null && run ${SUDO} systemctl reload nginx || true
          ok "Nginx config removed."
          ;;
      esac
    fi
  fi

  ok "Uptime Kuma uninstalled."
}

# --- CLI flag dispatch ----------------------------------------------------
for __a in "$@"; do
  case "${__a}" in
    --install)   need_node; a_install; exit $? ;;
    --uninstall) need_node; a_uninstall; exit $? ;;
    --update)    need_node; a_update; exit $? ;;
    --backup)    a_backup; exit $? ;;
    --restore)   a_restore; exit $? ;;
    --start)     pm2 start "${PM2_NAME}"; exit $? ;;
    --stop)      pm2 stop "${PM2_NAME}"; exit $? ;;
    --restart)   pm2 restart "${PM2_NAME}"; exit $? ;;
    --status)    a_status; exit $? ;;
    --logs)      pm2 logs "${PM2_NAME}"; exit $? ;;
  esac
done

# --- interactive menu -----------------------------------------------------
banner
need_node
while true; do
  MENU=(
    "Setup|install|install / reinstall Uptime Kuma"
    "Setup|update|update to latest version"
    "Setup|nginx|configure Nginx reverse proxy + SSL"
    "Manage|start|start (PM2)"
    "Manage|stop|stop (PM2)"
    "Manage|restart|restart (PM2)"
    "Manage|status|show status, version, and info"
    "Manage|logs|view PM2 logs"
    "Data|backup|backup data directory"
    "Data|restore|restore from backup"
    "Remove|uninstall|uninstall / remove Uptime Kuma"
    "Config|clear_cfg|clear saved config"
  )
  printf "\n" >&2
  menu_select "Uptime Kuma Manager:" || break
  case "${MENU_KEY}" in
    install)   a_install ;;
    update)    a_update ;;
    nginx)     a_nginx ;;
    start)     pm2 start "${PM2_NAME}" && ok "Started." ;;
    stop)      pm2 stop "${PM2_NAME}" && ok "Stopped." ;;
    restart)   pm2 restart "${PM2_NAME}" && ok "Restarted." ;;
    status)    a_status ;;
    logs)      a_logs ;;
    backup)    a_backup ;;
    restore)   a_restore ;;
    uninstall) a_uninstall ;;
    clear_cfg) cfg_clear && ok "Saved config cleared." ;;
  esac
done

printf "\n%b✔ uptime-kuma manager finished.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
