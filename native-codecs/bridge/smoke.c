#include "RiffCodecs.h"
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    if (argc != 4) return 2;
    RiffConversion *job = riff_conversion_create();
    if (!job) return 3;
    if (getenv("RIFF_CODEC_CANCEL")) riff_conversion_cancel(job);
    char error[512] = {0};
    int result = riff_conversion_run(job, argv[1], argv[2], argv[3], 192000,
                                     "Codec Test Song", "Riff", "Codec Tests", error, sizeof(error));
    if (result < 0) fprintf(stderr, "%s\n", error);
    if (result >= 0 && riff_conversion_progress(job) != 1) result = -1;
    riff_conversion_destroy(job);
    return result < 0 ? 1 : 0;
}
