/// <reference types="node" />

/**
 * Fetch the pinned ONNX Runtime pod archive (ekko-pnc's runtime) into
 * `vendors/onnxruntime/`.
 *
 * The archive is ~64 MB and carries a macOS slice beside the two iOS slices;
 * only the iOS slices are extracted. It is verified against the sha256 pinned
 * in `vendor-manifest.ts` and deleted afterwards. Run before `expo prebuild`
 * (the prebuild scripts chain it) and by EAS via `eas-build-post-install`;
 * `plugins/withOnnxRuntime.ts` runs it too and relies on its fast path.
 */

import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import {
  ONNXRUNTIME_ARCHIVE_SHA256,
  ONNXRUNTIME_ARCHIVE_URL,
  ONNXRUNTIME_IOS_SLICES,
  ONNXRUNTIME_VENDOR_DIR,
  ONNXRUNTIME_VENDOR_VERSION_STAMP,
  ONNXRUNTIME_VENDOR_XCFRAMEWORK,
  ONNXRUNTIME_VERSION,
} from "./vendor-manifest";
import {
  downloadVerified,
  extractSlices,
  pruneInfoPlist,
  stampIsCurrent,
} from "./vendor-fetch";

const LOG = "[fetch-onnxruntime]";

const root = path.resolve(__dirname, "..");
const vendor = path.join(root, ONNXRUNTIME_VENDOR_DIR);
const xcframework = path.join(root, ONNXRUNTIME_VENDOR_XCFRAMEWORK);
const stamp = path.join(root, ONNXRUNTIME_VENDOR_VERSION_STAMP);

async function main(): Promise<void> {
  if (
    stampIsCurrent(
      stamp,
      ONNXRUNTIME_VERSION,
      xcframework,
      "onnxruntime",
      ONNXRUNTIME_IOS_SLICES,
    )
  ) {
    console.log(
      `${LOG} onnxruntime ${ONNXRUNTIME_VERSION} already present in ${ONNXRUNTIME_VENDOR_DIR}/`,
    );
    return;
  }

  fs.mkdirSync(vendor, { recursive: true });
  // Clear the stamp first: an interrupted run must not look complete.
  fs.rmSync(stamp, { force: true });

  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "codictate-ort-"));
  try {
    const zip = path.join(temp, path.basename(ONNXRUNTIME_ARCHIVE_URL));
    await downloadVerified(
      LOG,
      ONNXRUNTIME_ARCHIVE_URL,
      ONNXRUNTIME_ARCHIVE_SHA256,
      zip,
    );
    extractSlices(
      LOG,
      zip,
      path.join(temp, "extract"),
      "onnxruntime",
      ONNXRUNTIME_IOS_SLICES,
      xcframework,
    );
    pruneInfoPlist(LOG, xcframework, ONNXRUNTIME_IOS_SLICES);
    fs.writeFileSync(stamp, `${ONNXRUNTIME_VERSION}\n`, "utf8");
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
  console.log(
    `${LOG} onnxruntime ${ONNXRUNTIME_VERSION} ready in ${ONNXRUNTIME_VENDOR_DIR}/`,
  );
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
