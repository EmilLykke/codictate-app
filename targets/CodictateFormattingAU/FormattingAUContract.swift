import AudioToolbox
import Foundation

// Adapted from KeyVox (`TranscriptionAUContract`, MIT). See NOTICE.

/// The messages between the keyboard and the Formatting AU it hosts out of process.
/// Compiled into both targets. The component codes repeat the ones in the AU's Info.plist.
///
/// Every exchange is synchronous (`AUMessageChannel.callAudioUnit`) and answers at once:
/// `format` starts the work and `poll` reads its state, so no call blocks on S1-mini.
/// An empty answer means the AU's process is gone.
enum FormattingAUContract {
    static let messageChannelName = "app.codictate.formatting-au"

    static var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: fourCharacterCode("s1fm"),
            componentManufacturer: fourCharacterCode("Cdct"),
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    enum Command: String {
        /// Loads S1-mini if it is ready and not loaded. Answers `accepted`.
        case prewarm
        /// Starts formatting `text` (with `requestID`, `languageId`, `style`, `context`),
        /// replacing any request still running. Answers `accepted`.
        case format
        /// Answers the state of `requestID`: `status`, plus `text` or `reason`.
        case poll
        /// Abandons the running request.
        case cancel
        /// Abandons the running request and frees the model.
        case unload
    }

    enum Status: String {
        case pending
        /// S1-mini cleaned the text. An empty `text` is a successful cleanup with no output.
        case formatted
        /// S1-mini did not run (`reason`): deliver the original text.
        case unchanged
        /// S1-mini failed (`reason`): deliver the original text.
        case failed
    }

    enum Key {
        static let command = "command"
        static let requestID = "requestID"
        static let text = "text"
        static let languageId = "languageId"
        static let style = "style"
        static let context = "context"
        static let accepted = "accepted"
        static let status = "status"
        static let reason = "reason"
    }

    private static func fourCharacterCode(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }
}
