import 'dart:async';

class DebugLogger {
  static final DebugLogger _instance = DebugLogger._internal();
  factory DebugLogger() => _instance;
  static DebugLogger get instance => _instance;
  DebugLogger._internal();

  final List<String> _logs = [];
  static const int maxLogs = 1000; // 最多保存1000条日志
  static const Duration _notificationInterval = Duration(milliseconds: 100);
  Timer? _notificationTimer;

  // Stream controller for real-time log updates
  final StreamController<List<String>> _logStreamController =
      StreamController<List<String>>.broadcast();

  List<String> get logs => List.unmodifiable(_logs);
  Stream<List<String>> get logStream => _logStreamController.stream;

  void addLog(String message) {
    final timestamp = DateTime.now();
    final formattedTime = "${timestamp.hour.toString().padLeft(2, '0')}:"
        "${timestamp.minute.toString().padLeft(2, '0')}:"
        "${timestamp.second.toString().padLeft(2, '0')}."
        "${timestamp.millisecond.toString().padLeft(3, '0')}";

    final logEntry = "[$formattedTime] $message";
    _logs.add(logEntry);

    // 保持日志数量在限制内
    if (_logs.length > maxLogs) {
      _logs.removeAt(0);
    }

    _scheduleListenerNotification();
  }

  void log(String message) {
    addLog(message);
  }

  void clear() {
    _logs.clear();
    _scheduleListenerNotification(immediate: true);
  }

  String getAllLogsAsString() {
    return _logs.join('\n');
  }

  void dispose() {
    _notificationTimer?.cancel();
    _logStreamController.close();
  }

  void _scheduleListenerNotification({bool immediate = false}) {
    // 没有打开日志面板时，不复制整份日志列表。密集 print 本身不应成为
    // debug 模式的性能瓶颈。
    if (!_logStreamController.hasListener) {
      return;
    }

    if (immediate) {
      _notificationTimer?.cancel();
      _notificationTimer = null;
      _emitLogs();
      return;
    }

    if (_notificationTimer?.isActive ?? false) {
      return;
    }
    _notificationTimer = Timer(_notificationInterval, () {
      _notificationTimer = null;
      _emitLogs();
    });
  }

  void _emitLogs() {
    if (!_logStreamController.hasListener || _logStreamController.isClosed) {
      return;
    }
    _logStreamController.add(List<String>.unmodifiable(_logs));
  }
}

void setupDebugLogger() {
  // 添加初始化日志，表示日志系统已启动
  DebugLogger().addLog("调试日志系统已启动 - 所有print输出都会被自动捕获");

  // 添加一些测试日志来验证系统工作正常
  DebugLogger().addLog("测试日志: INFO级别消息");
  DebugLogger().addLog("测试日志: [WARN] 警告级别消息");
  DebugLogger().addLog("测试日志: [ERROR] 错误级别消息");
  DebugLogger().addLog("测试日志: [DEBUG] 调试级别消息");
}
