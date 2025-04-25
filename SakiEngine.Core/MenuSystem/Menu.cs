using Microsoft.Xna.Framework;
using Microsoft.Xna.Framework.Graphics;
using SakiEngine.Core.SceneGraph;
using SakiEngine.Core.UI;
using SakiEngine.Core.Utils;
using System;
namespace SakiEngine.Core.MenuSystem
{
    /// <summary>
    /// 菜单基类，所有菜单必须继承此类
    /// Now inherits from UIElement to act as a container.
    /// </summary>
    public abstract class Menu : UIElement
    {
        /// <summary>
        /// 菜单类型
        /// </summary>
        public MenuType Type { get; private set; }
        
        /// <summary>
        /// 菜单管理器引用 (新增)
        /// </summary>
        public MenuManager? Manager { get; internal set; } // Internal set so only MenuManager can set it
        
        /// <summary>
        /// 构造函数
        /// </summary>
        protected Menu(string id, MenuType type)
            : base(id, LayerConstants.MenuBackground, UIRectN.FullScreen)
        {
            Type = type;
            BackgroundColor = Color.Transparent;
        }
        
        /// <summary>
        /// 初始化菜单
        /// </summary>
        protected abstract void Initialize();
        
        /// <summary>
        /// 当菜单被推入栈顶或重新激活时调用
        /// </summary>
        public virtual void OnActivate()
        {
            Initialize();
            Visible = true;
            Enabled = true;
        }
        
        /// <summary>
        /// 当菜单不再是栈顶时调用
        /// </summary>
        public virtual void OnDeactivate()
        {
            Enabled = false;
        }
        
        /// <summary>
        /// 当菜单从栈中移除时调用
        /// </summary>
        public virtual void OnRemove()
        {
            Visible = false;
            Enabled = false;
        }
        
        /// <summary>
        /// 更新菜单逻辑
        /// </summary>
        public override void Update(GameTime gameTime)
        {
            if (!Enabled)
                return;

            base.Update(gameTime);

            try
            {
                UpdateMenuLogic(gameTime);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[{Id}] EXCEPTION during UpdateMenuLogic: {ex.Message}");
            }
        }
        
        /// <summary>
        /// 子类实现的更新逻辑
        /// </summary>
        protected virtual void UpdateMenuLogic(GameTime gameTime) { }
        
        /// <summary>
        /// 绘制菜单
        /// </summary>
        public override void Draw(SpriteBatch spriteBatch, int screenWidth, int screenHeight)
        {
            base.Draw(spriteBatch, screenWidth, screenHeight);
        }
    }
} 