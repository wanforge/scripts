#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-gitlab-runner.sh — install & manage GitLab CI/CD self-hosted runners.
# Executes workflow jobs on your own machine.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/cicd/install-gitlab-runner.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-gitlab-runner"

# --- shared library ------------------------------------------------------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load
wf_log_init

have() { command -v "$1" >/dev/null 2>&1; }
detect_pm() { for pm in apt-get dnf yum pacman zypper apk; do command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return 0; }; done; return 1; }

pm_install() {
  local pkgs="$*"
  case "${PM}" in
    apt-get) run ${SUDO} apt-get install -y ${pkgs} ;; dnf) run ${SUDO} dnf -y install ${pkgs} ;; yum) run ${SUDO} yum -y install ${pkgs} ;;
    pacman) run ${SUDO} run pacman -S --noconfirm --needed ${pkgs} ;; zypper) run ${SUDO} zypper --non-interactive install ${pkgs} ;; apk) run ${SUDO} apk add ${pkgs} ;;
  esac
}

a_install() {
  hd "Install GitLab Runner"
  
  local URL; URL="$(ask_cfg CFG_GL_URL "GitLab instance URL:" "https://gitlab.com")"
  local TOKEN; TOKEN="$(asks "Runner Token (Registration or Authentication token from GitLab):")"
  [ -n "${TOKEN}" ] || { err "Token is required."; return 1; }

  local DESC; DESC="$(ask_cfg CFG_GL_DESC "Runner description (name):" "$(hostname)-runner")"
  local TAGS; TAGS="$(ask_cfg CFG_GL_TAGS "Runner tags (comma-separated):" "self-hosted")"

  # Choose executor
  local EXECUTOR; EXECUTOR="$(ask_cfg CFG_GL_EXECUTOR "Executor (shell or docker):" "shell")"
  case "${EXECUTOR}" in
    docker)
      local DOCKER_IMG; DOCKER_IMG="$(ask_cfg CFG_GL_DOCKER_IMG "Default Docker image:" "alpine:latest")"
      if ! have docker; then
        warn "Docker not detected on this system. You will need to install Docker for this executor to work."
      fi
      ;;
    *) EXECUTOR="shell" ;;
  esac

  # Step 1: Install gitlab-runner package if not present
  if ! have gitlab-runner; then
    step "Adding official GitLab repository"
    if [ "${PM}" = "apt-get" ]; then
      run ${SUDO} apt-get update -y
      pm_install curl ca-certificates
      curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh" | run ${SUDO} bash
    elif [ "${PM}" = "dnf" ] || [ "${PM}" = "yum" ]; then
      pm_install curl
      curl -L "https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.rpm.sh" | run ${SUDO} bash
    else
      err "Distro package repository not supported automatically. Install gitlab-runner manually."
      return 1
    fi

    step "Installing gitlab-runner"
    pm_install gitlab-runner
  else
    info "gitlab-runner package is already installed."
  fi

  # Step 2: Register the runner
  step "Registering runner with GitLab"
  local REG_CMD=(
    "gitlab-runner" "register"
    "--non-interactive"
    "--url" "${URL}"
    "--token" "${TOKEN}"
    "--description" "${DESC}"
    "--tag-list" "${TAGS}"
    "--executor" "${EXECUTOR}"
  )
  if [ "${EXECUTOR}" = "docker" ]; then
    REG_CMD+=("--docker-image" "${DOCKER_IMG}")
  fi

  if [ "${DRY_RUN:-0}" = "1" ]; then
    info "[dry-run] would run: ${REG_CMD[*]}"
  else
    run ${SUDO} "${REG_CMD[@]}"
  fi

  printf "\n%b✔ GitLab Runner registered.%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
  info "URL:     ${URL}"
  info "Name:    ${DESC}"
  info "Tags:    ${TAGS}"
  info "Executor: ${EXECUTOR}"
}

a_list() {
  hd "Registered GitLab Runners"
  if have gitlab-runner; then
    run ${SUDO} gitlab-runner list
  else
    warn "gitlab-runner is not installed."
  fi
}

a_status() {
  hd "GitLab Runner Service Status"
  if have systemctl; then
    ${SUDO} systemctl status gitlab-runner --no-pager || true
  else
    run ${SUDO} gitlab-runner status || true
  fi
}

a_logs() {
  hd "GitLab Runner logs (last 100 lines)"
  if have journalctl; then
    ${SUDO} journalctl -u gitlab-runner -n 100 --no-pager || true
  else
    warn "journalctl not available."
  fi
}

a_start()   { run ${SUDO} systemctl start gitlab-runner || run ${SUDO} gitlab-runner start; ok "Started."; }
a_stop()    { run ${SUDO} systemctl stop gitlab-runner || run ${SUDO} gitlab-runner stop; ok "Stopped."; }
a_restart() { run ${SUDO} systemctl restart gitlab-runner || { run ${SUDO} gitlab-runner stop; run ${SUDO} gitlab-runner start; }; ok "Restarted."; }

a_remove() {
  hd "Remove GitLab Runner"
  warn "This will unregister and optionally uninstall GitLab Runner."
  local yn; yn="$(ask "Proceed? [y/N]:" "n")"
  case "${yn}" in y|Y|yes) ;; *) info "Cancelled."; return 0 ;; esac

  local UNREG_ALL; UNREG_ALL="$(ask "Unregister ALL runners from this host? [y/N]:" "n")"
  if [[ "${UNREG_ALL}" =~ ^[yY](es)?$ ]]; then
    run ${SUDO} gitlab-runner unregister --all-runners || true
    ok "Unregistered all runners."
  else
    local URL; URL="$(ask_cfg CFG_GL_URL "GitLab instance URL:" "https://gitlab.com")"
    local TOKEN; TOKEN="$(asks "Token of the runner to remove:")"
    if [ -n "${TOKEN}" ]; then
      run ${SUDO} gitlab-runner unregister --url "${URL}" --token "${TOKEN}" || true
      ok "Unregistered runner."
    else
      warn "No token provided. Skipping unregistration."
    fi
  fi

  local rm_pkg; rm_pkg="$(ask "Uninstall the gitlab-runner package? [y/N]:" "n")"
  case "${rm_pkg}" in
    y|Y|yes)
      run ${SUDO} systemctl stop gitlab-runner 2>/dev/null || true
      run ${SUDO} systemctl disable gitlab-runner 2>/dev/null || true
      if [ "${PM}" = "apt-get" ]; then
        run ${SUDO} apt-get purge -y gitlab-runner
        run ${SUDO} rm -f /etc/apt/sources.list.d/runner_gitlab-runner.list
        run ${SUDO} apt-get update 2>/dev/null || true
      elif [ "${PM}" = "dnf" ] || [ "${PM}" = "yum" ]; then
        run ${SUDO} dnf remove -y gitlab-runner || run ${SUDO} yum remove -y gitlab-runner
        run ${SUDO} rm -f /etc/yum.repos.d/runner_gitlab-runner.repo
      fi
      ok "gitlab-runner package removed."
      ;;
  esac
}

# --- run -----------------------------------------------------------------
banner
PM="$(detect_pm)" || { err "No supported package manager found."; exit 1; }
have systemctl || warn "systemd not detected; service management may not work."

while true; do
  MENU=(
    "Action|install|Install & register a new GitLab runner"
    "Action|list|List registered runners"
    "Action|status|View service status"
    "Action|logs|View runner logs"
    "Action|start|Start runner service"
    "Action|stop|Stop runner service"
    "Action|restart|Restart runner service"
    "Action|remove|Unregister & remove a runner"
    "Config|clear_cfg|Clear saved configs"
  )
  printf "\n" >&2
  menu_select "GitLab Runner Manager:" || break
  case "${MENU_KEY}" in
    install) a_install ;;
    list) a_list; pause ;;
    status) a_status; pause ;;
    logs) a_logs; pause ;;
    start) a_start ;;
    stop) a_stop ;;
    restart) a_restart ;;
    remove) a_remove ;;
    clear_cfg) cfg_clear && ok "Saved config cleared." ;;
  esac
done

printf "\n%b✔ gitlab-runner manager finished.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
