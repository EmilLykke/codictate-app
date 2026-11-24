/// <reference types="node" />

/**
 * Expo config plugin: withFormattingAU
 *
 * Adds the CodictateFormattingAU extension, the Dictation AU: an Audio Unit
 * (`com.apple.AudioUnit-UI`, one `aufx` component, no interface) that the keyboard hosts out
 * of process for its In-keyboard path. It runs every Speech Model but Parakeet (the Host's
 * engines and Punctuation Restoration) and S1-mini, none of which fit the keyboard's memory
 * limit. The target and bundle id keep their first name (`CodictateFormattingAU`,
 * `app.codictate.formattingau`): a new bundle id needs new provisioning and App Store records.
 *
 * During prebuild this plugin:
 *  1. Copies targets/CodictateFormattingAU/ to ios/CodictateFormattingAU/, stamping the
 *     app's version into the extension's Info.plist.
 *  2. Creates the extension target (once), embeds it in the app's PlugIns and makes the app
 *     depend on it.
 *  3. Compiles the AU's own sources plus the Host's transcription pipeline, engines, bridges
 *     and S1-mini sources (HOST_SOURCES: the same files, not copies). Links (does not embed)
 *     the dynamic crispasr, parakeet and llama xcframeworks, which the app embeds and the AU
 *     loads through `@executable_path/../../Frameworks`, and links the static onnxruntime
 *     with its system frameworks.
 *  4. Compiles the AU's DictationAUContract.swift and AppGroupLog.swift, and the Host's
 *     SpeechModelCatalog.swift, into the keyboard too, which hosts the AU.
 *
 * Runs after every other plugin that touches the project (withKeyboardExtension for the
 * keyboard target and the app's shared sources, withCrispASR, withLlama, withParakeetCpp and
 * withOnnxRuntime for the framework references): app.config.ts registers it innermost. Were
 * it to add a framework reference first, those plugins would find it and skip embedding the
 * framework in the app. Every step is idempotent and throws when something it needs is
 * missing.
 */

import {
  ConfigPlugin,
  withDangerousMod,
  withXcodeProject,
} from "expo/config-plugins";
import * as fs from "fs";
import * as path from "path";
import {
  CRISPASR_IOS_SLICES,
  CRISPASR_XCFRAMEWORK_NAME,
  LLAMA_IOS_SLICES,
  LLAMA_XCFRAMEWORK_NAME,
  ONNXRUNTIME_SYSTEM_FRAMEWORKS,
  ONNXRUNTIME_XCFRAMEWORK_NAME,
  PARAKEET_XCFRAMEWORK_NAME,
} from "../scripts/vendor-manifest";

const AU_NAME = "CodictateFormattingAU";
const AU_BUNDLE_ID = "app.codictate.formattingau";
const KEYBOARD_NAME = "CodictateDictationKeyboard";
const DEPLOYMENT_TARGET = "17.0";
const LLAMA_FRAMEWORK_PATH = `vendor/${LLAMA_XCFRAMEWORK_NAME}`;
const CRISPASR_FRAMEWORK_PATH = `vendor/${CRISPASR_XCFRAMEWORK_NAME}`;
/**
 * The xcframeworks the AU links, each referenced once by the plugin that vendors it. The
 * dynamic ones are embedded only in the app; onnxruntime is static and links into the AU's
 * own binary.
 */
const AU_FRAMEWORKS = [
  { path: LLAMA_FRAMEWORK_PATH, plugin: "withLlama" },
  { path: CRISPASR_FRAMEWORK_PATH, plugin: "withCrispASR" },
  { path: `vendor/${PARAKEET_XCFRAMEWORK_NAME}`, plugin: "withParakeetCpp" },
  { path: `vendor/${ONNXRUNTIME_XCFRAMEWORK_NAME}`, plugin: "withOnnxRuntime" },
];

/** Compiled by the AU only. */
const AU_SOURCES = [
  "DictationAU.swift",
  "DictationAUMessageChannel.swift",
  "DictationAUSpeech.swift",
];
/** Compiled by the AU and the keyboard. */
const SHARED_WITH_KEYBOARD = ["DictationAUContract.swift", "AppGroupLog.swift"];
/**
 * The Host's files in ios/<project>/ the AU compiles too: the transcription pipeline every
 * Speech Model but Parakeet runs through, its engines and bridges, Punctuation Restoration
 * and S1-mini. Keep in step with the Host's list in withKeyboardExtension; a new bridge
 * header also goes in CodictateFormattingAU-Bridging-Header.h.
 */
const HOST_SOURCES = [
  "SpeechModelCatalog.swift",
  "DictationReadinessState.swift",
  "TranscriptionPipeline.swift",
  "TranscriptionEngine.swift",
  "TranscriptionLanguages.swift",
  "WavPCMReader.mm",
  "WhisperEngine.swift",
  "WhisperBridge.mm",
  "CohereEngine.swift",
  "CohereBridge.mm",
  "AudioSlicer.swift",
  "EkkoEngine.swift",
  "EkkoBridge.mm",
  "PunctuationRestorer.swift",
  "EkkoPnc.swift",
  "EkkoPncTokenizer.swift",
  "EkkoPncModel.swift",
  "PythonText.swift",
  "EkkoPncBridge.mm",
  "S1MiniFormatter.swift",
  "S1MiniBridge.mm",
];
/** The Host's files the keyboard compiles too, for the In-keyboard path's eligibility. */
const HOST_SOURCES_FOR_KEYBOARD = ["SpeechModelCatalog.swift"];
const AU_RESOURCES = ["PrivacyInfo.xcprivacy"];
/** In the group for Xcode's navigator only. */
const AU_OTHER_FILES = [
  "Info.plist",
  `${AU_NAME}.entitlements`,
  `${AU_NAME}-Bridging-Header.h`,
];

/* eslint-disable @typescript-eslint/no-explicit-any */
type Project = any;
type PbxList = { value: string; comment?: string }[];

const unquote = (value: unknown): string =>
  String(value ?? "").replace(/^"|"$/g, "");

function fail(message: string): never {
  throw new Error(`[withFormattingAU] ${message}`);
}

function lastKnownFileType(name: string): string {
  if (name.endsWith(".swift")) return "sourcecode.swift";
  if (name.endsWith(".mm")) return "sourcecode.cpp.objcpp";
  if (name.endsWith(".h")) return "sourcecode.c.h";
  if (name.endsWith(".plist")) return "text.plist.xml";
  if (name.endsWith(".entitlements")) return "text.plist.entitlements";
  return "text.xml";
}

function findTargetUuid(project: Project, name: string): string | undefined {
  const native = project.pbxNativeTargetSection() ?? {};
  return Object.keys(native).find(
    (key) => !key.endsWith("_comment") && unquote(native[key]?.name) === name,
  );
}

function findFileRefByPath(
  project: Project,
  filePath: string,
): string | undefined {
  const refs = project.pbxFileReferenceSection() ?? {};
  return Object.keys(refs).find(
    (key) => !key.endsWith("_comment") && unquote(refs[key]?.path) === filePath,
  );
}

/** The target's build phase of `isa`, created when missing. */
function ensurePhase(
  project: Project,
  targetUuid: string,
  isa: string,
  name: string,
): string {
  const objects = project.hash.project.objects;
  const target = project.pbxNativeTargetSection()[targetUuid];
  const existing = (target.buildPhases as PbxList).find(
    (phase) => objects[isa]?.[phase.value],
  );
  if (existing) return existing.value;
  project.addBuildPhase([], isa, name, targetUuid);
  const created = (target.buildPhases as PbxList).find(
    (phase) => objects[isa]?.[phase.value],
  );
  if (!created) fail(`could not create the ${name} phase`);
  return created.value;
}

/** Adds `fileRef` to the phase unless one of its build files already points at it. */
function ensureInPhase(
  project: Project,
  isa: string,
  phaseUuid: string,
  fileRef: string,
  name: string,
  settings?: Record<string, unknown>,
): void {
  const phase = project.hash.project.objects[isa][phaseUuid];
  const phaseName = unquote(
    project.hash.project.objects[isa][`${phaseUuid}_comment`],
  );
  const buildFiles = project.pbxBuildFileSection();
  if (!phase.files) phase.files = [];
  const present = (phase.files as PbxList).some(
    (entry) => buildFiles[entry.value]?.fileRef === fileRef,
  );
  if (present) return;
  const uuid = project.generateUuid();
  const comment = `${name} in ${phaseName}`;
  buildFiles[uuid] = {
    isa: "PBXBuildFile",
    fileRef,
    fileRef_comment: name,
    ...(settings ? { settings } : {}),
  };
  buildFiles[`${uuid}_comment`] = comment;
  phase.files.push({ value: uuid, comment });
}

/** A file reference for `name` in the AU's group, created when missing. */
function ensureGroupFile(
  project: Project,
  groupKey: string,
  name: string,
): string {
  const group = project.hash.project.objects.PBXGroup[groupKey];
  const refs = project.pbxFileReferenceSection();
  const existing = (group.children as PbxList).find(
    (child) => unquote(refs[child.value]?.path) === name,
  );
  if (existing) return existing.value;
  const uuid = project.generateUuid();
  refs[uuid] = {
    isa: "PBXFileReference",
    lastKnownFileType: lastKnownFileType(name),
    name: `"${name}"`,
    path: `"${name}"`,
    sourceTree: '"<group>"',
  };
  refs[`${uuid}_comment`] = name;
  group.children.push({ value: uuid, comment: name });
  return uuid;
}

function ensureGroup(project: Project, projectName: string): string {
  const groups = project.hash.project.objects.PBXGroup;
  const existing = Object.keys(groups).find(
    (key) =>
      !key.endsWith("_comment") && unquote(groups[key]?.path) === AU_NAME,
  );
  if (existing) return existing;
  const key = project.pbxCreateGroup(AU_NAME, AU_NAME);
  const mainGroupKey =
    project.findPBXGroupKey({ name: projectName }) ??
    project.findPBXGroupKey({ name: "" });
  const mainGroup = mainGroupKey ? groups[mainGroupKey] : undefined;
  if (!mainGroup?.children) fail("main PBXGroup not found");
  mainGroup.children.push({ value: key, comment: AU_NAME });
  return key;
}

/**
 * node-xcode's addTarget adds an empty "Copy Files" phase to the first target and puts the
 * product in whichever "Copy Files" phase it finds first. Put the .appex in exactly one of
 * the app's PlugIns phases (dstSubfolderSpec 13) and drop phases left empty.
 */
function embedInApp(
  project: Project,
  appUuid: string,
  productRef: string,
): void {
  const objects = project.hash.project.objects;
  const copyPhases = objects.PBXCopyFilesBuildPhase ?? {};
  const buildFiles = project.pbxBuildFileSection();
  const app = project.pbxNativeTargetSection()[appUuid];

  for (const key of Object.keys(copyPhases)) {
    if (key.endsWith("_comment")) continue;
    const phase = copyPhases[key];
    phase.files = ((phase.files ?? []) as PbxList).filter((entry) => {
      const ours = buildFiles[entry.value]?.fileRef === productRef;
      if (ours) {
        delete buildFiles[entry.value];
        delete buildFiles[`${entry.value}_comment`];
      }
      return !ours;
    });
  }
  const appPhases = app.buildPhases as PbxList;
  for (const entry of [...appPhases]) {
    const phase = copyPhases[entry.value];
    if (
      phase &&
      String(phase.dstSubfolderSpec) === "13" &&
      phase.files.length === 0
    ) {
      appPhases.splice(appPhases.indexOf(entry), 1);
      delete copyPhases[entry.value];
      delete copyPhases[`${entry.value}_comment`];
    }
  }
  const plugIns = appPhases.find((entry) => {
    const phase = copyPhases[entry.value];
    return phase && String(phase.dstSubfolderSpec) === "13";
  });
  let phaseUuid = plugIns?.value;
  if (!phaseUuid) {
    project.addBuildPhase(
      [],
      "PBXCopyFilesBuildPhase",
      "Embed Foundation Extensions",
      appUuid,
      "app_extension",
    );
    phaseUuid = (app.buildPhases as PbxList).find((entry) => {
      const phase = copyPhases[entry.value];
      return phase && String(phase.dstSubfolderSpec) === "13";
    })?.value;
  }
  if (!phaseUuid) fail("no PlugIns copy phase on the app target");
  ensureInPhase(
    project,
    "PBXCopyFilesBuildPhase",
    phaseUuid,
    productRef,
    `${AU_NAME}.appex`,
    { ATTRIBUTES: ["RemoveHeadersOnCopy"] },
  );
}

function appDependsOn(
  project: Project,
  appUuid: string,
  uuid: string,
): boolean {
  const app = project.pbxNativeTargetSection()[appUuid];
  const deps = project.hash.project.objects.PBXTargetDependency ?? {};
  return ((app.dependencies ?? []) as PbxList).some(
    (entry) => deps[entry.value]?.target === uuid,
  );
}

function applyBuildSettings(
  project: Project,
  auUuid: string,
  projectName: string,
  teamId: string | undefined,
): void {
  const target = project.pbxNativeTargetSection()[auUuid];
  const list = project.pbxXCConfigurationList()[target.buildConfigurationList];
  const configs = project.pbxXCBuildConfigurationSection();
  for (const entry of (list?.buildConfigurations ?? []) as PbxList) {
    const bs = configs[entry.value]?.buildSettings;
    if (!bs) continue;
    bs.PRODUCT_NAME = `"${AU_NAME}"`;
    bs.PRODUCT_BUNDLE_IDENTIFIER = `"${AU_BUNDLE_ID}"`;
    bs.IPHONEOS_DEPLOYMENT_TARGET = DEPLOYMENT_TARGET;
    bs.TARGETED_DEVICE_FAMILY = '"1"';
    bs.SWIFT_VERSION = "5.0";
    bs.CLANG_ENABLE_MODULES = "YES";
    bs.CLANG_ENABLE_OBJC_ARC = "YES";
    bs.CLANG_CXX_LANGUAGE_STANDARD = '"gnu++20"';
    bs.SKIP_INSTALL = "YES";
    bs.GENERATE_INFOPLIST_FILE = "NO";
    bs.INFOPLIST_FILE = `"$(SRCROOT)/${AU_NAME}/Info.plist"`;
    bs.CODE_SIGN_ENTITLEMENTS = `"$(SRCROOT)/${AU_NAME}/${AU_NAME}.entitlements"`;
    bs.CODE_SIGN_STYLE = "Automatic";
    // Expo's own DEVELOPMENT_TEAM mod runs before this target exists.
    if (teamId) bs.DEVELOPMENT_TEAM = teamId;
    bs.SWIFT_OBJC_BRIDGING_HEADER = `"${AU_NAME}/${AU_NAME}-Bridging-Header.h"`;
    // The app's sources folder holds the bridges' headers and cohere.h (withCrispASR);
    // the quoted `#import "crispasr.h"` and `#import "llama.h"` need the slices' Headers/.
    bs.HEADER_SEARCH_PATHS = [
      '"$(inherited)"',
      `"$(SRCROOT)/${projectName}"`,
      ...LLAMA_IOS_SLICES.map(
        (slice) =>
          `"$(SRCROOT)/${LLAMA_FRAMEWORK_PATH}/${slice}/llama.framework/Headers"`,
      ),
      ...CRISPASR_IOS_SLICES.map(
        (slice) =>
          `"$(SRCROOT)/${CRISPASR_FRAMEWORK_PATH}/${slice}/crispasr.framework/Headers"`,
      ),
    ];
    bs.FRAMEWORK_SEARCH_PATHS = ['"$(inherited)"', '"$(SRCROOT)/vendor"'];
    bs.LD_RUNPATH_SEARCH_PATHS = [
      '"$(inherited)"',
      '"@executable_path/Frameworks"',
      '"@executable_path/../../Frameworks"',
    ];
    // onnxruntime is a static framework: its podspec's system frameworks link here.
    bs.OTHER_LDFLAGS = `"${["$(inherited)", ...ONNXRUNTIME_SYSTEM_FRAMEWORKS.map((name) => `-framework ${name}`)].join(" ")}"`;
  }
}

const withFormattingAU: ConfigPlugin = (config) => {
  config = withDangerousMod(config, [
    "ios",
    (c) => {
      const source = path.join(c.modRequest.projectRoot, "targets", AU_NAME);
      const dest = path.join(c.modRequest.platformProjectRoot, AU_NAME);
      if (!fs.existsSync(source)) fail(`missing ${source}`);
      fs.mkdirSync(dest, { recursive: true });
      for (const file of fs.readdirSync(source)) {
        fs.copyFileSync(path.join(source, file), path.join(dest, file));
      }
      // An extension's versions must match its app's.
      const plistPath = path.join(dest, "Info.plist");
      const plist = fs.readFileSync(plistPath, "utf8");
      if (
        !plist.includes("__APP_VERSION__") ||
        !plist.includes("__APP_BUILD__")
      ) {
        fail(
          "Info.plist lost its __APP_VERSION__ / __APP_BUILD__ placeholders",
        );
      }
      fs.writeFileSync(
        plistPath,
        plist
          .replace("__APP_VERSION__", c.version ?? "1.0.0")
          .replace("__APP_BUILD__", c.ios?.buildNumber ?? "1"),
      );
      console.log(
        `[withFormattingAU] Copied ${AU_NAME} sources to ios/${AU_NAME}/`,
      );
      return c;
    },
  ]);

  config = withXcodeProject(config, (c) => {
    const project = c.modResults;
    const projectName = c.modRequest.projectName ?? "Codictate";
    const objects = project.hash.project.objects;
    if (!objects.PBXTargetDependency)
      objects.PBXTargetDependency = Object.create(null);
    if (!objects.PBXContainerItemProxy)
      objects.PBXContainerItemProxy = Object.create(null);

    const app = project.getTarget("com.apple.product-type.application");
    if (!app?.uuid) fail("main app target missing");
    const keyboardUuid = findTargetUuid(project, KEYBOARD_NAME);
    if (!keyboardUuid)
      fail(
        `${KEYBOARD_NAME} target missing; withKeyboardExtension must run first`,
      );
    const frameworkRefs = AU_FRAMEWORKS.map(
      ({ path: frameworkPath, plugin }) => {
        const ref = findFileRefByPath(project, frameworkPath);
        if (!ref)
          fail(
            `${frameworkPath} reference missing; ${plugin} must run first (register withFormattingAU innermost in app.config.ts)`,
          );
        return { name: path.basename(frameworkPath), ref };
      },
    );
    const hostRefs = HOST_SOURCES.map((name) => {
      const ref = findFileRefByPath(project, `${projectName}/${name}`);
      if (!ref)
        fail(
          `${projectName}/${name} reference missing; withKeyboardExtension must add it first`,
        );
      return { name, ref };
    });

    let auUuid = findTargetUuid(project, AU_NAME);
    if (!auUuid) {
      auUuid = project.addTarget(
        AU_NAME,
        "app_extension",
        AU_NAME,
        AU_BUNDLE_ID,
      ).uuid as string;
      console.log(`[withFormattingAU] Added ${AU_NAME} target`);
    }
    const auTarget = project.pbxNativeTargetSection()[auUuid];
    embedInApp(project, app.uuid, auTarget.productReference);
    if (!appDependsOn(project, app.uuid, auUuid)) {
      project.addTargetDependency(app.uuid, [auUuid]);
      if (!appDependsOn(project, app.uuid, auUuid))
        fail("could not make the app depend on the AU");
    }

    const sources = ensurePhase(
      project,
      auUuid,
      "PBXSourcesBuildPhase",
      "Sources",
    );
    const frameworks = ensurePhase(
      project,
      auUuid,
      "PBXFrameworksBuildPhase",
      "Frameworks",
    );
    const resources = ensurePhase(
      project,
      auUuid,
      "PBXResourcesBuildPhase",
      "Resources",
    );
    const keyboardSources = ensurePhase(
      project,
      keyboardUuid,
      "PBXSourcesBuildPhase",
      "Sources",
    );

    const groupKey = ensureGroup(project, projectName);
    for (const name of [...AU_SOURCES, ...SHARED_WITH_KEYBOARD]) {
      const ref = ensureGroupFile(project, groupKey, name);
      ensureInPhase(project, "PBXSourcesBuildPhase", sources, ref, name);
      if (SHARED_WITH_KEYBOARD.includes(name)) {
        ensureInPhase(
          project,
          "PBXSourcesBuildPhase",
          keyboardSources,
          ref,
          name,
        );
      }
    }
    for (const { name, ref } of hostRefs) {
      ensureInPhase(project, "PBXSourcesBuildPhase", sources, ref, name);
      if (HOST_SOURCES_FOR_KEYBOARD.includes(name)) {
        ensureInPhase(
          project,
          "PBXSourcesBuildPhase",
          keyboardSources,
          ref,
          name,
        );
      }
    }
    for (const name of AU_RESOURCES) {
      const ref = ensureGroupFile(project, groupKey, name);
      ensureInPhase(project, "PBXResourcesBuildPhase", resources, ref, name);
    }
    for (const name of AU_OTHER_FILES) ensureGroupFile(project, groupKey, name);
    for (const { name, ref } of frameworkRefs) {
      ensureInPhase(project, "PBXFrameworksBuildPhase", frameworks, ref, name);
    }

    applyBuildSettings(project, auUuid, projectName, c.ios?.appleTeamId);
    console.log(
      `[withFormattingAU] ${AU_NAME} wired: embedded in PlugIns, ${hostRefs.length} Host sources shared, ${frameworkRefs.map(({ name }) => name).join(", ")} linked`,
    );
    return c;
  });
  return config;
};
/* eslint-enable @typescript-eslint/no-explicit-any */

export default withFormattingAU;
