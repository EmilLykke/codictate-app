/// <reference types="node" />

/**
 * Xcode-project helpers shared by the plugins that vendor an xcframework built
 * or fetched into vendors/: withParakeetCpp and withOnnxRuntime. They follow
 * withCrispASR's linking (see the notes there on why node-xcode's own
 * `addFramework` is not used) and withLlama's Legal/ resources.
 *
 * Both plugins are registered inside withCrispASR in app.config.ts, so their
 * Xcode mods run after withKeyboardExtension has reset the app target's search
 * paths and OTHER_LDFLAGS; everything here appends to what it finds.
 */

import { IOSConfig, XcodeProject } from "expo/config-plugins";
import * as fs from "fs";
import * as path from "path";

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

export function mainAppTarget(
  project: XcodeProject,
  log: string,
): { uuid: string; name: string } {
  const app = project.getTarget("com.apple.product-type.application");
  if (!app?.uuid || !app.target?.name) {
    throw new Error(`${log} main app target missing`);
  }
  return {
    uuid: app.uuid,
    name: String(app.target.name).replace(/^"|"$/g, ""),
  };
}

function targetBuildSettings(
  project: XcodeProject,
  targetName: string,
): Record<string, unknown>[] {
  const target = project.pbxTargetByName(targetName);
  const list =
    project.pbxXCConfigurationList()?.[target?.buildConfigurationList];
  const ids = new Set<string>(
    (list?.buildConfigurations ?? []).map(
      (entry: { value: string }) => entry.value,
    ),
  );
  const configs = project.pbxXCBuildConfigurationSection() ?? {};
  return [...ids]
    .map((id) => configs[id]?.buildSettings)
    .filter(Boolean) as Record<string, unknown>[];
}

/** Appends to a list-valued build setting on one target instead of replacing it. */
export function appendBuildSettingList(
  project: XcodeProject,
  targetName: string,
  key: string,
  values: string[],
): void {
  for (const settings of targetBuildSettings(project, targetName)) {
    const current = settings[key];
    const list: string[] = Array.isArray(current)
      ? [...(current as string[])]
      : typeof current === "string" && current.length > 0
        ? [current]
        : ['"$(inherited)"'];
    for (const value of values) if (!list.includes(value)) list.push(value);
    settings[key] = list;
  }
}

/**
 * Appends `-framework <name>` for each missing name to the target's
 * OTHER_LDFLAGS, which withKeyboardExtension writes as one quoted string.
 */
export function appendLinkedSystemFrameworks(
  project: XcodeProject,
  targetName: string,
  frameworks: readonly string[],
): void {
  for (const settings of targetBuildSettings(project, targetName)) {
    const current = settings.OTHER_LDFLAGS;
    let flags = (
      Array.isArray(current)
        ? (current as string[]).map((v) => v.replace(/^"|"$/g, "")).join(" ")
        : String(current ?? "$(inherited)").replace(/^"|"$/g, "")
    ).trim();
    const tokens = flags.split(/\s+/);
    for (const name of frameworks) {
      const present = tokens.some(
        (token, i) => token === name && tokens[i - 1] === "-framework",
      );
      if (!present) flags += ` -framework ${name}`;
    }
    settings.OTHER_LDFLAGS = `"${flags}"`;
  }
}

/**
 * PBXCopyFilesBuildPhase with dstSubfolderSpec 10 (Frameworks). Expo generates
 * no Embed Frameworks phase, and node-xcode silently drops an embed without it.
 */
function ensureEmbedFrameworksPhase(
  project: XcodeProject,
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
 * Links the xcframework at `projectPath` (relative to ios/) into the target's
 * Frameworks phase, and with `embed` also copies a signed copy into the app's
 * Frameworks/ (dynamic frameworks only; a static one must not be embedded).
 * Returns false when it is already referenced.
 */
export function linkXcframework(
  project: XcodeProject,
  targetUuid: string,
  projectPath: string,
  embed: boolean,
): boolean {
  const options = {
    customFramework: true,
    lastKnownFileType: "wrapper.xcframework",
    target: targetUuid,
  };
  const linked = new PbxFile(projectPath, options);
  if (project.hasFile(linked.path)) return false;

  linked.uuid = project.generateUuid();
  linked.fileRef = project.generateUuid();
  linked.target = targetUuid;
  linked.group = "Frameworks";
  project.addToPbxBuildFileSection(linked);
  project.addToPbxFileReferenceSection(linked);
  project.addToFrameworksPbxGroup(linked);
  project.addToPbxFrameworksBuildPhase(linked);

  if (embed) {
    ensureEmbedFrameworksPhase(project, targetUuid);
    const embedded = new PbxFile(projectPath, {
      ...options,
      embed: true,
      sign: true,
    });
    embedded.uuid = project.generateUuid();
    embedded.fileRef = linked.fileRef;
    embedded.target = targetUuid;
    project.addToPbxBuildFileSection(embedded);
    project.addToPbxEmbedFrameworksBuildPhase(embedded);
  }
  return true;
}

/** Copies a vendored xcframework into ios/vendor/ and stamps it. */
export function copyXcframework(
  projectRoot: string,
  platformProjectRoot: string,
  source: string,
  projectPath: string,
  stampName: string,
  stamp: string,
): void {
  const dest = path.join(platformProjectRoot, projectPath);
  fs.rmSync(dest, { recursive: true, force: true });
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.cpSync(path.join(projectRoot, source), dest, { recursive: true });
  fs.writeFileSync(
    path.join(path.dirname(dest), stampName),
    `${stamp}\n`,
    "utf8",
  );
}

/** Copies license files into ios/<Project>/Legal/ during the dangerous mod. */
export function copyLegalFiles(
  projectRoot: string,
  platformProjectRoot: string,
  projectName: string,
  files: readonly (readonly [source: string, outputName: string])[],
): void {
  const legalDir = path.join(platformProjectRoot, projectName, "Legal");
  fs.mkdirSync(legalDir, { recursive: true });
  for (const [source, outputName] of files) {
    fs.copyFileSync(
      path.join(projectRoot, source),
      path.join(legalDir, outputName),
    );
  }
}

/** Bundles the Legal/ files as app resources, like withLlama. */
export function addLegalResources(
  project: XcodeProject,
  target: { uuid: string; name: string },
  outputNames: readonly string[],
): void {
  IOSConfig.XcodeUtils.ensureGroupRecursively(project, "Resources");
  for (const name of outputNames) {
    const resourcePath = `${target.name}/Legal/${name}`;
    if (!project.hasFile(resourcePath)) {
      IOSConfig.XcodeUtils.addResourceFileToGroup({
        filepath: resourcePath,
        groupName: "Resources",
        project,
        isBuildFile: true,
        targetUuid: target.uuid,
      });
    }
  }
}
