/* lp: Landlock probe for the kContainerOS audit (track: landlock).
 * One operation per call; prints "ok" or the errno name. Static, musl.
 * Never writes data to a file it did not create (open/close only), except
 * `copy`, `append1` and `trunc`, which the harness uses on scratch files only. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <mqueue.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/sysmacros.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <sys/xattr.h>
#include <unistd.h>

extern char **environ;

static const char *en(int e) {
    switch (e) {
    case 0: return "ok";
    case EPERM: return "EPERM"; case ENOENT: return "ENOENT"; case EIO: return "EIO";
    case ENXIO: return "ENXIO"; case EBADF: return "EBADF"; case EACCES: return "EACCES";
    case EBUSY: return "EBUSY"; case EEXIST: return "EEXIST"; case EXDEV: return "EXDEV";
    case ENODEV: return "ENODEV"; case ENOTDIR: return "ENOTDIR"; case EISDIR: return "EISDIR";
    case EINVAL: return "EINVAL"; case ENOTTY: return "ENOTTY"; case ETXTBSY: return "ETXTBSY";
    case EROFS: return "EROFS"; case ELOOP: return "ELOOP"; case ENOSYS: return "ENOSYS";
    case ENOTEMPTY: return "ENOTEMPTY"; case EOPNOTSUPP: return "EOPNOTSUPP";
    case ENOEXEC: return "ENOEXEC"; case ENAMETOOLONG: return "ENAMETOOLONG";
    case EMFILE: return "EMFILE"; case ENOSPC: return "ENOSPC"; case EAGAIN: return "EAGAIN";
    case ENODATA: return "ENODATA"; case EFAULT: return "EFAULT"; case ENOMEM: return "ENOMEM";
    }
    static char b[16]; snprintf(b, sizeof b, "E%d", e); return b;
}
static int res(long r) { puts(en(r < 0 ? errno : 0)); return r < 0; }

static int mode(const char *m) {
    if (!strcmp(m, "r")) return O_RDONLY;
    if (!strcmp(m, "w")) return O_WRONLY;
    if (!strcmp(m, "rw")) return O_RDWR;
    if (!strcmp(m, "3")) return 3;                 /* Linux: no read, no write, ioctl only */
    if (!strcmp(m, "a")) return O_WRONLY | O_APPEND;
    if (!strcmp(m, "t")) return O_WRONLY | O_TRUNC;
    if (!strcmp(m, "rt")) return O_RDONLY | O_TRUNC;   /* Linux truncates on this too */
    if (!strcmp(m, "c")) return O_WRONLY | O_CREAT | O_EXCL;
    if (!strcmp(m, "d")) return O_RDONLY | O_DIRECTORY;
    if (!strcmp(m, "p")) return O_PATH;
    if (!strcmp(m, "T")) return O_TMPFILE | O_RDWR;
    fprintf(stderr, "bad mode %s\n", m); exit(2);
}

/* execve in a child; the errno comes back through a CLOEXEC pipe. */
static int try_exec(int fd, const char *path, int flags) {
    int p[2]; if (pipe2(p, O_CLOEXEC)) return res(-1);
    pid_t c = fork();
    if (c == 0) {
        char *argv[] = { (char *)(path[0] ? path : "lp"), "true", 0 };
        if (fd >= 0) syscall(SYS_execveat, fd, path, argv, environ, flags);
        else execve(path, argv, environ);
        int e = errno; write(p[1], &e, sizeof e); _exit(127);
    }
    close(p[1]);
    int e = 0, st = 0; ssize_t n = read(p[0], &e, sizeof e);
    waitpid(c, &st, 0);
    if (n == sizeof e) { puts(en(e)); return 1; }
    if (WIFEXITED(st) && WEXITSTATUS(st) == 0) { puts("ok"); return 0; }
    printf("ran:status=%d\n", st); return 0;
}

static int copy(const char *src, int out) {
    int in = open(src, O_RDONLY); if (in < 0) return -1;
    char b[65536]; ssize_t n;
    while ((n = read(in, b, sizeof b)) > 0) if (write(out, b, n) != n) return -1;
    close(in); return n < 0 ? -1 : 0;
}

int main(int argc, char **argv) {
    const char *c = argc > 1 ? argv[1] : "";
    const char *a = argc > 2 ? argv[2] : "", *b = argc > 3 ? argv[3] : "";
    if (!strcmp(c, "true")) return 0;
    if (!strcmp(c, "abi")) { long v = syscall(444, 0, 0, 1); if (v < 0) return res(v); printf("%ld\n", v); return 0; }
    if (!strcmp(c, "open")) { int fd = open(b, mode(a), 0755); return res(fd); }
    if (!strcmp(c, "read")) { int fd = open(a, O_RDONLY); if (fd < 0) return res(fd); char x; return res(read(fd, &x, 1)); }
    if (!strcmp(c, "append1")) { int fd = open(a, O_WRONLY | O_APPEND); if (fd < 0) return res(fd); return res(write(fd, "x", 1)); }
    if (!strcmp(c, "ioctl")) {
        int fd = open(b, mode(a)); if (fd < 0) { printf("open:%s\n", en(errno)); return 1; }
        char buf[4096]; memset(buf, 0, sizeof buf);
        long r = ioctl(fd, strtoul(argv[4], 0, 16), buf);
        if (r < 0) { printf("ioctl:%s\n", en(errno)); return 1; }
        unsigned long long v; memcpy(&v, buf, 8); printf("ioctl:ok ret=%ld val=0x%llx\n", r, v); return 0;
    }
    if (!strcmp(c, "ftrunc")) { int fd = open(a, O_WRONLY); if (fd < 0) { printf("open:%s\n", en(errno)); return 1; } return res(ftruncate(fd, 0)); }
    if (!strcmp(c, "trunc")) return res(truncate(a, 0));
    if (!strcmp(c, "mkdir")) return res(mkdir(a, 0755));
    if (!strcmp(c, "rmdir")) return res(rmdir(a));
    if (!strcmp(c, "unlink")) return res(unlink(a));
    if (!strcmp(c, "symlink")) return res(symlink(a, b));
    if (!strcmp(c, "link")) return res(link(a, b));
    if (!strcmp(c, "linkfd")) { int fd = open(a, O_RDONLY); if (fd < 0) return res(fd); char p[64]; snprintf(p, sizeof p, "/proc/self/fd/%d", fd); return res(linkat(AT_FDCWD, p, AT_FDCWD, b, AT_SYMLINK_FOLLOW)); }
    if (!strcmp(c, "rename")) return res(rename(a, b));
    if (!strcmp(c, "exch")) return res(syscall(SYS_renameat2, AT_FDCWD, a, AT_FDCWD, b, 2 /* RENAME_EXCHANGE */));
    if (!strcmp(c, "chmod")) return res(chmod(b, strtoul(a, 0, 8)));
    if (!strcmp(c, "chown")) return res(chown(argv[4], atoi(a), atoi(b)));
    if (!strcmp(c, "utime")) return res(utimensat(AT_FDCWD, a, 0, 0));
    if (!strcmp(c, "setxattr")) return res(setxattr(a, "user.kcosaudit", "1", 1, 0));
    if (!strcmp(c, "mknod")) {
        mode_t t = a[0] == 'c' ? S_IFCHR : a[0] == 'b' ? S_IFBLK : a[0] == 'p' ? S_IFIFO : a[0] == 's' ? S_IFSOCK : S_IFREG;
        return res(mknod(b, t | 0666, argc > 5 ? makedev(atoi(argv[4]), atoi(argv[5])) : 0));
    }
    if (!strcmp(c, "bind")) {
        int s = socket(AF_UNIX, SOCK_STREAM, 0); struct sockaddr_un u = { AF_UNIX };
        strncpy(u.sun_path, a, sizeof u.sun_path - 1); return res(bind(s, (void *)&u, sizeof u));
    }
    if (!strcmp(c, "copy")) { int fd = open(b, O_WRONLY | O_CREAT | O_TRUNC, 0755); if (fd < 0) return res(fd); return res(copy(a, fd)); }
    if (!strcmp(c, "exec")) return try_exec(-1, a, 0);
    if (!strcmp(c, "fexec")) { int fd = open(b, mode(a)); if (fd < 0) { printf("open:%s\n", en(errno)); return 1; } return try_exec(fd, "", AT_EMPTY_PATH); }
    if (!strcmp(c, "procfdexec")) { int fd = open(a, O_RDONLY); if (fd < 0) { printf("open:%s\n", en(errno)); return 1; } char p[64]; snprintf(p, sizeof p, "/proc/self/fd/%d", fd); return try_exec(-1, p, 0); }
    if (!strcmp(c, "tmpfileexec")) { /* DIR SRC: unnamed file in DIR, filled from SRC, then executed two ways */
        int w = open(a, O_TMPFILE | O_RDWR, 0700); if (w < 0) { printf("tmpfile:%s\n", en(errno)); return 1; }
        if (copy(b, w)) { printf("copy:%s\n", en(errno)); return 1; }
        char p[64]; snprintf(p, sizeof p, "/proc/self/fd/%d", w);
        int r = open(p, O_RDONLY); close(w); if (r < 0) { printf("reopen:%s\n", en(errno)); return 1; }
        printf("execveat="); fflush(stdout); try_exec(r, "", AT_EMPTY_PATH);
        snprintf(p, sizeof p, "/proc/self/fd/%d", r);
        printf("procfd="); fflush(stdout); return try_exec(-1, p, 0);
    }
    if (!strcmp(c, "memfd")) return res(syscall(SYS_memfd_create, "x", 0));
    if (!strcmp(c, "mmapx")) { int fd = open(a, O_RDONLY); if (fd < 0) { printf("open:%s\n", en(errno)); return 1; } void *m = mmap(0, 4096, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, 0); return res(m == MAP_FAILED ? -1 : 0); }
    if (!strcmp(c, "mq")) { mqd_t q = mq_open(a, O_CREAT | O_RDWR, 0600, 0); if (q == (mqd_t)-1) return res(-1); mq_unlink(a); puts("ok"); return 0; }
    if (!strcmp(c, "uffd")) { /* /dev/userfaultfd: a userfaultfd without the userfaultfd system call */
        int fd = open(a, 3); if (fd < 0) { printf("open:%s\n", en(errno)); return 1; }
        long r = ioctl(fd, 0xAA00 /* USERFAULTFD_IOC_NEW */, O_CLOEXEC); if (r < 0) { printf("ioctl:%s\n", en(errno)); return 1; }
        printf("ioctl:ok fd=%ld\n", r); return 0;
    }
    if (!strcmp(c, "sweep")) { /* open with access mode 3 (no read, no write), never blocking, never a controlling tty */
        int fd = open(a, 3 | O_NONBLOCK | O_NOCTTY); return res(fd);
    }
    if (!strcmp(c, "reopen")) { /* MODE PATH: O_PATH descriptor first, then open it again through /proc/self/fd */
        int fd = open(b, O_PATH); if (fd < 0) { printf("opath:%s\n", en(errno)); return 1; }
        char p[64]; snprintf(p, sizeof p, "/proc/self/fd/%d", fd); return res(open(p, mode(a)));
    }
    if (!strcmp(c, "initenv")) { /* ENV... -- CMD...: become /sbin/init with exactly this environment (raw bytes, duplicates kept) */
        char *env[64], *av[64]; int e = 0, v = 0, i = 2;
        for (; i < argc && strcmp(argv[i], "--"); i++) env[e++] = argv[i];
        env[e] = 0; av[v++] = "/sbin/init";
        for (; i < argc; i++) av[v++] = argv[i];
        av[v] = 0; execve("/sbin/init", av, env); return res(-1);
    }
    if (!strcmp(c, "stat")) { struct stat s; if (lstat(a, &s)) return res(-1); printf("mode=%o uid=%d nlink=%d rdev=%d:%d\n", s.st_mode, s.st_uid, (int)s.st_nlink, major(s.st_rdev), minor(s.st_rdev)); return 0; }
    fprintf(stderr, "lp: unknown command %s\n", c); return 2;
}
