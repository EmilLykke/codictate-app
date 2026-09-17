#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface S1MiniBridge : NSObject

- (void)unloadModel;

- (void)formatTranscript:(NSString *)transcript
                modelPath:(NSString *)modelPath
                styling:(NSString *)styling
                  context:(NSString *)context
               completion:(void (^)(NSString * _Nullable output, NSString * _Nullable errorMessage))completion;

@end

NS_ASSUME_NONNULL_END
