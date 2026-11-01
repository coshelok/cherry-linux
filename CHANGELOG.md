# Changelog

## 0.6.5

Changes since **0.6.1** (`53a8d6d91`). See [release notes](RELEASE_NOTES.md)
for details, compatibility changes and validation coverage.

- UEFI framebuffer configuration and Live/Persistent/Rescue/Debug boot menu.
- Safe PID-1 guards, early-boot emergency shell, bounded hooks and race-free
  shutdown signal handling.
- RAM-resident shutdown helper releases OverlayFS and persistence before reboot.
- Persistence device wait, directory validation, mount-failure fallback and
  prominent runtime persistence status.
- Local getty/root autologin, optional password login, vi, cherry-help/status;
  locked shadow entries are rejected normally instead of producing a crypt error.
- OpenSSL-verified BusyBox HTTPS with unverified fallback disabled; explicit
  host OpenSSL/CA bootstrap inputs and the BusyBox IP verification correction.
- Target-first library resolution; existing target libraries/symlinks preserved.
- Separate package/configuration caches, environment fingerprints, normalized
  paths, build locks, staged outputs and locally compiled Limine host utility.
- Persistent DHCP client, network-independent base applets, defaults-before-overlay.
- Experimental chepm requires trusted SHA256, stages archives, rejects conflicts
  and unsupported entries, and publishes manifests only after installation.
- Unit/regression, persistence/shutdown, local TLS and BIOS/UEFI ISO tests; CI.

The userspace still depends on the host libc/toolchain. General hardware support,
Secure Boot, signed package repositories and reproducible builds remain future
work. A release number does not imply these features are supported.
