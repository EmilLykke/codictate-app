#import "EkkoBridge.h"
#import "WavPCMReader.h"
#import <TargetConditionals.h>

// The one place parakeet.cpp's header is reached: the iOS parakeet.xcframework ships it in
// the framework's Headers/.
#import <parakeet/parakeet_capi.h>

#include <mutex>
#include <stdlib.h>
#include <vector>

static NSString *const kEkkoBridgeErrorDomain = @"EkkoBridge";

/// `decoder` 0 picks the head by the model's architecture (the transducer for ekko), which is
/// what desktop's `parakeet-cli transcribe` runs with no `--decoder` flag.
static const int kEkkoDefaultDecoder = 0;

/// What desktop's ekko adds to the environment (EKKO_ENV in ekko-engine.ts): the attention
/// context the gate (#78) measured.  parakeet.cpp's encoder reads it with getenv on every
/// forward pass, so it is set once, before the first load.  PARAKEET_DEVICE is left to
/// parakeet.cpp (first GPU, i.e. Metal), as desktop leaves it, except under the simulator,
/// where ggml's Metal backend is unreliable (CohereBridge forces CPU there too).
static void EkkoSetEnvironmentOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        setenv("PARAKEET_ATT_CONTEXT", "128", 1);
#if TARGET_OS_SIMULATOR
        setenv("PARAKEET_DEVICE", "cpu", 1);
#endif
    });
}

static NSError *EkkoError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kEkkoBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *EkkoString(const char *text, NSString *fallback) {
    if (!text || !*text) return fallback;
    return [NSString stringWithUTF8String:text] ?: fallback;
}

@implementation EkkoBridge {
    /// Loaded once and held, the same cache-and-hold pattern as CohereBridge: a Dictation turn
    /// never pays the load.  Guarded by `_lock`, which also keeps one transcription at a time.
    parakeet_ctx *_ctx;
    NSString *_loadedModelPath;
    std::mutex _lock;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _ctx = nullptr;
    }
    return self;
}

- (BOOL)isLoaded {
    std::lock_guard<std::mutex> guard(_lock);
    return _ctx != nullptr;
}

- (NSString *)loadedModelPath {
    std::lock_guard<std::mutex> guard(_lock);
    return _loadedModelPath;
}

- (BOOL)loadModelAtPath:(NSString *)path error:(NSError **)error {
    std::lock_guard<std::mutex> guard(_lock);
    if (_ctx && [_loadedModelPath isEqualToString:path]) return YES;
    [self unloadLocked];

    EkkoSetEnvironmentOnce();
    parakeet_ctx *ctx = parakeet_capi_load(path.fileSystemRepresentation);
    if (!ctx) {
        // Thread-local and valid until the next load on this thread: read it right here.
        NSString *reason = EkkoString(parakeet_capi_load_error(), @"unknown error");
        NSLog(@"[EkkoBridge] Failed to load model at %@: %@", path, reason);
        if (error) {
            *error = EkkoError(1, [NSString stringWithFormat:
                @"Could not load the ekko speech model: %@", reason]);
        }
        return NO;
    }
    _ctx = ctx;
    _loadedModelPath = [path copy];
    NSLog(@"[EkkoBridge] Model loaded from: %@", path);
    return YES;
}

- (NSString *)transcribeSamples:(const float *)samples
                          count:(NSInteger)count
                     sampleRate:(NSInteger)sampleRate
                          error:(NSError **)error {
    std::lock_guard<std::mutex> guard(_lock);
    if (!_ctx) {
        if (error) *error = EkkoError(2, @"The ekko speech model is not loaded.");
        return nil;
    }
    char *raw = parakeet_capi_transcribe_pcm(_ctx, samples, (int)count, (int)sampleRate,
                                             kEkkoDefaultDecoder);
    if (!raw) {
        NSString *reason = EkkoString(parakeet_capi_last_error(_ctx), @"unknown error");
        NSLog(@"[EkkoBridge] Transcription failed: %@", reason);
        if (error) {
            *error = EkkoError(3, [NSString stringWithFormat:
                @"ekko transcription failed: %@", reason]);
        }
        return nil;
    }
    NSString *text = [NSString stringWithUTF8String:raw];
    parakeet_capi_free_string(raw);
    if (!text) {
        if (error) *error = EkkoError(4, @"ekko returned text that is not UTF-8.");
        return nil;
    }
    return text;
}

- (void)unloadModel {
    std::lock_guard<std::mutex> guard(_lock);
    [self unloadLocked];
}

- (void)unloadLocked {
    if (_ctx) {
        parakeet_capi_free(_ctx);
        _ctx = nullptr;
        _loadedModelPath = nil;
        NSLog(@"[EkkoBridge] Model unloaded.");
    }
}

+ (NSData *)readWavAsPCMF32AtPath:(NSString *)path error:(NSError **)error {
    NSError *readError = nil;
    std::vector<float> pcm = CodictateReadWavAsPCMF32(path, &readError);
    if (readError) {
        if (error) {
            *error = [NSError errorWithDomain:kEkkoBridgeErrorDomain code:5 userInfo:@{
                NSLocalizedDescriptionKey: @"Failed to read audio file.",
                NSUnderlyingErrorKey: readError,
            }];
        }
        return nil;
    }
    return [NSData dataWithBytes:pcm.data() length:pcm.size() * sizeof(float)];
}

- (void)dealloc {
    std::lock_guard<std::mutex> guard(_lock);
    [self unloadLocked];
}

@end
