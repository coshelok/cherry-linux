#!/usr/bin/env python3
"""Boot existing build artifacts in QEMU; use temporary persistence disks only."""

import argparse
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time


PROJECT = Path(__file__).resolve().parents[1]
COMMON = """
test -r /run/cherry/live.conf &&
test "$(grep -c ' /run ' /proc/mounts)" = 1 &&
test "$(grep -c ' /dev ' /proc/mounts)" = 1 &&
test "$(grep -c ' /dev/pts ' /proc/mounts)" = 1 &&
test -n "$(/usr/bin/busybox pidof mdev)"
""".strip().replace("\n", " ")


def boot(name, args, directory, cmdline, check, disk=None):
    command = [
        "qemu-system-x86_64", "-accel", "tcg", "-m", "512", "-smp", "2",
        "-kernel", str(args.kernel), "-initrd", str(args.build_dir / "init.cpio.gz"),
        "-append", "console=ttyS0 loglevel=4 cherry.debug " + cmdline,
        "-cdrom", str(args.iso), "-display", "none", "-serial", "stdio",
        "-monitor", "none", "-no-reboot", "-netdev", "user,id=net0",
        "-device", "virtio-net-pci,netdev=net0",
    ]
    if disk:
        command += ["-drive", f"file={disk},format=raw,if=virtio"]
    output = bytearray()
    sent = False
    deadline = time.monotonic() + 90
    proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(proc.stdout, selectors.EVENT_READ)
            while time.monotonic() < deadline:
                for key, _ in selector.select(timeout=1):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    output.extend(chunk)
                if not sent and b"cherry:/# " in output:
                    # Split the marker in printf so terminal echo cannot fake success.
                    shell = (f"if ( {COMMON} && {check} ); then "
                             "printf '__CHERRY_%s__\\n' PASS; else "
                             "printf '__CHERRY_%s__\\n' FAIL; fi; poweroff\n")
                    proc.stdin.write(shell.encode())
                    proc.stdin.flush()
                    sent = True
                if proc.poll() is not None:
                    # Drain any final shutdown output.
                    output.extend(proc.stdout.read())
                    break
            else:
                raise RuntimeError(f"{name}: VM timed out")
        log = output.decode(errors="replace").replace("\r", "")
        if (proc.returncode != 0 or "__CHERRY_PASS__" not in log
                or "__CHERRY_FAIL__" in log or "[BOOT][FATAL]" in log):
            raise RuntimeError(f"{name}: guest checks failed")
        if name == "missing-store" and "cannot mount persistence store" in log:
            raise RuntimeError("missing-store: attempted to mount an unrelated device")
        if name == "vfat" and "extended attributes required" not in log:
            raise RuntimeError("vfat: missing unsupported-filesystem warning")
        print(f"PASS {name}", flush=True)
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        (directory / f"{name}.log").write_bytes(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=PROJECT / "build")
    parser.add_argument("--kernel", type=Path,
                        default=PROJECT / "kernel/linux-7.0.10/arch/x86/boot/bzImage")
    parser.add_argument("--iso", type=Path)
    args = parser.parse_args()
    args.build_dir = args.build_dir.resolve()
    args.kernel = args.kernel.resolve()
    args.iso = (args.iso or args.build_dir /
                f"cherrylinux-v{(PROJECT / 'VERSION').read_text().strip()}.iso").resolve()
    with tempfile.TemporaryDirectory(prefix="cherry-smoke-") as tmp:
        directory = Path(tmp)
        disk = directory / "persist.img"
        with disk.open("wb") as stream:
            stream.truncate(256 * 1024 * 1024)
        subprocess.run(["mkfs.ext4", "-q", "-F", "-L", "cherry-persist", str(disk)],
                       check=True)
        uuid = subprocess.check_output(["blkid", "-s", "UUID", "-o", "value", str(disk)],
                                       text=True).strip()
        try:
            boot("missing-store", args, directory, "cherry.persist",
                 'test "$CHERRY_PERSIST" = 0 && ping -c 1 10.0.2.2')
            boot("autodetect-write", args, directory, "cherry.persist",
                 'test "$CHERRY_PERSIST" = 1 && echo saved > /root/persist-test', disk)
            for name, spec in (("uuid-read", "UUID=" + uuid),
                               ("label-read", "LABEL=cherry-persist"),
                               ("device-read", "/dev/vda")):
                boot(name, args, directory, "cherry.persist=" + spec,
                     'test "$CHERRY_PERSIST" = 1 && '
                     'test "$(cat /root/persist-test)" = saved', disk)
            boot("unknown-label", args, directory, "cherry.persist=LABEL=missing",
                 'test "$CHERRY_PERSIST" = 0 && test ! -e /root/persist-test', disk)
            boot("volatile-control", args, directory, "",
                 'test "$CHERRY_PERSIST" = 0 && test ! -e /root/persist-test', disk)
            vfat = directory / "vfat.img"
            with vfat.open("wb") as stream:
                stream.truncate(64 * 1024 * 1024)
            subprocess.run(["mkfs.vfat", "-n", "CHERRYBAD", str(vfat)],
                           check=True, stdout=subprocess.DEVNULL)
            boot("vfat", args, directory, "cherry.persist=LABEL=CHERRYBAD",
                 'test "$CHERRY_PERSIST" = 0', vfat)
        except Exception:
            # Keep failed logs with build artifacts instead of losing them with tmp.
            logs = args.build_dir / "smoke-logs"
            logs.mkdir(exist_ok=True)
            for log in directory.glob("*.log"):
                (logs / log.name).write_bytes(log.read_bytes())
            print(f"Guest logs: {logs}", flush=True)
            raise


if __name__ == "__main__":
    main()
