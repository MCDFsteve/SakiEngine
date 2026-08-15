import 'package:flutter/foundation.dart' as foundation;

export 'package:flutter/foundation.dart';

/// 演出模式开关（编译期）：
/// flutter run/build ... --dart-define=SAKI_SHOW_MODE=1
const String _sakiShowModeRaw = String.fromEnvironment(
  'SAKI_SHOW_MODE',
  defaultValue: '',
);
const bool kSakiShowMode =
    _sakiShowModeRaw == '1' || _sakiShowModeRaw == 'true';

/// 引擎统一调试开关（编译期）：
/// - Flutter 原生 Debug 为 true
/// - 演出模式（release/profile）也会返回 true
const bool kEngineDebugMode = foundation.kDebugMode || kSakiShowMode;

/// 高频诊断日志开关（编译期，默认关闭）：
/// flutter run/build ... --dart-define=SAKI_DIAGNOSTIC_LOGS=true
///
/// 普通 Debug 构建不再自动输出逐帧、逐按键或存档耗时日志；需要定位问题时
/// 再显式开启，避免长时间运行后终端被诊断信息淹没。
const bool kSakiDiagnosticLogs = bool.fromEnvironment(
  'SAKI_DIAGNOSTIC_LOGS',
  defaultValue: false,
);

void sakiDiagnosticLog(Object? message) {
  if (kSakiDiagnosticLogs) {
    foundation.debugPrint(message?.toString());
  }
}
