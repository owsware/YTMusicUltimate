#include "YTMUMixAnalysis.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#define FFT_SIZE 2048
#define HOP 256
#define MAX_FRAMES (YTMU_ANALYSIS_RATE * YTMU_ANALYSIS_SECONDS / HOP + 1)
#define PI 3.14159265358979323846

static double clamp(double v, double lo, double hi) { return fmin(hi, fmax(lo, v)); }

static void fft(float *real, float *imag) {
    for (unsigned i = 1, j = 0; i < FFT_SIZE; ++i) {
        unsigned bit = FFT_SIZE >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            float t = real[i]; real[i] = real[j]; real[j] = t;
            t = imag[i]; imag[i] = imag[j]; imag[j] = t;
        }
    }
    for (unsigned length = 2; length <= FFT_SIZE; length <<= 1) {
        double angle = -2 * PI / length;
        float wr = (float)cos(angle), wi = (float)sin(angle);
        for (unsigned base = 0; base < FFT_SIZE; base += length) {
            float r = 1, im = 0;
            for (unsigned j = 0; j < length / 2; ++j) {
                unsigned a = base + j, b = a + length / 2;
                float tr = r * real[b] - im * imag[b], ti = r * imag[b] + im * real[b];
                real[b] = real[a] - tr; imag[b] = imag[a] - ti;
                real[a] += tr; imag[a] += ti;
                float next = r * wr - im * wi;
                im = r * wi + im * wr; r = next;
            }
        }
    }
}

static void estimateKey(const double *chroma, YTMUMixAnalysis *result) {
    static const double profiles[2][12] = {
        {6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88},
        {6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17}
    };
    double best = -1, second = -1, mean = 0, variance = 0;
    int key = -1;
    for (int i = 0; i < 12; ++i) mean += chroma[i] / 12;
    for (int i = 0; i < 12; ++i) variance += (chroma[i] - mean) * (chroma[i] - mean);
    if (variance < 1e-12) return;
    for (int mode = 0; mode < 2; ++mode) {
        double pm = 0, pv = 0;
        for (int i = 0; i < 12; ++i) pm += profiles[mode][i] / 12;
        for (int i = 0; i < 12; ++i) pv += (profiles[mode][i] - pm) * (profiles[mode][i] - pm);
        for (int root = 0; root < 12; ++root) {
            double dot = 0;
            for (int i = 0; i < 12; ++i)
                dot += (chroma[(i + root) % 12] - mean) * (profiles[mode][i] - pm);
            double score = dot / sqrt(variance * pv);
            if (score > best) { second = best; best = score; key = mode * 12 + root; }
            else if (score > second) second = score;
        }
    }
    result->keyConfidence = clamp((best - second) * 4, 0, 1);
    if (best >= 0.65 && result->keyConfidence >= 0.15) result->key = key;
}

int YTMUAnalysePCM(const float *pcm, size_t count, YTMUMixAnalysis *result) {
    if (!result) return 0;
    memset(result, 0, sizeof(*result)); result->key = -1;
    if (!pcm || count < FFT_SIZE || count > YTMU_ANALYSIS_RATE * YTMU_ANALYSIS_SECONDS) return 0;
    double energy = 0;
    for (size_t i = 0; i < count; ++i) {
        if (!isfinite(pcm[i])) return 0;
        energy += (double)pcm[i] * pcm[i];
    }
    result->duration = (double)count / YTMU_ANALYSIS_RATE;
    result->rms = sqrt(energy / count);
    if (result->rms < 0.001) return 1;

    float real[FFT_SIZE], imag[FFT_SIZE], previous[FFT_SIZE / 2 + 1] = {0};
    float window[FFT_SIZE];
    double onsets[MAX_FRAMES] = {0}, chroma[12] = {0};
    for (int i = 0; i < FFT_SIZE; ++i) window[i] = (float)(0.5 - 0.5 * cos(2 * PI * i / (FFT_SIZE - 1)));
    size_t frames = 0;
    for (size_t start = 0; start + FFT_SIZE <= count; start += HOP) {
        for (int i = 0; i < FFT_SIZE; ++i) { real[i] = pcm[start + i] * window[i]; imag[i] = 0; }
        fft(real, imag);
        double flux = 0;
        for (int k = 3; k < FFT_SIZE / 2; ++k) {
            double hz = (double)k * YTMU_ANALYSIS_RATE / FFT_SIZE;
            float magnitude = sqrtf(real[k] * real[k] + imag[k] * imag[k]);
            if (hz < 8000) flux += fmax(0, magnitude - previous[k]);
            previous[k] = magnitude;
            if (hz >= 80 && hz <= 2500) {
                int note = (int)lround(69 + 12 * log2(hz / 440));
                double cents = fabs(69 + 12 * log2(hz / 440) - note);
                if (cents < 0.3) chroma[(note % 12 + 12) % 12] += magnitude * magnitude;
            }
        }
        onsets[frames++] = flux;
    }
    estimateKey(chroma, result);
    if (frames < 4 || result->duration < 3) return 1;

    /* Remove sustained noise and slow dynamics before measuring periodicity. */
    double filtered[MAX_FRAMES] = {0}, maximum = 0;
    for (size_t i = 0; i < frames; ++i) {
        double local = 0; size_t n = 0;
        size_t lo = i > 8 ? i - 8 : 0, hi = i + 8 < frames ? i + 8 : frames - 1;
        for (size_t j = lo; j <= hi; ++j) { local += onsets[j]; ++n; }
        filtered[i] = fmax(0, onsets[i] - 1.3 * local / n);
        maximum = fmax(maximum, filtered[i]);
    }
    if (maximum < 1e-6) return 1;
    double best = 0; int bestLag = 0;
    int minimumLag = (int)floor(60.0 * YTMU_ANALYSIS_RATE / (180 * HOP));
    int maximumLag = (int)ceil(60.0 * YTMU_ANALYSIS_RATE / (60 * HOP));
    for (int lag = minimumLag; lag <= maximumLag && lag < (int)frames / 3; ++lag) {
        double dot = 0, aa = 0, bb = 0;
        for (size_t i = (size_t)lag; i < frames; ++i) {
            dot += filtered[i] * filtered[i - lag];
            aa += filtered[i] * filtered[i]; bb += filtered[i - lag] * filtered[i - lag];
        }
        double score = aa * bb > 1e-12 ? dot / sqrt(aa * bb) : 0;
        if (score > best + 0.025) { best = score; bestLag = lag; }
    }
    if (!bestLag || best < 0.55) return 1;

    double phaseScore = -1; int phase = 0;
    for (int p = 0; p < bestLag; ++p) {
        double score = 0;
        for (size_t i = (size_t)p; i < frames; i += (size_t)bestLag) score += filtered[i];
        if (score > phaseScore) { phaseScore = score; phase = p; }
    }
    for (size_t expected = (size_t)phase; expected < frames && result->beatCount < YTMU_MAX_BEATS; expected += (size_t)bestLag) {
        size_t peak = expected;
        size_t lo = expected > 3 ? expected - 3 : 0, hi = expected + 3 < frames ? expected + 3 : frames - 1;
        for (size_t i = lo; i <= hi; ++i) if (filtered[i] > filtered[peak]) peak = i;
        if (filtered[peak] < maximum * 0.15) continue;
        double beat = ((double)peak * HOP + FFT_SIZE / 2.0) / YTMU_ANALYSIS_RATE;
        if (!result->beatCount || beat > result->beats[result->beatCount - 1] + 0.2)
            result->beats[result->beatCount++] = beat;
    }
    if (result->beatCount >= 4) {
        double intervals = (result->beats[result->beatCount - 1] - result->beats[0]) / (result->beatCount - 1);
        result->tempo = 60 / intervals;
        result->confidence = clamp(best, 0, 1);
    }
    return 1;
}

static int compatibleKeys(int a, int b) {
    if (a < 0 || b < 0) return 1; /* Unknown key does not justify changing pitch. */
    int rootA = a % 12, rootB = b % 12, delta = (rootB - rootA + 12) % 12;
    if (a / 12 == b / 12) return delta == 0 || delta == 5 || delta == 7;
    return a < 12 ? delta == 9 : delta == 3; /* Relative major/minor. */
}

YTMUMixPlan YTMUPlanMix(const YTMUMixAnalysis *outro, const YTMUMixAnalysis *intro,
                      double outgoingDuration, double incomingDuration,
                      double crossfadeDuration, int pitchPreserving, int sequentialAlbum) {
    YTMUMixPlan result = {YTMUMixBypass, 0, 1};
    if (!isfinite(outgoingDuration) || !isfinite(incomingDuration) ||
        outgoingDuration < 3 || incomingDuration < 3 || sequentialAlbum) return result;
    result.kind = YTMUMixCrossfade;
    result.duration = fmin(clamp(isfinite(crossfadeDuration) ? crossfadeDuration : 4, 1, 12),
                           fmin(outgoingDuration / 2, incomingDuration / 2));
    if (!pitchPreserving || !outro || !intro || !isfinite(outro->confidence) || !isfinite(intro->confidence) ||
        outro->confidence < 0.65 || intro->confidence < 0.65 ||
        outro->tempo < 60 || intro->tempo < 60 || !isfinite(outro->tempo) || !isfinite(intro->tempo) ||
        !outro->beatCount || !intro->beatCount || outro->beatCount > YTMU_MAX_BEATS ||
        intro->beatCount > YTMU_MAX_BEATS || outro->key < 0 || outro->key > 23 || intro->key < 0 || intro->key > 23 ||
        !isfinite(outro->keyConfidence) || !isfinite(intro->keyConfidence) ||
        outro->keyConfidence < 0.15 || intro->keyConfidence < 0.15 || !compatibleKeys(outro->key, intro->key)) return result;
    if (!isfinite(outro->rms) || !isfinite(intro->rms) || outro->rms < 0.001 || intro->rms < 0.001 ||
        fmax(outro->rms, intro->rms) / fmin(outro->rms, intro->rms) > 4) return result;
    double ratio = outro->tempo / intro->tempo;
    if (ratio < 0.94 || ratio > 1.06) return result;
    double firstBeat = intro->beats[0] / ratio;
    double bestError = 1e9, bestDuration = 0;
    for (size_t i = 0; i < outro->beatCount; ++i) {
        double start = outgoingDuration - outro->duration + outro->beats[i] - firstBeat;
        double duration = outgoingDuration - start;
        if (!isfinite(duration) || duration < 2 || duration > 12 ||
            duration > outgoingDuration / 2 || duration > incomingDuration / 2) continue;
        double error = fabs(duration - result.duration);
        if (error < bestError) { bestError = error; bestDuration = duration; }
    }
    if (bestDuration > 0) { result.kind = YTMUMixAutoMix; result.duration = bestDuration; result.incomingRate = ratio; }
    return result;
}

double YTMUMixRateAtProgress(double initialRate, double progress) {
    if (!isfinite(initialRate)) return 1;
    double t = clamp(isfinite(progress) ? progress : 1, 0, 1);
    /* Match beats during the overlap, recover tempo over the following two seconds. */
    double smooth = t * t * (3 - 2 * t);
    return 1 + (clamp(initialRate, 0.94, 1.06) - 1) * (1 - smooth);
}
