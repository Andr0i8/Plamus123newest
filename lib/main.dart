import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';

import 'database/database_helper.dart';
import 'services/audio_player_service.dart';
import 'services/binary_service.dart';
import 'services/library_service.dart';
import 'theme/app_theme.dart';
import 'ui/shell/plamus_shell.dart';
import 'ui/theme/theme_controller.dart';

/// Application entry: desktop-only music player (Linux + Windows).
///
/// Audio: `just_audio` requires the media_kit backend on Windows/Linux.
/// After changing audio dependencies, do a full cold restart.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Window manager + frameless window on Linux (the GTK header bar is
  // hidden so the shell renders its own top strip with the window
  // controls).
  await windowManager.ensureInitialized();

  final windowOptions = WindowOptions(
    minimumSize: const Size(800, 600),
    center: true,
    backgroundColor: Colors.transparent,
    skipTaskbar: false,
    titleBarStyle:
        Platform.isLinux ? TitleBarStyle.hidden : TitleBarStyle.normal,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  // media_kit backend required for just_audio on Windows + Linux.
  // Linux uses libmpv from media_kit_libs_linux; Windows uses bundled
  // libs from media_kit_libs_windows_audio.
  JustAudioMediaKit.ensureInitialized(
    windows: true,
    linux: true,
  );
  JustAudioMediaKit.title = 'Plamus';

  // SQLite via FFI on desktop.
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  // Extract bundled yt-dlp/ffmpeg into the app support dir (Windows)
  // or download yt-dlp on first run + resolve system ffmpeg (Linux).
  await BinaryService.instance.ensureBinariesExtracted();

  // Initialize audio service.
  final audio = AudioPlayerService();
  await audio.init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => LibraryService(DatabaseHelper.instance),
        ),
        ChangeNotifierProvider.value(value: audio),
        ChangeNotifierProvider(create: (_) => ThemeController()),
      ],
      child: const PlamusApp(),
    ),
  );
}

/// Root [MaterialApp] wired to [ThemeController] and Plamus themes.
class PlamusApp extends StatelessWidget {
  /// Creates the root widget.
  const PlamusApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeCtrl = context.watch<ThemeController>();

    // F11 fullscreen is handled directly in `PlamusShell`'s
    // `Focus.onKeyEvent` — focus routing to MaterialApp-level shortcuts
    // was unreliable on Linux when the shell auto-focused itself.
    return MaterialApp(
      title: 'Plamus',
      debugShowCheckedModeBanner: false,
      // Resolve the user's text-color choice once per brightness so
      // the "auto" default still maps to white-on-dark / black-on-light
      // while an explicit custom color (picked in Settings) wins in
      // both themes.
      theme: PlamusTheme.light(
        accentColor: themeCtrl.accentColor,
        textColor: themeCtrl.textColorFor(Brightness.light),
      ),
      darkTheme: PlamusTheme.dark(
        accentColor: themeCtrl.accentColor,
        textColor: themeCtrl.textColorFor(Brightness.dark),
      ),
      themeMode: themeCtrl.mode,
      home: const PlamusShell(),
    );
  }
}
