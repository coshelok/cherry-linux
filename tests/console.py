#!/usr/bin/env python3
"""Exercise recovery shells and the password-login boundary in isolated VMs."""
import argparse
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import types
import time
from smoke import PROJECT, boot


def run_case(name, build, kernel, iso, disk=None):
    command=['qemu-system-x86_64','-accel','tcg','-m','512','-smp','2',
             '-kernel',str(kernel),'-initrd',str(build/'init.cpio.gz'),
             '-append','console=ttyS0 loglevel=4 '+('cherry.login' if name!='emergency' else '')+(' cherry.persist' if disk else ''),
             '-display','none','-serial','stdio','-monitor','none','-no-reboot','-nic','none']
    if name != 'emergency': command += ['-cdrom',str(iso)]
    if disk: command += ['-drive',f'file={disk},format=raw,if=virtio']
    logs=build/'console-logs';logs.mkdir(exist_ok=True)
    proc=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    output=bytearray(); step=0; success=False
    try:
        deadline=time.monotonic()+60
        with selectors.DefaultSelector() as selector:
            selector.register(proc.stdout,selectors.EVENT_READ)
            while time.monotonic()<deadline:
                for key,_ in selector.select(1):
                    data=os.read(key.fileobj.fileno(),65536)
                    if data: output.extend(data)
                    else: selector.unregister(key.fileobj)
                if name == 'emergency':
                    if step==0 and b'[BOOT] Emergency shell' in output and (b'/ # ' in output or b'~ # ' in output):
                        proc.stdin.write(b'exit\n');proc.stdin.flush();step=1
                    if step==1 and output.count(b'[BOOT] Emergency shell')>=2 and output.endswith((b'/ # ', b'~ # ')):
                        proc.stdin.write(b"/bin/busybox printf '__EMERGENCY_%s__\\n' PASS; /bin/busybox poweroff -f\n")
                        proc.stdin.flush();step=2
                    if proc.poll() is not None:
                        output.extend(proc.stdout.read())
                        success=proc.returncode==0 and b'__EMERGENCY_PASS__' in output
                        break
                elif step==0 and b'login: ' in output:
                    proc.stdin.write(b'root\n');proc.stdin.flush();step=1
                elif step==1 and b'Password: ' in output:
                    proc.stdin.write(b'cherry-test-pass\n' if name=='password-login' else b'deliberately-wrong\n');proc.stdin.flush();step=2
                elif name=='locked-login' and step==2 and b'Login incorrect' in output:
                    success=b'cherry:~# ' not in output and b'cherry:/# ' not in output
                    break
                elif name=='password-login' and step==2 and output.endswith(b'# '):
                    proc.stdin.write(b"printf '__LOGIN_%s__\\n' PASS; poweroff\n")
                    proc.stdin.flush();step=3
                if proc.poll() is not None:
                    output.extend(proc.stdout.read())
                    if name=='password-login':
                        success=(proc.returncode==0 and b'__LOGIN_PASS__' in output
                                 and b'[SHUTDOWN] Filesystems closed cleanly' in output)
                    break
        if not success: raise RuntimeError(f'{name}: checks failed; see {logs}')
        print(f'PASS {name}',flush=True)
    finally:
        if proc.poll() is None: proc.kill()
        proc.wait()
        (logs/f'{name}.log').write_bytes(output)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir',type=Path,default=PROJECT/'build')
    parser.add_argument('--kernel',type=Path,default=PROJECT/'kernel/linux-7.0.10/arch/x86/boot/bzImage')
    args=parser.parse_args();build=args.build_dir.resolve()
    iso=build/f"cherrylinux-v{(PROJECT/'VERSION').read_text().strip()}.iso"
    for name in ('emergency','locked-login'):run_case(name,build,args.kernel.resolve(),iso)
    with tempfile.TemporaryDirectory(prefix='cherry-login-') as tmp:
        disk=Path(tmp)/'persist.img'
        with disk.open('wb') as stream: stream.truncate(128*1024*1024)
        subprocess.run(['mkfs.ext4','-q','-F','-L','cherry-persist',str(disk)],check=True)
        guest=types.SimpleNamespace(build_dir=build,kernel=args.kernel.resolve(),iso=iso)
        boot('set-password',guest,build/'console-logs','cherry.persist',
             "echo root:cherry-test-pass | busybox chpasswd -c sha512",disk)
        run_case('password-login',build,args.kernel.resolve(),iso,disk)
        metadata=subprocess.check_output(['dumpe2fs','-h',str(disk)],text=True,stderr=subprocess.DEVNULL)
        assert 'needs_recovery' not in metadata and 'orphan_present' not in metadata

if __name__=='__main__': main()
