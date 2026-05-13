/// <reference types="node" />

/**
 * Expo config plugin: withFluidAudio
 *
 * Adds the FluidAudio Swift Package (SPM) to the main iOS app target.
 * FluidAudio provides Parakeet TDT v3 ASR via CoreML on the Apple Neural Engine.
 */

import { ConfigPlugin, withXcodeProject } from "expo/config-plugins";

const FLUIDAUDIO_REPO = "https://github.com/FluidInference/FluidAudio.git";
const FLUIDAUDIO_MIN_VERSION = "0.14.5";
const FLUIDAUDIO_PRODUCT = "FluidAudio";

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
    const alreadyAdded = Object.keys(existingRefs).some((key) => {
      if (key.endsWith("_comment")) return false;
      const ref = existingRefs[key] as { repositoryURL?: string } | undefined;
      return ref?.repositoryURL?.includes("FluidAudio");
    });

    if (alreadyAdded) {
      console.log(
        "[withFluidAudio] FluidAudio package already added; skipping",
      );
      return c;
    }

    const pkgRefUuid = project.generateUuid();
    const pkgDepUuid = project.generateUuid();

    existingRefs[pkgRefUuid] = {
      isa: "XCRemoteSwiftPackageReference",
      repositoryURL: `"${FLUIDAUDIO_REPO}"`,
      requirement: {
        kind: "upToNextMajorVersion",
        minimumVersion: `"${FLUIDAUDIO_MIN_VERSION}"`,
      },
    };
    existingRefs[`${pkgRefUuid}_comment`] =
      'XCRemoteSwiftPackageReference "FluidAudio"';

    objects.XCSwiftPackageProductDependency[pkgDepUuid] = {
      isa: "XCSwiftPackageProductDependency",
      package: pkgRefUuid,
      productName: `"${FLUIDAUDIO_PRODUCT}"`,
    };
    objects.XCSwiftPackageProductDependency[`${pkgDepUuid}_comment`] =
      FLUIDAUDIO_PRODUCT;

    const projectSection = objects.PBXProject ?? {};
    for (const key of Object.keys(projectSection)) {
      if (key.endsWith("_comment")) continue;
      const pbxProject = projectSection[key] as {
        packageReferences?: { value: string; comment?: string }[];
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

    const appTarget = project.getTarget("com.apple.product-type.application");
    if (appTarget?.uuid) {
      const native = project.pbxNativeTargetSection() ?? {};
      const target = native[appTarget.uuid] as {
        packageProductDependencies?: { value: string; comment?: string }[];
      };
      if (target) {
        if (!target.packageProductDependencies) {
          target.packageProductDependencies = [];
        }
        const alreadyDep = target.packageProductDependencies.some(
          (entry) => entry.value === pkgDepUuid,
        );
        if (!alreadyDep) {
          target.packageProductDependencies.push({
            value: pkgDepUuid,
            comment: FLUIDAUDIO_PRODUCT,
          });
        }
      }
    }

    // Add FluidAudio to the build file section for the Frameworks build phase.
    const buildFileUuid = project.generateUuid();
    const buildFiles = project.pbxBuildFileSection() ?? {};
    buildFiles[buildFileUuid] = {
      isa: "PBXBuildFile",
      productRef: pkgDepUuid,
    };
    buildFiles[`${buildFileUuid}_comment`] =
      `${FLUIDAUDIO_PRODUCT} in Frameworks`;

    if (appTarget?.uuid) {
      const fwPhase = project.pbxFrameworksBuildPhaseObj(appTarget.uuid);
      if (fwPhase?.files) {
        fwPhase.files.push({
          value: buildFileUuid,
          comment: `${FLUIDAUDIO_PRODUCT} in Frameworks`,
        });
      }
    }

    console.log(
      `[withFluidAudio] Added FluidAudio SPM package (>= ${FLUIDAUDIO_MIN_VERSION})`,
    );

    return c;
  });

  return config;
};

export default withFluidAudio;
