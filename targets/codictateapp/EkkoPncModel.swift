import Foundation

/// The real Punctuation Model: ekko-pnc's weights from a local folder, opened the way the
/// Python reference (`ekko-stt[pnc]==0.1.2`, `Punctuator.__init__`) opens them. Port of
/// desktop `src/bun/utils/punctuation/ekko-pnc-model.ts`.
///
/// - `pnc.int8.onnx` in one ONNX Runtime session on the CPU execution provider
///   (`EkkoPncBridge`).
/// - `tokenizer.json` in `EkkoPncTokenizer`. Python reads nothing else for the tokenizer,
///   so neither does this (`tokenizer_config.json` is not read).
/// - `config.json`'s `id2label` as the label table.
final class EkkoPncModel: PunctuationModel {

    /// `Punctuator(model_filename="pnc.int8.onnx")`.
    static let modelFile = "pnc.int8.onnx"
    static let tokenizerFile = "tokenizer.json"
    static let configFile = "config.json"

    let labels: [Int: String]
    private let tokenizer: EkkoPncTokenizer
    private let bridge: EkkoPncBridge

    /// Open the three runtime files in `directory`. Throws naming the file at fault.
    init(directory: String) throws {
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        let tokenizerURL = folder.appendingPathComponent(Self.tokenizerFile)
        let configURL = folder.appendingPathComponent(Self.configFile)
        let tokenizerData = try Self.read(tokenizerURL)
        labels = try Self.labelTable(try Self.read(configURL), directory: directory)
        tokenizer = try EkkoPncTokenizer(tokenizerJSON: tokenizerData)
        bridge = try EkkoPncBridge(modelPath: folder.appendingPathComponent(Self.modelFile).path)
    }

    func encode(_ words: [String]) throws -> PretokenizedEncoding {
        tokenizer.encode(words)
    }

    func run(_ inputIds: [Int64]) throws -> PunctuationLogits {
        let input = inputIds.withUnsafeBufferPointer { Data(buffer: $0) }
        let output = try bridge.run(inputIds: input)
        let count = output.data.count / MemoryLayout<Float>.size
        let data = output.data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
        return PunctuationLogits(data: data, dims: output.dims.map(\.intValue))
    }

    /// `{int(key): value for key, value in config["id2label"].items()}`.
    private static func labelTable(_ data: Data, directory: String) throws -> [Int: String] {
        guard let config = try? JSONSerialization.jsonObject(with: data) as? NSDictionary,
              let id2label = config["id2label"] as? NSDictionary else {
            throw PunctuationError("invalid PnC config in \(directory): no id2label")
        }
        var labels: [Int: String] = [:]
        for (key, value) in id2label {
            guard let key = key as? String, !key.isEmpty,
                  key.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
                  let id = Int(key), let label = value as? String else {
                throw PunctuationError("invalid PnC config in \(directory): id2label \(key): \(value)")
            }
            labels[id] = label
        }
        return labels
    }

    private static func read(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw PunctuationError("could not read \(url.path): \(error.localizedDescription)")
        }
    }
}
