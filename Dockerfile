FROM docker/scout-cli:1.26 AS scout

FROM python:3.12.15-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /tmp/requirements.txt
RUN python -m pip install --no-cache-dir -r /tmp/requirements.txt

COPY --from=scout /docker-scout /usr/local/bin/docker-scout
COPY server.py /app/server.py

RUN useradd --system --uid 65532 --home-dir /nonexistent --shell /usr/sbin/nologin dockerlocal \
    && mkdir -p /tmp/dockerlocal-home/.cache /tmp/docker-scout \
    && chown -R 65532:65532 /tmp/dockerlocal-home /tmp/docker-scout \
    && chmod 0555 /usr/local/bin/docker-scout \
    && chmod 0444 /app/server.py

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
