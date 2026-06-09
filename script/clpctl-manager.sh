#!/usr/bin/env bash
# shellcheck disable=SC2086
#
# clpctl-manager.sh — interactive wrapper around the CloudPanel CLI (clpctl).
# Covers the documented v2 commands: basic-auth, cloudflare, database,
# Let's Encrypt, sites, users, vhost-templates, permissions, varnish cache.
#
# Reference: https://www.cloudpanel.io/docs/v2/cloudpanel-cli/
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/wanforge/server-mine/main/script/clpctl-manager.sh | bash
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail
TASK="clpctl-manager"

# --- shared library: banner, colors, logging, prompts, checkbox ----------
__LIB="https://raw.githubusercontent.com/wanforge/server-mine/main/script/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -r "${__d}/lib.sh" ]; then . "${__d}/lib.sh"
else . <(curl -fsSL "${__LIB}"); fi

# run clpctl with args; never echoes secret values
runclp() {
  printf "\n%b▶ clpctl %s%b\n" "${C_BOLD}${C_CYAN}" "$1" "${C_RESET}" >&2
  if ${SUDO} clpctl "$@"; then ok "Done."; else err "Command failed."; fi
}
req() { # req VALUE NAME — abort action if empty
  [ -n "$1" ] || { err "$2 is required."; return 1; }
}

# ---- actions ------------------------------------------------------------
a_basic_auth_enable() { local u p; u="$(ask 'Username:')"; req "$u" username || return; p="$(asks 'Password:')"; req "$p" password || return; runclp cloudpanel:enable:basic-auth --userName="$u" --password="$p"; }
a_basic_auth_disable() { runclp cloudpanel:disable:basic-auth; }
a_cloudflare_ips() { runclp cloudflare:update:ips; }

a_db_master() { runclp db:show:master-credentials; }
a_db_add() { local d n u p; d="$(ask 'Domain (site):')"; n="$(ask 'Database name:')"; u="$(ask 'DB user name:')"; p="$(asks 'DB user password:')"; req "$d" domain || return; req "$n" db || return; req "$u" user || return; req "$p" pass || return; runclp db:add --domainName="$d" --databaseName="$n" --databaseUserName="$u" --databaseUserPassword="$p"; }
a_db_export() { local n f; n="$(ask 'Database name:')"; f="$(ask 'Output file:' 'dump.sql.gz')"; req "$n" db || return; runclp db:export --databaseName="$n" --file="$f"; }
a_db_import() { local n f; n="$(ask 'Database name:')"; f="$(ask 'Input file:' 'dump.sql.gz')"; req "$n" db || return; req "$f" file || return; runclp db:import --databaseName="$n" --file="$f"; }

a_le_cert() { local d s; d="$(ask 'Domain:')"; req "$d" domain || return; s="$(ask 'Subject Alternative Names (comma-sep, Enter to skip):')"; if [ -n "$s" ]; then runclp lets-encrypt:install:certificate --domainName="$d" --subjectAlternativeName="$s"; else runclp lets-encrypt:install:certificate --domainName="$d"; fi; }

a_site_php() { local d v t u p; d="$(ask 'Domain:')"; v="$(ask 'PHP version:' '8.4')"; t="$(ask 'vHost template:' 'Generic')"; u="$(ask 'Site user:')"; p="$(asks 'Site user password:')"; req "$d" domain || return; req "$u" user || return; req "$p" pass || return; runclp site:add:php --domainName="$d" --phpVersion="$v" --vhostTemplate="$t" --siteUser="$u" --siteUserPassword="$p"; }
a_site_nodejs() { local d v port u p; d="$(ask 'Domain:')"; v="$(ask 'Node.js version:' '22')"; port="$(ask 'App port:' '3000')"; u="$(ask 'Site user:')"; p="$(asks 'Site user password:')"; req "$d" domain || return; req "$u" user || return; req "$p" pass || return; runclp site:add:nodejs --domainName="$d" --nodejsVersion="$v" --appPort="$port" --siteUser="$u" --siteUserPassword="$p"; }
a_site_python() { local d v port u p; d="$(ask 'Domain:')"; v="$(ask 'Python version:' '3.11')"; port="$(ask 'App port:' '8080')"; u="$(ask 'Site user:')"; p="$(asks 'Site user password:')"; req "$d" domain || return; req "$u" user || return; req "$p" pass || return; runclp site:add:python --domainName="$d" --pythonVersion="$v" --appPort="$port" --siteUser="$u" --siteUserPassword="$p"; }
a_site_static() { local d u p; d="$(ask 'Domain:')"; u="$(ask 'Site user:')"; p="$(asks 'Site user password:')"; req "$d" domain || return; req "$u" user || return; req "$p" pass || return; runclp site:add:static --domainName="$d" --siteUser="$u" --siteUserPassword="$p"; }
a_site_proxy() { local d url u p; d="$(ask 'Domain:')"; url="$(ask 'Reverse proxy URL:' 'http://127.0.0.1:3000')"; u="$(ask 'Site user:')"; p="$(asks 'Site user password:')"; req "$d" domain || return; req "$u" user || return; req "$p" pass || return; runclp site:add:reverse-proxy --domainName="$d" --reverseProxyUrl="$url" --siteUser="$u" --siteUserPassword="$p"; }
a_site_cert() { local d k c ch; d="$(ask 'Domain:')"; k="$(ask 'Private key path:')"; c="$(ask 'Certificate path:')"; ch="$(ask 'Certificate chain path (Enter to skip):')"; req "$d" domain || return; req "$k" key || return; req "$c" cert || return; if [ -n "$ch" ]; then runclp site:install:certificate --domainName="$d" --privateKey="$k" --certificate="$c" --certificateChain="$ch"; else runclp site:install:certificate --domainName="$d" --privateKey="$k" --certificate="$c"; fi; }
a_site_delete() { local d f; d="$(ask 'Domain to DELETE:')"; req "$d" domain || return; f="$(ask 'Force (skip confirmation)? [y/N]:' 'n')"; if [[ "$f" =~ ^(y|Y|yes)$ ]]; then runclp site:delete --domainName="$d" --force; else runclp site:delete --domainName="$d"; fi; }

a_user_add() { local u e fn ln p r tz s sites; u="$(ask 'Username:')"; e="$(ask 'Email:')"; fn="$(ask 'First name:')"; ln="$(ask 'Last name:')"; p="$(asks 'Password:')"; r="$(ask 'Role (admin/site-manager/user):' 'admin')"; tz="$(ask 'Timezone:' 'Asia/Jakarta')"; s="$(ask 'Status (1=active,0=inactive):' '1')"; req "$u" user || return; req "$e" email || return; req "$p" pass || return; if [ "$r" = "user" ]; then sites="$(ask 'Sites (comma-sep, e.g. domain.com,domain.io):')"; runclp user:add --userName="$u" --email="$e" --firstName="$fn" --lastName="$ln" --password="$p" --role="$r" --sites="$sites" --timezone="$tz" --status="$s"; else runclp user:add --userName="$u" --email="$e" --firstName="$fn" --lastName="$ln" --password="$p" --role="$r" --timezone="$tz" --status="$s"; fi; }
a_user_delete() { local u; u="$(ask 'Username to delete:')"; req "$u" user || return; runclp user:delete --userName="$u"; }
a_user_list() { runclp user:list; }
a_user_reset() { local u p; u="$(ask 'Username:')"; p="$(asks 'New password:')"; req "$u" user || return; req "$p" pass || return; runclp user:reset:password --userName="$u" --password="$p"; }
a_user_mfa_off() { local u; u="$(ask 'Username:')"; req "$u" user || return; runclp user:disable:mfa --userName="$u"; }

a_vht_list() { runclp vhost-templates:list; }
a_vht_import() { runclp vhost-templates:import; }
a_vht_add() { local n f; n="$(ask 'Template name:')"; f="$(ask 'File path or URL:')"; req "$n" name || return; req "$f" file || return; runclp vhost-template:add --name="$n" --file="$f"; }
a_vht_delete() { local n; n="$(ask 'Template name:')"; req "$n" name || return; runclp vhost-template:delete --name="$n"; }
a_vht_view() { local n; n="$(ask 'Template name:')"; req "$n" name || return; runclp vhost-template:view --name="$n"; }

a_perms_reset() { local d f path; d="$(ask 'Directory perms:' '770')"; f="$(ask 'File perms:' '660')"; path="$(ask 'Path:' '.')"; runclp system:permissions:reset --directories="$d" --files="$f" --path="$path"; }
a_varnish_purge() { local v; v="$(ask "Purge target ('all', 'tag1,tag2', or a URL):" 'all')"; runclp varnish-cache:purge --purge="$v"; }

# ---- menu (single-select TUI) -------------------------------------------
MENU=(
  "CloudPanel|ba_enable|basic-auth enable"
  "CloudPanel|ba_disable|basic-auth disable"
  "CloudPanel|cf_ips|cloudflare update IPs"
  "Database|db_master|show master credentials"
  "Database|db_add|db add"
  "Database|db_export|db export"
  "Database|db_import|db import"
  "Certificates|le_cert|Let's Encrypt install"
  "Certificates|site_cert|install custom cert"
  "Sites|site_php|add PHP site"
  "Sites|site_nodejs|add Node.js site"
  "Sites|site_python|add Python site"
  "Sites|site_static|add Static site"
  "Sites|site_proxy|add Reverse Proxy"
  "Sites|site_delete|delete site"
  "Users|user_add|add user"
  "Users|user_delete|delete user"
  "Users|user_list|list users"
  "Users|user_reset|reset password"
  "Users|user_mfa_off|disable MFA"
  "vHost Templates|vht_list|list"
  "vHost Templates|vht_import|import"
  "vHost Templates|vht_add|add"
  "vHost Templates|vht_delete|delete"
  "vHost Templates|vht_view|view"
  "System|perms_reset|reset permissions"
  "System|varnish_purge|purge varnish cache"
)

# ---- run ----------------------------------------------------------------
banner
if ! command -v clpctl >/dev/null 2>&1; then
  err "clpctl not found. Install CloudPanel first (install-cloudpanel.sh)."
  exit 1
fi
warn "Passwords are passed to clpctl as flags (CloudPanel's interface) and may briefly appear in the process list."

while true; do
  printf "\n" >&2
  menu_select "CloudPanel CLI:" || break
  case "${MENU_KEY}" in
    ba_enable) a_basic_auth_enable ;;  ba_disable) a_basic_auth_disable ;; cf_ips) a_cloudflare_ips ;;
    db_master) a_db_master ;;          db_add) a_db_add ;;                 db_export) a_db_export ;;
    db_import) a_db_import ;;           le_cert) a_le_cert ;;               site_cert) a_site_cert ;;
    site_php) a_site_php ;;             site_nodejs) a_site_nodejs ;;       site_python) a_site_python ;;
    site_static) a_site_static ;;       site_proxy) a_site_proxy ;;         site_delete) a_site_delete ;;
    user_add) a_user_add ;;            user_delete) a_user_delete ;;       user_list) a_user_list ;;
    user_reset) a_user_reset ;;         user_mfa_off) a_user_mfa_off ;;
    vht_list) a_vht_list ;;            vht_import) a_vht_import ;;          vht_add) a_vht_add ;;
    vht_delete) a_vht_delete ;;         vht_view) a_vht_view ;;
    perms_reset) a_perms_reset ;;      varnish_purge) a_varnish_purge ;;
  esac
done

printf "\n%b✔ clpctl-manager finished.%b\n\n" "${C_BOLD}${C_GREEN}" "${C_RESET}" >&2
