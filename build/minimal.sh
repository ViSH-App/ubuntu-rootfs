#!/bin/sh
# Build a runtime-only payload from a fully installed temporary Ubuntu base.
# Never purge Essential packages in-place; assemble a file allowlist instead.
set -eu
SOURCE_ROOT=${1:?}
WORK=${2:?}
TARGET="$WORK/minimal-rootfs"
python3 /build/minimal.py "$SOURCE_ROOT" "$TARGET" "/out/${OUT_NAME%.tar.gz}.manifest.json"

# Build the probe outside the payload against the same Ubuntu/ARM64 ABI.
g++ -O2 -pthread /build/runtime-probe.cpp -ldl -o "$WORK/runtime-probe"
python3 /build/verify-minimal.py "$TARGET" "$WORK/runtime-probe"

TAR_TMP="$WORK/minimal.tar"
tar --sort=name --numeric-owner --owner=0 --group=0 -C "$TARGET" -cf "$TAR_TMP" .
gzip -9 -c "$TAR_TMP" > "/out/$OUT_NAME"
zstd -19 --long -T0 -q -o "/out/$OUT_NAME_ZSTD" "$TAR_TMP"
# Verify both actual archives contain exactly the same tar stream.
gzip -t "/out/$OUT_NAME"
zstd -t "/out/$OUT_NAME_ZSTD"
gzip -dc "/out/$OUT_NAME" | sha256sum > "$WORK/gzip-tar.sha256"
zstd -dc "/out/$OUT_NAME_ZSTD" | sha256sum > "$WORK/zstd-tar.sha256"
cmp "$WORK/gzip-tar.sha256" "$WORK/zstd-tar.sha256"
# Repeat structural and executable checks after extracting the shipped archive.
mkdir "$WORK/verify-unpacked"
tar -xzf "/out/$OUT_NAME" -C "$WORK/verify-unpacked"
python3 /build/verify-minimal.py "$WORK/verify-unpacked" "$WORK/runtime-probe"
ls -lh "/out/$OUT_NAME" "/out/$OUT_NAME_ZSTD"
