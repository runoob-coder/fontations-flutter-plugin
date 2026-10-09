#!/usr/bin/env bash
#
# Fails when the committed XCFrameworks were not built from the current `rust/`.
#
# Why this exists
# ---------------
# The Swift Package Manager integration links committed binaries, so a stale
# XCFramework does not fail the build - it quietly runs old Rust code. That is
# how a fix once looked "broken" in the Flutter integration tests while the Rust
# unit tests (which compile from source) were green.
#
# Cheap by design: it only hashes `rust/`, so it runs on a Linux runner in a
# couple of seconds and gates the expensive macOS job.
#
# Usage: ./scripts/check_xcframework.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/xcframework_fingerprint.sh
source "$ROOT/scripts/xcframework_fingerprint.sh"

RUST_DIR="$ROOT/rust"
FINGERPRINT_FILE="$ROOT/scripts/xcframework.sha256"

if [ ! -f "$FINGERPRINT_FILE" ]; then
  echo "error: $FINGERPRINT_FILE is missing." >&2
  echo "       It is written by scripts/build_xcframework.sh; commit it." >&2
  exit 1
fi

expected=$(tr -d '[:space:]' < "$FINGERPRINT_FILE")
actual=$(fontations_rust_fingerprint "$RUST_DIR")

if [ "$expected" = "$actual" ]; then
  echo "ok: both XCFrameworks were built from the current rust/ ($actual)"
  exit 0
fi

cat >&2 <<EOF
error: the committed XCFrameworks do not match rust/.

  fingerprint of rust/ right now : $actual
  fingerprint they were built from: $expected

Someone changed rust/ without repackaging the binaries. SwiftPM consumers would
link the old code silently, so rebuild and commit the artifacts:

  ./scripts/build_xcframework.sh

(That rewrites scripts/xcframework.sha256; commit it together with the
XCFrameworks in the same commit as the Rust change.)
EOF
exit 1
