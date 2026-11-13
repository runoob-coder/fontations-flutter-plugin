#!/usr/bin/env bash
# Test entry point; native suites rebuild the host Rust library first.
# Run ./scripts/test.sh --help for usage.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"

# --- Options -----------------------------------------------------------------

unit=0
integration=0
example=0
rust=0
fuzz=0
device=''
coverage=0
build_native=1
explicit=0

usage() {
  cat <<'USAGE'
Usage: ./scripts/test.sh [suite...] [options]

Suites (default: --unit --integration --example --rust --fuzz):
  --unit           test/unit + test/p1_guards_test.dart (pure Dart)
  --integration    test/integration + test/fontations_test.dart
                   + test/upstream_test.dart (needs the host Rust library)
  --example        example/test widget tests (needs the host Rust library)
  --rust           cargo test --all-targets in rust/
  --fuzz           cargo test in rust/fuzz (deterministic target replays)
  --device TARGET  example/integration_test/simple_test.dart -d TARGET

Options:
  --coverage       write coverage/lcov.{unit,integration,example}.info
  --no-build       skip cargo build --release (reuse an existing library)
  -h, --help       show this help
USAGE
}

while (($#)); do
  case "$1" in
    --unit)
      unit=1
      explicit=1
      shift
      ;;
    --integration)
      integration=1
      explicit=1
      shift
      ;;
    --example)
      example=1
      explicit=1
      shift
      ;;
    --rust)
      rust=1
      explicit=1
      shift
      ;;
    --fuzz)
      fuzz=1
      explicit=1
      shift
      ;;
    --device)
      if (($# < 2)); then
        echo '--device needs a target, e.g. --device macos' >&2
        exit 2
      fi
      device="$2"
      explicit=1
      shift 2
      ;;
    --coverage)
      coverage=1
      shift
      ;;
    --no-build)
      build_native=0
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ((!explicit)); then
  unit=1
  integration=1
  example=1
  rust=1
  fuzz=1
fi

# --- Helpers -----------------------------------------------------------------

banner() {
  printf '\n==> %s\n' "$*"
}

# Bash 3.2 (macOS) rejects an empty array expansion under set -u.
COVERAGE_FILE=''
flutter_test() {
  if ((coverage)); then
    flutter test --coverage --coverage-path "$COVERAGE_FILE" "$@"
  else
    flutter test "$@"
  fi
}

ensure_native_library() {
  if ((!build_native)); then
    banner 'Skipping cargo build --release (--no-build)'
    return
  fi
  banner 'Building the host Rust library (cargo build --release)'
  (cd "$ROOT/rust" && cargo build --release)
}

need_native=0
if ((integration || example)) || [[ -n "$device" ]]; then
  need_native=1
fi
if ((need_native)); then
  ensure_native_library
fi
if ((coverage)); then
  mkdir -p "$ROOT/coverage"
fi

# --- Suites ------------------------------------------------------------------

if ((unit)); then
  COVERAGE_FILE="$ROOT/coverage/lcov.unit.info"
  banner 'Dart unit tests (pure Dart, no native library)'
  flutter_test test/unit test/p1_guards_test.dart
fi

if ((integration)); then
  COVERAGE_FILE="$ROOT/coverage/lcov.integration.info"
  banner 'Dart integration tests (host Rust library)'
  flutter_test \
    test/integration test/fontations_test.dart test/upstream_test.dart
fi

if ((example)); then
  COVERAGE_FILE="$ROOT/coverage/lcov.example.info"
  banner 'Example app widget tests'
  (cd "$ROOT/example" && flutter_test)
fi

if ((rust)); then
  banner 'Rust unit tests (cargo test --all-targets)'
  (cd "$ROOT/rust" && cargo test --all-targets)
fi

if ((fuzz)); then
  banner 'Fuzz target tests (cargo test in rust/fuzz)'
  (cd "$ROOT/rust/fuzz" && cargo test)
fi

if [[ -n "$device" ]]; then
  banner "On-device integration tests (-d $device)"
  (cd "$ROOT/example" && flutter test integration_test/simple_test.dart -d "$device")
fi

printf '\n==> All selected suites passed.\n'
