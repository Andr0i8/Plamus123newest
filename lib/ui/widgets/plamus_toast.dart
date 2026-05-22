import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

/// Direction the toast slides in from.
enum _PlamusToastSide { top, bottom }

/// Lightweight, theme-aware notification used in place of Flutter's default
/// [SnackBar] for short, in-app confirmations (sleep timer set, etc.).
///
/// Visual style mirrors [GlassPlayerBar]:
///   * blurred glass background (white-on-dark / dark-on-light alpha)
///   * accent-colored border + leading icon, matching the rest of Plamus
///   * rounded 20px corners and the same drop shadow language as the
///     glass cards used in the active sleep-timer summary card
///
/// Implementation notes:
///   * Built on [OverlayEntry] so it works regardless of whether the
///     calling screen has a [Scaffold]/[ScaffoldMessenger] above it (the
///     sleep-timer sheet can be invoked from anywhere in the app).
///   * Auto-dismisses after [duration] with a fade + slide-out animation.
///   * Tapping the toast (or its close button) dismisses early.
class PlamusToast {
  PlamusToast._();

  /// Currently visible toast, dismissed before showing a new one to avoid
  /// stacked notifications.
  static _PlamusToastEntry? _current;

  /// Shows a confirmation/info toast with [message].
  ///
  /// [icon] defaults to a gentle bedtime glyph since the only current
  /// caller is the sleep timer; pass a different icon for other callers.
  static void show(
    BuildContext context, {
    required String message,
    IconData icon = Icons.bedtime,
    Duration duration = const Duration(seconds: 3),
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    _current?.dismiss();

    final entry = _PlamusToastEntry(
      overlay: overlay,
      message: message,
      icon: icon,
      side: _PlamusToastSide.bottom,
      duration: duration,
    );
    _current = entry;
    entry.show();
  }
}

class _PlamusToastEntry {
  _PlamusToastEntry({
    required this.overlay,
    required this.message,
    required this.icon,
    required this.side,
    required this.duration,
  });

  final OverlayState overlay;
  final String message;
  final IconData icon;
  final _PlamusToastSide side;
  final Duration duration;

  OverlayEntry? _entry;
  Timer? _autoDismiss;
  final GlobalKey<_PlamusToastState> _toastKey =
      GlobalKey<_PlamusToastState>();
  bool _disposed = false;

  void show() {
    final entry = OverlayEntry(
      builder: (context) {
        return _PlamusToastWidget(
          key: _toastKey,
          message: message,
          icon: icon,
          side: side,
          onTapDismiss: dismiss,
        );
      },
    );
    _entry = entry;
    overlay.insert(entry);
    _autoDismiss = Timer(duration, dismiss);
  }

  Future<void> dismiss() async {
    if (_disposed) return;
    _disposed = true;
    _autoDismiss?.cancel();
    _autoDismiss = null;
    if (PlamusToast._current == this) {
      PlamusToast._current = null;
    }
    final state = _toastKey.currentState;
    if (state != null) {
      await state.playOut();
    }
    _entry?.remove();
    _entry = null;
  }
}

class _PlamusToastWidget extends StatefulWidget {
  const _PlamusToastWidget({
    super.key,
    required this.message,
    required this.icon,
    required this.side,
    required this.onTapDismiss,
  });

  final String message;
  final IconData icon;
  final _PlamusToastSide side;
  final Future<void> Function() onTapDismiss;

  @override
  State<_PlamusToastWidget> createState() => _PlamusToastState();
}

class _PlamusToastState extends State<_PlamusToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _offset;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
      reverseDuration: const Duration(milliseconds: 180),
    );
    final beginOffset = widget.side == _PlamusToastSide.bottom
        ? const Offset(0, 0.4)
        : const Offset(0, -0.4);
    _offset = Tween<Offset>(
      begin: beginOffset,
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );
    _opacity = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Plays the reverse animation so the entry can be removed cleanly.
  Future<void> playOut() async {
    if (!mounted) return;
    try {
      await _controller.reverse();
    } catch (_) {
      // Controller was disposed mid-reverse — caller still removes the entry.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final accent = theme.colorScheme.primary;
    final mediaQuery = MediaQuery.of(context);
    // Lift the toast above the bottom navigation / player bar.
    //
    // The desktop GlassPlayerBar measures roughly 130–155px tall once the
    // progress slider, control row, and outer SafeArea + 12px padding
    // settle. The mobile MobileMiniPlayer is a fixed 70px high, plus the
    // bottom-nav (~64px) and the device's home-bar safe-area inset.
    // Picking 140 guarantees both layouts have a visible gap between
    // the toast and the player without making the spacing feel wrong on
    // shorter screens.
    final bottomInset = mediaQuery.viewInsets.bottom +
        mediaQuery.viewPadding.bottom +
        140;

    return Positioned.fill(
      child: IgnorePointer(
        ignoring: false,
        child: Align(
          alignment: widget.side == _PlamusToastSide.bottom
              ? Alignment.bottomCenter
              : Alignment.topCenter,
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              bottom: widget.side == _PlamusToastSide.bottom ? bottomInset : 0,
              top: widget.side == _PlamusToastSide.top
                  ? mediaQuery.viewPadding.top + 16
                  : 0,
            ),
            child: SlideTransition(
              position: _offset,
              child: FadeTransition(
                opacity: _opacity,
                child: Material(
                  color: Colors.transparent,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                        child: GestureDetector(
                          onTap: widget.onTapDismiss,
                          behavior: HitTestBehavior.opaque,
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.black.withValues(alpha: 0.55)
                                  : Colors.white.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                color: accent.withValues(alpha: 0.45),
                                width: 1.4,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(
                                    alpha: isDark ? 0.4 : 0.12,
                                  ),
                                  blurRadius: 18,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: accent.withValues(alpha: 0.18),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(
                                    widget.icon,
                                    color: accent,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Flexible(
                                  child: Text(
                                    widget.message,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  tooltip: 'Dismiss',
                                  iconSize: 18,
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 32,
                                    minHeight: 32,
                                  ),
                                  onPressed: widget.onTapDismiss,
                                  icon: Icon(
                                    Icons.close,
                                    color: theme.iconTheme.color
                                        ?.withValues(alpha: 0.7),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
