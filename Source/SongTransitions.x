#import "Transitions/YTMUSongTransitions.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <math.h>

@interface YTCrossfadeTransition : NSObject
- (instancetype)initWithDuration:(double)duration;
@end

static BOOL YTMUOwnsTransitions(void) {
    return [YTMUTransitionPreferences()[@"YTMUltimateIsEnabled"] boolValue] && YTMUTransitionsCrossfadeSupported();
}

%group TransitionSettings
%hook YTMSettingsImpl
- (BOOL)isCrossfadeEnabled {
    return YTMUOwnsTransitions() ? YTMUTransitionsRequested() : %orig;
}
- (NSInteger)crossfadeDuration {
    return YTMUOwnsTransitions() ? [YTMUTransitionPreferences()[@"crossfadeDuration"] integerValue] : %orig;
}
%end
%end

%group TransitionMusicFlag
%hook YTColdConfigMusicPlaybackClientConfigImpl
- (BOOL)iosEnableCrossfade {
    return YTMUTransitionsRequested() ? YES : %orig;
}
%end
%end

%group TransitionPlayerFlag
%hook YTColdConfigIosPlayerClientSharedConfigImpl
- (BOOL)enableCrossfade {
    return YTMUTransitionsRequested() ? YES : %orig;
}
%end
%end

%group TransitionSequencer
%hook YTMPlayerSequencerController
- (id)initWithPlayerViewController:(id)controller {
    id result = %orig;
    if (result) [[YTMUSongTransitionCoordinator shared] bindSequencer:result playerController:controller];
    return result;
}
- (id)crossfadeTransitionFromSettings {
    if (!YTMUOwnsTransitions()) return %orig;
    if (!YTMUTransitionsRequested()) return nil;
    double duration = [[YTMUSongTransitionCoordinator shared] crossfadeDuration];
    return duration > 0 ? [[NSClassFromString(@"YTCrossfadeTransition") alloc] initWithDuration:duration] : nil;
}
- (void)scheduleSetSequenceForQueueModification {
    [[YTMUSongTransitionCoordinator shared] cancel];
    %orig;
}
- (void)resetSequence {
    [[YTMUSongTransitionCoordinator shared] cancel];
    %orig;
}
- (void)setSequenceForTapNextOrTapPrevWithPlayerTransition:(id)transition playbackConfig:(id)config {
    [[YTMUSongTransitionCoordinator shared] cancel];
    %orig;
}
%end
%end

%group TransitionEligibility
%hook YTPlayerViewController
- (BOOL)shouldPlaybackController:(id)controller applyTransitionEffect:(id)effect currentPlayerResponse:(id)current upcomingPlayerResponse:(id)upcoming {
    BOOL original = %orig;
    if (!YTMUOwnsTransitions() ||
        (![effect isKindOfClass:NSClassFromString(@"YTCrossfadeTransition")] &&
         ![effect isKindOfClass:NSClassFromString(@"MLAudioCrossfadeTransition")])) return original;
    /* Keep the native server/content policy, including sequential album playback. */
    BOOL allowed = original && [[YTMUSongTransitionCoordinator shared] allowsTransitionsForPlaybackController:controller current:current upcoming:upcoming];
    if (allowed) [[YTMUSongTransitionCoordinator shared] observeCurrentResponse:current upcomingResponse:upcoming];
    return allowed;
}
- (void)seekToTime:(double)time {
    [[YTMUSongTransitionCoordinator shared] cancel];
    %orig;
}
- (void)seekToTime:(double)time seekSource:(int)source {
    [[YTMUSongTransitionCoordinator shared] cancel];
    %orig;
}
- (void)seekToTime:(double)time toleranceBefore:(double)before toleranceAfter:(double)after seekSource:(int)source {
    [[YTMUSongTransitionCoordinator shared] cancel];
    %orig;
}
%end
%end

%group TransitionNativePlayer
%hook MLHAMMultiPlayer
- (void)spawnCrossfadeWithActiveContext:(id)outgoing activeClip:(id)clip nextContext:(id)incoming {
    [[YTMUSongTransitionCoordinator shared] prepareIncomingContext:incoming];
    %orig;
    /* The native engine alone activates the incoming clip and advances the queue. */
    dispatch_async(dispatch_get_main_queue(), ^{
        [[YTMUSongTransitionCoordinator shared] nativeFadeStarted:self outgoingContext:outgoing incomingContext:incoming];
    });
}
- (void)pauseWithStoppageReason:(int)reason {
    [[YTMUSongTransitionCoordinator shared] pauseMix];
    %orig;
}
- (void)play {
    %orig;
    [[YTMUSongTransitionCoordinator shared] resumeMix];
}
- (void)setRate:(float)rate {
    [[YTMUSongTransitionCoordinator shared] cancel];
    %orig;
}
%end
%end

%group TransitionUpcomingPlayback
%hook YTUpcomingPlaybackManager
- (void)upcomingPlayerTransitionController:(id)controller didFetchUpcomingPlayablePlaybackData:(id)data {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[YTMUSongTransitionCoordinator shared] observeUpcomingPlaybackData:data];
    });
}
%end
%end

static const void *YTMUQueueButtonKey = &YTMUQueueButtonKey;
static const void *YTMUQueueBottomInsetKey = &YTMUQueueBottomInsetKey;

%group TransitionQueueUI
%hook YTMQueueCollectionViewController
- (void)viewDidLoad {
    %orig;
    UIViewController *controller = (UIViewController *)self;
    YTMUQueueTransitionButton *button = [[YTMUQueueTransitionButton alloc] initWithFrame:CGRectZero];
    button.queueController = self;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
        [button.bottomAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
        [button.heightAnchor constraintGreaterThanOrEqualToConstant:44]
    ]];
    objc_setAssociatedObject(self, YTMUQueueButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (void)viewDidLayoutSubviews {
    %orig;
    UIViewController *controller = (UIViewController *)self;
    UIButton *button = objc_getAssociatedObject(self, YTMUQueueButtonKey);
    if (!button) return;
    [controller.view bringSubviewToFront:button];
    /* Reserve room for the compact button so the final queue item remains reachable. */
    NSArray *candidates = [controller.view isKindOfClass:UICollectionView.class] ? @[controller.view] : controller.view.subviews;
    for (UIView *view in candidates) {
        if (![view isKindOfClass:UICollectionView.class]) continue;
        UICollectionView *collection = (UICollectionView *)view;
        NSNumber *previous = objc_getAssociatedObject(collection, YTMUQueueBottomInsetKey);
        UIEdgeInsets inset = collection.contentInset;
        if (!previous || fabs(inset.bottom - previous.doubleValue) > 0.5) {
            inset.bottom += 64;
            objc_setAssociatedObject(collection, YTMUQueueBottomInsetKey, @(inset.bottom), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            collection.contentInset = inset;
        }
    }
}
%end
%end

%ctor {
    @autoreleasepool {
        NSMutableDictionary *preferences = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] mutableCopy] ?: [NSMutableDictionary dictionary];
        NSDictionary *defaults = @{@"songTransitionsEnabled": @NO, @"songTransitionMode": @0, @"crossfadeDuration": @4};
        BOOL changed = NO;
        for (NSString *key in defaults) if (!preferences[key]) { preferences[key] = defaults[key]; changed = YES; }
        if (changed) [[NSUserDefaults standardUserDefaults] setObject:preferences forKey:@"YTMUltimate"];
        [YTMUSongTransitionCoordinator shared];
        if (YTMUTransitionsCrossfadeSupported()) {
            %init(TransitionSettings);
            Class sequencer = NSClassFromString(@"YTMPlayerSequencerController");
            if (YTMUTransitionMethodMatches(sequencer, NSSelectorFromString(@"initWithPlayerViewController:"), "@", @[@"@"]) &&
                YTMUTransitionMethodMatches(sequencer, NSSelectorFromString(@"scheduleSetSequenceForQueueModification"), "v", @[])) {
                %init(TransitionSequencer);
            }
            Class player = NSClassFromString(@"YTPlayerViewController");
            if (YTMUTransitionMethodMatches(player, NSSelectorFromString(@"seekToTime:"), "v", @[@"d"]) &&
                YTMUTransitionMethodMatches(player, NSSelectorFromString(@"seekToTime:seekSource:"), "v", @[@"d", @"i"]) &&
                YTMUTransitionMethodMatches(player, NSSelectorFromString(@"seekToTime:toleranceBefore:toleranceAfter:seekSource:"), "v", @[@"d", @"d", @"d", @"i"])) {
                %init(TransitionEligibility);
            }
            Class multi = NSClassFromString(@"MLHAMMultiPlayer");
            if (YTMUTransitionMethodMatches(multi, NSSelectorFromString(@"pauseWithStoppageReason:"), "v", @[@"i"]) &&
                YTMUTransitionMethodMatches(multi, NSSelectorFromString(@"play"), "v", @[]) &&
                YTMUTransitionMethodMatches(multi, NSSelectorFromString(@"setRate:"), "v", @[@"f"])) {
                %init(TransitionNativePlayer);
            }
            if (YTMUTransitionMethodMatches(NSClassFromString(@"YTColdConfigMusicPlaybackClientConfigImpl"), NSSelectorFromString(@"iosEnableCrossfade"), "B", @[])) { %init(TransitionMusicFlag); }
            if (YTMUTransitionMethodMatches(NSClassFromString(@"YTColdConfigIosPlayerClientSharedConfigImpl"), NSSelectorFromString(@"enableCrossfade"), "B", @[])) { %init(TransitionPlayerFlag); }
            if (YTMUTransitionsAutoMixSupported()) { %init(TransitionUpcomingPlayback); }
        }
        Class queue = NSClassFromString(@"YTMQueueCollectionViewController");
        if ([queue isSubclassOfClass:UIViewController.class] &&
            YTMUTransitionMethodMatches(queue, @selector(viewDidLoad), "v", @[]) &&
            YTMUTransitionMethodMatches(queue, @selector(viewDidLayoutSubviews), "v", @[])) {
            %init(TransitionQueueUI);
        }
    }
}
