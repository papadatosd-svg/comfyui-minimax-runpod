#!/bin/bash
# Start downloading in background; do not block ComfyUI startup.
set -e
mkdir -p /var/log
/usr/local/bin/download-minimax-h3-models.sh >> /var/log/minimax-startup.log 2>&1 &
exec /start.sh
