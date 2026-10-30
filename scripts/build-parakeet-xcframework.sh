#!/usr/bin/env bash
#
# Build the dynamic parakeet.xcframework that ekko runs on, from the pinned
# parakeet.cpp tag, and zip it for upload as a release asset.
#
# parakeet.cpp publishes no iOS artifact, so this script is the only way the
# framework comes to exist. It is not part of the app build: the result is
# uploaded once to a vendor-scoped release on EmilLykke/codictate-app, pinned
# by sha256 in scripts/vendor-manifest.ts, and fetched by
# scripts/fetch-parakeet.ts like every other vendored binary.
#
# What it produces:
#   parakeet.xcframework/
#     ios-arm64/parakeet.framework                    (device)
#     ios-arm64_x86_64-simulator/parakeet.framework   (Simulator, fat)
# Each framework holds one dylib that exports only `parakeet_capi_*`, plus
# Headers/parakeet_capi.h and a module map. ggml is linked in statically and
# kept private: crispasr.framework and llama.framework each carry their own
# ggml, and parakeet's must not bind to (or be bound by) theirs.
#
# Usage:
#   scripts/build-parakeet-xcframework.sh [output-dir]
#
# Requires Xcode, cmake and git. Takes a few minutes. The work happens in a
# temp dir unless PARAKEET_WORK_DIR points somewhere else, and the zip lands in
# output-dir (default: <work-dir>/out).

set -euo pipefail

PARAKEET_TAG="v0.6.1"
# The commit the tag pointed at when the published asset was built. A moved tag
# fails the build instead of silently producing a different binary.
PARAKEET_COMMIT="5c9b0fbbd8e611d88e47d7e1ebae9bca9b447e8f"
PARAKEET_REPO="https://github.com/mudler/parakeet.cpp.git"
# Matches expo-build-properties ios.deploymentTarget in app.config.ts.
DEPLOYMENT_TARGET="17.0"
BUNDLE_ID="app.codictate.vendor.parakeet"

WORK_DIR="${PARAKEET_WORK_DIR:-$(mktemp -d -t parakeet-xcframework)}"
mkdir -p "$WORK_DIR" "${1:-$WORK_DIR/out}"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
OUT_DIR="$(cd "${1:-$WORK_DIR/out}" && pwd)"
SRC_DIR="$WORK_DIR/parakeet.cpp"
JOBS="$(sysctl -n hw.ncpu)"

log() { printf '[build-parakeet] %s\n' "$*"; }

# -- source -------------------------------------------------------------------

if [[ ! -d "$SRC_DIR/.git" ]]; then
  log "cloning $PARAKEET_REPO at $PARAKEET_TAG"
  git clone --quiet --depth 1 --branch "$PARAKEET_TAG" "$PARAKEET_REPO" "$SRC_DIR"
fi
actual_commit="$(git -C "$SRC_DIR" rev-parse HEAD)"
if [[ "$actual_commit" != "$PARAKEET_COMMIT" ]]; then
  echo "error: $PARAKEET_TAG resolves to $actual_commit, expected $PARAKEET_COMMIT" >&2
  exit 1
fi
# Only ggml is needed: ced.cpp and voice-detect.cpp are switched off below. The
# submodule is checked out at the commit the tag records, never a branch tip.
git -C "$SRC_DIR" submodule update --init --depth 1 third_party/ggml
log "ggml at $(git -C "$SRC_DIR/third_party/ggml" rev-parse HEAD)"

# -- per-slice static build ---------------------------------------------------

# Configures and builds libparakeet.a plus the ggml static libraries for one
# SDK + architecture. parakeet's own configure step applies its in-tree ggml
# patches (scripts/apply_ggml_patches.sh), idempotently, before ggml builds.
build_static() {
  local name="$1" sysroot="$2" arch="$3"
  local build="$WORK_DIR/build-$name"
  log "configuring $name ($sysroot, $arch)"
  cmake -S "$SRC_DIR" -B "$build" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DPARAKEET_VERSION="${PARAKEET_TAG#v}" \
    -DPARAKEET_SHARED=OFF \
    -DPARAKEET_BUILD_CLI=OFF \
    -DPARAKEET_BUILD_SERVER=OFF \
    -DPARAKEET_BUILD_TESTS=OFF \
    -DPARAKEET_WITH_CED=OFF \
    -DPARAKEET_WITH_VOICEDETECT=OFF \
    -DPARAKEET_GGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_NATIVE=OFF \
    -DGGML_OPENMP=OFF \
    -DGGML_BACKEND_DL=OFF \
    -DGGML_BUILD_TESTS=OFF \
    -DGGML_BUILD_EXAMPLES=OFF \
    > "$build.configure.log"
  log "building $name"
  cmake --build "$build" --target parakeet -j "$JOBS" > "$build.build.log"
}

# Links one slice's static libraries into a single dylib that exports only the
# C API. -force_load keeps every parakeet_capi_* entry point; ggml is resolved
# from its archives as needed and, being absent from the export list, stays
# local to this image.
link_dylib() {
  local name="$1" target="$2" sdk="$3"
  local build="$WORK_DIR/build-$name"
  local out="$WORK_DIR/dylib-$name/parakeet"
  mkdir -p "$(dirname "$out")"

  local archives=()
  while IFS= read -r lib; do archives+=("$lib"); done < <(
    find "$build/third_party/ggml" -name 'libggml*.a' | sort
  )

  log "linking $name dylib"
  xcrun --sdk "$sdk" clang++ \
    -target "$target" \
    -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" \
    -dynamiclib \
    -install_name "@rpath/parakeet.framework/parakeet" \
    -compatibility_version 1 \
    -current_version "${PARAKEET_TAG#v}" \
    -Wl,-force_load,"$build/libparakeet.a" \
    "${archives[@]}" \
    -Wl,-exported_symbols_list,"$WORK_DIR/exports.txt" \
    -Wl,-dead_strip \
    -framework Foundation \
    -framework Metal \
    -framework MetalKit \
    -framework Accelerate \
    -o "$out"
  strip -x "$out"
  # strip leaves an ad-hoc signature named "parakeet.strip"; Xcode keeps the
  # identifier when it re-signs on copy, so set the real one here.
  codesign --force --sign - --identifier "$BUNDLE_ID" "$out" 2> /dev/null
}

make_framework() {
  local dylib="$1" dest="$2" platform="$3"
  local fw="$dest/parakeet.framework"
  rm -rf "$fw"
  mkdir -p "$fw/Headers" "$fw/Modules"
  cp "$dylib" "$fw/parakeet"
  cp "$SRC_DIR/include/parakeet_capi.h" "$fw/Headers/"
  cat > "$fw/Modules/module.modulemap" <<'EOF'
framework module parakeet {
  header "parakeet_capi.h"
  export *
}
EOF
  cat > "$fw/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>parakeet</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>parakeet</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>${PARAKEET_TAG#v}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
  <key>MinimumOSVersion</key><string>$DEPLOYMENT_TARGET</string>
</dict>
</plist>
EOF
}

echo '_parakeet_capi_*' > "$WORK_DIR/exports.txt"

build_static ios-arm64 iphoneos arm64
build_static sim-arm64 iphonesimulator arm64
build_static sim-x86_64 iphonesimulator x86_64

link_dylib ios-arm64 "arm64-apple-ios$DEPLOYMENT_TARGET" iphoneos
link_dylib sim-arm64 "arm64-apple-ios$DEPLOYMENT_TARGET-simulator" iphonesimulator
link_dylib sim-x86_64 "x86_64-apple-ios$DEPLOYMENT_TARGET-simulator" iphonesimulator

mkdir -p "$WORK_DIR/dylib-sim"
lipo -create \
  "$WORK_DIR/dylib-sim-arm64/parakeet" \
  "$WORK_DIR/dylib-sim-x86_64/parakeet" \
  -output "$WORK_DIR/dylib-sim/parakeet"

make_framework "$WORK_DIR/dylib-ios-arm64/parakeet" "$WORK_DIR/fw-ios" iPhoneOS
make_framework "$WORK_DIR/dylib-sim/parakeet" "$WORK_DIR/fw-sim" iPhoneSimulator

# -- checks -------------------------------------------------------------------

for fw in "$WORK_DIR/fw-ios/parakeet.framework" "$WORK_DIR/fw-sim/parakeet.framework"; do
  exported="$(nm -gU "$fw/parakeet" | awk '{print $3}' | sort -u)"
  leaked="$(grep -v '^_parakeet_capi_' <<<"$exported" || true)"
  if [[ -n "$leaked" ]]; then
    echo "error: $fw exports symbols outside parakeet_capi_*:" >&2
    echo "$leaked" | head -20 >&2
    exit 1
  fi
  if ! grep -qx '_parakeet_capi_transcribe_pcm' <<<"$exported"; then
    echo "error: $fw does not export parakeet_capi_transcribe_pcm" >&2
    exit 1
  fi
  log "$(basename "$(dirname "$fw")"): $(wc -l <<<"$exported" | tr -d ' ') exported symbols, all parakeet_capi_*"
done

# -- package ------------------------------------------------------------------

XCFRAMEWORK="$OUT_DIR/parakeet.xcframework"
ZIP="$OUT_DIR/parakeet-${PARAKEET_TAG}-ios-xcframework.zip"
rm -rf "$XCFRAMEWORK" "$ZIP"
xcodebuild -create-xcframework \
  -framework "$WORK_DIR/fw-ios/parakeet.framework" \
  -framework "$WORK_DIR/fw-sim/parakeet.framework" \
  -output "$XCFRAMEWORK" > /dev/null
cp "$SRC_DIR/LICENSE" "$XCFRAMEWORK/LICENSE-parakeet.cpp.txt"
cp "$SRC_DIR/third_party/ggml/LICENSE" "$XCFRAMEWORK/LICENSE-ggml.txt"

(cd "$OUT_DIR" && ditto -c -k --keepParent --norsrc --noextattr parakeet.xcframework "$ZIP")

log "wrote $ZIP"
log "sha256 $(shasum -a 256 "$ZIP" | awk '{print $1}')"
log "size   $(du -h "$ZIP" | awk '{print $1}')"
