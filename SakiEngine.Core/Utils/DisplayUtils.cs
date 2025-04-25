using Microsoft.Xna.Framework.Graphics;
using System.Runtime.InteropServices;

namespace SakiEngine.Core.Utils
{
    /// <summary>
    /// 提供显示相关的辅助方法
    /// </summary>
    public static class DisplayUtils
    {
        /// <summary>
        /// 尝试根据原生显示高度的最后一位数字判断是否为 macOS 刘海屏 (Notched Display)。
        /// 这是一个基于观察的启发式方法，可能不完全准确。
        /// </summary>
        /// <returns>如果疑似刘海屏且运行在 macOS 上则返回 true，否则返回 false。</returns>
        public static bool IsLikelyNotchedDisplay()
        {
            // 此检测仅适用于 macOS
            if (!RuntimeInformation.IsOSPlatform(OSPlatform.OSX))
            {
                return false;
            }

            try
            {
                // 获取主显示器的原生分辨率
                var displayMode = GraphicsAdapter.DefaultAdapter.CurrentDisplayMode;
                int height = displayMode.Height;

                // 根据高度的最后一位判断 (非 0 或 1 则认为是刘海屏)
                int lastDigit = height % 10;
                bool isLikelyNotched = lastDigit != 0 && lastDigit != 1;

                // 可以在这里添加日志记录原生分辨率和判断结果，方便调试
                // Console.WriteLine($"[DisplayUtils] Native Height: {height}, LastDigit: {lastDigit}, IsLikelyNotched: {isLikelyNotched}");

                return isLikelyNotched;
            }
            catch (System.Exception ex)
            {
                // 获取显示信息可能失败，保守返回 false
                Console.WriteLine($"[DisplayUtils] Error detecting display mode: {ex.Message}");
                return false;
            }
        }
    }
} 