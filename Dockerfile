# Hosted demo (Hugging Face Spaces or Render): the Python proxy serves the portal and forwards /api/* to Boomi;
# Node runs the SNAP partner client. Platforms that set PORT themselves (Render) override the 7860 default (Spaces).
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends nodejs && rm -rf /var/lib/apt/lists/*
RUN useradd -m -u 1000 user
WORKDIR /app
COPY --chown=user frontend ./frontend
COPY --chown=user proxy/server.py ./proxy/server.py
COPY --chown=user tools/snap_client.js ./tools/snap_client.js
ENV HOST=0.0.0.0 PORT=7860 TRUST_PROXY=1 SNAP_KEY_DIR=/etc/secrets PYTHONUNBUFFERED=1
USER user
EXPOSE 7860
CMD ["python3", "-I", "proxy/server.py"]
