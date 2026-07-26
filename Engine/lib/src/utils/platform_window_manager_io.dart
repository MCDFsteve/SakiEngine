import 'dart:io' show Platform;
import 'dart:ui';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

export 'package:window_manager/window_manager.dart' show WindowListener;

class PlatformWindowManager {
  static const double _aspectRatioOverflowTolerance = 0.5;
  static const double _maximumExpectedFrameVerticalInset = 160.0;
  static const double defaultStartupWindowFillFraction = 0.9;
  static Rect? _aspectRatioMaximizeRestoreBounds;

  static bool get _isDesktop {
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  static bool get isWindows => Platform.isWindows;

  static bool get supportsWindowStateSync => _isDesktop;

  static bool get supportsWindowAspectRatioPresetSwitching => _isDesktop;

  static bool get isAspectRatioMaximized =>
      _aspectRatioMaximizeRestoreBounds != null;

  static Future<void> ensureInitialized() async {
    if (_isDesktop) {
      await windowManager.ensureInitialized();
    }
  }

  static Future<void> setPreventClose(bool prevent) async {
    if (_isDesktop) {
      await windowManager.setPreventClose(prevent);
    }
  }

  static Future<void> maximize() async {
    if (_isDesktop) {
      _aspectRatioMaximizeRestoreBounds = null;
      await windowManager.maximize();
    }
  }

  static Future<void> unmaximize() async {
    if (_isDesktop) {
      _aspectRatioMaximizeRestoreBounds = null;
      await windowManager.unmaximize();
    }
  }

  static Future<bool?> isMaximized() async {
    if (_isDesktop) {
      return windowManager.isMaximized();
    }
    return null;
  }

  static void addListener(WindowListener listener) {
    if (_isDesktop) {
      windowManager.addListener(listener);
    }
  }

  static void removeListener(WindowListener listener) {
    if (_isDesktop) {
      windowManager.removeListener(listener);
    }
  }

  static Future<void> destroy() async {
    if (_isDesktop) {
      await windowManager.destroy();
    }
  }

  static Future<void> close() async {
    if (_isDesktop) {
      await windowManager.close();
    }
  }

  static Future<void> setTitle(String title) async {
    if (_isDesktop) {
      await windowManager.setTitle(title);
    }
  }

  static Future<void> prepareForWindowsFullscreenTransition() async {
    if (!isWindows) {
      return;
    }
    // Reset internal frameless marker in window_manager so first fullscreen
    // transition on Windows does not degrade to borderless-only mode.
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
  }

  static Future<void> setFullScreen(bool fullScreen) async {
    if (_isDesktop) {
      await windowManager.setFullScreen(fullScreen);
    }
  }

  static Future<bool?> isFullScreen() async {
    if (_isDesktop) {
      return windowManager.isFullScreen();
    }
    return null;
  }

  static Future<void> setAspectRatio(double aspectRatio) async {
    if (_isDesktop) {
      await windowManager.setAspectRatio(aspectRatio);
    }
  }

  static Future<double?> queryCurrentWindowAspectRatio() async {
    if (!_isDesktop) {
      return null;
    }

    try {
      final size = await windowManager.getSize();
      if (size.height <= 0) {
        return null;
      }
      return size.width / size.height;
    } catch (_) {
      return null;
    }
  }

  static Future<void> applyAspectRatioPresetByKeepingHeight(
    double aspectRatio, {
    double reservedVerticalHeight = 0.0,
    bool updateAspectRatioConstraint = true,
  }) async {
    if (!_isDesktop || aspectRatio <= 0) {
      return;
    }

    try {
      if (await windowManager.isFullScreen()) {
        return;
      }
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      }
      _aspectRatioMaximizeRestoreBounds = null;

      final currentBounds = await windowManager.getBounds();
      final currentSize = currentBounds.size;
      if (currentSize.height <= 0) {
        return;
      }
      final effectiveReservedVerticalHeight = _effectiveReservedVerticalHeight(
        currentBounds,
        reservedVerticalHeight,
      );

      final visibleDisplayBounds = await _resolveCurrentVisibleDisplayBounds(
        currentBounds,
      );
      final targetSize = resolveAspectRatioPresetTargetSize(
        currentSize: currentSize,
        aspectRatio: aspectRatio,
        reservedVerticalHeight: effectiveReservedVerticalHeight,
        visibleDisplaySize: visibleDisplayBounds?.size,
      );
      if (updateAspectRatioConstraint) {
        await windowManager
            .setAspectRatio(targetSize.width / targetSize.height);
      }
      await windowManager.setSize(
        targetSize,
        animate: true,
      );
    } catch (_) {}
  }

  static Future<bool?> toggleAspectRatioMaximized(
    double aspectRatio, {
    double reservedVerticalHeight = 0.0,
  }) async {
    if (!_isDesktop || aspectRatio <= 0) {
      return null;
    }

    try {
      if (await windowManager.isFullScreen()) {
        return null;
      }

      final restoreBounds = _aspectRatioMaximizeRestoreBounds;
      if (restoreBounds != null &&
          restoreBounds.width > 0 &&
          restoreBounds.height > 0) {
        _aspectRatioMaximizeRestoreBounds = null;
        await windowManager
            .setAspectRatio(restoreBounds.width / restoreBounds.height);
        await windowManager.setBounds(restoreBounds, animate: true);
        return false;
      }

      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      }

      final currentBounds = await windowManager.getBounds();
      final effectiveReservedVerticalHeight = _effectiveReservedVerticalHeight(
        currentBounds,
        reservedVerticalHeight,
      );
      final visibleDisplayBounds = await _resolveCurrentVisibleDisplayBounds(
        currentBounds,
      );
      if (visibleDisplayBounds == null ||
          visibleDisplayBounds.width <= 0 ||
          visibleDisplayBounds.height <= 0) {
        return null;
      }

      final targetBounds = resolveAspectRatioMaximizedBounds(
        visibleDisplayBounds: visibleDisplayBounds,
        aspectRatio: aspectRatio,
        reservedVerticalHeight: effectiveReservedVerticalHeight,
      );
      if (targetBounds.width <= 0 || targetBounds.height <= 0) {
        return null;
      }

      _aspectRatioMaximizeRestoreBounds = currentBounds;
      await windowManager
          .setAspectRatio(targetBounds.width / targetBounds.height);
      await windowManager.setBounds(targetBounds, animate: true);
      return true;
    } catch (_) {
      return null;
    }
  }

  static Future<void> enforceContentAspectRatio(
    double aspectRatio, {
    double reservedVerticalHeight = 0.0,
  }) async {
    if (!_isDesktop || aspectRatio <= 0) {
      return;
    }

    try {
      if (await windowManager.isFullScreen()) {
        return;
      }
      final currentBounds = await windowManager.getBounds();
      final currentSize = currentBounds.size;
      if (currentSize.width <= 0 || currentSize.height <= 0) {
        return;
      }
      final effectiveReservedVerticalHeight = _effectiveReservedVerticalHeight(
        currentBounds,
        reservedVerticalHeight,
      );

      final visibleDisplayBounds = await _resolveCurrentVisibleDisplayBounds(
        currentBounds,
      );
      final targetSize = resolveAspectRatioPresetTargetSize(
        currentSize: currentSize,
        aspectRatio: aspectRatio,
        reservedVerticalHeight: effectiveReservedVerticalHeight,
        visibleDisplaySize: visibleDisplayBounds?.size,
      );
      if ((targetSize.width - currentSize.width).abs() <= 1.0 &&
          (targetSize.height - currentSize.height).abs() <= 1.0) {
        await windowManager.setAspectRatio(
          currentSize.width / currentSize.height,
        );
        return;
      }

      await windowManager.setAspectRatio(targetSize.width / targetSize.height);
      await windowManager.setSize(targetSize);
    } catch (_) {}
  }

  static Future<void> applyStartupWindowSizeForAspectRatio(
    double aspectRatio, {
    double fillFraction = defaultStartupWindowFillFraction,
  }) async {
    if (!_isDesktop || aspectRatio <= 0) {
      return;
    }

    try {
      if (await windowManager.isFullScreen()) {
        return;
      }
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      }

      final currentBounds = await windowManager.getBounds();
      final reservedVerticalHeight =
          _effectiveReservedVerticalHeight(currentBounds, 0.0);
      final visibleDisplayBounds =
          await _resolveCurrentVisibleDisplayBounds(currentBounds);
      if (visibleDisplayBounds == null ||
          visibleDisplayBounds.width <= 0 ||
          visibleDisplayBounds.height <= 0) {
        return;
      }

      final targetBounds = resolveStartupWindowBounds(
        visibleDisplayBounds: visibleDisplayBounds,
        aspectRatio: aspectRatio,
        fillFraction: fillFraction,
        reservedVerticalHeight: reservedVerticalHeight,
      );
      if (targetBounds.width <= 0 || targetBounds.height <= 0) {
        return;
      }

      await windowManager.setAspectRatio(aspectRatio);
      await windowManager.setBounds(targetBounds);
    } catch (_) {}
  }

  static Size resolveAspectRatioPresetTargetSize({
    required Size currentSize,
    required double aspectRatio,
    double reservedVerticalHeight = 0.0,
    Size? visibleDisplaySize,
  }) {
    if (currentSize.width <= 0 || currentSize.height <= 0 || aspectRatio <= 0) {
      return currentSize;
    }

    final maxReservedHeight =
        currentSize.height > 1 ? currentSize.height - 1 : 0.0;
    final safeReservedHeight =
        reservedVerticalHeight.clamp(0.0, maxReservedHeight).toDouble();
    final contentHeight = currentSize.height - safeReservedHeight;
    final targetWidth = (contentHeight * aspectRatio).roundToDouble();
    final visibleWidth = visibleDisplaySize?.width;
    if (visibleWidth != null &&
        visibleWidth > 0 &&
        targetWidth > visibleWidth + _aspectRatioOverflowTolerance) {
      final targetHeight =
          (currentSize.width / aspectRatio + safeReservedHeight)
              .roundToDouble();
      if (targetHeight > 0) {
        return Size(currentSize.width, targetHeight);
      }
    }

    return Size(targetWidth, currentSize.height);
  }

  static Rect resolveStartupWindowBounds({
    required Rect visibleDisplayBounds,
    required double aspectRatio,
    double fillFraction = defaultStartupWindowFillFraction,
    double reservedVerticalHeight = 0.0,
  }) {
    return _resolveContentAspectWindowBounds(
      visibleDisplayBounds: visibleDisplayBounds,
      aspectRatio: aspectRatio,
      fillFraction: fillFraction,
      reservedVerticalHeight: reservedVerticalHeight,
    );
  }

  /// Resolves the non-client vertical area around Flutter's content view.
  ///
  /// On macOS, window_manager sizes the complete NSWindow frame while its
  /// aspect-ratio constraint applies to the content area. Keeping those two
  /// measurements separate prevents the title bar from becoming a black strip
  /// beside the game canvas on the first frame.
  static double resolveWindowFrameVerticalInset({
    required Size windowFrameSize,
    required Size contentSize,
  }) {
    if (windowFrameSize.height <= 0 || contentSize.height <= 0) {
      return 0.0;
    }

    final inset = windowFrameSize.height - contentSize.height;
    final maximumInset = (windowFrameSize.height * 0.25)
        .clamp(0.0, _maximumExpectedFrameVerticalInset)
        .toDouble();
    if (inset <= _aspectRatioOverflowTolerance || inset > maximumInset) {
      return 0.0;
    }
    return inset;
  }

  static double _effectiveReservedVerticalHeight(
    Rect currentWindowBounds,
    double requestedReservedVerticalHeight,
  ) {
    if (requestedReservedVerticalHeight > 0 || !Platform.isMacOS) {
      return requestedReservedVerticalHeight;
    }

    final view = PlatformDispatcher.instance.implicitView;
    if (view == null || view.devicePixelRatio <= 0) {
      return 0.0;
    }
    final contentSize = view.physicalSize / view.devicePixelRatio;
    return resolveWindowFrameVerticalInset(
      windowFrameSize: currentWindowBounds.size,
      contentSize: contentSize,
    );
  }

  static Rect _resolveContentAspectWindowBounds({
    required Rect visibleDisplayBounds,
    required double aspectRatio,
    required double fillFraction,
    double reservedVerticalHeight = 0.0,
  }) {
    if (visibleDisplayBounds.width <= 0 ||
        visibleDisplayBounds.height <= 0 ||
        aspectRatio <= 0) {
      return Rect.zero;
    }

    final clampedFillFraction = fillFraction.clamp(0.1, 1.0).toDouble();
    final maxWidth = visibleDisplayBounds.width * clampedFillFraction;
    final maxHeight = visibleDisplayBounds.height * clampedFillFraction;
    final maxReservedHeight = maxHeight > 1 ? maxHeight - 1 : 0.0;
    final safeReservedHeight =
        reservedVerticalHeight.clamp(0.0, maxReservedHeight).toDouble();
    final maxContentHeight = maxHeight - safeReservedHeight;

    var targetWidth = maxWidth;
    var targetContentHeight = targetWidth / aspectRatio;
    if (targetContentHeight > maxContentHeight) {
      targetContentHeight = maxContentHeight;
      targetWidth = targetContentHeight * aspectRatio;
    }
    var targetHeight = targetContentHeight + safeReservedHeight;

    targetWidth = targetWidth.roundToDouble();
    targetHeight = targetHeight.roundToDouble();
    final targetLeft = (visibleDisplayBounds.left +
            (visibleDisplayBounds.width - targetWidth) / 2)
        .roundToDouble();
    final targetTop = (visibleDisplayBounds.top +
            (visibleDisplayBounds.height - targetHeight) / 2)
        .roundToDouble();

    return Rect.fromLTWH(
      targetLeft,
      targetTop,
      targetWidth,
      targetHeight,
    );
  }

  static Rect resolveAspectRatioMaximizedBounds({
    required Rect visibleDisplayBounds,
    required double aspectRatio,
    double reservedVerticalHeight = 0.0,
  }) {
    return _resolveContentAspectWindowBounds(
      visibleDisplayBounds: visibleDisplayBounds,
      aspectRatio: aspectRatio,
      fillFraction: 1.0,
      reservedVerticalHeight: reservedVerticalHeight,
    );
  }

  static Future<Rect?> _resolveCurrentVisibleDisplayBounds(
    Rect currentWindowBounds,
  ) async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      if (displays.isEmpty) {
        return _displayVisibleBounds(
          await screenRetriever.getPrimaryDisplay(),
        );
      }

      final windowCenter = currentWindowBounds.center;
      for (final display in displays) {
        final visiblePosition = display.visiblePosition;
        final visibleSize = display.visibleSize;
        if (visiblePosition == null || visibleSize == null) {
          continue;
        }
        final visibleRect = Rect.fromLTWH(
          visiblePosition.dx,
          visiblePosition.dy,
          visibleSize.width,
          visibleSize.height,
        );
        if (visibleRect.contains(windowCenter)) {
          return visibleRect;
        }
      }

      return _displayVisibleBounds(await screenRetriever.getPrimaryDisplay());
    } catch (_) {
      return null;
    }
  }

  static Rect? _displayVisibleBounds(Display display) {
    final visiblePosition = display.visiblePosition;
    final visibleSize = display.visibleSize;
    if (visiblePosition == null || visibleSize == null) {
      return null;
    }
    return Rect.fromLTWH(
      visiblePosition.dx,
      visiblePosition.dy,
      visibleSize.width,
      visibleSize.height,
    );
  }
}
