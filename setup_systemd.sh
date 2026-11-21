#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Standalone script to register ComfyUI + Cloudflare Tunnel as systemd services
# on an already-provisioned Ubuntu 24.04 instance.
# ==============================================================================

PORT="${PORT:-8188}"
ENABLE_CLOUDFLARE_TUNNEL="${ENABLE_CLOUDFLARE_TUNNEL:-1}"

if [ -d "/workspace/ComfyUI" ]; then
  COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
else
  COMFY_DIR="${COMFY_DIR:-$HOME/ComfyUI}"
fi

RUN_USER="$(whoami)"
SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi

if [ ! -x "$COMFY_DIR/.venv/bin/python" ]; then
  echo "Error: ComfyUI venv not found at $COMFY_DIR/.venv/bin/python" >&2
  exit 1
fi

echo "==> Creating comfyui.service..."
$SUDO tee /etc/systemd/system/comfyui.service >/dev/null <<EOF
[Unit]
Description=ComfyUI Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
WorkingDirectory=${COMFY_DIR}
ExecStart=${COMFY_DIR}/.venv/bin/python main.py --listen 0.0.0.0 --port ${PORT}
Restart=always
RestartSec=5
StandardOutput=append:${COMFY_DIR}/comfyui.log
StandardError=append:${COMFY_DIR}/comfyui.log

[Install]
WantedBy=multi-user.target
EOF

pkill -f "main.py.*--port ${PORT}" || true
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now comfyui

if [ "$ENABLE_CLOUDFLARE_TUNNEL" = "1" ]; then
  if ! command -v cloudflared >/dev/null 2>&1; then
    echo "==> Installing cloudflared..."
    curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
      -o /tmp/cloudflared
    chmod +x /tmp/cloudflared
    $SUDO mv /tmp/cloudflared /usr/local/bin/cloudflared
  fi

  echo "==> Creating comfyui-tunnel.service..."
  $SUDO tee /etc/systemd/system/comfyui-tunnel.service >/dev/null <<EOF
[Unit]
Description=Cloudflare Quick Tunnel for ComfyUI
After=comfyui.service network-online.target
Requires=comfyui.service

[Service]
Type=simple
User=${RUN_USER}
ExecStart=/usr/local/bin/cloudflared tunnel --url http://127.0.0.1:${PORT}
Restart=always
RestartSec=5
StandardOutput=append:${COMFY_DIR}/tunnel.log
StandardError=append:${COMFY_DIR}/tunnel.log

[Install]
WantedBy=multi-user.target
EOF

  pkill -f "cloudflared tunnel" || true
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now comfyui-tunnel
  sleep 4
  echo "==> Tunnel URL:"
  grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$COMFY_DIR/tunnel.log" | tail -n1 || true
fi

echo "==> Done. Services enabled for auto-start on boot."
