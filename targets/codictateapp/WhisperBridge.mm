#import "WhisperBridge.h"
#import <whisper.h>
#import <AVFoundation/AVFoundation.h>

#include <vector>

// ---------------------------------------------------------------------------
// Helper: read a 16-kHz mono WAV file into a float32 PCM buffer.
// Whisper requires 32-bit float PCM at exactly 16 000 Hz, mono.
// ---------------------------------------------------------------------------
static std::vector<float> readWavAsPCMF32(NSString *path, NSError **outError) {
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
        if (outError) *outError = [NSError errorWithDomain:@"WhisperBridge" code:1
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

// ---------------------------------------------------------------------------

@implementation WhisperBridge {
    struct whisper_context *_ctx;
    dispatch_queue_t _queue;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _ctx = nullptr;
        _queue = dispatch_queue_create("com.codictate.whisper", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)isLoaded {
    return _ctx != nullptr;
}

- (BOOL)loadModelAtPath:(NSString *)path {
    [self unloadModel];

    struct whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = false; // GPU not available in extensions
    cparams.use_coreml = false;

    struct whisper_context *ctx =
        whisper_init_from_file_with_params(path.UTF8String, cparams);

    if (!ctx) {
        NSLog(@"[WhisperBridge] Failed to load model at: %@", path);
        return NO;
    }

    _ctx = ctx;
    NSLog(@"[WhisperBridge] Model loaded from: %@", path);
    return YES;
}

- (void)transcribeWavFile:(NSString *)wavPath
                 language:(nullable NSString *)language
               completion:(void (^)(NSString * _Nullable, NSString * _Nullable))completion {

    if (!_ctx) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, @"Whisper model is not loaded.");
        });
        return;
    }

    struct whisper_context *ctx = _ctx;
    NSString *lang = language ?: @"auto";

    dispatch_async(_queue, ^{
        // Read WAV into float PCM
        NSError *readError = nil;
        std::vector<float> pcm = readWavAsPCMF32(wavPath, &readError);

        if (readError || pcm.empty()) {
            NSString *msg = readError.localizedDescription ?: @"Failed to read audio file.";
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, msg); });
            return;
        }

        // Run inference
        struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        params.print_progress   = false;
        params.print_realtime   = false;
        params.print_timestamps = false;
        params.language         = lang.UTF8String;
        params.n_threads        = 4;
        params.single_segment   = false;
        params.no_context       = true;

        int result = whisper_full(ctx, params, pcm.data(), (int)pcm.size());
        if (result != 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, @"Whisper transcription failed.");
            });
            return;
        }

        // Collect segments
        NSMutableString *transcript = [NSMutableString string];
        int nSegments = whisper_full_n_segments(ctx);
        for (int i = 0; i < nSegments; i++) {
            const char *text = whisper_full_get_segment_text(ctx, i);
            if (text) [transcript appendFormat:@"%s", text];
        }

        NSString *trimmed = [transcript
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(trimmed.length > 0 ? trimmed : nil, nil);
        });
    });
}

- (void)unloadModel {
    if (_ctx) {
        whisper_free(_ctx);
        _ctx = nullptr;
        NSLog(@"[WhisperBridge] Model unloaded.");
    }
}

- (void)dealloc {
    [self unloadModel];
}

@end
