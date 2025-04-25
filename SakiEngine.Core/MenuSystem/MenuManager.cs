using Microsoft.Xna.Framework;
using Microsoft.Xna.Framework.Graphics;
using System.Collections.Generic;
using System;

namespace SakiEngine.Core.MenuSystem
{
    /// <summary>
    /// 菜单管理器，处理菜单栈和菜单切换
    /// </summary>
    public class MenuManager
    {
        private readonly List<Menu> _menuStack = new();
        
        /// <summary>
        /// 当前活动菜单（栈顶）
        /// </summary>
        public Menu? ActiveMenu => _menuStack.Count > 0 ? _menuStack[^1] : null;
        
        /// <summary>
        /// 推入一个新菜单到栈顶
        /// </summary>
        public void PushMenu(Menu menu)
        {
            if (_menuStack.Count > 0)
            {
                var currentTop = _menuStack[^1];
                if (menu.Type == MenuType.Exclusive || currentTop.Type == MenuType.Exclusive)
                {
                    currentTop.Enabled = false;
                    currentTop.OnDeactivate();
                }
            }
            _menuStack.Add(menu);
            menu.Enabled = true;
            menu.Manager = this;
            menu.OnActivate();
        }
        
        /// <summary>
        /// 弹出栈顶菜单
        /// </summary>
        public Menu? PopMenu()
        {
            Menu? removedMenu = null;
            if (_menuStack.Count > 0)
            {
                removedMenu = _menuStack[^1];
                removedMenu.Enabled = false;
                removedMenu.OnDeactivate();
                removedMenu.OnRemove();
                _menuStack.RemoveAt(_menuStack.Count - 1);

                if (_menuStack.Count > 0)
                {
                    var newTop = _menuStack[^1];
                    if (!newTop.Enabled)
                    {
                        newTop.OnActivate();
                    }
                }
            }
            return removedMenu;
        }
        
        /// <summary>
        /// 替换栈顶菜单
        /// </summary>
        public void ReplaceMenu(Menu menu)
        {
            if (_menuStack.Count > 0)
            {
                PopMenu();
            }
            
            PushMenu(menu);
        }
        
        /// <summary>
        /// 清空整个菜单栈
        /// </summary>
        public void ClearMenus()
        {
            while (_menuStack.Count > 0)
            {
                PopMenu();
            }
        }
        
        /// <summary>
        /// 更新菜单逻辑
        /// </summary>
        public void Update(GameTime gameTime)
        {
            bool exclusiveFound = false;
            for (int i = _menuStack.Count - 1; i >= 0; i--)
            {
                var menu = _menuStack[i];
                if (menu.Enabled)
                {
                    menu.Update(gameTime);
                }
                if (menu.Enabled && menu.Type == MenuType.Exclusive)
                {
                    exclusiveFound = true;
                }
                if (exclusiveFound && menu.Type != MenuType.Overlay)
                {
                    break;
                }
            }
        }
        
        /// <summary>
        /// 绘制菜单
        /// </summary>
        public void Draw(SpriteBatch spriteBatch, int screenWidth, int screenHeight)
        {
            int topExclusiveIndex = -1;
            for (int i = _menuStack.Count - 1; i >= 0; i--)
            {
                if (_menuStack[i].Enabled && _menuStack[i].Type == MenuType.Exclusive)
                {
                    topExclusiveIndex = i;
                    break;
                }
            }

            int startIndex = (topExclusiveIndex != -1) ? topExclusiveIndex : 0;

            for (int i = startIndex; i < _menuStack.Count; i++)
            {
                var menu = _menuStack[i];
                if (menu.Visible)
                {
                    menu.Draw(spriteBatch, screenWidth, screenHeight);
                }
            }
        }
    }
} 