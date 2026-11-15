# Native audio dependencies

Work in progress: these libraries are not yet integrated into the Riff app.
This is a reproducible, in-process codec build; no companion service or child
process is required on iPhone. FFmpeg is configured for audio demuxing/decoding,
MP3 (LAME), FLAC, AAC/M4A and Opus encoding, HLS and HTTPS (Secure Transport).
Network callers must explicitly enable TLS certificate verification at runtime.

Pinned sources, verified by SHA-256 in `build.sh`:

- FFmpeg n8.0.1: https://github.com/FFmpeg/FFmpeg/tree/n8.0.1
- LAME 3.100: https://github.com/lameproject/lame/tree/1f5cc9487284d5950343aa5d4f70de433468070a
- Opus 1.5.2: https://github.com/xiph/opus/tree/v1.5.2

Run `native-codecs/build.sh host` and `native-codecs/smoke.sh` on an Apple Silicon
Mac to test real conversions. `native-codecs/build.sh` creates an arm64 device and
arm64 simulator XCFramework with public FFmpeg headers. Link Security,
AudioToolbox, CoreFoundation, z, bz2 and iconv as required by the FFmpeg config.
The workflow retains build logs, exact FFmpeg configuration and license texts.
The full application source and pinned dependency build inputs must remain
available to allow relinking modified LGPL components when distributing Riff.
No GPL or nonfree FFmpeg configuration is enabled.

The next integration step is a cancellation-aware C bridge, decoding/playback
through the existing native effects graph, and native unit/device validation.
Host command-line binaries exist only for build validation and are never shipped
or executed in the iPhone app.
