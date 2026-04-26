/**
 * Expo config plugin: withKeyboardExtension
 *
 * Adds the CodictateDictationKeyboard keyboard extension to the iOS project.
 *
 * During prebuild this plugin:
 *  1. Copies extension sources from targets/CodictateDictationKeyboard/ → ios/…
 *  2. Copies WhisperBridge.h into ios/codictateapp/ and patches codictateapp-Bridging-Header.h.
 *  3. Copies other targets/codictateapp/*.swift into ios/codictateapp/ (not KeyboardHostRecorder — see 4).
 *  4. Injects targets/codictateapp/KeyboardHostRecorder.swift into AppDelegate.swift (app target).
 *  5. Patches AppDelegate for codictateapp://keyboard-record.
 *  6. Adds App Group entitlement, keyboard extension (UIKit-only), links WhisperBridge.mm + ModelManager into the app target via node-xcode (never hand-edit project.pbxproj).
 *
 * All Xcode edits live in this plugin only — do not hand-edit ios/*.xcodeproj; prebuild regenerates ios/.
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
const EXT_BUNDLE_ID = "com.emillo2003.codictate-app.keyboard";
const APP_GROUP_ID = "group.com.emillo2003.codictate-app";
const DEPLOYMENT_TARGET = "15.1";

/** Keyboard extension: UI + App Group bridge only (no mic / no Whisper). */
const EXTENSION_SOURCES = [
  "KeyboardViewController.swift",
  "DictationKeyboardView.swift",
];

/** Removed from the extension target on each prebuild sync (legacy layout). */
const REMOVED_FROM_EXTENSION_SOURCES = [
  "WhisperBridge.mm",
  "AudioRecorder.swift",
  "ModelManager.swift",
];

const HOST_SWIFT_DIR = "codictateapp";
const HOST_RECORDER_FILE = "KeyboardHostRecorder.swift";

const RNWHISPER_XCFRAMEWORK =
  "../node_modules/whisper.rn/ios/rnwhisper.xcframework";

// node-xcode `pbxFile` resolves the canonical path stored in PBXFileReference
// (e.g. UIKit.framework → System/Library/Frameworks/UIKit.framework).
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
    if (p === "codictateapp/AppDelegate.swift") {
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

/** Strip legacy Whisper/mic sources from the extension; attach them to the app; fix build settings. */
function syncKeyboardExtensionAndWireHostTranscription(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
): void {
  const extUuid = findKeyboardExtensionTargetUuid(project);
  const extGroupKey = findKeyboardExtensionGroupKey(project);

  if (extUuid && extGroupKey) {
    for (const filename of REMOVED_FROM_EXTENSION_SOURCES) {
      try {
        project.removeSourceFile(filename, { target: extUuid }, extGroupKey);
      } catch {
        /* not present */
      }
    }

    try {
      project.removeFramework(RNWHISPER_XCFRAMEWORK, {
        target: extUuid,
        customFramework: true,
      });
    } catch {
      /* not linked */
    }

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
      "codictateapp/WhisperBridge.mm",
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      "codictateapp/ModelManager.swift",
      hostSourceGroup,
      appUuid,
    );
    ensureSourceFileBuiltByMainAppTarget(
      project,
      "codictateapp/DictationIntent.swift",
      hostSourceGroup,
      appUuid,
    );
  } else {
    console.warn(
      "[withKeyboardExtension] Could not resolve host group for ModelManager.swift / WhisperBridge.mm.",
    );
  }

  patchKeyboardExtensionBuildSettings(project);
  project.updateBuildProperty(
    "CLANG_CXX_LANGUAGE_STANDARD",
    '"gnu++20"',
    undefined,
    appTargetName,
  );

  const whisperHeaders = [
    '"$(inherited)"',
    `"$(SRCROOT)/../node_modules/whisper.rn/ios/rnwhisper.xcframework/ios-arm64/rnwhisper.framework/Headers"`,
    `"$(SRCROOT)/../node_modules/whisper.rn/ios/rnwhisper.xcframework/ios-arm64_x86_64-simulator/rnwhisper.framework/Headers"`,
  ];
  project.updateBuildProperty(
    "HEADER_SEARCH_PATHS",
    whisperHeaders,
    undefined,
    appTargetName,
  );
  project.updateBuildProperty(
    "FRAMEWORK_SEARCH_PATHS",
    ['"$(inherited)"', '"$(SRCROOT)/../node_modules/whisper.rn/ios"'],
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

/** Reset extension target to a thin UIKit-only keyboard (no Obj-C++ / no rnwhisper). */
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
    if (!bid.includes("codictate-app.keyboard")) continue;
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

      const hostDestEarly = path.join(
        c.modRequest.platformProjectRoot,
        HOST_SWIFT_DIR,
      );
      const whisperSrcPath = path.join(destDir, "WhisperBridge.h");
      if (fs.existsSync(whisperSrcPath)) {
        fs.mkdirSync(hostDestEarly, { recursive: true });
        const whisperDest = path.join(hostDestEarly, "WhisperBridge.h");
        fs.copyFileSync(whisperSrcPath, whisperDest);
        const whisperMmSrc = path.join(destDir, "WhisperBridge.mm");
        if (fs.existsSync(whisperMmSrc)) {
          fs.copyFileSync(
            whisperMmSrc,
            path.join(hostDestEarly, "WhisperBridge.mm"),
          );
        }
        // Expo pins SWIFT_OBJC_BRIDGING_HEADER to codictateapp-Bridging-Header.h — import Whisper there.
        const expoBridgingPath = path.join(
          hostDestEarly,
          "codictateapp-Bridging-Header.h",
        );
        if (fs.existsSync(expoBridgingPath)) {
          let bridging = fs.readFileSync(expoBridgingPath, "utf8");
          if (!/WhisperBridge\.h/.test(bridging)) {
            bridging = `${bridging.trimEnd()}\n\n#import "WhisperBridge.h"\n`;
            fs.writeFileSync(expoBridgingPath, bridging, "utf8");
            console.log(
              `[withKeyboardExtension] Patched codictateapp-Bridging-Header.h for WhisperBridge`,
            );
          }
        }
      }

      // Main-app helper: microphone recording for the keyboard (extension → app handoff).
      const hostSrcDir = path.join(
        c.modRequest.projectRoot,
        "targets",
        HOST_SWIFT_DIR,
      );
      const hostDestDir = path.join(
        c.modRequest.platformProjectRoot,
        HOST_SWIFT_DIR,
      );
      if (fs.existsSync(hostSrcDir)) {
        fs.mkdirSync(hostDestDir, { recursive: true });
        for (const file of fs.readdirSync(hostSrcDir)) {
          if (!file.endsWith(".swift")) continue;
          if (file === HOST_RECORDER_FILE) continue;
          fs.copyFileSync(
            path.join(hostSrcDir, file),
            path.join(hostDestDir, file),
          );
        }
        console.log(
          `[withKeyboardExtension] Copied ${HOST_SWIFT_DIR}/*.swift (except ${HOST_RECORDER_FILE}) → ios/${HOST_SWIFT_DIR}/`,
        );
      }

      const recorderSrcPath = path.join(hostSrcDir, HOST_RECORDER_FILE);
      const appDelegatePath = path.join(hostDestDir, "AppDelegate.swift");

      if (fs.existsSync(appDelegatePath)) {
        let ad = fs.readFileSync(appDelegatePath, "utf8");
        ad = removeInjectedKeyboardHostRecorder(ad);

        if (!ad.includes('url.host == "keyboard-record"')) {
          ad = ad.replace(
            `  public override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    return super.application(app, open: url, options: options) || RCTLinkingManager.application(app, open: url, options: options)
  }`,
            `  public override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if url.scheme == "codictateapp", url.host == "keyboard-record" {
      KeyboardHostRecorder.shared.handleDeepLink()
      return true
    }
    return super.application(app, open: url, options: options) || RCTLinkingManager.application(app, open: url, options: options)
  }`,
          );
          console.log(
            "[withKeyboardExtension] Patched AppDelegate for keyboard-record URL",
          );
        }

        // Boot the dictation coordinator so JS module / App Intent can drive it via NotificationCenter.
        if (!ad.includes("KeyboardHostRecorder.shared.bootstrap()")) {
          ad = ad.replace(
            "    return super.application(application, didFinishLaunchingWithOptions: launchOptions)\n  }",
            "    KeyboardHostRecorder.shared.bootstrap()\n    return super.application(application, didFinishLaunchingWithOptions: launchOptions)\n  }",
          );
          console.log(
            "[withKeyboardExtension] Wired KeyboardHostRecorder.shared.bootstrap() into AppDelegate launch",
          );
        }

        if (fs.existsSync(recorderSrcPath)) {
          const body = stripSwiftLeadingImports(
            fs.readFileSync(recorderSrcPath, "utf8"),
          );
          ad = ensureAppDelegateRecorderImports(ad);
          ad = `${ad.trimEnd()}\n\n${KEYBOARD_HOST_INJECT_BEGIN}\n// Source of truth: targets/${HOST_SWIFT_DIR}/${HOST_RECORDER_FILE}\n${body}\n${KEYBOARD_HOST_INJECT_END}\n`;
          console.log(
            "[withKeyboardExtension] Injected KeyboardHostRecorder into AppDelegate.swift",
          );
        } else {
          console.warn(
            `[withKeyboardExtension] Missing ${recorderSrcPath}; open-url handler may not compile.`,
          );
        }

        fs.writeFileSync(appDelegatePath, ad);
      }

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

  // Step 3: Add the Xcode target
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
    // 3c. Extension sources — UI + bridge only (Whisper runs in the main app).
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

      bs.LD_RUNPATH_SEARCH_PATHS = '"$(inherited)"';
      bs.HEADER_SEARCH_PATHS = ['"$(inherited)"'];
      bs.FRAMEWORK_SEARCH_PATHS = ['"$(inherited)"'];
      bs.OTHER_LDFLAGS = '"$(inherited)"';
    });

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
    ensureXcodeDependencyInfrastructure(project);

    const appTarget = project.getTarget("com.apple.product-type.application");
    const extUuid = findKeyboardExtensionTargetUuid(project);
    if (!appTarget?.uuid || !extUuid) return c;

    if (!hostAppAlreadyDependsOnExtension(project, appTarget.uuid, extUuid)) {
      try {
        project.addTargetDependency(appTarget.uuid, [extUuid]);
      } catch {
        // Rare: malformed project graph — run `npx expo prebuild --platform ios`.
      }
    }

    return c;
  });

  return config;
};

export default withKeyboardExtension;
