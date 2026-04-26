import Foundation

/// Downloads and locates the Whisper Tiny model in the App Group container for keyboard handoff.
final class ModelManager {

    static let shared = ModelManager()

    private let groupID = "group.com.emillo2003.codictate-app"
    private let modelFilename = "ggml-tiny-q5_1.bin"
    private let modelURL = URL(string:
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny-q5_1.bin"
    )!
    private let minModelBytes: Int64 = 20 * 1024 * 1024

    enum ModelState {
        case notFound
        case downloading(progress: Double)
        case ready(path: String)
        case failed(String)
    }

    private init() {}

    var modelFilePath: String? {
        containerURL?.appendingPathComponent(modelFilename).path
    }

    private var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupID
        )
    }

    var modelIsReady: Bool {
        guard let path = modelFilePath else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int64) ?? 0
        return size >= minModelBytes
    }

    func ensureModel(
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

        let destPath = container.appendingPathComponent(modelFilename)

        if modelIsReady, let path = modelFilePath {
            onComplete(.success(path))
            return
        }

        if FileManager.default.fileExists(atPath: destPath.path) {
            try? FileManager.default.removeItem(at: destPath)
        }

        onProgress(0)
        let session = URLSession(configuration: .default)
        let task = session.downloadTask(with: modelURL) { tempURL, _, error in
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
}
