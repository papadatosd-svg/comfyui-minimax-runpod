#!/bin/bash
BASE_DIR="/workspace/runpod-slim/ComfyUI/models"
LOG="/var/log/minimax-h3-models.log"
READY_MARKER="/workspace/runpod-slim/ComfyUI/main.py"

command -v hf >/dev/null || { echo "hf CLI missing" >&2; exit 1; }
export HF_HUB_ENABLE_HF_TRANSFER=1
export HF_XET_HIGH_PERFORMANCE=1

# Models: subdir|name|url|min_size_bytes (min_size = sanity check)
MODELS=(
    "diffusion_models|minimax_h3_fl2va_pruned_int8_convrot.safetensors|https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors|20000000000"
    "text_encoders|qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors|https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors|15000000000"
    "vae|minimax_h3_video_vae_fp16.safetensors|https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_video_vae_fp16.safetensors|5000000000"
    "vae|minimax_h3_audio_vae_fp32.safetensors|https://huggingface.co/Comfy-Org/MiniMax-H3/resolve/main/vae/minimax_h3_audio_vae_fp32.safetensors|600000000"
)

log() { echo "$(date): $*" | tee -a "$LOG"; }

TOTAL_MODELS=${#MODELS[@]}
CURRENT=0

log "📥 === MiniMax H3 model download started (PID $$) — $TOTAL_MODELS models ==="
log "⏳ Waiting for /workspace mount and ComfyUI ready marker..."
for i in $(seq 1 120); do
    [ -f "$READY_MARKER" ] && break
    sleep 5
done

if [ ! -f "$READY_MARKER" ]; then
    log "❌ ERROR: ComfyUI ready marker not found after 600s, aborting"
    exit 1
fi

log "✅ ComfyUI ready, base dir: $BASE_DIR"
mkdir -p "$BASE_DIR"/{vae,vae_approx,diffusion_models,text_encoders,loras,checkpoints}

# MODEL_VOLUME_PATH: external model storage (network volume at /workspace/storage,
# global volume at /workspace-global, or any mounted path). When set, we symlink
# its subdirs into models/ and write extra_model_paths.yaml — no downloads needed.
# Auto-detect common mount points when the env var is not set.
if [ -z "${MODEL_VOLUME_PATH:-}" ]; then
    for cand in /workspace/storage/models /workspace/models /workspace-global/models /workspace-global /workspace/storage; do
        if [ -d "$cand/diffusion_models" ] || [ -d "$cand/vae" ]; then
            MODEL_VOLUME_PATH="$cand"
            log "🔎 Auto-detected model volume at $MODEL_VOLUME_PATH"
            break
        fi
    done
fi
if [ -n "${MODEL_VOLUME_PATH:-}" ] && [ -d "$MODEL_VOLUME_PATH" ]; then
    log "🔗 MODEL_VOLUME_PATH=$MODEL_VOLUME_PATH — linking models, skipping downloads"
    for d in "$MODEL_VOLUME_PATH"/*/; do
        [ -d "$d" ] || continue
        dest="$BASE_DIR/$(basename "$d")"
        rmdir "$dest" 2>/dev/null
        if [ -e "$dest" ] && [ ! -L "$dest" ]; then
            log "   ⚠️ $dest non-empty dir, not linking"
            continue
        fi
        ln -sfn "$d" "$dest"
        log "   ↪ $(basename "$d") -> $d"
    done
    cat > "$(dirname "$BASE_DIR")/extra_model_paths.yaml" <<YAML
shared_volume:
  base_path: $MODEL_VOLUME_PATH
  diffusion_models: diffusion_models
  text_encoders: text_encoders
  loras: loras
  vae: vae
  vae_approx: vae_approx
  ultralytics: ultralytics
  sams: sams
  LLM: LLM/GGUF
  checkpoints: checkpoints
YAML
    log "🏁 extra_model_paths.yaml written — volume models ready"
    exit 0
fi

monitor_progress() {
    local watch_dir="$1" expected="$2" name="$3"
    local cur pct filled pad bar exp_mb
    exp_mb=$(( expected / 1048576 ))
    while :; do
        cur=$(du -sb "$watch_dir" 2>/dev/null | awk '{print $1}')
        cur=${cur:-0}
        pct=$(( cur * 100 / expected ))
        [ "$pct" -gt 100 ] && pct=100
        filled=$(( pct / 5 ))
        printf -v bar '%*s' "$filled" ''; bar=${bar// /#}
        printf -v pad '%*s' "$((20 - filled))" ''; pad=${pad// /-}
        log "   ⏳ $name [${bar}${pad}] ${pct}% ($((cur / 1048576))/${exp_mb} MB)"
        sleep 20
    done
}

download_model() {
    local subdir="$1" name="$2" url="$3" min_size="$4"
    local dest="$BASE_DIR/$subdir/$name"
    local max_retries=5

    local repo_id repo_path
    repo_id=$(echo "$url" | awk -F/ '{print $4"/"$5}')
    repo_path=$(echo "$url" | sed -E 's#https?://[^/]+/[^/]+/[^/]+/resolve/main/(.+)#\1#')

    local hf_cmd="hf"
    command -v hf >/dev/null 2>&1 || hf_cmd="huggingface-cli"

    for attempt in $(seq 1 $max_retries); do
        if [ -f "$dest" ] || [ -L "$dest" ]; then
            local size
            size=$(stat -L -c%s "$dest" 2>/dev/null || stat -L -f%z "$dest" 2>/dev/null || echo 0)
            if [ "$size" -ge "$min_size" ]; then
                log "✅ $name already present ($size bytes >= $min_size), skipping"
                return 0
            else
                log "⚠️  $name incomplete ($size bytes < $min_size), retrying (attempt $attempt/$max_retries)"
            fi
        else
            log "📥 Downloading $name (attempt $attempt/$max_retries)..."
        fi

        local tmp_dir="$BASE_DIR/.tmp_download_${name//\//_}"
        rm -rf "$tmp_dir"
        mkdir -p "$tmp_dir" "$(dirname "$dest")"
        export HF_HUB_ENABLE_HF_TRANSFER=1
        export HF_XET_HIGH_PERFORMANCE=1
        local resume_flag=""
        [ "$hf_cmd" = "huggingface-cli" ] && resume_flag="--resume-download"

        monitor_progress "$tmp_dir" "$min_size" "$name" &
        local mon_pid=$!

        if timeout 900 $hf_cmd download "$repo_id" "$repo_path" \
                --local-dir "$tmp_dir" \
                $resume_flag 2>&1 | tee -a "$LOG"; then
            kill "$mon_pid" 2>/dev/null; wait "$mon_pid" 2>/dev/null
            local downloaded_path="$tmp_dir/$repo_path"
            if [ -f "$downloaded_path" ] || [ -L "$downloaded_path" ]; then
                if [ -L "$downloaded_path" ]; then
                    ln -sf "$(readlink -f "$downloaded_path")" "$dest"
                else
                    mv -f "$downloaded_path" "$dest"
                fi
                rm -rf "$tmp_dir"
                local size
                size=$(stat -L -c%s "$dest" 2>/dev/null || stat -L -f%z "$dest" 2>/dev/null || echo 0)
                if [ "$size" -ge "$min_size" ]; then
                    log "✅ $name downloaded successfully ($size bytes)"
                    return 0
                else
                    log "⚠️  $name downloaded but size $size < $min_size, will retry"
                fi
            else
                log "⚠️  $name not found at $downloaded_path after download, will retry"
                rm -rf "$tmp_dir"
            fi
        else
            kill "$mon_pid" 2>/dev/null; wait "$mon_pid" 2>/dev/null
            log "⚠️  $hf_cmd failed for $name (attempt $attempt), retrying in $((attempt*10))s..."
            rm -rf "$tmp_dir"
        fi

        [ "$attempt" -lt "$max_retries" ] && sleep $((attempt * 30))
    done

    log "❌ FAILED: $name could not be downloaded after $max_retries attempts"
    return 1
}

failures=0
MODEL_IDX=0
for entry in "${MODELS[@]}"; do
    MODEL_IDX=$((MODEL_IDX + 1))
    IFS='|' read -r subdir name url min_size <<< "$entry"
    log "━━━ [$MODEL_IDX/$TOTAL_MODELS] ━━━"
    download_model "$subdir" "$name" "$url" "$min_size" || failures=$((failures + 1))
    sleep 5
done

log "📦 === MiniMax H3 model download finished ($failures failures) ==="
if [ "$failures" -eq 0 ]; then
    log "✅ Four MiniMax H3 model files downloaded"
else
    log "❌ $failures model downloads failed"
    exit 1
fi
# === RealESRGAN x4plus automatic download ===
UPSCALE_DIR="$BASE_DIR/upscale_models"
UPSCALE_FILE="$UPSCALE_DIR/RealESRGAN_x4plus.pth"
UPSCALE_URL="https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth"

mkdir -p "$UPSCALE_DIR"

if [ -f "$UPSCALE_FILE" ] && [ "$(stat -c%s "$UPSCALE_FILE")" -ge 60000000 ]; then
    log "✅ RealESRGAN_x4plus.pth already installed"
else
    log "📥 Downloading RealESRGAN_x4plus.pth..."
    rm -f "$UPSCALE_FILE.tmp"

    if curl -fL --retry 3 --connect-timeout 30 \
        "$UPSCALE_URL" -o "$UPSCALE_FILE.tmp" \
        && [ "$(stat -c%s "$UPSCALE_FILE.tmp")" -ge 60000000 ]; then
        mv -f "$UPSCALE_FILE.tmp" "$UPSCALE_FILE"
        log "✅ RealESRGAN_x4plus.pth installed successfully"
    else
        rm -f "$UPSCALE_FILE.tmp"
        log "❌ RealESRGAN download failed"
        exit 1
    fi
fi
