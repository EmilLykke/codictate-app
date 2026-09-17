/// <reference types="node" />

import { execFileSync } from "node:child_process";
import * as crypto from "node:crypto";
import { once } from "node:events";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  LLAMA_IOS_SLICES,
  LLAMA_RELEASE_BASE,
  LLAMA_VENDOR_DIR,
  LLAMA_VENDOR_VERSION_STAMP,
  LLAMA_VENDOR_XCFRAMEWORK,
  LLAMA_VERSION,
  LLAMA_XCFRAMEWORK_ARCHIVE,
  LLAMA_XCFRAMEWORK_NAME,
} from "./vendor-manifest";

const root = path.resolve(__dirname, "..");
const vendor = path.join(root, LLAMA_VENDOR_DIR);
const framework = path.join(root, LLAMA_VENDOR_XCFRAMEWORK);
const stamp = path.join(root, LLAMA_VENDOR_VERSION_STAMP);
const url = `${LLAMA_RELEASE_BASE}/${LLAMA_XCFRAMEWORK_ARCHIVE.asset}`;

function current(): boolean {
  return (
    fs.existsSync(stamp) &&
    fs.readFileSync(stamp, "utf8").trim() === LLAMA_VERSION &&
    fs.existsSync(path.join(framework, "Info.plist")) &&
    LLAMA_IOS_SLICES.every((slice) =>
      fs.existsSync(path.join(framework, slice, "llama.framework", "llama")),
    )
  );
}

async function download(destination: string): Promise<void> {
  const response = await fetch(url);
  if (!response.ok || !response.body)
    throw new Error(`HTTP ${response.status} for ${url}`);
  const hash = crypto.createHash("sha256");
  const output = fs.createWriteStream(destination);
  const reader = response.body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    hash.update(value);
    if (!output.write(value)) await once(output, "drain");
  }
  output.end();
  await once(output, "finish");
  const actual = hash.digest("hex");
  if (actual !== LLAMA_XCFRAMEWORK_ARCHIVE.sha256) {
    throw new Error(
      `sha256 mismatch for ${LLAMA_XCFRAMEWORK_ARCHIVE.asset}: ${actual}`,
    );
  }
}

function archiveRoot(zip: string): string {
  const marker = `${LLAMA_XCFRAMEWORK_NAME}/`;
  const listing = execFileSync("unzip", ["-Z1", zip], { encoding: "utf8" });
  const entry = listing.split("\n").find((line) => line.includes(marker));
  if (!entry) throw new Error(`${LLAMA_XCFRAMEWORK_NAME} missing from archive`);
  return entry.slice(0, entry.indexOf(marker));
}

function prunePlist(): void {
  const plist = path.join(framework, "Info.plist");
  const json = execFileSync("plutil", ["-convert", "json", "-o", "-", plist], {
    encoding: "utf8",
  });
  const libraries = JSON.parse(json).AvailableLibraries as Array<{
    LibraryIdentifier: string;
  }>;
  const keep = new Set<string>(LLAMA_IOS_SLICES);
  libraries
    .map((item, index) => ({ item, index }))
    .filter(({ item }) => !keep.has(item.LibraryIdentifier))
    .reverse()
    .forEach(({ index }) =>
      execFileSync("plutil", ["-remove", `AvailableLibraries.${index}`, plist]),
    );
  for (let index = 0; index < LLAMA_IOS_SLICES.length; index += 1) {
    try {
      execFileSync("plutil", [
        "-remove",
        `AvailableLibraries.${index}.DebugSymbolsPath`,
        plist,
      ]);
    } catch {
      /* absent */
    }
  }
}

async function main(): Promise<void> {
  if (current()) return;
  fs.mkdirSync(vendor, { recursive: true });
  fs.rmSync(stamp, { force: true });
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), "codictate-llama-"));
  try {
    const zip = path.join(temp, LLAMA_XCFRAMEWORK_ARCHIVE.asset);
    await download(zip);
    const prefix = archiveRoot(zip);
    const base = `${prefix}${LLAMA_XCFRAMEWORK_NAME}`;
    execFileSync("unzip", [
      "-q",
      "-o",
      zip,
      `${base}/Info.plist`,
      ...LLAMA_IOS_SLICES.map((slice) => `${base}/${slice}/llama.framework/*`),
      "-d",
      temp,
    ]);
    fs.rmSync(framework, { recursive: true, force: true });
    fs.cpSync(path.join(temp, base), framework, { recursive: true });
    prunePlist();
    fs.writeFileSync(stamp, `${LLAMA_VERSION}\n`);
  } finally {
    fs.rmSync(temp, { recursive: true, force: true });
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
