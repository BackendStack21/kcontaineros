#!/bin/sh
# Build the three programs, each with its own linker script, and put them
# into one flash image:  tools/build.sh OUTDIR
set -eu
out=$1
rel=target/aarch64-unknown-none-softfloat/release

for bin in boot kernel init; do
    # The bootloader is not an ELF file: the CPU starts at its first byte.
    flat=
    [ "$bin" != boot ] || flat="-C link-arg=--oformat=binary"
    cargo rustc --release --locked --bin "$bin" -- \
        -C "link-arg=-T$PWD/link/$bin.ld" -C link-arg=-zmax-page-size=4096 $flat
done

mkdir -p "$out"
cp "$rel/boot" "$rel/kernel" "$rel/init" "$out"
tools/mkimage.sh "$rel/boot" "$rel/kernel" "$rel/init" "$out/kcos.img"
