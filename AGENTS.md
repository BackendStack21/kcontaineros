# Working on kContainerOS

For people and coding agents changing this repository. The README says what
the project does and promises; this file says how to change it without
breaking those promises.

## What you are working on

One freestanding Rust binary (`no_std`, no libc, no crates) for
linux/arm64 that is PID 1, a small shell and the core utilities, picked by
`argv[0]`. It is shipped as a Docker image of that binary plus four files
in `/etc`.

```
src/main.rs     _start, self-relocation, dispatch on argv[0], allocator
src/sys.rs      every system call, through the single function sc()
src/lock.rs     the lockdown: no_new_privs, Landlock, seccomp filter, capabilities
src/init.rs     PID 1
src/sh.rs       shell
src/applets.rs  utilities
src/util.rs     shared helpers
tools/          mkrootfs.sh (image contents), update-docs.sh and update-og.py (site)
test/           e2e.sh runs suite.sh against real containers; cases/ are shell scripts
docs/           the landing page served at kcos.21no.de
```

Three builds come out of the same sources: the full image, the sealed image
(`--no-default-features`: init only) and the coverage build (`--features
cov`, against `std`, never shipped). A change has to compile in all three.

## Rules that are not negotiable

- **No dependencies.** `Cargo.toml` has no `[dependencies]` and stays that
  way. `core` and `alloc` only.
- **ARM64 Linux only.** Syscall numbers, struct layouts and the seccomp
  filter are written for aarch64.
- **Init never allocates and installs no signal handler.** It consumes
  signals with `rt_sigtimedwait`. Code reachable from `init::run` and from
  `lock.rs` uses the stack and fixed buffers. `util::eprint` is shared with
  init and must not allocate either.
- **Every system call goes through `sys::sc`.** Add a wrapper in `sys.rs`
  with the syscall number in `mod nr`; say in a comment what the kernel
  struct looks like if you pass one.
- **Fail closed in the lockdown.** If the filter cannot be installed, init
  does not start the command. A Landlock rule that cannot be added grants
  nothing. Never follow a symbolic link when attaching a rule.
- **Correct or loud, never silently different.** The shell implements a
  subset of POSIX sh. Anything outside it is a syntax error found before the
  first command runs, not something run as something else. Whether a script
  is valid must not depend on the value of a variable. The same goes for
  utility options: an option a tool does not have is an error.
- **Nothing untrusted reaches a terminal raw.** File names, arguments and
  process names are shown through `Out::safe` or `eprint`, which replace
  everything but printable ASCII when the output is a terminal.
- **The binary stays under 100 kB.** The suite checks it. The release
  profile is `opt-level = "z"`; look at what a change costs.

## Build and test

Docker on an ARM64 host, bash, python3 and curl are needed. There is no
host-side `cargo build`; everything is built inside Docker.

```sh
make build       # docker build --platform linux/arm64 -t kcontaineros .
make test        # test/e2e.sh: builds the image and runs every check
make coverage    # the same checks on an instrumented build; fails under 99% lines
IMG=kcos-wip test/e2e.sh   # test under another image name, leaving kcontaineros alone
```

A quick look at one behaviour does not need the suite:

```sh
docker build --platform linux/arm64 -t kcos-wip .
docker run --rm kcos-wip sh -c '...'                      # under init, as nobody
docker run --rm --entrypoint /bin/sh kcos-wip -c '...'    # the shell alone, no Landlock
python3 test/term.py 'echo hi\n' '\x03' -- docker run -it --rm kcos-wip   # through a terminal
```

The built-in shell has no loops, globs or `$(…)`. To set something up, the
suite adds a static busybox at `/bb` (with `ENV KCOS_EXEC=/bb`) and drives
it with `/bb/busybox sh`, calling the tools under test as `/bin/NAME`.

## Writing checks

Checks live in `test/suite.sh`, which `test/e2e.sh` sources after defining
the helpers (`expect`, `x`, `t`, `tu`, `k`, `bb`, `run`, `typed`; each is
described where it is defined). Shell-language cases that fit one script go
in `test/cases/NAME.sh` with the expected output in `NAME.out`.

- Compare the complete output and the exit status. A check that greps for
  one word passes when everything else is wrong.
- Name the check after the behaviour, as a sentence that is true when it
  passes.
- For anything the lockdown refuses, add the control: the same attempt
  without init (`--entrypoint`), where it must succeed. A refusal with no
  control proves nothing about init.
- Never write to a kernel file or a device to see whether it is allowed.
  Open it for appending and close it (`true >> /proc/sys/...`): if the check
  ever regresses, nothing on the machine running the tests may change. Do
  not open hypervisor sockets or block devices in a control run.
- Keep host specifics out: no fixed device names that only exist on one
  kind of host, no sizes or PIDs that depend on the runtime where it can be
  avoided.
- New code needs checks that reach it; `make coverage` lists every
  uncovered line and fails below 99%.

## Changing the lockdown

`lock.rs` is the part where a mistake is a hole. Before changing it:

- Read the Security section of the README. Every row there is a claim that
  a check in `test/suite.sh` holds the image to, as root under
  `--privileged` with Docker's own filter off. Change the claim, the code
  and the check together.
- Landlock can only add permissions, never subtract. The ruleset is built
  from what is mounted when init starts: program directories get execute,
  other top-level directories get write, `/dev` is an allowlist, and `/proc`
  and `/sys` are not writable for root. Think about what a new rule grants
  to root, who owns the kernel's files, and to a user whom a device's
  permissions admit.
- The seccomp program is classic BPF assembled by hand in `install_filter`.
  Jump offsets are counted in instructions; a clause that loads an argument
  must end in a return on every path, because the accumulator no longer
  holds the syscall number. Update the size of `prog` when adding
  instructions. New syscall numbers above `NEWEST_KNOWN` are answered
  `ENOSYS` until someone has looked at them.
- Try to break it afterwards, from inside a container, with a static probe
  (`test/probe.rs`) or busybox.

## Changing the shell or a utility

- Decide first whether the feature is in or out. In: implement it as POSIX
  has it and compare against `busybox sh` on real scripts. Out: make it a
  syntax error in `check()`, with a message that names the construct.
- The shell parses and expands each pipeline right before running it;
  `check()` runs the same parser over the whole script first. Keep the two
  in agreement: nothing may pass `check()` and then fail to parse.
- Applets return an exit status and report errors through `fail()`. An
  applet whose output cannot be written exits 1 (`util::output_failed`).
- A new applet goes into `applets::LIST`; `tools/mkrootfs.sh` reads the
  list to create the symlinks, and the suite's `APPLETS` and file listing
  need the name too.

## Documentation

The README, `docs/index.html` and `docs/llms.txt` describe how things work
today. No changelog, no "was fixed", no account of how a behaviour came
about. They must agree with each other and with the image:

- Change a behaviour, and the three change in the same commit.
- A number (sizes, counts) is measured, not estimated.
- A terminal session shown on the page is one that the image produces.
- Say what the lockdown does not do as plainly as what it does.

`tools/update-docs.sh` regenerates what is derived: the copy of the binary
embedded in the page, the FAQ structured data (from the visible questions)
and the picture of the binary in `docs/og.png`. Run it after rebuilding the
image and after editing the questions; running it twice changes nothing.

## Releasing

1. Set the version in `Cargo.toml` and `Cargo.lock`. `tools/mkrootfs.sh`
   puts it into `/etc/os-release`; the suite's `--version` checks and the
   "Compared with Alpine" paragraph of the README name it too.
2. `make test` and `make coverage`, both green.
3. `make build`, then `tools/update-docs.sh`. Re-measure the sizes in the
   README table if the binary changed (`docker images`, `docker history`,
   `wc -c` on the binary).
4. Commit, push `main`, tag `vX.Y.Z`, push the tag.
5. `make site-deploy` publishes the page. It rebuilds, runs
   `tools/update-docs.sh` and refuses to deploy while `docs/` differs from
   the last commit.

## Housekeeping

- The suite names what it creates `kcos-…-$$` and removes it on exit. If a
  run is killed, `docker ps -a --filter name=kcos-` shows what is left.
- Repeated builds fill Docker's disk. When non-root containers start
  failing with "no space left on device", that is the cause, not the image.
- Do not commit `target/`, `__pycache__/` or editor files; `.gitignore` and
  `.dockerignore` list them.
