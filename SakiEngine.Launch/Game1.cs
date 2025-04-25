using Microsoft.Xna.Framework;
using Microsoft.Xna.Framework.Graphics;
using Microsoft.Xna.Framework.Input;
using SakiEngine.Core.GameCore;
using SakiEngine.Launch.Menus;
using System.IO; // Add this for Path
using System; // Add this for AppDomain
using SakiEngine.Core.UI; // Add this
using SakiEngine.Core.Text; // Add this

namespace SakiEngine.Launch
{
    /// <summary>
    /// 游戏启动类
    /// </summary>
    public class Game1 : GameInstance
    {
        // --- 添加：当前游戏设置 ---
        public static GameSettings CurrentSettings { get; private set; } = null!;
        // -------------------------

        /// <summary>
        /// 构造函数
        /// </summary>
        public Game1() : base()
        {
            Window.Title = "SakiEngine 演示";
        }

        /// <summary>
        /// 初始化游戏
        /// </summary>
        protected override void Initialize()
        {
            // 先调用基类 Initialize，创建 ResolutionManager 并应用动态初始分辨率
            base.Initialize(); 

            // --- 加载设置 ---
            bool settingsFileExisted = File.Exists(GameSettings.GetSettingsFilePath());
            CurrentSettings = GameSettings.Load(); // Load settings (might return defaults)
            // --- 打印设置路径 ---
            Console.WriteLine($"[Game1] Settings file path: {GameSettings.GetSettingsFilePath()}");
            
            // --- 如果设置文件不存在，使用 ResolutionManager 的动态初始分辨率更新设置 ---
            if (!settingsFileExisted)
            {
                Console.WriteLine("[Game1] Settings file not found. Using dynamic initial resolution as default.");
                var initialDynamicSize = ResolutionManager.CurrentWindowSize; // Get the size set by ResolutionManager constructor
                CurrentSettings.ResolutionWidth = initialDynamicSize.X;
                CurrentSettings.ResolutionHeight = initialDynamicSize.Y;
                // Optionally save these defaults now
                CurrentSettings.Save(); 
            }
            // ---------------
            
            // --- 应用最终设置 (加载的或刚更新的动态默认值) ---
            // 应用分辨率 (需要在 ResolutionManager 初始化后)
            ResolutionManager.ChangeResolution(new Point(CurrentSettings.ResolutionWidth, CurrentSettings.ResolutionHeight));
            
            // 应用全屏模式 (需要在 ResolutionManager 初始化后)
            if (CurrentSettings.IsFullscreen)
            {
                var displayMode = GraphicsAdapter.DefaultAdapter.CurrentDisplayMode;
                ResolutionManager.SetFullscreen(displayMode.Width, displayMode.Height);
            }
            else
            {
                ResolutionManager.SetWindowed();
            }
            // --------------------

            // 应用其他设置 (如字体渲染参数)
            ApplyLoadedFontSettings();
        }

        /// <summary>
        /// 加载游戏内容
        /// </summary>
        protected override void LoadContent()
        {
            base.LoadContent();
            
            // 打开主菜单
            MenuManager.PushMenu(new MainMenu());
        }

        /// <summary>
        /// 更新游戏逻辑
        /// </summary>
        protected override void Update(GameTime gameTime)
        {
            // 退出游戏的快捷键
            if (GamePad.GetState(PlayerIndex.One).Buttons.Back == ButtonState.Pressed || 
                Keyboard.GetState().IsKeyDown(Keys.Escape))
            {
                // 如果只有一个菜单，则退出游戏
                if (MenuManager.ActiveMenu != null && 
                    MenuManager.ActiveMenu.Id == "MainMenu")
                {
                    Exit();
                }
                // 否则返回上一个菜单
                else if (MenuManager.ActiveMenu != null)
                {
                    MenuManager.PopMenu();
                }
            }

            base.Update(gameTime);
        }

        /// <summary>
        /// 绘制游戏
        /// </summary>
        protected override void Draw(GameTime gameTime)
        {
            base.Draw(gameTime);
        }

        /// <summary>
        /// Helper to apply loaded font settings to the managers
        /// </summary>
        private void ApplyLoadedFontSettings()
        {
             if (CurrentSettings != null)
            {
                SkiaTextElement.TextRenderScale = CurrentSettings.ScaleFactor;
                CurrentTextSamplerState = CurrentSettings.SamplerState;
                SkiaFontManager.UseAntialias = CurrentSettings.UseAntialias;
                SkiaFontManager.CurrentHintingLevel = CurrentSettings.HintingLevel;
                SkiaFontManager.UseSubpixelText = CurrentSettings.UseSubpixelText;
                SkiaFontManager.UseLcdRenderText = CurrentSettings.UseSubpixelText; // Link LCD to subpixel for simplicity
                // Autohint is derived from hinting level in SettingsMenu, no direct setting needed here
            }
        }
    }
}
