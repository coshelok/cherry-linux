# Cherry Linux

<img width="1024" height="1024" alt="cherry" src="https://github.com/user-attachments/assets/aa7255cc-bb40-480c-ab17-3aa548c2a371" />


Cherry Linux is a small, source-built live GNU/Linux distribution. Every
userspace component is compiled from upstream sources during the build; the
resulting image boots from a CD or USB drive, runs from a RAM-backed
overlay, and can optionally persist changes to a writable partition.

Current status: **0.6.0**. The project is working towards a
stable 1.0.0 release; see the roadmap below.

## Features

- Linux kernel built from Cherry's own config (monolithic, no modules)
- GNU userland built from source: bash, coreutils, grep, sed, gawk,
  findutils, diffutils, tar, gzip, bzip2, xz, make, patch
- BusyBox for networking (`udhcpc`, `ip`, `wget`), login and device
  management (`mdev`, `syslogd`)
- Static C boot bootstrap (`src/boot_init.c`) and runtime init
  (`src/init.c`) with no external runtime dependencies
- SquashFS live root on an OverlayFS mount, persistent or RAM-backed
- Limine bootloader (BIOS and UEFI)
- `cherryfetch` system information tool
- `chepm` package manager (experimental)

## Repository layout

| Path | Purpose |
| --- | --- |
| `build.sh` | Full build: kernel, rootfs, initramfs, SquashFS, ISO |
| `rootfs.sh` | Builds the root filesystem from upstream sources |
| `cherry.config` | Kernel configuration |
| `src/` | C sources of the boot and runtime init |
| `overlay/` | Files merged into the rootfs at build time |
| `utils/` | `cherryfetch` and `chepm` |
| `kernel/` | Kernel source tree (fetched automatically, not tracked by git) |
| `tools/limine-src/` | Vendored Limine bootloader binaries |
| `build/` | Build artifacts (ISO, rootfs, cached sources) |

## Requirements

Build host: x86_64 Linux with a working C toolchain and the usual build
tools (`bash`, `gcc`, `make`, `wget`, `cpio`). `mksquashfs` and `xorriso`
are built automatically if missing. The build does not require root.

## Building

```sh
make            # equivalent to ./build.sh
```

The kernel source tree is downloaded (and its sha256 verified) into
`kernel/` when missing. All package archives are cached in `build/sources`
and verified against pinned sha256 checksums on every build. The first
build is slow because it compiles the kernel; later builds reuse it.

Useful environment variables:

| Variable | Effect |
| --- | --- |
| `REBUILD_ROOTFS=1` | Rebuild the rootfs from scratch |
| `ROOTFS_PROFILE=minimal` | Skip non-essential packages |
| `ENABLE_NET=0` | Skip BusyBox networking setup |
| `KERNEL_VERSION=7.0.10` | Kernel version to build |
| `KERNEL_DIR=...` | Use a custom kernel source tree |
| `BUILD_DIR=...` | Alternate build directory |

Build output: `build/cherrylinux-v<VERSION>.iso`.

## Running in QEMU

```sh
make run        # or ./run.sh
```

`run.sh` boots the newest ISO with a `virtio` network device behind QEMU
user-mode networking (DHCP works out of the box). Extra QEMU arguments can
be passed via `QEMU_EXTRA`, and resources via `MEM`/`CPUS`.

## Boot options

Options are passed on the kernel command line:

| Option | Effect |
| --- | --- |
| `cherry.persist` | Enable persistence; autodetect the store by the `cherry-persist` label |
| `cherry.persist=LABEL=name`, `UUID=...`, `/dev/sdX` | Use an explicit persistence store |
| `single`, `rescue`, `cherry.rescue` | Rescue mode: skip network setup and `rc.local` |
| `cherry.debug` | Verbose logging from the boot and runtime init |
| `cherry.hostname=NAME` | Override the default hostname (`cherrylinux`) |

## Persistence

The persistence store is a regular filesystem on a disk or partition,
labelled `cherry-persist` or selected via `cherry.persist=...`. OverlayFS
requires extended attribute support on the store, so use ext4, xfs, btrfs
or f2fs (vfat/exfat are not suitable). The `upper/` and `work/`
directories are created automatically on first boot.

To prepare a store from another Linux system:

```sh
mkfs.ext4 -L cherry-persist /dev/sdX1
```

## Overlay

Files under `overlay/` are merged into the root filesystem on every rootfs
build and are a convenient place for site-specific configuration:

- `overlay/etc/rc.local` — runs at every boot (must be executable)
- `overlay/etc/rc.shutdown` — runs before halt/reboot/poweroff
- `overlay/home/cherry/` — initial home directory of the `cherry` user

## Testing

There is no CI yet; every release is validated manually against
[TESTING.md](TESTING.md).

## Roadmap

- `0.6.x` — build infrastructure: pinned checksums, kernel auto-download,
  Makefile, QEMU runner, documentation
- `0.7.0` — boot/init reliability: persistence fixes, rescue shell,
  shutdown polish
- `0.8.0` — live UX: Limine boot menu, getty, editor, TLS
- `0.9.0` — kernel and hardware: user namespaces, zram, firmware
- `1.0.0` — stable release

## License

Cherry Linux project code is licensed under the GNU General Public
License, version 2.0 (see [LICENSE](LICENSE)). Bundled components remain
under their own respective licenses.
