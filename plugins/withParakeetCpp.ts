/// <reference types="node" />

/**
 * Expo config plugin: withParakeetCpp
 *
 * Vendors the pinned parakeet.xcframework (ekko's ASR runtime) into ios/vendor/
 * and links and embeds it, with Code Sign On Copy, in the main app target only.
 * It is a dynamic framework whose only exports are `parakeet_capi_*`; its ggml
 * stays private, so it lives beside crispasr's and llama's without either
 * binding to the other. Import it as `#import <parakeet/parakeet_capi.h>`.
 *
 * Like withLlama it runs `fetch-parakeet` itself and relies on that script's
 * fast path, and it bundles the parakeet.cpp and ggml licenses under Legal/.
 */

import {
  ConfigPlugin,
  withDangerousMod,
  withXcodeProject,
} from "expo/config-plugins";
import { execFileSync } from "child_process";

import {
  PARAKEET_STAMP,
  PARAKEET_VENDOR_XCFRAMEWORK,
  PARAKEET_XCFRAMEWORK_NAME,
} from "../scripts/vendor-manifest";
import {
  addLegalResources,
  appendBuildSettingList,
  copyLegalFiles,
  copyXcframework,
  linkXcframework,
  mainAppTarget,
} from "./vendor-xcode";

const LOG = "[withParakeetCpp]";
const destination = `vendor/${PARAKEET_XCFRAMEWORK_NAME}`;
const legalFiles = [
  ["third-party/parakeet.cpp/LICENSE", "parakeet.cpp-LICENSE.txt"],
  ["third-party/parakeet.cpp/LICENSE-ggml", "parakeet.cpp-ggml-LICENSE.txt"],
] as const;

const withParakeetCpp: ConfigPlugin = (config) => {
  config = withDangerousMod(config, [
    "ios",
    (c) => {
      const { projectRoot, platformProjectRoot } = c.modRequest;
      execFileSync("bun", ["scripts/fetch-parakeet.ts"], {
        cwd: projectRoot,
        stdio: "inherit",
      });
      copyXcframework(
        projectRoot,
        platformProjectRoot,
        PARAKEET_VENDOR_XCFRAMEWORK,
        destination,
        ".parakeet-version",
        PARAKEET_STAMP,
      );
      copyLegalFiles(
        projectRoot,
        platformProjectRoot,
        c.modRequest.projectName ?? "Codictate",
        legalFiles,
      );
      return c;
    },
  ]);

  // Main app target only: the keyboard and widget extensions run no ASR.
  config = withXcodeProject(config, (c) => {
    const project = c.modResults;
    const app = mainAppTarget(project, LOG);
    const added = linkXcframework(project, app.uuid, destination, true);
    console.log(
      `${LOG} ${PARAKEET_XCFRAMEWORK_NAME} ${added ? "linked and embedded in" : "already linked in"} ${app.name}`,
    );
    appendBuildSettingList(project, app.name, "FRAMEWORK_SEARCH_PATHS", [
      '"$(SRCROOT)/vendor"',
    ]);
    addLegalResources(
      project,
      app,
      legalFiles.map(([, name]) => name),
    );
    return c;
  });

  return config;
};

export default withParakeetCpp;
