#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mntent.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <time.h>

#define CMDLINE_MAX 4096
#define LIVE_CONF "/run/cherry/live.conf"
#define SHUTDOWN_HOOK "/etc/rc.shutdown"
#define MDEV_PATH "/usr/bin/mdev"

/* Parsed kernel command line options. */
static int opt_debug;
static int opt_rescue;
static char opt_hostname[64];
static int opt_login;
static volatile sig_atomic_t shutdown_request = -1;
static int shutting_down;
static sigset_t event_signals;
static void perform_shutdown(void);

static void reset_signals(void)
{
    sigset_t empty;
    sigemptyset(&empty);
    sigprocmask(SIG_SETMASK, &empty, NULL);
}

/* Signals stay blocked between checks; sigtimedwait cannot lose a request. */
static void wait_event(int milliseconds)
{
    struct timespec timeout = { milliseconds / 1000,
                               (milliseconds % 1000) * 1000000L };
    int sig = sigtimedwait(&event_signals, NULL, &timeout);
    if (shutdown_request < 0) {
        if (sig == SIGUSR1) shutdown_request = 0;
        if (sig == SIGUSR2) shutdown_request = 1;
        if (sig == SIGTERM) shutdown_request = 2;
    }
}


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

static void debug_msg(const char *fmt, ...)
{
    va_list ap;

    if (!opt_debug)
        return;

    va_start(ap, fmt);
    fprintf(stdout, "[INIT][DEBUG] ");
    vfprintf(stdout, fmt, ap);
    fputc('\n', stdout);
    fflush(stdout);
    va_end(ap);
}

static _Noreturn void fatal(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[INIT][FATAL] ");
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    fflush(stderr);
    va_end(ap);

    if (getpid() != 1)
        exit(EXIT_FAILURE);
    /* Keep PID 1 alive if the recovery shell exits. */
    reset_signals();
    for (;;) {
        fprintf(stderr, "[INIT] Emergency shell; exit to reopen. Use busybox reboot -f to restart.\n");
        pid_t pid = fork();
        if (pid == 0) {
            setsid();
            int fd = open("/dev/console", O_RDWR);
            if (fd >= 0) {
                ioctl(fd, TIOCSCTTY, 1);
                dup2(fd, 0); dup2(fd, 1); dup2(fd, 2);
                if (fd > 2) close(fd);
            }
            execl("/usr/bin/busybox", "busybox", "sh", "-i", (char *)NULL);
            _exit(127);
        }
        if (pid > 0)
            while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
        sleep(1);
    }
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

static void parse_cmdline(void)
{
    char buf[CMDLINE_MAX];
    int fd = open("/proc/cmdline", O_RDONLY | O_CLOEXEC);

    if (fd < 0) {
        log_msg("WARN", "cannot read /proc/cmdline: %s", strerror(errno));
        return;
    }

    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);

    if (n <= 0) {
        log_msg("WARN", "empty kernel command line");
        return;
    }

    buf[n] = '\0';

    char *save = NULL;
    for (char *tok = strtok_r(buf, " \t\r\n", &save); tok;
         tok = strtok_r(NULL, " \t\r\n", &save)) {
        if (strcmp(tok, "cherry.debug") == 0) {
            opt_debug = 1;
        } else if (strcmp(tok, "single") == 0 ||
                   strcmp(tok, "rescue") == 0 ||
                   strcmp(tok, "cherry.rescue") == 0) {
            opt_rescue = 1;
        } else if (strcmp(tok, "cherry.login") == 0) {
            opt_login = 1;
        } else if (strncmp(tok, "cherry.hostname=", 16) == 0) {
            snprintf(opt_hostname, sizeof(opt_hostname), "%s", tok + 16);
        }
    }
}

/*
 * Load the environment exported by the boot initramfs (CHERRY_LIVE,
 * CHERRY_PERSIST, ...). Values already present in the environment win.
 */
static void read_live_config(void)
{
    FILE *fp = fopen(LIVE_CONF, "r");

    if (!fp) {
        debug_msg("no %s: %s", LIVE_CONF, strerror(errno));
        return;
    }

    char line[512];
    while (fgets(line, sizeof(line), fp)) {
        if (line[0] == '#' || line[0] == '\n')
            continue;

        char *nl = strchr(line, '\n');
        if (nl)
            *nl = '\0';

        char *eq = strchr(line, '=');
        if (!eq)
            continue;

        *eq = '\0';
        const char *key = line;
        const char *val = eq + 1;

        if (getenv(key) == NULL)
            setenv(key, val, 1);
    }

    fclose(fp);
}

static int is_mounted(const char *target)
{
    FILE *fp = setmntent("/proc/self/mounts", "r");
    if (!fp)
        return 0;

    int found = 0;
    struct mntent *entry;
    while ((entry = getmntent(fp)) != NULL) {
        if (strcmp(entry->mnt_dir, target) == 0) {
            found = 1;
            break;
        }
    }
    endmntent(fp);
    return found;
}

static void mount_tmpfs(const char *target, const char *opts)
{
    if (is_mounted(target))
        return;

    if (mkdir(target, 0755) < 0 && errno != EEXIST)
        log_msg("WARN", "mkdir %s: %s", target, strerror(errno));

    if (mount("tmpfs", target, "tmpfs", 0, opts) < 0 && errno != EBUSY)
        log_msg("WARN", "mount tmpfs on %s: %s", target, strerror(errno));
}

static void setup_filesystems(void)
{
    static const struct {
        const char *target;
        const char *fstype;
        unsigned long flags;
        const char *data;
    } mounts[] = {
        { "/proc", "proc",     MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL },
        { "/sys",  "sysfs",    MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL },
        { "/dev",  "devtmpfs", MS_NOSUID,                        "mode=0755" },
    };

    for (size_t i = 0; i < sizeof(mounts) / sizeof(mounts[0]); ++i) {
        if (is_mounted(mounts[i].target))
            continue;
        if (mount(mounts[i].target, mounts[i].target, mounts[i].fstype,
                  mounts[i].flags, mounts[i].data) < 0 && errno != EBUSY)
            log_msg("WARN", "mount %s: %s", mounts[i].target,
                    strerror(errno));
    }

    mount_tmpfs("/run", "mode=0755");
    mount_tmpfs("/tmp", "mode=1777");
    mount_tmpfs("/dev/shm", "mode=1777");
}

static void run_mdev(void)
{
    if (access(MDEV_PATH, X_OK) != 0)
        return;

    pid_t pid = fork();
    if (pid < 0) {
        log_msg("WARN", "fork mdev: %s", strerror(errno));
        return;
    }

    if (pid == 0) {
        /* -d subscribes to netlink before scanning /sys, then daemonizes.
         * The default kernel does not enable the legacy hotplug helper. */
        reset_signals();
        char *const argv[] = { "mdev", "-d", NULL };
        execv(MDEV_PATH, argv);
        _exit(127);
    }

    int status;
    pid_t waited;
    do {
        waited = waitpid(pid, &status, 0);
    } while (waited < 0 && errno == EINTR);
    if (waited < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0)
        log_msg("WARN", "mdev failed to start");
}

static void run_script(const char *path)
{
    if (access(path, X_OK) != 0) return;
    debug_msg("running %s", path);
    pid_t pid = fork();
    if (pid < 0) { log_msg("WARN", "fork %s: %s", path, strerror(errno)); return; }
    if (pid == 0) {
        reset_signals();
        setsid();
        execl(path, path, (char *)NULL);
        _exit(127);
    }
    struct timespec started, now;
    clock_gettime(CLOCK_MONOTONIC, &started);
    for (;;) {
        int status;
        pid_t result = waitpid(pid, &status, WNOHANG);
        if (result == pid) {
            if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
                log_msg("WARN", "%s failed (status %d)", path, status);
            return;
        }
        if (result < 0 && errno != EINTR) return;
        clock_gettime(CLOCK_MONOTONIC, &now);
        if ((!shutting_down && shutdown_request >= 0) || now.tv_sec - started.tv_sec >= 30) {
            log_msg("WARN", "stopping %s (shutdown or 30 second timeout)", path);
            kill(-pid, SIGTERM); kill(pid, SIGTERM);
            wait_event(200);
            kill(-pid, SIGKILL); kill(pid, SIGKILL);
            while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
            return;
        }
        wait_event(100);
    }
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
        reset_signals();
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

        if (!opt_rescue) {
            if (opt_login)
                execl("/usr/bin/getty", "getty", "-L", "-", "115200", "linux", (char *)NULL);
            else
                execl("/usr/bin/getty", "getty", "-L", "-n", "-l",
                      "/usr/lib/cherry/live-login", "-", "115200", "linux", (char *)NULL);
            if (opt_login) {
                fprintf(stderr, "[INIT] password login requested but getty unavailable\n");
                _exit(127);
            }
            fprintf(stderr, "[INIT] getty unavailable; using rescue shell\n");
        }
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

static void install_shutdown_handlers(void)
{
    sigemptyset(&event_signals);
    sigaddset(&event_signals, SIGCHLD);
    sigaddset(&event_signals, SIGUSR1);
    sigaddset(&event_signals, SIGUSR2);
    sigaddset(&event_signals, SIGTERM);
    if (sigprocmask(SIG_BLOCK, &event_signals, NULL) < 0)
        fatal("cannot block init signals: %s", strerror(errno));
}

static int stage_shutdown(void)
{
    int in = open("/usr/lib/cherry/shutdown", O_RDONLY | O_CLOEXEC);
    if (in < 0) return -1;
    int out = open("/run/cherry/shutdown", O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0700);
    if (out < 0) { close(in); return -1; }
    char buf[16384];
    ssize_t n;
    int ok = 1;
    while ((n = read(in, buf, sizeof(buf))) > 0) {
        ssize_t offset = 0;
        while (offset < n) {
            ssize_t written = write(out, buf + offset, (size_t)(n - offset));
            if (written <= 0) { ok = 0; break; }
            offset += written;
        }
        if (!ok) break;
    }
    if (n < 0 || fchmod(out, 0700) < 0) ok = 0;
    close(in); close(out);
    return ok ? 0 : -1;
}

static void perform_shutdown(void)
{
    static const char *const names[] = { "halt", "poweroff", "reboot" };
    shutting_down = 1;
    log_msg("INFO", "Shutdown requested: %s", names[shutdown_request]);
    if (stage_shutdown() < 0)
        fatal("cannot stage shutdown helper: %s", strerror(errno));
    run_script(SHUTDOWN_HOOK);
    kill(-1, SIGTERM); /* Linux excludes PID 1 and kernel threads. */
    for (int i = 0; i < 20; ++i) { reap_children(); wait_event(100); }
    kill(-1, SIGKILL);
    for (int i = 0; i < 10; ++i) { reap_children(); wait_event(100); }
    sync();
    execl("/run/cherry/shutdown", "cherry-shutdown", names[shutdown_request], (char *)NULL);
    fatal("cannot execute shutdown helper: %s", strerror(errno));
}

static void shell_supervisor(void)
{
    for (;;) {
        wait_event(0);
        if (shutdown_request >= 0) perform_shutdown();
        reap_children();
        log_msg("INFO", "Starting interactive shell");

        pid_t shell_pid = start_shell();

        for (;;) {
            int status;
            wait_event(0);
            if (shutdown_request >= 0) perform_shutdown();
            pid_t pid = waitpid(-1, &status, WNOHANG);

            if (shutdown_request >= 0)
                perform_shutdown();

            if (pid < 0) {
                if (errno == EINTR)
                    continue;
                fatal("waitpid: %s", strerror(errno));
            }

            if (pid == shell_pid)
                break;
            if (pid == 0) wait_event(1000);
        }

        log_msg("WARN", "Shell exited; restarting in 1 second");
        wait_event(1000);
    }
}

static void run_network_setup(void)
{
    run_script("/usr/lib/cherry/net-up");
}

static void setup_environment(void)
{
    char configured[64] = "cherrylinux";
    (void)read_first_line("/etc/hostname", configured, sizeof(configured));
    const char *hostname = opt_hostname[0] ? opt_hostname : configured;

    if (sethostname(hostname, strlen(hostname)) < 0)
        log_msg("WARN", "sethostname failed: %s", strerror(errno));

    setenv("PATH", "/bin:/sbin:/usr/bin:/usr/sbin", 1);
    setenv("HOME", "/root", 1);
    setenv("USER", "root", 1);
    setenv("LOGNAME", "root", 1);
    setenv("SHELL", "/bin/sh", 1);
    setenv("TERM", "linux", 0);
    setenv("PS1", "cherry:\\w# ", 1);
}

int main(void)
{
    if (getpid() != 1) {
        fprintf(stderr, "Cherry runtime init must run as PID 1\n");
        return EXIT_FAILURE;
    }
    install_shutdown_handlers();

    parse_cmdline();

    log_msg("INFO", "Starting Cherry Linux runtime");
    read_live_config();
    setup_filesystems();
    run_mdev();
    setup_environment();

    if (opt_rescue) {
        log_msg("INFO", "Rescue mode: skipping network and rc.local");
    } else {
        log_msg("INFO", "Configuring network");
        run_network_setup();
        wait_event(0);
        if (shutdown_request >= 0) perform_shutdown();

        debug_msg("running /etc/rc.local");
        run_script("/etc/rc.local");
    }

    log_msg("INFO", "System ready");
    printf("\n  Welcome to Cherry Linux\n");
    const char *persist = getenv("CHERRY_PERSIST");
    printf("  Changes: %s\n", persist && strcmp(persist, "1") == 0
           ? "saved to persistence storage" : "RAM only; lost on shutdown");
    const char *requested = getenv("CHERRY_PERSIST_REQUESTED");
    if (requested && strcmp(requested, "1") == 0 && (!persist || strcmp(persist, "1") != 0))
        printf("  WARNING: requested persistence is unavailable. Changes WILL NOT be saved.\n");
    printf("  Type cherry-help for commands. %s\n\n",
           opt_login && !opt_rescue ? "Password login enabled." : "Live console runs as root.");
    /* This directory belongs to the live user, even in a rootless-built image. */
    if (chown("/home/cherry", 1000, 1000) < 0)
        log_msg("WARN", "cannot set home ownership: %s", strerror(errno));
    fflush(stdout);

    shell_supervisor();
    return 0;
}
