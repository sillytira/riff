# Standalone iPhone port — active implementation

This is not a feature-complete Riff release. Keep the goal active; the user wants
all music features and downloads to work standalone. Discord RPC is explicitly
excluded. The user authorized GitHub Pro macOS Actions and chose unsigned IPA
installation using AltStore/SideStore. No Apple signing credentials are needed
for the selected artifact; device installation still requires sideload signing.

Desktop baseline: ac68b13b1ee444c4b1ebd506f77da9bd1d83217a (0.7.5).
Development branch: `ios/liquid-glass` in `sillytira/riff`.
Draft PR: https://github.com/sillytira/riff/pull/1

## Implemented in source

- Native SwiftUI library, provider search, download queue, full player and mini-player.
- Native iOS 26 glass tab accessory and system navigation; iOS 18 material fallback.
- Files audio import, sandbox copies, atomic library storage, restored identities.
- Embedded CPython 3.13 and yt-dlp 2026.10.26; no companion server or subprocess.
- In-process Apple JavaScriptCore challenge provider for yt-dlp EJS.
- YouTube/YouTube Music/SoundCloud search, URL resolution and AVPlayer streaming.
- Direct HTTP downloads with decode validation and offline library persistence.
- Native AVAssetDownloadURLSession HLS downloads, preserving system-managed asset locations.
- Offline HLS playback through AVPlayer. Needs real-device verification.
- Editable mixed local/online playback queues, persistent editable playlists,
  shuffle/repeat, seeking, transport commands and lock-screen metadata.
- Native local AVAudioEngine playback with 10-band and grouped 3-band EQ,
  independent rate/pitch, reverb, distortion, presets and persisted settings.
- Waveform selection editor with non-destructive WAV exports and sharing.
- System AirPlay route picker, call interruption/headphone-removal handling,
  and the original Riff app icon.
- LRCLIB lookup, synchronized LRC parser/import, timing offset and lyric-line seeking.
- Cancellation/stale-result handling for search, playback and lyrics import.
- Corrupt manifests are preserved and writes are refused until recovery.

## Evidence obtained

Latest fully passing native build: https://github.com/sillytira/riff/actions/runs/43622835731
18 native tests and 2 UI tests passed, plus simulator/device builds and IPA packaging.
Earlier run 43621684813 passed 16 native tests and 2 UI tests, including actual
DSP output (EQ gain, independent pitch/rate and sample-exact trimming).
Native player advancement, pause/resume/seeking and settings restoration passed
in run 43622835731. UI tests verified playlist creation, rename and relaunch
persistence. iPhone 17 Pro screenshots were downloaded and visually inspected.
An empty glass-accessory surface was found and fixed. A subsequent structural
state-reset issue was fixed using the iOS 26.1 `isEnabled` accessory API with
version-gated, stable-identity fallbacks for iOS 26.0/18.

**Current pending validation:** run 43624155553 at e0a604c, which adds an end-to-end
UI test for search -> stream playback -> direct download -> offline local playback
-> waveform editor -> saved edit -> relaunch persistence. It also validates the
new YouTube Music parser and detailed stream artwork enrichment. Do not assume
this run passed; inspect its actual result next.

**Live providers:** macOS run https://github.com/sillytira/riff/actions/runs/43622202851
failed overall because YouTube search returned 15 results but resolving three
videos returned a sign-in/bot challenge. SoundCloud passed search, resolution,
HLS manifest and 65,536 bytes of real media access. This is a real unresolved
provider gate. Do not hide the failure or substitute a companion proxy.
The smoke workflow/script now live in the main iOS branch too and can be
manually dispatched with that ref. Host checks use Node; native iOS uses JSC.

The user was optionally asked to sideload the development IPA from run
43621684813 and report iPhone/iOS version and actual YouTube/SoundCloud behavior.
That question does not block independent implementation. Never ask the user to
send private cookies or passwords through chat; implement local account handling.


- Run 43618396616 passed simulator/device builds, IPA packaging and 7 native tests.
  These include embedded Python, OpenSSL, yt-dlp and JavaScriptCore execution.
- Run 43618590472 passed simulator/device builds, IPA packaging and 8 native tests.
  Added end-to-end HTTP extraction -> download -> decoder validation -> persistent
  offline library restore, using a local WAV server on the macOS runner.
- Five Python protocol tests passed locally, including real JSON contracts and
  refusal of non-HTTP URL schemes without disabling TLS verification.
- Live SoundCloud search and stream resolution passed in the Linux workspace.
  The resolved format was HLS m4a, motivating native HLS downloading.
- Linux YouTube requests were refused by the environment proxy. YouTube's live
  playback and EJS integration still need validation from the Mac/iPhone path.
- Latest queue/lyrics/HLS/UI revisions are under CI validation. Read the actual
  latest run before claiming those tests passed. UI navigation screenshots are
  exported from the XCTest result bundle by the current workflow.
- Physical-device playback, background lifecycle, route/interruption handling,
  HLS downloading and visual behavior have not yet been verified.

## Remaining feature gates

1. Validate current CI and inspect playback/editor screenshots; fix failures.
2. Add native YouTube sign-in/cookie handling with Keychain storage and temporary
   yt-dlp cookie files. Real YouTube/JSC and physical-device HLS verification remain
   required; hosted runners encountered a YouTube sign-in challenge.
3. Add MP3/FLAC/M4A/Opus conversion/export, missing decoders such as OGG, and full
   streaming DSP. Current full DSP applies to direct local files; streaming and
   HLS currently support playback speed. WAV is the current effects export format.
   Prefer a current in-process codec build; do not introduce a companion server.
4. Finish Spotify/Apple/Deezer/etc. playlist migration and account library flows.
   Current public import delegates to yt-dlp, which does not cover every original
   metadata-only provider. Do not claim those providers work yet.
5. Add local tag/artwork/album indexing, persistent artwork and local/synchronized
   lyrics caching, history/favorites, library removal, account/library backup and
   restore, download progress/recovery and duplicate handling.
6. Complete interruption/route/background download relaunch recovery and Now
   Playing artwork; verify all on a physical device. Current lifecycle handling
   compiles and has service tests, but phone-call/background behavior is unverified.
7. Preserve themes/customization, iOS-compatible plugin functionality, lyrics
   translation/karaoke, visualizers, albums/artists and discovery features.
8. Reconcile remaining bridge/API functions in `desktop-contract.json` (95 bridge
   members, 72 API routes), including OAuth/Keychain flows and preferences.
9. Real-device acceptance and reproducible sideloadable IPA with no feature
   placeholders. Keep the PR draft until all required gates are validated.

Desktop tray/global shortcuts/windows/update binaries need applicable iOS
representations. Unrestricted desktop child processes cannot run unchanged on
iOS. Discord RPC is excluded; no other feature omission was approved.

## Build and test

`ios/scripts/prepare-python.sh` downloads the checksum-pinned Python XCFramework
and pinned yt-dlp/EJS/certifi packages. `ios/scripts/build-unsigned.sh` generates
an Xcode project, compiles for device and packages `ios/build/Riff-unsigned.ipa`.
Run the `iOS build` workflow for simulator/unit/UI validation and IPA artifacts.
The workflow launches the WAV fixture server needed by the end-to-end native test.

Desktop runtime files remain unchanged. Baseline `node --test`: 56 tests,
47 passed and 9 pre-existing failures (lyrics/search exports, search assertions,
Spotify OAuth URL handling). These failures have not been represented as passes.
