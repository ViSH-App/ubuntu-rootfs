#!/bin/sh
# Runs inside an aarch64 ubuntu:${UBUNTU_VERSION} container.
# Bootstraps the official Canonical ubuntu-base tarball, installs the package
# set, strips caches/dynamic mountpoints, and emits a clean rootfs tarball.
set -eu

: "${UBUNTU_VERSION:?}"
: "${UBUNTU_BASE_VERSION:?}"
: "${ARCH:?}"
: "${DEB_ARCH:?}"
: "${OUT_NAME:?}"
: "${OUT_NAME_ZSTD:?}"

TARGET=/tmp/rootfs
WORK=/tmp/work
mkdir -p "$TARGET" "$WORK"

export DEBIAN_FRONTEND=noninteractive

apt-get update >/dev/null
apt-get install -y --no-install-recommends ca-certificates curl tar zstd >/dev/null

BASE_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/${UBUNTU_VERSION}/release"
BASE_TARBALL="ubuntu-base-${UBUNTU_BASE_VERSION}-base-${DEB_ARCH}.tar.gz"

echo ">> Fetching $BASE_URL/$BASE_TARBALL"
curl -fsSL -o "$WORK/$BASE_TARBALL" "$BASE_URL/$BASE_TARBALL"

echo ">> Verifying against the official SHA256SUMS"
curl -fsSL -o "$WORK/SHA256SUMS" "$BASE_URL/SHA256SUMS"
(cd "$WORK" && grep " [ *]${BASE_TARBALL}\$" SHA256SUMS > SHA256SUMS.one && sha256sum -c SHA256SUMS.one)

echo ">> Extracting ubuntu-base"
tar --numeric-owner -xzf "$WORK/$BASE_TARBALL" -C "$TARGET"

# The official arm64 base image already points at ports.ubuntu.com; keep that
# host and fail loudly if it ever changes (the app's mirror editor rewrites this
# file and matches the shipped host against its "official mirror" preset).
# The scheme is switched to https further down, once ca-certificates is in.
SOURCES="$TARGET/etc/apt/sources.list.d/ubuntu.sources"
grep -q "ports.ubuntu.com" "$SOURCES"

# Provide DNS to the chroot during install only.
cp /etc/resolv.conf "$TARGET/etc/resolv.conf"

# Minimal device nodes for the chroot: dpkg/apt maintainer scripts redirect to
# /dev/null and gpgv wants /dev/urandom. Requires CAP_MKNOD, which docker grants
# by default. The whole /dev tree is emptied again before packing.
mkdir -p "$TARGET/dev"
mknod -m 0666 "$TARGET/dev/null" c 1 3
mknod -m 0666 "$TARGET/dev/zero" c 1 5
mknod -m 0666 "$TARGET/dev/full" c 1 7
mknod -m 0666 "$TARGET/dev/random" c 1 8
mknod -m 0666 "$TARGET/dev/urandom" c 1 9
mknod -m 0666 "$TARGET/dev/tty" c 5 0

# Never start services from maintainer scripts inside the chroot.
cat > "$TARGET/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 "$TARGET/usr/sbin/policy-rc.d"

PACKAGES=$(grep -vE '^[[:space:]]*(#|$)' /build/packages.txt | tr '\n' ' ')

echo ">> Installing packages:"
echo "   $PACKAGES"
chroot "$TARGET" env DEBIAN_FRONTEND=noninteractive apt-get update
# shellcheck disable=SC2086
chroot "$TARGET" env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y --no-install-recommends $PACKAGES

# Ship the sources over https. iOS blocks cleartext http by default, so the
# app's mirror presets (and its latency probes) are all https; an http:// URI
# here would never match the official-mirror preset and every user would see
# their source listed as "custom". Done only now that ca-certificates is
# installed — the bootstrap above has no TLS roots to verify with. The
# apt-get update that follows proves the https transport actually works.
# The trailing slash upstream ships goes too: the app compares the configured
# URI against its preset, and "…/ubuntu-ports/" is not "…/ubuntu-ports".
sed -i 's#^URIs:[[:space:]]*http://ports\.ubuntu\.com/ubuntu-ports/*[[:space:]]*$#URIs: https://ports.ubuntu.com/ubuntu-ports#' "$SOURCES"
grep -q '^URIs: https://ports\.ubuntu\.com/ubuntu-ports$' "$SOURCES"
! grep -q '^URIs:.*http://' "$SOURCES"
# apt index cost. Under ViSH the CPU is emulated (~10x slower than native on
# branchy integer code), so `apt-get update` is bound by index DECOMPRESSION,
# hashing and the package-cache build — not by the network. Measured on the
# Mac harness (this rootfs, 8 host cores, same mirror, back to back):
#   stock (xz indexes, translations, all 4 components):  58.6 s, 205 MB of lists
#   + Acquire::Languages "none":                         38.5 s, 148 MB
#   + main universe multiverse (no restricted):          ~32 s,  ~122 MB
#   + gz instead of xz indexes:                          22.2 s  (fetch 20 s -> 11 s:
#     gzip inflates 2.6x faster than xz in the guest; costs +5 MB of download)
# On the iPad the CPU share is larger still, so every one of these matters more
# there. Two of them are what the official Docker image does (docker-no-languages,
# docker-gzip-indexes); `restricted` is proprietary drivers/firmware, nothing an
# emulator can use. What is lost: `apt show` long descriptions (Translation-en)
# — the short description in Packages is still shown.
cat > "$TARGET/etc/apt/apt.conf.d/10index-cost" <<'EOF'
// See ubuntu-rootfs build/inside.sh: index decompression + cache build are
// the cost of `apt-get update` on an emulated CPU, so keep the indexes small
// and cheap to inflate. Delete this file to get stock apt behaviour back.
Acquire::Languages "none";
Acquire::CompressionTypes::Order:: "gz";
EOF
sed -i 's/^Components:[[:space:]]*main universe restricted multiverse[[:space:]]*$/Components: main universe multiverse/' "$SOURCES"
grep -q '^Components: main universe multiverse$' "$SOURCES"
! grep -q '^Components:.*restricted' "$SOURCES"

# Start from empty lists so this update fetches the TRIMMED set from scratch
# (the bootstrap update above already pulled the stock set over http, and apt
# would just "Hit" those). The lists are stripped again before packing.
LISTS="$TARGET/var/lib/apt/lists"
rm -rf "${LISTS:?}"/*
echo ">> Verifying the https sources (and the trimmed index set)"
chroot "$TARGET" env DEBIAN_FRONTEND=noninteractive apt-get update
# Prove the trims took: no translation or restricted index was fetched.
# (`! cmd` is exempt from set -e, so test explicitly.)
if ls "$LISTS" | grep -qE '_i18n_Translation-|_restricted_'; then
    echo "apt fetched a translation/restricted index despite the trim:" >&2
    ls "$LISTS" | grep -E '_i18n_Translation-|_restricted_' >&2
    exit 1
fi

# Kernel release reported by `uname -r`. The guest kernel reads
# /etc/kernel-osrelease (kernel/uname.c) and only accepts a plain dotted-numeric
# version, so bake the numeric part of the Ubuntu kernel this release ships
# (e.g. linux-image-6.8.0-85-generic -> 6.8.0). Baked at build time on purpose:
# the runtime probe in RootfsPatch's kernel-osrelease.sh would have to pull tens
# of MB of apt indexes. Best-effort; on any failure uname keeps its default.
KREL=$(chroot "$TARGET" apt-cache show linux-image-generic 2>/dev/null \
    | sed -n 's/^Depends: .*linux-image-\([0-9][0-9.]*\)-[0-9].*/\1/p' | head -n 1)
case "$KREL" in
    [0-9]*[!0-9.]*) KREL="" ;;
esac
if [ -n "$KREL" ]; then
    printf '%s\n' "$KREL" > "$TARGET/etc/kernel-osrelease"
    echo ">> /etc/kernel-osrelease = $KREL"
else
    echo ">> WARNING: could not determine the Ubuntu kernel version; leaving uname at its default" >&2
fi

# pid 1: busybox init + a minimal inittab (getty respawn on tty1..tty6).
# busybox-static installs as /bin/busybox; symlink the applet names init(8) and
# the inittab reference. No openrc/systemd equivalent — there are no services.
test -x "$TARGET/bin/busybox"
ln -sf /bin/busybox "$TARGET/sbin/init"
ln -sf /bin/busybox "$TARGET/sbin/getty"
ln -sf /bin/busybox "$TARGET/sbin/reboot"

cat > "$TARGET/etc/inittab" <<'EOF'
# /etc/inittab

::sysinit:/bin/sh /etc/rc.sysinit

# Set up a couple of getty's
tty1::respawn:/sbin/getty 38400 tty1
tty2::respawn:/sbin/getty 38400 tty2
tty3::respawn:/sbin/getty 38400 tty3
tty4::respawn:/sbin/getty 38400 tty4
tty5::respawn:/sbin/getty 38400 tty5
tty6::respawn:/sbin/getty 38400 tty6

# Put a getty on the serial port
#ttyS0::respawn:/sbin/getty -L 115200 ttyS0 vt100

# Stuff to do for the 3-finger salute
::ctrlaltdel:/sbin/reboot
EOF
chmod 0644 "$TARGET/etc/inittab"

# Everything here is best-effort: the host already mounts the pseudo
# filesystems it cares about, so a failing mount must never block boot.
cat > "$TARGET/etc/rc.sysinit" <<'EOF'
#!/bin/sh
[ -e /proc/self ] || mount -t proc proc /proc 2>/dev/null
[ -e /sys/kernel ] || mount -t sysfs sysfs /sys 2>/dev/null
[ -e /dev/pts/ptmx ] || { mkdir -p /dev/pts && mount -t devpts devpts /dev/pts 2>/dev/null; }
exit 0
EOF
chmod 0755 "$TARGET/etc/rc.sysinit"

# Ship default DNS so consumers have working resolution out of the box.
cat > "$TARGET/etc/resolv.conf" <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

# Debian convention: the hostname must resolve or sudo warns on every call.
# The app rewrites both lines when the user changes the hostname.
cat > "$TARGET/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	localhost
::1	localhost ip6-localhost ip6-loopback
EOF

# Blank every MOTD source Ubuntu ships (static file, dynamic generators, legal).
rm -f "$TARGET/etc/motd" "$TARGET/etc/legal"
: > "$TARGET/etc/motd"
rm -rf "${TARGET:?}/etc/update-motd.d"
mkdir -p "$TARGET/etc/update-motd.d"

# Default environment. Every value here is a guarded fallback — whatever the
# spawner passes in wins. Installed twice: /etc/profile.d for login shells and
# appended to /etc/bash.bashrc for interactive non-login bash.
# TERM/HOME are NOT set here: the app injects them via execve envp and login(1)
# preserves TERM / sets HOME from /etc/passwd, so a rootfs fallback would only
# duplicate them. PATH stays because login resets it (see below).
mkdir -p "$TARGET/etc/profile.d"
cat > "$WORK/default-env.sh" <<'EOF'
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}"
export EDITOR="${EDITOR:-nano}"
export VISUAL="${VISUAL:-$EDITOR}"
# login(1) strips the inherited PATH and /etc/profile resets it to the standard
# six; re-prepend user-local binary directories afterward.
# Unconditional: installers (pip, uv, bun) create these dirs mid-session, and
# a not-yet-existing PATH entry is harmless.
for _d in "$HOME/.bun/bin" "$HOME/.local/bin"; do
  case ":$PATH:" in
    *":$_d:"*) ;;
    *) PATH="$_d:$PATH" ;;
  esac
done
unset _d
export PATH
EOF
cp "$WORK/default-env.sh" "$TARGET/etc/profile.d/10-default-env.sh"
chmod 0644 "$TARGET/etc/profile.d/10-default-env.sh"

# Interactive bash defaults: history behavior, a couple of aliases, and the
# colored prompt (red for root, green for everyone else). Appended to
# /etc/bash.bashrc so a plain `bash` gets the same environment a login shell
# builds from /etc/profile.d.
{
  echo ''
  echo '# --- ViSH defaults ---'
  cat "$WORK/default-env.sh"
  cat <<'EOF'
HISTCONTROL=ignoreboth
HISTSIZE=1000
HISTFILESIZE=2000
shopt -s histappend
# Persist history incrementally instead of waiting for a normal shell exit.
PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND$'\n'}history -a"

alias ll='ls -alh'
alias la='ls -A'

if [ -n "$PS1" ]; then
  if [ "$(id -u)" = 0 ]; then
    PS1='\[\033[01;31m\]\h\[\033[01;34m\] \w \$\[\033[00m\] '
  else
    PS1='\[\033[01;32m\]\u@\h\[\033[01;34m\] \w \$\[\033[00m\] '
  fi
fi
EOF
} >> "$TARGET/etc/bash.bashrc"

# Root's login shell must be bash. The grep makes the build fail loudly if
# upstream ever changes the passwd layout.
sed -i 's#^\(root:.*\):/bin/sh$#\1:/bin/bash#' "$TARGET/etc/passwd"
grep -q '^root:.*:/bin/bash$' "$TARGET/etc/passwd"

# Distro descriptor consumed by the app (root model / GuestDistro detection).
mkdir -p "$TARGET/.vish"
cat > "$TARGET/.vish/rootfs.json" <<EOF
{ "id": "ubuntu", "version": "${UBUNTU_VERSION}", "boot": ["/sbin/init"], "login": ["/bin/login", "-f", "root"] }
EOF
chmod 0644 "$TARGET/.vish/rootfs.json"

# Defensive cleanup — keep the archive small and reproducible.
chroot "$TARGET" apt-get clean
rm -rf \
  "$TARGET/usr/sbin/policy-rc.d" \
  "$TARGET/var/lib/apt/lists/"* \
  "$TARGET/var/cache/apt/"* \
  "$TARGET/var/log/"* \
  "$TARGET/tmp/"* \
  "$TARGET/root/.bash_history" \
  "$TARGET/root/.wget-hsts" 2>/dev/null || true
mkdir -p "$TARGET/var/lib/apt/lists/partial" "$TARGET/var/cache/apt/archives/partial"

# Empty the dynamic mountpoints but keep the directories.
for d in proc sys dev; do
  rm -rf "${TARGET:?}/$d"
  mkdir -p "$TARGET/$d"
done

echo ">> Packing $OUT_NAME and $OUT_NAME_ZSTD"
cd "$TARGET"
TAR_TMP="$WORK/rootfs.tar"
tar --numeric-owner --owner=0 --group=0 -cf "$TAR_TMP" .
gzip -9 -c "$TAR_TMP" > "/out/$OUT_NAME"
zstd -19 --long -T0 -q -o "/out/$OUT_NAME_ZSTD" "$TAR_TMP"
rm -f "$TAR_TMP"

ls -lah "/out/$OUT_NAME" "/out/$OUT_NAME_ZSTD"
