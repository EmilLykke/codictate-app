/// <reference types="node" />

import {
  ConfigPlugin,
  IOSConfig,
  XcodeProject,
  withDangerousMod,
  withXcodeProject,
} from "expo/config-plugins";
import { execFileSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import {
  LLAMA_IOS_SLICES,
  LLAMA_VENDOR_XCFRAMEWORK,
  LLAMA_VERSION,
  LLAMA_XCFRAMEWORK_NAME,
} from "../scripts/vendor-manifest";

const destination = `vendor/${LLAMA_XCFRAMEWORK_NAME}`;

function ensureFramework(projectRoot: string): void {
  // The fetcher checks its version stamp and required slices before taking its fast path.
  // Existence alone is insufficient after the pinned runtime revision changes.
  execFileSync("bun", ["scripts/fetch-llama.ts"], {
    cwd: projectRoot,
    stdio: "inherit",
  });
}

function appendSetting(
  project: XcodeProject,
  targetName: string,
  key: string,
  values: string[],
): void {
  const target = project.pbxTargetByName(targetName);
  const list =
    project.pbxXCConfigurationList()?.[target?.buildConfigurationList];
  const ids = new Set<string>(
    (list?.buildConfigurations ?? []).map(
      (entry: { value: string }) => entry.value,
    ),
  );
  const configs = project.pbxXCBuildConfigurationSection() ?? {};
  for (const id of ids) {
    const settings = configs[id]?.buildSettings;
    if (!settings) continue;
    const current = Array.isArray(settings[key])
      ? settings[key]
      : [settings[key] ?? '"$(inherited)"'];
    for (const value of values)
      if (!current.includes(value)) current.push(value);
    settings[key] = current;
  }
}

const withLlama: ConfigPlugin = (config) => {
  config = withDangerousMod(config, [
    "ios",
    (c) => {
      ensureFramework(c.modRequest.projectRoot);
      const source = path.join(
        c.modRequest.projectRoot,
        LLAMA_VENDOR_XCFRAMEWORK,
      );
      const dest = path.join(c.modRequest.platformProjectRoot, destination);
      fs.rmSync(dest, { recursive: true, force: true });
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.cpSync(source, dest, { recursive: true });
      fs.writeFileSync(
        path.join(c.modRequest.platformProjectRoot, "vendor/.llama-version"),
        `${LLAMA_VERSION}\n`,
      );
      const projectName = c.modRequest.projectName ?? "Codictate";
      const legalDir = path.join(
        c.modRequest.platformProjectRoot,
        projectName,
        "Legal",
      );
      fs.mkdirSync(legalDir, { recursive: true });
      for (const [sourcePath, outputName] of [
        ["third-party/s1-mini/LICENSE", "S1-mini-LICENSE.txt"],
        ["third-party/s1-mini/NOTICE", "S1-mini-NOTICE.txt"],
        ["third-party/llama.cpp/LICENSE", "llama.cpp-LICENSE.txt"],
      ] as const) {
        fs.copyFileSync(
          path.join(c.modRequest.projectRoot, sourcePath),
          path.join(legalDir, outputName),
        );
      }
      return c;
    },
  ]);

  config = withXcodeProject(config, (c) => {
    const project = c.modResults;
    const app = project.getTarget("com.apple.product-type.application");
    if (!app?.uuid || !app.target?.name)
      throw new Error("[withLlama] main app target missing");
    const targetName = String(app.target.name).replace(/^"|"$/g, "");
    if (!project.pbxEmbedFrameworksBuildPhaseObj(app.uuid)) {
      project.addBuildPhase(
        [],
        "PBXCopyFilesBuildPhase",
        "Embed Frameworks",
        app.uuid,
        "frameworks",
      );
    }
    if (!project.hasFile(destination)) {
      project.addFramework(destination, {
        customFramework: true,
        embed: true,
        sign: true,
        target: app.uuid,
      });
    }
    IOSConfig.XcodeUtils.ensureGroupRecursively(project, "Resources");
    for (const name of [
      "S1-mini-LICENSE.txt",
      "S1-mini-NOTICE.txt",
      "llama.cpp-LICENSE.txt",
    ]) {
      const resourcePath = `${targetName}/Legal/${name}`;
      if (!project.hasFile(resourcePath)) {
        IOSConfig.XcodeUtils.addResourceFileToGroup({
          filepath: resourcePath,
          groupName: "Resources",
          project,
          isBuildFile: true,
        });
      }
    }
    appendSetting(project, targetName, "FRAMEWORK_SEARCH_PATHS", [
      '"$(SRCROOT)/vendor"',
    ]);
    appendSetting(
      project,
      targetName,
      "HEADER_SEARCH_PATHS",
      LLAMA_IOS_SLICES.map(
        (slice) =>
          `"$(SRCROOT)/${destination}/${slice}/llama.framework/Headers"`,
      ),
    );
    return c;
  });
  return config;
};

export default withLlama;
