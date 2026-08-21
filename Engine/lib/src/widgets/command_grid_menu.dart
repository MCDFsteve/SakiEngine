import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sakiengine/src/widgets/command_radial_wheel.dart';
import 'package:sakiengine/src/widgets/smart_image.dart';

/// Debug命令网格菜单（用于承载大量选项，如背景）
class CommandGridMenu extends StatefulWidget {
  final String title;
  final String applyHint;
  final List<CommandWheelOption> options;
  final String? currentOptionId;
  final Offset center;
  final ValueChanged<String> onHighlightedOptionChanged;
  final ValueChanged<String>? onOptionDoubleTap;
  final VoidCallback? onDismiss;

  const CommandGridMenu({
    super.key,
    required this.title,
    required this.options,
    required this.center,
    required this.onHighlightedOptionChanged,
    this.onOptionDoubleTap,
    this.currentOptionId,
    this.applyHint = 'Release Shift To Apply',
    this.onDismiss,
  });

  @override
  State<CommandGridMenu> createState() => _CommandGridMenuState();
}

class _CommandGridMenuState extends State<CommandGridMenu> {
  String? _highlightedId;

  @override
  void initState() {
    super.initState();
    _syncHighlight();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _highlightedId == null) {
        return;
      }
      widget.onHighlightedOptionChanged(_highlightedId!);
    });
  }

  @override
  void didUpdateWidget(covariant CommandGridMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.options != widget.options ||
        oldWidget.currentOptionId != widget.currentOptionId) {
      _syncHighlight();
      if (_highlightedId != null) {
        widget.onHighlightedOptionChanged(_highlightedId!);
      }
    }
  }

  void _syncHighlight() {
    if (widget.options.isEmpty) {
      _highlightedId = null;
      return;
    }
    final currentId = widget.currentOptionId;
    if (currentId != null && widget.options.any((o) => o.id == currentId)) {
      _highlightedId = currentId;
      return;
    }
    _highlightedId = widget.options.first.id;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.options.isEmpty) {
      return const SizedBox.shrink();
    }

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          widget.onDismiss?.call();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Positioned.fill(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            final menuWidth = size.width.clamp(560.0, 880.0);
            final menuHeight = size.height.clamp(360.0, 620.0);
            final left = (widget.center.dx - menuWidth / 2).clamp(
              12.0,
              size.width - menuWidth - 12.0,
            );
            final top = (widget.center.dy - menuHeight / 2).clamp(
              12.0,
              size.height - menuHeight - 12.0,
            );

            return Stack(
              children: [
                Positioned(
                  left: left,
                  top: top,
                  width: menuWidth,
                  height: menuHeight,
                  child: IgnorePointer(
                    ignoring: false,
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF121212).withOpacity(0.90),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.18),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.45),
                            blurRadius: 16,
                            offset: const Offset(0, 7),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Text(
                                  widget.applyHint,
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1, color: Color(0x33FFFFFF)),
                          Expanded(
                            child: GridView.builder(
                              padding: const EdgeInsets.all(10),
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent: 200,
                                    mainAxisSpacing: 8,
                                    crossAxisSpacing: 8,
                                    childAspectRatio: 1.30,
                                  ),
                              itemCount: widget.options.length,
                              itemBuilder: (context, index) {
                                final option = widget.options[index];
                                final selected = option.id == _highlightedId;
                                return _GridCell(
                                  option: option,
                                  selected: selected,
                                  onHover: () {
                                    if (_highlightedId == option.id) {
                                      return;
                                    }
                                    setState(() {
                                      _highlightedId = option.id;
                                    });
                                    widget.onHighlightedOptionChanged(
                                      option.id,
                                    );
                                  },
                                  onDoubleTap: () {
                                    if (_highlightedId != option.id) {
                                      setState(() {
                                        _highlightedId = option.id;
                                      });
                                      widget.onHighlightedOptionChanged(
                                        option.id,
                                      );
                                    }
                                    widget.onOptionDoubleTap?.call(option.id);
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _GridCell extends StatelessWidget {
  final CommandWheelOption option;
  final bool selected;
  final VoidCallback onHover;
  final VoidCallback? onDoubleTap;

  const _GridCell({
    required this.option,
    required this.selected,
    required this.onHover,
    this.onDoubleTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => onHover(),
      onHover: (_) => onHover(),
      child: GestureDetector(
        onTapDown: (_) => onHover(),
        onPanDown: (_) => onHover(),
        onDoubleTap: onDoubleTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: selected
                ? const Color(0xFFDA9D2B).withOpacity(0.24)
                : const Color(0xFF1F1F1F).withOpacity(0.76),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? const Color(0xFFF1C15D).withOpacity(0.92)
                  : Colors.white.withOpacity(0.16),
              width: selected ? 1.6 : 1.0,
            ),
          ),
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    color: const Color(0xFF151515),
                    child:
                        option.imagePath != null && option.imagePath!.isNotEmpty
                        ? SmartImage.asset(
                            option.imagePath!,
                            fit: BoxFit.cover,
                            width: double.infinity,
                            height: double.infinity,
                            errorWidget: const _GridFallbackIcon(),
                          )
                        : const _GridFallbackIcon(),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                option.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: selected ? const Color(0xFFFFF0A6) : Colors.white,
                  fontSize: selected ? 12.5 : 12,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GridFallbackIcon extends StatelessWidget {
  const _GridFallbackIcon();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF202020),
      alignment: Alignment.center,
      child: const Icon(
        Icons.image_not_supported_outlined,
        color: Colors.white30,
        size: 24,
      ),
    );
  }
}
