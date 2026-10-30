#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C wrapper around parakeet.cpp's C API (`parakeet_capi.h`, v0.6.1), the ASR
/// Harness that runs the Danish ekko Speech Model in-process.  Only Foundation types cross
/// this header, so the Swift bridging header never needs parakeet's.
///
/// Every method is synchronous and may block for seconds; call them off the main thread.
/// Access to the loaded context is serialised inside the bridge, so any thread may call in.
NS_SWIFT_SENDABLE
@interface EkkoBridge : NSObject

/// YES while a model is loaded.
@property (nonatomic, readonly) BOOL isLoaded;

/// The path of the loaded GGUF, or nil.
@property (nonatomic, readonly, copy, nullable) NSString *loadedModelPath;

/// Loads the GGUF at `path` and holds it.  A no-op when that file is already loaded; a
/// different file replaces the loaded one.  The error carries `parakeet_capi_load_error`.
- (BOOL)loadModelAtPath:(NSString *)path error:(NSError **)error;

/// Transcribes mono float PCM with the model's default decoder.  Returns the transcript
/// exactly as parakeet.cpp wrote it (lowercase, unpunctuated for ekko, possibly empty).
/// The error carries `parakeet_capi_last_error`.
- (nullable NSString *)transcribeSamples:(const float *)samples
                                   count:(NSInteger)count
                              sampleRate:(NSInteger)sampleRate
                                   error:(NSError **)error
    NS_SWIFT_NAME(transcribe(samples:count:sampleRate:));

/// Releases the loaded model and its native memory.  Safe when nothing is loaded.
- (void)unloadModel;

/// Reads a WAV as 16 kHz mono float32 PCM (WavPCMReader), packed as `float`s.
+ (nullable NSData *)readWavAsPCMF32AtPath:(NSString *)path error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
