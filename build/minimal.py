#!/usr/bin/env python3
"""Assemble an allowlisted runtime, not a general-purpose Ubuntu installation."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

source, target, manifest = map(Path, sys.argv[1:])
if target.exists():
    raise SystemExit('refusing to overwrite an existing staging tree')
target.mkdir(parents=True)
# Match Ubuntu's merged-/usr layout without copying any base utilities.
for name, dest in [('bin', 'usr/bin'), ('sbin', 'usr/sbin'), ('lib', 'usr/lib')]:
    (target / dest).mkdir(parents=True, exist_ok=True)
    (target / name).symlink_to(dest)

packages = ['libc6', 'libc-bin', 'libgcc-s1', 'libstdc++6', 'zlib1g', 'busybox-static',
            'ca-certificates', 'tzdata']
records = []

def copy_file(path):
    relative = path.lstrip('/')
    src, dst = source / relative, target / relative
    if src.is_dir() and not src.is_symlink():
        return
    if not src.exists() and not src.is_symlink():
        raise RuntimeError('missing package file: ' + path)
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() or dst.is_symlink():
        return
    if src.is_symlink():
        dst.symlink_to(os.readlink(src))
    else:
        shutil.copy2(src, dst)

for package in packages:
    metadata = subprocess.check_output([
        'chroot', str(source), 'dpkg-query', '-W',
        '-f=${Package}\t${Version}\t${Architecture}\t${source:Package}\n', package
    ], text=True).strip().split('\t')
    records.append(dict(zip(['package', 'version', 'architecture', 'source'], metadata)))
    paths = subprocess.check_output(['chroot', str(source), 'dpkg-query', '-L', package], text=True).splitlines()
    for path in paths:
        allowed = path.startswith(('/usr/lib/', '/lib/', '/lib64/'))
        allowed |= package == 'tzdata' and path.startswith('/usr/share/zoneinfo/')
        allowed |= package == 'busybox-static' and path in ('/bin/busybox', '/usr/bin/busybox')
        if allowed:
            copy_file(path)
    # Keep redistribution notices; materialize package doc-directory symlinks.
    copyright_file = source / 'usr/share/doc' / package / 'copyright'
    if not copyright_file.exists():
        raise RuntimeError('missing copyright for ' + package)
    dest = target / 'usr/share/doc' / package / 'copyright'
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(copyright_file.read_bytes())

# CA generation tools (openssl/update-ca-certificates) do not ship. Keep the
# generated trust store and its referenced certificates so file AND directory
# lookup work for independently packaged Python/OpenSSL versions.
for path in ['etc/ssl/certs', 'usr/share/ca-certificates']:
    shutil.copytree(source / path, target / path, symlinks=True)
for path in ['etc/os-release', 'usr/lib/os-release']:
    if (source / path).exists() or (source / path).is_symlink():
        copy_file('/' + path)

for path in ['dev', 'proc', 'sys', 'tmp', 'run', 'root', 'home', 'var/tmp', 'etc', '.vish']:
    (target / path).mkdir(parents=True, exist_ok=True)
for path in ['tmp', 'var/tmp']:
    (target / path).chmod(0o1777)
(target / 'root').chmod(0o700)

# Only the launcher-facing applets are exposed; no login, getty or services.
for name in ['sh', 'basename', 'dirname', 'readlink', 'uname', 'env']:
    (target / 'usr/bin' / name).symlink_to('busybox')
files = {
    'etc/passwd': 'root:x:0:0:root:/root:/bin/sh\nnobody:x:65534:65534:nobody:/nonexistent:/bin/sh\n',
    'etc/group': 'root:x:0:\nnogroup:x:65534:\n',
    'etc/nsswitch.conf': 'passwd: files\ngroup: files\nshadow: files\nhosts: files dns\nnetworks: files\n',
    'etc/hosts': '127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n',
    'etc/resolv.conf': 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n',
    'etc/timezone': 'Etc/UTC\n',
    'etc/profile': 'export PATH=/usr/bin:/bin\nexport LANG="${LANG:-C.UTF-8}"\nexport SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"\n',
}
for path, content in files.items():
    (target / path).write_text(content)
(target / 'etc/localtime').symlink_to('../usr/share/zoneinfo/Etc/UTC')
# OpenSSL's conventional default certificate-file path, without libssl/tools.
(target / 'usr/lib/ssl').mkdir(exist_ok=True)
(target / 'usr/lib/ssl/cert.pem').symlink_to('/etc/ssl/certs/ca-certificates.crt')
# No apt/dpkg database: this rootfs is replaced atomically by its embedder.
# Versioned engine packages own Python, SDL, codecs and graphics backends.
descriptor = {'id': 'ubuntu', 'version': os.environ['UBUNTU_VERSION'],
              'variant': 'minimal', 'boot': ['/bin/sh'], 'login': ['/bin/sh']}
(target / '.vish/rootfs.json').write_text(json.dumps(descriptor, indent=2) + '\n')
(target / '.vish/packages.json').write_text(json.dumps(records, indent=2) + '\n')
record = {'target': 'minimal', 'architecture': os.environ['ARCH'],
          'ubuntu_base_version': os.environ['UBUNTU_BASE_VERSION'],
          'packages': records, 'package_manager': False,
          'engine_included': False, 'shell': 'busybox sh',
          'files': sorted(str(p.relative_to(target)) for p in target.rglob('*') if p.is_symlink() or p.is_file())}
manifest.write_text(json.dumps(record, indent=2) + '\n')
print('Assembled minimal runtime from', len(packages), 'allowlisted packages')
