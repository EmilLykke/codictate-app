// Pinned CrispASR release and the exact slices codictate-app keeps from it.
//
// `scripts/fetch-crispasr.ts` (which downloads and verifies) and
// `plugins/withCrispASR.ts` (which vendors the result into the generated ios/
// tree) both read this file, so the fetched artifact and the linked artifact
// cannot drift apart.
//
// crispasr is a prebuilt release asset verified by sha256; nothing is built
// from source. See docs/adr/0001-crispasr-as-the-ios-asr-harness.md for why,
// and for why FluidAudio keeps Parakeet.

/**
 * CrispASR, the iOS ASR Harness. Same tag the desktop app pins, so a Danish bug
 * reproduces identically on either.
 */
export const CRISPASR_VERSION = "v0.8.29";

export const CRISPASR_RELEASE_BASE = `https://github.com/CrispStrobe/CrispASR/releases/download/${CRISPASR_VERSION}`;

export interface VendorArchive {
  /** Asset file name inside the pinned release. */
  asset: string;
  /** sha256 of the asset, as published by the GitHub release asset digest. */
  sha256: string;
}

/**
 * The official xcframework, ~500 MB across seven platform slices plus a dSYM
 * per slice. The fetch script keeps two slices and no dSYM, which is roughly
 * 4% of the archive; the rest never lands on disk.
 */
export const CRISPASR_XCFRAMEWORK_ARCHIVE: VendorArchive = {
  asset: `crispasr-${CRISPASR_VERSION}-xcframework.zip`,
  sha256: "d57dd5c55493e14e8d117884065c5a4638d3f1bd5a667cd68f71e471ab231910",
};

export const CRISPASR_XCFRAMEWORK_NAME = "crispasr.xcframework";

/**
 * The two `LibraryIdentifier`s kept from the archive. Everything else
 * (`macos-*`, `tvos-*`, `xros-*`, and every dSYM) is discarded, and the
 * xcframework's `Info.plist` is rewritten so `AvailableLibraries` lists only
 * these two - Xcode errors on a slice the plist promises but the bundle lacks.
 */
export const CRISPASR_IOS_SLICES = [
  "ios-arm64",
  "ios-arm64_x86_64-simulator",
] as const;

/**
 * The framework ships `crispasr.h`, `ggml*.h` and `gguf.h` in `Headers/`, but
 * not `cohere.h`, which declares the Cohere2 ASR entry points hviske needs. It
 * is fetched from the same tag so the header and the binary cannot disagree.
 */
export const CRISPASR_COHERE_HEADER = "cohere.h";

export const CRISPASR_COHERE_HEADER_URL = `https://raw.githubusercontent.com/CrispStrobe/CrispASR/${CRISPASR_VERSION}/src/${CRISPASR_COHERE_HEADER}`;

// -- vendors/ layout, relative to the project root ---------------------------
//
// `vendors/` is gitignored: it is a fetched artifact, never committed.

export const CRISPASR_VENDOR_DIR = "vendors/crispasr";

export const CRISPASR_VENDOR_XCFRAMEWORK = `${CRISPASR_VENDOR_DIR}/${CRISPASR_XCFRAMEWORK_NAME}`;

export const CRISPASR_VENDOR_INCLUDE_DIR = `${CRISPASR_VENDOR_DIR}/include`;

/** Written last by the fetch script, so an interrupted run re-downloads. */
export const CRISPASR_VENDOR_VERSION_STAMP = `${CRISPASR_VENDOR_DIR}/.version`;

// llama.cpp is a separate dynamic framework from crispasr. Both export ggml,
// but Mach-O's two-level namespace keeps each framework's internal references
// bound to its own image; S1-mini uses llama while ASR stays on crispasr.
// b9999 is intentionally pinned instead of the newer b10470 used by the CLI
// smoke harness: b10470's official xcframework dropped the iOS Simulator
// slice, while Codictate and crispasr support both device and Simulator.
export const LLAMA_VERSION = "b9999";
export const LLAMA_XCFRAMEWORK_ARCHIVE: VendorArchive = {
  asset: `llama-${LLAMA_VERSION}-xcframework.zip`,
  sha256: "edc986f1e646d69fc331074a57b909082e9172c0bb09eef06ade6afdf4496c5a",
};
export const LLAMA_RELEASE_BASE = `https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_VERSION}`;
export const LLAMA_XCFRAMEWORK_NAME = "llama.xcframework";
export const LLAMA_IOS_SLICES = [
  "ios-arm64",
  "ios-arm64_x86_64-simulator",
] as const;
export const LLAMA_VENDOR_DIR = "vendors/llama";
export const LLAMA_VENDOR_XCFRAMEWORK = `${LLAMA_VENDOR_DIR}/${LLAMA_XCFRAMEWORK_NAME}`;
export const LLAMA_VENDOR_VERSION_STAMP = `${LLAMA_VENDOR_DIR}/.version`;

// parakeet.cpp runs the Danish ekko Speech Model. Upstream publishes no iOS
// artifact, so scripts/build-parakeet-xcframework.sh builds a dynamic
// xcframework from the pinned tag and the zip lives on a vendor-scoped
// prerelease of this repo. ggml is linked in privately: the framework exports
// only `parakeet_capi_*`, so it cannot bind to crispasr's or llama's ggml.
// To bump: change the tag and commit in the build script, run it, upload the
// zip to a new `vendor-parakeet.cpp-<tag>` prerelease, then update these pins.
export const PARAKEET_VERSION = "v0.6.1";
export const PARAKEET_RELEASE_BASE = `https://github.com/EmilLykke/codictate-app/releases/download/vendor-parakeet.cpp-${PARAKEET_VERSION}`;
export const PARAKEET_XCFRAMEWORK_ARCHIVE: VendorArchive = {
  asset: `parakeet-${PARAKEET_VERSION}-ios-xcframework.zip`,
  sha256: "b49d3f323a7b5a81e3fc1718766486093c78c60635bbcba6c7969cf3789d30f9",
};
export const PARAKEET_XCFRAMEWORK_NAME = "parakeet.xcframework";
export const PARAKEET_IOS_SLICES = [
  "ios-arm64",
  "ios-arm64_x86_64-simulator",
] as const;
export const PARAKEET_VENDOR_DIR = "vendors/parakeet";
export const PARAKEET_VENDOR_XCFRAMEWORK = `${PARAKEET_VENDOR_DIR}/${PARAKEET_XCFRAMEWORK_NAME}`;
export const PARAKEET_VENDOR_VERSION_STAMP = `${PARAKEET_VENDOR_DIR}/.version`;
/**
 * The asset is our own build, so a rebuild could replace it under the same tag.
 * Stamping the digest as well as the tag makes a re-pin refetch.
 */
export const PARAKEET_STAMP = `${PARAKEET_VERSION} ${PARAKEET_XCFRAMEWORK_ARCHIVE.sha256}`;

// ONNX Runtime runs the ekko-pnc Punctuation Model, CPU execution provider
// only. 1.30.0 matches desktop's onnxruntime-node. This is Microsoft's prebuilt
// CocoaPods archive; its xcframework is a *static* framework, so it is linked
// into the app binary and never embedded.
//
// Microsoft publishes no checksum for the 1.30.0 pod archive: the SPM
// Package.swift (microsoft/onnxruntime-swift-package-manager) stops at 1.24.2,
// whose pinned checksum f7100a99...0b54 does match download.onnxruntime.ai. This
// sha256 was taken from download.onnxruntime.ai on 2026-10-30 and pins that
// download from here on.
export const ONNXRUNTIME_VERSION = "1.30.0";
export const ONNXRUNTIME_ARCHIVE_URL = `https://download.onnxruntime.ai/pod-archive-onnxruntime-c-${ONNXRUNTIME_VERSION}.zip`;
export const ONNXRUNTIME_ARCHIVE_SHA256 =
  "e6f1670c14406fd9f082bb400ab197a9b0a9646058ca6366e440642e2b54a2ea";
export const ONNXRUNTIME_XCFRAMEWORK_NAME = "onnxruntime.xcframework";
/** The archive also has `macos-arm64_x86_64`, which the fetch drops. */
export const ONNXRUNTIME_IOS_SLICES = [
  "ios-arm64",
  "ios-arm64_x86_64-simulator",
] as const;
/** System frameworks the onnxruntime-c podspec declares for iOS. */
export const ONNXRUNTIME_SYSTEM_FRAMEWORKS = [
  "CoreFoundation",
  "Foundation",
  "Network",
  "Security",
  "SystemConfiguration",
  "UIKit",
] as const;
export const ONNXRUNTIME_VENDOR_DIR = "vendors/onnxruntime";
export const ONNXRUNTIME_VENDOR_XCFRAMEWORK = `${ONNXRUNTIME_VENDOR_DIR}/${ONNXRUNTIME_XCFRAMEWORK_NAME}`;
export const ONNXRUNTIME_VENDOR_VERSION_STAMP = `${ONNXRUNTIME_VENDOR_DIR}/.version`;
