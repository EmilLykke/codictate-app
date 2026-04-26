import {
  NativeModule,
  requireNativeModule,
  type EventSubscription,
} from "expo-modules-core";

export type DictationPhase =
  | "idle"
  | "start"
  | "recording"
  | "stop_requested"
  | "processing"
  | "ready"
  | "failed";

export type DictationSource = "host" | "keyboard" | "intent";

export type DictationStateSnapshot = {
  phase: DictationPhase;
  transcript: string | null;
  error: string | null;
  source: DictationSource | null;
};

export type StateChangeEvent = {
  phase: DictationPhase;
  error?: string;
};

export type TranscriptEvent = { transcript: string };
export type ErrorEvent = { message: string };

export type ModelVariant = "base" | "tiny";
export type ModelProgressEvent = { variant: ModelVariant; progress: number };
export type ModelInfo = { variant: ModelVariant; ready: boolean; size: number };

type CodictateDictationEvents = {
  onStateChange: (event: StateChangeEvent) => void;
  onTranscript: (event: TranscriptEvent) => void;
  onError: (event: ErrorEvent) => void;
  onModelProgress: (event: ModelProgressEvent) => void;
};

declare class CodictateDictationNativeModule extends NativeModule<CodictateDictationEvents> {
  start(source?: DictationSource): Promise<void>;
  stop(): Promise<void>;
  cancel(): Promise<void>;
  getState(): Promise<DictationStateSnapshot>;
  consumeTranscript(): Promise<string | null>;
  acknowledgeError(): Promise<void>;
  isModelReady(variant?: ModelVariant): Promise<boolean>;
  ensureModel(variant?: ModelVariant): Promise<void>;
  deleteModel(variant?: ModelVariant): Promise<void>;
  listModels(): Promise<ModelInfo[]>;
}

const Native =
  requireNativeModule<CodictateDictationNativeModule>("CodictateDictation");

export async function start(source: DictationSource = "host"): Promise<void> {
  return Native.start(source);
}

export async function stop(): Promise<void> {
  return Native.stop();
}

export async function cancel(): Promise<void> {
  return Native.cancel();
}

export async function getState(): Promise<DictationStateSnapshot> {
  return Native.getState();
}

/** Reads + clears any "ready" transcript sitting in App Group. Returns null when nothing is queued. */
export async function consumeTranscript(): Promise<string | null> {
  return Native.consumeTranscript();
}

export async function acknowledgeError(): Promise<void> {
  return Native.acknowledgeError();
}

export function onStateChange(
  listener: (event: StateChangeEvent) => void,
): EventSubscription {
  return Native.addListener("onStateChange", listener);
}

export function onTranscript(
  listener: (event: TranscriptEvent) => void,
): EventSubscription {
  return Native.addListener("onTranscript", listener);
}

export function onError(
  listener: (event: ErrorEvent) => void,
): EventSubscription {
  return Native.addListener("onError", listener);
}

export function onModelProgress(
  listener: (event: ModelProgressEvent) => void,
): EventSubscription {
  return Native.addListener("onModelProgress", listener);
}

export async function isModelReady(
  variant: ModelVariant = "base",
): Promise<boolean> {
  return Native.isModelReady(variant);
}

export async function ensureModel(
  variant: ModelVariant = "base",
): Promise<void> {
  return Native.ensureModel(variant);
}

export async function deleteModel(
  variant: ModelVariant = "base",
): Promise<void> {
  return Native.deleteModel(variant);
}

export async function listModels(): Promise<ModelInfo[]> {
  return Native.listModels();
}
