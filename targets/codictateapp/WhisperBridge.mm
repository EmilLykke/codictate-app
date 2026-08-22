#import "WhisperBridge.h"
#import "WavPCMReader.h"
#import <TargetConditionals.h>

// crispasr's framework exports the whisper C API this bridge was already written
// against. Quoted, not <crispasr/crispasr.h>: withCrispASR puts both xcframework
// slices' Headers/ on HEADER_SEARCH_PATHS, which resolves the quoted form without
// depending on how Xcode surfaces the framework module.
#import "crispasr.h"

#include <vector>

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
    // This file is built by the main app target only, never by the keyboard extension,
    // so Metal is available.  The old "GPU not available in extensions" comment was
    // describing a target this bridge has never been in.
    cparams.use_gpu = true;
#if TARGET_OS_SIMULATOR
    // ggml's Metal backend is unreliable under the simulator; force the CPU backend.
    cparams.use_gpu = false;
#endif

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
        std::vector<float> pcm = CodictateReadWavAsPCMF32(wavPath, &readError);

        if (readError || pcm.empty()) {
            NSString *msg = readError.localizedDescription ?: @"Failed to read audio file.";
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, msg); });
            return;
        }

        // Run inference
        struct whisper_full_params params = whisper_full_default_params(CRISPASR_SAMPLING_GREEDY);
        params.print_progress   = false;
        params.print_realtime   = false;
        params.print_timestamps = false;
        params.language         = lang.UTF8String;
        params.translate        = false;
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
            if (text) {
                NSString *segment = [NSString stringWithUTF8String:text];
                if (segment) [transcript appendString:segment];
            }
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
