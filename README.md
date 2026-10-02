# Ubuntu Root Filesystem

Ubuntu 24.04 LTS root filesystem variants for 64-bit ARM systems. The build
starts from an official, version-pinned Canonical `ubuntu-base` tarball and
produces plain compressed tar archives without container image metadata.

## Artifacts

Each default release provides:

- `ubuntu-aarch64-rootfs.tar.gz`
- `ubuntu-aarch64-rootfs.tar.gz.sha256`
- `ubuntu-aarch64-rootfs.tar.zst`
- `ubuntu-aarch64-rootfs.tar.zst.sha256`

The default root filesystem includes Bash, common editors, Git, SSH and network tools,
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

For the default target, package sources stay on the official `ports.ubuntu.com`
(`/etc/apt/sources.list.d/ubuntu.sources`) and are rewritten to `https://`:
clients that forbid cleartext http must still be able to reach the default
mirror. The build verifies the https transport with an `apt-get update` before
packing.

## Releases

GitHub Actions builds and publishes releases from `main` or when manually
triggered. Release tags use the format `v<ubuntu-version>-<UTC-timestamp>`.
There is no scheduled rebuild, and old releases are kept indefinitely.

## `minimal`: embedded application runtime

Every push that triggers the workflow builds `default` and `minimal` in parallel
on two independent runners. To build the minimal payload locally:

```sh
ROOTFS_TARGET=minimal ./build/build.sh
```

This target is for an application that launches its own versioned engine. It is
not a terminal distribution and does not contain a Ren'Py engine yet. It ships:

- ARM64 glibc/loader, C.UTF-8 data, GCC/C++ runtime libraries and zlib.
- The generated CA trust store and timezone data, plus required copyright notices.
- Static BusyBox with only `sh`, `basename`, `dirname`, `readlink`, `uname`, and
  `env` exposed as commands, for `/bin/sh` engine launcher scripts.
- Minimal user/host/DNS configuration and a `/.vish/rootfs.json` descriptor whose
  boot and login commands are `/bin/sh` (no init/getty/service startup).

**No Bash**, APT/dpkg, editors, Git/SSH/network CLI tools, compilers, headers,
manual pages, desktop/display servers, SDL, Python or engine-specific codecs
are included. BusyBox is the standard static Ubuntu binary; its other built-in
applets are not exposed as command symlinks. This is a runtime base, not a
security sandbox or a claim that arbitrary Ren'Py games already work.

The builder uses Ubuntu Base and APT only as an assembly environment, then copies
an explicit runtime-file allowlist into a separate tree. It does not attempt to
purge Ubuntu's Essential packages in place. There is no package database in the
payload: the host replaces this base atomically and installs engine packages
separately. Set the process environment when launching directly; `/etc/profile`
is only a fallback for login shells. The host supplies `/dev`, `/proc`, `/sys`
and controls the game's process lifecycle.

Artifacts:

```text
ubuntu-aarch64-minimal-rootfs.tar.gz
ubuntu-aarch64-minimal-rootfs.tar.gz.sha256
ubuntu-aarch64-minimal-rootfs.tar.zst
ubuntu-aarch64-minimal-rootfs.tar.zst.sha256
ubuntu-aarch64-minimal-rootfs.manifest.json
ubuntu-aarch64-minimal-rootfs.manifest.json.sha256
```

The manifest identifies source package versions and payload files. The build
checks that both compressed artifacts decode to the same tar, then extracts the
actual gzip artifact and verifies symlinks, ARM64 ELF architecture, forbidden
payloads, empty runtime mountpoints, shell execution and a dynamically linked
C++ probe (glibc, C.UTF-8, NSS/localhost, threads, exception unwinding, zlib).
These are Linux packaging/runtime checks, not ViSH/iOS or Ren'Py game tests.

Both targets are published together in one release only after both builds
succeed. Release tags include the Ubuntu version, UTC timestamp, workflow run ID
and attempt. Existing default asset names remain unchanged; the same latest
release also provides the `ubuntu-aarch64-minimal-rootfs.*` assets. The release
job rechecks all five SHA-256 files before publishing. Intermediate Actions
artifacts are retained for one day; published release assets remain available.
Manual workflow dispatch is also supported and builds both targets.

### Local packaging verification — 2026-10-02

The ARM64 `minimal` target was built using the workflow's `build/build.sh`
entrypoint in Docker. Both pre-pack and extracted-artifact executable checks
passed. The manifests matched all 1,195 shipped files/symlinks; gzip, zstd and
manifest SHA-256 checks passed. Sizes for this run were 7,343,049 bytes (gzip)
and 4,161,265 bytes (zstd), with 29,784,813 bytes of regular-file payload.
Package versions are recorded in the accompanying manifest and may change on a
later rebuild. GitHub workflow syntax was checked with actionlint 1.7.12; no
GitHub Actions run, release publication or ViSH/iOS execution is implied by
these local results.
