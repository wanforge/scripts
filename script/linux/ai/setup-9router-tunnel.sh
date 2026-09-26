#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2034
#
# setup-9router-tunnel.sh — integrate 9Router AI Gateway with Cloudflare Tunnel,
# configure custom domain proxy, and link endpoints to Hermes & Claude Code.
#
# Usage:
#   ./setup-9router-tunnel.sh
#   ./setup-9router-tunnel.sh --domain "ai.example.com" --port 20128
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail

TASK="setup-9router-tunnel"
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

if   [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
elif [ -r "${__d}/lib.sh" ]; then . "${__d}/lib.sh"
elif [ -n "${WF_INSTALL_DIR:-}" ] && [ -r "${WF_INSTALL_DIR}/lib.sh" ]; then . "${WF_INSTALL_DIR}/lib.sh"
elif [ -r "/opt/wanforge-scripts/lib.sh" ]; then . "/opt/wanforge-scripts/lib.sh"
elif [ -r "${HOME:-}/.local/lib/wanforge-scripts/lib.sh" ]; then . "${HOME}/.local/lib/wanforge-scripts/lib.sh"
elif command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}")
else . <(wget -qO- "${__LIB}"); fi

banner "9Router & Cloudflare Tunnel Proxy Setup"

ROUTER_HOST="127.0.0.1"
ROUTER_PORT="20128"
CF_DIR="${HOME}/.cloudflared"
mkdir -p "${CF_DIR}"

# --- Check cloudflared binary --------------------------------------------
check_cloudflared() {
  if ! command -v cloudflared >/dev/null 2>&1; then
    warn "Biner 'cloudflared' belum terpasang di sistem."
    if ask "Pasang cloudflared sekarang via installer wanforge?" 1; then
      local cf_installer="${__d}/../network/install-cloudflared.sh"
      if [ -x "${cf_installer}" ]; then
        bash "${cf_installer}"
      else
        sub "Mengunduh biner resmi cloudflared..."
        local arch
        case "$(uname -m)" in
          x86_64)  arch="amd64" ;;
          aarch64) arch="arm64" ;;
          armv7l)  arch="arm" ;;
          *) arch="amd64" ;;
        esac
        local tmp_bin; tmp_bin="$(mktemp)"
        curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" -o "${tmp_bin}"
        chmod +x "${tmp_bin}"
        if [ "$(id -u)" -eq 0 ]; then
          mv -f "${tmp_bin}" /usr/local/bin/cloudflared
        else
          mkdir -p "${HOME}/.local/bin"
          mv -f "${tmp_bin}" "${HOME}/.local/bin/cloudflared"
          export PATH="${HOME}/.local/bin:${PATH}"
        fi
        ok "cloudflared berhasil diinstal."
      fi
    else
      err "cloudflared diperlukan untuk mengonfigurasi tunnel."
      return 1
    fi
  fi
  ok "cloudflared biner: $(cloudflared --version | head -n1)"
  return 0
}

# --- Health check 9Router -------------------------------------------------
check_9router_health() {
  sub "Memeriksa status 9Router AI Gateway di http://${ROUTER_HOST}:${ROUTER_PORT}..."
  if curl -s --max-time 3 "http://${ROUTER_HOST}:${ROUTER_PORT}/api/health" >/dev/null 2>&1; then
    ok "9Router aktif dan merespons: http://${ROUTER_HOST}:${ROUTER_PORT}"
    return 0
  else
    warn "9Router tidak merespons di port ${ROUTER_PORT}."
    info "Pastikan 9Router berjalan (contoh: 9router -t atau systemctl --user status 9router)."
    return 1
  fi
}

# --- Action: Quick Ephemeral Tunnel ---------------------------------------
action_quick_tunnel() {
  check_cloudflared || return 1
  info "Memulai Quick Ephemeral Tunnel Cloudflare (trycloudflare.com)..."
  info "Endpoint 9Router lokal http://${ROUTER_HOST}:${ROUTER_PORT} akan diekspos sementara."
  info "Tekan Ctrl+C untuk menghentikan tunnel kapan saja."
  echo ""
  cloudflared tunnel --url "http://${ROUTER_HOST}:${ROUTER_PORT}"
}

# --- Action: Named Tunnel & Custom Domain ---------------------------------
action_named_tunnel() {
  check_cloudflared || return 1

  info "Konfigurasi Named Tunnel Cloudflare dengan Custom Domain (contoh: ai.wanforge.asia)."
  local domain; domain="$(ask_cfg "Masukkan Domain / Subdomain yang diarahkan ke 9Router" "ai.wanforge.asia")"
  if [ -z "${domain}" ]; then
    err "Domain tidak boleh kosong."
    return 1
  fi

  local tunnel_name; tunnel_name="$(ask_cfg "Nama Tunnel Cloudflare" "9router-tunnel")"

  # 1. Login check
  if [ ! -f "${CF_DIR}/cert.pem" ]; then
    info "Sertifikat origin cert.pem belum ada. Silakan login ke Cloudflare:"
    cloudflared tunnel login
  fi

  # 2. Create or verify tunnel
  sub "Membuat atau memverifikasi tunnel '${tunnel_name}'..."
  local tunnel_id=""
  local list_out; list_out="$(cloudflared tunnel list 2>/dev/null || true)"
  if echo "${list_out}" | grep -q "${tunnel_name}"; then
    tunnel_id="$(echo "${list_out}" | awk -v name="${tunnel_name}" '$2 == name {print $1}')"
    ok "Tunnel ditemukan dengan ID: ${tunnel_id}"
  else
    local create_out; create_out="$(cloudflared tunnel create "${tunnel_name}")"
    tunnel_id="$(echo "${create_out}" | grep -oE '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' | head -n1 || true)"
    if [ -z "${tunnel_id}" ]; then
      err "Gagal membuat tunnel. Output:\n${create_out}"
      return 1
    fi
    ok "Tunnel '${tunnel_name}' berhasil dibuat: ID ${tunnel_id}"
  fi

  # 3. Write ingress config
  local conf_file="${CF_DIR}/config.yml"
  sub "Menulis konfigurasi ingress di ${conf_file}..."
  cat > "${conf_file}" <<EOF
tunnel: ${tunnel_id}
credentials-file: ${CF_DIR}/${tunnel_id}.json

ingress:
  - hostname: ${domain}
    service: http://${ROUTER_HOST}:${ROUTER_PORT}
    originRequest:
      noTLSVerify: true
      connectTimeout: 30s
  - service: http_status:404
EOF
  ok "Konfigurasi ingress Cloudflare Tunnel tersimpan di ${conf_file}."

  # 4. Route DNS
  if ask "Buat DNS CNAME '${domain}' otomatis di Cloudflare?" 1; then
    sub "Mengarahkan DNS ${domain} ke tunnel ${tunnel_name}..."
    cloudflared tunnel route dns "${tunnel_name}" "${domain}" || true
    ok "Rute DNS dibuat untuk ${domain}."
  fi

  # 5. Service setup
  if ask "Pasang service daemon untuk tunnel ini?" 1; then
    if [ "$(id -u)" -eq 0 ]; then
      cloudflared --config "${conf_file}" service install || true
      systemctl enable --now cloudflared 2>/dev/null || true
      ok "Service systemd cloudflared aktif di tingkat sistem."
    else
      local user_svc_dir="${HOME}/.config/systemd/user"
      mkdir -p "${user_svc_dir}"
      local user_svc="${user_svc_dir}/cloudflared-9router.service"
      cat > "${user_svc}" <<EOF
[Unit]
Description=Cloudflare Tunnel for 9Router AI Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(which cloudflared) tunnel --config ${conf_file} run
Restart=always
RestartSec=5
KillMode=mixed
TimeoutStopSec=20

[Install]
WantedBy=default.target
EOF
      systemctl --user daemon-reload 2>/dev/null || true
      systemctl --user enable --now cloudflared-9router.service 2>/dev/null || true
      ok "User systemd service terpasang: cloudflared-9router.service"
    fi
  fi

  # 6. Offer updating Hermes & Claude configurations
  if ask "Perbarui konfigurasi Hermes & Claude Code agar menggunakan custom domain 'https://${domain}/v1'?" 1; then
    update_agent_endpoints "https://${domain}/v1"
  fi

  printf "\n%b✔ Setup Custom Domain Proxy Selesai!%b\n" "${C_BOLD}${C_GREEN}" "${C_RESET}"
  printf "  • URL Publik AI Gateway: %bhttps://%s/v1%b\n" "${C_BOLD}${C_CYAN}" "${domain}" "${C_RESET}"
  printf "  • Health Endpoint      : https://%s/api/health\n" "${domain}"
  printf "  • Models List Endpoint : https://%s/v1/models\n\n" "${domain}"
}

# --- Action: Zero Trust Token Service Setup -------------------------------
action_token_service() {
  check_cloudflared || return 1
  info "Setup Cloudflare Tunnel via Token Zero Trust Dashboard (One-Click)."
  local token; token="$(ask_secret "Masukkan Token Cloudflare Tunnel (eyJh...):")"
  if [ -z "${token}" ]; then
    err "Token tidak boleh kosong."
    return 1
  fi

  if [ "$(id -u)" -eq 0 ]; then
    sub "Menginstal service cloudflared sistem via token..."
    cloudflared service install "${token}"
    systemctl enable --now cloudflared
    ok "Service cloudflared terpasang dan berjalan via token."
  else
    sub "Menginstal service user systemd cloudflared via token..."
    local user_svc_dir="${HOME}/.config/systemd/user"
    mkdir -p "${user_svc_dir}"
    local user_svc="${user_svc_dir}/cloudflared.service"
    cat > "${user_svc}" <<EOF
[Unit]
Description=Cloudflare Zero Trust Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(which cloudflared) tunnel run --token ${token}
Restart=always
RestartSec=5
TimeoutStopSec=20

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now cloudflared.service
    ok "User systemd service terpasang: cloudflared.service"
  fi
}

# --- Action: Update Agent Endpoints ---------------------------------------
update_agent_endpoints() {
  local target_url="$1"
  sub "Memperbarui konfigurasi endpoint AI Agent ke: ${target_url}"

  # 1. Update Claude Code settings
  local claude_settings="${HOME}/.claude/settings.json"
  if [ -f "${claude_settings}" ] || [ -d "${HOME}/.claude" ]; then
    mkdir -p "${HOME}/.claude"
    if command -v jq >/dev/null 2>&1; then
      local tmp_json; tmp_json="$(mktemp)"
      if [ -f "${claude_settings}" ]; then
        jq --arg url "${target_url}" '.env.ANTHROPIC_BASE_URL = $url' "${claude_settings}" > "${tmp_json}" && mv -f "${tmp_json}" "${claude_settings}"
      else
        cat > "${claude_settings}" <<EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "${target_url}",
    "_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL": "1"
  }
}
EOF
      fi
      ok "Claude Code settings.json diperbarui: ANTHROPIC_BASE_URL=${target_url}"
    fi
  fi

  # 2. Update Hermes config.yaml
  local hermes_cfg="${HERMES_HOME:-${HOME}/.hermes}/config.yaml"
  if [ -f "${hermes_cfg}" ] && command -v python3 >/dev/null 2>&1; then
    python3 - <<EOF
import yaml, os
cfg = "${hermes_cfg}"
if os.path.exists(cfg):
    with open(cfg, "r") as f:
        d = yaml.safe_load(f) or {}
    if "custom_providers" not in d or not isinstance(d["custom_providers"], list):
        d["custom_providers"] = []
    found = False
    for p in d["custom_providers"]:
        if isinstance(p, dict) and ("9router" in p.get("name", "").lower() or "localhost:20128" in p.get("base_url", "")):
            p["base_url"] = "${target_url}"
            found = True
            break
    if not found:
        d["custom_providers"].append({
            "name": "9Router-Proxy",
            "base_url": "${target_url}",
            "key_env": "NINEROUTER_API_KEY",
            "model": "hermes"
        })
    with open(cfg, "w") as f:
        yaml.dump(d, f, default_flow_style=False, sort_keys=False)
    print("Hermes config.yaml custom_providers updated.")
EOF
    ok "Hermes config.yaml diperbarui dengan endpoint Cloudflare Proxy."
  fi
}

# --- Action: Test Endpoint ------------------------------------------------
action_test_endpoint() {
  local ep; ep="$(ask_cfg "Masukkan URL endpoint untuk diuji" "http://${ROUTER_HOST}:${ROUTER_PORT}/api/health")"
  sub "Menguji koneksi ke ${ep}..."
  local res; res="$(curl -s -w "\nHTTP_STATUS:%{http_code}" --max-time 10 "${ep}" || true)"
  printf "\n%bHasil Uji Koneksi:%b\n%s\n\n" "${C_CYAN}" "${C_RESET}" "${res}"
}

# --- Interactive Menu -----------------------------------------------------
check_9router_health || true

MENU=(
  "Tunnel|named|Named Tunnel + Custom Domain Proxy (ai.wanforge.asia)"
  "Tunnel|quick|Quick Ephemeral Tunnel (trycloudflare.com langsung)"
  "Tunnel|token|Zero Trust Token Service (Systemd Daemon)"
  "Link|update|Update Hermes & Claude endpoint ke Custom Domain"
  "Audit|health|Cek status 9Router lokal & cloudflared"
  "Audit|test|Uji request curl ke endpoint AI Gateway"
)

while true; do
  if menu_select "Pilih aksi integrasi 9Router Cloudflare Tunnel:"; then
    case "${MENU_KEY}" in
      named)  action_named_tunnel ;;
      quick)  action_quick_tunnel ;;
      token)  action_token_service ;;
      update)
        ep="$(ask_cfg "Masukkan URL Proxy Custom Domain" "https://ai.wanforge.asia/v1")"
        update_agent_endpoints "${ep}"
        ;;
      health)
        check_9router_health || true
        check_cloudflared || true
        pause
        ;;
      test)
        action_test_endpoint
        pause
        ;;
      *) break ;;
    esac
  else
    break
  fi
done

ok "Script setup-9router-tunnel selesai."
