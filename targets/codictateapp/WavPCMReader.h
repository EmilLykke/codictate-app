#pragma once

#import <Foundation/Foundation.h>

#include <vector>

// ---------------------------------------------------------------------------
// Read a WAV file into a float32 PCM buffer at exactly 16 000 Hz, mono.
//
// Both ASR bridges need the identical conversion: crispasr's whisper backend and
// its cohere backend each take `const float *samples` at 16 kHz mono and neither
// resamples for you.  Shared here rather than copied so the two cannot drift.
//
// Obj-C++ only -- never add this header to the Swift bridging header.
// ---------------------------------------------------------------------------
std::vector<float> CodictateReadWavAsPCMF32(NSString *path, NSError **outError);
