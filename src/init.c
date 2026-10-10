#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

static void log_msg(const char *level, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stdout, "[INIT][%s] ", level);
    vfprintf(stdout, fmt, ap);
    fputc('\n', stdout);
    fflush(stdout);
    va_end(ap);
}

static void fatal(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[INIT][FATAL] ");
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    fflush(stderr);
    va_end(ap);

    sync();
    reboot(RB_POWER_OFF);
    for (;;) pause();
}

static int read_first_line(const char *path, char *buf, size_t size)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;

    ssize_t n = read(fd, buf, size - 1);
    close(fd);
    if (n <= 0)
        return -1;

    buf[n] = '\0';
    char *nl = strchr(buf, '\n');
    if (nl)
        *nl = '\0';
    return 0;
}

static int open_console_tty(void)
{
    /*
     * tty0 is a multiplexer. Ask the kernel which VT is actually active
     * and use that concrete /dev/ttyN as the shell's controlling terminal.
     */
    char active[128];

    if (read_first_line("/sys/class/tty/console/active", active,
                        sizeof(active)) == 0) {
        char *last = strrchr(active, ' ');
        const char *console = last ? last + 1 : active;

        if (strcmp(console, "tty0") == 0) {
            if (read_first_line("/sys/class/tty/tty0/active", active,
                                sizeof(active)) == 0)
                console = active;
        }

        if (strncmp(console, "tty", 3) == 0) {
            char path[PATH_MAX];
            int n = snprintf(path, sizeof(path), "/dev/%s", console);
            if (n > 0 && (size_t)n < sizeof(path)) {
                int fd = open(path, O_RDWR | O_CLOEXEC);
                if (fd >= 0)
                    return fd;
            }
        }
    }

    const char *candidates[] = {
        "/dev/tty1",
        "/dev/tty2",
        "/dev/tty0",
        "/dev/ttyS0",
        NULL
    };

    for (size_t i = 0; candidates[i] != NULL; ++i) {
        int fd = open(candidates[i], O_RDWR | O_CLOEXEC);
        if (fd >= 0 && isatty(fd))
            return fd;
        if (fd >= 0)
            close(fd);
    }

    return -1;
}

static int acquire_shell_tty(void)
{
    int tty_fd = open_console_tty();
    if (tty_fd < 0)
        return -1;

    if (!isatty(tty_fd)) {
        close(tty_fd);
        return -1;
    }

    if (ioctl(tty_fd, TIOCSCTTY, 1) < 0) {
        int saved_errno = errno;
        close(tty_fd);
        errno = saved_errno;
        return -1;
    }

    /* We are the session leader after setsid(), hence also a pgrp leader. */
    pid_t pgrp = getpgrp();
    if (tcsetpgrp(tty_fd, pgrp) < 0) {
        int saved_errno = errno;
        close(tty_fd);
        errno = saved_errno;
        return -1;
    }

    return tty_fd;
}

static pid_t start_shell(void)
{
    pid_t pid = fork();
    if (pid < 0)
        fatal("fork shell: %s", strerror(errno));

    if (pid == 0) {
        if (setsid() < 0) {
            fprintf(stderr, "[INIT] setsid failed: %s\n", strerror(errno));
            _exit(127);
        }

        int tty_fd = acquire_shell_tty();
        if (tty_fd < 0) {
            fprintf(stderr, "[INIT] cannot acquire a controlling TTY: %s\n",
                    strerror(errno));
            _exit(127);
        }

        if (dup2(tty_fd, STDIN_FILENO) < 0 ||
            dup2(tty_fd, STDOUT_FILENO) < 0 ||
            dup2(tty_fd, STDERR_FILENO) < 0) {
            fprintf(stderr, "[INIT] dup2 shell TTY failed: %s\n",
                    strerror(errno));
            close(tty_fd);
            _exit(127);
        }

        if (tty_fd > STDERR_FILENO)
            close(tty_fd);

        (void)signal(SIGINT, SIG_DFL);
        (void)signal(SIGQUIT, SIG_DFL);
        (void)signal(SIGTSTP, SIG_DFL);
        (void)signal(SIGTTIN, SIG_DFL);
        (void)signal(SIGTTOU, SIG_DFL);

        char *const shell_argv[] = { "sh", "-i", NULL };
        execv("/bin/sh", shell_argv);

        char *const busybox_argv[] = { "busybox", "sh", "-i", NULL };
        execv("/usr/bin/busybox", busybox_argv);

        fprintf(stderr, "[INIT] cannot execute /bin/sh or /usr/bin/busybox: %s\n",
                strerror(errno));
        _exit(127);
    }

    return pid;
}

static void reap_children(void)
{
    for (;;) {
        int status;
        pid_t pid = waitpid(-1, &status, WNOHANG);
        if (pid <= 0)
            return;
    }
}

static volatile sig_atomic_t shutdown_request = -1;

static void shutdown_signal_handler(int sig)
{
    if (sig == SIGUSR1)      /* BusyBox halt */
        shutdown_request = 0;
    else if (sig == SIGUSR2) /* BusyBox poweroff */
        shutdown_request = 1;
    else if (sig == SIGTERM) /* BusyBox reboot */
        shutdown_request = 2;
}

static void install_shutdown_handlers(void)
{
    static const int sigs[] = { SIGUSR1, SIGUSR2, SIGTERM };
    struct sigaction sa;

    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = shutdown_signal_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0; /* no SA_RESTART: let signals interrupt waitpid() */

    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); ++i)
        sigaction(sigs[i], &sa, NULL);
}

static void perform_shutdown(void)
{
    static const unsigned int actions[] = {
        RB_HALT_SYSTEM,
        RB_POWER_OFF,
        RB_AUTOBOOT,
    };
    static const char *const names[] = { "halt", "poweroff", "reboot" };

    log_msg("INFO", "Shutdown requested: %s", names[shutdown_request]);
    sync();

    if (reboot(actions[shutdown_request]) == 0) {
        for (;;)
            pause();
    }

    log_msg("FATAL", "reboot syscall failed: %s", strerror(errno));
    for (;;)
        pause();
}

static void shell_supervisor(void)
{
    for (;;) {
        reap_children();
        log_msg("INFO", "Starting interactive shell");

        pid_t shell_pid = start_shell();

        for (;;) {
            int status;
            pid_t pid = waitpid(-1, &status, 0);

            if (shutdown_request >= 0)
                perform_shutdown();

            if (pid < 0) {
                if (errno == EINTR)
                    continue;
                fatal("waitpid: %s", strerror(errno));
            }

            if (pid == shell_pid)
                break;
        }

        log_msg("WARN", "Shell exited; restarting in 1 second");
        sleep(1);
    }
}

static void run_network_setup(void)
{
    const char *script = "/usr/lib/cherry/net-up";

    if (access(script, X_OK) != 0)
        return;

    pid_t pid = fork();
    if (pid < 0) {
        log_msg("WARN", "fork network setup: %s", strerror(errno));
        return;
    }

    if (pid == 0) {
        char *const argv[] = { (char *)script, NULL };
        execv(script, argv);
        _exit(127);
    }

    int status;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR)
            break;
    }
}

static void setup_environment(void)
{
    if (sethostname("cherrylinux", strlen("cherrylinux")) < 0)
        log_msg("WARN", "sethostname failed: %s", strerror(errno));

    setenv("PATH", "/bin:/sbin:/usr/bin:/usr/sbin", 1);
    setenv("HOME", "/root", 1);
    setenv("USER", "root", 1);
    setenv("SHELL", "/bin/sh", 1);
    setenv("PS1", "cherry:\\w# ", 1);
}

int main(void)
{
    if (getpid() != 1)
        fatal("Cherry runtime init must run as PID 1 (got %ld)", (long)getpid());

    log_msg("INFO", "Starting Cherry Linux runtime");
    setup_environment();
    install_shutdown_handlers();

    log_msg("INFO", "Configuring network");
    run_network_setup();

    log_msg("INFO", "System ready");
    printf("\n  Welcome to Cherry Linux\n");
    printf("  GNU userspace shell: /bin/sh\n\n");
    fflush(stdout);

    shell_supervisor();
    return 0;
}
