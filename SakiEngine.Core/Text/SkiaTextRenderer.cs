using Microsoft.Xna.Framework;
using Microsoft.Xna.Framework.Graphics;
using System;
using System.Collections.Generic;

namespace SakiEngine.Core.Text
{
    /// <summary>
    /// 使用 Skia 的文本渲染器
    /// </summary>
    public class SkiaTextRenderer
    {
        private readonly GraphicsDevice _graphicsDevice;
        private readonly SkiaFontManager _fontManager;
        
        // 文本块缓存，避免重复渲染相同的文本
        private readonly Dictionary<string, TextBlockInfo> _textBlockCache = new();
        
        // 默认设置
        private string _defaultFontName = "SourceHanSansCN-Medium";
        private float _defaultFontSize = 16f;
        private Color _defaultColor = Color.White;
        
        /// <summary>
        /// 构造函数
        /// </summary>
        public SkiaTextRenderer(GraphicsDevice graphicsDevice, SkiaFontManager fontManager)
        {
            _graphicsDevice = graphicsDevice;
            _fontManager = fontManager;
        }
        
        /// <summary>
        /// 设置默认字体
        /// </summary>
        public void SetDefaultFont(string fontName, float fontSize)
        {
            _defaultFontName = fontName;
            _defaultFontSize = fontSize;
        }
        
        /// <summary>
        /// 设置默认颜色
        /// </summary>
        public void SetDefaultColor(Color color)
        {
            _defaultColor = color;
        }
        
        /// <summary>
        /// 渲染文本
        /// </summary>
        public void DrawText(SpriteBatch spriteBatch, string text, Vector2 position)
        {
            DrawText(spriteBatch, text, position, _defaultFontName, _defaultFontSize, _defaultColor);
        }
        
        /// <summary>
        /// 渲染文本（指定字体和颜色）
        /// </summary>
        public void DrawText(SpriteBatch spriteBatch, string text, Vector2 position, string fontName, float fontSize, Color color)
        {
            if (string.IsNullOrEmpty(text))
            {
                return;
            }
            
            try
            {
                // 生成缓存键
                string cacheKey = $"{text}|{fontName}|{fontSize}|{color.PackedValue}";
                
                // 检查缓存
                if (!_textBlockCache.TryGetValue(cacheKey, out var textBlock))
                {
                    // 渲染文本到纹理
                    var texture = _fontManager.RenderText(text, fontName, fontSize, color);
                    
                    // 创建并缓存文本块
                    textBlock = new TextBlockInfo
                    {
                        Texture = texture,
                        Size = new Vector2(texture.Width, texture.Height)
                    };
                    
                    _textBlockCache[cacheKey] = textBlock;
                }
                
                // 绘制文本纹理
                spriteBatch.Draw(
                    textBlock.Texture,
                    position,
                    null,
                    Color.White,
                    0f,
                    Vector2.Zero,
                    1f,
                    SpriteEffects.None,
                    0f
                );
            }
            catch (Exception ex)
            {
                Console.WriteLine($"绘制文本失败: {ex.Message}");
                // 忽略绘制错误，继续游戏
            }
        }
        
        /// <summary>
        /// 测量文本尺寸
        /// </summary>
        public Vector2 MeasureText(string text)
        {
            return _fontManager.MeasureText(text, _defaultFontName, _defaultFontSize);
        }
        
        /// <summary>
        /// 测量文本尺寸（指定字体）
        /// </summary>
        public Vector2 MeasureText(string text, string fontName, float fontSize)
        {
            if (string.IsNullOrEmpty(text))
            {
                return Vector2.Zero;
            }
            
            try
            {
                return _fontManager.MeasureText(text, fontName, fontSize);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"测量文本失败: {ex.Message}");
                // 返回零大小而不是抛出异常
                return new Vector2(10f * text.Length, fontSize); // 简单估计
            }
        }
        
        /// <summary>
        /// 清除文本块缓存
        /// </summary>
        public void ClearCache()
        {
            foreach (var textBlock in _textBlockCache.Values)
            {
                textBlock.Texture.Dispose();
            }
            
            _textBlockCache.Clear();
        }
        
        /// <summary>
        /// 获取或渲染文本块信息 (供 SkiaTextElement 使用)
        /// </summary>
        public TextBlockInfo GetOrRenderTextBlock(string text, string fontName, float fontSize, Color color)
        {
             if (string.IsNullOrEmpty(text))
            {
                // 返回一个包含空纹理和零尺寸的 TextBlockInfo
                return new TextBlockInfo { Texture = new Texture2D(_graphicsDevice, 1, 1), Size = Vector2.Zero };
            }
            
             try
            {
                // 生成缓存键 (包含颜色，因为颜色影响渲染结果)
                string cacheKey = $"{text}|{fontName}|{fontSize}|{color.PackedValue}";
                
                // 检查缓存
                if (!_textBlockCache.TryGetValue(cacheKey, out var textBlock))
                {
                    // 渲染文本到纹理 (现在会根据 fontSize 生成可能很大的纹理)
                    var texture = _fontManager.RenderText(text, fontName, fontSize, color);
                    
                    // 创建并缓存文本块
                    textBlock = new TextBlockInfo
                    {
                        Texture = texture,
                        Size = new Vector2(texture.Width, texture.Height)
                    };
                    
                    _textBlockCache[cacheKey] = textBlock;
                }
                
                return textBlock;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"获取或渲染文本块失败: {ex.Message}");
                // 返回空或默认值，避免崩溃
                return new TextBlockInfo { Texture = new Texture2D(_graphicsDevice, 1, 1), Size = Vector2.Zero };
            }
        }
        
        /// <summary>
        /// 文本块信息
        /// </summary>
        public class TextBlockInfo
        {
            public required Texture2D Texture { get; set; }
            public required Vector2 Size { get; set; }
        }
    }
} 