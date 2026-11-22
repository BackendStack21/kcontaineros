/* Audit helper for the escape-root track. Static, no dependencies beyond libc.
 * It models a compromised application: every subcommand tries something and
 * prints "name: ok(ret)" or "name: errno N (text)". Nothing here writes to a
 * kernel file or a device; opens are O_APPEND and closed at once.
 *
 *   esc sys            system calls the filter claims to refuse, harmless arguments
 *   esc ns             clone() with each namespace flag
 *   esc socks [vsock]  socket() for every address family (40 only when asked)
 *   esc caps           capabilities, securebits, attempts to raise them
 *   esc ids            setuid/setgid/setgroups/mknod/nice in a child
 *   esc pid1           everything aimed at PID 1
 *   esc exec SRC       ways of starting a copy of SRC from writable places
 *   esc writes DIR     ways of changing a program directory
 *   esc wr PATH...     open each for append, close
 *   esc rd PATH...     open each for reading, close
 *   esc scanw DIR      append-open every regular file under DIR (init runs only)
 *   esc scandev        open every node under /dev for read and for append (init runs only)
 *   esc core DIR       dump core with DIR as working directory, report DIR/core*
 *   esc ipc            SysV and POSIX IPC, inotify, pidfd, landlock, seccomp
 *   esc hello          print a line (the "program brought along")
 *   esc cpukill        RLIMIT_CPU on PID 1, then make it work
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/ipc.h>
#include <sys/mman.h>
#include <sys/msg.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/sem.h>
#include <sys/shm.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <time.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <sys/xattr.h>
#include <unistd.h>

static void res(const char *name, long r) {
    if (r < 0) printf("%s: errno %d (%s)\n", name, errno, strerror(errno));
    else printf("%s: ok(%ld)\n", name, r);
    fflush(stdout);
}
#define S(name, ...) res(name, syscall(__VA_ARGS__))

static char zero[4096];

static void cmd_sys(void) {
    pid_t me = getpid();
    S("memfd_create", 279, "x", 0);
    S("memfd_secret", 447, 0);
    S("ptrace(SEIZE,no such pid)", 117, 0x4206, 0x3ffffff0, 0, 0);
    S("process_vm_readv(self,0 iov)", 270, me, 0, 0, 0, 0, 0);
    S("process_vm_writev(self,0 iov)", 271, me, 0, 0, 0, 0, 0);
    S("kcmp(self,self,FILE,0,0)", 272, me, me, 0, 0, 0);
    S("pidfd_getfd(-1)", 438, -1, 0, 0);
    S("process_madvise(-1)", 440, -1, 0, 0, 0, 0);
    S("process_mrelease(-1)", 448, -1, 0);
    S("unshare(0)", 97, 0);
    S("setns(-1)", 268, -1, 0);
    S("umount2(/nonexistent)", 39, "/nonexistent", 0);
    S("mount(/nonexistent)", 40, 0, "/nonexistent", 0, 0, 0);
    S("pivot_root(/nonexistent)", 41, "/nonexistent", "/nonexistent");
    S("chroot(/nonexistent)", 51, "/nonexistent");
    S("open_tree(/nonexistent)", 428, -100, "/nonexistent", 0);
    S("move_mount(bad)", 429, -1, "", -1, "", 0);
    S("fsopen(nonexistentfs)", 430, "kcosnofs", 0);
    S("fsconfig(-1)", 431, -1, 0, 0, 0, 0);
    S("fsmount(-1)", 432, -1, 0, 0);
    S("fspick(/nonexistent)", 433, -100, "/nonexistent", 0);
    S("mount_setattr(/nonexistent)", 442, -100, "/nonexistent", 0, zero, 32);
    S("name_to_handle_at(/nonexistent)", 264, -100, "/nonexistent", zero, zero, 0);
    S("open_by_handle_at(-1)", 265, -1, zero, 0);
    S("kexec_load(bad flags)", 104, 0, 0, 0, 0xffffffffUL);
    S("kexec_file_load(-1)", 294, -1, -1, 0, 0, 0);
    S("init_module(NULL)", 105, 0, 0, "");
    S("delete_module(nonexistent)", 106, "kcos_nonexistent", 04000);
    S("finit_module(-1)", 273, -1, "", 0);
    S("bpf(bad cmd)", 280, 9999, 0, 0);
    S("perf_event_open(NULL)", 241, 0, 0, -1, -1, 0);
    S("userfaultfd", 282, 0);
    S("io_uring_setup(0,NULL)", 425, 0, 0);
    S("io_uring_enter(-1)", 426, -1, 0, 0, 0, 0, 0);
    S("io_uring_register(-1)", 427, -1, 0, 0, 0);
    S("add_key(NULL)", 217, 0, 0, 0, 0, 0);
    S("request_key(NULL)", 218, 0, 0, 0, 0);
    S("keyctl(GET_KEYRING_ID,session,create)", 219, 0, -3, 1);
    S("lookup_dcookie", 18, 0, 0, 0);
    S("nfsservctl", 42, 0, 0, 0);
    S("vhangup", 58);
    S("quotactl(bad)", 60, 0, 0, 0, 0);
    S("quotactl_fd(-1)", 443, -1, 0, 0, 0);
    S("acct(/nonexistent)", 89, "/nonexistent");
    S("syslog(SIZE_BUFFER)", 116, 10, 0, 0);
    S("reboot(bad magic)", 142, 0, 0, 0, 0);
    S("sethostname(NULL,huge)", 161, 0, 100000);
    S("setdomainname(NULL,huge)", 162, 0, 100000);
    S("clock_settime(REALTIME,NULL)", 112, 0, 0);
    S("settimeofday(NULL,NULL)", 170, 0, 0);
    S("adjtimex(read only)", 171, zero);
    S("clock_adjtime(REALTIME,read only)", 266, 0, zero);
    S("swapon(/nonexistent)", 224, "/nonexistent", 0);
    S("swapoff(/nonexistent)", 225, "/nonexistent");
    S("fanotify_init", 262, 0, 0);
    S("lsm_set_self_attr(bad)", 460, 0, 0, 0, 0);
    S("mbind(0,0)", 235, 0, 0, 0, 0, 0, 0);
    S("set_mempolicy(DEFAULT)", 237, 0, 0, 0);
    S("migrate_pages(self,0)", 238, 0, 0, 0, 0);
    S("move_pages(self,0)", 239, 0, 0, 0, 0, 0, 0);
    S("set_mempolicy_home_node(0)", 450, 0, 0, 0, 0);
    S("clone3(NULL,0)", 435, 0, 0);
    S("personality(query)", 92, 0xffffffffUL);
    S("personality(ADDR_NO_RANDOMIZE)", 92, 0x0040000);
    S("personality(0)", 92, 0);
    S("personality(high bits|ADDR_NO_RANDOMIZE)", 92, 0x100000000UL | 0x0040000);
    S("personality(0) again", 92, 0);
    S("syscall 467", 467, -1, 0, 0, 0, 0);
    S("syscall 600", 600, 0, 0);
    S("prctl(KCOS probe)", 167, 0x4b434f53, 0);
    S("prctl(KCOF probe)", 167, 0x4b434f46, 0);
    /* allowed by the filter; shown for the record */
    S("pidfd_open(1)", 434, 1, 0);
    S("listmount(root)", 458, (long[]){24, 0, 0xffffffffffffffffUL /*LSMT_ROOT*/, 0}, zero, 8, 0);
    S("execveat(-1)", 281, -1, "", 0, 0, 0x1000);
}

static void cmd_ns(void) {
    static const struct { const char *n; unsigned long f; } fl[] = {
        {"clone(NEWNS)", 0x00020000}, {"clone(NEWCGROUP)", 0x02000000}, {"clone(NEWUTS)", 0x04000000},
        {"clone(NEWIPC)", 0x08000000}, {"clone(NEWUSER)", 0x10000000}, {"clone(NEWPID)", 0x20000000},
        {"clone(NEWNET)", 0x40000000}, {"clone(NEWUSER|high bits set)", 0xffffffff10000000UL},
        {"clone(plain fork)", 0}, {"clone(high bits only)", 0x100000000UL},
    };
    for (unsigned i = 0; i < sizeof fl / sizeof *fl; i++) {
        long pid = syscall(220, fl[i].f | SIGCHLD, 0, 0, 0, 0);
        if (pid == 0) _exit(0);
        res(fl[i].n, pid > 0 ? 1 : pid);
        if (pid > 0) waitpid(pid, 0, 0);
    }
    S("unshare(NEWUSER)", 97, 0x10000000);
    S("unshare(NEWTIME)", 97, 0x80);
}

static void cmd_socks(int vsock) {
    static const int types[] = {SOCK_STREAM, SOCK_DGRAM, SOCK_RAW, SOCK_SEQPACKET};
    for (int af = 0; af <= 46; af++) {
        if (af == 40 && !vsock) { printf("af 40 (AF_VSOCK): skipped in this run\n"); continue; }
        for (unsigned t = 0; t < 4; t++) {
            int fd = socket(af, types[t], 0);
            if (fd >= 0) { printf("socket(af %d, type %d): ok\n", af, types[t]); close(fd); }
            else if (errno != EAFNOSUPPORT && errno != ESOCKTNOSUPPORT && errno != EPROTONOSUPPORT && errno != EINVAL)
                printf("socket(af %d, type %d): errno %d (%s)\n", af, types[t], errno, strerror(errno));
        }
    }
    if (vsock) {
        S("socket(AF_VSOCK | high bits)", 198, 0x100000000UL | 40, 1, 0);
        S("socketpair(AF_VSOCK)", 199, 40, 1, 0, zero);
    }
    for (int proto = 0; proto <= 22; proto++) {
        int fd = socket(AF_NETLINK, SOCK_RAW, proto);
        if (fd >= 0) { printf("netlink proto %d: ok\n", proto); close(fd); }
        else if (errno != EPROTONOSUPPORT) printf("netlink proto %d: errno %d (%s)\n", proto, errno, strerror(errno));
    }
    S("socket(AF_INET,RAW,ICMP)", 198, 2, 3, 1);
    S("socket(AF_PACKET,RAW)", 198, 17, 3, 0x0300);
    S("socket(AF_INET,DGRAM,ICMP) ping socket", 198, 2, 2, 1);
    S("socket(AF_ALG)", 198, 38, 5, 0);
}

static void show_status(void) {
    FILE *f = fopen("/proc/self/status", "r");
    char line[256];
    while (f && fgets(line, sizeof line, f))
        if (!strncmp(line, "Cap", 3) || !strncmp(line, "NoNew", 5) || !strncmp(line, "Seccomp", 7) ||
            !strncmp(line, "Uid", 3) || !strncmp(line, "Gid", 3) || !strncmp(line, "Groups", 6))
            fputs(line, stdout);
    if (f) fclose(f);
}

static void cmd_caps(void) {
    show_status();
    res("prctl(GET_SECUREBITS)", prctl(27));
    res("prctl(GET_NO_NEW_PRIVS)", prctl(39, 0, 0, 0, 0));
    res("prctl(GET_SECCOMP)", prctl(21));
    res("prctl(GET_DUMPABLE)", prctl(3));
    res("prctl(GET_KEEPCAPS)", prctl(7));
    int inb = 0;
    for (int c = 0; c < 64; c++) if (prctl(23 /*CAPBSET_READ*/, c) == 1) inb++;
    printf("capabilities in the bounding set: %d\n", inb);
    if (fork() == 0) {
        res("prctl(SET_NO_NEW_PRIVS,0)", prctl(38, 0, 0, 0, 0));
        res("prctl(SET_SECUREBITS,0)", prctl(28, 0));
        res("prctl(SET_KEEPCAPS,1)", prctl(8, 1));
        res("prctl(CAP_AMBIENT_RAISE,CAP_SYS_ADMIN)", prctl(47, 2, 21, 0, 0));
        res("prctl(SET_SECCOMP,DISABLED)", prctl(22, 0));
        res("prctl(SET_MM,START_BRK,0)", prctl(35, 6, 0, 0, 0));
        res("prctl(SET_PTRACER,ANY)", prctl(0x59616d61, -1L));
        uint32_t hdr[2] = {0x20080522, 0};
        uint32_t data[6] = {~0u, ~0u, ~0u, ~0u, ~0u, ~0u};
        res("capset(all)", syscall(91, hdr, data));
        uint32_t inh[6] = {0, 0, ~0u, 0, 0, ~0u};
        res("capset(inheritable=all)", syscall(91, hdr, inh));
        res("seccomp(SET_MODE_STRICT off? op 99)", syscall(277, 99, 0, 0));
        _exit(0);
    }
    wait(0);
}

static void cmd_ids(void) {
    if (fork() == 0) { res("setuid(1000)", setuid(1000)); _exit(0); } wait(0);
    if (fork() == 0) { res("setgid(1000)", setgid(1000)); _exit(0); } wait(0);
    if (fork() == 0) { gid_t g[1] = {5}; res("setgroups([5])", setgroups(1, g)); _exit(0); } wait(0);
    if (fork() == 0) { res("setresuid(-1,1000,-1)", setresuid(-1, 1000, -1)); _exit(0); } wait(0);
    if (fork() == 0) { res("setpriority(self,-5)", setpriority(PRIO_PROCESS, 0, -5)); _exit(0); } wait(0);
    if (fork() == 0) {
        struct sched_param p = {1};
        res("sched_setscheduler(self,FIFO)", sched_setscheduler(0, SCHED_FIFO, &p));
        _exit(0);
    }
    wait(0);
    if (fork() == 0) {
        struct rlimit r = {RLIM_INFINITY, RLIM_INFINITY};
        struct rlimit o; getrlimit(RLIMIT_NOFILE, &o);
        r.rlim_cur = r.rlim_max = o.rlim_max + 1;
        res("setrlimit(NOFILE, hard+1)", setrlimit(RLIMIT_NOFILE, &r));
        _exit(0);
    }
    wait(0);
    res("mknod(/tmp/kcos-null, char 1:3)", mknod("/tmp/kcos-null", S_IFCHR | 0666, makedev(1, 3)));
    unlink("/tmp/kcos-null");
    res("mknod(/dev/shm/kcos-null, char 1:3)", mknod("/dev/shm/kcos-null", S_IFCHR | 0666, makedev(1, 3)));
    unlink("/dev/shm/kcos-null");
    res("chown(/tmp, 1000)", chown("/tmp", 1000, -1));
    res("mlock(64k)", mlock(malloc(65536), 65536));
    res("bind(port 80)", ({ int s = socket(AF_INET, SOCK_STREAM, 0); struct sockaddr_in { short f; unsigned short p; unsigned a; char z[8]; } a = {2, 0x5000, 0, {0}}; int r = bind(s, (void *)&a, 16); close(s); r; }));
}

static void try_open(const char *label, const char *path, int flags) {
    int fd = open(path, flags | O_NONBLOCK | O_NOCTTY | O_CLOEXEC);
    printf("%s %s: ", label, path);
    if (fd < 0) printf("errno %d (%s)\n", errno, strerror(errno));
    else { printf("OPENED\n"); close(fd); }
    fflush(stdout);
}

static void cmd_pid1(void) {
    char buf[256];
    res("kill(1,0)", kill(1, 0));
    res("kill(1,SIGKILL)", kill(1, SIGKILL));
    res("kill(1,SIGSTOP)", kill(1, SIGSTOP));
    usleep(200000);
    int fd = open("/proc/1/stat", O_RDONLY);
    int n = fd < 0 ? -1 : read(fd, buf, 60);
    if (n > 0) { buf[n] = 0; printf("/proc/1/stat begins: %s\n", buf); }
    close(fd);
    long pfd = syscall(434, 1, 0);
    res("pidfd_open(1)", pfd);
    res("pidfd_send_signal(pid1,0)", syscall(424, pfd, 0, 0, 0));
    res("pidfd_getfd(pid1,0)", syscall(438, pfd, 0, 0));
    res("ptrace(SEIZE,1)", syscall(117, 0x4206, 1, 0, 0));
    struct iovec { void *b; size_t l; } l = {buf, 8}, r = {(void *)0x400000, 8};
    res("process_vm_readv(1)", syscall(270, 1, &l, 1, &r, 1, 0));
    res("setns(pidfd of 1, NEWNS)", syscall(268, pfd, 0x00020000));
    struct rlimit old, nw;
    res("prlimit64(1,NOFILE,get)", prlimit(1, RLIMIT_NOFILE, 0, &old));
    printf("  pid 1 NOFILE before: %llu/%llu\n", (unsigned long long)old.rlim_cur, (unsigned long long)old.rlim_max);
    nw = old; nw.rlim_cur = old.rlim_cur > 7 ? 7 : old.rlim_cur;
    res("prlimit64(1,NOFILE,set soft=7)", prlimit(1, RLIMIT_NOFILE, &nw, 0));
    if (prlimit(1, RLIMIT_NOFILE, 0, &nw) == 0)
        printf("  pid 1 NOFILE after: %llu/%llu\n", (unsigned long long)nw.rlim_cur, (unsigned long long)nw.rlim_max);
    prlimit(1, RLIMIT_NOFILE, &old, 0);
    cpu_set_t set;
    res("sched_getaffinity(1)", sched_getaffinity(1, sizeof set, &set));
    res("sched_setaffinity(1,same mask)", sched_setaffinity(1, sizeof set, &set));
    errno = 0;
    int prio = getpriority(PRIO_PROCESS, 1);
    res("setpriority(1, +1)", setpriority(PRIO_PROCESS, 1, prio + 1));
    printf("  pid 1 nice: before %d, after %d\n", prio, getpriority(PRIO_PROCESS, 1));
    struct sched_param sp = {0};
    res("sched_setscheduler(1,SCHED_BATCH)", sched_setscheduler(1, 3, &sp));
    printf("  pid 1 policy now: %d\n", sched_getscheduler(1));
    res("ioprio_set(pid 1, idle class)", syscall(30, 1, 1, 3 << 13));
    res("setpgid(1,self)", setpgid(1, getpid()));
    res("getsid(1)", getsid(1));
    static const char *rd[] = {"environ", "maps", "smaps", "mem", "auxv", "stack", "io", "pagemap", "syscall",
                               "personality", "cmdline", "status", "limits", "fd", "fdinfo", "ns/mnt", "root", "cwd", "exe", 0};
    for (int i = 0; rd[i]; i++) {
        snprintf(buf, sizeof buf, "/proc/1/%s", rd[i]);
        try_open("read ", buf, O_RDONLY);
    }
    char link[128];
    res("readlink(/proc/1/exe)", readlink("/proc/1/exe", link, sizeof link));
    res("readlink(/proc/1/root)", readlink("/proc/1/root", link, sizeof link));
    static const char *wr[] = {"mem", "oom_score_adj", "comm", "coredump_filter", "timerslack_ns", "attr/current",
                               "uid_map", "setgroups", "clear_refs", "loginuid", 0};
    for (int i = 0; wr[i]; i++) {
        snprintf(buf, sizeof buf, "/proc/1/%s", wr[i]);
        try_open("append", buf, O_WRONLY | O_APPEND);
    }
}

static int copy_to(const char *src, int out) {
    int in = open(src, O_RDONLY);
    char b[65536];
    ssize_t n;
    if (in < 0) return -1;
    while ((n = read(in, b, sizeof b)) > 0)
        if (write(out, b, n) != n) return -1;
    close(in);
    return n < 0 ? -1 : 0;
}

/* Runs `how` in a child so that a successful exec does not end the test. */
static void child_exec(const char *label, const char *path, int fd) {
    fflush(stdout);
    pid_t p = fork();
    if (p == 0) {
        char *argv[] = {"brought", "hello", 0};
        char *envp[] = {0};
        if (fd >= 0) syscall(281, fd, "", argv, envp, 0x1000 /*AT_EMPTY_PATH*/);
        else execve(path, argv, envp);
        printf("%s: errno %d (%s)\n", label, errno, strerror(errno));
        fflush(stdout);
        _exit(111);
    }
    int st;
    waitpid(p, &st, 0);
    if (!(WIFEXITED(st) && WEXITSTATUS(st) == 111)) printf("%s: EXECUTED (status %#x)\n", label, st);
    fflush(stdout);
}

static void cmd_exec(const char *src, int argc, char **dirs) {
    char p[512], q[512];
    child_exec("execve(the helper in its program directory) [reference]", src, -1);
    for (int i = 0; i < argc; i++) {
        const char *d = dirs[i];
        printf("-- writable directory %s\n", d);
        snprintf(p, sizeof p, "%s/kcos-brought", d);
        int out = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0755);
        if (out < 0 || copy_to(src, out)) { printf("copy to %s: errno %d (%s)\n", p, errno, strerror(errno)); continue; }
        close(out);
        child_exec("execve(copy)", p, -1);
        int fd = open(p, O_RDONLY);
        child_exec("execveat(fd of copy, AT_EMPTY_PATH)", 0, fd);
        snprintf(q, sizeof q, "/proc/self/fd/%d", fd);
        child_exec("execve(/proc/self/fd/N of copy)", q, -1);
        int pfd = open(p, O_PATH);
        child_exec("execveat(O_PATH fd of copy)", 0, pfd);
        close(pfd);
        snprintf(q, sizeof q, "/proc/self/root%s", p);
        child_exec("execve(/proc/self/root/... copy)", q, -1);
        unlink(p);
        child_exec("execveat(fd of copy, after unlink)", 0, fd);
        close(fd);
        /* O_TMPFILE: a file that never had a name */
        int tf = open(d, O_TMPFILE | O_RDWR, 0755);
        if (tf < 0) printf("open(O_TMPFILE): errno %d (%s)\n", errno, strerror(errno));
        else {
            copy_to(src, tf);
            snprintf(q, sizeof q, "/proc/self/fd/%d", tf);
            int ro = open(q, O_RDONLY);
            close(tf);
            child_exec("execveat(O_TMPFILE file)", 0, ro);
            close(ro);
        }
        /* symlink and hard link from the writable place to the program */
        snprintf(p, sizeof p, "%s/kcos-sym", d);
        unlink(p);
        if (symlink(src, p) == 0) child_exec("execve(symlink in writable dir -> program) [reference: allowed]", p, -1);
        unlink(p);
        snprintf(p, sizeof p, "%s/kcos-hard", d);
        res("link(program -> writable dir)", link(src, p));
        unlink(p);
        /* mmap as code: documented as possible unless the mount is noexec */
        snprintf(p, sizeof p, "%s/kcos-map", d);
        int mf = open(p, O_RDWR | O_CREAT | O_TRUNC, 0755);
        if (mf >= 0) {
            if (write(mf, zero, 4096) != 4096) perror("write");
            void *m = mmap(0, 4096, PROT_READ | PROT_EXEC, MAP_PRIVATE, mf, 0);
            printf("mmap(file in %s, PROT_EXEC): %s\n", d, m == MAP_FAILED ? strerror(errno) : "mapped (documented limit)");
            close(mf);
            unlink(p);
        }
    }
    /* shared anonymous memory is a shmem file on the kernel's internal mount, which Landlock does not see */
    int in = open(src, O_RDONLY);
    struct stat st;
    fstat(in, &st);
    size_t len = (st.st_size + 4095) & ~4095UL;
    char *m = mmap(0, len, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    if (m != MAP_FAILED && read(in, m, st.st_size) > 0) {
        snprintf(p, sizeof p, "/proc/self/map_files/%lx-%lx", (unsigned long)m, (unsigned long)m + len);
        struct stat ls;
        res("lstat(map_files entry of shared anonymous memory)", lstat(p, &ls));
        child_exec("execve(/proc/self/map_files/... shared anonymous memory)", p, -1);
    }
    int id = shmget(IPC_PRIVATE, len, 0700 | IPC_CREAT);
    char *sm = id < 0 ? MAP_FAILED : shmat(id, 0, 0);
    if (sm != (void *)-1) {
        lseek(in, 0, SEEK_SET);
        if (read(in, sm, st.st_size) < 0) perror("read");
        snprintf(p, sizeof p, "/proc/self/map_files/%lx-%lx", (unsigned long)sm, (unsigned long)sm + len);
        child_exec("execve(/proc/self/map_files/... SysV shm)", p, -1);
        shmctl(id, IPC_RMID, 0);
    }
    close(in);
}

static void cmd_writes(const char *dir, const char *victim) {
    char p[512], q[512];
    struct stat st;
    printf("-- program directory %s, existing file %s\n", dir, victim);
    stat(dir, &st);
    printf("mode of %s: %o uid %d\n", dir, st.st_mode & 07777, st.st_uid);
    snprintf(p, sizeof p, "%s/kcos-new", dir);
    res("open(O_CREAT)", open(p, O_WRONLY | O_CREAT, 0755));
    res("mkdir", mkdir(p, 0755));
    res("symlink", symlink("/tmp", p));
    res("mkfifo", mknod(p, S_IFIFO | 0600, 0));
    res("open(dir, O_TMPFILE)", open(dir, O_TMPFILE | O_RDWR, 0755));
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un a = {AF_UNIX, ""};
    strncpy(a.sun_path, p, sizeof a.sun_path - 1);
    res("bind(unix socket)", bind(s, (void *)&a, sizeof a));
    close(s);
    int t = open("/tmp/kcos-src", O_WRONLY | O_CREAT | O_TRUNC, 0755);
    if (t >= 0) close(t);
    res("rename(/tmp/file -> dir)", rename("/tmp/kcos-src", p));
    res("link(/tmp/file -> dir)", link("/tmp/kcos-src", p));
    res("renameat2(EXCHANGE /tmp/file <-> victim)", syscall(276, -100, "/tmp/kcos-src", -100, victim, 2));
    res("open(victim, O_WRONLY|O_APPEND)", open(victim, O_WRONLY | O_APPEND));
    res("open(victim, O_RDWR)", open(victim, O_RDWR));
    res("open(victim, O_RDONLY|O_TRUNC)", open(victim, O_RDONLY | O_TRUNC));
    res("truncate(victim, same size)", ({ stat(victim, &st); truncate(victim, st.st_size); }));
    res("unlink(victim)", unlink(victim));
    res("rename(victim -> /tmp)", rename(victim, "/tmp/kcos-stolen"));
    snprintf(q, sizeof q, "%s.moved", victim);
    res("rename(victim -> same dir)", rename(victim, q));
    res("rmdir(dir)", rmdir(dir));
    res("rename(dir -> /tmp/d)", rename(dir, "/tmp/kcos-d"));
    /* what Landlock does not mediate: metadata */
    stat(victim, &st);
    res("chmod(victim, same mode)", chmod(victim, st.st_mode & 07777));
    res("chmod(victim, +setuid) then back", ({ int r = chmod(victim, (st.st_mode & 07777) | 04000); chmod(victim, st.st_mode & 07777); r; }));
    res("chown(victim, same owner)", chown(victim, st.st_uid, st.st_gid));
    struct timespec ts[2] = {st.st_atim, st.st_mtim};
    res("utimensat(victim, same times)", utimensat(AT_FDCWD, victim, ts, 0));
    res("setxattr(victim, user.kcos)", setxattr(victim, "user.kcos", "x", 1, 0));
    res("removexattr(victim, user.kcos)", removexattr(victim, "user.kcos"));
    res("setxattr(victim, security.capability)", setxattr(victim, "security.capability",
        "\x00\x00\x00\x02\xff\xff\xff\xff\x00\x00\x00\x00\xff\xff\xff\xff\x00\x00\x00\x00", 20, 0));
    res("setxattr(victim, trusted.kcos)", setxattr(victim, "trusted.kcos", "x", 1, 0));
    int fd = open(victim, O_RDONLY);
    int fl = 0;
    res("ioctl(victim, FS_IOC_GETFLAGS)", ioctl(fd, 0x80086601, &fl));
    int im = fl | 0x10;
    res("ioctl(victim, FS_IOC_SETFLAGS immutable)", ioctl(fd, 0x40086602, &im));
    close(fd);
    unlink("/tmp/kcos-src");
}

static long n_ok, n_denied, n_other, n_files;
static void walk(const char *dir, int depth, int mode) {
    DIR *d = opendir(dir);
    struct dirent *e;
    char p[4096];
    if (!d) return;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (snprintf(p, sizeof p, "%s/%s", dir, e->d_name) >= (int)sizeof p) continue;
        struct stat st;
        if (lstat(p, &st)) continue;
        if (S_ISDIR(st.st_mode)) {
            /* one process's files are enough: skip the other PIDs and the task copies */
            if (mode == 0 && depth == 0 && e->d_name[0] >= '0' && e->d_name[0] <= '9' && atoi(e->d_name) != 1 && atoi(e->d_name) != getpid()) continue;
            if (!strcmp(e->d_name, "task") || !strcmp(e->d_name, "map_files")) continue;
            if (depth < 24) walk(p, depth + 1, mode);
            continue;
        }
        if (S_ISLNK(st.st_mode)) continue;
        if (mode == 0 && !S_ISREG(st.st_mode)) continue;
        n_files++;
        int flagsets[2] = {O_WRONLY | O_APPEND, O_RDONLY};
        for (int k = 0; k < (mode == 0 ? 1 : 2); k++) {
            int fd = open(p, flagsets[k] | O_NONBLOCK | O_NOCTTY | O_CLOEXEC);
            if (fd >= 0) {
                n_ok++;
                printf("OPENED for %s: %s (mode %o, rdev %u:%u)\n", k == 0 ? "append" : "read", p, st.st_mode, major(st.st_rdev), minor(st.st_rdev));
                close(fd);
            } else if (errno == EACCES) n_denied++;
            else { n_other++; if (mode == 1) printf("other for %s: %s: errno %d (%s)\n", k == 0 ? "append" : "read", p, errno, strerror(errno)); }
        }
    }
    closedir(d);
}

static void cmd_core(const char *dir) {
    struct rlimit r = {RLIM_INFINITY, RLIM_INFINITY};
    char p[512];
    res("setrlimit(CORE, unlimited)", setrlimit(RLIMIT_CORE, &r));
    pid_t c = fork();
    if (c == 0) {
        if (chdir(dir)) _exit(3);
        prctl(PR_SET_DUMPABLE, 1);
        raise(SIGSEGV);
        _exit(4);
    }
    int st;
    waitpid(c, &st, 0);
    printf("child in %s: %s%s\n", dir, WIFSIGNALED(st) ? "killed by signal" : "exited", WIFSIGNALED(st) && WCOREDUMP(st) ? ", kernel says core dumped" : "");
    DIR *d = opendir(dir);
    struct dirent *e;
    int found = 0;
    while (d && (e = readdir(d)))
        if (!strncmp(e->d_name, "core", 4)) {
            struct stat s;
            snprintf(p, sizeof p, "%s/%s", dir, e->d_name);
            stat(p, &s);
            printf("FOUND %s (%lld bytes, mode %o)\n", p, (long long)s.st_size, s.st_mode & 07777);
            found = 1;
            res("unlink(core file)", unlink(p));
        }
    if (!found) printf("no core file in %s\n", dir);
}

static void cmd_ipc(void) {
    int id = shmget(IPC_PRIVATE, 4096, 0600 | IPC_CREAT);
    res("shmget", id); if (id >= 0) shmctl(id, IPC_RMID, 0);
    id = msgget(IPC_PRIVATE, 0600 | IPC_CREAT);
    res("msgget", id); if (id >= 0) msgctl(id, IPC_RMID, 0);
    id = semget(IPC_PRIVATE, 1, 0600 | IPC_CREAT);
    res("semget", id); if (id >= 0) semctl(id, 0, IPC_RMID);
    long mq = syscall(180 /*mq_open*/, "kcosq", O_CREAT | O_RDWR, 0600, 0);
    res("mq_open", mq); syscall(181, "kcosq");
    res("inotify_init1", syscall(26, 0));
    res("signalfd4", ({ sigset_t m; sigemptyset(&m); sigaddset(&m, SIGUSR1); syscall(74, -1, &m, 8, 0); }));
    res("landlock_create_ruleset(VERSION)", syscall(444, 0, 0, 1));
    /* A second filter that allows everything cannot undo the first. */
    struct { unsigned short c; unsigned char jt, jf; unsigned k; } allow[] = {{6, 0, 0, 0x7fff0000}};
    struct { unsigned short len; void *f; } prog = {1, allow};
    if (fork() == 0) {
        res("seccomp(SET_MODE_FILTER, allow-all)", syscall(277, 1, 0, &prog));
        res("  memfd_create after allow-all filter", syscall(279, "x", 0));
        res("  unshare(0) after allow-all filter", syscall(97, 0));
        _exit(0);
    }
    wait(0);
    if (fork() == 0) {
        long l = syscall(277, 1, 8 /*NEW_LISTENER*/, &prog);
        res("seccomp(NEW_LISTENER)", l);
        _exit(0);
    }
    wait(0);
    if (fork() == 0) {
        /* a ruleset that handles nothing new and allows everything it handles */
        unsigned long attr[3] = {1 /*EXECUTE*/, 0, 0};
        long rs = syscall(444, attr, 8, 0);
        res("landlock_create_ruleset(EXECUTE)", rs);
        int root = open("/", O_PATH);
        struct __attribute__((packed)) { unsigned long acc; int fd; } rule = {1, root};
        res("landlock_add_rule(/ : EXECUTE)", syscall(445, rs, 1, &rule, 0));
        res("landlock_restrict_self", syscall(446, rs, 0));
        int t = open("/tmp/kcos-ll", O_WRONLY | O_CREAT | O_TRUNC, 0755);
        if (t >= 0) { copy_to("/proc/self/exe", t); close(t); }
        child_exec("  execve(/tmp copy) after stacking an allow-exec-everywhere domain", "/tmp/kcos-ll", -1);
        unlink("/tmp/kcos-ll");
        _exit(0);
    }
    wait(0);
    res("io_setup (aio)", syscall(0, 1, zero));
    res("timerfd_create", syscall(85, 1, 0));
    res("eventfd2", syscall(19, 0, 0));
    res("get_robust_list(1)", syscall(100, 1, zero, zero + 8));
    res("sched_setattr(self, DEADLINE)", ({ unsigned long a[7] = {0}; ((unsigned *)a)[0] = 56; ((unsigned *)a)[1] = 6; a[3] = 1000000; a[4] = 10000000; a[5] = 10000000; syscall(274, 0, a, 0); }));
    res("sync", syscall(81));
}

static void cmd_cpukill(void) {
    struct rlimit r = {1, 1};
    res("prlimit64(1, RLIMIT_CPU, 1s)", prlimit(1, RLIMIT_CPU, &r, 0));
    time_t end = time(0) + 40;
    long sent = 0;
    while (time(0) < end) {
        for (int i = 0; i < 2000; i++) if (kill(1, SIGURG) == 0) sent++;
    }
    printf("still here after %ld signals to PID 1\n", sent);
}

int main(int argc, char **argv) {
    const char *c = argc > 1 ? argv[1] : "";
    setvbuf(stdout, 0, _IOLBF, 0);
    if (!strcmp(c, "hello")) { printf("BROUGHT PROGRAM RUNNING as %s (pid %d)\n", argv[0], getpid()); return 0; }
    if (!strcmp(c, "sys")) cmd_sys();
    else if (!strcmp(c, "ns")) cmd_ns();
    else if (!strcmp(c, "socks")) cmd_socks(argc > 2 && !strcmp(argv[2], "vsock"));
    else if (!strcmp(c, "caps")) cmd_caps();
    else if (!strcmp(c, "ids")) cmd_ids();
    else if (!strcmp(c, "pid1")) cmd_pid1();
    else if (!strcmp(c, "exec") && argc > 2) cmd_exec(argv[2], argc - 3, argv + 3);
    else if (!strcmp(c, "writes") && argc > 3) cmd_writes(argv[2], argv[3]);
    else if (!strcmp(c, "wr")) for (int i = 2; i < argc; i++) try_open("append", argv[i], O_WRONLY | O_APPEND);
    else if (!strcmp(c, "rd")) for (int i = 2; i < argc; i++) try_open("read ", argv[i], O_RDONLY);
    else if (!strcmp(c, "scanw") && argc > 2) {
        walk(argv[2], 0, 0);
        printf("scanw %s: %ld regular files tried, %ld opened, %ld EACCES, %ld other errors\n", argv[2], n_files, n_ok, n_denied, n_other);
    } else if (!strcmp(c, "scandev")) {
        walk("/dev", 0, 1);
        printf("scandev: %ld nodes tried twice (append, read), %ld opens succeeded, %ld EACCES, %ld other errors\n", n_files, n_ok, n_denied, n_other);
    } else if (!strcmp(c, "core") && argc > 2) cmd_core(argv[2]);
    else if (!strcmp(c, "ipc")) cmd_ipc();
    else if (!strcmp(c, "cpukill")) cmd_cpukill();
    else { fprintf(stderr, "usage: see esc.c\n"); return 2; }
    return 0;
}
