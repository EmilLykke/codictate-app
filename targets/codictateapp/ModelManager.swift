import Foundation

/// Downloads and locates Whisper GGML models in the App Group container.
///
/// Two models live side-by-side:
///   • `tiny`  (~57 MB) — used by the keyboard extension and any keyboard-source dictation
///                        (extension memory is tight, can't load Base)
///   • `base`  (~143 MB) — used by host-app dictation (in-app + Action Button) for higher quality
///
/// Both download into the shared App Group so the keyboard extension can read either one.
final class ModelManager {

    enum Variant: String {
        case tiny
        case base

        var filename: String {
            switch self {
            case .tiny: return "ggml-tiny-q5_1.bin"
            case .base: return "ggml-base-q5_1.bin"
            }
        }

        var url: URL {
            switch self {
            case .tiny:
                return URL(string:
                    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q5_1.bin"
                )!
            case .base:
                return URL(string:
                    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base-q5_1.bin"
                )!
            }
        }

        var minBytes: Int64 {
            switch self {
            case .tiny: return 20 * 1024 * 1024
            case .base: return 52 * 1024 * 1024
            }
        }
    }

    static let shared = ModelManager()

    private let groupID = "group.com.emillo2003.codictate-app"

    private init() {}

    // MARK: - Public API

    /// Default model used by `KeyboardHostTranscription`. Stays `.tiny` for backward
    /// compatibility with the keyboard handoff path; host/intent paths call
    /// `ensureModel(variant:...)` explicitly with `.base`.
    var modelFilePath: String? {
        modelFilePath(for: .tiny)
    }

    var modelIsReady: Bool {
        modelIsReady(for: .tiny)
    }

    func modelFilePath(for variant: Variant) -> String? {
        containerURL?.appendingPathComponent(variant.filename).path
    }

    func modelIsReady(for variant: Variant) -> Bool {
        guard let path = modelFilePath(for: variant) else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int64) ?? 0
        return size >= variant.minBytes
    }

    /// Default ensure (Tiny) — kept for backward compatibility with keyboard flow.
    func ensureModel(
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        ensureModel(variant: .tiny, onProgress: onProgress, onComplete: onComplete)
    }

    /// Pick a specific variant. Skips the network if the file already exists at >= minBytes.
    func ensureModel(
        variant: Variant,
        onProgress: @escaping (Double) -> Void,
        onComplete: @escaping (Result<String, Error>) -> Void
    ) {
        guard let container = containerURL else {
            onComplete(.failure(NSError(
                domain: "ModelManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable."]
            )))
            return
        }

        let destPath = container.appendingPathComponent(variant.filename)

        if modelIsReady(for: variant), let path = modelFilePath(for: variant) {
            onComplete(.success(path))
            return
        }

        // Stale / partial file: clear before downloading.
        if FileManager.default.fileExists(atPath: destPath.path) {
            try? FileManager.default.removeItem(at: destPath)
        }

        onProgress(0)
        let session = URLSession(configuration: .default)
        let task = session.downloadTask(with: variant.url) { tempURL, _, error in
            DispatchQueue.main.async {
                onProgress(1)
                if let error {
                    onComplete(.failure(error))
                    return
                }
                guard let tempURL else {
                    onComplete(.failure(NSError(
                        domain: "ModelManager", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Download produced no file."]
                    )))
                    return
                }
                do {
                    try FileManager.default.moveItem(at: tempURL, to: destPath)
                    onComplete(.success(destPath.path))
                } catch {
                    onComplete(.failure(error))
                }
            }
        }
        task.resume()
    }

    // MARK: - Private

    private var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        )
    }
}
