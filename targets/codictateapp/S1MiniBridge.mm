#import "S1MiniBridge.h"
#import "llama.h"

#include <algorithm>
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
} // namespace

@implementation S1MiniBridge {
    dispatch_queue_t _queue;
    llama_model *_model;
    NSString *_loadedPath;
}

- (instancetype)init {
    self = [super init];
    if (self) _queue = dispatch_queue_create("app.codictate.s1-mini", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)dealloc {
    if (_model) llama_model_free(_model);
}

- (void)unloadModel {
    dispatch_async(_queue, ^{
        if (self->_model) llama_model_free(self->_model);
        self->_model = nullptr;
        self->_loadedPath = nil;
    });
}

- (void)formatTranscript:(NSString *)transcript
                modelPath:(NSString *)modelPath
                styling:(NSString *)styling
                  context:(NSString *)context
               completion:(void (^)(NSString * _Nullable, NSString * _Nullable))completion {
    dispatch_async(_queue, ^{
        @autoreleasepool {
            std::call_once(backendOnce, [] { llama_backend_init(); });
            if (!self->_model || ![self->_loadedPath isEqualToString:modelPath]) {
                if (self->_model) llama_model_free(self->_model);
                llama_model_params params = llama_model_default_params();
                params.n_gpu_layers = 99;
                self->_model = llama_model_load_from_file(modelPath.fileSystemRepresentation, params);
                self->_loadedPath = self->_model ? [modelPath copy] : nil;
            }
            if (!self->_model) {
                completion(nil, @"S1-mini could not be loaded.");
                return;
            }

            const llama_vocab *vocab = llama_model_get_vocab(self->_model);
            std::vector<llama_token> transcriptTokens;
            const std::string rawTranscript(transcript.UTF8String ?: "");
            if (!tokenize(vocab, rawTranscript, transcriptTokens) || transcriptTokens.size() > 1000) {
                completion(nil, @"S1-mini input exceeds its supported chunk size.");
                return;
            }
            std::vector<llama_token> promptTokens;
            const std::string prompt = promptFor(transcript, styling, context);
            if (!tokenize(vocab, prompt, promptTokens) || promptTokens.empty()) {
                completion(nil, @"S1-mini prompt tokenization failed.");
                return;
            }

            llama_context_params contextParams = llama_context_default_params();
            contextParams.n_ctx = std::max<uint32_t>(2048, (uint32_t) promptTokens.size() + 1400);
            // Keep the transient compute buffer modest on phones. There is no latency
            // target for optional cleanup, and generation remains serial.
            contextParams.n_batch = std::min<uint32_t>(128, contextParams.n_ctx);
            llama_context *ctx = llama_init_from_model(self->_model, contextParams);
            if (!ctx) {
                completion(nil, @"S1-mini context creation failed.");
                return;
            }

            bool decodeFailed = false;
            const int32_t batchSize = (int32_t) contextParams.n_batch;
            for (size_t offset = 0; offset < promptTokens.size(); offset += (size_t) batchSize) {
                const int32_t count = (int32_t) std::min((size_t) batchSize, promptTokens.size() - offset);
                llama_batch batch = llama_batch_get_one(promptTokens.data() + offset, count);
                if (llama_decode(ctx, batch) != 0) { decodeFailed = true; break; }
            }
            if (decodeFailed) {
                llama_free(ctx);
                completion(nil, @"S1-mini prompt evaluation failed.");
                return;
            }

            llama_sampler *sampler = llama_sampler_init_greedy();
            std::string output;
            const int32_t inputEstimate = std::max<int32_t>(1, (int32_t) promptTokens.size() - 45);
            const int32_t maxNewTokens = (int32_t) std::ceil(inputEstimate * 1.3) + 32;
            bool reachedEnd = false;
            for (int32_t generated = 0; generated < maxNewTokens; ++generated) {
                llama_token token = llama_sampler_sample(sampler, ctx, -1);
                llama_sampler_accept(sampler, token);
                if (llama_vocab_is_eog(vocab, token)) { reachedEnd = true; break; }
                if (!appendPiece(vocab, token, output)) { decodeFailed = true; break; }
                llama_batch next = llama_batch_get_one(&token, 1);
                if (llama_decode(ctx, next) != 0) { decodeFailed = true; break; }
            }
            llama_sampler_free(sampler);
            llama_free(ctx);
            if (decodeFailed || !reachedEnd) {
                completion(nil, decodeFailed ? @"S1-mini generation failed." : @"S1-mini output reached its token limit.");
                return;
            }

            NSString *result = [[NSString alloc] initWithBytes:output.data()
                                                        length:output.size()
                                                      encoding:NSUTF8StringEncoding];
            if (!result) {
                completion(nil, @"S1-mini returned invalid UTF-8.");
                return;
            }
            if ([result containsString:@"<|im_"] ||
                [result containsString:@"<think"] ||
                [result containsString:@"</think"]) {
                completion(nil, @"S1-mini returned malformed protocol output.");
                return;
            }
            completion([result stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet], nil);
        }
    });
}

@end
