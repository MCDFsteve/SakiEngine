import 'package:flutter/material.dart';
import '../../utils/adaptive_sizer.dart'; // Import the new sizer
import 'package:provider/provider.dart'; // Import Provider
// import '../../utils/resolution_sizer.dart'; // REMOVED
// import 'package:flutter_screenutil/flutter_screenutil.dart'; // REMOVED
import 'dart:math'; // Import for min function

// 可复用的菜单按钮样式
class MenuButton extends StatelessWidget {
  final String text;
  final VoidCallback onPressed;

  const MenuButton({super.key, required this.text, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    // Watch for sizer changes to rebuild
    context.watch<AdaptiveSizer>();

    // 使用基于屏幕宽度(sw)和高度(sh)的归一化坐标
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 0.01.sh), // 垂直间距使用 sh
      child: ElevatedButton(
        onPressed: onPressed,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent, // 透明背景
          foregroundColor: Colors.white, // 白色文字
          minimumSize: Size(0.15.sw, 0.07.sh), // 最小尺寸使用 sw 和 sh
          shape: RoundedRectangleBorder(
            // 圆角半径使用屏幕短边的比例
            borderRadius: BorderRadius.circular(min(1.sw, 1.sh) * 0.015),
            // 边框宽度使用 sw
            side: BorderSide(color: Colors.cyan.withOpacity(0.7), width: 0.0015.sw),
          ),
          elevation: 0,
           shadowColor: Colors.transparent
        ).copyWith(
           overlayColor: MaterialStateProperty.resolveWith<Color?>(
             (Set<MaterialState> states) {
               if (states.contains(MaterialState.hovered)) {
                 return Colors.cyan.withOpacity(0.1); // 悬停效果
               }
               if (states.contains(MaterialState.pressed)) {
                 return Colors.cyan.withOpacity(0.2); // 按下效果
               }
               return null;
             },
           ),
        ),
        // *** Revert font size to use .sp ***
        child: Text(text, style: TextStyle(fontSize: 24.sp)), 
      ),
    );
  }
} 