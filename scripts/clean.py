#!/usr/bin/env python3
"""Remove only a recognized Cherry build directory."""
from pathlib import Path
import shutil
import sys
root = Path(sys.argv[1]).resolve()
project = Path(__file__).resolve().parents[1]
if not root.exists():
    sys.exit(0)
if root in (Path('/'), Path.home(), project) or project.is_relative_to(root):
    sys.exit(f'Refusing to remove {root}')
if not (root / '.build.lock').exists() and not (root / 'rootfs/.cherry-build-inputs').exists():
    sys.exit(f'Not a recognized Cherry build directory: {root}')
# Do not remove a tree in active use by either builder.
import fcntl
locks = []
for name in ('.build.lock', '.rootfs.lock'):
    stream = (root / name).open('a')
    try:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit('A build is running')
    locks.append(stream)
shutil.rmtree(root)
