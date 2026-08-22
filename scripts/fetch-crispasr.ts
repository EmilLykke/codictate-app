/// <reference types="node" />

/**
 * Fetch the pinned CrispASR xcframework into `vendors/crispasr/`.
 *
 * Run before `expo prebuild` (the `prebuild` scripts chain it) and by EAS via
 * `eas-build-post-install`. `plugins/withCrispASR.ts` refuses to run without
 * the result; it never downloads anything itself, so a build machine with no
 * network fails here with one clear message instead of half-configuring Xcode.
 *
 * The release asset is ~500 MB of seven platform slices plus a dSYM each. Only
 * the two iOS slices are extracted, so `vendors/` ends up around 50 MB. The
 * archive itself is verified against the sha256 pinned in `vendor-manifest.ts`
 * and deleted afterwards.
 */

import { execFileSync } from "node:child_process";
import * as crypto from "node:crypto";
import { once } from "node:events";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

import {
  CRISPASR_COHERE_HEADER,
  CRISPASR_COHERE_HEADER_URL,
  CRISPASR_IOS_SLICES,
  CRISPASR_RELEASE_BASE,
  CRISPASR_VENDOR_DIR,
  CRISPASR_VENDOR_INCLUDE_DIR,
  CRISPASR_VENDOR_VERSION_STAMP,
  CRISPASR_VENDOR_XCFRAMEWORK,
  CRISPASR_VERSION,
  CRISPASR_XCFRAMEWORK_ARCHIVE,
  CRISPASR_XCFRAMEWORK_NAME,
} from "./vendor-manifest";

const LOG = "[fetch-crispasr]";

const PROJECT_ROOT = path.resolve(__dirname, "..");
const VENDOR_DIR = path.join(PROJECT_ROOT, CRISPASR_VENDOR_DIR);
const XCFRAMEWORK_DIR = path.join(PROJECT_ROOT, CRISPASR_VENDOR_XCFRAMEWORK);
const INCLUDE_DIR = path.join(PROJECT_ROOT, CRISPASR_VENDOR_INCLUDE_DIR);
const HEADER_PATH = path.join(INCLUDE_DIR, CRISPASR_COHERE_HEADER);
const STAMP_PATH = path.join(PROJECT_ROOT, CRISPASR_VENDOR_VERSION_STAMP);

const ARCHIVE_URL = `${CRISPASR_RELEASE_BASE}/${CRISPASR_XCFRAMEWORK_ARCHIVE.asset}`;

/** Every part the stamp promises. A missing piece means the stamp is a lie. */
function isUpToDate(): boolean {
  if (!fs.existsSync(STAMP_PATH)) return false;
  if (fs.readFileSync(STAMP_PATH, "utf8").trim() !== CRISPASR_VERSION) {
    return false;
  }
  if (!fs.existsSync(path.join(XCFRAMEWORK_DIR, "Info.plist"))) return false;
  if (!fs.existsSync(HEADER_PATH)) return false;
  return CRISPASR_IOS_SLICES.every((slice) =>
    fs.existsSync(path.join(XCFRAMEWORK_DIR, slice, "crispasr.framework")),
  );
}

function formatMiB(bytes: number): string {
  return `${(bytes / 1024 / 1024).toFixed(1)} MiB`;
}

/**
 * Streams to disk while hashing, so a 500 MB archive never sits in memory. A
 * digest mismatch deletes the file and exits non-zero: a half-right ASR runtime
 * is worse than no runtime.
 */
async function downloadAndVerify(url: string, dest: string): Promise<void> {
  console.log(`${LOG} downloading ${url}`);
  const response = await fetch(url);
  if (!response.ok || !response.body) {
    throw new Error(
      `${LOG} download failed: HTTP ${response.status} for ${url}`,
    );
  }

  const total = Number(response.headers.get("content-length") ?? 0);
  const hash = crypto.createHash("sha256");
  const out = fs.createWriteStream(dest);
  const reader = response.body.getReader();
  let received = 0;
  let nextReport = 0;

  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    hash.update(value);
    received += value.byteLength;
    if (!out.write(value)) await once(out, "drain");
    if (received >= nextReport) {
      const pct = total ? ` (${Math.floor((received / total) * 100)}%)` : "";
      console.log(`${LOG}   ${formatMiB(received)}${pct}`);
      nextReport = received + 50 * 1024 * 1024;
    }
  }
  out.end();
  await once(out, "finish");

  const digest = hash.digest("hex");
  if (digest !== CRISPASR_XCFRAMEWORK_ARCHIVE.sha256) {
    fs.rmSync(dest, { force: true });
    throw new Error(
      `${LOG} sha256 mismatch for ${CRISPASR_XCFRAMEWORK_ARCHIVE.asset}\n` +
        `  expected ${CRISPASR_XCFRAMEWORK_ARCHIVE.sha256}\n` +
        `  actual   ${digest}\n` +
        `The pinned release asset changed or the download is corrupt. Do not build against it.`,
    );
  }
  console.log(`${LOG} sha256 verified (${formatMiB(received)})`);
}

/** Path prefix the xcframework sits under inside the archive, "" when at the root. */
function findArchiveRoot(zipPath: string): string {
  const marker = `${CRISPASR_XCFRAMEWORK_NAME}/`;
  const listing = execFileSync("unzip", ["-Z1", zipPath], {
    encoding: "utf8",
    maxBuffer: 256 * 1024 * 1024,
  });
  for (const entry of listing.split("\n")) {
    const at = entry.indexOf(marker);
    if (at >= 0) return entry.slice(0, at);
  }
  throw new Error(
    `${LOG} ${CRISPASR_XCFRAMEWORK_NAME} not found inside ${path.basename(zipPath)}`,
  );
}

/**
 * Extracts the two iOS slices and the top-level `Info.plist`, nothing else.
 * Restricting to `<slice>/crispasr.framework/*` also drops the dSYMs, which sit
 * beside the framework rather than inside it.
 */
function extractIosSlices(zipPath: string, stageDir: string): void {
  const root = findArchiveRoot(zipPath);
  const base = `${root}${CRISPASR_XCFRAMEWORK_NAME}`;
  const patterns = [
    `${base}/Info.plist`,
    ...CRISPASR_IOS_SLICES.map(
      (slice) => `${base}/${slice}/crispasr.framework/*`,
    ),
  ];

  console.log(`${LOG} extracting ${CRISPASR_IOS_SLICES.join(", ")}`);
  execFileSync("unzip", ["-q", "-o", zipPath, ...patterns, "-d", stageDir], {
    stdio: "inherit",
  });

  const staged = path.join(stageDir, base);
  for (const slice of CRISPASR_IOS_SLICES) {
    const framework = path.join(staged, slice, "crispasr.framework");
    if (!fs.existsSync(framework)) {
      throw new Error(`${LOG} archive is missing the ${slice} slice`);
    }
  }

  fs.rmSync(XCFRAMEWORK_DIR, { recursive: true, force: true });
  fs.mkdirSync(path.dirname(XCFRAMEWORK_DIR), { recursive: true });
  fs.cpSync(staged, XCFRAMEWORK_DIR, { recursive: true });
}

/**
 * Drops the five discarded slices from `AvailableLibraries`. Xcode reads the
 * plist, not the directory listing, and errors out on a `LibraryIdentifier`
 * whose folder is absent.
 */
function pruneInfoPlist(): void {
  const plistPath = path.join(XCFRAMEWORK_DIR, "Info.plist");
  const raw = execFileSync(
    "plutil",
    ["-convert", "json", "-o", "-", plistPath],
    {
      encoding: "utf8",
    },
  );
  const libraries = (JSON.parse(raw).AvailableLibraries ?? []) as {
    LibraryIdentifier?: string;
  }[];

  const kept = new Set<string>(CRISPASR_IOS_SLICES);
  for (const slice of CRISPASR_IOS_SLICES) {
    const listed = libraries.some((lib) => lib.LibraryIdentifier === slice);
    if (!listed) {
      throw new Error(`${LOG} Info.plist does not declare the ${slice} slice`);
    }
  }

  // Descending, so each removal cannot shift an index still to be removed.
  const doomed = libraries
    .map((lib, index) => ({ index, id: lib.LibraryIdentifier ?? "" }))
    .filter((entry) => !kept.has(entry.id))
    .reverse();

  for (const entry of doomed) {
    execFileSync("plutil", [
      "-remove",
      `AvailableLibraries.${entry.index}`,
      plistPath,
    ]);
  }

  // The kept slices still advertise a dSYMs folder we deliberately did not
  // extract. Drop the key rather than leave the plist pointing at nothing.
  const remaining = libraries.length - doomed.length;
  for (let index = 0; index < remaining; index += 1) {
    try {
      execFileSync(
        "plutil",
        ["-remove", `AvailableLibraries.${index}.DebugSymbolsPath`, plistPath],
        { stdio: "pipe" },
      );
    } catch {
      /* slice declared no dSYMs path */
    }
  }

  console.log(
    `${LOG} Info.plist now lists ${remaining} of ${libraries.length} slices`,
  );
}

/** `cohere.h` is not in the framework's Headers/, so it comes from the tag. */
async function fetchCohereHeader(): Promise<void> {
  console.log(`${LOG} downloading ${CRISPASR_COHERE_HEADER_URL}`);
  const response = await fetch(CRISPASR_COHERE_HEADER_URL);
  if (!response.ok) {
    throw new Error(
      `${LOG} ${CRISPASR_COHERE_HEADER} download failed: HTTP ${response.status}`,
    );
  }
  const source = await response.text();
  if (!source.includes("cohere_transcribe")) {
    throw new Error(
      `${LOG} ${CRISPASR_COHERE_HEADER} does not declare cohere_transcribe; refusing to write it`,
    );
  }
  fs.mkdirSync(INCLUDE_DIR, { recursive: true });
  fs.writeFileSync(HEADER_PATH, source, "utf8");
}

async function main(): Promise<void> {
  if (isUpToDate()) {
    console.log(
      `${LOG} crispasr ${CRISPASR_VERSION} already present in ${CRISPASR_VENDOR_DIR}/`,
    );
    return;
  }

  fs.mkdirSync(VENDOR_DIR, { recursive: true });
  // Clear the stamp first: an interrupted run must not look complete.
  fs.rmSync(STAMP_PATH, { force: true });

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "crispasr-"));
  const zipPath = path.join(tmpDir, CRISPASR_XCFRAMEWORK_ARCHIVE.asset);
  try {
    await downloadAndVerify(ARCHIVE_URL, zipPath);
    extractIosSlices(zipPath, path.join(tmpDir, "extract"));
    pruneInfoPlist();
    await fetchCohereHeader();
    fs.writeFileSync(STAMP_PATH, `${CRISPASR_VERSION}\n`, "utf8");
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }

  const size = execFileSync("du", ["-sh", VENDOR_DIR], { encoding: "utf8" })
    .split("\t")[0]
    .trim();
  console.log(
    `${LOG} crispasr ${CRISPASR_VERSION} ready in ${CRISPASR_VENDOR_DIR}/ (${size})`,
  );
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
