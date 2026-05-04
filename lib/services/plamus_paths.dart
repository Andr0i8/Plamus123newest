import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Centralized filesystem locations for music files and support data.
class PlamusPaths {
  PlamusPaths._();

  /// Per-user application support directory for Plamus.
  ///
  /// Resolved per-platform:
  /// * **Windows**: `%APPDATA%\com.example\plamus` (via `path_provider`).
  /// * **Linux**: `$XDG_DATA_HOME/plamus` (defaults to `~/.local/share/plamus`)
  ///   constructed explicitly so the path is independent of the embedder's
  ///   binary name and matches the documented spec.
  /// * **macOS / mobile**: platform application support directory.
  ///
  /// Always exists on return (created if missing).
  static Future<String> applicationSupportDirectory() async {
    if (Platform.isLinux) {
      final base = _linuxDataHome();
      final dir = Directory(p.join(base, 'plamus'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir.path;
    }
    final support = await getApplicationSupportDirectory();
    if (!await support.exists()) {
      await support.create(recursive: true);
    }
    return support.path;
  }

  /// Ensures the on-disk music library folder exists and returns its path.
  ///
  /// Lives under [applicationSupportDirectory] so it is writable and
  /// user-specific.
  static Future<String> musicLibraryDirectory() async {
    final support = await applicationSupportDirectory();
    final dir = Directory(p.join(support, 'music_library'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  /// Resolves `$XDG_DATA_HOME` (or `~/.local/share` if unset) on Linux.
  ///
  /// Throws [StateError] if neither `XDG_DATA_HOME` nor `HOME` are set, which
  /// would be unusual outside of stripped-down container environments.
  static String _linuxDataHome() {
    final xdg = Platform.environment['XDG_DATA_HOME'];
    if (xdg != null && xdg.isNotEmpty) return xdg;
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      throw StateError(
        'Cannot determine HOME or XDG_DATA_HOME to locate Plamus data dir on Linux',
      );
    }
    return p.join(home, '.local', 'share');
  }
}
