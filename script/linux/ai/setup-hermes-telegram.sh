#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2034
#
# setup-hermes-telegram.sh — setup and optimize Hermes Agent with Telegram bot,
# user & group whitelist, require-mention policy, and 9Router / custom domain.
#
# Usage:
#   ./setup-hermes-telegram.sh
#   ./setup-hermes-telegram.sh --token "<TOKEN>" --user "<USER_ID>" --chat "<GROUP_ID>"
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail

TASK="setup-hermes-telegram"
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

if   [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
elif [ -r "${__d}/lib.sh" ]; then . "${__d}/lib.sh"
elif [ -n "${WF_INSTALL_DIR:-}" ] && [ -r "${WF_INSTALL_DIR}/lib.sh" ]; then . "${WF_INSTALL_DIR}/lib.sh"
elif [ -r "/opt/wanforge-scripts/lib.sh" ]; then . "/opt/wanforge-scripts/lib.sh"
elif [ -r "${HOME:-}/.local/lib/wanforge-scripts/lib.sh" ]; then . "${HOME}/.local/lib/wanforge-scripts/lib.sh"
elif command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}")
else . <(wget -qO- "${__LIB}"); fi

banner "Hermes Telegram & Optimization Setup"

HERMES_DIR="${HERMES_HOME:-${HOME}/.hermes}"
CONFIG_FILE="${HERMES_DIR}/config.yaml"
ENV_FILE="${HERMES_DIR}/.env"

mkdir -p "${HERMES_DIR}"
touch "${ENV_FILE}"

# Ensure python3 with PyYAML or use fallback json/awk
PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python3"
elif [ -x "${HERMES_DIR}/hermes-agent/venv/bin/python" ]; then
  PYTHON_BIN="${HERMES_DIR}/hermes-agent/venv/bin/python"
fi

if [ -z "${PYTHON_BIN}" ]; then
  err "Python 3 diperlukan untuk memproses konfigurasi Hermes Agent."
  exit 1
fi

# Ensure pyyaml is available in python environment
if ! "${PYTHON_BIN}" -c "import yaml" >/dev/null 2>&1; then
  sub "Menginstal modul PyYAML..."
  "${PYTHON_BIN}" -m pip install pyyaml >/dev/null 2>&1 || true
fi

# --- CLI flags ------------------------------------------------------------
ARG_TOKEN=""
ARG_USER=""
ARG_CHAT=""
ARG_REQUIRE_MENTION="true"
ARG_API_URL="http://127.0.0.1:20128/v1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token) ARG_TOKEN="$2"; shift 2 ;;
    --user) ARG_USER="$2"; shift 2 ;;
    --chat) ARG_CHAT="$2"; shift 2 ;;
    --no-require-mention) ARG_REQUIRE_MENTION="false"; shift 1 ;;
    --api-url) ARG_API_URL="$2"; shift 2 ;;
    *) shift 1 ;;
  esac
done

# --- Telegram Token -------------------------------------------------------
CURRENT_TOKEN=""
if [ -f "${ENV_FILE}" ]; then
  CURRENT_TOKEN="$(grep -E '^TELEGRAM_BOT_TOKEN=' "${ENV_FILE}" 2>/dev/null | cut -d '=' -f2- | tr -d '"' | tr -d "'" || true)"
fi

TG_TOKEN="${ARG_TOKEN}"
if [ -z "${TG_TOKEN}" ]; then
  if [ -n "${CURRENT_TOKEN}" ]; then
    masked_tok="${CURRENT_TOKEN:0:8}...${CURRENT_TOKEN: -5}"
    info "Token saat ini terpasang: ${masked_tok}"
    if ask_yn "Gunakan token Telegram yang tersimpan?" "y"; then
      TG_TOKEN="${CURRENT_TOKEN}"
    else
      TG_TOKEN="$(ask_secret "Masukkan Token Bot Telegram baru dari @BotFather")"
    fi
  else
    TG_TOKEN="$(ask_secret "Masukkan Token Bot Telegram dari @BotFather")"
  fi
fi

if [ -z "${TG_TOKEN}" ]; then
  err "Token Bot Telegram tidak boleh kosong."
  exit 1
fi

# Simpan token ke .env
if grep -q '^TELEGRAM_BOT_TOKEN=' "${ENV_FILE}" 2>/dev/null; then
  sed -i "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=\"${TG_TOKEN}\"|" "${ENV_FILE}"
else
  echo "TELEGRAM_BOT_TOKEN=\"${TG_TOKEN}\"" >> "${ENV_FILE}"
fi
chmod 600 "${ENV_FILE}"
ok "Token tersimpan di ${ENV_FILE} (chmod 600)"

# --- Allowed Users (allow_from) -------------------------------------------
TG_USERS="${ARG_USER}"
if [ -z "${TG_USERS}" ]; then
  printf "\n" >&2
  info "Daftar User ID / Username Telegram yang diizinkan mengakses agent (DM & Admin)."
  info "Pisahkan dengan koma jika lebih dari satu. Contoh: 310068528, @username"
  TG_USERS="$(ask "Telegram Allowed Users (ID atau @username)" "${USER_TG_ID:-310068528}")"
fi

# --- Allowed Group Chats (allowed_chats) -----------------------------------
TG_CHATS="${ARG_CHAT}"
if [ -z "${TG_CHATS}" ]; then
  printf "\n" >&2
  info "Daftar Chat ID Group Telegram yang diizinkan (format grup umumnya berawalan -100)."
  info "Kosongkan jika hanya ingin mengizinkan pesan DM / Private."
  TG_CHATS="$(ask "Telegram Allowed Groups (contoh: -100123456789 atau kosong)" "")"
fi

# --- Group Policies -------------------------------------------------------
REQ_MENTION="${ARG_REQUIRE_MENTION}"
if [ -z "${ARG_USER}" ] && [ -n "${TG_CHATS}" ]; then
  printf "\n" >&2
  if ask_yn "Wajibkan mention (@botname atau reply) di dalam Group agar bot tidak spam?" "y"; then
    REQ_MENTION="true"
  else
    REQ_MENTION="false"
  fi
fi

# --- AI Backend URL (9Router / Cloudflare Proxy) --------------------------
BACKEND_URL="${ARG_API_URL}"
if [ -z "${ARG_USER}" ]; then
  printf "\n" >&2
  info "URL AI Gateway untuk Hermes Agent."
  info "Pilihan: Lokal 9Router (http://127.0.0.1:20128/v1) atau Cloudflare Tunnel domain (https://ai.domain.com/v1)"
  BACKEND_URL="$(ask "AI Gateway Base URL" "http://127.0.0.1:20128/v1")"
fi

# --- Update config.yaml with Python safely --------------------------------
sub "Memperbarui konfigurasi Hermes di ${CONFIG_FILE}..."

"${PYTHON_BIN}" - <<EOF
import os
import yaml

config_path = "${CONFIG_FILE}"
data = {}
if os.path.exists(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
    except Exception as e:
        print(f"Warning: could not parse existing config: {e}")
        data = {}

# Ensure platforms structure
if "platforms" not in data or not isinstance(data["platforms"], dict):
    data["platforms"] = {}

# Parse users list
users_raw = "${TG_USERS}".split(",")
allowed_users = [u.strip() for u in users_raw if u.strip()]

# Parse chats list
chats_raw = "${TG_CHATS}".split(",")
allowed_chats = [c.strip() for c in chats_raw if c.strip()]

req_mention = "${REQ_MENTION}".lower() in ("true", "1", "yes")
backend_url = "${BACKEND_URL}".strip()

telegram_cfg = data["platforms"].get("telegram", {})
if not isinstance(telegram_cfg, dict):
    telegram_cfg = {}

telegram_cfg["enabled"] = True
telegram_cfg["allow_from"] = allowed_users
if allowed_chats:
    telegram_cfg["allowed_chats"] = allowed_chats
    telegram_cfg["group_allowed_chats"] = allowed_chats
    telegram_cfg["group_allow_from"] = allowed_users
    telegram_cfg["require_mention"] = req_mention
    telegram_cfg["observe_unmentioned_group_messages"] = False
else:
    # Clear group gates if empty
    telegram_cfg.pop("allowed_chats", None)
    telegram_cfg.pop("group_allowed_chats", None)
    telegram_cfg["require_mention"] = True

data["platforms"]["telegram"] = telegram_cfg

# Ensure toolsets for telegram include essentials
if "toolsets" not in data or not isinstance(data["toolsets"], dict):
    data["toolsets"] = {}

core_tools = [
    "browser", "clarify", "code_execution", "context_engine", "cronjob",
    "delegation", "file", "memory", "session_search", "skills",
    "terminal", "todo", "tts", "vision", "web"
]
tg_tools = data["toolsets"].get("telegram", [])
if not isinstance(tg_tools, list) or len(tg_tools) == 0:
    data["toolsets"]["telegram"] = core_tools
else:
    for t in core_tools:
        if t not in tg_tools:
            tg_tools.append(t)
    data["toolsets"]["telegram"] = tg_tools

# Configure Custom Provider (9Router)
if "custom_providers" not in data or not isinstance(data["custom_providers"], list):
    data["custom_providers"] = []

# Check if 9router already defined
found_router = False
for cp in data["custom_providers"]:
    if isinstance(cp, dict) and ("9router" in cp.get("name", "").lower() or cp.get("base_url") == backend_url):
        cp["base_url"] = backend_url
        cp["model"] = cp.get("model", "hermes")
        found_router = True
        break

if not found_router:
    data["custom_providers"].append({
        "name": "9Router",
        "base_url": backend_url,
        "key_env": "NINEROUTER_API_KEY",
        "model": "hermes"
    })

# Optimize compression and security
if "compression" not in data or not isinstance(data["compression"], dict):
    data["compression"] = {}
data["compression"]["enabled"] = True
data["compression"]["threshold"] = 0.50
data["compression"]["target_ratio"] = 0.20

if "security" not in data or not isinstance(data["security"], dict):
    data["security"] = {}
data["security"]["redact_secrets"] = True

with open(config_path, "w", encoding="utf-8") as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

print("Config saved successfully.")
EOF

ok "Hermes YAML configuration updated successfully."

# --- Systemd Service Configuration ----------------------------------------
SERVICE_DIR="${HOME}/.config/systemd/user"
mkdir -p "${SERVICE_DIR}"
SERVICE_NAME="hermes-gateway"
SERVICE_FILE="${SERVICE_DIR}/${SERVICE_NAME}.service"

HERMES_PYTHON="${HERMES_DIR}/hermes-agent/venv/bin/python"
if [ ! -x "${HERMES_PYTHON}" ]; then
  HERMES_PYTHON="$(which python3)"
fi

sub "Configuring systemd user unit ${SERVICE_FILE}..."
cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Hermes Agent Gateway - Telegram Bot Integration
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${HERMES_PYTHON} -m hermes_cli.main gateway run
WorkingDirectory=${HERMES_DIR}
Environment="PATH=${HERMES_DIR}/hermes-agent/venv/bin:${HOME}/.local/share/lerd/bin:${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin"
Environment="VIRTUAL_ENV=${HERMES_DIR}/hermes-agent/venv"
Environment="HERMES_HOME=${HERMES_DIR}"
Environment="HERMES_SUPERVISED_CHILD=1"
Restart=always
RestartSec=5
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

# Enable linger for current user so daemon runs without active SSH
if command -v loginctl >/dev/null 2>&1; then
  loginctl enable-linger "${USER}" 2>/dev/null || true
fi

# Reload systemd user daemon
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable "${SERVICE_NAME}.service" 2>/dev/null || true

  info "To apply new configuration to daemon service:"
  info "  Run from external shell: systemctl --user restart ${SERVICE_NAME}"
fi

# --- Summary --------------------------------------------------------------
printf "\n%b── Hermes Telegram Configuration Summary ──%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
printf "  • Config File   : %s\n" "${CONFIG_FILE}"
printf "  • Secret File   : %s\n" "${ENV_FILE}"
printf "  • Allowed Users : %s\n" "${TG_USERS}"
printf "  • Allowed Groups: %s\n" "${TG_CHATS:-[DM Only]}"
printf "  • Require Mention: %s\n" "${REQ_MENTION}"
printf "  • AI Gateway    : %s\n" "${BACKEND_URL}"
printf "  • Service       : systemctl --user status hermes-gateway\n\n"
ok "Hermes Telegram setup completed."
