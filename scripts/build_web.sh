#!/usr/bin/env bash
#
# Compiles the Rust crate into a WebAssembly module and writes the JavaScript
# glue next to it, ready to be served by a Flutter web app.
#
#   ./scripts/build_web.sh [output_dir]
#
# The default output is `example/web/pkg`, which is where `flutter_rust_bridge`
# looks for it: the generated Dart loads `<webPrefix><stem>.js` with
# `webPrefix = 'pkg/'`, so an app has to serve `pkg/fontations.js` and
# `pkg/fontations_bg.wasm` from its own web root.
#
# The module is **threaded**: it uses `SharedArrayBuffer`, which browsers only
# hand out to a cross origin isolated page. Whatever serves the app has to send
#
#   Cross-Origin-Opener-Policy: same-origin
#   Cross-Origin-Embedder-Policy: require-corp
#
# `scripts/coop_server.py` does exactly that for local testing, and the exact
# headers `flutter_rust_bridge` expects are documented at
# https://fzyzcjy.github.io/flutter_rust_bridge/manual/miscellaneous/web-cross-origin
#
# A single threaded build is *not* an alternative: `flutter_rust_bridge` spins
# up a Web Worker pool on wasm and panics at start up when the module has no
# shared memory. That is why this needs nightly with `-Z build-std` (the same
# toolchain `flutter_rust_bridge_codegen build-web` drives through `wasm-pack`)
# rather than the plain stable `wasm32-unknown-unknown` target.
set -euo pipefail

OUT_DIR="${1:-example/web/pkg}"

cd "$(dirname "$0")/.."

# `wasm-bindgen` has to match the version of the crate exactly: the generated
# JavaScript and the wasm module share an ABI that changes between releases.
WASM_BINDGEN_VERSION="$(
  awk '/^name = "wasm-bindgen"$/ { found = 1; next } found && /^version = "/ {
    gsub(/version = "|"/, ""); print; exit
  }' rust/Cargo.lock
)"
if [[ -z "$WASM_BINDGEN_VERSION" ]]; then
  echo "could not read the wasm-bindgen version from rust/Cargo.lock" >&2
  exit 1
fi

echo "wasm-bindgen $WASM_BINDGEN_VERSION -> $OUT_DIR"

rustup toolchain install nightly --profile minimal
rustup component add rust-src --toolchain nightly
rustup target add wasm32-unknown-unknown --toolchain nightly

if ! command -v wasm-bindgen >/dev/null 2>&1; then
  echo "installing wasm-bindgen-cli $WASM_BINDGEN_VERSION"
  cargo install wasm-bindgen-cli --version "$WASM_BINDGEN_VERSION"
elif [[ "$(wasm-bindgen --version)" != *"$WASM_BINDGEN_VERSION"* ]]; then
  echo "wasm-bindgen is $(wasm-bindgen --version), the crate needs $WASM_BINDGEN_VERSION" >&2
  exit 1
fi

# The flags `flutter_rust_bridge_codegen build-web` passes to `wasm-pack`: atomics
# plus shared memory, with the TLS and heap symbols the worker pool links
# against. Keep them in sync with that command if this ever stops loading.
(cd rust && \
  RUSTUP_TOOLCHAIN=nightly \
  RUSTFLAGS="-C target-feature=+atomics,+bulk-memory,+mutable-globals \
-C link-args=--shared-memory \
-C link-args=--max-memory=1073741824 \
-C link-args=--import-memory \
-C link-args=--export=__heap_base \
-C link-args=--export=__wasm_init_tls \
-C link-args=--export=__tls_size \
-C link-args=--export=__tls_align \
-C link-args=--export=__tls_base" \
  cargo +nightly build \
    --target wasm32-unknown-unknown \
    --release \
    -Z build-std=std,panic_abort)

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
wasm-bindgen \
  --target no-modules \
  --no-typescript \
  --out-dir "$OUT_DIR" \
  --out-name fontations \
  rust/target/wasm32-unknown-unknown/release/fontations.wasm

echo "built:"
find "$OUT_DIR" -type f -exec ls -lh {} \;

cat <<NOTE

The app has to serve this folder from its web root as "pkg/", with the
cross origin isolation headers listed at the top of this script:
  * copy $OUT_DIR into <your_app>/web/pkg, or
  * build straight into it: $0 <your_app>/web/pkg
NOTE
