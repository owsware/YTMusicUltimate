#import <Foundation/Foundation.h>

/* Runs solely on the incoming native player's serial queue. */
@interface YTMUNativeTempoSession : NSObject
- (instancetype)initWithPlayer:(id)player queue:(dispatch_queue_t)queue renderer:(id)renderer
                   initialRate:(double)rate duration:(double)duration completion:(void (^)(void))completion;
- (void)start;
- (void)pause;
- (void)resume;
- (void)reapplyRate;
- (void)cancel;
- (void)cancelRestoringRate:(BOOL)restoreRate;
@end

FOUNDATION_EXPORT const void *YTMUNativePitchKey;
FOUNDATION_EXPORT const void *YTMUNativePitchQueueKey;
FOUNDATION_EXPORT const void *YTMUNativePitchGenerationKey;
void YTMURestoreNativePitch(id renderer);
void YTMURestoreNativePitchForGeneration(id renderer, NSNumber *generation);
