/* Executable-location adapter for a procfs/PID namespace mismatch.
 * This substitutes only the current process's own executable-location query
 * with its argv[0] basename beneath an explicitly configured toolchain root.
 * It does not access procfs for that query, change permissions, or modify Lean.
 * Child tools resolve their own names, preserving Lean's multicall dispatch.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char *program_invocation_short_name;

ssize_t readlink(const char *path, char *buf, size_t size) {
    char own[80];
    snprintf(own, sizeof(own), "/proc/%ld/exe", (long)getpid());
    const char *root = getenv("FRE_LEAN_ROOT");
    const char *name = program_invocation_short_name;
    const char *known[] = {"lean", "lake", "leanchecker", "leanexport",
        "leanchecker-paranoid", "lean4lean", "nanoda_bin", "con-leche",
        "con-ron", "leanc", "leanir", NULL};
    int supported = 0;
    for (int i = 0; name && known[i]; ++i)
        if (strcmp(name, known[i]) == 0) supported = 1;
    if (root && root[0] == '/' && supported && strcmp(path, own) == 0) {
        char configured[4096];
        int length = snprintf(configured, sizeof(configured), "%s/bin/%s", root, name);
        if (length < 0 || (size_t)length >= sizeof(configured)) {
            errno = ENAMETOOLONG; return -1;
        }
        size_t n = (size_t)length;
        if (n > size) n = size;
        memcpy(buf, configured, n);
        return (ssize_t)n;
    }
    ssize_t (*original)(const char *, char *, size_t);
    original = (ssize_t (*)(const char *, char *, size_t))dlsym(RTLD_NEXT, "readlink");
    if (!original) { errno = ENOSYS; return -1; }
    return original(path, buf, size);
}
