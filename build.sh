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

# llama.cpp's server runs the downloadable local models (Apple silicon only). Built once,
# statically, with its Metal shaders embedded, from LLAMA_CPP_DIR (default ../llama.cpp).
LLAMA_CPP_DIR="${LLAMA_CPP_DIR:-../llama.cpp}"
if [ ! -x .llama-build/bin/llama-server ]; then
  cmake -S "$LLAMA_CPP_DIR" -B .llama-build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 >/dev/null
  cmake --build .llama-build --target llama-server -j 10 >/dev/null
fi
mkdir -p "$APP/Contents/Helpers"
cp .llama-build/bin/llama-server "$APP/Contents/Helpers/"

ID="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
codesign --force --options runtime --sign "${ID:--}" "$APP/Contents/Helpers/llama-server"
codesign --force --options runtime --sign "${ID:--}" "$APP"
echo "Built $APP (signed: ${ID:-ad hoc})"
