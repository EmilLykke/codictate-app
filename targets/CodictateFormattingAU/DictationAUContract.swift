import AudioToolbox
import Foundation

// Adapted from KeyVox (`TranscriptionAUContract`, MIT). See NOTICE.

/// The messages between the keyboard and the Dictation AU it hosts out of process.
/// Compiled into both targets. The component codes repeat the ones in the AU's Info.plist.
///
/// Every exchange is synchronous (`AUMessageChannel.callAudioUnit`) and answers at once:
/// `format` and `transcribe` start the work and `poll` reads its state, so no call blocks on
/// a model. One request at a time; a new one replaces the one before. An empty answer means
/// the AU's process is gone.
enum DictationAUContract {
    static let messageChannelName = "app.codictate.dictation-au"

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
        /// Loads S1-mini if it is selected, ready and not loaded, and with `variant` (any
        /// Speech Model but `parakeet`) that Speech Model too. Frees S1-mini when it is no
        /// longer selected, and with `variant` `parakeet` the loaded Speech Model (the
        /// keyboard's model switcher). Answers `accepted`.
        case prewarm
        /// Starts formatting `text` (with `requestID`, `languageId`, `style`, `context`).
        /// For the In-keyboard path's Parakeet turns. Answers `accepted`.
        case format
        /// Starts transcribing the WAV at `wavPath` (relative to the App Group container,
        /// inside `KeyboardRecordings/`) with `variant` (any Speech Model but `parakeet`) and
        /// the stored Transcription Language `languageId`, as the Host would: Language Lock,
        /// Dictation Readiness, the engine, Punctuation Restoration for ekko, then S1-mini
        /// when eligible. `audioSeconds` is for the logs. Answers `accepted`.
        case transcribe
        /// Answers the state of `requestID`: `status`, plus `text` or `reason`.
        case poll
        /// Abandons the running request.
        case cancel
        /// Abandons the running request and frees every model.
        case unload
    }

    enum Status: String {
        case pending
        /// `transcribe`: the Speech Model's text (after Punctuation Restoration) is `text`,
        /// and S1-mini is formatting it. A keyboard out of time may insert `text`.
        case formatting
        /// `transcribe`: the text to insert is `text`. Empty: no speech, or S1-mini cleaned
        /// the transcript down to nothing.
        case transcribed
        /// `transcribe`: Dictation Readiness refused the turn (`reason`); nothing ran.
        case blocked
        /// `format`: S1-mini cleaned the text. An empty `text` is a successful cleanup with no
        /// output.
        case formatted
        /// `format`: S1-mini did not run (`reason`): deliver the original text.
        case unchanged
        /// `format`: S1-mini failed (`reason`): deliver the original text. `transcribe`: the
        /// Speech Model failed (`reason`): there is no text.
        case failed
    }

    enum Key {
        static let command = "command"
        static let requestID = "requestID"
        static let text = "text"
        static let languageId = "languageId"
        static let style = "style"
        static let context = "context"
        static let variant = "variant"
        static let wavPath = "wavPath"
        static let audioSeconds = "audioSeconds"
        static let accepted = "accepted"
        static let status = "status"
        static let reason = "reason"
    }

    private static func fourCharacterCode(_ code: String) -> FourCharCode {
        code.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }
}
