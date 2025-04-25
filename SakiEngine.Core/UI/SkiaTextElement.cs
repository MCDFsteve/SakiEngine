using Microsoft.Xna.Framework;
using Microsoft.Xna.Framework.Graphics;
using SakiEngine.Core.GameCore;
using SakiEngine.Core.SceneGraph;
using SakiEngine.Core.Utils;
using System;

namespace SakiEngine.Core.UI
{
    /// <summary>
    /// 文本对齐方式
    /// </summary>
    public enum TextAlignment
    {
        Left,
        Center,
        Right
    }
    
    /// <summary>
    /// 使用 SkiaSharp 渲染的文本元素 (适配字体大小缩放)
    /// </summary>
    public class SkiaTextElement : UIElement
    {
        private string _text;
        private string _fontName = "default"; // Initialize with internal default
        private float _semanticFontSize = 16f; // 存储语义字体大小 (相对于 ReferenceHeight)
        private Color _textColor = Color.White;
        private TextAlignment _alignment = TextAlignment.Left;
        private bool _needsRedraw = true;
        private Texture2D? _cachedTexture;
        private Vector2 _cachedSize = Vector2.Zero;
        
        // 新增：静态缩放因子，影响所有文本渲染
        public static float TextRenderScale { get; set; } = 1.0f; // 默认为 1x
        
        // 新增：计算实际渲染像素大小
        private float RenderFontSize => _semanticFontSize * (GameInstance.InternalHeight / GameInstance.ReferenceHeight);
        
        /// <summary>
        /// 文本内容
        /// </summary>
        public string Text
        {
            get => _text;
            set
            {
                if (_text != value)
                {
                    _text = value;
                    InvalidateRender();
                    InvalidateLayout(); // Text change can affect layout
                }
            }
        }
        
        /// <summary>
        /// 字体名称 (Uses default from FontManager if set to null/empty)
        /// </summary>
        public string FontName
        {
            get => _fontName;
            set
            {
                string newName = (!string.IsNullOrEmpty(value)) ? value : (GameInstance.Instance?.FontManager?.DefaultFontName ?? "default");
                if (_fontName != newName)
                {
                    _fontName = newName;
                    InvalidateRender(); // Font name change requires redraw
                    InvalidateLayout(); // Font change affects layout
                }
            }
        }
        
        /// <summary>
        /// 字体大小
        /// </summary>
        public float FontSize
        {
            get => _semanticFontSize;
            set
            {
                if (_semanticFontSize != value)
                {
                    _semanticFontSize = value;
                    InvalidateLayout();
                }
            }
        }
        
        /// <summary>
        /// 文本颜色
        /// </summary>
        public Color TextColor
        {
            get => _textColor;
            set
            {
                if (_textColor != value)
                {
                    _textColor = value;
                    InvalidateRender();
                }
            }
        }
        
        /// <summary>
        /// 文本对齐方式
        /// </summary>
        public TextAlignment Alignment
        {
            get => _alignment;
            set
            {
                if (_alignment != value)
                {
                    _alignment = value;
                    // Alignment change might affect visual appearance but not necessarily layout bounds
                    // InvalidateRender(); // Only invalidate render if alignment affects texture generation (it doesn't here)
                }
            }
        }
        
        /// <summary>
        /// 构造函数 (Uses default font if none specified implicitly)
        /// </summary>
        public SkiaTextElement(string id, int layerId, UIRectN rect, string initialText)
            : base(id, layerId, rect)
        {
            _text = initialText;
            // Set font using the property setter, which handles defaulting
            FontName = GameInstance.Instance?.FontManager?.DefaultFontName ?? "default"; // Explicitly set default initially
            FontSize = 16f; // Keep default size
        }
        
        /// <summary>
        /// 设置字体和语义大小 (Uses default font name if null/empty)
        /// </summary>
        public void SetFont(string? fontName, float semanticFontSize)
        {
            bool changed = false;
            // Use property setter logic for font name defaulting
            string resolvedFontName = (!string.IsNullOrEmpty(fontName)) ? fontName : (GameInstance.Instance?.FontManager?.DefaultFontName ?? "default");
            if (_fontName != resolvedFontName)
            {
                _fontName = resolvedFontName;
                changed = true;
            }
            if (Math.Abs(_semanticFontSize - semanticFontSize) > 0.01f)
            {
                _semanticFontSize = semanticFontSize;
                changed = true;
            }

            if (changed)
            {
                InvalidateRender();
                InvalidateLayout(); // Font change affects layout
            }
        }
        
        /// <summary>
        /// 使缓存的纹理无效，需要重新渲染
        /// </summary>
        private void InvalidateRender()
        {
            _needsRedraw = true;
        }
        
        /// <summary>
        /// 测量文本尺寸 (使用渲染字体大小)
        /// </summary>
        public Vector2 MeasureText(string text)
        {
            if (string.IsNullOrEmpty(_text))
            {
                return Vector2.Zero;
            }

            try
            {
                // 确保 TextRenderScale 有效 (这个 Scale 是额外的调试/测试用缩放)
                float scale = Math.Max(1.0f, TextRenderScale);

                // 获取基于语义大小计算出的渲染像素大小
                float baseRenderFontSize = RenderFontSize;

                // 应用额外的 TextRenderScale
                float finalRenderFontSize = baseRenderFontSize * scale;

                // 使用最终渲染像素大小测量
                Vector2 renderSize = GameInstance.Instance.TextRenderer.MeasureText(_text, _fontName, finalRenderFontSize);

                // 返回用于布局的尺寸 (需要将 TextRenderScale 效果抵消掉)
                return renderSize / scale;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"SkiaTextElement 测量文本失败: {ex.Message}");
                // 返回一个基于语义大小的估计值
                return new Vector2(10f * _text.Length, _semanticFontSize * 1.2f); // Use semantic size for fallback estimate
            }
        }
        
        /// <summary>
        /// 使布局无效，需要重新计算
        /// </summary>
        protected void InvalidateLayout()
        {
            // TODO: Implement layout recalculation if needed
            // For now, measuring is done on demand.
        }
        
        /// <summary>
        /// 绘制文本元素
        /// </summary>
        public override void Draw(SpriteBatch spriteBatch, int screenWidth, int screenHeight)
        {
            // screenWidth/Height are expected to be InternalWidth/Height
            if (!Visible || string.IsNullOrEmpty(_text))
                return;

            // 渲染或获取缓存纹理
            RenderAndCacheIfNeeded();

            if (_cachedTexture == null || _cachedTexture.IsDisposed || _cachedSize == Vector2.Zero)
            {
                return; // Cannot draw if texture is invalid
            }

            // 获取屏幕矩形 (基于 MeasureText 返回的布局尺寸)
            Rectangle bounds = GetElementScreenBounds(screenWidth, screenHeight);

            // 绘制背景 (如果需要)
            if (BackgroundColor.A > 0)
            {
                spriteBatch.Draw(
                    GameInstance.Instance.WhitePixelTexture,
                    bounds,
                    BackgroundColor * Alpha
                );
            }

            // 计算绘制位置 (基于布局尺寸 bounds)
            // _cachedSize 是渲染纹理的实际像素尺寸 (基于 RenderFontSize * TextRenderScale)
            // 我们需要计算出期望的布局尺寸 (基于 MeasureText)
            Vector2 expectedLayoutSize = MeasureText(_text); // This already accounts for TextRenderScale
            Vector2 position = bounds.Location.ToVector2();

            // 根据对齐方式调整位置
            switch (_alignment)
            {
                case TextAlignment.Center:
                    position.X += (bounds.Width - expectedLayoutSize.X) / 2f;
                    position.Y += (bounds.Height - expectedLayoutSize.Y) / 2f;
                    break;
                case TextAlignment.Right:
                    position.X += bounds.Width - expectedLayoutSize.X;
                    break;
                // Left alignment is default (position.X)
            }
            
            // 计算最终绘制的缩放因子 (抵消 TextRenderScale)
            float drawScale = (TextRenderScale > 0) ? 1.0f / TextRenderScale : 1.0f;

            // 绘制缓存的纹理，应用 drawScale
            spriteBatch.Draw(
                _cachedTexture,
                position,
                null, // sourceRectangle (draw entire texture)
                Color.White * Alpha, // Apply element alpha
                Rotation, // Apply element rotation
                Vector2.Zero, // Origin
                drawScale, // Apply scaling to counteract TextRenderScale used for rendering
                SpriteEffects.None,
                0f
            );
        }
        
        /// <summary>
        /// 渲染文本到缓存纹理 (如果需要)
        /// </summary>
        private void RenderAndCacheIfNeeded()
        {
            if (_needsRedraw || _cachedTexture == null || _cachedTexture.IsDisposed)
            {
                if (string.IsNullOrEmpty(_text))
                {
                    _cachedTexture?.Dispose();
                    _cachedTexture = new Texture2D(GameInstance.Instance.GraphicsDevice, 1, 1); // Minimal texture
                    _cachedSize = Vector2.One;
                    _needsRedraw = false;
                    return;
                }

                try
                {
                    // 确保 TextRenderScale 有效
                    float scale = Math.Max(1.0f, TextRenderScale);
                    // 获取渲染像素大小
                    float renderFontSize = RenderFontSize * scale;
                    // 获取最终颜色 (考虑 Alpha, 但纹理应以完全不透明的方式渲染白色，然后在 Draw 中应用 Alpha)
                    // Color finalColor = _textColor; // Render with full color for caching
                    Color finalColor = Color.White; // Render white text to texture, apply color tint and alpha during Draw

                    // 从渲染器获取对应 renderFontSize 的（可能很大的）纹理块信息
                    var textBlock = GameInstance.Instance.TextRenderer.GetOrRenderTextBlock(_text, _fontName, renderFontSize, finalColor);

                    _cachedTexture?.Dispose(); // Dispose previous texture

                    if (textBlock != null && textBlock.Texture != null && !textBlock.Texture.IsDisposed)
                    {
                        _cachedTexture = textBlock.Texture;
                        _cachedSize = textBlock.Size;
                    }
                    else
                    {
                        //Console.WriteLine($"SkiaTextElement 未能获取有效纹理: {_text}");
                        _cachedTexture = new Texture2D(GameInstance.Instance.GraphicsDevice, 1, 1);
                        _cachedSize = Vector2.One;
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"SkiaTextElement 渲染文本到缓存失败: {ex.Message}");
                    _cachedTexture?.Dispose();
                    _cachedTexture = new Texture2D(GameInstance.Instance.GraphicsDevice, 1, 1);
                    _cachedSize = Vector2.One;
                }
                _needsRedraw = false;
            }
        }
        
        /// <summary>
        /// 获取元素在屏幕上的实际边界 (基于 MeasureText)
        /// </summary>
        private Rectangle GetElementScreenBounds(int screenWidth, int screenHeight)
        {
             // This should use the internal resolution (screenWidth/Height)
             if (Parent != null)
            {
                return GetScreenRectFromParent(screenWidth, screenHeight);
            }
            else
            {
                return GetScreenRect(screenWidth, screenHeight);
            }
        }
    }
} 