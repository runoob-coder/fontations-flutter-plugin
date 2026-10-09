#!/usr/bin/env bash
#
# Shared helper: a fingerprint of everything the Rust build depends on.
#
# The XCFrameworks under ios/ and macos/ are committed, but they are *build
# output*: they are only correct for the exact `rust/` tree they were built
# from. Nothing about a stale binary looks wrong at build time - SwiftPM happily
# links last month's dylib - so CI compares this fingerprint instead of trusting
# that whoever changed `rust/` also reran the packaging script.
#
# The fingerprint deliberately covers the whole crate (sources, `Cargo.toml`,
# `Cargo.lock`, `build.rs`, `.cargo/config.toml`) and excludes `target/`, which
# is 2 GB of intermediate artifacts that must not affect the result.

set -euo pipefail

# `sha256sum` on Linux, `shasum -a 256` on macOS.
fontations_sha256() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}

# Prints the fingerprint as a bare hex digest.
#
# One line per file (`<relative path> <sha256>`), then a digest of those lines,
# so both the file set and each file's contents matter. `LC_ALL=C sort` keeps
# the order stable across machines.
fontations_rust_fingerprint() {
  local rust_dir=$1

  find "$rust_dir" -type f -not -path '*/target/*' -print |
    LC_ALL=C sort |
    while IFS= read -r file; do
      printf '%s ' "${file#"$rust_dir"/}"
      fontations_sha256 "$file" | awk '{print $1}'
    done |
    fontations_sha256 |
    awk '{print $1}'
}
