// newlib system calls for the meimei SoC: stdout/stderr -> UART, heap in DMEM, exit -> SIM_EXIT
#include <errno.h>
#include <sys/stat.h>
#include <stdint.h>
#include "soc.h"

extern char _end[], __heap_end[];
static char *heap_ptr = _end;

int _write(int fd, const char *buf, int len) {
    if (fd != 1 && fd != 2) { errno = EBADF; return -1; }
    for (int i = 0; i < len; i++) {
        if (buf[i] == '\n') uart_putc('\r');
        uart_putc(buf[i]);
    }
    return len;
}
int _read(int fd, char *buf, int len) {
    if (fd != 0) { errno = EBADF; return -1; }
    int n = 0;
    while (n < len) {
        int c = uart_getc();
        if (c < 0) break;
        buf[n++] = (char)c;
    }
    return n;
}
void *_sbrk(intptr_t incr) {
    char *prev = heap_ptr;
    if (heap_ptr + incr > __heap_end) { errno = ENOMEM; return (void *)-1; }
    heap_ptr += incr;
    return prev;
}
void _exit(int code) { sim_exit(code); }
int _close(int fd) { (void)fd; return -1; }
int _fstat(int fd, struct stat *st) { (void)fd; st->st_mode = S_IFCHR; return 0; }
int _isatty(int fd) { (void)fd; return 1; }
int _lseek(int fd, int off, int whence) { (void)fd; (void)off; (void)whence; return 0; }
int _kill(int pid, int sig) { (void)pid; (void)sig; errno = EINVAL; return -1; }
int _getpid(void) { return 1; }
int _open(const char *name, int flags, int mode) { (void)name; (void)flags; (void)mode; errno = ENOSYS; return -1; }
int _gettimeofday(void *tv, void *tz) { (void)tv; (void)tz; errno = ENOSYS; return -1; }
