# ComfyUI Cloud Bootstrap (Ubuntu 24.04)

Self-contained bootstrap scripts for provisioning **ComfyUI + ComfyUI-Manager + `aria2`** on **nova-cloud.ai** and similar GPU cloud providers running Ubuntu 24.04.

## What It Installs & Configures

- **System tools:** `aria2`, `git`, `curl`, `wget`, `ffmpeg`, `libgl1`, `libglib2.0-0`
- **Python environment:** Installs [`uv`](https://docs.astral.sh/uv/) and creates a seeded Python 3.12 virtual environment (`--seed` includes `pip` for ComfyUI-Manager, while avoiding Ubuntu 24.04's `python3.12-venv` apt version mismatch)
- **ComfyUI + ComfyUI-Manager:** Shallow-cloned (`--depth 1 --single-branch`) for fast downloads on slow links
- **ComfyUI-Manager config:** Automatically sets `network_mode = personal_cloud` in `ComfyUI/user/__manager/config.ini`
- **Access & Auto-start:**
  - Opens port `8188/tcp` in `ufw` (if active)
  - Optional Cloudflare Quick Tunnel (`ENABLE_CLOUDFLARE_TUNNEL=1`)
  - Registers `comfyui.service` and `comfyui-tunnel.service` in `systemd` so both auto-start after stopping/starting the GPU instance (falls back to `nohup` in container environments without `systemd`)
  - Installs `/usr/local/bin/comfy-url` to print the current Cloudflare tunnel URL anytime

## Files

| File | Purpose |
| --- | --- |
| `bootstrap_comfyui.sh` | All-in-one setup script (installs everything, configures `systemd`, and installs `comfy-url`) |
| `comfy-url` | Standalone copy of the helper installed to `/usr/local/bin/comfy-url` |
| `setup_systemd.sh` | Standalone script to add `systemd` auto-start services to an already-provisioned instance |

---

## Deploying to a New Instance

### Option 1: Stream directly from your Mac over SSH (recommended for private repos)

No need to copy files, use `nano`, or put GitHub credentials on the GPU instance:

```bash
ssh ubuntu@<INSTANCE_IP> 'ENABLE_CLOUDFLARE_TUNNEL=1 bash -s' < bootstrap_comfyui.sh
```

### Option 2: Fetch from your private GitHub repo using a Personal Access Token (PAT)

On the GPU instance (or in your provider's startup script field):

```bash
curl -fsSL -H "Authorization: Bearer <YOUR_GITHUB_PAT>" \
  https://raw.githubusercontent.com/<YOUR_USER>/<YOUR_REPO>/main/bootstrap_comfyui.sh \
  | ENABLE_CLOUDFLARE_TUNNEL=1 bash
```

### Option 3: Clone the repo on the instance

```bash
git clone https://github.com/<YOUR_USER>/<YOUR_REPO>.git
cd <YOUR_REPO>
ENABLE_CLOUDFLARE_TUNNEL=1 ./bootstrap_comfyui.sh
```

---

## Configuration (Environment Variables)

| Variable | Default | Description |
| --- | --- | --- |
| `ENABLE_CLOUDFLARE_TUNNEL` | `0` | Set to `1` to install `cloudflared` and start a Cloudflare Quick Tunnel |
| `ENABLE_SYSTEMD` | `1` | Set to `0` to skip `systemd` services and run via `nohup` |
| `PORT` | `8188` | Port ComfyUI listens on |
| `TORCH_INDEX_URL` | `https://download.pytorch.org/whl/cu128` | PyTorch wheel index (e.g. switch to `cu126` for older CUDA drivers) |
| `BASE_DIR` | `/workspace` (if writable) else `$HOME` | Parent directory where `ComfyUI/` is installed |

Example with custom CUDA version:

```bash
ssh ubuntu@<INSTANCE_IP> 'ENABLE_CLOUDFLARE_TUNNEL=1 TORCH_INDEX_URL=https://download.pytorch.org/whl/cu126 bash -s' < bootstrap_comfyui.sh
```

---

## Everyday Usage

### Get the Cloudflare Tunnel URL (after a reboot or anytime)

On the instance:
```bash
comfy-url
```

From your Mac (opens ComfyUI straight in your browser):
```bash
open "$(ssh ubuntu@<INSTANCE_IP> comfy-url)"
```

### Manage `systemd` services

```bash
sudo systemctl status comfyui comfyui-tunnel
sudo systemctl restart comfyui
tail -f ~/ComfyUI/comfyui.log
```

### Fast model downloads with `aria2c`

```bash
aria2c -x 16 -s 16 -k 1M -d ~/ComfyUI/models/checkpoints -o model.safetensors "<MODEL_URL>"
```
