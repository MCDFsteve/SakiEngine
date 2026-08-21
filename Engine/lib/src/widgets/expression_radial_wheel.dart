import 'package:flutter/material.dart';
import 'package:sakiengine/src/widgets/command_radial_wheel.dart';

/// Debug差分快捷轮盘（按住Shift弹出）
class ExpressionRadialWheel extends StatelessWidget {
  final String characterName;
  final String currentExpression;
  final List<String> expressions;
  final Offset center;
  final ValueChanged<String> onHighlightedExpressionChanged;
  final Map<String, String>? expressionImagePaths;
  final VoidCallback? onDismiss;

  const ExpressionRadialWheel({
    super.key,
    required this.characterName,
    required this.currentExpression,
    required this.expressions,
    required this.center,
    required this.onHighlightedExpressionChanged,
    this.expressionImagePaths,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    if (expressions.isEmpty) {
      return const SizedBox.shrink();
    }

    final options = expressions
        .map(
          (expression) => CommandWheelOption(
            id: expression,
            label: expression,
            imagePath: expressionImagePaths?[expression],
          ),
        )
        .toList(growable: false);

    return CommandRadialWheel(
      title: characterName,
      currentOptionId: currentExpression,
      options: options,
      center: center,
      onHighlightedOptionChanged: onHighlightedExpressionChanged,
      applyHint: 'Release Shift To Apply',
      onDismiss: onDismiss,
    );
  }
}
