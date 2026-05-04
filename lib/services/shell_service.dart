import 'dart:io';

/// Cross-platform shell helpers (reveal a file in the system file manager).
///
/// Replaces the previous `WindowsShell` helper. The class is named
/// [ShellService] for clarity now that it handles more than Windows.
class ShellService {
  ShellService._();

  /// Opens the system file manager focused on [filePath].
  ///
  /// * **Windows**: `explorer /select,<file>`. Pre-selects the file so the
  ///   user can immediately see it highlighted in Explorer.
  /// * **Linux**: `xdg-open <directory>` on the file's parent. `xdg-open`
  ///   does not have a portable file-selection flag, so opening the
  ///   containing folder is the closest equivalent that works across all
  ///   desktop environments (GNOME, KDE, Xfce, …).
  /// * **macOS**: `open -R <file>`. The `-R` flag reveals/highlights the
  ///   file in Finder, matching Windows behavior.
  ///
  /// Throws [FileSystemException] if [filePath] is empty or the file is
  /// missing, and [ProcessException] if the underlying tool fails.
  static Future<void> showInFolder(String filePath) async {
    if (filePath.isEmpty) {
      throw const FileSystemException('Cannot show empty path in folder');
    }
    final f = File(filePath);
    if (!await f.exists()) {
      throw FileSystemException('Cannot show missing file in folder', filePath);
    }

    if (Platform.isWindows) {
      // Normalize forward slashes to backslashes — Explorer's `/select,` flag
      // is sensitive to the separator style.
      final normalized = filePath.replaceAll('/', '\\');
      final args = <String>['/select,$normalized'];
      final result = await Process.run('explorer', args);
      // Note: explorer.exe sometimes returns exit code 1 even on success;
      // mirror the original behavior of treating non-zero as an error so we
      // don't silently mask a real failure.
      if (result.exitCode != 0) {
        throw ProcessException(
          'explorer',
          args,
          result.stderr.toString().trim(),
          result.exitCode,
        );
      }
      return;
    }

    if (Platform.isLinux) {
      final dir = f.parent.path;
      final result = await Process.run('xdg-open', [dir]);
      if (result.exitCode != 0) {
        throw ProcessException(
          'xdg-open',
          [dir],
          result.stderr.toString().trim(),
          result.exitCode,
        );
      }
      return;
    }

    if (Platform.isMacOS) {
      final args = <String>['-R', filePath];
      final result = await Process.run('open', args);
      if (result.exitCode != 0) {
        throw ProcessException(
          'open',
          args,
          result.stderr.toString().trim(),
          result.exitCode,
        );
      }
      return;
    }

    // Mobile / unknown platforms: no file-manager equivalent we can rely on.
  }
}
