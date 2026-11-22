//! The system calls: `svc #0` with the number in x8, arguments in x0 and
//! x1, the result in x0. A negative result is an error.

/// exit(status): never returns. The machine powers off.
pub const SYS_EXIT: u64 = 0;
/// write(ptr, len): the bytes go to the console. Returns len.
pub const SYS_WRITE: u64 = 1;
/// read(ptr, len): waits for at least one byte from the console. Returns
/// how many were stored.
pub const SYS_READ: u64 = 2;
/// info(ptr): stores two u64: bytes of RAM, bytes not yet handed out.
pub const SYS_INFO: u64 = 3;

/// The pointer does not lie in memory the program may use that way.
pub const EFAULT: i64 = -14;
/// No such system call.
pub const ENOSYS: i64 = -38;
