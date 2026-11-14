# Standalone iPhone port — implementation status

This is an incomplete native port, not a feature-complete Riff release.
Desktop baseline: ac68b13b1ee444c4b1ebd506f77da9bd1d83217a (0.7.5).

## Requirements

- Standalone iPhone execution; no companion server.
- Native iOS 26 Liquid Glass with material fallback on iOS 18/19.
- Unsigned device IPA for AltStore/SideStore signing.
- Preserve desktop source and MIT attribution.

## Native foundation

Implemented: Files audio import with sandbox copies and decoder validation; atomic
library manifest; restored stable track identities; local search; playback,
pause/resume, next and automatic advance; native Liquid Glass player surface;
Reduce Transparency support. Compilation and execution must be checked in Actions.
Background audio entitlement is configured, but interruptions, routes, lock-screen
commands, seeking, artwork and metadata are not implemented yet. AVAudioPlayer
format support is not equivalent to all formats supported by desktop ffmpeg.

## Feature parity gates (all required before claiming parity)

| Capability | Desktop implementation | iOS work remaining |
| --- | --- | --- |
| YouTube/YouTube Music/SoundCloud | server.js + yt-dlp subprocess | Native extraction/network implementation or embedded, iOS-compatible interpreter; auth and live provider tests |
| Spotify/Apple/Deezer/etc. playlist imports | server.js provider handlers | Port pagination, matching, auth and persistence |
| Offline downloads, tagging, conversion | yt-dlp + ffmpeg executables | In-process iOS codec/mux/tag libraries, downloads and background lifecycle |
| Trim/region editor | server encode endpoints + renderer | Native editor plus in-process encoding/export |
| EQ and DSP | audio.js, Web Audio, Tone | Native audio graph, pitch/rate/reverb/distortion, audio quality verification |
| Lyrics, translation, karaoke | server.js + renderer | Port providers, LRC/YRC parsing, timing, offsets and views |
| Themes/custom CSS | Electron IPC + renderer CSS | Retain web-rendered customization or define an equivalent native theme system |
| Plugins | Electron filesystem + unrestricted JS | Design compatible sandbox; unrestricted Node/system-process plugins cannot execute unchanged on iOS |
| Discord Rich Presence | discord-rpc local desktop IPC | Desktop IPC cannot execute unchanged on iPhone; no equivalent implemented |
| Local library/playlists/history | renderer storage + desktop filesystem | Metadata/artwork, playlists, queue editing, history, imports/exports, folder access |
| Visualizers/fullscreen/mini-player | WebGL + Electron windows | Native visualization, karaoke/fullscreen, supported mobile presentation |
| Google/YouTube/Spotify accounts | Electron auth + server | iOS OAuth, callback registration and Keychain storage |
| Desktop integration | tray, global shortcuts, launcher, updater | Map applicable controls to iOS; desktop tray/windows cannot be retained literally |

## Baseline verification

Before any desktop source changes, `node --test` reported 56 tests: 47 passed,
9 failed. Failures cover missing exported lyrics/search helpers, search cleanup
assertions and Spotify OAuth URL handling. These are pre-existing baseline failures;
no desktop runtime code has been changed by the iOS foundation.

## Build

The `iOS build` GitHub workflow compiles simulator code, runs native unit tests,
and packages an unsigned arm64 device application as `Riff-unsigned.ipa`.
An unsigned IPA must be signed by AltStore/SideStore before installation.
A passing compilation alone does not establish feature parity or real-device
playback/background correctness. Do not label this foundation a finished product.
