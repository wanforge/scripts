#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# firewall-manager.sh — full ufw manager: status, enable/disable, default
# policy, allow/deny ports, allow/deny single & multiple IPs/CIDRs, IP→port
# rules, rate-limit, app profiles, delete rule, logging, reset.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/wanforge/server-mine/main/script/firewall-manager.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="firewall-manager"

# --- shared library: banner, colors, logging, prompts, checkbox ----------
__LIB="https://raw.githubusercontent.com/wanforge/server-mine/main/script/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/lib.sh" ]; then . "${__d}/lib.sh"
else . <(curl -fsSL "${__LIB}"); fi

# ---- helpers ------------------------------------------------------------
uw() { printf "\n%b▶ ufw %s%b\n" "${C_BOLD}${C_CYAN}" "$*" "${C_RESET}" >&2; if ${SUDO} ufw "$@"; then ok "Done."; else err "ufw command failed."; fi; }
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
      if [ -n "$proto" ]; then ${SUDO} ufw "$action" from "$a" to any port "$port" proto "$proto"
      else ${SUDO} ufw "$action" from "$a" to any port "$port"; fi
    else
      ${SUDO} ufw "$action" from "$a"
    fi && ok_n=$((ok_n+1)) || bad_n=$((bad_n+1))
  done
  ok "${action}: ${ok_n} applied, ${bad_n} skipped/failed."
}

# ---- actions ------------------------------------------------------------
a_status()   { hd "Status (verbose)"; ${SUDO} ufw status verbose >&2 || true; hd "Numbered rules"; ${SUDO} ufw status numbered >&2 || true; }
a_enable()   { uw --force enable; }
a_disable()  { local c; c="$(ask "Disable the firewall? [y/N]:" "n")"; [[ "$c" =~ ^(y|Y|yes)$ ]] && uw disable || info "Kept enabled."; }
a_reload()   { uw reload; }
a_reset()    { warn "Reset DELETES ALL rules and disables ufw."; local c; c="$(ask "Type 'yes' to reset:" "no")"; [ "$c" = "yes" ] && uw --force reset || info "Aborted."; }
a_default()  {
  local dir pol
  dir="$(ask "Direction [incoming/outgoing/routed]:" "incoming")"
  pol="$(ask "Policy [allow/deny/reject]:" "deny")"
  uw default "$pol" "$dir"
}
a_logging()  { local lv; lv="$(ask "Logging level [on/off/low/medium/high/full]:" "low")"; uw logging "$lv"; }

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
  hd "Application profiles"; ${SUDO} ufw app list >&2 || true
  local app; app="$(ask "Allow which app profile? (Enter to skip):" "")"
  [ -n "$app" ] && uw allow "$app" || info "Skipped."
}
a_delete() {
  hd "Numbered rules"; ${SUDO} ufw status numbered >&2 || true
  local n; n="$(ask "Rule number to delete (Enter to skip):" "")"
  [ -z "$n" ] && { info "Skipped."; return; }
  [[ "$n" =~ ^[0-9]+$ ]] || { err "Invalid number."; return; }
  ${SUDO} ufw --force delete "$n" >&2 && ok "Deleted rule ${n}." || err "Delete failed."
}

req_nonempty() { [ -n "$1" ] || { err "Value required."; return 1; }; }

# ---- menu ---------------------------------------------------------------
menu() {
  printf "%bufw firewall — choose an action (q to quit):%b\n" "${C_BOLD}" "${C_RESET}" >&2
  printf "  %b— View & control —%b\n" "${C_DIM}" "${C_RESET}" >&2
  printf "   1) status            2) enable            3) disable\n   4) reload            5) reset (danger)    6) default policy\n   7) logging level\n" >&2
  printf "  %b— Ports —%b\n" "${C_DIM}" "${C_RESET}" >&2
  printf "   8) allow port        9) deny port        10) rate-limit port\n" >&2
  printf "  %b— IP / subnet —%b\n" "${C_DIM}" "${C_RESET}" >&2
  printf "  11) allow IP/CIDR     12) deny IP/CIDR     13) allow multiple IPs\n  14) deny multiple IPs 15) allow IP→port    16) deny IP→port\n" >&2
  printf "  %b— Apps & rules —%b\n" "${C_DIM}" "${C_RESET}" >&2
  printf "  17) app profiles     18) delete rule\n" >&2
}

# ---- run ----------------------------------------------------------------
banner
if ! command -v ufw >/dev/null 2>&1; then
  c="$(ask "ufw not installed. Install it now? [Y/n]:" "y")"
  case "$c" in n|N|no) err "ufw required."; exit 1 ;; *)
    if command -v apt-get >/dev/null 2>&1; then ${SUDO} apt-get update && ${SUDO} apt-get install -y ufw
    elif command -v dnf >/dev/null 2>&1; then ${SUDO} dnf -y install ufw
    elif command -v pacman >/dev/null 2>&1; then ${SUDO} pacman -S --noconfirm ufw
    elif command -v apk >/dev/null 2>&1; then ${SUDO} apk add ufw
    else err "Install ufw manually."; exit 1; fi ;;
  esac
fi
warn "Tip: before enabling, allow your SSH port so you don't lock yourself out."

while true; do
  printf "\n" >&2; menu
  case "$(ask 'Action:' '')" in
    1) a_status ;;       2) a_enable ;;       3) a_disable ;;
    4) a_reload ;;       5) a_reset ;;        6) a_default ;;
    7) a_logging ;;      8) a_allow_port ;;   9) a_deny_port ;;
    10) a_limit_port ;;  11) a_allow_ip ;;    12) a_deny_ip ;;
    13) a_allow_many ;;  14) a_deny_many ;;   15) a_allow_ip_port ;;
    16) a_deny_ip_port ;; 17) a_apps ;;       18) a_delete ;;
    q|Q|quit|"") break ;; *) warn "Unknown choice." ;;
  esac
done

printf "\n%b✔ firewall-manager finished.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
