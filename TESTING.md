# Testing Cherry Linux

All VM tests use temporary disk images. They never mount or reboot the host.
Unit tests compile actual init code with the reboot syscall replaced by a trap.

## Dependencies

`make test`: Python 3, GCC, binutils, GNU coreutils/tar/gzip, Bash.

VM tests additionally need QEMU x86_64, e2fsprogs (`mkfs.ext4`, `debugfs`,
`dumpe2fs`), `blkid`, dosfstools (`mkfs.vfat`), and OpenSSL. ISO UEFI tests need
OVMF (`ovmf` on Debian/Ubuntu, `edk2-ovmf` on Arch). No KVM or network downloads
are required for tests. The TLS server runs inside the guest.

## Commands

```sh
make test
make build
make smoke
make smoke-iso
```

`make smoke` checks rescue, DHCP client lifetime, missing/unknown persistence,
early-boot emergency-shell restart, rejection of locked password login,
successful password login after setting a password on persistent storage,
write/read across boots by label/UUID/device, volatile mode, malformed upper,
and unsupported VFAT storage. Every successful VM must report clean shutdown;
ext4 metadata must no longer contain `needs_recovery` or `orphan_present`.

TLS tests require an untrusted certificate and a wrong hostname to fail,
a locally trusted matching certificate to succeed (including the default CA
lookup without environment overrides), and a missing OpenSSL
executable to fail closed. They do not disable verification to obtain a pass.

`make smoke-iso` boots the existing ISO through firmware and Limine, saves a
screenshot, types through the graphical console, verifies a registered
framebuffer via serial output, and shuts down. It does not bypass the bootloader
with QEMU `-kernel`. These tests cover emulated standard VGA, not every real GPU
or Secure Boot.

## Build profiles

Use separate output directories; do not run builds sharing extracted sources
concurrently. The normal builder locks each BUILD_DIR.

```sh
BUILD_DIR=build-minimal ROOTFS_PROFILE=minimal THREADS=4 ./build.sh
python3 tests/smoke.py --build-dir build-minimal
python3 tests/tls.py --build-dir build-minimal
BUILD_DIR=build-offline ENABLE_NET=0 THREADS=4 ./build.sh
python3 tests/smoke.py --build-dir build-offline --no-network
python3 tests/console.py --build-dir build-offline
```

Set `SOURCES_DIR` to an existing cache if downloads are unavailable. Minimal
removes development headers, static archives, documentation and translations;
network-disabled builds retain getty, mdev, mount, vi and power commands.

## Logs and failure diagnosis

- Package build logs: `BUILD_DIR/pkg-*.log`.
- Failed boot cases: `BUILD_DIR/smoke-logs/`.
- TLS guest log: `BUILD_DIR/tls-logs/`.
- Emergency and password-login logs: `BUILD_DIR/console-logs/`.
- Firmware screenshots, serial and QEMU logs: `BUILD_DIR/iso-logs/`.

For a manual serial console use `CMDLINE_EXTRA='console=ttyS0 cherry.debug'`
when building, then pass `QEMU_EXTRA='-display none -serial stdio'` to run.sh.
The default ISO uses the graphical/local console. To inspect an early boot
failure, use the emergency BusyBox shell and `busybox dmesg`.

A shutdown helper failure deliberately stops before poweroff and reports the
remaining mount; it must not be reported as a successful clean shutdown.
