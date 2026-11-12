/* Optional local startup adapter for a procfs/PID namespace mismatch.
 * It changes only the current process's self-executable path lookup.
 * It does not change Lean source, proof checking, or compiler libraries.
 * Build: cc -shared -fPIC -O2 -o /tmp/setoff-proc.so proc_exe_compat.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static const char *mapped_path(const char *path) {
  char own_exe[64];
  snprintf(own_exe, sizeof own_exe, "/proc/%ld/exe", (long)getpid());
  return path && strcmp(path, own_exe) == 0 ? "/proc/self/exe" : path;
}

ssize_t readlink(const char *path, char *buf, size_t size) {
  static ssize_t (*original)(const char *, char *, size_t);
  if (!original) original = dlsym(RTLD_NEXT, "readlink");
  return original(mapped_path(path), buf, size);
}

ssize_t readlinkat(int dirfd, const char *path, char *buf, size_t size) {
  static ssize_t (*original)(int, const char *, char *, size_t);
  if (!original) original = dlsym(RTLD_NEXT, "readlinkat");
  return original(dirfd, mapped_path(path), buf, size);
}
