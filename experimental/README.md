# kcos-bare — experimental

A bootloader, a kernel and a first program for ARM64, written from nothing:
no dependencies, no `std`, no `alloc`, only `core`. It boots in QEMU's
`virt` machine from a flash image of about 100 kB.

It is an experiment next to kContainerOS, not part of it. kContainerOS is
a userland for the Linux kernel a container already has. This is the other
end: what runs when there is no kernel yet. **It does not run Linux
programs**, so it is not something to build a container image `FROM`.

```
$ docker run -it --rm kcos-bare
kcos-boot 0.1.0
boot: image ok, kernel at 0x40200000
kcos-kernel 0.1.0
kernel: ram 128 MiB, mmu on, init at EL0
$ echo hello
hello
$ info
ram 128 MiB, free 125 MiB
$ peek 40200000
kernel: init killed: data abort at pc 0x80000aa8, address 0x40200000
kernel: power off
```

## The three programs

| | Runs | Does |
| --- | --- | --- |
| `boot` (6 kB) | at reset, in place from flash at address 0, EL1, MMU off | Verifies the image that follows it, places the kernel's segments and the init file in RAM, jumps to the kernel. |
| `kernel` (25 kB) | at EL1, from 2 MiB into RAM | Turns the MMU on, loads init at EL0, then serves its system calls. |
| `init` (9 kB) | at EL0, from 2 GiB up | A command line on the console. |

`src/lib.rs` and its modules are what they share: the UART, the device
tree and ELF readers, the checksum, the system call numbers.

### The bootloader

The CPU starts at the first byte of flash. The bootloader has no writable
data (the linker script refuses to link one that does) and a stack below
the kernel's load address. It reads the amount of RAM from the device tree
QEMU leaves at the start of RAM, then the image header at 64 KiB:

```
0        the bootloader, padded to 64 KiB
0x10000  "KCOSIMG1", then little-endian u32: length of the kernel,
         length of init, POSIX cksum of the two together; zeros to 32 bytes
0x10020  the kernel (ELF), then init (ELF)
```

It starts the image it was built with or nothing. A wrong magic, a wrong
checksum, a kernel that is not a static ARM64 executable, a segment that
does not lie in RAM, an entry point outside executable code or a start at
another exception level than EL1: each is one line on the console, and the
machine powers off.

The checksum finds a damaged image. It authenticates nothing: whoever can
write the flash can write a matching checksum.

### The kernel

One CPU, one process, no interrupt handler, no allocation. Memory is
handed out a page at a time and never taken back.

- **Its own memory is out of reach of EL0**, and write-xor-execute for
  itself: code is read-only, data is not executable, and `SCTLR_EL1.WXN`
  makes any writable page non-executable whatever its entry says.
- **init gets the gigabyte from `0x80000000`**: each ELF segment with its
  own permissions (a segment that is writable and executable is refused),
  a 64 KiB stack at the top that cannot be executed, and an unmapped page
  below it.
- **A system call acts only on memory init could use itself.** Pointers
  are checked by walking the page tables by hand before anything is read
  or stored, so a bad pointer is `-14` for init, never a fault in the
  kernel and never the kernel reading or writing on init's behalf.
- **Anything else init does that it may not ends it**: touching memory
  that is not its own, executing data, a privileged instruction, floating
  point. The kernel says what and where, and powers off.
- **An exception while the kernel runs is a kernel bug**: it is reported
  with the registers that describe it, and the machine powers off.
- Waiting for the console does not spin: the UART's interrupt line is
  routed to the CPU, which keeps interrupts masked and sleeps in `wfi`
  until the line is raised.

System calls are `svc #0` with the number in x8, arguments in x0 and x1
and the result in x0:

| Nr | Call | |
| --- | --- | --- |
| 0 | `exit(status)` | The kernel prints the status and powers off. |
| 1 | `write(ptr, len)` | Bytes to the console. Returns `len`. |
| 2 | `read(ptr, len)` | Waits for at least one byte. Returns how many. |
| 3 | `info(ptr)` | Stores two `u64`: bytes of RAM, bytes not handed out. |

Any other number is `-38`.

### init

`echo`, `info`, `help` and `exit [STATUS]`, and commands that exist to
push against the kernel: `peek ADDR` and `poke ADDR` read and write a byte
anywhere, `jump ADDR` calls an address, `el` reads a system register, `fp` uses a
floating point register,
`sys NR [A0 [A1]]` makes any system call with any arguments. Backspace
edits the line, Ctrl-C drops it, Ctrl-D on an empty line exits. A command
it does not have, an argument too many or a line over 128 bytes is an
error, not a guess.

## Build, run, test

Docker is all that is needed; it builds the image and brings QEMU. From
the repository root:

```sh
make bare-build   # docker build -t kcos-bare experimental
make bare-run     # docker run -it --rm kcos-bare     (Ctrl-A X leaves QEMU)
make bare-test    # experimental/test/run.sh
docker build --target image -o out experimental    # only out/kcos.img
```

With a QEMU of your own:

```sh
qemu-system-aarch64 -M virt,gic-version=2 -cpu cortex-a72 -m 128 \
    -display none -serial mon:stdio -bios out/kcos.img
```

`test/run.sh` boots the image once per check and compares everything that
appears on the console. Each refusal has its control next to it: init
reads its own memory before it is shown not to read the kernel's, and an
image joined from its parts boots before a damaged one is shown not to.

## What it is not

- **Only QEMU `virt` with a GICv2.** Device addresses are the board's;
  only the amount of RAM is read from the device tree. It has not run on
  hardware, and caches are enabled without the invalidation real hardware
  wants first.
- **No secure boot.** See the checksum above.
- **One process.** No scheduler, no timer, no files, no network, no second
  CPU. Memory is never freed. At most 1 GiB of RAM is used.
- **No floating point** for anyone: everything is built for
  `aarch64-unknown-none-softfloat`, and init is ended if it tries.
- **No Linux ABI.** The four system calls above are all there is.
