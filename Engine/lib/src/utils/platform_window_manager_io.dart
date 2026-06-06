import 'dart:io' show Platform;
import 'dart:ui';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

export 'package:window_manager/window_manager.dart' show WindowListener;

class PlatformWindowManager {
  static const double _aspectRatioOverflowTolerance = 0.5;
  static const double defaultStartupWindowFillFraction = 0.9;

  static bool get _isDesktop {
    return Platform.isWindows || Platform.isMacOS || Platform.isLinux;
  }

  static bool get isWindows => Platform.isWindows;

  static bool get supportsWindowStateSync => _isDesktop;

  static bool get supportsWindowAspectRatioPresetSwitching => _isDesktop;

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
      await windowManager.maximize();
    }
  }

  static Future<void> unmaximize() async {
    if (_isDesktop) {
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

      final currentBounds = await windowManager.getBounds();
      final currentSize = currentBounds.size;
      if (currentSize.height <= 0) {
        return;
      }

      final visibleDisplayBounds = await _resolveCurrentVisibleDisplayBounds(
        currentBounds,
      );
      final targetSize = resolveAspectRatioPresetTargetSize(
        currentSize: currentSize,
        aspectRatio: aspectRatio,
        visibleDisplaySize: visibleDisplayBounds?.size,
      );
      if (updateAspectRatioConstraint) {
        await windowManager.setAspectRatio(aspectRatio);
      }
      await windowManager.setSize(
        targetSize,
        animate: true,
      );
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
    Size? visibleDisplaySize,
  }) {
    if (currentSize.width <= 0 || currentSize.height <= 0 || aspectRatio <= 0) {
      return currentSize;
    }

    final targetWidth = (currentSize.height * aspectRatio).roundToDouble();
    final visibleWidth = visibleDisplaySize?.width;
    if (visibleWidth != null &&
        visibleWidth > 0 &&
        targetWidth > visibleWidth + _aspectRatioOverflowTolerance) {
      final targetHeight = (currentSize.width / aspectRatio).roundToDouble();
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
  }) {
    if (visibleDisplayBounds.width <= 0 ||
        visibleDisplayBounds.height <= 0 ||
        aspectRatio <= 0) {
      return Rect.zero;
    }

    final clampedFillFraction = fillFraction.clamp(0.1, 1.0).toDouble();
    final maxWidth = visibleDisplayBounds.width * clampedFillFraction;
    final maxHeight = visibleDisplayBounds.height * clampedFillFraction;

    var targetWidth = maxWidth;
    var targetHeight = targetWidth / aspectRatio;
    if (targetHeight > maxHeight) {
      targetHeight = maxHeight;
      targetWidth = targetHeight * aspectRatio;
    }

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
