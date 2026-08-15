import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/utils/settings_manager.dart';

enum PerformanceBottleneck {
  collecting,
  smooth,
  frameRateCap,
  ui,
  raster,
  uiAndRaster,
  uiAndScheduling,
  scheduling,
  pipeline,
}

class SlowFrameSample {
  final DateTime recordedAt;
  final double totalMs;
  final double buildMs;
  final double rasterMs;
  final double schedulingMs;
  final String cause;

  const SlowFrameSample({
    required this.recordedAt,
    required this.totalMs,
    required this.buildMs,
    required this.rasterMs,
    required this.schedulingMs,
    required this.cause,
  });
}

class PerformanceSnapshot {
  final int sampleCount;
  final double targetFps;
  final int frameRateLimit;
  final double fps;
  final double averageFrameIntervalMs;
  final double p95FrameIntervalMs;
  final double averageBuildMs;
  final double p95BuildMs;
  final double averageRasterMs;
  final double p95RasterMs;
  final double averageSchedulingMs;
  final double p95SchedulingMs;
  final double averageTotalMs;
  final double p95TotalMs;
  final double jankRate;
  final PerformanceBottleneck bottleneck;
  final String diagnosis;
  final String recommendation;
  final List<SlowFrameSample> slowFrames;

  const PerformanceSnapshot({
    required this.sampleCount,
    required this.targetFps,
    required this.frameRateLimit,
    required this.fps,
    required this.averageFrameIntervalMs,
    required this.p95FrameIntervalMs,
    required this.averageBuildMs,
    required this.p95BuildMs,
    required this.averageRasterMs,
    required this.p95RasterMs,
    required this.averageSchedulingMs,
    required this.p95SchedulingMs,
    required this.averageTotalMs,
    required this.p95TotalMs,
    required this.jankRate,
    required this.bottleneck,
    required this.diagnosis,
    required this.recommendation,
    required this.slowFrames,
  });

  factory PerformanceSnapshot.empty() {
    return const PerformanceSnapshot(
      sampleCount: 0,
      targetFps: 60,
      frameRateLimit: 0,
      fps: 0,
      averageFrameIntervalMs: 0,
      p95FrameIntervalMs: 0,
      averageBuildMs: 0,
      p95BuildMs: 0,
      averageRasterMs: 0,
      p95RasterMs: 0,
      averageSchedulingMs: 0,
      p95SchedulingMs: 0,
      averageTotalMs: 0,
      p95TotalMs: 0,
      jankRate: 0,
      bottleneck: PerformanceBottleneck.collecting,
      diagnosis: '正在收集帧样本',
      recommendation: '保持当前场景活动几秒钟，以获得稳定结论。',
      slowFrames: <SlowFrameSample>[],
    );
  }

  double get frameBudgetMs => 1000 / targetFps;

  String get bottleneckLabel {
    switch (bottleneck) {
      case PerformanceBottleneck.collecting:
        return '采样中';
      case PerformanceBottleneck.smooth:
        return '流畅';
      case PerformanceBottleneck.frameRateCap:
        return '主动限帧';
      case PerformanceBottleneck.ui:
        return 'UI / Dart';
      case PerformanceBottleneck.raster:
        return 'Raster / GPU';
      case PerformanceBottleneck.uiAndRaster:
        return 'UI + Raster';
      case PerformanceBottleneck.uiAndScheduling:
        return 'UI + 调度';
      case PerformanceBottleneck.scheduling:
        return '调度 / Isolate';
      case PerformanceBottleneck.pipeline:
        return '帧管线';
    }
  }
}

class SakiPerformanceMonitor extends ChangeNotifier {
  SakiPerformanceMonitor._();

  static final SakiPerformanceMonitor instance = SakiPerformanceMonitor._();

  static const int _maxSamples = 180;
  static const int _maxSlowFrames = 8;
  static const Duration _commitInterval = Duration(milliseconds: 500);
  static const Duration _diagnosticLogInterval = Duration(seconds: 2);

  final ListQueue<_FrameSample> _samples = ListQueue<_FrameSample>();
  final ListQueue<SlowFrameSample> _slowFrames = ListQueue<SlowFrameSample>();
  final Stopwatch _clock = Stopwatch();

  PerformanceSnapshot _snapshot = PerformanceSnapshot.empty();
  int? _lastVsyncUs;
  int _lastCommitUs = 0;
  int _lastDiagnosticLogUs = 0;
  PerformanceBottleneck? _lastLoggedBottleneck;
  bool _started = false;
  bool _deepProfilingEnabled = false;
  bool _repaintRainbowEnabled = false;

  PerformanceSnapshot get snapshot => _snapshot;
  bool get isStarted => _started;
  bool get deepProfilingEnabled => _deepProfilingEnabled;
  bool get repaintRainbowEnabled => _repaintRainbowEnabled;

  void start() {
    if (_started) {
      return;
    }
    _started = true;
    _clock.start();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    if (_shouldWriteTerminalLogs) {
      print(
        '[PERF] 性能监控已启动：每 2 秒输出 FPS、UI、Raster、调度和卡顿率；'
        '瓶颈变化时立即输出诊断。',
      );
    }
  }

  void stop() {
    if (!_started) {
      return;
    }
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _clock.stop();
    _started = false;
  }

  void reset() {
    _samples.clear();
    _slowFrames.clear();
    _lastVsyncUs = null;
    _snapshot = PerformanceSnapshot.empty();
    _lastLoggedBottleneck = null;
    _lastDiagnosticLogUs = 0;
    if (_shouldWriteTerminalLogs) {
      print('[PERF] 性能样本已重置');
    }
    notifyListeners();
  }

  void setDeepProfilingEnabled(bool enabled) {
    if (kReleaseMode || _deepProfilingEnabled == enabled) {
      return;
    }
    _deepProfilingEnabled = enabled;
    debugProfileBuildsEnabledUserWidgets = enabled;
    debugProfileLayoutsEnabled = enabled;
    debugProfilePaintsEnabled = enabled;
    if (_shouldWriteTerminalLogs) {
      print('[PERF] DevTools 深度时间线采样${enabled ? '已启用' : '已关闭'}');
    }
    notifyListeners();
  }

  void setRepaintRainbowEnabled(bool enabled) {
    if (kReleaseMode || _repaintRainbowEnabled == enabled) {
      return;
    }
    _repaintRainbowEnabled = enabled;
    debugRepaintRainbowEnabled = enabled;
    if (_shouldWriteTerminalLogs) {
      print('[PERF] 重绘彩虹${enabled ? '已启用' : '已关闭'}');
    }
    notifyListeners();
  }

  String buildReport() {
    final data = _snapshot;
    final mode = kDebugMode
        ? 'debug'
        : kProfileMode
            ? 'profile'
            : 'release';
    final buffer = StringBuffer()
      ..writeln('SakiEngine 性能报告')
      ..writeln('构建模式: $mode')
      ..writeln(
        '目标: ${data.targetFps.toStringAsFixed(0)} FPS '
        '(预算 ${data.frameBudgetMs.toStringAsFixed(2)} ms, '
        '限帧 ${data.frameRateLimit == 0 ? '关闭' : data.frameRateLimit})',
      )
      ..writeln(
        '结论: ${data.bottleneckLabel} — ${data.diagnosis}',
      )
      ..writeln(
        'FPS: ${data.fps.toStringAsFixed(1)} | '
        '卡顿帧: ${(data.jankRate * 100).toStringAsFixed(1)}% | '
        '样本: ${data.sampleCount}',
      )
      ..writeln(
        '帧间隔 avg/p95: ${data.averageFrameIntervalMs.toStringAsFixed(2)} / '
        '${data.p95FrameIntervalMs.toStringAsFixed(2)} ms',
      )
      ..writeln(
        'UI Build avg/p95: ${data.averageBuildMs.toStringAsFixed(2)} / '
        '${data.p95BuildMs.toStringAsFixed(2)} ms',
      )
      ..writeln(
        'Raster avg/p95: ${data.averageRasterMs.toStringAsFixed(2)} / '
        '${data.p95RasterMs.toStringAsFixed(2)} ms',
      )
      ..writeln(
        '调度延迟 avg/p95: '
        '${data.averageSchedulingMs.toStringAsFixed(2)} / '
        '${data.p95SchedulingMs.toStringAsFixed(2)} ms',
      )
      ..writeln(
        '总管线 avg/p95: ${data.averageTotalMs.toStringAsFixed(2)} / '
        '${data.p95TotalMs.toStringAsFixed(2)} ms',
      )
      ..writeln('建议: ${data.recommendation}');

    if (kDebugMode) {
      buffer.writeln('备注: debug 模式包含断言和调试开销，请用 profile 模式复核绝对帧率。');
    }

    if (data.slowFrames.isNotEmpty) {
      buffer.writeln('最近慢帧:');
      for (final frame in data.slowFrames) {
        buffer.writeln(
          '- ${_formatTime(frame.recordedAt)} ${frame.cause}: '
          'total=${frame.totalMs.toStringAsFixed(1)}ms, '
          'build=${frame.buildMs.toStringAsFixed(1)}ms, '
          'raster=${frame.rasterMs.toStringAsFixed(1)}ms, '
          'schedule=${frame.schedulingMs.toStringAsFixed(1)}ms',
        );
      }
    }

    return buffer.toString().trimRight();
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final vsyncUs = timing.timestampInMicroseconds(FramePhase.vsyncStart);
      final previousVsyncUs = _lastVsyncUs;
      final intervalUs =
          previousVsyncUs == null ? 0 : math.max(0, vsyncUs - previousVsyncUs);
      _lastVsyncUs = vsyncUs;

      final sample = _FrameSample(
        intervalMs: intervalUs / 1000,
        buildMs: timing.buildDuration.inMicroseconds / 1000,
        rasterMs: timing.rasterDuration.inMicroseconds / 1000,
        schedulingMs: timing.vsyncOverhead.inMicroseconds / 1000,
        totalMs: timing.totalSpan.inMicroseconds / 1000,
      );
      _samples.addLast(sample);
      if (_samples.length > _maxSamples) {
        _samples.removeFirst();
      }
      _recordSlowFrameIfNeeded(sample);
    }

    final nowUs = _clock.elapsedMicroseconds;
    if (nowUs - _lastCommitUs < _commitInterval.inMicroseconds) {
      return;
    }
    _lastCommitUs = nowUs;
    _commitSnapshot(nowUs);
  }

  void _recordSlowFrameIfNeeded(_FrameSample sample) {
    final frameRateLimit = SettingsManager().currentFrameRateLimit;
    final targetFps = frameRateLimit > 0 ? frameRateLimit.toDouble() : 60.0;
    final budgetMs = 1000 / targetFps;
    final worstStageMs = math.max(
      math.max(sample.buildMs, sample.rasterMs),
      math.max(sample.schedulingMs, sample.totalMs),
    );
    if (worstStageMs < budgetMs * 1.25) {
      return;
    }

    _slowFrames.addLast(
      SlowFrameSample(
        recordedAt: DateTime.now(),
        totalMs: sample.totalMs,
        buildMs: sample.buildMs,
        rasterMs: sample.rasterMs,
        schedulingMs: sample.schedulingMs,
        cause: _slowFrameCause(sample, budgetMs),
      ),
    );
    if (_slowFrames.length > _maxSlowFrames) {
      _slowFrames.removeFirst();
    }
  }

  String _slowFrameCause(_FrameSample sample, double budgetMs) {
    final stages = <String, double>{
      'UI': sample.buildMs,
      'Raster': sample.rasterMs,
      '调度': sample.schedulingMs,
    };
    final slowestStage =
        stages.entries.reduce((a, b) => a.value >= b.value ? a : b);
    if (slowestStage.value < budgetMs && sample.totalMs > budgetMs) {
      return '管线';
    }
    return slowestStage.key;
  }

  void _commitSnapshot(int nowUs) {
    if (_samples.isEmpty) {
      return;
    }

    final frameRateLimit = SettingsManager().currentFrameRateLimit;
    final targetFps = frameRateLimit > 0 ? frameRateLimit.toDouble() : 60.0;
    final budgetMs = 1000 / targetFps;
    final intervals = _samples
        .map((sample) => sample.intervalMs)
        .where((value) => value > 0)
        .toList(growable: false);
    final builds =
        _samples.map((sample) => sample.buildMs).toList(growable: false);
    final rasters =
        _samples.map((sample) => sample.rasterMs).toList(growable: false);
    final schedulings =
        _samples.map((sample) => sample.schedulingMs).toList(growable: false);
    final totals =
        _samples.map((sample) => sample.totalMs).toList(growable: false);

    final averageIntervalMs = _average(intervals);
    final p95IntervalMs = _percentile(intervals, 0.95);
    final averageBuildMs = _average(builds);
    final p95BuildMs = _percentile(builds, 0.95);
    final averageRasterMs = _average(rasters);
    final p95RasterMs = _percentile(rasters, 0.95);
    final averageSchedulingMs = _average(schedulings);
    final p95SchedulingMs = _percentile(schedulings, 0.95);
    final averageTotalMs = _average(totals);
    final p95TotalMs = _percentile(totals, 0.95);
    final double fps = averageIntervalMs <= 0 ? 0.0 : 1000 / averageIntervalMs;
    final jankCount = _samples.where((sample) {
      return sample.totalMs > budgetMs ||
          sample.buildMs > budgetMs ||
          sample.rasterMs > budgetMs ||
          sample.schedulingMs > budgetMs;
    }).length;
    final jankRate = jankCount / _samples.length;

    final diagnosis = _diagnose(
      sampleCount: _samples.length,
      fps: fps,
      frameRateLimit: frameRateLimit,
      budgetMs: budgetMs,
      p95IntervalMs: p95IntervalMs,
      p95BuildMs: p95BuildMs,
      p95RasterMs: p95RasterMs,
      p95SchedulingMs: p95SchedulingMs,
      p95TotalMs: p95TotalMs,
    );

    _snapshot = PerformanceSnapshot(
      sampleCount: _samples.length,
      targetFps: targetFps,
      frameRateLimit: frameRateLimit,
      fps: fps,
      averageFrameIntervalMs: averageIntervalMs,
      p95FrameIntervalMs: p95IntervalMs,
      averageBuildMs: averageBuildMs,
      p95BuildMs: p95BuildMs,
      averageRasterMs: averageRasterMs,
      p95RasterMs: p95RasterMs,
      averageSchedulingMs: averageSchedulingMs,
      p95SchedulingMs: p95SchedulingMs,
      averageTotalMs: averageTotalMs,
      p95TotalMs: p95TotalMs,
      jankRate: jankRate,
      bottleneck: diagnosis.bottleneck,
      diagnosis: diagnosis.message,
      recommendation: diagnosis.recommendation,
      slowFrames: List<SlowFrameSample>.unmodifiable(_slowFrames),
    );

    notifyListeners();
    _maybeWriteDiagnosticLog(nowUs);
  }

  _Diagnosis _diagnose({
    required int sampleCount,
    required double fps,
    required int frameRateLimit,
    required double budgetMs,
    required double p95IntervalMs,
    required double p95BuildMs,
    required double p95RasterMs,
    required double p95SchedulingMs,
    required double p95TotalMs,
  }) {
    if (sampleCount < 12) {
      return const _Diagnosis(
        PerformanceBottleneck.collecting,
        '正在收集帧样本',
        '保持当前场景活动几秒钟，以获得稳定结论。',
      );
    }

    final uiSlow = p95BuildMs > budgetMs;
    final rasterSlow = p95RasterMs > budgetMs;
    final schedulingSlow = p95SchedulingMs > budgetMs * 0.75;
    final intervalSlow = p95IntervalMs > budgetMs * 1.35;
    final pipelineSlow = p95TotalMs > budgetMs * 1.35;
    final nearConfiguredCap = frameRateLimit > 0 &&
        fps >= frameRateLimit * 0.82 &&
        fps <= frameRateLimit * 1.12 &&
        !uiSlow &&
        !rasterSlow;

    if (nearConfiguredCap) {
      return _Diagnosis(
        PerformanceBottleneck.frameRateCap,
        '当前 FPS 接近设置中的 $frameRateLimit FPS 上限',
        '若需要更高帧率，请在视频设置中关闭限帧或提高上限。',
      );
    }
    if (uiSlow && rasterSlow) {
      return const _Diagnosis(
        PerformanceBottleneck.uiAndRaster,
        'Widget 构建与 Raster 光栅化都超过帧预算',
        '先用 DevTools 深度时间线查找高频 Build/Layout，再用重绘彩虹检查大面积重复绘制。',
      );
    }
    if (uiSlow && schedulingSlow) {
      return const _Diagnosis(
        PerformanceBottleneck.uiAndScheduling,
        'UI 构建与帧开始前调度延迟都超过预算',
        'UI isolate 正在执行过多工作；重点检查高频 setState、同步资源处理、密集日志和未切分循环。',
      );
    }
    if (uiSlow) {
      return const _Diagnosis(
        PerformanceBottleneck.ui,
        'UI / Dart 构建阶段超过帧预算',
        '开启 DevTools 深度时间线，重点查看频繁 setState、同步解析、图片合成和大范围 Widget 重建。',
      );
    }
    if (rasterSlow) {
      return const _Diagnosis(
        PerformanceBottleneck.raster,
        'Raster / GPU 光栅化阶段超过帧预算',
        '开启重绘彩虹，重点检查大图缩放、模糊/阴影、saveLayer、渐变和缺少 RepaintBoundary 的动画。',
      );
    }
    if (schedulingSlow) {
      return const _Diagnosis(
        PerformanceBottleneck.scheduling,
        '帧开始前调度延迟偏高，UI isolate 可能被长任务占用',
        '检查同步文件/资源读取、密集日志、脚本解析和未切分的循环；在 DevTools CPU Profiler 中录制。',
      );
    }
    if (intervalSlow && !pipelineSlow) {
      return const _Diagnosis(
        PerformanceBottleneck.scheduling,
        '帧间隔偏高，但 Build/Raster 本身不慢',
        '先确认是否主动限帧或场景没有连续动画；若应持续动画，请检查 Timer、Ticker 和帧请求是否中断。',
      );
    }
    if (pipelineSlow) {
      return const _Diagnosis(
        PerformanceBottleneck.pipeline,
        '单项阶段未明显超标，但完整帧管线延迟偏高',
        '在 DevTools Performance 中同时查看 UI、Raster 与 shader compilation 事件。',
      );
    }
    return const _Diagnosis(
      PerformanceBottleneck.smooth,
      '最近样本均在目标帧预算内',
      '如仍有体感卡顿，请在问题场景中重置样本后重新采集。',
    );
  }

  void _maybeWriteDiagnosticLog(int nowUs) {
    if (!_shouldWriteTerminalLogs) {
      return;
    }
    final data = _snapshot;
    if (data.sampleCount < 12) {
      return;
    }

    final bottleneckChanged = _lastLoggedBottleneck != data.bottleneck;
    final intervalElapsed =
        nowUs - _lastDiagnosticLogUs >= _diagnosticLogInterval.inMicroseconds;
    if (!bottleneckChanged && !intervalElapsed) {
      return;
    }

    _lastLoggedBottleneck = data.bottleneck;
    _lastDiagnosticLogUs = nowUs;
    print(
      '[PERF][${data.bottleneckLabel}] '
      'fps=${data.fps.toStringAsFixed(1)}/${data.targetFps.toStringAsFixed(0)} '
      'cap=${data.frameRateLimit == 0 ? 'off' : data.frameRateLimit} | '
      'frame.avg/p95=${data.averageFrameIntervalMs.toStringAsFixed(1)}/'
      '${data.p95FrameIntervalMs.toStringAsFixed(1)}ms | '
      'ui.avg/p95=${data.averageBuildMs.toStringAsFixed(1)}/'
      '${data.p95BuildMs.toStringAsFixed(1)}ms | '
      'raster.avg/p95=${data.averageRasterMs.toStringAsFixed(1)}/'
      '${data.p95RasterMs.toStringAsFixed(1)}ms | '
      'schedule.avg/p95=${data.averageSchedulingMs.toStringAsFixed(1)}/'
      '${data.p95SchedulingMs.toStringAsFixed(1)}ms | '
      'total.p95=${data.p95TotalMs.toStringAsFixed(1)}ms '
      'jank=${(data.jankRate * 100).toStringAsFixed(0)}% '
      'samples=${data.sampleCount}',
    );
    if (bottleneckChanged) {
      print('[PERF][诊断] ${data.diagnosis}');
      print('[PERF][建议] ${data.recommendation}');
    }
  }

  static bool get _shouldWriteTerminalLogs => kSakiDiagnosticLogs;

  static double _average(List<double> values) {
    if (values.isEmpty) {
      return 0;
    }
    return values.reduce((a, b) => a + b) / values.length;
  }

  static double _percentile(List<double> values, double percentile) {
    if (values.isEmpty) {
      return 0;
    }
    final sorted = List<double>.of(values)..sort();
    final index =
        ((sorted.length - 1) * percentile).ceil().clamp(0, sorted.length - 1);
    return sorted[index];
  }

  static String _formatTime(DateTime value) {
    return '${value.hour.toString().padLeft(2, '0')}:'
        '${value.minute.toString().padLeft(2, '0')}:'
        '${value.second.toString().padLeft(2, '0')}';
  }
}

class _FrameSample {
  final double intervalMs;
  final double buildMs;
  final double rasterMs;
  final double schedulingMs;
  final double totalMs;

  const _FrameSample({
    required this.intervalMs,
    required this.buildMs,
    required this.rasterMs,
    required this.schedulingMs,
    required this.totalMs,
  });
}

class _Diagnosis {
  final PerformanceBottleneck bottleneck;
  final String message;
  final String recommendation;

  const _Diagnosis(this.bottleneck, this.message, this.recommendation);
}
