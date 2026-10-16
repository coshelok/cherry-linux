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
#include <sys/vfs.h>
#include <sys/wait.h>
#include <sys/xattr.h>
#include <linux/magic.h>
#include <unistd.h>

#define MEDIA_WAIT_MS 10000
#define OVERLAY_SIZE "50%"
#define CMDLINE_MAX 4096
#define PERSIST_MNT "/run/cherry/persist"
#define LIVE_CONF "/run/cherry/live.conf"

/* Parsed kernel command line options. */
static int opt_debug;
static int opt_persist;
static char opt_persist_spec[256];

/* Set when a persistence store was successfully mounted. */
static int persist_active;

static char rootfs_loop_path[PATH_MAX];

static void log_msg(const char *level, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stdout, "[BOOT][%s] ", level);
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
    fprintf(stdout, "[BOOT][DEBUG] ");
    vfprintf(stdout, fmt, ap);
    fputc('\n', stdout);
    fflush(stdout);
    va_end(ap);
}

static void fatal(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[BOOT][FATAL] ");
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

    if (stat(dev, &st) < 0) {
        debug_msg("stat %s failed: %s", dev, strerror(errno));
        return -1;
    }

    if (!S_ISBLK(st.st_mode)) {
        debug_msg("%s exists but is not a block device", dev);
        return -1;
    }

    debug_msg("Trying ISO9660 mount on %s", dev);

    (void)umount2("/run/cherry/bootmnt", MNT_DETACH);

    if (mount(dev, "/run/cherry/bootmnt", "iso9660",
              MS_RDONLY | MS_NODEV | MS_NOSUID | MS_NOEXEC, NULL) < 0) {
        debug_msg("mount %s failed: %s", dev, strerror(errno));
        return -1;
    }

    debug_msg("ISO9660 mounted from %s", dev);

    if (access("/run/cherry/bootmnt/boot/rootfs.sfs", R_OK) == 0) {
        log_msg("INFO", "Boot media found on %s", dev);
        return 0;
    }

    debug_msg("%s mounted, but /boot/rootfs.sfs is missing", dev);

    (void)umount2("/run/cherry/bootmnt", MNT_DETACH);
    return -1;
}

static void find_boot_media(void)
{
    if (try_mount_iso("/dev/sr0") == 0)
        return;

    log_msg("INFO", "Scanning block devices for Cherry Linux ISO...");

    for (int elapsed = 0; elapsed < MEDIA_WAIT_MS; elapsed += 200) {
        DIR *dir = opendir("/sys/class/block");

        if (!dir) {
            debug_msg("cannot open /sys/class/block: %s", strerror(errno));
        } else {
            struct dirent *entry;

            while ((entry = readdir(dir)) != NULL) {
                if (entry->d_name[0] == '.' ||
                    !is_media_candidate(entry->d_name))
                    continue;

                char dev[PATH_MAX];
                int n = snprintf(dev, sizeof(dev),
                                 "/dev/%s", entry->d_name);

                if (n < 0 || (size_t)n >= sizeof(dev))
                    continue;

                debug_msg("block device candidate: %s", entry->d_name);

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

static void parse_cmdline(void)
{
    char buf[CMDLINE_MAX];
    ssize_t n;
    int fd = open("/proc/cmdline", O_RDONLY | O_CLOEXEC);

    if (fd < 0) {
        log_msg("WARN", "cannot read /proc/cmdline: %s", strerror(errno));
        return;
    }

    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);

    if (n <= 0) {
        log_msg("WARN", "empty kernel command line");
        return;
    }

    buf[n] = '\0';

    char *save = NULL;
    for (char *tok = strtok_r(buf, " \t\r\n", &save); tok;
         tok = strtok_r(NULL, " \t\r\n", &save)) {
        if (strcmp(tok, "persistent") == 0 ||
            strcmp(tok, "cherry.persist") == 0 ||
            strcmp(tok, "persist") == 0) {
            opt_persist = 1;
        } else if (strncmp(tok, "cherry.persist=", 15) == 0) {
            opt_persist = 1;
            snprintf(opt_persist_spec, sizeof(opt_persist_spec),
                     "%s", tok + 15);
        } else if (strcmp(tok, "cherry.debug") == 0) {
            opt_debug = 1;
        }
    }
}

/*
 * Run a command and capture its stdout. Returns 0 when the command exited
 * successfully and produced output; the first line is NUL-terminated in
 * `out`. Returns -1 otherwise.
 */
static int run_capture(char *const argv[], char *out, size_t outsz)
{
    int pipefd[2];

    if (pipe(pipefd) < 0)
        return -1;

    pid_t pid = fork();
    if (pid < 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        return -1;
    }

    if (pid == 0) {
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);
        execv(argv[0], argv);
        _exit(127);
    }

    close(pipefd[1]);

    size_t total = 0;
    while (total + 1 < outsz) {
        ssize_t n = read(pipefd[0], out + total, outsz - 1 - total);
        if (n > 0) {
            total += (size_t)n;
        } else if (n == 0) {
            break;
        } else if (errno != EINTR) {
            break;
        }
    }
    close(pipefd[0]);
    out[total] = '\0';

    int status;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR)
        ;

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
        return -1;

    return out[0] ? 0 : -1;
}

/*
 * Find a filesystem whose LABEL or UUID field equals `value` by probing the
 * devices with the BusyBox blkid shipped in the initramfs. The boot stage has
 * no udev/mdev, so /dev/disk/by-* symlinks do not exist; the block devices
 * themselves are created by devtmpfs. On success stores "/dev/..." in `out`.
 */
static int find_blkid(const char *field, const char *value,
                      char *out, size_t outsz)
{
    char buf[32768];
    char needle[64];

    if (access("/bin/busybox", X_OK) != 0) {
        debug_msg("no /bin/busybox in initramfs; autodetect unavailable");
        return -1;
    }

    char *const argv[] = { (char *)"/bin/busybox", (char *)"blkid", NULL };
    if (run_capture(argv, buf, sizeof(buf)) < 0) {
        debug_msg("blkid returned no output");
        return -1;
    }

    snprintf(needle, sizeof(needle), " %s=\"%s\"", field, value);

    char *save = NULL;
    for (char *line = strtok_r(buf, "\n", &save); line;
         line = strtok_r(NULL, "\n", &save)) {
        char *colon = strchr(line, ':');
        if (!colon)
            continue;
        *colon = '\0';
        if (line[0] && strstr(colon + 1, needle)) {
            snprintf(out, outsz, "%s", line);
            return 0;
        }
    }

    return -1;
}

/*
 * Resolve the persistence store into a raw device path. The store may be
 * given explicitly as a device, a UUID= or LABEL= spec, or left to
 * autodetection, in which case the conventional "cherry-persist" label is
 * used. Empty output means no suitable device was found.
 */
static void persist_device_path(char *out, size_t outsz)
{
    const char *spec = opt_persist_spec;

    if (spec[0] == '\0') {
        if (find_blkid("LABEL", "cherry-persist", out, outsz) == 0)
            debug_msg("persistence store by label: %s", out);
        else
            debug_msg("no device labelled cherry-persist found");
        return;
    }

    if (strncmp(spec, "/dev/", 5) == 0) {
        snprintf(out, outsz, "%s", spec);
    } else if (strncmp(spec, "UUID=", 5) == 0) {
        if (find_blkid("UUID", spec + 5, out, outsz) != 0) {
            log_msg("WARN", "no device found with UUID %s", spec + 5);
            out[0] = '\0';
        }
    } else if (strncmp(spec, "LABEL=", 6) == 0) {
        if (find_blkid("LABEL", spec + 6, out, outsz) != 0) {
            log_msg("WARN", "no device found with label %s", spec + 6);
            out[0] = '\0';
        }
    } else {
        /* A bare name without a /dev/ prefix is treated as a label. */
        if (find_blkid("LABEL", spec, out, outsz) != 0) {
            log_msg("WARN", "no device found with label %s", spec);
            out[0] = '\0';
        }
    }
}

static int mount_persist_store(const char *dev)
{
    static const char *const fstypes[] = {
        "ext4", "ext3", "ext2", "f2fs", "xfs", "btrfs", "vfat", NULL
    };

    if (mount(dev, PERSIST_MNT, NULL,
              MS_NOSUID | MS_NODEV, NULL) == 0)
        return 0;

    for (size_t i = 0; fstypes[i] != NULL; ++i) {
        if (mount(dev, PERSIST_MNT, fstypes[i],
                  MS_NOSUID | MS_NODEV, NULL) == 0)
            return 0;
    }

    return -1;
}

/*
 * OverlayFS needs extended attribute support on the upper layer. Probe the
 * mounted store with a user xattr: filesystems such as vfat/exfat mount
 * fine but cannot serve as a persistence store.
 */
static int persist_supports_xattrs(void)
{
    static const char path[] = PERSIST_MNT "/.cherry-xattr-probe";
    static const char value[] = "1";
    int ok = 0;
    int fd = open(path, O_WRONLY | O_CREAT | O_CLOEXEC, 0600);

    if (fd < 0) {
        debug_msg("xattr probe: cannot create %s: %s", path, strerror(errno));
        return 0;
    }

    if (fsetxattr(fd, "user.cherry.probe", value, sizeof(value) - 1, 0) == 0)
        ok = 1;
    else
        debug_msg("xattr probe: setxattr failed: %s", strerror(errno));

    close(fd);
    (void)unlink(path);
    return ok;
}

static void mount_persistence(void)
{
    if (!opt_persist) {
        debug_msg("persistence not requested");
        return;
    }

    char dev[PATH_MAX];
    struct stat st;

    persist_device_path(dev, sizeof(dev));

    if (dev[0] == '\0') {
        log_msg("WARN", "persistence store not found; continuing with volatile overlay");
        return;
    }

    if (stat(dev, &st) < 0) {
        log_msg("WARN", "persistence device %s not found: %s",
                dev, strerror(errno));
        return;
    }

    mkdir_required(PERSIST_MNT, 0755);

    if (mount_persist_store(dev) < 0) {
        log_msg("WARN", "cannot mount persistence store %s: %s",
                dev, strerror(errno));
        return;
    }

    if (!persist_supports_xattrs()) {
        log_msg("WARN",
                "persistence store %s cannot host the OverlayFS upper layer "
                "(extended attributes required; use ext4/xfs/btrfs/f2fs)", dev);
        log_msg("WARN", "continuing with a volatile overlay");
        (void)umount2(PERSIST_MNT, MNT_DETACH);
        return;
    }

    if (mkdir(PERSIST_MNT "/upper", 0755) < 0 && errno != EEXIST) {
        log_msg("WARN", "cannot create upper dir: %s", strerror(errno));
        (void)umount2(PERSIST_MNT, MNT_DETACH);
        return;
    }
    if (mkdir(PERSIST_MNT "/work", 0755) < 0 && errno != EEXIST) {
        log_msg("WARN", "cannot create work dir: %s", strerror(errno));
        (void)umount2(PERSIST_MNT, MNT_DETACH);
        return;
    }

    persist_active = 1;
    log_msg("INFO", "Persistence enabled on %s", dev);
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

    if (snprintf(rootfs_loop_path, sizeof(rootfs_loop_path), "%s", loop_path) >=
        (int)sizeof(rootfs_loop_path))
        fatal("rootfs loop device path is too long");

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
    close(loop_fd);

    log_msg("INFO", "Attached %s to %s", image, loop_path);
}

static void build_overlay_root(void)
{
    char upperdir[PATH_MAX];
    char workdir[PATH_MAX];
    char options[PATH_MAX * 2 + 64];

    mkdir_required("/new_root", 0755);
    mkdir_required("/run/cherry/airootfs", 0755);

    mount_required(rootfs_loop_path, "/run/cherry/airootfs",
                   "squashfs", MS_RDONLY, NULL);

    /* The SquashFS image is attached to the loop device now; the ISO mount
       is no longer needed and must not leak into the final root. */
    if (umount2("/run/cherry/bootmnt", MNT_DETACH) < 0)
        debug_msg("umount boot media: %s", strerror(errno));
    else
        debug_msg("unmounted boot media");

    if (persist_active) {
        snprintf(upperdir, sizeof(upperdir), "%s/upper", PERSIST_MNT);
        snprintf(workdir, sizeof(workdir), "%s/work", PERSIST_MNT);
        log_msg("INFO", "Using persistent overlay upper directory");
    } else {
        mkdir_required("/run/cherry/cowspace", 0755);
        mount_required("tmpfs", "/run/cherry/cowspace", "tmpfs", 0,
                       "size=" OVERLAY_SIZE ",mode=0755");
        mkdir_required("/run/cherry/cowspace/upper", 0755);
        mkdir_required("/run/cherry/cowspace/work", 0755);
        snprintf(upperdir, sizeof(upperdir),
                 "/run/cherry/cowspace/upper");
        snprintf(workdir, sizeof(workdir), "/run/cherry/cowspace/work");
    }

    snprintf(options, sizeof(options),
             "lowerdir=/run/cherry/airootfs,upperdir=%s,workdir=%s",
             upperdir, workdir);

    mount_required("overlay", "/new_root", "overlay", 0, options);

    log_msg("INFO", "Overlay root is ready (%s upper)",
            persist_active ? "persistent" : "tmpfs");
}

static void write_live_config(void)
{
    int fd = open(LIVE_CONF, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);

    if (fd < 0) {
        log_msg("WARN", "cannot write %s: %s", LIVE_CONF, strerror(errno));
        return;
    }

    dprintf(fd,
            "# Generated by Cherry Linux boot init\n"
            "CHERRY_LIVE=1\n"
            "CHERRY_PERSIST=%d\n",
            persist_active);
    close(fd);
}

static void move_mount_tree(const char *old_path, const char *new_path)
{
    if (mount(old_path, new_path, NULL, MS_MOVE, NULL) < 0)
        fatal("move mount %s -> %s: %s", old_path, new_path, strerror(errno));
}

static int is_initial_rootfs_fd(int fd)
{
    struct statfs stfs;
    if (fstatfs(fd, &stfs) < 0)
        return 0;

    return stfs.f_type == TMPFS_MAGIC || stfs.f_type == RAMFS_MAGIC;
}

static void remove_initial_root(int fd)
{
    DIR *dir = fdopendir(fd);
    if (!dir) {
        close(fd);
        return;
    }

    int root_fd = dirfd(dir);
    struct stat root_st;
    if (fstat(root_fd, &root_st) < 0) {
        closedir(dir);
        return;
    }

    for (;;) {
        struct dirent *entry;
        errno = 0;
        entry = readdir(dir);
        if (!entry)
            break;

        if (entry->d_name[0] == '.' &&
            (entry->d_name[1] == '\0' ||
             (entry->d_name[1] == '.' && entry->d_name[2] == '\0')))
            continue;

        struct stat st;
        if (fstatat(root_fd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW) < 0)
            continue;

        /* Never descend into mounted filesystems. */
        if (st.st_dev != root_st.st_dev)
            continue;

        if (S_ISDIR(st.st_mode)) {
            int child_fd = openat(root_fd, entry->d_name,
                                  O_RDONLY | O_DIRECTORY | O_CLOEXEC);
            if (child_fd >= 0) {
                remove_initial_root(child_fd);
            }
            (void)unlinkat(root_fd, entry->d_name, AT_REMOVEDIR);
        } else {
            (void)unlinkat(root_fd, entry->d_name, 0);
        }
    }

    closedir(dir);
}

static void switch_root(void)
{
    mkdir_required("/new_root/dev", 0755);
    mkdir_required("/new_root/proc", 0555);
    mkdir_required("/new_root/sys", 0555);
    mkdir_required("/new_root/run", 0755);

    /* /run carries Cherry's runtime mount tree into the final root. */
    move_mount_tree("/dev", "/new_root/dev");
    move_mount_tree("/proc", "/new_root/proc");
    move_mount_tree("/sys", "/new_root/sys");
    move_mount_tree("/run", "/new_root/run");

    int old_root_fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (old_root_fd < 0)
        fatal("open initial root: %s", strerror(errno));

    if (chdir("/new_root") < 0)
        fatal("chdir /new_root: %s", strerror(errno));

    if (mount(".", "/", NULL, MS_MOVE, NULL) < 0)
        fatal("move new root over initramfs root: %s", strerror(errno));

    if (chroot(".") < 0)
        fatal("chroot new root: %s", strerror(errno));

    if (chdir("/") < 0)
        fatal("chdir /: %s", strerror(errno));

    log_msg("INFO", "Switched to Cherry Linux rootfs");

    if (is_initial_rootfs_fd(old_root_fd)) {
        log_msg("INFO", "Releasing initial initramfs root");
        remove_initial_root(old_root_fd);
    } else {
        close(old_root_fd);
        log_msg("WARN", "Initial root is not tmpfs/ramfs; left untouched");
    }
}

static void exec_runtime_init(void)
{
    char *const argv[] = { "init", NULL };

    log_msg("INFO", "Transferring control to /sbin/init");
    execv("/sbin/init", argv);

    fatal("cannot execute /sbin/init: %s", strerror(errno));
}

int main(void)
{
    if (getpid() != 1)
        fatal("Cherry boot init must run as PID 1 (got %ld)", (long)getpid());

    log_msg("INFO", "Starting Cherry Linux bootstrap...");

    const char *dirs[] = {
        "/proc", "/sys", "/dev", "/run", "/mnt", "/tmp",
        "/new_root"
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

    mkdir_required("/run/cherry", 0755);
    mkdir_required("/run/cherry/bootmnt", 0755);

    parse_cmdline();

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
    attach_rootfs_loop("/run/cherry/bootmnt/boot/rootfs.sfs");
    mount_persistence();
    build_overlay_root();
    write_live_config();
    switch_root();
    exec_runtime_init();

    return 0;
}
