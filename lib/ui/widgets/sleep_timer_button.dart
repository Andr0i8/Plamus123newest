import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/audio_player_service.dart';
import 'plamus_toast.dart';

/// Small player control that opens the one-shot sleep timer sheet.
class SleepTimerButton extends StatefulWidget {
  const SleepTimerButton({
    super.key,
    this.iconSize = 22,
    this.padding = EdgeInsets.zero,
    this.constraints = const BoxConstraints(minWidth: 40, minHeight: 40),
  });

  final double iconSize;
  final EdgeInsetsGeometry padding;
  final BoxConstraints constraints;

  @override
  State<SleepTimerButton> createState() => _SleepTimerButtonState();
}

class _SleepTimerButtonState extends State<SleepTimerButton> {
  Timer? _ticker;
  AudioPlayerService? _audio;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextAudio = context.read<AudioPlayerService>();
    if (_audio == nextAudio) return;
    _audio?.removeListener(_handleAudioChanged);
    _audio = nextAudio..addListener(_handleAudioChanged);
    _syncTicker(nextAudio.sleepTimerActive);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _audio?.removeListener(_handleAudioChanged);
    super.dispose();
  }

  void _handleAudioChanged() {
    final active = _audio?.sleepTimerActive ?? false;
    _syncTicker(active);
    if (mounted) setState(() {});
  }

  void _syncTicker(bool active) {
    if (!active) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final audio = context.watch<AudioPlayerService>();
    final theme = Theme.of(context);
    final active = audio.sleepTimerActive;
    final remaining = audio.sleepTimerRemaining;
    final baseColor = theme.iconTheme.color ?? theme.colorScheme.onSurface;

    return IconButton(
      tooltip: active
          ? 'Sleep timer: ${_formatRemaining(remaining)} remaining'
          : 'Sleep timer',
      iconSize: widget.iconSize,
      constraints: widget.constraints,
      padding: widget.padding,
      icon: Icon(
        active ? Icons.bedtime : Icons.bedtime_outlined,
        color: active
            ? theme.colorScheme.primary
            : baseColor.withValues(alpha: 0.65),
      ),
      onPressed: () => showSleepTimerSheet(context),
    );
  }
}

/// Opens the sleep timer picker.
Future<void> showSleepTimerSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => const _SleepTimerSheet(),
  );
}

class _SleepTimerSheet extends StatefulWidget {
  const _SleepTimerSheet();

  @override
  State<_SleepTimerSheet> createState() => _SleepTimerSheetState();
}

class _SleepTimerSheetState extends State<_SleepTimerSheet> {
  static const List<MapEntry<int, String>> _presets = [
    MapEntry(1, '1 min'),
    MapEntry(5, '5 min'),
    MapEntry(10, '10 min'),
    MapEntry(30, '30 min'),
    MapEntry(60, '1 hour'),
  ];

  final TextEditingController _customCtrl = TextEditingController();
  Timer? _ticker;
  String? _customError;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _customCtrl.dispose();
    super.dispose();
  }

  void _setTimer(int minutes) {
    if (minutes <= 0) {
      setState(() => _customError = 'Enter a positive number of minutes');
      return;
    }

    final duration = Duration(minutes: minutes);
    final label = _formatDurationLabel(duration);
    final audio = context.read<AudioPlayerService>();
    // Capture the root navigator/overlay context BEFORE popping the sheet
    // so the toast can attach to the underlying screen's overlay rather
    // than the sheet's (which is about to be torn down).
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    audio.setSleepTimer(duration);
    Navigator.of(context).pop();
    PlamusToast.show(
      rootContext,
      message: 'Sleep timer set for $label',
      icon: Icons.bedtime,
    );
  }

  void _setCustomTimer() {
    final minutes = int.tryParse(_customCtrl.text.trim());
    if (minutes == null || minutes <= 0) {
      setState(() => _customError = 'Enter a positive number of minutes');
      return;
    }
    _setTimer(minutes);
  }

  void _cancelTimer() {
    final audio = context.read<AudioPlayerService>();
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    audio.cancelSleepTimer();
    Navigator.of(context).pop();
    PlamusToast.show(
      rootContext,
      message: 'Sleep timer cancelled',
      icon: Icons.bedtime_off_outlined,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final audio = context.watch<AudioPlayerService>();
    final active = audio.sleepTimerActive;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24, 0, 24, bottomInset + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Sleep timer',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Pause playback automatically after a chosen duration.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color:
                    theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
              ),
            ),
            if (active) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Icon(Icons.bedtime, color: theme.colorScheme.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Active timer',
                            style: theme.textTheme.labelLarge,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${_formatRemaining(audio.sleepTimerRemaining)} remaining',
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: _cancelTimer,
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final preset in _presets)
                  ActionChip(
                    label: Text(preset.value),
                    avatar: const Icon(Icons.timer_outlined, size: 18),
                    onPressed: () => _setTimer(preset.key),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _customCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Custom minutes',
                      hintText: 'e.g. 45',
                      errorText: _customError,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) {
                      if (_customError != null) {
                        setState(() => _customError = null);
                      }
                    },
                    onSubmitted: (_) => _setCustomTimer(),
                  ),
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: FilledButton(
                    onPressed: _setCustomTimer,
                    child: const Text('Set'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _formatRemaining(Duration duration) {
  final d = duration.isNegative ? Duration.zero : duration;
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '$m:${s.toString().padLeft(2, '0')}';
}

String _formatDurationLabel(Duration duration) {
  final minutes = duration.inMinutes;
  if (minutes == 60) return '1 hour';
  return '$minutes min';
}
