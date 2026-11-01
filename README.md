# Cherry Linux

<img width="1024" height="1024" alt="cherry" src="https://github.com/user-attachments/assets/aa7255cc-bb40-480c-ab17-3aa548c2a371" />


Cherry Linux is a small, source-built live GNU/Linux distribution. Its
GNU tools and BusyBox are compiled from upstream sources during the build; the
resulting image boots from a CD or USB drive, runs from a RAM-backed
overlay, and can optionally persist changes to a writable partition.

Current status: **0.6.5**. The project is working towards a
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
- Limine bootloader (BIOS and UEFI) with Live / Persistent / Rescue / Debug entries
- Local getty with explicit root autologin; optional password login
- BusyBox `vi`, `cherry-help`, and `cherry-status`
- Verified HTTPS through BusyBox wget + OpenSSL; no unverified TLS fallback
- RAM-based shutdown helper which closes OverlayFS and persistence before poweroff
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
| `utils/` | `cherryfetch`, `chepm`, `cherry-help`, `cherry-status` |
| `kernel/` | Kernel source tree (fetched automatically, not tracked by git) |
| `tools/limine-src/` | Vendored Limine bootloader binaries |
| `build/` | Build artifacts (ISO, rootfs, cached sources) |

## Requirements

Build host: x86_64 Linux with a working C toolchain and the usual build
tools (`bash`, `gcc`, `make`, `wget`, `cpio`). `mksquashfs` and `xorriso`
are built automatically if missing. The build does not require root.
Static libc development libraries are required for the init programs and
BusyBox. Kernel compilation also needs flex, bison, bc, and libelf development
files. The build uses GNU tar, binutils (`readelf`), `file`, `realpath`, and
`flock`. Network-enabled images require the host `openssl` executable and a
CA bundle (default `/etc/ssl/certs/ca-certificates.crt`).

GNU utilities and BusyBox are compiled from pinned source archives. Missing
shared libraries, the dynamic loader, OpenSSL, and CA certificates are explicit
host bootstrap inputs. Existing target libraries take precedence and are never
overwritten. Their identities feed the cache; runtime library hashes are recorded
in the image's `.cherry-runtime-sha256`. This is not yet a hermetic or bit-for-bit
reproducible toolchain. Only native x86_64 Linux builds are supported.

## Building

```sh
make            # equivalent to ./build.sh
```

The kernel source tree is downloaded (and its sha256 verified) into
`kernel/` when missing. All package archives are cached in `build/sources`
and verified against pinned sha256 checksums before extraction. The first
build is slow because it compiles the kernel; later builds reuse it.
The package tree is cached separately from image configuration. Changes to
`VERSION`, utilities, or `overlay/` only reassemble the rootfs. Recipe, toolchain,
runtime library, TLS trust-store, or profile changes rebuild the package tree.
Downloaded archives remain cached. Builders lock their output directories and
publish completed trees and images only after their respective stages succeed.

Useful environment variables:

| Variable | Effect |
| --- | --- |
| `REBUILD_ROOTFS=1` | Rebuild the rootfs from scratch |
| `ROOTFS_PROFILE=minimal` | Skip non-essential packages |
| `ENABLE_NET=0` | Skip BusyBox networking setup |
| `KERNEL_VERSION=7.0.10` | Kernel version to build |
| `KERNEL_DIR=...` | Use a custom kernel source tree |
| `CMDLINE_EXTRA="cherry.login"` | Append kernel command line options to all ISO menu entries |
| `BUILD_DIR=...` | Alternate build directory; relative paths are resolved before compilation |
| `THREADS=8` | Maximum parallel make jobs |
| `CA_BUNDLE=...` | CA trust bundle imported into network-enabled images |

Build output: `build/cherrylinux-v<VERSION>.iso`.

## Running in QEMU

```sh
make run        # or ./run.sh
```

`run.sh` boots the ISO matching `VERSION` with a `virtio` network device behind QEMU
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
| `cherry.hostname=NAME` | Override `/etc/hostname` |
| `cherry.login` | Require password login instead of local root autologin |

The Live entry uses RAM only. Persistent requests a partition labelled
`cherry-persist`. Rescue skips network setup and `rc.local`. Debug enables verbose
logging. Default console access is **root without a password**, intentionally for
a local live/rescue system. No remote login service is enabled. Accounts start
with locked passwords; run `passwd root` in a persistent session before choosing
`cherry.login`. Root can switch to the `cherry` account with `su cherry`.

## Persistence

The persistence store is a regular filesystem on a disk or partition,
labelled `cherry-persist` or selected via `cherry.persist=...`. OverlayFS
requires extended attribute support on the store. Use **ext4** with the
default kernel config; xfs, btrfs and f2fs require enabling their drivers
in `cherry.config` (vfat/exfat are not suitable). The `upper/` and `work/`
directories are created automatically on first boot. If the store does
not support extended attributes, Cherry warns and continues with a
volatile overlay instead of failing. Invalid `upper`/`work` directories and
OverlayFS mount failures also fall back to RAM. The boot banner warns when
requested persistence is unavailable; `cherry-status` reports the active mode.
Always use `poweroff` or `reboot` to close the writable filesystem cleanly.
The system waits up to ten seconds for a persistence device to appear.

To prepare a store from another Linux system:

```sh
mkfs.ext4 -L cherry-persist /dev/sdX1
```

## Overlay

Files under `overlay/` are merged into the root filesystem **after** default
configuration is generated. Removed overlay files disappear on the next rootfs
assembly. Runtime init is installed by the image builder after this stage.
Executable hooks have a 30-second timeout; shutdown interrupts a running boot
hook. Common customization paths:

- `overlay/etc/rc.local` — runs at every boot (must be executable)
- `overlay/etc/rc.shutdown` — runs before halt/reboot/poweroff
- `overlay/home/cherry/` — initial home directory of the `cherry` user

## Testing

Run `make test` for compiler/syntax/unit checks, `make smoke` for direct-kernel
boot, persistence, shutdown and TLS tests, and `make smoke-iso` for actual ISO
BIOS/UEFI console tests. See [TESTING.md](TESTING.md) for dependencies, profiles,
log locations and coverage. A GitHub Actions workflow is configured for these
checks on Ubuntu 24.04.

## Experimental packages

`chepm` handles trusted archives containing regular files and directories only:

```sh
chepm -ins example /path/to/example.tar.gz TRUSTED_SHA256
chepm -ls
chepm -del example
```

It rejects overwrite conflicts, unsafe paths, links and special files. A trusted
SHA256 must be supplied separately; the tool does not establish publisher trust.
Set `CHEPM_REPO_URL=https://...` and omit the archive argument to download a
package. Dependencies, upgrades, signatures and install hooks are not supported.
An interrupted operation leaves a lock and a `.pending` list in `/var/lib/chepm`:
inspect and recover the recorded files before removing the stale state. Removing
a package preserves shared directories. Use experimental packages only on a
recoverable live/persistence image.

## Roadmap

- `0.6.x` — live usability, boot/shutdown reliability, verified TLS and automated tests
- `0.8.x` — hardware coverage, firmware, optional zram and namespaces
- `0.9.x` — reproducible toolchain, update/recovery workflow and stabilization
- `1.0.0` — stable release with a documented support matrix

See [RELEASE_NOTES.md](RELEASE_NOTES.md) for the complete 0.6.1 → 0.6.5 release
notes and [CHANGELOG.md](CHANGELOG.md) for a concise change list.

## License

Cherry Linux project code is licensed under the GNU General Public
License, version 2.0 (see [LICENSE](LICENSE)). Bundled components remain
under their own respective licenses.
