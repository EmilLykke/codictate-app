import Darwin
import Foundation

/// NSLog plus a line in `<App Group>/Library/Logs/keyboard.log`, which the keyboard and the
/// Formatting AU both write, so a device run can be read back without a console:
///
///     xcrun devicectl device copy from --device <id> --domain-type appGroupDataContainer \
///       --domain-identifier group.app.codictate --source Library/Logs/keyboard.log --destination .
///
/// Each line is one `O_APPEND` write, so the two processes interleave whole lines. Past
/// `maxBytes` the file moves to `keyboard.1.log` (one generation kept).
enum AppGroupLog {
    static let maxBytes = 200 * 1024
    private static let queue = DispatchQueue(label: "app.codictate.appgroup-log", qos: .utility)
    private static let process = ProcessInfo.processInfo.processName

    private static let fileURL: URL? = {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.app.codictate"
        ) else { return nil }
        let directory = container.appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("keyboard.log")
    }()

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// `message` carries its own `[Keyboard]` or `[FormattingAU]` prefix.
    static func write(_ message: String) {
        NSLog("%@", message)
        let date = Date()
        let pid = getpid()
        queue.async {
            guard let url = fileURL else { return }
            let line = "\(timestamp.string(from: date)) \(process)[\(pid)] \(message)\n"
            rotateIfNeeded(url)
            let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            defer { close(fd) }
            let bytes = Array(line.utf8)
            _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }
    }

    private static func rotateIfNeeded(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0, Int(info.st_size) > maxBytes else { return }
        let previous = url.deletingLastPathComponent().appendingPathComponent("keyboard.1.log")
        // rename(2) replaces the old generation atomically; a racing process at worst
        // rotates twice.
        _ = rename(url.path, previous.path)
    }
}
