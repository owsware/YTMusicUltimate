#import <Foundation/Foundation.h>
#import "YTMUMixAnalysis.h"

/* Worker-thread only. Each window has an eight-second / six-MiB network budget. */
BOOL YTMUDecodeAudioWindow(NSURL *url, double start, double duration,
                          NSOperation *operation, YTMUMixAnalysis *analysis);
