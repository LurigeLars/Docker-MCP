FROM docker/scout-cli:1.30.0@sha256:01f7e63d8ee0668b2c19f09920d7e7eff8d3e507ca931df2b8c00ae19b71d588 AS scout

FROM python:3.12.15-slim

# Exact reviewed commit is supplied by refresh-public-runtime.ps1.
# Other builds remain explicitly "unknown" rather than asserting a false SHA.
ARG SOURCE_REVISION=unknown
LABEL org.opencontainers.image.source="https://github.com/LurigeLars/Docker-MCP" \
      org.opencontainers.image.revision="${SOURCE_REVISION}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && apt-get install -y --no-install-recommends --only-upgrade apt zlib1g libc6 libc-bin \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /tmp/requirements.txt
RUN python -m pip install --no-cache-dir -r /tmp/requirements.txt

# Set modes at copy time: a later chmod would duplicate the ~200 MB binary in a new layer.
COPY --from=scout --chmod=0555 /docker-scout /usr/local/bin/docker-scout
COPY server.py tool_usage.py /app/

RUN useradd --system --uid 65532 --home-dir /nonexistent --shell /usr/sbin/nologin dockerlocal \
    && mkdir -p /var/lib/dockerlocal-tool-usage /tmp/dockerlocal-home/.cache /tmp/docker-scout \
    && chown 65532:65532 /var/lib/dockerlocal-tool-usage \
    && chmod 0700 /var/lib/dockerlocal-tool-usage \
    && chown -R 65532:65532 /tmp/dockerlocal-home /tmp/docker-scout \
    && chmod 0444 /app/server.py /app/tool_usage.py

USER 65532:65532
WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    HOME=/tmp/dockerlocal-home \
    XDG_CACHE_HOME=/tmp/dockerlocal-home/.cache \
    DOCKER_API_URL=http://host.docker.internal:23750 \
    DOCKER_HOST=tcp://host.docker.internal:23750 \
    DOCKER_SCOUT_CACHE_DIR=/tmp/docker-scout \
    DOCKER_SCOUT_NEW_VERSION_WARN=false

ENTRYPOINT ["python", "/app/server.py"]
