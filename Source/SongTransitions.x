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
%end
%end

%group TransitionEngineFlags
%hook YTColdConfig
- (BOOL)iosPlayerClientSharedConfigEnableCrossfade {
    return YTMUOwnsTransitions() ? YES : %orig;
}
- (BOOL)musicPlaybackClientConfigIosEnableCrossfade {
    return YTMUOwnsTransitions() ? YES : %orig;
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
- (void)updateUpcomingVideoIDAndLatencyTickLoggerForSequence:(id)sequence currentSequenceIndex:(NSInteger)index isLoopAllEnabled:(BOOL)loopAll {
    %orig;
    [[YTMUSongTransitionCoordinator shared] sequenceChanged];
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
    /* The native policy hook accepts unassigned song experiments; content vetoes remain. */
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
    [[YTMUSongTransitionCoordinator shared] nativeFadeWillStart:self outgoingContext:outgoing activeClip:clip];
    [[YTMUSongTransitionCoordinator shared] prepareIncomingContext:incoming];
    %orig;
    /* The native engine alone activates the incoming clip and advances the queue. */
    dispatch_async(dispatch_get_main_queue(), ^{
        [[YTMUSongTransitionCoordinator shared] nativeFadeStarted:self outgoingContext:outgoing incomingContext:incoming];
    });
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
        [[YTMUSongTransitionCoordinator shared] cancel];
    %orig;
    [[YTMUSongTransitionCoordinator shared] nativeRateChanged:rate player:self];
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
        if (YTMUTransitionsCrossfadeSupported()) {
            %init(TransitionSettings);
            %init(TransitionContentPolicy);
            %init(TransitionEngineFlags);
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
                YTMUTransitionMethodMatches(multi, NSSelectorFromString(@"setRate:"), "v", @[@"f"])) {
                %init(TransitionNativePlayer);
            }
            if (YTMUTransitionMethodMatches(NSClassFromString(@"YTColdConfigMusicPlaybackClientConfigImpl"), NSSelectorFromString(@"iosEnableCrossfade"), "B", @[])) { %init(TransitionMusicFlag); }
            if (YTMUTransitionMethodMatches(NSClassFromString(@"YTColdConfigIosPlayerClientSharedConfigImpl"), NSSelectorFromString(@"enableCrossfade"), "B", @[])) { %init(TransitionPlayerFlag); }
            if (YTMUTransitionsAutoMixSupported()) { %init(TransitionUpcomingPlayback); }
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
