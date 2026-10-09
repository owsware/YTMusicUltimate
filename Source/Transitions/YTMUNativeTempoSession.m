#import "YTMUNativeTempoSession.h"
#import "YTMUSongTransitions.h"
#import "YTMUMixAnalysis.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <math.h>

/* Shared association with the coordinator; setter/restoration use playerQueue. */
const void *YTMUNativePitchKey = &YTMUNativePitchKey;
const void *YTMUNativePitchQueueKey = &YTMUNativePitchQueueKey;
const void *YTMUNativePitchGenerationKey = &YTMUNativePitchGenerationKey;
void YTMURestoreNativePitch(id renderer) {
    NSString *original = objc_getAssociatedObject(renderer, YTMUNativePitchKey);
    if (!original) return;
    ((void (*)(id, SEL, id))objc_msgSend)(renderer, NSSelectorFromString(@"setAudioTimePitchAlgorithm:"), original);
    objc_setAssociatedObject(renderer, YTMUNativePitchKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(renderer, YTMUNativePitchQueueKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(renderer, YTMUNativePitchGenerationKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
void YTMURestoreNativePitchForGeneration(id renderer, NSNumber *generation) {
    if (generation && [generation isEqual:objc_getAssociatedObject(renderer, YTMUNativePitchGenerationKey)])
        YTMURestoreNativePitch(renderer);
}

typedef struct { double mediaTime, productionTime, absoluteTime; } YTMUTempoPlayerTime;
@interface YTMUNativeTempoSession ()
@property (nonatomic, strong) id player;
@property (nonatomic, strong) id renderer;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_source_t timer;
@property (atomic) BOOL cancelled;
@property (atomic) BOOL paused;
@property (nonatomic) double rate;
@property (nonatomic) double appliedRate;
@property (nonatomic) double duration;
@property (nonatomic) double startTime;
@property (nonatomic) BOOL finished;
@property (nonatomic) BOOL changedRate;
@property (nonatomic, strong) NSNumber *pitchGeneration;
@property (nonatomic, copy) void (^completion)(void);
@end

@implementation YTMUNativeTempoSession
- (instancetype)initWithPlayer:(id)player queue:(dispatch_queue_t)queue renderer:(id)renderer
                   initialRate:(double)rate duration:(double)duration completion:(void (^)(void))completion {
    if ((self = [super init])) {
        _player = player; _queue = queue; _renderer = renderer;
        _rate = rate; _appliedRate = 1; _duration = duration * rate; _completion = [completion copy];
        _pitchGeneration = objc_getAssociatedObject(renderer, YTMUNativePitchGenerationKey);
    }
    return self;
}
- (void)start {
    dispatch_async(self.queue, ^{
        if (self.cancelled) return;
        YTMUTempoPlayerTime time = ((YTMUTempoPlayerTime (*)(id, SEL))objc_msgSend)(self.player, NSSelectorFromString(@"currentTime"));
        float rate = ((float (*)(id, SEL))objc_msgSend)(self.player, NSSelectorFromString(@"rate"));
        if (!isfinite(time.mediaTime) || time.mediaTime < 0 || time.mediaTime > 0.5 || !isfinite(rate) ||
            fabsf(rate - 1) > 0.001 ||
            ![[self.renderer audioTimePitchAlgorithm] isEqual:AVAudioTimePitchAlgorithmSpectral]) {
            YTMURecordTransitionEvent(@"tempo", @"crossfade-fallback; renderer, speed or intro unavailable");
            [self finishRestoringRate:NO]; return;
        }
        self.startTime = time.mediaTime;
        [self applyRate:self.rate];
        self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
        /* No UIKit/main-run-loop dependency. Poll only this short active mix;
           half the old audio timer frequency, with 20 ms scheduling leeway. */
        dispatch_source_set_timer(self.timer, self.paused ? DISPATCH_TIME_FOREVER : dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), NSEC_PER_SEC / 10, NSEC_PER_SEC / 50);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(self.timer, ^{ [weakSelf tick]; });
        dispatch_resume(self.timer);
        YTMURecordTransitionEvent(@"tempo", [NSString stringWithFormat:@"pitch-preserving %.4fx; native audio queue", self.rate]);
    });
}
- (void)applyRate:(double)rate {
    if (self.cancelled) return;
    if (fabs(rate - self.appliedRate) < 0.0001) return;
    self.appliedRate = rate;
    self.changedRate = YES;
    ((void (*)(id, SEL, float))objc_msgSend)(self.player, NSSelectorFromString(@"setRate:"), (float)rate);
}
- (void)tick {
    if (self.cancelled || self.paused) return;
    YTMUTempoPlayerTime time = ((YTMUTempoPlayerTime (*)(id, SEL))objc_msgSend)(self.player, NSSelectorFromString(@"currentTime"));
    double elapsed = time.mediaTime - self.startTime;
    if (!isfinite(elapsed) || elapsed < -0.1) { [self finishRestoringRate:YES]; return; }
    /* Pauses and buffering freeze the media clock. Never expire/cut native audio
       because wall-clock time advanced while its media clock was stopped. */
    if (elapsed < self.duration) return;
    double progress = (elapsed - self.duration) / 2;
    [self applyRate:YTMUMixRateAtProgress(self.rate, progress)];
    if (progress >= 1) { YTMURecordTransitionEvent(@"tempo", @"normal-speed-restored"); [self finishRestoringRate:YES]; }
}
- (void)finishRestoringRate:(BOOL)restoreRate {
    if (self.finished) return;
    self.finished = YES;
    self.cancelled = YES;
    if (self.timer) { dispatch_source_cancel(self.timer); self.timer = nil; }
    if (restoreRate && self.changedRate) {
        self.appliedRate = 1;
        ((void (*)(id, SEL, float))objc_msgSend)(self.player, NSSelectorFromString(@"setRate:"), 1.0f);
    }
    YTMURestoreNativePitchForGeneration(self.renderer, self.pitchGeneration);
    void (^completion)(void) = self.completion;
    self.completion = nil;
    if (completion) dispatch_async(dispatch_get_main_queue(), completion);
}
- (void)pause {
    self.paused = YES;
    dispatch_async(self.queue, ^{
        if (self.timer) dispatch_source_set_timer(self.timer, DISPATCH_TIME_FOREVER, NSEC_PER_SEC / 10, NSEC_PER_SEC / 50);
    });
}
- (void)resume {
    self.paused = NO;
    dispatch_async(self.queue, ^{
        if (self.timer && !self.cancelled)
            dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), NSEC_PER_SEC / 10, NSEC_PER_SEC / 50);
    });
}
- (void)reapplyRate {
    dispatch_async(self.queue, ^{
        if (!self.cancelled) ((void (*)(id, SEL, float))objc_msgSend)(self.player, NSSelectorFromString(@"setRate:"), (float)self.appliedRate);
    });
}
- (void)cancel {
    [self cancelRestoringRate:YES];
}
- (void)cancelRestoringRate:(BOOL)restoreRate {
    self.cancelled = YES;
    dispatch_async(self.queue, ^{ [self finishRestoringRate:restoreRate]; });
}
@end
