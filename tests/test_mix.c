#include "../Source/Transitions/YTMUMixAnalysis.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PI 3.14159265358979323846
#define SAMPLES (YTMU_ANALYSIS_RATE * YTMU_ANALYSIS_SECONDS)

static void rhythm(float *pcm, double bpm, double phase) {
    for (int i = 0; i < SAMPLES; ++i) {
        double t = (double)i / YTMU_ANALYSIS_RATE;
        double beat = fmod(t + phase, 60 / bpm);
        pcm[i] = (float)(0.7 * exp(-beat * 60) * sin(2 * PI * 170 * t));
    }
}
static void chord(float *pcm, double root, double third, double fifth) {
    for (int i = 0; i < SAMPLES; ++i) {
        double t = (double)i / YTMU_ANALYSIS_RATE;
        pcm[i] = (float)(0.1 * (sin(2 * PI * root * t) + sin(2 * PI * third * t) + sin(2 * PI * fifth * t)));
    }
}

static void test_content_policy(void) {
    YTMUMixContent song = {.duration = 180, .musicVideoType = 1, .crossfadeBehavior = 0};
    YTMUMixContent next = song;
    /* Manual transitions work across all known experiment assignments, while
       content exclusions remain independent of account/server experiments. */
    assert(YTMUAllowsMixContentPair(&song, &next));
    next.crossfadeBehavior = 2;
    assert(YTMUAllowsMixContentPair(&song, &next));
    next.crossfadeBehavior = 1;
    assert(YTMUAllowsMixContentPair(&song, &next));
    next.crossfadeBehavior = -1;
    assert(!YTMUAllowsMixContentPair(&song, &next));
    next = song;
    for (int type = 0; type <= 9; ++type) {
        next.musicVideoType = type;
        assert(YTMUAllowsMixContentPair(&song, &next) == (type == 1 || type == 6 || type == 9));
    }
    next = song; next.live = 1;
    assert(!YTMUAllowsMixContentPair(&song, &next));
    assert(!strcmp(YTMUMixContentExclusion(&song, &next), "live-stream"));
    next = song; next.podcast = 1;
    assert(!YTMUAllowsMixContentPair(&song, &next));
    next = song; next.duration = 2;
    assert(!YTMUAllowsMixContentPair(&song, &next));
    next.duration = NAN;
    assert(!YTMUAllowsMixContentPair(&song, &next));
    next = song;
    song.album = next.album = "album";
    song.hasTrackNumber = next.hasTrackNumber = 1;
    song.trackNumber = 3; next.trackNumber = 4;
    assert(!YTMUAllowsMixContentPair(&song, &next));
    next.trackNumber = 5;
    assert(YTMUAllowsMixContentPair(&song, &next));
    next.trackNumber = 4; next.album = "other album";
    assert(YTMUAllowsMixContentPair(&song, &next));
    next.album = "album"; next.hasTrackNumber = 0;
    assert(YTMUAllowsMixContentPair(&song, &next));
    assert(!YTMUAllowsMixContentPair(NULL, &next));
    assert(!strcmp(YTMUMixContentExclusion(NULL, &next), "missing-content"));
}

int main(void) {
    test_content_policy();
    float *pcm = calloc(SAMPLES, sizeof(float)); assert(pcm);
    YTMUMixAnalysis silence, outgoing, incoming;
    assert(YTMUAnalysePCM(pcm, SAMPLES, &silence));
    assert(silence.tempo == 0 && silence.confidence == 0 && silence.key == -1);
    assert(!YTMUAnalysePCM(pcm, SAMPLES + 1, &silence));
    assert(!YTMUAnalysePCM(pcm, 10, &silence));
    pcm[30] = NAN; assert(!YTMUAnalysePCM(pcm, SAMPLES, &silence));
    rhythm(pcm, 120, 0.13);
    assert(YTMUAnalysePCM(pcm, SAMPLES, &outgoing));
    printf("120 BPM fixture: %.2f BPM, confidence %.3f, %zu beats\n", outgoing.tempo, outgoing.confidence, outgoing.beatCount);
    assert(fabs(outgoing.tempo - 120) < 2 && outgoing.confidence >= 0.65 && outgoing.beatCount >= 16);
    rhythm(pcm, 118, 0.21);
    assert(YTMUAnalysePCM(pcm, SAMPLES, &incoming));
    printf("118 BPM fixture: %.2f BPM, confidence %.3f, %zu beats\n", incoming.tempo, incoming.confidence, incoming.beatCount);
    assert(fabs(incoming.tempo - 118) < 2 && incoming.confidence >= 0.65);
    /* Timing/key planning is exercised independently of the percussion-only fixture. */
    outgoing.key = incoming.key = 0;
    outgoing.keyConfidence = incoming.keyConfidence = 0.9;
    YTMUMixPlan mix = YTMUPlanMix(&outgoing, &incoming, 240, 180, 4, 1, 0);
    assert(mix.kind == YTMUMixAutoMix && mix.duration >= 2 && mix.duration <= 12);
    assert(mix.incomingRate >= 0.94 && mix.incomingRate <= 1.06);
    double aligned = 12 - mix.duration + incoming.beats[0] / mix.incomingRate;
    double distance = 100;
    for (size_t i = 0; i < outgoing.beatCount; ++i) distance = fmin(distance, fabs(aligned - outgoing.beats[i]));
    assert(distance < 0.001);
    assert(YTMUPlanMix(&outgoing, &incoming, 240, 180, 4, 0, 0).kind == YTMUMixCrossfade);
    assert(YTMUPlanMix(&outgoing, &incoming, 240, 180, 4, 1, 1).kind == YTMUMixBypass);
    incoming.key = -1;
    assert(YTMUPlanMix(&outgoing, &incoming, 240, 180, 4, 1, 0).kind == YTMUMixCrossfade);
    incoming.key = 0;
    incoming.tempo = 90;
    assert(YTMUPlanMix(&outgoing, &incoming, 240, 180, 4, 1, 0).kind == YTMUMixCrossfade);
    incoming.tempo = outgoing.tempo; incoming.key = 1; outgoing.key = 0;
    assert(YTMUPlanMix(&outgoing, &incoming, 240, 180, 4, 1, 0).kind == YTMUMixCrossfade);
    incoming.key = 7;
    assert(YTMUPlanMix(&outgoing, &incoming, 240, 180, 4, 1, 0).kind == YTMUMixAutoMix);
    incoming.confidence = 0.2;
    assert(YTMUPlanMix(&outgoing, &incoming, 240, 180, 4, 1, 0).kind == YTMUMixCrossfade);
    incoming.confidence = NAN;
    assert(YTMUPlanMix(&outgoing, &incoming, 240, 180, 4, 1, 0).kind == YTMUMixCrossfade);
    incoming.confidence = 0.9; incoming.rms = outgoing.rms / 8;
    assert(YTMUPlanMix(&outgoing, &incoming, 240, 180, 4, 1, 0).kind == YTMUMixCrossfade);
    assert(YTMUPlanMix(NULL, NULL, NAN, 180, 4, 1, 0).kind == YTMUMixBypass);
    assert(YTMUPlanMix(NULL, NULL, 2, 180, 4, 1, 0).kind == YTMUMixBypass);
    assert(YTMUPlanMix(NULL, NULL, 5, 180, 12, 1, 0).duration <= 2.5);
    assert(YTMUPlanMix(NULL, NULL, 180, 5, 12, 0, 0).duration == 2.5);
    assert(YTMUPlanMix(NULL, NULL, 240, 180, NAN, 1, 0).duration == 4);
    assert(fabs(YTMUMixRateAtProgress(1.04, 0) - 1.04) < 1e-6);
    assert(YTMUMixRateAtProgress(1.04, 1) == 1);
    assert(YTMUMixRateAtProgress(1.04, 0.5) < 1.04);
    assert(YTMUMixRateAtProgress(10, 0) <= 1.06);
    chord(pcm, 261.6256, 329.6276, 391.9954);
    assert(YTMUAnalysePCM(pcm, SAMPLES, &incoming));
    printf("C major fixture: key %d, key confidence %.3f\n", incoming.key, incoming.keyConfidence);
    assert(incoming.key == 0 && incoming.confidence < 0.65);
    unsigned state = 31;
    for (int i = 0; i < SAMPLES; ++i) {
        state = state * 1664525u + 1013904223u;
        pcm[i] = (float)((double)(state >> 8) / 16777216 - 0.5) * 0.1f;
    }
    assert(YTMUAnalysePCM(pcm, SAMPLES, &incoming));
    assert(incoming.confidence < 0.65);
    /* Unevenly spaced transients should not produce a confident beat grid. */
    memset(pcm, 0, SAMPLES * sizeof(float));
    double next = 0.1, onset = -1;
    for (int i = 0; i < SAMPLES; ++i) {
        double t = (double)i / YTMU_ANALYSIS_RATE;
        if (t >= next) {
            onset = t;
            state = state * 1664525u + 1013904223u;
            next += 0.25 + 0.6 * (double)(state >> 8) / 16777216;
        }
        if (onset >= 0) pcm[i] = (float)(0.7 * exp(-(t - onset) * 60) * sin(2 * PI * 170 * t));
    }
    assert(YTMUAnalysePCM(pcm, SAMPLES, &incoming));
    assert(incoming.confidence < 0.65);
    free(pcm);
    puts("All mixing tests passed.");
    return 0;
}
