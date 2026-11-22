/* kp: probe helper for the escape-user audit track. Static, musl.
 * Each subcommand prints "NAME: result" lines and never writes outside
 * the paths it is given. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <mqueue.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/ipc.h>
#include <sys/mman.h>
#include <sys/shm.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static void res(const char *what, long r) {
    if (r < 0) printf("%s: errno %d (%s)\n", what, errno, strerror(errno));
    else printf("%s: ok (%ld)\n", what, r);
    fflush(stdout);
}

/* run f in a child so that a successful exec or jump does not end us */
static void in_child(void (*f)(const char *), const char *arg) {
    fflush(stdout);
    pid_t p = fork();
    if (p == 0) { f(arg); fflush(stdout); _exit(0); }
    int st; waitpid(p, &st, 0);
    if (WIFEXITED(st)) printf("  child exit %d\n", WEXITSTATUS(st));
    else printf("  child signal %d\n", WTERMSIG(st));
    fflush(stdout);
}

static void do_execveat(const char *path) {
    int fd = open(path, O_PATH | O_CLOEXEC);
    res("open O_PATH", fd);
    if (fd < 0) return;
    char *av[] = { (char *)path, NULL };
    res("execveat AT_EMPTY_PATH", syscall(SYS_execveat, fd, "", av, environ, AT_EMPTY_PATH));
}
static void do_fexec(const char *path) {
    int fd = open(path, O_RDONLY);
    res("open O_RDONLY", fd);
    if (fd < 0) return;
    char p[64]; snprintf(p, sizeof p, "/proc/self/fd/%d", fd);
    char *av[] = { (char *)path, NULL };
    res("execve /proc/self/fd/N", execve(p, av, environ));
}
static void do_mapexec(const char *path) {
    int fd = open(path, O_RDONLY);
    res("open", fd);
    if (fd < 0) return;
    void *m = mmap(NULL, 4096, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, 0);
    if (m == MAP_FAILED) { res("mmap PROT_EXEC of file", -1); return; }
    printf("mmap PROT_EXEC of file: ok, jumping\n"); fflush(stdout);
    ((void (*)(void))m)();
}
static void do_anonexec(const char *path) {
    int fd = open(path, O_RDONLY);
    res("open", fd);
    if (fd < 0) return;
    void *m = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    long n = read(fd, m, 4096);
    res("read into anonymous memory", n);
    if (mprotect(m, 4096, PROT_READ | PROT_EXEC) < 0) { res("mprotect PROT_EXEC", -1); return; }
    __builtin___clear_cache((char *)m, (char *)m + 4096);
    printf("mprotect PROT_EXEC: ok, jumping\n"); fflush(stdout);
    ((void (*)(void))m)();
}
/* A SysV segment is a file on the kernel's internal tmpfs, as a memfd is. */
static void do_shmexec(const char *path) {
    int fd = open(path, O_RDONLY);
    res("open", fd);
    if (fd < 0) return;
    struct stat st; fstat(fd, &st);
    size_t len = (st.st_size + 4095) & ~4095UL;
    int id = shmget(IPC_PRIVATE, len, IPC_CREAT | 0700);
    res("shmget", id);
    if (id < 0) return;
    char *m = shmat(id, NULL, 0);
    shmctl(id, IPC_RMID, NULL);
    if (m == (void *)-1) { res("shmat", -1); return; }
    read(fd, m, st.st_size);
    char p[128];
    snprintf(p, sizeof p, "/proc/self/map_files/%lx-%lx", (unsigned long)m, (unsigned long)m + len);
    printf("link %s\n", p);
    char *av[] = { "shm", NULL };
    res("open map_files link", open(p, O_RDONLY));
    res("execve map_files link", execve(p, av, environ));
}
static void do_tmpfile(const char *dir) {
    int fd = open(dir, O_TMPFILE | O_RDWR, 0700);
    res("open O_TMPFILE", fd);
    if (fd < 0) return;
    int src = open("/proc/self/exe", O_RDONLY);
    char buf[65536]; long n;
    while ((n = read(src, buf, sizeof buf)) > 0) write(fd, buf, n);
    fchmod(fd, 0755);
    char p[64]; snprintf(p, sizeof p, "/proc/self/fd/%d", fd);
    int ro = open(p, O_RDONLY);          /* exec needs no writer on the file */
    res("reopen read-only", ro);
    close(fd);
    char *av[] = { "kp", "hello", NULL };
    res("execveat on O_TMPFILE file", syscall(SYS_execveat, ro, "", av, environ, AT_EMPTY_PATH));
}

int main(int argc, char **argv) {
    if (argc < 2) { printf("kp: started with argc=%d argv0=%s\n", argc, argc ? argv[0] : "(none)"); return 0; }
    const char *c = argv[1], *a = argc > 2 ? argv[2] : "";
    if (!strcmp(c, "hello")) { printf("KP-HELLO: a program started from %s\n", argv[0]); return 0; }
    if (!strcmp(c, "execveat")) in_child(do_execveat, a);
    else if (!strcmp(c, "fexec")) in_child(do_fexec, a);
    else if (!strcmp(c, "mapexec")) in_child(do_mapexec, a);
    else if (!strcmp(c, "anonexec")) in_child(do_anonexec, a);
    else if (!strcmp(c, "shmexec")) in_child(do_shmexec, a);
    else if (!strcmp(c, "tmpfile")) in_child(do_tmpfile, a);
    else if (!strcmp(c, "memfd")) res("memfd_create", syscall(SYS_memfd_create, "x", 0));
    else if (!strcmp(c, "argv0")) {           /* kp argv0 PATH ARGV0 [ARGS] */
        res("execve", execve(a, argv + 3, environ));
    } else if (!strcmp(c, "argc0")) {
        char *none[] = { NULL };
        res("execve with empty argv", execve(a, none, environ));
    } else if (!strcmp(c, "mq")) {            /* a named object that is not in /work */
        const char *name = "/kcos-audit-escape-user";
        mqd_t q = mq_open(name, O_CREAT | O_RDWR, 0600, NULL);
        res("mq_open O_CREAT", q);
        if (q != (mqd_t)-1) {
            res("mq_send", mq_send(q, "stored outside /work", 20, 0));
            mq_close(q);
            q = mq_open(name, O_RDONLY);
            char buf[8192] = {0};
            long n = mq_receive(q, buf, sizeof buf, NULL);
            if (n >= 0) printf("mq_receive after reopen: \"%.*s\"\n", (int)n, buf); else res("mq_receive", -1);
            res("mq_unlink", mq_unlink(name));
        }
    } else if (!strcmp(c, "sysvshm")) {
        int id = shmget(0x6b636f73, 1 << 20, IPC_CREAT | 0600);
        res("shmget 1 MiB with a key", id);
        if (id >= 0) {
            char *m = shmat(id, NULL, 0);
            if (m != (void *)-1) { strcpy(m, "stored outside /work"); shmdt(m); m = shmat(id, NULL, 0); printf("shm after reattach: \"%s\"\n", m); }
            res("shmctl IPC_RMID", shmctl(id, IPC_RMID, NULL));
        }
    } else if (!strcmp(c, "openw")) {         /* open for writing, write nothing */
        int fd = open(a, O_WRONLY | O_APPEND);
        res("open O_WRONLY|O_APPEND", fd);
    } else if (!strcmp(c, "openr")) {
        int fd = open(a, O_RDONLY);
        res("open O_RDONLY", fd);
    } else if (!strcmp(c, "tiocsti")) {       /* push one harmless '#' into a terminal's input */
        if (fork() > 0) { wait(NULL); return 0; }
        res("setsid (become a session leader without a terminal)", setsid());
        int fd = open(a, O_RDWR | O_NOCTTY);
        res("open terminal", fd);
        if (fd >= 0) {
            res("ioctl TIOCSCTTY (take it as controlling terminal)", ioctl(fd, 0x540E, 0));
            res("ioctl TIOCSTI", ioctl(fd, 0x5412, "#"));
        }
    } else if (!strcmp(c, "churn")) {
        /* One process that changes its PID every millisecond and ignores
         * SIGTERM: a chain, not a bomb. Stops by itself after N seconds. */
        int secs = atoi(a);
        signal(SIGTERM, SIG_IGN); signal(SIGHUP, SIG_IGN);
        time_t end = time(NULL) + secs;
        if (fork() > 0) return 0;
        while (time(NULL) < end) {
            pid_t p = fork();
            if (p > 0) _exit(0);
            if (p == 0) setsid();
            usleep(1000);
        }
    } else { printf("kp: unknown %s\n", c); return 2; }
    return 0;
}
