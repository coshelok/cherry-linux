#!/usr/bin/env python3
"""Verify TLS inside QEMU, without binding sockets on the build host."""
import argparse
import base64
from pathlib import Path
import subprocess
import tempfile
import types
from smoke import boot, PROJECT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=PROJECT / 'build')
    parser.add_argument('--kernel', type=Path, default=PROJECT / 'kernel/linux-7.0.10/arch/x86/boot/bzImage')
    opts = parser.parse_args()
    build = opts.build_dir.resolve()
    args = types.SimpleNamespace(build_dir=build, kernel=opts.kernel.resolve(),
        iso=build / f"cherrylinux-v{(PROJECT / 'VERSION').read_text().strip()}.iso")
    logs = build / 'tls-logs'
    logs.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='cherry-tls-') as tmp:
        root = Path(tmp)
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
            '-keyout', str(root/'key.pem'), '-out', str(root/'cert.pem'), '-days', '1',
            '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost'],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        script = '#!/bin/sh\nset -eu\n'
        for name in ('key.pem', 'cert.pem'):
            encoded = base64.b64encode((root/name).read_bytes()).decode()
            script += f"printf '%s' '{encoded}' | base64 -d > /tmp/{name}\n"
        script += '''
openssl s_server -accept 8443 -cert /tmp/cert.pem -key /tmp/key.pem -www > /tmp/tls-server.log 2>&1 &
server=$!
trap 'kill "$server" 2>/dev/null || true; wait "$server" 2>/dev/null || true' EXIT
sleep 1
# Unknown issuer must fail with the shipped trust store.
if wget -T 5 -O /tmp/untrusted https://localhost:8443/; then exit 1; fi
# Explicitly trusted certificate and matching hostname must work.
SSL_CERT_FILE=/tmp/cert.pem wget -T 5 -O /tmp/trusted https://localhost:8443/
test -s /tmp/trusted
# Also exercise the image's default CA lookup, without an environment override.
cp /etc/ssl/certs/ca-certificates.crt /tmp/original-ca-bundle
cat /tmp/cert.pem >> /etc/ssl/certs/ca-certificates.crt
wget -T 5 -O /tmp/default-trust https://localhost:8443/
test -s /tmp/default-trust
mv /tmp/original-ca-bundle /etc/ssl/certs/ca-certificates.crt
# A trusted issuer is insufficient if the hostname does not match.
if SSL_CERT_FILE=/tmp/cert.pem wget -T 5 -O /tmp/mismatch https://127.0.0.1:8443/; then exit 1; fi
# Missing OpenSSL must fail closed, not invoke BusyBox internal TLS.
mv /usr/bin/openssl /usr/bin/openssl.disabled
if wget -T 5 -O /tmp/fallback https://localhost:8443/; then
    mv /usr/bin/openssl.disabled /usr/bin/openssl; exit 1
fi
mv /usr/bin/openssl.disabled /usr/bin/openssl
'''
        (root/'test.sh').write_text(script)
        disk = root/'tls.img'
        with disk.open('wb') as stream: stream.truncate(128*1024*1024)
        subprocess.run(['mkfs.ext4','-q','-F',str(disk)],check=True)
        subprocess.run(['debugfs','-w','-R',f'write {root / "test.sh"} /test.sh',str(disk)],check=True,capture_output=True)
        boot('tls-verification',args,logs,'',
             'mkdir -p /mnt/tls && mount /dev/vda /mnt/tls && sh /mnt/tls/test.sh',disk)

if __name__ == '__main__': main()
