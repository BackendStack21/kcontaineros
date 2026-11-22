/* Static probe for the kContainerOS system call filter audit.
 *
 *   sysprobe safe        calls that are harmless with and without the filter
 *   sysprobe initonly    calls that may only be made under init (AF_VSOCK)
 *   sysprobe raw NR...   call each number with six zero arguments (only for
 *                        numbers the filter is expected to refuse)
 *   sysprobe mem         read and write another process's memory via /proc/PID/mem
 *   sysprobe stack       add further seccomp filters and retry a refused call
 *   sysprobe stack-errno0  the same with a filter answering "errno 0"
 *   sysprobe execveat    start a copy of this program from places that hold no programs
 *
 * Output of safe/initonly/raw, one line per call, tab separated:
 *   label  x8(hex)  arg0(hex)  result     result is "ok:N" or "errno:N"
 * Every argument that is a pointer is an invalid address (1) unless the call
 * needs a real one, so nothing is changed where a call is let through.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/uio.h>
#include <sys/wait.h>

typedef unsigned long ul;

static long raw(ul nr, ul a, ul b, ul c, ul d, ul e, ul f) {
    register ul x8 __asm__("x8") = nr;
    register ul x0 __asm__("x0") = a;
    register ul x1 __asm__("x1") = b;
    register ul x2 __asm__("x2") = c;
    register ul x3 __asm__("x3") = d;
    register ul x4 __asm__("x4") = e;
    register ul x5 __asm__("x5") = f;
    __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory", "cc");
    return (long)x0;
}

static long show(const char *label, ul nr, ul a, ul b, ul c, ul d, ul e, ul f) {
    long r = raw(nr, a, b, c, d, e, f);
    if (r < 0 && r > -4096)
        printf("%s\t%lx\t%lx\terrno:%ld\n", label, nr, a, -r);
    else
        printf("%s\t%lx\t%lx\tok:%ld\n", label, nr, a, r);
    fflush(stdout);
    return r;
}

#define BAD 1UL                /* an address that is never mapped */
#define NOPID 0x7ffffff0UL     /* a PID that does not exist */
#define NOFD ((ul)-1)
#define HI (1UL << 32)

static void safe(void) {
    ul me = getpid();
    static char name[] = "x";
    long r;

    /* --- the README's "refused" list and the rest of DENIED --- */
    r = show("memfd_create", 279, (ul)name, 0, 0, 0, 0, 0);
    if (r >= 0) close(r);
    r = show("memfd_create(x8 high bits set)", HI | 279, (ul)name, 0, 0, 0, 0, 0);
    if (r >= 0) close(r);
    r = show("memfd_secret", 447, 0, 0, 0, 0, 0, 0);
    if (r >= 0) close(r);
    show("ptrace(PEEKDATA,nopid)", 117, 2, NOPID, 0, 0, 0, 0);
    show("ptrace(SEIZE,nopid)", 117, 0x4206, NOPID, 0, 0, 0, 0);
    show("process_vm_readv(self,0 iov)", 270, me, 0, 0, 0, 0, 0);
    show("process_vm_writev(self,0 iov)", 271, me, 0, 0, 0, 0, 0);
    show("kcmp(self,self,FILE,0,0)", 272, me, me, 0, 0, 0, 0);
    show("pidfd_getfd(-1)", 438, NOFD, 0, 0, 0, 0, 0);
    show("process_madvise(-1)", 440, NOFD, 0, 0, 0, 0, 0);
    show("process_mrelease(-1)", 448, NOFD, 0, 0, 0, 0, 0);
    show("unshare(0)", 97, 0, 0, 0, 0, 0, 0);
    show("setns(-1)", 268, NOFD, 0, 0, 0, 0, 0);
    show("umount2(bad)", 39, BAD, 0, 0, 0, 0, 0);
    show("mount(bad)", 40, BAD, BAD, BAD, 0, 0, 0);
    show("pivot_root(bad)", 41, BAD, BAD, 0, 0, 0, 0);
    show("chroot(bad)", 51, BAD, 0, 0, 0, 0, 0);
    show("open_tree(-1,bad)", 428, NOFD, BAD, 0, 0, 0, 0);
    show("move_mount(-1,bad)", 429, NOFD, BAD, NOFD, BAD, 0, 0);
    show("fsopen(bad)", 430, BAD, 0, 0, 0, 0, 0);
    show("fsconfig(-1)", 431, NOFD, 0, 0, 0, 0, 0);
    show("fsmount(-1)", 432, NOFD, 0, 0, 0, 0, 0);
    show("fspick(-1,bad)", 433, NOFD, BAD, 0, 0, 0, 0);
    show("mount_setattr(-1,bad)", 442, NOFD, BAD, 0, 0, 0, 0);
    show("name_to_handle_at(-1,bad)", 264, NOFD, BAD, BAD, BAD, 0, 0);
    show("open_by_handle_at(-1,bad)", 265, NOFD, BAD, 0, 0, 0, 0);
    show("kexec_load(bad flags)", 104, 0, 0, 0, 0x8000, 0, 0);
    show("kexec_file_load(-1,bad flags)", 294, NOFD, NOFD, 0, 0, 0x8000, 0);
    show("init_module(bad,0)", 105, BAD, 0, BAD, 0, 0, 0);
    show("delete_module(bad)", 106, BAD, 0, 0, 0, 0, 0);
    show("finit_module(-1)", 273, NOFD, BAD, 0, 0, 0, 0);
    show("bpf(bad cmd)", 280, 0xffff, 0, 0, 0, 0, 0);
    show("perf_event_open(bad)", 241, BAD, 0, NOFD, NOFD, 0, 0);
    show("userfaultfd(bad flags)", 282, 0xffff, 0, 0, 0, 0, 0);
    show("io_uring_setup(0,bad)", 425, 0, BAD, 0, 0, 0, 0);
    show("io_uring_enter(-1)", 426, NOFD, 0, 0, 0, 0, 0);
    show("io_uring_register(-1)", 427, NOFD, 0, 0, 0, 0, 0);
    show("add_key(bad)", 217, BAD, BAD, 0, 0, 0, 0);
    show("request_key(bad)", 218, BAD, BAD, 0, 0, 0, 0);
    show("keyctl(bad op)", 219, 0xffff, 0, 0, 0, 0, 0);
    show("lookup_dcookie", 18, 0, BAD, 0, 0, 0, 0);
    show("nfsservctl", 42, 0, 0, 0, 0, 0, 0);
    show("vhangup", 58, 0, 0, 0, 0, 0, 0);
    show("quotactl(bad cmd)", 60, 0xffffffff, BAD, 0, 0, 0, 0);
    show("quotactl_fd(-1)", 443, NOFD, 0xffffffff, 0, 0, 0, 0);
    show("acct(bad)", 89, BAD, 0, 0, 0, 0, 0);
    show("syslog(SIZE_BUFFER)", 116, 10, 0, 0, 0, 0, 0);
    show("reboot(bad magic)", 142, 0, 0, 0, 0, 0, 0);
    show("sethostname(bad,-1)", 161, BAD, NOFD, 0, 0, 0, 0);
    show("setdomainname(bad,-1)", 162, BAD, NOFD, 0, 0, 0, 0);
    show("clock_settime(REALTIME,bad)", 112, 0, BAD, 0, 0, 0, 0);
    show("settimeofday(bad,0)", 170, BAD, 0, 0, 0, 0, 0);
    show("adjtimex(bad)", 171, BAD, 0, 0, 0, 0, 0);
    show("clock_adjtime(REALTIME,bad)", 266, 0, BAD, 0, 0, 0, 0);
    show("swapon(bad)", 224, BAD, 0, 0, 0, 0, 0);
    show("swapoff(bad)", 225, BAD, 0, 0, 0, 0, 0);
    show("fanotify_init(bad flags)", 262, 0xffffffff, 0, 0, 0, 0, 0);
    show("lsm_set_self_attr(0,bad)", 460, 0, BAD, 0, 0, 0, 0);
    show("mbind(0,0,DEFAULT)", 235, 0, 0, 0, 0, 0, 0);
    show("set_mempolicy(bad mode)", 237, 0xffff, 0, 0, 0, 0, 0);
    show("migrate_pages(nopid)", 238, NOPID, 0, 0, 0, 0, 0);
    show("move_pages(nopid)", 239, NOPID, 0, 0, 0, 0, 0);
    show("set_mempolicy_home_node(bad)", 450, 0, 0, 0, 0xffff, 0, 0);

    /* --- clone / clone3: CLONE_SIGHAND without CLONE_VM is EINVAL in the
     * kernel, so no process is ever created where the filter lets it through */
    show("clone3(bad,0)", 435, BAD, 0, 0, 0, 0, 0);
    show("clone(NEWNS|SIGHAND)", 220, 0x00020000 | 0x800, 0, 0, 0, 0, 0);
    show("clone(NEWCGROUP|SIGHAND)", 220, 0x02000000 | 0x800, 0, 0, 0, 0, 0);
    show("clone(NEWUTS|SIGHAND)", 220, 0x04000000 | 0x800, 0, 0, 0, 0, 0);
    show("clone(NEWIPC|SIGHAND)", 220, 0x08000000 | 0x800, 0, 0, 0, 0, 0);
    show("clone(NEWUSER|SIGHAND)", 220, 0x10000000 | 0x800, 0, 0, 0, 0, 0);
    show("clone(NEWPID|SIGHAND)", 220, 0x20000000 | 0x800, 0, 0, 0, 0, 0);
    show("clone(NEWNET|SIGHAND)", 220, 0x40000000 | 0x800, 0, 0, 0, 0, 0);
    show("clone(hi32|NEWUSER|SIGHAND)", 220, HI | 0x10000000 | 0x800, 0, 0, 0, 0, 0);
    show("clone(NEW* only in hi32|SIGHAND)", 220, (0x7e020000UL << 32) | 0x800, 0, 0, 0, 0, 0);
    show("clone(SIGHAND)", 220, 0x800, 0, 0, 0, 0, 0);
    show("clone(bit31|SIGHAND)", 220, 0x80000000UL | 0x800, 0, 0, 0, 0, 0);
    {
        long pid = raw(220, SIGCHLD, 0, 0, 0, 0, 0);
        if (pid == 0) raw(93, 0, 0, 0, 0, 0, 0);
        if (pid > 0) { int st; waitpid(pid, &st, 0); pid = 0; }
        if (pid < 0) printf("clone(SIGCHLD) fork\t%x\t%x\terrno:%ld\n", 220, SIGCHLD, -pid);
        else printf("clone(SIGCHLD) fork\t%x\t%x\tok:0\n", 220, SIGCHLD);
        fflush(stdout);
    }

    /* --- personality --- */
    show("personality(query)", 92, 0xffffffff, 0, 0, 0, 0, 0);
    show("personality(query, hi32 set)", 92, HI | 0xffffffff, 0, 0, 0, 0, 0);
    show("personality(0)", 92, 0, 0, 0, 0, 0, 0);
    show("personality(ADDR_NO_RANDOMIZE)", 92, 0x0040000, 0, 0, 0, 0, 0);
    raw(92, 0, 0, 0, 0, 0, 0);
    show("personality(hi32|ADDR_NO_RANDOMIZE)", 92, HI | 0x0040000, 0, 0, 0, 0, 0);
    raw(92, 0, 0, 0, 0, 0, 0);
    show("personality(PER_LINUX32)", 92, 8, 0, 0, 0, 0, 0);
    raw(92, 0, 0, 0, 0, 0, 0);
    show("personality(READ_IMPLIES_EXEC)", 92, 0x0400000, 0, 0, 0, 0, 0);
    raw(92, 0, 0, 0, 0, 0, 0);
    show("personality(1)", 92, 1, 0, 0, 0, 0, 0);
    raw(92, 0, 0, 0, 0, 0, 0);
    show("personality(0xfffffffe)", 92, 0xfffffffe, 0, 0, 0, 0, 0);
    raw(92, 0, 0, 0, 0, 0, 0);
    show("personality(hi32 only)", 92, HI, 0, 0, 0, 0, 0);

    /* --- socket: ordinary families (never AF_VSOCK here) --- */
    r = show("socket(AF_UNIX)", 198, 1, 1, 0, 0, 0, 0);
    if (r >= 0) close(r);
    r = show("socket(AF_INET)", 198, 2, 1, 0, 0, 0, 0);
    if (r >= 0) close(r);
    r = show("socket(AF_INET6)", 198, 10, 1, 0, 0, 0, 0);
    if (r >= 0) close(r);
    r = show("socket(AF_NETLINK,ROUTE)", 198, 16, 3, 0, 0, 0, 0);
    if (r >= 0) close(r);
    r = show("socket(AF_PACKET) [needs CAP_NET_RAW]", 198, 17, 3, 0, 0, 0, 0);
    if (r >= 0) close(r);
    r = show("socket(AF_INET,RAW) [needs CAP_NET_RAW]", 198, 2, 3, 1, 0, 0, 0);
    if (r >= 0) close(r);

    /* --- newer than the filter knows, and the edge below it --- */
    show("setxattrat(-1,bad) [463]", 463, NOFD, BAD, 0, BAD, 0, 0);
    show("removexattrat(-1,bad) [466, newest known]", 466, NOFD, BAD, 0, BAD, 0, 0);
    show("nr 467 (open_tree_attr)", 467, NOFD, BAD, 0, 0, 0, 0);
    show("nr 468 (file_getattr)", 468, NOFD, BAD, 0, 0, 0, 0);
    show("nr 469 (file_setattr)", 469, NOFD, BAD, 0, 0, 0, 0);
    show("nr 470 (listns)", 470, 0, 0, 0, 0, 0, 0);
    show("nr 600", 600, 0, 0, 0, 0, 0, 0);
    show("nr 1100", 1100, 0, 0, 0, 0, 0, 0);
    show("nr 0x7fffffff", 0x7fffffff, 0, 0, 0, 0, 0, 0);
    show("nr 0x80000000", 0x80000000UL, 0, 0, 0, 0, 0, 0);
    show("nr 0xfffffffe", 0xfffffffeUL, 0, 0, 0, 0, 0, 0);

    /* --- allowed by the filter; what they return depends on capabilities --- */
    show("prctl(KCOS probe)", 167, 0x4b434f53, 0, 0, 0, 0, 0);
    show("prctl(KCOF probe)", 167, 0x4b434f46, 0, 0, 0, 0, 0);
    show("prctl(hi32|KCOS probe)", 167, HI | 0x4b434f53, 0, 0, 0, 0, 0);
    show("prctl(GET_NO_NEW_PRIVS)", 167, 39, 0, 0, 0, 0, 0);
    show("prctl(GET_SECCOMP)", 167, 21, 0, 0, 0, 0, 0);
    show("prctl(GET_DUMPABLE)", 167, 3, 0, 0, 0, 0, 0);
    show("prctl(CAPBSET_READ,SYS_ADMIN)", 167, 23, 21, 0, 0, 0, 0);
    show("prctl(SET_MM,bad) [needs CAP_SYS_RESOURCE]", 167, 35, 0xffff, 0, 0, 0, 0);
    show("prctl(SET_SECUREBITS,0) [needs CAP_SETPCAP]", 167, 28, 0, 0, 0, 0, 0);
    show("prctl(SET_NO_NEW_PRIVS,0) [cannot be cleared]", 167, 38, 0, 0, 0, 0, 0);
    {
        unsigned int allow = 0x7fff0000;
        show("seccomp(GET_ACTION_AVAIL,ALLOW)", 277, 2, 0, (ul)&allow, 0, 0, 0);
        show("seccomp(SET_MODE_STRICT bad flags)", 277, 0, 1, 0, 0, 0, 0);
    }
    show("execveat(-1,bad)", 281, NOFD, BAD, 0, 0, 0, 0);
    r = show("pidfd_open(self)", 434, me, 0, 0, 0, 0, 0);
    if (r >= 0) {
        show("pidfd_send_signal(self,0)", 424, r, 0, 0, 0, 0, 0);
        close(r);
    }
    r = show("pidfd_open(1)", 434, 1, 0, 0, 0, 0, 0);
    if (r >= 0) close(r);
    show("landlock_create_ruleset(VERSION)", 444, 0, 0, 1, 0, 0, 0);
    show("get_mempolicy(0)", 236, 0, 0, 0, 0, 0, 0);
    {
        ul lim[2];
        show("prlimit64(pid 1,NOFILE,get)", 261, 1, 7, 0, (ul)lim, 0, 0);
        show("get_robust_list(pid 1)", 100, 1, BAD, BAD, 0, 0, 0);
        show("sched_getaffinity(pid 1)", 123, 1, 8, (ul)lim, 0, 0, 0);
    }
    show("setgroups(0) [needs CAP_SETGID]", 159, 0, 0, 0, 0, 0, 0);
    show("setpriority(self,-1) [needs CAP_SYS_NICE]", 140, 0, 0, (ul)-1, 0, 0, 0);
    raw(140, 0, 0, 0, 0, 0, 0);
    show("statmount(bad)", 457, BAD, BAD, 0, 0, 0, 0);
    show("listmount(bad)", 458, BAD, BAD, 0, 0, 0, 0);
    show("lsm_get_self_attr(0,bad)", 459, 0, BAD, BAD, 0, 0, 0);
    show("lsm_list_modules(bad)", 461, BAD, BAD, 0, 0, 0, 0);
    show("fanotify_mark(-1)", 263, NOFD, 0, 0, 0, 0, 0);
    show("openat2(-1,bad)", 437, NOFD, BAD, BAD, 24, 0, 0);
    show("ioctl(-1,TIOCSTI)", 29, NOFD, 0x5412, BAD, 0, 0, 0);
    show("syncfs(-1)", 267, NOFD, 0, 0, 0, 0, 0);
    show("mknodat(-1,bad,S_IFBLK)", 33, NOFD, BAD, 0060600, 0x0800, 0, 0);
    show("capget(bad)", 90, BAD, 0, 0, 0, 0, 0);
}

static void initonly(void) {
    long r;
    int sv[2];
    r = show("socket(AF_VSOCK,STREAM)", 198, 40, 1, 0, 0, 0, 0);
    if (r >= 0) close(r);
    r = show("socket(AF_VSOCK,DGRAM)", 198, 40, 2, 0, 0, 0, 0);
    if (r >= 0) close(r);
    r = show("socket(AF_VSOCK,SEQPACKET|CLOEXEC)", 198, 40, 5 | 02000000, 0, 0, 0, 0);
    if (r >= 0) close(r);
    r = show("socket(hi32|AF_VSOCK)", 198, HI | 40, 1, 0, 0, 0, 0);
    if (r >= 0) close(r);
    r = show("socket(0xffffffff00000028)", 198, 0xffffffff00000028UL, 1, 0, 0, 0, 0);
    if (r >= 0) close(r);
    r = show("socketpair(AF_VSOCK)", 199, 40, 1, 0, (ul)sv, 0, 0);
    if (r >= 0) { close(sv[0]); close(sv[1]); }
}

/* Two children of this process: a victim holding a buffer, and an attacker
 * that is not its ancestor and goes through /proc/VICTIM/mem. */
static char secret[32] = "ORIGINAL-SECRET";
static const char readonly[32] = "READONLY-ORIGINAL";

static void mem(void) {
    int go[2], done[2];
    if (pipe(go) || pipe(done)) return;
    pid_t victim = fork();
    if (victim == 0) {
        char c;
        close(go[1]);
        read(go[0], &c, 1);                 /* wait for the attacker */
        printf("victim: writable buffer now \"%s\"\n", secret);
        printf("victim: read-only buffer now \"%s\"\n", (const char *)(volatile const char *)readonly);
        fflush(stdout);
        _exit(0);
    }
    pid_t attacker = fork();
    if (attacker == 0) {
        char path[64], buf[32] = {0};
        snprintf(path, sizeof path, "/proc/%d/mem", victim);
        printf("attacker: uid %d, victim is a sibling process\n", getuid());
        struct iovec l = {buf, 15}, rm = {secret, 15};
        long r = raw(270, victim, (ul)&l, 1, (ul)&rm, 1, 0);
        printf("attacker: process_vm_readv -> %s\n", r < 0 ? strerror(-r) : "allowed");
        int fd = open(path, O_RDONLY);
        if (fd < 0) printf("attacker: open %s for reading: %s\n", "/proc/VICTIM/mem", strerror(errno));
        else {
            ssize_t n = pread(fd, buf, 15, (off_t)(ul)secret);
            if (n < 0) printf("attacker: read of victim memory: %s\n", strerror(errno));
            else printf("attacker: read %zd bytes of victim memory: \"%s\"\n", n, buf);
            close(fd);
        }
        fd = open(path, O_RDWR);
        if (fd < 0) printf("attacker: open %s for writing: %s\n", "/proc/VICTIM/mem", strerror(errno));
        else {
            ssize_t n = pwrite(fd, "TAMPERED-SECRET", 15, (off_t)(ul)secret);
            if (n < 0) printf("attacker: write to victim memory: %s\n", strerror(errno));
            else printf("attacker: wrote %zd bytes into victim memory\n", n);
            n = pwrite(fd, "READONLY-TAMPERED", 17, (off_t)(ul)readonly);
            if (n < 0) printf("attacker: write to victim read-only page: %s\n", strerror(errno));
            else printf("attacker: wrote %zd bytes into a read-only page of the victim\n", n);
            close(fd);
        }
        fd = open("/proc/1/mem", O_RDONLY);
        if (fd < 0) printf("attacker: open /proc/1/mem for reading: %s\n", strerror(errno));
        else {
            ssize_t n = pread(fd, buf, 4, (off_t)(ul)secret);
            printf("attacker: /proc/1/mem opened, read -> %s\n", n < 0 ? strerror(errno) : "data");
            close(fd);
        }
        fflush(stdout);
        _exit(0);
    }
    int st;
    waitpid(attacker, &st, 0);
    write(go[1], "x", 1);
    waitpid(victim, &st, 0);
}

/* A process can add filters. The kernel takes the most restrictive answer
 * of all of them, so nothing added later can turn a refusal into a call
 * that runs. */
static void memfd_after(const char *label) {
    static char name[] = "kcos-audit";
    char link[64] = {0}, path[64];
    long r = show(label, 279, (ul)name, 0, 0, 0, 0, 0);
    if (r < 0) return;
    snprintf(path, sizeof path, "/proc/self/fd/%ld", r);
    if (readlink(path, link, sizeof link - 1) < 0) strcpy(link, "(nothing)");
    printf("    descriptor %ld is %s: %s\n", r, link,
           strstr(link, "memfd:kcos-audit") ? "A MEMORY FILE WAS CREATED" : "no memory file was created");
    fflush(stdout);
}

static void stack(int errno0) {
    /* struct sock_filter { u16 code; u8 jt, jf; u32 k; } */
    struct { unsigned short code; unsigned char jt, jf; unsigned int k; } allow_all[] = {
        {0x06, 0, 0, 0x7fff0000},
    }, notify[] = {
        {0x20, 0, 0, 0},
        {0x15, 0, 1, 279},
        {0x06, 0, 0, 0x7fc00000},   /* SECCOMP_RET_USER_NOTIF */
        {0x06, 0, 0, 0x7fff0000},
    }, fake_ok[] = {
        {0x20, 0, 0, 0},
        {0x15, 0, 1, 279},
        {0x06, 0, 0, 0x00050000},   /* SECCOMP_RET_ERRNO | 0: returns 0 without running the call */
        {0x06, 0, 0, 0x7fff0000},
    };
    struct { unsigned short len; void *f; } p1 = {1, allow_all}, p2 = {4, notify}, p3 = {4, fake_ok};
    raw(167, 38, 1, 0, 0, 0, 0);            /* no_new_privs, for the run without init */
    memfd_after("before: memfd_create");
    if (errno0) {
        show("seccomp(add ERRNO(0) filter for memfd_create)", 277, 1, 0, (ul)&p3, 0, 0, 0);
        memfd_after("after ERRNO(0): memfd_create");
        return;
    }
    show("seccomp(add allow-all filter)", 277, 1, 0, (ul)&p1, 0, 0, 0);
    memfd_after("after allow-all: memfd_create");
    show("seccomp(add USER_NOTIF filter, NEW_LISTENER)", 277, 1, 8, (ul)&p2, 0, 0, 0);
    fflush(stdout);
    /* Where the call is let through as far as this filter, it waits for a
     * supervisor that never answers: do it in a child and end that. (This
     * process may be PID 1 of its container, which no alarm would end.) */
    pid_t pid = fork();
    if (pid == 0) {
        memfd_after("after USER_NOTIF: memfd_create");
        _exit(0);
    }
    for (int i = 0; i < 30; i++) {
        int st;
        if (waitpid(pid, &st, WNOHANG) == pid) return;
        usleep(100000);
    }
    kill(pid, SIGKILL);
    waitpid(pid, NULL, 0);
    printf("after USER_NOTIF: memfd_create\tblocked for 3 s waiting for a supervisor; ended\n");
}

/* execveat and files that are not in a program directory. */
static int copy_self(int out) {
    char buf[65536];
    int in = open("/proc/self/exe", O_RDONLY);
    ssize_t n;
    if (in < 0) return -1;
    while ((n = read(in, buf, sizeof buf)) > 0)
        if (write(out, buf, n) != n) { close(in); return -1; }
    close(in);
    return 0;
}

static void try_exec(const char *label, long fd, const char *path, ul flags) {
    static char a0[] = "sysprobe", a1[] = "executed";
    char *argv[] = {a0, a1, NULL}, *envp[] = {NULL};
    printf("%s: ", label);
    fflush(stdout);
    pid_t pid = fork();
    if (pid == 0) {
        long r = raw(281, fd, (ul)path, (ul)argv, (ul)envp, flags, 0);
        printf("execveat -> %s\n", strerror(-r));
        fflush(stdout);
        _exit(0);
    }
    int st;
    waitpid(pid, &st, 0);
}

static void execveat_test(void) {
    int fd, w;
    try_exec("the probe itself, in a program directory", AT_FDCWD, "/bb/sysprobe", 0);
    fd = open("/bb", O_RDONLY | O_DIRECTORY);
    try_exec("the probe itself, relative to a descriptor of /bb", fd, "sysprobe", 0);
    close(fd);

    w = open("/tmp/kcos-audit-x", O_WRONLY | O_CREAT | O_TRUNC, 0755);
    if (w < 0 || copy_self(w)) { printf("cannot write /tmp/kcos-audit-x: %s\n", strerror(errno)); return; }
    close(w);
    try_exec("copy in /tmp, by path", AT_FDCWD, "/tmp/kcos-audit-x", 0);
    fd = open("/tmp/kcos-audit-x", O_PATH);
    try_exec("copy in /tmp, by O_PATH descriptor and AT_EMPTY_PATH", fd, "", 0x1000);
    close(fd);
    fd = open("/tmp/kcos-audit-x", O_RDONLY);
    unlink("/tmp/kcos-audit-x");
    try_exec("copy in /tmp, unlinked, by descriptor", fd, "", 0x1000);
    {
        char p[64];
        snprintf(p, sizeof p, "/proc/self/fd/%d", fd);
        try_exec("copy in /tmp, unlinked, by /proc/self/fd/N", AT_FDCWD, p, 0);
    }
    close(fd);

    w = open("/tmp", O_TMPFILE | O_RDWR, 0755);
    if (w < 0) printf("O_TMPFILE in /tmp: %s\n", strerror(errno));
    else if (!copy_self(w)) {
        char p[64];
        snprintf(p, sizeof p, "/proc/self/fd/%d", w);
        fd = open(p, O_RDONLY);
        close(w);
        try_exec("O_TMPFILE in /tmp (never had a name), by descriptor", fd, "", 0x1000);
        close(fd);
    }
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    if (!strcmp(argv[1], "safe")) safe();
    else if (!strcmp(argv[1], "initonly")) initonly();
    else if (!strcmp(argv[1], "mem")) mem();
    else if (!strcmp(argv[1], "stack")) stack(0);
    else if (!strcmp(argv[1], "stack-errno0")) stack(1);
    else if (!strcmp(argv[1], "execveat")) execveat_test();
    else if (!strcmp(argv[1], "executed")) printf("RAN AS A NEW PROGRAM\n");
    else if (!strcmp(argv[1], "raw")) {
        for (int i = 2; i < argc; i++) {
            char label[32];
            ul nr = strtoul(argv[i], NULL, 0);
            snprintf(label, sizeof label, "raw %lu", nr);
            show(label, nr, 0, 0, 0, 0, 0, 0);
        }
    } else return 2;
    return 0;
}
