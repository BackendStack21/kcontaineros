# Security audit: summary

kContainerOS 0.2.0 was put through an end-to-end security audit on
22 November 2026. What it found is fixed in 1.0.0. This is the summary; the
method, every finding with its reproduction, and the harnesses to run the
audit again are in [`audit/`](audit/README.md).

## Read this first

The audit was designed and carried out by an AI model (Claude), which also
wrote most of the code it audited. **No independent party has reviewed this
image.** To make up for that as far as a design can:

- each of the ten tracks was given to an auditor that knew nothing of how
  the code had been written or reviewed, and was told to trust only what a
  real container does;
- what could be established mechanically was: the system call filter was
  read back from the kernel and evaluated for every call number, the shell
  was compared with another shell on generated scripts, and the test suite
  was run against deliberately broken copies of the lockdown;
- every finding had to be reproduced by a second reviewer whose task was to
  refute it.

It ran on one host: Docker Desktop on macOS arm64, Linux 7.0.14, Landlock
ABI 8.

## What was examined

| Track | Question |
| --- | --- |
| seccomp | Is the filter in the kernel the intended one, with no way round it? |
| landlock | Who can read, write, run and control what, and can the rules be tricked while they are built? |
| escape-root | Can root in a `--privileged` container, with Docker's own protections off, get past the lockdown? |
| escape-user | Can the default user, in the ways the image is really run? |
| init | Does PID 1 stay correct under signals, floods, orphans and failures? |
| shell | Does the shell either do what POSIX says or refuse? |
| utils | Are the utilities safe on hostile file trees and under races? |
| memory | Do the `unsafe` code, the entry code and the allocator hold their contracts? |
| supply | Is what ships what the sources say, and is the build reproducible? |
| claims | Is every claim in the documents true, and does the test suite notice a broken lockdown? |

## What it found

**No way out of the container, and no way to gain privilege past the
lockdown.** The system call filter held completely: the program in the
kernel is the one in the source, every documented refusal is real, and no
other call reaches the same effect.

64 findings were reported; 53 were reproduced as defects.

| Severity | Meaning | Count |
| --- | --- | --- |
| critical | escape, or privilege past the lockdown | 0 |
| high | a documented security claim was false | 3 |
| medium | integrity or availability, or misleading security documentation | 7 |
| low | functional | 30 |
| info | | 13 |

The three high findings, all fixed:

1. **A device that was not named could be driven with `ioctl`.** Opened for
   neither reading nor writing, it asked Landlock for nothing. The device
   `ioctl` right is now handled (Linux 6.10 and later; the limit on older
   kernels is documented).
2. **Naming one device of a subdirectory of `/dev` in `KCOS_DEV` made the
   others in it readable.** An entry now accounts only for the node it
   names.
3. **`rm -r DIR/` could be sent elsewhere** by swapping the directory for a
   symbolic link during the call, because a trailing slash makes the kernel
   follow the link. It lost files in 30 of 300 rounds before the fix and in
   none of 600 after.

Among the medium findings: a backslash-newline inside a word hid shell
keywords from the syntax check; an ignored `KCOS_EXEC` entry left its
directory writable; the README overstated what root is kept from reading.

Two findings were about the project's own assurances:

- **The test suite missed 9 of 16 deliberate breakages of the lockdown**,
  for instance `/sys` writable for root, and files removable from program
  directories. It now calls every system call on the filter's list, and
  attacks program directories by truncation, removal and linking, each
  with a control run without init.
- **The suite changed the machine it ran on**: a control run set the clock
  of the Docker VM. It no longer does, and its checks no longer depend on
  timing.

## What was done

| Outcome | Findings |
| --- | --- |
| Fixed, in the code or the test suite | 43 |
| Corrected in the documents | 7 |
| Accepted as it is | 3 |
| Open | 1 |
| No change needed (not a defect, or already documented) | 10 |

The test suite grew from 459 to 504 checks. Every finding, with what was
done about it, is listed in [`audit/README.md`](audit/README.md).

## What is still open

- Some of the suite's terminal checks compare selected lines of a session,
  not the whole of it.
- The limits stated in the README's Security section stand: among them
  code a process maps into its own memory, `/proc/PID/mem` between
  processes of one user, what root can still read in `/proc` and `/sys`,
  and `docker exec` starting outside init.
- Not covered: other kernels and Landlock versions, a Linux host with
  native bind mounts, Kubernetes, user-namespace remapping, gVisor or Kata
  as runtime, and the kernel itself.
