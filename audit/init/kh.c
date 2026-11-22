/* kh: static helper for the init audit. Built by build.sh into the image
 * kcos-audit-init-img at /bb/kh. Every mode is small and does one thing. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static void msleep(long ms) {
    struct timespec ts = {ms / 1000, (ms % 1000) * 1000000L};
    while (nanosleep(&ts, &ts) < 0 && errno == EINTR) {}
}

/* The kernel's struct sigaction on arm64: handler, flags, restorer, mask. */
static long ksigaction(int sig, void *handler) {
    unsigned long act[4] = {(unsigned long)handler, 0, 0, ~0UL};
    return syscall(SYS_rt_sigaction, sig, act, 0, 8);
}
static void unblock_all(void) {
    unsigned long none = 0;
    syscall(SYS_rt_sigprocmask, 2, &none, 0, 8);
}

static int fin;
static void rec_handler(int sig) {
    char b[8];
    int n = 0;
    if (sig >= 10) b[n++] = '0' + sig / 10;
    b[n++] = '0' + sig % 10;
    b[n++] = '\n';
    write(1, b, n);
    if (sig == fin) _exit(0);
}

/* rec FIN: print the number of every signal received; exit 0 on FIN. */
static int rec(int f) {
    fin = f;
    for (int s = 1; s <= 64; s++)
        if (s != 9 && s != 19) ksigaction(s, rec_handler);
    unblock_all();
    write(1, "ready\n", 6);
    for (;;) pause();
}

/* selfkill N [core]: die of signal N with the default action. */
static int selfkill(int sig, int core) {
    struct rlimit rl = {core ? RLIM_INFINITY : 0, core ? RLIM_INFINITY : 0};
    setrlimit(RLIMIT_CORE, &rl);
    ksigaction(sig, 0);
    unblock_all();
    syscall(SYS_kill, getpid(), sig);
    msleep(300);
    return 99; /* the signal did not end the process */
}

/* flood TARGET NPROC SECS SIG...: NPROC processes send the signals to TARGET
 * in a tight loop for SECS seconds. */
static int flood(int target, int nproc, int secs, char **sigs, int nsig) {
    for (int i = 0; i < nproc; i++) {
        if (fork() == 0) {
            time_t end = time(0) + secs;
            unsigned long k = 0;
            while (time(0) < end)
                for (int j = 0; j < 4096; j++) syscall(SYS_kill, target, atoi(sigs[k++ % nsig]));
            if (getenv("KH_VERBOSE")) printf("flooder %d: %lu signals sent\n", getpid(), k);
            _exit(0);
        }
    }
    return 0;
}

/* tally SECS: count the signals received for SECS seconds, then say so. */
static volatile unsigned long tallied;
static void tally_handler(int sig) { (void)sig; tallied++; }
static int tally(int secs) {
    for (int s = 1; s <= 64; s++)
        if (s != 9 && s != 19 && s != 17) ksigaction(s, tally_handler);
    unblock_all();
    time_t end = time(0) + secs;
    while (time(0) < end) msleep(100);
    printf("command: %lu signals received in %d s\n", tallied, secs);
    return 7;
}

/* orphans N MS: N grandchildren that outlive their parent by MS ms. */
static int orphans(int n, int ms) {
    int made = 0;
    for (int i = 0; i < n; i++) {
        pid_t p = fork();
        if (p < 0) { msleep(1); i--; continue; }
        if (p == 0) {
            pid_t g = fork();
            if (g == 0) { msleep(ms); _exit(0); }
            _exit(g < 0 ? 1 : 0);
        }
        int st;
        waitpid(p, &st, 0);
        if (WIFEXITED(st) && WEXITSTATUS(st) == 0) made++; else { msleep(1); }
    }
    printf("orphans made: %d\n", made);
    return 0;
}

/* count STATE: how many processes in /proc are in that state (Z, T, ...). */
static int count(char state) {
    int n = 0;
    for (int pid = 1; pid < 4194304; pid++) {
        char path[64], buf[512];
        snprintf(path, sizeof path, "/proc/%d/stat", pid);
        int fd = open(path, O_RDONLY);
        if (fd < 0) { if (pid > 200000) break; continue; }
        int len = read(fd, buf, sizeof buf - 1);
        close(fd);
        if (len <= 0) continue;
        buf[len] = 0;
        char *c = strrchr(buf, ')');
        if (c && c[2] == state) n++;
    }
    printf("%d\n", n);
    return 0;
}

/* wrap TARGET: fork and reap until the newest PID is TARGET-1, so that the
 * next process created in this PID namespace is TARGET. */
static int wrap(int target) {
    long n = 0;
    for (;;) {
        pid_t p = fork();
        if (p == 0) _exit(0);
        if (p < 0) return 1;
        waitpid(p, 0, 0);
        n++;
        if (p == target - 1) break;
        if (n > 9000000) { printf("wrap: PID %d is never handed out\n", target - 1); return 1; }
    }
    printf("wrap: %ld forks, next pid is %d\n", n, target);
    return 0;
}

/* leader SECS: become a process group leader, sleep, say that it lived. */
static int leader(int secs) {
    setpgid(0, 0);
    printf("leader: pid %d pgid %d ppid %d\n", getpid(), getpgrp(), getppid());
    fflush(stdout);
    msleep(secs * 1000L);
    printf("leader: survived\n");
    return 0;
}

/* stubborn SECS [setsid] [name NAME]: ignore every signal, sleep. */
static int stubborn(int argc, char **argv) {
    int secs = atoi(argv[0]);
    for (int s = 1; s <= 64; s++)
        if (s != 9 && s != 19) ksigaction(s, (void *)1);
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "setsid")) {
            if (fork() > 0) _exit(0);
            setsid();
        } else if (!strcmp(argv[i], "name") && i + 1 < argc) {
            if (prctl(PR_SET_NAME, argv[++i]) < 0) perror("PR_SET_NAME");
        }
    }
    msleep(secs * 1000L);
    return 0;
}

/* hopper SECS: ignore signals; fork, let the parent exit, new session, again. */
static int hopper(int secs) {
    time_t end = time(0) + secs;
    for (int s = 1; s <= 64; s++)
        if (s != 9 && s != 19) ksigaction(s, (void *)1);
    while (time(0) < end) {
        pid_t p = fork();
        if (p > 0) _exit(0);
        if (p == 0) setsid();
    }
    return 0;
}

/* bomb SECS: ignore signals and fork without end, in every process. Only
 * ever run with --pids-limit and --memory. */
static int bomb(int secs) {
    time_t end = time(0) + secs;
    for (int s = 1; s <= 64; s++)
        if (s != 9 && s != 19) ksigaction(s, (void *)1);
    while (time(0) < end) {
        pid_t p = fork();
        if (p < 0) msleep(1);
        if (p == 0) setsid(); /* out of the command's process group */
    }
    return 0;
}

/* closefd DIGITS CMD...: close those descriptors, then exec. */
static int closefd(char *digits, char **cmd) {
    for (; *digits; digits++) close(*digits - '0');
    execv(cmd[0], cmd);
    return 111;
}

/* bigexec PROG ARG: exec PROG ARG with as much padding in further arguments
 * as execve accepts, found by trying in a child. */
static int bigexec(char *prog, char *arg) {
    static char chunk[100001];
    memset(chunk, 'A', 100000);
    long lo = 0, hi = 8 * 1024 * 1024 / 100000 * 100000;
    enum { MAXA = 200 };
    char *av[MAXA + 4];
    for (long step = 100000 * 64; step >= 1; step /= 2) {
        for (;;) {
            long want = lo + step;
            if (want > hi) break;
            int n = 0;
            av[n++] = "/bb/busybox";
            av[n++] = "true";
            long left = want;
            static char tail[100001];
            while (left >= 100000 && n < MAXA) { av[n++] = chunk; left -= 100000; }
            memset(tail, 'B', left); tail[left] = 0;
            av[n++] = tail; av[n] = 0;
            pid_t p = fork();
            if (p == 0) { execv("/bb/busybox", av); _exit(errno == E2BIG ? 7 : 8); }
            int st; waitpid(p, &st, 0);
            if (WIFEXITED(st) && WEXITSTATUS(st) == 0) lo = want; else break;
        }
    }
    /* lo bytes of padding fit beside "/bb/busybox true". Give PROG the same
     * total, so that it is at the limit. */
    long pad = lo + (long)strlen("/bb/busybox") + (long)strlen("true") - (long)strlen(prog) - (long)strlen(arg);
    int n = 0;
    av[n++] = prog; av[n++] = arg;
    static char tail2[100001];
    while (pad >= 100000 && n < MAXA) { av[n++] = chunk; pad -= 100000; }
    memset(tail2, 'B', pad); tail2[pad] = 0;
    av[n++] = tail2; av[n] = 0;
    fprintf(stderr, "bigexec: %ld bytes of padding\n", lo);
    execv(prog, av);
    perror("bigexec");
    return 112;
}

/* sigq TARGET SIG N: queue SIG N times with a value. */
static int sigq(int target, int sig, int n) {
    int ok = 0;
    for (int i = 0; i < n; i++) {
        union sigval v = {.sival_int = i};
        if (sigqueue(target, sig, v) == 0) ok++;
    }
    printf("queued %d of %d\n", ok, n);
    return 0;
}

/* presig SIG CMD...: exec CMD with SIG already pending (and so blocked). */
static int presig(int sig, char **cmd) {
    unsigned long set = 1UL << (sig - 1);
    syscall(SYS_rt_sigprocmask, 0, &set, 0, 8);
    syscall(SYS_kill, getpid(), sig);
    execv(cmd[0], cmd);
    return 111;
}

/* ignoring SIG... -- CMD...: exec CMD with those signals ignored. */
static int ignoring(char **argv) {
    for (; *argv && strcmp(*argv, "--"); argv++) ksigaction(atoi(*argv), (void *)1);
    execv(argv[1], argv + 1);
    return 111;
}

int main(int argc, char **argv) {
    setvbuf(stdout, 0, _IOLBF, 0);
    if (argc < 2) return 2;
    char *m = argv[1];
    if (!strcmp(m, "rec")) return rec(atoi(argv[2]));
    if (!strcmp(m, "selfkill")) return selfkill(atoi(argv[2]), argc > 3);
    if (!strcmp(m, "flood")) return flood(atoi(argv[2]), atoi(argv[3]), atoi(argv[4]), argv + 5, argc - 5);
    if (!strcmp(m, "tally")) return tally(atoi(argv[2]));
    if (!strcmp(m, "orphans")) return orphans(atoi(argv[2]), atoi(argv[3]));
    if (!strcmp(m, "count")) return count(argv[2][0]);
    if (!strcmp(m, "wrap")) return wrap(atoi(argv[2]));
    if (!strcmp(m, "leader")) return leader(atoi(argv[2]));
    if (!strcmp(m, "stubborn")) return stubborn(argc - 2, argv + 2);
    if (!strcmp(m, "hopper")) return hopper(atoi(argv[2]));
    if (!strcmp(m, "bomb")) return bomb(atoi(argv[2]));
    if (!strcmp(m, "closefd")) return closefd(argv[2], argv + 3);
    if (!strcmp(m, "bigexec")) return bigexec(argv[2], argv[3]);
    if (!strcmp(m, "sigq")) return sigq(atoi(argv[2]), atoi(argv[3]), atoi(argv[4]));
    if (!strcmp(m, "presig")) return presig(atoi(argv[2]), argv + 3);
    if (!strcmp(m, "ignoring")) return ignoring(argv + 2);
    if (!strcmp(m, "exit")) return atoi(argv[2]);
    if (!strcmp(m, "now")) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); printf("%ld\n", t.tv_sec * 1000 + t.tv_nsec / 1000000); return 0; }
    if (!strcmp(m, "pid")) { printf("%d\n", getpid()); return 0; }
    if (!strcmp(m, "sleepms")) { msleep(atol(argv[2])); return 0; }
    return 2;
}
