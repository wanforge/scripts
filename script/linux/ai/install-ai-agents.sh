#!/usr/bin/env bash
# shellcheck disable=SC2086,SC2034
#
# install-ai-agents.sh — comprehensive installer & optimizer for AI Coding & Gateway Stack:
# Hermes Agent, Claude Code, Antigravity (AGY), 9Router, Tmux, and Cloudflare Tunnel.
#
# Usage:
#   ./install-ai-agents.sh               # interactive dashboard
#   ./install-ai-agents.sh --all         # automated full stack installation
#   ./install-ai-agents.sh doctor        # system health & readiness check
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Sugeng Sulistiyawan
#
set -euo pipefail

TASK="install-ai-agents"
__LIB="https://scripts.wanforge.asia/script/linux/lib.sh"
__d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"

if   [ -r "${__d}/../lib.sh" ]; then . "${__d}/../lib.sh"
elif [ -r "${__d}/lib.sh" ]; then . "${__d}/lib.sh"
elif [ -n "${WF_INSTALL_DIR:-}" ] && [ -r "${WF_INSTALL_DIR}/lib.sh" ]; then . "${WF_INSTALL_DIR}/lib.sh"
elif [ -r "/opt/wanforge-scripts/lib.sh" ]; then . "/opt/wanforge-scripts/lib.sh"
elif [ -r "${HOME:-}/.local/lib/wanforge-scripts/lib.sh" ]; then . "${HOME}/.local/lib/wanforge-scripts/lib.sh"
elif command -v curl >/dev/null 2>&1; then . <(curl -fsSL "${__LIB}")
else . <(wget -qO- "${__LIB}"); fi

banner "WanForge AI Agent & LLM Stack"

HERMES_DIR="${HERMES_HOME:-${HOME}/.hermes}"
USER_BIN="${HOME}/.local/bin"
mkdir -p "${USER_BIN}"
export PATH="${USER_BIN}:${HOME}/.local/share/lerd/bin:/usr/local/bin:${PATH}"

# Ensure sudo helper if needed
SUDO=""
[ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1 && SUDO="sudo"

# --- 1. System Base Dependencies & Tmux ------------------------------------
install_base_and_tmux() {
  hd "1. Memasang Dependensi Sistem & Tmux"

  local pkgs=(curl wget git jq tmux python3 python3-pip)
  sub "Memeriksa dan memperbarui paket: ${pkgs[*]}..."
  
  if command -v pkg_install >/dev/null 2>&1; then
    pkg_install "${pkgs[@]}" || true
  elif [ -n "${SUDO}" ] && command -v apt-get >/dev/null 2>&1; then
    ${SUDO} apt-get update -y && ${SUDO} apt-get install -y "${pkgs[@]}" build-essential || true
  elif [ -n "${SUDO}" ] && command -v dnf >/dev/null 2>&1; then
    ${SUDO} dnf install -y "${pkgs[@]}" || true
  fi

  # Optimized ~/.tmux.conf for AI agents
  sub "Mengonfigurasi ~/.tmux.conf teroptimasi untuk coding agent..."
  cat > "${HOME}/.tmux.conf" <<'EOF'
# WanForge AI Agent tmux configuration
set -g mouse on
set -g history-limit 50000
set -s escape-time 10
set -g focus-events on
set -g default-terminal "screen-256color"
set-option -sa terminal-overrides ',xterm-256color:RGB'
set -g status-interval 5
set -g status-style "bg=#1e1e2e,fg=#cdd6f4"
set -g status-left "#[fg=#89b4fa,bold] [Agent tmux] #[default]"
set -g status-right "#[fg=#a6e3a1]%H:%M #[fg=#f9e2af]%d-%b-%y "
setw -g mode-keys vi
EOF
  ok "Tmux terpasang dan ~/.tmux.conf berhasil dikonfigurasi."
}

# --- 2. Node.js & 9Router AI Gateway --------------------------------------
install_9router() {
  hd "2. Setup 9Router AI Gateway (Port 20128)"

  # Ensure Node.js & npm
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    sub "Memasang Node.js LTS..."
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL https://deb.nodesource.com/setup_20.x | ${SUDO:-} bash - || true
      ${SUDO:-} apt-get install -y nodejs || true
    fi
  fi

  if ! command -v 9router >/dev/null 2>&1; then
    sub "Menginstal 9Router via npm..."
    npm install -g 9router || ${SUDO:-} npm install -g 9router || true
  fi

  # Systemd User Service for 9Router
  local svc_dir="${HOME}/.config/systemd/user"
  mkdir -p "${svc_dir}"
  local svc_file="${svc_dir}/9router.service"

  local node_bin; node_bin="$(which node 2>/dev/null || echo "/usr/bin/node")"
  local router_bin; router_bin="$(which 9router 2>/dev/null || echo "${HOME}/.local/bin/9router")"

  sub "Membuat unit systemd user ${svc_file}..."
  cat > "${svc_file}" <<EOF
[Unit]
Description=9Router AI Gateway
After=network.target

[Service]
Type=simple
ExecStart=${router_bin} -p 20128 -H 0.0.0.0 -n -t
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable --now 9router.service 2>/dev/null || true
  fi

  # Setup MITM DNS Aliases for AGY
  local mitm_dir="${HOME}/.9router/mitm"
  mkdir -p "${mitm_dir}"
  sub "Mengonfigurasi model combo & alias di ${mitm_dir}/aliases.json..."
  cat > "${mitm_dir}/aliases.json" <<'EOF'
{
  "antigravity": {
    "gemini-3.7-flash-high": "agy",
    "gemini-3.7-flash-medium": "agy",
    "gemini-3.7-flash-low": "agy",
    "gemini-3.6-flash-high": "agy",
    "gemini-3.6-flash-medium": "agy",
    "gemini-3.6-flash-low": "agy",
    "gemini-3.5-flash-high": "agy",
    "gemini-3.5-flash-medium": "agy",
    "gemini-3.5-flash-low": "agy",
    "gemini-3-flash-agent": "agy",
    "gemini-pro-agent": "agy",
    "claude-sonnet-4-6": "agy",
    "claude-opus-4-6-thinking": "agy",
    "gpt-oss-120b-medium": "agy",
    "gemini-2.5-flash": "agy"
  }
}
EOF

  # Setup standard combos via Node.js script if API client exists
  node - <<'EOF' 2>/dev/null || true
try {
  const http = require('http');
  const req = http.request({
    hostname: '127.0.0.1',
    port: 20128,
    path: '/api/health',
    method: 'GET',
    timeout: 2000
  }, (res) => {
    console.log("9Router active and responding.");
  });
  req.on('error', () => {});
  req.end();
} catch (e) {}
EOF

  ok "9Router berhasil dikonfigurasi pada port 20128."
}

# --- 3. Claude Code CLI Setup ----------------------------------------------
install_claude_code() {
  hd "3. Setup Claude Code CLI (@anthropic-ai/claude-code)"

  if ! command -v claude >/dev/null 2>&1; then
    sub "Menginstal Claude Code CLI secara global via npm..."
    npm install -g @anthropic-ai/claude-code || ${SUDO:-} npm install -g @anthropic-ai/claude-code
  else
    ok "Claude Code CLI sudah terpasang: $(claude --version 2>/dev/null || echo 'installed')"
  fi

  local claude_dir="${HOME}/.claude"
  mkdir -p "${claude_dir}"
  local settings_file="${claude_dir}/settings.json"

  sub "Mengonfigurasi ${settings_file} untuk terhubung ke 9Router..."
  if command -v jq >/dev/null 2>&1 && [ -f "${settings_file}" ]; then
    local tmp_json; tmp_json="$(mktemp)"
    jq '
      .env.ANTHROPIC_BASE_URL = "http://127.0.0.1:20128/v1" |
      .env._CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL = "1" |
      .env.ENABLE_TOOL_SEARCH = "auto" |
      .env.CLAUDE_CODE_MAX_CONTEXT_TOKENS = "998000" |
      .model = "claude"
    ' "${settings_file}" > "${tmp_json}" && mv -f "${tmp_json}" "${settings_file}"
  else
    cat > "${settings_file}" <<'EOF'
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:20128/v1",
    "_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL": "1",
    "ENABLE_TOOL_SEARCH": "auto",
    "CLAUDE_CODE_MAX_CONTEXT_TOKENS": "998000"
  },
  "permissions": {
    "allow": [
      "Bash(git *)",
      "Bash(bun *)",
      "Bash(pnpm *)",
      "Bash(npm *)",
      "Bash(node *)",
      "Bash(python3 *)",
      "Bash(systemctl *)",
      "Read",
      "Edit",
      "Write"
    ]
  },
  "model": "claude"
}
EOF
  fi
  ok "Claude Code settings.json siap (Base URL: http://127.0.0.1:20128/v1)."
}

# --- 4. Antigravity Agent (AGY) Setup --------------------------------------
install_antigravity() {
  hd "4. Setup Antigravity Agent CLI (AGY)"

  if command -v agy >/dev/null 2>&1; then
    ok "Biner 'agy' ditemukan: $(which agy)"
  else
    info "Memeriksa biner agy di direktori lokal..."
    if [ -x "${HOME}/.local/bin/agy" ]; then
      ok "Biner agy aktif di ${HOME}/.local/bin/agy"
    else
      warn "Biner agy belum terpasang di PATH."
      info "Untuk menginstal Antigravity CLI resmi Google:"
      info "  Letakkan biner agy pada ${HOME}/.local/bin/agy dan jalankan chmod +x."
    fi
  fi

  local gemini_dir="${HOME}/.gemini"
  local hooks_dir="${gemini_dir}/hooks"
  mkdir -p "${hooks_dir}"

  sub "Mengonfigurasi setting dan hook Antigravity di ${gemini_dir}/settings.json..."
  cat > "${gemini_dir}/settings.json" <<'EOF'
{
  "hooks": {
    "BeforeTool": [
      {
        "matcher": "run_shell_command",
        "hooks": [
          {
            "type": "command",
            "command": "rtk hook gemini"
          }
        ]
      }
    ]
  }
}
EOF
  ok "Konfigurasi Antigravity AGY tersimpan."
}

# --- 5. Hermes Agent Setup ------------------------------------------------
install_hermes_agent() {
  hd "5. Setup Hermes Agent Framework"

  if command -v hermes >/dev/null 2>&1; then
    ok "Hermes Agent CLI sudah terpasang: $(which hermes)"
  else
    sub "Mengunduh dan menjalankan installer resmi Hermes Agent..."
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash || true
    fi
  fi

  # Configure Hermes Gateway systemd service
  local svc_dir="${HOME}/.config/systemd/user"
  mkdir -p "${svc_dir}"
  local srv_name="hermes-gateway"
  local svc_file="${svc_dir}/${srv_name}.service"

  local hermes_py="${HERMES_DIR}/hermes-agent/venv/bin/python"
  [ ! -x "${hermes_py}" ] && hermes_py="$(which python3 2>/dev/null || echo "/usr/bin/python3")"

  sub "Membuat unit systemd user ${svc_file}..."
  cat > "${svc_file}" <<EOF
[Unit]
Description=Hermes Agent Gateway - Messaging Platform Integration
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=${hermes_py} -m hermes_cli.main gateway run
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

  if command -v loginctl >/dev/null 2>&1; then
    loginctl enable-linger "${USER}" 2>/dev/null || true
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user enable "${srv_name}.service" 2>/dev/null || true
  fi

  ok "Hermes Agent & Gateway Service terpasang."
}

# --- 6. Optimization Stack (RTK & Caveman) --------------------------------
install_optimization_stack() {
  hd "6. Memasang Perkakas Optimasi Token & Prompt (Caveman & RTK)"

  if ! command -v caveman >/dev/null 2>&1; then
    sub "Menginstal Caveman CLI..."
    npm install -g @caveman-ai/cli 2>/dev/null || ${SUDO:-} npm install -g @caveman-ai/cli 2>/dev/null || true
  fi
  if command -v caveman >/dev/null 2>&1; then
    ok "Caveman CLI terpasang: $(which caveman)"
  fi

  if command -v rtk >/dev/null 2>&1; then
    ok "RTK (Rust Token Killer) aktif: $(rtk gain 2>/dev/null || echo 'ready')"
  else
    info "RTK dapat diinstal via cargo / brew / rtk release untuk penghematan output terminal."
  fi
}

# --- 7. Doctor & Diagnostics ----------------------------------------------
run_doctor() {
  hd "Audit Kesiapan Sistem AI Agent & LLM Stack"

  printf "\n%b[1] Tmux & Terminal Status:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  if command -v tmux >/dev/null 2>&1; then
    ok "Tmux: $(tmux -V) (${HOME}/.tmux.conf exists: $([ -f "${HOME}/.tmux.conf" ] && echo 'Ya' || echo 'Tidak'))"
  else
    warn "Tmux belum terpasang."
  fi

  printf "\n%b[2] 9Router AI Gateway:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  if command -v 9router >/dev/null 2>&1 || [ -x "${HOME}/.local/share/lerd/bin/9router" ]; then
    ok "9Router biner: OK"
  else
    warn "9Router biner tidak ditemukan."
  fi
  if curl -s --max-time 2 "http://127.0.0.1:20128/api/health" | grep -q "ok" 2>/dev/null; then
    ok "9Router Service HTTP: Sehat (http://127.0.0.1:20128/api/health)"
  else
    warn "9Router Service tidak merespons di port 20128."
  fi

  printf "\n%b[3] Claude Code CLI:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  if command -v claude >/dev/null 2>&1; then
    ok "Claude Code: $(claude --version 2>/dev/null || echo 'installed')"
    if [ -f "${HOME}/.claude/settings.json" ]; then
      local base_url; base_url="$(grep -oE 'http[^"]+' "${HOME}/.claude/settings.json" | head -n1 || echo 'default')"
      info "Claude Base URL: ${base_url}"
    fi
  else
    warn "Claude Code CLI belum terpasang."
  fi

  printf "\n%b[4] Antigravity (AGY):%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  if command -v agy >/dev/null 2>&1 || [ -x "${HOME}/.local/bin/agy" ]; then
    ok "Antigravity AGY: Tersedia"
  else
    warn "Antigravity AGY biner belum ditemukan di PATH."
  fi

  printf "\n%b[5] Hermes Agent & Telegram Gateway:%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  if command -v hermes >/dev/null 2>&1; then
    ok "Hermes Agent CLI: $(which hermes)"
  else
    warn "Hermes Agent CLI belum ada di PATH."
  fi
  if [ -f "${HERMES_DIR}/.env" ] && grep -q '^TELEGRAM_BOT_TOKEN=' "${HERMES_DIR}/.env"; then
    ok "Telegram Bot Token: Terpasang di ${HERMES_DIR}/.env"
  else
    warn "Telegram Bot Token belum dikonfigurasi."
  fi
  if [ -f "${HERMES_DIR}/config.yaml" ]; then
    ok "Hermes config.yaml: Ditemukan"
  fi
  if systemctl --user is-active --quiet hermes-gateway.service 2>/dev/null; then
    ok "hermes-gateway.service: Aktif & Running"
  else
    info "hermes-gateway.service: $(systemctl --user is-active hermes-gateway.service 2>/dev/null || echo 'inactive')"
  fi

  printf "\n%b[6] Cloudflare Tunnel (cloudflared):%b\n" "${C_BOLD}${C_CYAN}" "${C_RESET}"
  if command -v cloudflared >/dev/null 2>&1; then
    ok "cloudflared: $(cloudflared --version | head -n1)"
  else
    warn "cloudflared belum terpasang."
  fi
  printf "\n"
}

# --- CLI Dispatch ---------------------------------------------------------
case "${1:-}" in
  --all)
    install_base_and_tmux
    install_9router
    install_claude_code
    install_antigravity
    install_hermes_agent
    install_optimization_stack
    run_doctor
    exit 0
    ;;
  doctor|audit)
    run_doctor
    exit 0
    ;;
  tmux)
    install_base_and_tmux
    exit 0
    ;;
  9router)
    install_9router
    exit 0
    ;;
  claude)
    install_claude_code
    exit 0
    ;;
  antigravity|agy)
    install_antigravity
    exit 0
    ;;
  hermes)
    install_hermes_agent
    exit 0
    ;;
esac

# --- Interactive Main Menu ------------------------------------------------
MENU=(
  "Full|all|Pasang Seluruh Stack AI Otomatis (Hermes + Claude + AGY + 9Router + Tmux)"
  "Install|tmux|Pasang & Tuning Tmux untuk Agent Orchestration"
  "Install|9router|Pasang 9Router AI Gateway & Systemd Service (Port 20128)"
  "Install|claude|Pasang Claude Code CLI & Pengaturan 9Router Backend"
  "Install|agy|Pasang Antigravity CLI (AGY) & Hook Konfigurasi"
  "Install|hermes|Pasang Hermes Agent Framework & Gateway Service"
  "Integrate|telegram|Konfigurasi Bot Telegram Hermes (Whitelist User, Grup, Mention)"
  "Integrate|tunnel|Integrasi 9Router Cloudflare Tunnel & Proxy Custom Domain"
  "Optimize|tools|Pasang Caveman & Tools Optimasi Token"
  "Audit|doctor|Jalankan Audit & Health Check Kesiapan Seluruh AI Agent"
)

while true; do
  if menu_select "Pilih komponen AI Agent Stack yang ingin dikonfigurasi:"; then
    case "${MENU_KEY}" in
      all)
        install_base_and_tmux
        install_9router
        install_claude_code
        install_antigravity
        install_hermes_agent
        install_optimization_stack
        run_doctor
        pause
        ;;
      tmux)     install_base_and_tmux; pause ;;
      9router)  install_9router; pause ;;
      claude)   install_claude_code; pause ;;
      agy)      install_antigravity; pause ;;
      hermes)   install_hermes_agent; pause ;;
      telegram)
        bash "${__d}/setup-hermes-telegram.sh" || true
        pause
        ;;
      tunnel)
        bash "${__d}/setup-9router-tunnel.sh" || true
        pause
        ;;
      tools)    install_optimization_stack; pause ;;
      doctor)   run_doctor; pause ;;
      *) break ;;
    esac
  else
    break
  fi
done

ok "Script install-ai-agents selesai."
