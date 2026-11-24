import AVFoundation
import AudioToolbox
import CoreAudioKit
import UIKit

// Adapted from KeyVox (`TranscriptionAU`, `TranscriptionAUViewController`, MIT). See NOTICE.

/// The Formatting AU's entry point (`NSExtensionPrincipalClass`). The AU has no interface;
/// it is the UI kind of Audio Unit extension (`com.apple.AudioUnit-UI`) only because iOS runs
/// that kind without the plain kind's memory ceiling, which S1-mini would not fit under.
final class FormattingAUViewController: AUViewController, AUAudioUnitFactory {
    override func loadView() {
        view = UIView()
    }

    func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let unit = try FormattingAU(componentDescription: componentDescription)
        AppGroupLog.write("[FormattingAU] Audio unit created \(FormattingAUMemory.current())")
        return unit
    }
}

/// An Audio Unit the keyboard hosts for its message channel, which runs S1-mini in this
/// extension's process. It passes audio through unchanged, so a music app that lists it as
/// an effect gets a bypass rather than an error.
final class FormattingAU: AUAudioUnit {
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    override init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = []
    ) throws {
        try super.init(componentDescription: componentDescription, options: options)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) else {
            throw NSError(domain: "FormattingAU", code: 1)
        }
        inputBusArray = AUAudioUnitBusArray(
            audioUnit: self, busType: .input, busses: [try AUAudioUnitBus(format: format)]
        )
        outputBusArray = AUAudioUnitBusArray(
            audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: format)]
        )
        maximumFramesToRender = 4_096
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    override var canProcessInPlace: Bool { true }

    override var internalRenderBlock: AUInternalRenderBlock {
        { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            var flags = AudioUnitRenderActionFlags()
            // In place: the input lands in the output buffers.
            return pullInputBlock(&flags, timestamp, frameCount, 0, outputData)
        }
    }

    override func messageChannel(for channelName: String) -> any AUMessageChannel {
        guard channelName == FormattingAUContract.messageChannelName else {
            return super.messageChannel(for: channelName)
        }
        return FormattingAUMessageChannel.shared
    }
}
