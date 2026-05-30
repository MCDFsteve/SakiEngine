import 'dart:async';
import 'package:flutter/material.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:sakiengine/src/config/asset_manager.dart';

class MoviePlayer extends StatefulWidget {
  final String movieFile;
  final VoidCallback? onVideoEnd;
  final bool autoPlay;
  final bool looping;
  final int? repeatCount; // null 表示仅播放一次
  final Duration? loopStart;
  final bool backgroundMode;
  final bool pingPongLoop;
  final BoxFit fit;
  final Alignment alignment;

  const MoviePlayer({
    super.key,
    required this.movieFile,
    this.onVideoEnd,
    this.autoPlay = true,
    this.looping = false,
    this.repeatCount,
    this.loopStart,
    this.backgroundMode = false,
    this.pingPongLoop = false,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
  });

  @override
  State<MoviePlayer> createState() => _MoviePlayerState();
}

class _MoviePlayerState extends State<MoviePlayer> {
  Player? _player;
  VideoController? _videoController;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<String>? _errorSubscription;
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  bool _isInitialized = false;
  bool _hasError = false;
  String? _errorMessage;
  bool _hasCalledOnEnd = false;
  int _currentPlayCount = 0;
  Duration _mediaDuration = Duration.zero;
  bool _isPingPongReversePhase = false;
  bool _isPingPongTransitioning = false;

  bool get _isPingPongLoopEnabled =>
      widget.pingPongLoop && widget.loopStart != null;

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
    if (oldWidget.movieFile != widget.movieFile ||
        oldWidget.looping != widget.looping ||
        oldWidget.loopStart != widget.loopStart ||
        oldWidget.pingPongLoop != widget.pingPongLoop) {
      _initializeVideo();
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
        _hasCalledOnEnd = false;
        _currentPlayCount = 0;
        _mediaDuration = Duration.zero;
        _isPingPongReversePhase = false;
        _isPingPongTransitioning = false;
      });

      String? videoPath = await AssetManager().findAsset(widget.movieFile);
      videoPath ??=
          await AssetManager().findAsset('videos/${widget.movieFile}');
      videoPath ??=
          await AssetManager().findAsset('movies/${widget.movieFile}');

      if (!mounted) return;

      if (videoPath == null) {
        _setError('找不到视频文件: ${widget.movieFile}');
        return;
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

      final mediaSource = _buildMediaSource(videoPath);
      await _player!.open(Media(mediaSource), play: widget.autoPlay);

      if (!mounted) return;
      setState(() {
        _isInitialized = true;
      });
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

    _durationSubscription = _player!.stream.duration.listen((duration) {
      _mediaDuration = duration;
    });

    _positionSubscription = _player!.stream.position.listen((position) {
      _handlePingPongPosition(position);
    });

    _errorSubscription = _player!.stream.error.listen((message) {
      if (message.isNotEmpty) {
        _setError('视频播放出错: $message');
      }
    });
  }

  void _handlePingPongPosition(Duration position) {
    if (!_isPingPongLoopEnabled || _isPingPongTransitioning) {
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

    _isPingPongTransitioning = true;
    try {
      await player.setPlaybackDirection(PlaybackDirection.backward);
      await player.seek(duration);
      _isPingPongReversePhase = true;
      await player.play();
    } on UnsupportedError {
      _isPingPongReversePhase = false;
      try {
        await player.seek(loopStart);
        await player.play();
      } catch (_) {}
    } catch (_) {} finally {
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
    } catch (_) {} finally {
      _isPingPongTransitioning = false;
    }
  }

  void _handlePlaybackCompleted() async {
    final player = _player;
    if (player == null) {
      return;
    }

    if (_isPingPongLoopEnabled) {
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
    await _durationSubscription?.cancel();
    await _positionSubscription?.cancel();
    await _errorSubscription?.cancel();
    _completedSubscription = null;
    _durationSubscription = null;
    _positionSubscription = null;
    _errorSubscription = null;

    final player = _player;
    _player = null;
    _videoController = null;
    _hasCalledOnEnd = false;
    _currentPlayCount = 0;
    _mediaDuration = Duration.zero;
    _isPingPongReversePhase = false;
    _isPingPongTransitioning = false;

    await player?.dispose();
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
