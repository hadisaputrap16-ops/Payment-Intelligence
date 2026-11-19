# Hosted demo: the Python proxy serves the portal and forwards /api/* to Boomi; Node runs the SNAP partner client.
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends nodejs && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY frontend ./frontend
COPY proxy/server.py ./proxy/server.py
COPY tools/snap_client.js ./tools/snap_client.js
ENV HOST=0.0.0.0 TRUST_PROXY=1 SNAP_KEY_DIR=/etc/secrets PYTHONUNBUFFERED=1
RUN useradd -r app
USER app
CMD ["python3", "-I", "proxy/server.py"]
