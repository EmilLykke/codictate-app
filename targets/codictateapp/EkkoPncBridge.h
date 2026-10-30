#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One model run's first output: float32 scores, row-major, of shape `dims`.
@interface EkkoPncLogits : NSObject

/// `dims` multiplied out, as native-endian float32.
@property (nonatomic, readonly) NSData *data;
@property (nonatomic, readonly) NSArray<NSNumber *> *dims;

@end

/// Thin Objective-C wrapper around one ONNX Runtime session on ekko-pnc's
/// `pnc.int8.onnx`, opened the way the Python reference opens it: default session
/// options on the CPU execution provider only.  Session::Run is thread-safe, but
/// PunctuationRestorer serializes every call anyway.
///
/// ONNX Runtime sends usage telemetry by default on some platforms.  Codictate
/// promises no analytics, so `ORT_DISABLE_TELEMETRY=1` is set with setenv before the
/// process's one OrtEnv is created, and telemetry events are disabled on it as well.
@interface EkkoPncBridge : NSObject

/// Open the model at `modelPath`.  Fails with an error naming the cause.
- (nullable instancetype)initWithModelPath:(NSString *)modelPath
                                     error:(NSError **)error NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// One run: `input_ids` of shape [1, n] (int64, from `inputIds`, n = length / 8) and an
/// all-ones `attention_mask` of the same shape.  Gives the session's first output, which
/// must be float32.
- (nullable EkkoPncLogits *)runWithInputIds:(NSData *)inputIds
                                      error:(NSError **)error
    NS_SWIFT_NAME(run(inputIds:));

@end

NS_ASSUME_NONNULL_END
