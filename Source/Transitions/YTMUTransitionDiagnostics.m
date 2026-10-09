#import "YTMUSongTransitions.h"

/* A bounded, in-memory trace: no media URLs, account information or track IDs.
   No polling, disk writes, network requests or notifications per audio tick. */
@interface YTMUTransitionTrace : NSObject
@property (nonatomic, strong) NSMutableArray<NSString *> *recent;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *counts;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *stages;
@property (nonatomic, copy) NSString *last;
@end
@implementation YTMUTransitionTrace
- (instancetype)init {
    if ((self = [super init])) {
        _recent = [NSMutableArray array]; _counts = [NSMutableDictionary dictionary];
        _stages = [NSMutableDictionary dictionary];
    }
    return self;
}
@end

static YTMUTransitionTrace *trace(void) {
    static YTMUTransitionTrace *value; static dispatch_once_t once;
    dispatch_once(&once, ^{ value = [YTMUTransitionTrace new]; }); return value;
}

void YTMURecordTransitionEvent(NSString *event, NSString *detail) {
    if (!event.length) return;
    YTMUTransitionTrace *value = trace();
    NSString *line = [NSString stringWithFormat:@"%@: %@", event, detail ?: @""];
    if (line.length > 384) line = [line substringToIndex:384];
    @synchronized (value) {
        if (value.counts[event] || value.counts.count < 32) {
            value.counts[event] = @(MIN((NSUInteger)1000000, [value.counts[event] unsignedIntegerValue] + 1));
            /* Preserve each stage when later transport/queue events fill the ring. */
            value.stages[event] = line;
        }
        /* Repeated policy evaluations count, but do not evict useful stages. */
        if ([line isEqual:value.last]) return;
        value.last = line;
        if (value.recent.count == 32) [value.recent removeObjectAtIndex:0];
        [value.recent addObject:[NSString stringWithFormat:@"%.1f %@", NSProcessInfo.processInfo.systemUptime, line]];
    }
}

NSString *YTMUTransitionDiagnosticsReport(void) {
    YTMUTransitionTrace *value = trace();
    NSDictionary *prefs = YTMUTransitionPreferences();
    NSMutableString *report = [NSMutableString stringWithFormat:
        @"YTMusicUltimate transitions r5\nYouTube Music %@; iOS %@\nCrossfade ABI: %@; AutoMix ABI: %@\nEnabled: %@; mode: %@; duration: %@ s; Low Power: %@\n",
        NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"unknown",
        UIDevice.currentDevice.systemVersion,
        YTMUTransitionsCrossfadeSupported() ? @"verified" : @"unavailable",
        YTMUTransitionsAutoMixSupported() ? @"verified" : @"unavailable",
        prefs[@"songTransitionsEnabled"], [prefs[@"songTransitionMode"] integerValue] == 1 ? @"Crossfade" : @"AutoMix",
        prefs[@"crossfadeDuration"], NSProcessInfo.processInfo.lowPowerModeEnabled ? @"yes" : @"no"];
    if ([NSThread isMainThread]) [report appendFormat:@"%@\n", [[YTMUSongTransitionCoordinator shared] diagnosticsSnapshot]];
    @synchronized (value) {
        for (NSString *key in [value.counts.allKeys sortedArrayUsingSelector:@selector(compare:)])
            [report appendFormat:@"%@: %@\n", key, value.counts[key]];
        [report appendString:@"Last result for each playback stage:\n"];
        for (NSString *key in [value.stages.allKeys sortedArrayUsingSelector:@selector(compare:)])
            [report appendFormat:@"%@\n", value.stages[key]];
        [report appendString:@"Recent playback stages:\n"];
        [report appendString:[value.recent componentsJoinedByString:@"\n"]];
    }
    return report;
}
