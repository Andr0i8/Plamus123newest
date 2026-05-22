# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Plamus is an offline-first, cross-platform music player built with Flutter (Android + Windows desktop). It features local library management, YouTube audio extraction (pure Dart), and a minimalist UI with glass morphism design.

## Development Commands

### Running the app
```bash
flutter run -d windows    # Desktop
flutter run -d android    # Android (connected device/emulator)
```

### Testing
```bash
flutter test
```

### Building
```bash
# Desktop
flutter build windows --release

# Android — split APKs for smaller size
flutter build apk --split-per-abi

# Android — App Bundle for Play Store
flutter build appbundle
```

### Code analysis
```bash
flutter analyze
```

### Dependency management
```bash
flutter pub get
flutter pub upgrade
```

## Architecture

### Audio Backend
- **Android/iOS**: `just_audio` with `just_audio_background` for background playback + media notifications
- **Windows/Linux**: `just_audio` with `media_kit` backend (`JustAudioMediaKit.ensureInitialized()`)
- After changing audio dependencies, perform a **full cold restart** (not hot reload)

### Database Layer
- SQLite via `sqflite` on mobile, `sqflite_common_ffi` on desktop
- Must initialize FFI in `main()` for desktop: `sqfliteFfiInit(); databaseFactory = databaseFactoryFfi;`
- Schema: `tracks`, `playlists`, `playlist_tracks`, `history`
- Database file: `plamus.db` in application support directory

### State Management
- Provider pattern for reactive state
- Three main providers:
  - `LibraryService`: tracks, playlists, SQLite coordination
  - `AudioPlayerService`: playback queue, shuffle, repeat, volume
  - `ThemeController`: light/dark theme toggle

### Media Download Pipeline (Android)
1. **YouTube URLs**: `DownloadService` runs the bundled `yt-dlp_musllinux_aarch64` binary
   shipped under `android/app/src/main/jniLibs/arm64-v8a/libytdlp.so`. The
   APK installer extracts it into `applicationInfo.nativeLibraryDir` at
   install time — Android 10+ (API 29) blocks `execve()` on app-data
   files, so this is the only directory we can launch executables from.
   - The binary's ELF interpreter is `/lib/ld-musl-aarch64.so.1`, which
     doesn't exist on Android. We work around that by also shipping the
     musl loader as `libldmusl.so` (extracted from Alpine's `musl`
     package) and exec'ing it with the yt-dlp path as its first
     argument: `Process.start(loader, [ytdlp, ...args])`.
   - `TMPDIR` is pinned to `applicationInfo.cacheDir` so PyInstaller's
     onefile bootstrap can self-extract; the OS default of `/tmp`
     doesn't exist on Android.
   - yt-dlp args: `--no-playlist -f bestaudio[ext=m4a]/bestaudio[ext=mp4]/bestaudio`.
     We don't ship ffmpeg (would cost ~25 MB / ABI), so we ask yt-dlp
     for an audio-only stream that `just_audio` can play natively
     (typically `.m4a`/AAC for YouTube).
2. **Direct audio URLs (iOS only)**: `AudioDownloadService` uses `http`
   package to stream-download. Android handles direct URLs via the
   yt-dlp pipeline above.
3. **Local files**: `MediaIngestService` copies audio files into library folder
4. **Registration**: `LibraryService.registerTrackFile()` indexes the file path in SQLite
5. Supported audio formats: MP3, WAV, FLAC, M4A, AAC, OGG, OPUS, WEBM, WMA

#### Updating the Android yt-dlp binary

The two Android JNI binaries are committed to the repo at
`android/app/src/main/jniLibs/arm64-v8a/`. They never need to change at
runtime (no first-run download), but ship-time updates are manual:

```bash
# 1. Refresh yt-dlp itself
curl -L -o android/app/src/main/jniLibs/arm64-v8a/libytdlp.so \
  https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_musllinux_aarch64

# 2. Refresh the musl loader (only needed if Alpine bumps musl ABI;
#    typically untouched for years)
curl -L -o /tmp/musl.apk \
  http://dl-cdn.alpinelinux.org/alpine/latest-stable/main/aarch64/musl-1.2.5-r23.apk
mkdir -p /tmp/musl_extract && tar -xzf /tmp/musl.apk -C /tmp/musl_extract
cp /tmp/musl_extract/lib/ld-musl-aarch64.so.1 \
   android/app/src/main/jniLibs/arm64-v8a/libldmusl.so
```

After replacing either file, run `flutter clean && flutter build apk
--debug` and reinstall on the device — `useLegacyPackaging = true` in
`app/build.gradle.kts` only re-extracts the .so files on a fresh
install, not on hot reload.

### Media Download Pipeline (Desktop)
1. **YouTube/URLs**: `DownloadService` runs bundled `yt-dlp.exe` (supports many sites beyond YouTube)
2. **Local files**: `MediaIngestService` copies audio or extracts from video via ffmpeg
3. **Binary Dependencies**: `BinaryService` extracts `yt-dlp.exe` and `ffmpeg.exe` from `assets/bin/`
   - **Only needed for desktop builds** — do NOT place large binaries when building Android
   - yt-dlp flags: `--no-playlist -x --audio-format mp3 --audio-quality 0`
   - ffmpeg flags: `-vn -codec:a libmp3lame -q:a 0` (VBR quality 0)

### UI Structure
- **Desktop**: `PlamusShell` — sidebar navigation + animated content + `GlassPlayerBar`
- **Mobile**: `PlamusShellMobile` — bottom navigation + `MobileMiniPlayer`
- Sections: Home (library), Search/Import, Liked Songs, History, Playlist Detail
- Theme: custom `PlamusTheme` with light/dark variants, glass morphism effects

### File Paths
- Library directory: platform equivalent of app support via `path_provider`
- Database: `plamus.db` in application support directory
- Binaries (desktop): `bin/yt-dlp.exe`, `ffmpeg.exe` in app support
- Binaries (Android): `applicationInfo.nativeLibraryDir/{libytdlp,libldmusl}.so`,
  populated automatically by the APK installer from
  `android/app/src/main/jniLibs/arm64-v8a/`. Reachable from Dart via the
  `com.plamus/native_paths` MethodChannel that `MainActivity.kt`
  registers — see `BinaryService` for the lookup.

## Key Services

### AudioDownloadService (iOS only)
- Server-backed YouTube extractor used on iOS, where Apple does not
  allow shipping an executable yt-dlp inside the IPA.
- Forwards YouTube URLs to the self-hosted Plamus extraction server
  (see `services/youtube_download_service.dart`); response carries
  audio file + `X-Track-{Title,Artist,Thumbnail}` headers.
- Also handles direct (non-YouTube) audio URLs via `http` streaming
  for iOS-only convenience.
- Android no longer routes through this service — it runs yt-dlp
  locally via `DownloadService` with a bundled binary.

### AudioPlayerService
- Wraps `just_audio` with queue management, repeat modes
- Repeat modes: off, all (loop queue), one (loop single track)
- Records play history to SQLite on track load
- Updates track duration in DB after first play if unknown

### LibraryService
- CRUD for tracks and playlists
- Smart lists: liked tracks, recent history (last 50 plays)
- Track operations: rename (updates file + DB), export, reveal in Explorer, delete
- Playlist operations: create, rename, delete, add/remove tracks

### DownloadService (Desktop + Android)
- Runs yt-dlp as child process with 45-minute timeout
- Parses `[download] X%` from stderr for progress UI
- Returns path to downloaded audio file in library directory
- Desktop output: `.mp3` (yt-dlp transcodes via ffmpeg)
- Android output: `.m4a` / `.mp4` / `.webm` (no ffmpeg, native stream)
- Android launch shape: `Process.start(libldmusl.so, [libytdlp.so, ...args],
  env: { TMPDIR=cacheDir })` — required to bypass Android's missing
  `/lib/ld-musl-aarch64.so.1` interpreter (see "Media Download Pipeline
  (Android)" above for the full story)

### MediaIngestService
- Copies audio files into library folder
- On desktop: can also extract audio from video via ffmpeg
- On mobile: audio files only (no video transcoding)
- Ensures unique filenames with `_1`, `_2` suffixes if collision

## Android Build Optimization
- **Bundled binaries**: `arm64-v8a` ships ~29 MB of native binaries
  (`libytdlp.so` + `libldmusl.so`) under `android/app/src/main/jniLibs/`.
  Other ABIs are unaffected — `armeabi-v7a` and `x86_64` carry no
  yt-dlp, so Plamus only supports YouTube downloads on arm64 phones.
- **Native libs are not stripped**: `packaging.jniLibs.keepDebugSymbols`
  in `app/build.gradle.kts` opts `libytdlp.so` / `libldmusl.so` out of
  the default release-mode strip pass. The yt-dlp PyInstaller bundle
  appends an opaque archive after the ELF sections; running `objcopy`
  on it would corrupt the embedded payload.
- **Native libs are extracted to disk**:
  `packaging.jniLibs.useLegacyPackaging = true` ensures the APK
  installer extracts the .so files to `nativeLibraryDir` instead of
  mmap'ing them out of the compressed APK. Mmap mode breaks
  `Process.start()` because the kernel can only `execve()` real
  filesystem entries.
- **Split APKs**: `build.gradle.kts` configured for per-ABI splits (arm64-v8a, armeabi-v7a)
- **R8 shrinking**: `isMinifyEnabled = true` + `isShrinkResources = true` in release builds
- **ProGuard rules**: `android/app/proguard-rules.pro` preserves Flutter + audio service classes
- **Asset exclusion**: `androidResources.ignoreAssetsPatterns` excludes `.exe` and `yt-dlp_*` files
- **Build commands**:
  - `flutter build apk --split-per-abi` — split APKs for direct distribution
  - `flutter build appbundle` — App Bundle for Play Store (automatic per-device optimization)

## Common Pitfalls
- **Audio not working (desktop)**: ensure `JustAudioMediaKit.ensureInitialized()` ran
- **Audio not working (mobile)**: ensure `JustAudioBackground.init()` ran in main()
- **yt-dlp/ffmpeg missing (desktop)**: check `BinaryService.lastResolution.errors`
- **yt-dlp missing (Android)**: check `BinaryService.lastResolution.errors`.
  Common causes: ABI mismatch (only `arm64-v8a` ships the binary; older
  ARMv7 phones can't download), `useLegacyPackaging` was flipped to
  `false` (the .so stays inside the APK, not on disk), or the strip
  pass corrupted the PyInstaller bundle (`keepDebugSymbols` glob
  removed). Reinstall the APK after touching any of those.
- **YouTube download fails on Android with `FileNotFoundError /tmp/_MEIxxx`**:
  the `TMPDIR` env var didn't propagate to the yt-dlp child process.
  Confirm `BinaryResolution.tmpDir` is non-empty in
  `BinaryService.instance.lastResolution`; if it is, the cache dir
  isn't writable for some reason (extremely rare).
- **YouTube download fails on Android with `bad ELF interpreter`**:
  the launch path bypassed the bundled musl loader. Verify the
  `Process.start` call site in `download_service.dart` uses
  `BinaryResolution.linkerPath` as `executable` and passes
  `BinaryResolution.ytDlpPath` as `processArgs[0]`.
- **APK too large**: `assets/bin/` should only contain README.txt;
  desktop binaries there bloat every Android build. The native
  binaries under `android/app/src/main/jniLibs/arm64-v8a/` are
  intentional and only ship in the arm64 split.
- **File in use errors**: Windows locks open files; stop playback before renaming/deleting
- **Hot reload issues**: audio backend changes require full restart
