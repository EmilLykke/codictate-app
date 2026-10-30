/// <reference types="node" />

/**
 * Fetch the pinned parakeet.xcframework (ekko's ASR runtime) into
 * `vendors/parakeet/`.
 *
 * The zip is our own build of parakeet.cpp (scripts/build-parakeet-xcframework.sh),
 * published on a vendor-scoped prerelease of this repo and verified against the
 * sha256 pinned in `vendor-manifest.ts`. Run before `expo prebuild` (the
 * prebuild scripts chain it) and by EAS via `eas-build-post-install`;
 * `plugins/withParakeetCpp.ts` runs it too and relies on its fast path.
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import {
  PARAKEET_IOS_SLICES,
  PARAKEET_RELEASE_BASE,
  PARAKEET_STAMP,
  PARAKEET_VENDOR_DIR,
  PARAKEET_VENDOR_VERSION_STAMP,
  PARAKEET_VENDOR_XCFRAMEWORK,
  PARAKEET_VERSION,
  PARAKEET_XCFRAMEWORK_ARCHIVE,
} from "./vendor-manifest";
import {
  downloadVerified,
  extractSlices,
  pruneInfoPlist,
  stampIsCurrent,
} from "./vendor-fetch";

const LOG = "[fetch-parakeet]";

const root = path.resolve(__dirname, "..");
const vendor = path.join(root, PARAKEET_VENDOR_DIR);
const xcframework = path.join(root, PARAKEET_VENDOR_XCFRAMEWORK);
const stamp = path.join(root, PARAKEET_VENDOR_VERSION_STAMP);

async function main(): Promise<void> {
  if (
    stampIsCurrent(
      stamp,
      PARAKEET_STAMP,
      xcframework,
      "parakeet",
      PARAKEET_IOS_SLICES,
    )
  ) {
    console.log(
      `${LOG} parakeet.cpp ${PARAKEET_VERSION} already present in ${PARAKEET_VENDOR_DIR}/`,
    );
    return;
  }

  fs.mkdirSync(vendor, { recursive: true });
  // Clear the stamp first: an interrupted run must not look complete.
  fs.rmSync(stamp, { force: true });

  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "codictate-parakeet-"));
  try {
    const zip = path.join(temp, PARAKEET_XCFRAMEWORK_ARCHIVE.asset);
    await downloadVerified(
      LOG,
      `${PARAKEET_RELEASE_BASE}/${PARAKEET_XCFRAMEWORK_ARCHIVE.asset}`,
      PARAKEET_XCFRAMEWORK_ARCHIVE.sha256,
      zip,
    );
    extractSlices(
      LOG,
      zip,
      path.join(temp, "extract"),
      "parakeet",
      PARAKEET_IOS_SLICES,
      xcframework,
    );
    pruneInfoPlist(LOG, xcframework, PARAKEET_IOS_SLICES);
    fs.writeFileSync(stamp, `${PARAKEET_STAMP}\n`, "utf8");
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
  console.log(
    `${LOG} parakeet.cpp ${PARAKEET_VERSION} ready in ${PARAKEET_VENDOR_DIR}/`,
  );
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
