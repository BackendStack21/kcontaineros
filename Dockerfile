# kContainerOS — zero-dependency, Rust-based mini OS for containers (ARM64).
#
#   docker build --platform linux/arm64 -t kcontaineros .
#   docker build --platform linux/arm64 --target sealed -t kcontaineros:sealed .   (init only: no shell, no tools)
#   docker build --platform linux/arm64 --target cov -t kcontaineros-cov .   (test coverage only)

FROM --platform=$BUILDPLATFORM rust:1.100.0-alpine3.24@sha256:8d0e82abfdf9a38071e07cabc5afba4ddbe077631a80e4e742a760c38beadc33 AS toolchain
ARG TARGETARCH
RUN [ "$TARGETARCH" = arm64 ] || { echo "kContainerOS supports linux/arm64 only (got linux/$TARGETARCH)" >&2; exit 1; }
RUN rustup target add aarch64-unknown-none
WORKDIR /src
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY .cargo .cargo
COPY src src
COPY rootfs rootfs
COPY tools tools

# The real thing: freestanding, no libc, no std.
FROM toolchain AS build
RUN cargo build --release --locked \
 && tools/mkrootfs.sh target/aarch64-unknown-none/release/kcontaineros /rootfs

# The same sources built against std with LLVM coverage instrumentation.
# Every process writes its counters to /cov when it exits or execs.
FROM toolchain AS covtools
RUN apk add --no-cache musl-dev && rustup component add llvm-tools
ENV RUSTFLAGS="-C instrument-coverage -C panic=abort"
RUN cargo build --locked --features cov --target aarch64-unknown-linux-musl \
 && tools/mkrootfs.sh target/aarch64-unknown-linux-musl/debug/kcontaineros /rootfs \
 && mkdir -m 1777 /rootfs/cov

FROM scratch AS cov
COPY --from=covtools /rootfs /
ENV PATH=/usr/local/bin:/usr/bin:/bin:/sbin
USER 65534:65534
ENTRYPOINT ["/sbin/init"]
CMD ["/bin/sh"]

# PID 1 and nothing else: no shell, no utilities, no writable directory.
FROM toolchain AS build-sealed
RUN cargo build --release --locked --no-default-features \
 && tools/mkrootfs.sh --sealed target/aarch64-unknown-none/release/kcontaineros /rootfs

FROM scratch AS sealed
COPY --from=build-sealed /rootfs /
ENV PATH=/usr/local/bin:/usr/bin
USER 65534:65534
ENTRYPOINT ["/sbin/init"]

FROM scratch
COPY --from=build /rootfs /
ENV PATH=/usr/local/bin:/usr/bin:/bin:/sbin
# Not root unless the image built on top says so.
USER 65534:65534
# init is PID 1: it locks the container down, forwards signals to CMD and
# reaps zombies.
ENTRYPOINT ["/sbin/init"]
CMD ["/bin/sh"]
