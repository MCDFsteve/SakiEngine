import 'dart:async';
import 'dart:html' as html;
import 'dart:ui';

class PlatformWindowManager {
  static const double defaultStartupWindowFillFraction = 0.9;

  static bool get isWindows => false;

  static bool get supportsWindowStateSync => true;

  static bool get supportsWindowAspectRatioPresetSwitching => false;

  static bool get isAspectRatioMaximized => false;

  static final Map<WindowListener, List<StreamSubscription<html.Event>>>
      _listeners = <WindowListener, List<StreamSubscription<html.Event>>>{};

  static Future<void> ensureInitialized() async {}

  static Future<void> setPreventClose(bool prevent) async {}

  static Future<void> maximize() async {}

  static Future<void> unmaximize() async {}

  static Future<bool?> isMaximized() async => false;

  static void addListener(WindowListener listener) {
    removeListener(listener);

    final subscriptions = <StreamSubscription<html.Event>>[];

    subscriptions.add(html.window.onBeforeUnload.listen((_) {
      Future.microtask(() => listener.onWindowClose());
    }));

    subscriptions.add(html.document.onFullscreenChange.listen((_) {
      final isFullscreen = html.document.fullscreenElement != null;
      if (isFullscreen) {
        listener.onWindowEnterFullScreen();
      } else {
        listener.onWindowLeaveFullScreen();
      }
    }));

    _listeners[listener] = subscriptions;
  }

  static void removeListener(WindowListener listener) {
    final subscriptions = _listeners.remove(listener);
    if (subscriptions == null) {
      return;
    }
    for (final subscription in subscriptions) {
      subscription.cancel();
    }
  }

  static Future<void> destroy() async {
    for (final subscriptions in _listeners.values) {
      for (final subscription in subscriptions) {
        subscription.cancel();
      }
    }
    _listeners.clear();

    try {
      html.window.close();
    } catch (_) {}
  }

  static Future<void> close() async {
    await destroy();
  }

  static Future<void> setTitle(String title) async {
    html.document.title = title;
  }

  static Future<void> prepareForWindowsFullscreenTransition() async {}

  static Future<void> setFullScreen(bool fullScreen) async {
    if (fullScreen) {
      try {
        final element = html.document.documentElement;
        if (element != null) {
          await element.requestFullscreen();
        }
      } catch (_) {}
      return;
    }

    try {
      if (html.document.fullscreenElement != null) {
        html.document.exitFullscreen();
      }
    } catch (_) {}
  }

  static Future<bool?> isFullScreen() async {
    try {
      return html.document.fullscreenElement != null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> setAspectRatio(double aspectRatio) async {}

  static Future<double?> queryCurrentWindowAspectRatio() async => null;

  static Future<void> applyAspectRatioPresetByKeepingHeight(
    double aspectRatio, {
    double reservedVerticalHeight = 0.0,
    bool updateAspectRatioConstraint = true,
  }) async {}

  static Future<void> applyStartupWindowSizeForAspectRatio(
    double aspectRatio, {
    double fillFraction = defaultStartupWindowFillFraction,
  }) async {}

  static Future<bool?> toggleAspectRatioMaximized(double aspectRatio) async {
    return null;
  }

  static Future<void> enforceContentAspectRatio(
    double aspectRatio, {
    double reservedVerticalHeight = 0.0,
  }) async {}

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
        targetWidth > visibleWidth) {
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
}

mixin WindowListener {
  Future<void> onWindowClose();

  void onWindowEnterFullScreen() {}

  void onWindowLeaveFullScreen() {}

  void onWindowResize() {}

  void onWindowResized() {}

  void onWindowMaximize() {}

  void onWindowUnmaximize() {}

  void onWindowRestore() {}
}
