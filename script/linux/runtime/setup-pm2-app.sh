#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# setup-pm2-app.sh — configure pm2-logrotate and register an application with
# PM2 by generating an ecosystem.config.js, then start + save (no sudo).
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/runtime/setup-pm2-app.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="setup-pm2-app"

# --- shared library: banner, colors, logging, prompts, checkbox ----------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load
wf_log_init

# run as a target user (e.g. a CloudPanel site user) when invoked as root
maybe_switch_user "https://scripts.wanforge.asia/script/linux/runtime/setup-pm2-app.sh"

_pm2_load() {
  export NVM_DIR="${HOME}/.nvm"
  # shellcheck disable=SC1091
  [ -s "${NVM_DIR}/nvm.sh" ] && . "${NVM_DIR}/nvm.sh" && nvm use default >/dev/null 2>&1 || true
  command -v pm2 >/dev/null 2>&1 || { err "pm2 not found. Run install-nodejs.sh first."; return 1; }
}

a_uninstall() {
  hd "Remove PM2 Application"
  _pm2_load || return 1
  local app_name="${CFG_PM2_APP_NAME:-my-app}"
  warn "Will delete PM2 app '${app_name}' and save the process list."
  local yn; yn="$(ask "Delete PM2 app '${app_name}'? [y/N]:" "n")"
  case "${yn}" in y|Y|yes) ;; *) info "Cancelled."; return 0 ;; esac
  pm2 delete "${app_name}" 2>/dev/null || warn "App '${app_name}' not found in PM2 process list."
  pm2 save
  ok "PM2 app '${app_name}' removed."
}

# ---- run ----------------------------------------------------------------
case "${1:-}" in
  --stop)
    hd "Stop PM2 App";    _pm2_load || exit 1
    pm2 stop    "${CFG_PM2_APP_NAME:-my-app}" 2>/dev/null || warn "App not found in PM2"
    pm2 save; ok "Stopped.";    exit 0 ;;
  --start)
    hd "Start PM2 App";   _pm2_load || exit 1
    pm2 start   "${CFG_PM2_APP_NAME:-my-app}" 2>/dev/null || warn "App not found in PM2"
    pm2 save; ok "Started.";   exit 0 ;;
  --restart)
    hd "Restart PM2 App"; _pm2_load || exit 1
    pm2 restart "${CFG_PM2_APP_NAME:-my-app}" 2>/dev/null || warn "App not found in PM2"
    pm2 save; ok "Restarted."; exit 0 ;;
  --status)
    hd "PM2 Status"; _pm2_load || exit 1; pm2 list; exit 0 ;;
  --logs)
    hd "PM2 Logs"; _pm2_load || exit 1
    pm2 logs "${CFG_PM2_APP_NAME:-my-app}" --lines 50; exit 0 ;;
  --remove-cron)
    hd "Remove Cron"
    wf_cron_remove "pm2|${CFG_PM2_APP_NAME:-my-app}"; exit 0 ;;
  --uninstall) a_uninstall; exit $? ;;
esac
banner
if [ -z "${1:-}" ]; then
  MENU=(
    "Manage|configure|configure / register PM2 app"
    "Manage|stop|stop PM2 app"
    "Manage|start|start PM2 app"
    "Manage|restart|restart PM2 app"
    "Manage|status|show PM2 status"
    "Manage|logs|tail PM2 app logs"
    "Manage|remove_cron|remove related cron entries"
    "Manage|uninstall|delete PM2 app"
  )
  menu_select "PM2 App — choose action:" || exit 0
  case "${MENU_KEY}" in
    stop)        hd "Stop PM2 App";    _pm2_load || exit 1; pm2 stop    "${CFG_PM2_APP_NAME:-my-app}" 2>/dev/null || true; pm2 save; ok "Stopped.";    exit 0 ;;
    start)       hd "Start PM2 App";   _pm2_load || exit 1; pm2 start   "${CFG_PM2_APP_NAME:-my-app}" 2>/dev/null || true; pm2 save; ok "Started.";   exit 0 ;;
    restart)     hd "Restart PM2 App"; _pm2_load || exit 1; pm2 restart "${CFG_PM2_APP_NAME:-my-app}" 2>/dev/null || true; pm2 save; ok "Restarted."; exit 0 ;;
    status)      hd "PM2 Status";      _pm2_load || exit 1; pm2 list;   exit 0 ;;
    logs)        hd "PM2 Logs";        _pm2_load || exit 1; pm2 logs "${CFG_PM2_APP_NAME:-my-app}" --lines 50; exit 0 ;;
    remove_cron) wf_cron_remove "pm2|${CFG_PM2_APP_NAME:-my-app}"; exit 0 ;;
    uninstall)   a_uninstall; exit $? ;;
    configure|*) ;;
  esac
fi

# make pm2 (installed via nvm) available in this shell
export NVM_DIR="${HOME}/.nvm"
# shellcheck disable=SC1091
[ -s "${NVM_DIR}/nvm.sh" ] && . "${NVM_DIR}/nvm.sh" && nvm use default >/dev/null 2>&1 || true
if ! command -v pm2 >/dev/null 2>&1; then
  err "pm2 not found. Run install-nodejs.sh first (it installs Node + PM2)."
  exit 1
fi
info "Using $(pm2 -v 2>/dev/null && echo "pm2 $(pm2 -v)" || echo pm2)"

# ---- pm2-logrotate config (optional) ------------------------------------
LR_ANS="$(ask_cfg CFG_PM2_LOGROTATE "Configure pm2-logrotate (size/retention/compress)? [Y/n]:" "y")"
case "${LR_ANS}" in
  n|N|no) info "Skipped logrotate config." ;;
  *)
    pm2 install pm2-logrotate >/dev/null 2>&1 || true
    MAXSIZE="$(ask_cfg CFG_PM2_LR_MAXSIZE "Max log size before rotate:" "10M")"
    RETAIN="$(ask_cfg CFG_PM2_LR_RETAIN "Number of rotated files to keep:" "30")"
    COMPRESS="$(ask_cfg CFG_PM2_LR_COMPRESS "Compress rotated logs? [Y/n]:" "y")"
    [[ "${COMPRESS}" =~ ^(n|N|no)$ ]] && COMPRESS="false" || COMPRESS="true"
    pm2 set pm2-logrotate:max_size "${MAXSIZE}"
    pm2 set pm2-logrotate:retain "${RETAIN}"
    pm2 set pm2-logrotate:compress "${COMPRESS}"
    pm2 set pm2-logrotate:rotateInterval '0 0 * * *'
    ok "pm2-logrotate: max_size=${MAXSIZE}, retain=${RETAIN}, compress=${COMPRESS}"
    ;;
esac

# ---- define an application ----------------------------------------------
APP_ANS="$(ask "Register an application now? [Y/n]:" "y")"
case "${APP_ANS}" in
  n|N|no) info "No app registered."; pm2 save || true; exit 0 ;;
esac

APP_NAME="$(ask_cfg CFG_PM2_APP_NAME "App name:" "my-app")"
APP_CWD="$(ask_cfg CFG_PM2_APP_CWD "Working directory (project path):" "$(pwd)")"
if [ ! -d "${APP_CWD}" ]; then err "Directory not found: ${APP_CWD}"; exit 1; fi
APP_SCRIPT="$(ask_cfg CFG_PM2_APP_SCRIPT "Entry script or command (e.g. app.js, dist/main.js, npm):" "app.js")"
APP_ARGS="$(ask_cfg CFG_PM2_APP_ARGS "Arguments (e.g. 'run start' for npm, empty otherwise):" "")"
APP_INSTANCES="$(ask_cfg CFG_PM2_APP_INSTANCES "Instances (1, a number, or 'max' for cluster):" "1")"
if [ "${APP_INSTANCES}" = "1" ]; then EXEC_MODE="fork"; else EXEC_MODE="cluster"; fi
APP_NODE_ENV="$(ask_cfg CFG_PM2_APP_NODE_ENV "NODE_ENV:" "production")"
APP_MEM="$(ask_cfg CFG_PM2_APP_MEM "Restart if memory exceeds:" "300M")"

ECOSYS="${APP_CWD}/ecosystem.config.js"
if [ -f "${ECOSYS}" ]; then
  OVERWRITE="$(ask "${ECOSYS} exists. Overwrite? [y/N]:" "n")"
  [[ "${OVERWRITE}" =~ ^(y|Y|yes)$ ]] || { err "Aborted to avoid overwriting."; exit 1; }
fi

# normalise instances value for JS (quote 'max', keep numbers bare)
if [ "${APP_INSTANCES}" = "max" ]; then INST_JS='"max"'; else INST_JS="${APP_INSTANCES}"; fi
# args line only if provided
ARGS_LINE=""
[ -n "${APP_ARGS}" ] && ARGS_LINE="    args: \"${APP_ARGS}\","

cat > "${ECOSYS}" <<EOF
// Generated by wanforge.asia setup-pm2-app.sh
module.exports = {
  apps: [
    {
      name: "${APP_NAME}",
      cwd: "${APP_CWD}",
      script: "${APP_SCRIPT}",
${ARGS_LINE}
      instances: ${INST_JS},
      exec_mode: "${EXEC_MODE}",
      autorestart: true,
      max_memory_restart: "${APP_MEM}",
      env: {
        NODE_ENV: "${APP_NODE_ENV}"
      }
    }
  ]
};
EOF
ok "Wrote ${ECOSYS}"

info "Starting app with PM2..."
pm2 start "${ECOSYS}" --update-env
pm2 save
ok "Saved PM2 process list."
pm2 list || true

printf "\n%b✔ PM2 app configured.%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
printf "%b  Manage: pm2 status · pm2 logs %s · pm2 restart %s%b\n\n" "${C_DIM}" "${APP_NAME}" "${APP_NAME}" "${C_RESET}" >&2
