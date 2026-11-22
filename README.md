# kContainerOS

A zero-dependency, Rust-based mini OS for containers. **ARM64 only.**

Site: <https://kcos.21no.de> · Source: <https://github.com/BackendStack21/kcontaineros>

The whole userland is one static binary of under 100 kB with no libc, no
`std` and no crates. It talks to the Linux kernel through raw syscalls. The
Docker image is under 250 kB and contains nothing else except four small
files in `/etc`.

| Path | Role |
| --- | --- |
| `/sbin/init` | PID 1: forwards every signal to your command, reaps zombies, exits with your command's status. Never allocates; as PID 1 it never polls. |
| `/bin/sh` | A small shell, enough for Dockerfile `RUN`/`CMD` shell form, simple entrypoint scripts and `docker exec -it … sh`. |
| `/bin/*` | `cat chmod chown cp echo env false kill ln ls mkdir mv ps pwd rm sleep touch true uname` |

All of them are symlinks to `/bin/kcontaineros`, and so is `/usr/bin/env`.

## Use

```sh
git clone https://github.com/BackendStack21/kcontaineros.git && cd kcontaineros
make build        # docker build --platform linux/arm64 -t kcontaineros .
make test         # end-to-end tests against the local Docker daemon
make coverage     # the same tests on an instrumented build, with a coverage report
docker run -it --rm kcontaineros
```

Put a binary on top of it:

```dockerfile
FROM kcontaineros
COPY my-server /usr/local/bin/my-server
CMD ["my-server"]
```

What to know before you do:

- **It runs as `nobody`, not root.** Build steps that write need `USER 0`
  first; switch back with `USER 65534:65534`.
- **Programs run only from `/bin`, `/sbin` and `/usr`.** Put yours in
  `/usr/local/bin`, or name its directory: `ENV KCOS_EXEC=/app`. Whatever
  directory holds programs cannot be written to at run time, together with
  the top-level directory it is in. Entries must be plain absolute paths
  to real directories: `/`, a trailing slash, `.` or `..` components and
  anything reached through a symbolic link are ignored, with a warning. The
  top-level directory of an ignored entry is not writable all the same.
- **Only the standard devices can be used**: `null`, `zero`, `full`,
  `random`, `urandom`, `tty`, `console`, the terminals and `/dev/shm`. A
  device passed with `--device` has to be named: `ENV KCOS_DEV=/dev/fuse`.
  POSIX message queues (`mq_open`) do not work under init.
- **`memfd_create` is refused.** A few runtimes use it for JIT code or
  sealed memory; they need another base image.
- **Your command holds no capabilities**, whatever `--cap-add` or
  `--privileged` say. Ports below 1024 still work, because Docker makes
  them unprivileged.
- **New top-level directories cannot be created at run time.** Create them in
  the Dockerfile, or mount a volume there.
- `ENTRYPOINT` is `/sbin/init`, so `CMD` runs under it. If you set your own
  `ENTRYPOINT`, or pass `--entrypoint`, init and everything it enforces are
  gone. Keep it with `ENTRYPOINT ["/sbin/init", "--", "my-server"]`.
- With `--read-only`, `/tmp`, `/var/tmp` and `/run` are read-only too. Add
  `--tmpfs /tmp` if your program writes there.

See `examples/hello-http` for a complete image.

### The sealed image

```sh
docker build --platform linux/arm64 --target sealed -t kcontaineros:sealed .
```

`kcontaineros:sealed` is init and nothing else: about 100 kB, no shell, no
utilities, no writable directory. The binary is built without the shell and
utility code, so there is none to reach by renaming it. Use it for the final
stage when your image needs no `RUN` steps:

```dockerfile
FROM kcontaineros:sealed
COPY my-server /usr/local/bin/my-server
CMD ["my-server"]
```

## Security

The aim: code running inside the container, including code an attacker has
taken over, cannot gain privilege, cannot loosen its restrictions and cannot
run a program it brought with it. Init applies the restrictions to itself
before it starts your command, the kernel enforces them, and every process
inherits them. None can be undone from inside.

| Restriction | Mechanism | What it stops |
| --- | --- | --- |
| No privilege gain | `no_new_privs` | setuid binaries and file capabilities grant nothing. |
| No capabilities | bounding, ambient and process sets emptied | Root in the container holds no privilege the kernel grants by capability, even under `--privileged`. What is left is what owning a file allows. |
| Run or write, never both | Landlock, plus the filter for memory files | Programs are started only from the image's program directories, and nothing can be created, removed or written in those, whatever the file permissions. A binary dropped in `/tmp` or on a volume cannot be started, and memory files (`memfd_create`) cannot be created at all. Symbolic links are never followed when the rules are set up, so a link cannot turn a program directory into a writable one. |
| Only the standard devices | Landlock | Of `/dev`, a program can read, write and control (`ioctl`) `null`, `zero`, `full`, `random`, `urandom`, `tty`, `console`, the terminals in `/dev/pts`, and `/dev/shm`; also `/dev/termination-log` where Kubernetes mounts that file. Nothing else, whatever the device's permissions say: under `--privileged` that is every disk of the host. A device passed with `--device` has to be named, each one by its own path: `ENV KCOS_DEV=/dev/fuse:/dev/net/tun`. |
| Root cannot write the kernel's files | Landlock | Root keeps no capability, but it still owns the files in `/proc` and `/sys`. Under init, root cannot open them for writing: not `/proc/sys`, not the sysrq trigger. Reading them is not stopped. |
| Reduced kernel surface | seccomp filter, on top of Docker's | `ptrace`, the system calls that read or write another process's memory (`process_vm_readv`, `process_vm_writev`), new namespaces, mounts, `chroot`, kernel modules, `bpf`, `io_uring`, `perf`, keyrings, clock and hostname changes, sockets to the hypervisor (`AF_VSOCK`), and switching off address randomisation are refused. System calls newer than the filter knows are answered "not implemented". |
| Nothing to tamper with | image files are read-only and owned by root; default user is `nobody` | The image cannot be modified by the default user. |
| PID 1 is opaque | not dumpable | Other processes cannot read its memory or environment. |

`make test` checks each of these against the strongest attacker Docker can
hand over (root, `--privileged`, Docker's own filter switched off) and runs
the same attempts without init as a control, where they succeed.

[`AUDIT.md`](AUDIT.md) summarises an end-to-end security audit of the
image: no escape and no privilege gain were found, three security claims
were false and are fixed. [`audit/`](audit/README.md) has the method, every
finding and the harnesses to run it again. It was carried out by an AI
model, not by an independent party.

How the binary itself is built:

- **Static PIE.** The kernel loads it at a random address on every start and
  the binary relocates itself. Code, data, stack and heap are all randomised.
- **Read-only after start.** Function and string tables are made read-only
  once relocated (RELRO). No segment is both writable and executable, and
  the stack is not executable.
- **Pinned and reproducible.** The compiler image is pinned by digest, the
  toolchain by version, and a rebuild from scratch produces the identical
  image layer.
- **No signal handlers and no threads.** PID 1 consumes signals
  synchronously, so there is no handler code to race.

What this does not give you. No image can make these claims honestly:

- **It is not a guarantee against kernel bugs.** The filter removes the
  interfaces most exploits start from; it cannot remove the kernel.
- **Code that is already running can still compute.** An attacker with
  code execution inside your server can use what your server can reach:
  its files, its network, its memory. The restrictions stop them going
  further, not from being there.
- **"Cannot run" means "cannot be started as a program".** A process can
  still map bytes into its own memory as executable code and jump to them;
  neither Landlock nor the filter prevents that, because every dynamic
  loader and JIT does the same. Such code runs inside the process it was
  loaded into, under every restriction above, and cannot become a new
  program. Mount writable directories `noexec` (Docker's `--tmpfs` does by
  default) to stop files there being mapped as code.
- **As root, a program cannot write to `/proc` or `/sys` at all**, its own
  `/proc/self/oom_score_adj` included. Run as a non-root user, the default,
  and ordinary file permissions apply there instead.
- **Root can still read what root owns in `/proc` and `/sys`.** In a
  `--privileged` container, where Docker hides nothing, that includes
  kernel state such as `/proc/slabinfo`, `/proc/vmallocinfo` and the names
  of other containers' keyrings in `/proc/keys`. What needs a capability to
  read (`/proc/kcore`, `/proc/kmsg`, kernel addresses) stays hidden. The
  default user reads none of it.
- **A device that is not named can still be opened for neither reading nor
  writing** (access mode 3). Nothing can be read from it, written to it or,
  on Linux 6.10 and later, asked of it with `ioctl`. On older kernels
  Landlock cannot stop the `ioctl`: do not pass a device there that you
  have not named.
- **A device in a directory of its own** (`/dev/net/tun`) switches the
  confinement of reads on, as an unnamed device does (see the Docker
  Desktop note below): what else is in that directory was not named.
- **The rules go by where things are mounted when init starts.** They
  assume the usual layout, and a container started otherwise gets less:
  a device node outside `/dev` (mapped there with `--device
  /dev/x:/data/x`, or on a volume mounted without `nodev`) is an ordinary
  file; a `/proc` or `/sys` mounted somewhere else is an ordinary
  directory; and one volume mounted both inside a program directory and
  somewhere writable can be written through the second path and run
  through the first. Mount a volume in one place.
- **Whoever owns a file can still change its permissions, timestamps and
  extended attributes (`user.*`)**, in program directories too: root for
  the image's files, the default user for files an image built on top
  copied in with `--chown`. Nobody can change what is in them.
- **A dynamic loader you ship is a program that loads programs.** Copy in
  `ld-musl` or `ld-linux` and it will map and run a binary from any
  directory not mounted `noexec`, as it does with every shared library.
- **Host directories shared by Docker Desktop** (a bind mount from macOS or
  Windows) can be read but not written to, and programs in them cannot be
  started: their filesystem cannot be matched by any Landlock rule. When
  `/dev` holds anything beyond the standard entries and what `KCOS_DEV`
  names (`--privileged`, an unnamed `--device`, a mount under `/dev`), they
  cannot be read either. Use a volume. Bind mounts on a Linux host are not affected.
- **Processes of the same user can read and write each other's memory
  through `/proc/PID/mem`**, read-only pages included, unless the host
  enables Yama: the filter refuses the system calls made for it, not the
  file. Root can read there, not write. Run one service per container.
- **`docker exec`, `--entrypoint` and `RUN` steps start outside init.** A
  shell or utility started that way still applies `no_new_privs` and the
  filter to itself, but keeps the capabilities Docker gave it and is not
  under the Landlock rules: build steps have to be able to write the image.
  Other programs started that way get only what Docker gives them.
- **The shell will interpret a script from anywhere**, including one an
  attacker wrote to `/tmp`. It cannot be executed directly, and the shell
  running it is under the same restrictions, but it is attacker-chosen
  logic. The sealed image has no shell.
- **On kernels without Landlock** (before 5.19, or with it disabled) init
  prints a warning and the run-or-write rule is not enforced. Everything
  else is; if the filter itself cannot be installed, or Landlock is there
  and its rules cannot be set up, init refuses to start. As PID 1 it
  applies all of it whatever an outer filter answers.
- **Started as non-root, or as root without `CAP_SETPCAP`, init cannot
  empty the capability bounding set.** It does not matter: with
  `no_new_privs` nothing can draw on it.
- No stack protector or branch protection (BTI/PAC): both need a nightly
  compiler for this target. The unwind tables of the prebuilt `core`
  library (unused) are still in the binary for the same reason.
- User-namespace remapping has not been tested.

How the tools behave where it matters:

- `rm -r` walks the tree through directory descriptors opened without
  following symlinks, so a symlink swapped in during the walk cannot send it
  elsewhere, also when the operand is written with a trailing slash. It
  refuses `/`, `.` and `..`, and trees deeper than 4096 levels or than the
  limits on open files and on the stack allow. What it cannot remove it reports
  once, and it still empties a directory it is not allowed to delete.
- `kill` accepts only real process IDs: `0`, `-1` and numbers that would wrap
  around a 32-bit PID are rejected.
- `cp` never copies setuid, setgid or sticky bits, and refuses to copy a file
  onto itself.
- `ps` always, and `ls`, `pwd`, `env`, `cd -` and `command -v` on a
  terminal, replace everything but printable ASCII in what they print with
  `?`. So does every error message that goes
  to a terminal, from the utilities, the shell and init.
- The shell rejects what it does not implement instead of running it as
  something else, and checks a whole script before running its first line
  (a script on standard input is checked as it is read).
- A utility whose output cannot be written (full disk, closed descriptor)
  exits with status 1.

## Containing AI agents

An AI agent acts through tools: a process that runs commands, edits files or
calls services on the model's behalf. Text the model reads can steer it, so
the tool process has to be treated as something an attacker may end up
directing. Put the tool server in this image and the usual next steps are
refused by the kernel, not by instructions the model is asked to follow.

| What a hijacked agent might try | What happens |
| --- | --- |
| Fetch a program and run it | Nothing written at run time can be started as a program: not from `/tmp`, not from a volume, not from a memory file. |
| Become root, or use root | No capabilities and `no_new_privs`: there is nothing to escalate to. |
| Replace its own tools | Nothing running under init can write to a program directory. |
| Go after the kernel | New namespaces, mounts, `ptrace`, `bpf`, `io_uring` and similar are refused. |
| Use what is lying around | The sealed image has no shell, no interpreter and no package manager. |
| Keep running after you say stop | `docker stop` reaches the tool server at once, and leftover processes are reaped. |

Build the tool server as a static binary on the sealed image:

```dockerfile
FROM kcontaineros:sealed
COPY agent-tools /usr/local/bin/agent-tools
CMD ["agent-tools"]
```

The image cannot decide the network, memory, process count or what is
mounted, so set those when you run it. A tool server that talks over
standard input and output needs no network at all:

```sh
docker run -i --rm --read-only --network none --ipc none \
    --memory 512m --pids-limit 128 \
    --tmpfs /work:uid=65534,gid=65534,mode=0700 \
    my-agent-tools
```

Run that way, a tool server can write its working files to `/work` and
nowhere else, cannot start anything it writes there as a program, has no
network, and holds no privilege. `--ipc none` matters for "nowhere else":
without it Docker gives every container a writable `/dev/shm` of 64 MB.

What this does not contain:

- **The network.** Without `--network none` or a network you restrict
  yourself, an agent can send anything it can read to anywhere it can reach.
- **What can be read.** Every file and secret you mount is readable by the
  tool server. Mount only what the tools need.
- **What your tools do.** A tool that deletes files will delete them for a
  hijacked agent too. The image contains the process, not the purpose.
- **Machine code loaded into the tool server itself.** A hijacked process
  can map bytes as code inside its own memory. That code is still the tool
  server: same restrictions, no new program.
- **Interpreted code.** Copy in Python, Node or a shell and the agent can
  run any script through it. The run rule stops programs brought in at run
  time, not code fed to an interpreter you shipped. The full image ships a
  small shell; the sealed image does not.
- **Development work.** Agents that need compilers, package managers or
  dynamically linked tools do not fit. This is for a fixed set of tools
  built as static binaries.

It has not been tested with any agent framework.

## Common questions

### How do I get a directory my program can write to?

Under init, a top-level directory is either for running programs or for
writing, never both. `/bin`, `/sbin`, `/usr` and anything named in
`KCOS_EXEC` hold programs and cannot be written to. Every other top-level
directory that exists when the container starts can be, subject to ordinary
file permissions. Since the image runs as `nobody` (65534), the directory
also has to belong to that user. Out of the box only `/tmp` and `/var/tmp`
qualify, plus the `/dev/shm` that Docker mounts in every container unless
it is started with `--ipc none`.

**A directory in the image.** `WORKDIR` creates it owned by the current
user, which is `nobody`:

```dockerfile
FROM kcontaineros
WORKDIR /data
```

Or create it as root and hand it over, for a path below an existing
directory or when you do not want it to be the working directory:

```dockerfile
FROM kcontaineros
USER 0
RUN mkdir -p /var/lib/app && chown 65534:65534 /var/lib/app
USER 65534:65534
```

**A volume.** Mount it on a directory prepared as above and a new named
volume takes over that directory's owner:

```sh
docker run -v app-data:/data my-image
```

Mounted on a path the image does not have, the volume is owned by root and
`nobody` cannot write to it. Bind mounts keep the permissions they have on
the host.

**A temporary filesystem**, owned by the user from the start:

```sh
docker run --tmpfs /scratch:uid=65534,gid=65534,mode=0700 my-image
```

**With `--read-only`** nothing in the image is writable, so every writable
path has to be a volume or a tmpfs: `docker run --read-only --tmpfs /tmp my-image`.

What cannot be made writable:

- anything under `/bin`, `/sbin`, `/usr` or the top-level directory of a
  `KCOS_EXEC` entry, even as a volume or tmpfs mounted there;
- a directory inside a program directory, whatever links point at it:
  `/data -> /usr/share/x` is as read-only as `/usr/share/x`;
- anything in `/dev` but the standard devices, `/dev/shm` and what
  `KCOS_DEV` names;
- for root, `/proc` and `/sys`;
- `/` itself: `mkdir /new` fails at run time, so create top-level
  directories in the Dockerfile or let a mount create them.

In the sealed image there is no `/tmp`. Mount one:
`--tmpfs /tmp:uid=65534,gid=65534,mode=0700`.

### My program fails with "permission denied" when it starts. Why?

Programs run only from `/bin`, `/sbin` and `/usr`. Copy yours to
`/usr/local/bin`, or declare its directory in the Dockerfile:

```dockerfile
ENV KCOS_EXEC=/app
```

Several directories are separated by colons. Each must be a plain absolute
path to a real directory, with no symbolic link on the way and no trailing
slash: init prints a warning for an entry it cannot use. That directory's
top-level directory then stops being writable, so a program in `/app/bin`
cannot keep its data in `/app/data`. Nothing in `/dev`, `/proc` or `/sys`
can be a program directory.

A program that is dynamically linked fails differently, with "no such file
or directory" ("not found" from the shell): its loader is missing. Build it
statically.

### A `RUN` step in my Dockerfile fails with "permission denied".

The image's user is `nobody` and its directories are read-only. Switch to
root for the build steps that write, then back:

```dockerfile
USER 0
RUN mkdir -p /etc/app && echo "mode=production" > /etc/app/config
USER 65534:65534
```

`COPY` and `WORKDIR` need no switch.

### How do I use a device passed with `--device`?

Name it, in the Dockerfile or when starting the container:

```sh
docker run --device /dev/fuse -e KCOS_DEV=/dev/fuse my-image
```

Several devices are separated by colons. Without the name the device is
there but cannot be opened. Ordinary permissions still apply on top, so a
non-root user may need the device's group: `--group-add`.

### Does my program need root? What about port 80?

No. Under init even root holds no capabilities, so running as root gains
almost nothing, gives up the protection of the read-only image, and loses
the ability to write anything in `/proc` and `/sys`. Ports
below 1024 work for any user, because Docker makes them unprivileged inside
a container. `--cap-add` and `--privileged` have no effect on the command.

A program that starts as root and switches user itself (some servers do)
will fail to switch: start it as the final user instead.

### How do I check that the lockdown is active?

```sh
docker run --rm my-image cat /proc/self/status
```

Look for `NoNewPrivs: 1`, `Seccomp: 2` and `CapEff: 0000000000000000`. If
the kernel has no Landlock, init prints a warning line when the container
starts. `make test` checks the restrictions themselves.

### How do I get a shell in a running container?

`docker exec -it CONTAINER sh`. That shell starts outside init: it cannot
gain privileges and is under the system call filter, but it is not held to
the run-or-write rule. The sealed image has no shell; use `docker cp` to
get files out and `docker logs` to see output.

### Can I use my existing entrypoint script?

Only if it stays within the shell's subset: commands, variables with
`${NAME:-default}`, pipes, `&&` and `||`, `&` and `wait`, redirections,
`cd`, `export`, `umask`, `set --`, `exec`. A script with `if`, loops, `$(…)`, `[`,
globs, `trap`, `read`, `.` or `${NAME:?}` stops with a syntax error before
its first command runs. Either put
the logic in your program, or call the program directly:

```dockerfile
ENTRYPOINT ["/sbin/init", "--", "my-server", "--config", "/etc/app/config"]
```

Keep `/sbin/init` first whenever you set `ENTRYPOINT`; without it nothing
on this page is enforced.

### How do I add CA certificates or timezone data?

Copy them from an image that has them:

```dockerfile
FROM alpine AS certs
RUN apk add --no-cache ca-certificates tzdata

FROM kcontaineros
COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=certs /usr/share/zoneinfo /usr/share/zoneinfo
```

### My runtime fails on `memfd_create`, `ptrace` or `io_uring`.

Those calls are refused on purpose and there is no switch to allow them. A
program that needs them needs another base image.

### Does it work on Kubernetes, or with user namespaces?

Neither has been tested. Nothing in the image depends on Docker itself, but
that is reasoning, not a result.

## Supported features

| Area | Feature | Status | Notes |
| --- | --- | --- | --- |
| Platform | linux/arm64 | Yes | The only supported architecture. |
| Platform | linux/amd64 and others | No | `docker build` stops with an error. |
| Docker | `docker run`, `exec`, `stop`, `kill`, `--init` | Yes | Covered by `test/e2e.sh`. |
| Docker | `-it` interactive terminal | Yes | Prompt, Ctrl-C, Ctrl-D. Ctrl-Z has no effect on the command init started: nothing could resume it. A child of that command that leaves Ctrl-Z at its default is stopped as anywhere else, and resuming it is the command's business. A command stopped by `SIGSTOP` stays stopped until something continues it; `docker stop` does. |
| Docker | `FROM kcontaineros` with shell-form `RUN` / `CMD` | Yes | Uses the built-in `/bin/sh`. |
| Docker | `--read-only`, `--cap-drop ALL`, `--user`, `--security-opt no-new-privileges`, `--memory 8m` | Yes | Tested together. |
| Docker | `--cap-add`, `--privileged` | No effect | Init drops every capability regardless. |
| Lockdown | `no_new_privs`, capability drop, seccomp filter, Landlock run-or-write rule | Yes | See Security. Landlock needs kernel 5.19 or later. |
| Lockdown | Extra program directories | Yes | `ENV KCOS_EXEC=/app:/opt/tool/bin` |
| Lockdown | Devices beyond the standard ones | Yes | `ENV KCOS_DEV=/dev/fuse:/dev/net/tun`, together with `--device`. |
| Lockdown | Sealed image without shell or utilities | Yes | `--target sealed` |
| init | Signal forwarding to the command | Yes | Every catchable signal, sent to the command's PID. |
| init | Graceful stop of shell-form commands | Yes | The shell replaces itself with the last command, so the signal reaches your program. |
| init | Zombie reaping | Yes | Orphans are adopted and reaped. |
| init | Exit status pass-through | Yes | `128 + signal` when the command is killed. |
| init | Running nested, not as PID 1 | Yes | Adopts orphans, stops what the command left behind, in whatever session or process group (SIGTERM, then SIGKILL after 2 s or as soon as init is signalled itself), hands the terminal back. That means every child it has, also one it inherited from the program that started it. Leftovers that multiply faster than they can be killed are given up on after about 8 s, with a warning; leftovers outside the command's process group are found only when `/proc` is that of init's PID namespace. Started as a background job it leaves the terminal alone. |
| init | Supervising or restarting several services | No | One command; use the shell's `&` and `wait` for more. |
| Binaries | Statically linked | Yes | Tested with Rust on musl and with busybox. Go with `CGO_ENABLED=0` and Zig produce the same kind of binary but are not in the test suite. |
| Binaries | Dynamically linked | No | Copy in the loader and libraries yourself. |
| Shell | Quoting, `$VAR`, `${VAR:-default}`, `$?`, `$$`, `$!`, `$#`, `$-`, `"$@"`, `$*`, `$1`..`$9` | Yes | Every variable is exported. A default may contain further `$` expansions but no quotes and no `$@`. Unquoted expansions are split on whitespace and never globbed; `IFS` cannot be changed. |
| Shell | Pipes, `&&`, `\|\|`, `;`, `&`, `<`, `>`, `>>`, `N>&M`, `N>&-` | Yes | Also on builtins. `a && b &` runs the whole list in the background. A background command reads from `/dev/null`. |
| Shell | `cd exit export unset exec set shift wait umask command :` | Yes | `set` accepts `-e`, `-x` and `-- ARGS`; `umask` octal masks only; `command` is `command -v NAME` or `command NAME ARGS`, not `command exec`. `set` and `export` without operands do not list the variables (use `env`): they are errors. `--` ends a builtin's options. An option a builtin does not have is an error: `export`, `unset`, `set` and `shift` end the script, the others fail and it goes on. `cd -`, `cd -P` and `cd -L` work; `cd` sets `PWD` and `OLDPWD` to the physical directory, as `cd -P` does. `wait PID` returns that command's status. |
| Shell | Script files, `sh -c`, `sh -ec`, commands on stdin | Yes | `#!/bin/sh` scripts run, and so does an executable text file without a `#!` line. Quoted strings, pipelines and `&&` lists may span lines. A script on stdin stops at its first syntax error. |
| Shell | `if` / `for` / `while` / `case`, functions, `{ }`, `!`, `$(…)`, backticks, here-documents | No | Syntax error; nothing in the script runs. |
| Shell | `trap`, `eval`, `read`, `.`, `return`, `local`, `readonly`, `alias`, `getopts`, `ulimit`, `type`, `set -u`, `set -o` | No | Syntax error; nothing in the script runs. |
| Shell | `${VAR:?}`, `${VAR:=x}`, `${VAR:+x}`, `${#VAR}`, `${VAR%x}`, `${VAR#x}` and the other `${…}` operators | No | Syntax error; nothing in the script runs. |
| Shell | Globbing (`*`, `?`, `[`) and `~` | No | Syntax error when unquoted; quote them to pass them literally. |
| Shell | `&>file`, `$'…'` | No | Syntax error; write `>file 2>&1`. |
| Shell | `[` and `test` | No | There is no such command. |
| Utilities | `cat chmod chown cp echo env false kill ln ls mkdir mv ps pwd rm sleep touch true uname` | Yes | Common flags only, such as `ls -la`, `rm -rf`, `mkdir -p`, `ln -s`, `chown UID:GID`, `env -i -u NAME NAME=value command`, `echo -ne`, `kill -s TERM`, `sleep 1.5`, `sleep 2m`, `sleep infinity`. `--` ends options; an unknown option is an error, for the tools without options (`cat`, `sleep`) too. `uname` takes one option. `mv` does not cross filesystems. |
| Utilities | `cp -r`, `chmod u+x`, `grep`, `sed`, `tar`, `wget` and the rest | No | |
| System | Package manager | No | Add files with `COPY`. |
| System | CA certificates, timezone data, `/etc/services` | No | Copy them in if needed. |
| System | Users | Partly | `root` and `nobody` in `/etc/passwd`; no `adduser`. The default user is `nobody`. |
| System | Booting on bare metal or in a VM | No | It is a userland; the kernel comes from the container runtime. |

## Compared with Alpine

Alpine is the usual small base image, so it is the natural reference. Both
were measured on the same machine: Alpine 3.24.4 and kContainerOS 1.0.0 on
Docker 29.9.3, linux/arm64.

| | kContainerOS | Alpine 3.24 |
| --- | --- | --- |
| Image size (`docker images`) | 246 kB | 13.6 MB |
| Root filesystem layer | 184 kB | 9.31 MB |
| Userland | one 95 kB Rust binary | busybox, 919 kB |
| Utilities | 19, plus `sh` and `init` | 304 busybox applets |
| C library | none | musl, 723 kB |
| Package manager | none | `apk`, 16 packages installed |
| Shell | partial, see the table above | full POSIX `ash` |
| Dynamically linked binaries | no | yes, against musl |
| CA certificates | no | yes |
| Timezone data | no | no, `apk add tzdata` |
| PID 1 by default | `/sbin/init`, then your command | your command itself |
| `docker stop` on `sleep 300` | 0.11 s, exit 143 | 3.2 s, exit 137 |
| `docker run --rm IMAGE true`, 7 runs | 170 to 192 ms | 172 to 258 ms |
| Architectures | arm64 | arm64, amd64 and six more |

What the numbers mean:

- **Size.** kContainerOS is more than 50 times smaller. Either way the base is
  small next to most applications, so this matters most when you ship many
  images or pull on slow links.
- **Stopping.** On Alpine the command is PID 1, and the kernel does not
  deliver `SIGTERM` to a PID 1 that has no handler for it. Docker waits, then
  sends `SIGKILL` (exit 137). The wait was 3.2 s with this Docker's default
  and 10.2 s with `-t 10`. kContainerOS forwards the signal, so the command
  exits at once. `docker run --init` gives Alpine the same behaviour.
- **Startup.** The difference is within noise. Starting a container is
  dominated by Docker, not by the image.

Choose kContainerOS when you ship a static binary and want nothing else in
the image. Choose Alpine when you need packages, a full shell, dynamically
linked programs, another architecture, or a distribution with security
updates and a community behind it.

## Tests and coverage

`make test` builds the image and runs the end-to-end checks in
`test/suite.sh` against the local Docker daemon. It needs an ARM64 host,
bash, python3 and curl. Checks compare complete output and the exit status
wherever they can, so a command that fails cannot pass by printing nothing. Shell-language cases live in `test/cases/` as a script and
its expected output.

`make coverage` runs the same checks against an instrumented build, prints a
per-file report with every uncovered line, and fails below 99% line
coverage.

How the measurement works, and what it leaves out:

- The instrumented build compiles the same sources against `std`, because
  LLVM's profiling runtime needs a C library. Each process writes its
  counters when it exits or execs.
- A few lines can never be counted: the ones that run after a process has
  written its counters.
- The start-up code exists only in the real build and cannot be
  instrumented: `_start`, the self-relocation routine and the panic handler.
  Every check in `make test` runs through it, since it starts every process.
- The sealed image is tested by `make test` only; its build has no shell or
  utilities to instrument.

## Limits

- **Binaries must be statically linked** (Rust on musl, Go with `CGO_ENABLED=0`,
  Zig, …). There is no libc or dynamic loader; a dynamically linked binary
  needs its loader and libraries copied in.
- **No CA certificates or timezone data.** Copy them in if your program makes
  TLS connections or needs local time.
- **The shell is not POSIX-complete.** It has no control flow, functions,
  globbing, `$(…)`, here-documents, `trap` or `read`, and no `[`. Existing entrypoint scripts
  that use them stop with a syntax error before doing anything. Copy in
  another shell if a script needs more.
- It is a container userland, not a bootable OS: the kernel comes from the
  container runtime.

## Layout

```
src/sys.rs        raw aarch64 syscalls
src/lock.rs       the lockdown: no_new_privs, Landlock, seccomp filter, capabilities
src/init.rs       PID 1
src/sh.rs         shell
src/applets.rs    core utilities
src/util.rs       shared helpers
src/main.rs       entry point (_start), self-relocation, dispatch on argv[0], allocator
tools/mkrootfs.sh assembles the image's root filesystem
test/e2e.sh       test runner; test/suite.sh holds the checks, test/cases/ the shell scripts
test/term.py      test helper that drives a command through a terminal
test/elf.py       test helper that reads the hardening properties off the binary
test/probe.rs     test helper that issues the system calls the filter must refuse
docs/             the site at kcos.21no.de: index.html, 404.html, share image, _headers,
                  robots.txt, sitemap.xml, llms.txt
wrangler.jsonc    Cloudflare configuration that serves docs/
AGENTS.md         how to change the project: rules, checks, release steps
AUDIT.md          summary of the security audit
audit/            the audit itself: method, findings, harnesses to run it again
tools/update-docs.sh  re-embeds the built binary into docs/index.html and redraws it in the
                  share image (tools/update-og.py); run it after a rebuild
```

## The site

`docs/` is the landing page at <https://kcos.21no.de>, served by Cloudflare
Workers static assets as configured in `wrangler.jsonc`. A push to `main`
deploys it.

```sh
make site-preview   # npx wrangler dev: serve docs/ locally, headers included
make site-deploy    # deploy by hand: build, re-embed the binary, npx wrangler deploy
```

- `docs/_headers` sets the Content-Security-Policy and the other response
  headers. The page makes no request outside its own origin except for the
  fonts on `assets.21no.de`.
- Unknown paths get `docs/404.html` with status 404.
- After rebuilding the image, run `tools/update-docs.sh` and commit the
  result before pushing, so the page embeds the binary you built.
  `make site-deploy` runs it and refuses to publish a page that the script
  had to change.

## License

MIT, copyright 21no.de. See [LICENSE](LICENSE).
