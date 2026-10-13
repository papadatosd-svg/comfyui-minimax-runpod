# MiniMax H3 RunPod — build prototype

Builds on public `runpod/comfyui:cuda13.0`. Downloads only 4 model files **at Pod runtime** (not in the Docker image). ComfyUI starts in parallel via `/start.sh`.

## Before RunPod
1. Create a public GitHub repository and upload Dockerfile + two `.sh` files.
2. Use GitHub Actions or another public-image builder to publish to GHCR; this zip is **not already a published image**.
3. Verify image build and pulls successfully without credentials before any GPU test.
4. A successful Docker build alone **does not prove MiniMax works**: the official base may lack the creator's custom nodes or workflow. Validate installed nodes with the actual workflow before generation.

## Caveats
- 4 files reflect the non-Turbo ComfyUI workflow screenshot. Turbo LoRA is intentionally excluded.
- Files are downloaded to `/workspace/runpod-slim/ComfyUI/models` and use roughly 40 GB+ of temporary storage.
- Pod disk may be wiped upon Stop. Verify persistence separately.
- Logs: `/var/log/minimax-h3-models.log`.
- This is an **untested build prototype**; no external Docker build or GPU test was performed.
- The original author's image is not included or copied. Read license terms of the model prior to use.
