import 'dart:async';

import 'package:erika_flutter/erika_flutter.dart';
import 'package:flutter/material.dart';
import 'package:sakiengine/src/config/asset_manager.dart';
import 'package:sakiengine/src/utils/smart_asset_image.dart';

enum MovieVideoAlphaMode { opaque, packedAlphaRight }

extension on MovieVideoAlphaMode {
  ErikaVideoAlphaMode get erikaValue => switch (this) {
    MovieVideoAlphaMode.opaque => ErikaVideoAlphaMode.opaque,
    MovieVideoAlphaMode.packedAlphaRight =>
      ErikaVideoAlphaMode.packedAlphaRight,
  };
}

class MoviePlayer extends StatefulWidget {
  final String movieFile;
  final VoidCallback? onVideoEnd;
  final VoidCallback? onVideoReady;
  final ValueChanged<Duration>? onPositionChanged;
  final bool autoPlay;
  final bool looping;
  final int? repeatCount;
  final Duration? loopStart;
  final Duration initialPosition;
  final bool backgroundMode;
  final bool pingPongLoop;
  final String? pingPongReverseMovieFile;
  final String? sequentialMovieFile;
  final bool sequentialLooping;
  final BoxFit fit;
  final Alignment alignment;
  final String? placeholderImageAssetName;
  final double playbackRate;
  final Color backgroundColor;
  final MovieVideoAlphaMode videoAlphaMode;
  final BlendMode videoBlendMode;
  final double videoOpacity;

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
    this.initialPosition = Duration.zero,
    this.backgroundMode = false,
    this.pingPongLoop = false,
    this.pingPongReverseMovieFile,
    this.sequentialMovieFile,
    this.sequentialLooping = false,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.placeholderImageAssetName,
    this.playbackRate = 1.0,
    this.backgroundColor = Colors.black,
    this.videoAlphaMode = MovieVideoAlphaMode.opaque,
    this.videoBlendMode = BlendMode.srcOver,
    this.videoOpacity = 1.0,
  }) : assert(initialPosition >= Duration.zero),
       assert(playbackRate > 0),
       assert(videoOpacity >= 0.0 && videoOpacity <= 1.0);

  @override
  State<MoviePlayer> createState() => _MoviePlayerState();
}

class _MoviePlayerState extends State<MoviePlayer> {
  ErikaPlayer? _player;
  ErikaPlayer? _secondaryPlayer;
  StreamSubscription<ErikaPlayerEvent>? _eventSubscription;
  StreamSubscription<ErikaPlayerEvent>? _secondaryEventSubscription;

  bool _isInitialized = false;
  bool _hasError = false;
  String? _errorMessage;
  bool _hasReportedReady = false;
  bool _surfaceAttached = false;
  bool _hasVideoParams = false;
  bool _hasStartedPlayback = false;
  bool _secondaryHasStartedPlayback = false;
  bool _showSecondaryPlayer = false;
  bool _handlingPrimaryCompletion = false;
  bool _handlingSecondaryCompletion = false;
  bool _hasCalledOnEnd = false;
  int _currentPlayCount = 0;
  int _initializationGeneration = 0;
  int _videoWidth = 0;
  int _videoHeight = 0;
  ErikaPlaybackState _playbackState = ErikaPlaybackState.idle;
  Completer<void>? _surfaceAttachedCompleter;
  Completer<void>? _secondarySurfaceAttachedCompleter;
  Completer<void>? _secondaryPlaybackProgressCompleter;

  bool get _hasSequentialFollowUp =>
      widget.sequentialMovieFile?.trim().isNotEmpty == true;

  bool get _hasSecondaryMedia =>
      widget.pingPongReverseMovieFile?.trim().isNotEmpty == true ||
      _hasSequentialFollowUp;

  bool get _hasPlaceholderImage =>
      widget.placeholderImageAssetName?.trim().isNotEmpty == true;

  bool get _playbackCanBeReportedReady =>
      _playbackState == ErikaPlaybackState.ready ||
      _playbackState == ErikaPlaybackState.playing ||
      _playbackState == ErikaPlaybackState.paused;

  @override
  void initState() {
    super.initState();
    unawaited(_initializeVideo());
  }

  @override
  void didUpdateWidget(covariant MoviePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final shouldReinitialize =
        oldWidget.movieFile != widget.movieFile ||
        oldWidget.looping != widget.looping ||
        oldWidget.loopStart != widget.loopStart ||
        oldWidget.initialPosition != widget.initialPosition ||
        oldWidget.backgroundMode != widget.backgroundMode ||
        oldWidget.pingPongLoop != widget.pingPongLoop ||
        oldWidget.pingPongReverseMovieFile != widget.pingPongReverseMovieFile ||
        oldWidget.sequentialMovieFile != widget.sequentialMovieFile ||
        oldWidget.sequentialLooping != widget.sequentialLooping ||
        oldWidget.videoAlphaMode != widget.videoAlphaMode;
    if (shouldReinitialize) {
      unawaited(_initializeVideo());
      return;
    }
    if (oldWidget.autoPlay != widget.autoPlay) {
      unawaited(_syncPlaybackWithAutoPlay());
    }
    if (oldWidget.playbackRate != widget.playbackRate) {
      unawaited(_applyPlaybackRate());
    }
  }

  Future<void> _initializeVideo() async {
    final generation = ++_initializationGeneration;
    await _disposePlayers();
    if (!mounted || generation != _initializationGeneration) {
      return;
    }

    if (widget.movieFile.trim().isEmpty) {
      _setError('视频文件名为空');
      return;
    }

    setState(() {
      _isInitialized = false;
      _hasError = false;
      _errorMessage = null;
      _hasReportedReady = false;
      _surfaceAttached = false;
      _hasVideoParams = false;
      _hasStartedPlayback = false;
      _secondaryHasStartedPlayback = false;
      _showSecondaryPlayer = false;
      _handlingPrimaryCompletion = false;
      _handlingSecondaryCompletion = false;
      _hasCalledOnEnd = false;
      _currentPlayCount = 0;
      _videoWidth = 0;
      _videoHeight = 0;
      _playbackState = ErikaPlaybackState.idle;
    });
    _secondaryPlaybackProgressCompleter = null;
    final surfaceAttachedCompleter = Completer<void>();
    _surfaceAttachedCompleter = surfaceAttachedCompleter;

    try {
      final videoPath = await _resolveMoviePath(widget.movieFile);
      if (!mounted || generation != _initializationGeneration) {
        return;
      }
      if (videoPath == null) {
        _setError('找不到视频文件: ${widget.movieFile}');
        return;
      }

      String? secondaryPath;
      final secondaryMovieFile =
          widget.pingPongReverseMovieFile?.trim().isNotEmpty == true
          ? widget.pingPongReverseMovieFile!.trim()
          : widget.sequentialMovieFile?.trim();
      if (_hasSecondaryMedia && secondaryMovieFile != null) {
        secondaryPath = await _resolveMoviePath(secondaryMovieFile);
        if (!mounted || generation != _initializationGeneration) {
          return;
        }
        if (secondaryPath == null) {
          _setError('找不到后续视频文件: $secondaryMovieFile');
          return;
        }
      }

      final player = ErikaPlayer(
        allowBackgroundPlayback: widget.backgroundMode,
        videoAlphaMode: widget.videoAlphaMode.erikaValue,
      );
      _player = player;
      _eventSubscription = player.events.listen(
        (event) => _handlePrimaryEvent(player, event),
        onError: (Object error, StackTrace stackTrace) {
          if (_player == player) {
            _setError('视频事件流出错: $error');
          }
        },
      );

      if (mounted) {
        setState(() {
          _isInitialized = true;
        });
      }

      await player.open(videoPath);
      await surfaceAttachedCompleter.future.timeout(
        const Duration(seconds: 1),
        onTimeout: () {},
      );
      if (!mounted || generation != _initializationGeneration) {
        return;
      }
      await player.setPlaybackRate(widget.playbackRate);
      if (widget.backgroundMode) {
        await player.setVolume(0.0);
      }
      if (widget.initialPosition > Duration.zero) {
        await player.seek(widget.initialPosition);
      }
      if (widget.autoPlay) {
        await player.play();
      }

      if (secondaryPath != null &&
          mounted &&
          generation == _initializationGeneration) {
        await _initializeSecondaryPlayer(secondaryPath, generation);
      }
    } catch (error) {
      if (mounted && generation == _initializationGeneration) {
        _setError('视频初始化失败: $error');
      }
    }
  }

  Future<void> _initializeSecondaryPlayer(String path, int generation) async {
    final player = ErikaPlayer(
      allowBackgroundPlayback: widget.backgroundMode,
      videoAlphaMode: widget.videoAlphaMode.erikaValue,
    );
    _secondaryPlayer = player;
    _secondarySurfaceAttachedCompleter = Completer<void>();
    _secondaryEventSubscription = player.events.listen(
      (event) => _handleSecondaryEvent(player, event),
      onError: (Object _, StackTrace _) {},
    );
    if (mounted) {
      setState(() {});
    }
    await player.open(path);
    await player.setPlaybackRate(widget.playbackRate);
    if (widget.backgroundMode) {
      await player.setVolume(0.0);
    }
    if (!mounted || generation != _initializationGeneration) {
      return;
    }
  }

  void _handlePrimaryEvent(ErikaPlayer player, ErikaPlayerEvent event) {
    if (!mounted || _player != player) {
      return;
    }
    switch (event.kind) {
      case ErikaEventKind.stateChanged:
        _playbackState = event.state;
        if (event.state == ErikaPlaybackState.playing) {
          _hasStartedPlayback = true;
        } else if (event.state == ErikaPlaybackState.stopped &&
            _hasStartedPlayback) {
          unawaited(_handlePrimaryPlaybackCompleted());
        } else if (event.state == ErikaPlaybackState.error) {
          _setError(event.message ?? event.error ?? '视频播放出错');
          return;
        }
        break;
      case ErikaEventKind.positionChanged:
        widget.onPositionChanged?.call(event.position);
        break;
      case ErikaEventKind.bufferingChanged:
        break;
      case ErikaEventKind.videoParamsChanged:
        if (event.video.width > 0 && event.video.height > 0) {
          _hasVideoParams = true;
          final logicalWidth =
              widget.videoAlphaMode == MovieVideoAlphaMode.packedAlphaRight
              ? event.video.width ~/ 2
              : event.video.width;
          if (_videoWidth != logicalWidth ||
              _videoHeight != event.video.height) {
            setState(() {
              _videoWidth = logicalWidth;
              _videoHeight = event.video.height;
            });
          }
        }
        break;
      case ErikaEventKind.surfaceAttached:
        _surfaceAttached = true;
        final completer = _surfaceAttachedCompleter;
        if (completer != null && !completer.isCompleted) {
          completer.complete();
        }
        break;
      case ErikaEventKind.error:
        _setError(event.message ?? event.error ?? '视频播放出错');
        return;
      default:
        break;
    }
    _maybeReportVideoReady();
  }

  void _handleSecondaryEvent(ErikaPlayer player, ErikaPlayerEvent event) {
    if (!mounted || _secondaryPlayer != player) {
      return;
    }
    if (event.kind == ErikaEventKind.stateChanged) {
      if (event.state == ErikaPlaybackState.playing) {
        _secondaryHasStartedPlayback = true;
      } else if (event.state == ErikaPlaybackState.stopped &&
          _secondaryHasStartedPlayback) {
        unawaited(_handleSecondaryPlaybackCompleted());
      }
    } else if (event.kind == ErikaEventKind.surfaceAttached) {
      final completer = _secondarySurfaceAttachedCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
    } else if (event.kind == ErikaEventKind.positionChanged) {
      final completer = _secondaryPlaybackProgressCompleter;
      if (_secondaryHasStartedPlayback &&
          completer != null &&
          !completer.isCompleted) {
        completer.complete();
      }
    }
  }

  void _maybeReportVideoReady() {
    if (_hasReportedReady ||
        !_isInitialized ||
        _hasError ||
        !_surfaceAttached ||
        !_hasVideoParams ||
        !_playbackCanBeReportedReady) {
      return;
    }
    _hasReportedReady = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onVideoReady?.call();
      }
    });
  }

  Future<void> _handlePrimaryPlaybackCompleted() async {
    final player = _player;
    if (player == null || _handlingPrimaryCompletion) {
      return;
    }
    _handlingPrimaryCompletion = true;
    _hasStartedPlayback = false;
    try {
      final secondaryPlayer = _secondaryPlayer;
      if (secondaryPlayer != null &&
          (widget.pingPongLoop || _hasSequentialFollowUp)) {
        await _secondarySurfaceAttachedCompleter?.future.timeout(
          const Duration(seconds: 1),
          onTimeout: () {},
        );
        if (!mounted || _player != player) {
          return;
        }
        await secondaryPlayer.seek(Duration.zero);
        if (widget.autoPlay) {
          final playbackProgressCompleter = Completer<void>();
          _secondaryPlaybackProgressCompleter = playbackProgressCompleter;
          _secondaryHasStartedPlayback = true;
          await secondaryPlayer.play();
          await playbackProgressCompleter.future.timeout(
            const Duration(milliseconds: 500),
            onTimeout: () {},
          );
          if (identical(
            _secondaryPlaybackProgressCompleter,
            playbackProgressCompleter,
          )) {
            _secondaryPlaybackProgressCompleter = null;
          }
        }
        if (mounted && _player == player) {
          setState(() {
            _showSecondaryPlayer = true;
          });
        }
        return;
      }

      if (widget.looping || widget.pingPongLoop) {
        await player.seek(widget.loopStart ?? Duration.zero);
        if (widget.autoPlay) {
          await player.play();
        }
        return;
      }

      _currentPlayCount++;
      final targetRepeatCount = widget.repeatCount ?? 1;
      if (_currentPlayCount < targetRepeatCount) {
        await player.seek(Duration.zero);
        if (widget.autoPlay) {
          await player.play();
        }
        return;
      }
      _reportVideoEnd();
    } catch (_) {
      _reportVideoEnd();
    } finally {
      _handlingPrimaryCompletion = false;
    }
  }

  Future<void> _handleSecondaryPlaybackCompleted() async {
    final secondaryPlayer = _secondaryPlayer;
    if (secondaryPlayer == null || _handlingSecondaryCompletion) {
      return;
    }
    _handlingSecondaryCompletion = true;
    _secondaryHasStartedPlayback = false;
    try {
      if (_hasSequentialFollowUp) {
        if (widget.sequentialLooping) {
          await secondaryPlayer.seek(Duration.zero);
          if (widget.autoPlay) {
            await secondaryPlayer.play();
          }
        } else {
          _reportVideoEnd();
        }
        return;
      }

      final primaryPlayer = _player;
      if (widget.pingPongLoop && primaryPlayer != null) {
        await secondaryPlayer.pause();
        await secondaryPlayer.seek(Duration.zero);
        await primaryPlayer.seek(widget.loopStart ?? Duration.zero);
        if (mounted) {
          setState(() {
            _showSecondaryPlayer = false;
          });
        }
        if (widget.autoPlay) {
          await primaryPlayer.play();
        }
      }
    } finally {
      _handlingSecondaryCompletion = false;
    }
  }

  void _reportVideoEnd() {
    if (_hasCalledOnEnd) {
      return;
    }
    _hasCalledOnEnd = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        widget.onVideoEnd?.call();
      }
    });
  }

  Future<void> _syncPlaybackWithAutoPlay() async {
    final activePlayer = _showSecondaryPlayer ? _secondaryPlayer : _player;
    final inactivePlayer = _showSecondaryPlayer ? _player : _secondaryPlayer;
    try {
      if (widget.autoPlay) {
        await activePlayer?.play();
        await inactivePlayer?.pause();
      } else {
        await _player?.pause();
        await _secondaryPlayer?.pause();
      }
    } catch (_) {}
  }

  Future<void> _applyPlaybackRate() async {
    try {
      await Future.wait<void>([
        if (_player != null) _player!.setPlaybackRate(widget.playbackRate),
        if (_secondaryPlayer != null)
          _secondaryPlayer!.setPlaybackRate(widget.playbackRate),
      ]);
    } catch (_) {}
  }

  Future<String?> _resolveMoviePath(String movieFile) async {
    String? videoPath = await AssetManager().findNativeMediaAsset(movieFile);
    videoPath ??= await AssetManager().findNativeMediaAsset(
      'videos/$movieFile',
    );
    videoPath ??= await AssetManager().findNativeMediaAsset(
      'movies/$movieFile',
    );
    return videoPath;
  }

  void _setError(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _hasError = true;
      _errorMessage = message;
      _isInitialized = false;
    });
  }

  Future<void> _disposePlayers() async {
    await _eventSubscription?.cancel();
    await _secondaryEventSubscription?.cancel();
    _eventSubscription = null;
    _secondaryEventSubscription = null;
    _surfaceAttachedCompleter = null;
    _secondarySurfaceAttachedCompleter = null;
    _secondaryPlaybackProgressCompleter = null;
    final player = _player;
    final secondaryPlayer = _secondaryPlayer;
    _player = null;
    _secondaryPlayer = null;
    await Future.wait<void>([
      if (player != null) player.dispose(),
      if (secondaryPlayer != null) secondaryPlayer.dispose(),
    ]);
  }

  @override
  void dispose() {
    _initializationGeneration++;
    unawaited(_disposePlayers());
    super.dispose();
  }

  Widget _buildVideoLayer(BuildContext context, ErikaPlayer player) {
    final texture = ErikaTextureVideoView(
      key: ObjectKey(player),
      player: player,
      blendMode: widget.videoBlendMode,
      opacity: widget.videoOpacity,
    );
    if (_videoWidth <= 0 || _videoHeight <= 0) {
      return SizedBox.expand(child: texture);
    }
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return FittedBox(
      fit: widget.fit,
      alignment: widget.alignment,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: _videoWidth / pixelRatio,
        height: _videoHeight / pixelRatio,
        child: texture,
      ),
    );
  }

  Widget _buildPlaceholderLayer() {
    final assetName = widget.placeholderImageAssetName?.trim();
    if (assetName == null || assetName.isEmpty) {
      return ColoredBox(color: widget.backgroundColor);
    }
    return SmartAssetImage(
      assetName: assetName,
      fit: widget.fit,
      errorWidget: ColoredBox(color: widget.backgroundColor),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      if (widget.backgroundMode) {
        return SizedBox.expand(child: _buildPlaceholderLayer());
      }
      if (_errorMessage?.contains('视频文件名为空') == true) {
        return const SizedBox.shrink();
      }
      return ColoredBox(
        color: widget.backgroundColor,
        child: Center(
          child: Text(
            _errorMessage ?? '视频加载失败',
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
        ),
      );
    }

    final player = _player;
    if (!_isInitialized || player == null) {
      if (widget.backgroundMode) {
        return SizedBox.expand(child: _buildPlaceholderLayer());
      }
      return ColoredBox(
        color: widget.backgroundColor,
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    final secondaryPlayer = _secondaryPlayer;
    return SizedBox.expand(
      child: ColoredBox(
        color: widget.backgroundColor,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_hasPlaceholderImage) _buildPlaceholderLayer(),
            if (secondaryPlayer != null && !_showSecondaryPlayer)
              _buildVideoLayer(context, secondaryPlayer),
            _buildVideoLayer(context, player),
            if (secondaryPlayer != null && _showSecondaryPlayer)
              _buildVideoLayer(context, secondaryPlayer),
          ],
        ),
      ),
    );
  }
}
