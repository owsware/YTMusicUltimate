#import "YTMUAudioWindowDecoder.h"
#import <QuartzCore/QuartzCore.h>
#include "../Utils/MobileFFmpeg/libavformat/avformat.h"
#include "../Utils/MobileFFmpeg/libavcodec/avcodec.h"
#include "../Utils/MobileFFmpeg/libswresample/swresample.h"
#include "../Utils/MobileFFmpeg/libavutil/channel_layout.h"
#include "../Utils/MobileFFmpeg/libavutil/opt.h"
#include <errno.h>

static const NSUInteger YTMUMaxWindowBytes = 6 * 1024 * 1024;

@interface YTMUWindowBudget : NSObject
@property (nonatomic) CFTimeInterval deadline;
@property (nonatomic) NSUInteger bytes;
@property (nonatomic, strong) NSOperation *operation;
- (BOOL)expired;
@end
@implementation YTMUWindowBudget
- (BOOL)expired { return self.operation.cancelled || CACurrentMediaTime() >= self.deadline || self.bytes >= YTMUMaxWindowBytes; }
@end

@interface YTMUWindowRequest : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSMutableData *data;
@property (nonatomic, strong) NSHTTPURLResponse *response;
@property (nonatomic, strong) YTMUWindowBudget *budget;
@property (nonatomic) NSUInteger limit;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, strong) dispatch_semaphore_t completion;
@end
@implementation YTMUWindowRequest
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
 didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))handler {
    if (![response isKindOfClass:[NSHTTPURLResponse class]] ||
        ([(NSHTTPURLResponse *)response statusCode] != 200 && [(NSHTTPURLResponse *)response statusCode] != 206) ||
        (response.expectedContentLength > 0 && (uint64_t)response.expectedContentLength > self.limit)) {
        handler(NSURLSessionResponseCancel); return;
    }
    self.response = (NSHTTPURLResponse *)response;
    handler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if ([self.budget expired] || data.length > self.limit - self.data.length ||
        data.length > YTMUMaxWindowBytes - self.budget.bytes) {
        [task cancel]; return;
    }
    self.budget.bytes += data.length;
    [self.data appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    self.error = error;
    dispatch_semaphore_signal(self.completion);
}
@end

static NSData *YTMUFetch(NSURL *url, NSString *range, NSUInteger limit,
                         YTMUWindowBudget *budget, NSHTTPURLResponse **response) {
    if (![url.scheme.lowercaseString isEqualToString:@"https"] || [budget expired]) return nil;
    YTMUWindowRequest *delegate = [YTMUWindowRequest new];
    delegate.data = [NSMutableData data]; delegate.limit = limit; delegate.budget = budget;
    delegate.completion = dispatch_semaphore_create(0);
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    configuration.timeoutIntervalForRequest = MAX(0.1, budget.deadline - CACurrentMediaTime());
    configuration.timeoutIntervalForResource = configuration.timeoutIntervalForRequest;
    NSOperationQueue *queue = [NSOperationQueue new]; queue.maxConcurrentOperationCount = 1;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:delegate delegateQueue:queue];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    if (range) [request setValue:range forHTTPHeaderField:@"Range"];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request];
    [task resume];
    BOOL finished = NO;
    while (![budget expired]) {
        if (!dispatch_semaphore_wait(delegate.completion, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10))) {
            finished = YES; break;
        }
    }
    [session invalidateAndCancel];
    if (!finished || delegate.error || !delegate.response || !delegate.data.length) return nil;
    if (response) *response = delegate.response;
    return delegate.data;
}

static NSURL *YTMURelativeURL(NSString *line, NSURL *base) {
    NSURL *url = [NSURL URLWithString:[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] relativeToURL:base].absoluteURL;
    return [url.scheme.lowercaseString isEqualToString:@"https"] ? url : nil;
}

static NSString *YTMUAttribute(NSString *line, NSString *key) {
    NSString *needle = [key stringByAppendingString:@"=\""];
    NSRange start = [line rangeOfString:needle];
    if (start.location == NSNotFound) return nil;
    NSUInteger offset = NSMaxRange(start);
    NSRange end = [line rangeOfString:@"\"" options:0 range:NSMakeRange(offset, line.length - offset)];
    return end.location == NSNotFound ? nil : [line substringWithRange:NSMakeRange(offset, end.location - offset)];
}

/* Fetch only the media segments intersecting the requested audio window. */
static NSData *YTMUHLSWindow(NSURL *url, double start, double duration,
                             YTMUWindowBudget *budget, double *skip) {
    NSData *manifest = YTMUFetch(url, nil, 256 * 1024, budget, NULL);
    NSString *text = [[NSString alloc] initWithData:manifest encoding:NSUTF8StringEncoding];
    if (![text hasPrefix:@"#EXTM3U"]) return nil;
    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    if ([text containsString:@"#EXT-X-STREAM-INF:"]) {
        NSURL *audioURL = nil;
        for (NSUInteger i = 0; i < lines.count; ++i) {
            NSString *line = lines[i];
            if ([line hasPrefix:@"#EXT-X-MEDIA:"] && [line containsString:@"TYPE=AUDIO"]) {
                NSString *uri = YTMUAttribute(line, @"URI");
                if (uri) { audioURL = YTMURelativeURL(uri, url); break; }
            }
            if ([line hasPrefix:@"#EXT-X-STREAM-INF:"] && i + 1 < lines.count) {
                NSString *codecs = YTMUAttribute(line, @"CODECS");
                if ([codecs hasPrefix:@"mp4a"] && ![codecs containsString:@","])
                    audioURL = YTMURelativeURL(lines[i + 1], url);
            }
        }
        if (!audioURL) return nil;
        url = audioURL;
        manifest = YTMUFetch(url, nil, 256 * 1024, budget, NULL);
        text = [[NSString alloc] initWithData:manifest encoding:NSUTF8StringEncoding];
        lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    }
    /* Unsupported playlists fall back without downloading or decrypting them. */
    if (![text containsString:@"#EXT-X-ENDLIST"] || [text containsString:@"#EXT-X-KEY:"] ||
        [text containsString:@"#EXT-X-BYTERANGE:"] || [text containsString:@"#EXT-X-DISCONTINUITY"]) return nil;
    NSMutableData *media = [NSMutableData data];
    NSURL *initialization = nil; double cursor = 0, segmentDuration = 0;
    BOOL selected = NO;
    for (NSString *untrimmed in lines) {
        NSString *line = [untrimmed stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([line hasPrefix:@"#EXT-X-MAP:"]) initialization = YTMURelativeURL(YTMUAttribute(line, @"URI"), url);
        else if ([line hasPrefix:@"#EXTINF:"]) segmentDuration = [[line substringFromIndex:8] doubleValue];
        else if (line.length && ![line hasPrefix:@"#"] && segmentDuration > 0) {
            if (cursor + segmentDuration > start && cursor < start + duration) {
                if (!selected) {
                    *skip = MAX(0, start - cursor); selected = YES;
                    if (initialization) {
                        NSData *init = YTMUFetch(initialization, nil, 256 * 1024, budget, NULL);
                        if (!init) return nil;
                        [media appendData:init];
                    }
                }
                NSData *segment = YTMUFetch(YTMURelativeURL(line, url), nil, 2 * 1024 * 1024, budget, NULL);
                if (!segment) return nil;
                [media appendData:segment];
            }
            cursor += segmentDuration; segmentDuration = 0;
            if (cursor >= start + duration) break;
        }
    }
    return selected ? media : nil;
}

@interface YTMUWindowSource : NSObject
@property (nonatomic, strong) YTMUWindowBudget *budget;
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSData *memory;
@property (nonatomic, strong) NSData *block;
@property (nonatomic) int64_t blockStart;
@property (nonatomic) int64_t position;
@property (nonatomic) int64_t length;
@end
@implementation YTMUWindowSource
@end

static int YTMURead(void *opaque, uint8_t *buffer, int size) {
    YTMUWindowSource *source = (__bridge YTMUWindowSource *)opaque;
    if ([source.budget expired]) return AVERROR_EXIT;
    if (source.position >= source.length && source.length >= 0) return AVERROR_EOF;
    if (source.memory) {
        int count = (int)MIN((int64_t)size, (int64_t)source.memory.length - source.position);
        if (count <= 0) return AVERROR_EOF;
        memcpy(buffer, (const uint8_t *)source.memory.bytes + source.position, count);
        source.position += count; return count;
    }
    if (!source.block || source.position < source.blockStart ||
        source.position >= source.blockStart + (int64_t)source.block.length) {
        int64_t end = source.position + 65535;
        if (source.length >= 0) end = MIN(end, source.length - 1);
        NSHTTPURLResponse *response = nil;
        NSString *range = [NSString stringWithFormat:@"bytes=%lld-%lld", (long long)source.position, (long long)end];
        NSData *data = YTMUFetch(source.url, range, 65536, source.budget, &response);
        if (!data || response.statusCode != 206) return AVERROR(EIO);
        NSString *contentRange = [response valueForHTTPHeaderField:@"Content-Range"];
        NSArray *parts = [contentRange componentsSeparatedByString:@"/"];
        if (parts.count != 2 || [parts[1] isEqualToString:@"*"]) return AVERROR(EIO);
        source.length = [parts[1] longLongValue];
        NSString *expected = [NSString stringWithFormat:@"bytes %lld-", (long long)source.position];
        if (source.length <= 0 || ![contentRange hasPrefix:expected]) return AVERROR(EIO);
        source.block = data; source.blockStart = source.position;
    }
    int64_t offset = source.position - source.blockStart;
    int count = (int)MIN((int64_t)size, (int64_t)source.block.length - offset);
    memcpy(buffer, (const uint8_t *)source.block.bytes + offset, count);
    source.position += count; return count;
}

static int64_t YTMUSeek(void *opaque, int64_t offset, int whence) {
    YTMUWindowSource *source = (__bridge YTMUWindowSource *)opaque;
    if (whence == AVSEEK_SIZE) return source.length;
    whence &= ~AVSEEK_FORCE;
    int64_t position = whence == SEEK_SET ? offset : whence == SEEK_CUR ? source.position + offset :
                       whence == SEEK_END && source.length >= 0 ? source.length + offset : -1;
    if (position < 0 || (source.length >= 0 && position > source.length)) return AVERROR(EINVAL);
    source.position = position; return position;
}

static int YTMUInterrupt(void *opaque) { return [(__bridge YTMUWindowBudget *)opaque expired]; }

BOOL YTMUDecodeAudioWindow(NSURL *url, double start, double duration,
                          NSOperation *operation, YTMUMixAnalysis *analysis) {
    if (!url || !analysis || !isfinite(start) || start < 0 || !isfinite(duration) || duration <= 0 ||
        ![url.scheme.lowercaseString isEqualToString:@"https"]) return NO;
    duration = MIN(duration, YTMU_ANALYSIS_SECONDS);
    YTMUWindowBudget *budget = [YTMUWindowBudget new];
    budget.operation = operation; budget.deadline = CACurrentMediaTime() + 8;
    YTMUWindowSource *source = [YTMUWindowSource new]; source.budget = budget; source.url = url; source.length = -1;
    double skip = start;
    BOOL hls = [url.path.lowercaseString hasSuffix:@".m3u8"];
    if (hls) {
        source.memory = YTMUHLSWindow(url, start, duration, budget, &skip);
        if (!source.memory) return NO;
        source.length = source.memory.length;
    }
    uint8_t *ioBuffer = av_malloc(32768);
    AVIOContext *io = ioBuffer ? avio_alloc_context(ioBuffer, 32768, 0, (__bridge void *)source, YTMURead, NULL, YTMUSeek) : NULL;
    AVFormatContext *format = avformat_alloc_context();
    AVCodecContext *codec = NULL; SwrContext *resampler = NULL;
    AVFrame *frame = NULL; AVPacket *packet = NULL; float *pcm = NULL;
    size_t written = 0, capacity = (size_t)ceil(duration * YTMU_ANALYSIS_RATE);
    BOOL success = NO;
    if (!io || !format) goto cleanup;
    format->pb = io; format->flags |= AVFMT_FLAG_CUSTOM_IO;
    format->interrupt_callback = (AVIOInterruptCB){YTMUInterrupt, (__bridge void *)budget};
    format->probesize = 256 * 1024; format->max_analyze_duration = AV_TIME_BASE;
    if (avformat_open_input(&format, NULL, NULL, NULL) < 0 || avformat_find_stream_info(format, NULL) < 0) goto cleanup;
    int stream = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (stream < 0) goto cleanup;
    AVCodecParameters *parameters = format->streams[stream]->codecpar;
    if (parameters->channels < 1 || parameters->channels > 8 || parameters->sample_rate < 8000 || parameters->sample_rate > 192000) goto cleanup;
    AVCodec *decoder = avcodec_find_decoder(parameters->codec_id);
    codec = decoder ? avcodec_alloc_context3(decoder) : NULL;
    if (!codec || avcodec_parameters_to_context(codec, parameters) < 0) goto cleanup;
    codec->thread_count = 1;
    if (avcodec_open2(codec, decoder, NULL) < 0) goto cleanup;
    resampler = swr_alloc_set_opts(NULL, AV_CH_LAYOUT_MONO, AV_SAMPLE_FMT_FLT, YTMU_ANALYSIS_RATE,
                                 codec->channel_layout ?: av_get_default_channel_layout(codec->channels), codec->sample_fmt, codec->sample_rate, 0, NULL);
    if (!resampler || swr_init(resampler) < 0) goto cleanup;
    if (!hls && start > 0) {
        int64_t timestamp = (int64_t)(start / av_q2d(format->streams[stream]->time_base));
        if (av_seek_frame(format, stream, timestamp, AVSEEK_FLAG_BACKWARD) < 0) goto cleanup;
        avcodec_flush_buffers(codec);
    }
    frame = av_frame_alloc(); packet = av_packet_alloc(); pcm = calloc(capacity, sizeof(float));
    if (!frame || !packet || !pcm) goto cleanup;
    double origin = NAN;
    for (unsigned packets = 0; packets < 4096 && written < capacity && ![budget expired]; ++packets) {
        if (av_read_frame(format, packet) < 0) break;
        if (packet->stream_index == stream && avcodec_send_packet(codec, packet) >= 0) {
            while (avcodec_receive_frame(codec, frame) == 0 && written < capacity) {
                if (frame->best_effort_timestamp == AV_NOPTS_VALUE || frame->nb_samples <= 0 || frame->nb_samples > 65536) goto cleanup;
                double timestamp = frame->best_effort_timestamp * av_q2d(format->streams[stream]->time_base);
                if (!isfinite(origin)) origin = hls ? timestamp : 0;
                double relative = timestamp - origin;
                int count = (int)av_rescale_rnd(swr_get_delay(resampler, codec->sample_rate) + frame->nb_samples,
                                              YTMU_ANALYSIS_RATE, codec->sample_rate, AV_ROUND_UP);
                if (count <= 0 || count > 65536) goto cleanup;
                float *converted = av_malloc(count * sizeof(float));
                if (!converted) goto cleanup;
                uint8_t *output[] = {(uint8_t *)converted};
                int samples = swr_convert(resampler, output, count, (const uint8_t **)frame->extended_data, frame->nb_samples);
                int trim = (int)MIN((double)MAX(samples, 0), MAX(0, ceil((skip - relative) * YTMU_ANALYSIS_RATE)));
                if (samples > trim) {
                    size_t take = MIN((size_t)(samples - trim), capacity - written);
                    memcpy(pcm + written, converted + trim, take * sizeof(float)); written += take;
                }
                av_free(converted); av_frame_unref(frame);
            }
        }
        av_packet_unref(packet);
    }
    /* Partial windows would shift the outgoing beat grid; reject them. */
    success = !operation.cancelled && written >= capacity - YTMU_ANALYSIS_RATE / 10 && YTMUAnalysePCM(pcm, written, analysis);
cleanup:
    free(pcm); av_packet_free(&packet); av_frame_free(&frame); swr_free(&resampler); avcodec_free_context(&codec);
    avformat_close_input(&format);
    if (io) { av_freep(&io->buffer); avio_context_free(&io); } else av_free(ioBuffer);
    return success;
}
