FROM rust:1-bookworm AS builder
WORKDIR /source
COPY rust/crates/relay_server rust/crates/relay_server
COPY rust/crates/relay_protocol rust/crates/relay_protocol
RUN cargo build --locked --release --manifest-path rust/crates/relay_server/Cargo.toml

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 relay && mkdir /var/lib/chta-relay && chown relay /var/lib/chta-relay
COPY --from=builder /source/rust/crates/relay_server/target/release/cht-relay /usr/local/bin/chta-relay
USER 10001
EXPOSE 4002
ENTRYPOINT ["/usr/local/bin/chta-relay", "--config", "/etc/chta/relay.json"]
