/// <reference types="node" />

/**
 * Expo config plugin: withOnnxRuntime
 *
 * Vendors the pinned onnxruntime.xcframework (ekko-pnc's runtime) into
 * ios/vendor/ and links it into the main app target only. Microsoft ships it as
 * a *static* framework, so it is linked into the app binary and not embedded,
 * and the system frameworks its podspec declares are added to OTHER_LDFLAGS.
 * Import it as `#import <onnxruntime/onnxruntime_c_api.h>` (or
 * `onnxruntime_cxx_api.h`).
 *
 * Like withLlama it runs `fetch-onnxruntime` itself and relies on that script's
 * fast path, and it bundles ONNX Runtime's LICENSE and ThirdPartyNotices.txt
 * under Legal/.
 */

import {
  ConfigPlugin,
  withDangerousMod,
  withXcodeProject,
} from "expo/config-plugins";
import { execFileSync } from "child_process";

import {
  ONNXRUNTIME_SYSTEM_FRAMEWORKS,
  ONNXRUNTIME_VENDOR_XCFRAMEWORK,
  ONNXRUNTIME_VERSION,
  ONNXRUNTIME_XCFRAMEWORK_NAME,
} from "../scripts/vendor-manifest";
import {
  addLegalResources,
  appendBuildSettingList,
  appendLinkedSystemFrameworks,
  copyLegalFiles,
  copyXcframework,
  linkXcframework,
  mainAppTarget,
} from "./vendor-xcode";

const LOG = "[withOnnxRuntime]";
const destination = `vendor/${ONNXRUNTIME_XCFRAMEWORK_NAME}`;
const legalFiles = [
  ["third-party/onnxruntime/LICENSE", "onnxruntime-LICENSE.txt"],
  [
    "third-party/onnxruntime/ThirdPartyNotices.txt",
    "onnxruntime-ThirdPartyNotices.txt",
  ],
] as const;

const withOnnxRuntime: ConfigPlugin = (config) => {
  config = withDangerousMod(config, [
    "ios",
    (c) => {
      const { projectRoot, platformProjectRoot } = c.modRequest;
      execFileSync("bun", ["scripts/fetch-onnxruntime.ts"], {
        cwd: projectRoot,
        stdio: "inherit",
      });
      copyXcframework(
        projectRoot,
        platformProjectRoot,
        ONNXRUNTIME_VENDOR_XCFRAMEWORK,
        destination,
        ".onnxruntime-version",
        ONNXRUNTIME_VERSION,
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

  // Main app target only: the keyboard and widget extensions run no models.
  config = withXcodeProject(config, (c) => {
    const project = c.modResults;
    const app = mainAppTarget(project, LOG);
    const added = linkXcframework(project, app.uuid, destination, false);
    console.log(
      `${LOG} ${ONNXRUNTIME_XCFRAMEWORK_NAME} ${added ? "linked in" : "already linked in"} ${app.name}`,
    );
    appendBuildSettingList(project, app.name, "FRAMEWORK_SEARCH_PATHS", [
      '"$(SRCROOT)/vendor"',
    ]);
    appendLinkedSystemFrameworks(
      project,
      app.name,
      ONNXRUNTIME_SYSTEM_FRAMEWORKS,
    );
    addLegalResources(
      project,
      app,
      legalFiles.map(([, name]) => name),
    );
    return c;
  });

  return config;
};

export default withOnnxRuntime;
