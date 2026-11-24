#import "S1MiniBridge.h"
#import "llama.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <mutex>
#include <string>
#include <vector>

namespace {
std::once_flag backendOnce;

NSString *const systemPrompt = @"You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text.";

std::string promptFor(NSString *transcript, NSString *styling, NSString *context) {
    NSString *prompt = [NSString stringWithFormat:
        @"<|im_start|>system\n%@<|im_end|>\n"
         "<|im_start|>user\n[Styling: %@] [Structure: lists] [Context: %@]\n%@<|im_end|>\n"
         "<|im_start|>assistant\n<think>\n\n</think>\n\n",
        systemPrompt, styling, context, transcript];
    return std::string(prompt.UTF8String ?: "");
}

bool tokenize(const llama_vocab *vocab, const std::string &text, std::vector<llama_token> &tokens) {
    int32_t count = llama_tokenize(vocab, text.data(), (int32_t) text.size(), nullptr, 0, true, true);
    if (count >= 0) return false;
    tokens.resize((size_t) -count);
    count = llama_tokenize(vocab, text.data(), (int32_t) text.size(), tokens.data(), (int32_t) tokens.size(), true, true);
    if (count < 0) return false;
    tokens.resize((size_t) count);
    return true;
}

bool appendPiece(const llama_vocab *vocab, llama_token token, std::string &output) {
    std::vector<char> buffer(64);
    int32_t size = llama_token_to_piece(vocab, token, buffer.data(), (int32_t) buffer.size(), 0, false);
    if (size < 0) {
        buffer.resize((size_t) -size);
        size = llama_token_to_piece(vocab, token, buffer.data(), (int32_t) buffer.size(), 0, false);
    }
    if (size < 0) return false;
    output.append(buffer.data(), (size_t) size);
    return true;
}

double secondsSince(CFAbsoluteTime start) { return CFAbsoluteTimeGetCurrent() - start; }

/// One run's result. `backendFault` marks failures a Metal problem can cause (context
/// creation, decode), which a CPU retry may get past.
struct RunResult {
    NSString *output = nil;
    NSString *error = nil;
    bool backendFault = false;
};
} // namespace

@implementation S1MiniBridge {
    dispatch_queue_t _queue;
    llama_model *_model;
    NSString *_loadedPath;
    BOOL _modelOnGPU;
    BOOL _gpuFailed;
    std::atomic<uint64_t> _cancelGeneration;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = dispatch_queue_create("app.codictate.s1-mini", DISPATCH_QUEUE_SERIAL);
        _cancelGeneration = 0;
        self.allowsGPU = YES;
        self.fallsBackToCPU = NO;
    }
    return self;
}

- (void)dealloc {
    if (_model) llama_model_free(_model);
}

- (void)log:(NSString *)line {
    void (^handler)(NSString *) = self.logHandler;
    if (handler) handler(line);
    else NSLog(@"%@", line);
}

- (void)unloadModel {
    dispatch_async(_queue, ^{
        if (self->_model) {
            llama_model_free(self->_model);
            [self log:@"[S1Mini] model unloaded"];
        }
        self->_model = nullptr;
        self->_loadedPath = nil;
    });
}

- (void)cancelPending {
    _cancelGeneration.fetch_add(1);
}

- (void)prewarmModelAtPath:(NSString *)modelPath completion:(void (^)(BOOL))completion {
    dispatch_async(_queue, ^{
        @autoreleasepool {
            BOOL loaded = [self loadModelAtPath:modelPath];
            if (completion) completion(loaded);
        }
    });
}

/// Queue only. Loads `modelPath` unless it is loaded, on Metal when allowed, else the CPU.
- (BOOL)loadModelAtPath:(NSString *)modelPath {
    std::call_once(backendOnce, [] { llama_backend_init(); });
    const BOOL wantGPU = self.allowsGPU && !_gpuFailed;
    if (_model && [_loadedPath isEqualToString:modelPath] && (_modelOnGPU == wantGPU || !_modelOnGPU)) {
        return YES;
    }
    if (_model) llama_model_free(_model);
    _model = nullptr;
    _loadedPath = nil;

    const CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    llama_model_params params = llama_model_default_params();
    params.n_gpu_layers = wantGPU ? 99 : 0;
    _model = llama_model_load_from_file(modelPath.fileSystemRepresentation, params);
    BOOL onGPU = wantGPU;
    if (!_model && wantGPU && self.fallsBackToCPU) {
        [self log:[NSString stringWithFormat:
            @"[S1Mini] Metal load failed after %.2f s (gpu offload supported=%d); retrying on the CPU",
            secondsSince(start), llama_supports_gpu_offload()]];
        _gpuFailed = YES;
        params.n_gpu_layers = 0;
        _model = llama_model_load_from_file(modelPath.fileSystemRepresentation, params);
        onGPU = NO;
    }
    if (!_model) {
        [self log:[NSString stringWithFormat:@"[S1Mini] model load failed after %.2f s", secondsSince(start)]];
        return NO;
    }
    _loadedPath = [modelPath copy];
    _modelOnGPU = onGPU;
    [self log:[NSString stringWithFormat:@"[S1Mini] model loaded in %.2f s on %@ (gpu offload supported=%d)",
        secondsSince(start), onGPU ? @"GPU (Metal)" : @"CPU", llama_supports_gpu_offload()]];
    return YES;
}

- (void)formatTranscript:(NSString *)transcript
                modelPath:(NSString *)modelPath
                styling:(NSString *)styling
                  context:(NSString *)context
               completion:(void (^)(NSString * _Nullable, NSString * _Nullable))completion {
    const uint64_t generation = _cancelGeneration.load();
    dispatch_async(_queue, ^{
        @autoreleasepool {
            if (self->_cancelGeneration.load() != generation) {
                completion(nil, @"S1-mini request was cancelled.");
                return;
            }
            if (![self loadModelAtPath:modelPath]) {
                completion(nil, @"S1-mini could not be loaded.");
                return;
            }
            RunResult result = [self runTranscript:transcript styling:styling context:context generation:generation];
            if (result.backendFault && self->_modelOnGPU && self.fallsBackToCPU) {
                [self log:[NSString stringWithFormat:@"[S1Mini] %@ on Metal; reloading on the CPU and retrying", result.error]];
                self->_gpuFailed = YES;
                if (![self loadModelAtPath:modelPath]) {
                    completion(nil, @"S1-mini could not be loaded on the CPU.");
                    return;
                }
                result = [self runTranscript:transcript styling:styling context:context generation:generation];
            }
            completion(result.output, result.output ? nil : result.error);
        }
    });
}

/// Queue only, with the model loaded.
- (RunResult)runTranscript:(NSString *)transcript
                   styling:(NSString *)styling
                   context:(NSString *)context
                generation:(uint64_t)generation {
    RunResult result;
    const llama_vocab *vocab = llama_model_get_vocab(_model);
    std::vector<llama_token> transcriptTokens;
    const std::string rawTranscript(transcript.UTF8String ?: "");
    if (!tokenize(vocab, rawTranscript, transcriptTokens) || transcriptTokens.size() > 1000) {
        result.error = @"S1-mini input exceeds its supported chunk size.";
        return result;
    }
    std::vector<llama_token> promptTokens;
    const std::string prompt = promptFor(transcript, styling, context);
    if (!tokenize(vocab, prompt, promptTokens) || promptTokens.empty()) {
        result.error = @"S1-mini prompt tokenization failed.";
        return result;
    }

    llama_context_params contextParams = llama_context_default_params();
    contextParams.n_ctx = std::max<uint32_t>(2048, (uint32_t) promptTokens.size() + 1400);
    // Keep the transient compute buffer modest on phones. There is no latency
    // target for optional cleanup, and generation remains serial.
    contextParams.n_batch = std::min<uint32_t>(128, contextParams.n_ctx);
    if (!_modelOnGPU) {
        // Nothing may reach Metal on the CPU path, where Metal may be the fault.
        contextParams.offload_kqv = false;
        contextParams.op_offload = false;
    }
    llama_context *ctx = llama_init_from_model(_model, contextParams);
    if (!ctx) {
        result.error = @"S1-mini context creation failed.";
        result.backendFault = true;
        return result;
    }

    const CFAbsoluteTime prefillStart = CFAbsoluteTimeGetCurrent();
    bool decodeFailed = false;
    const int32_t batchSize = (int32_t) contextParams.n_batch;
    for (size_t offset = 0; offset < promptTokens.size(); offset += (size_t) batchSize) {
        const int32_t count = (int32_t) std::min((size_t) batchSize, promptTokens.size() - offset);
        llama_batch batch = llama_batch_get_one(promptTokens.data() + offset, count);
        if (llama_decode(ctx, batch) != 0) { decodeFailed = true; break; }
    }
    if (decodeFailed) {
        llama_free(ctx);
        result.error = @"S1-mini prompt evaluation failed.";
        result.backendFault = true;
        return result;
    }
    const double prefillSeconds = secondsSince(prefillStart);

    const CFAbsoluteTime generateStart = CFAbsoluteTimeGetCurrent();
    llama_sampler *sampler = llama_sampler_init_greedy();
    std::string output;
    const int32_t inputEstimate = std::max<int32_t>(1, (int32_t) promptTokens.size() - 45);
    const int32_t maxNewTokens = (int32_t) std::ceil(inputEstimate * 1.3) + 32;
    bool reachedEnd = false;
    bool cancelled = false;
    int32_t generated = 0;
    for (; generated < maxNewTokens; ++generated) {
        if (_cancelGeneration.load() != generation) { cancelled = true; break; }
        llama_token token = llama_sampler_sample(sampler, ctx, -1);
        llama_sampler_accept(sampler, token);
        if (llama_vocab_is_eog(vocab, token)) { reachedEnd = true; break; }
        if (!appendPiece(vocab, token, output)) { decodeFailed = true; break; }
        llama_batch next = llama_batch_get_one(&token, 1);
        if (llama_decode(ctx, next) != 0) { decodeFailed = true; result.backendFault = true; break; }
    }
    llama_sampler_free(sampler);
    llama_free(ctx);
    const double generateSeconds = secondsSince(generateStart);
    [self log:[NSString stringWithFormat:
        @"[S1Mini] %@: prompt %zu tokens in %.2f s, generated %d tokens in %.2f s (%.1f tok/s)%@",
        _modelOnGPU ? @"GPU" : @"CPU", promptTokens.size(), prefillSeconds, generated, generateSeconds,
        generateSeconds > 0 ? generated / generateSeconds : 0.0,
        cancelled ? @", cancelled" : (decodeFailed ? @", decode failed" : (reachedEnd ? @"" : @", hit token limit"))]];
    if (cancelled) {
        result.error = @"S1-mini request was cancelled.";
        return result;
    }
    if (decodeFailed || !reachedEnd) {
        result.error = decodeFailed ? @"S1-mini generation failed." : @"S1-mini output reached its token limit.";
        return result;
    }

    NSString *text = [[NSString alloc] initWithBytes:output.data()
                                              length:output.size()
                                            encoding:NSUTF8StringEncoding];
    if (!text) {
        result.error = @"S1-mini returned invalid UTF-8.";
        return result;
    }
    if ([text containsString:@"<|im_"] ||
        [text containsString:@"<think"] ||
        [text containsString:@"</think"]) {
        result.error = @"S1-mini returned malformed protocol output.";
        return result;
    }
    result.output = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return result;
}

@end
