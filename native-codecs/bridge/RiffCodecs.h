#ifndef RIFF_CODECS_H
#define RIFF_CODECS_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct RiffConversion RiffConversion;
RiffConversion *riff_conversion_create(void);
/* Run once on a worker executor. Cancellation/progress may be called concurrently.
   Input/output must be distinct local paths. Output must not already exist.
   format: wav (float PCM), mp3, flac, m4a or opus. bitrate is bits/sec for lossy encoders. */
int riff_conversion_run(RiffConversion *, const char *input, const char *output,
                        const char *format, int bitrate, const char *title,
                        const char *artist, const char *album, char *error, size_t error_size);
void riff_conversion_cancel(RiffConversion *);
double riff_conversion_progress(const RiffConversion *);
/* Destroy only after run and all concurrent progress/cancel calls have ended. */
void riff_conversion_destroy(RiffConversion *);
const char *riff_codecs_version(void);

/* Cancellation may run concurrently. All other decoder calls must be serialized.
   Output is planar Float32 stereo at 48 kHz. Read returns frames, zero at EOF,
   or a negative error. An opened decoder is single-use; seek opens a new one. */
typedef struct RiffStreamDecoder RiffStreamDecoder;
RiffStreamDecoder *riff_decoder_create(void);
int riff_decoder_open(RiffStreamDecoder *, const char *url, const char *headers,
                      double position, double *duration, char *error, size_t error_size);
int riff_decoder_read(RiffStreamDecoder *, float *left, float *right, int capacity,
                      double *position, char *error, size_t error_size);
void riff_decoder_cancel(RiffStreamDecoder *);
void riff_decoder_destroy(RiffStreamDecoder *);
#ifdef __cplusplus
}
#endif
#endif
