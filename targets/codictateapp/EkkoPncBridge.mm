#import "EkkoPncBridge.h"

// The ONNX Runtime pod archive ships onnxruntime.framework with its headers inside the
// framework and again in a loose Headers/ folder; take whichever the build reaches.
#if __has_include(<onnxruntime/onnxruntime_cxx_api.h>)
#import <onnxruntime/onnxruntime_cxx_api.h>
#else
#import "onnxruntime_cxx_api.h"
#endif

#include <stdlib.h>
#include <exception>
#include <memory>
#include <string>
#include <vector>

static NSString *const kEkkoPncErrorDomain = @"EkkoPncBridge";

static NSError *EkkoPncError(NSString *message) {
    return [NSError errorWithDomain:kEkkoPncErrorDomain
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

/// The process's one OrtEnv, created on first use.  Throws what creating it threw, every
/// time it is asked for after a failure.
static Ort::Env &EkkoPncSharedEnv() {
    static Ort::Env *env = nullptr;
    static std::string failure;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Read with getenv when the OrtEnv starts its telemetry; must come first.
        setenv("ORT_DISABLE_TELEMETRY", "1", 1);
        try {
            env = new Ort::Env(ORT_LOGGING_LEVEL_WARNING, "codictate-pnc");
            env->DisableTelemetryEvents();
        } catch (const std::exception &error) {
            failure = error.what();
        }
    });
    if (!env) throw std::runtime_error("could not create the ONNX Runtime environment: " + failure);
    return *env;
}

@implementation EkkoPncLogits

- (instancetype)initWithData:(NSData *)data dims:(NSArray<NSNumber *> *)dims {
    self = [super init];
    if (self) {
        _data = data;
        _dims = dims;
    }
    return self;
}

@end

@implementation EkkoPncBridge {
    std::unique_ptr<Ort::Session> _session;
    std::string _outputName;
}

- (nullable instancetype)initWithModelPath:(NSString *)modelPath error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    try {
        Ort::Env &env = EkkoPncSharedEnv();
        // Default options, no execution provider appended: the CPU provider, as Python's
        // `InferenceSession(path, providers=["CPUExecutionProvider"])`.
        Ort::SessionOptions options;
        _session = std::make_unique<Ort::Session>(env, modelPath.fileSystemRepresentation, options);
        Ort::AllocatorWithDefaultOptions allocator;
        if (_session->GetOutputCount() < 1) {
            throw std::runtime_error("the model has no outputs");
        }
        _outputName = _session->GetOutputNameAllocated(0, allocator).get();
    } catch (const std::exception &caught) {
        if (error) {
            *error = EkkoPncError([NSString stringWithFormat:@"could not load PnC model %@: %s",
                                   modelPath, caught.what()]);
        }
        return nil;
    }
    return self;
}

- (nullable EkkoPncLogits *)runWithInputIds:(NSData *)inputIds error:(NSError **)error {
    try {
        const int64_t count = (int64_t)(inputIds.length / sizeof(int64_t));
        std::vector<int64_t> ids(count);
        memcpy(ids.data(), inputIds.bytes, (size_t)count * sizeof(int64_t));
        std::vector<int64_t> mask(count, 1);
        const int64_t shape[2] = {1, count};

        Ort::MemoryInfo memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        Ort::Value inputs[2] = {
            Ort::Value::CreateTensor<int64_t>(memory, ids.data(), ids.size(), shape, 2),
            Ort::Value::CreateTensor<int64_t>(memory, mask.data(), mask.size(), shape, 2),
        };
        const char *inputNames[2] = {"input_ids", "attention_mask"};
        const char *outputNames[1] = {_outputName.c_str()};

        std::vector<Ort::Value> outputs =
            _session->Run(Ort::RunOptions{nullptr}, inputNames, inputs, 2, outputNames, 1);
        if (outputs.size() != 1 || !outputs[0].IsTensor()) {
            throw std::runtime_error("the model gave no output tensor");
        }
        Ort::TensorTypeAndShapeInfo info = outputs[0].GetTensorTypeAndShapeInfo();
        if (info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) {
            throw std::runtime_error("the model gave logits that are not float32");
        }
        std::vector<int64_t> outputShape = info.GetShape();
        NSMutableArray<NSNumber *> *dims = [NSMutableArray arrayWithCapacity:outputShape.size()];
        for (int64_t dim : outputShape) [dims addObject:@(dim)];

        const size_t elements = info.GetElementCount();
        NSData *data = [NSData dataWithBytes:outputs[0].GetTensorData<float>()
                                      length:elements * sizeof(float)];
        return [[EkkoPncLogits alloc] initWithData:data dims:dims];
    } catch (const std::exception &caught) {
        if (error) {
            *error = EkkoPncError([NSString stringWithFormat:@"PnC inference failed: %s", caught.what()]);
        }
        return nil;
    }
}

@end
