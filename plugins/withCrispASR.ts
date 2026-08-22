/// <reference types="node" />

/**
 * Expo config plugin: withCrispASR
 *
 * Vendors the pinned crispasr xcframework into the generated ios/ tree and
 * links it into the main app target. crispasr is the iOS ASR Harness: it
 * carries both the whisper API `WhisperBridge.mm` already calls and the cohere
 * backend the Danish hviske weights need. See
 * docs/adr/0001-crispasr-as-the-ios-asr-harness.md.
 *
 * During prebuild this plugin:
 *  1. Copies vendors/crispasr/crispasr.xcframework into ios/vendor/.
 *  2. Copies vendors/crispasr/include/cohere.h next to the other main-app
 *     sources in ios/<ProjectName>/, so `#import "cohere.h"` resolves.
 *  3. Links and embeds the xcframework in the *main app target only*, with
 *     Code Sign On Copy, because it is a dynamic framework.
 *  4. Appends the framework/header search paths to the main app target.
 *
 * It never downloads anything: `bun run fetch-crispasr` owns that, and this
 * plugin fails loudly when the fetch has not run. All Xcode edits live here;
 * do not hand-edit ios/*.xcodeproj.
 *
 * Ordering note: Expo runs mods in reverse registration order, so this plugin
 * is applied *innermost* in app.config.ts to make its Xcode mod run last. That
 * matters because withKeyboardExtension replaces HEADER_SEARCH_PATHS and
 * FRAMEWORK_SEARCH_PATHS on the app target wholesale on every prebuild; this
 * plugin appends to whatever it left behind.
 */

import {
  ConfigPlugin,
  withDangerousMod,
  withXcodeProject,
} from "expo/config-plugins";
import * as path from "path";
import * as fs from "fs";

import {
  CRISPASR_COHERE_HEADER,
  CRISPASR_IOS_SLICES,
  CRISPASR_VENDOR_INCLUDE_DIR,
  CRISPASR_VENDOR_XCFRAMEWORK,
  CRISPASR_VERSION,
  CRISPASR_XCFRAMEWORK_NAME,
} from "../scripts/vendor-manifest";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/** Folder inside ios/ that holds vendored binary artifacts. Relative to SRCROOT. */
const IOS_VENDOR_DIR = "vendor";

/** Path stored in PBXFileReference, i.e. relative to ios/. */
const XCFRAMEWORK_PROJECT_PATH = `${IOS_VENDOR_DIR}/${CRISPASR_XCFRAMEWORK_NAME}`;

/** Guards the copy so a version bump cannot leave a stale framework in ios/. */
const IOS_VERSION_STAMP = `${IOS_VENDOR_DIR}/.crispasr-version`;

const MISSING_VENDOR_HINT =
  `[withCrispASR] ${CRISPASR_VENDOR_XCFRAMEWORK} not found.\n` +
  `Run \`bun run fetch-crispasr\` first (the prebuild scripts chain it, and EAS runs it ` +
  `from eas-build-post-install). This plugin never downloads; a ~500 MB fetch does not ` +
  `belong inside a config plugin.`;

function unquote(value: string | undefined): string {
  return (value ?? "").replace(/^"|"$/g, "");
}

// node-xcode's `pbxFile` derives the file type, group and source tree for a
// path. Same require dance withKeyboardExtension uses.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const PbxFile = require("xcode/lib/pbxFile") as new (
  filepath: string,
  opt?: Record<string, unknown>,
) => {
  path: string;
  group: string;
  uuid?: string;
  fileRef?: string;
  target?: string;
};

// ---------------------------------------------------------------------------
// Xcode helpers
// ---------------------------------------------------------------------------

/**
 * Build configuration UUIDs belonging to one target. Matching on PRODUCT_NAME
 * (what node-xcode's own search-path helpers do) would also catch the
 * project-level configurations, so walk the target's configuration list.
 */
function buildConfigUuidsForTarget(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
  targetName: string,
): string[] {
  const target = project.pbxTargetByName(targetName);
  const listUuid = target?.buildConfigurationList;
  if (!listUuid) return [];

  const lists = project.pbxXCConfigurationList() ?? {};
  const list = lists[listUuid] as
    | { buildConfigurations?: { value: string }[] }
    | undefined;
  return (list?.buildConfigurations ?? []).map((entry) => entry.value);
}

/**
 * Appends to a list-valued build setting instead of replacing it. The app
 * target's search paths are rewritten by withKeyboardExtension on every
 * prebuild, and clobbering them back would drop the Pods entries that
 * withKeyboardExtension and the autolinked pods put there.
 */
function appendBuildSettingList(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
  targetName: string,
  property: string,
  values: string[],
): void {
  const configUuids = new Set(buildConfigUuidsForTarget(project, targetName));
  if (configUuids.size === 0) {
    console.warn(
      `[withCrispASR] No build configurations found for target ${targetName}; skipped ${property}.`,
    );
    return;
  }

  const configs = project.pbxXCBuildConfigurationSection() ?? {};
  for (const key of Object.keys(configs)) {
    if (key.endsWith("_comment")) continue;
    if (!configUuids.has(key)) continue;

    const config = configs[key];
    if (typeof config !== "object" || !config?.buildSettings) continue;
    const settings = config.buildSettings as Record<string, unknown>;

    const current = settings[property];
    const list: string[] = Array.isArray(current)
      ? [...(current as string[])]
      : typeof current === "string" && current.length > 0
        ? [current]
        : ['"$(inherited)"'];

    for (const value of values) {
      if (!list.includes(value)) list.push(value);
    }
    settings[property] = list;
  }
}

/**
 * PBXCopyFilesBuildPhase with dstSubfolderSpec 10 (Frameworks). Expo generates
 * an "Embed Foundation Extensions" phase but no Embed Frameworks phase, and
 * node-xcode's `addFramework({ embed: true })` silently drops the embed when
 * the phase is missing.
 */
function ensureEmbedFrameworksPhase(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
  targetUuid: string,
): void {
  if (project.pbxEmbedFrameworksBuildPhaseObj(targetUuid)) return;
  project.addBuildPhase(
    [],
    "PBXCopyFilesBuildPhase",
    "Embed Frameworks",
    targetUuid,
    "frameworks",
  );
}

/**
 * Links the xcframework into the app target's Frameworks phase and embeds a
 * signed copy.
 *
 * This is node-xcode's own `addFramework({ customFramework: true, embed: true })`
 * with one call left out: `addToFrameworkSearchPaths`, which matches build
 * configurations on `PRODUCT_NAME` against a `productName` the library never
 * sets, so it lands a bogus relative `"vendor"` search path on every target
 * whose PRODUCT_NAME is `$(TARGET_NAME)` - the widget extension included. The
 * search paths are set deliberately further down instead.
 *
 * Returns false when the framework is already referenced, i.e. on a repeat
 * prebuild that did not clean ios/.
 */
function linkAndEmbedXcframework(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
  targetUuid: string,
): boolean {
  const options = {
    customFramework: true,
    lastKnownFileType: "wrapper.xcframework",
    target: targetUuid,
  };

  const linked = new PbxFile(XCFRAMEWORK_PROJECT_PATH, options);
  if (project.hasFile(linked.path)) return false;

  linked.uuid = project.generateUuid();
  linked.fileRef = project.generateUuid();
  linked.target = targetUuid;
  // Without this the PBXBuildFile comment reads "in Resources": pbxFile has no
  // group mapping for wrapper.xcframework and falls back to the default.
  linked.group = "Frameworks";

  project.addToPbxBuildFileSection(linked);
  project.addToPbxFileReferenceSection(linked);
  project.addToFrameworksPbxGroup(linked);
  project.addToPbxFrameworksBuildPhase(linked);

  // A separate PBXBuildFile row, sharing the file reference, carries the
  // CodeSignOnCopy attribute for the Embed Frameworks phase.
  const embedded = new PbxFile(XCFRAMEWORK_PROJECT_PATH, {
    ...options,
    embed: true,
    sign: true,
  });
  embedded.uuid = project.generateUuid();
  embedded.fileRef = linked.fileRef;
  embedded.target = targetUuid;

  project.addToPbxBuildFileSection(embedded);
  project.addToPbxEmbedFrameworksBuildPhase(embedded);

  return true;
}

// ---------------------------------------------------------------------------
// Plugin entry point
// ---------------------------------------------------------------------------

const withCrispASR: ConfigPlugin = (config) => {
  // Step 1: copy the fetched artifacts into ios/ during prebuild.
  config = withDangerousMod(config, [
    "ios",
    (c) => {
      const vendorSrc = path.join(
        c.modRequest.projectRoot,
        CRISPASR_VENDOR_XCFRAMEWORK,
      );
      if (!fs.existsSync(vendorSrc)) {
        throw new Error(MISSING_VENDOR_HINT);
      }

      const headerSrc = path.join(
        c.modRequest.projectRoot,
        CRISPASR_VENDOR_INCLUDE_DIR,
        CRISPASR_COHERE_HEADER,
      );
      if (!fs.existsSync(headerSrc)) {
        throw new Error(
          `[withCrispASR] ${CRISPASR_VENDOR_INCLUDE_DIR}/${CRISPASR_COHERE_HEADER} not found.\n` +
            `Delete vendors/crispasr/.version and run \`bun run fetch-crispasr\` again.`,
        );
      }

      const vendorDest = path.join(
        c.modRequest.platformProjectRoot,
        XCFRAMEWORK_PROJECT_PATH,
      );
      const stampPath = path.join(
        c.modRequest.platformProjectRoot,
        IOS_VERSION_STAMP,
      );
      const stamped =
        fs.existsSync(stampPath) &&
        fs.readFileSync(stampPath, "utf8").trim() === CRISPASR_VERSION;

      if (stamped && fs.existsSync(vendorDest)) {
        console.log(
          `[withCrispASR] ios/${XCFRAMEWORK_PROJECT_PATH} already at ${CRISPASR_VERSION}`,
        );
      } else {
        fs.rmSync(vendorDest, { recursive: true, force: true });
        fs.mkdirSync(path.dirname(vendorDest), { recursive: true });
        fs.cpSync(vendorSrc, vendorDest, { recursive: true });
        fs.writeFileSync(stampPath, `${CRISPASR_VERSION}\n`, "utf8");
        console.log(
          `[withCrispASR] Copied ${CRISPASR_XCFRAMEWORK_NAME} (${CRISPASR_VERSION}) to ios/${IOS_VENDOR_DIR}/`,
        );
      }

      // cohere.h lands beside the main app's other sources rather than being
      // referenced out of vendors/, so the Xcode project stays self-contained.
      // Headers need no build phase entry, only a search path (step 2).
      const iosProjectName = c.modRequest.projectName ?? "Codictate";
      const hostDestDir = path.join(
        c.modRequest.platformProjectRoot,
        iosProjectName,
      );
      fs.mkdirSync(hostDestDir, { recursive: true });
      fs.copyFileSync(
        headerSrc,
        path.join(hostDestDir, CRISPASR_COHERE_HEADER),
      );
      console.log(
        `[withCrispASR] Copied ${CRISPASR_COHERE_HEADER} to ios/${iosProjectName}/`,
      );

      return c;
    },
  ]);

  // Step 2: link, embed and expose headers on the main app target only.
  // Never the keyboard extension and never the widget: both are memory-capped
  // extensions that do not run ASR, and embedding a dynamic framework in them
  // would only inflate the bundle.
  config = withXcodeProject(config, (c) => {
    const project = c.modResults;

    const appTarget = project.getTarget("com.apple.product-type.application");
    if (!appTarget?.uuid || !appTarget.target?.name) {
      console.warn(
        "[withCrispASR] Main app target not found; skipped crispasr linking.",
      );
      return c;
    }
    const appUuid: string = appTarget.uuid;
    const appTargetName = unquote(appTarget.target.name);

    ensureEmbedFrameworksPhase(project, appUuid);

    // The search paths below are reapplied whether or not the framework was
    // already referenced, because withKeyboardExtension resets them every run.
    const added = linkAndEmbedXcframework(project, appUuid);
    console.log(
      added
        ? `[withCrispASR] Linked and embedded ${CRISPASR_XCFRAMEWORK_NAME} in ${appTargetName}`
        : `[withCrispASR] ${CRISPASR_XCFRAMEWORK_NAME} already linked in ${appTargetName}`,
    );

    appendBuildSettingList(project, appTargetName, "FRAMEWORK_SEARCH_PATHS", [
      `"$(SRCROOT)/${IOS_VENDOR_DIR}"`,
    ]);

    // Both slices' Headers/ plus the app's own source folder for cohere.h.
    // This is what makes the quoted `#import "crispasr.h"` in WhisperBridge.mm
    // and `#import "cohere.h"` in CohereBridge.mm resolve.
    appendBuildSettingList(project, appTargetName, "HEADER_SEARCH_PATHS", [
      ...CRISPASR_IOS_SLICES.map(
        (slice) =>
          `"$(SRCROOT)/${XCFRAMEWORK_PROJECT_PATH}/${slice}/crispasr.framework/Headers"`,
      ),
      `"$(SRCROOT)/${appTargetName}"`,
    ]);

    // LD_RUNPATH_SEARCH_PATHS already carries @executable_path/Frameworks on
    // the Expo-generated app target, which is all an embedded dynamic
    // framework needs, so it is deliberately left alone.

    return c;
  });

  return config;
};

export default withCrispASR;
