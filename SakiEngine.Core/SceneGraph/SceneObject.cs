using Microsoft.Xna.Framework;
using Microsoft.Xna.Framework.Graphics;
using SakiEngine.Core.Utils;

namespace SakiEngine.Core.SceneGraph
{
    /// <summary>
    /// 场景对象基类，场景中所有可渲染对象的基础
    /// </summary>
    public abstract class SceneObject
    {
        /// <summary>
        /// 对象ID，用于查找和引用
        /// </summary>
        public string Id { get; set; }
        
        /// <summary>
        /// 渲染层ID
        /// </summary>
        public int LayerId { get; set; }
        
        /// <summary>
        /// 对象的归一化位置和大小
        /// </summary>
        public UIRectN Rect { get; set; }
        
        /// <summary>
        /// 是否可见
        /// </summary>
        public bool Visible { get; set; } = true;
        
        /// <summary>
        /// 透明度 (0.0-1.0)
        /// </summary>
        public float Alpha { get; set; } = 1.0f;
        
        /// <summary>
        /// 模糊半径 (0表示无模糊)
        /// </summary>
        public float BlurRadius { get; set; } = 0f;
        
        /// <summary>
        /// 旋转角度（弧度）
        /// </summary>
        public float Rotation { get; set; } = 0f;
        
        /// <summary>
        /// 缩放因子
        /// </summary>
        public Vector2 Scale { get; set; } = Vector2.One;
        
        /// <summary>
        /// 创建对象实例
        /// </summary>
        protected SceneObject(string id, int layerId, UIRectN rect)
        {
            Id = id;
            LayerId = layerId;
            Rect = rect;
        }
        
        /// <summary>
        /// 更新对象逻辑
        /// </summary>
        public virtual void Update(GameTime gameTime)
        {
            // 基类通常不做任何事情，由子类实现
        }
        
        /// <summary>
        /// 绘制对象
        /// </summary>
        public abstract void Draw(SpriteBatch spriteBatch, int screenWidth, int screenHeight);
        
        /// <summary>
        /// 获取对象在屏幕上的实际矩形
        /// </summary>
        public Rectangle GetScreenRect(int screenWidth, int screenHeight)
        {
            return Rect.ToRectangle(screenWidth, screenHeight);
        }
    }
} 