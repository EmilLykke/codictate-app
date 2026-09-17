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
