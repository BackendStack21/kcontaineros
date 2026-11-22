/* Build step only: give FILE every file capability (permitted, effective),
 * as `setcap all+ep FILE` would. struct vfs_cap_data, version 2. */
#include <stdio.h>
#include <sys/xattr.h>
int main(int argc, char **argv) {
    static const unsigned char cap[20] = {0x01, 0, 0, 0x02, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0, 0xff, 0x01, 0, 0, 0, 0, 0, 0};
    if (argc < 2 || setxattr(argv[1], "security.capability", cap, sizeof cap, 0)) { perror("setxattr"); return 1; }
    return 0;
}
