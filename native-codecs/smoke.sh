#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RIFF_FFMPEG="$PWD/native-codecs/build/macosx/install/bin/ffmpeg"
RIFF_FFPROBE="$PWD/native-codecs/build/macosx/install/bin/ffprobe"
RIFF_TEST_OUTPUT="$PWD/native-codecs/build/smoke"
mkdir -p "$RIFF_TEST_OUTPUT"
# Convert actual audio through every promised output codec, then decode it again.
for RIFF_FORMAT in mp3 flac m4a opus; do
  case "$RIFF_FORMAT" in
    mp3) RIFF_ENCODER=libmp3lame ;;
    flac) RIFF_ENCODER=flac ;;
    m4a) RIFF_ENCODER=aac ;;
    opus) RIFF_ENCODER=libopus ;;
  esac
  "$RIFF_FFMPEG" -v error -y -i ios/RiffTests/Fixtures/ui-tone.wav -c:a "$RIFF_ENCODER" "$RIFF_TEST_OUTPUT/tone.$RIFF_FORMAT"
  "$RIFF_FFMPEG" -v error -y -i "$RIFF_TEST_OUTPUT/tone.$RIFF_FORMAT" -c:a pcm_s16le "$RIFF_TEST_OUTPUT/$RIFF_FORMAT.wav"
  "$RIFF_FFPROBE" -v error -show_entries format=duration -of default=noprint_wrappers=1 "$RIFF_TEST_OUTPUT/tone.$RIFF_FORMAT"
done
python3 - <<'PY'
from pathlib import Path
import math, struct, wave
for file in Path('native-codecs/build/smoke').glob('*.wav'):
    with wave.open(str(file)) as audio:
        assert 1.9 < audio.getnframes() / audio.getframerate() < 2.2, file
        samples = struct.unpack('<' + 'h' * (audio.getnframes() * audio.getnchannels()), audio.readframes(audio.getnframes()))
        rms = math.sqrt(sum(x*x for x in samples) / len(samples))
        assert rms > 100, (file, rms)
        print(file.name, 'decoded audible audio; RMS', round(rms))
PY
