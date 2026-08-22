#import "WavPCMReader.h"
#import <AVFoundation/AVFoundation.h>

std::vector<float> CodictateReadWavAsPCMF32(NSString *path, NSError **outError) {
    std::vector<float> samples;

    NSURL *url = [NSURL fileURLWithPath:path];
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:outError];
    if (!file) return samples;

    // Build a format descriptor: 16 kHz, mono, float32
    AVAudioFormat *targetFormat = [[AVAudioFormat alloc]
        initWithCommonFormat:AVAudioPCMFormatFloat32
                  sampleRate:16000.0
                    channels:1
                 interleaved:NO];
    if (!targetFormat) {
        if (outError) *outError = [NSError errorWithDomain:@"WavPCMReader" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Failed to create target format"}];
        return samples;
    }

    // Use AVAudioConverter to resample if necessary
    AVAudioConverter *converter = [[AVAudioConverter alloc]
        initFromFormat:file.processingFormat
              toFormat:targetFormat];

    // Allocate a buffer for the entire file in the source format
    AVAudioFrameCount frameCapacity = (AVAudioFrameCount)file.length;
    AVAudioPCMBuffer *sourceBuffer = [[AVAudioPCMBuffer alloc]
        initWithPCMFormat:file.processingFormat
            frameCapacity:frameCapacity];
    if (!sourceBuffer) return samples;

    if (![file readIntoBuffer:sourceBuffer error:outError]) return samples;

    // Allocate output buffer (16 kHz might differ in frame count)
    double ratio = 16000.0 / file.processingFormat.sampleRate;
    AVAudioFrameCount outFrames = (AVAudioFrameCount)(frameCapacity * ratio + 1);
    AVAudioPCMBuffer *outputBuffer = [[AVAudioPCMBuffer alloc]
        initWithPCMFormat:targetFormat
            frameCapacity:outFrames];
    if (!outputBuffer) return samples;

    // Convert / resample
    __block BOOL inputConsumed = NO;
    AVAudioConverterOutputStatus status = [converter
        convertToBuffer:outputBuffer
                  error:outError
     withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount inNumPackets,
                                         AVAudioConverterInputStatus *outStatus) {
        if (inputConsumed) {
            *outStatus = AVAudioConverterInputStatus_NoDataNow;
            return nil;
        }
        inputConsumed = YES;
        *outStatus = AVAudioConverterInputStatus_HaveData;
        return sourceBuffer;
    }];

    if (status == AVAudioConverterOutputStatus_Error) return samples;

    AVAudioFrameCount framesFilled = outputBuffer.frameLength;
    float *data = outputBuffer.floatChannelData[0];
    samples.assign(data, data + framesFilled);
    return samples;
}
