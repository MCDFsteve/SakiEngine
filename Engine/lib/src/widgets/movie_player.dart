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
  bool _isInitialized = false;
  bool _hasError = false;
  String? _errorMessage;
  bool _hasCalledOnEnd = false;
  int _currentPlayCount = 0;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  @override
  void didUpdateWidget(MoviePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.movieFile != widget.movieFile) {
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

      final playlistMode =
          widget.looping && widget.loopStart == null
              ? PlaylistMode.loop
              : PlaylistMode.none;
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

    _errorSubscription = _player!.stream.error.listen((message) {
      if (message.isNotEmpty) {
        _setError('视频播放出错: $message');
      }
    });
  }

  void _handlePlaybackCompleted() async {
    if (_player == null) {
      return;
    }

    if (widget.looping && widget.loopStart != null) {
      try {
        await _player!.seek(widget.loopStart!);
        await _player!.play();
      } catch (_) {}
      return;
    }

    if (_hasCalledOnEnd || widget.looping) {
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
    await _errorSubscription?.cancel();
    _completedSubscription = null;
    _errorSubscription = null;

    final player = _player;
    _player = null;
    _videoController = null;
    _hasCalledOnEnd = false;
    _currentPlayCount = 0;

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
