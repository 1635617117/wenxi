Pod::Spec.new do |s|
  s.name             = 'asterlink_native'
  s.version          = '1.5.0'
  s.summary          = 'AsterLink iOS host bridge for the Gopeed engine.'
  s.homepage         = 'https://github.com/z7786/wenxi'
  s.license          = { :type => 'AGPL-3.0-only', :file => '../../LICENSE' }
  s.author           = { 'AsterLink' => 'noreply@example.com' }
  s.source           = { :path => '.' }

  s.platform         = :ios, '12.0'
  s.swift_version    = '5.0'

  # Produced by native/build-gopeed-ios.sh (gomobile bind -target=ios) and
  # written straight into this directory. CocoaPods handles link + embed +
  # framework search paths, so Runner.xcodeproj needs no manual edit.
  s.vendored_frameworks = 'AsterLink.xcframework'
  s.source_files        = 'Classes/**/*.{swift,h,m}'
  # Go's runtime/DNS code references res_9_ninit, res_9_nsearch, res_9_nclose.
  # macOS links libresolv implicitly; iOS does not, so link it explicitly.
  s.libraries = 'resolv'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }

  s.dependency 'Flutter'
end
