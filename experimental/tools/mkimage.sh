#!/bin/sh
# The flash image:  tools/mkimage.sh BOOT KERNEL INIT OUT
#
#   0        the bootloader, padded to 64 KiB
#   0x10000  "KCOSIMG1", then little-endian u32: length of the kernel,
#            length of init, POSIX cksum of the two together; zeros to 32 bytes
#   0x10020  the kernel (ELF), then init (ELF)
set -eu
boot=$1 kernel=$2 init=$3 out=$4
boot_size=65536

le32() {
    n=$1
    for _ in 1 2 3 4; do
        # shellcheck disable=SC2059
        printf "\\$(printf %03o $((n & 255)))"
        n=$((n >> 8))
    done
}

size=$(wc -c < "$boot")
[ "$size" -le $boot_size ] || { echo "mkimage: $boot is larger than $boot_size bytes" >&2; exit 1; }
sum=$(cat "$kernel" "$init" | cksum)

{
    cat "$boot"
    head -c $((boot_size - size)) /dev/zero
    printf KCOSIMG1
    le32 "$(wc -c < "$kernel")"
    le32 "$(wc -c < "$init")"
    le32 "${sum%% *}"
    le32 0; le32 0; le32 0
    cat "$kernel" "$init"
} > "$out"

echo "boot $size, kernel $(wc -c < "$kernel"), init $(wc -c < "$init"), image $(wc -c < "$out") bytes"
