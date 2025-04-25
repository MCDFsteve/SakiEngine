using Microsoft.Xna.Framework;
using Microsoft.Xna.Framework.Graphics;
using SakiEngine.Core.GameCore;
using SakiEngine.Core.SceneGraph;
using SakiEngine.Core.Utils;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;

namespace SakiEngine.Core.UI
{
    /// <summary>
    /// UI元素基类，所有UI控件的基础
    /// </summary>
    public class UIElement : SceneObject
    {
        private readonly List<SceneObject> _children = new();
        
        /// <summary>
        /// Gets a read-only collection of the child elements.
        /// </summary>
        public ReadOnlyCollection<SceneObject> Children => _children.AsReadOnly();
        
        /// <summary>
        /// 是否启用（可接收输入）
        /// </summary>
        public bool Enabled { get; set; } = true;
        
        /// <summary>
        /// 背景颜色
        /// </summary>
        public Color BackgroundColor { get; set; } = Color.Transparent;
        
        /// <summary>
        /// 前景颜色（文本/边框）
        /// </summary>
        public Color ForegroundColor { get; set; } = Color.White;
        
        /// <summary>
        /// 鼠标悬停状态
        /// </summary>
        public bool IsHovered { get; protected set; }
        
        /// <summary>
        /// 鼠标按下状态
        /// </summary>
        public bool IsPressed { get; protected set; }
        
        /// <summary>
        /// 点击事件委托
        /// </summary>
        public event Action<UIElement>? OnClick;
        
        /// <summary>
        /// 父控件
        /// </summary>
        public SceneObject? Parent { get; private set; }
        
        /// <summary>
        /// 构造函数
        /// </summary>
        public UIElement(string id, int layerId, UIRectN rect) 
            : base(id, layerId, rect)
        {
        }
        
        /// <summary>
        /// 添加子对象
        /// </summary>
        public virtual void AddChild(SceneObject child)
        {
            if (child is UIElement uiElement)
            {
                uiElement.Parent = this;
            }
            _children.Add(child);
        }
        
        /// <summary>
        /// 移除子对象
        /// </summary>
        public virtual bool RemoveChild(SceneObject child)
        {
            bool removed = _children.Remove(child);
            if (removed && child is UIElement uiElement)
            {
                uiElement.Parent = null;
            }
            return removed;
        }
        
        /// <summary>
        /// 获取本地矩形（相对于父容器）
        /// </summary>
        public Rectangle GetLocalRect(int parentWidth, int parentHeight)
        {
            return Rect.ToRectangle(parentWidth, parentHeight);
        }
        
        /// <summary>
        /// 根据父控件获取屏幕坐标
        /// </summary>
        public Rectangle GetScreenRectFromParent(int screenWidth, int screenHeight)
        {
            if (Parent == null)
            {
                return GetScreenRect(screenWidth, screenHeight);
            }
            
            var parentRect = Parent.GetScreenRect(screenWidth, screenHeight);
            var localRect = GetLocalRect(parentRect.Width, parentRect.Height);
            
            return new Rectangle(
                parentRect.X + localRect.X,
                parentRect.Y + localRect.Y,
                localRect.Width,
                localRect.Height
            );
        }
        
        /// <summary>
        /// 更新控件状态
        /// </summary>
        public override void Update(GameTime gameTime)
        {
            if (!Visible || !Enabled)
                return;
                
            // Update self first (CheckMouseState)
            CheckMouseState();
            
            // Update children (make a copy in case collection is modified during update)
            foreach (var child in _children.ToList()) // Use ToList() for safe iteration
            {
                child.Update(gameTime);
            }
        }
        
        /// <summary>
        /// 检查鼠标状态
        /// </summary>
        protected virtual void CheckMouseState()
        {
            // 子类负责实现鼠标检测
        }
        
        /// <summary>
        /// 触发点击事件
        /// </summary>
        protected virtual void TriggerClick()
        {
            OnClick?.Invoke(this);
        }
        
        /// <summary>
        /// 绘制元素
        /// </summary>
        public override void Draw(SpriteBatch spriteBatch, int screenWidth, int screenHeight)
        {
            if (!Visible)
                return;
            
            Rectangle bounds;
            
            // Draw self background first
            if (Parent != null)
            {
                bounds = GetScreenRectFromParent(screenWidth, screenHeight);
            }
            else
            {
                bounds = GetScreenRect(screenWidth, screenHeight);
            }
            
            if (BackgroundColor.A > 0)
            {
                spriteBatch.Draw(
                    GameInstance.Instance.WhitePixelTexture,
                    bounds,
                    BackgroundColor * Alpha
                );
            }
            
            // Draw children (ensure they draw within parent bounds potentially?)
            // Sorting by LayerId might be important here if not done in AddChild
            foreach (var child in _children) // Draw in added order, or sort first
            {
                child.Draw(spriteBatch, screenWidth, screenHeight);
            }
        }
    }
} 