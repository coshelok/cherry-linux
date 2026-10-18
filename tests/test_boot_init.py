"""Exercise bootstrap failure paths without mounting anything on the host."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]


class BootInitTests(unittest.TestCase):
    def test_missing_blkid_clears_device_path(self):
        source = r'''
#define main cherry_boot_main
#define access boot_test_access
#include BOOT_SOURCE
#undef main
#undef access
#include <assert.h>

int boot_test_access(const char *path, int mode)
{
    (void)path;
    (void)mode;
    errno = ENOENT;
    return -1;
}

int main(void)
{
    char out[PATH_MAX];
    const char *specs[] = { "", "LABEL=missing", "UUID=missing", "missing" };
    for (size_t i = 0; i < sizeof(specs) / sizeof(specs[0]); ++i) {
        snprintf(opt_persist_spec, sizeof(opt_persist_spec), "%s", specs[i]);
        strcpy(out, "/dev/unrelated-disk");
        persist_device_path(out, sizeof(out));
        assert(out[0] == '\0');
    }
    strcpy(opt_persist_spec, "/dev/vda");
    persist_device_path(out, sizeof(out));
    assert(strcmp(out, "/dev/vda") == 0);
    persist_device_path(NULL, 0);
    return 0;
}
'''.replace("BOOT_SOURCE", json.dumps(str(PROJECT / "src/boot_init.c")))
        with tempfile.TemporaryDirectory(prefix="cherry-boot-test-") as tmp:
            src = Path(tmp) / "test.c"
            binary = Path(tmp) / "test"
            src.write_text(source)
            subprocess.run(["gcc", "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                            str(src), "-o", str(binary)], check=True)
            subprocess.run([str(binary)], check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
