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
#ifdef __cplusplus
}
#endif
#endif
