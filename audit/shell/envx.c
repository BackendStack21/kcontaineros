/* Starts /bin/sh -c SCRIPT with an environment no shell would build:
 * duplicate names, an entry without '=', an empty name, a name with a blank. */
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    static char big[120001];
    memset(big, 'v', sizeof big - 1);
    memcpy(big, "BIG=", 4);
    char *env[] = { "A=first", "PATH=/usr/local/bin:/usr/bin:/bin:/sbin", "A=second", "NOEQ", "=emptyname",
                    "B C=blank", "D=x=y", "PATH=/nosuch", "IFS=:", "PWD=/lie", "OLDPWD=/tmp", "1X=digit", big, 0 };
    char *sh = argc > 2 ? argv[2] : "/bin/sh";
    char *args[] = { "sh", "-c", argv[1], 0 };
    execve(sh, args, env);
    return 111;
}
