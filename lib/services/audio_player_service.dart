import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:shared_preferences/shared_preferences.dart';

import '../database/database_helper.dart';
import '../models/repeat_mode.dart';
import '../models/track_model.dart';
import '../ui/theme/theme_controller.dart';

/// Identifies the UI surface that started playback (`"library"`,
/// `"liked"`, `"history"`, or `"playlist:{id}"`). Used by track tiles to
/// highlight the currently-playing row only in the surface where playback
/// was initiated, so e.g. playing from a playlist doesn't also light up
/// the same track in the main library.
typedef PlaybackContextId = String;

/// Wraps [ja.AudioPlayer] with queue, repeat, shuffle, volume, history hooks
/// and a "playback context" string used for per-surface UI highlighting.
///
/// CRITICAL: When repeat is OFF, intercepts currentIndexStream to prevent auto-advance.
/// This ensures playback stops after the current track completes.
class AudioPlayerService extends ChangeNotifier {
  /// Creates the service; call [init] once before use.
  AudioPlayerService() : _player = ja.AudioPlayer();

  final ja.AudioPlayer _player;
  final DatabaseHelper _db = DatabaseHelper.instance;

  /// Expose the player for external access if needed.
  ja.AudioPlayer get player => _player;

  /// Ordered list currently driving playback.
  List<TrackModel> _queue = [];

  /// Repeat behavior for boundaries and single-track loop.
  RepeatMode repeatMode = RepeatMode.off;

  /// Volume in the range 0.0–1.0 (maps to UI 0–100%).
  double volume = 1;

  /// Whether the player is fully initialized and ready.
  bool isLoading = true;

  /// Whether shuffle mode is currently active.
  bool _shuffleEnabled = false;

  /// Public read-only view of [_shuffleEnabled].
  bool get shuffleEnabled => _shuffleEnabled;

  /// Snapshot of the queue order BEFORE shuffle was turned on. Used by
  /// [toggleShuffle] to put the queue back in its original sequence when
  /// shuffle is disabled. Empty whenever shuffle is OFF.
  List<TrackModel> _originalQueue = [];

  /// Stack of tracks the user has actually heard during the current
  /// shuffle session, newest on top. [skipPrevious] pops from this when
  /// shuffle is on so "previous" walks back through the order tracks
  /// were really played in (Spotify-style back-stack), instead of just
  /// the queue index, which would be unhelpful after a reshuffle.
  final List<TrackModel> _playHistory = [];

  /// Random source used for queue shuffling — held as a field to keep
  /// behavior deterministically swappable in unit tests.
  final Random _random = Random();

  /// Identifier of the surface that started current playback (see
  /// [PlaybackContextId]). `null` when nothing is playing.
  PlaybackContextId? _playbackContextId;

  /// Public getter for the current playback context.
  PlaybackContextId? get playbackContextId => _playbackContextId;

  /// Track the last known index to detect unwanted auto-advance
  int? _lastKnownIndex;

  /// Flag to prevent recursive pause calls
  bool _isHandlingIndexChange = false;

  /// One-shot sleep timer that pauses playback when it expires.
  Timer? _sleepTimer;

  /// Wall-clock expiration for [_sleepTimer], used by the UI to show
  /// remaining time without persisting anything between app launches.
  DateTime? _sleepTimerEndsAt;

  /// Cached "show track artwork" setting. Read from SharedPreferences in
  /// [init] and refreshed at every [setQueue] / shuffle reload, plus
  /// directly via [setShowArtwork] when the user toggles it in Settings
  /// while a track is loaded. The desktop UI (track tiles, glass player
  /// bar, now-playing screen) reads this through
  /// [ThemeController.showArtwork] but we keep a copy here for parity
  /// with previous releases.
  bool _showArtwork = true;

  /// Guards async timer callbacks from notifying after service disposal.
  bool _disposed = false;

  /// The active queue (unmodifiable view).
  List<TrackModel> get queue => List.unmodifiable(_queue);

  /// Whether a one-shot sleep timer is currently active.
  bool get sleepTimerActive => _sleepTimerEndsAt != null;

  /// Wall-clock time when the active sleep timer will fire, or null.
  DateTime? get sleepTimerEndsAt => _sleepTimerEndsAt;

  /// Remaining sleep timer duration, clamped to zero when inactive/expired.
  Duration get sleepTimerRemaining {
    final endsAt = _sleepTimerEndsAt;
    if (endsAt == null) return Duration.zero;
    final remaining = endsAt.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  // ============================================================================
  // REACTIVE STREAMS - SINGLE SOURCE OF TRUTH
  // ============================================================================

  /// Stream of the currently playing track (reactive).
  Stream<TrackModel?> get currentTrackStream {
    return _player.currentIndexStream.map((index) {
      if (index == null ||
          _queue.isEmpty ||
          index < 0 ||
          index >= _queue.length) {
        return null;
      }
      return _queue[index];
    });
  }

  /// Stream of playback position (for progress bar).
  Stream<Duration> get positionStream => _player.positionStream;

  /// Stream of track duration (for progress bar).
  Stream<Duration?> get durationStream => _player.durationStream;

  /// Stream of playing state (for play/pause button).
  Stream<bool> get playingStream => _player.playingStream;

  /// Stream of processing state (for ready checks).
  Stream<ja.ProcessingState> get processingStateStream =>
      _player.playerStateStream.map((state) => state.processingState);

  /// Stream of buffered position (for buffer indicator).
  Stream<Duration> get bufferedPositionStream => _player.bufferedPositionStream;

  /// Stream of volume changes (for volume slider).
  Stream<double> get volumeStream => _player.volumeStream;

  /// Stream of loop mode changes (for repeat button).
  Stream<ja.LoopMode> get loopModeStream => _player.loopModeStream;

  // ============================================================================
  // LEGACY GETTERS
  // ============================================================================

  /// Current track or null if the queue is empty.
  TrackModel? get currentTrack {
    if (_queue.isEmpty) return null;
    final actualIndex = _player.currentIndex;
    if (actualIndex == null ||
        actualIndex < 0 ||
        actualIndex >= _queue.length) {
      return null;
    }
    return _queue[actualIndex];
  }

  /// Latest known position for UI.
  Duration get position => _player.position;

  /// Latest known total duration.
  Duration get duration => _player.duration ?? Duration.zero;

  /// Whether the engine is actively playing audio.
  bool get playing => _player.playing;

  /// Whether the player is ready to accept commands.
  bool get isReady {
    final state = _player.processingState;
    return state == ja.ProcessingState.ready ||
        state == ja.ProcessingState.buffering ||
        state == ja.ProcessingState.loading;
  }

  /// Configures the player and wires its streams.
  Future<void> init() async {
    isLoading = true;
    notifyListeners();

    // Pick up the persisted "show track artwork" preference up front so
    // any UI that reads `showArtwork` synchronously during the first
    // frame sees the user's saved choice rather than the default.
    await _refreshShowArtworkFromPrefs();

    await _player.setVolume(volume);
    await _player.setLoopMode(ja.LoopMode.off);

    // Listen to index changes for history recording AND to wake up Provider
    // listeners (context.watch<AudioPlayerService>()) so the mini-player /
    // track tiles rebuild when next/previous switches the active track.
    _player.currentIndexStream.listen((index) {
      // Notify listeners on EVERY index change so widgets that read
      // `currentTrack` synchronously (e.g. the now-playing highlight in
      // track tiles, the mobile mini-player title row) repaint immediately.
      notifyListeners();

      if (index != null && index >= 0 && index < _queue.length) {
        _recordPlayForTrack(_queue[index]);

        // Shuffle back-stack on auto-advance (RepeatMode.all). When the
        // engine moves forward on its own (track ended naturally), push
        // the OUTGOING track onto _playHistory so a subsequent
        // skipPrevious can step back through real listening order. We
        // skip this when our own toggleShuffle / reshuffle is rebuilding
        // the source (_isHandlingIndexChange) and dedupe against the
        // last entry to avoid double-push when skipNext also added it.
        if (_shuffleEnabled &&
            !_isHandlingIndexChange &&
            _lastKnownIndex != null &&
            index != _lastKnownIndex &&
            _lastKnownIndex! >= 0 &&
            _lastKnownIndex! < _queue.length) {
          final outgoing = _queue[_lastKnownIndex!];
          if (_playHistory.isEmpty || _playHistory.last.id != outgoing.id) {
            _playHistory.add(outgoing);
          }

          // End-of-shuffled-queue auto-wrap (RepeatMode.all): the
          // engine just looped from the last index back to 0. Generate
          // a fresh random order so the listener doesn't hear the same
          // shuffled sequence on every loop. We schedule this as a
          // microtask so the engine finishes its own state update
          // before we swap the audio source.
          final wrapped = _lastKnownIndex! == _queue.length - 1 &&
              index == 0 &&
              repeatMode == RepeatMode.all &&
              _queue.length > 1;
          if (wrapped) {
            scheduleMicrotask(_reshuffleAndRestart);
          }
        }

        // Detect unwanted auto-advance when repeat is OFF
        if (!_isHandlingIndexChange &&
            _lastKnownIndex != null &&
            index != _lastKnownIndex &&
            repeatMode == RepeatMode.off) {
          _isHandlingIndexChange = true;
          debugPrint(
              'AudioPlayerService: Auto-advance detected ($_lastKnownIndex -> $index) with repeat OFF - STOPPING');

          // Pause immediately and go back to the previous track
          _player.pause().then((_) {
            _player.seek(Duration.zero, index: _lastKnownIndex);
            _isHandlingIndexChange = false;
          });
        } else {
          _lastKnownIndex = index;
        }
      }
    });

    // CRITICAL FIX: Listen to player state to handle track completion
    _player.playerStateStream.listen((state) {
      // When track completes and repeat is OFF, stop playback completely
      if (state.processingState == ja.ProcessingState.completed &&
          repeatMode == RepeatMode.off) {
        debugPrint(
            'AudioPlayerService: Track completed with repeat OFF - stopping playback');
        _player.pause();
        _player.seek(Duration.zero);
      }
    });

    isLoading = false;
    notifyListeners();
  }

  /// Replaces the queue and optionally starts at [startIndex].
  ///
  /// [contextId] identifies the UI surface that started this playback (see
  /// [PlaybackContextId]). Track tiles use it to decide whether to render the
  /// "now playing" highlight, so the same track playing from a playlist
  /// doesn't also light up in the main library.
  ///
  /// Shuffle interaction: if shuffle is currently ON, the new queue is
  /// reshuffled here so the chosen track plays first and the rest land
  /// in random order — same UX as Spotify when you tap a track from a
  /// list while shuffle is engaged.
  Future<void> setQueue(
    List<TrackModel> tracks, {
    int startIndex = 0,
    bool playImmediately = true,
    PlaybackContextId? contextId,
  }) async {
    if (tracks.isEmpty) {
      await stop();
      return;
    }

    // Re-read the persisted "show artwork" preference at every queue
    // change so a user who flipped the toggle while music was playing
    // still gets the right artUri on the next playback session even if
    // the settings screen forgot to call setShowArtwork directly.
    await _refreshShowArtworkFromPrefs();

    _queue = List<TrackModel>.from(tracks);
    _playbackContextId = contextId;
    // A fresh queue invalidates any previous shuffle session bookkeeping:
    // the back-stack and the original-order snapshot belong to the
    // PREVIOUS queue and would only confuse skipPrevious if reused.
    _playHistory.clear();
    _originalQueue = [];

    final safeIndex = startIndex.clamp(0, _queue.length - 1);
    int initialIndex = safeIndex;

    if (_shuffleEnabled && _queue.length > 1) {
      // Save the un-shuffled order so a later toggleShuffle() can
      // restore it, then shuffle the queue with the user's clicked
      // track pinned to the front so playback doesn't leap to a
      // random song.
      _originalQueue = List<TrackModel>.from(_queue);
      final clicked = _queue[safeIndex];
      final others = [
        ..._queue.sublist(0, safeIndex),
        ..._queue.sublist(safeIndex + 1),
      ]..shuffle(_random);
      _queue = [clicked, ...others];
      initialIndex = 0;
    }

    _lastKnownIndex = initialIndex;

    try {
      await _player.setAudioSource(
        _buildAudioSource(_queue),
        initialIndex: initialIndex,
      );
      if (playImmediately) {
        await _player.play();
      }
    } catch (e) {
      debugPrint('AudioPlayerService: failed to load queue: $e');
      rethrow;
    }
    notifyListeners();
  }

  /// Builds a [ja.ConcatenatingAudioSource] from [tracks]. Extracted so
  /// shuffle toggles can rebuild the engine source from the same code
  /// path that [setQueue] uses.
  ja.ConcatenatingAudioSource _buildAudioSource(List<TrackModel> tracks) {
    return ja.ConcatenatingAudioSource(
      children: tracks
          .map((t) => ja.AudioSource.file(t.filePath))
          .toList(),
    );
  }

  /// Reads the persisted "Show track artwork" preference and updates the
  /// cached value. Failures default to `true` (artwork on) so a missing
  /// SharedPreferences install doesn't silently strip the cover image.
  Future<void> _refreshShowArtworkFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _showArtwork =
          prefs.getBool(ThemeController.showArtworkPrefKey) ?? true;
    } catch (e) {
      debugPrint('AudioPlayerService: showArtwork pref read failed: $e');
      _showArtwork = true;
    }
  }

  /// Updates the cached "Show track artwork" preference. Called by the
  /// settings UI after toggling so the next track switch (or queue
  /// rebuild) picks up the new value without a SharedPreferences
  /// roundtrip. The persistent storage is owned by [ThemeController].
  void setShowArtwork(bool value) {
    _showArtwork = value;
  }

  /// Whether the cached "Show track artwork" preference is currently on.
  /// Used internally and by tests; the UI watches [ThemeController]
  /// directly because that's what owns the persisted source of truth.
  bool get showArtwork => _showArtwork;

  /// Plays a single track from a list context.
  ///
  /// [contextId] identifies the surface that initiated playback so the now-
  /// playing highlight only appears in that surface (e.g. a track in a
  /// playlist won't also light up in the main library).
  Future<void> playTrackInContext(
    TrackModel clickedTrack,
    List<TrackModel> contextTracks, {
    PlaybackContextId? contextId,
  }) async {
    final clickedIndex = contextTracks.indexWhere(
      (t) => t.id == clickedTrack.id,
    );
    if (clickedIndex == -1) {
      await setQueue(
        [clickedTrack],
        playImmediately: true,
        contextId: contextId,
      );
      return;
    }
    await setQueue(
      contextTracks,
      startIndex: clickedIndex,
      playImmediately: true,
      contextId: contextId,
    );
  }

  /// Toggles play/pause for a specific track.
  ///
  /// When the clicked track is already current AND [contextId] matches the
  /// current playback context, this only toggles play/pause. Otherwise it
  /// starts a new playback session in [contextId].
  Future<void> togglePlayTrack(
    TrackModel clickedTrack,
    List<TrackModel> contextTracks, {
    PlaybackContextId? contextId,
  }) async {
    final current = currentTrack;
    final sameContext = contextId == null ||
        _playbackContextId == null ||
        _playbackContextId == contextId;

    if (current?.id != null && current?.id == clickedTrack.id && sameContext) {
      if (playing) {
        await pause();
      } else {
        await play();
      }
      return;
    }

    await playTrackInContext(
      clickedTrack,
      contextTracks,
      contextId: contextId,
    );
  }

  /// Appends tracks without changing the current item.
  void appendToQueue(List<TrackModel> tracks) {
    _queue.addAll(tracks);
    notifyListeners();
  }

  /// Clears playback state.
  Future<void> stop() async {
    await _player.stop();
    _queue = [];
    _originalQueue = [];
    _playHistory.clear();
    _lastKnownIndex = null;
    _playbackContextId = null;
    _clearSleepTimer(notify: false);
    notifyListeners();
  }

  /// Starts/replaces the one-shot sleep timer.
  ///
  /// When the timer expires playback is paused in place (the queue and
  /// position are preserved) and the timer state is cleared.
  void setSleepTimer(Duration duration) {
    if (duration <= Duration.zero) {
      throw ArgumentError.value(
        duration,
        'duration',
        'Sleep timer duration must be positive',
      );
    }

    _sleepTimer?.cancel();
    _sleepTimerEndsAt = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, () {
      unawaited(_handleSleepTimerExpired());
    });
    notifyListeners();
  }

  /// Cancels the active sleep timer, if any.
  void cancelSleepTimer() {
    _clearSleepTimer();
  }

  Future<void> _handleSleepTimerExpired() async {
    try {
      await _player.pause();
    } catch (e) {
      debugPrint('AudioPlayerService: sleep timer pause failed: $e');
    } finally {
      _clearSleepTimer();
    }
  }

  void _clearSleepTimer({bool notify = true}) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEndsAt = null;
    if (notify && !_disposed) notifyListeners();
  }

  /// Updates repeat mode with IMMEDIATE effect and UI update.
  Future<void> setRepeatMode(RepeatMode mode) async {
    repeatMode = mode;
    notifyListeners();

    final loopMode = switch (mode) {
      RepeatMode.off => ja.LoopMode.off,
      RepeatMode.all => ja.LoopMode.all,
      RepeatMode.one => ja.LoopMode.one,
    };
    await _player.setLoopMode(loopMode);

    debugPrint('AudioPlayerService: Repeat mode set to $mode');
  }

  /// Cycles repeat mode: off → all → one → off
  Future<void> cycleRepeatMode() async {
    final nextMode = switch (repeatMode) {
      RepeatMode.off => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.off,
    };
    await setRepeatMode(nextMode);
  }

  /// Gets current repeat mode (for UI).
  RepeatMode get currentRepeatMode => repeatMode;

  /// Toggles shuffle mode on/off — Spotify-style.
  ///
  /// Enabling: snapshot the current queue into [_originalQueue], then
  /// rebuild the engine queue with the currently-playing track at the
  /// front and every other track behind it in random order. The track
  /// currently playing keeps playing without interruption — only the
  /// order of what comes next changes.
  ///
  /// Disabling: restore [_originalQueue] verbatim, then seek to the
  /// current track's position in that original sequence. Again, the
  /// current track keeps playing; only the rest of the order resets.
  ///
  /// Either way, the back-stack ([_playHistory]) is reset because the
  /// queue layout changed and the old "previous" entries no longer
  /// describe a meaningful walk-back through the new order.
  ///
  /// If the queue is empty we just flip the preference; it'll get
  /// applied the next time [setQueue] runs.
  Future<void> toggleShuffle() async {
    if (_queue.isEmpty) {
      _shuffleEnabled = !_shuffleEnabled;
      notifyListeners();
      return;
    }

    final wasPlaying = _player.playing;
    final position = _player.position;
    final currentIdx = _player.currentIndex ?? 0;
    final clampedIdx = currentIdx.clamp(0, _queue.length - 1);
    final currentTrack = _queue[clampedIdx];

    _shuffleEnabled = !_shuffleEnabled;

    if (_shuffleEnabled) {
      // Enable shuffle: snapshot original order, build a fresh queue
      // with the current track first and the rest randomized after it.
      _originalQueue = List<TrackModel>.from(_queue);
      final remaining = [
        ..._queue.sublist(0, clampedIdx),
        ..._queue.sublist(clampedIdx + 1),
      ]..shuffle(_random);
      _queue = [currentTrack, ...remaining];
    } else {
      // Disable shuffle: restore original order. If we never captured
      // one (shouldn't happen, but be safe), keep the current queue
      // as-is so we don't blow away the user's playback.
      if (_originalQueue.isNotEmpty) {
        _queue = List<TrackModel>.from(_originalQueue);
      }
      _originalQueue = [];
    }

    // Find the current track in the new queue layout. It MUST exist
    // (we built the new queue around it) but defensively fall back to
    // index 0 if anything is wrong so we don't crash mid-playback.
    final newIdx = _queue.indexWhere((t) => t.id == currentTrack.id);
    final safeIdx = newIdx >= 0 ? newIdx : 0;
    _lastKnownIndex = safeIdx;
    _playHistory.clear();

    try {
      // Suppress the auto-advance guard while the engine reloads the
      // source — it could otherwise observe transient index 0 and yank
      // us back, even though the user explicitly toggled shuffle.
      _isHandlingIndexChange = true;
      await _player.setAudioSource(
        _buildAudioSource(_queue),
        initialIndex: safeIdx,
        initialPosition: position,
      );
      if (wasPlaying) {
        await _player.play();
      }
    } catch (e) {
      debugPrint('AudioPlayerService: toggleShuffle failed: $e');
    } finally {
      _isHandlingIndexChange = false;
    }
    notifyListeners();
  }

  /// Re-randomizes the entire queue while keeping shuffle on. Called
  /// when [skipNext] reaches the end of the shuffled queue with
  /// [RepeatMode.all], so the user keeps getting fresh random order
  /// instead of replaying the same shuffled sequence forever.
  ///
  /// The track that just finished is rotated away from index 0 so the
  /// "next" track after the loop boundary can't be the same one the
  /// listener literally just heard.
  Future<void> _reshuffleAndRestart() async {
    if (_queue.isEmpty) return;

    final lastPlayed = currentTrack;
    final shuffled = List<TrackModel>.from(_queue)..shuffle(_random);
    if (lastPlayed != null &&
        shuffled.length > 1 &&
        shuffled.first.id == lastPlayed.id) {
      // Rotate so the same song doesn't immediately replay.
      shuffled.add(shuffled.removeAt(0));
    }
    _queue = shuffled;
    _playHistory.clear();
    _lastKnownIndex = 0;

    try {
      _isHandlingIndexChange = true;
      await _player.setAudioSource(
        _buildAudioSource(_queue),
        initialIndex: 0,
      );
      await _player.play();
    } catch (e) {
      debugPrint('AudioPlayerService: reshuffle failed: $e');
    } finally {
      _isHandlingIndexChange = false;
    }
    notifyListeners();
  }

  /// Starts or resumes the current source.
  Future<void> play() async {
    if (currentTrack == null) return;

    if (!isReady) {
      debugPrint('AudioPlayerService: Cannot play - player not ready');
      return;
    }

    await _player.play();
  }

  /// Pauses playback.
  Future<void> pause() async {
    await _player.pause();
  }

  /// Seeks within the current track.
  Future<void> seek(Duration target) async {
    if (!isReady) {
      debugPrint('AudioPlayerService: Cannot seek - player not ready');
      return;
    }

    final maxDuration = _player.duration;
    if (maxDuration == null || maxDuration == Duration.zero) {
      debugPrint('AudioPlayerService: Cannot seek - duration unknown');
      return;
    }

    final safeDuration = target < Duration.zero
        ? Duration.zero
        : (target > maxDuration ? maxDuration : target);

    try {
      await _player.seek(safeDuration);
    } catch (e) {
      debugPrint('AudioPlayerService: Seek failed: $e');
    }
  }

  /// Sets output volume (0.0–1.0) with INSTANT effect.
  Future<void> setVolumeLinear(double v) async {
    volume = v.clamp(0.0, 1.0);
    notifyListeners();
    await _player.setVolume(volume);
  }

  /// Moves to the next track.
  ///
  /// Shuffle mode adds two behaviors on top of the regular sequential
  /// advance:
  /// 1. The track being left is pushed onto [_playHistory] so a later
  ///    [skipPrevious] can step back through what the listener really
  ///    heard, not what's adjacent in the (possibly reshuffled) queue.
  /// 2. Reaching the end of a shuffled queue with [RepeatMode.all]
  ///    triggers [_reshuffleAndRestart] instead of just looping the
  ///    same shuffled order over and over.
  Future<void> skipNext() async {
    if (_queue.isEmpty) return;

    final currentIdx = _player.currentIndex ?? 0;
    final isLastTrack = currentIdx >= _queue.length - 1;

    // Record the current track on the back-stack BEFORE we move off it,
    // so skipPrevious(shuffle) walks back through actual listening
    // history. We do this in shuffle mode only — non-shuffle's
    // back-stack is the queue order itself.
    if (_shuffleEnabled) {
      final track = currentTrack;
      if (track != null) _playHistory.add(track);
    }

    if (isLastTrack) {
      if (repeatMode == RepeatMode.all &&
          _shuffleEnabled &&
          _queue.length > 1) {
        // End of shuffled queue + repeat-all: regenerate fresh random
        // order and start it from the top.
        await _reshuffleAndRestart();
        return;
      }
      if (repeatMode == RepeatMode.off) {
        debugPrint(
            'AudioPlayerService: At last track with repeat OFF - not advancing');
        return;
      }
      // Repeat-all (non-shuffle): just-audio's seekToNext handles the
      // wrap to index 0.
    }

    if (!isLastTrack) {
      _lastKnownIndex = currentIdx + 1;
    } else if (repeatMode == RepeatMode.all) {
      _lastKnownIndex = 0;
    }

    await _player.seekToNext();
    // Wake up Provider listeners immediately so the mini-player title /
    // artist / now-playing highlight repaint without waiting for the index
    // stream's next async tick.
    notifyListeners();
  }

  /// Moves to the previous track.
  ///
  /// In shuffle mode, "previous" is the actual back-stack of recently
  /// played tracks ([_playHistory]) — same as Spotify. The current
  /// queue order is irrelevant once tracks have been re-randomized,
  /// so we walk back through what the listener really heard.
  ///
  /// Outside shuffle, or when the back-stack is empty (start of the
  /// shuffle session), we fall through to the engine's seekToPrevious.
  Future<void> skipPrevious() async {
    if (_queue.isEmpty) return;

    // Restart current track if more than 2.5s in
    if (_player.position.inMilliseconds > 2500) {
      await _player.seek(Duration.zero);
      return;
    }

    if (_shuffleEnabled && _playHistory.isNotEmpty) {
      // Pop the most recently played track off the back-stack and seek
      // to it in the current queue. If for some reason it's no longer
      // in the queue (shouldn't happen — we keep the same set of tracks
      // when reshuffling), fall through to the default behavior.
      final prev = _playHistory.removeLast();
      final idx = _queue.indexWhere((t) => t.id == prev.id);
      if (idx >= 0) {
        // Set _lastKnownIndex BEFORE the seek so the index-stream
        // listener sees `index == _lastKnownIndex` and skips both the
        // auto-advance guard and the back-stack auto-push (we're
        // stepping back, not moving on).
        _lastKnownIndex = idx;
        await _player.seek(Duration.zero, index: idx);
        notifyListeners();
        return;
      }
    }

    final currentIdx = _player.currentIndex ?? 0;
    final isFirstTrack = currentIdx <= 0;

    // When repeat is OFF and we're at the first track, just restart
    if (repeatMode == RepeatMode.off && isFirstTrack) {
      await _player.seek(Duration.zero);
      return;
    }

    // Update last known index before seeking
    if (!isFirstTrack) {
      _lastKnownIndex = currentIdx - 1;
    } else if (repeatMode == RepeatMode.all) {
      _lastKnownIndex = _queue.length - 1;
    }

    await _player.seekToPrevious();
    // Same rationale as skipNext: notify on user-initiated track change so
    // the UI repaints synchronously instead of one frame late.
    notifyListeners();
  }

  /// Records play history for a specific track.
  Future<void> _recordPlayForTrack(TrackModel track) async {
    if (track.id == null) return;

    try {
      await _db.recordPlay(track.id!);

      final d = _player.duration;
      if (d != null && d > Duration.zero && track.durationMs == 0) {
        await _db.updateTrack(
          track.copyWith(durationMs: d.inMilliseconds),
        );
      }
    } catch (e) {
      debugPrint('AudioPlayerService: failed to record play: $e');
    }
  }

  @override
  void dispose() {
    // Stop playback and clear all streams immediately
    _disposed = true;
    _sleepTimer?.cancel();
    _player.stop();
    _player.dispose();
    super.dispose();
  }
}
