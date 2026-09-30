# Changelog

## 0.5.2 — Base System

### Added
- Centralized Cherry Linux versioning through `VERSION`.
- A dedicated userspace initialization stage through `/etc/rc`.
- A system-wide shell environment in `/etc/profile`.
- A minimal login message in `/etc/motd`.
- The `cherryctl` system utility with version, info, status, reboot and poweroff commands.

### Improved
- The interactive shell now starts as a login shell and receives the Cherry system profile.
- `cherryfetch` reports the version from `/etc/os-release` instead of a hardcoded release number.
- The build script uses the centralized version for the generated ISO filename.
- Root filesystem metadata now uses the same version as the build system.
