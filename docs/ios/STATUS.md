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
- YouTube/SoundCloud search, URL resolution and AVPlayer streaming.
- Direct HTTP downloads with decode validation and offline library persistence.
- Native AVAssetDownloadURLSession HLS downloads, preserving system-managed asset locations.
- Offline HLS playback through AVPlayer. Needs real-device verification.
- Queue advancement, shuffle/repeat, seeking, transport commands and lock-screen metadata.
- LRCLIB lookup, synchronized LRC parser/import, timing offset and lyric-line seeking.
- Cancellation/stale-result handling for search, playback and lyrics import.
- Corrupt manifests are preserved and writes are refused until recovery.

## Evidence obtained

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

1. Validate latest CI and inspect UI screenshots; fix any failures.
2. Verify live YouTube/SoundCloud search, streaming and downloads through the
   native runtime, including JavaScript challenge solving and HLS persistence.
3. Persist/manage playlists, editable queues, history/favorites, and playlist
   migration (Spotify/Apple/Deezer/YouTube/SoundCloud and other desktop providers).
4. Port the audio engineering suite: 10/3-band EQ, rate/pitch, reverb/distortion,
   visualizers, region/trim editor, non-destructive exports and format conversion.
5. Add local metadata/artwork/LRC indexing, library removal, account/library
   import/export, download progress/recovery and duplicate handling.
6. Add native interruption/route handling, background download relaunch recovery,
   Now Playing artwork, system volume/AirPlay and accessible adaptive layouts.
7. Preserve themes/customization, plugin functionality in an iOS-compatible
   runtime, lyrics translation/karaoke, albums/artists and discovery features.
8. Provider account OAuth/Keychain flows and all remaining bridge/API functions
   inventoried in `desktop-contract.json` (95 bridge members, 72 API routes).
9. Real-device acceptance and reproducible sideloadable IPA with no feature
   placeholders. Keep the PR draft until the required features are validated.

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
