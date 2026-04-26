#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin Objective-C wrapper around the whisper.cpp C API.
/// Exposes only what the keyboard extension needs: load a model, transcribe a
/// WAV file, then free the model.  All heavy work runs on a serial background
/// queue; the completion handler is called on the main queue.
@interface WhisperBridge : NSObject

/// Returns YES if a model is currently loaded.
@property (nonatomic, readonly) BOOL isLoaded;

/// Load the GGML model at the given file-system path.
/// Returns YES on success.  Blocks the calling thread briefly while the model
/// header is read; the actual heavy initialisation runs asynchronously.
- (BOOL)loadModelAtPath:(NSString *)path;

/// Transcribe a 16-kHz mono PCM WAV file.
/// @param wavPath  Absolute path to the WAV file produced by AudioRecorder.
/// @param language BCP-47 language code, e.g. "en".  Pass nil for auto-detect.
/// @param completion  Called on the main queue with the transcript (or nil on
///                    error) and an optional error string.
- (void)transcribeWavFile:(NSString *)wavPath
                 language:(nullable NSString *)language
               completion:(void (^)(NSString * _Nullable transcript,
                                    NSString * _Nullable errorMessage))completion;

/// Release the loaded model and free all native memory.
- (void)unloadModel;

@end

NS_ASSUME_NONNULL_END
