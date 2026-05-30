import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:sakiengine/src/config/asset_manager.dart';

class MoviePlayer extends StatefulWidget {
  final String movieFile;
  final VoidCallback? onVideoEnd;
  final VoidCallback? onVideoReady;
  final ValueChanged<Duration>? onPositionChanged;
  final bool autoPlay;
  final bool looping;
  final int? repeatCount; // null 表示仅播放一次
  final Duration? loopStart;
  final bool backgroundMode;
  final bool pingPongLoop;
  final String? pingPongReverseMovieFile;
  final BoxFit fit;
  final Alignment alignment;

  const MoviePlayer({
    super.key,
    required this.movieFile,
    this.onVideoEnd,
    this.onVideoReady,
    this.onPositionChanged,
    this.autoPlay = true,
    this.looping = false,
    this.repeatCount,
    this.loopStart,
    this.backgroundMode = false,
    this.pingPongLoop = false,
    this.pingPongReverseMovieFile,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
  });

  @override
  State<MoviePlayer> createState() => _MoviePlayerState();
}

class _MoviePlayerState extends State<MoviePlayer> {
  static const Duration _pingPongReverseEntryOffset =
      Duration(milliseconds: 120);

  Player? _player;
  VideoController? _videoController;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<bool>? _bufferingSubscription;
  StreamSubscription<String>? _errorSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<int?>? _widthSubscription;
  bool _isInitialized = false;
  bool _hasError = false;
  String? _errorMessage;
  bool _hasReportedReady = false;
  bool _hasCalledOnEnd = false;
  int _currentPlayCount = 0;
  Duration _mediaDuration = Duration.zero;
  bool _isBuffering = true;
  bool _hasVideoSize = false;
  bool _isPingPongReversePhase = false;
  bool _isPingPongTransitioning = false;
  bool _isPreparedPingPongLoopActive = false;
  String? _primaryMediaSource;
  String? _pingPongReverseMediaSource;

  bool get _isPingPongLoopEnabled =>
      widget.pingPongLoop && widget.loopStart != null;

  bool get _hasPreparedPingPongReverseSource =>
      _isPingPongLoopEnabled &&
      _primaryMediaSource != null &&
      _pingPongReverseMediaSource != null;

  Duration? _currentDuration() {
    if (_mediaDuration > Duration.zero) {
      return _mediaDuration;
    }
    final duration = _player?.state.duration ?? Duration.zero;
    if (duration > Duration.zero) {
      return duration;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  @override
  void didUpdateWidget(MoviePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final shouldReinitialize = oldWidget.movieFile != widget.movieFile ||
        oldWidget.looping != widget.looping ||
        oldWidget.loopStart != widget.loopStart ||
        oldWidget.backgroundMode != widget.backgroundMode ||
        oldWidget.pingPongLoop != widget.pingPongLoop ||
        oldWidget.pingPongReverseMovieFile != widget.pingPongReverseMovieFile;
    if (shouldReinitialize) {
      _initializeVideo();
      return;
    }

    if (oldWidget.autoPlay != widget.autoPlay) {
      unawaited(_syncPlaybackWithAutoPlay());
    }
  }

  Future<void> _initializeVideo() async {
    await _disposePlayer();

    try {
      if (widget.movieFile.isEmpty) {
        _setError('视频文件名为空');
        return;
      }

      setState(() {
        _isInitialized = false;
        _hasError = false;
        _errorMessage = null;
        _hasReportedReady = false;
        _hasCalledOnEnd = false;
        _currentPlayCount = 0;
        _mediaDuration = Duration.zero;
        _isBuffering = true;
        _hasVideoSize = false;
        _isPingPongReversePhase = false;
        _isPingPongTransitioning = false;
        _isPreparedPingPongLoopActive = false;
      });
      _primaryMediaSource = null;
      _pingPongReverseMediaSource = null;

      final videoPath = await _resolveMoviePath(widget.movieFile);

      if (!mounted) return;

      if (videoPath == null) {
        _setError('找不到视频文件: ${widget.movieFile}');
        return;
      }

      final reverseMovieFile = widget.pingPongReverseMovieFile?.trim();
      String? reverseVideoPath;
      if (_isPingPongLoopEnabled &&
          reverseMovieFile != null &&
          reverseMovieFile.isNotEmpty) {
        reverseVideoPath = await _resolveMoviePath(reverseMovieFile);

        if (!mounted) return;

        if (reverseVideoPath == null) {
          _setError('找不到反向视频文件: $reverseMovieFile');
          return;
        }
      }

      _player = Player();
      _videoController = VideoController(_player!);
      _listenPlayerEvents();

      final playlistMode = _isPingPongLoopEnabled
          ? PlaylistMode.none
          : (widget.looping && widget.loopStart == null
              ? PlaylistMode.loop
              : PlaylistMode.none);
      await _player!.setPlaylistMode(playlistMode);
      await _applyBackgroundVolume();

      final mediaSource = _buildMediaSource(videoPath);
      _primaryMediaSource = mediaSource;
      _pingPongReverseMediaSource =
          reverseVideoPath == null ? null : _buildMediaSource(reverseVideoPath);
      await _player!.open(Media(mediaSource), play: widget.autoPlay);
      await _applyBackgroundVolume();

      if (!mounted) return;
      setState(() {
        _isInitialized = true;
      });
      _isBuffering = _player?.state.buffering ?? _isBuffering;
      _hasVideoSize = _hasVideoSize || (_player?.state.width != null);
      _maybeReportVideoReady();
    } catch (e) {
      _setError('视频初始化失败: $e');
    }
  }

  void _listenPlayerEvents() {
    if (_player == null) return;

    _completedSubscription = _player!.stream.completed.listen((completed) {
      if (completed) {
        _handlePlaybackCompleted();
      }
    });

    _bufferingSubscription = _player!.stream.buffering.listen((buffering) {
      _isBuffering = buffering;
      _maybeReportVideoReady();
    });

    _durationSubscription = _player!.stream.duration.listen((duration) {
      _mediaDuration = duration;
      _maybeReportVideoReady();
    });

    _positionSubscription = _player!.stream.position.listen((position) {
      widget.onPositionChanged?.call(position);
      _handlePingPongPosition(position);
    });

    _widthSubscription = _player!.stream.width.listen((width) {
      if (width != null && width > 0) {
        _hasVideoSize = true;
        _maybeReportVideoReady();
      }
    });

    _errorSubscription = _player!.stream.error.listen((message) {
      if (message.isNotEmpty) {
        _setError('视频播放出错: $message');
      }
    });
  }

  void _handlePingPongPosition(Duration position) {
    if (!_isPingPongLoopEnabled ||
        _hasPreparedPingPongReverseSource ||
        _isPingPongTransitioning) {
      return;
    }

    final loopStart = widget.loopStart;
    if (loopStart == null) {
      return;
    }

    const threshold = Duration(milliseconds: 120);
    if (_isPingPongReversePhase) {
      if (position <= loopStart + threshold) {
        unawaited(_switchPingPongToForward());
      }
    }
  }

  void _maybeReportVideoReady() {
    if (_hasReportedReady || !_isInitialized || _hasError) {
      return;
    }

    final hasDuration = _mediaDuration > Duration.zero ||
        (_player?.state.duration ?? Duration.zero) > Duration.zero;
    final hasVideoSize = _hasVideoSize || (_player?.state.width != null);
    final isBuffering = _isBuffering || (_player?.state.buffering ?? false);
    if (isBuffering || (!hasDuration && !hasVideoSize)) {
      return;
    }

    _hasReportedReady = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      widget.onVideoReady?.call();
    });
  }

  Future<void> _syncPlaybackWithAutoPlay() async {
    final player = _player;
    if (player == null || !_isInitialized) {
      return;
    }

    try {
      if (widget.autoPlay) {
        await player.play();
      } else {
        await player.pause();
      }
      await _applyBackgroundVolume();
    } catch (_) {}
  }

  Future<void> _startPingPongReverse() async {
    final player = _player;
    final loopStart = widget.loopStart;
    if (player == null || loopStart == null) {
      return;
    }

    final duration = _currentDuration();
    if (duration == null || duration <= loopStart) {
      return;
    }

    final reverseSeekTarget = duration - _pingPongReverseEntryOffset > loopStart
        ? duration - _pingPongReverseEntryOffset
        : duration - const Duration(milliseconds: 1);

    _isPingPongTransitioning = true;
    try {
      await player.setPlaybackDirection(PlaybackDirection.backward);
      await player.seek(reverseSeekTarget);
      _isPingPongReversePhase = true;
      await player.play();
    } on UnsupportedError {
      _isPingPongReversePhase = false;
      try {
        await player.seek(loopStart);
        await player.play();
      } catch (_) {}
    } catch (_) {
    } finally {
      _isPingPongTransitioning = false;
    }
  }

  Future<void> _switchPingPongToForward() async {
    final player = _player;
    final loopStart = widget.loopStart;
    if (player == null || loopStart == null) {
      return;
    }
    if (_isPingPongTransitioning) {
      return;
    }

    _isPingPongTransitioning = true;
    try {
      await player.setPlaybackDirection(PlaybackDirection.forward);
      await player.seek(loopStart);
      _isPingPongReversePhase = false;
      await player.play();
    } on UnsupportedError {
      _isPingPongReversePhase = false;
      try {
        await player.seek(loopStart);
        await player.play();
      } catch (_) {}
    } catch (_) {
    } finally {
      _isPingPongTransitioning = false;
    }
  }

  Future<void> _startPreparedPingPongLoop() async {
    final player = _player;
    final loopStart = widget.loopStart;
    final forwardSource = _primaryMediaSource;
    final reverseSource = _pingPongReverseMediaSource;
    if (player == null ||
        loopStart == null ||
        forwardSource == null ||
        reverseSource == null) {
      return;
    }

    _isPingPongTransitioning = true;
    try {
      await player.setPlaylistMode(PlaylistMode.loop);
      await _applyBackgroundVolume();
      await player.open(
        Playlist(
          [
            Media(reverseSource),
            Media(forwardSource, start: loopStart),
          ],
        ),
        play: true,
      );
      await _applyBackgroundVolume();
      _isPreparedPingPongLoopActive = true;
    } catch (_) {
      _isPreparedPingPongLoopActive = false;
      try {
        await player.setPlaylistMode(PlaylistMode.none);
        await _applyBackgroundVolume();
        await player.open(
          Media(forwardSource, start: loopStart),
          play: true,
        );
        await _applyBackgroundVolume();
      } catch (_) {}
    } finally {
      _isPingPongTransitioning = false;
    }
  }

  void _handlePlaybackCompleted() async {
    final player = _player;
    if (player == null) {
      return;
    }

    if (_isPingPongLoopEnabled) {
      if (_hasPreparedPingPongReverseSource) {
        if (_isPingPongTransitioning) {
          return;
        }
        if (!_isPreparedPingPongLoopActive) {
          await _startPreparedPingPongLoop();
        }
        return;
      }
      if (_isPingPongTransitioning) {
        return;
      }
      if (_isPingPongReversePhase) {
        await _switchPingPongToForward();
      } else {
        await _startPingPongReverse();
      }
      return;
    }

    if (_hasCalledOnEnd || widget.looping) {
      if (widget.looping && widget.loopStart != null) {
        try {
          await _player!.seek(widget.loopStart!);
          await _player!.play();
        } catch (_) {}
      }
      return;
    }

    _currentPlayCount++;
    final targetRepeatCount = widget.repeatCount ?? 1;

    if (_currentPlayCount < targetRepeatCount) {
      try {
        await _player!.seek(Duration.zero);
        await _player!.play();
      } catch (_) {}
    } else {
      _hasCalledOnEnd = true;
      if (widget.onVideoEnd != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            widget.onVideoEnd!();
          }
        });
      }
    }
  }

  String _buildMediaSource(String path) {
    final trimmed = path.trim();
    final lower = trimmed.toLowerCase();

    if (trimmed.startsWith('asset:///')) {
      return trimmed;
    }

    if (lower.startsWith('assets/') || lower.startsWith('packages/')) {
      return 'asset:///$trimmed';
    }

    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasScheme) {
      return trimmed;
    }

    if (trimmed.startsWith('/')) {
      return Uri.file(trimmed).toString();
    }

    return 'asset:///Assets/$trimmed';
  }

  void _setError(String message) {
    if (!mounted) return;
    setState(() {
      _hasError = true;
      _errorMessage = message;
      _isInitialized = false;
    });
  }

  Future<void> _disposePlayer() async {
    await _completedSubscription?.cancel();
    await _bufferingSubscription?.cancel();
    await _durationSubscription?.cancel();
    await _positionSubscription?.cancel();
    await _widthSubscription?.cancel();
    await _errorSubscription?.cancel();
    _completedSubscription = null;
    _bufferingSubscription = null;
    _durationSubscription = null;
    _positionSubscription = null;
    _widthSubscription = null;
    _errorSubscription = null;

    final player = _player;
    _player = null;
    _videoController = null;
    _hasReportedReady = false;
    _hasCalledOnEnd = false;
    _currentPlayCount = 0;
    _mediaDuration = Duration.zero;
    _isBuffering = true;
    _hasVideoSize = false;
    _isPingPongReversePhase = false;
    _isPingPongTransitioning = false;
    _isPreparedPingPongLoopActive = false;
    _primaryMediaSource = null;
    _pingPongReverseMediaSource = null;

    await player?.dispose();
  }

  Future<String?> _resolveMoviePath(String movieFile) async {
    String? videoPath = await AssetManager().findAsset(movieFile);
    videoPath ??= await AssetManager().findAsset('videos/$movieFile');
    videoPath ??= await AssetManager().findAsset('movies/$movieFile');
    return videoPath;
  }

  Future<void> _applyBackgroundVolume() async {
    if (!widget.backgroundMode) {
      return;
    }
    await _player?.setVolume(0.0);
  }

  @override
  void dispose() {
    unawaited(_disposePlayer());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      if (widget.backgroundMode) {
        return const SizedBox.expand(
          child: ColoredBox(color: Colors.black),
        );
      }

      if (_errorMessage?.contains('视频文件名为空') == true) {
        return const SizedBox.shrink();
      }

      return Container(
        color: Colors.black,
        child: Center(
          child: Text(
            _errorMessage ?? '视频加载失败',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
            ),
          ),
        ),
      );
    }

    if (!_isInitialized || _videoController == null) {
      if (widget.backgroundMode) {
        return const SizedBox.expand(
          child: ColoredBox(color: Colors.black),
        );
      }

      return Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(
            color: Colors.black,
          ),
        ),
      );
    }

    return SizedBox.expand(
      child: ColoredBox(
        color: Colors.black,
        child: Video(
          controller: _videoController!,
          fit: widget.fit,
          alignment: widget.alignment,
          controls: null,
          fill: Colors.black,
        ),
      ),
    );
  }
}
