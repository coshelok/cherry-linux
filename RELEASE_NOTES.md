# Cherry Linux 0.6.5

Changes since **0.6.1**: live usability, boot/shutdown fixes and faster rebuilds.

## Known issues

- **Persistence on the boot USB drive is broken with a raw-written ISO.**
  Even a correctly prepared partition can fail with `Device or resource busy`.
  Cherry falls back to RAM: **changes are lost on shutdown**. Persistence on a
  separate device passed QEMU tests; real-hardware persistence is unverified.
  It requires a prepared ext4 filesystem labelled `cherry-persist`, or an
  explicitly selected store. The menu does not create partitions. Check
  `cherry-status` before relying on saved changes.
- **GPU support is incomplete.** Missing Intel firmware
  (`i915/adlp_guc_70.bin`) and `nvidiafb: unknown NV_ARCH` were reported on real
  hardware. A usable console does not imply working GPU acceleration.

## What's new

- **Boot:** UEFI framebuffer support; Live / Persistent / Rescue / Debug menu;
  emergency shells on initialization failure; safe refusal to run init outside
  PID 1.
- **Console:** getty, optional password login with `cherry.login`, `vi`,
  `cherry-help` and `cherry-status`. Fix locked-password handling, home-directory
  ownership and `/etc/hostname` support.
- **Persistence and shutdown:** retry storage discovery, validate overlay
  directories and warn on RAM fallback. Fix shutdown signal handling and close
  OverlayFS and backing storage through a RAM-resident shutdown helper.
- **Networking:** verify HTTPS certificates and hostnames through OpenSSL;
  disable unverified TLS fallback. Keep DHCP running for lease renewal.
- **Builds:** cache packages separately from configuration; version and overlay
  edits no longer recompile packages. Preserve target libraries, stage outputs,
  lock builds, compile the Limine host tool locally and generate ISO SHA256 files.
- **Profiles:** retain essential console/device/power tools without networking;
  remove translations from minimal images.
- **Packages:** validate and stage `chepm` archives, reject unsafe paths, links
  and overwrite conflicts, and roll back copied files on copy failure.

## Compatibility

- Local root autologin remains the default. For `cherry.login`, first set a
  password in a working persistent session and enable persistence on subsequent
  boots. No remote login service is enabled.
- Hooks now have a **30-second timeout**. Overlay configuration takes precedence
  over generated defaults.
- `chepm` now requires a trusted checksum: `chepm -ins NAME ARCHIVE SHA256`.
  Repository downloads require HTTPS. It remains experimental, without upgrades,
  dependency resolution, signatures or automatic recovery after power loss.
- Network-enabled builds require host OpenSSL and a CA bundle. Builds still
  depend on host libraries and are not fully reproducible. Secure Boot is unsupported.

## Validation

16 unit/regression tests passed. QEMU checks cover BIOS/UEFI boot for both image
profiles, separate-device persistence, clean shutdown, login and TLS. The
same-USB persistence failure was also reproduced. Added `make test`, `make smoke`,
`make smoke-iso` and a GitHub Actions workflow; remote CI has not yet been run.

See [CHANGELOG.md](CHANGELOG.md) and [TESTING.md](TESTING.md) for details.
