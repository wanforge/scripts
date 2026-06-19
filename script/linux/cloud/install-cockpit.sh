#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# install-cockpit.sh — install the Cockpit web console with a grouped checkbox
# menu: core, reverse-proxy config, NetworkManager, plugins, and PCP metrics.
# Each action is selectable/skippable. Debian/Ubuntu only.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/cloud/install-cockpit.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="install-cockpit"

# --- shared library: banner, colors, logging, prompts, checkbox ----------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load

svc_enable_start() { local s="$1"; run ${SUDO} systemctl enable "$s" >/dev/null 2>&1 || true; run ${SUDO} systemctl start "$s" || true; }

# ---- menu ---------------------------------------------------------------
MENU=(
  "Core|cockpit|Web console: install, enable, start"
  "Core|ufw-9090|Open port 9090 in ufw (skip if proxied by CloudPanel)"
  "Proxy|cockpit-conf|Reverse-proxy config (AllowOrigins, X-Forwarded-Proto)"
  "Network|networkmanager|Install NetworkManager + netplan renderer (risky)"
  "Plugins|cockpit-networkmanager|Networking management"
  "Plugins|cockpit-storaged|Storage management"
  "Plugins|cockpit-sosreport|Diagnostic reports"
  "Plugins|cockpit-pcp|Performance metrics (PCP)"
  "Plugins|cockpit-machines|KVM / libvirt virtual machines"
  "Plugins|cockpit-podman|Podman containers"
  "Metrics|pmcd-pmlogger|Enable pmcd + pmlogger services"
)

# ---- run ----------------------------------------------------------------
banner
if ! command -v apt-get >/dev/null 2>&1; then err "This script targets Debian/Ubuntu (apt)."; exit 1; fi
checkbox "Select Cockpit actions:" || { warn "Cancelled."; exit 0; }
[ "${#CHOSEN_KEYS[@]}" -eq 0 ] && { warn "Nothing selected."; exit 0; }

run ${SUDO} apt-get update

# core
if has_key cockpit; then
  info "Installing Cockpit..."; run ${SUDO} apt-get install -y cockpit; svc_enable_start cockpit; ok "Cockpit running."
fi

# reverse-proxy config
if has_key cockpit-conf; then
  ORIGIN="$(ask_cfg CFG_COCKPIT_ORIGIN "Allowed origin domain (e.g. cockpit.domain.id, Enter to skip):" "")"
  ORIGIN="${ORIGIN#http://}"; ORIGIN="${ORIGIN#https://}"
  if [ -n "${ORIGIN}" ]; then
    warn "AllowUnencrypted=true is only safe behind a TLS-terminating proxy."
    run ${SUDO} mkdir -p /etc/cockpit
    printf '[WebService]\nAllowOrigins = %s\nProtocolHeader = X-Forwarded-Proto\nAllowUnencrypted = true\n' "${ORIGIN}" \
      | run ${SUDO} tee /etc/cockpit/cockpit.conf >/dev/null
    run ${SUDO} systemctl restart cockpit || true
    ok "Wrote /etc/cockpit/cockpit.conf (origin: ${ORIGIN})."
  else
    info "No origin given; skipped cockpit.conf."
  fi
fi

# firewall
if has_key ufw-9090; then
  if command -v ufw >/dev/null 2>&1; then ${SUDO} ufw allow 9090/tcp && ok "Opened 9090/tcp."
  else info "ufw not installed; skipped (Cockpit listens on 9090)."; fi
fi

# NetworkManager + netplan renderer
if has_key networkmanager; then
  warn "Changing the netplan renderer can drop your SSH connection. A backup is made."
  CONF="$(ask "Proceed with NetworkManager renderer? type 'yes' to confirm:" "no")"
  if [ "${CONF}" = "yes" ]; then
    run ${SUDO} apt-get install -y network-manager
    NP="$(ls /etc/netplan/*.yaml 2>/dev/null | head -1 || true)"
    if [ -n "${NP}" ]; then
      run ${SUDO} cp "${NP}" "${NP}.bak.$(date +%s 2>/dev/null || echo bak)" 2>/dev/null || true
      if ${SUDO} grep -qE '^\s*renderer:' "${NP}"; then
        run ${SUDO} sed -i 's|^\s*renderer:.*|  renderer: NetworkManager|' "${NP}"
      else
        run ${SUDO} sed -i 's|^\(network:\)|\1\n  renderer: NetworkManager|' "${NP}"
      fi
      run ${SUDO} netplan generate && ${SUDO} netplan apply || warn "netplan apply failed; check ${NP}.bak"
      svc_enable_start NetworkManager
      ok "NetworkManager renderer applied (backup: ${NP}.bak.*)."
    else
      warn "No /etc/netplan/*.yaml found; installed NetworkManager only."
    fi
  else
    info "Skipped NetworkManager renderer change."
  fi
fi

# plugins
PLUGINS=""
for p in cockpit-networkmanager cockpit-storaged cockpit-sosreport cockpit-pcp cockpit-machines cockpit-podman; do
  has_key "$p" && PLUGINS="${PLUGINS} ${p}"
done
if [ -n "${PLUGINS# }" ]; then
  info "Installing plugins:${PLUGINS}"
  run ${SUDO} apt-get install -y ${PLUGINS} || warn "Some plugins unavailable on this release."
fi

# PCP services
if has_key pmcd-pmlogger; then
  run ${SUDO} systemctl enable --now pmcd pmlogger 2>/dev/null && ok "pmcd/pmlogger enabled." || warn "Could not enable pmcd/pmlogger."
fi

printf "\n%b✔ Cockpit setup done.%b  %bhttp://127.0.0.1:9090%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" "${C_DIM}" "${C_RESET}" >&2
