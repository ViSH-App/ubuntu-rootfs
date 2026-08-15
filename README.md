# Ubuntu Root Filesystem

A minimal Ubuntu 24.04 LTS root filesystem for 64-bit ARM systems. The build
starts from an official, version-pinned Canonical `ubuntu-base` tarball and
produces plain compressed tar archives without container image metadata.

## Artifacts

Each release provides:

- `ubuntu-aarch64-rootfs.tar.gz`
- `ubuntu-aarch64-rootfs.tar.gz.sha256`
- `ubuntu-aarch64-rootfs.tar.zst`
- `ubuntu-aarch64-rootfs.tar.zst.sha256`

The root filesystem includes Bash, common editors, Git, SSH and network tools,
TLS certificates, timezone data, and other small command-line utilities listed
in [`build/packages.txt`](build/packages.txt). BusyBox (static) is pid 1 via a
minimal `/etc/inittab`; there is no systemd and no service is enabled.
Localization data beyond `C.UTF-8` is not installed.

## Download

Use the stable latest-release URLs:

```text
https://github.com/ViSH-App/ubuntu-rootfs/releases/latest/download/ubuntu-aarch64-rootfs.tar.gz
https://github.com/ViSH-App/ubuntu-rootfs/releases/latest/download/ubuntu-aarch64-rootfs.tar.gz.sha256
https://github.com/ViSH-App/ubuntu-rootfs/releases/latest/download/ubuntu-aarch64-rootfs.tar.zst
https://github.com/ViSH-App/ubuntu-rootfs/releases/latest/download/ubuntu-aarch64-rootfs.tar.zst.sha256
```

Verify an artifact before use:

```sh
shasum -a 256 -c ubuntu-aarch64-rootfs.tar.gz.sha256
```

Consumers that need a reproducible payload should pin a specific release tag
instead of `latest`; releases are never deleted.

## Build

Docker is required. Building on a non-ARM64 host also requires ARM64 emulation
through QEMU/binfmt.

```sh
./build/build.sh
```

To select a specific `ubuntu-base` point release:

```sh
UBUNTU_BASE_VERSION=24.04.4 ./build/build.sh
```

The base tarball is downloaded from
`https://cdimage.ubuntu.com/ubuntu-base/releases/$UBUNTU_VERSION/release/` and
checked against the official `SHA256SUMS` before it is unpacked. Artifacts are
written to `dist/`. Only the `aarch64` target is currently supported.

## Contents beyond the package list

- `/sbin/init`, `/sbin/getty`, `/sbin/reboot` → `/bin/busybox` (static), driven
  by a minimal `/etc/inittab` (`sysinit` + getty respawn on `tty1`–`tty6`).
  Both `/sbin/init` as pid 1 and `/bin/login -f root` work as entry points.
- `/etc/profile.d/10-default-env.sh` and a matching block appended to
  `/etc/bash.bashrc`: `SSL_CERT_FILE`, `EDITOR`/`VISUAL`, `~/.local/bin` and
  `~/.bun/bin` on `PATH`, history defaults, `ll`/`la`, colored prompt.
- `/etc/kernel-osrelease`: the dotted-numeric version of the kernel this Ubuntu
  release ships, so `uname -r` matches the distribution.
- `/.vish/rootfs.json`: distribution descriptor (`id`, `version`, default boot
  and login commands).
- Empty MOTD (static, dynamic and legal), public-resolver `/etc/resolv.conf`,
  `/etc/hosts` with `127.0.0.1` and `127.0.1.1` entries, root's login shell set
  to Bash, apt lists and caches removed.

Package sources stay on `ports.ubuntu.com`
(`/etc/apt/sources.list.d/ubuntu.sources`).

## Releases

GitHub Actions builds and publishes releases from `main` or when manually
triggered. Release tags use the format `v<ubuntu-version>-<UTC-timestamp>`.
There is no scheduled rebuild, and old releases are kept indefinitely.
