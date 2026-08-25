import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';

/// 鼠标滚轮处理器
/// 负责处理游戏中的鼠标滚轮事件:
/// - 向下滚动: 推进对话
/// - 向上滚动: 回退剧情或打开观看记录
class MouseWheelHandler {
  /// 向前滚动回调 (推进对话)
  final VoidCallback? onScrollForward;

  /// 向后滚动回调 (回退剧情)
  final VoidCallback? onScrollBackward;

  /// 是否允许处理滚轮事件的检查函数
  final bool Function()? shouldHandleScroll;

  MouseWheelHandler({
    this.onScrollForward,
    this.onScrollBackward,
    this.shouldHandleScroll,
  });

  void _log(String message) {
    sakiDiagnosticLog('[MouseWheelHandler] $message');
  }

  /// 处理指针信号事件
  void handlePointerSignal(PointerSignalEvent pointerSignal) {
    // 检查是否允许处理滚轮事件
    if (shouldHandleScroll != null && !shouldHandleScroll!()) {
      _log('ignored signal: ${pointerSignal.runtimeType}');
      return;
    }

    // 处理标准的PointerScrollEvent（鼠标滚轮）
    if (pointerSignal is PointerScrollEvent) {
      _log('PointerScrollEvent dy=${pointerSignal.scrollDelta.dy}');
      // 向上滚动 (dy < 0): 回退剧情或打开观看记录
      if (pointerSignal.scrollDelta.dy < 0) {
        _log('branch=backward');
        onScrollBackward?.call();
      }
      // 向下滚动 (dy > 0): 推进剧情
      else if (pointerSignal.scrollDelta.dy > 0) {
        _log('branch=forward');
        onScrollForward?.call();
      }
    }
    // 处理macOS触控板事件
    else if (pointerSignal.toString().contains('Scroll')) {
      _log('fallback scroll signal type=${pointerSignal.runtimeType}');
      // 无法读取方向时保持原行为，默认推进剧情
      onScrollForward?.call();
    } else {
      _log('unhandled signal type=${pointerSignal.runtimeType}');
    }
  }

  /// 处理触控板平移缩放更新（macOS 常见）
  void handlePanZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (shouldHandleScroll != null && !shouldHandleScroll!()) {
      _log('ignored panZoom update');
      return;
    }

    final dy = event.panDelta.dy;
    if (dy == 0) {
      return;
    }
    _log('PointerPanZoomUpdateEvent panDelta.dy=$dy');
    if (dy < 0) {
      _log('panZoom branch=backward');
      onScrollBackward?.call();
    } else {
      _log('panZoom branch=forward');
      onScrollForward?.call();
    }
  }
}

/// 鼠标滚轮监听器Widget
/// 包装一个子Widget并添加鼠标滚轮事件处理
class MouseWheelListener extends StatelessWidget {
  final Widget child;
  final MouseWheelHandler handler;

  const MouseWheelListener({
    super.key,
    required this.child,
    required this.handler,
  });

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: handler.handlePointerSignal,
      behavior: HitTestBehavior.translucent,
      child: child,
    );
  }
}
