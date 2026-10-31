#!/bin/sh
# Builds a universal Lingveil.app into build/. Signs with SIGN_IDENTITY when set, otherwise
# with the first Apple Development identity (a stable signature keeps the Screen Recording
# permission across rebuilds), otherwise ad hoc.
set -eu
cd "$(dirname "$0")"
VERSION="${VERSION:-0.1.0}"
APP=build/Lingveil.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ARCHS="${ARCHS:-arm64 x86_64}"
for arch in $ARCHS; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos15.0" -module-name Lingveil Sources/*.swift -o "build/Lingveil-$arch" &
done
wait
lipo -create $(for a in $ARCHS; do echo "build/Lingveil-$a"; done) -output "$APP/Contents/MacOS/Lingveil"
rm build/Lingveil-*

sed -e "s/VERSION/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

ID="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
codesign --force --options runtime --sign "${ID:--}" "$APP"
echo "Built $APP (signed: ${ID:-ad hoc})"
