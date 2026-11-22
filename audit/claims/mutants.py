#!/usr/bin/env python3
"""Mutant definitions for audit/claims/mutants.sh.

  mutants.py list                 names, one per line
  mutants.py apply NAME DIR       apply mutant NAME to the source copy in DIR
                                  and print the unified diff

Each mutant is one (file, old, new) replacement, or a list of them; `old` must occur exactly once.
"""
import difflib, sys, pathlib

M = {
 "m0": None,  # baseline: unmodified sources
 "m0b": None, "m0c": None,  # the baseline again, to tell flaky checks from kills
 # drop one syscall from DENIED ("writing another process's memory")
 "m1": ("src/lock.rs", "    271, // process_vm_writev\n", ""),
 # skip the AF_VSOCK clause (compare the family with a value no family has)
 "m2": ("src/lock.rs", "ins(JEQ, 0, 1, AF_VSOCK),", "ins(JEQ, 0, 1, 0xffff),"),
 # /sys stays writable for root
 "m3": ("src/lock.rs", 'let kernel = root && matches!(name, b"proc" | b"sys");',
                       'let kernel = root && matches!(name, b"proc");'),
 # follow symbolic links when attaching a rule
 "m4": ("src/lock.rs", "let dir_flags = sys::O_PATH | sys::O_DIRECTORY | sys::O_NOFOLLOW | sys::O_CLOEXEC;",
                       "let dir_flags = sys::O_PATH | sys::O_DIRECTORY | sys::O_CLOEXEC;"),
 # PID 1 stays dumpable
 "m5": ("src/lock.rs", "    sys::prctl(PR_SET_DUMPABLE, 0);\n", ""),
 # truncation is not handled by the ruleset (files in program directories can be truncated)
 "m6": ("src/lock.rs", "let truncate = if abi >= 3 { FS_TRUNCATE } else { 0 };", "let truncate = 0 * abi as u64;"),
 # /dev/shm: writable and executable
 "m7": ("src/lock.rs", 'allow(ruleset, b"/dev/shm", read | write);', 'allow(ruleset, b"/dev/shm", read | write | FS_EXECUTE);'),
 # removing files is not handled by the ruleset (LANDLOCK_ACCESS_FS_REMOVE_FILE, bit 5)
 "m8": ("src/lock.rs", "const FS_WRITE: u64 = 1 << 1 | 0x1ff << 4;", "const FS_WRITE: u64 = 1 << 1 | 0x1fd << 4;"),
 # --- four more, beyond the eight asked for
 # a filter that cannot be installed is not fatal
 "m9": ("src/lock.rs", "    if !install_filter(probe) {", "    if false && !install_filter(probe) {"),
 # nested init does not SIGKILL what ignores SIGTERM
 "m10": ("src/init.rs", "if signal_leftovers(child, SIGKILL) && now - killing_since < GIVE_UP_MS {", "if false && now - killing_since < GIVE_UP_MS {"),
 # a symbolic link named in KCOS_DEV is taken for a device
 "m11": ("src/lock.rs", 'device.starts_with(b"/dev/") && !is_type(device, 0o120000) && allow_path', 'device.starts_with(b"/dev/") && allow_path'),
 # clone() may create every namespace but a user namespace
 "m12": ("src/lock.rs", "const CLONE_NEW_ANY: u32 = 0x7e02_0000;", "const CLONE_NEW_ANY: u32 = 0x1000_0000;"),
 # the calls the suite attacks with busybox tools (mount, chroot, hostname, date) leave the refusal list
 "m13": [("src/lock.rs", "    40,  // mount\n", ""), ("src/lock.rs", "    51,  // chroot\n", ""),
         ("src/lock.rs", "    161, // sethostname\n", ""), ("src/lock.rs", "    112, // clock_settime\n", ""),
         ("src/lock.rs", "    170, // settimeofday\n", "")],
}

def main():
    if sys.argv[1] == "list":
        print("\n".join(M)); return
    name, root = sys.argv[2], pathlib.Path(sys.argv[3])
    if M[name] is None:
        print("(baseline, no change)"); return
    edits = M[name] if isinstance(M[name], list) else [M[name]]
    before = {}
    for f, old, new in edits:
        p = root / f
        src = p.read_text()
        before.setdefault(f, src)
        if src.count(old) != 1:
            sys.exit(f"{name}: pattern occurs {src.count(old)} times in {f}")
        p.write_text(src.replace(old, new))
    for f, src in before.items():
        out = (root / f).read_text()
        sys.stdout.writelines(difflib.unified_diff(src.splitlines(True), out.splitlines(True), "a/" + f, "b/" + f, n=1))

main()
