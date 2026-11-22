/* Audit helper (track: memory). Static, musl. Starts programs in ways a
 * shell cannot: empty argv, hostile envp, resource limits; builds deep trees;
 * reports exactly how a child ended. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static int usage(void) {
    fputs("hexec tiny | argc0 T | argv0 NAME T [A..] | noeq T [A..] | bigenv N LEN T [A..] |\n"
          "      bigarg LEN T [A..] | rlim RES SOFT T [A..] | deep N [NAME] | report T [A..] | closefd FDS T [A..] |\n"
          "      argsfile FILE | comm NAME T [A..]\n", stderr);
    return 2;
}

int main(int argc, char **argv) {
    if (argc < 2) return usage();
    const char *m = argv[1];
    if (!strcmp(m, "tiny")) return 42;
    if (!strcmp(m, "argc0") && argc == 3) {
        char *none[] = {NULL};
        execve(argv[2], none, environ);
        perror("execve");
        return 111;
    }
    if (!strcmp(m, "argv0") && argc >= 4) {
        char *path = argv[3];
        argv[3] = argv[2];
        execve(path, argv + 3, environ);
        perror("execve");
        return 111;
    }
    if (!strcmp(m, "noeq") && argc >= 3) {
        /* entries without '=', empty, '=' only, duplicates; first PATH is bogus */
        char *env[] = {"NOEQ", "", "=", "=x", "PATH", "A", "PATH=/nonexistent", "PATH=/bin",
                       "KCOS_EXEC", "KCOS_EXEC=", "KCOS_EXEC=/bb", "HOME", "PWD", "OLDPWD", NULL};
        execve(argv[2], argv + 2, env);
        perror("execve");
        return 111;
    }
    if (!strcmp(m, "bigenv") && argc >= 5) {
        long n = atol(argv[2]), len = atol(argv[3]);
        char **env = calloc(n + 2, sizeof *env);
        for (long i = 0; i < n; i++) {
            env[i] = malloc(len + 32);
            int k = sprintf(env[i], "V%ld=", i);
            memset(env[i] + k, 'x', len);
            env[i][k + len] = 0;
        }
        env[n] = "PATH=/bin";
        execve(argv[4], argv + 4, env);
        perror("execve");
        return 111;
    }
    if (!strcmp(m, "bigarg") && argc >= 4) {
        long len = atol(argv[2]);
        char *big = malloc(len + 1);
        memset(big, 'A', len);
        big[len] = 0;
        char **av = calloc(argc + 2, sizeof *av);
        int k = 0;
        for (int i = 3; i < argc; i++) av[k++] = argv[i];
        av[k++] = big;
        execve(argv[3], av, environ);
        perror("execve");
        return 111;
    }
    if (!strcmp(m, "rlim") && argc >= 5) {
        int res = !strcmp(argv[2], "as") ? RLIMIT_AS : !strcmp(argv[2], "stack") ? RLIMIT_STACK :
                  !strcmp(argv[2], "data") ? RLIMIT_DATA : !strcmp(argv[2], "nofile") ? RLIMIT_NOFILE :
                  !strcmp(argv[2], "fsize") ? RLIMIT_FSIZE : !strcmp(argv[2], "nproc") ? RLIMIT_NPROC : -1;
        if (res < 0) return usage();
        struct rlimit r;
        getrlimit(res, &r);
        r.rlim_cur = strtoull(argv[3], 0, 0);
        if (r.rlim_cur > r.rlim_max) r.rlim_max = r.rlim_cur;
        if (setrlimit(res, &r)) { perror("setrlimit"); return 111; }
        execve(argv[4], argv + 4, environ);
        perror("execve");
        return 111;
    }
    if (!strcmp(m, "deep") && argc >= 3) {
        long n = atol(argv[2]);
        const char *name = argc > 3 ? argv[3] : "d";
        for (long i = 0; i < n; i++) {
            if (mkdir(name, 0777) && errno != EEXIST) { fprintf(stderr, "mkdir at %ld: %s\n", i, strerror(errno)); return 1; }
            if (chdir(name)) { fprintf(stderr, "chdir at %ld: %s\n", i, strerror(errno)); return 1; }
        }
        return 0;
    }
    if (!strcmp(m, "closefd") && argc >= 4) {
        for (const char *p = argv[2]; *p; p++) close(*p - '0');
        execve(argv[3], argv + 3, environ);
        return 111;
    }
    if (!strcmp(m, "argsfile") && argc == 3) {
        /* FILE holds NUL-terminated arguments; the first is the program. */
        size_t cap = 1 << 20;
        char *buf = calloc(1, cap);
        char **av = calloc(4096, sizeof *av);
        int fd = open(argv[2], O_RDONLY);
        ssize_t n = fd < 0 ? -1 : read(fd, buf, cap - 1);
        if (n <= 0) return 111;
        close(fd);
        int k = 0;
        for (ssize_t i = 0; i < n && k < 4095; i += strlen(buf + i) + 1) av[k++] = buf + i;
        execve(av[0], av, environ);
        perror("execve");
        return 111;
    }
    if (!strcmp(m, "comm") && argc >= 4) {
        /* Name this process argv[2] (raw bytes, as ps reads it from
         * /proc/PID/stat), blank its command line, and run T as a child. */
        prctl(PR_SET_NAME, argv[2], 0, 0, 0);
        pid_t p = fork();
        if (p == 0) { execve(argv[3], argv + 3, environ); _exit(111); }
        char *end = argv[argc - 1] + strlen(argv[argc - 1]);
        memset(argv[0], 0, end - argv[0]);
        int st;
        waitpid(p, &st, 0);
        return WIFSIGNALED(st) ? 128 + WTERMSIG(st) : WEXITSTATUS(st);
    }
    if (!strcmp(m, "report") && argc >= 3) {
        pid_t p = fork();
        if (p == 0) {
            execve(argv[2], argv + 2, environ);
            perror("execve");
            _exit(111);
        }
        int st;
        waitpid(p, &st, 0);
        if (WIFSIGNALED(st)) printf("[signal %d]\n", WTERMSIG(st));
        else printf("[exit %d]\n", WEXITSTATUS(st));
        return 0;
    }
    return usage();
}
