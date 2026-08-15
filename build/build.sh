#!/usr/bin/env bash
# Build a portable Ubuntu rootfs tarball.
# Same entrypoint is used locally and in CI.
#
# Required: docker (with QEMU/binfmt for the target arch).
# Output:   dist/<OUT_NAME> and dist/<OUT_NAME>.sha256
set -euo pipefail

ARCH="${ARCH:-aarch64}"
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"
# Point release of the ubuntu-base tarball published under
# https://cdimage.ubuntu.com/ubuntu-base/releases/$UBUNTU_VERSION/release/
UBUNTU_BASE_VERSION="${UBUNTU_BASE_VERSION:-24.04.4}"

case "$ARCH" in
  aarch64) DOCKER_PLATFORM="linux/arm64"; DEB_ARCH="arm64" ;;
  *) echo "unsupported ARCH: $ARCH (only aarch64 is wired up today)" >&2; exit 1 ;;
esac

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
OUT_NAME="ubuntu-${ARCH}-rootfs.tar.gz"
OUT_NAME_ZSTD="ubuntu-${ARCH}-rootfs.tar.zst"

mkdir -p "$DIST_DIR"
rm -f \
  "$DIST_DIR/$OUT_NAME" "$DIST_DIR/$OUT_NAME.sha256" \
  "$DIST_DIR/$OUT_NAME_ZSTD" "$DIST_DIR/$OUT_NAME_ZSTD.sha256"

echo ">> Building $OUT_NAME, $OUT_NAME_ZSTD (ubuntu-base $UBUNTU_BASE_VERSION, $ARCH on $DOCKER_PLATFORM)"

docker run --rm --platform "$DOCKER_PLATFORM" \
  -v "$REPO_ROOT/build:/build:ro" \
  -v "$DIST_DIR:/out" \
  -e UBUNTU_VERSION="$UBUNTU_VERSION" \
  -e UBUNTU_BASE_VERSION="$UBUNTU_BASE_VERSION" \
  -e ARCH="$ARCH" \
  -e DEB_ARCH="$DEB_ARCH" \
  -e OUT_NAME="$OUT_NAME" \
  -e OUT_NAME_ZSTD="$OUT_NAME_ZSTD" \
  "ubuntu:${UBUNTU_VERSION}" \
  /build/inside.sh

cd "$DIST_DIR"
if command -v sha256sum >/dev/null 2>&1; then
  SHA=sha256sum
else
  SHA="shasum -a 256"
fi
for f in "$OUT_NAME" "$OUT_NAME_ZSTD"; do
  $SHA "$f" > "$f.sha256"
done

echo ">> Done"
ls -lah "$DIST_DIR/$OUT_NAME" "$DIST_DIR/$OUT_NAME.sha256" \
        "$DIST_DIR/$OUT_NAME_ZSTD" "$DIST_DIR/$OUT_NAME_ZSTD.sha256"
cat "$DIST_DIR/$OUT_NAME.sha256" "$DIST_DIR/$OUT_NAME_ZSTD.sha256"
