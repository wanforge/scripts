#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-docker.sh — install Docker Engine + Docker Compose,
# run container diagnostics, clean caches, and patch UFW security bypass.
# Debian/Ubuntu.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/runtime/install-docker.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-docker"

# --- shared library ------------------------------------------------------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load
wf_log_init

have() { command -v "$1" >/dev/null 2>&1; }

a_uninstall() {
  hd "Uninstall Docker"
  warn "This will remove Docker packages, configurations, and containers."
  local yn; yn="$(ask "Completely remove Docker? [y/N]:" "n")"
  case "${yn}" in y|Y|yes) ;; *) info "Cancelled."; return 0 ;; esac

  step "Purging Docker packages"
  run ${SUDO} apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras || true
  run ${SUDO} apt-get autoremove -y
  
  local rdir; rdir="$(ask "Delete Docker directories (/var/lib/docker, /etc/docker)? [y/N]:" "n")"
  case "${rdir}" in
    y|Y|yes)
      run ${SUDO} rm -rf /var/lib/docker /etc/docker /var/lib/containerd
      ok "Deleted directories."
      ;;
  esac
  
  # Remove sources
  run ${SUDO} rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg
  ok "Docker uninstalled."
}

a_install() {
  hd "Install Docker Engine & Compose"
  step "Adding official Docker repository"
  run ${SUDO} apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release
  
  run ${SUDO} mkdir -p /etc/apt/keyrings
  local ID; ID="$(. /etc/os-release && echo "$ID")"
  local CODENAME; CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | gpg --dearmor 2>/dev/null | run ${SUDO} tee /etc/apt/keyrings/docker.gpg >/dev/null
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${CODENAME} stable" \
    | run ${SUDO} tee /etc/apt/sources.list.d/docker.list >/dev/null
  
  step "Installing Docker packages"
  run ${SUDO} apt-get update
  run ${SUDO} apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  
  # Start service
  run ${SUDO} systemctl enable --now docker
  ok "Docker installed and running."
  
  # Option to add current user to docker group
  local cur_user; cur_user="$(whoami)"
  if [ "${cur_user}" != "root" ]; then
    case "$(ask "Add current user (${cur_user}) to 'docker' group? [Y/n]:" "y")" in
      n|N|no) ;;
      *)
        run ${SUDO} usermod -aG docker "${cur_user}"
        ok "User added to 'docker' group. Log out and back in to apply."
        ;;
    esac
  fi
}

a_diagnostics() {
  hd "Docker Diagnostics & Troubleshooting"
  if ! have docker; then
    err "Docker is not installed."
    return 1
  fi
  
  # Show running containers
  info "Containers status summary:"
  docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
  
  # Check for restarting or crash loops
  info "Checking for crash-looping containers..."
  local restarts; restarts=$(docker ps -a --filter "status=restarting" -q | wc -l)
  local failed; failed=$(docker ps -a --filter "status=exited" --format "{{.Names}} exited {{.Status}}" | grep -v "exited 0" || echo "")
  
  if [ "${restarts}" -gt 0 ]; then
    warn "Found ${restarts} container(s) in restarting/crash loop!"
    docker ps -a --filter "status=restarting" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
  fi
  if [ -n "${failed}" ]; then
    warn "Found container(s) that exited with error codes:"
    echo "${failed}"
  fi
  if [ "${restarts}" -eq 0 ] && [ -z "${failed}" ]; then
    ok "No crash loops or error-exited containers detected."
  fi
  
  # Stats
  info "Container resource usage snapshot:"
  docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" || true
}

a_cleanup() {
  hd "Docker Storage Cleanup"
  if ! have docker; then
    err "Docker is not installed."
    return 1
  fi
  warn "This will delete all stopped containers, unused networks, dangling images, and build caches."
  local yn; yn="$(ask "Proceed with cleanup? [y/N]:" "n")"
  case "${yn}" in y|Y|yes) ;; *) info "Cancelled."; return 0 ;; esac
  
  step "Running docker system prune"
  docker system prune -f --volumes
  ok "Cleanup finished."
}

a_ufw_patch() {
  hd "UFW Firewall Security Patch"
  if [ ! -f /etc/ufw/after.rules ]; then
    err "UFW is not installed or /etc/ufw/after.rules is missing."
    return 1
  fi
  
  if grep -q "docker-user" /etc/ufw/after.rules; then
    ok "UFW-Docker patch is already applied to /etc/ufw/after.rules."
    return 0
  fi
  
  warn "By default, Docker bypasses UFW rules. This patch appends rules to route container traffic through UFW."
  local yn; yn="$(ask "Apply UFW-Docker security patch? [y/N]:" "n")"
  case "${yn}" in y|Y|yes) ;; *) info "Cancelled."; return 0 ;; esac
  
  step "Backing up UFW rules"
  run ${SUDO} cp /etc/ufw/after.rules /etc/ufw/after.rules.bak
  
  step "Applying patch to /etc/ufw/after.rules"
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
  
  step "Reloading UFW"
  run ${SUDO} ufw reload
  ok "Firewall patch applied. Docker containers now respect UFW rules."
}

# --- dispatch flags --------------------------------------------------------
for __a in "$@"; do
  case "${__a}" in
    --uninstall) a_uninstall; exit $? ;;
    --start) run ${SUDO} systemctl start docker; exit $? ;;
    --stop) run ${SUDO} systemctl stop docker; exit $? ;;
    --restart) run ${SUDO} systemctl restart docker; exit $? ;;
    --status) ${SUDO} systemctl status docker --no-pager; exit $? ;;
  esac
done

# --- interactive menu ------------------------------------------------------
banner
while true; do
  MENU=(
    "Action|install|Install Docker Engine & Compose"
    "Action|diagnostics|Audit running containers & crash loops"
    "Action|cleanup|Prune unused container space"
    "Action|ufw|Apply UFW Firewall security patch"
    "Service|status|View Docker service status"
    "Service|stop|Stop Docker service"
    "Service|start|Start Docker service"
    "Service|restart|Restart Docker service"
    "Action|uninstall|Uninstall / Remove Docker"
  )
  printf "\n" >&2
  menu_select "Docker Engine Manager:" || break
  case "${MENU_KEY}" in
    install) a_install ;;
    diagnostics) a_diagnostics; pause ;;
    cleanup) a_cleanup; pause ;;
    ufw) a_ufw_patch; pause ;;
    status) run ${SUDO} systemctl status docker --no-pager || true; pause ;;
    stop) run ${SUDO} systemctl stop docker && ok "Stopped Docker." ;;
    start) run ${SUDO} systemctl start docker && ok "Started Docker." ;;
    restart) run ${SUDO} systemctl restart docker && ok "Restarted Docker." ;;
    uninstall) a_uninstall ;;
  esac
done

printf "\n%b✔ docker manager finished.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
