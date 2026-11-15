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
- Persistent Favorites and Recently Played for local/online songs, with favorites
  accessible from Library, song menus and the player navigation bar (pending CI).
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
- LRCLIB lookup, synchronized LRC parser/import, per-song timing offset and lyric-line seeking.
- Manual lyric search, cleaned YouTube titles, remix-aware recording matching,
  persistent lyrics/offsets and offline restoration.
- Local tag/title/artist/album/artwork indexing; durable downsampled artwork cache.
- YouTube sign-in browser and Netscape cookie import with Keychain persistence;
  extractor jars are disposable and protected. Real Google account sign-in is untested.
- Cancellation/stale-result handling for search, playback and lyrics import.
- Corrupt manifests are preserved and writes are refused until recovery.

## Evidence obtained

Latest fully passing native build: https://github.com/sillytira/riff/actions/runs/43627166211
This built the simulator/device app and IPA, passed native and UI tests, and
includes YouTube cookie import/sign-in controls, Keychain storage, embedded tag
and cover indexing, and persistent artwork. Run 43624155553 also passed its
search -> stream -> download -> offline playback -> editor -> saved edit ->
relaunch UI flow. Earlier runs validated DSP output (EQ, independent pitch/rate,
sample-exact trimming), queue navigation and persistent playlists/effect settings.

The user sideloaded run 43621684813 and confirmed music works, but reported
missing covers. Their screenshots show a mashup playing with a placeholder and
no matching lyrics. New source adds legacy YouTube/SoundCloud cover recovery,
lock-screen artwork, manual lyric search, remix-aware matching, offline lyrics
and per-song timing offsets. Embedded and local artwork tests passed. Subsequent
runs failed a remote-cover test; the most recent failure was a Swift isolation
trap in the lock-screen artwork callback, identified from the crash report.
Commit f180497 explicitly makes system callbacks Sendable. Run 43669795963
passed all 28 native tests and four of five UI tests, including downloading a
tagged audio file and showing its embedded cover in both Library and Now Playing.
Those screenshots were downloaded and visually inspected. The remaining UI flow
failed during streaming/edit persistence. Test fixtures now serve HTTP byte ranges,
use a sustained AAC clip and pause before editing. The editor now keeps its chosen
track when the playback queue advances. These fixes await the next full run.

**Live providers:** macOS run https://github.com/sillytira/riff/actions/runs/43622202851
failed overall because YouTube search returned 15 results but resolving three
videos returned a sign-in/bot challenge. SoundCloud passed search, resolution,
HLS manifest and 65,536 bytes of real media access. This is a real unresolved
provider gate. Do not hide the failure or substitute a companion proxy.
The smoke workflow/script now live in the main iOS branch too and can be
manually dispatched with that ref. Host checks use Node; native iOS uses JSC.

The user was optionally asked to sideload the development IPA from run
43621684813 and report iPhone/iOS version and actual YouTube/SoundCloud behavior.
The user replied that music works but covers were missing. This does not block independent implementation. Never ask the user to
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
- The user confirmed physical-device music playback. Background lifecycle,
  route/interruption handling, HLS downloading and updated artwork still need
  explicit device verification.

## Remaining feature gates

1. Validate current CI and inspect playback/editor screenshots; fix failures.
2. Validate native YouTube sign-in/cookie handling. Real YouTube/JSC and physical-device HLS verification remain
   required; hosted runners encountered a YouTube sign-in challenge.
3. Add MP3/FLAC/M4A/Opus conversion/export, missing decoders such as OGG, and full
   streaming DSP. Current full DSP applies to direct local files; streaming and
   HLS currently support playback speed. WAV is the current effects export format.
   Prefer a current in-process codec build; do not introduce a companion server.
4. Finish Spotify/Apple/Deezer/etc. playlist migration and account library flows.
   Current public import delegates to yt-dlp, which does not cover every original
   metadata-only provider. Do not claim those providers work yet.
5. Validate history/favorites, then finish library removal, account/library backup and
   restore, download progress/recovery and duplicate handling.
6. Complete interruption/route/background download relaunch recovery and verify
   Now Playing artwork on a physical device. Current lifecycle handling
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

## Codec dependency work

An isolated branch `codec/native` builds checksum-pinned FFmpeg 8.0.1, LAME and
Opus for Apple Silicon host, iPhone and simulator. It includes a cancellation-aware
C conversion API, MP3/FLAC/M4A/Opus conversion checks, metadata retention checks and
FLAC sample equality checks. Run 43671363635 passed host conversion, metadata, lossless-sample equality,
existing-file preservation and cancellation checks, then built the iPhone and
simulator libraries. It is not linked into the app yet. The app still exports WAV only. Do not mark the format
conversion or streaming DSP gates complete.
