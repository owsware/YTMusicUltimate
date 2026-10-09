#import "YTMUSongTransitions.h"
#import "YTMUAudioWindowDecoder.h"
#import "YTMUNativeTempoSession.h"
#import "../Headers/Localization.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <math.h>

NSString *const YTMUTransitionsChangedNotification = @"YTMUTransitionsChanged";

static const char *unqualified(const char *type) {
    if (!type) return "";
    while (*type && strchr("rnNoORV", *type)) ++type;
    return type;
}

BOOL YTMUTransitionMethodMatches(Class cls, SEL selector, const char *result, NSArray<NSString *> *arguments) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (!signature || signature.numberOfArguments != arguments.count + 2 ||
        strcmp(unqualified(signature.methodReturnType), result)) return NO;
    for (NSUInteger i = 0; i < arguments.count; ++i)
        if (strcmp(unqualified([signature getArgumentTypeAtIndex:i + 2]), arguments[i].UTF8String)) return NO;
    return YES;
}

static id objectGetter(id object, NSString *name) {
    if (!object) return nil;
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2 || unqualified(signature.methodReturnType)[0] != '@') return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL boolGetter(id object, NSString *name, BOOL fallback) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return fallback;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    const char *type = unqualified(signature.methodReturnType);
    if (signature.numberOfArguments != 2 || (strcmp(type, "B") && strcmp(type, "c"))) return fallback;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static int64_t integerGetter(id object, NSString *name, int64_t fallback) {
    SEL selector = NSSelectorFromString(name);
    if (!object || ![object respondsToSelector:selector]) return fallback;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2) return fallback;
    const char *type = unqualified(signature.methodReturnType);
    if (!strcmp(type, "i")) return ((int32_t (*)(id, SEL))objc_msgSend)(object, selector);
    if (!strcmp(type, "I")) return ((uint32_t (*)(id, SEL))objc_msgSend)(object, selector);
    if (!strcmp(type, "q")) return ((int64_t (*)(id, SEL))objc_msgSend)(object, selector);
    if (!strcmp(type, "Q")) return ((uint64_t (*)(id, SEL))objc_msgSend)(object, selector);
    return fallback;
}

static double doubleGetter(id object, NSString *name, double fallback) {
    SEL selector = NSSelectorFromString(name);
    if (!YTMUTransitionMethodMatches([object class], selector, "d", @[])) return fallback;
    return ((double (*)(id, SEL))objc_msgSend)(object, selector);
}

static id objectIvar(id object, const char *name) {
    if (!object) return nil;
    Ivar ivar = class_getInstanceVariable([object class], name);
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : NULL;
    return type && type[0] == '@' ? object_getIvar(object, ivar) : nil;
}

static NSString *videoID(id response) {
    id identifier = objectGetter(response, @"videoID");
    return [identifier isKindOfClass:NSString.class] ? identifier : nil;
}

static id playerData(id response) {
    if ([response isKindOfClass:NSClassFromString(@"YTIPlayerResponse")]) return response;
    return objectGetter(response, @"playerData");
}

static double responseDuration(id response) {
    id data = playerData(response);
    id details = objectGetter(data, @"videoDetails");
    SEL selector = NSSelectorFromString(@"lengthSeconds");
    if (![details respondsToSelector:selector]) return 0;
    NSMethodSignature *signature = [details methodSignatureForSelector:selector];
    const char *type = unqualified(signature.methodReturnType);
    if (signature.numberOfArguments != 2) return 0;
    if (!strcmp(type, "q") || !strcmp(type, "Q") || !strcmp(type, "i") || !strcmp(type, "I"))
        return integerGetter(details, @"lengthSeconds", 0);
    if (type[0] == '@') {
        id value = objectGetter(details, @"lengthSeconds");
        return [value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class] ? [value doubleValue] : 0;
    }
    return 0;
}

static NSURL *audioURL(id response) {
    id streaming = objectGetter(objectGetter(response, @"playerData"), @"streamingData");
    id manifest = objectGetter(streaming, @"hlsManifestURL");
    if ([manifest isKindOfClass:NSString.class] && [manifest length]) return [NSURL URLWithString:manifest];
    id formats = objectGetter(streaming, @"adaptiveFormatsArray");
    if (![formats isKindOfClass:NSArray.class]) return nil;
    for (id format in formats) {
        id mime = objectGetter(format, @"mimeType");
        id url = objectGetter(format, @"URL");
        if ([mime isKindOfClass:NSString.class] && [mime hasPrefix:@"audio/"] && [url isKindOfClass:NSString.class])
            return [NSURL URLWithString:url];
    }
    return nil;
}

BOOL YTMUTransitionsCrossfadeSupported(void) {
    static BOOL supported; static dispatch_once_t once;
    dispatch_once(&once, ^{
        supported = [NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] isEqualToString:@"9.40.2"] &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTMSettingsImpl"), NSSelectorFromString(@"isCrossfadeEnabled"), "B", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTMSettingsImpl"), NSSelectorFromString(@"crossfadeDuration"), "q", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTCrossfadeTransition"), NSSelectorFromString(@"initWithDuration:"), "@", @[@"d"]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTMPlayerSequencerController"), NSSelectorFromString(@"crossfadeTransitionFromSettings"), "@", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTMPlayerSequencerController"), NSSelectorFromString(@"initWithPlayerViewController:"), "@", @[@"@"]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTMPlayerSequencerController"), NSSelectorFromString(@"updateCrossfadeTransitionInActiveSequence"), "v", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTMPlayerSequencerController"), NSSelectorFromString(@"scheduleSetSequenceForQueueModification"), "v", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTMPlayerSequencerController"), NSSelectorFromString(@"updateUpcomingVideoIDAndLatencyTickLoggerForSequence:currentSequenceIndex:isLoopAllEnabled:"), "v", @[@"@", @"q", @"B"]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTMPlayerSequencerController"), NSSelectorFromString(@"resetSequence"), "v", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTMPlayerSequencerController"), NSSelectorFromString(@"isLoopingOnSingleItemEnabled"), "B", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTMPlayerSequencerController"), NSSelectorFromString(@"setSequenceForTapNextOrTapPrevWithPlayerTransition:playbackConfig:"), "v", @[@"@", @"@"]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"MLHAMMultiPlayer"), NSSelectorFromString(@"spawnCrossfadeWithActiveContext:activeClip:nextContext:"), "v", @[@"@", @"@", @"@"]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"MLHAMMultiPlayer"), NSSelectorFromString(@"pauseWithStoppageReason:"), "v", @[@"i"]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"MLHAMMultiPlayer"), NSSelectorFromString(@"play"), "v", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"MLHAMMultiPlayer"), NSSelectorFromString(@"setRate:"), "v", @[@"f"]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"MLHAMMultiPlayer"), NSSelectorFromString(@"rate"), "f", @[]) &&
            YTMUTransitionMethodMatches(object_getClass(NSClassFromString(@"YTMCrossfadeTransitionPolicy")), NSSelectorFromString(@"isCrossfadeTransitionEnabledForCurrentPlayerResponse:upcomingPlayerResponse:"), "B", @[@"@", @"@"]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"MLHAMMultiPlayer"), NSSelectorFromString(@"clearBackgroundPlayer"), "v", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"MLHAMQueuePlayerContext"), NSSelectorFromString(@"audioFadeController"), "@", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"MLAudioFadeController"), NSSelectorFromString(@"setPendingTransitionEffects:"), "v", @[@"@"]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTPlayerViewController"), NSSelectorFromString(@"seekToTime:"), "v", @[@"d"]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTPlayerViewController"), NSSelectorFromString(@"seekToTime:seekSource:"), "v", @[@"d", @"i"]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTPlayerViewController"), NSSelectorFromString(@"seekToTime:toleranceBefore:toleranceAfter:seekSource:"), "v", @[@"d", @"d", @"d", @"i"]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTColdConfigMusicPlaybackClientConfigImpl"), NSSelectorFromString(@"iosEnableCrossfade"), "B", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTColdConfigIosPlayerClientSharedConfigImpl"), NSSelectorFromString(@"enableCrossfade"), "B", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTColdConfigIosPlayerClientSharedConfigImpl"), NSSelectorFromString(@"enableVolumeFading"), "B", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTColdConfig"), NSSelectorFromString(@"iosPlayerClientSharedConfigEnableCrossfade"), "B", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTColdConfig"), NSSelectorFromString(@"musicPlaybackClientConfigIosEnableCrossfade"), "B", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTColdConfig"), NSSelectorFromString(@"iosPlayerClientSharedConfigEnableVolumeFading"), "B", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTHotConfigIosPlayerClientSharedConfigImpl"), NSSelectorFromString(@"enablePlayerPlaybackMigration"), "B", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTHotConfig"), NSSelectorFromString(@"iosPlayerClientSharedConfigEnablePlayerPlaybackMigration"), "B", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTPlayerSequencerDefaultPlaybackItemHandler"),
                NSSelectorFromString(@"initWithPlayerViewController:latencyLoggerProvider:shouldEnableMediaDrivenPrefetch:"), "@", @[@"@", @"@", @"B"]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTLocalPlaybackController"),
                NSSelectorFromString(@"initWithParentResponder:overlayFactory:playerView:playbackControllerDelegate:viewportSizeProvider:recompositeProvider:shouldDelayAdsPlaybackCoordinatorCreation:shouldEnableMediaDrivenPrefetch:enablePictureInPictureSupport:"),
                "@", @[@"@", @"@", @"@", @"@", @"@", @"@", @"B", @"B", @"B"]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTLocalPlaybackController"), NSSelectorFromString(@"setUpcomingPlayerPlaybacks:"), "v", @[@"@"]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTLocalPlaybackController"), NSSelectorFromString(@"upcomingPlaybackManager:resolvedPlayablePlaybacks:"), "v", @[@"@", @"@"]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTLocalPlaybackController"), NSSelectorFromString(@"upcomingPlaybackManagerDidRequestPrefetchAfterLastUpcomingPlayback:"), "@", @[@"@"]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTUpcomingPlaybackManager"), NSSelectorFromString(@"upcomingPlaybacksArray"), "@", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTPlaybackConfig"), NSSelectorFromString(@"prefetchWindow"), "d", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTPlaybackConfig"), NSSelectorFromString(@"setPrefetchWindow:"), "v", @[@"d"]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTPlayerViewController"), NSSelectorFromString(@"contentPlayerResponse"), "@", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTPlayerViewController"), NSSelectorFromString(@"shouldPlaybackController:applyTransitionEffect:currentPlayerResponse:upcomingPlayerResponse:"), "B", @[@"@", @"@", @"@", @"@"]);
    });
    return supported;
}

BOOL YTMUTransitionsAutoMixSupported(void) {
    static BOOL supported; static dispatch_once_t once;
    dispatch_once(&once, ^{
        Ivar renderer = class_getInstanceVariable(NSClassFromString(@"MLHAMQueuePlayer"), "_audioTrackRenderer");
        supported = YTMUTransitionsCrossfadeSupported() && renderer && ivar_getTypeEncoding(renderer)[0] == '@' &&
            YTMUTransitionMethodMatches(NSClassFromString(@"HAMSBARAudioTrackRenderer"), NSSelectorFromString(@"underlyingRenderer"), "@", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"MLHAMQueuePlayer"), NSSelectorFromString(@"setRate:"), "v", @[@"f"]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"MLHAMQueuePlayer"), NSSelectorFromString(@"rate"), "f", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"MLHAMQueuePlayer"), NSSelectorFromString(@"currentTime"), "{?=ddd}", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"MLHAMQueuePlayer"), NSSelectorFromString(@"playerQueue"), "@", @[]) &&
            YTMUTransitionMethodMatches(NSClassFromString(@"YTUpcomingPlaybackManager"), NSSelectorFromString(@"upcomingPlayerTransitionController:didFetchUpcomingPlayablePlaybackData:"), "v", @[@"@", @"@"]) &&
            YTMUTransitionMethodMatches(AVSampleBufferAudioRenderer.class, NSSelectorFromString(@"audioTimePitchAlgorithm"), "@", @[]) &&
            YTMUTransitionMethodMatches(AVSampleBufferAudioRenderer.class, NSSelectorFromString(@"setAudioTimePitchAlgorithm:"), "v", @[@"@"]);
    });
    return supported;
}

NSDictionary *YTMUTransitionPreferences(void) {
    NSDictionary *stored = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] ?: @{};
    NSMutableDictionary *preferences = [@{@"songTransitionsEnabled": @NO, @"songTransitionMode": @0,
                                          @"crossfadeDuration": @4, @"YTMUltimateIsEnabled": @YES} mutableCopy];
    for (NSString *key in preferences.allKeys) if ([stored[key] isKindOfClass:NSNumber.class]) preferences[key] = stored[key];
    preferences[@"songTransitionMode"] = @([preferences[@"songTransitionMode"] integerValue] == YTMUTransitionCrossfade ? 1 : 0);
    double duration = [preferences[@"crossfadeDuration"] doubleValue];
    preferences[@"crossfadeDuration"] = @(isfinite(duration) ? fmin(12, fmax(1, round(duration))) : 4);
    return preferences;
}

void YTMUSetTransitionPreference(NSString *key, id value) {
    if (![@[@"songTransitionsEnabled", @"songTransitionMode", @"crossfadeDuration"] containsObject:key] ||
        ![value isKindOfClass:NSNumber.class]) return;
    NSMutableDictionary *preferences = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] mutableCopy] ?: [NSMutableDictionary dictionary];
    if ([key isEqualToString:@"crossfadeDuration"]) {
        double duration = [value doubleValue]; value = @(isfinite(duration) ? fmin(12, fmax(1, round(duration))) : 4);
    } else if ([key isEqualToString:@"songTransitionMode"]) value = @([value integerValue] == 1 ? 1 : 0);
    else value = @([value boolValue]);
    preferences[key] = value;
    [[NSUserDefaults standardUserDefaults] setObject:preferences forKey:@"YTMUltimate"];
}

BOOL YTMUTransitionsRequested(void) {
    NSDictionary *preferences = YTMUTransitionPreferences();
    return [preferences[@"YTMUltimateIsEnabled"] boolValue] && [preferences[@"songTransitionsEnabled"] boolValue] &&
        YTMUTransitionsCrossfadeSupported() &&
        ([preferences[@"songTransitionMode"] integerValue] == YTMUTransitionCrossfade || YTMUTransitionsAutoMixSupported());
}

static YTMUMixContent responseContent(id response) {
    id data = playerData(response);
    id details = objectGetter(data, @"videoDetails");
    id config = objectGetter(objectGetter(objectGetter(data, @"playerConfig"), @"audioConfig"), @"crossfadeConfig");
    id metadata = objectGetter(data, @"trackAlbumMetadata");
    NSString *album = objectGetter(metadata, @"externalPlaylistId");
    /* Values are verified from 9.40.2's protobuf enum descriptors. */
    return (YTMUMixContent){
        .duration = responseDuration(response),
        .musicVideoType = (int)integerGetter(details, @"musicVideoType", -1),
        .crossfadeBehavior = (int)integerGetter(config, @"crossfadeBehavior", config ? -1 : 0),
        .live = boolGetter(data, @"isLivePlayback", YES) || boolGetter(details, @"isLiveContent", NO),
        .podcast = boolGetter(details, @"isExternallyHostedPodcast", NO),
        .album = [album isKindOfClass:NSString.class] ? album.UTF8String : NULL,
        .hasTrackNumber = boolGetter(metadata, @"hasTrackNumber", NO),
        .trackNumber = (int)integerGetter(metadata, @"trackNumber", 0)
    };
}

BOOL YTMUTransitionsAllowContentPair(id current, id upcoming) {
    if (!YTMUTransitionsRequested()) return NO;
    if (!current || !upcoming || !videoID(current).length || !videoID(upcoming).length) {
        YTMURecordTransitionEvent(@"content", @"missing-current-or-next-response"); return NO;
    }
    if ([videoID(current) isEqual:videoID(upcoming)]) {
        YTMURecordTransitionEvent(@"content", @"same-song"); return NO;
    }
    YTMUMixContent outgoing = responseContent(current), incoming = responseContent(upcoming);
    const char *reason = YTMUMixContentExclusion(&outgoing, &incoming);
    YTMURecordTransitionEvent(@"content", [NSString stringWithFormat:@"%s; types=%d/%d; policy=%d/%d; seconds=%.0f/%.0f",
        reason ?: "eligible", outgoing.musicVideoType, incoming.musicVideoType, outgoing.crossfadeBehavior,
        incoming.crossfadeBehavior, outgoing.duration, incoming.duration]);
    return reason == NULL;
}

BOOL YTMUTransitionsCanReuseNativeQueue(id data) {
    if (!YTMUTransitionsRequested()) return NO;
    YTMUMixContent song = responseContent(data);
    /* Only replace the "new player for next playback" preference when YouTube
       itself confirms this response is gapless compatible. Never override its
       forced incompatibility, preroll or interstitial checks. */
    song.album = NULL;
    return YTMUAllowsMixContentPair(&song, &song) && boolGetter(data, @"canBeEnqueuedGaplessly", NO) &&
        !boolGetter(data, @"hasPrerollAds", YES) && integerGetter(data, @"interstitialPodsArray_Count", -1) == 0;
}

static const void *YTMUPrefetchWindowKey = &YTMUPrefetchWindowKey;

void YTMUPrepareUpcomingTransitionPlayback(id playback) {
    id config = objectGetter(playback, @"playbackConfig");
    if (!YTMUTransitionMethodMatches([config class], NSSelectorFromString(@"setPrefetchWindow:"), "v", @[@"d"])) return;
    double previous = doubleGetter(config, @"prefetchWindow", 0);
    NSArray<NSNumber *> *saved = objc_getAssociatedObject(config, YTMUPrefetchWindowKey);
    double native = saved.count == 2 && previous == saved[1].doubleValue ? saved[0].doubleValue : previous;
    id transition = objectGetter(playback, @"incomingTransition");
    BOOL enabled = YTMUTransitionsRequested() && [transition isKindOfClass:NSClassFromString(@"YTCrossfadeTransition")];
    if (!enabled && !saved) return;
    NSDictionary *prefs = YTMUTransitionPreferences();
    double window = YTMUMixPrefetchWindow(native, [prefs[@"crossfadeDuration"] doubleValue],
        [prefs[@"songTransitionMode"] integerValue] == YTMUTransitionAutoMix, enabled);
    if (previous != window) ((void (*)(id, SEL, double))objc_msgSend)(config, NSSelectorFromString(@"setPrefetchWindow:"), window);
    objc_setAssociatedObject(config, YTMUPrefetchWindowKey, window == native ? nil : @[@(native), @(window)], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTMURecordTransitionEvent(@"prefetch-window", [NSString stringWithFormat:@"native=%.1f effective=%.1f seconds", native, window]);
}

void YTMURecordNativeTransitionItem(id item, id videoController) {
    if (!YTMUTransitionsRequested()) return;
    id playback = objectGetter(objectGetter(videoController, @"singleVideo"), @"playerPlayback");
    id source = objectGetter(playback, @"incomingTransition");
    id effect = objectGetter(item, @"incomingTransition");
    YTMURecordTransitionEvent(@"player-item", [NSString stringWithFormat:@"playback=%@ source=%@ item=%@ effect=%@ fade=%.2f seconds",
        [playback class], [source class], [item class], [effect class], doubleGetter(effect, @"duration", 0)]);
}

NSString *YTMUTransitionsAvailability(void) {
    if (!YTMUTransitionsCrossfadeSupported()) return LOC(@"TRANSITIONS_UNAVAILABLE");
    if (!YTMUTransitionsAutoMixSupported()) return LOC(@"AUTOMIX_UNAVAILABLE");
    return LOC(@"TRANSITIONS_FOOTER");
}

typedef struct { double mediaTime, productionTime, absoluteTime; } YTMUNativePlayerTime;

@interface YTMUSongTransitionCoordinator ()
@property (nonatomic, weak) id sequencer;
@property (nonatomic, weak) id playerController;
@property (nonatomic, strong) NSDictionary *preferences;
@property (nonatomic, strong) NSOperationQueue *analysisQueue;
@property (nonatomic, strong) NSCache<NSString *, NSData *> *cache;
@property (nonatomic, strong) NSMutableArray<NSString *> *cacheKeys;
@property (nonatomic, strong) NSHashTable *renderers;
@property (nonatomic, copy) NSString *pair;
@property (atomic) NSUInteger generation;
@property (nonatomic) YTMUMixPlan plan;
@property (nonatomic, weak) id mixingPlayer;
@property (nonatomic, weak) id nativeOverlapPlayer;
@property (nonatomic) BOOL handoffInProgress;
@property (nonatomic, weak) id incomingPlayer;
@property (atomic, strong) YTMUNativeTempoSession *tempoSession;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSHashTable *artworkControllers;
@property (nonatomic, weak) id artworkController;
@property (nonatomic, weak) UIView *artworkOverlay;
@property (nonatomic, weak) UIView *artworkThumbnail;
@property (nonatomic, weak) id artworkClockPlayer;
@property (nonatomic, strong) UIImageView *outgoingArtwork;
@property (nonatomic, copy) NSString *artworkIncomingID;
@property (nonatomic) BOOL artworkRunning;
@property (nonatomic) BOOL artworkIncomingAssigned;
@property (nonatomic) BOOL artworkIncomingLoaded;
@property (nonatomic) double artworkStartTime;
@property (nonatomic) double artworkDuration;
@property (nonatomic) double artworkProgress;
@property (nonatomic) double artworkRevealStart;
@property (nonatomic) BOOL playbackPaused;
- (void)prepareArtworkForOutgoingContext:(id)context clip:(id)clip;
- (BOOL)updateArtworkProgress;
- (void)cancelArtwork;
@end

@implementation YTMUSongTransitionCoordinator
+ (instancetype)shared {
    static YTMUSongTransitionCoordinator *coordinator; static dispatch_once_t once;
    dispatch_once(&once, ^{ coordinator = [self new]; }); return coordinator;
}
- (instancetype)init {
    if ((self = [super init])) {
        _preferences = YTMUTransitionPreferences();
        _analysisQueue = [NSOperationQueue new]; _analysisQueue.maxConcurrentOperationCount = 1;
        _analysisQueue.qualityOfService = NSQualityOfServiceUtility;
        _cache = [NSCache new]; _cache.countLimit = 64; _cache.totalCostLimit = 64 * sizeof(YTMUMixAnalysis);
        _cacheKeys = [NSMutableArray array];
        _renderers = [NSHashTable weakObjectsHashTable];
        _artworkControllers = [NSHashTable weakObjectsHashTable];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(preferencesChanged:)
                                                     name:NSUserDefaultsDidChangeNotification object:nil];
        for (NSString *name in @[AVAudioSessionRouteChangeNotification, AVAudioSessionInterruptionNotification,
                                 AVAudioSessionMediaServicesWereResetNotification, NSProcessInfoPowerStateDidChangeNotification])
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(environmentChanged:) name:name object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(artworkEnvironmentChanged:)
                                                     name:UIApplicationWillResignActiveNotification object:nil];
    }
    return self;
}
- (void)bindSequencer:(id)sequencer playerController:(id)controller {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self bindSequencer:sequencer playerController:controller]; }); return;
    }
    self.sequencer = sequencer; self.playerController = controller;
    YTMURecordTransitionEvent(@"sequencer", [NSString stringWithFormat:@"bound %@ / %@", [sequencer class], [controller class]]);
}
- (void)preferencesChanged:(NSNotification *)notification {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self preferencesChanged:notification]; }); return; }
    NSDictionary *preferences = YTMUTransitionPreferences();
    if ([preferences isEqualToDictionary:self.preferences]) return;
    self.preferences = preferences;
    YTMURecordTransitionEvent(@"preferences", [NSString stringWithFormat:@"enabled=%@ mode=%@ seconds=%@",
        preferences[@"songTransitionsEnabled"], preferences[@"songTransitionMode"], preferences[@"crossfadeDuration"]]);
    [self cancel];
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMUTransitionsChangedNotification object:nil];
    [self updateSequence];
}
- (void)environmentChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        YTMURecordTransitionEvent(@"environment", notification.name);
        [self cancel]; [self updateSequence];
    });
}
- (void)updateSequence {
    SEL selector = NSSelectorFromString(@"updateCrossfadeTransitionInActiveSequence");
    if (YTMUTransitionMethodMatches([self.sequencer class], selector, "v", @[]))
        ((void (*)(id, SEL))objc_msgSend)(self.sequencer, selector);
    /* Refresh copied native upcoming playback objects as well as the sequencer
       items. Mutating a previously copied item's effect alone can stay stale. */
    SEL refresh = NSSelectorFromString(@"scheduleSetSequenceForQueueModification");
    if (YTMUTransitionMethodMatches([self.sequencer class], refresh, "v", @[]))
        ((void (*)(id, SEL))objc_msgSend)(self.sequencer, refresh);
}
- (BOOL)allowsTransitionsForPlaybackController:(id)controller current:(id)current upcoming:(id)upcoming {
    if (!YTMUTransitionsAllowContentPair(current, upcoming)) return NO;
    id status = objectGetter(controller, @"playerStatus");
    NSString *reason = !status ? @"missing-player-status" :
        boolGetter(status, @"externalPlayback", YES) ? @"casting-or-unknown-route" :
        boolGetter(status, @"pictureInPicture", NO) ? @"picture-in-picture" :
        boolGetter(self.sequencer, @"isLoopingOnSingleItemEnabled", YES) ? @"repeat-one-or-missing-sequencer" : nil;
    YTMURecordTransitionEvent(@"playback-policy", [NSString stringWithFormat:@"%@; controller=%@; status=%@",
        reason ?: @"eligible", [controller class], [status class]]);
    if (reason) return NO;
    return YES;
}
- (double)crossfadeDuration {
    return [self crossfadeDurationForSequencer:self.sequencer];
}
- (double)crossfadeDurationForSequencer:(id)sequencer {
    /* Native construction can run inside init, before the coordinator binds.
       Evaluate repeat-one on the sequencer actually requesting the effect. */
    if (boolGetter(sequencer, @"isLoopingOnSingleItemEnabled", YES)) return 0;
    NSString *currentID = videoID(objectGetter(self.playerController, @"contentPlayerResponse"));
    NSString *nextID = objectGetter(sequencer, @"upcomingVideoID");
    NSString *pair = currentID && nextID ? [NSString stringWithFormat:@"%@/%@", currentID, nextID] : nil;
    if (self.plan.kind != YTMUMixBypass && [pair isEqualToString:self.pair])
        return self.plan.duration;
    double duration = [self.preferences[@"crossfadeDuration"] doubleValue];
    double currentDuration = responseDuration(objectGetter(self.playerController, @"contentPlayerResponse"));
    return currentDuration > 0 ? MIN(duration, currentDuration / 2) : duration;
}
- (void)observeCurrentResponse:(id)current upcomingResponse:(id)upcoming {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self observeCurrentResponse:current upcomingResponse:upcoming]; }); return;
    }
    if (!YTMUTransitionsRequested() || self.incomingPlayer || self.handoffInProgress) return;
    NSString *currentID = videoID(current), *nextID = videoID(upcoming);
    id immediateNext = objectGetter(self.sequencer, @"upcomingVideoID");
    if (!currentID.length || !nextID.length || ![immediateNext isEqual:nextID]) return;
    NSString *pair = [NSString stringWithFormat:@"%@/%@", currentID, nextID];
    if ([pair isEqualToString:self.pair]) return;
    [self.analysisQueue cancelAllOperations];
    self.generation++; self.pair = pair;
    double outgoingDuration = responseDuration(current), incomingDuration = responseDuration(upcoming);
    double fallback = [self.preferences[@"crossfadeDuration"] doubleValue];
    self.plan = YTMUPlanMix(NULL, NULL, outgoingDuration, incomingDuration, fallback, 0, 0);
    YTMURecordTransitionEvent(@"plan", [NSString stringWithFormat:@"crossfade %.2f seconds", self.plan.duration]);
    NSUInteger generation = self.generation;
    /* Do not recursively rebuild a queue from inside its eligibility callback. */
    dispatch_async(dispatch_get_main_queue(), ^{
        id state = objectGetter(self.nativeOverlapPlayer, @"playerContextState");
        if (generation == self.generation && !self.handoffInProgress && !objectGetter(state, @"backgroundPlayerContext"))
            [self updateSequence];
    });
    if ([self.preferences[@"songTransitionMode"] integerValue] != YTMUTransitionAutoMix) return;
    NSString *tailKey = [NSString stringWithFormat:@"%@/tail/%.3f", currentID, outgoingDuration];
    NSString *headKey = [NSString stringWithFormat:@"%@/head/%.3f", nextID, incomingDuration];
    NSData *cachedTail = [self.cache objectForKey:tailKey], *cachedHead = [self.cache objectForKey:headKey];
    if (NSProcessInfo.processInfo.lowPowerModeEnabled && (!cachedTail || !cachedHead)) {
        YTMURecordTransitionEvent(@"analysis", @"cached-only; using crossfade in Low Power Mode"); return;
    }
    NSURL *tailURL = audioURL(current), *headURL = audioURL(upcoming);
    if ((!cachedTail && !tailURL) || (!cachedHead && !headURL)) {
        YTMURecordTransitionEvent(@"analysis", @"audio window unavailable; using crossfade"); return;
    }
    __weak typeof(self) weakSelf = self;
    NSBlockOperation *operation = [NSBlockOperation new];
    __weak NSBlockOperation *weakOperation = operation;
    [operation addExecutionBlock:^{
        @autoreleasepool {
            NSBlockOperation *task = weakOperation;
            if (!task || task.cancelled) return;
            YTMUMixAnalysis tail, head;
            BOOL haveTail = cachedTail.length == sizeof(tail), haveHead = cachedHead.length == sizeof(head);
            if (haveTail) [cachedTail getBytes:&tail length:sizeof(tail)];
            else haveTail = YTMUDecodeAudioWindow(tailURL, MAX(0, outgoingDuration - 12), MIN(12, outgoingDuration), task, &tail);
            if (task.cancelled) return;
            if (haveHead) [cachedHead getBytes:&head length:sizeof(head)];
            else haveHead = YTMUDecodeAudioWindow(headURL, 0, MIN(12, incomingDuration), task, &head);
            if (task.cancelled) return;
            NSData *tailData = haveTail ? [NSData dataWithBytes:&tail length:sizeof(tail)] : nil;
            NSData *headData = haveHead ? [NSData dataWithBytes:&head length:sizeof(head)] : nil;
            YTMUMixPlan plan = YTMUPlanMix(haveTail ? &tail : NULL, haveHead ? &head : NULL,
                                         outgoingDuration, incomingDuration, fallback, YTMUTransitionsAutoMixSupported(), 0);
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf || task.cancelled || generation != strongSelf.generation) return;
                if (tailData) [strongSelf cacheAnalysis:tailData forKey:tailKey];
                if (headData) [strongSelf cacheAnalysis:headData forKey:headKey];
                strongSelf.plan = plan;
                YTMURecordTransitionEvent(@"analysis", [NSString stringWithFormat:@"outro=%d intro=%d plan=%d fade=%.2f rate=%.4f",
                    haveTail, haveHead, plan.kind, plan.duration, plan.incomingRate]);
                /* Rebuilding a transition after overlap begins would change its end point. */
                id state = objectGetter(strongSelf.nativeOverlapPlayer, @"playerContextState");
                if (!strongSelf.incomingPlayer && !strongSelf.handoffInProgress && !objectGetter(state, @"backgroundPlayerContext"))
                    [strongSelf updateSequence];
            });
        }
    }];
    [self.analysisQueue addOperation:operation];
}
- (void)cacheAnalysis:(NSData *)data forKey:(NSString *)key {
    [self.cacheKeys removeObject:key];
    /* NSCache's limits are advisory; enforce a hard entry limit ourselves. */
    while (self.cacheKeys.count >= 64) {
        [self.cache removeObjectForKey:self.cacheKeys.firstObject];
        [self.cacheKeys removeObjectAtIndex:0];
    }
    [self.cacheKeys addObject:key];
    [self.cache setObject:data forKey:key cost:data.length];
}
- (void)observeUpcomingPlaybackData:(id)data {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self observeUpcomingPlaybackData:data]; });
        return;
    }
    id current = objectGetter(self.playerController, @"contentPlayerResponse");
    id upcoming = objectGetter(data, @"playerResponse");
    YTMURecordTransitionEvent(@"prefetch", [NSString stringWithFormat:@"current=%@ next=%@", [current class], [upcoming class]]);
    id controller = objectIvar(self.playerController, "_playbackController");
    Class policy = NSClassFromString(@"YTMCrossfadeTransitionPolicy");
    SEL selector = NSSelectorFromString(@"isCrossfadeTransitionEnabledForCurrentPlayerResponse:upcomingPlayerResponse:");
    if (![self allowsTransitionsForPlaybackController:controller current:current upcoming:upcoming] ||
        !YTMUTransitionMethodMatches(object_getClass(policy), selector, "B", @[@"@", @"@"])) return;
    if (((BOOL (*)(id, SEL, id, id))objc_msgSend)(policy, selector, current, upcoming))
        [self observeCurrentResponse:current upcomingResponse:upcoming];
}
- (void)prepareIncomingContext:(id)context {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self prepareIncomingContext:context]; }); return;
    }
    if (self.plan.kind != YTMUMixAutoMix || !YTMUTransitionsRequested()) return;
    id player = objectGetter(context, @"player");
    id queue = objectGetter(player, @"playerQueue");
    if (!queue) return;
    NSUInteger generation = self.generation;
    /* Enqueue before native play, on the player's own queue. Existing renderers are covered too. */
    dispatch_async((dispatch_queue_t)queue, ^{
        if (generation == self.generation)
            [self prepareAudioRenderer:objectIvar(player, "_audioTrackRenderer") queue:(dispatch_queue_t)queue generation:generation];
    });
}
- (void)prepareAudioRenderer:(id)trackRenderer queue:(dispatch_queue_t)queue generation:(NSUInteger)generation {
    if (!YTMUTransitionsRequested() || !YTMUTransitionsAutoMixSupported() ||
        [YTMUTransitionPreferences()[@"songTransitionMode"] integerValue] != YTMUTransitionAutoMix) return;
    id renderer = objectGetter(trackRenderer, @"underlyingRenderer");
    if (![renderer isKindOfClass:AVSampleBufferAudioRenderer.class]) return;
    SEL setter = NSSelectorFromString(@"setAudioTimePitchAlgorithm:");
    NSString *original = objectGetter(renderer, @"audioTimePitchAlgorithm");
    if (!original) return;
    if (!objc_getAssociatedObject(renderer, YTMUNativePitchKey)) {
        objc_setAssociatedObject(renderer, YTMUNativePitchKey, original, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(renderer, YTMUNativePitchQueueKey, queue, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(renderer, YTMUNativePitchGenerationKey, @(generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, id))objc_msgSend)(renderer, setter, AVAudioTimePitchAlgorithmSpectral);
    if (![objectGetter(renderer, @"audioTimePitchAlgorithm") isEqual:AVAudioTimePitchAlgorithmSpectral]) {
        YTMURestoreNativePitch(renderer);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation == self.generation && YTMUTransitionsRequested()) [self.renderers addObject:renderer];
        else dispatch_async(queue, ^{ YTMURestoreNativePitchForGeneration(renderer, @(generation)); });
    });
}
- (void)nativeFadeWillStart:(id)multiPlayer outgoingContext:(id)outgoing activeClip:(id)clip {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self nativeFadeWillStart:multiPlayer outgoingContext:outgoing activeClip:clip]; }); return;
    }
    if (!YTMUTransitionsRequested()) return;
    self.handoffInProgress = YES; self.nativeOverlapPlayer = multiPlayer;
    [self prepareArtworkForOutgoingContext:outgoing clip:clip];
}
- (void)nativeFadeStarted:(id)multiPlayer outgoingContext:(id)outgoing incomingContext:(id)incoming {
    if (![NSThread isMainThread] || !YTMUTransitionsRequested()) return;
    self.handoffInProgress = NO;
    id nativeState = objectGetter(multiPlayer, @"playerContextState");
    if (objectGetter(nativeState, @"activePlayerContext") != incoming || !objectGetter(nativeState, @"backgroundPlayerContext")) {
        YTMURecordTransitionEvent(@"overlap", @"spawn-did-not-retain-both-players");
        [self cancelArtwork]; return;
    }
    YTMURecordTransitionEvent(@"overlap", [NSString stringWithFormat:@"both-native-players-active; app-state=%ld",
        (long)UIApplication.sharedApplication.applicationState]);
    self.nativeOverlapPlayer = multiPlayer;
    self.artworkRunning = self.outgoingArtwork != nil;
    if (self.artworkRunning) [self resumeMix];
    if (self.plan.kind != YTMUMixAutoMix ||
        [self.preferences[@"songTransitionMode"] integerValue] != YTMUTransitionAutoMix ||
        fabs(self.plan.incomingRate - 1) < 0.001) { [self restorePitchAlgorithms]; return; }
    id player = objectGetter(incoming, @"player");
    if (!YTMUTransitionMethodMatches([player class], NSSelectorFromString(@"currentTime"), "{?=ddd}", @[]) ||
        !YTMUTransitionMethodMatches([player class], NSSelectorFromString(@"rate"), "f", @[]) ||
        !YTMUTransitionMethodMatches([player class], NSSelectorFromString(@"setRate:"), "v", @[@"f"])) {
        [self restorePitchAlgorithms]; return;
    }
    float rate = ((float (*)(id, SEL))objc_msgSend)(player, NSSelectorFromString(@"rate"));
    if (!isfinite(rate) || fabsf(rate - 1) > 0.001) { [self restorePitchAlgorithms]; return; }
    id queue = objectGetter(player, @"playerQueue");
    if (!queue) { [self restorePitchAlgorithms]; return; }
    NSUInteger generation = self.generation;
    YTMUMixPlan plan = self.plan;
    dispatch_async((dispatch_queue_t)queue, ^{
        if (generation != self.generation) return;
        /* Native renderer creation may happen after the pre-play preparation. */
        [self prepareAudioRenderer:objectIvar(player, "_audioTrackRenderer") queue:(dispatch_queue_t)queue generation:generation];
        id renderer = objectGetter(objectIvar(player, "_audioTrackRenderer"), @"underlyingRenderer");
        /* No speed adjustment unless the actual incoming renderer confirms pitch preservation. */
        BOOL pitchReady = [renderer isKindOfClass:AVSampleBufferAudioRenderer.class] &&
            [objectGetter(renderer, @"audioTimePitchAlgorithm") isEqual:AVAudioTimePitchAlgorithmSpectral];
        dispatch_async(dispatch_get_main_queue(), ^{
            id state = objectGetter(multiPlayer, @"playerContextState");
            if (generation != self.generation) return;
            if (!pitchReady || objectGetter(state, @"activePlayerContext") != incoming || !YTMUTransitionsRequested()) {
                YTMURecordTransitionEvent(@"tempo", @"pitch preservation unavailable; using crossfade");
                [self restorePitchAlgorithms]; return;
            }
            self.mixingPlayer = multiPlayer; self.incomingPlayer = player;
            __weak typeof(self) weakSelf = self;
            __block __weak YTMUNativeTempoSession *weakSession;
            YTMUNativeTempoSession *session = [[YTMUNativeTempoSession alloc] initWithPlayer:player queue:(dispatch_queue_t)queue
                renderer:renderer initialRate:plan.incomingRate duration:plan.duration completion:^{
                    typeof(self) strongSelf = weakSelf;
                    if (!strongSelf || strongSelf.tempoSession != weakSession) return;
                    strongSelf.tempoSession = nil; strongSelf.incomingPlayer = nil; strongSelf.mixingPlayer = nil;
                    [strongSelf restorePitchAlgorithms];
                }];
            weakSession = session; self.tempoSession = session;
            if (self.playbackPaused) [session pause];
            [session start];
        });
    });
}
- (void)tick:(NSTimer *)timer {
    if (![self updateArtworkProgress]) [self pauseMix];
}
- (void)pauseMix {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self pauseMix]; }); return; }
    [self.timer invalidate]; self.timer = nil;
}
- (void)resumeMix {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self resumeMix]; }); return; }
    if (self.playbackPaused || !self.artworkRunning || self.timer) return;
    self.timer = [NSTimer timerWithTimeInterval:1.0 / 20 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    self.timer.tolerance = 0.01;
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)nativePlaybackPaused {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self nativePlaybackPaused]; }); return;
    }
    self.playbackPaused = YES; [self.tempoSession pause]; [self pauseMix];
    if (YTMUTransitionsRequested()) YTMURecordTransitionEvent(@"transport", @"paused");
}
- (void)nativePlaybackResumed {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self nativePlaybackResumed]; }); return;
    }
    self.playbackPaused = NO; [self.tempoSession resume]; [self resumeMix];
    if (YTMUTransitionsRequested()) YTMURecordTransitionEvent(@"transport", @"playing");
}
- (void)nativeRateChanged:(float)rate player:(id)player {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self nativeRateChanged:rate player:player]; }); return;
    }
    /* Native activation re-applies 1x to every context. Keep an ongoing, verified
       incoming tempo adjustment when the user's playback speed has not changed. */
    if (player == self.mixingPlayer && self.incomingPlayer && fabsf(rate - 1) < 0.001)
        [self.tempoSession reapplyRate];
}
- (void)nativePlaybackSpeedWillChange {
    if (![NSThread isMainThread]) {
        [self.tempoSession cancelRestoringRate:NO];
        dispatch_async(dispatch_get_main_queue(), ^{ [self nativePlaybackSpeedWillChange]; }); return;
    }
    /* The user's native rate setter runs after the hook. Never enqueue a 1x
       restoration that would overwrite the newly selected playback speed. */
    [self.tempoSession cancelRestoringRate:NO]; self.tempoSession = nil;
    self.incomingPlayer = nil; [self cancel];
}
- (NSString *)diagnosticsSnapshot {
    id current = objectGetter(self.playerController, @"contentPlayerResponse");
    id nativeController = objectIvar(self.playerController, "_playbackController");
    return [NSString stringWithFormat:@"Sequencer: %@; player: %@; playback: %@; current response: %@\nNext song known: %@; repeat-one: %@; analysis queued: %lu; cache: %lu; tempo active: %@; paused: %@",
        [self.sequencer class], [self.playerController class], [nativeController class], [current class],
        objectGetter(self.sequencer, @"upcomingVideoID") ? @"yes" : @"no",
        boolGetter(self.sequencer, @"isLoopingOnSingleItemEnabled", YES) ? @"yes/unknown" : @"no",
        (unsigned long)self.analysisQueue.operationCount, (unsigned long)self.cacheKeys.count,
        self.tempoSession ? @"yes" : @"no", self.playbackPaused ? @"yes" : @"no"];
}
- (void)sequenceChanged {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self sequenceChanged]; }); return;
    }
    if (!self.pair) return;
    NSArray<NSString *> *identifiers = [self.pair componentsSeparatedByString:@"/"];
    NSString *current = videoID(objectGetter(self.playerController, @"contentPlayerResponse"));
    NSString *upcoming = objectGetter(self.sequencer, @"upcomingVideoID");
    if (identifiers.count != 2) { [self cancel]; return; }
    /* Queue extension and the native handoff also rebuild the sequence. They
       must not tear down the overlap they just started. Explicit skip/seek/reset
       paths still cancel, as does replacing the current/next song. */
    id state = objectGetter(self.nativeOverlapPlayer, @"playerContextState");
    if ([current isEqual:identifiers[1]] && (self.handoffInProgress || self.incomingPlayer || objectGetter(state, @"backgroundPlayerContext"))) return;
    if (![current isEqual:identifiers[0]] || ![upcoming isEqual:identifiers[1]]) [self cancel];
}
- (void)cancel {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self cancel]; }); return; }
    self.generation++; self.pair = nil;
    [self cancelArtwork];
    [self.analysisQueue cancelAllOperations]; [self pauseMix];
    [self.tempoSession cancel]; self.tempoSession = nil;
    self.incomingPlayer = nil; self.mixingPlayer = nil;
    self.plan = (YTMUMixPlan){YTMUMixBypass, 0, 1};
    id nativePlayer = self.nativeOverlapPlayer;
    self.handoffInProgress = NO;
    self.nativeOverlapPlayer = nil; /* Clear first: native completion can send sequencer callbacks. */
    id state = objectGetter(nativePlayer, @"playerContextState");
    if (objectGetter(state, @"backgroundPlayerContext")) {
        id fade = objectGetter(objectGetter(state, @"activePlayerContext"), @"audioFadeController");
        SEL clearEffects = NSSelectorFromString(@"setPendingTransitionEffects:");
        if (YTMUTransitionMethodMatches([fade class], clearEffects, "v", @[@"@"]))
            ((void (*)(id, SEL, id))objc_msgSend)(fade, clearEffects, @{});
        SEL clearBackground = NSSelectorFromString(@"clearBackgroundPlayer");
        if (YTMUTransitionMethodMatches([nativePlayer class], clearBackground, "v", @[]))
            ((void (*)(id, SEL))objc_msgSend)(nativePlayer, clearBackground);
    }
    [self restorePitchAlgorithms];
}
- (void)restorePitchAlgorithms {
    for (id renderer in self.renderers) {
        dispatch_queue_t queue = objc_getAssociatedObject(renderer, YTMUNativePitchQueueKey);
        NSNumber *generation = objc_getAssociatedObject(renderer, YTMUNativePitchGenerationKey);
        if (queue) dispatch_async(queue, ^{ YTMURestoreNativePitchForGeneration(renderer, generation); });
    }
    [self.renderers removeAllObjects];
}
- (void)registerArtworkController:(id)controller {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self registerArtworkController:controller]; }); return;
    }
    [self.artworkControllers addObject:controller];
}
- (BOOL)artworkIsVisible {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive ||
        !self.artworkThumbnail.window || boolGetter(self.artworkOverlay, @"shouldHideThumbnail", YES)) return NO;
    for (UIView *view = self.artworkThumbnail; view; view = view.superview)
        if (view.hidden || view.alpha < 0.01) return NO;
    return YES;
}
- (void)prepareArtworkForOutgoingContext:(id)context clip:(id)clip {
    [self cancelArtwork];
    if ([self.preferences[@"songTransitionMode"] integerValue] != YTMUTransitionAutoMix ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    NSArray<NSString *> *pair = [self.pair componentsSeparatedByString:@"/"];
    if (pair.count != 2) return;
    id player = objectGetter(context, @"player");
    SEL timeSelector = NSSelectorFromString(@"currentTime");
    if (!YTMUTransitionMethodMatches([player class], timeSelector, "{?=ddd}", @[])) return;
    YTMUNativePlayerTime time = ((YTMUNativePlayerTime (*)(id, SEL))objc_msgSend)(player, timeSelector);
    if (!isfinite(time.mediaTime)) return;
    double end = doubleGetter(clip, @"startTime", NAN) + doubleGetter(clip, @"duration", NAN);
    double duration = end - time.mediaTime;
    if (!isfinite(duration) || duration <= 0 || duration > 12.25) duration = [self crossfadeDuration];
    if (!isfinite(duration) || duration <= 0 || duration > 12.25) return;
    for (id controller in self.artworkControllers) {
        if (![objectGetter(controller, @"currentVideoID") isEqual:pair[0]]) continue;
        UIView *overlay = objectGetter(controller, @"overlayView");
        UIView *thumbnail = objectGetter(overlay, @"thumbnailView");
        if (![overlay isKindOfClass:UIView.class] || ![thumbnail isKindOfClass:UIView.class]) continue;
        self.artworkOverlay = overlay; self.artworkThumbnail = thumbnail;
        if (![self artworkIsVisible]) continue;
        UIImage *image = objectGetter(thumbnail, @"image");
        UIImageView *nativeImage = objectGetter(thumbnail, @"imageView");
        if (![image isKindOfClass:UIImage.class] || ![nativeImage isKindOfClass:UIImageView.class] ||
            nativeImage.superview != thumbnail || CGRectIsEmpty(nativeImage.bounds)) continue;
        self.artworkController = controller; self.artworkClockPlayer = player;
        self.artworkIncomingID = pair[1]; self.artworkStartTime = time.mediaTime; self.artworkDuration = duration;
        UIImageView *cover = [[UIImageView alloc] initWithImage:image];
        cover.frame = nativeImage.frame; cover.contentMode = nativeImage.contentMode;
        cover.clipsToBounds = nativeImage.clipsToBounds; cover.layer.cornerRadius = nativeImage.layer.cornerRadius;
        cover.userInteractionEnabled = NO; cover.accessibilityElementsHidden = YES;
        cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.outgoingArtwork = cover; [thumbnail addSubview:cover];
        return;
    }
    [self cancelArtwork];
}
- (void)artworkResponseChanged:(id)response controller:(id)controller {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self artworkResponseChanged:response controller:controller]; }); return;
    }
    if (!self.outgoingArtwork || controller != self.artworkController) return;
    if (![videoID(response) isEqual:self.artworkIncomingID]) { [self cancelArtwork]; return; }
    self.artworkIncomingAssigned = YES;
    /* A cached native request can finish synchronously inside the response setter. */
    UIImage *image = objectGetter(self.artworkThumbnail, @"image");
    if (image && image != self.outgoingArtwork.image) [self artworkImageChanged:self.artworkThumbnail];
}
- (BOOL)shouldAnimateNativeArtworkImage:(id)view {
    return ![NSThread isMainThread] || !self.outgoingArtwork || view != self.artworkThumbnail;
}
- (void)artworkImageChanged:(id)view {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self artworkImageChanged:view]; }); return;
    }
    if (!self.outgoingArtwork || view != self.artworkThumbnail ||
        (!self.artworkIncomingAssigned && ![objectGetter(self.artworkController, @"currentVideoID") isEqual:self.artworkIncomingID])) return;
    if (![objectGetter(view, @"image") isKindOfClass:UIImage.class]) return;
    if (!self.artworkIncomingLoaded) self.artworkRevealStart = self.artworkProgress;
    self.artworkIncomingLoaded = YES;
    [self.artworkThumbnail bringSubviewToFront:self.outgoingArtwork];
}
- (void)artworkLayoutChanged:(id)view {
    if (![NSThread isMainThread] || view != self.artworkOverlay || !self.outgoingArtwork) return;
    if (![self artworkIsVisible]) { [self cancelArtwork]; return; }
    UIImageView *image = objectGetter(self.artworkThumbnail, @"imageView");
    if (![image isKindOfClass:UIImageView.class] || image.superview != self.artworkThumbnail) { [self cancelArtwork]; return; }
    self.outgoingArtwork.frame = image.frame; self.outgoingArtwork.contentMode = image.contentMode;
    self.outgoingArtwork.layer.cornerRadius = image.layer.cornerRadius;
    [self.artworkThumbnail bringSubviewToFront:self.outgoingArtwork];
}
- (BOOL)updateArtworkProgress {
    if (!self.outgoingArtwork || !self.artworkRunning) return NO;
    id state = objectGetter(self.nativeOverlapPlayer, @"playerContextState");
    if (![self artworkIsVisible] || !YTMUTransitionsRequested() ||
        !objectGetter(state, @"backgroundPlayerContext") || !self.artworkClockPlayer) { [self cancelArtwork]; return NO; }
    YTMUNativePlayerTime time = ((YTMUNativePlayerTime (*)(id, SEL))objc_msgSend)(self.artworkClockPlayer, NSSelectorFromString(@"currentTime"));
    double elapsed = time.mediaTime - self.artworkStartTime;
    if (!isfinite(elapsed) || elapsed < -0.1) { [self cancelArtwork]; return NO; }
    self.artworkProgress = fmin(1, fmax(self.artworkProgress, elapsed / self.artworkDuration));
    if (self.artworkProgress >= 1) { [self cancelArtwork]; return NO; }
    /* Wait for real incoming art. A late image fades over the remaining overlap
       instead of exposing the loader's placeholder or using a wall-clock delay. */
    if (self.artworkIncomingLoaded)
        self.outgoingArtwork.alpha = (1 - self.artworkProgress) / MAX(0.001, 1 - self.artworkRevealStart);
    return YES;
}
- (void)cancelArtworkForOverlay:(id)view {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self cancelArtworkForOverlay:view]; }); return;
    }
    if (view == self.artworkOverlay) [self cancelArtwork];
}
- (void)artworkEnvironmentChanged:(NSNotification *)notification {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self artworkEnvironmentChanged:notification]; }); return;
    }
    [self cancelArtwork];
    YTMURecordTransitionEvent(@"app-state", @"inactive; artwork stopped; native audio retained");
}
- (void)cancelArtwork {
    [self.outgoingArtwork removeFromSuperview]; self.outgoingArtwork = nil;
    self.artworkController = nil; self.artworkOverlay = nil; self.artworkThumbnail = nil;
    self.artworkClockPlayer = nil; self.artworkIncomingID = nil; self.artworkRunning = NO;
    self.artworkIncomingAssigned = NO; self.artworkIncomingLoaded = NO;
    self.artworkProgress = 0; self.artworkRevealStart = 0;
    [self pauseMix];
}
@end

static const void *YTMUPlayerControlsRowKey = &YTMUPlayerControlsRowKey;
static const void *YTMUPlayerControlOffsetKey = &YTMUPlayerControlOffsetKey;

BOOL YTMUTransitionControlsVisible(UIView *controls) {
    return controls && YTMUTransitionsCrossfadeSupported() &&
        [YTMUTransitionPreferences()[@"YTMUltimateIsEnabled"] boolValue] && integerGetter(controls, @"style", -1) == 0;
}

void YTMURestoreTransitionControlFrames(UIView *controls) {
    for (UIView *view in controls.subviews) {
        NSNumber *offset = objc_getAssociatedObject(view, YTMUPlayerControlOffsetKey);
        if (!offset) continue;
        CGRect frame = view.frame; frame.origin.y += offset.doubleValue; view.frame = frame;
        objc_setAssociatedObject(view, YTMUPlayerControlOffsetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

void YTMULayoutTransitionControls(UIView *controls) {
    UIView *row = objc_getAssociatedObject(controls, YTMUPlayerControlsRowKey);
    if (!YTMUTransitionControlsVisible(controls) || controls.bounds.size.height < 100 || controls.bounds.size.width < 160) {
        row.hidden = YES; return;
    }
    if (!row) {
        row = [UIView new];
        for (NSInteger mode = 0; mode < 2; mode++) {
            YTMUPlayerTransitionButton *button = [[YTMUPlayerTransitionButton alloc] initWithFrame:CGRectZero];
            button.mode = mode; [row addSubview:button];
        }
        [controls addSubview:row];
        objc_setAssociatedObject(controls, YTMUPlayerControlsRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    row.hidden = NO;
    /* Native controls are centered in the expanded bounds. Restore their original
       row, leaving 44 points for the two toggles. Undo before each native layout. */
    for (UIView *view in controls.subviews) {
        if (![view isKindOfClass:UIControl.class]) continue;
        CGRect frame = view.frame; frame.origin.y -= 22; view.frame = frame;
        objc_setAssociatedObject(view, YTMUPlayerControlOffsetKey, @22, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGFloat width = controls.bounds.size.width;
    row.frame = CGRectMake(0, controls.bounds.size.height - 44, width, 44);
    CGFloat buttonWidth = MIN(120, (width - 16) / 2);
    for (YTMUPlayerTransitionButton *button in row.subviews) {
        UIButton *native = objectGetter(controls, button.mode == YTMUTransitionAutoMix ? @"shuffleButton" : @"loopButton");
        button.nativeButton = [native isKindOfClass:UIButton.class] ? native : nil;
        CGFloat center = native ? native.center.x : width * (button.mode == 0 ? 0.25 : 0.75);
        CGFloat x = MAX(0, MIN(width - buttonWidth, center - buttonWidth / 2));
        button.frame = CGRectMake(x, 0, buttonWidth, 44);
        [button refresh];
    }
}

@implementation YTMUPlayerTransitionButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        self.titleLabel.adjustsFontSizeToFitWidth = YES;
        self.titleLabel.minimumScaleFactor = 0.8;
        self.contentEdgeInsets = UIEdgeInsetsMake(0, 4, 4, 4);
        self.imageEdgeInsets = UIEdgeInsetsMake(0, -3, 0, 3);
        self.backgroundColor = UIColor.clearColor;
        [self addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh)
                                                     name:YTMUTransitionsChangedNotification object:nil];
    }
    return self;
}
- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)didMoveToWindow { [super didMoveToWindow]; [self refresh]; }
- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous]; [self refresh];
}
- (void)refresh {
    NSDictionary *preferences = YTMUTransitionPreferences();
    self.enabled = [preferences[@"YTMUltimateIsEnabled"] boolValue] && YTMUTransitionsCrossfadeSupported() &&
        (self.mode == YTMUTransitionCrossfade || YTMUTransitionsAutoMixSupported());
    self.selected = [preferences[@"songTransitionsEnabled"] boolValue] &&
        [preferences[@"songTransitionMode"] integerValue] == self.mode;
    NSString *title = self.mode == YTMUTransitionAutoMix ? LOC(@"AUTOMIX") : LOC(@"CROSSFADE");
    [self setTitle:title forState:UIControlStateNormal];
    UIImageSymbolConfiguration *symbols = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightRegular];
    [self setImage:[UIImage systemImageNamed:self.mode == YTMUTransitionAutoMix ? @"waveform" : @"arrow.left.arrow.right"
                         withConfiguration:symbols] forState:UIControlStateNormal];
    UIColor *nativeColor = objectGetter(UIColor.class, @"ytm_selectedButtonColor");
    if (![nativeColor isKindOfClass:UIColor.class]) nativeColor = self.nativeButton.tintColor ?: UIColor.labelColor;
    UIColor *color = self.selected ? nativeColor : [nativeColor colorWithAlphaComponent:0.6];
    self.tintColor = color; [self setTitleColor:color forState:UIControlStateNormal];
    self.alpha = self.enabled ? 1 : 0.35;
    self.accessibilityLabel = title;
    self.accessibilityValue = self.selected ? LOC(@"TRANSITIONS_ON") : LOC(@"TRANSITIONS_OFF");
    self.accessibilityHint = self.enabled ? nil : YTMUTransitionsAvailability();
    self.accessibilityTraits = UIAccessibilityTraitButton | (self.selected ? UIAccessibilityTraitSelected : 0) |
        (self.enabled ? 0 : UIAccessibilityTraitNotEnabled);
    [self setNeedsDisplay];
}
- (void)drawRect:(CGRect)rect {
    [super drawRect:rect];
    if (self.selected) {
        [self.tintColor setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(CGRectGetMidX(self.bounds) - 2, self.bounds.size.height - 7, 4, 4)] fill];
    }
}
- (void)toggle {
    if (!self.enabled) return;
    NSDictionary *current = YTMUTransitionPreferences();
    BOOL active = [current[@"songTransitionsEnabled"] boolValue] && [current[@"songTransitionMode"] integerValue] == self.mode;
    NSMutableDictionary *preferences = [[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"] mutableCopy] ?: [NSMutableDictionary dictionary];
    preferences[@"songTransitionsEnabled"] = @(!active);
    preferences[@"songTransitionMode"] = @(self.mode);
    /* Store both values together: one tap, one preference notification/rebuild. */
    [[NSUserDefaults standardUserDefaults] setObject:preferences forKey:@"YTMUltimate"];
    [[NSNotificationCenter defaultCenter] postNotificationName:NSUserDefaultsDidChangeNotification object:NSUserDefaults.standardUserDefaults];
}
@end
