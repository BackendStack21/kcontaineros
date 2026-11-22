#!/usr/bin/env bash
# Boots the image in QEMU, inside Docker, and compares everything that
# appears on the console:  test/run.sh        (IMG=name to build under another tag)
#
# Each check is one boot. What is typed is echoed by init, so the expected
# text reads like the session.
set -u
cd "$(dirname "$0")/.."
IMG=${IMG:-kcos-bare}
docker build -q -t "$IMG" . > /dev/null || { echo "build failed" >&2; exit 1; }

VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml)
BOOT="kcos-boot $VERSION
boot: image ok, kernel at 0x40200000
kcos-kernel $VERSION"
UP="$BOOT
kernel: ram 128 MiB, mmu on, init at EL0"
OFF="kernel: power off"

pass=0 fail=0

# The address of the instruction that trapped moves with every build.
norm() { tr -d '\r' | sed -E 's/ at pc 0x[0-9a-f]+/ at pc PC/'; }

check() { # NAME ACTUAL EXPECTED
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: $1"
        diff <(echo "$3") <(echo "$2") | head -40 | sed 's/^/    /'
    fi
}

# session NAME INPUT EXPECTED: boot, type INPUT (a printf format), and see
# the boot lines followed by EXPECTED. No machine runs longer than a minute.
session() {
    check "$1" "$(printf "$2" | docker run -i --rm --entrypoint timeout "$IMG" 60 kcos-qemu 2>&1 | norm)" "$UP
$3"
}

# vm NAME SCRIPT EXPECTED: run SCRIPT in the container that has QEMU, the
# image and its parts; `boot FILE...` there boots an image made of them.
vm() {
    check "$1" "$(docker run --rm --entrypoint sh "$IMG" -c '
        cd /usr/share/kcos
        boot() { ./mkimage.sh "$@" /tmp/img > /dev/null && timeout 60 kcos-qemu /tmp/img < /dev/null; }
        '"$2" 2>&1 | norm)" "$3"
}

# --- the shell ---------------------------------------------------------

session "init runs commands and its exit status reaches the kernel" \
    'echo hello   world\necho\ninfo\nexit 3\n' \
'$ echo hello   world
hello world
$ echo

$ info
ram 128 MiB, free 125 MiB
$ exit 3
kernel: init exited with status 3
'"$OFF"

session "help lists every command" 'help\nexit\n' \
'$ help
echo [WORD]...     print the words
info               memory, as the kernel reports it
sys NR [A0 [A1]]   make system call NR (decimal) with hexadecimal arguments
peek ADDR          read the byte at a hexadecimal address
poke ADDR          write a zero byte there
jump ADDR          call the code there
el                 read CurrentEL, which only the kernel may
fp                 use a floating point register
exit [STATUS]      end init: the machine powers off
help               this list
$ exit
kernel: init exited with status 0
'"$OFF"

session "what is not a command or not its arguments is an error" \
    'nope\na b c d e\npeek\npeek zz\npeek 1 2\npoke\njump\nsys\nsys x\nsys 1 2 3 4\nel 1\nfp 1\ninfo 1\nhelp me\nexit 256\nexit x\nexit 1 2\n   \nexit\n' \
'$ nope
init: nope: not found
$ a b c d e
init: a: not found
$ peek
init: usage: peek ADDR
$ peek zz
init: peek: the address must be hexadecimal digits
$ peek 1 2
init: usage: peek ADDR
$ poke
init: usage: poke ADDR
$ jump
init: usage: jump ADDR
$ sys
init: usage: sys NR [A0 [A1]]
$ sys x
init: usage: sys NR [A0 [A1]]
$ sys 1 2 3 4
init: usage: sys NR [A0 [A1]]
$ el 1
init: usage: el
$ fp 1
init: usage: fp
$ info 1
init: usage: info
$ help me
init: usage: help
$ exit 256
init: usage: exit [STATUS], from 0 to 255
$ exit x
init: usage: exit [STATUS], from 0 to 255
$ exit 1 2
init: usage: exit [STATUS], from 0 to 255
$    
$ exit
kernel: init exited with status 0
'"$OFF"

session "backspace edits the line, ^C drops it, ^D on an empty line ends init" \
    'ab\177\010echo ok\necho gone\003echo x\n\004' \
'$ ab'$'\b \b\b \b''echo ok
ok
$ echo gone^C
$ echo x
x
$ 
kernel: init exited with status 0
'"$OFF"

long=$(printf 'x%.0s' $(seq 1 129))
session "a line longer than 128 bytes is refused whole, not cut" \
    "$long"'\n'"${long%x}"'\nexit 7\n' \
'$ '"${long%x}"'
init: line too long
$ '"${long%x}"'
init: '"${long%x}"': not found
$ exit 7
kernel: init exited with status 7
'"$OFF"

# --- the kernel keeps init out -----------------------------------------
# The controls: init reads its own code, and a write with its own pointer
# is served.

session "init reads its own memory" 'peek 80000000\nexit\n' \
'$ peek 80000000
0x58
$ exit
kernel: init exited with status 0
'"$OFF"

session "init cannot read the kernel" 'peek 40200000\n' \
'$ peek 40200000
kernel: init killed: data abort at pc PC, address 0x40200000
'"$OFF"

session "init cannot write the kernel" 'poke 40200000\n' \
'$ poke 40200000
kernel: init killed: data abort at pc PC, address 0x40200000
'"$OFF"

session "init cannot read RAM that is not its own" 'peek 40000000\n' \
'$ peek 40000000
kernel: init killed: data abort at pc PC, address 0x40000000
'"$OFF"

session "init cannot write RAM that is not its own" 'poke 47fff000\n' \
'$ poke 47fff000
kernel: init killed: data abort at pc PC, address 0x47fff000
'"$OFF"

session "init cannot reach the UART but through the kernel" 'peek 9000000\n' \
'$ peek 9000000
kernel: init killed: data abort at pc PC, address 0x9000000
'"$OFF"

session "init cannot read the bootloader in flash, which is not mapped" 'peek 0\n' \
'$ peek 0
kernel: init killed: data abort at pc PC, address 0x0
'"$OFF"

session "init cannot write its own code" 'poke 80000000\n' \
'$ poke 80000000
kernel: init killed: data abort at pc PC, address 0x80000000
'"$OFF"

session "init writes its own stack" 'poke bffffff0\nexit\n' \
'$ poke bffffff0
written
$ exit
kernel: init exited with status 0
'"$OFF"

session "init cannot execute its stack" 'jump bffff000\n' \
'$ jump bffff000
kernel: init killed: instruction abort at pc PC, address 0xbffff000
'"$OFF"

session "init cannot execute the kernel" 'jump 40200000\n' \
'$ jump 40200000
kernel: init killed: instruction abort at pc PC, address 0x40200000
'"$OFF"

session "the page below the stack is not there" 'peek bffeffff\n' \
'$ peek bffeffff
kernel: init killed: data abort at pc PC, address 0xbffeffff
'"$OFF"

session "init cannot read a system register" 'el\n' \
'$ el
kernel: init killed: undefined instruction at pc PC
'"$OFF"

session "init cannot use floating point" 'fp\n' \
'$ fp
kernel: init killed: floating point is not available at pc PC
'"$OFF"

# --- system calls do not act on pointers init could not use itself ------

session "write is served for init's memory and for no other" \
    'sys 1 80000000 0\nsys 1 40200000 10\nsys 1 40000000 10\nsys 1 9000000 1\nsys 1 bffffff0 20\nsys 1 7ffffff0 20\nsys 1 ffffffffffffffff 2\nsys 1 80000000 ffffffffffffffff\nexit\n' \
'$ sys 1 80000000 0
0
$ sys 1 40200000 10
-14
$ sys 1 40000000 10
-14
$ sys 1 9000000 1
-14
$ sys 1 bffffff0 20
-14
$ sys 1 7ffffff0 20
-14
$ sys 1 ffffffffffffffff 2
-14
$ sys 1 80000000 ffffffffffffffff
-14
$ exit
kernel: init exited with status 0
'"$OFF"

session "read and info store only where init may write" \
    'sys 2 40200000 1\nsys 2 80000000 1\nsys 2 bffffff0 0\nsys 3 40200000\nsys 3 80000000\nsys 3 bffffff8\nsys 3 bfffff00\nexit\n' \
'$ sys 2 40200000 1
-14
$ sys 2 80000000 1
-14
$ sys 2 bffffff0 0
0
$ sys 3 40200000
-14
$ sys 3 80000000
-14
$ sys 3 bffffff8
-14
$ sys 3 bfffff00
0
$ exit
kernel: init exited with status 0
'"$OFF"

session "a system call that does not exist is an error" 'sys 4\nsys 18446744073709551615\nexit\n' \
'$ sys 4
-38
$ sys 18446744073709551615
-38
$ exit
kernel: init exited with status 0
'"$OFF"

# --- the bootloader starts the image it was built with or nothing -------
# The control: the same parts, joined as the build joins them, boot.

vm "an image joined from its parts boots" '{ boot boot kernel init & sleep 5; kill $!; wait; } 2> /dev/null' \
"$UP
\$ "

vm "one changed byte in the image is a checksum mismatch" \
    'cp /kcos.img /tmp/i; printf X | dd of=/tmp/i bs=1 seek=65568 conv=notrunc 2> /dev/null; timeout 60 kcos-qemu /tmp/i' \
"kcos-boot $VERSION
boot: image checksum mismatch"

vm "flash without an image after the bootloader is refused" 'timeout 60 kcos-qemu boot' \
"kcos-boot $VERSION
boot: no image in flash"

vm "a kernel that is not an executable is refused" 'boot boot mkimage.sh init' \
"kcos-boot $VERSION
boot: the kernel is not an ARM64 executable"

vm "a kernel linked for somewhere that is not RAM is refused" 'boot boot init init' \
"kcos-boot $VERSION
boot: a kernel segment lies outside RAM"

vm "the kernel refuses an init that is not an executable" 'boot boot kernel mkimage.sh' \
"$BOOT
kernel: init is not an ARM64 executable"

vm "the kernel refuses an init linked for the kernel's addresses" 'boot boot kernel kernel' \
"$BOOT
kernel: an init segment lies outside the user address space"

vm "started at EL2, the bootloader refuses" \
    'timeout 60 qemu-system-aarch64 -M virt,gic-version=2,virtualization=on -cpu cortex-a72 -m 128 -display none -serial mon:stdio -bios /kcos.img' \
"kcos-boot $VERSION
boot: not started at EL1"

vm "RAM is read from the device tree; a gigabyte of it is used" \
    'for m in 64 4096; do KCOS_RAM=$m timeout 60 kcos-qemu < /dev/null & sleep 5; kill $!; wait; echo; done 2>/dev/null' \
"$BOOT
kernel: ram 64 MiB, mmu on, init at EL0
\$ 
$BOOT
kernel: ram 1024 MiB, mmu on, init at EL0
\$ "

vm "the bootloader fits its 64 KiB and the image is under 128 KiB" \
    'test $(wc -c < boot) -le 65536 && test $(wc -c < /kcos.img) -lt 131072 && echo yes' \
"yes"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
