# Same reviewed Scout pin as the Python image (../Dockerfile).
FROM docker/scout-cli:1.30.0@sha256:01f7e63d8ee0668b2c19f09920d7e7eff8d3e507ca931df2b8c00ae19b71d588 AS scout

# Static musl binary; the server itself needs no shell or libc.
FROM rust:1-alpine AS build
RUN apk add --no-cache musl-dev ca-certificates
WORKDIR /src
COPY Cargo.toml Cargo.lock ./
COPY src ./src
ARG CARGO_LOCKED=--locked
RUN cargo test --release $CARGO_LOCKED \
    && cargo build --release $CARGO_LOCKED \
    && cp target/release/dockerlocal-rs /dockerlocal-rs

FROM scratch
COPY --from=build --chmod=0555 /dockerlocal-rs /dockerlocal-rs
# docker-scout is static; it needs CA roots for Docker Hub and a writable /tmp (tmpfs at runtime).
COPY --from=scout --chmod=0555 /docker-scout /usr/local/bin/docker-scout
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
USER 65532:65532
ENV DOCKER_API_URL=http://host.docker.internal:23750 \
    DOCKER_HOST=tcp://host.docker.internal:23750 \
    HOME=/tmp/dockerlocal-home \
    XDG_CACHE_HOME=/tmp/dockerlocal-home/.cache \
    DOCKER_SCOUT_CACHE_DIR=/tmp/docker-scout \
    DOCKER_SCOUT_NEW_VERSION_WARN=false
ENTRYPOINT ["/dockerlocal-rs"]
