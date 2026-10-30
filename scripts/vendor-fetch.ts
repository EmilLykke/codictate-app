/// <reference types="node" />

// Shared steps of the xcframework fetch scripts that came after crispasr and
// llama: fetch-parakeet.ts and fetch-onnxruntime.ts. Each one downloads a
// pinned zip, checks its sha256, keeps the iOS slices and stamps the result.

import { execFileSync } from "node:child_process";
import * as crypto from "node:crypto";
import { once } from "node:events";
import * as fs from "node:fs";
import * as path from "node:path";

/** Every part a stamp promises. A missing piece means the stamp is a lie. */
export function stampIsCurrent(
  stampPath: string,
  stamp: string,
  xcframeworkDir: string,
  frameworkName: string,
  slices: readonly string[],
): boolean {
  if (!fs.existsSync(stampPath)) return false;
  if (fs.readFileSync(stampPath, "utf8").trim() !== stamp) return false;
  if (!fs.existsSync(path.join(xcframeworkDir, "Info.plist"))) return false;
  return slices.every((slice) =>
    fs.existsSync(
      path.join(
        xcframeworkDir,
        slice,
        `${frameworkName}.framework`,
        frameworkName,
      ),
    ),
  );
}

/**
 * Streams to disk while hashing. A digest mismatch deletes the file and throws:
 * an unverified runtime must never reach the build.
 */
export async function downloadVerified(
  log: string,
  url: string,
  sha256: string,
  dest: string,
): Promise<void> {
  console.log(`${log} downloading ${url}`);
  const response = await fetch(url);
  if (!response.ok || !response.body) {
    throw new Error(
      `${log} download failed: HTTP ${response.status} for ${url}`,
    );
  }
  const hash = crypto.createHash("sha256");
  const out = fs.createWriteStream(dest);
  const reader = response.body.getReader();
  let received = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    hash.update(value);
    received += value.byteLength;
    if (!out.write(value)) await once(out, "drain");
  }
  out.end();
  await once(out, "finish");

  const digest = hash.digest("hex");
  if (digest !== sha256) {
    fs.rmSync(dest, { force: true });
    throw new Error(
      `${log} sha256 mismatch for ${url}\n` +
        `  expected ${sha256}\n` +
        `  actual   ${digest}\n` +
        `The pinned asset changed or the download is corrupt. Do not build against it.`,
    );
  }
  console.log(
    `${log} sha256 verified (${(received / 1024 / 1024).toFixed(1)} MiB)`,
  );
}

/**
 * Extracts the xcframework's Info.plist and the named slices' frameworks,
 * nothing else, then moves the result to `xcframeworkDir`. Returns the archive
 * path prefix the xcframework sat under, for pulling sibling files.
 */
export function extractSlices(
  log: string,
  zipPath: string,
  stageDir: string,
  frameworkName: string,
  slices: readonly string[],
  xcframeworkDir: string,
): string {
  const marker = `${frameworkName}.xcframework/`;
  const listing = execFileSync("unzip", ["-Z1", zipPath], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  const entry = listing.split("\n").find((line) => line.includes(marker));
  if (!entry) {
    throw new Error(
      `${log} ${frameworkName}.xcframework not found in ${path.basename(zipPath)}`,
    );
  }
  const prefix = entry.slice(0, entry.indexOf(marker));
  const base = `${prefix}${frameworkName}.xcframework`;

  console.log(`${log} extracting ${slices.join(", ")}`);
  execFileSync(
    "unzip",
    [
      "-q",
      "-o",
      zipPath,
      `${base}/Info.plist`,
      ...slices.map((slice) => `${base}/${slice}/${frameworkName}.framework/*`),
      "-d",
      stageDir,
    ],
    { stdio: "inherit" },
  );

  const staged = path.join(stageDir, base);
  for (const slice of slices) {
    if (
      !fs.existsSync(path.join(staged, slice, `${frameworkName}.framework`))
    ) {
      throw new Error(`${log} archive is missing the ${slice} slice`);
    }
  }
  fs.rmSync(xcframeworkDir, { recursive: true, force: true });
  fs.mkdirSync(path.dirname(xcframeworkDir), { recursive: true });
  fs.cpSync(staged, xcframeworkDir, {
    recursive: true,
    verbatimSymlinks: true,
  });
  return prefix;
}

/**
 * Drops undeclared slices from `AvailableLibraries`. Xcode reads the plist, not
 * the directory listing, and errors on a `LibraryIdentifier` whose folder is
 * absent.
 */
export function pruneInfoPlist(
  log: string,
  xcframeworkDir: string,
  slices: readonly string[],
): void {
  const plistPath = path.join(xcframeworkDir, "Info.plist");
  const raw = execFileSync(
    "plutil",
    ["-convert", "json", "-o", "-", plistPath],
    { encoding: "utf8" },
  );
  const libraries = (JSON.parse(raw).AvailableLibraries ?? []) as {
    LibraryIdentifier?: string;
  }[];
  const kept = new Set<string>(slices);
  for (const slice of slices) {
    if (!libraries.some((lib) => lib.LibraryIdentifier === slice)) {
      throw new Error(`${log} Info.plist does not declare the ${slice} slice`);
    }
  }
  libraries
    .map((lib, index) => ({ index, id: lib.LibraryIdentifier ?? "" }))
    .filter((lib) => !kept.has(lib.id))
    .reverse()
    .forEach((lib) =>
      execFileSync("plutil", [
        "-remove",
        `AvailableLibraries.${lib.index}`,
        plistPath,
      ]),
    );
}
