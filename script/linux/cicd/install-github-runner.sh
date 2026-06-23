#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-github-runner.sh — install & manage GitHub Actions self-hosted
# runners on this host. Self-hosted runners execute workflow jobs on your own
# machine, so GitHub-hosted runner minutes are NOT billed (self-hosted runners
# are free of per-minute charges).
#
# Single-select TUI manager:
#   Install      register a new runner + install it as a systemd service
#   List         show every runner configured on this host
#   Status       systemd status of a runner
#   Logs         tail journald logs for a runner service
#   Start/Stop/Restart   control a runner service
#   Remove       unregister a runner from GitHub + uninstall its service
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/cicd/install-github-runner.sh | bash
#
# Tokens (Settings → Actions → Runners):
#   "New runner" shows a short-lived REGISTRATION token (used by Install).
#   "Remove"/"⋯" on a runner shows a short-lived REMOVAL token (used by Remove).
#
# Docs:
#   About self-hosted runners ........... https://docs.github.com/actions/hosting-your-own-runners/managing-self-hosted-runners/about-self-hosted-runners
#   Adding self-hosted runners .......... https://docs.github.com/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners
#   Running as a service ................ https://docs.github.com/actions/hosting-your-own-runners/managing-self-hosted-runners/configuring-the-self-hosted-runner-application-as-a-service
#   Removing runners .................... https://docs.github.com/actions/hosting-your-own-runners/managing-self-hosted-runners/removing-self-hosted-runners
#   Using in a workflow (runs-on) ....... https://docs.github.com/actions/using-jobs/choosing-the-runner-for-a-job
#   Labels ............................... https://docs.github.com/actions/hosting-your-own-runners/managing-self-hosted-runners/using-labels-with-self-hosted-runners
#   Autoscaling / ephemeral runners ..... https://docs.github.com/actions/hosting-your-own-runners/managing-self-hosted-runners/autoscaling-with-self-hosted-runners
#   Billing / usage limits .............. https://docs.github.com/billing/managing-billing-for-github-actions/about-billing-for-github-actions
#   Security hardening .................. https://docs.github.com/actions/security-guides/security-hardening-for-github-actions#hardening-for-self-hosted-runners
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-github-runner"

# --- shared library: banner, colors, logging, prompts, menus -------------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi

have() { command -v "$1" >/dev/null 2>&1; }
cfg_load  # restore saved runner config (scope, name, labels, etc.)
wf_log_init

# Where runners are installed. Each runner gets its own subdir: $RUNNER_ROOT/<name>.
RUNNER_ROOT="${RUNNER_ROOT:-/opt/actions-runner}"

detect_pm() { for pm in apt-get dnf yum pacman zypper apk; do command -v "$pm" >/dev/null 2>&1 && { echo "$pm"; return 0; }; done; return 1; }
pm_install() {
  local pkgs="$*"
  case "${PM}" in
    apt-get) run ${SUDO} apt-get install -y ${pkgs} ;; dnf) run ${SUDO} dnf -y install ${pkgs} ;; yum) run ${SUDO} yum -y install ${pkgs} ;;
    pacman) run ${SUDO} pacman -S --noconfirm --needed ${pkgs} ;; zypper) run ${SUDO} zypper --non-interactive install ${pkgs} ;; apk) run ${SUDO} apk add ${pkgs} ;;
  esac
}

# Map uname -m to the arch token used in actions/runner release asset names.
runner_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "x64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7)  echo "arm" ;;
    *) return 1 ;;
  esac
}

# Resolve the latest actions/runner version (strip the leading "v").
latest_runner_version() {
  local tag
  tag="$(dl "https://api.github.com/repos/actions/runner/releases/latest" 2>/dev/null \
    | grep -m1 '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')"
  [ -n "${tag}" ] && echo "${tag}"
}

# ---- discovery ----------------------------------------------------------
# A runner = a directory containing config.sh + a configured .runner file.
list_runner_dirs() {
  [ -d "${RUNNER_ROOT}" ] || return 0
  ${SUDO} find "${RUNNER_ROOT}" -maxdepth 2 -name config.sh -printf '%h\n' 2>/dev/null | sort -u
}
runner_svc_name() { ${SUDO} cat "$1/.service" 2>/dev/null || true; }                          # systemd unit name
runner_url()      { ${SUDO} grep -o '"gitHubUrl": *"[^"]*"' "$1/.runner" 2>/dev/null | sed -E 's/.*"([^"]*)"$/\1/'; }
runner_agent()    { ${SUDO} grep -o '"agentName": *"[^"]*"' "$1/.runner" 2>/dev/null | sed -E 's/.*"([^"]*)"$/\1/'; }
runner_user()     { ${SUDO} stat -c '%U' "$1" 2>/dev/null || echo "?"; }
svc_state()       { [ -n "$1" ] && systemctl is-active "$1" 2>/dev/null || echo "unknown"; }

# Build a MENU of installed runners; the chosen dir lands in PICKED_DIR.
PICKED_DIR=""
pick_runner() {
  local dirs=() d
  while IFS= read -r d; do [ -n "$d" ] && dirs+=("$d"); done < <(list_runner_dirs)
  if [ "${#dirs[@]}" -eq 0 ]; then warn "No runners installed under ${RUNNER_ROOT}."; PICKED_DIR=""; return 1; fi
  MENU=()
  for d in "${dirs[@]}"; do
    local svc nm url st
    svc="$(runner_svc_name "$d")"; nm="$(runner_agent "$d")"; url="$(runner_url "$d")"; st="$(svc_state "${svc}")"
    MENU+=("Runners|${d}|${nm:-?}  [${st}]  ${url}")
  done
  menu_select "Pick a runner:" || { PICKED_DIR=""; return 1; }
  PICKED_DIR="${MENU_KEY}"
  return 0
}

# ---- actions ------------------------------------------------------------
a_install() {
  hd "Install a new self-hosted runner"
  info "Jobs with ${C_BOLD}runs-on: self-hosted${C_RESET} run on THIS machine — no GitHub-hosted minutes billed."

  local ARCH; ARCH="$(runner_arch)" || { err "Unsupported CPU arch: $(uname -m)"; return 1; }
  [ "$(uname -s)" = "Linux" ] || { err "This installer targets Linux only."; return 1; }

  # scope + target
  local SCOPE GH_PATH GH_URL
  SCOPE="$(ask_cfg CFG_RUNNER_SCOPE "Scope — [r]epo or [o]rg? [r/o]:" "r")"
  case "${SCOPE}" in o|O|org) SCOPE="org" ;; *) SCOPE="repo" ;; esac
  if [ "${SCOPE}" = "repo" ]; then
    GH_PATH="$(ask_cfg CFG_RUNNER_GH_PATH "Repo (owner/name), e.g. wanforge/scripts:" "")"
  else
    GH_PATH="$(ask_cfg CFG_RUNNER_GH_PATH "Org name, e.g. wanforge:" "")"
  fi
  [ -n "${GH_PATH}" ] || { err "Target is required."; return 1; }
  GH_URL="https://github.com/${GH_PATH}"

  # Registration token is short-lived — never cached
  local TOKEN; TOKEN="$(asks "Registration token (Settings → Actions → Runners → New runner):")"
  [ -n "${TOKEN}" ] || { err "Registration token is required."; return 1; }

  local NAME LABELS GROUP WORKDIR EPHEMERAL RUNNER_USER DIR
  NAME="$(ask_cfg CFG_RUNNER_NAME  "Runner name:" "$(hostname)-runner")"
  LABELS="$(ask_cfg CFG_RUNNER_LABELS  "Extra labels (comma-separated):" "self-hosted")"
  GROUP="$(ask_cfg CFG_RUNNER_GROUP  "Runner group:" "Default")"
  WORKDIR="$(ask_cfg CFG_RUNNER_WORKDIR  "Work directory (job checkout root):" "_work")"
  EPHEMERAL="$(ask_cfg CFG_RUNNER_EPHEMERAL  "Ephemeral? (auto-unregister after one job) [y/N]:" "n")"
  RUNNER_USER="$(ask_cfg CFG_RUNNER_USER  "System user to own/run the runner (NOT root):" "github-runner")"
  DIR="${RUNNER_ROOT}/${NAME}"

  # version
  info "Resolving latest runner version..."
  local VERSION; VERSION="$(latest_runner_version)" || true
  [ -n "${VERSION:-}" ] || VERSION="$(ask "Could not auto-detect; enter runner version (e.g. 2.323.0):" "")"
  [ -n "${VERSION}" ] || { err "Runner version is required."; return 1; }
  ok "Runner version: ${VERSION}"

  # prerequisites
  info "Installing prerequisites (curl, tar, ca-certificates)..."
  case "${PM}" in
    apt-get) run ${SUDO} apt-get update -y; pm_install curl tar ca-certificates ;;
    *)       pm_install curl tar ca-certificates || warn "Prereq install skipped/failed; continuing." ;;
  esac

  # service user (GitHub forbids running the service as root)
  if ! id "${RUNNER_USER}" >/dev/null 2>&1; then
    info "Creating system user ${RUNNER_USER}..."
    run ${SUDO} useradd --system --create-home --shell /bin/bash "${RUNNER_USER}" \
      || { err "Failed to create user ${RUNNER_USER}."; return 1; }
  else
    info "User ${RUNNER_USER} already exists."
  fi

  # download + extract
  local PKG PKG_URL
  PKG="actions-runner-linux-${ARCH}-${VERSION}.tar.gz"
  PKG_URL="https://github.com/actions/runner/releases/download/v${VERSION}/${PKG}"
  run ${SUDO} mkdir -p "${DIR}"
  info "Downloading ${PKG}..."
  run ${SUDO} bash -c "cd '${DIR}' && { command -v curl >/dev/null 2>&1 && curl -fsSL -o '${PKG}' '${PKG_URL}' || wget -qO '${PKG}' '${PKG_URL}'; }" \
    || { err "Download failed: ${PKG_URL}"; return 1; }
  info "Extracting..."
  run ${SUDO} tar -xzf "${DIR}/${PKG}" -C "${DIR}"
  run ${SUDO} rm -f "${DIR}/${PKG}"
  run ${SUDO} chown -R "${RUNNER_USER}:${RUNNER_USER}" "${DIR}"

  # runner-side OS deps (libicu, etc.)
  if [ -r "${DIR}/bin/installdependencies.sh" ]; then
    info "Installing runner dependencies..."
    run ${SUDO} bash "${DIR}/bin/installdependencies.sh" || warn "installdependencies.sh reported issues; continuing."
  fi

  # configure (unattended)
  local EPH_FLAG=""
  case "${EPHEMERAL}" in y|Y|yes) EPH_FLAG="--ephemeral" ;; esac
  info "Registering runner with ${GH_URL}..."
  run ${SUDO} -u "${RUNNER_USER}" bash -c "cd '${DIR}' && ./config.sh \
    --unattended \
    --url '${GH_URL}' \
    --token '${TOKEN}' \
    --name '${NAME}' \
    --labels '${LABELS}' \
    --runnergroup '${GROUP}' \
    --work '${WORKDIR}' \
    ${EPH_FLAG} \
    --replace" \
    || { err "Configuration failed (token may be expired — registration tokens are short-lived)."; return 1; }

  # install + start service
  info "Installing systemd service..."
  run ${SUDO} bash -c "cd '${DIR}' && ./svc.sh install '${RUNNER_USER}'" || { err "Service install failed."; return 1; }
  run ${SUDO} bash -c "cd '${DIR}' && ./svc.sh start"                     || { err "Service start failed."; return 1; }

  printf "\n%b✔ Runner '%s' installed and running.%b\n" "${C_BOLD}${C_GREEN}" "${NAME}" "${C_RESET}" >&2
  info "Scope:  ${SCOPE} (${GH_URL})"
  info "Dir:    ${DIR}    User: ${RUNNER_USER}"
  info "Labels: ${LABELS}${EPH_FLAG:+   (ephemeral)}"
  info "Use in a workflow:  ${C_BOLD}runs-on: [self-hosted]${C_RESET}  (or a custom label)"
}

a_list() {
  hd "Installed runners (under ${RUNNER_ROOT})"
  local any=0 d svc nm url st usr
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    any=1
    svc="$(runner_svc_name "$d")"; nm="$(runner_agent "$d")"; url="$(runner_url "$d")"
    st="$(svc_state "${svc}")"; usr="$(runner_user "$d")"
    printf "  %b●%b %-24s %b%-10s%b user=%-14s %s\n" \
      "${C_GREEN}" "${C_RESET}" "${nm:-?}" "${C_DIM}" "${st}" "${C_RESET}" "${usr}" "${url}" >&2
    printf "      %bdir:%b %s   %bsvc:%b %s\n" "${C_DIM}" "${C_RESET}" "$d" "${C_DIM}" "${C_RESET}" "${svc:-<none>}" >&2
  done < <(list_runner_dirs)
  [ "${any}" -eq 1 ] || warn "No runners found. Use Install to add one."
}

a_status() {
  pick_runner || return 0
  local svc; svc="$(runner_svc_name "${PICKED_DIR}")"
  if [ -n "${svc}" ]; then ${SUDO} systemctl status "${svc}" --no-pager >&2 || true
  else run ${SUDO} bash -c "cd '${PICKED_DIR}' && ./svc.sh status" || true; fi
}

a_logs() {
  pick_runner || return 0
  local svc; svc="$(runner_svc_name "${PICKED_DIR}")"
  [ -n "${svc}" ] || { warn "No service file in ${PICKED_DIR}."; return 0; }
  info "journalctl -u ${svc} (last 100 lines; Ctrl-C to exit a follow)"
  ${SUDO} journalctl -u "${svc}" -n 100 --no-pager >&2 || true
}

a_start()   { pick_runner || return 0; run ${SUDO} bash -c "cd '${PICKED_DIR}' && ./svc.sh start";  ok "Started."; }
a_stop()    { pick_runner || return 0; run ${SUDO} bash -c "cd '${PICKED_DIR}' && ./svc.sh stop";   ok "Stopped."; }
a_restart() { pick_runner || return 0; run ${SUDO} bash -c "cd '${PICKED_DIR}' && ./svc.sh stop"; run ${SUDO} bash -c "cd '${PICKED_DIR}' && ./svc.sh start"; ok "Restarted."; }

a_remove() {
  pick_runner || return 0
  local DIR="${PICKED_DIR}" usr url
  usr="$(runner_user "${DIR}")"; url="$(runner_url "${DIR}")"
  warn "About to UNREGISTER and DELETE runner in ${DIR} (${url})."
  local ANS; ANS="$(ask "Proceed? [y/N]:" "n")"
  case "${ANS}" in y|Y|yes) ;; *) info "Cancelled."; return 0 ;; esac

  # stop + uninstall the service first
  run ${SUDO} bash -c "cd '${DIR}' && ./svc.sh stop"      || true
  run ${SUDO} bash -c "cd '${DIR}' && ./svc.sh uninstall" || true

  # unregister from GitHub (needs a short-lived REMOVAL token from the runner's "Remove" dialog)
  local TOKEN; TOKEN="$(asks "Removal token (runner → Remove → copy token; Enter to skip):")"
  if [ -n "${TOKEN}" ]; then
    run ${SUDO} -u "${usr}" bash -c "cd '${DIR}' && ./config.sh remove --token '${TOKEN}'" \
      || warn "Unregister failed (token expired?). Remove it from the GitHub UI manually."
  else
    warn "No removal token given — runner left registered on GitHub. Delete it from the UI."
  fi

  local DEL; DEL="$(ask "Delete the runner directory ${DIR}? [y/N]:" "n")"
  case "${DEL}" in y|Y|yes) run ${SUDO} rm -rf "${DIR}"; ok "Directory removed." ;; esac
  ok "Removal complete."
}

# ---- menu (single-select TUI) -------------------------------------------
MENU=(
  "Runners|install|install a new self-hosted runner"
  "Runners|list|list runners on this host"
  "Manage|status|status of a runner"
  "Manage|logs|view logs (journald) of a runner"
  "Manage|start|start a runner service"
  "Manage|stop|stop a runner service"
  "Manage|restart|restart a runner service"
  "Manage|remove|unregister & remove a runner"
  "Config|clear_cfg|clear saved config (scope, name, labels, etc.)"
)

# ---- run ----------------------------------------------------------------
banner
PM="$(detect_pm)" || { err "No supported package manager found."; exit 1; }
have systemctl || warn "systemd not detected; service install/management may not work."
info "Self-hosted runners run jobs on THIS machine — GitHub-hosted minutes are not billed."
info "Docs: https://docs.github.com/actions/hosting-your-own-runners"

while true; do
  printf "\n" >&2
  menu_select "GitHub Actions runner manager:" || break
  case "${MENU_KEY}" in
    install) a_install ;;  list) a_list ;;
    status) a_status ;;    logs) a_logs ;;
    start) a_start ;;      stop) a_stop ;;   restart) a_restart ;;
    remove) a_remove ;;
    clear_cfg) cfg_clear && ok "Saved config cleared." ;;
  esac
done

printf "\n%b✔ github-runner manager finished.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
