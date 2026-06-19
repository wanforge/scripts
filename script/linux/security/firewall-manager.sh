#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# firewall-manager.sh — full ufw manager: status, enable/disable, default
# policy, allow/deny ports, allow/deny single & multiple IPs/CIDRs, IP→port
# rules, rate-limit, app profiles, delete rule, logging, reset.
#
# Usage:
#   curl -fsSL https://scripts.wanforge.asia/script/linux/security/firewall-manager.sh | bash
#   # dry-run (print ufw commands, change nothing):
#   curl -fsSL .../script/firewall-manager.sh | DRY_RUN=1 bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="firewall-manager"

# --- shared library: banner, colors, logging, prompts, checkbox ----------
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
else if command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}"); else . <(wget -qO- "${__LIB}"); fi; fi
cfg_load

# ---- helpers ------------------------------------------------------------
# DRY_RUN + run() come from lib.sh (global to all scripts).
ufw_run() { run ${SUDO} ufw "$@"; }
uw() { printf "\n%b▶ ufw %s%b\n" "${C_BOLD}${C_CYAN}" "$*" "${C_RESET}" >&2; if ufw_run "$@"; then ok "Done."; else err "ufw command failed."; fi; }
valid_addr() { [[ "$1" =~ ^[0-9a-fA-F:.]+(/[0-9]{1,3})?$ ]]; }
valid_proto() { case "$1" in tcp|udp|"") return 0;; *) return 1;; esac; }
ask_proto() { local p; p="$(ask "Protocol [tcp/udp/any]:" "any")"; case "$p" in tcp|udp) echo "$p";; *) echo "";; esac; }

# apply a from-rule (allow/deny) to one or many addresses
apply_addr_rule() {
  local action="$1" list="$2" port="${3:-}" proto="${4:-}"
  local a ok_n=0 bad_n=0
  for a in ${list//,/ }; do
    if ! valid_addr "$a"; then warn "Skip invalid address: $a"; bad_n=$((bad_n+1)); continue; fi
    if [ -n "$port" ]; then
      if [ -n "$proto" ]; then ufw_run "$action" from "$a" to any port "$port" proto "$proto"
      else ufw_run "$action" from "$a" to any port "$port"; fi
    else
      ufw_run "$action" from "$a"
    fi && ok_n=$((ok_n+1)) || bad_n=$((bad_n+1))
  done
  ok "${action}: ${ok_n} applied, ${bad_n} skipped/failed."
}

# ---- actions ------------------------------------------------------------
a_status()   { hd "Status (verbose)"; ufw_run status verbose >&2 || true; hd "Numbered rules"; ufw_run status numbered >&2 || true; }
a_enable()   { uw --force enable; }
a_disable()  { local c; c="$(ask "Disable the firewall? [y/N]:" "n")"; [[ "$c" =~ ^(y|Y|yes)$ ]] && uw disable || info "Kept enabled."; }
a_reload()   { uw reload; }
a_reset()    { warn "Reset DELETES ALL rules and disables ufw."; local c; c="$(ask "Type 'yes' to reset:" "no")"; [ "$c" = "yes" ] && uw --force reset || info "Aborted."; }
a_default()  {
  local dir pol
  dir="$(ask_cfg CFG_FW_DEFAULT_DIR "Direction [incoming/outgoing/routed]:" "incoming")"
  pol="$(ask_cfg CFG_FW_DEFAULT_POL "Policy [allow/deny/reject]:" "deny")"
  uw default "$pol" "$dir"
}
a_logging()  { local lv; lv="$(ask_cfg CFG_FW_LOGLEVEL "Logging level [on/off/low/medium/high/full]:" "low")"; uw logging "$lv"; }

a_allow_port() { local p pr; p="$(ask "Port (e.g. 8080 or 8000:8010):" "")"; req_nonempty "$p" || return; pr="$(ask_proto)"; [ -n "$pr" ] && uw allow "${p}/${pr}" || uw allow "${p}"; }
a_deny_port()  { local p pr; p="$(ask "Port to deny:" "")"; req_nonempty "$p" || return; pr="$(ask_proto)"; [ -n "$pr" ] && uw deny "${p}/${pr}" || uw deny "${p}"; }
a_limit_port() { local p pr; p="$(ask "Port to rate-limit (brute-force protection, e.g. 22):" "22")"; pr="$(ask_proto)"; [ -n "$pr" ] && uw limit "${p}/${pr}" || uw limit "${p}"; }

a_allow_ip()   { local ip; ip="$(ask "Allow from IP/CIDR:" "")"; req_nonempty "$ip" || return; apply_addr_rule allow "$ip"; }
a_deny_ip()    { local ip; ip="$(ask "Deny from IP/CIDR:" "")"; req_nonempty "$ip" || return; apply_addr_rule deny "$ip"; }
a_allow_many() { local list; list="$(ask "Allow these IPs/CIDRs (space/comma separated):" "")"; req_nonempty "$list" || return; apply_addr_rule allow "$list"; }
a_deny_many()  { local list; list="$(ask "Deny these IPs/CIDRs (space/comma separated):" "")"; req_nonempty "$list" || return; apply_addr_rule deny "$list"; }
a_allow_ip_port() { local ip p pr; ip="$(ask "Allow from IP/CIDR:" "")"; req_nonempty "$ip" || return; p="$(ask "To port:" "")"; req_nonempty "$p" || return; pr="$(ask_proto)"; apply_addr_rule allow "$ip" "$p" "$pr"; }
a_deny_ip_port()  { local ip p pr; ip="$(ask "Deny from IP/CIDR:" "")"; req_nonempty "$ip" || return; p="$(ask "To port:" "")"; req_nonempty "$p" || return; pr="$(ask_proto)"; apply_addr_rule deny "$ip" "$p" "$pr"; }

a_apps() {
  hd "Application profiles"; ufw_run app list >&2 || true
  local app; app="$(ask "Allow which app profile? (Enter to skip):" "")"
  [ -n "$app" ] && uw allow "$app" || info "Skipped."
}
a_delete() {
  hd "Numbered rules"; ufw_run status numbered >&2 || true
  local n; n="$(ask "Rule number to delete (Enter to skip):" "")"
  [ -z "$n" ] && { info "Skipped."; return; }
  [[ "$n" =~ ^[0-9]+$ ]] || { err "Invalid number."; return; }
  ufw_run --force delete "$n" >&2 && ok "Deleted rule ${n}." || err "Delete failed."
}

req_nonempty() { [ -n "$1" ] || { err "Value required."; return 1; }; }

# ---- menu (single-select TUI) -------------------------------------------
MENU=(
  "View & control|status|status (verbose + numbered)"
  "View & control|enable|enable firewall"
  "View & control|disable|disable firewall"
  "View & control|reload|reload"
  "View & control|reset|reset (danger)"
  "View & control|default|default policy"
  "View & control|logging|logging level"
  "Ports|allow_port|allow port"
  "Ports|deny_port|deny port"
  "Ports|limit_port|rate-limit port"
  "IP / subnet|allow_ip|allow IP/CIDR"
  "IP / subnet|deny_ip|deny IP/CIDR"
  "IP / subnet|allow_many|allow multiple IPs"
  "IP / subnet|deny_many|deny multiple IPs"
  "IP / subnet|allow_ip_port|allow IP → port"
  "IP / subnet|deny_ip_port|deny IP → port"
  "Apps & rules|apps|app profiles"
  "Apps & rules|delete|delete rule"
  "Config|clear_cfg|Clear saved config (default policy, logging)"
)

# ---- run ----------------------------------------------------------------
banner
[ "${DRY_RUN}" = "1" ] && warn "DRY-RUN mode: ufw commands are printed, not executed."
if [ "${DRY_RUN}" != "1" ] && ! command -v ufw >/dev/null 2>&1; then
  c="$(ask "ufw not installed. Install it now? [Y/n]:" "y")"
  case "$c" in n|N|no) err "ufw required."; exit 1 ;; *)
    if command -v apt-get >/dev/null 2>&1; then run ${SUDO} apt-get update && run ${SUDO} apt-get install -y ufw
    elif command -v dnf >/dev/null 2>&1; then run ${SUDO} dnf -y install ufw
    elif command -v pacman >/dev/null 2>&1; then run ${SUDO} pacman -S --noconfirm ufw
    elif command -v apk >/dev/null 2>&1; then run ${SUDO} apk add ufw
    else err "Install ufw manually."; exit 1; fi ;;
  esac
fi
warn "Tip: before enabling, allow your SSH port so you don't lock yourself out."

while true; do
  printf "\n" >&2
  menu_select "ufw firewall:" || break
  case "${MENU_KEY}" in
    status) a_status ;;     enable) a_enable ;;     disable) a_disable ;;
    reload) a_reload ;;     reset) a_reset ;;       default) a_default ;;
    logging) a_logging ;;   allow_port) a_allow_port ;; deny_port) a_deny_port ;;
    limit_port) a_limit_port ;; allow_ip) a_allow_ip ;;  deny_ip) a_deny_ip ;;
    allow_many) a_allow_many ;; deny_many) a_deny_many ;; allow_ip_port) a_allow_ip_port ;;
    deny_ip_port) a_deny_ip_port ;; apps) a_apps ;;   delete) a_delete ;;
    clear_cfg) cfg_clear && ok "Saved config cleared." ;;
  esac
done

printf "\n%b✔ firewall-manager finished.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
