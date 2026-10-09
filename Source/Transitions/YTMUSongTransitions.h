#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, YTMUTransitionMode) { YTMUTransitionAutoMix = 0, YTMUTransitionCrossfade = 1 };
FOUNDATION_EXPORT NSString *const YTMUTransitionsChangedNotification;
BOOL YTMUTransitionMethodMatches(Class cls, SEL selector, const char *result, NSArray<NSString *> *arguments);
BOOL YTMUTransitionsCrossfadeSupported(void);
BOOL YTMUTransitionsAutoMixSupported(void);
NSDictionary *YTMUTransitionPreferences(void);
void YTMUSetTransitionPreference(NSString *key, id value);
BOOL YTMUTransitionsRequested(void);
BOOL YTMUTransitionsAllowContentPair(id current, id upcoming);
BOOL YTMUTransitionsCanReuseNativeQueue(id playerData);
void YTMUPrepareUpcomingTransitionPlayback(id playback);
void YTMURefreshNativePrefetchBinding(id manager);
BOOL YTMUNativeTransitionPrefetchAllowed(id controller, BOOL nativeAllowed);
BOOL YTMUOwnsNativePrefetchBinding(id controller);
void YTMURecordNativeTransitionItem(id item, id videoController);
void YTMURecordTransitionEvent(NSString *event, NSString *detail);
NSString *YTMUTransitionDiagnosticsReport(void);
NSString *YTMUTransitionsAvailability(void);
BOOL YTMUTransitionControlsVisible(UIView *controls);
void YTMULayoutTransitionControls(UIView *controls);
void YTMURestoreTransitionControlFrames(UIView *controls);

@interface YTMUSongTransitionCoordinator : NSObject
+ (instancetype)shared;
- (void)bindSequencer:(id)sequencer playerController:(id)controller;
- (void)observeCurrentResponse:(id)current upcomingResponse:(id)upcoming;
- (void)observeUpcomingPlaybackData:(id)data;
- (void)prepareIncomingContext:(id)context;
- (BOOL)allowsTransitionsForPlaybackController:(id)controller current:(id)current upcoming:(id)upcoming;
- (double)crossfadeDuration;
- (double)crossfadeDurationForSequencer:(id)sequencer;
- (void)nativeFadeWillStart:(id)multiPlayer outgoingContext:(id)outgoing activeClip:(id)clip;
- (void)nativeFadeStarted:(id)multiPlayer outgoingContext:(id)outgoing incomingContext:(id)incoming;
- (void)pauseMix;
- (void)resumeMix;
- (void)nativePlaybackPaused;
- (void)nativePlaybackResumed;
- (void)sequenceChanged;
- (void)nativeRateChanged:(float)rate player:(id)player;
- (void)nativePlaybackSpeedWillChange;
- (NSString *)diagnosticsSnapshot;
- (void)registerArtworkController:(id)controller;
- (void)artworkResponseChanged:(id)response controller:(id)controller;
- (BOOL)shouldAnimateNativeArtworkImage:(id)view;
- (void)artworkImageChanged:(id)view;
- (void)artworkLayoutChanged:(id)view;
- (void)cancelArtworkForOverlay:(id)view;
- (void)cancel;
@end

@interface YTMUPlayerTransitionButton : UIButton
@property (nonatomic) YTMUTransitionMode mode;
@property (nonatomic, weak) UIButton *nativeButton;
- (void)refresh;
@end
