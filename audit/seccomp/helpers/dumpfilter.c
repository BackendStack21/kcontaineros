/* Dump the classic-BPF seccomp filters attached to a process, as the kernel
 * holds them: PTRACE_SECCOMP_GET_FILTER. Needs CAP_SYS_ADMIN + CAP_SYS_PTRACE
 * in the initial user namespace and must itself not be under seccomp.
 *
 *   dumpfilter PID...   ->  "pid P filter I len N" then one line per
 *                           instruction: "code jt jf k" in hex.
 * Index 0 is the oldest filter on this kernel (kernel/seccomp.c, get_nth_filter).
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
/* struct sock_filter, as in <linux/filter.h> (not needed at build time) */
struct sock_filter { unsigned short code; unsigned char jt, jf; unsigned int k; };

#ifndef PTRACE_SECCOMP_GET_FILTER
#define PTRACE_SECCOMP_GET_FILTER 0x420c
#endif

int main(int argc, char **argv) {
    int rc = 0;
    for (int a = 1; a < argc; a++) {
        pid_t pid = atoi(argv[a]);
        if (ptrace(PTRACE_ATTACH, pid, 0, 0) < 0) {
            printf("pid %d attach-error %s\n", pid, strerror(errno));
            rc = 1;
            continue;
        }
        int st;
        waitpid(pid, &st, __WALL);
        for (long idx = 0;; idx++) {
            long n = ptrace(PTRACE_SECCOMP_GET_FILTER, pid, (void *)idx, NULL);
            if (n < 0) {
                printf("pid %d filter %ld none %s\n", pid, idx, strerror(errno));
                break;
            }
            struct sock_filter *f = calloc(n, sizeof *f);
            long m = ptrace(PTRACE_SECCOMP_GET_FILTER, pid, (void *)idx, f);
            printf("pid %d filter %ld len %ld\n", pid, idx, m);
            for (long i = 0; i < m; i++)
                printf("%04x %02x %02x %08x\n", f[i].code, f[i].jt, f[i].jf, f[i].k);
            free(f);
        }
        ptrace(PTRACE_DETACH, pid, 0, 0);
    }
    return rc;
}
