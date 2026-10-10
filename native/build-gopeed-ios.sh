#!/usr/bin/env bash
# Build the embedded Gopeed 1.8.1 engine into an iOS .xcframework via gomobile,
# mirroring native/build-gopeed.ps1 (Android .aar) with the NDK-only flags
# (-androidapi / -javapkg / max-page-size) removed and -target swapped to ios.
#
# Runs on a macOS runner (Xcode clang toolchain required by cgo). Output:
#   ios/Frameworks/AsterLink.xcframework   (ios-arm64 + ios-arm64-simulator)
#
# Dart binding symbol name follows package `gopeed` in bind/asterlink, so the
# generated Objective-C headers expose the same Open/Begin/Snapshot/... API the
# Kotlin/JNI path uses. No Go source changes needed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NATIVE="$ROOT/native"
GOPEED="$NATIVE/gopeed"
TOOLS="$NATIVE/.tools-ios"
OUT="$ROOT/plugins/asterlink_native/ios"

# Pinned to the same x/mobile commit as build-gopeed.ps1.
# gomobile init installs gobind@latest on its own, which can require a newer Go
# than the engine is pinned to (x/mobile 2026-09 needs go >= 1.26). Do not hard
# pin GOTOOLCHAIN here: let it upgrade on demand, then the engine itself still
# builds with the version its go.mod asks for.
MOBILE_VERSION="v0.0.0-20250911085028-6912353760cf"

export GOBIN="$TOOLS"
export PATH="$TOOLS:$PATH"
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"
export GOFLAGS="-mod=mod"
: "${GOPROXY:=https://proxy.golang.org,direct}"
export GOPROXY

mkdir -p "$TOOLS" "$OUT"

echo ">> Verifying Go toolchain"
go version

echo ">> Installing gomobile/gobind @ $MOBILE_VERSION"
go install golang.org/x/mobile/cmd/gomobile@"$MOBILE_VERSION"
go install golang.org/x/mobile/cmd/gobind@"$MOBILE_VERSION"

echo ">> gomobile init (needs Xcode clang for cgo)"
# The runner can default to Command Line Tools, which has no iOS SDK. Force the
# full Xcode toolchain or cgo cross-compilation for iOS fails.
if [ -d /Applications/Xcode.app ]; then
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer || \
    xcode-select -s /Applications/Xcode.app/Contents/Developer
fi
xcodebuild -version || true
gomobile init

echo ">> Building iOS xcframework from bind/asterlink"
cd "$GOPEED"
gomobile bind \
  -tags nosqlite \
  -trimpath \
  -ldflags "-w -s -checklinkname=0 -X github.com/GopeedLab/gopeed/pkg/base.Version=1.8.1" \
  -target=ios,12.0 \
  -o "$OUT/AsterLink.xcframework" \
  ./bind/asterlink

echo ">> Verifying artifact"
if [ ! -d "$OUT/AsterLink.xcframework" ]; then
  echo "ERROR: AsterLink.xcframework not produced" >&2
  exit 1
fi
ls -la "$OUT/AsterLink.xcframework"
echo ">> Done: $OUT/AsterLink.xcframework"
