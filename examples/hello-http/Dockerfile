# Example: a statically linked HTTP server on top of kContainerOS.
ARG BASE=kcontaineros
FROM rust:1.100.0-alpine3.24@sha256:8d0e82abfdf9a38071e07cabc5afba4ddbe077631a80e4e742a760c38beadc33 AS build
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src src
# rust:alpine builds static musl binaries, which is why no libc is needed below.
RUN cargo build --release --locked

FROM ${BASE}
COPY --from=build /app/target/release/hello-http /usr/local/bin/hello-http
# The base image runs as nobody; build steps that write need root.
USER 0
# Shell-form RUN works because the base image ships /bin/sh.
RUN mkdir -p /data && echo ready > /data/status
# The server itself needs no privilege.
USER 65534:65534
EXPOSE 8080
# Exec form: init runs the server directly and forwards signals to it.
CMD ["hello-http"]
