import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:sakiengine/src/config/saki_engine_config.dart';
import 'package:sakiengine/src/game/game_manager.dart';
import 'package:sakiengine/src/game/save_load_manager.dart';
import 'package:sakiengine/src/utils/binary_serializer.dart';
import 'package:sakiengine/src/screens/game_play_screen.dart';
import 'package:sakiengine/src/utils/scaling_manager.dart';
import 'package:sakiengine/src/utils/ui_sound_manager.dart';
import 'package:sakiengine/src/widgets/common/notification_overlay.dart';
import 'package:sakiengine/src/widgets/common/overlay_scaffold.dart';
import 'package:sakiengine/src/widgets/screenshot_thumbnail.dart';
import 'package:sakiengine/src/widgets/confirm_dialog.dart';
import 'package:sakiengine/src/widgets/common/square_icon_button.dart';
import 'package:sakiengine/src/utils/rich_text_parser.dart';
import 'package:sakiengine/src/localization/localization_manager.dart';

enum SaveLoadMode { save, load }

class SaveLoadScreen extends StatefulWidget {
  final SaveLoadMode mode;
  final GameManager? gameManager;
  final VoidCallback onClose;
  final VoidCallback? onLoadSuccess;
  final Function(SaveSlot)? onLoadSlot;
  final bool useOverlayScaffold;
  final bool showHeader;
  final bool showFooter;

  const SaveLoadScreen({
    super.key,
    required this.mode,
    this.gameManager,
    required this.onClose,
    this.onLoadSuccess,
    this.onLoadSlot,
    this.useOverlayScaffold = true,
    this.showHeader = true,
    this.showFooter = true,
  });

  @override
  State<SaveLoadScreen> createState() => _SaveLoadScreenState();
}

class _SaveLoadScreenState extends State<SaveLoadScreen> {
  final _notificationOverlayKey = GlobalKey<NotificationOverlayState>();
  final SaveLoadManager _saveLoadManager = SaveLoadManager();
  final ScrollController _scrollController = ScrollController();
  final LocalizationManager _localization = LocalizationManager();

  // 懒加载相关
  static const int _slotsPerPage = 24; // 每页24个存档位（4列x6行）
  final Map<int, SaveSlot?> _cachedSlots = {}; // 缓存已加载的存档位
  final ValueNotifier<int> _totalPages = ValueNotifier<int>(1); // 当前总页数
  bool _isLoadingMore = false;
  List<int>? _existingSlotIds; // 缓存存在的存档ID
  bool _isInitializing = true;
  Object? _initializationError;

  @override
  void initState() {
    super.initState();
    _initializeSaveSlots();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _cachedSlots.clear();
    _existingSlotIds = null;
    _totalPages.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      _loadMoreSlots();
    }
  }

  Future<void> _initializeSaveSlots() async {
    final openingStopwatch = Stopwatch()..start();
    var waitingStage = 'request-save-headers';
    final waitingHeartbeat = kSakiDiagnosticLogs
        ? Timer.periodic(const Duration(seconds: 1), (_) {
            sakiDiagnosticLog(
              '[SAKI_SAVE][SCREEN] waiting mode=${widget.mode.name} '
              'stage=$waitingStage '
              'elapsedMs=${openingStopwatch.elapsedMilliseconds}',
            );
          })
        : null;
    sakiDiagnosticLog('[SAKI_SAVE][SCREEN] open mode=${widget.mode.name}');
    if (mounted) {
      setState(() {
        _isInitializing = true;
        _initializationError = null;
      });
    }

    try {
      // Rust 索引器一次扫描并解析列表所需的轻量字段，避免先扫文件名、
      // 再逐个完整反序列化同一批存档。
      sakiDiagnosticLog(
        '[SAKI_SAVE][SCREEN] list-request-start mode=${widget.mode.name}',
      );
      final slots = await _saveLoadManager.listSaveSlots();
      waitingStage = 'apply-save-headers';
      sakiDiagnosticLog(
        '[SAKI_SAVE][SCREEN] list-request-done mode=${widget.mode.name} '
        'slots=${slots.length} elapsedMs=${openingStopwatch.elapsedMilliseconds}',
      );
      if (!mounted) return;

      final applyStopwatch = Stopwatch()..start();
      _cachedSlots.clear();
      for (final slot in slots) {
        _cachedSlots[slot.id] = slot;
      }
      _existingSlotIds = slots.map((slot) => slot.id).toList()..sort();

      // 计算初始页数（至少1页，如果有存档则基于最大ID计算）
      int initialPages = 1;
      if (_existingSlotIds != null && _existingSlotIds!.isNotEmpty) {
        final maxSlotId = _existingSlotIds!.last;
        initialPages = (maxSlotId / _slotsPerPage).ceil();
      }
      _totalPages.value = initialPages;
      applyStopwatch.stop();
      sakiDiagnosticLog(
        '[SAKI_SAVE][SCREEN] index-ready '
        'slots=${slots.length} applyMs='
        '${applyStopwatch.elapsedMicroseconds / 1000.0} elapsedMs='
        '${openingStopwatch.elapsedMicroseconds / 1000.0}',
      );
    } catch (error) {
      if (!mounted) return;
      _initializationError = error;
      print(
        '[SAKI_SAVE][SCREEN] failed elapsedMs='
        '${openingStopwatch.elapsedMicroseconds / 1000.0} error=$error',
      );
      _notificationOverlayKey.currentState?.show(
        _localization.t(
          'saveLoad.notification.initFailed',
          params: {'error': error.toString()},
        ),
      );
    } finally {
      waitingHeartbeat?.cancel();
      if (mounted) {
        waitingStage = 'build-first-grid-frame';
        setState(() {
          _isInitializing = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          openingStopwatch.stop();
          sakiDiagnosticLog(
            '[SAKI_SAVE][SCREEN] first-grid-frame '
            'slots=${_existingSlotIds?.length ?? 0} elapsedMs='
            '${openingStopwatch.elapsedMicroseconds / 1000.0}',
          );
        });
      }
    }
  }

  Future<void> _loadSlotsForPage(int page) async {
    final startSlotId = (page - 1) * _slotsPerPage + 1;
    final endSlotId = page * _slotsPerPage;

    try {
      final slots = await _saveLoadManager.listSaveSlotsInRange(
        startSlotId,
        endSlotId,
      );

      // 更新缓存
      for (int i = 0; i < slots.length; i++) {
        final slotId = startSlotId + i;
        _cachedSlots[slotId] = slots[i];
      }

      if (mounted) {
        setState(() {}); // 触发重绘显示新加载的数据
      }
    } catch (e) {
      print('加载第$page页存档失败: $e');
    }
  }

  Future<void> _loadMoreSlots() async {
    if (_isLoadingMore) return;

    _isLoadingMore = true;
    final nextPage = _totalPages.value + 1;

    await _loadSlotsForPage(nextPage);
    _totalPages.value = nextPage;

    _isLoadingMore = false;
  }

  int _getTotalSlotCount() {
    return _totalPages.value * _slotsPerPage;
  }

  Future<void> _updateSingleSlot(int slotId, SaveSlot? newSlotData) async {
    if (!mounted) return;

    // 直接更新缓存
    _cachedSlots[slotId] = newSlotData;

    // 如果是新存档，更新存在的存档ID列表
    if (newSlotData != null && _existingSlotIds != null) {
      if (!_existingSlotIds!.contains(slotId)) {
        _existingSlotIds!.add(slotId);
        _existingSlotIds!.sort();
      }
    } else if (newSlotData == null && _existingSlotIds != null) {
      _existingSlotIds!.remove(slotId);
    }

    setState(() {});
  }

  Future<void> _swapSlots(int slotId1, int slotId2) async {
    if (!mounted) return;

    final slot1 = _cachedSlots[slotId1];
    final slot2 = _cachedSlots[slotId2];

    if (slot1 != null && slot2 != null) {
      _cachedSlots[slotId1] = slot2.copyWith(id: slotId1);
      _cachedSlots[slotId2] = slot1.copyWith(id: slotId2);
    } else if (slot1 != null) {
      _cachedSlots[slotId1] = null;
      _cachedSlots[slotId2] = slot1.copyWith(id: slotId2);
    } else if (slot2 != null) {
      _cachedSlots[slotId1] = slot2.copyWith(id: slotId1);
      _cachedSlots[slotId2] = null;
    }

    setState(() {});
  }

  Future<void> _handleSave(int slotId) async {
    if (widget.gameManager == null || !mounted) return;

    try {
      final snapshot = widget.gameManager!.saveStateSnapshot();
      await _saveLoadManager.saveGame(
        slotId,
        widget.gameManager!.currentScriptFile,
        snapshot,
        widget.gameManager!.poseConfigs,
      );

      // 只更新单个存档位，避免全局重绘
      final updatedSlots = await _saveLoadManager.listSaveSlots();
      final newSlot = updatedSlots.firstWhere(
        (slot) => slot.id == slotId,
        orElse: () => SaveSlot(
          id: -1,
          saveTime: DateTime.now(),
          currentScript: '',
          dialoguePreview: '',
          snapshot: GameStateSnapshot(
            scriptIndex: 0,
            currentState: GameState.initial(),
          ),
        ),
      );

      if (newSlot.id != -1) {
        await _updateSingleSlot(slotId, newSlot);
      }
    } catch (e) {
      final message = e.toString();
      if (message.contains('存档已锁定，无法覆盖')) {
        _notificationOverlayKey.currentState?.show(
          _localization.t('saveLoad.notification.locked'),
        );
      } else {
        _notificationOverlayKey.currentState?.show(
          _localization.t(
            'saveLoad.notification.saveFailed',
            params: {'error': e.toString()},
          ),
        );
      }
    }
  }

  Future<void> _handleLoad(SaveSlot slot) async {
    final fullSlot = await _saveLoadManager.loadGame(slot.id);
    if (!mounted) return;
    if (fullSlot == null) {
      _notificationOverlayKey.currentState?.show(
        _localization.t('saveLoad.notification.loadFailed'),
      );
      return;
    }

    if (widget.onLoadSlot != null) {
      // 先让存档网格及其缩略图、语义节点完整卸载，再创建游戏页面。
      // 旧顺序会让读档页和游戏页在至少一个 frame 内重叠，并可能被
      // 异步语义回调继续强引用，显著抬高峰值和返回菜单后的内存。
      final onLoadSlot = widget.onLoadSlot!;
      widget.onClose();
      await WidgetsBinding.instance.endOfFrame;
      onLoadSlot(fullSlot);
    } else if (widget.onLoadSuccess != null) {
      // 如果有读档成功回调，就调用它而不是直接导航
      widget.onLoadSuccess!();
    } else {
      // 否则保持原有行为，直接导航到新的游戏界面
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(
          builder: (context) => GamePlayScreen(saveSlotToLoad: fullSlot),
        ),
        (route) => false,
      );
    }
  }

  Future<bool?> _showDeleteConfirmDialog(int slotId) async {
    return showDialog<bool>(
      context: context,
      builder: (context) => ConfirmDialog(
        title: _localization.t('saveLoad.delete.title'),
        content: _localization.t(
          'saveLoad.delete.content',
          params: {'id': slotId.toString().padLeft(2, '0')},
        ),
        onConfirm: () {},
        onCancel: () {},
        confirmResult: true,
        cancelResult: false,
      ),
    );
  }

  Future<void> _handleDelete(int slotId) async {
    try {
      await _saveLoadManager.deleteSave(slotId);
      //_notificationOverlayKey.currentState?.show('存档已删除');
      await _updateSingleSlot(slotId, null);
    } catch (e) {
      _notificationOverlayKey.currentState?.show(
        _localization.t(
          'saveLoad.notification.deleteFailed',
          params: {'error': e.toString()},
        ),
      );
    }
  }

  Future<void> _handleToggleLock(int slotId) async {
    try {
      final success = await _saveLoadManager.toggleSaveLock(slotId);
      if (success) {
        final currentSlot = _cachedSlots[slotId];
        if (currentSlot != null) {
          final isNowLocked = !currentSlot.isLocked;
          await _updateSingleSlot(
            slotId,
            currentSlot.copyWith(isLocked: isNowLocked),
          );
        }
      } else {
        _notificationOverlayKey.currentState?.show(
          _localization.t('saveLoad.notification.operationFailed'),
        );
      }
    } catch (e) {
      _notificationOverlayKey.currentState?.show(
        _localization.t(
          'saveLoad.notification.operationFailedWithError',
          params: {'error': e.toString()},
        ),
      );
    }
  }

  /// 获取网格列数（模块化）
  /// - 移动端（iOS/Android）：固定2列
  /// - 桌面端/Web：根据窗口高宽比自动调整（2/3/4列）
  int _getCurrentGridColumnCount(BuildContext context) {
    // 移动端固定2列
    if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
      return 2;
    }

    // 桌面端和Web根据窗口比例判断
    final screenRatio =
        MediaQuery.of(context).size.height / MediaQuery.of(context).size.width;
    if (screenRatio > 1.5) {
      return 2;
    } else if (screenRatio > 1.0) {
      return 3;
    } else {
      return 4;
    }
  }

  /// 获取网格卡片宽高比（模块化）
  /// 确保不同列数下内容完整显示
  double _getCurrentGridChildAspectRatio(BuildContext context) {
    // 移动端固定比例
    if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
      return 2.4;
    }

    // 桌面端和Web根据窗口比例判断
    final screenRatio =
        MediaQuery.of(context).size.height / MediaQuery.of(context).size.width;
    if (screenRatio > 1.5) {
      return 2.4;
    } else if (screenRatio > 1.0) {
      return 2.2;
    } else {
      return 2.25;
    }
  }

  String _formatScriptName(String scriptName) {
    if (scriptName.isEmpty) return '';

    // 处理特殊脚本名
    if (scriptName == 'start') {
      return _localization.t('saveLoad.script.prologue');
    }

    // 处理章节脚本名 (cpx_xxx 格式)
    final chapterMatch = RegExp(r'^cp(\d+)(_.*)?$').firstMatch(scriptName);
    if (chapterMatch != null) {
      final chapterNum = int.parse(chapterMatch.group(1)!);
      final chapterName = _getChapterName(chapterNum);
      return _localization.t(
        'saveLoad.script.chapter',
        params: {'name': chapterName},
      );
    }

    // 处理其他特殊脚本
    if (scriptName.startsWith('epilogue')) {
      return _localization.t('saveLoad.script.epilogue');
    }
    if (scriptName.startsWith('prologue')) {
      return _localization.t('saveLoad.script.prologue');
    }
    if (scriptName.startsWith('ending')) {
      return _localization.t('saveLoad.script.ending');
    }

    // 默认返回原文件名
    return scriptName;
  }

  String _getChapterName(int chapterNum) {
    // 尝试从翻译中获取章节名
    if (chapterNum <= 20) {
      return _localization.t('saveLoad.chapter.$chapterNum');
    } else {
      return chapterNum.toString(); // 超过20章用阿拉伯数字
    }
  }

  Future<void> _handleMove(int fromSlotId, int direction) async {
    final columnCount = _getCurrentGridColumnCount(context);
    int toSlotId;

    // 计算当前存档位在网格中的行列位置（从0开始）
    final fromRow = (fromSlotId - 1) ~/ columnCount;
    final fromCol = (fromSlotId - 1) % columnCount;

    switch (direction) {
      case 0: // 上
        final toRow = fromRow - 1;
        if (toRow < 0) {
          _notificationOverlayKey.currentState?.show(
            _localization.t('saveLoad.notification.cannotMoveUp'),
          );
          return;
        }
        toSlotId = toRow * columnCount + fromCol + 1;
        break;
      case 1: // 下
        final toRow = fromRow + 1;
        toSlotId = toRow * columnCount + fromCol + 1;
        break;
      case 2: // 左
        if (fromCol == 0) {
          _notificationOverlayKey.currentState?.show(
            _localization.t('saveLoad.notification.cannotMoveLeft'),
          );
          return;
        }
        toSlotId = fromSlotId - 1;
        break;
      case 3: // 右
        if (fromCol == columnCount - 1) {
          _notificationOverlayKey.currentState?.show(
            _localization.t('saveLoad.notification.cannotMoveRight'),
          );
          return;
        }
        toSlotId = fromSlotId + 1;
        break;
      default:
        return;
    }

    if (toSlotId < 1) {
      _notificationOverlayKey.currentState?.show(
        _localization.t(
          'saveLoad.notification.cannotMoveToSlot',
          params: {'id': toSlotId.toString().padLeft(2, '0')},
        ),
      );
      return;
    }

    try {
      final targetSlot = _cachedSlots[toSlotId];

      final bool success;
      if (targetSlot == null) {
        success = await _saveLoadManager.moveSave(fromSlotId, toSlotId);
        if (!success) {
          _notificationOverlayKey.currentState?.show(
            _localization.t('saveLoad.notification.cannotMoveLocked'),
          );
        }
      } else {
        success = await _saveLoadManager.swapSaves(fromSlotId, toSlotId);
        if (!success) {
          _notificationOverlayKey.currentState?.show(
            _localization.t('saveLoad.notification.cannotMoveLocked'),
          );
        }
      }

      if (success) {
        if (targetSlot == null) {
          final sourceSlot = _cachedSlots[fromSlotId];
          if (sourceSlot != null) {
            await _updateSingleSlot(fromSlotId, null);
            await _updateSingleSlot(
              toSlotId,
              sourceSlot.copyWith(id: toSlotId),
            );
          }
        } else {
          await _swapSlots(fromSlotId, toSlotId);
        }
      }
    } catch (e) {
      _notificationOverlayKey.currentState?.show(
        _localization.t(
          'saveLoad.notification.moveFailed',
          params: {'error': e.toString()},
        ),
      );
    }
  }

  String _getTitleText() {
    return widget.mode == SaveLoadMode.save
        ? _localization.t('saveLoad.title.save')
        : _localization.t('saveLoad.title.load');
  }

  @override
  Widget build(BuildContext context) {
    final uiScale = context.scaleFor(ComponentType.ui);
    final textScale = context.scaleFor(ComponentType.text);
    final config = SakiEngineConfig();
    final content = _buildGridContent(uiScale, textScale, config);

    return Stack(
      children: [
        if (widget.useOverlayScaffold)
          OverlayScaffold(
            title: _getTitleText(),
            showHeader: widget.showHeader,
            onClose: (_) => widget.onClose(),
            content: content,
            footer: widget.showFooter
                ? _buildFooter(uiScale, textScale, config)
                : null,
          )
        else
          content,
        NotificationOverlay(key: _notificationOverlayKey, scale: uiScale),
      ],
    );
  }

  Widget _buildGridContent(
    double uiScale,
    double textScale,
    SakiEngineConfig config,
  ) {
    if (_isInitializing) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
              color: config.themeColors.primary,
              strokeWidth: 2 * uiScale,
            ),
            SizedBox(height: 16 * uiScale),
            Text(
              _localization.t('saveLoad.loading'),
              style: config.reviewTitleTextStyle.copyWith(
                fontSize:
                    config.reviewTitleTextStyle.fontSize! * textScale * 0.45,
                color: config.themeColors.primary.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    if (_initializationError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _localization.t(
                'saveLoad.notification.initFailed',
                params: {'error': _initializationError.toString()},
              ),
              textAlign: TextAlign.center,
              style: config.reviewTitleTextStyle.copyWith(
                fontSize:
                    config.reviewTitleTextStyle.fontSize! * textScale * 0.4,
                color: config.themeColors.primary,
              ),
            ),
            SizedBox(height: 12 * uiScale),
            TextButton(
              onPressed: _initializeSaveSlots,
              child: Text(_localization.t('saveLoad.retry')),
            ),
          ],
        ),
      );
    }

    return ValueListenableBuilder<int>(
      valueListenable: _totalPages,
      builder: (context, totalPages, child) {
        final totalSlotCount = _getTotalSlotCount();

        return ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
          child: GridView.builder(
            controller: _scrollController,
            padding: EdgeInsets.all(32 * uiScale),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _getCurrentGridColumnCount(context),
              childAspectRatio: _getCurrentGridChildAspectRatio(context),
              crossAxisSpacing: 20 * uiScale,
              mainAxisSpacing: 20 * uiScale,
            ),
            itemCount:
                totalSlotCount + (_isLoadingMore ? 1 : 0), // 加载更多时显示加载指示器
            itemBuilder: (context, index) {
              // 如果是最后一个项目且正在加载，显示加载指示器
              if (index >= totalSlotCount) {
                return Center(
                  child: Padding(
                    padding: EdgeInsets.all(20 * uiScale),
                    child: CircularProgressIndicator(
                      color: config.themeColors.primary,
                      strokeWidth: 2 * uiScale,
                    ),
                  ),
                );
              }

              final slotId = index + 1;
              final saveSlot = _cachedSlots[slotId];
              final isSlotEmpty = saveSlot == null;

              return _SaveSlotCard(
                key: ValueKey('slot_$slotId'),
                slotId: slotId,
                saveSlot: saveSlot,
                loadScreenshot: saveSlot == null
                    ? null
                    : () => _saveLoadManager.loadSaveScreenshot(saveSlot),
                formattedScriptName: saveSlot != null
                    ? _formatScriptName(saveSlot.currentScript)
                    : '',
                config: config,
                uiScale: uiScale,
                textScale: textScale,
                localization: _localization,
                onTap: () {
                  if (widget.mode == SaveLoadMode.save) {
                    _handleSave(slotId);
                  } else if (!isSlotEmpty) {
                    _handleLoad(saveSlot);
                  }
                },
                onDelete: isSlotEmpty
                    ? null
                    : () async {
                        final shouldDelete = await _showDeleteConfirmDialog(
                          slotId,
                        );
                        if (shouldDelete == true) {
                          await _handleDelete(slotId);
                        }
                      },
                onToggleLock: isSlotEmpty
                    ? null
                    : () async {
                        await _handleToggleLock(slotId);
                      },
                onMove: isSlotEmpty
                    ? null
                    : (direction) async {
                        await _handleMove(slotId, direction);
                      },
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildFooter(
    double uiScale,
    double textScale,
    SakiEngineConfig config,
  ) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(vertical: 12 * uiScale),
      decoration: BoxDecoration(
        color: config.themeColors.primary.withValues(alpha: 0.05),
        border: Border(
          top: BorderSide(
            color: config.themeColors.primary.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
      ),
      child: ValueListenableBuilder<int>(
        valueListenable: _totalPages,
        builder: (context, totalPages, child) {
          if (_isInitializing) {
            return Center(
              child: Text(
                _localization.t('saveLoad.loading'),
                style: config.reviewTitleTextStyle.copyWith(
                  fontSize:
                      config.reviewTitleTextStyle.fontSize! * textScale * 0.4,
                  color: config.themeColors.primary.withValues(alpha: 0.7),
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.normal,
                ),
              ),
            );
          }

          final totalSlots = _getTotalSlotCount();
          final existingCount = _existingSlotIds?.length ?? 0;

          return Center(
            child: Text(
              widget.mode == SaveLoadMode.save
                  ? '${_localization.t('saveLoad.footer.selectSave')} • ${_localization.t('saveLoad.footer.displayed', params: {'count': totalSlots.toString()})} • ${_localization.t('saveLoad.footer.used', params: {'count': existingCount.toString()})}'
                  : '${_localization.t('saveLoad.footer.selectLoad')} • ${_localization.t('saveLoad.footer.displayed', params: {'count': totalSlots.toString()})} • ${_localization.t('saveLoad.footer.used', params: {'count': existingCount.toString()})}',
              style: config.reviewTitleTextStyle.copyWith(
                fontSize:
                    config.reviewTitleTextStyle.fontSize! * textScale * 0.4,
                color: config.themeColors.primary.withValues(alpha: 0.7),
                fontStyle: FontStyle.italic,
                fontWeight: FontWeight.normal,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SaveSlotCard extends StatefulWidget {
  final int slotId;
  final SaveSlot? saveSlot;
  final Future<Uint8List?> Function()? loadScreenshot;
  final String formattedScriptName;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  final VoidCallback? onToggleLock;
  final Function(int)? onMove;
  final SakiEngineConfig config;
  final double uiScale;
  final double textScale;
  final LocalizationManager localization;

  const _SaveSlotCard({
    super.key,
    required this.slotId,
    this.saveSlot,
    this.loadScreenshot,
    required this.formattedScriptName,
    required this.onTap,
    this.onDelete,
    this.onToggleLock,
    this.onMove,
    required this.config,
    required this.uiScale,
    required this.textScale,
    required this.localization,
  });

  @override
  State<_SaveSlotCard> createState() => _SaveSlotCardState();
}

class _SaveSlotCardState extends State<_SaveSlotCard>
    with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  late AnimationController _animationController;
  late Animation<double> _borderAnimation;
  final _uiSoundManager = UISoundManager();
  Future<String>? _dialoguePreviewFuture;
  Future<Uint8List?>? _screenshotFuture;

  Future<String>? _createDialoguePreviewFuture(SaveSlot? saveSlot) {
    if (saveSlot == null) {
      return null;
    }
    return SaveLoadManager.getDialoguePreview(saveSlot.snapshot);
  }

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _borderAnimation = Tween<double>(begin: 0.2, end: 0.5).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _dialoguePreviewFuture = _createDialoguePreviewFuture(widget.saveSlot);
    _screenshotFuture = widget.loadScreenshot?.call();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _SaveSlotCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldSlot = oldWidget.saveSlot;
    final newSlot = widget.saveSlot;
    final shouldRefreshDialogueFuture =
        oldSlot?.id != newSlot?.id ||
        oldSlot?.saveTime != newSlot?.saveTime ||
        oldSlot?.snapshot.scriptIndex != newSlot?.snapshot.scriptIndex;

    if (shouldRefreshDialogueFuture) {
      _dialoguePreviewFuture = _createDialoguePreviewFuture(newSlot);
      _screenshotFuture = widget.loadScreenshot?.call();
    }
  }

  Widget _buildScreenshot() {
    return FutureBuilder<Uint8List?>(
      future: _screenshotFuture,
      initialData: widget.saveSlot?.screenshotData,
      builder: (context, snapshot) => ScreenshotThumbnail(
        key: ValueKey('${widget.saveSlot?.id}_${widget.saveSlot?.saveTime}'),
        screenshotData: snapshot.data,
        borderRadius: 0 * widget.uiScale,
        placeholderColor: widget.config.themeColors.primary.withOpacity(0.1),
        iconColor: widget.config.themeColors.primary.withOpacity(0.3),
        iconSize: 24 * widget.uiScale,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final uiScale = widget.uiScale;
    final config = widget.config;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          _uiSoundManager.playButtonClick();
          widget.onTap();
        },
        borderRadius: BorderRadius.circular(0 * uiScale),
        hoverColor: config.themeColors.primary.withOpacity(0.1),
        onHover: (hovering) {
          if (_isHovered != hovering) {
            setState(() {
              _isHovered = hovering;
            });
            if (hovering) {
              _uiSoundManager.playButtonHover();
              _animationController.forward();
            } else {
              _animationController.reverse();
            }
          }
        },
        child: AnimatedBuilder(
          animation: _borderAnimation,
          builder: (context, child) => Container(
            decoration: BoxDecoration(
              color: _isHovered
                  ? config.themeColors.primary.withOpacity(0.05)
                  : Colors.transparent,
              border: Border.all(
                color: config.themeColors.primary.withOpacity(
                  _borderAnimation.value,
                ),
                width: 1,
              ),
              borderRadius: BorderRadius.circular(0 * uiScale),
            ),
            child: Stack(
              children: [
                Padding(
                  padding: EdgeInsets.all(12.0 * uiScale),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 内容区域
                      Expanded(
                        child: widget.saveSlot != null
                            ? _buildDataCard(uiScale, widget.textScale, config)
                            : _buildEmptyCard(
                                uiScale,
                                widget.textScale,
                                config,
                              ),
                      ),
                    ],
                  ),
                ),
                if ((widget.onMove != null ||
                        widget.onDelete != null ||
                        widget.onToggleLock != null) &&
                    widget.saveSlot != null)
                  Positioned(
                    bottom: 8 * uiScale,
                    right: 8 * uiScale,
                    child: _buildActionButtons(uiScale, config),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButtons(double uiScale, SakiEngineConfig config) {
    // 移动端按钮尺寸加倍
    final isMobile = !kIsWeb && (Platform.isIOS || Platform.isAndroid);
    final buttonSize = isMobile ? 45 * uiScale : 26 * uiScale;
    final buttonSpacing = isMobile ? 6 * uiScale : 3 * uiScale;
    final isLocked = widget.saveSlot?.isLocked ?? false;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.onMove != null && !isLocked) ...[
          SquareIconButton(
            icon: Icons.keyboard_arrow_up,
            size: buttonSize,
            onTap: () => widget.onMove!(0),
          ),
          SizedBox(width: buttonSpacing),
          SquareIconButton(
            icon: Icons.keyboard_arrow_down,
            size: buttonSize,
            onTap: () => widget.onMove!(1),
          ),
          SizedBox(width: buttonSpacing),
          SquareIconButton(
            icon: Icons.keyboard_arrow_left,
            size: buttonSize,
            onTap: () => widget.onMove!(2),
          ),
          SizedBox(width: buttonSpacing),
          SquareIconButton(
            icon: Icons.keyboard_arrow_right,
            size: buttonSize,
            onTap: () => widget.onMove!(3),
          ),
          SizedBox(width: buttonSpacing),
        ],
        if (widget.onToggleLock != null)
          SquareIconButton(
            icon: isLocked ? Icons.lock : Icons.lock_open,
            size: buttonSize,
            onTap: () => widget.onToggleLock!(),
            hoverBackgroundColor: config.themeColors.primary.withOpacity(0.1),
          ),
        if (widget.onDelete != null && !isLocked) ...[
          SizedBox(width: buttonSpacing),
          SquareIconButton(
            icon: Icons.close,
            size: buttonSize,
            onTap: () => widget.onDelete!(),
            hoverBackgroundColor: config.themeColors.primary.withOpacity(0.1),
          ),
        ],
      ],
    );
  }

  Widget _buildDataCard(
    double uiScale,
    double textScale,
    SakiEngineConfig config,
  ) {
    final isLocked = widget.saveSlot?.isLocked ?? false;
    final opacity = isLocked ? 0.6 : 1.0;

    // 移动端对话文字增大2/3
    final isMobile = !kIsWeb && (Platform.isIOS || Platform.isAndroid);
    final dialogueFontSize = isMobile ? 0.5 : 0.36;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 标题行
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              widget.localization.t(
                'saveLoad.slot',
                params: {'id': widget.slotId.toString().padLeft(2, '0')},
              ),
              style: config.reviewTitleTextStyle.copyWith(
                fontSize:
                    config.reviewTitleTextStyle.fontSize! * textScale * 0.45,
                color: config.themeColors.primary.withOpacity(opacity),
                fontWeight: FontWeight.bold,
              ),
            ),
            if (widget.saveSlot != null)
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 章节名显示在时间左侧
                    if (widget.formattedScriptName.isNotEmpty)
                      Flexible(
                        child: Text(
                          widget.formattedScriptName,
                          style: config.reviewTitleTextStyle.copyWith(
                            fontSize:
                                config.reviewTitleTextStyle.fontSize! *
                                textScale *
                                0.32,
                            color: config.themeColors.primary.withOpacity(
                              0.6 * opacity,
                            ),
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.5,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (widget.formattedScriptName.isNotEmpty)
                      SizedBox(width: 8 * uiScale),
                    // 时间显示在右侧
                    Text(
                      DateFormat(
                        'MM-dd HH:mm',
                      ).format(widget.saveSlot!.saveTime),
                      style: config.reviewTitleTextStyle.copyWith(
                        fontSize:
                            config.reviewTitleTextStyle.fontSize! *
                            textScale *
                            0.32,
                        color: config.themeColors.primary.withOpacity(
                          0.6 * opacity,
                        ),
                        fontWeight: FontWeight.normal,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
        // 移除之前独立的脚本文件名显示
        SizedBox(height: 6 * uiScale),
        // 内容区域 - 使用Expanded确保不会溢出
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 截图区域 - 使用更小的宽高比
              Expanded(
                flex: 14,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(0 * uiScale),
                  child: AspectRatio(
                    aspectRatio: 16 / 10, // 从16:9改为16:10，减少高度
                    child: Opacity(opacity: opacity, child: _buildScreenshot()),
                  ),
                ),
              ),
              SizedBox(width: 8 * uiScale), // 减少间距
              // 文本区域 - 使用FutureBuilder实时查询对话预览
              Expanded(
                flex: 13,
                child: FutureBuilder<String>(
                  future: _dialoguePreviewFuture,
                  builder: (context, snapshot) {
                    final dialogueText =
                        snapshot.data ?? widget.saveSlot!.dialoguePreview;
                    return Text(
                      RichTextParser.cleanText(dialogueText),
                      maxLines: 3, // 减少行数从4到3
                      overflow: TextOverflow.ellipsis,
                      style: config.reviewTitleTextStyle.copyWith(
                        fontSize:
                            config.reviewTitleTextStyle.fontSize! *
                            textScale *
                            dialogueFontSize,
                        color: config.themeColors.onSurface.withOpacity(
                          0.8 * opacity,
                        ),
                        fontWeight: FontWeight.normal,
                        height: 1.2, // 减少行高从1.4到1.2
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyCard(
    double uiScale,
    double textScale,
    SakiEngineConfig config,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.localization.t(
            'saveLoad.slot',
            params: {'id': widget.slotId.toString().padLeft(2, '0')},
          ),
          style: config.reviewTitleTextStyle.copyWith(
            fontSize: config.reviewTitleTextStyle.fontSize! * textScale * 0.45,
            color: config.themeColors.primary.withOpacity(0.5),
            fontWeight: FontWeight.bold,
          ),
        ),
        SizedBox(height: 6 * uiScale),
        Expanded(
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min, // 防止溢出
              children: [
                Icon(
                  Icons.add_box_sharp,
                  size: 24 * uiScale, // 减小图标大小
                  color: config.themeColors.primary.withOpacity(0.3),
                ),
                SizedBox(height: 4 * uiScale), // 减少间距
                Text(
                  widget.localization.t('saveLoad.empty'),
                  style: config.reviewTitleTextStyle.copyWith(
                    fontSize:
                        config.reviewTitleTextStyle.fontSize! *
                        textScale *
                        0.36,
                    color: config.themeColors.primary.withOpacity(0.3),
                    fontWeight: FontWeight.normal,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
