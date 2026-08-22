#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C wrapper around the cohere C API that the crispasr ASR
/// Harness exports.  crispasr's cohere backend is the only runtime that can read
/// the Danish hviske GGUF weights; whisper.cpp and llama.cpp cannot read them at
/// all.  Same shape as WhisperBridge: load a model, transcribe a WAV file, then
/// free the model.  All heavy work runs on a serial background queue; the
/// completion handler is called on the main queue.
@interface CohereBridge : NSObject

/// Returns YES if a model is currently loaded.
@property (nonatomic, readonly) BOOL isLoaded;

/// Load the GGUF model at the given file-system path.
/// Returns YES on success.
- (BOOL)loadModelAtPath:(NSString *)path;

/// Transcribe a 16-kHz mono PCM WAV file.
/// @param wavPath  Absolute path to the WAV file produced by AudioRecorder.
/// @param language ISO-639-1 code, e.g. "da".  Not nullable on purpose: upstream
///                 autodetect is unimplemented, so NULL would silently produce a
///                 wrong-language transcript rather than an error.
/// @param completion  Called on the main queue with the transcript (or nil on
///                    error) and an optional error string.
- (void)transcribeWavFile:(NSString *)wavPath
                 language:(NSString *)language
               completion:(void (^)(NSString * _Nullable transcript,
                                    NSString * _Nullable errorMessage))completion;

/// Release the loaded model and free all native memory.
- (void)unloadModel;

@end

NS_ASSUME_NONNULL_END
