#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/loop.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#define MEDIA_WAIT_MS 10000
#define OVERLAY_SIZE "50%"

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

static void mkdir_required(const char *path, mode_t mode)
{
    if (mkdir(path, mode) == 0 || errno == EEXIST)
        return;
    fatal("mkdir %s: %s", path, strerror(errno));
}

static void mknod_if_missing(const char *path, mode_t mode,
                             unsigned int major_num, unsigned int minor_num)
{
    if (mknod(path, mode, makedev(major_num, minor_num)) == 0)
        return;
    if (errno == EEXIST)
        return;
    fatal("mknod %s: %s", path, strerror(errno));
}

static void mount_required(const char *source, const char *target,
                           const char *fstype, unsigned long flags,
                           const char *data)
{
    if (mount(source, target, fstype, flags, data) == 0)
        return;
    fatal("mount %s on %s (%s): %s", source, target,
          fstype ? fstype : "auto", strerror(errno));
}

static void redirect_console(void)
{
    int fd = open("/dev/console", O_RDWR | O_CLOEXEC);
    if (fd < 0)
        fatal("open /dev/console: %s", strerror(errno));

    if (dup2(fd, STDIN_FILENO) < 0 ||
        dup2(fd, STDOUT_FILENO) < 0 ||
        dup2(fd, STDERR_FILENO) < 0) {
        fatal("dup2 /dev/console: %s", strerror(errno));
    }

    if (fd > STDERR_FILENO)
        close(fd);
}

static int is_media_candidate(const char *name)
{
    return strncmp(name, "sr", 2) == 0 ||
           strncmp(name, "sd", 2) == 0 ||
           strncmp(name, "vd", 2) == 0 ||
           strncmp(name, "xvd", 3) == 0 ||
           strncmp(name, "nvme", 4) == 0 ||
           strncmp(name, "mmcblk", 6) == 0;
}

static int try_mount_iso(const char *dev)
{
    struct stat st;

    if (stat(dev, &st) < 0 || !S_ISBLK(st.st_mode))
        return -1;

    (void)umount2("/cdrom", MNT_DETACH);

    if (mount(dev, "/cdrom", "iso9660",
              MS_RDONLY | MS_NODEV | MS_NOSUID | MS_NOEXEC, NULL) < 0)
        return -1;

    if (access("/cdrom/boot/rootfs.sfs", R_OK) == 0) {
        log_msg("INFO", "Boot media found on %s", dev);
        return 0;
    }

    (void)umount2("/cdrom", MNT_DETACH);
    return -1;
}

static void find_boot_media(void)
{
    if (try_mount_iso("/dev/sr0") == 0)
        return;

    log_msg("INFO", "Scanning block devices for Cherry Linux ISO...");

    for (int elapsed = 0; elapsed < MEDIA_WAIT_MS; elapsed += 200) {
        DIR *dir = opendir("/sys/class/block");
        if (dir) {
            struct dirent *entry;
            while ((entry = readdir(dir)) != NULL) {
                if (entry->d_name[0] == '.' || !is_media_candidate(entry->d_name))
                    continue;

                char dev[PATH_MAX];
                int n = snprintf(dev, sizeof(dev), "/dev/%s", entry->d_name);
                if (n < 0 || (size_t)n >= sizeof(dev))
                    continue;

                if (try_mount_iso(dev) == 0) {
                    closedir(dir);
                    return;
                }
            }
            closedir(dir);
        }
        usleep(200000);
    }

    fatal("could not find an ISO9660 device containing /boot/rootfs.sfs");
}

static void attach_rootfs_loop(const char *image)
{
    int ctl = open("/dev/loop-control", O_RDWR | O_CLOEXEC);
    if (ctl < 0) {
        mknod_if_missing("/dev/loop-control", S_IFCHR | 0600, 10, 237);
        ctl = open("/dev/loop-control", O_RDWR | O_CLOEXEC);
    }
    if (ctl < 0)
        fatal("open /dev/loop-control: %s", strerror(errno));

    int index = ioctl(ctl, LOOP_CTL_GET_FREE);
    if (index < 0)
        fatal("LOOP_CTL_GET_FREE: %s", strerror(errno));

    char loop_path[PATH_MAX];
    int n = snprintf(loop_path, sizeof(loop_path), "/dev/loop%d", index);
    if (n < 0 || (size_t)n >= sizeof(loop_path))
        fatal("loop device path is too long");

    struct stat loop_st;
    if (stat(loop_path, &loop_st) < 0)
        mknod_if_missing(loop_path, S_IFBLK | 0600, 7, (unsigned int)index);

    int loop_fd = open(loop_path, O_RDWR | O_CLOEXEC);
    if (loop_fd < 0)
        fatal("open %s: %s", loop_path, strerror(errno));

    int image_fd = open(image, O_RDONLY | O_CLOEXEC);
    if (image_fd < 0) {
        int saved_errno = errno;
        close(loop_fd);
        fatal("open %s: %s", image, strerror(saved_errno));
    }

    if (ioctl(loop_fd, LOOP_SET_FD, image_fd) < 0) {
        int saved_errno = errno;
        close(image_fd);
        close(loop_fd);
        fatal("LOOP_SET_FD for %s: %s", image, strerror(saved_errno));
    }

    close(image_fd);
    close(ctl);

    /*
     * Important: close our userspace FD before mounting the block device.
     * Keeping it open can make the kernel reject the mount with EBUSY.
     */
    close(loop_fd);

    if (mount(loop_path, "/ro_root", "squashfs", MS_RDONLY, NULL) < 0) {
        int saved_errno = errno;

        int cleanup_fd = open(loop_path, O_RDWR | O_CLOEXEC);
        if (cleanup_fd >= 0) {
            (void)ioctl(cleanup_fd, LOOP_CLR_FD, 0);
            close(cleanup_fd);
        }

        fatal("mount %s as SquashFS: %s", loop_path, strerror(saved_errno));
    }

    log_msg("INFO", "Mounted %s as read-only root layer", loop_path);
}

static void build_overlay_root(void)
{
    mkdir_required("/ro_root", 0755);
    mkdir_required("/rw_root", 0755);
    mkdir_required("/new_root", 0755);

    mount_required("tmpfs", "/rw_root", "tmpfs", 0,
                   "size=" OVERLAY_SIZE ",mode=0755");

    mkdir_required("/rw_root/upper", 0755);
    mkdir_required("/rw_root/work", 0755);

    const char *options =
        "lowerdir=/ro_root,upperdir=/rw_root/upper,workdir=/rw_root/work";
    mount_required("overlay", "/new_root", "overlay", 0, options);

    log_msg("INFO", "Overlay root is ready");
}

static void move_mount_tree(const char *old_path, const char *new_path)
{
    if (mount(old_path, new_path, NULL, MS_MOVE, NULL) < 0)
        fatal("move mount %s -> %s: %s", old_path, new_path, strerror(errno));
}

static void switch_root(void)
{
    mkdir_required("/new_root/dev", 0755);
    mkdir_required("/new_root/proc", 0555);
    mkdir_required("/new_root/sys", 0555);
    mkdir_required("/new_root/run", 0755);

    move_mount_tree("/dev", "/new_root/dev");
    move_mount_tree("/proc", "/new_root/proc");
    move_mount_tree("/sys", "/new_root/sys");
    move_mount_tree("/run", "/new_root/run");

    if (chdir("/new_root") < 0)
        fatal("chdir /new_root: %s", strerror(errno));

    if (mount(".", "/", NULL, MS_MOVE, NULL) < 0)
        fatal("move new root over initramfs root: %s", strerror(errno));

    if (chroot(".") < 0)
        fatal("chroot new root: %s", strerror(errno));

    if (chdir("/") < 0)
        fatal("chdir /: %s", strerror(errno));

    log_msg("INFO", "Switched to Cherry Linux rootfs");
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
     * QEMU with console=tty0 gives us the virtual console, but tty0 is a
     * multiplexer. Ask the kernel which VT is actually active and use that
     * concrete /dev/ttyN as the shell's controlling terminal.
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
        /*
         * A shell only gets job control when it owns a controlling TTY and
         * its process group is foreground on that TTY.
         */
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

        /* Let the shell handle terminal-generated signals itself. */
        (void)signal(SIGINT, SIG_DFL);
        (void)signal(SIGQUIT, SIG_DFL);
        (void)signal(SIGTSTP, SIG_DFL);
        (void)signal(SIGTTIN, SIG_DFL);
        (void)signal(SIGTTOU, SIG_DFL);

        char *const shell_argv[] = { "sh", "--login", "-i", NULL };
        execv("/bin/sh", shell_argv);

        char *const busybox_argv[] = { "busybox", "sh", "-i", NULL };
        execv("/usr/bin/busybox", busybox_argv);

        fprintf(stderr, "[INIT] cannot execute /bin/sh or /usr/bin/busybox: %s\n",
                strerror(errno));
        _exit(127);
    }

    return pid;
}

static void run_rc(void)
{
    pid_t pid = fork();
    if (pid < 0)
        fatal("fork /etc/rc: %s", strerror(errno));

    if (pid == 0) {
        execl("/bin/sh", "sh", "/etc/rc", (char *)NULL);
        fprintf(stderr, "[INIT] cannot execute /etc/rc: %s\n", strerror(errno));
        _exit(127);
    }

    int status;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno == EINTR)
            continue;
        fatal("waitpid /etc/rc: %s", strerror(errno));
    }

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
        fatal("/etc/rc failed");
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

int main(void)
{
    if (getpid() != 1)
        fatal("Cherry init must run as PID 1 (got %ld)", (long)getpid());

    log_msg("INFO", "Booting Cherry Linux...");

    const char *dirs[] = {
        "/proc", "/sys", "/dev", "/run", "/mnt", "/tmp",
        "/cdrom", "/ro_root", "/rw_root", "/new_root"
    };

    for (size_t i = 0; i < sizeof(dirs) / sizeof(dirs[0]); ++i)
        mkdir_required(dirs[i], 0755);

    mount_required("proc", "/proc", "proc", 0, NULL);
    mount_required("sysfs", "/sys", "sysfs", 0, NULL);
    mount_required("devtmpfs", "/dev", "devtmpfs", 0, NULL);

    /* devtmpfs replaces the initramfs /dev directory contents, so /dev/pts
       must be created after devtmpfs is mounted. */
    mkdir_required("/dev/pts", 0755);
    mount_required("devpts", "/dev/pts", "devpts", 0,
                   "mode=0620,ptmxmode=0666");
    mount_required("tmpfs", "/run", "tmpfs", 0, "mode=0755,size=10%");

    mknod_if_missing("/dev/console", S_IFCHR | 0600, 5, 1);
    mknod_if_missing("/dev/tty",     S_IFCHR | 0666, 5, 0);
    mknod_if_missing("/dev/tty0",    S_IFCHR | 0620, 4, 0);
    mknod_if_missing("/dev/tty1",    S_IFCHR | 0620, 4, 1);
    mknod_if_missing("/dev/tty2",    S_IFCHR | 0620, 4, 2);
    mknod_if_missing("/dev/ttyS0",   S_IFCHR | 0620, 4, 64);
    mknod_if_missing("/dev/null",    S_IFCHR | 0666, 1, 3);
    mknod_if_missing("/dev/zero",    S_IFCHR | 0666, 1, 5);
    mknod_if_missing("/dev/random",  S_IFCHR | 0666, 1, 8);
    mknod_if_missing("/dev/urandom", S_IFCHR | 0666, 1, 9);

    redirect_console();

    find_boot_media();
    attach_rootfs_loop("/cdrom/boot/rootfs.sfs");
    build_overlay_root();
    switch_root();

    if (sethostname("cherrylinux", strlen("cherrylinux")) < 0)
        log_msg("WARN", "sethostname failed: %s", strerror(errno));

    setenv("PATH", "/bin:/sbin:/usr/bin:/usr/sbin", 1);
    setenv("HOME", "/root", 1);
    setenv("USER", "root", 1);
    setenv("SHELL", "/bin/sh", 1);

    run_rc();

    log_msg("INFO", "System ready");
    shell_supervisor();
    return 0;
}
