#define _GNU_SOURCE
#include <errno.h>
#include <limits.h>
#include <mntent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

/* Executed by PID 1 from /run after all other userspace processes stop.
 * Moving into RAM releases the executable and cwd references to OverlayFS. */
static int deepest_first(const void *a, const void *b)
{
    size_t x = strlen(*(char *const *)a), y = strlen(*(char *const *)b);
    return x < y ? 1 : x > y ? -1 : 0;
}

int main(int argc, char **argv)
{
    if (getpid() != 1 || argc != 2) {
        fprintf(stderr, "cherry-shutdown must be invoked by PID 1\n");
        return EXIT_FAILURE;
    }
    int action;
    if (!strcmp(argv[1], "poweroff")) action = RB_POWER_OFF;
    else if (!strcmp(argv[1], "reboot")) action = RB_AUTOBOOT;
    else if (!strcmp(argv[1], "halt")) action = RB_HALT_SYSTEM;
    else return EXIT_FAILURE;

    sync();
    if (chdir("/run") < 0 || (mkdir("oldroot", 0700) < 0 && errno != EEXIST) ||
        syscall(SYS_pivot_root, ".", "oldroot") < 0) {
        perror("[SHUTDOWN] pivot_root into RAM");
        /* Do not claim a clean shutdown when we cannot release the live root. */
        for (;;) pause();
    }
    chdir("/");
    char **paths = NULL;
    size_t count = 0;
    FILE *fp = setmntent("/oldroot/proc/mounts", "r");
    if (!fp) { perror("[SHUTDOWN] mount table"); for (;;) pause(); }
    struct mntent *entry;
    while ((entry = getmntent(fp)) != NULL) {
        if (strcmp(entry->mnt_dir, "/") == 0) continue;
        char **next = realloc(paths, (count + 1) * sizeof(*paths));
        if (!next) { perror("[SHUTDOWN] memory"); for (;;) pause(); }
        paths = next;
        paths[count] = strdup(entry->mnt_dir);
        if (!paths[count]) { perror("[SHUTDOWN] memory"); for (;;) pause(); }
        count++;
    }
    endmntent(fp);
    qsort(paths, count, sizeof(*paths), deepest_first);
    /* First release oldroot (overlay), then its lower and upper backing mounts.
     * Pseudofilesystems may be pinned by our console; lazy detach only those. */
    int failed = 0;
    for (int pass = 0; pass < 2; pass++) {
        for (size_t i = 0; i < count; i++) {
            int oldroot = !strcmp(paths[i], "/oldroot") || !strncmp(paths[i], "/oldroot/", 9);
            if (oldroot != (pass == 0)) continue;
            if (umount2(paths[i], 0) == 0) continue;
            if ((!strncmp(paths[i], "/oldroot/dev", 12) ||
                 !strcmp(paths[i], "/oldroot/proc") || !strcmp(paths[i], "/oldroot/sys")) &&
                umount2(paths[i], MNT_DETACH) == 0) continue;
            if (mount(NULL, paths[i], NULL, MS_REMOUNT | MS_RDONLY, NULL) == 0) continue;
            fprintf(stderr, "[SHUTDOWN] cannot close %s: %s\n", paths[i], strerror(errno));
            failed = 1;
        }
    }
    sync();
    if (failed) {
        fprintf(stderr, "[SHUTDOWN] shutdown stopped: writable mounts remain\n");
        for (;;) pause();
    }
    printf("[SHUTDOWN] Filesystems closed cleanly\n");
    fflush(stdout);
    reboot(action);
    perror("[SHUTDOWN] reboot");
    for (;;) pause();
}
