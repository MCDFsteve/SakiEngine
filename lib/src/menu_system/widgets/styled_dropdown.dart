import 'dart:async';
import 'dart:math'; // Import for min

import 'package:flutter/material.dart';
import '../../utils/adaptive_sizer.dart'; // Import the new sizer
import 'package:provider/provider.dart'; // Import Provider
// import 'package:flutter_screenutil/flutter_screenutil.dart'; // REMOVED
import 'package:vector_math/vector_math_64.dart' as vector;

// 下拉菜单项的数据结构
class StyledDropdownMenuItem<T> {
  final T value;
  final Widget child; // 用于显示在按钮和下拉列表中的 Widget

  const StyledDropdownMenuItem({required this.value, required this.child});
}

// 自定义的下拉菜单 Widget
class StyledDropdown<T> extends StatefulWidget {
  final T? value; // 当前选中的值
  final List<StyledDropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final Widget? hint; // 未选中任何项时的提示 Widget
  final Color iconColor;
  final TextStyle? textStyle; // Allow passing text style

  const StyledDropdown({
    super.key,
    required this.items,
    this.value,
    this.onChanged,
    this.hint,
    this.iconColor = Colors.cyan,
    this.textStyle, // Default text style can be defined in build
  });

  @override
  State<StyledDropdown<T>> createState() => _StyledDropdownState<T>();
}

class _StyledDropdownState<T> extends State<StyledDropdown<T>> {
  bool _isOpen = false;
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  late Timer _timer; // Timer for debouncing hover state

  @override
  void initState() {
    super.initState();
    _timer = Timer(Duration.zero, () {}); // Initialize timer
  }

  @override
  void dispose() {
    _removeOverlay();
    _timer.cancel(); // Cancel timer on dispose
    super.dispose();
  }

  void _toggleDropdown() {
    setState(() {
      _isOpen = !_isOpen;
      if (_isOpen) {
        _createOverlay();
      } else {
        _removeOverlay();
      }
    });
  }

  void _closeDropdown() {
    if (_isOpen) {
       setState(() {
        _isOpen = false;
         _removeOverlay();
      });
    }
  }

  void _createOverlay() {
    if (_overlayEntry != null) return;
    final overlay = Overlay.of(context);
    final renderBox = context.findRenderObject() as RenderBox;
    final size = renderBox.size;

    final double itemBorderRadius = min(1.sw, 1.sh) * 0.005; // Example calculation
    final double itemBorderWidth = 0.0008.sw; // Example calculation

    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        width: size.width,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: Offset(0.0, size.height),
          child: TapRegion(
            onTapOutside: (event) => _closeDropdown(),
            child: Material(
              elevation: 4.0,
              color: Colors.grey[850],
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(itemBorderRadius),
                side: BorderSide(color: Colors.grey[700] ?? Colors.grey, width: itemBorderWidth)
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: widget.items.map((item) {
                  return InkWell(
                    onTap: () {
                      widget.onChanged?.call(item.value);
                      _closeDropdown();
                    },
                    child: Container(
                      height: 0.045.sh, // Use sh for height
                      padding: EdgeInsets.symmetric(horizontal: 0.015.sw), // Use sw for horizontal padding
                      alignment: Alignment.centerLeft,
                      // Use the passed textStyle or default defined in build
                      child: DefaultTextStyle.merge(
                          style: widget.textStyle ?? TextStyle(fontSize: 18.sp, color: Colors.white),
                          child: item.child
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(_overlayEntry!);
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  // Builds the widget representing the currently selected item
  Widget _buildSelectedItemWidget() {
    // Define base text style, similar to SettingsMenuScreen or use passed style
    final TextStyle effectiveTextStyle = widget.textStyle ?? TextStyle(fontSize: 18.sp, color: Colors.white);
    final TextStyle hintTextStyle = effectiveTextStyle.copyWith(color: Colors.grey[600]);

    if (widget.value == null) {
      return widget.hint ?? Text('Select', style: hintTextStyle);
    }
    final selectedItem = widget.items.firstWhere(
      (item) => item.value == widget.value,
      orElse: () {
        assert(widget.items.isNotEmpty, 'Dropdown has a non-null value but no items.');
        return StyledDropdownMenuItem<T>(
              value: widget.items.first.value,
              child: widget.hint ?? Text('Select', style: hintTextStyle)
            );
      },
    );
    // Apply the text style to the selected item's child
    return DefaultTextStyle.merge(
        style: effectiveTextStyle,
        child: selectedItem.child
    );
  }

  @override
  Widget build(BuildContext context) {
    // Watch for sizer changes to rebuild
    context.watch<AdaptiveSizer>();

    final theme = Theme.of(context);
    // Define base text style if not passed
    final TextStyle effectiveTextStyle = widget.textStyle ?? TextStyle(fontSize: 18.sp, color: Colors.white);
    
    // Define button style using normalized coordinates
    final ButtonStyle buttonStyle = ButtonStyle(
        minimumSize: MaterialStateProperty.all(Size(0, 0)), // Let padding define size
        padding: MaterialStateProperty.all(EdgeInsets.symmetric(horizontal: 0.008.sw, vertical: 0.01.sh)), // Use sw and sh
        shape: MaterialStateProperty.all<RoundedRectangleBorder>(
           RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(min(1.sw, 1.sh) * 0.005), // Use min(sw,sh)
                side: BorderSide(color: Colors.grey[700] ?? Colors.grey, width: 0.0008.sw) // Use sw
            )
        ),
        elevation: MaterialStateProperty.all(0),
        shadowColor: MaterialStateProperty.all(Colors.transparent),
        alignment: Alignment.centerLeft,
    ).copyWith(
        overlayColor: MaterialStateProperty.resolveWith<Color?>((states) {
          if (states.contains(WidgetState.hovered)) return Colors.cyan.withOpacity(0.08);
          if (states.contains(WidgetState.pressed)) return Colors.cyan.withOpacity(0.15);
          return null;
        }),
    );

    return CompositedTransformTarget(
      link: _layerLink,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _toggleDropdown,
          customBorder: buttonStyle.shape?.resolve({}),
          overlayColor: buttonStyle.overlayColor,
          child: Ink(
            decoration: ShapeDecoration(
               shape: buttonStyle.shape!.resolve({})!,
               color: Colors.black.withOpacity(0.2)
            ),
            child: Container(
              // Padding is now controlled by ButtonStyle
              // constraints: BoxConstraints(minHeight: ...), // Removed minHeight
              padding: buttonStyle.padding!.resolve({}), // Apply padding from ButtonStyle
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  // Apply text style here as well
                  DefaultTextStyle.merge(
                    style: effectiveTextStyle,
                    child: _buildSelectedItemWidget(),
                  ),
                  SizedBox(width: 0.004.sw), // Use sw
                  AnimatedRotation(
                      turns: _isOpen ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                          Icons.keyboard_arrow_down,
                          color: widget.iconColor ?? theme.iconTheme.color ?? Colors.white,
                          size: min(1.sw, 1.sh) * 0.02, // Use min(sw,sh)
                        ),
                      ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
} 