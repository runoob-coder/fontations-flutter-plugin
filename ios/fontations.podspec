#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint fontations.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'fontations'
  s.version          = '0.0.1'
  s.summary          = 'Flutter bindings for the fontations font stack.'
  s.description      = <<-DESC
Reads OpenType font metadata, variation axes and glyph outlines through the
fontations crates (read-fonts / skrifa), exposed to Dart with flutter_rust_bridge.
                       DESC
  s.homepage         = 'https://github.com/googlefonts/fontations'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.module_name      = 'fontations'

  # The source files below are included in the native builds of apps using this
  # FFI plugin. Podspec does not support relative paths, so the files live under
  # `fontations/Sources` and are shared with the SwiftPM package.

  # CocoaPods integration: Rust is compiled from source here (see script_phase
  # below). Apps that use Swift Package Manager link the prebuilt XCFramework
  # referenced by ios/fontations/Package.swift instead.
  s.source           = { :path => '.' }
  # Shared with the SwiftPM package, see ios/fontations/Package.swift.
  s.source_files = 'fontations/Sources/fontations/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '11.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  s.script_phase = {
    :name => 'Build Rust library',
    # First argument is relative path to the `rust` folder, second is name of rust library
    :script => 'sh "$PODS_TARGET_SRCROOT/../cargokit/build_pod.sh" ../rust fontations',
    :execution_position => :before_compile,
    :input_files => ['${BUILT_PRODUCTS_DIR}/cargokit_phony'],
    # Let XCode know that the static library referenced in -force_load below is
    # created by this build step.
    :output_files => ["${PODS_CONFIGURATION_BUILD_DIR}/fontations/libfontations.a"],
  }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # Flutter.framework does not contain a i386 slice.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_LDFLAGS' => '-force_load ${PODS_CONFIGURATION_BUILD_DIR}/fontations/libfontations.a',
  }
end