import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sakiengine/src/localization/localization_manager.dart';
import 'package:sakiengine/src/utils/music_manager.dart';
import 'package:sakiengine/src/utils/foundation_compat.dart';
import 'package:sakiengine/src/utils/ui_sound_manager.dart';
import 'package:sakiengine/src/widgets/confirm_dialog.dart';

import '../../utils/platform_window_manager_io.dart'
    if (dart.library.html) '../../utils/platform_window_manager_web.dart';

class ExitConfirmationDialog {
  static Future<void> closeApplication() async {
    try {
      await Future.wait<void>([
        MusicManager().shutdown(),
        UISoundManager().shutdown(),
      ]);
      await PlatformWindowManager.setPreventClose(false);
      await PlatformWindowManager.close();
    } catch (_) {
      SystemNavigator.pop();
    }
  }

  static Future<bool> showExitConfirmation(
    BuildContext context, {
    bool hasProgress = true,
  }) async {
    final localization = LocalizationManager();
    final title = localization.t('dialog.exit.title');
    final content = hasProgress
        ? localization.t('dialog.exit.contentWithProgress')
        : localization.t('dialog.exit.contentSimple');

    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return ConfirmDialog(
          title: title,
          content: content,
          onConfirm: () => Navigator.of(context).pop(true),
        );
      },
    );
    return shouldExit ?? false;
  }

  static Future<void> showExitConfirmationAndDestroy(BuildContext context) async {
    final localization = LocalizationManager();
    final title = localization.t('dialog.exit.title');
    final content = localization.t('dialog.exit.contentSimple');

    final shouldExit = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return ConfirmDialog(
          title: title,
          content: content,
          onConfirm: () => Navigator.of(context).pop(true),
        );
      },
    );

    if (shouldExit == true) {
      await closeApplication();
    }
  }
}
