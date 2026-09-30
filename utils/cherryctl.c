#define _GNU_SOURCE

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/reboot.h>
#include <sys/utsname.h>
#include <unistd.h>

static const char *read_pretty_name(void)
{
    static char value[256];
    FILE *file = fopen("/etc/os-release", "r");

    if (!file)
        return "Cherry Linux";

    while (fgets(value, sizeof(value), file)) {
        if (strncmp(value, "PRETTY_NAME=", 12) == 0) {
            char *name = value + 12;
            size_t len = strlen(name);

            if (len > 0 && name[len - 1] == '\n')
                name[--len] = '\0';

            if (len >= 2 && name[0] == '"' && name[len - 1] == '"') {
                name[len - 1] = '\0';
                memmove(name, name + 1, len - 1);
            }

            fclose(file);
            return name;
        }
    }

    fclose(file);
    return "Cherry Linux";
}

static void print_help(void)
{
    puts("Usage: cherryctl <command>");
    puts("");
    puts("Commands:");
    puts("  version    Print Cherry Linux version");
    puts("  info       Print basic system information");
    puts("  status     Show basic system status");
    puts("  reboot     Reboot the system");
    puts("  poweroff   Power off the system");
}

static int require_root(void)
{
    if (geteuid() != 0) {
        fprintf(stderr, "cherryctl: this command requires root\n");
        return 1;
    }

    return 0;
}

static int do_reboot(int command)
{
    if (require_root() != 0)
        return 1;

    sync();

    if (reboot(command) < 0) {
        fprintf(stderr, "cherryctl: reboot failed: %s\n", strerror(errno));
        return 1;
    }

    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        print_help();
        return argc == 1 ? 0 : 1;
    }

    if (strcmp(argv[1], "help") == 0 || strcmp(argv[1], "--help") == 0) {
        print_help();
        return 0;
    }

    if (strcmp(argv[1], "version") == 0) {
        puts(read_pretty_name());
        return 0;
    }

    if (strcmp(argv[1], "info") == 0) {
        struct utsname uts;

        if (uname(&uts) < 0) {
            fprintf(stderr, "cherryctl: uname failed: %s\n", strerror(errno));
            return 1;
        }

        printf("OS:           %s\n", read_pretty_name());
        printf("Kernel:       %s\n", uts.release);
        printf("Architecture: %s\n", uts.machine);
        printf("Init PID:     1\n");
        printf("Init process: ");

        FILE *comm = fopen("/proc/1/comm", "r");
        if (comm) {
            char name[128];

            if (fgets(name, sizeof(name), comm))
                fputs(name, stdout);
            else
                puts("unknown");

            fclose(comm);
        } else {
            puts("unavailable");
        }

        return 0;
    }

    if (strcmp(argv[1], "status") == 0) {
        if (access("/proc/1", F_OK) != 0) {
            puts("Cherry init: not running");
            return 1;
        }

        if (access("/etc/os-release", R_OK) != 0) {
            puts("Base system: incomplete");
            return 1;
        }

        puts("Cherry init: running (PID 1)");
        puts("Base system: ready");
        return 0;
    }

    if (strcmp(argv[1], "reboot") == 0)
        return do_reboot(RB_AUTOBOOT);

    if (strcmp(argv[1], "poweroff") == 0)
        return do_reboot(RB_POWER_OFF);

    fprintf(stderr, "cherryctl: unknown command '%s'\n", argv[1]);
    print_help();
    return 1;
}
