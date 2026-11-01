"""Run with: python3 -m unittest discover -s tests"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]


class RootfsCacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="cherry-cache-test-")
        self.addCleanup(self.tmp.cleanup)
        self.project = Path(self.tmp.name)
        for name in ("scripts", "utils", "overlay"):
            (self.project / name).mkdir()
        shutil.copy(PROJECT / "scripts/rootfs-cache.sh", self.project / "scripts")
        (self.project / "rootfs.sh").write_text("recipe\n")
        (self.project / "VERSION").write_text("0.6.1\n")
        self.file = self.project / "overlay/rc.local"
        self.file.write_text("original\n")

    def fingerprint(self, function="rootfs_input_hash", **options):
        env = {"PATH": os.environ["PATH"], "PROJECT_DIR": str(self.project)}
        env.update(options)
        return subprocess.check_output(
            ["bash", "-c", 'source "$PROJECT_DIR/scripts/rootfs-cache.sh"; '
             'CHERRY_VERSION=$(cat "$PROJECT_DIR/VERSION"); ' + function],
            env=env, text=True,
        ).strip()

    def test_timestamps_do_not_invalidate_cache(self):
        before = self.fingerprint()
        os.utime(self.file, (100, 100))
        self.assertEqual(before, self.fingerprint())

    def test_overlay_content_mode_and_removal_invalidate_cache(self):
        before = self.fingerprint()
        self.file.write_text("changed\n")
        content = self.fingerprint()
        self.assertNotEqual(before, content)
        self.file.chmod(0o755)
        mode = self.fingerprint()
        self.assertNotEqual(content, mode)
        self.file.unlink()
        self.assertNotEqual(mode, self.fingerprint())

    def test_overlay_symlink_target_invalidates_cache(self):
        link = self.project / "overlay/link"
        link.symlink_to("one")
        before = self.fingerprint()
        link.unlink()
        link.symlink_to("two")
        self.assertNotEqual(before, self.fingerprint())

    def test_recipe_version_and_utilities_invalidate_cache(self):
        for filename in ("rootfs.sh", "VERSION", "utils/cherryfetch"):
            with self.subTest(filename=filename):
                before = self.fingerprint()
                (self.project / filename).write_text("changed\n")
                self.assertNotEqual(before, self.fingerprint())

    def test_build_options_invalidate_cache(self):
        before = self.fingerprint()
        for key, value in {
            "ROOTFS_PROFILE": "minimal", "ENABLE_NET": "0",
            "ENABLE_BUSYBOX": "1", "BUSYBOX_VERSION": "other",
            "BUSYBOX_SHA256": "other", "CFLAGS": "-O0", "CC": "clang",
        }.items():
            with self.subTest(option=key):
                self.assertNotEqual(before, self.fingerprint(**{key: value}))
        self.assertEqual(before, self.fingerprint(ENABLE_NET="1", ROOTFS_PROFILE="full"))

    def test_package_cache_survives_overlay_version_and_utility_edits(self):
        before = self.fingerprint(function="package_input_hash")
        for filename in ("overlay/rc.local", "VERSION", "utils/cherryfetch", "scripts/rootfs-config.sh"):
            (self.project / filename).write_text("new configuration\n")
            self.assertEqual(before, self.fingerprint(function="package_input_hash"))
        (self.project / "rootfs.sh").write_text("new recipe\n")
        self.assertNotEqual(before, self.fingerprint(function="package_input_hash"))


if __name__ == "__main__":
    unittest.main()
