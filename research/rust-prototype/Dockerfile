# Research build only. Static musl binary on an empty base: HTTP to the socket proxy
# needs no TLS roots, shell or libc.
FROM rust:1-alpine AS build
RUN apk add --no-cache musl-dev
WORKDIR /src
COPY Cargo.toml Cargo.lock* ./
COPY src ./src
RUN cargo test --release --locked 2>/dev/null || cargo test --release \
    && cargo build --release \
    && cp target/release/dockerlocal-rs /dockerlocal-rs

FROM scratch
COPY --from=build --chmod=0555 /dockerlocal-rs /dockerlocal-rs
USER 65532:65532
ENV DOCKER_API_URL=http://host.docker.internal:23750
ENTRYPOINT ["/dockerlocal-rs"]
