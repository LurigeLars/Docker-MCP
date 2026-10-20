# Build ONLY after security review of this directory and upstream image/deps.
# For deployment, pin the resulting local image Id sha256:<64 hex> separately
# in ignored Windows operator config; never use a mutable tag in runner config.
FROM python:3.12.12-slim

RUN python -m pip install --no-cache-dir 'mcp==2.3.0' 'tzdata==2026.4' && \
    mkdir -p /runner /input /workspace && \
    chmod 755 /runner /input /workspace
COPY container_entrypoint.py /runner/container_entrypoint.py
RUN chmod 444 /runner/container_entrypoint.py
USER 65532:65532
WORKDIR /workspace
ENTRYPOINT ["python", "-I", "/runner/container_entrypoint.py"]
