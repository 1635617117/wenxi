// AsterLink iOS host plugin: Dart entry point.
//
// The app talks to the Gopeed engine over the plain MethodChannel
// 'com.asterlink.app/native' from lib/platform/native_engine.dart
// (AndroidGopeedTransport). Reusing that channel on iOS keeps the Dart layer
// untouched, so this package intentionally exposes no Dart API; its only job is
// to make Flutter load and register the iOS platform implementation.

library asterlink_native;

/// No-op: the plugin registers itself on iOS via GeneratedPluginRegistrant.
void ensureAsterLinkNative() {}
