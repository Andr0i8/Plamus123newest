import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';

import 'database/database_helper.dart';
import 'services/audio_player_service.dart';
import 'services/binary_service.dart';
import 'services/library_service.dart';
import 'theme/app_theme.dart';
import 'ui/shell/plamus_shell.dart';
import 'ui/shell/plamus_shell_mobile.dart';
import 'ui/theme/theme_controller.dart';

/// Application entry: Cross-platform music player (Desktop + Mobile).
///
/// **Desktop audio:** `just_audio` requires media_kit backend on Windows/Linux.
/// **Mobile audio:** `just_audio_background` for background playback.
/// After changing audio dependencies, do a full cold restart.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Mobile: Lock to portrait mode.
  // Note: JustAudioBackground.init and permission requests are deferred to
  // _PlamusAppState.initState via a postFrameCallback because they require
  // the Android Activity to exist, which isn't true this early in main().
  if (Platform.isAndroid || Platform.isIOS) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  }

  // Desktop: Initialize window manager for fullscreen support.
  //
  // Linux gets a borderless window (BUG 1): `TitleBarStyle.hidden` tells
  // window_manager to either hide the GTK header bar created by
  // `my_application.cc` (on GNOME) or call `gtk_window_set_decorated(false)`
  // (other WMs). Users drag the window via the custom top bar in
  // `PlamusShell` that wraps `DragToMoveArea`.
  //
  // Windows/macOS keep their native title bars, matching the previous UX.
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
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
  }

  // Desktop: media_kit backend required for just_audio on Windows + Linux.
  // Linux uses libmpv from media_kit_libs_linux; Windows uses bundled libs
  // from media_kit_libs_windows_audio.
  if (Platform.isWindows || Platform.isLinux) {
    JustAudioMediaKit.ensureInitialized(
      windows: true,
      linux: true,
    );
    JustAudioMediaKit.title = 'Plamus';
    // Note: media_kit handles caching internally for local files
    // The "Failed to create file cache" warning can be safely ignored for local playback
  }

  // Desktop: SQLite via FFI.
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // Desktop only: extract yt-dlp/ffmpeg binaries.
  // On Android/iOS, downloads use AudioDownloadService (pure Dart) instead.
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await BinaryService.instance.ensureBinariesExtracted();
  }

  // Initialize audio service
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

/// Request storage permissions for mobile.
Future<void> _requestMobilePermissions() async {
  if (Platform.isAndroid) {
    // Request storage permissions
    await Permission.storage.request();
    await Permission.audio.request();

    // Android 13+ requires notification permission
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
  }
}

/// Root [MaterialApp] wired to [ThemeController] and Plamus themes.
class PlamusApp extends StatefulWidget {
  /// Creates the root widget.
  const PlamusApp({super.key});

  @override
  State<PlamusApp> createState() => _PlamusAppState();
}

class _PlamusAppState extends State<PlamusApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (Platform.isAndroid || Platform.isIOS) {
        await JustAudioBackground.init(
          androidNotificationChannelId: 'com.plamus.audio',
          androidNotificationChannelName: 'Plamus Audio',
          androidNotificationOngoing: true,
          androidShowNotificationBadge: true,
        );
        await _requestMobilePermissions();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeCtrl = context.watch<ThemeController>();

    // F11 fullscreen is handled directly in `PlamusShell`'s `Focus.onKeyEvent`
    // (see BUG 2). Keeping it there rather than in a top-level
    // `Shortcuts`/`Actions` map gives us consistent behavior on Linux, where
    // focus routing to MaterialApp-level shortcuts was unreliable, and
    // avoids double-toggling when both paths fire.
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
      home: Platform.isAndroid || Platform.isIOS
          ? const PlamusShellMobile()
          : const PlamusShell(),
    );
  }
}
