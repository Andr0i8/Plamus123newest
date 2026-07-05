import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../../models/playlist_model.dart';
import '../../services/audio_player_service.dart';
import '../../services/library_service.dart';
import '../../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../screens/history_screen.dart';
import '../screens/home_library_screen.dart';
import '../screens/import_screen.dart';
import '../screens/liked_screen.dart';
import '../screens/playlist_detail_screen.dart';
import '../screens/settings_screen.dart';
import '../widgets/glass_player_bar.dart';

/// Sidebar destinations and smooth content transitions.
enum PlamusSection {
  library,
  importPage,
  liked,
  history,
  playlist,
  settings,
}

/// Root shell: Desktop-only layout with sidebar.
class PlamusShell extends StatefulWidget {
  const PlamusShell({super.key});

  @override
  State<PlamusShell> createState() => _PlamusShellState();
}

class _PlamusShellState extends State<PlamusShell>
    with SingleTickerProviderStateMixin {
  PlamusSection _section = PlamusSection.library;
  int? _playlistId;
  bool _sidebarCollapsed = false;
  late AnimationController _sidebarAnimationController;
  late Animation<double> _sidebarAnimation;

  @override
  void initState() {
    super.initState();
    _sidebarAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: 1.0, // Start with sidebar visible
    );
    _sidebarAnimation = CurvedAnimation(
      parent: _sidebarAnimationController,
      curve: Curves.easeInOutCubic,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<LibraryService>().refreshAll();
    });
  }

  @override
  void dispose() {
    _sidebarAnimationController.dispose();
    super.dispose();
  }

  void _toggleSidebar() {
    setState(() {
      _sidebarCollapsed = !_sidebarCollapsed;
      if (_sidebarCollapsed) {
        _sidebarAnimationController.reverse();
      } else {
        _sidebarAnimationController.forward();
      }
    });
  }

  /// Toggles fullscreen via `window_manager`. Shared between the F11 key
  /// handler and any future UI entry points.
  ///
  /// No-op on platforms where `window_manager` is not initialized
  /// (mobile) — the desktop shell is only used on Windows/Linux/macOS, but
  /// the guard keeps the method safe in unit tests.
  Future<void> _toggleFullScreen() async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) return;
    try {
      final isFullScreen = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!isFullScreen);
    } catch (e) {
      debugPrint('F11 fullscreen toggle failed: $e');
    }
  }

  /// Switches the shell body to a playlist. Used by both the sidebar tile
  /// and the home screen's "Playlists" tab so both entry points end up at
  /// the SAME [PlaylistDetailScreen] instance rendered INSIDE this shell
  /// — the persistent [GlassPlayerBar] stays visible and the now-playing
  /// context is scoped to the playlist surface (see [_openPlaylistById]).
  void _openPlaylist(PlaylistModel p) {
    if (p.id == null) return;
    _openPlaylistById(p.id!);
  }

  /// Sibling of [_openPlaylist] that takes the playlist id directly.
  /// Wired into [HomeLibraryScreen.onOpenPlaylist] so the tab uses the
  /// shell's state-based navigation instead of pushing a new route over
  /// the shell scaffold (which would hide the player bar).
  void _openPlaylistById(int id) {
    setState(() {
      _section = PlamusSection.playlist;
      _playlistId = id;
    });
  }

  Future<void> _createPlaylist() async {
    final ctrl = TextEditingController(text: 'New playlist');
    final messenger = ScaffoldMessenger.of(context);

    String? name;
    try {
      name = await showDialog<String>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Create playlist'),
            content: TextField(
              controller: ctrl,
              decoration: const InputDecoration(labelText: 'Name'),
              autofocus: true,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
                child: const Text('Create'),
              ),
            ],
          );
        },
      );
    } finally {
      ctrl.dispose();
    }

    if (!mounted) return;
    if (name == null || name.isEmpty) return;

    try {
      final id = await context.read<LibraryService>().createPlaylist(name);
      if (!mounted) return;
      setState(() {
        _section = PlamusSection.playlist;
        _playlistId = id;
      });
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Could not create playlist: $e')),
      );
    }
  }

  Widget _buildBody(ThemeData theme) {
    final playlistId = _playlistId;
    switch (_section) {
      case PlamusSection.library:
        // Pass the shell's state-based navigation as a callback so the
        // home screen's "Playlists" tab opens playlists the SAME way as
        // the sidebar (see _openPlaylist). Without this the tab would
        // push a new route over the shell, hiding GlassPlayerBar and
        // making the now-playing highlight scope ambiguous.
        return HomeLibraryScreen(onOpenPlaylist: _openPlaylistById);
      case PlamusSection.importPage:
        return const ImportScreen();
      case PlamusSection.liked:
        return const LikedScreen();
      case PlamusSection.history:
        return const HistoryScreen();
      case PlamusSection.settings:
        return const SettingsScreen();
      case PlamusSection.playlist:
        if (playlistId == null) {
          return HomeLibraryScreen(onOpenPlaylist: _openPlaylistById);
        }
        return PlaylistDetailScreen(playlistId: playlistId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    final sidebarColor = brightness == Brightness.dark
        ? PlamusColors.darkSidebar
        : PlamusColors.lightSidebar;

    final lib = context.watch<LibraryService>();
    final audio = context.watch<AudioPlayerService>();

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          // Spacebar: Play/Pause
          if (event.logicalKey == LogicalKeyboardKey.space) {
            if (audio.playing) {
              audio.pause();
            } else {
              audio.play();
            }
            return KeyEventResult.handled;
          }
          // Left Arrow: Seek backward 5 seconds
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            final newPos = audio.position - const Duration(seconds: 5);
            audio.seek(newPos < Duration.zero ? Duration.zero : newPos);
            return KeyEventResult.handled;
          }
          // Right Arrow: Seek forward 5 seconds
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            final newPos = audio.position + const Duration(seconds: 5);
            final maxPos = audio.duration;
            audio.seek(newPos > maxPos ? maxPos : newPos);
            return KeyEventResult.handled;
          }
          // PageUp: Increase volume by 5%
          if (event.logicalKey == LogicalKeyboardKey.pageUp) {
            final newVolume = (audio.volume + 0.05).clamp(0.0, 1.0);
            audio.setVolumeLinear(newVolume);
            return KeyEventResult.handled;
          }
          // PageDown: Decrease volume by 5%
          if (event.logicalKey == LogicalKeyboardKey.pageDown) {
            final newVolume = (audio.volume - 0.05).clamp(0.0, 1.0);
            audio.setVolumeLinear(newVolume);
            return KeyEventResult.handled;
          }
          // F11: Fullscreen toggle (BUG 2).
          //
          // The top-level `Shortcuts`/`Actions` in main.dart intercepts F11 on
          // Windows/macOS but misses it on Linux — the focus never reaches the
          // MaterialApp-level shortcut map when the shell's Focus widget has
          // autofocused itself. Handling it here (same place as the other
          // keyboard shortcuts) makes F11 work consistently on every desktop.
          if (event.logicalKey == LogicalKeyboardKey.f11) {
            if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
              _toggleFullScreen();
              return KeyEventResult.handled;
            }
          }
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: Row(
          children: [
            AnimatedBuilder(
              animation: _sidebarAnimation,
              builder: (context, child) {
                return SizeTransition(
                  sizeFactor: _sidebarAnimation,
                  axis: Axis.horizontal,
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: 280,
                    margin: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                    child: Material(
                      color: sidebarColor,
                      borderRadius: BorderRadius.circular(30),
                      elevation: 0,
                      child: ListView(
                        padding: const EdgeInsets.symmetric(
                            vertical: 28, horizontal: 20),
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Padding(
                                  padding:
                                      const EdgeInsets.only(left: 8, bottom: 8),
                                  child: Text(
                                    'Plamus',
                                    style: theme.textTheme.headlineMedium
                                        ?.copyWith(
                                      fontWeight: FontWeight.w900,
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 32),
                          _NavButton(
                            label: 'Home',
                            icon: FontAwesomeIcons.house,
                            selected: _section == PlamusSection.library,
                            onTap: () => setState(
                                () => _section = PlamusSection.library),
                          ),
                          _NavButton(
                            label: 'Search / import',
                            icon: FontAwesomeIcons.magnifyingGlass,
                            selected: _section == PlamusSection.importPage,
                            onTap: () => setState(
                                () => _section = PlamusSection.importPage),
                          ),
                          _NavButton(
                            label: 'Liked songs',
                            icon: FontAwesomeIcons.heart,
                            selected: _section == PlamusSection.liked,
                            onTap: () =>
                                setState(() => _section = PlamusSection.liked),
                          ),
                          _NavButton(
                            label: 'History',
                            icon: FontAwesomeIcons.clock,
                            selected: _section == PlamusSection.history,
                            onTap: () => setState(
                                () => _section = PlamusSection.history),
                          ),
                          const Divider(height: 40),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: FilledButton.tonalIcon(
                              onPressed: _createPlaylist,
                              style: FilledButton.styleFrom(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(25),
                                ),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 20, vertical: 14),
                              ),
                              icon:
                                  const FaIcon(FontAwesomeIcons.plus, size: 16),
                              label: const Text('Create playlist'),
                            ),
                          ),
                          const SizedBox(height: 24),
                          Padding(
                            padding: const EdgeInsets.only(
                                left: 8, top: 8, bottom: 12),
                            child: Text(
                              'Playlists',
                              style: theme.textTheme.labelLarge,
                            ),
                          ),
                          ...lib.playlists.map(
                            (p) => _PlaylistSidebarTile(
                              playlist: p,
                              selected: _section == PlamusSection.playlist &&
                                  _playlistId == p.id,
                              onOpen: () => _openPlaylist(p),
                              onChanged: () =>
                                  context.read<LibraryService>().refreshAll(),
                              onDeleted: (id) {
                                if (_playlistId == id) {
                                  setState(() {
                                    _section = PlamusSection.library;
                                    _playlistId = null;
                                  });
                                }
                              },
                            ),
                          ),
                          const Divider(height: 24),
                          _NavButton(
                            label: 'Settings',
                            icon: FontAwesomeIcons.gear,
                            selected: _section == PlamusSection.settings,
                            onTap: () => setState(
                                () => _section = PlamusSection.settings),
                          ),
                          const SizedBox(height: 8),
                          Consumer<ThemeController>(
                            builder: (context, tc, _) {
                              return ListTile(
                                dense: true,
                                leading: Icon(
                                  tc.isDark
                                      ? Icons.light_mode_outlined
                                      : Icons.dark_mode_outlined,
                                ),
                                title: Text(
                                    tc.isDark ? 'Light theme' : 'Dark theme'),
                                onTap: tc.toggle,
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
            Expanded(
              child: Column(
                children: [
                  // Top bar with sidebar toggle + (Linux only) drag-to-move
                  // area and custom window controls. The drag area wraps the
                  // empty space between the sidebar toggle and the window
                  // controls so the user can move the frameless window by
                  // grabbing any blank region in the top bar.
                  _TopBar(
                    sidebarCollapsed: _sidebarCollapsed,
                    onToggleSidebar: _toggleSidebar,
                  ),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 280),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: KeyedSubtree(
                        key: ValueKey<String>(
                          '${_section.name}-${_playlistId ?? 0}',
                        ),
                        child: _buildBody(theme),
                      ),
                    ),
                  ),
                  const GlassPlayerBar(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Desktop top bar: sidebar toggle on the left; on Linux, the rest of the
/// strip is a drag-to-move region plus minimize / maximize / close buttons
/// so the user can still move and resize the window after we've hidden the
/// native title bar (BUG 1).
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.sidebarCollapsed,
    required this.onToggleSidebar,
  });

  final bool sidebarCollapsed;
  final VoidCallback onToggleSidebar;

  @override
  Widget build(BuildContext context) {
    final isLinux = Platform.isLinux;
    final toggle = IconButton(
      icon: Icon(sidebarCollapsed ? Icons.menu : Icons.menu_open),
      onPressed: onToggleSidebar,
      tooltip: sidebarCollapsed ? 'Show sidebar' : 'Hide sidebar',
    );

    // Non-Linux: keep the original lightweight top bar exactly as before.
    if (!isLinux) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            toggle,
            const Spacer(),
          ],
        ),
      );
    }

    // Linux: the native title bar is hidden. Reuse this strip as a drag
    // region (via `DragToMoveArea`) and append window controls so users
    // can still move, minimize, maximize and close the window.
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          toggle,
          Expanded(
            child: DragToMoveArea(
              child: Container(
                // Transparent fill so the whole strip is hit-testable by
                // GestureDetector inside DragToMoveArea.
                color: Colors.transparent,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  'Plamus',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context)
                            .textTheme
                            .labelMedium
                            ?.color
                            ?.withValues(alpha: 0.55),
                        letterSpacing: 0.8,
                      ),
                ),
              ),
            ),
          ),
          const _WindowControlButton(
            tooltip: 'Minimize',
            icon: Icons.remove,
            kind: _WindowControl.minimize,
          ),
          const _WindowControlButton(
            tooltip: 'Maximize / restore',
            icon: Icons.crop_square,
            kind: _WindowControl.maximize,
          ),
          const _WindowControlButton(
            tooltip: 'Close',
            icon: Icons.close,
            kind: _WindowControl.close,
            isClose: true,
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// Which window-manager action a [_WindowControlButton] dispatches.
enum _WindowControl { minimize, maximize, close }

class _WindowControlButton extends StatelessWidget {
  const _WindowControlButton({
    required this.tooltip,
    required this.icon,
    required this.kind,
    this.isClose = false,
  });

  final String tooltip;
  final IconData icon;
  final _WindowControl kind;

  /// Close gets a red hover highlight, mirroring typical borderless desktop
  /// apps; minimize/maximize stay neutral.
  final bool isClose;

  Future<void> _dispatch() async {
    try {
      switch (kind) {
        case _WindowControl.minimize:
          await windowManager.minimize();
          break;
        case _WindowControl.maximize:
          final maximized = await windowManager.isMaximized();
          if (maximized) {
            await windowManager.unmaximize();
          } else {
            await windowManager.maximize();
          }
          break;
        case _WindowControl.close:
          await windowManager.close();
          break;
      }
    } catch (e) {
      debugPrint('Window control $kind failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: _dispatch,
        hoverColor: isClose
            ? theme.colorScheme.error.withValues(alpha: 0.2)
            : theme.colorScheme.onSurface.withValues(alpha: 0.08),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(
            icon,
            size: 16,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
          ),
        ),
      ),
    );
  }
}

class _NavButton extends StatefulWidget {
  const _NavButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final FaIconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavButton> createState() => _NavButtonState();
}

class _PlaylistSidebarTile extends StatelessWidget {
  const _PlaylistSidebarTile({
    required this.playlist,
    required this.selected,
    required this.onOpen,
    required this.onChanged,
    required this.onDeleted,
  });

  final PlaylistModel playlist;
  final bool selected;
  final VoidCallback onOpen;
  final VoidCallback onChanged;
  final void Function(int id) onDeleted;

  Future<void> _rename(BuildContext context) async {
    if (playlist.id == null) return;
    final ctrl = TextEditingController(text: playlist.name);
    final messenger = ScaffoldMessenger.of(context);

    String? name;
    try {
      name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Rename playlist'),
          content: TextField(
            controller: ctrl,
            decoration: const InputDecoration(labelText: 'Name'),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: const Text('Save'),
            ),
          ],
        ),
      );
    } finally {
      ctrl.dispose();
    }

    if (!context.mounted) return;
    if (name == null || name.isEmpty) return;

    try {
      await context.read<LibraryService>().renamePlaylist(playlist.id!, name);
      if (!context.mounted) return;
      onChanged();
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Rename failed: $e')),
      );
    }
  }

  Future<void> _delete(BuildContext context) async {
    if (playlist.id == null) return;
    final messenger = ScaffoldMessenger.of(context);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete playlist?'),
        content: const Text(
            'Tracks stay in your library; only the playlist is removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (ok != true) return;
    if (!context.mounted) return;

    try {
      final id = playlist.id!;
      await context.read<LibraryService>().deletePlaylist(id);
      if (!context.mounted) return;
      onDeleted(id);
      onChanged();
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Delete failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color =
        selected ? theme.colorScheme.primary : theme.colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.18)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: ListTile(
          dense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
          leading: FaIcon(FontAwesomeIcons.listUl, size: 18, color: color),
          title: Text(
            playlist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: color,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          onTap: onOpen,
          trailing: PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'rename') {
                _rename(context);
              } else if (v == 'delete') {
                _delete(context);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavButtonState extends State<_NavButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyLarge?.color ?? Colors.white;
    final color = widget.selected ? theme.colorScheme.primary : base;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedScale(
          scale: _hover ? 1.02 : 1.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          child: Material(
            color: widget.selected
                ? theme.colorScheme.primary.withValues(alpha: 0.18)
                : _hover
                    ? theme.colorScheme.primary.withValues(alpha: 0.08)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  children: [
                    FaIcon(widget.icon, size: 18, color: color),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: color,
                          fontWeight: widget.selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
