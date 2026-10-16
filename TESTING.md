# Manual test checklist

Cherry Linux has no CI yet. Run this checklist by hand on a release
candidate before tagging a release. Use a VM unless a test says otherwise.

## Build

- [ ] `make` completes and writes `build/cherrylinux-v<VERSION>.iso`
- [ ] The ISO name matches the contents of `VERSION`
- [ ] Re-running `make` reuses the cached sources in `build/sources`
- [ ] Corrupt a cached archive (`truncate -s 1024 build/sources/bash-*.tar.gz`)
      and re-run the build: it must abort with a checksum error; after
      removing the bad file the archive is re-downloaded and verified
- [ ] Fresh-clone check (kernel auto-download): move `kernel/linux-*`
      aside, run `./build.sh`, confirm the tarball is downloaded, verified
      and extracted; then move it back

## Boot (QEMU)

- [ ] `make run` boots to the Cherry Linux banner and root shell
- [ ] `uname -r` reports the kernel version from `build.sh`
- [ ] `cherryfetch` displays OS, kernel, uptime and RAM
- [ ] `ip addr` shows `eth0`/`enp0s*` with a DHCP lease (QEMU user net)
- [ ] `ping -c1 10.0.2.2` succeeds
- [ ] `cat /etc/resolv.conf` contains a nameserver from DHCP
- [ ] Exiting the shell (`exit`, Ctrl+D) restarts it after a second
- [ ] `cherry.debug` on the cmdline produces `[BOOT][DEBUG]`/`[INIT][DEBUG]` logs

## Shutdown

- [ ] `poweroff` runs `/etc/rc.shutdown` (when present), syncs and powers off
- [ ] `reboot` reboots the machine
- [ ] `halt` halts the machine

## Persistence

Kernel cmdline changes currently require editing the `limine.conf` heredoc
in `build.sh` (a boot menu with these options lands in 0.8.0), then
rebuilding the ISO.

- [ ] Prepare a store: `qemu-img create -f raw persist.img 256M &&
      mkfs.ext4 -L cherry-persist persist.img`
- [ ] Boot with `cherry.persist` in the cmdline and the disk attached
      (`QEMU_EXTRA="-drive file=persist.img,format=raw,if=virtio"`)
- [ ] `[BOOT][INFO] Persistence enabled` appears in the boot log
- [ ] `touch /root/persist-test`, reboot; the file is still there
- [ ] Boot without `cherry.persist`; `persist-test` is absent after reboot

## Rescue mode

- [ ] Boot with `single` in the cmdline: boot completes, network setup and
      `rc.local` are skipped
- [ ] Boot with an unplugged boot medium: after the media scan the boot
      init does not hang or corrupt anything (current behaviour is a
      controlled power-off; improved in 0.7.0)

## USB

- [ ] Write the ISO to a USB stick (`dd if=... of=/dev/sdX bs=4M`)
- [ ] The stick boots on a UEFI machine
- [ ] The stick boots on a BIOS machine
- [ ] Booting the stick on real hardware: check display, keyboard, NIC
