using Microsoft.Xna.Framework;
using Microsoft.Xna.Framework.Graphics;
using System;
using System.Collections.Generic;
using System.Linq;

namespace SakiEngine.Core.GameCore
{
    /// <summary>
    /// 标准分辨率预设 (用于基础列表)
    /// </summary>
    public enum StandardResolutionPreset
    {
        p540 = 0,     // 960x540
        HD = 1,       // 1280x720
        HD_Plus = 2,  // 1600x900
        FullHD = 3,   // 1920x1080
        QHD = 4       // 2560x1440
    }

    /// <summary>
    /// 分辨率管理器 (支持动态添加基于屏幕的16:9分辨率并排序)
    /// </summary>
    public class ResolutionManager
    {
        private readonly Game _game;
        private readonly GraphicsDeviceManager _graphics;

        // 标准预设分辨率数组
        private static readonly Point[] StandardResolutionSizes = new[]
        {
            new Point(960, 540),   // p540
            new Point(1280, 720),  // HD
            new Point(1600, 900),  // HD Plus
            new Point(1920, 1080), // Full HD
            new Point(2560, 1440)  // QHD
        };

        // 存储所有可用分辨率 (包括动态添加的)
        private readonly List<Point> _availableResolutions;
        public IReadOnlyList<Point> AvailableResolutions => _availableResolutions.AsReadOnly(); // Expose as ReadOnly

        // 存储所有可用分辨率的显示名称
        private readonly List<string> _availableResolutionNames;
        public IReadOnlyList<string> AvailableResolutionNames => _availableResolutionNames.AsReadOnly(); // Expose as ReadOnly

        // 当前窗口大小 (Point)
        public Point CurrentWindowSize { get; private set; }

        // 存储上次窗口化时的大小
        private Point? _lastWindowedSize = null;

        // 目标内部渲染宽高比 (16:9)
        private const float TargetAspectRatio = (float)GameInstance.InternalWidth / GameInstance.InternalHeight;

        /// <summary>
        /// 构造函数 - 动态分辨率添加、排序和默认选择
        /// </summary>
        public ResolutionManager(Game game, GraphicsDeviceManager graphics)
        {
            _game = game;
            _graphics = graphics;

            // 初始化可用列表 (从标准列表开始)
            _availableResolutions = new List<Point>(StandardResolutionSizes);
            _availableResolutionNames = new List<string>();
            foreach (var size in StandardResolutionSizes)
            {
                _availableResolutionNames.Add($"{size.X} x {size.Y}");
            }

            // 检测主显示器分辨率
            var displayMode = GraphicsAdapter.DefaultAdapter.CurrentDisplayMode;
            Console.WriteLine($"[ResolutionManager] Detected Display: {displayMode.Width}x{displayMode.Height}");

            // 计算基于屏幕宽度的动态 16:9 分辨率
            int detectedWidth = displayMode.Width;
            int dynamicHeight = (int)Math.Round(detectedWidth * 9.0 / 16.0);
            Point dynamicRes = new Point(detectedWidth, dynamicHeight);
            Console.WriteLine($"[ResolutionManager] Calculated dynamic 16:9 resolution based on width: {dynamicRes.X}x{dynamicRes.Y}");

            // 检查动态分辨率是否已存在，如果不存在则按高度排序插入
            int existingIndex = _availableResolutions.IndexOf(dynamicRes);
            string dynamicResName = $"{dynamicRes.X} x {dynamicRes.Y} (推荐)";

            if (existingIndex == -1) // 不存在，需要插入
            {
                int insertIndex = 0;
                // 找到第一个高度大于等于 dynamicRes 高度的位置
                while (insertIndex < _availableResolutions.Count && _availableResolutions[insertIndex].Y < dynamicRes.Y)
                {
                    insertIndex++;
                }
                _availableResolutions.Insert(insertIndex, dynamicRes);
                _availableResolutionNames.Insert(insertIndex, dynamicResName);
                Console.WriteLine($"[ResolutionManager] Added dynamic resolution at index {insertIndex}.");
            }
            else // 已存在，添加 "(推荐)" 后缀
            {
                _availableResolutionNames[existingIndex] = $"{_availableResolutions[existingIndex].X} x {_availableResolutions[existingIndex].Y} (推荐)";
                 Console.WriteLine("[ResolutionManager] Dynamic resolution already exists, marked as recommended.");
            }

            // 始终将计算出的动态分辨率设为默认窗口大小
            Point initialResolutionPoint = dynamicRes;
            Console.WriteLine($"[ResolutionManager] Setting default window size to dynamic resolution: {initialResolutionPoint.X}x{initialResolutionPoint.Y}");

            CurrentWindowSize = initialResolutionPoint;
            _lastWindowedSize = initialResolutionPoint; // 初始化上次窗口设置

            // 设置初始窗口分辨率和模式
            ApplyResolution(CurrentWindowSize, false); // 初始为窗口模式
        }

        /// <summary>
        /// 改变窗口分辨率
        /// </summary>
        public void ChangeResolution(Point newSize)
        {
            // 确保只在窗口模式下应用
            if (!_graphics.IsFullScreen)
            {
                 ApplyResolution(newSize, false);
            }
        }

        /// <summary>
        /// 设置为全屏模式
        /// </summary>
        public void SetFullscreen(int screenWidth, int screenHeight)
        {
            if (!_graphics.IsFullScreen)
            {
                _lastWindowedSize = CurrentWindowSize; // 保存当前窗口大小
            }
            _graphics.PreferredBackBufferWidth = screenWidth;
            _graphics.PreferredBackBufferHeight = screenHeight;
            _graphics.IsFullScreen = true;
            _graphics.HardwareModeSwitch = false;
            ApplyGraphicsSettings();
        }

        /// <summary>
        /// 设置为窗口模式
        /// </summary>
        public void SetWindowed()
        {
            if (_graphics.IsFullScreen)
            {
                // 恢复上次或当前大小 (注意: 确保 _lastWindowedSize 有值)
                var sizeToRestore = _lastWindowedSize ?? CurrentWindowSize;
                ApplyResolution(sizeToRestore, false);
            }
        }

        /// <summary>
        /// 应用窗口分辨率和全屏设置 (私有)
        /// </summary>
        private void ApplyResolution(Point windowSize, bool isFullscreen)
        {
            if (!isFullscreen)
            {
                CurrentWindowSize = windowSize;
                _lastWindowedSize = windowSize; // 记录窗口模式的大小
                _graphics.PreferredBackBufferWidth = windowSize.X;
                _graphics.PreferredBackBufferHeight = windowSize.Y;
            }
            // 全屏尺寸在 SetFullscreen 设置

            _graphics.IsFullScreen = isFullscreen;
            _graphics.HardwareModeSwitch = false;
            ApplyGraphicsSettings();
        }

        /// <summary>
        /// 应用图形设置的核心方法 (私有)
        /// </summary>
        private void ApplyGraphicsSettings()
        {
            _graphics.PreferMultiSampling = true;
            _graphics.GraphicsProfile = GraphicsProfile.HiDef;
            _graphics.SynchronizeWithVerticalRetrace = true;
            _graphics.ApplyChanges();
            // 可以在这里添加窗口居中逻辑，如果 MonoGame 默认不居中的话
        }

        /// <summary>
        /// 计算 Render Target 绘制到后台缓冲区时的目标矩形 (保持 16:9 居中)
        /// </summary>
        /// <returns>目标绘制矩形</returns>
        public Rectangle GetOutputDestinationRectangle()
        {
            var pp = _graphics.GraphicsDevice.PresentationParameters;
            int backBufferWidth = pp.BackBufferWidth;
            int backBufferHeight = pp.BackBufferHeight;

            float outputAspectRatio = (float)backBufferWidth / backBufferHeight;
            int outputWidth = backBufferWidth;
            int outputHeight = backBufferHeight;
            int outputX = 0;
            int outputY = 0;

            if (outputAspectRatio > TargetAspectRatio) // 输出比目标宽 (Pillarbox)
            {
                outputWidth = (int)(backBufferHeight * TargetAspectRatio);
                outputX = (backBufferWidth - outputWidth) / 2;
            }
            else if (outputAspectRatio < TargetAspectRatio) // 输出比目标窄 (Letterbox)
            {
                outputHeight = (int)(backBufferWidth / TargetAspectRatio);
                outputY = (backBufferHeight - outputHeight) / 2;
            }
            // 如果宽高比正好匹配，则 outputWidth/Height/X/Y 保持为 backBuffer 的值

            return new Rectangle(outputX, outputY, outputWidth, outputHeight);
        }
    }
}