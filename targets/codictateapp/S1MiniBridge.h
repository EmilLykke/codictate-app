#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// S1-mini on llama.cpp. Compiled into the Host and into the Formatting AU
/// (`CodictateFormattingAU`). The defaults are the Host's: Metal, no CPU retry.
@interface S1MiniBridge : NSObject

/// YES (default): offload every layer to Metal. NO: CPU only.
@property (atomic) BOOL allowsGPU;
/// YES: a Metal load, context or decode failure reloads the model on the CPU and retries
/// once, and Metal stays off for this bridge. Default NO.
@property (atomic) BOOL fallsBackToCPU;
/// Receives diagnostics (load time, backend, token counts, timings). Nil: NSLog.
@property (atomic, copy, nullable) void (^logHandler)(NSString *line);

- (void)unloadModel;

/// Loads the model off the caller's thread if it is not loaded.
- (void)prewarmModelAtPath:(NSString *)modelPath
                completion:(nullable void (^)(BOOL loaded))completion;

/// Abandons every format call made before this one; a running generation stops at its
/// next token and completes with an error.
- (void)cancelPending;

- (void)formatTranscript:(NSString *)transcript
                modelPath:(NSString *)modelPath
                styling:(NSString *)styling
                  context:(NSString *)context
               completion:(void (^)(NSString * _Nullable output, NSString * _Nullable errorMessage))completion;

@end

NS_ASSUME_NONNULL_END
