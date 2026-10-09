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
NSString *YTMUTransitionsAvailability(void);

@interface YTMUSongTransitionCoordinator : NSObject
+ (instancetype)shared;
- (void)bindSequencer:(id)sequencer playerController:(id)controller;
- (void)observeCurrentResponse:(id)current upcomingResponse:(id)upcoming;
- (void)observeUpcomingPlaybackData:(id)data;
- (void)prepareIncomingContext:(id)context;
- (BOOL)allowsTransitionsForPlaybackController:(id)controller current:(id)current upcoming:(id)upcoming;
- (double)crossfadeDuration;
- (void)nativeFadeStarted:(id)multiPlayer outgoingContext:(id)outgoing incomingContext:(id)incoming;
- (void)pauseMix;
- (void)resumeMix;
- (void)cancel;
@end

@interface YTMUQueueTransitionButton : UIButton
@property (nonatomic, weak) id queueController;
@end
