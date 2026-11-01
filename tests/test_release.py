"""Regression tests which never mount or reboot the host."""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[1]


class InitSafetyTests(unittest.TestCase):
    def compile_run(self, filename, body):
        source = ('#define main cherry_main\n#define reboot forbidden_reboot\n'
                  '#include ' + json.dumps(str(PROJECT / filename)) + '\n'
                  '#undef main\n#include <assert.h>\n'
                  'int forbidden_reboot(int action) { (void)action; abort(); }\n' + body)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / 'test.c').write_text(source)
            subprocess.run(['gcc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                            str(path / 'test.c'), '-o', str(path / 'test')], check=True)
            return subprocess.run([str(path / 'test')], capture_output=True, timeout=5)

    def test_non_pid1_refuses_without_reboot(self):
        for filename in ('src/init.c', 'src/boot_init.c'):
            with self.subTest(filename=filename):
                result = self.compile_run(filename, 'int main(void) { return cherry_main(); }')
                self.assertEqual(result.returncode, 1, result.stderr)

    def test_persistence_directory_rejects_file_and_symlink(self):
        result = self.compile_run('src/boot_init.c', r'''
int main(void) {
    char dir[] = "/tmp/cherry-dirs-XXXXXX";
    assert(mkdtemp(dir));
    char path[PATH_MAX]; snprintf(path, sizeof(path), "%s/upper", dir);
    FILE *f = fopen(path, "w"); assert(f); fclose(f);
    assert(persist_directory(path) == -1); unlink(path);
    assert(symlink(dir, path) == 0);
    assert(persist_directory(path) == -1); unlink(path);
    assert(persist_directory(path) == 0);
    assert(persist_directory(path) == 0); rmdir(path); rmdir(dir);
    return 0;
}''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_shutdown_interrupts_hook(self):
        result = self.compile_run('src/init.c', r'''
int main(void) {
    char path[] = "/tmp/cherry-hook-XXXXXX";
    int fd = mkstemp(path); assert(fd >= 0);
    const char text[] = "#!/bin/sh\nsleep 20\n";
    assert(write(fd, text, sizeof(text)-1) == sizeof(text)-1);
    assert(fchmod(fd, 0700) == 0); close(fd);
    install_shutdown_handlers();
    pid_t sender = fork(); assert(sender >= 0);
    if (!sender) { usleep(100000); kill(getppid(), SIGTERM); _exit(0); }
    run_script(path);
    assert(shutdown_request == 2);
    waitpid(sender, NULL, 0); unlink(path);
    return 0;
}''')
        self.assertEqual(result.returncode, 0, result.stderr)


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='cherry-chepm-')
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.root = self.path / 'root'
        self.root.mkdir()
        self.env = dict(os.environ, CHEPM_ROOT=str(self.root))

    def package(self, name, members):
        archive = self.path / (name + '.tar.gz')
        with tarfile.open(archive, 'w:gz') as tar:
            for path, data, kind in members:
                item = tarfile.TarInfo(path)
                item.mode = 0o755
                if kind == 'link':
                    item.type = tarfile.SYMTYPE
                    item.linkname = data
                    tar.addfile(item)
                else:
                    content = data.encode()
                    item.size = len(content)
                    tar.addfile(item, io.BytesIO(content))
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        return str(archive), digest

    def run_chepm(self, *args):
        return subprocess.run([str(PROJECT / 'utils/chepm'), *args], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def test_install_conflict_remove(self):
        package = self.package('good', [('usr/bin/example', 'hello', 'file')])
        result = self.run_chepm('-ins', 'good', *package)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'usr/bin/example').read_text(), 'hello')
        result = self.run_chepm('-ins', 'conflict', *package)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / 'var/lib/chepm/manifests/conflict').exists())
        self.assertEqual(self.run_chepm('-del', 'good').returncode, 0)
        self.assertFalse((self.root / 'usr/bin/example').exists())

    def test_bad_checksum_and_archive_do_not_publish_manifest(self):
        archive, digest = self.package('bad', [('usr/bin/example', 'hello', 'file')])
        self.assertNotEqual(self.run_chepm('-ins', 'bad', archive, '0'*64).returncode, 0)
        Path(archive).write_bytes(b'broken')
        digest = hashlib.sha256(b'broken').hexdigest()
        for _ in range(2):
            self.assertNotEqual(self.run_chepm('-ins', 'bad', archive, digest).returncode, 0)
            self.assertFalse((self.root / 'var/lib/chepm/manifests/bad').exists())

    def test_traversal_links_and_parent_symlinks_rejected(self):
        for filename, kind in (('../escape', 'file'), ('usr/link', 'link')):
            package = self.package('unsafe', [(filename, '/tmp', kind)])
            self.assertNotEqual(self.run_chepm('-ins', 'unsafe', *package).returncode, 0)
        (self.root / 'usr').symlink_to(self.path, target_is_directory=True)
        package = self.package('unsafe', [('usr/escape', 'bad', 'file')])
        self.assertNotEqual(self.run_chepm('-ins', 'unsafe', *package).returncode, 0)
        self.assertFalse((self.path / 'escape').exists())


class LibraryTests(unittest.TestCase):
    def test_target_library_and_soname_are_preserved(self):
        with tempfile.TemporaryDirectory(prefix='cherry-libs-') as tmp:
            directory = Path(tmp)
            target, host = directory/'root', directory/'host'
            for path in (target/'usr/lib', target/'usr/bin', target/'usr/sbin', host):
                path.mkdir(parents=True, exist_ok=True)
            source = directory/'library.c'
            for folder, value in ((host, 99), (target/'usr/lib', 7)):
                source.write_text(f'int cherry_value(void) {{ return {value}; }}\n')
                subprocess.run(['gcc', '-fPIC', '-shared', '-Wl,-soname,libcherrytest.so.1',
                    str(source), '-o', str(folder/'libcherrytest.so.1.0')], check=True)
                (folder/'libcherrytest.so.1').symlink_to('libcherrytest.so.1.0')
            source.write_text('#include <stdio.h>\nint cherry_value(void);\nint main(void) { printf("%d\\n", cherry_value()); }\n')
            binary = target/'usr/bin/probe'
            subprocess.run(['gcc',str(source),'-L'+str(host),'-l:libcherrytest.so.1',
                '-Wl,-rpath,'+str(host),'-o',str(binary)],check=True)
            before = (target/'usr/lib/libcherrytest.so.1.0').read_bytes()
            subprocess.run(['bash','-c', 'die() { echo "$*" >&2; exit 1; }; source "$1"; copy_runtime_libraries',
                'test',str(PROJECT/'scripts/copy-libraries.sh')],
                env=dict(os.environ,TARGET_DIR=str(target)),check=True,capture_output=True)
            self.assertTrue((target/'usr/lib/libcherrytest.so.1').is_symlink())
            self.assertEqual(before,(target/'usr/lib/libcherrytest.so.1.0').read_bytes())
            output=subprocess.check_output([str(target/'usr/lib/ld-linux-x86-64.so.2'),
                '--library-path',str(target/'usr/lib'),str(binary)],text=True)
            self.assertEqual(output.strip(),'7')


class ConfigurationTests(unittest.TestCase):
    def test_overlay_wins_and_stale_command_hash_is_reset(self):
        import shutil
        with tempfile.TemporaryDirectory(prefix='cherry config ') as tmp:
            directory = Path(tmp)
            project, target = directory/'project', directory/'root'
            (project/'overlay/etc').mkdir(parents=True)
            (target/'etc').mkdir(parents=True)
            (project/'scripts').mkdir()
            shutil.copy(PROJECT/'scripts/live-login', project/'scripts')
            shutil.copytree(PROJECT/'utils',project/'utils')
            (project/'overlay/etc/hostname').write_text('custom-host\n')
            (project/'overlay/etc/resolv.conf').write_text('nameserver 192.0.2.1\n')
            env = dict(os.environ, PROJECT_DIR=str(project), TARGET_DIR=str(target),
                       BUILD_DIR=str(directory), CHERRY_VERSION='0.6.5', ENABLE_NET='0')
            command = 'set -euo pipefail; log() { :; }; hash -p /nonexistent/install install; source "$1"'
            result = subprocess.run(['bash','-c',command,'test',str(PROJECT/'scripts/rootfs-config.sh')],
                                    env=env,capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertEqual((target/'etc/hostname').read_text(),'custom-host\n')
            self.assertEqual((target/'etc/resolv.conf').read_text(),'nameserver 192.0.2.1\n')
            self.assertFalse((target/'usr/lib/cherry/net-up').exists())
            self.assertTrue(os.access(target/'usr/bin/cherry-help',os.X_OK))

    def test_publish_refuses_unmanaged_or_recovery_directory(self):
        with tempfile.TemporaryDirectory(prefix='cherry-publish-') as tmp:
            directory=Path(tmp)
            stage,target=directory/'stage',directory/'target'
            stage.mkdir();target.mkdir()
            (target/'keep').write_text('original')
            script='set -euo pipefail; source "$1"; publish_tree "$2" "$3"'
            args=['bash','-c',script,'test',str(PROJECT/'scripts/build-common.sh'),str(stage),str(target)]
            result=subprocess.run(args,env=dict(os.environ,PROJECT_DIR=str(PROJECT)),capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual((target/'keep').read_text(),'original')
            (target/'.cherry-build-inputs').touch()
            previous=directory/'target.previous';previous.mkdir()
            (previous/'recover').write_text('recovery')
            result=subprocess.run(args,env=dict(os.environ,PROJECT_DIR=str(PROJECT)),capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual((previous/'recover').read_text(),'recovery')
