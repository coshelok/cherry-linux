# Cherry Linux overlay

Files placed in this directory are merged into the root filesystem
(root `/`) at build time by `rootfs.sh`, on top of the packages installed
from source and the generated defaults. The conventional subdirectories are already present.

Examples:

- `overlay/etc/rc.local` — runs at every boot (must be executable).
- `overlay/etc/rc.shutdown` — runs before halt/reboot/poweroff.
- `overlay/usr/local/bin/anything` — picked up via `PATH` at runtime.
- `overlay/home/cherry/*` — initial contents of the `cherry` user's home.

Overlays are applied on every rootfs build, so they are also an easy way
to keep extra configuration scripts under version control.