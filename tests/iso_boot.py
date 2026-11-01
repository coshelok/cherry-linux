#!/usr/bin/env python3
"""Boot the actual ISO via BIOS/UEFI and type into its graphical console."""
import argparse
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import subprocess
import tempfile
import time

PROJECT = Path(__file__).resolve().parents[1]


def firmware():
    for directory in ('/usr/share/edk2/x64', '/usr/share/OVMF', '/usr/share/edk2/ovmf'):
        for code, variables in (('OVMF_CODE.4m.fd','OVMF_VARS.4m.fd'),
                                ('OVMF_CODE_4M.fd','OVMF_VARS_4M.fd'),
                                ('OVMF_CODE.fd','OVMF_VARS.fd')):
            code, variables = Path(directory)/code, Path(directory)/variables
            if code.is_file() and variables.is_file(): return code, variables
    raise RuntimeError('OVMF firmware not found; install ovmf/edk2-ovmf')


def boot_iso(mode, iso, logs):
    print(f'Booting ISO ({mode})',flush=True)
    serial = logs/f'{mode}.serial'
    with tempfile.TemporaryDirectory(prefix='cherry-iso-') as tmp:
        command = ['qemu-system-x86_64','-accel','tcg','-m','512','-smp','2',
                   '-cdrom',str(iso),'-boot','d','-display','none','-serial',f'file:{serial}',
                   '-qmp','stdio','-no-reboot','-netdev','user,id=net0',
                   '-device','virtio-net-pci,netdev=net0']
        if mode == 'uefi':
            code, variables = firmware()
            varcopy = Path(tmp)/'vars.fd'
            shutil.copyfile(variables,varcopy)
            command += ['-drive',f'if=pflash,format=raw,readonly=on,file={code}',
                        '-drive',f'if=pflash,format=raw,file={varcopy}']
        with (logs/f'{mode}.log').open('w') as log:
            proc=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log)
            buffer=bytearray()
            def response():
                deadline=time.monotonic()+10
                with selectors.DefaultSelector() as sel:
                    sel.register(proc.stdout,selectors.EVENT_READ)
                    while time.monotonic()<deadline:
                        if b'\n' in buffer:
                            line,_,rest=buffer.partition(b'\n'); buffer[:]=rest
                            item=json.loads(line)
                            if 'event' not in item: return item
                            continue
                        if sel.select(1):
                            data=os.read(proc.stdout.fileno(),65536)
                            if not data: raise RuntimeError('QMP closed unexpectedly')
                            buffer.extend(data)
                raise RuntimeError('QMP timeout')
            def call(name,arguments=None):
                obj={'execute':name}
                if arguments is not None: obj['arguments']=arguments
                proc.stdin.write((json.dumps(obj)+'\n').encode());proc.stdin.flush()
                result=response()
                if 'error' in result: raise RuntimeError(result['error'])
                return result
            try:
                response();call('qmp_capabilities')
                time.sleep(25)
                call('screendump',{'filename':str(logs/f'{mode}.png'),'format':'png'})
                mapping={' ':'spc','/':'slash','>':'shift-dot','S':'shift-s','-':'minus','\n':'ret'}
                for char in 'cat /proc/fb > /dev/ttyS0\necho cherry-iso-pass > /dev/ttyS0\npoweroff\n':
                    call('human-monitor-command',{'command-line':'sendkey '+mapping.get(char,char)+' 10'})
                    time.sleep(0.03)
                proc.wait(timeout=30)
                text=re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', serial.read_text(errors='replace'))
                if proc.returncode != 0 or 'cherry-iso-pass' not in text or not re.search(r'^0 .+',text,re.M):
                    raise RuntimeError(f'{mode}: no usable framebuffer/console or shutdown failed; see {logs}')
                print(f'PASS ISO {mode}',flush=True)
            finally:
                if proc.poll() is None:
                    proc.kill();proc.wait()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir',type=Path,default=PROJECT/'build')
    parser.add_argument('--mode',choices=('bios','uefi','both'),default='both')
    args=parser.parse_args()
    build=args.build_dir.resolve()
    logs=build/'iso-logs';logs.mkdir(exist_ok=True)
    iso=build/f"cherrylinux-v{(PROJECT/'VERSION').read_text().strip()}.iso"
    for mode in (('bios','uefi') if args.mode=='both' else (args.mode,)):
        boot_iso(mode,iso,logs)

if __name__=='__main__': main()
