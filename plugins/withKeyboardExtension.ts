/// <reference types="node" />

/**
 * Expo config plugin: withKeyboardExtension
 *
 * Adds the CodictateDictationKeyboard keyboard extension to the iOS project.
 *
 * During prebuild this plugin:
 *  1. Copies extension sources from targets/CodictateDictationKeyboard/ to ios/.
 *  2. Copies the Obj-C++ bridge headers (WhisperBridge.h, CohereBridge.h, EkkoBridge.h, ...) into ios/codictateapp/ and patches codictateapp-Bridging-Header.h.
 *  3. Copies other targets/codictateapp/*.swift into ios/codictateapp/ (not KeyboardHostRecorder; see 4).
 *  4. Injects targets/codictateapp/KeyboardHostRecorder.swift into AppDelegate.swift (app target).
 *  5. Patches AppDelegate (bootstrap on every launch, codictateapp://keyboard-record and
 *     keyboard-session, background URLSession events for Speech Model downloads) and
 *     SceneDelegate (React Native starts only in the foreground; host links stay native).
 *  6. Adds App Group entitlement, keyboard extension (Swift-only; FluidAudio via withFluidAudio), links the ASR bridges + ModelManager into the app target via node-xcode (never hand-edit project.pbxproj).
 *
 * All Xcode edits live in this plugin only. Do not hand-edit ios/*.xcodeproj; prebuild regenerates ios/.
 */

import {
  ConfigPlugin,
  withDangerousMod,
  withXcodeProject,
  withEntitlementsPlist,
} from "expo/config-plugins";
import * as path from "path";
import * as fs from "fs";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const EXT_NAME = "CodictateDictationKeyboard";
const EXT_BUNDLE_ID = "app.codictate.keyboard";
const APP_GROUP_ID = "group.app.codictate";
const DEPLOYMENT_TARGET = "17.0";

/**
 * Keyboard extension: UI, the App Group bridge, and the In-keyboard path (WebKit capture +
 * Parakeet through FluidAudio, which withFluidAudio links to this target, and the client of
 * the Formatting AU). Every file here must also be in targets/CodictateDictationKeyboard/,
 * which Step 1 copies wholesale. withFormattingAU adds the AU's contract and the App Group
 * log, which both targets compile.
 */
const EXTENSION_SOURCES = [
  "KeyboardViewController.swift",
  "DictationKeyboardView.swift",
  "InKeyboardDictation.swift",
  "KeyboardWebCapture.swift",
  "KeyboardParakeet.swift",
  "KeyboardFormattingAUClient.swift",
  "DictatePill.swift",
];

/** Dropped from the extension's Sources phase when a legacy layout still compiles them there. */
const REMOVED_FROM_EXTENSION_SOURCES = [
  "WhisperBridge.mm",
  "AudioRecorder.swift",
  "ModelManager.swift",
];

const HOST_SWIFT_SRC_DIR = "codictateapp"; // source in targets/
// Destination folder inside ios/ is the Expo-generated project name (e.g. "Codictate")
const HOST_RECORDER_FILE = "KeyboardHostRecorder.swift";

const WIDGET_TARGET_NAME = "ExpoWidgetsTarget";
const CONTROL_WIDGET_FILE = "DictationControl.swift";

// node-xcode `pbxFile` resolves the canonical path stored in PBXFileReference
// (e.g. UIKit.framework to System/Library/Frameworks/UIKit.framework).
// eslint-disable-next-line @typescript-eslint/no-require-imports
const PbxFile = require("xcode/lib/pbxFile") as new (
  filepath: string,
  opt?: Record<string, unknown>,
) => { path: string; basename: string };

/** `pbxProject` does not expose `pbxGroupSection()`; read `PBXGroup` from the parsed document. */
function getPbxGroupObjects(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
): Record<string, { path?: string; children?: { value: string }[] }> {
  return project.hash?.project?.objects?.PBXGroup ?? {};
}

function findFileRefUuidForPath(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
  filePath: string,
): string | undefined {
  const section = project.pbxFileReferenceSection?.() ?? {};
  const normalized = filePath.replace(/^"|"$/g, "");
  for (const key of Object.keys(section)) {
    if (key.endsWith("_comment")) continue;
    const fr = section[key] as { path?: string } | undefined;
    const p = fr?.path?.replace(/^"|"$/g, "") ?? "";
    if (p === normalized) return key;
  }
  return undefined;
}

const KEYBOARD_HOST_INJECT_BEGIN =
  "/* <withKeyboardExtension KeyboardHostRecorder begin> */";
const KEYBOARD_HOST_INJECT_END =
  "/* <withKeyboardExtension KeyboardHostRecorder end> */";

function stripSwiftLeadingImports(source: string): string {
  return source
    .split("\n")
    .filter((line) => !/^\s*import\s+/.test(line))
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

function removeInjectedKeyboardHostRecorder(source: string): string {
  const re =
    /\/\* <withKeyboardExtension KeyboardHostRecorder begin> \*\/[\s\S]*?\/\* <withKeyboardExtension KeyboardHostRecorder end> \*\//m;
  return source.replace(re, "").replace(/\n{3,}/g, "\n\n");
}

function ensureAppDelegateRecorderImports(source: string): string {
  let out = source;
  if (!/\bimport\s+AVFoundation\b/.test(out)) {
    out = out.replace(
      /import ReactAppDependencyProvider\n/,
      "import ReactAppDependencyProvider\nimport AVFoundation\n",
    );
  }
  if (!/\bimport\s+UIKit\b/.test(out)) {
    out = out.replace(
      /import AVFoundation\n/,
      "import AVFoundation\nimport UIKit\n",
    );
  }
  if (!/\bimport\s+WidgetKit\b/.test(out)) {
    out = out.replace(/import UIKit\n/, "import UIKit\nimport WidgetKit\n");
  }
  if (!/\bimport\s+ActivityKit\b/.test(out)) {
    out = out.replace(
      /import WidgetKit\n/,
      "import WidgetKit\nimport ActivityKit\n",
    );
  }
  return out;
}

/**
 * `addFramework` no-ops when the file reference already exists (main app has
 * UIKit, etc.). The extension still needs its own PBXBuildFile rows in its
 * Frameworks phase, so we attach to the existing PBXFileReference when needed.
 */
function ensureFrameworkLinked(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
  rawPath: string,
  extUuid: string,
  pbxFileOpts?: Record<string, unknown>,
): void {
  const pf = new PbxFile(rawPath, pbxFileOpts ?? {});
  const canonicalPath = pf.path;
  const existing = project.hasFile(canonicalPath) || project.hasFile(rawPath);

  if (!existing) {
    project.addFramework(rawPath, {
      target: extUuid,
      link: true,
      ...pbxFileOpts,
    });
    return;
  }

  const fileRefKey =
    findFileRefUuidForPath(project, canonicalPath) ??
    findFileRefUuidForPath(project, rawPath);
  if (!fileRefKey) return;

  const file = {
    uuid: project.generateUuid(),
    fileRef: fileRefKey,
    basename: pf.basename,
    target: extUuid,
  };
  project.addToPbxBuildFileSection(file);
  project.addToPbxFrameworksBuildPhase(file);
}

/**
 * node-xcode's `addTargetDependency` no-ops if these sections are missing
 * (common on Expo-generated projects). Without a dependency, the host app can
 * archive or copy an empty/stale `.appex`, so the keyboard never registers.
 */
function ensureXcodeDependencyInfrastructure(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
): void {
  const o = project.hash.project.objects;
  if (!o.PBXTargetDependency) o.PBXTargetDependency = Object.create(null);
  if (!o.PBXContainerItemProxy) o.PBXContainerItemProxy = Object.create(null);
}

function findWidgetExtensionTargetUuid(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
): string | undefined {
  const native = project.pbxNativeTargetSection() ?? {};
  for (const key of Object.keys(native)) {
    if (key.endsWith("_comment")) continue;
    const t = native[key] as {
      name?: string;
      productType?: string;
    };
    const name = (t?.name ?? "").replace(/^"|"$/g, "");
    if (name === WIDGET_TARGET_NAME) {
      return key;
    }
  }
  return undefined;
}

function findWidgetExtensionTargetUuids(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
): string[] {
  const native = project.pbxNativeTargetSection() ?? {};
  const uuids: string[] = [];
  for (const key of Object.keys(native)) {
    if (key.endsWith("_comment")) continue;
    const t = native[key] as { name?: string } | undefined;
    const name = (t?.name ?? "").replace(/^"|"$/g, "");
    if (name === WIDGET_TARGET_NAME) {
      uuids.push(key);
    }
  }
  return uuids;
}

function removeWidgetTargetDuplicate(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
  targetUuid: string,
): void {
  const objects = project.hash.project.objects;
  const native = project.pbxNativeTargetSection() ?? {};
  const target = native[targetUuid] as
    | {
        buildConfigurationList?: string;
        productReference?: string;
      }
    | undefined;
  const productReference = target?.productReference?.replace(/^"|"$/g, "");

  for (const key of Object.keys(objects.PBXProject ?? {})) {
    if (key.endsWith("_comment")) continue;
    const pbxProject = objects.PBXProject[key] as
      | {
          targets?: { value: string }[];
          attributes?: { TargetAttributes?: Record<string, unknown> };
        }
      | undefined;
    if (pbxProject?.targets) {
      pbxProject.targets = pbxProject.targets.filter(
        (entry) => entry.value !== targetUuid,
      );
    }
    if (pbxProject?.attributes?.TargetAttributes) {
      delete pbxProject.attributes.TargetAttributes[targetUuid];
    }
  }

  const depSection = objects.PBXTargetDependency ?? {};
  const removedDependencyUuids = new Set<string>();
  for (const key of Object.keys(depSection)) {
    if (key.endsWith("_comment")) continue;
    const dep = depSection[key] as { target?: string } | undefined;
    if (dep?.target === targetUuid) {
      removedDependencyUuids.add(key);
      delete depSection[key];
      delete depSection[`${key}_comment`];
    }
  }

  for (const key of Object.keys(native)) {
    if (key.endsWith("_comment")) continue;
    const current = native[key] as
      | { dependencies?: { value: string }[] }
      | undefined;
    if (current?.dependencies) {
      current.dependencies = current.dependencies.filter(
        (entry) => !removedDependencyUuids.has(entry.value),
      );
    }
  }

  const proxySection = objects.PBXContainerItemProxy ?? {};
  for (const key of Object.keys(proxySection)) {
    if (key.endsWith("_comment")) continue;
    const proxy = proxySection[key] as
      | { remoteGlobalIDString?: string }
      | undefined;
    if (proxy?.remoteGlobalIDString === targetUuid) {
      delete proxySection[key];
      delete proxySection[`${key}_comment`];
    }
  }

  if (productReference) {
    const buildFiles = project.pbxBuildFileSection() ?? {};
    const removedBuildFileUuids = new Set<string>();
    for (const key of Object.keys(buildFiles)) {
      if (key.endsWith("_comment")) continue;
      const buildFile = buildFiles[key] as { fileRef?: string } | undefined;
      if (buildFile?.fileRef === productReference) {
        removedBuildFileUuids.add(key);
        delete buildFiles[key];
        delete buildFiles[`${key}_comment`];
      }
    }

    for (const sectionName of [
      "PBXCopyFilesBuildPhase",
      "PBXSourcesBuildPhase",
    ]) {
      const section = objects[sectionName] ?? {};
      for (const key of Object.keys(section)) {
        if (key.endsWith("_comment")) continue;
        const phase = section[key] as
          | { files?: { value: string }[] }
          | undefined;
        if (phase?.files) {
          phase.files = phase.files.filter(
            (entry) => !removedBuildFileUuids.has(entry.value),
          );
        }
      }
    }

    const groups = objects.PBXGroup ?? {};
    for (const key of Object.keys(groups)) {
      if (key.endsWith("_comment")) continue;
      const group = groups[key] as
        | { children?: { value: string }[] }
        | undefined;
      if (group?.children) {
        group.children = group.children.filter(
          (entry) => entry.value !== productReference,
        );
      }
    }

    const fileRefs = project.pbxFileReferenceSection?.() ?? {};
    delete fileRefs[productReference];
    delete fileRefs[`${productReference}_comment`];
  }

  if (target?.buildConfigurationList) {
    const configLists = objects.XCConfigurationList ?? {};
    const configList = configLists[target.buildConfigurationList] as
      | { buildConfigurations?: { value: string }[] }
      | undefined;
    const configs = objects.XCBuildConfiguration ?? {};
    for (const config of configList?.buildConfigurations ?? []) {
      delete configs[config.value];
      delete configs[`${config.value}_comment`];
    }
    delete configLists[target.buildConfigurationList];
    delete configLists[`${target.buildConfigurationList}_comment`];
  }

  delete native[targetUuid];
  delete native[`${targetUuid}_comment`];
}

function dedupeWidgetExtensionTargets(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
): void {
  const widgetTargetUuids = findWidgetExtensionTargetUuids(project);
  if (widgetTargetUuids.length <= 1) return;

  const targetToKeep =
    widgetTargetUuids.find((uuid) =>
      findSourcesBuildPhaseForTarget(project, uuid),
    ) ?? widgetTargetUuids[0];

  for (const uuid of widgetTargetUuids) {
    if (uuid !== targetToKeep) {
      removeWidgetTargetDuplicate(project, uuid);
      console.log(
        `[withKeyboardExtension] Removed duplicate ${WIDGET_TARGET_NAME} target ${uuid}`,
      );
    }
  }
}

function findWidgetExtensionGroupKey(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
): string | undefined {
  const groups = getPbxGroupObjects(project);
  for (const key of Object.keys(groups)) {
    if (key.endsWith("_comment")) continue;
    const g = groups[key] as { path?: string };
    const p = (g.path ?? "").replace(/^"|"$/g, "");
    if (p === WIDGET_TARGET_NAME) return key;
  }
  return project.findPBXGroupKey({ name: WIDGET_TARGET_NAME });
}

/** Find the PBXSourcesBuildPhase UUID belonging to a specific native target. */
function findSourcesBuildPhaseForTarget(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
  targetUuid: string,
): string | undefined {
  const native = project.pbxNativeTargetSection() ?? {};
  const target = native[targetUuid] as {
    buildPhases?: { value: string; comment?: string }[];
  };
  if (!target?.buildPhases) return undefined;
  const sourcesSection =
    project.hash?.project?.objects?.PBXSourcesBuildPhase ?? {};
  for (const phase of target.buildPhases) {
    if (sourcesSection[phase.value]) return phase.value;
  }
  return undefined;
}

function findKeyboardExtensionTargetUuid(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
): string | undefined {
  const native = project.pbxNativeTargetSection() ?? {};
  for (const key of Object.keys(native)) {
    if (key.endsWith("_comment")) continue;
    const t = native[key] as {
      name?: string;
      productType?: string;
    };
    const name = (t?.name ?? "").replace(/^"|"$/g, "");
    const productType = (t?.productType ?? "").replace(/^"|"$/g, "");
    if (
      name === EXT_NAME &&
      productType === "com.apple.product-type.app-extension"
    ) {
      return key;
    }
  }
  return undefined;
}

function hostAppAlreadyDependsOnExtension(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
  hostUuid: string,
  extensionUuid: string,
): boolean {
  const native = project.pbxNativeTargetSection() ?? {};
  const host = native[hostUuid] as { dependencies?: { value: string }[] };
  const deps = host?.dependencies;
  if (!Array.isArray(deps)) return false;
  const depSection = project.hash.project.objects.PBXTargetDependency ?? {};
  for (const d of deps) {
    const td = depSection[d.value] as { target?: string } | undefined;
    if (td?.target === extensionUuid) return true;
  }
  return false;
}

function unquoteProductName(name: string | undefined): string {
  if (!name) return "";
  return name.replace(/^"|"$/g, "");
}

/** PBX group whose `path` is the extension folder on disk (`ios/CodictateDictationKeyboard/`). */
function findKeyboardExtensionGroupKey(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
): string | undefined {
  const groups = getPbxGroupObjects(project);
  for (const key of Object.keys(groups)) {
    if (key.endsWith("_comment")) continue;
    const g = groups[key] as { path?: string };
    const p = (g.path ?? "").replace(/^"|"$/g, "");
    if (p === EXT_NAME) return key;
  }
  return project.findPBXGroupKey({ name: EXT_NAME });
}

/** PBX group that lists AppDelegate for the main app (not ExpoModulesProviders). */
function findHostAppSourceGroupKey(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
): string | undefined {
  const fileRefs = project.pbxFileReferenceSection?.() ?? {};
  let appDelegateUuid: string | undefined;
  for (const key of Object.keys(fileRefs)) {
    if (key.endsWith("_comment")) continue;
    const fr = fileRefs[key] as { path?: string } | undefined;
    const p = (fr?.path ?? "").replace(/^"|"$/g, "");
    if (p === "AppDelegate.swift" || p.endsWith("/AppDelegate.swift")) {
      appDelegateUuid = key;
      break;
    }
  }
  if (!appDelegateUuid) {
    for (const key of Object.keys(fileRefs)) {
      if (key.endsWith("_comment")) continue;
      const fr = fileRefs[key] as { path?: string } | undefined;
      const p = (fr?.path ?? "").replace(/^"|"$/g, "");
      if (p === "AppDelegate.swift" || p.endsWith("/AppDelegate.swift")) {
        appDelegateUuid = key;
        break;
      }
    }
  }
  if (!appDelegateUuid) return undefined;
  const groups = getPbxGroupObjects(project);
  for (const key of Object.keys(groups)) {
    if (key.endsWith("_comment")) continue;
    const g = groups[key];
    if (g.children?.some((c) => c.value === appDelegateUuid)) return key;
  }
  return undefined;
}

function mainAppSourcesPhaseReferencesFileRef(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
  appTargetUuid: string,
  fileRefUuid: string,
): boolean {
  const phase = project.pbxSourcesBuildPhaseObj(appTargetUuid);
  const files = phase?.files as { value: string }[] | undefined;
  if (!files?.length) return false;
  const buildFiles = project.pbxBuildFileSection() ?? {};
  for (const entry of files) {
    const bf = buildFiles[entry.value] as { fileRef?: string } | undefined;
    if (bf?.fileRef === fileRefUuid) return true;
  }
  return false;
}

/**
 * Ensures `pathForAddSourceFile` is compiled by the main app target. Handles prebuild re-runs where
 * `addSourceFile` no-ops because the file ref already exists (e.g. still only linked to the extension).
 */
function ensureSourceFileBuiltByMainAppTarget(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
  pathForAddSourceFile: string,
  groupKey: string,
  appTargetUuid: string,
): void {
  const added = project.addSourceFile(
    pathForAddSourceFile,
    { target: appTargetUuid },
    groupKey,
  );
  if (added) return;

  const pf = new PbxFile(pathForAddSourceFile);
  const refKey =
    findFileRefUuidForPath(project, pf.path) ??
    findFileRefUuidForPath(project, pathForAddSourceFile);
  if (!refKey) return;
  if (mainAppSourcesPhaseReferencesFileRef(project, appTargetUuid, refKey)) {
    return;
  }

  const file = {
    uuid: project.generateUuid(),
    fileRef: refKey,
    basename: pf.basename,
    target: appTargetUuid,
  };
  project.addToPbxBuildFileSection(file);
  project.addToPbxSourcesBuildPhase(file);
}

/**
 * Drops REMOVED_FROM_EXTENSION_SOURCES from the extension's Sources phase only. node-xcode's
 * `removeSourceFile` matches build files and file references by basename across the whole
 * project, so on a prebuild without --clean it also tore out the main app's WhisperBridge.mm
 * and ModelManager.swift, leaving dangling phase entries and duplicate references.
 */
function removeLegacyExtensionSources(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
  extUuid: string,
): void {
  const phaseUuid = findSourcesBuildPhaseForTarget(project, extUuid);
  if (!phaseUuid) return;
  const phase = project.hash.project.objects.PBXSourcesBuildPhase[phaseUuid];
  if (!phase?.files) return;
  const buildFiles = project.pbxBuildFileSection() ?? {};
  const fileRefs = project.pbxFileReferenceSection() ?? {};
  phase.files = phase.files.filter((entry: { value: string }) => {
    const bf = buildFiles[entry.value] as { fileRef?: string } | undefined;
    const ref = bf?.fileRef ? fileRefs[bf.fileRef] : undefined;
    const refPath = (
      (ref as { path?: string } | undefined)?.path ?? ""
    ).replace(/^"|"$/g, "");
    const legacy = REMOVED_FROM_EXTENSION_SOURCES.includes(
      path.basename(refPath),
    );
    if (legacy) {
      delete buildFiles[entry.value];
      delete buildFiles[`${entry.value}_comment`];
    }
    return !legacy;
  });
}

/** Strip legacy Whisper/mic sources from the extension; attach them to the app; fix build settings. */
function syncKeyboardExtensionAndWireHostTranscription(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
): void {
  const extUuid = findKeyboardExtensionTargetUuid(project);
  const extGroupKey = findKeyboardExtensionGroupKey(project);

  if (extUuid && extGroupKey) {
    removeLegacyExtensionSources(project, extUuid);

    for (const filename of EXTENSION_SOURCES) {
      project.addSourceFile(filename, { target: extUuid }, extGroupKey);
    }
  } else {
    console.warn(
      "[withKeyboardExtension] Extension target or group missing; skipped extension source sync.",
    );
  }

  const appTarget = project.getTarget("com.apple.product-type.application");
  if (!appTarget?.uuid || !appTarget.target?.name) return;
  const appTargetName = unquoteProductName(appTarget.target.name);
  const appUuid = appTarget.uuid;

  const hostSourceGroup = findHostAppSourceGroupKey(project);
  if (hostSourceGroup) {
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/WhisperBridge.mm`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/CohereBridge.mm`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/S1MiniBridge.mm`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/WavPCMReader.mm`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/EkkoBridge.mm`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/EkkoPncBridge.mm`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/ModelManager.swift`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/FormattingManager.swift`,
      hostSourceGroup,
      appUuid,
    );
    // Shared with the Formatting AU, which withFormattingAU links to the same file.
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/S1MiniFormatter.swift`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/DictationIntent.swift`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/DictationActivityAttributes.swift`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/TranscriptionEngine.swift`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/ParakeetEngine.swift`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/WhisperEngine.swift`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/CohereEngine.swift`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/AudioSlicer.swift`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/EkkoEngine.swift`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/PythonText.swift`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/EkkoPnc.swift`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/EkkoPncTokenizer.swift`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/EkkoPncModel.swift`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/PunctuationRestorer.swift`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/TranscriptionLanguages.swift`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/DictationReadiness.swift`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/BackgroundDownloadEvents.swift`,
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      `${appTargetName}/KeyboardListenSession.swift`,
      hostSourceGroup,
      appUuid,
    );
  } else {
    console.warn(
      "[withKeyboardExtension] Could not resolve host group for the main-app native sources.",
    );
  }

  patchKeyboardExtensionBuildSettings(project);
  project.updateBuildProperty(
    "CLANG_CXX_LANGUAGE_STANDARD",
    '"gnu++20"',
    undefined,
    appTargetName,
  );

  // The ASR Harness search paths are owned by `withCrispASR`, which runs after this
  // plugin and appends to whatever it finds. Reset to `$(inherited)` here so nothing
  // stale survives a re-prebuild, and do not add crispasr entries in this file.
  project.updateBuildProperty(
    "HEADER_SEARCH_PATHS",
    ['"$(inherited)"'],
    undefined,
    appTargetName,
  );
  project.updateBuildProperty(
    "FRAMEWORK_SEARCH_PATHS",
    ['"$(inherited)"'],
    undefined,
    appTargetName,
  );
  project.updateBuildProperty(
    "OTHER_LDFLAGS",
    '"$(inherited) -framework Accelerate -framework Metal -framework MetalKit -framework CoreML"',
    undefined,
    appTargetName,
  );
}

/** Reset extension target to a Swift-only keyboard (no Obj-C++ bridges; Parakeet comes from the FluidAudio package). */
function patchKeyboardExtensionBuildSettings(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
): void {
  const buildConfigs = project.pbxXCBuildConfigurationSection() ?? {};
  for (const key of Object.keys(buildConfigs)) {
    if (key.endsWith("_comment")) continue;
    const cfg = buildConfigs[key];
    if (typeof cfg !== "object" || !cfg?.buildSettings) continue;
    const bs = cfg.buildSettings as Record<string, unknown>;
    const bid = String(bs.PRODUCT_BUNDLE_IDENTIFIER ?? "");
    if (!bid.includes("codictate.keyboard")) continue;
    delete bs.SWIFT_OBJC_BRIDGING_HEADER;
    bs.HEADER_SEARCH_PATHS = ['"$(inherited)"'];
    bs.FRAMEWORK_SEARCH_PATHS = ['"$(inherited)"'];
    bs.OTHER_LDFLAGS = '"$(inherited)"';
    bs.LD_RUNPATH_SEARCH_PATHS = '"$(inherited)"';
  }
}

// ---------------------------------------------------------------------------
// Plugin entry point
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// AppDelegate + SceneDelegate (Expo SDK 58 scene life cycle)
// ---------------------------------------------------------------------------
//
// SDK 58 generates AppDelegate.swift (creates the React Native factory) and
// SceneDelegate.swift (`ExpoAppSceneDelegate`, which creates the window, starts
// React Native and re-feeds URL / life-cycle events to the AppDelegate). The
// patches below anchor on that template and throw when an anchor is missing, so a
// template change fails prebuild instead of shipping a Host that silently lost its
// Cold path deep link, background launch guard or download relaunch hook.

const HOST_DEEP_LINK_MARKER = "static func handleHostDeepLink(";
const BACKGROUND_URL_SESSION_MARKER = "handleEventsForBackgroundURLSession";
const SCENE_DEFERRAL_MARKER = "pendingConnection";

/** Swift added to AppDelegate: the Host's native-only deep links and the download relaunch hook. */
const APP_DELEGATE_METHODS = `

  // MARK: - Host deep links

  /// Linking API. Under the scene life cycle UIKit calls no app-delegate URL method;
  /// \`ExpoAppSceneDelegate\` re-feeds each link here instead: a cold launch's link from its
  /// connection options, a warm one through \`SceneDelegate.scene(_:openURLContexts:)\`.
  public override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if Self.handleHostDeepLink(url) {
      return true
    }
    return super.application(app, open: url, options: options)
  }

  /// Handles the Host's native-only links: the keyboard's Cold path
  /// (\`codictateapp://keyboard-record\`) and a Live Activity tap (\`keyboard-session\`, or the
  /// legacy \`dictation\`). They skip \`super\`, so expo-linking never records them as the
  /// initial URL and Expo Router never tries to open them as a route.
  static func handleHostDeepLink(_ url: URL) -> Bool {
    guard url.scheme == "codictateapp" else { return false }
    switch url.host {
    case "keyboard-record":
      KeyboardHostRecorder.shared.handleDeepLink()
      return true
    case "keyboard-session", "dictation":
      KeyboardHostRecorder.shared.handleKeyboardSessionDeepLink()
      return true
    default:
      return false
    }
  }

  // MARK: - Background Speech Model downloads

  /// iOS wakes the app when a background download finishes and hands over the
  /// completion handler for that session. One download session runs in this
  /// process, owned by \`ModelManager\` and attached from \`bootstrap()\` above, so the
  /// handler is answered from its \`urlSessionDidFinishEvents\`. This stays an
  /// app-delegate method under the scene life cycle and runs on a background relaunch
  /// where React Native is never started, which is exactly why the Expo module owns no
  /// session of its own. Any other identifier belongs to another library and goes to
  /// Expo's own subscribers.
  public override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    guard BackgroundDownloadEvents.owns(sessionIdentifier: identifier) else {
      super.application(
        application,
        handleEventsForBackgroundURLSession: identifier,
        completionHandler: completionHandler)
      return
    }
    BackgroundDownloadEvents.shared.store(completionHandler: completionHandler)
  }`;

/** Swift that replaces the SceneDelegate template's extension point. */
const SCENE_DELEGATE_BODY = `  // The Host does not require React Native for keyboard or Action Button dictation, so
  // React Native starts only when this scene first comes to the foreground. UIKit also
  // connects a scene for a system-requested background launch (Action Button
  // \`AudioRecordingIntent\`, a background download relaunch) and leaves it in the
  // background; \`ExpoAppSceneDelegate\` would start React Native right away.
  // \`KeyboardHostRecorder.bootstrap()\` runs from AppDelegate on every launch, scene or not.

  private var pendingConnection: (session: UISceneSession, options: UIScene.ConnectionOptions)?

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    NSLog("[SceneDelegate] willConnect app state=\\(UIApplication.shared.applicationState.rawValue)")
    pendingConnection = (session, connectionOptions)
  }

  override func sceneWillEnterForeground(_ scene: UIScene) {
    connectIfPending(scene)
    super.sceneWillEnterForeground(scene)
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    connectIfPending(scene)
    super.sceneDidBecomeActive(scene)
  }

  override func sceneDidDisconnect(_ scene: UIScene) {
    pendingConnection = nil
    super.sceneDidDisconnect(scene)
  }

  /// Warm links. The Host's native-only links stop here, as they did before the scene life
  /// cycle; \`super\` would otherwise hand them to React Native's Linking as well, and
  /// Expo Router would open \`/keyboard-record\` as a route.
  override func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
    let forReactNative = URLContexts.filter { !AppDelegate.handleHostDeepLink($0.url) }
    guard !forReactNative.isEmpty else { return }
    super.scene(scene, openURLContexts: forReactNative)
  }

  /// Runs Expo's connection: creates the window, starts React Native and re-feeds the
  /// connection's links (a Cold path link reaches \`AppDelegate.application(_:open:options:)\`).
  private func connectIfPending(_ scene: UIScene) {
    guard let pending = pendingConnection else { return }
    pendingConnection = nil
    NSLog("[SceneDelegate] Scene entering the foreground - starting React Native")
    super.scene(scene, willConnectTo: pending.session, options: pending.options)
  }
`;

/** Inserts `text` just before the closing brace of `class AppDelegate`. */
function insertIntoAppDelegateClass(source: string, text: string): string {
  const classStart = source.search(/\nclass AppDelegate\b/);
  const classEnd =
    classStart === -1 ? -1 : source.indexOf("\n}\n", classStart + 1);
  if (classEnd === -1) {
    throw new Error(
      "[withKeyboardExtension] AppDelegate.swift format unrecognized: no `class AppDelegate { ... }` block",
    );
  }
  return source.slice(0, classEnd) + text + source.slice(classEnd);
}

function patchAppDelegate(source: string, recorderBody: string): string {
  let ad = removeInjectedKeyboardHostRecorder(source);

  if (ad.includes("didInitReactNative")) {
    throw new Error(
      "[withKeyboardExtension] AppDelegate.swift still has the pre-SDK 58 deferred React Native init. " +
        "Run a clean prebuild (the default; drop --no-clean) so it is regenerated from the SDK 58 template.",
    );
  }

  // Every launch, including a background one that never connects a scene: observers,
  // the Parakeet migration, the background download session, stale state recovery.
  if (!ad.includes("KeyboardHostRecorder.shared.bootstrap()")) {
    const anchor = "  ) -> Bool {\n    let delegate = ReactNativeDelegate()";
    if (!ad.includes(anchor)) {
      throw new Error(
        "[withKeyboardExtension] AppDelegate.swift format unrecognized: cannot find didFinishLaunching creating ReactNativeDelegate",
      );
    }
    ad = ad.replace(
      anchor,
      '  ) -> Bool {\n    NSLog("[AppDelegate] didFinishLaunching state=\\(application.applicationState.rawValue)")\n    KeyboardHostRecorder.shared.bootstrap()\n\n    let delegate = ReactNativeDelegate()',
    );
    console.log(
      "[withKeyboardExtension] Wired KeyboardHostRecorder.shared.bootstrap() into AppDelegate launch",
    );
  }

  const hasDeepLinks = ad.includes(HOST_DEEP_LINK_MARKER);
  const hasUrlSession = ad.includes(BACKGROUND_URL_SESSION_MARKER);
  if (hasDeepLinks !== hasUrlSession) {
    throw new Error(
      "[withKeyboardExtension] AppDelegate.swift is half patched (host deep links xor background URLSession); run a clean prebuild",
    );
  }
  if (!hasDeepLinks) {
    if (/func application\(\s*_ app: UIApplication,\s*open url: URL/.test(ad)) {
      throw new Error(
        "[withKeyboardExtension] AppDelegate.swift already overrides application(_:open:options:); merge the host deep links into it",
      );
    }
    ad = insertIntoAppDelegateClass(ad, APP_DELEGATE_METHODS);
    console.log(
      "[withKeyboardExtension] Injected host deep links + background URLSession handler into AppDelegate",
    );
  }

  ad = ensureAppDelegateRecorderImports(ad);
  return `${ad.trimEnd()}\n\n${KEYBOARD_HOST_INJECT_BEGIN}\n// Source of truth: targets/${HOST_SWIFT_SRC_DIR}/${HOST_RECORDER_FILE}\n${recorderBody}\n${KEYBOARD_HOST_INJECT_END}\n`;
}

function patchSceneDelegate(source: string): string {
  if (source.includes(SCENE_DEFERRAL_MARKER)) return source;
  const anchor = "  // Extension point for config plugins.\n";
  if (
    !/class SceneDelegate: ExpoAppSceneDelegate \{/.test(source) ||
    !source.includes(anchor)
  ) {
    throw new Error(
      "[withKeyboardExtension] SceneDelegate.swift format unrecognized: expected the SDK 58 `class SceneDelegate: ExpoAppSceneDelegate` template",
    );
  }
  let sd = source.replace(anchor, `${anchor}\n${SCENE_DELEGATE_BODY}`);
  if (!/^import UIKit$/m.test(sd)) {
    sd = sd.replace(/^(internal import Expo\n)/m, "$1import UIKit\n");
  }
  console.log(
    "[withKeyboardExtension] Patched SceneDelegate: React Native starts in the foreground only, host deep links stay native",
  );
  return sd;
}

const withKeyboardExtension: ConfigPlugin = (config) => {
  // Step 1: Copy source files from targets/ into ios/ during prebuild
  config = withDangerousMod(config, [
    "ios",
    (c) => {
      const srcDir = path.join(c.modRequest.projectRoot, "targets", EXT_NAME);
      const destDir = path.join(c.modRequest.platformProjectRoot, EXT_NAME);

      if (!fs.existsSync(srcDir)) {
        throw new Error(
          `[withKeyboardExtension] Source directory not found: ${srcDir}\n` +
            `Make sure targets/${EXT_NAME}/ exists in your project root.`,
        );
      }

      fs.mkdirSync(destDir, { recursive: true });

      for (const file of fs.readdirSync(srcDir)) {
        fs.copyFileSync(path.join(srcDir, file), path.join(destDir, file));
      }

      console.log(
        `[withKeyboardExtension] Copied ${EXT_NAME} sources to ios/${EXT_NAME}/`,
      );

      // Main-app helper: native sources for recording, transcription, and App Intent.
      const hostSrcDir = path.join(
        c.modRequest.projectRoot,
        "targets",
        HOST_SWIFT_SRC_DIR,
      );
      const iosProjectName = c.modRequest.projectName ?? HOST_SWIFT_SRC_DIR;
      const hostDestDir = path.join(
        c.modRequest.platformProjectRoot,
        iosProjectName,
      );
      if (fs.existsSync(hostSrcDir)) {
        fs.mkdirSync(hostDestDir, { recursive: true });
        for (const file of fs.readdirSync(hostSrcDir)) {
          const isSource =
            file.endsWith(".swift") ||
            file.endsWith(".h") ||
            file.endsWith(".mm");
          if (!isSource) continue;
          if (file === HOST_RECORDER_FILE) continue;
          fs.copyFileSync(
            path.join(hostSrcDir, file),
            path.join(hostDestDir, file),
          );
        }
        console.log(
          `[withKeyboardExtension] Copied ${HOST_SWIFT_SRC_DIR} sources (except ${HOST_RECORDER_FILE}) to ios/${iosProjectName}/`,
        );
      }

      // Expo pins SWIFT_OBJC_BRIDGING_HEADER to <ProjectName>-Bridging-Header.h. Import Whisper there.
      const expoBridgingPath = path.join(
        hostDestDir,
        `${iosProjectName}-Bridging-Header.h`,
      );
      if (fs.existsSync(expoBridgingPath)) {
        let bridging = fs.readFileSync(expoBridgingPath, "utf8");
        // Obj-C++ bridges only. WavPCMReader.h is C++ and must never land here.
        for (const header of [
          "WhisperBridge.h",
          "CohereBridge.h",
          "S1MiniBridge.h",
          "EkkoBridge.h",
          "EkkoPncBridge.h",
        ]) {
          if (bridging.includes(header)) continue;
          bridging = `${bridging.trimEnd()}\n\n#import "${header}"\n`;
          console.log(
            `[withKeyboardExtension] Patched codictateapp-Bridging-Header.h for ${header}`,
          );
        }
        fs.writeFileSync(expoBridgingPath, bridging, "utf8");
      }

      // Control Widget: copy DictationControl.swift into the widget extension target.
      const widgetSrcDir = path.join(
        c.modRequest.projectRoot,
        "targets",
        "widgets",
      );
      const widgetDestDir = path.join(
        c.modRequest.platformProjectRoot,
        WIDGET_TARGET_NAME,
      );
      if (fs.existsSync(widgetSrcDir) && fs.existsSync(widgetDestDir)) {
        const controlSrc = path.join(widgetSrcDir, CONTROL_WIDGET_FILE);
        if (fs.existsSync(controlSrc)) {
          fs.copyFileSync(
            controlSrc,
            path.join(widgetDestDir, CONTROL_WIDGET_FILE),
          );
          console.log(
            `[withKeyboardExtension] Copied ${CONTROL_WIDGET_FILE} to ios/${WIDGET_TARGET_NAME}/`,
          );
        }

        // Live Activity widget: copy the SwiftUI Live Activity view.
        const liveActivityWidgetFile = "DictationLiveActivityWidget.swift";
        const liveActivitySrc = path.join(widgetSrcDir, liveActivityWidgetFile);
        if (fs.existsSync(liveActivitySrc)) {
          fs.copyFileSync(
            liveActivitySrc,
            path.join(widgetDestDir, liveActivityWidgetFile),
          );
          console.log(
            `[withKeyboardExtension] Copied ${liveActivityWidgetFile} to ios/${WIDGET_TARGET_NAME}/`,
          );
        }

        // Shared ActivityAttributes: copy into widget extension so it compiles in both targets.
        const attrsFile = "DictationActivityAttributes.swift";
        const attrsSrc = path.join(
          c.modRequest.projectRoot,
          "targets",
          HOST_SWIFT_SRC_DIR,
          attrsFile,
        );
        if (fs.existsSync(attrsSrc)) {
          fs.copyFileSync(attrsSrc, path.join(widgetDestDir, attrsFile));
          console.log(
            `[withKeyboardExtension] Copied ${attrsFile} to ios/${WIDGET_TARGET_NAME}/`,
          );
        }

        // Patch index.swift: replace the expo-widgets WidgetBundle with a native-only one.
        // ExpoWidgets framework can crash the widget extension process (database mapping errors),
        // preventing ALL ActivityConfigurations from registering. Our native widgets don't need it.
        const indexSwiftPath = path.join(widgetDestDir, "index.swift");
        if (fs.existsSync(indexSwiftPath)) {
          const nativeBundle = [
            "import WidgetKit",
            "import SwiftUI",
            "",
            "@main",
            "struct ExportWidgets0: WidgetBundle {",
            "  var body: some Widget {",
            "    if #available(iOS 16.1, *) {",
            "      DictationLiveActivityWidget()",
            "    }",
            "    if #available(iOS 18.0, *) {",
            "      DictationControlWidget()",
            "    }",
            "  }",
            "}",
            "",
          ].join("\n");
          fs.writeFileSync(indexSwiftPath, nativeBundle, "utf8");
          console.log(
            "[withKeyboardExtension] Replaced index.swift with native-only WidgetBundle (removed ExpoWidgets dependency)",
          );
        }
      }

      const recorderSrcPath = path.join(hostSrcDir, HOST_RECORDER_FILE);
      const appDelegatePath = path.join(hostDestDir, "AppDelegate.swift");
      const sceneDelegatePath = path.join(hostDestDir, "SceneDelegate.swift");
      for (const required of [
        recorderSrcPath,
        appDelegatePath,
        sceneDelegatePath,
      ]) {
        if (!fs.existsSync(required)) {
          throw new Error(`[withKeyboardExtension] Missing ${required}`);
        }
      }
      const recorderBody = stripSwiftLeadingImports(
        fs.readFileSync(recorderSrcPath, "utf8"),
      );
      fs.writeFileSync(
        appDelegatePath,
        patchAppDelegate(
          fs.readFileSync(appDelegatePath, "utf8"),
          recorderBody,
        ),
      );
      console.log(
        "[withKeyboardExtension] Injected KeyboardHostRecorder into AppDelegate.swift",
      );
      fs.writeFileSync(
        sceneDelegatePath,
        patchSceneDelegate(fs.readFileSync(sceneDelegatePath, "utf8")),
      );

      const staleRecorderPath = path.join(hostDestDir, HOST_RECORDER_FILE);
      if (fs.existsSync(staleRecorderPath)) {
        fs.unlinkSync(staleRecorderPath);
        console.log(
          `[withKeyboardExtension] Removed standalone ${HOST_RECORDER_FILE} (injected into AppDelegate)`,
        );
      }

      return c;
    },
  ]);

  // Step 2: Add App Group to main app entitlements
  config = withEntitlementsPlist(config, (c) => {
    const groups: string[] =
      (c.modResults["com.apple.security.application-groups"] as string[]) ?? [];
    if (!groups.includes(APP_GROUP_ID)) {
      groups.push(APP_GROUP_ID);
    }
    c.modResults["com.apple.security.application-groups"] = groups;
    return c;
  });

  // Every prebuild: move Whisper/native sources to the app target; slim the extension.
  config = withXcodeProject(config, (c) => {
    syncKeyboardExtensionAndWireHostTranscription(c.modResults);
    return c;
  });

  // Ensure the iOS app target depends on the keyboard extension and that
  // PBXTargetDependency sections exist (fixes prebuilds where addTargetDependency
  // silently did nothing).
  config = withXcodeProject(config, (c) => {
    const project = c.modResults;
    dedupeWidgetExtensionTargets(project);
    ensureXcodeDependencyInfrastructure(project);

    const appTarget = project.getTarget("com.apple.product-type.application");
    const extUuid = findKeyboardExtensionTargetUuid(project);
    if (!appTarget?.uuid || !extUuid) return c;

    if (!hostAppAlreadyDependsOnExtension(project, appTarget.uuid, extUuid)) {
      try {
        project.addTargetDependency(appTarget.uuid, [extUuid]);
      } catch {
        // Rare: malformed project graph. Run `npx expo prebuild --platform ios`.
      }
    }

    return c;
  });

  // Add widget-only Swift files to the widget extension's Sources build phase.
  // addSourceFile() defaults to the main app's Sources phase, so we must move
  // each file out of the main app and into the widget extension explicitly.
  // DictationActivityAttributes.swift is NOT widget-only. It compiles in both
  // targets (the main app needs it for ActivityKit calls in KeyboardHostRecorder).
  const WIDGET_ONLY_FILES = [
    CONTROL_WIDGET_FILE,
    "DictationLiveActivityWidget.swift",
  ];
  const WIDGET_SHARED_FILES = ["DictationActivityAttributes.swift"];

  config = withXcodeProject(config, (c) => {
    const project = c.modResults;
    dedupeWidgetExtensionTargets(project);
    const widgetUuid = findWidgetExtensionTargetUuid(project);
    const widgetGroup = findWidgetExtensionGroupKey(project);

    if (widgetUuid && widgetGroup) {
      const appTarget = project.getTarget("com.apple.product-type.application");
      const appPhaseUuid = appTarget?.uuid
        ? findSourcesBuildPhaseForTarget(project, appTarget.uuid)
        : undefined;

      for (const filename of WIDGET_ONLY_FILES) {
        project.addSourceFile(filename, {}, widgetGroup);

        const fileRefUuid = findFileRefUuidForPath(project, filename);
        if (!fileRefUuid) continue;

        // Remove from main app Sources (addSourceFile wrongly put it there).
        if (appPhaseUuid) {
          const sourcesSection =
            project.hash.project.objects.PBXSourcesBuildPhase;
          const appPhase = sourcesSection[appPhaseUuid];
          if (appPhase?.files) {
            const buildFiles = project.pbxBuildFileSection() ?? {};
            appPhase.files = appPhase.files.filter(
              (entry: { value: string }) => {
                const bf = buildFiles[entry.value] as
                  | { fileRef?: string }
                  | undefined;
                return bf?.fileRef !== fileRefUuid;
              },
            );
          }
        }

        // Add to widget target's Sources build phase.
        const widgetPhaseUuid = findSourcesBuildPhaseForTarget(
          project,
          widgetUuid,
        );
        if (widgetPhaseUuid) {
          const sourcesSection =
            project.hash.project.objects.PBXSourcesBuildPhase;
          const widgetPhase = sourcesSection[widgetPhaseUuid];
          if (widgetPhase?.files) {
            const buildFiles = project.pbxBuildFileSection() ?? {};
            const alreadyInWidget = widgetPhase.files.some(
              (entry: { value: string }) => {
                const bf = buildFiles[entry.value] as
                  | { fileRef?: string }
                  | undefined;
                return bf?.fileRef === fileRefUuid;
              },
            );
            if (!alreadyInWidget) {
              const uuid = project.generateUuid();
              project.addToPbxBuildFileSection({
                uuid,
                fileRef: fileRefUuid,
                basename: filename,
                target: widgetUuid,
              });
              widgetPhase.files.push({
                value: uuid,
                comment: `${filename} in Sources`,
              });
            }
          }
        }

        console.log(
          `[withKeyboardExtension] Added ${filename} to ${WIDGET_TARGET_NAME} Sources (widget-only)`,
        );
      }

      // Files compiled in both the main app AND the widget extension.
      // The main app already has its own copy (codictateapp/X.swift) wired via
      // ensureSourceFileBuiltByMainAppTarget. Here we add the ExpoWidgetsTarget
      // copy to the widget extension only. addSourceFile() wrongly puts it into
      // the main app Sources too, so we strip that duplicate.
      for (const filename of WIDGET_SHARED_FILES) {
        project.addSourceFile(filename, {}, widgetGroup);

        const fileRefUuid = findFileRefUuidForPath(project, filename);
        if (!fileRefUuid) continue;

        // Remove from main app Sources (addSourceFile wrongly put it there).
        if (appPhaseUuid) {
          const sourcesSection =
            project.hash.project.objects.PBXSourcesBuildPhase;
          const appPhase = sourcesSection[appPhaseUuid];
          if (appPhase?.files) {
            const buildFiles = project.pbxBuildFileSection() ?? {};
            appPhase.files = appPhase.files.filter(
              (entry: { value: string }) => {
                const bf = buildFiles[entry.value] as
                  | { fileRef?: string }
                  | undefined;
                return bf?.fileRef !== fileRefUuid;
              },
            );
          }
        }

        const widgetPhaseUuid = findSourcesBuildPhaseForTarget(
          project,
          widgetUuid,
        );
        if (widgetPhaseUuid) {
          const sourcesSection =
            project.hash.project.objects.PBXSourcesBuildPhase;
          const widgetPhase = sourcesSection[widgetPhaseUuid];
          if (widgetPhase?.files) {
            const buildFiles = project.pbxBuildFileSection() ?? {};
            const alreadyInWidget = widgetPhase.files.some(
              (entry: { value: string }) => {
                const bf = buildFiles[entry.value] as
                  | { fileRef?: string }
                  | undefined;
                return bf?.fileRef === fileRefUuid;
              },
            );
            if (!alreadyInWidget) {
              const uuid = project.generateUuid();
              project.addToPbxBuildFileSection({
                uuid,
                fileRef: fileRefUuid,
                basename: filename,
                target: widgetUuid,
              });
              widgetPhase.files.push({
                value: uuid,
                comment: `${filename} in Sources`,
              });
            }
          }
        }

        console.log(
          `[withKeyboardExtension] Added ${filename} to ${WIDGET_TARGET_NAME} Sources (shared with main app)`,
        );
      }
    }

    return c;
  });

  // Step 3: Add the keyboard extension target. Registered last on purpose: Expo runs
  // mods of the same type in reverse registration order, so this runs before every other
  // xcodeproj mod above, and withFluidAudio (inside this plugin in app.config.ts) runs
  // after it. A clean prebuild (the default since SDK 57) then finds the target in place
  // for the source sync, the host dependency and the FluidAudio link.
  config = withXcodeProject(config, (c) => {
    const project = c.modResults;

    // Guard: don't add twice on repeated prebuild runs
    const targets = project.pbxNativeTargetSection() ?? {};
    const alreadyAdded = Object.values(targets).some((t) => {
      if (typeof t !== "object" || t === null || !("name" in t)) return false;
      const name = ((t as { name?: string }).name ?? "").replace(/^"|"$/g, "");
      return name === EXT_NAME;
    });
    if (alreadyAdded) return c;

    ensureXcodeDependencyInfrastructure(project);

    // ------------------------------------------------------------------
    // 3a. Add extension target
    // ------------------------------------------------------------------
    const extTarget = project.addTarget(
      EXT_NAME,
      "app_extension",
      EXT_NAME, // subfolder name
      EXT_BUNDLE_ID,
    );
    const extUuid: string = extTarget.uuid;

    // `addTarget()` leaves buildPhases empty. Without dedicated phases,
    // `addSourceFile` / `addFramework` match the *first* Sources/Frameworks
    // phase in the project (the main app), so Swift never sees the bridging
    // header and `WhisperBridge` is out of scope.
    project.addBuildPhase([], "PBXSourcesBuildPhase", "Sources", extUuid);
    project.addBuildPhase([], "PBXFrameworksBuildPhase", "Frameworks", extUuid);

    // ------------------------------------------------------------------
    // 3b. Create PBX group for the extension
    //     The group has path = EXT_NAME, so file refs use just the filename.
    // ------------------------------------------------------------------
    let groupKey = project.findPBXGroupKey({ name: EXT_NAME });
    if (!groupKey) {
      groupKey = project.pbxCreateGroup(EXT_NAME, EXT_NAME);

      // Attach to the project's main group
      const mainGroupKey =
        project.findPBXGroupKey({ name: c.modRequest.projectName }) ??
        project.findPBXGroupKey({ name: "" });
      if (mainGroupKey) {
        const mainGroup = project.hash.project.objects.PBXGroup[mainGroupKey];
        if (mainGroup?.children) {
          mainGroup.children.push({ value: groupKey, comment: EXT_NAME });
        }
      }
    }

    // ------------------------------------------------------------------
    // 3c. Extension sources: UI, bridge and the In-keyboard path (Whisper runs in the main app).
    // ------------------------------------------------------------------
    EXTENSION_SOURCES.forEach((filename) => {
      project.addSourceFile(filename, { target: extUuid }, groupKey);
    });

    // Add Info.plist and entitlements to the group
    project.addFile("Info.plist", groupKey, { target: extUuid });
    project.addFile(`${EXT_NAME}.entitlements`, groupKey, { target: extUuid });

    // ------------------------------------------------------------------
    // 3d. Link frameworks
    // ------------------------------------------------------------------
    (["UIKit", "Foundation", "AVFoundation"] as const).forEach((fw) => {
      ensureFrameworkLinked(project, `${fw}.framework`, extUuid);
    });

    // ------------------------------------------------------------------
    // 3e. Build settings
    // ------------------------------------------------------------------
    const buildConfigs = project.pbxXCBuildConfigurationSection() ?? {};

    Object.keys(buildConfigs).forEach((key) => {
      const cfg = buildConfigs[key];
      if (typeof cfg !== "object" || !cfg.buildSettings) return;

      const bs = cfg.buildSettings;
      if (bs.PRODUCT_NAME !== EXT_NAME && bs.PRODUCT_NAME !== `"${EXT_NAME}"`)
        return;

      bs.PRODUCT_BUNDLE_IDENTIFIER = `"${EXT_BUNDLE_ID}"`;
      bs.IPHONEOS_DEPLOYMENT_TARGET = DEPLOYMENT_TARGET;
      bs.TARGETED_DEVICE_FAMILY = '"1"';
      bs.SWIFT_VERSION = "5.0";
      bs.CLANG_ENABLE_MODULES = "YES";
      bs.CLANG_ENABLE_OBJC_ARC = "YES";
      bs.SKIP_INSTALL = "YES";
      bs.GENERATE_INFOPLIST_FILE = "NO";

      bs.INFOPLIST_FILE = `"$(SRCROOT)/${EXT_NAME}/Info.plist"`;
      bs.CODE_SIGN_ENTITLEMENTS = `"$(SRCROOT)/${EXT_NAME}/${EXT_NAME}.entitlements"`;

      // Expo's own DEVELOPMENT_TEAM mod runs before this target exists.
      if (c.ios?.appleTeamId) bs.DEVELOPMENT_TEAM = c.ios.appleTeamId;

      bs.LD_RUNPATH_SEARCH_PATHS = '"$(inherited)"';
      bs.HEADER_SEARCH_PATHS = ['"$(inherited)"'];
      bs.FRAMEWORK_SEARCH_PATHS = ['"$(inherited)"'];
      bs.OTHER_LDFLAGS = '"$(inherited)"';
    });

    return c;
  });

  return config;
};

export default withKeyboardExtension;
