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
    return YTMUOwnsTransitions() ? YES : %orig;
}
%end
%end

%group TransitionPlayerFlag
%hook YTColdConfigIosPlayerClientSharedConfigImpl
- (BOOL)enableCrossfade {
    return YTMUOwnsTransitions() ? YES : %orig;
}
- (BOOL)enableVolumeFading {
    BOOL own = YTMUOwnsTransitions();
    YTMURecordTransitionEvent(@"volume-engine", own ? @"native-transition-provider-enabled" : @"native-setting");
    return own ? YES : %orig;
}
%end
%end

%group TransitionEngineFlags
%hook YTColdConfig
- (BOOL)iosPlayerClientSharedConfigEnableCrossfade {
    BOOL own = YTMUOwnsTransitions();
    YTMURecordTransitionEvent(@"engine-flag", own ? @"crossfade-enabled-at-initialization" : @"native-setting");
    return own ? YES : %orig;
}
- (BOOL)musicPlaybackClientConfigIosEnableCrossfade {
    return YTMUOwnsTransitions() ? YES : %orig;
}
- (BOOL)musicPlaybackClientConfigIosEnableMediaDrivenPrefetch {
    /* The watch controller reads this before constructing the main player. */
    return YTMUOwnsTransitions() ? YES : %orig;
}
- (BOOL)iosPlayerClientSharedConfigEnableVolumeFading {
    return YTMUOwnsTransitions() ? YES : %orig;
}
%end
%end

%group TransitionPlaybackMigration
%hook YTHotConfigIosPlayerClientSharedConfigImpl
- (BOOL)enablePlayerPlaybackMigration {
    BOOL own = YTMUOwnsTransitions();
    if (own) YTMURecordTransitionEvent(@"playback-object", @"preserving-incoming-fade");
    return own ? YES : %orig;
}
%end
%hook YTHotConfig
- (BOOL)iosPlayerClientSharedConfigEnablePlayerPlaybackMigration {
    return YTMUOwnsTransitions() ? YES : %orig;
}
%end
%end

%group TransitionNativePrefetch
%hook YTPlayerSequencerDefaultPlaybackItemHandler
- (id)initWithPlayerViewController:(id)controller latencyLoggerProvider:(id)provider shouldEnableMediaDrivenPrefetch:(BOOL)enabled {
    BOOL effective = YTMUOwnsTransitions() || enabled;
    YTMURecordTransitionEvent(@"prefetch-mode", [NSString stringWithFormat:@"handler native=%d effective=%d", enabled, effective]);
    return %orig(controller, provider, effective);
}
%end
%hook YTLocalPlaybackController
- (id)initWithParentResponder:(id)parent overlayFactory:(id)overlay playerView:(id)view playbackControllerDelegate:(id)delegate viewportSizeProvider:(id)viewport recompositeProvider:(id)recomposite shouldDelayAdsPlaybackCoordinatorCreation:(BOOL)delay shouldEnableMediaDrivenPrefetch:(BOOL)enabled enablePictureInPictureSupport:(BOOL)pip {
    BOOL effective = YTMUOwnsTransitions() || enabled;
    YTMURecordTransitionEvent(@"prefetch-mode", [NSString stringWithFormat:@"playback native=%d effective=%d", enabled, effective]);
    return %orig(parent, overlay, view, delegate, viewport, recomposite, delay, effective, pip);
}
- (void)setUpcomingPlayerPlaybacks:(id)value {
    /* Preserve native ownership and empty-array cancellation. Only the immediate
       next song receives extra preparation; the native sequencer replenishes it. */
    id playbacks = value;
    if (YTMUTransitionsRequested() && [value isKindOfClass:NSArray.class] && [value count]) {
        playbacks = @[[value firstObject]];
        YTMURecordTransitionEvent(@"upcoming-input", [NSString stringWithFormat:@"native=%lu prepared=1", (unsigned long)[value count]]);
    }
    %orig(playbacks);
}
- (void)upcomingPlaybackManager:(id)manager resolvedPlayablePlaybacks:(id)playbacks {
    if (YTMUTransitionsRequested() && [playbacks isKindOfClass:NSArray.class])
        YTMURecordTransitionEvent(@"upcoming-resolved", [NSString stringWithFormat:@"playable=%lu", (unsigned long)[playbacks count]]);
    %orig;
}
- (id)upcomingPlaybackManagerDidRequestPrefetchAfterLastUpcomingPlayback:(id)manager {
    if (YTMUTransitionsRequested()) {
        id pending = ((id (*)(id, SEL))objc_msgSend)(manager, NSSelectorFromString(@"upcomingPlaybacksArray"));
        if ([pending isKindOfClass:NSArray.class] && [pending count]) return nil;
    }
    return %orig;
}
%end
%end

%group TransitionTimelineDelivery
%hook YTQueuePlaybackTimelineManager
- (void)setPlaybacks:(id)playbacks reloadContext:(id)context {
    if (YTMUTransitionsRequested() && [playbacks isKindOfClass:NSArray.class])
        YTMURecordTransitionEvent(@"timeline-input", [NSString stringWithFormat:@"playbacks=%lu", (unsigned long)[playbacks count]]);
    %orig;
}
- (id)createPlayerItemForVideoController:(id)controller reloadContext:(id)context {
    id result = %orig;
    YTMURecordNativeTransitionItem(result, controller);
    return result;
}
%end
%end

%group TransitionNativePool
%hook MLPlayerPoolImpl
- (id)acquireQueuePlayerWithStickySettings:(id)settings mediaPlayerResources:(id)resources {
    id result = %orig;
    id provider = ((id (*)(id, SEL))objc_msgSend)(resources, NSSelectorFromString(@"audioTransitionProvider"));
    YTMURecordTransitionEvent(@"native-engine", [NSString stringWithFormat:@"player=%@; audio-transition-provider=%@", [result class], [provider class]]);
    return result;
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
    if (!YTMUTransitionsRequested()) { YTMURecordTransitionEvent(@"transition", @"disabled"); return nil; }
    double duration = [[YTMUSongTransitionCoordinator shared] crossfadeDurationForSequencer:self];
    YTMURecordTransitionEvent(@"transition", [NSString stringWithFormat:@"scheduled %.2f seconds", duration]);
    return duration > 0 ? [[NSClassFromString(@"YTCrossfadeTransition") alloc] initWithDuration:duration] : nil;
}
- (void)updateUpcomingVideoIDAndLatencyTickLoggerForSequence:(id)sequence currentSequenceIndex:(NSInteger)index isLoopAllEnabled:(BOOL)loopAll {
    %orig;
    [[YTMUSongTransitionCoordinator shared] sequenceChanged];
}
- (void)resetSequence {
    [[YTMUSongTransitionCoordinator shared] cancelForReason:@"native-sequence-reset"];
    %orig;
}
- (void)setSequenceForTapNextOrTapPrevWithPlayerTransition:(id)transition playbackConfig:(id)config {
    [[YTMUSongTransitionCoordinator shared] cancelForReason:@"next-or-previous"];
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
    /* Manual transitions override the account experiment; content vetoes remain. */
    BOOL allowed = original && [[YTMUSongTransitionCoordinator shared] allowsTransitionsForPlaybackController:controller current:current upcoming:upcoming];
    YTMURecordTransitionEvent(@"delegate", [NSString stringWithFormat:@"native=%d final=%d effect=%@", original, allowed, [effect class]]);
    if (allowed) [[YTMUSongTransitionCoordinator shared] observeCurrentResponse:current upcomingResponse:upcoming];
    return allowed;
}
- (void)seekToTime:(double)time {
    [[YTMUSongTransitionCoordinator shared] cancelForReason:@"seek"];
    %orig;
}
- (void)seekToTime:(double)time seekSource:(int)source {
    [[YTMUSongTransitionCoordinator shared] cancelForReason:@"seek-with-source"];
    %orig;
}
- (void)seekToTime:(double)time toleranceBefore:(double)before toleranceAfter:(double)after seekSource:(int)source {
    [[YTMUSongTransitionCoordinator shared] cancelForReason:@"seek-with-tolerance"];
    %orig;
}
%end
%end

%group TransitionNativePlayer
%hook MLHAMMultiPlayer
- (void)spawnCrossfadeWithActiveContext:(id)outgoing activeClip:(id)clip nextContext:(id)incoming {
    if (YTMUTransitionsRequested()) YTMURecordTransitionEvent(@"overlap", @"native-spawn-called");
    [[YTMUSongTransitionCoordinator shared] nativeFadeWillStart:self outgoingContext:outgoing activeClip:clip];
    [[YTMUSongTransitionCoordinator shared] prepareIncomingContext:incoming];
    %orig;
    /* The native engine alone activates the incoming clip and advances the queue. */
    dispatch_async(dispatch_get_main_queue(), ^{
        [[YTMUSongTransitionCoordinator shared] nativeFadeStarted:self outgoingContext:outgoing incomingContext:incoming];
    });
}
- (BOOL)shouldApplyTransitionEffect:(id)effect previousClip:(id)previous toClip:(id)next {
    BOOL allowed = %orig;
    if (YTMUTransitionsRequested() && [effect isKindOfClass:NSClassFromString(@"MLAudioCrossfadeTransition")])
        YTMURecordTransitionEvent(@"audio-policy", allowed ? @"native-accepted" : @"native-rejected");
    return allowed;
}
- (void)clearBackgroundPlayer {
    if (YTMUTransitionsRequested())
        YTMURecordTransitionEvent(@"overlap-cleanup", @"native-background-player-release");
    %orig;
}
- (void)commitTransitionEffects {
    %orig;
    if (YTMUTransitionsRequested()) {
        id state = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"playerContextState"));
        id value = ((id (*)(id, SEL))objc_msgSend)(state, NSSelectorFromString(@"playerContexts"));
        if (![value isKindOfClass:NSArray.class]) return;
        NSArray *contexts = value;
        id background = ((id (*)(id, SEL))objc_msgSend)(state, NSSelectorFromString(@"backgroundPlayerContext"));
        double largest = 0;
        for (id context in contexts) {
            SEL selector = NSSelectorFromString(@"crossfadeDuration");
            if (YTMUTransitionMethodMatches([context class], selector, "d", @[]))
                largest = fmax(largest, ((double (*)(id, SEL))objc_msgSend)(context, selector));
        }
        /* Native playerContexts excludes the outgoing background player. */
        YTMURecordTransitionEvent(@"audio-contexts", [NSString stringWithFormat:@"queued=%lu background=%d total=%lu max-fade=%.2f seconds",
            (unsigned long)contexts.count, background != nil, (unsigned long)contexts.count + (background ? 1 : 0), largest]);
    }
}
- (void)pauseWithStoppageReason:(int)reason {
    [[YTMUSongTransitionCoordinator shared] nativePlaybackPaused];
    %orig;
}
- (void)play {
    %orig;
    [[YTMUSongTransitionCoordinator shared] nativePlaybackResumed];
}
- (void)setRate:(float)rate {
    float previous = ((float (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"rate"));
    if (!isfinite(rate) || fabsf(previous - rate) > 0.001)
        [[YTMUSongTransitionCoordinator shared] nativePlaybackSpeedWillChange];
    %orig;
    [[YTMUSongTransitionCoordinator shared] nativeRateChanged:rate player:self];
}
%end
%end

%group TransitionQueueEligibility
%hook YTIPlayerResponse
- (BOOL)canEnqueueUpcomingPlaybacks {
    BOOL original = %orig;
    if (!YTMUTransitionsRequested()) return original;
    BOOL compatible = YTMUTransitionsCanReuseNativeQueue(self);
    YTMURecordTransitionEvent(@"native-queue", [NSString stringWithFormat:@"enqueue=%d gapless-compatible-song=%d", original, compatible]);
    return original || compatible;
}
- (BOOL)canBeEnqueuedGaplessly {
    BOOL result = %orig;
    if (YTMUTransitionsRequested()) YTMURecordTransitionEvent(@"native-gapless", result ? @"compatible" : @"incompatible");
    return result;
}
%end
%end

%group TransitionUpcomingPlayback
%hook YTUpcomingPlaybackManager
- (void)setUpcomingPlaybacks:(id)playbacks {
    %orig;
    YTMURefreshNativePrefetchBinding(self);
}
- (void)setCurrentContentVideo:(id)video {
    %orig;
    YTMURefreshNativePrefetchBinding(self);
}
- (void)upcomingPlayerTransitionController:(id)controller didFetchUpcomingPlayablePlaybackData:(id)data {
    if (YTMUTransitionsRequested()) YTMURecordTransitionEvent(@"prefetch-ready", @"native-resolver-returned-playable-data");
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[YTMUSongTransitionCoordinator shared] observeUpcomingPlaybackData:data];
    });
}
- (id)maybeStartPrefetchForPlayback:(id)playback isFirstUpcomingPlayback:(BOOL)first {
    id result = %orig;
    if (YTMUTransitionsRequested() && first) {
        NSInteger code = ((NSInteger (*)(id, SEL))objc_msgSend)(result, NSSelectorFromString(@"result"));
        NSArray *reasons = @[@"already-playable", @"no-next-playback", @"unplayable", @"in-flight", @"started",
            @"endpoint-disabled", @"not-immediate-next", @"live-stream", @"waiting-server-window"];
        YTMURecordTransitionEvent(@"prefetch-result", [NSString stringWithFormat:@"%ld %@", (long)code,
            code >= 0 && code < (NSInteger)reasons.count ? reasons[code] : @"unknown-native-result"]);
    }
    return result;
}
%end
%hook YTUpcomingPlayerTransitionController
- (BOOL)shouldPrefetchPlayerTransition {
    /* Extend only this synchronous eligibility check. The playback config must
       keep its native identity and values for hashing and queue activation. */
    YTMUNativePrefetchScope previous = YTMUBeginNativePrefetchCheck(self);
    BOOL original;
    @try {
        original = %orig;
    } @finally {
        YTMUEndNativePrefetchCheck(previous);
    }
    return YTMUNativeTransitionPrefetchAllowed(self, original);
}
- (void)prefetchPlayerTransition {
    if (YTMUOwnsNativePrefetchBinding(self))
        YTMURecordTransitionEvent(@"prefetch-start", @"native-clock-started-next-song-resolver");
    %orig;
}
- (void)videoResolver:(id)resolver didChangeFromState:(NSInteger)previous toState:(NSInteger)state {
    if (YTMUOwnsNativePrefetchBinding(self))
        YTMURecordTransitionEvent(@"resolver-state", [NSString stringWithFormat:@"%ld -> %ld", (long)previous, (long)state]);
    %orig;
}
%end
%hook YTPlaybackConfig
- (double)prefetchWindow {
    double original = %orig;
    return YTMUScopedNativePrefetchWindow(self, original);
}
%end
%end

%group TransitionContentPolicy
%hook YTMCrossfadeTransitionPolicy
+ (BOOL)isCrossfadeTransitionEnabledForCurrentPlayerResponse:(id)current upcomingPlayerResponse:(id)upcoming {
    if (YTMUOwnsTransitions()) return YTMUTransitionsAllowContentPair(current, upcoming);
    return %orig;
}
%end
%end

%group TransitionArtworkUI
%hook YTMVideoOverlayViewController
- (void)viewDidLoad {
    %orig;
    [[YTMUSongTransitionCoordinator shared] registerArtworkController:self];
}
- (void)setPlayerResponse:(id)response CPN:(id)cpn {
    %orig;
    [[YTMUSongTransitionCoordinator shared] registerArtworkController:self];
    [[YTMUSongTransitionCoordinator shared] artworkResponseChanged:response controller:self];
}
%end
%hook YTMVideoOverlayView
- (void)layoutSubviews {
    %orig;
    [[YTMUSongTransitionCoordinator shared] artworkLayoutChanged:self];
}
- (void)updateThumbnailVisibility {
    %orig;
    [[YTMUSongTransitionCoordinator shared] artworkLayoutChanged:self];
}
- (void)setUserContentMode:(NSUInteger)mode {
    NSUInteger previous = ((NSUInteger (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"userContentMode"));
    %orig;
    if (previous != mode) [[YTMUSongTransitionCoordinator shared] cancelArtworkForOverlay:self];
}
%end
%hook YTImageView
- (void)setImage:(id)image animated:(BOOL)animated {
    BOOL animate = [[YTMUSongTransitionCoordinator shared] shouldAnimateNativeArtworkImage:self] && animated;
    %orig(image, animate);
    [[YTMUSongTransitionCoordinator shared] artworkImageChanged:self];
}
%end
%end

@interface YTMPlayerControlsView : UIView
@end
@interface YTMNowPlayingView : UIView
@property (nonatomic, readonly) YTMPlayerControlsView *playerControlsView;
@end

%group TransitionPlayerUI
%hook YTMPlayerControlsView
- (CGSize)sizeThatFits:(CGSize)size {
    CGSize result = %orig;
    if (YTMUTransitionControlsVisible(self)) result.height += 44;
    return result;
}
- (void)layoutSubviews {
    YTMURestoreTransitionControlFrames(self);
    %orig;
    YTMULayoutTransitionControls(self);
}
%end
%hook YTMNowPlayingView
- (CGSize)sizeThatFits:(CGSize)size {
    CGSize result = %orig;
    if (YTMUTransitionControlsVisible(self.playerControlsView)) result.height += 44;
    return result;
}
- (double)playerControlsViewHeight {
    double height = %orig;
    return height + (YTMUTransitionControlsVisible(self.playerControlsView) ? 44 : 0);
}
- (void)layoutMod3ActionBarScrubberAbovePlayerControls {
    %orig;
    /* This native layout uses a fixed 72pt frame instead of its height getter. */
    if (YTMUTransitionControlsVisible(self.playerControlsView)) {
        CGRect frame = self.playerControlsView.frame; frame.size.height += 44;
        self.playerControlsView.frame = frame;
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
        YTMURecordTransitionEvent(@"startup", YTMUTransitionsCrossfadeSupported() ? @"crossfade-interfaces-available" : @"unsupported-playback-interfaces");
        if (YTMUTransitionsCrossfadeSupported()) {
            %init(TransitionSettings);
            %init(TransitionContentPolicy);
            %init(TransitionEngineFlags);
            %init(TransitionPlaybackMigration);
            %init(TransitionNativePrefetch);
            if (YTMUTransitionMethodMatches(NSClassFromString(@"YTQueuePlaybackTimelineManager"),
                    NSSelectorFromString(@"setPlaybacks:reloadContext:"), "v", @[@"@", @"@"]) &&
                YTMUTransitionMethodMatches(NSClassFromString(@"YTQueuePlaybackTimelineManager"),
                    NSSelectorFromString(@"createPlayerItemForVideoController:reloadContext:"), "@", @[@"@", @"@"])) {
                %init(TransitionTimelineDelivery);
            }
            Class sequencer = NSClassFromString(@"YTMPlayerSequencerController");
            if (YTMUTransitionMethodMatches(sequencer, NSSelectorFromString(@"initWithPlayerViewController:"), "@", @[@"@"]) &&
                YTMUTransitionMethodMatches(sequencer, NSSelectorFromString(@"updateUpcomingVideoIDAndLatencyTickLoggerForSequence:currentSequenceIndex:isLoopAllEnabled:"), "v", @[@"@", @"q", @"B"])) {
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
                YTMUTransitionMethodMatches(multi, NSSelectorFromString(@"playerContextState"), "@", @[]) &&
                YTMUTransitionMethodMatches(NSClassFromString(@"MLHAMMultiPlayerContextState"), NSSelectorFromString(@"playerContexts"), "@", @[]) &&
                YTMUTransitionMethodMatches(multi, NSSelectorFromString(@"commitTransitionEffects"), "v", @[]) &&
                YTMUTransitionMethodMatches(multi, NSSelectorFromString(@"shouldApplyTransitionEffect:previousClip:toClip:"), "B", @[@"@", @"@", @"@"]) &&
                YTMUTransitionMethodMatches(multi, NSSelectorFromString(@"setRate:"), "v", @[@"f"])) {
                %init(TransitionNativePlayer);
            }
            Class response = NSClassFromString(@"YTIPlayerResponse");
            if (YTMUTransitionMethodMatches(response, NSSelectorFromString(@"canEnqueueUpcomingPlaybacks"), "B", @[]) &&
                YTMUTransitionMethodMatches(response, NSSelectorFromString(@"canBeEnqueuedGaplessly"), "B", @[])) {
                %init(TransitionQueueEligibility);
            }
            if (YTMUTransitionMethodMatches(NSClassFromString(@"MLPlayerPoolImpl"),
                NSSelectorFromString(@"acquireQueuePlayerWithStickySettings:mediaPlayerResources:"), "@", @[@"@", @"@"]) &&
                YTMUTransitionMethodMatches(NSClassFromString(@"MLMediaPlayerResources"), NSSelectorFromString(@"audioTransitionProvider"), "@", @[])) {
                %init(TransitionNativePool);
            }
            if (YTMUTransitionMethodMatches(NSClassFromString(@"YTColdConfigMusicPlaybackClientConfigImpl"), NSSelectorFromString(@"iosEnableCrossfade"), "B", @[])) { %init(TransitionMusicFlag); }
            if (YTMUTransitionMethodMatches(NSClassFromString(@"YTColdConfigIosPlayerClientSharedConfigImpl"), NSSelectorFromString(@"enableCrossfade"), "B", @[])) { %init(TransitionPlayerFlag); }
            if (YTMUTransitionMethodMatches(NSClassFromString(@"YTUpcomingPlaybackManager"),
                NSSelectorFromString(@"upcomingPlayerTransitionController:didFetchUpcomingPlayablePlaybackData:"), "v", @[@"@", @"@"]) &&
                YTMUTransitionMethodMatches(NSClassFromString(@"YTUpcomingPlaybackManager"),
                    NSSelectorFromString(@"maybeStartPrefetchForPlayback:isFirstUpcomingPlayback:"), "@", @[@"@", @"B"]) &&
                YTMUTransitionMethodMatches(NSClassFromString(@"YTUpcomingPlaybackManagerPrefetchResultInfo"), NSSelectorFromString(@"result"), "q", @[])) {
                %init(TransitionUpcomingPlayback);
            }
            Class overlayController = NSClassFromString(@"YTMVideoOverlayViewController");
            Class overlay = NSClassFromString(@"YTMVideoOverlayView");
            Class imageView = NSClassFromString(@"YTImageView");
            if (YTMUTransitionMethodMatches(overlayController, @selector(viewDidLoad), "v", @[]) &&
                YTMUTransitionMethodMatches(overlayController, NSSelectorFromString(@"setPlayerResponse:CPN:"), "v", @[@"@", @"@"]) &&
                YTMUTransitionMethodMatches(overlayController, NSSelectorFromString(@"overlayView"), "@", @[]) &&
                YTMUTransitionMethodMatches(overlayController, NSSelectorFromString(@"currentVideoID"), "@", @[]) &&
                YTMUTransitionMethodMatches(overlay, @selector(layoutSubviews), "v", @[]) &&
                YTMUTransitionMethodMatches(overlay, NSSelectorFromString(@"updateThumbnailVisibility"), "v", @[]) &&
                YTMUTransitionMethodMatches(overlay, NSSelectorFromString(@"setUserContentMode:"), "v", @[@"Q"]) &&
                YTMUTransitionMethodMatches(overlay, NSSelectorFromString(@"userContentMode"), "Q", @[]) &&
                YTMUTransitionMethodMatches(overlay, NSSelectorFromString(@"shouldHideThumbnail"), "B", @[]) &&
                YTMUTransitionMethodMatches(overlay, NSSelectorFromString(@"thumbnailView"), "@", @[]) &&
                YTMUTransitionMethodMatches(imageView, NSSelectorFromString(@"image"), "@", @[]) &&
                YTMUTransitionMethodMatches(imageView, NSSelectorFromString(@"imageView"), "@", @[]) &&
                YTMUTransitionMethodMatches(imageView, NSSelectorFromString(@"setImage:animated:"), "v", @[@"@", @"B"])) {
                %init(TransitionArtworkUI);
            }
        }
        Class controls = NSClassFromString(@"YTMPlayerControlsView");
        Class nowPlaying = NSClassFromString(@"YTMNowPlayingView");
        if ([controls isSubclassOfClass:UIView.class] && [nowPlaying isSubclassOfClass:UIView.class] &&
            YTMUTransitionMethodMatches(controls, @selector(layoutSubviews), "v", @[]) &&
            YTMUTransitionMethodMatches(controls, @selector(sizeThatFits:), "{CGSize=dd}", @[@"{CGSize=dd}"]) &&
            YTMUTransitionMethodMatches(controls, NSSelectorFromString(@"style"), "q", @[]) &&
            YTMUTransitionMethodMatches(controls, NSSelectorFromString(@"shuffleButton"), "@", @[]) &&
            YTMUTransitionMethodMatches(controls, NSSelectorFromString(@"loopButton"), "@", @[]) &&
            YTMUTransitionMethodMatches(nowPlaying, @selector(sizeThatFits:), "{CGSize=dd}", @[@"{CGSize=dd}"]) &&
            YTMUTransitionMethodMatches(nowPlaying, NSSelectorFromString(@"playerControlsView"), "@", @[]) &&
            YTMUTransitionMethodMatches(nowPlaying, NSSelectorFromString(@"playerControlsViewHeight"), "d", @[]) &&
            YTMUTransitionMethodMatches(nowPlaying, NSSelectorFromString(@"layoutMod3ActionBarScrubberAbovePlayerControls"), "v", @[])) {
            %init(TransitionPlayerUI);
        }
    }
}
