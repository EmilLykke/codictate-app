#import "CohereBridge.h"
#import "WavPCMReader.h"
#import <TargetConditionals.h>

// crispasr ships cohere.h outside the framework's Headers/ folder, so it is
// vendored at vendors/crispasr/include/cohere.h and reached via the header
// search path rather than through the framework module.
#import "cohere.h"

#include <stdlib.h>
#include <vector>

/// hviske is Danish only.  Never pass NULL for the language: upstream autodetect
/// is unimplemented and a wrong code yields a fluent wrong-language transcript
/// with no error at all.
static NSString *const kCohereFallbackLanguage = @"da";

@implementation CohereBridge {
    /// The cohere context is loaded once and held resident, the same cache-and-hold
    /// pattern WhisperBridge uses.  Kept deliberately: see
    /// docs/adr/0001-crispasr-as-the-ios-asr-harness.md.  hviske measured ~282 MB peak
    /// RSS on desktop, and the keyboard warm session keeps this process alive in the
    /// background, which is the state iOS jetsams first.  If device testing shows
    /// jetsam, the agreed remedy is to free the context on
    /// UIApplication.didEnterBackgroundNotification when no dictation is in flight and
    /// reload it lazily, paying reload latency on the warm path.  Not implemented yet.
    struct cohere_context *_ctx;
    dispatch_queue_t _queue;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _ctx = nullptr;
        _queue = dispatch_queue_create("com.codictate.cohere", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)isLoaded {
    return _ctx != nullptr;
}

- (BOOL)loadModelAtPath:(NSString *)path {
    [self unloadModel];

    struct cohere_context_params cparams = cohere_context_default_params();
    cparams.use_gpu = true;
#if TARGET_OS_SIMULATOR
    // ggml's Metal backend is unreliable under the simulator; force the CPU backend.
    cparams.use_gpu = false;
#endif

    struct cohere_context *ctx =
        cohere_init_from_file(path.UTF8String, cparams);

    if (!ctx) {
        NSLog(@"[CohereBridge] Failed to load model at: %@", path);
        return NO;
    }

    _ctx = ctx;
    NSLog(@"[CohereBridge] Model loaded from: %@", path);
    return YES;
}

- (void)transcribeWavFile:(NSString *)wavPath
                 language:(NSString *)language
               completion:(void (^)(NSString * _Nullable, NSString * _Nullable))completion {

    if (!_ctx) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, @"Danish model is not loaded.");
        });
        return;
    }

    struct cohere_context *ctx = _ctx;
    NSString *lang = language.length > 0 ? language : kCohereFallbackLanguage;

    dispatch_async(_queue, ^{
        // Read WAV into float PCM
        NSError *readError = nil;
        std::vector<float> pcm = CodictateReadWavAsPCMF32(wavPath, &readError);

        if (readError || pcm.empty()) {
            NSString *msg = readError.localizedDescription ?: @"Failed to read audio file.";
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, msg); });
            return;
        }

        // Run inference.  cohere_transcribe returns a malloc'd UTF-8 string the
        // caller owns.
        char *raw = cohere_transcribe(ctx, pcm.data(), (int)pcm.size(), lang.UTF8String);
        if (!raw) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, @"Danish transcription failed.");
            });
            return;
        }

        NSString *text = [NSString stringWithUTF8String:raw];
        free(raw);

        NSString *trimmed = [(text ?: @"")
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(trimmed.length > 0 ? trimmed : nil, nil);
        });
    });
}

- (void)unloadModel {
    if (_ctx) {
        cohere_free(_ctx);
        _ctx = nullptr;
        NSLog(@"[CohereBridge] Model unloaded.");
    }
}

- (void)dealloc {
    [self unloadModel];
}

@end
