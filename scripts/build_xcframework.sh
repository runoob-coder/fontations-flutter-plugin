#!/usr/bin/env bash
#
# Builds the prebuilt binaries that back the Swift Package Manager integration
# of this plugin.
#
# Why this exists
# ---------------
# The Rust code is normally compiled by cargokit while the app builds: on the
# CocoaPods integration that happens in the podspec's script phase. When an app
# uses Swift Package Manager there is no such hook - SwiftPM has no script
# phases and its build tool plugins run sandboxed, so cargo cannot run during
# the Xcode build. Those apps therefore link the artifact produced by this
# script instead.
#
# When to run it
# --------------
# Whenever anything under rust/ changes (crate sources, dependencies, profile
# settings): ./scripts/build_xcframework.sh
#
# The result is committed, so SwiftPM users always link exactly the binary that
# was built together with the Rust sources it came from.
#
# What it does
# ------------
#   1. cargo build for every Apple target (macOS universal, iOS device, iOS
#      simulator).
#   2. Packages the slices: `fontations.framework` bundles for iOS, a plain
#      `libfontations.dylib` for macOS (macOS framework bundles are deep
#      bundles: they need Versions/Current symlinks, which `flutter pub
#      publish` does not preserve). install_name is @rpath based in both cases.
#   3. lipo the macOS and iOS simulator slices into fat binaries.
#   4. xcodebuild -create-xcframework, then installs one XCFramework in
#      ios/fontations/ and one in macos/fontations/.
#
# Usage: ./scripts/build_xcframework.sh [release|debug]

set -euo pipefail

PROFILE=${1:-release}
case "$PROFILE" in
  release) PROFILE_DIR=release ;;
  debug)   PROFILE_DIR=debug ;;
  *) echo "usage: $0 [release|debug]" >&2; exit 1 ;;
esac

CRATE=fontations
FRAMEWORK_NAME=fontations.framework
MIN_MACOS=11.0
MIN_IOS=13.0

ROOT_XCF=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/xcframework_fingerprint.sh
source "$ROOT_XCF/scripts/xcframework_fingerprint.sh"
RUST_DIR="$ROOT_XCF/rust"
WORK_DIR="$ROOT_XCF/build/xcframework/$PROFILE_DIR"
IOS_OUT="$ROOT_XCF/ios/$CRATE/$CRATE.xcframework"
MACOS_OUT="$ROOT_XCF/macos/$CRATE/$CRATE.xcframework"

log() { printf '\n==> %s\n' "$*"; }

# Prints the deployment target of a Mach-O binary.
min_version() {
  local version
  version=$(
    otool -l "$1" |
      awk '/cmd LC_BUILD_VERSION/ { f = 1 } f && /minos/ { print $2; exit }'
  )
  if [ -z "$version" ]; then
    # Older linkers emit LC_VERSION_MIN_IPHONEOS / LC_VERSION_MIN_MACOSX.
    version=$(
      otool -l "$1" |
        awk '/cmd LC_VERSION_MIN_/ { f = 1 } f && /version/ { print $2; exit }'
    )
  fi
  echo "$version"
}

# build_slice <cargo target> <linker min-version flag> <slice dir>
#
# Leaves the linked binary at <slice dir>/lib<crate>.dylib.
build_slice() {
  local target=$1 link_arg=$2 slice_dir=$3

  log "cargo build --profile $PROFILE --target $target"
  ( cd "$RUST_DIR" && RUSTFLAGS="-C link-arg=$link_arg" \
      cargo build --profile "$PROFILE" --target "$target" )

  mkdir -p "$slice_dir"
  cp "$RUST_DIR/target/$target/$PROFILE_DIR/lib$CRATE.dylib" \
    "$slice_dir/lib$CRATE.dylib"
  strip -x -S "$slice_dir/lib$CRATE.dylib" || true
}

# make_framework <slice dir> <framework dir>
#
# Wraps a dylib into an iOS framework bundle.
make_framework() {
  local slice_dir=$1 fw_dir=$2
  local min_os

  rm -rf "$fw_dir"
  mkdir -p "$fw_dir"
  cp "$slice_dir/lib$CRATE.dylib" "$fw_dir/$CRATE"
  install_name_tool -id "@rpath/$FRAMEWORK_NAME/$CRATE" "$fw_dir/$CRATE"

  min_os=$(min_version "$fw_dir/$CRATE")
  if [ -z "$min_os" ]; then
    echo "could not determine the deployment target of $fw_dir/$CRATE" >&2
    exit 1
  fi

  cat > "$fw_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$CRATE</string>
  <key>CFBundleIdentifier</key>
  <string>org.$CRATE.$CRATE</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$CRATE</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>iPhoneOS</string>
  </array>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>MinimumOSVersion</key>
  <string>$min_os</string>
</dict>
</plist>
PLIST
  chmod 644 "$fw_dir/Info.plist"
}

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

build_slice aarch64-apple-darwin "-mmacosx-version-min=$MIN_MACOS" \
  "$WORK_DIR/macos/arm64"
build_slice x86_64-apple-darwin "-mmacosx-version-min=$MIN_MACOS" \
  "$WORK_DIR/macos/x86_64"
build_slice aarch64-apple-ios "-miphoneos-version-min=$MIN_IOS" \
  "$WORK_DIR/ios/device"
build_slice aarch64-apple-ios-sim "-miphonesimulator-version-min=$MIN_IOS" \
  "$WORK_DIR/ios/simulator/arm64"
build_slice x86_64-apple-ios "-miphoneos-version-min=$MIN_IOS" \
  "$WORK_DIR/ios/simulator/x86_64"

log "creating fat macOS / iOS simulator binaries"
mkdir -p "$WORK_DIR/macos/universal" "$WORK_DIR/ios/simulator/universal"
lipo -create \
  "$WORK_DIR/macos/arm64/lib$CRATE.dylib" \
  "$WORK_DIR/macos/x86_64/lib$CRATE.dylib" \
  -output "$WORK_DIR/macos/universal/lib$CRATE.dylib"
lipo -create \
  "$WORK_DIR/ios/simulator/arm64/lib$CRATE.dylib" \
  "$WORK_DIR/ios/simulator/x86_64/lib$CRATE.dylib" \
  -output "$WORK_DIR/ios/simulator/universal/lib$CRATE.dylib"
install_name_tool -id "@rpath/lib$CRATE.dylib" \
  "$WORK_DIR/macos/universal/lib$CRATE.dylib"

log "creating iOS frameworks"
make_framework "$WORK_DIR/ios/device" "$WORK_DIR/ios/device/$FRAMEWORK_NAME"
make_framework "$WORK_DIR/ios/simulator/universal" \
  "$WORK_DIR/ios/simulator/universal/$FRAMEWORK_NAME"

log "creating macOS XCFramework"
rm -rf "$MACOS_OUT"
xcodebuild -create-xcframework \
  -library "$WORK_DIR/macos/universal/lib$CRATE.dylib" \
  -output "$MACOS_OUT" > /dev/null

log "creating iOS XCFramework"
rm -rf "$IOS_OUT"
xcodebuild -create-xcframework \
  -framework "$WORK_DIR/ios/device/$FRAMEWORK_NAME" \
  -framework "$WORK_DIR/ios/simulator/universal/$FRAMEWORK_NAME" \
  -output "$IOS_OUT" > /dev/null

# Record which `rust/` tree these binaries came from. `scripts/check_xcframework.sh`
# recomputes it in CI and fails if someone ships a binary without rebuilding it.
log "recording the rust fingerprint"
FINGERPRINT=$(fontations_rust_fingerprint "$RUST_DIR")
printf '%s\n' "$FINGERPRINT" > "$ROOT_XCF/scripts/xcframework.sha256"

log "built:"
du -sh "$MACOS_OUT" | sed "s|^|  |"
du -sh "$IOS_OUT" | sed "s|^|  |"
echo "  rust fingerprint: $FINGERPRINT"
echo
echo "Commit both XCFrameworks together with scripts/xcframework.sha256 and the"
echo "Rust change they were built from."
