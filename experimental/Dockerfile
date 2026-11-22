# kcos-bare — experimental bootloader, kernel and init for ARM64 (QEMU virt).
#
#   docker build -t kcos-bare experimental     (QEMU with the image: docker run -it --rm kcos-bare)
#   docker build --target image -o out experimental   (only the flash image, as out/kcos.img)

FROM --platform=$BUILDPLATFORM rust:1.100.0-alpine3.24@sha256:8d0e82abfdf9a38071e07cabc5afba4ddbe077631a80e4e742a760c38beadc33 AS build
RUN rustup target add aarch64-unknown-none-softfloat
WORKDIR /src
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY .cargo .cargo
COPY link link
COPY src src
COPY tools tools
RUN tools/build.sh /out

FROM scratch AS image
COPY --from=build /out/kcos.img /kcos.img

# Something to boot it on. Nothing of this is in the image above.
FROM alpine:3.24
RUN apk add --no-cache qemu-system-aarch64
COPY --from=build /out/kcos.img /kcos.img
# The parts and the tool that joins them, for the checks that boot images
# put together wrongly.
COPY --from=build /out/boot /out/kernel /out/init /src/tools/mkimage.sh /usr/share/kcos/
COPY tools/kcos-qemu /usr/local/bin/kcos-qemu
ENTRYPOINT ["kcos-qemu"]
