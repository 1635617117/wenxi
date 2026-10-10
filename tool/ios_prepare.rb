#!/usr/bin/env ruby
# iOS build preparation. Runs ONLY inside the GitHub Actions iOS job; it never
# touches Android/Windows builds.
#
#   1. Inject dependency_overrides for the two desktop-only plugins
#      (window_manager / tray_manager) -> pure-Dart stubs, because those
#      plugins ship Linux/macOS/Windows backends only and cannot link on iOS.
#      Injected here (not committed) so desktop builds keep the real plugins.
#   2. Patch ios/Runner/Info.plist with the permissions the engine needs:
#      background audio (BT streaming), arbitrary loads, local network.
#
# No pbxproj editing: the Gopeed xcframework and the Swift bridge arrive through
# the local plugin plugins/asterlink_native (CocoaPods links and embeds them).
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
abort 'pubspec.yaml missing' unless File.exist?(File.join(ROOT, 'pubspec.yaml'))

# --- 1. dependency_overrides -> stubs -------------------------------------
pubspec = File.join(ROOT, 'pubspec.yaml')
lines = File.readlines(pubspec)
marker = 'stub_plugins/window_manager'
idx = lines.index { |l| l.start_with?('dependency_overrides:') }
abort 'pubspec.yaml has no dependency_overrides section' unless idx
unless lines.any? { |l| l.include?(marker) }
  lines.insert(idx + 1,
               "  window_manager:\n",
               "    path: stub_plugins/window_manager\n",
               "  tray_manager:\n",
               "    path: stub_plugins/tray_manager\n")
  File.write(pubspec, lines.join)
  puts 'injected stub dependency_overrides'
else
  puts 'stub overrides already present'
end

# --- 2. Info.plist permissions --------------------------------------------
plist = File.join(ROOT, 'ios/Runner/Info.plist')
unless File.exist?(plist)
  puts "WARN: #{plist} not found - run 'flutter create --platforms=ios .' first"
  exit 0
end

# Remove-then-add so the script is idempotent across repeated CI runs.
def plist_delete(plist, key)
  system('/usr/libexec/PlistBuddy', '-c', "Delete :#{key}", plist,
         out: File::NULL, err: File::NULL)
end

def plist_add(plist, key, type, value)
  # PlistBuddy parses unquoted strings by whitespace, so always quote values.
  system('/usr/libexec/PlistBuddy', '-c', %(Add :#{key} #{type} "#{value}"), plist)
end

# gomobile's -target=ios takes no version in this x/mobile revision, so the
# deployment target is set here instead (matches the podspec platform).
%x(/usr/bin/ruby -e '
require "xcodeproj"
p = Xcodeproj::Project.open("ios/Runner.xcodeproj")
p.targets.each do |t|
  %w[Debug Release Profile].each do |c|
    t.build_configuration_list.build_settings(c)["IPHONEOS_DEPLOYMENT_TARGET"] = "12.0"
  end
end
p.save
puts "set IPHONEOS_DEPLOYMENT_TARGET=12.0"
') if File.directory?('ios/Runner.xcodeproj')

plist_delete(plist, 'UIBackgroundModes')
plist_delete(plist, 'NSAppTransportSecurity')
plist_delete(plist, 'NSLocalNetworkUsageDescription')
plist_add(plist, 'UIBackgroundModes', 'array', '')
plist_add(plist, 'UIBackgroundModes:0', 'string', 'audio')
plist_add(plist, 'UIBackgroundModes:1', 'string', 'fetch')
plist_add(plist, 'NSAppTransportSecurity', 'dict', '')
plist_add(plist, 'NSAppTransportSecurity:NSAllowsArbitraryLoads', 'bool', 'true')
plist_add(plist, 'NSLocalNetworkUsageDescription', 'string',
          '用于网盘解析与 BT 本地流式传输')
puts "patched #{plist}"
