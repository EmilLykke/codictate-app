import ActivityKit
import Foundation

struct DictationActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var phase: String
        var startDate: Date
        var processingStartDate: Date? = nil
        var statusMessage: String? = nil
    }
}
