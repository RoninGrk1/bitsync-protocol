FROM rust:1.85-bookworm AS builder
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY crates crates
COPY sdk/rust sdk/rust
COPY config config
RUN cargo build --release -p bitsync-node

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/bitsync-node /usr/local/bin/bitsync-node
COPY config /config
EXPOSE 9100
ENTRYPOINT ["bitsync-node"]
CMD ["--config", "/config/node.toml"]
