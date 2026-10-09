#ifndef YTMU_MIX_ANALYSIS_H
#define YTMU_MIX_ANALYSIS_H

#include <stddef.h>

#define YTMU_ANALYSIS_RATE 22050
#define YTMU_ANALYSIS_SECONDS 12
#define YTMU_MAX_BEATS 64

typedef struct {
    double duration;
    double tempo;
    double confidence;
    double rms;
    int key; /* 0..11 major, 12..23 minor; -1 when uncertain. */
    double keyConfidence;
    size_t beatCount;
    double beats[YTMU_MAX_BEATS]; /* Seconds relative to the window. */
} YTMUMixAnalysis;

typedef enum { YTMUMixBypass, YTMUMixCrossfade, YTMUMixAutoMix } YTMUMixKind;
typedef struct {
    YTMUMixKind kind;
    double duration;
    double incomingRate;
} YTMUMixPlan;

typedef struct {
    double duration;
    int musicVideoType; /* 9.40.2 protobuf values; audio tracks: 1, 6, 9. */
    int crossfadeBehavior; /* Server experiment: 0 unassigned, 1 off, 2 on. */
    int live, podcast;
    const char *album;
    int hasTrackNumber, trackNumber;
} YTMUMixContent;

int YTMUAllowsMixContentPair(const YTMUMixContent *outgoing, const YTMUMixContent *incoming);
const char *YTMUMixContentExclusion(const YTMUMixContent *outgoing, const YTMUMixContent *incoming);

/* Accepts at most twelve seconds of finite mono PCM at 22050 Hz. */
int YTMUAnalysePCM(const float *pcm, size_t count, YTMUMixAnalysis *result);
/* Keeps the incoming intro intact; aligns its first beat with the outgoing grid. */
YTMUMixPlan YTMUPlanMix(const YTMUMixAnalysis *outro, const YTMUMixAnalysis *intro,
                      double outgoingDuration, double incomingDuration,
                      double crossfadeDuration, int pitchPreserving, int sequentialAlbum);
double YTMUMixRateAtProgress(double initialRate, double progress);
/* Additional native prefetch lead is bounded; never shorten a native window. */
double YTMUMixPrefetchWindow(double nativeWindow, double crossfadeDuration, int autoMix, int enabled);

#endif
