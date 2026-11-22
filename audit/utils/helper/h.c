/* Static helper for the utils audit. Lives in /bb (a KCOS_EXEC directory).
 *   h mksock PATH              create a unix socket file
 *   h argv PROG [ARG0 ARG...]  execve(PROG) with exactly this argv (none: argc 0)
 *   h comm NAME SECONDS        set the process name (comm) and sleep
 *   h sleep SECONDS            sleep (so that argv set through "h argv" stays visible)
 *   h nofd N PROG ARGS...      close descriptor N, then exec PROG ARGS
 *   h rlimit-nofile N PROG ARGS...  set RLIMIT_NOFILE, exec
 *   h rlimit-fsize N PROG ARGS...   set RLIMIT_FSIZE (SIGXFSZ ignored), exec
 *   h mkdeep DIR N NAME        DIR, then N-1 directories NAME nested in it, a file "f" at the bottom
 *   h depth DIR NAME           how many levels are left (0: DIR is gone)
 *   h indeep DIR N NAME PROG ARGS...  chdir N-1 levels down, then exec PROG
 *   h flip A B                 swap the names A and B (renameat2 RENAME_EXCHANGE) until killed
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <fcntl.h>
#include <sys/syscall.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>

int main(int argc, char **argv, char **envp) {
    if (argc < 2) return 2;
    if (!strcmp(argv[1], "mksock") && argc == 3) {
        struct sockaddr_un a = { .sun_family = AF_UNIX };
        strncpy(a.sun_path, argv[2], sizeof a.sun_path - 1);
        int s = socket(AF_UNIX, SOCK_STREAM, 0);
        if (s < 0 || bind(s, (struct sockaddr *)&a, sizeof a) < 0) { perror("mksock"); return 1; }
        return 0;
    }
    if (!strcmp(argv[1], "argv") && argc >= 3) {
        execve(argv[2], argv + 3, envp);
        perror("execve"); return 126;
    }
    if (!strcmp(argv[1], "comm") && argc == 4) {
        if (prctl(PR_SET_NAME, argv[2], 0, 0, 0) < 0) { perror("prctl"); return 1; }
        sleep(atoi(argv[3])); return 0;
    }
    if (!strcmp(argv[1], "sleep") && argc == 3) { sleep(atoi(argv[2])); return 0; }
    if (!strcmp(argv[1], "nofd") && argc >= 4) {
        close(atoi(argv[2])); execve(argv[3], argv + 3, envp); perror("execve"); return 126;
    }
    if (!strncmp(argv[1], "rlimit-", 7) && argc >= 4) {
        struct rlimit r = { atol(argv[2]), atol(argv[2]) };
        int which = !strcmp(argv[1], "rlimit-nofile") ? RLIMIT_NOFILE : RLIMIT_FSIZE;
        if (which == RLIMIT_FSIZE) signal(SIGXFSZ, SIG_IGN);
        if (setrlimit(which, &r) < 0) { perror("setrlimit"); return 1; }
        execve(argv[3], argv + 3, envp); perror("execve"); return 126;
    }
    if (!strcmp(argv[1], "mkdeep") && argc == 5) {
        if (mkdir(argv[2], 0755) < 0) { perror("mkdir"); return 1; }
        int fd = open(argv[2], O_RDONLY | O_DIRECTORY), n = atoi(argv[3]);
        for (int i = 1; i < n; i++) {
            if (mkdirat(fd, argv[4], 0755) < 0) { perror("mkdirat"); return 1; }
            int next = openat(fd, argv[4], O_RDONLY | O_DIRECTORY);
            if (next < 0) { perror("openat"); return 1; }
            close(fd); fd = next;
        }
        close(openat(fd, "f", O_WRONLY | O_CREAT, 0644));
        return 0;
    }
    if (!strcmp(argv[1], "depth") && argc == 4) {
        int fd = open(argv[2], O_RDONLY | O_DIRECTORY | O_NOFOLLOW), n = 0;
        while (fd >= 0) {
            n++;
            int next = openat(fd, argv[3], O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
            close(fd); fd = next;
        }
        printf("%d\n", n);
        return 0;
    }
    if (!strcmp(argv[1], "indeep") && argc >= 6) {
        if (chdir(argv[2]) < 0) { perror("chdir"); return 1; }
        for (int i = 1; i < atoi(argv[3]); i++) if (chdir(argv[4]) < 0) { perror("chdir"); return 1; }
        execve(argv[5], argv + 5, envp); perror("execve"); return 126;
    }
    if (!strcmp(argv[1], "flip") && argc == 4) {
        for (;;) syscall(SYS_renameat2, AT_FDCWD, argv[2], AT_FDCWD, argv[3], 2 /* RENAME_EXCHANGE */);
    }
    return 2;
}
