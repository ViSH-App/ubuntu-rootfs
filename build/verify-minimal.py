#!/usr/bin/env python3
"""Verify the actual runtime tree; no apt/dpkg or host tools inside it."""
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys

root, probe = map(Path, sys.argv[1:])

def resolve_guest(path):
    parts = list(PurePosixPath(path).parts)
    resolved = []
    hops = 0
    while parts:
        part = parts.pop(0)
        if part in ('/', '.', ''):
            continue
        if part == '..':
            if resolved:
                resolved.pop()
            continue
        candidate = root.joinpath(*resolved, part)
        if candidate.is_symlink():
            hops += 1
            if hops > 40:
                raise RuntimeError('symlink loop: ' + str(path))
            link = PurePosixPath(os.readlink(candidate))
            if link.is_absolute():
                resolved = []
            parts = list(link.parts) + parts
        else:
            resolved.append(part)
    return root.joinpath(*resolved)

for p in root.rglob('*'):
    if p.name.lower().startswith(('python', 'libpython', 'renpy', 'librenpy', 'libsdl')):
        raise RuntimeError('engine component belongs in the App-imported package: ' + str(p.relative_to(root)))
    if p.is_symlink() and not resolve_guest('/' + str(p.relative_to(root))).exists():
        raise RuntimeError('dangling guest symlink: ' + str(p.relative_to(root)))
    if p.is_file() and not p.is_symlink():
        with p.open('rb') as f:
            header = f.read(20)
        if header[:4] == b'\x7fELF' and (header[4:6] != b'\x02\x01' or int.from_bytes(header[18:20], 'little') != 183):
            raise RuntimeError('non-aarch64 ELF: ' + str(p))
for name in ['bash', 'apt', 'apt-get', 'dpkg', 'git', 'ssh', 'curl', 'wget', 'nano', 'vi', 'vim', 'gcc', 'g++', 'python3', 'openssl', 'systemctl', 'login', 'getty']:
    for directory in ['usr/bin', 'usr/sbin', 'bin', 'sbin']:
        if (root / directory / name).exists():
            raise RuntimeError('unexpected tool: ' + name)
for path in ['etc/apt', 'var/lib/dpkg', 'usr/include', 'usr/share/man', 'usr/share/info']:
    if (root / path).exists():
        raise RuntimeError('unexpected payload: ' + path)
for path in ['dev', 'proc', 'sys', 'tmp', 'run']:
    if list((root / path).iterdir()):
        raise RuntimeError('nonempty runtime mountpoint: ' + path)
meta = json.loads((root / '.vish/rootfs.json').read_text())
if meta['variant'] != 'minimal' or meta['boot'] != ['/bin/sh']:
    raise RuntimeError('wrong runtime descriptor')
subprocess.run(['chroot', str(root), '/bin/sh', '-c',
                'test "$(basename /a/b)" = b && test "$(dirname /a/b)" = /a && test "$(uname -m)" = aarch64'], check=True)
copy = root / 'tmp/runtime-probe'
shutil.copy2(probe, copy)
try:
    subprocess.run(['chroot', str(root), '/tmp/runtime-probe'], check=True)
finally:
    copy.unlink()
print('PASS: minimal allowlist, symlinks, ARM64 ELF, shell and executable smoke')
