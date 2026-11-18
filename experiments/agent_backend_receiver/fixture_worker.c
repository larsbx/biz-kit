/* Fixed Linux acceptance workload. It exchanges one byte over each supplied
 * descriptor and has no task data, executable arguments or business ports. */
#define _GNU_SOURCE
#include <errno.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <stdlib.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#if defined(__x86_64__)
#define FIXTURE_ARCH AUDIT_ARCH_X86_64
#elif defined(__aarch64__)
#define FIXTURE_ARCH AUDIT_ARCH_AARCH64
#else
#error "The execution fixture requires Linux x86-64 or arm64"
#endif

#define ALLOW(syscall_number)                                      \
  BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, syscall_number, 0, 1),        \
  BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW)

int main(int argc, char **argv) {
  if (argc != 4) return 2;
  int witness = atoi(argv[1]);
  int stop = atoi(argv[2]);
  long long start_by = strtoll(argv[3], NULL, 10);
  char byte;
  struct timespec now;
  struct sock_filter rules[] = {
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, FIXTURE_ARCH, 1, 0),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
    BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
    ALLOW(SYS_read),
    ALLOW(SYS_write),
    ALLOW(SYS_exit),
    ALLOW(SYS_exit_group),
    ALLOW(SYS_clock_gettime),
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
  };
  struct sock_fprog filter = {sizeof rules / sizeof rules[0], rules};

  alarm(20); /* Bounded cleanup even if the acceptance harness exits. */
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) ||
      prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &filter)) return 3;

  /* The start witness is written by the restricted process itself. */
  if (syscall(SYS_socket, AF_INET, SOCK_STREAM, 0) != -1 || errno != EPERM ||
      clock_gettime(CLOCK_REALTIME, &now) ||
      now.tv_sec * 1000000LL + now.tv_nsec / 1000 >= start_by ||
      write(witness, "S", 1) != 1) return 4;

  return read(stop, &byte, 1) == 1 && byte == 'C' &&
         write(witness, "C", 1) == 1 ? 0 : 5;
}
