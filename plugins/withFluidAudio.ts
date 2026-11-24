/// <reference types="node" />

/**
 * Expo config plugin: withFluidAudio
 *
 * Adds the FluidAudio Swift Package (SPM) to the main iOS app target and to the
 * CodictateDictationKeyboard extension. FluidAudio provides Parakeet TDT v3 ASR via CoreML
 * on the Apple Neural Engine; the keyboard runs it for the In-keyboard path. Both targets
 * share one package reference, each with its own product dependency, as Xcode does.
 * Idempotent: a prebuild without --clean re-pins the reference and links any target that
 * is missing the product.
 *
 * Pinned to one exact version: a FluidAudio bump can change the model files or how
 * they load, so it is an upgrade made on purpose, never one a clean build picks up.
 */

import { ConfigPlugin, withXcodeProject } from "expo/config-plugins";

const FLUIDAUDIO_REPO = "https://github.com/FluidInference/FluidAudio.git";
const FLUIDAUDIO_VERSION = "0.15.7";
const FLUIDAUDIO_PRODUCT = "FluidAudio";

type PbxList = { value: string; comment?: string }[];

const KEYBOARD_TARGET_NAME = "CodictateDictationKeyboard";

/** Links FluidAudio to `targetUuid` unless one of its product dependencies already does. */
function linkFluidAudio(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
  targetUuid: string,
  pkgRefUuid: string,
): boolean {
  const objects = project.hash.project.objects;
  const deps = objects.XCSwiftPackageProductDependency;
  const native = project.pbxNativeTargetSection() ?? {};
  const target = native[targetUuid] as
    | { packageProductDependencies?: PbxList }
    | undefined;
  if (!target) return false;
  if (!target.packageProductDependencies) {
    target.packageProductDependencies = [];
  }
  const alreadyLinked = target.packageProductDependencies.some((entry) => {
    const dep = deps[entry.value] as { package?: string } | undefined;
    return dep?.package === pkgRefUuid;
  });
  if (alreadyLinked) return false;

  const pkgDepUuid = project.generateUuid();
  deps[pkgDepUuid] = {
    isa: "XCSwiftPackageProductDependency",
    package: pkgRefUuid,
    productName: `"${FLUIDAUDIO_PRODUCT}"`,
  };
  deps[`${pkgDepUuid}_comment`] = FLUIDAUDIO_PRODUCT;
  target.packageProductDependencies.push({
    value: pkgDepUuid,
    comment: FLUIDAUDIO_PRODUCT,
  });

  // The product in the target's Frameworks build phase.
  const buildFileUuid = project.generateUuid();
  const buildFiles = project.pbxBuildFileSection() ?? {};
  buildFiles[buildFileUuid] = {
    isa: "PBXBuildFile",
    productRef: pkgDepUuid,
  };
  buildFiles[`${buildFileUuid}_comment`] =
    `${FLUIDAUDIO_PRODUCT} in Frameworks`;
  const fwPhase = project.pbxFrameworksBuildPhaseObj(targetUuid);
  if (fwPhase?.files) {
    fwPhase.files.push({
      value: buildFileUuid,
      comment: `${FLUIDAUDIO_PRODUCT} in Frameworks`,
    });
  }
  return true;
}

function findKeyboardTargetUuid(
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  project: any,
): string | undefined {
  const native = project.pbxNativeTargetSection() ?? {};
  return Object.keys(native).find((key) => {
    if (key.endsWith("_comment")) return false;
    const t = native[key] as { name?: string } | undefined;
    return (t?.name ?? "").replace(/^"|"$/g, "") === KEYBOARD_TARGET_NAME;
  });
}

const withFluidAudio: ConfigPlugin = (config) => {
  config = withXcodeProject(config, (c) => {
    const project = c.modResults;
    const objects = project.hash.project.objects;

    if (!objects.XCRemoteSwiftPackageReference) {
      objects.XCRemoteSwiftPackageReference = Object.create(null);
    }
    if (!objects.XCSwiftPackageProductDependency) {
      objects.XCSwiftPackageProductDependency = Object.create(null);
    }

    const existingRefs = objects.XCRemoteSwiftPackageReference;
    let pkgRefUuid = Object.keys(existingRefs).find((key) => {
      if (key.endsWith("_comment")) return false;
      const ref = existingRefs[key] as { repositoryURL?: string } | undefined;
      return ref?.repositoryURL?.includes("FluidAudio");
    });

    if (pkgRefUuid) {
      // A prebuild without --clean keeps the old reference; re-pin it so it never
      // keeps a range from before the pin.
      const ref = existingRefs[pkgRefUuid] as { requirement?: unknown };
      ref.requirement = {
        kind: "exactVersion",
        version: `"${FLUIDAUDIO_VERSION}"`,
      };
    } else {
      pkgRefUuid = project.generateUuid() as string;
      existingRefs[pkgRefUuid] = {
        isa: "XCRemoteSwiftPackageReference",
        repositoryURL: `"${FLUIDAUDIO_REPO}"`,
        requirement: {
          kind: "exactVersion",
          version: `"${FLUIDAUDIO_VERSION}"`,
        },
      };
      existingRefs[`${pkgRefUuid}_comment`] =
        'XCRemoteSwiftPackageReference "FluidAudio"';
    }

    const projectSection = objects.PBXProject ?? {};
    for (const key of Object.keys(projectSection)) {
      if (key.endsWith("_comment")) continue;
      const pbxProject = projectSection[key] as {
        packageReferences?: PbxList;
      };
      if (!pbxProject.packageReferences) {
        pbxProject.packageReferences = [];
      }
      const alreadyRef = pbxProject.packageReferences.some(
        (entry) => entry.value === pkgRefUuid,
      );
      if (!alreadyRef) {
        pbxProject.packageReferences.push({
          value: pkgRefUuid,
          comment: `XCRemoteSwiftPackageReference "${FLUIDAUDIO_PRODUCT}"`,
        });
      }
    }

    const linked: string[] = [];
    const appTarget = project.getTarget("com.apple.product-type.application");
    if (
      appTarget?.uuid &&
      linkFluidAudio(project, appTarget.uuid, pkgRefUuid)
    ) {
      linked.push("app");
    }
    // withKeyboardExtension adds the keyboard target; this plugin sits inside it in
    // app.config.ts, and Expo runs inner plugins' mods later, so the target exists here.
    const keyboardUuid = findKeyboardTargetUuid(project);
    if (!keyboardUuid) {
      console.warn(
        `[withFluidAudio] ${KEYBOARD_TARGET_NAME} target not found; FluidAudio not linked to it`,
      );
    } else if (linkFluidAudio(project, keyboardUuid, pkgRefUuid)) {
      linked.push(KEYBOARD_TARGET_NAME);
    }

    console.log(
      `[withFluidAudio] FluidAudio pinned to ${FLUIDAUDIO_VERSION}; newly linked: ${linked.join(", ") || "none"}`,
    );

    return c;
  });

  return config;
};

export default withFluidAudio;
