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

export type ModelVariant = "parakeet" | "base" | "base_en" | "hviske";
export type ModelProgressEvent = { variant: ModelVariant; progress: number };
export type ModelInfo = { variant: ModelVariant; ready: boolean; size: number };

export type FormattingModel = "off" | "s1-mini";
export type FormattingStyle =
  | "casual"
  | "semi-casual"
  | "semi-formal"
  | "formal";
export type FormattingContext = "general" | "email";
export type FormattingModelProgressEvent = { progress: number };
export type FormattingModelStatus = {
  ready: boolean;
  downloading: boolean;
  size: number;
  expectedSize: number;
  path: string | null;
  error?: string;
};

/** Closed set. The Host produces the message for each one; JS only renders it. */
export type DictationBlockedReason =
  | "weightsMissing"
  | "downloadInProgress"
  | "languageUnsupportedByModel"
  | "micPermissionMissing";

/**
 * Whether the current (Speech Model, Transcription Language, permissions)
 * combination can start a Dictation turn. Computed in the Host, because keyboard
 * and Action Button dictation run with no React Native process alive.
 */
export type DictationReadiness =
  | { blocked: false; reason: null; message: null }
  | { blocked: true; reason: DictationBlockedReason; message: string };

type CodictateDictationEvents = {
  onStateChange: (event: StateChangeEvent) => void;
  onTranscript: (event: TranscriptEvent) => void;
  onError: (event: ErrorEvent) => void;
  onModelProgress: (event: ModelProgressEvent) => void;
  onFormattingModelProgress: (event: FormattingModelProgressEvent) => void;
  onFormattingModelStatus: (event: FormattingModelStatus) => void;
  "codictate.readiness.changed": (event: DictationReadiness) => void;
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
  getPreferredModel(): Promise<ModelVariant>;
  setPreferredModel(variant: ModelVariant): Promise<void>;
  getTranscriptionLanguageId(): string;
  setTranscriptionLanguageId(id: string): void;
  getDictationReadiness(): DictationReadiness;
  getFormattingModel(): FormattingModel;
  setFormattingModel(model: FormattingModel): void;
  getFormattingStyle(): FormattingStyle;
  setFormattingStyle(style: FormattingStyle): void;
  getFormattingContext(): FormattingContext;
  setFormattingContext(context: FormattingContext): void;
  isFormattingModelReady(): Promise<boolean>;
  ensureFormattingModel(): Promise<string>;
  deleteFormattingModel(): Promise<void>;
  getFormattingModelStatus(): Promise<FormattingModelStatus>;
  getKeyboardWarmDuration(): Promise<number>;
  setKeyboardWarmDuration(seconds: number): Promise<void>;
  isKeyboardWarmSessionActive(): Promise<boolean>;
  endKeyboardWarmSession(): Promise<void>;
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

export function onFormattingModelProgress(
  listener: (event: FormattingModelProgressEvent) => void,
): EventSubscription {
  return Native.addListener("onFormattingModelProgress", listener);
}

export function onFormattingModelStatus(
  listener: (event: FormattingModelStatus) => void,
): EventSubscription {
  return Native.addListener("onFormattingModelStatus", listener);
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

const KNOWN_VARIANTS: ModelVariant[] = [
  "parakeet",
  "base",
  "base_en",
  "hviske",
];

export async function getPreferredModel(): Promise<ModelVariant> {
  const v = await Native.getPreferredModel();
  return KNOWN_VARIANTS.includes(v as ModelVariant)
    ? (v as ModelVariant)
    : "base";
}

export async function setPreferredModel(variant: ModelVariant): Promise<void> {
  return Native.setPreferredModel(variant);
}

/**
 * The Transcription Language id, from `TRANSCRIPTION_LANGUAGE_OPTIONS` or "auto".
 * Synchronous: it is a single App Group UserDefaults read, and the Host needs the
 * same value with no JS process alive.
 */
export function getTranscriptionLanguageId(): string {
  return Native.getTranscriptionLanguageId();
}

export function setTranscriptionLanguageId(id: string): void {
  Native.setTranscriptionLanguageId(id);
}

export function getDictationReadiness(): DictationReadiness {
  return Native.getDictationReadiness();
}

export function addDictationReadinessListener(
  listener: (readiness: DictationReadiness) => void,
): EventSubscription {
  return Native.addListener("codictate.readiness.changed", listener);
}

export function getFormattingModel(): FormattingModel {
  return Native.getFormattingModel();
}

export function setFormattingModel(model: FormattingModel): void {
  Native.setFormattingModel(model);
}

export function getFormattingStyle(): FormattingStyle {
  return Native.getFormattingStyle();
}

export function setFormattingStyle(style: FormattingStyle): void {
  Native.setFormattingStyle(style);
}

export function getFormattingContext(): FormattingContext {
  return Native.getFormattingContext();
}

export function setFormattingContext(context: FormattingContext): void {
  Native.setFormattingContext(context);
}

export async function isFormattingModelReady(): Promise<boolean> {
  return Native.isFormattingModelReady();
}

export async function ensureFormattingModel(): Promise<string> {
  return Native.ensureFormattingModel();
}

export async function deleteFormattingModel(): Promise<void> {
  return Native.deleteFormattingModel();
}

export async function getFormattingModelStatus(): Promise<FormattingModelStatus> {
  return Native.getFormattingModelStatus();
}

export async function getKeyboardWarmDuration(): Promise<number> {
  return Native.getKeyboardWarmDuration();
}

export async function setKeyboardWarmDuration(seconds: number): Promise<void> {
  return Native.setKeyboardWarmDuration(seconds);
}

export async function isKeyboardWarmSessionActive(): Promise<boolean> {
  return Native.isKeyboardWarmSessionActive();
}

export async function endKeyboardWarmSession(): Promise<void> {
  return Native.endKeyboardWarmSession();
}
