# Cherry Linux

Cherry Linux is a minimal x86_64 Linux distribution in active development.

The 0.5.x series focuses on the low-level foundation of the distribution: the kernel, initramfs, root filesystem, boot process and the tooling used to build them.

## Build

On an x86_64 Linux build host:

```sh
./build.sh
```

The generated ISO is written to `build/cherrylinux-v<VERSION>.iso`.

## Current architecture

```
Limine
  -> Linux kernel
  -> Cherry init
  -> ISO9660 boot media
  -> SquashFS root
  -> OverlayFS writable layer
  -> /etc/rc
  -> interactive login shell
```

## Cherry 0.5.2

The 0.5.2 release introduces the first explicit userspace initialization stage and a small system control utility.

Useful commands inside the system:

```sh
cherryctl version
cherryctl info
cherryctl status
```

For privileged shutdown operations:

```sh
cherryctl reboot
cherryctl poweroff
```

This project is currently an x86_64-focused minimal distribution and does not aim to provide a desktop environment in the 0.5.x-0.9.x development series.
