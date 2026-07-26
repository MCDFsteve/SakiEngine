import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sakiengine/src/config/saki_engine_config.dart';
import 'package:sakiengine/src/utils/debug_logger.dart';
import 'package:sakiengine/src/utils/performance_monitor.dart';
import 'package:sakiengine/src/utils/scaling_manager.dart';
import 'package:sakiengine/src/widgets/common/overlay_scaffold.dart';

class DebugPanelDialog extends StatefulWidget {
  final VoidCallback onClose;

  const DebugPanelDialog({
    super.key,
    required this.onClose,
  });

  @override
  State<DebugPanelDialog> createState() => _DebugPanelDialogState();
}

class _DebugPanelDialogState extends State<DebugPanelDialog>
    with TickerProviderStateMixin {
  late TabController _tabController;
  final ScrollController _logScrollController = ScrollController();
  String _engineVersion = '加载中...';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    SakiPerformanceMonitor.instance.start();
    _loadEngineVersion();

    // 自动滚动到日志底部
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_logScrollController.hasClients) {
        _logScrollController.animateTo(
          _logScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _loadEngineVersion() async {
    try {
      final pubspecContent = await rootBundle.loadString('pubspec.yaml');
      // 简单的字符串解析，查找 "version: " 行
      final lines = pubspecContent.split('\n');
      for (final line in lines) {
        if (line.trim().startsWith('version:')) {
          final version = line.split(':')[1].trim();
          setState(() {
            _engineVersion = version;
          });
          return;
        }
      }
      setState(() {
        _engineVersion = '未找到';
      });
    } catch (e) {
      setState(() {
        _engineVersion = '读取失败: $e';
      });
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final config = SakiEngineConfig();
    final scale = context.scaleFor(ComponentType.ui);

    return OverlayScaffold(
      title: '调试面板',
      onClose: (_) => widget.onClose(),
      content: Column(
        children: [
          // 标签页
          _buildTabBar(config, scale),

          // 内容区域
          Expanded(
            child: Focus(
              canRequestFocus: false,
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildSystemTab(config, scale),
                  _buildPerformanceTab(config, scale),
                  _buildLogTab(config, scale),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar(SakiEngineConfig config, double scale) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: config.themeColors.primary.withOpacity(0.3),
            width: 1,
          ),
        ),
      ),
      child: TabBar(
        controller: _tabController,
        indicatorColor: config.themeColors.primary,
        labelColor: config.themeColors.primary,
        unselectedLabelColor: config.themeColors.primary.withOpacity(0.6),
        labelStyle: TextStyle(
          fontFamily: 'SourceHanSansCN',
          fontSize: 16 * scale,
          fontWeight: FontWeight.w600,
        ),
        tabs: const [
          Tab(text: '系统信息'),
          Tab(text: '性能'),
          Tab(text: '调试日志'),
        ],
      ),
    );
  }

  Widget _buildPerformanceTab(SakiEngineConfig config, double scale) {
    final monitor = SakiPerformanceMonitor.instance;
    return ListenableBuilder(
      listenable: monitor,
      builder: (context, child) {
        final snapshot = monitor.snapshot;
        final statusColor = _performanceStatusColor(snapshot.bottleneck);
        return SingleChildScrollView(
          padding: EdgeInsets.all(16 * scale),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: EdgeInsets.all(16 * scale),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.08),
                  border: Border.all(
                    color: statusColor.withValues(alpha: 0.55),
                  ),
                  borderRadius: BorderRadius.circular(8 * scale),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      _performanceStatusIcon(snapshot.bottleneck),
                      color: statusColor,
                      size: 32 * scale,
                    ),
                    SizedBox(width: 14 * scale),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            snapshot.bottleneckLabel,
                            style: TextStyle(
                              color: statusColor,
                              fontSize: 20 * scale,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: 4 * scale),
                          Text(
                            snapshot.diagnosis,
                            style: TextStyle(
                              color: config.themeColors.primary,
                              fontSize: 14 * scale,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(height: 6 * scale),
                          Text(
                            snapshot.recommendation,
                            style: TextStyle(
                              color: config.themeColors.primary
                                  .withValues(alpha: 0.72),
                              fontSize: 12 * scale,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: 12 * scale),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          snapshot.fps > 0
                              ? snapshot.fps.toStringAsFixed(1)
                              : '--',
                          style: TextStyle(
                            color: statusColor,
                            fontSize: 30 * scale,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          'FPS',
                          style: TextStyle(
                            color: statusColor.withValues(alpha: 0.75),
                            fontSize: 11 * scale,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(height: 12 * scale),
              _buildPerformanceMetricsCard(config, scale, snapshot),
              SizedBox(height: 12 * scale),
              _buildPerformanceToolsCard(config, scale, monitor),
              SizedBox(height: 12 * scale),
              _buildSlowFramesCard(config, scale, snapshot),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPerformanceMetricsCard(
    SakiEngineConfig config,
    double scale,
    PerformanceSnapshot snapshot,
  ) {
    return Container(
      padding: EdgeInsets.all(14 * scale),
      decoration: BoxDecoration(
        color: config.themeColors.primaryDark.withValues(alpha: 0.05),
        border: Border.all(
          color: config.themeColors.primary.withValues(alpha: 0.3),
        ),
        borderRadius: BorderRadius.circular(8 * scale),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '帧耗时（平均 / P95）',
            style: TextStyle(
              color: config.themeColors.primary,
              fontSize: 15 * scale,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 10 * scale),
          Wrap(
            spacing: 8 * scale,
            runSpacing: 8 * scale,
            children: [
              _buildPerformanceMetric(
                'UI Build',
                snapshot.averageBuildMs,
                snapshot.p95BuildMs,
                snapshot.frameBudgetMs,
                config,
                scale,
              ),
              _buildPerformanceMetric(
                'Raster / GPU',
                snapshot.averageRasterMs,
                snapshot.p95RasterMs,
                snapshot.frameBudgetMs,
                config,
                scale,
              ),
              _buildPerformanceMetric(
                '调度延迟',
                snapshot.averageSchedulingMs,
                snapshot.p95SchedulingMs,
                snapshot.frameBudgetMs,
                config,
                scale,
              ),
              _buildPerformanceMetric(
                '完整帧管线',
                snapshot.averageTotalMs,
                snapshot.p95TotalMs,
                snapshot.frameBudgetMs,
                config,
                scale,
              ),
            ],
          ),
          SizedBox(height: 10 * scale),
          Text(
            '帧间隔 ${snapshot.averageFrameIntervalMs.toStringAsFixed(2)} / '
            '${snapshot.p95FrameIntervalMs.toStringAsFixed(2)} ms'
            '  ·  卡顿帧 ${(snapshot.jankRate * 100).toStringAsFixed(1)}%'
            '  ·  样本 ${snapshot.sampleCount}'
            '  ·  预算 ${snapshot.frameBudgetMs.toStringAsFixed(2)} ms'
            '  ·  ${snapshot.frameRateLimit == 0 ? '未限帧' : '限帧 ${snapshot.frameRateLimit} FPS'}',
            style: TextStyle(
              color: config.themeColors.primary.withValues(alpha: 0.7),
              fontSize: 11 * scale,
            ),
          ),
          if (kDebugMode) ...[
            SizedBox(height: 6 * scale),
            Text(
              'Debug 模式包含断言和 VM 调试开销；定位阶段类型后，请用 Profile 模式复核绝对帧率。',
              style: TextStyle(
                color: Colors.orange.withValues(alpha: 0.9),
                fontSize: 11 * scale,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPerformanceMetric(
    String label,
    double averageMs,
    double p95Ms,
    double budgetMs,
    SakiEngineConfig config,
    double scale,
  ) {
    final statusColor = p95Ms > budgetMs
        ? Colors.redAccent
        : p95Ms > budgetMs * 0.7
            ? Colors.orangeAccent
            : Colors.greenAccent.shade400;
    return Container(
      width: 150 * scale,
      padding: EdgeInsets.symmetric(
        horizontal: 10 * scale,
        vertical: 8 * scale,
      ),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.07),
        border: Border.all(color: statusColor.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(6 * scale),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: config.themeColors.primary.withValues(alpha: 0.68),
              fontSize: 11 * scale,
            ),
          ),
          SizedBox(height: 3 * scale),
          Text(
            '${averageMs.toStringAsFixed(2)} / ${p95Ms.toStringAsFixed(2)} ms',
            style: TextStyle(
              color: statusColor,
              fontSize: 13 * scale,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPerformanceToolsCard(
    SakiEngineConfig config,
    double scale,
    SakiPerformanceMonitor monitor,
  ) {
    return Container(
      padding: EdgeInsets.all(14 * scale),
      decoration: BoxDecoration(
        color: config.themeColors.primaryDark.withValues(alpha: 0.05),
        border: Border.all(
          color: config.themeColors.primary.withValues(alpha: 0.3),
        ),
        borderRadius: BorderRadius.circular(8 * scale),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '定位工具',
            style: TextStyle(
              color: config.themeColors.primary,
              fontSize: 15 * scale,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 8 * scale),
          _buildPerformanceSwitch(
            title: 'DevTools 深度时间线',
            description: '为用户 Widget Build、Layout 和 Paint 写入时间线事件；录制时会有额外开销。',
            value: monitor.deepProfilingEnabled,
            enabled: !kReleaseMode,
            onChanged: monitor.setDeepProfilingEnabled,
            config: config,
            scale: scale,
          ),
          _buildPerformanceSwitch(
            title: '重绘彩虹',
            description: '持续变色的区域正在重复绘制，可用于发现动画导致的大面积 Raster 开销。',
            value: monitor.repaintRainbowEnabled,
            enabled: !kReleaseMode,
            onChanged: monitor.setRepaintRainbowEnabled,
            config: config,
            scale: scale,
          ),
          SizedBox(height: 8 * scale),
          Wrap(
            spacing: 8 * scale,
            runSpacing: 8 * scale,
            children: [
              OutlinedButton.icon(
                onPressed: monitor.reset,
                icon: Icon(Icons.restart_alt, size: 16 * scale),
                label: const Text('重置样本'),
              ),
              OutlinedButton.icon(
                onPressed: _copyPerformanceReport,
                icon: Icon(Icons.copy, size: 16 * scale),
                label: const Text('复制性能报告'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPerformanceSwitch({
    required String title,
    required String description,
    required bool value,
    required bool enabled,
    required ValueChanged<bool> onChanged,
    required SakiEngineConfig config,
    required double scale,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4 * scale),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: config.themeColors.primary,
                    fontSize: 13 * scale,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  description,
                  style: TextStyle(
                    color: config.themeColors.primary.withValues(alpha: 0.62),
                    fontSize: 10.5 * scale,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: enabled && value,
            onChanged: enabled ? onChanged : null,
          ),
        ],
      ),
    );
  }

  Widget _buildSlowFramesCard(
    SakiEngineConfig config,
    double scale,
    PerformanceSnapshot snapshot,
  ) {
    return Container(
      padding: EdgeInsets.all(14 * scale),
      decoration: BoxDecoration(
        color: config.themeColors.primaryDark.withValues(alpha: 0.05),
        border: Border.all(
          color: config.themeColors.primary.withValues(alpha: 0.3),
        ),
        borderRadius: BorderRadius.circular(8 * scale),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '最近慢帧',
            style: TextStyle(
              color: config.themeColors.primary,
              fontSize: 15 * scale,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 8 * scale),
          if (snapshot.slowFrames.isEmpty)
            Text(
              '暂未记录到超过预算 25% 的慢帧。',
              style: TextStyle(
                color: config.themeColors.primary.withValues(alpha: 0.62),
                fontSize: 11 * scale,
              ),
            )
          else
            for (final frame in snapshot.slowFrames.reversed)
              Padding(
                padding: EdgeInsets.only(bottom: 4 * scale),
                child: Text(
                  '${_formatPerformanceTime(frame.recordedAt)}  '
                  '${frame.cause.padRight(6)}  '
                  'total ${frame.totalMs.toStringAsFixed(1)}  '
                  'UI ${frame.buildMs.toStringAsFixed(1)}  '
                  'Raster ${frame.rasterMs.toStringAsFixed(1)}  '
                  'Schedule ${frame.schedulingMs.toStringAsFixed(1)} ms',
                  style: TextStyle(
                    color: config.themeColors.primary.withValues(alpha: 0.78),
                    fontFamily: 'monospace',
                    fontSize: 10.5 * scale,
                  ),
                ),
              ),
        ],
      ),
    );
  }

  Color _performanceStatusColor(PerformanceBottleneck bottleneck) {
    switch (bottleneck) {
      case PerformanceBottleneck.collecting:
        return Colors.blueGrey;
      case PerformanceBottleneck.smooth:
        return Colors.greenAccent.shade400;
      case PerformanceBottleneck.frameRateCap:
        return Colors.lightBlueAccent;
      case PerformanceBottleneck.ui:
      case PerformanceBottleneck.raster:
      case PerformanceBottleneck.uiAndRaster:
      case PerformanceBottleneck.uiAndScheduling:
        return Colors.redAccent;
      case PerformanceBottleneck.scheduling:
      case PerformanceBottleneck.pipeline:
        return Colors.orangeAccent;
    }
  }

  IconData _performanceStatusIcon(PerformanceBottleneck bottleneck) {
    switch (bottleneck) {
      case PerformanceBottleneck.collecting:
        return Icons.hourglass_top;
      case PerformanceBottleneck.smooth:
        return Icons.check_circle_outline;
      case PerformanceBottleneck.frameRateCap:
        return Icons.speed;
      case PerformanceBottleneck.ui:
        return Icons.code;
      case PerformanceBottleneck.raster:
        return Icons.videogame_asset;
      case PerformanceBottleneck.uiAndRaster:
      case PerformanceBottleneck.uiAndScheduling:
        return Icons.warning_amber;
      case PerformanceBottleneck.scheduling:
        return Icons.schedule;
      case PerformanceBottleneck.pipeline:
        return Icons.account_tree_outlined;
    }
  }

  Future<void> _copyPerformanceReport() async {
    final report = SakiPerformanceMonitor.instance.buildReport();
    await Clipboard.setData(ClipboardData(text: report));
    DebugLogger.instance.addLog('[PERF] 性能报告已复制到剪贴板');
  }

  String _formatPerformanceTime(DateTime value) {
    return '${value.hour.toString().padLeft(2, '0')}:'
        '${value.minute.toString().padLeft(2, '0')}:'
        '${value.second.toString().padLeft(2, '0')}';
  }

  Widget _buildSystemTab(SakiEngineConfig config, double scale) {
    return Padding(
      padding: EdgeInsets.all(20 * scale),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSystemInfoCard(config, scale),
          SizedBox(height: 16 * scale),
          _buildQuickActionsCard(config, scale),
        ],
      ),
    );
  }

  Widget _buildSystemInfoCard(SakiEngineConfig config, double scale) {
    return Expanded(
      flex: 3,
      child: Container(
        padding: EdgeInsets.all(16 * scale),
        decoration: BoxDecoration(
          color: config.themeColors.primaryDark.withOpacity(0.05),
          border: Border.all(
            color: config.themeColors.primary.withOpacity(0.3),
            width: 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '系统信息',
              style: TextStyle(
                fontFamily: 'SourceHanSansCN',
                fontSize: 16 * scale,
                color: config.themeColors.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 12 * scale),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildInfoRow('引擎版本', _engineVersion, config, scale),
                    _buildInfoRow(
                        '平台', Platform.operatingSystem, config, scale),
                    _buildInfoRow('操作系统版本', Platform.operatingSystemVersion,
                        config, scale),
                    _buildInfoRow(
                        'CPU 架构', _getCpuArchitecture(), config, scale),
                    _buildInfoRow('Dart 版本', Platform.version.split(' ')[0],
                        config, scale),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickActionsCard(SakiEngineConfig config, double scale) {
    return Expanded(
      flex: 2,
      child: Container(
        padding: EdgeInsets.all(16 * scale),
        decoration: BoxDecoration(
          color: config.themeColors.primaryDark.withOpacity(0.05),
          border: Border.all(
            color: config.themeColors.primary.withOpacity(0.3),
            width: 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '快速操作',
              style: TextStyle(
                fontFamily: 'SourceHanSansCN',
                fontSize: 16 * scale,
                color: config.themeColors.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(height: 12 * scale),
            Expanded(
              child: Column(
                children: [
                  _buildActionButton(
                    '打开存档文件夹',
                    Icons.folder_open,
                    _openSaveDirectory,
                    config,
                    scale,
                  ),
                  SizedBox(height: 8 * scale),
                  _buildActionButton(
                    '清理日志记录',
                    Icons.clear_all,
                    _clearLogs,
                    config,
                    scale,
                  ),
                  SizedBox(height: 8 * scale),
                  _buildActionButton(
                    '复制系统信息',
                    Icons.copy,
                    _copySystemInfo,
                    config,
                    scale,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogTab(SakiEngineConfig config, double scale) {
    return Container(
      padding: EdgeInsets.all(16 * scale),
      child: Column(
        children: [
          // 日志控制栏
          Row(
            children: [
              Text(
                '调试日志',
                style: TextStyle(
                  fontFamily: 'SourceHanSansCN',
                  fontSize: 16 * scale,
                  color: config.themeColors.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: _copyLogs,
                icon: Icon(
                  Icons.copy,
                  size: 16 * scale,
                  color: config.themeColors.primary,
                ),
                label: Text(
                  '复制日志',
                  style: TextStyle(
                    fontSize: 14 * scale,
                    color: config.themeColors.primary,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _generateTestLogs,
                icon: Icon(
                  Icons.bug_report,
                  size: 16 * scale,
                  color: config.themeColors.primary,
                ),
                label: Text(
                  '测试日志',
                  style: TextStyle(
                    fontSize: 14 * scale,
                    color: config.themeColors.primary,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _clearLogs,
                icon: Icon(
                  Icons.clear_all,
                  size: 16 * scale,
                  color: config.themeColors.primary,
                ),
                label: Text(
                  '清空',
                  style: TextStyle(
                    fontSize: 14 * scale,
                    color: config.themeColors.primary,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: _scrollToBottom,
                icon: Icon(
                  Icons.arrow_downward,
                  size: 16 * scale,
                  color: config.themeColors.primary,
                ),
                label: Text(
                  '底部',
                  style: TextStyle(
                    fontSize: 14 * scale,
                    color: config.themeColors.primary,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 8 * scale),

          // 日志内容区域
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.8),
                border: Border.all(
                  color: config.themeColors.primary.withOpacity(0.3),
                  width: 1,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: _buildLogContent(config, scale),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogContent(SakiEngineConfig config, double scale) {
    return StreamBuilder<List<String>>(
      stream: DebugLogger.instance.logStream,
      initialData: DebugLogger.instance.logs, // 添加初始数据
      builder: (context, snapshot) {
        final logs = snapshot.data ?? DebugLogger.instance.logs;

        // 在数据更新时自动滚动到底部
        if (logs.isNotEmpty && snapshot.hasData) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_logScrollController.hasClients) {
              _logScrollController.animateTo(
                _logScrollController.position.maxScrollExtent,
                duration: const Duration(milliseconds: 100),
                curve: Curves.easeOut,
              );
            }
          });
        }

        if (logs.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 48 * scale,
                  color: Colors.grey,
                ),
                SizedBox(height: 12 * scale),
                Text(
                  '暂无日志记录',
                  style: TextStyle(
                    fontSize: 16 * scale,
                    color: Colors.grey,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: 8 * scale),
                Text(
                  '应用运行时的调试信息会显示在这里',
                  style: TextStyle(
                    fontSize: 12 * scale,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          controller: _logScrollController,
          padding: EdgeInsets.all(12 * scale),
          itemCount: logs.length,
          itemBuilder: (context, index) {
            final log = logs[index];
            return Container(
              margin: EdgeInsets.only(bottom: 2 * scale),
              padding: EdgeInsets.symmetric(
                horizontal: 8 * scale,
                vertical: 4 * scale,
              ),
              decoration: BoxDecoration(
                color: _getLogBackgroundColor(log).withOpacity(0.1),
                borderRadius: BorderRadius.circular(4 * scale),
                border: Border.all(
                  color: _getLogColor(log).withOpacity(0.2),
                  width: 0.5,
                ),
              ),
              child: SelectableText(
                log,
                style: TextStyle(
                  fontFamily: 'Monaco',
                  fontSize: 12 * scale,
                  color: _getLogColor(log),
                  height: 1.3,
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildInfoRow(
      String label, String value, SakiEngineConfig config, double scale) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8 * scale),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100 * scale,
            child: Text(
              '$label:',
              style: TextStyle(
                fontSize: 14 * scale,
                color: config.themeColors.primary.withOpacity(0.8),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 14 * scale,
                color: config.themeColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton(
    String text,
    IconData icon,
    VoidCallback onPressed,
    SakiEngineConfig config,
    double scale,
  ) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 16 * scale),
        label: Text(
          text,
          style: TextStyle(fontSize: 14 * scale),
        ),
        style: ElevatedButton.styleFrom(
          foregroundColor: config.themeColors.background,
          backgroundColor: config.themeColors.primary.withOpacity(0.8),
          padding: EdgeInsets.symmetric(
            horizontal: 16 * scale,
            vertical: 8 * scale,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
    );
  }

  Color _getLogColor(String log) {
    if (log.contains('[ERROR]')) return Colors.red[300]!;
    if (log.contains('[WARN]')) return Colors.orange[300]!;
    if (log.contains('[INFO]')) return Colors.blue[300]!;
    if (log.contains('[DEBUG]')) return Colors.grey[400]!;
    return Colors.green[300]!;
  }

  Color _getLogBackgroundColor(String log) {
    if (log.contains('[ERROR]')) return Colors.red;
    if (log.contains('[WARN]')) return Colors.orange;
    if (log.contains('[INFO]')) return Colors.blue;
    if (log.contains('[DEBUG]')) return Colors.grey;
    return Colors.green;
  }

  String _getCpuArchitecture() {
    try {
      final result = Process.runSync('uname', ['-m']);
      return result.stdout.toString().trim();
    } catch (e) {
      return 'Unknown';
    }
  }

  void _generateTestLogs() {
    DebugLogger.instance.log("生成测试日志开始");
    DebugLogger.instance.log("[INFO] 这是一条信息级别的日志");
    DebugLogger.instance.log("[WARN] 这是一条警告级别的日志");
    DebugLogger.instance.log("[ERROR] 这是一条错误级别的日志");
    DebugLogger.instance.log("[DEBUG] 这是一条调试级别的日志");
    DebugLogger.instance.log("普通日志消息");

    // 也通过print函数测试
    print("通过print函数输出的测试日志");
    print("[INFO] 通过print输出的信息日志");

    DebugLogger.instance.log("测试日志生成完成");
  }

  void _scrollToBottom() {
    if (_logScrollController.hasClients) {
      _logScrollController.animateTo(
        _logScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _clearLogs() {
    DebugLogger.instance.clear();
  }

  Future<void> _copyLogs() async {
    final logs = DebugLogger.instance.logs;
    if (logs.isEmpty) {
      DebugLogger.instance.log('暂无日志可复制');
      return;
    }

    final logText = logs.join('\n');
    await Clipboard.setData(ClipboardData(text: logText));
    DebugLogger.instance.log('已复制 ${logs.length} 条日志到剪贴板');
  }

  Future<void> _openSaveDirectory() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final savesBaseDir = '${directory.path}/SakiEngine/Saves';

      if (Platform.isMacOS) {
        await Process.run('open', [savesBaseDir]);
      } else if (Platform.isWindows) {
        await Process.run('explorer', [savesBaseDir]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [savesBaseDir]);
      }

      DebugLogger.instance.log('已打开存档文件夹: $savesBaseDir');
    } catch (e) {
      DebugLogger.instance.log('[ERROR] 打开存档文件夹失败: $e');
    }
  }

  Future<void> _copySystemInfo() async {
    final info = '''
引擎版本: $_engineVersion
平台: ${Platform.operatingSystem}
操作系统版本: ${Platform.operatingSystemVersion}
CPU 架构: ${_getCpuArchitecture()}
Dart 版本: ${Platform.version.split(' ')[0]}
''';

    await Clipboard.setData(ClipboardData(text: info));
    DebugLogger.instance.log('系统信息已复制到剪贴板');
  }
}
