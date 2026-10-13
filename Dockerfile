FROM runpod/comfyui:cuda13.0
USER root
# Install only transfer CLI; do not upgrade CUDA, torch or ComfyUI.
RUN python3 -m pip install --no-cache-dir --break-system-packages 'huggingface_hub[hf_xet]>=0.34,<2' || python3 -m pip install --no-cache-dir 'huggingface_hub[hf_xet]>=0.34,<2'
COPY download-minimax-h3-models.sh /usr/local/bin/download-minimax-h3-models.sh
COPY minimax-entrypoint.sh /usr/local/bin/minimax-entrypoint.sh
RUN chmod +x /usr/local/bin/download-minimax-h3-models.sh /usr/local/bin/minimax-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/minimax-entrypoint.sh"]
CMD []
