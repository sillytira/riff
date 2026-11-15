#include "RiffCodecs.h"
#include <errno.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>

struct RiffConversion { atomic_bool cancelled; _Atomic double progress; };
RiffConversion *riff_conversion_create(void) {
    RiffConversion *job = calloc(1, sizeof(*job));
    if (job) { atomic_init(&job->cancelled, false); atomic_init(&job->progress, 0); }
    return job;
}
void riff_conversion_cancel(RiffConversion *job) { if (job) atomic_store(&job->cancelled, true); }
double riff_conversion_progress(const RiffConversion *job) { return job ? atomic_load(&job->progress) : 0; }
void riff_conversion_destroy(RiffConversion *job) { free(job); }
const char *riff_codecs_version(void) { return av_version_info(); }
static int interrupted(void *opaque) { return atomic_load(&((RiffConversion *)opaque)->cancelled); }

typedef struct {
    RiffConversion *job;
    AVFormatContext *output;
    AVCodecContext *encoder;
    AVStream *stream;
    AVAudioFifo *fifo;
    SwrContext *swr;
    int64_t samples;
    double duration;
} Writer;

static int packets(Writer *writer, AVFrame *frame) {
    int result = avcodec_send_frame(writer->encoder, frame);
    if (result < 0) return result;
    AVPacket *packet = av_packet_alloc();
    if (!packet) return AVERROR(ENOMEM);
    while ((result = avcodec_receive_packet(writer->encoder, packet)) >= 0) {
        av_packet_rescale_ts(packet, writer->encoder->time_base, writer->stream->time_base);
        packet->stream_index = writer->stream->index;
        result = av_interleaved_write_frame(writer->output, packet);
        av_packet_unref(packet);
        if (result < 0) break;
    }
    av_packet_free(&packet);
    return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}

static int write_fifo(Writer *writer, bool final) {
    int available, result = 0;
    const int size = writer->encoder->frame_size > 0 ? writer->encoder->frame_size : 4096;
    while ((available = av_audio_fifo_size(writer->fifo)) >= size || (final && available > 0)) {
        if (interrupted(writer->job)) return AVERROR_EXIT;
        int count = available < size ? available : size;
        int capacity = count;
        if (count < size && !(writer->encoder->codec->capabilities & AV_CODEC_CAP_SMALL_LAST_FRAME)
            && !(writer->encoder->codec->capabilities & AV_CODEC_CAP_VARIABLE_FRAME_SIZE)) capacity = size;
        AVFrame *frame = av_frame_alloc();
        if (!frame) return AVERROR(ENOMEM);
        frame->nb_samples = capacity;
        frame->format = writer->encoder->sample_fmt;
        frame->sample_rate = writer->encoder->sample_rate;
        result = av_channel_layout_copy(&frame->ch_layout, &writer->encoder->ch_layout);
        if (result >= 0) result = av_frame_get_buffer(frame, 0);
        if (result >= 0) result = av_samples_set_silence(frame->extended_data, 0, capacity,
                                    frame->ch_layout.nb_channels, frame->format);
        if (result >= 0 && av_audio_fifo_read(writer->fifo, (void **)frame->extended_data, count) != count) result = AVERROR(EIO);
        if (result >= 0) {
            frame->pts = writer->samples;
            writer->samples += capacity;
            result = packets(writer, frame);
        }
        av_frame_free(&frame);
        if (result < 0) return result;
        if (writer->duration > 0) {
            double progress = writer->samples / (writer->duration * writer->encoder->sample_rate);
            atomic_store(&writer->job->progress, progress < .99 ? progress : .99);
        }
    }
    return 0;
}

static int converted(Writer *writer, AVFrame *input) {
    int result;
    if (!writer->swr) {
        if (!input) return 0;
        result = swr_alloc_set_opts2(&writer->swr, &writer->encoder->ch_layout,
                    writer->encoder->sample_fmt, writer->encoder->sample_rate,
                    &input->ch_layout, input->format, input->sample_rate, 0, NULL);
        if (result < 0) return result;
        if ((result = swr_init(writer->swr)) < 0) return result;
    }
    int capacity = swr_get_out_samples(writer->swr, input ? input->nb_samples : 0);
    if (capacity < 0) return capacity;
    if (!capacity) return 0;
    uint8_t **audio = NULL;
    result = av_samples_alloc_array_and_samples(&audio, NULL, writer->encoder->ch_layout.nb_channels,
                                                capacity, writer->encoder->sample_fmt, 0);
    if (result < 0) return result;
    int count = swr_convert(writer->swr, audio, capacity,
                            input ? (const uint8_t **)input->extended_data : NULL, input ? input->nb_samples : 0);
    if (count < 0) result = count;
    else if ((result = av_audio_fifo_realloc(writer->fifo, av_audio_fifo_size(writer->fifo) + count)) >= 0) {
        result = av_audio_fifo_write(writer->fifo, (void **)audio, count);
        if (result != count) result = AVERROR(EIO);
        else result = write_fifo(writer, false);
    }
    av_freep(&audio[0]);
    av_freep(&audio);
    return result;
}

static int decoded(AVCodecContext *decoder, Writer *writer) {
    AVFrame *frame = av_frame_alloc();
    if (!frame) return AVERROR(ENOMEM);
    int result;
    while ((result = avcodec_receive_frame(decoder, frame)) >= 0) {
        if (interrupted(writer->job)) { result = AVERROR_EXIT; break; }
        result = converted(writer, frame);
        av_frame_unref(frame);
        if (result < 0) break;
    }
    av_frame_free(&frame);
    return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}

int riff_conversion_run(RiffConversion *job, const char *input, const char *output, const char *format,
                        int bitrate, const char *title, const char *artist, const char *album,
                        char *error, size_t error_size) {
    int result = AVERROR(EINVAL), stream_index = -1;
    const char *stage = "Invalid conversion request";
    AVFormatContext *source = NULL;
    AVCodecContext *decoder = NULL;
    AVPacket *packet = NULL;
    Writer writer = { .job = job };
    bool output_created = false;
    if (!job || !input || !output || !format || !strcmp(input, output) || strstr(input, "://") || access(output, F_OK) == 0) goto done;
    const char *codec_name = NULL, *muxer = NULL;
    if (!strcmp(format, "mp3")) { codec_name = "libmp3lame"; muxer = "mp3"; }
    else if (!strcmp(format, "flac")) { codec_name = "flac"; muxer = "flac"; }
    else if (!strcmp(format, "m4a")) { codec_name = "aac"; muxer = "ipod"; }
    else if (!strcmp(format, "opus")) { codec_name = "libopus"; muxer = "ogg"; }
    else if (!strcmp(format, "wav")) { codec_name = "pcm_f32le"; muxer = "wav"; }
    else goto done;
    if (interrupted(job)) { result = AVERROR_EXIT; goto done; }
    stage = "Open source audio";
    source = avformat_alloc_context();
    if (!source) { result = AVERROR(ENOMEM); goto done; }
    source->interrupt_callback = (AVIOInterruptCB){ .callback = interrupted, .opaque = job };
    // Conversion is deliberately file-only; remote playback has a separate API.
    AVDictionary *options = NULL;
    av_dict_set(&options, "protocol_whitelist", "file", 0);
    result = avformat_open_input(&source, input, NULL, &options);
    av_dict_free(&options);
    if (result < 0 || (result = avformat_find_stream_info(source, NULL)) < 0) goto done;
    stream_index = av_find_best_stream(source, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (stream_index < 0) { result = stream_index; goto done; }
    const AVCodec *decoder_codec = avcodec_find_decoder(source->streams[stream_index]->codecpar->codec_id);
    if (!decoder_codec) { result = AVERROR_DECODER_NOT_FOUND; goto done; }
    decoder = avcodec_alloc_context3(decoder_codec);
    if (!decoder) { result = AVERROR(ENOMEM); goto done; }
    if ((result = avcodec_parameters_to_context(decoder, source->streams[stream_index]->codecpar)) < 0 ||
        (result = avcodec_open2(decoder, decoder_codec, NULL)) < 0) goto done;
    writer.duration = source->duration > 0 ? source->duration / (double)AV_TIME_BASE : 0;
    stage = "Create audio encoder";
    const AVCodec *encoder_codec = avcodec_find_encoder_by_name(codec_name);
    if (!encoder_codec) { result = AVERROR_ENCODER_NOT_FOUND; goto done; }
    writer.encoder = avcodec_alloc_context3(encoder_codec);
    if (!writer.encoder) { result = AVERROR(ENOMEM); goto done; }
    const enum AVSampleFormat *formats = NULL;
    int format_count = 0;
    result = avcodec_get_supported_config(writer.encoder, encoder_codec, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0, (const void **)&formats, &format_count);
    if (result < 0 || !formats || format_count < 1) { result = AVERROR(EINVAL); goto done; }
    writer.encoder->sample_fmt = formats[0];
    writer.encoder->sample_rate = decoder->sample_rate > 0 ? decoder->sample_rate : 48000;
    const int *rates = NULL;
    int rate_count = 0;
    if (avcodec_get_supported_config(writer.encoder, encoder_codec, AV_CODEC_CONFIG_SAMPLE_RATE, 0, (const void **)&rates, &rate_count) >= 0 && rates && rate_count > 0) {
        int desired = writer.encoder->sample_rate, selected = rates[0];
        for (int index = 0; index < rate_count; index++) {
            if (abs(rates[index] - desired) < abs(selected - desired)) selected = rates[index];
        }
        writer.encoder->sample_rate = selected;
    }
    const AVChannelLayout *layouts = NULL;
    int layout_count = 0;
    av_channel_layout_default(&writer.encoder->ch_layout, decoder->ch_layout.nb_channels > 0 ? decoder->ch_layout.nb_channels : 2);
    if (avcodec_get_supported_config(writer.encoder, encoder_codec, AV_CODEC_CONFIG_CHANNEL_LAYOUT, 0, (const void **)&layouts, &layout_count) >= 0 && layouts && layout_count > 0) {
        int selected = 0;
        for (int index = 0; index < layout_count; index++) {
            if (av_channel_layout_compare(&layouts[index], &writer.encoder->ch_layout) == 0) { selected = index; break; }
        }
        av_channel_layout_uninit(&writer.encoder->ch_layout);
        if ((result = av_channel_layout_copy(&writer.encoder->ch_layout, &layouts[selected])) < 0) goto done;
    }
    if (!strcmp(format, "flac")) {
        for (int index = 0; index < format_count; index++) {
            if (formats[index] == AV_SAMPLE_FMT_S32) { writer.encoder->sample_fmt = AV_SAMPLE_FMT_S32; writer.encoder->bits_per_raw_sample = 24; break; }
        }
    }
    writer.encoder->time_base = (AVRational){ 1, writer.encoder->sample_rate };
    writer.encoder->bit_rate = bitrate >= 32000 && bitrate <= 320000 ? bitrate : 192000;
    if ((result = avformat_alloc_output_context2(&writer.output, NULL, muxer, output)) < 0) goto done;
    if (writer.output->oformat->flags & AVFMT_GLOBALHEADER) writer.encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    if ((result = avcodec_open2(writer.encoder, encoder_codec, NULL)) < 0) goto done;
    writer.stream = avformat_new_stream(writer.output, NULL);
    if (!writer.stream) { result = AVERROR(ENOMEM); goto done; }
    writer.stream->time_base = writer.encoder->time_base;
    if ((result = avcodec_parameters_from_context(writer.stream->codecpar, writer.encoder)) < 0) goto done;
    if (title) av_dict_set(&writer.output->metadata, "title", title, 0);
    if (artist) av_dict_set(&writer.output->metadata, "artist", artist, 0);
    if (album) av_dict_set(&writer.output->metadata, "album", album, 0);
    stage = "Write converted audio";
    if ((result = avio_open(&writer.output->pb, output, AVIO_FLAG_WRITE)) < 0) goto done;
    output_created = true;
    if ((result = avformat_write_header(writer.output, NULL)) < 0) goto done;
    writer.fifo = av_audio_fifo_alloc(writer.encoder->sample_fmt, writer.encoder->ch_layout.nb_channels, 1);
    packet = av_packet_alloc();
    if (!writer.fifo || !packet) { result = AVERROR(ENOMEM); goto done; }
    while ((result = av_read_frame(source, packet)) >= 0) {
        if (interrupted(job)) { result = AVERROR_EXIT; break; }
        if (packet->stream_index == stream_index) {
            result = avcodec_send_packet(decoder, packet);
            if (result >= 0) result = decoded(decoder, &writer);
        }
        av_packet_unref(packet);
        if (result < 0) break;
    }
    if (result != AVERROR_EOF) goto done;
    result = avcodec_send_packet(decoder, NULL);
    if (result >= 0) result = decoded(decoder, &writer);
    if (result >= 0) result = converted(&writer, NULL);
    if (result >= 0) result = write_fifo(&writer, true);
    if (result >= 0) result = packets(&writer, NULL);
    if (result >= 0) result = av_write_trailer(writer.output);
    if (result >= 0) atomic_store(&job->progress, 1);
done:
    if (result < 0 && error && error_size) {
        char detail[AV_ERROR_MAX_STRING_SIZE];
        av_strerror(result, detail, sizeof(detail));
        snprintf(error, error_size, "%s: %s", stage, detail);
    }
    av_packet_free(&packet);
    if (writer.fifo) av_audio_fifo_free(writer.fifo);
    swr_free(&writer.swr);
    avcodec_free_context(&writer.encoder);
    avcodec_free_context(&decoder);
    if (writer.output) {
        if (writer.output->pb) avio_closep(&writer.output->pb);
        avformat_free_context(writer.output);
    }
    avformat_close_input(&source);
    if (result < 0 && output_created) remove(output);
    return result;
}

#include <pthread.h>
#include <strings.h>
#include <math.h>
#include <sys/stat.h>
#include <libavutil/time.h>

struct RiffStreamDecoder {
    atomic_bool cancelled;
    _Atomic int64_t deadline;
    AVFormatContext *source;
    AVCodecContext *codec;
    AVPacket *packet;
    AVFrame *frame;
    SwrContext *swr;
    AVAudioFifo *fifo;
    int stream_index;
    bool demux_eof, drain_sent, decoded_eof, timeline_ready;
    int64_t skip_remaining;
    double requested_position, read_position, origin;
    char *headers;
    char *local_path;
    char initial_host[1024];
    char initial_scheme[32];
    int initial_port;
};
static pthread_once_t riff_network_once = PTHREAD_ONCE_INIT;
static void riff_network_initialize(void) {
    avformat_network_init();
    // Provider URLs can contain access signatures. Return sanitized stage/error
    // messages through the API instead of emitting FFmpeg's raw URL diagnostics.
    av_log_set_level(AV_LOG_QUIET);
}
static int stream_interrupted(void *opaque) {
    RiffStreamDecoder *decoder = opaque;
    return atomic_load(&decoder->cancelled) || av_gettime_relative() > atomic_load(&decoder->deadline);
}
static int stream_error(RiffStreamDecoder *decoder, int code, const char *stage, char *error, size_t capacity) {
    if (!atomic_load(&decoder->cancelled) && av_gettime_relative() > atomic_load(&decoder->deadline)) code = AVERROR(ETIMEDOUT);
    if (error && capacity) {
        char detail[AV_ERROR_MAX_STRING_SIZE];
        av_strerror(code, detail, sizeof(detail));
        snprintf(error, capacity, "%s: %s", stage, detail);
    }
    return code;
}
RiffStreamDecoder *riff_decoder_create(void) {
    RiffStreamDecoder *decoder = calloc(1, sizeof(*decoder));
    if (decoder) { atomic_init(&decoder->cancelled, false); atomic_init(&decoder->deadline, INT64_MAX); }
    return decoder;
}
void riff_decoder_cancel(RiffStreamDecoder *decoder) { if (decoder) atomic_store(&decoder->cancelled, true); }
void riff_decoder_destroy(RiffStreamDecoder *decoder) {
    if (!decoder) return;
    if (decoder->fifo) av_audio_fifo_free(decoder->fifo);
    swr_free(&decoder->swr);
    av_packet_free(&decoder->packet);
    av_frame_free(&decoder->frame);
    avcodec_free_context(&decoder->codec);
    avformat_close_input(&decoder->source);
    av_free(decoder->headers);
    av_free(decoder->local_path);
    free(decoder);
}
static int stream_io_open(AVFormatContext *format, AVIOContext **io, const char *url, int flags, AVDictionary **options) {
    RiffStreamDecoder *decoder = format->opaque;
    AVDictionary *local = NULL;
    if (!options) options = &local;
    if (decoder->local_path) {
        // Local audio cannot open playlists, remote URLs or unrelated child files.
        if (strcmp(url, decoder->local_path)) return AVERROR(EACCES);
        av_dict_set(options, "protocol_whitelist", "file", 0);
        AVIOInterruptCB interrupt = { stream_interrupted, decoder };
        int result = avio_open2(io, url, flags, &interrupt, options);
        av_dict_free(&local);
        return result;
    }
    av_dict_set(options, "tls_verify", "1", 0);
    av_dict_set(options, "rw_timeout", "20000000", 0);
    av_dict_set(options, "protocol_whitelist", "http,https,tcp,tls,crypto,data", 0);
    char host[1024], scheme[32];
    int port;
    const char *target = !strncasecmp(url, "crypto+", 7) || !strncasecmp(url, "crypto:", 7) ? url + 7 : url;
    av_url_split(scheme, sizeof(scheme), NULL, 0, host, sizeof(host), &port, NULL, 0, target);
    if (port < 0) port = !strcasecmp(scheme, "https") ? 443 : 80;
    bool same_origin = !strcasecmp(host, decoder->initial_host) && !strcasecmp(scheme, decoder->initial_scheme) && port == decoder->initial_port;
    char *filtered = av_malloc(strlen(decoder->headers) + 1);
    if (!filtered) return AVERROR(ENOMEM);
    char *output = filtered;
    const char *line = decoder->headers;
    while (*line) {
        const char *end = strstr(line, "\r\n");
        size_t length = end ? (size_t)(end - line) : strlen(line);
        const char *colon = memchr(line, ':', length);
        size_t key = colon ? (size_t)(colon - line) : 0;
        bool sensitive = (key == 6 && !strncasecmp(line, "Cookie", key)) ||
                         (key == 7 && !strncasecmp(line, "Cookie2", key)) ||
                         (key == 13 && !strncasecmp(line, "Authorization", key));
        bool proxy_auth = key == 19 && !strncasecmp(line, "Proxy-Authorization", key);
        if (!proxy_auth && (!sensitive || same_origin)) {
            memcpy(output, line, length); output += length;
            if (end) { *output++ = '\r'; *output++ = '\n'; }
        }
        if (!end) break;
        line = end + 2;
    }
    *output = 0;
    av_dict_set(options, "headers", filtered, 0);
    av_free(filtered);
    AVIOInterruptCB interrupt = { stream_interrupted, decoder };
    int result = avio_open2(io, url, flags, &interrupt, options);
    av_dict_free(&local);
    return result;
}
static int decoder_open(RiffStreamDecoder *decoder, const char *url, const char *headers,
                        double position, double *duration, char *error, size_t error_size, bool local) {
    if (!decoder || !url || !isfinite(position) || position < 0 || decoder->source) return AVERROR(EINVAL);
    if (local) {
        struct stat info;
        if (*url != '/' || stat(url, &info) || !S_ISREG(info.st_mode)) return AVERROR(EINVAL);
        decoder->local_path = av_strdup(url);
        if (!decoder->local_path) return AVERROR(ENOMEM);
    } else if (strncasecmp(url, "http://", 7) && strncasecmp(url, "https://", 8)) return AVERROR(EINVAL);
    pthread_once(&riff_network_once, riff_network_initialize);
    atomic_store(&decoder->deadline, av_gettime_relative() + 20000000);
    if (stream_interrupted(decoder)) return AVERROR_EXIT;
    decoder->requested_position = position;
    decoder->read_position = position;
    decoder->source = avformat_alloc_context();
    if (!decoder->source) return AVERROR(ENOMEM);
    decoder->source->interrupt_callback = (AVIOInterruptCB){ stream_interrupted, decoder };
    decoder->source->opaque = decoder;
    decoder->source->io_open = stream_io_open;
    decoder->headers = av_strdup(headers ? headers : "");
    if (!decoder->headers) return AVERROR(ENOMEM);
    av_url_split(decoder->initial_scheme, sizeof(decoder->initial_scheme), NULL, 0, decoder->initial_host, sizeof(decoder->initial_host), &decoder->initial_port, NULL, 0, url);
    if (decoder->initial_port < 0) decoder->initial_port = !strcasecmp(decoder->initial_scheme, "https") ? 443 : 80;
    AVDictionary *options = NULL;
    av_dict_set(&options, "protocol_whitelist", local ? "file" : "http,https,tcp,tls,crypto,data", 0);
    if (local) av_dict_set(&options, "format_whitelist", "mov,mp3,ogg,flac,wav,aac,aiff,matroska,webm,ape,wv,tta,mpc,mpc8,dsf,dsdiff,asf", 0);
    av_dict_set(&options, "tls_verify", "1", 0);
    av_dict_set(&options, "http_persistent", "0", 0);
    av_dict_set(&options, "rw_timeout", "20000000", 0);
    av_dict_set(&options, "user_agent", "Riff/0.7.5 (iOS)", 0);
    if (headers && *headers) av_dict_set(&options, "headers", headers, 0);
    int result = avformat_open_input(&decoder->source, url, NULL, &options);
    av_dict_free(&options);
    if (result < 0) return stream_error(decoder, result, "Open audio stream", error, error_size);
    if ((result = avformat_find_stream_info(decoder->source, NULL)) < 0) return stream_error(decoder, result, "Read stream information", error, error_size);
    result = av_find_best_stream(decoder->source, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (result < 0) return stream_error(decoder, result, "Find stream audio", error, error_size);
    decoder->stream_index = result;
    AVStream *stream = decoder->source->streams[result];
    decoder->origin = stream->start_time != AV_NOPTS_VALUE ? stream->start_time * av_q2d(stream->time_base) :
                      (decoder->source->start_time != AV_NOPTS_VALUE ? decoder->source->start_time / (double)AV_TIME_BASE : 0);
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) return stream_error(decoder, AVERROR_DECODER_NOT_FOUND, "Decode stream format", error, error_size);
    decoder->codec = avcodec_alloc_context3(codec);
    decoder->packet = av_packet_alloc();
    decoder->frame = av_frame_alloc();
    decoder->fifo = av_audio_fifo_alloc(AV_SAMPLE_FMT_FLTP, 2, 1);
    if (!decoder->codec || !decoder->packet || !decoder->frame || !decoder->fifo) return AVERROR(ENOMEM);
    if ((result = avcodec_parameters_to_context(decoder->codec, stream->codecpar)) < 0 ||
        (result = avcodec_open2(decoder->codec, codec, NULL)) < 0) return stream_error(decoder, result, "Initialize stream decoder", error, error_size);
    if (duration) *duration = decoder->source->duration > 0 ? decoder->source->duration / (double)AV_TIME_BASE : 0;
    if (position > 0) {
        double requested_timestamp = (position + decoder->origin) / av_q2d(stream->time_base);
        if (!isfinite(requested_timestamp) || requested_timestamp >= INT64_MAX || requested_timestamp <= INT64_MIN) return AVERROR(EINVAL);
        int64_t timestamp = (int64_t)requested_timestamp;
        result = avformat_seek_file(decoder->source, decoder->stream_index, INT64_MIN, timestamp, timestamp, AVSEEK_FLAG_BACKWARD);
        if (result < 0) return stream_error(decoder, result, "Seek audio stream", error, error_size);
        avcodec_flush_buffers(decoder->codec);
    }
    return 0;
}
int riff_decoder_open(RiffStreamDecoder *decoder, const char *url, const char *headers,
                      double position, double *duration, char *error, size_t error_size) {
    return decoder_open(decoder, url, headers, position, duration, error, error_size, false);
}
int riff_decoder_open_file(RiffStreamDecoder *decoder, const char *path,
                           double position, double *duration, char *error, size_t error_size) {
    return decoder_open(decoder, path, NULL, position, duration, error, error_size, true);
}
const char *riff_decoder_metadata(RiffStreamDecoder *decoder, const char *key) {
    if (!decoder || !decoder->source || !key) return NULL;
    AVDictionaryEntry *entry = av_dict_get(decoder->source->metadata, key, NULL, 0);
    if (!entry && decoder->stream_index >= 0 && decoder->stream_index < decoder->source->nb_streams)
        entry = av_dict_get(decoder->source->streams[decoder->stream_index]->metadata, key, NULL, 0);
    return entry ? entry->value : NULL;
}
const unsigned char *riff_decoder_artwork(RiffStreamDecoder *decoder, size_t *size) {
    if (size) *size = 0;
    if (!decoder || !decoder->source || !size) return NULL;
    for (unsigned i = 0; i < decoder->source->nb_streams; ++i) {
        AVStream *stream = decoder->source->streams[i];
        if ((stream->disposition & AV_DISPOSITION_ATTACHED_PIC) && stream->attached_pic.size > 0 && stream->attached_pic.size <= 8 * 1024 * 1024) {
            *size = stream->attached_pic.size;
            return stream->attached_pic.data;
        }
    }
    return NULL;
}
static int stream_converted(RiffStreamDecoder *decoder, AVFrame *input) {
    int result;
    if (!decoder->swr) {
        if (!input) return 0;
        AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
        result = swr_alloc_set_opts2(&decoder->swr, &stereo, AV_SAMPLE_FMT_FLTP, 48000,
                                    &input->ch_layout, input->format, input->sample_rate, 0, NULL);
        if (result < 0 || (result = swr_init(decoder->swr)) < 0) return result;
    }
    if (!decoder->timeline_ready && input) {
        AVStream *stream = decoder->source->streams[decoder->stream_index];
        double first = input->best_effort_timestamp != AV_NOPTS_VALUE ? input->best_effort_timestamp * av_q2d(stream->time_base) - decoder->origin : decoder->requested_position;
        decoder->skip_remaining = (int64_t)llround(fmax(0, decoder->requested_position - first) * 48000);
        decoder->read_position = fmax(decoder->requested_position, first);
        decoder->timeline_ready = true;
    }
    int capacity = swr_get_out_samples(decoder->swr, input ? input->nb_samples : 0);
    if (capacity <= 0) return capacity;
    uint8_t **audio = NULL;
    result = av_samples_alloc_array_and_samples(&audio, NULL, 2, capacity, AV_SAMPLE_FMT_FLTP, 0);
    if (result < 0) return result;
    int count = swr_convert(decoder->swr, audio, capacity, input ? (const uint8_t **)input->extended_data : NULL, input ? input->nb_samples : 0);
    if (count < 0) result = count;
    else {
        int skip = decoder->skip_remaining < count ? (int)decoder->skip_remaining : count;
        decoder->skip_remaining -= skip;
        count -= skip;
        void *planes[] = { ((float *)audio[0]) + skip, ((float *)audio[1]) + skip };
        result = 0;
        if (count > 0) {
            result = av_audio_fifo_realloc(decoder->fifo, av_audio_fifo_size(decoder->fifo) + count);
            if (result >= 0 && av_audio_fifo_write(decoder->fifo, planes, count) != count) result = AVERROR(EIO);
        }
    }
    av_freep(&audio[0]);
    av_freep(&audio);
    return result;
}
int riff_decoder_read(RiffStreamDecoder *decoder, float *left, float *right, int capacity,
                      double *position, char *error, size_t error_size) {
    if (!decoder || !decoder->codec || !left || !right || capacity < 1 || capacity > 16384) return AVERROR(EINVAL);
    atomic_store(&decoder->deadline, av_gettime_relative() + 20000000);
    int result = 0;
    while (!decoder->decoded_eof && av_audio_fifo_size(decoder->fifo) < capacity) {
        if (stream_interrupted(decoder)) { result = AVERROR_EXIT; break; }
        result = avcodec_receive_frame(decoder->codec, decoder->frame);
        if (result >= 0) {
            result = stream_converted(decoder, decoder->frame);
            av_frame_unref(decoder->frame);
            if (result < 0) break;
            continue;
        }
        if (result == AVERROR_EOF) {
            result = stream_converted(decoder, NULL);
            decoder->decoded_eof = true;
            break;
        }
        if (result != AVERROR(EAGAIN)) break;
        if (decoder->demux_eof) {
            if (decoder->drain_sent) { result = AVERROR_INVALIDDATA; break; }
            decoder->drain_sent = true;
            result = avcodec_send_packet(decoder->codec, NULL);
            if (result < 0 && result != AVERROR_EOF) break;
            continue;
        }
        do {
            result = av_read_frame(decoder->source, decoder->packet);
            if (result < 0 || decoder->packet->stream_index == decoder->stream_index) break;
            av_packet_unref(decoder->packet);
        } while (!stream_interrupted(decoder));
        if (result == AVERROR_EOF) { decoder->demux_eof = true; result = 0; continue; }
        if (result < 0) break;
        result = avcodec_send_packet(decoder->codec, decoder->packet);
        av_packet_unref(decoder->packet);
        if (result < 0) break;
    }
    if (result < 0) return stream_error(decoder, result, "Read audio stream", error, error_size);
    int count = av_audio_fifo_size(decoder->fifo);
    if (count > capacity) count = capacity;
    if (position) *position = decoder->read_position;
    if (count) {
        void *planes[] = { left, right };
        if (av_audio_fifo_read(decoder->fifo, planes, count) != count) return AVERROR(EIO);
        decoder->read_position += count / 48000.0;
    }
    return count;
}
