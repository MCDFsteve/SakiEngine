using Microsoft.Xna.Framework;
using Microsoft.Xna.Framework.Graphics;
using Microsoft.Xna.Framework.Input;
using SakiEngine.Core.GameCore;
using SakiEngine.Core.SceneGraph;
using SakiEngine.Core.Utils;
using System.Collections.Generic;
using System;

namespace SakiEngine.Core.UI
{
    /// <summary>
    /// 按钮状态
    /// </summary>
    public enum ButtonUIState
    {
        Normal,
        Hover,
        Pressed
    }
    
    /// <summary>
    /// 按钮控件 (适配 Render Target 缩放)
    /// </summary>
    public class Button : UIElement
    {
        /// <summary>
        /// 鼠标悬停颜色
        /// </summary>
        public Color HoverColor { get; set; } = new Color(100, 100, 100, 200);
        
        /// <summary>
        /// 鼠标按下颜色
        /// </summary>
        public Color PressedColor { get; set; } = new Color(80, 80, 80, 200);
        
        /// <summary>
        /// 按钮是否启用
        /// </summary>
        public bool IsEnabled { get; set; } = true;
        
        /// <summary>
        /// 当前状态
        /// </summary>
        public ButtonUIState State { get; private set; } = ButtonUIState.Normal;
        
        /// <summary>
        /// 构造函数
        /// </summary>
        public Button(string id, int layerId, UIRectN rect)
            : base(id, layerId, rect)
        {
            BackgroundColor = new Color(50, 50, 50, 200);
        }
        
        /// <summary>
        /// 检查鼠标状态 (重构以适应 Render Target 缩放)
        /// </summary>
        protected override void CheckMouseState()
        {
            bool wasHovered = IsHovered; 
            IsHovered = false; // Reset hover state at the beginning
            
            if (!IsEnabled)
            {
                State = ButtonUIState.Normal;
                IsPressed = false;
                if (wasHovered) 
                {
                    Mouse.SetCursor(MouseCursor.Arrow);
                }
                return;
            }

            var mouseState = Mouse.GetState();
            var rawMousePos = mouseState.Position; // Use Position for Point

            // --- 添加：macOS 全屏鼠标 Y 坐标修正 (使用刘海屏检测) ---
            if (DisplayUtils.IsLikelyNotchedDisplay() &&
                GameInstance.Instance.GraphicsDeviceManager.IsFullScreen)
            {
                // 创建一个新的 Point 应用修正，因为 Point 是值类型
                rawMousePos = new Point(rawMousePos.X, rawMousePos.Y - 36);
            }
            // -------------------------------------

            // 1. 获取最终渲染的目标矩形 (在屏幕上的位置和大小)
            var destRect = GameInstance.Instance.ResolutionManager.GetOutputDestinationRectangle();
            
            // 2. 计算按钮在内部渲染空间 (1920x1080) 的边界
            Rectangle internalBounds;
            if (Parent != null)
            {
                // IMPORTANT: Pass internal resolution to parent calculation
                internalBounds = GetScreenRectFromParent(
                    GameInstance.InternalWidth,
                    GameInstance.InternalHeight
                );
            }
            else
            {
                // IMPORTANT: Pass internal resolution for root elements
                internalBounds = GetScreenRect(
                    GameInstance.InternalWidth,
                    GameInstance.InternalHeight
                );
            }
            
            // 3. 检查鼠标是否在渲染目标区域内
            if (destRect.Contains(rawMousePos))
            {
                // 4. 将屏幕鼠标坐标映射回内部渲染空间 (1920x1080)
                float mouseInDestX = rawMousePos.X - destRect.X;
                float mouseInDestY = rawMousePos.Y - destRect.Y;

                // Avoid division by zero if destRect has zero width/height
                float scaleX = (destRect.Width > 0) ? GameInstance.InternalWidth / (float)destRect.Width : 0f;
                float scaleY = (destRect.Height > 0) ? GameInstance.InternalHeight / (float)destRect.Height : 0f;

                var internalMousePos = new Point(
                    (int)(mouseInDestX * scaleX),
                    (int)(mouseInDestY * scaleY)
            );

                // 5. 使用内部坐标进行悬停检查
                IsHovered = internalBounds.Contains(internalMousePos);
            }
            // else: Mouse is outside the destination rectangle, IsHovered remains false
            
            // --- 光标更改逻辑 (基于 IsHovered) ---
            if (IsHovered && !wasHovered) 
            {
                 Mouse.SetCursor(MouseCursor.Hand);
            }
            else if (!IsHovered && wasHovered) 
            {
                 Mouse.SetCursor(MouseCursor.Arrow);
            }
            
            // --- 状态更新逻辑 (基于 IsHovered 和 mouseState) ---
            if (IsHovered)
            {
                if (mouseState.LeftButton == Microsoft.Xna.Framework.Input.ButtonState.Pressed)
                {
                    State = ButtonUIState.Pressed;
                    IsPressed = true;
                }
                else
                {
                    // Check if the button was pressed on this element and now released
                    if (IsPressed && mouseState.LeftButton == Microsoft.Xna.Framework.Input.ButtonState.Released)
                    {
                        TriggerClick(); 
                    }
                    State = ButtonUIState.Hover;
                    IsPressed = false; // Reset pressed state if mouse button is up
                }
            }
            else
            {
                State = ButtonUIState.Normal;
                // If mouse moved away while pressed, reset pressed state
                IsPressed = false;
            }
        }
        
        /// <summary>
        /// 绘制按钮 (现在基于内部 1920x1080 坐标绘制)
        /// </summary>
        public override void Draw(SpriteBatch spriteBatch, int screenWidth, int screenHeight)
        {
            // IMPORTANT: screenWidth and screenHeight should always be InternalWidth/Height here
            // because drawing happens onto the internal render target.
            if (screenWidth != GameInstance.InternalWidth || screenHeight != GameInstance.InternalHeight)
            {
                // Log a warning or throw an error if called with incorrect dimensions
                Console.WriteLine($"Warning: Button.Draw called with unexpected screen dimensions ({screenWidth}x{screenHeight}). Expected internal resolution.");
                // Optionally, you might want to return or adapt, but ideally the caller (MenuManager/SceneGraph) should be fixed.
            }

            if (!Visible)
                return;
                
            // Get bounds based on the internal resolution
            var bounds = GetScreenRect(GameInstance.InternalWidth, GameInstance.InternalHeight);
            
            // 根据状态选择颜色
            Color drawColor;
            if (!IsEnabled) // 如果未启用，使用背景色并降低透明度或使用特定禁用色
            {
                drawColor = BackgroundColor * 0.5f; // 示例：半透明
            }
            else
            {
                switch (State)
                {
                    case ButtonUIState.Hover:
                        drawColor = HoverColor;
                        break;
                    case ButtonUIState.Pressed:
                        drawColor = PressedColor;
                        break;
                    default:
                        drawColor = BackgroundColor;
                        break;
                }
            }
            
            // 绘制背景
            spriteBatch.Draw(
                GameInstance.Instance.WhitePixelTexture,
                bounds,
                drawColor * Alpha // 保持 Alpha 混合
            );
            
            // 绘制子对象 (传递内部宽高)
            base.Draw(spriteBatch, GameInstance.InternalWidth, GameInstance.InternalHeight);
        }

        /// <summary>
        /// 触发点击事件
        /// </summary>
        protected override void TriggerClick()
        {
            // 只有在按钮启用时才触发实际的点击事件
            if (IsEnabled)
            {
                try
                {
                    base.TriggerClick();
                }
                catch (Exception ex)
                {
                    Console.WriteLine($">>> [{Id}] EXCEPTION during base.TriggerClick(): {ex.Message}");
                }
            }
        }
    }
} 