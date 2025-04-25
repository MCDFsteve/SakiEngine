using Microsoft.Xna.Framework;
using Microsoft.Xna.Framework.Graphics;
using SkiaSharp;
using SkiaSharp.HarfBuzz;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq; // Needed for Directory.EnumerateFiles and FirstOrDefault
using System.Runtime.InteropServices;

namespace SakiEngine.Core.Text
{
    /// <summary>
    /// 使用 SkiaSharp 的字体管理器，支持矢量字体渲染
    /// </summary>
    public class SkiaFontManager : IDisposable
    {
        // 字体缓存
        private readonly Dictionary<string, Dictionary<float, SKTypeface>> _typefaceCache = new();
        private readonly Dictionary<(string, float), SKShaper> _shaperCache = new();
        
        // 已加载的字体对应的纹理，按需生成
        // private readonly Dictionary<string, Texture2D> _textureCache = new(); // 纹理现在在 SkiaTextRenderer 中缓存
        
        // 默认字体设置
        private const string PreferredDefaultFontName = "SourceHanSansCN-Medium"; // Preferred default
        private string _actualDefaultFontName = "default"; // Actual default to use, fallback to "default"
        public string DefaultFontName => _actualDefaultFontName; // Public accessor for the default font name
        
        private const float DefaultFontSize = 16f;
        
        // 渲染缩放因子，用于超采样抗锯齿
        // public static float RenderScaleFactor { get; set; } = 1.0f; // 移除
        
        // --- 新增：动态渲染质量设置 ---
        public static SKFilterQuality CurrentFilterQuality { get; set; } = SKFilterQuality.High;
        public static SKPaintHinting CurrentHintingLevel { get; set; } = SKPaintHinting.Full;
        public static bool UseAntialias { get; set; } = true;
        public static bool UseSubpixelText { get; set; } = true;
        public static bool UseLcdRenderText { get; set; } = true;
        public static bool UseAutohinted { get; set; } = true; // 添加 Autohinted 控制
        // -------------------------------
        
        // 备用字体
        private SKTypeface _fallbackTypeface;
        
        // 图形设备
        private readonly GraphicsDevice _graphicsDevice;
        
        // 字体文件的基础目录
        private readonly string _fontBasePath;
        
        /// <summary>
        /// 构造函数
        /// </summary>
        public SkiaFontManager(GraphicsDevice graphicsDevice, string fontBasePath)
        {
            _graphicsDevice = graphicsDevice;
            _fontBasePath = fontBasePath;
            _fallbackTypeface = SKTypeface.Default; // Keep system default as ultimate fallback

            // Determine the actual default font name to use
            if (TryLoadAndSetDefault(PreferredDefaultFontName))
            {
                Console.WriteLine($"[SkiaFontManager] Using preferred default font: {_actualDefaultFontName}");
            }
            else if (TryLoadFirstAvailableFont())
            {
                 Console.WriteLine($"[SkiaFontManager] Using first available font as default: {_actualDefaultFontName}");
            }
            else
            {
                Console.WriteLine($"[SkiaFontManager] Warning: Could not load preferred or any available font. Falling back to system default for font name \"default\".");
                _actualDefaultFontName = "default"; // Ensure it's set to internal fallback name
            }
        }
        
        /// <summary>
        /// Tries to load the specified font name and set it as the actual default.
        /// </summary>
        private bool TryLoadAndSetDefault(string fontName)
        {
            if (string.IsNullOrEmpty(fontName) || fontName == "default") return false;
            try
            {
                // Use GetTypefaceInternal logic without fallback to default name yet
                if (LoadTypefaceFromFile(fontName) != null)
                {
                    _actualDefaultFontName = fontName;
                    // Pre-cache it? GetTypeface will cache on first use anyway.
                    // GetTypeface(fontName, DefaultFontSize);
                    return true;
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[SkiaFontManager] Failed to load font '{fontName}' during default check: {ex.Message}");
            }
            return false;
        }

        /// <summary>
        /// Tries to load the first available TTF or OTF font from the base path.
        /// </summary>
        private bool TryLoadFirstAvailableFont()
        {
            if (!Directory.Exists(_fontBasePath)) return false;
            try
            {
                var firstFontFile = Directory.EnumerateFiles(_fontBasePath)
                                             .FirstOrDefault(f => f.EndsWith(".ttf", StringComparison.OrdinalIgnoreCase) ||
                                                                  f.EndsWith(".otf", StringComparison.OrdinalIgnoreCase));
                if (firstFontFile != null)
                {
                    string fontName = Path.GetFileNameWithoutExtension(firstFontFile);
                    return TryLoadAndSetDefault(fontName);
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[SkiaFontManager] Error finding first available font: {ex.Message}");
            }
            return false;
        }

        /// <summary>
        /// Internal logic to load a typeface directly from file path, returns null on failure.
        /// </summary>
        private SKTypeface? LoadTypefaceFromFile(string fontName)
        {
             // Check cache first (important!)
             // This simple check won't work as cache includes size. Need more complex cache check or just reload.
             // For simplicity, we might just try loading the file path directly here for the default check.

            string[] extensions = { ".ttf", ".otf", ".ttc" };
            foreach (var ext in extensions)
            {
                string fontPath = Path.Combine(_fontBasePath, $"{fontName}{ext}");
                if (File.Exists(fontPath))
                {
                    try { return SKTypeface.FromFile(fontPath); }
                    catch { /* Ignore load error for this extension */ }
                }
            }
            return null;
        }

        /// <summary>
        /// 获取指定名称和大小的字体 (Handles default name and fallback)
        /// </summary>
        public SKTypeface GetTypeface(string? fontName, float fontSize)
        {
            // 1. Resolve default font name if needed
            string resolvedFontName = (string.IsNullOrEmpty(fontName) || fontName == "default") ? _actualDefaultFontName : fontName;

            // If even the resolved default is "default", use system default
            if (resolvedFontName == "default")
            {
                 return _fallbackTypeface;
            }

            // 2. Check cache for the resolved name and size
            if (_typefaceCache.TryGetValue(resolvedFontName, out var sizeDict))
            {
                if (sizeDict.TryGetValue(fontSize, out var typeface))
                {
                    return typeface;
                }
            }
            else
            {
                _typefaceCache[resolvedFontName] = new Dictionary<float, SKTypeface>();
            }

            // 3. Try loading the resolved font name from file
            var loadedTypeface = LoadTypefaceFromFile(resolvedFontName);

            // 4. If loading fails, fall back to system default
            if (loadedTypeface == null)
            {
                Console.WriteLine($"[SkiaFontManager] Failed to load resolved font '{resolvedFontName}'. Using system default.");
                loadedTypeface = _fallbackTypeface;
                // Cache the fallback under the resolved name to avoid repeated load attempts
                _typefaceCache[resolvedFontName][fontSize] = loadedTypeface;
                return loadedTypeface;
            }

            // 5. Cache and return the successfully loaded typeface
            _typefaceCache[resolvedFontName][fontSize] = loadedTypeface;
            return loadedTypeface;
        }
        
        /// <summary>
        /// 获取字体整形器
        /// </summary>
        public SKShaper GetShaper(string fontName, float fontSize)
        {
            var key = (fontName, fontSize);
            
            if (_shaperCache.TryGetValue(key, out var shaper))
            {
                return shaper;
            }
            
            var typeface = GetTypeface(fontName, fontSize);
            shaper = new SKShaper(typeface);
            _shaperCache[key] = shaper;
            
            return shaper;
        }
        
        /// <summary>
        /// 渲染文本到纹理
        /// </summary>
        public Texture2D RenderText(string text, string fontName, float fontSize, Color color)
        {
            if (string.IsNullOrEmpty(text))
            {
                return new Texture2D(_graphicsDevice, 1, 1);
            }
            
            // 获取字体
            var typeface = GetTypeface(fontName, fontSize);
            var shaper = GetShaper(fontName, fontSize);
            
            // 创建画笔
            using var paint = new SKPaint
            {
                Typeface = typeface,
                TextSize = fontSize,
                // --- 使用静态质量设置 ---
                IsAntialias = UseAntialias,
                Color = new SKColor(color.R, color.G, color.B, color.A),
                SubpixelText = UseSubpixelText,
                FilterQuality = CurrentFilterQuality,
                HintingLevel = CurrentHintingLevel,
                IsAutohinted = UseAutohinted, 
                LcdRenderText = UseLcdRenderText,
                 // -----------------------
                
                // 调整描边设置，获得更平滑的边缘
                StrokeWidth = 0,
                Style = SKPaintStyle.Fill
            };
            
            // 测量文本尺寸
            var textWidth = 0f;
            var textHeight = 0f;
            
            // 使用 SKRect 但不在 using 语句中
            var textBounds = new SKRect();
            paint.MeasureText(text, ref textBounds);
            textWidth = textBounds.Width;
            textHeight = textBounds.Height;
            
            // 获取字体度量信息以更准确地计算高度
            var fontMetrics = paint.FontMetrics;
            var fullHeight = fontMetrics.Descent - fontMetrics.Ascent;
            
            // 确保尺寸至少为1x1，并添加额外的高度空间来避免裁切
            int width = Math.Max(1, (int)Math.Ceiling(textWidth));
            int height = Math.Max(1, (int)Math.Ceiling(fullHeight * 1.2f)); // 增加20%的高度作为安全边距
            
            Texture2D texture;

            // 创建Skia位图，使用8888配置获得最佳质量 (直接使用 width, height)
            using (var bitmap = new SKBitmap(
                width, // 直接使用计算出的宽度
                height, // 直接使用计算出的高度
                SKColorType.Rgba8888,
                SKAlphaType.Premul
            ))
            {
                using (var canvas = new SKCanvas(bitmap))
                {
                    // 清空画布
                    canvas.Clear(SKColors.Transparent);

                    // 绘制文本，并调整基线位置以确保正确显示
                    float baselinePosition = -fontMetrics.Ascent; // 基线位置从顶部计算

                    // 检查 shaper 是否可用
                    if (shaper != null)
                    {
                        canvas.DrawShapedText(shaper, text, 0, baselinePosition, paint);
                    }
                    else
                    {
                        // 如果 shaper 不可用（例如旧版 SkiaSharp 或特定情况），回退到 DrawText
                        // 注意：DrawText 可能不支持复杂的文字布局，但作为备用方案
                        canvas.DrawText(text, 0, baselinePosition, paint);
                    }
                } // canvas dispose

                texture = new Texture2D(_graphicsDevice, width, height);

                // 直接使用 bitmap
                SKBitmap finalBitmap = bitmap; // 直接引用

                // 复制像素数据
                byte[] pixelData = new byte[width * height * 4];
                using (var pixmap = finalBitmap.PeekPixels()) // 使用 using 确保释放 Pixmap
                {
                    if (pixmap != null && pixmap.GetPixels() != IntPtr.Zero)
                    {
                        try
                        {
                            Marshal.Copy(
                                pixmap.GetPixels(),
                                pixelData,
                                0,
                                pixelData.Length
                            );
                             texture.SetData(pixelData);
                        }
                        catch (Exception ex)
                        {
                            Console.WriteLine($"复制像素数据时出错: {ex.Message}");
                            texture.Dispose();
                            texture = new Texture2D(_graphicsDevice, 1, 1);
                        }
                    }
                    else
                    {
                         Console.WriteLine("无法访问最终位图的像素数据。");
                         texture.Dispose();
                         texture = new Texture2D(_graphicsDevice, 1, 1);
                    }
                }
            } // bitmap dispose

            return texture;
        }
        
        /// <summary>
        /// 获取文本尺寸
        /// </summary>
        public Vector2 MeasureText(string text, string fontName, float fontSize)
        {
            if (string.IsNullOrEmpty(text))
            {
                return Vector2.Zero;
            }
            
            // 获取字体
            var typeface = GetTypeface(fontName, fontSize);
            var shaper = GetShaper(fontName, fontSize);
            
            // 创建画笔
            using var paint = new SKPaint
            {
                Typeface = typeface,
                TextSize = fontSize,
                // --- 同样使用影响测量的静态质量设置 ---
                IsAntialias = UseAntialias, 
                HintingLevel = CurrentHintingLevel, // Hinting 可能影响宽度
                IsAutohinted = UseAutohinted
                // FilterQuality, SubpixelText, LcdRenderText 对测量影响不大，可以省略
                // -------------------------------------
            };
            
            // 使用HarfBuzz整形获取更准确的宽度
            float textWidth;
            try 
            {
                // 使用整形器获取更准确的宽度，但不使用using语句
                var shapedText = shaper.Shape(text, paint);
                textWidth = shapedText.Width;
            }
            catch
            {
                // 如果整形失败，使用传统方法
                var textBounds = new SKRect();
                paint.MeasureText(text, ref textBounds);
                textWidth = textBounds.Width;
            }
            
            // 获取字体度量信息以更准确地计算高度
            var fontMetrics = paint.FontMetrics;
            var fullHeight = fontMetrics.Descent - fontMetrics.Ascent;
            
            // 增加20%的高度作为安全边距，与RenderText方法保持一致
            return new Vector2(textWidth, fullHeight * 1.2f);
        }
        
        /// <summary>
        /// 释放资源
        /// </summary>
        public void Dispose()
        {
            // 释放所有缓存的纹理
            // foreach (var texture in _textureCache.Values)
            // {
            //    texture.Dispose();
            // }
            // _textureCache.Clear();
            
            // 释放所有缓存的整形器
            foreach (var shaper in _shaperCache.Values)
            {
                shaper.Dispose();
            }
            _shaperCache.Clear();
            
            // 释放所有缓存的字体
            foreach (var sizeDict in _typefaceCache.Values)
            {
                foreach (var typeface in sizeDict.Values)
                {
                    typeface.Dispose();
                }
            }
            _typefaceCache.Clear();
            
            // 释放备用字体
            _fallbackTypeface?.Dispose();
        }
    }
} 