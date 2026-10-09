#import "YTMUSongTransitions.h"
#import "YTMUAudioWindowDecoder.h"
#import "../Headers/Localization.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <math.h>

NSString *const YTMUTransitionsChangedNotification = @"YTMUTransitionsChanged";
static const void *YTMUOriginalPitchKey = &YTMUOriginalPitchKey;

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

static double responseDuration(id response) {
    id data = objectGetter(response, @"playerData");
    id details = objectGetter(data, @"videoDetails");
    SEL selector = NSSelectorFromString(@"lengthSeconds");
    if (![details respondsToSelector:selector]) return 0;
    NSMethodSignature *signature = [details methodSignatureForSelector:selector];
    const char *type = unqualified(signature.methodReturnType);
    if (signature.numberOfArguments != 2) return 0;
    if (!strcmp(type, "q")) return ((int64_t (*)(id, SEL))objc_msgSend)(details, selector);
    if (!strcmp(type, "Q")) return ((uint64_t (*)(id, SEL))objc_msgSend)(details, selector);
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
    id data = objectGetter(response, @"playerData");
    id details = objectGetter(data, @"videoDetails");
    id config = objectGetter(objectGetter(objectGetter(data, @"playerConfig"), @"audioConfig"), @"crossfadeConfig");
    id metadata = objectGetter(data, @"trackAlbumMetadata");
    NSString *album = objectGetter(metadata, @"externalPlaylistId");
    /* Values are verified from 9.40.2's protobuf enum descriptors. Unknown
       crossfade policy is an unassigned experiment, not a content veto. */
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
    if (!YTMUTransitionsRequested() || !current || !upcoming ||
        !videoID(current).length || !videoID(upcoming).length || [videoID(current) isEqual:videoID(upcoming)]) return NO;
    YTMUMixContent outgoing = responseContent(current), incoming = responseContent(upcoming);
    return YTMUAllowsMixContentPair(&outgoing, &incoming);
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
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) double mixStart;
@property (nonatomic) double mixDuration;
@property (nonatomic) double initialRate;
@property (nonatomic) double appliedIncomingRate;
@property (nonatomic) BOOL applyingRate;
@property (nonatomic) double previousMixTime;
@property (nonatomic) NSUInteger stalledTicks;
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
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(preferencesChanged:)
                                                     name:NSUserDefaultsDidChangeNotification object:nil];
        for (NSString *name in @[AVAudioSessionRouteChangeNotification, AVAudioSessionInterruptionNotification,
                                 AVAudioSessionMediaServicesWereResetNotification, NSProcessInfoPowerStateDidChangeNotification])
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(environmentChanged:) name:name object:nil];
    }
    return self;
}
- (void)bindSequencer:(id)sequencer playerController:(id)controller {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self bindSequencer:sequencer playerController:controller]; }); return;
    }
    self.sequencer = sequencer; self.playerController = controller;
}
- (void)preferencesChanged:(NSNotification *)notification {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self preferencesChanged:notification]; }); return; }
    NSDictionary *preferences = YTMUTransitionPreferences();
    if ([preferences isEqualToDictionary:self.preferences]) return;
    self.preferences = preferences;
    [self cancel];
    [[NSNotificationCenter defaultCenter] postNotificationName:YTMUTransitionsChangedNotification object:nil];
    [self updateSequence];
    SEL refresh = NSSelectorFromString(@"scheduleSetSequenceForQueueModification");
    if (YTMUTransitionMethodMatches([self.sequencer class], refresh, "v", @[]))
        ((void (*)(id, SEL))objc_msgSend)(self.sequencer, refresh);
}
- (void)environmentChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{ [self cancel]; [self updateSequence]; });
}
- (void)updateSequence {
    SEL selector = NSSelectorFromString(@"updateCrossfadeTransitionInActiveSequence");
    if (YTMUTransitionMethodMatches([self.sequencer class], selector, "v", @[]))
        ((void (*)(id, SEL))objc_msgSend)(self.sequencer, selector);
}
- (BOOL)allowsTransitionsForPlaybackController:(id)controller current:(id)current upcoming:(id)upcoming {
    if (!YTMUTransitionsAllowContentPair(current, upcoming)) return NO;
    id status = objectGetter(controller, @"playerStatus");
    if (!status || boolGetter(status, @"externalPlayback", YES) ||
        boolGetter(status, @"pictureInPicture", NO) ||
        boolGetter(self.sequencer, @"isLoopingOnSingleItemEnabled", YES)) return NO;
    return YES;
}
- (double)crossfadeDuration {
    if (boolGetter(self.sequencer, @"isLoopingOnSingleItemEnabled", YES)) return 0;
    NSString *currentID = videoID(objectGetter(self.playerController, @"playerResponse"));
    NSString *nextID = objectGetter(self.sequencer, @"upcomingVideoID");
    NSString *pair = currentID && nextID ? [NSString stringWithFormat:@"%@/%@", currentID, nextID] : nil;
    if ([self.preferences[@"songTransitionMode"] integerValue] == YTMUTransitionAutoMix && self.plan.kind != YTMUMixBypass && [pair isEqualToString:self.pair])
        return self.plan.duration;
    double duration = [self.preferences[@"crossfadeDuration"] doubleValue];
    double currentDuration = responseDuration(objectGetter(self.playerController, @"playerResponse"));
    return currentDuration > 0 ? MIN(duration, currentDuration / 2) : duration;
}
- (void)observeCurrentResponse:(id)current upcomingResponse:(id)upcoming {
    if (![NSThread isMainThread] || !YTMUTransitionsRequested() || self.incomingPlayer || self.handoffInProgress) return;
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
    if ([self.preferences[@"songTransitionMode"] integerValue] != YTMUTransitionAutoMix) return;
    NSString *tailKey = [NSString stringWithFormat:@"%@/tail/%.3f", currentID, outgoingDuration];
    NSString *headKey = [NSString stringWithFormat:@"%@/head/%.3f", nextID, incomingDuration];
    NSData *cachedTail = [self.cache objectForKey:tailKey], *cachedHead = [self.cache objectForKey:headKey];
    if (NSProcessInfo.processInfo.lowPowerModeEnabled && (!cachedTail || !cachedHead)) return;
    NSURL *tailURL = audioURL(current), *headURL = audioURL(upcoming);
    if ((!cachedTail && !tailURL) || (!cachedHead && !headURL)) return;
    NSUInteger generation = self.generation;
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
                /* Rebuilding a transition after overlap begins would change its end point. */
                if (!strongSelf.incomingPlayer) [strongSelf updateSequence];
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
    id current = objectGetter(self.playerController, @"playerResponse");
    id upcoming = objectGetter(data, @"playerResponse");
    id controller = objectIvar(self.playerController, "_playbackController");
    Class policy = NSClassFromString(@"YTMCrossfadeTransitionPolicy");
    SEL selector = NSSelectorFromString(@"isCrossfadeTransitionEnabledForCurrentPlayerResponse:upcomingPlayerResponse:");
    if (![self allowsTransitionsForPlaybackController:controller current:current upcoming:upcoming] ||
        !YTMUTransitionMethodMatches(object_getClass(policy), selector, "B", @[@"@", @"@"])) return;
    if (((BOOL (*)(id, SEL, id, id))objc_msgSend)(policy, selector, current, upcoming))
        [self observeCurrentResponse:current upcomingResponse:upcoming];
}
- (void)prepareIncomingContext:(id)context {
    if (![NSThread isMainThread] || self.plan.kind != YTMUMixAutoMix || !YTMUTransitionsRequested()) return;
    id player = objectGetter(context, @"player");
    id queue = objectGetter(player, @"playerQueue");
    if (!queue) return;
    NSUInteger generation = self.generation;
    /* Enqueue before native play, on the player's own queue. Existing renderers are covered too. */
    dispatch_async((dispatch_queue_t)queue, ^{
        if (generation == self.generation)
            [self prepareAudioRenderer:objectIvar(player, "_audioTrackRenderer") generation:generation];
    });
}
- (void)prepareAudioRenderer:(id)trackRenderer generation:(NSUInteger)generation {
    if (!YTMUTransitionsRequested() || !YTMUTransitionsAutoMixSupported() ||
        [YTMUTransitionPreferences()[@"songTransitionMode"] integerValue] != YTMUTransitionAutoMix) return;
    id renderer = objectGetter(trackRenderer, @"underlyingRenderer");
    if (![renderer isKindOfClass:AVSampleBufferAudioRenderer.class]) return;
    SEL setter = NSSelectorFromString(@"setAudioTimePitchAlgorithm:");
    NSString *original = objectGetter(renderer, @"audioTimePitchAlgorithm");
    if (!original) return;
    if (!objc_getAssociatedObject(renderer, YTMUOriginalPitchKey)) objc_setAssociatedObject(renderer, YTMUOriginalPitchKey, original, OBJC_ASSOCIATION_COPY_NONATOMIC);
    ((void (*)(id, SEL, id))objc_msgSend)(renderer, setter, AVAudioTimePitchAlgorithmSpectral);
    if (![objectGetter(renderer, @"audioTimePitchAlgorithm") isEqual:AVAudioTimePitchAlgorithmSpectral]) {
        ((void (*)(id, SEL, id))objc_msgSend)(renderer, setter, original);
        objc_setAssociatedObject(renderer, YTMUOriginalPitchKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation == self.generation && YTMUTransitionsRequested()) [self.renderers addObject:renderer];
        else {
            NSString *saved = objc_getAssociatedObject(renderer, YTMUOriginalPitchKey);
            if (saved) ((void (*)(id, SEL, id))objc_msgSend)(renderer, setter, saved);
            objc_setAssociatedObject(renderer, YTMUOriginalPitchKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
    });
}
- (void)nativeFadeWillStart:(id)multiPlayer {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self nativeFadeWillStart:multiPlayer]; }); return;
    }
    if (!YTMUTransitionsRequested()) return;
    self.handoffInProgress = YES; self.nativeOverlapPlayer = multiPlayer;
}
- (void)nativeFadeStarted:(id)multiPlayer outgoingContext:(id)outgoing incomingContext:(id)incoming {
    if (![NSThread isMainThread] || !YTMUTransitionsRequested()) return;
    self.handoffInProgress = NO;
    id nativeState = objectGetter(multiPlayer, @"playerContextState");
    if (objectGetter(nativeState, @"activePlayerContext") != incoming || !objectGetter(nativeState, @"backgroundPlayerContext")) return;
    self.nativeOverlapPlayer = multiPlayer;
    if (self.plan.kind != YTMUMixAutoMix ||
        [self.preferences[@"songTransitionMode"] integerValue] != YTMUTransitionAutoMix) return;
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
        id renderer = objectGetter(objectIvar(player, "_audioTrackRenderer"), @"underlyingRenderer");
        /* No speed adjustment unless the actual incoming renderer confirms pitch preservation. */
        BOOL pitchReady = [renderer isKindOfClass:AVSampleBufferAudioRenderer.class] &&
            [objectGetter(renderer, @"audioTimePitchAlgorithm") isEqual:AVAudioTimePitchAlgorithmSpectral];
        dispatch_async(dispatch_get_main_queue(), ^{
            id state = objectGetter(multiPlayer, @"playerContextState");
            if (generation != self.generation) return;
            if (!pitchReady || objectGetter(state, @"activePlayerContext") != incoming || !YTMUTransitionsRequested()) {
                [self restorePitchAlgorithms]; return;
            }
            YTMUNativePlayerTime time = ((YTMUNativePlayerTime (*)(id, SEL))objc_msgSend)(player, NSSelectorFromString(@"currentTime"));
            if (!isfinite(time.mediaTime) || time.mediaTime > 0.15) { [self restorePitchAlgorithms]; return; }
            self.mixingPlayer = multiPlayer; self.incomingPlayer = player;
            self.initialRate = plan.incomingRate; self.mixDuration = plan.duration * plan.incomingRate; self.mixStart = time.mediaTime;
            self.previousMixTime = time.mediaTime; self.stalledTicks = 0;
            [self setIncomingRate:plan.incomingRate]; [self resumeMix];
        });
    });
}
- (void)setIncomingRate:(double)rate {
    if (!self.incomingPlayer) return;
    self.appliedIncomingRate = rate;
    self.applyingRate = YES;
    ((void (*)(id, SEL, float))objc_msgSend)(self.incomingPlayer, NSSelectorFromString(@"setRate:"), (float)rate);
    self.applyingRate = NO;
}
- (void)tick:(NSTimer *)timer {
    id player = self.incomingPlayer;
    if (!player) { [self pauseMix]; return; }
    YTMUNativePlayerTime time = ((YTMUNativePlayerTime (*)(id, SEL))objc_msgSend)(player, NSSelectorFromString(@"currentTime"));
    double elapsed = time.mediaTime - self.mixStart;
    if (!isfinite(elapsed) || elapsed < -0.1 || !YTMUTransitionsRequested()) { [self cancel]; return; }
    self.stalledTicks = fabs(time.mediaTime - self.previousMixTime) < 0.001 ? self.stalledTicks + 1 : 0;
    self.previousMixTime = time.mediaTime;
    if (self.stalledTicks > 100) { [self cancel]; return; }
    if (elapsed < self.mixDuration) return;
    double progress = (elapsed - self.mixDuration) / 2;
    [self setIncomingRate:YTMUMixRateAtProgress(self.initialRate, progress)];
    if (progress >= 1) {
        self.incomingPlayer = nil; self.mixingPlayer = nil; [self pauseMix];
        [self restorePitchAlgorithms];
    }
}
- (void)pauseMix {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self pauseMix]; }); return; }
    [self.timer invalidate]; self.timer = nil;
}
- (void)resumeMix {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self resumeMix]; }); return; }
    if (!self.incomingPlayer || self.timer) return;
    self.timer = [NSTimer timerWithTimeInterval:1.0 / 20 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    self.timer.tolerance = 0.01;
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}
- (void)nativeRateChanged:(float)rate player:(id)player {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self nativeRateChanged:rate player:player]; }); return;
    }
    /* Native activation re-applies 1x to every context. Keep an ongoing, verified
       incoming tempo adjustment when the user's playback speed has not changed. */
    if (player == self.mixingPlayer && self.incomingPlayer && fabsf(rate - 1) < 0.001)
        [self setIncomingRate:self.appliedIncomingRate];
}
- (void)sequenceChanged {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self sequenceChanged]; }); return;
    }
    if (!self.pair) return;
    NSArray<NSString *> *identifiers = [self.pair componentsSeparatedByString:@"/"];
    NSString *current = videoID(objectGetter(self.playerController, @"playerResponse"));
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
    [self.analysisQueue cancelAllOperations]; [self pauseMix]; [self setIncomingRate:1];
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
        NSString *original = objc_getAssociatedObject(renderer, YTMUOriginalPitchKey);
        if (original) ((void (*)(id, SEL, id))objc_msgSend)(renderer, NSSelectorFromString(@"setAudioTimePitchAlgorithm:"), original);
        objc_setAssociatedObject(renderer, YTMUOriginalPitchKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    [self.renderers removeAllObjects];
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
