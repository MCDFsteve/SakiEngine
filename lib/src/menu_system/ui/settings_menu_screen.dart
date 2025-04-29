import 'package:flutter/material.dart';
import '../../utils/adaptive_sizer.dart'; // Import the new sizer
import 'package:provider/provider.dart'; // Import Provider
import 'dart:math'; // Import for min
import '../widgets/menu_button.dart'; // 引入 MenuButton
import '../widgets/styled_dropdown.dart'; // *** Add import for StyledDropdown ***
import '../../../main.dart'; // For kIsDesktopOS
import '../../widgets/constrained_scaffold.dart'; // Import the wrapper

// 设置菜单的 UI 界面 (StatelessWidget)
class SettingsMenuScreen extends StatelessWidget {
  // 接收状态和回调
  final List<Size> availableResolutions; // *** 新增：可用分辨率列表 ***
  final Size? native16x9PhysicalSize; // *** 新增：原生16:9尺寸 ***
  final Size? selectedResolution; // 当前选中的 *物理* 分辨率
  final bool isLoading; // 是否正在加载设置
  final bool isFullscreen; // *** 新增：当前是否全屏 ***
  final ValueChanged<Size?> onResolutionChanged; // 分辨率改变的回调
  final ValueChanged<bool?> onFullscreenChanged; // *** 新增：全屏切换的回调 ***
  final VoidCallback onGoBack; // 返回按钮的回调

  const SettingsMenuScreen({
    super.key,
    required this.availableResolutions, // *** 新增参数 ***
    this.native16x9PhysicalSize, // *** 新增参数 (可空) ***
    required this.selectedResolution,
    required this.isLoading,
    required this.isFullscreen, // *** 新增参数 ***
    required this.onResolutionChanged,
    required this.onFullscreenChanged, // *** 新增参数 ***
    required this.onGoBack,
  });

  // *** Helper moved outside build ***
  List<StyledDropdownMenuItem<bool>> _buildFullscreenItems(TextStyle itemTextStyle) {
      return [
          StyledDropdownMenuItem<bool>(
              value: true,
              child: Text('全屏', style: itemTextStyle),
          ),
          StyledDropdownMenuItem<bool>(
              value: false,
              child: Text('窗口化', style: itemTextStyle),
          ),
      ];
  }

  // *** Helper moved outside build ***
  List<StyledDropdownMenuItem<Size>> _buildResolutionItems(TextStyle itemTextStyle) {
      return availableResolutions.map((Size size) {
          String label = '${size.width.toInt()} x ${size.height.toInt()}';
          if (native16x9PhysicalSize != null && 
              size.width == native16x9PhysicalSize!.width && 
              size.height == native16x9PhysicalSize!.height) {
               label += ' (原生)';
          }
          return StyledDropdownMenuItem<Size>( 
            value: size,
            child: Text(label, style: itemTextStyle),
          );
      }).toList();
  }

  @override
  Widget build(BuildContext context) {
    // Watch for sizer changes to rebuild
    context.watch<AdaptiveSizer>();

    // ... (theme definition) ...
    final ThemeData theme = ThemeData.dark().copyWith(
       canvasColor: Colors.black.withOpacity(0.7),
    );

    // *** Revert base font size to use .sp ***
    // This still needs to be inside build because .sp depends on AdaptiveSizer
    final TextStyle itemTextStyle = TextStyle(fontSize: 18.sp, color: Colors.white);
    final TextStyle titleStyle = TextStyle(fontSize: 36.sp, fontWeight: FontWeight.bold, color: Colors.white);
    final TextStyle labelStyle = TextStyle(color: Colors.white, fontSize: 20.sp);
    final TextStyle hintStyle = itemTextStyle.copyWith(color: Colors.grey[600]);
    
    // *** Generate lists here, still potentially expensive *** 
    // Caching these would require a StatefulWidget or other state management
    final List<StyledDropdownMenuItem<bool>> fullscreenItems = _buildFullscreenItems(itemTextStyle);
    final List<StyledDropdownMenuItem<Size>> resolutionItems = _buildResolutionItems(itemTextStyle);

    // Define the body content widget separately
    Widget buildBodyContent() {
       return isLoading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                Center(
                  child: Container(
                    // Calculations using .sw/.sh need to be inside build
                    width: 0.36.sw,
                    padding: EdgeInsets.symmetric(horizontal: 0.02.sw, vertical: 0.037.sh),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.7),
                      borderRadius: BorderRadius.circular(min(1.sw, 1.sh) * 0.013),
                      border: Border.all(color: Colors.cyan.withOpacity(0.5), width: 0.0008.sw)
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '设置 / Settings',
                          style: titleStyle, // Use defined style
                        ),
                        SizedBox(height: 0.037.sh),
                        // Fullscreen/Windowed Row
                        Opacity(
                          opacity: !kIsDesktopOS ? 0.5 : 1.0,
                          child: AbsorbPointer(
                            absorbing: !kIsDesktopOS,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('显示模式:', style: labelStyle), // Use defined style
                                SizedBox(
                                  width: 0.13.sw,
                                  child: StyledDropdown<bool>(
                                    value: isFullscreen,
                                    items: fullscreenItems, // Use generated list
                                    onChanged: onFullscreenChanged,
                                    iconColor: Colors.cyan,
                                    hint: Text('选择模式', style: hintStyle), // Use defined style
                                    textStyle: itemTextStyle,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        SizedBox(height: 0.018.sh),
                        // Resolution Row
                        Opacity(
                          opacity: (isFullscreen || !kIsDesktopOS) ? 0.5 : 1.0,
                          child: AbsorbPointer(
                              absorbing: isFullscreen || !kIsDesktopOS,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween, // Added for consistency
                                children: [
                                  Text('分辨率:', style: labelStyle), // Use defined style
                                  SizedBox(
                                    width: 0.13.sw,
                                    child: StyledDropdown<Size>(
                                      value: selectedResolution,
                                      items: resolutionItems, // Use generated list
                                      onChanged: onResolutionChanged,
                                      iconColor: Colors.cyan,
                                      hint: Text('选择分辨率', style: hintStyle), // Use defined style
                                      textStyle: itemTextStyle,
                                    ),
                                  ),
                                ],
                              ),
                          ),
                        ),
                        SizedBox(height: 0.055.sh),
                        // Back button
                        Center(
                          child: MenuButton(
                            text: '返回',
                            onPressed: onGoBack,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
    }

    return Theme(
      data: theme,
      child: Constrained16x9Scaffold(
         body: buildBodyContent(),
      ),
    );
  }
}
