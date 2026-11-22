//! Restrictions a kContainerOS process puts on itself before it does
//! anything else. The kernel enforces them, they are inherited by every
//! descendant, and nothing in userland can lift them again.
//!
//! Every personality (shell, utility, init) applies:
//!
//!   * `no_new_privs`: no setuid binary or file capability ever grants more.
//!   * seccomp: the system calls that exist to reconfigure the kernel, to
//!     reach into other processes or to create namespaces are refused.
//!
//! Init, which is what a container starts with, applies two more to itself
//! and so to the command it runs:
//!
//!   * Landlock: programs can be executed only from the image's own
//!     directories, and those directories cannot be written to. Whatever
//!     can be written (/tmp, a volume, a memory file) cannot be executed.
//!   * No capabilities (`drop_capabilities`), whatever `docker run` was told.
//!
//! None of this needs privilege, so it holds for root and non-root alike.
//!
//! A shell or utility started outside init (a `RUN` step of a build,
//! `docker exec`) keeps whatever capabilities it was given and is not
//! confined by Landlock: build steps have to be able to write the image.

use crate::sys;
use crate::util::{cstr, eprint};

const PR_SET_DUMPABLE: usize = 4;
const PR_CAPBSET_DROP: usize = 24;
const PR_SET_NO_NEW_PRIVS: usize = 38;
const PR_CAP_AMBIENT: usize = 47;
const PR_CAP_AMBIENT_CLEAR_ALL: usize = 4;

/// prctl operations that do not exist. The filter answers them with
/// EALREADY, which is how a process learns that an ancestor has already
/// locked it down (`PROBE`), or locked it down as init does (`PROBE_FULL`),
/// and that another layer would add nothing.
const PROBE: u32 = 0x4b43_4f53; // "KCOS"
const PROBE_FULL: u32 = 0x4b43_4f46; // "KCOF"
const EALREADY: u32 = 114;
const EPERM: u32 = 1;
const ENOSYS: u32 = 38;

/// `full` is what init asks for: also confine the filesystem.
pub unsafe fn lockdown(envp: *const *const u8, full: bool) {
    let probe = if full { PROBE_FULL } else { PROBE };
    if sys::prctl(probe as usize, 0) == -(EALREADY as isize) {
        return;
    }
    sys::prctl(PR_SET_NO_NEW_PRIVS, 1);
    if full && !confine_files(envp) {
        eprint(&[b"kcontaineros: warning: Landlock is unavailable, so programs can be run from any path\n"]);
    }
    if !install_filter(probe) {
        // Without the filter the guarantees above do not hold: do not run.
        eprint(&[b"kcontaineros: cannot install the system call filter\n"]);
        sys::exit(125);
    }
}

// ----------------------------------------------------------------- Landlock

const FS_EXECUTE: u64 = 1 << 0;
const FS_WRITE_FILE: u64 = 1 << 1;
const FS_READ_FILE: u64 = 1 << 2;
/// The device nodes a program may open; see `confine_files`.
const DEVICES: [&[u8]; 9] = [
    b"/dev/null",
    b"/dev/zero",
    b"/dev/full",
    b"/dev/random",
    b"/dev/urandom",
    b"/dev/tty",
    b"/dev/console",
    b"/dev/ptmx",
    b"/dev/termination-log", // a file Kubernetes mounts for the container
];
/// Writing to files, and creating or removing anything in a directory.
const FS_WRITE: u64 = 1 << 1 | 0x1ff << 4;
/// Moving or linking a file into another directory.
const FS_REFER: u64 = 1 << 13;
const FS_TRUNCATE: u64 = 1 << 14;

/// Programs may be executed from these directories, and from those listed
/// in `KCOS_EXEC` (colon-separated absolute paths) by whoever built or
/// started the container. The top-level directory each one lives in can
/// no longer be written to: a place is for running or for writing, not both.
const EXEC_DIRS: &[u8] = b"/bin:/sbin:/usr";

/// The usable entries of a colon-separated list: absolute, not `/` itself,
/// and with no empty, `.` or `..` component. Anything else could name the
/// whole filesystem, or a writable place under another name.
fn absolute_dirs(list: &[u8]) -> impl Iterator<Item = &[u8]> {
    list.split(|&c| c == b':').filter(|d| {
        d.first() == Some(&b'/')
            && d[1..].split(|&c| c == b'/').all(|part| !matches!(part, b"" | b"." | b".."))
    })
}

unsafe fn confine_files(envp: *const *const u8) -> bool {
    // Version 2 is the first that can allow renames across directories;
    // version 1 would refuse every one of them.
    let abi = sys::landlock_abi();
    if abi < 2 {
        return false;
    }
    // The first of each, as getenv(3) would find it.
    let (mut extra, mut devices): (Option<&[u8]>, Option<&[u8]>) = (None, None);
    let mut e = envp;
    while !(*e).is_null() {
        let var = cstr(*e);
        if extra.is_none() {
            extra = var.strip_prefix(b"KCOS_EXEC=");
        }
        if devices.is_none() {
            devices = var.strip_prefix(b"KCOS_DEV=");
        }
        e = e.add(1);
    }
    let (extra, devices) = (extra.unwrap_or(b""), devices.unwrap_or(b""));
    // An entry that is not a plain absolute path is dropped, and said so.
    for (name, list) in [(&b"KCOS_EXEC"[..], extra), (b"KCOS_DEV", devices)] {
        for entry in list.split(|&c| c == b':').filter(|e| !e.is_empty()) {
            if !absolute_dirs(entry).any(|_| true) {
                eprint(&[b"kcontaineros: warning: ", name, b": ", entry, b" is not a plain absolute path: ignored\n"]);
            }
        }
    }

    // Reading is confined only when /dev holds more than a container's
    // usual devices (--privileged, --device): a disk of the host can be
    // read by anyone its permissions admit, and Landlock is what is left to
    // say no. Otherwise reads stay as they are, because some filesystems
    // (host directories shared by Docker Desktop) cannot be matched by any
    // rule and would become unreadable for nothing.
    let read = if unusual_devices(devices) { FS_READ_FILE } else { 0 };
    let truncate = if abi >= 3 { FS_TRUNCATE } else { 0 };
    let write = FS_WRITE | truncate;
    // What a rule on a single file, or on a device, can carry.
    let file = read | FS_WRITE_FILE | truncate;
    let ruleset = sys::landlock_create_ruleset(&(FS_EXECUTE | FS_REFER | read | write));
    if ruleset < 0 {
        return false;
    }
    let ruleset = ruleset as i32;

    let root = sys::geteuid() == 0;
    allow(ruleset, b"/", FS_REFER);
    for dir in absolute_dirs(EXEC_DIRS) {
        allow(ruleset, dir, FS_EXECUTE);
    }
    for dir in absolute_dirs(extra) {
        // Not where the kernel keeps its own files: /dev/shm has to stay
        // writable, and so could then be run from.
        let kernel = [&b"/dev"[..], b"/proc", b"/sys"]
            .iter()
            .any(|k| dir.starts_with(k) && matches!(dir.get(k.len()), None | Some(b'/')));
        if kernel {
            eprint(&[b"kcontaineros: warning: KCOS_EXEC: ", dir, b" cannot hold programs: ignored\n"]);
        } else if !allow(ruleset, dir, FS_EXECUTE) {
            eprint(&[b"kcontaineros: warning: KCOS_EXEC: ", dir, b" is not a directory (symbolic links are not followed): ignored\n"]);
        }
    }
    // Everything at the top level can be read, and what holds no programs
    // can be written, with two exceptions.
    let slash = sys::open(b"/\0".as_ptr(), sys::O_RDONLY | sys::O_DIRECTORY | sys::O_CLOEXEC, 0) as i32;
    let mut buf = [0u8; 4096];
    loop {
        let n = sys::getdents(slash, &mut buf);
        if n <= 0 {
            break;
        }
        let mut p = 0;
        while p < n as usize {
            // struct linux_dirent64 { u64 ino; i64 off; u16 reclen; u8 type; char name[]; }
            let reclen = u16::from_ne_bytes([buf[p + 16], buf[p + 17]]) as usize;
            let mut path = [b'/'; 258];
            let name = cstr(buf.as_ptr().add(p + 19));
            path[1..1 + name.len()].copy_from_slice(name);
            let top = &path[..1 + name.len()];
            p += reclen;
            // /dev is handled below: under --privileged it holds the host's
            // disks, and their permissions admit more than root.
            if matches!(name, b"." | b".." | b"dev") {
                continue;
            }
            // "/usr" holds programs if an exec directory is it or is inside it.
            let holds_programs = absolute_dirs(EXEC_DIRS)
                .chain(absolute_dirs(extra))
                .any(|d| d.starts_with(top) && matches!(d.get(top.len()), None | Some(b'/')));
            // The files of /proc and /sys belong to root, so with every
            // capability gone the owner's write permission would still
            // reach /proc/sys or the sysrq trigger. Not for root, then.
            let kernel = root && matches!(name, b"proc" | b"sys");
            let access = read | if holds_programs || kernel { 0 } else { write };
            // A directory, or else a single file mounted at the top level.
            // (A regular one: a device node mapped there is not a file to
            // hand out by default.)
            if access != 0 && !allow(ruleset, top, access) && is_regular_file(top) {
                allow_path(ruleset, top, access & file, false);
            }
        }
    }
    sys::close(slash);
    // What every program expects of /dev, what the container was started
    // with in KCOS_DEV, and nothing else in it.
    for device in DEVICES {
        allow_path(ruleset, device, file, false);
    }
    allow(ruleset, b"/dev/pts", file);
    allow(ruleset, b"/dev/shm", read | write);
    if read != 0 {
        allow(ruleset, b"/dev/mqueue", read);
    }
    for device in absolute_dirs(devices) {
        if !(device.starts_with(b"/dev/") && !is_type(device, 0o120000) && allow_path(ruleset, device, file, false)) {
            eprint(&[b"kcontaineros: warning: KCOS_DEV: ", device, b" is not a device in /dev (symbolic links are not followed): ignored\n"]);
        }
    }

    let applied = sys::landlock_restrict_self(ruleset) == 0;
    sys::close(ruleset);
    applied
}

fn is_regular_file(path: &[u8]) -> bool {
    is_type(path, 0o100000)
}

/// True if `path` itself (a link is not followed) has file type `kind`,
/// one of the S_IF constants.
fn is_type(path: &[u8], kind: u16) -> bool {
    let mut z = [0u8; 4096];
    if path.len() >= z.len() {
        return false;
    }
    z[..path.len()].copy_from_slice(path);
    let mut st = [0u8; 256];
    // statx: mode is a u16 at offset 28; S_IFMT is 0o170000.
    sys::statx(z.as_ptr(), true, &mut st) == 0 && u16::from_ne_bytes([st[28], st[29]]) & 0o170000 == kind
}

/// True if /dev holds anything beyond what Docker puts in every container
/// and what `KCOS_DEV` names, or cannot be listed at all.
fn unusual_devices(named: &[u8]) -> bool {
    const USUAL: [&[u8]; 18] = [
        b".", b"..", b"null", b"zero", b"full", b"random", b"urandom", b"tty", b"console", b"ptmx",
        b"pts", b"shm", b"mqueue", b"fd", b"stdin", b"stdout", b"stderr", b"core",
    ];
    let dev = sys::open(b"/dev\0".as_ptr(), sys::O_RDONLY | sys::O_DIRECTORY | sys::O_CLOEXEC, 0);
    if dev < 0 {
        return true;
    }
    let mut buf = [0u8; 4096];
    let mut unusual = false;
    loop {
        let n = sys::getdents(dev as i32, &mut buf);
        if n <= 0 {
            unusual |= n < 0;
            break;
        }
        let mut p = 0;
        while p < n as usize {
            // struct linux_dirent64 { u64 ino; i64 off; u16 reclen; u8 type; char name[]; }
            let reclen = u16::from_ne_bytes([buf[p + 16], buf[p + 17]]) as usize;
            let name = unsafe { cstr(buf.as_ptr().add(p + 19)) };
            // "/dev/net/tun" in KCOS_DEV accounts for the entry "net".
            let is_named = absolute_dirs(named).any(|d| {
                d.strip_prefix(b"/dev/")
                    .is_some_and(|rest| rest.starts_with(name) && matches!(rest.get(name.len()), None | Some(b'/')))
            });
            unusual |= !(USUAL.contains(&name) || name == b"termination-log" || is_named);
            p += reclen;
        }
    }
    sys::close(dev as i32);
    unusual
}

/// Grant `access` beneath `dir`, an absolute path. It is walked one
/// component at a time without following symbolic links, so a link can
/// never make a rule land on a directory other than the one named: `/lib`
/// pointing into `/usr` must not make `/usr/lib` writable. A path that is
/// missing, is not a directory or leads through a link grants nothing;
/// returns whether a rule was added.
fn allow(ruleset: i32, dir: &[u8], access: u64) -> bool {
    allow_path(ruleset, dir, access, true)
}

/// `allow` for a path whose last component may be a file (`is_dir` false):
/// a device node, which takes only the rights that make sense for a file.
fn allow_path(ruleset: i32, path: &[u8], access: u64, is_dir: bool) -> bool {
    let dir_flags = sys::O_PATH | sys::O_DIRECTORY | sys::O_NOFOLLOW | sys::O_CLOEXEC;
    let mut fd = sys::open(b"/\0".as_ptr(), dir_flags, 0);
    let mut parts = path.split(|&c| c == b'/').filter(|part| !part.is_empty()).peekable();
    while let Some(part) = parts.next() {
        if fd < 0 {
            break;
        }
        let flags = if is_dir || parts.peek().is_some() { dir_flags } else { dir_flags & !sys::O_DIRECTORY };
        let mut name = [0u8; 256];
        let next = if part.len() < name.len() {
            name[..part.len()].copy_from_slice(part);
            sys::openat(fd as i32, name.as_ptr(), flags, 0)
        } else {
            -36
        };
        sys::close(fd as i32);
        fd = next;
    }
    if fd < 0 {
        return false;
    }
    // struct landlock_path_beneath_attr, packed: u64 rights, i32 fd.
    let mut rule = [0u8; 12];
    rule[..8].copy_from_slice(&access.to_ne_bytes());
    rule[8..].copy_from_slice(&(fd as i32).to_ne_bytes());
    let added = sys::landlock_add_rule(ruleset, &rule) == 0;
    sys::close(fd as i32);
    added
}

// ------------------------------------------------------------------ seccomp

// Classic BPF, as seccomp runs it: struct sock_filter { u16 code; u8 jt;
// u8 jf; u32 k; }, here packed into a u64.
const fn ins(code: u16, jt: u8, jf: u8, k: u32) -> u64 {
    code as u64 | (jt as u64) << 16 | (jf as u64) << 24 | (k as u64) << 32
}
const LOAD: u16 = 0x20; // A = 32-bit word at offset k of struct seccomp_data
const JEQ: u16 = 0x15; // if A == k skip jt instructions, else skip jf
const JGT: u16 = 0x25; // if A > k ...
const JSET: u16 = 0x45; // if A & k ...
const RET: u16 = 0x06; // return k

// struct seccomp_data { i32 nr; u32 arch; u64 ip; u64 args[6]; }
const NR: u32 = 0;
const ARCH: u32 = 4;
const ARG0: u32 = 16; // low half; aarch64 is little-endian

const ALLOW: u32 = 0x7fff_0000;
const KILL_PROCESS: u32 = 0x8000_0000;
const fn errno(e: u32) -> u32 {
    0x0005_0000 | e
}
const AUDIT_ARCH_AARCH64: u32 = 0xc000_00b7;

const SYS_PERSONALITY: u32 = 92;
const SYS_PRCTL: u32 = 167;
const SYS_SOCKET: u32 = 198;
const AF_VSOCK: u32 = 40;
const SYS_CLONE: u32 = 220;
const SYS_CLONE3: u32 = 435;

/// The newest system call this filter was written against (removexattrat).
/// Anything a later kernel adds is answered with "not implemented" until
/// someone has looked at it: programs already cope with that on old kernels.
const NEWEST_KNOWN: u32 = 466;

/// clone(2) flags that create a namespace.
const CLONE_NEW_ANY: u32 = 0x7e02_0000;

/// System calls refused with EPERM. Nothing a server needs is here; most
/// also need a capability that PID 1 has already dropped, and the rest are
/// the usual first steps of a kernel exploit or of tampering with another
/// process.
const DENIED: &[u32] = &[
    // files with no path: Landlock cannot see them, so a program written
    // into one could be executed from memory
    279, // memfd_create
    447, // memfd_secret
    // other processes' memory and descriptors
    117, // ptrace
    270, // process_vm_readv
    271, // process_vm_writev
    272, // kcmp
    438, // pidfd_getfd
    440, // process_madvise
    448, // process_mrelease
    // namespaces and the filesystem tree
    97,  // unshare
    268, // setns
    39,  // umount2
    40,  // mount
    41,  // pivot_root
    51,  // chroot
    428, // open_tree
    429, // move_mount
    430, // fsopen
    431, // fsconfig
    432, // fsmount
    433, // fspick
    442, // mount_setattr
    264, // name_to_handle_at
    265, // open_by_handle_at
    // kernel code, tracing and large kernel interfaces
    104, // kexec_load
    294, // kexec_file_load
    105, // init_module
    106, // delete_module
    273, // finit_module
    280, // bpf
    241, // perf_event_open
    282, // userfaultfd
    425, // io_uring_setup
    426, // io_uring_enter
    427, // io_uring_register
    217, // add_key
    218, // request_key
    219, // keyctl
    // machine-wide state
    18,  // lookup_dcookie
    42,  // nfsservctl
    58,  // vhangup
    60,  // quotactl
    443, // quotactl_fd
    89,  // acct
    116, // syslog
    142, // reboot
    161, // sethostname
    162, // setdomainname
    112, // clock_settime
    170, // settimeofday
    171, // adjtimex
    266, // clock_adjtime
    224, // swapon
    225, // swapoff
    262, // fanotify_init
    460, // lsm_set_self_attr
    // memory placement across NUMA nodes
    235, // mbind
    237, // set_mempolicy
    238, // migrate_pages
    239, // move_pages
    450, // set_mempolicy_home_node
];

fn install_filter(probe: u32) -> bool {
    let mut prog = [0u64; 31 + 2 * DENIED.len()];
    let fixed = [
        // Only the native ABI: a 32-bit entry would use other numbers.
        ins(LOAD, 0, 0, ARCH),
        ins(JEQ, 1, 0, AUDIT_ARCH_AARCH64),
        ins(RET, 0, 0, KILL_PROCESS),
        ins(LOAD, 0, 0, NR),
        ins(JGT, 0, 1, NEWEST_KNOWN),
        ins(RET, 0, 0, errno(ENOSYS)),
        // prctl(PROBE) and, in init's filter, prctl(PROBE_FULL): "already
        // locked down".
        ins(JEQ, 0, 5, SYS_PRCTL),
        ins(LOAD, 0, 0, ARG0),
        ins(JEQ, 1, 0, PROBE),
        ins(JEQ, 0, 1, probe),
        ins(RET, 0, 0, errno(EALREADY)),
        ins(LOAD, 0, 0, NR),
        // clone: threads and processes, but no new namespaces.
        ins(JEQ, 0, 4, SYS_CLONE),
        ins(LOAD, 0, 0, ARG0),
        ins(JSET, 0, 1, CLONE_NEW_ANY),
        ins(RET, 0, 0, errno(EPERM)),
        ins(RET, 0, 0, ALLOW),
        // personality: only the default, or asking for the current one.
        // Anything else can switch off address-space randomisation.
        ins(JEQ, 0, 5, SYS_PERSONALITY),
        ins(LOAD, 0, 0, ARG0),
        ins(JEQ, 2, 0, 0xffff_ffff),
        ins(JEQ, 1, 0, 0),
        ins(RET, 0, 0, errno(EPERM)),
        ins(RET, 0, 0, ALLOW),
        // clone3 hides its flags behind a pointer the filter cannot follow:
        // "not implemented" makes every libc fall back to clone.
        ins(JEQ, 0, 1, SYS_CLONE3),
        ins(RET, 0, 0, errno(ENOSYS)),
        // socket: every family but the one that talks to the hypervisor,
        // which Docker's own filter refuses as well.
        ins(JEQ, 0, 4, SYS_SOCKET),
        ins(LOAD, 0, 0, ARG0),
        ins(JEQ, 0, 1, AF_VSOCK),
        ins(RET, 0, 0, errno(EPERM)),
        ins(RET, 0, 0, ALLOW),
    ];
    prog[..fixed.len()].copy_from_slice(&fixed);
    let mut n = fixed.len();
    for &nr in DENIED {
        prog[n] = ins(JEQ, 0, 1, nr);
        prog[n + 1] = ins(RET, 0, 0, errno(EPERM));
        n += 2;
    }
    prog[n] = ins(RET, 0, 0, ALLOW);
    sys::seccomp_filter(&[n + 1, prog.as_ptr() as usize]) == 0
}

// ------------------------------------------------------------- capabilities

/// Give up every capability, for good: the bounding set (what any later
/// exec could regain), the ambient set, and this process's own.
pub fn drop_capabilities() {
    for cap in 0..64 {
        sys::prctl(PR_CAPBSET_DROP, cap);
    }
    sys::prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL);
    let version_3 = 0x2008_0522;
    sys::capset(&[version_3, 0], &[0; 6]);
    // Not dumpable: other processes, even with the same UID, cannot read
    // PID 1's memory or environment through /proc.
    sys::prctl(PR_SET_DUMPABLE, 0);
}
