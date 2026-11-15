#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
RIFF_FFMPEG="$PWD/native-codecs/build/macosx/install/bin/ffmpeg"
RIFF_FFPROBE="$PWD/native-codecs/build/macosx/install/bin/ffprobe"
RIFF_TEST_OUTPUT="$PWD/native-codecs/build/smoke"
mkdir -p "$RIFF_TEST_OUTPUT"
# Convert actual audio through every promised output codec, then decode it again.
for RIFF_FORMAT in mp3 flac m4a opus; do
  rm -f "$RIFF_TEST_OUTPUT/tone.$RIFF_FORMAT"
  "$PWD/native-codecs/build/macosx/convert-smoke" ios/RiffTests/Fixtures/ui-tone.wav "$RIFF_TEST_OUTPUT/tone.$RIFF_FORMAT" "$RIFF_FORMAT"
  "$RIFF_FFMPEG" -v error -y -i "$RIFF_TEST_OUTPUT/tone.$RIFF_FORMAT" -c:a pcm_s16le "$RIFF_TEST_OUTPUT/$RIFF_FORMAT.wav"
  "$RIFF_FFPROBE" -v error -show_entries format=duration:format_tags=title,artist,album:stream_tags=title,artist,album -of json "$RIFF_TEST_OUTPUT/tone.$RIFF_FORMAT" > "$RIFF_TEST_OUTPUT/$RIFF_FORMAT.json"
  # Never overwrite an existing file, including a previous conversion.
  RIFF_EXISTING_HASH="$(shasum -a 256 "$RIFF_TEST_OUTPUT/tone.$RIFF_FORMAT")"
  if "$PWD/native-codecs/build/macosx/convert-smoke" ios/RiffTests/Fixtures/ui-tone.wav "$RIFF_TEST_OUTPUT/tone.$RIFF_FORMAT" "$RIFF_FORMAT"; then exit 1; fi
  test "$RIFF_EXISTING_HASH" = "$(shasum -a 256 "$RIFF_TEST_OUTPUT/tone.$RIFF_FORMAT")"
done
python3 - <<'PY'
from pathlib import Path
import json, math, struct, wave
for file in Path('native-codecs/build/smoke').glob('*.wav'):
    with wave.open(str(file)) as audio:
        assert 1.9 < audio.getnframes() / audio.getframerate() < 2.2, file
        samples = struct.unpack('<' + 'h' * (audio.getnframes() * audio.getnchannels()), audio.readframes(audio.getnframes()))
        rms = math.sqrt(sum(x*x for x in samples) / len(samples))
        assert rms > 100, (file, rms)
        print(file.name, 'decoded audible audio; RMS', round(rms))
with wave.open('ios/RiffTests/Fixtures/ui-tone.wav') as original, wave.open('native-codecs/build/smoke/flac.wav') as restored:
    assert original.getframerate() == restored.getframerate()
    assert original.getnchannels() == restored.getnchannels()
    assert original.readframes(original.getnframes()) == restored.readframes(restored.getnframes()), 'FLAC must preserve original PCM samples'
for file in Path('native-codecs/build/smoke').glob('*.json'):
    data = json.loads(file.read_text())
    tags = dict(data.get('format', {}).get('tags', {}))
    for stream in data.get('streams', []): tags.update(stream.get('tags', {}))
    tags = {key.lower(): value for key, value in tags.items()}
    assert tags.get('title') == 'Codec Test Song', (file, tags)
    assert tags.get('artist') == 'Riff', (file, tags)
    assert tags.get('album') == 'Codec Tests', (file, tags)
PY

rm -f "$RIFF_TEST_OUTPUT/cancelled.mp3"
if RIFF_CODEC_CANCEL=1 "$PWD/native-codecs/build/macosx/convert-smoke" ios/RiffTests/Fixtures/ui-tone.wav "$RIFF_TEST_OUTPUT/cancelled.mp3" mp3; then exit 1; fi
test ! -e "$RIFF_TEST_OUTPUT/cancelled.mp3"
