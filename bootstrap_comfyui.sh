#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# ComfyUI + ComfyUI-Manager + aria2 Bootstrap Script (Ubuntu 24.04)
# Designed for nova-cloud.ai and similar GPU cloud providers.
# ==============================================================================

PORT="${PORT:-8188}"
TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu128}"
ENABLE_CLOUDFLARE_TUNNEL="${ENABLE_CLOUDFLARE_TUNNEL:-1}" # Set to 0 to disable Cloudflare Quick Tunnel
ENABLE_SYSTEMD="${ENABLE_SYSTEMD:-1}"                     # Set to 1 to auto-start on boot (when systemd is available)

# Use /workspace if available and writable, otherwise $HOME (e.g., /home/ubuntu)
if [ -d "/workspace" ] && [ -w "/workspace" ]; then
  BASE_DIR="${BASE_DIR:-/workspace}"
else
  BASE_DIR="${BASE_DIR:-$HOME}"
fi
export COMFY_DIR="$BASE_DIR/ComfyUI"

# Handle root vs non-root user
SUDO=""
if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
  SUDO="sudo"
fi
RUN_USER="$(whoami)"

echo "==> [1/7] Installing system packages (git, aria2, ffmpeg)..."
export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -y
$SUDO apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  wget \
  git \
  aria2 \
  ffmpeg \
  libgl1 \
  libglib2.0-0

echo "==> [2/7] Installing uv (fast Python & venv manager)..."
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

echo "==> [3/7] Cloning ComfyUI into $COMFY_DIR (shallow clone)..."
if [ ! -d "$COMFY_DIR/.git" ]; then
  git clone --depth 1 --single-branch https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
else
  echo "    ComfyUI already exists, pulling latest..."
  git -C "$COMFY_DIR" pull --ff-only || true
fi

echo "==> [4/7] Creating venv and installing PyTorch + ComfyUI dependencies..."
if [ ! -d "$COMFY_DIR/.venv" ]; then
  # --seed installs pip inside the venv so ComfyUI-Manager can install node deps
  uv venv --seed --python 3.12 "$COMFY_DIR/.venv"
fi

# shellcheck disable=SC1091
source "$COMFY_DIR/.venv/bin/activate"

uv pip install --python "$COMFY_DIR/.venv/bin/python" --upgrade \
  torch torchvision torchaudio --index-url "$TORCH_INDEX_URL"
uv pip install --python "$COMFY_DIR/.venv/bin/python" -r "$COMFY_DIR/requirements.txt"

echo "==> [5/7] Installing & configuring ComfyUI-Manager (shallow clone)..."
MANAGER_DIR="$COMFY_DIR/custom_nodes/ComfyUI-Manager"
mkdir -p "$COMFY_DIR/custom_nodes"
if [ ! -d "$MANAGER_DIR/.git" ]; then
  git clone --depth 1 --single-branch https://github.com/Comfy-Org/ComfyUI-Manager.git "$MANAGER_DIR"
else
  git -C "$MANAGER_DIR" pull --ff-only || true
fi

if [ -f "$MANAGER_DIR/requirements.txt" ]; then
  uv pip install --python "$COMFY_DIR/.venv/bin/python" -r "$MANAGER_DIR/requirements.txt"
fi

# Set network_mode = personal_cloud in $COMFY_DIR/user/__manager/config.ini
"$COMFY_DIR/.venv/bin/python" - <<'EOF'
import configparser
import os

cfg_path = os.path.join(os.environ["COMFY_DIR"], "user", "__manager", "config.ini")
os.makedirs(os.path.dirname(cfg_path), exist_ok=True)

cp = configparser.ConfigParser()
if os.path.exists(cfg_path):
    cp.read(cfg_path)

if "default" not in cp:
    cp["default"] = {}

cp["default"]["network_mode"] = "personal_cloud"

with open(cfg_path, "w") as f:
    cp.write(f)
EOF

echo "==> [6/7] Installing comfy-url & civitdl helpers + cloudflared..."
$SUDO tee /usr/local/bin/comfy-url >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

for log in "/workspace/ComfyUI/tunnel.log" "$HOME/ComfyUI/tunnel.log" "/home/ubuntu/ComfyUI/tunnel.log"; do
  if [ -f "$log" ]; then
    url=$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$log" | tail -n1 || true)
    if [ -n "$url" ]; then
      echo "$url"
      exit 0
    fi
  fi
done

echo "No Cloudflare tunnel URL found in tunnel.log yet." >&2
exit 1
EOF
$SUDO chmod +x /usr/local/bin/comfy-url

$SUDO tee /usr/local/bin/civitdl >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: civitdl [-d <dir>] <url> [output_filename]

Environment variables:
  CF_API_KEY       CivitAI API key (falls back to CIVITAI_API_KEY if unset)

Options:
  -d, --dir <dir>  Directory to save the downloaded file into
  -h, --help       Show this help message
USAGE
}

DEST_DIR=""
POSITIONAL=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dir)
      [[ $# -lt 2 ]] && { echo "Error: $1 requires a directory argument." >&2; exit 1; }
      DEST_DIR="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    --) shift; POSITIONAL+=("$@"); break ;;
    -*) echo "Error: Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

[[ ${#POSITIONAL[@]} -lt 1 ]] && { usage >&2; exit 1; }

URL="${POSITIONAL[0]}"
OUT="${POSITIONAL[1]:-}"
TOKEN="${CF_API_KEY:-${CIVITAI_API_KEY:-}}"
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

if [[ -n "$TOKEN" ]]; then
  [[ "$URL" == *"?"* ]] && AUTH_URL="${URL}&token=${TOKEN}" || AUTH_URL="${URL}?token=${TOKEN}"
else
  echo "Warning: CF_API_KEY is not set; proceeding without auth token..." >&2
  AUTH_URL="$URL"
fi

echo "Resolving link with curl..."
FINAL_URL=$(curl -s -L -I -w '%{url_effective}' -o /dev/null --user-agent "$USER_AGENT" "$AUTH_URL" || true)
if [[ -z "$FINAL_URL" || "$FINAL_URL" == "$AUTH_URL" ]]; then
  FINAL_URL=$(curl -s -L -r 0-1 -w '%{url_effective}' -o /dev/null --user-agent "$USER_AGENT" "$AUTH_URL" || true)
fi
[[ -z "$FINAL_URL" ]] && { echo "Error: Failed to resolve download URL." >&2; exit 1; }

echo "Link resolved. Handing off to aria2c..."
ARIA_OPTS=(
  -c -x16 -s16 -k1M -j1
  --file-allocation=none
  --summary-interval=0
  --content-disposition=true
  --user-agent="$USER_AGENT"
  --header="Accept: */*"
  --header="Referer: https://civitai.com/"
)
[[ -n "$DEST_DIR" ]] && { mkdir -p "$DEST_DIR"; ARIA_OPTS+=(-d "$DEST_DIR"); }
[[ -n "$OUT" ]] && ARIA_OPTS+=(-o "$OUT")

aria2c "${ARIA_OPTS[@]}" "$FINAL_URL"
EOF
$SUDO chmod +x /usr/local/bin/civitdl

if [ "$ENABLE_CLOUDFLARE_TUNNEL" = "1" ] && ! command -v cloudflared >/dev/null 2>&1; then
  echo "    Installing cloudflared..."
  curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -o /tmp/cloudflared
  chmod +x /tmp/cloudflared
  $SUDO mv /tmp/cloudflared /usr/local/bin/cloudflared
fi

echo "==> [7/7] Configuring firewall & starting ComfyUI on 0.0.0.0:${PORT}..."
if command -v ufw >/dev/null 2>&1; then
  if $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
    $SUDO ufw allow "${PORT}/tcp"
    echo "    Opened port ${PORT}/tcp in UFW."
  fi
fi

# Stop any previously running manual processes
pkill -f "main.py.*--port ${PORT}" || true
pkill -f "cloudflared tunnel" || true

USE_SYSTEMD=0
if [ "$ENABLE_SYSTEMD" = "1" ] && [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
  USE_SYSTEMD=1
fi

if [ "$USE_SYSTEMD" = "1" ]; then
  echo "    Setting up systemd services for auto-start on boot..."
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

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now comfyui

  if [ "$ENABLE_CLOUDFLARE_TUNNEL" = "1" ]; then
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
    $SUDO systemctl daemon-reload
    $SUDO systemctl enable --now comfyui-tunnel
    sleep 5
    TUNNEL_URL=$(comfy-url 2>/dev/null || true)
  fi
else
  echo "    Starting via nohup (systemd not active or disabled)..."
  cd "$COMFY_DIR"
  nohup "$COMFY_DIR/.venv/bin/python" main.py --listen 0.0.0.0 --port "$PORT" \
    > "$COMFY_DIR/comfyui.log" 2>&1 &

  if [ "$ENABLE_CLOUDFLARE_TUNNEL" = "1" ]; then
    nohup cloudflared tunnel --url "http://127.0.0.1:${PORT}" \
      > "$COMFY_DIR/tunnel.log" 2>&1 &
    sleep 5
    TUNNEL_URL=$(comfy-url 2>/dev/null || true)
  fi
fi

sleep 2
PUBLIC_IP=$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || echo "<YOUR_INSTANCE_IP>")

echo ""
echo "=================================================================="
echo " ComfyUI + ComfyUI-Manager is running!"
echo " Config: $COMFY_DIR/user/__manager/config.ini (network_mode=personal_cloud)"
echo " Logs:   $COMFY_DIR/comfyui.log"
if [ "$USE_SYSTEMD" = "1" ]; then
  echo " Mode:   systemd (auto-starts on reboot)"
fi
echo "=================================================================="
echo " Access options:"
echo "  1. Direct (if port $PORT is open in your cloud provider dashboard):"
echo "     http://${PUBLIC_IP}:${PORT}"
echo ""
echo "  2. SSH Tunnel (most secure - run on your local machine):"
echo "     ssh -N -L ${PORT}:127.0.0.1:${PORT} ${RUN_USER}@${PUBLIC_IP}"
echo "     Then open: http://localhost:${PORT}"
if [ -n "${TUNNEL_URL:-}" ]; then
  echo ""
  echo "  3. Cloudflare Quick Tunnel:"
  echo "     ${TUNNEL_URL}"
  echo "     (Run 'comfy-url' anytime to retrieve the current tunnel URL)"
fi
echo "=================================================================="
