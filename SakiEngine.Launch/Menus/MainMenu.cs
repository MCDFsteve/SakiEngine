using Microsoft.Xna.Framework;
using Microsoft.Xna.Framework.Graphics;
using SakiEngine.Core.GameCore;
using SakiEngine.Core.MenuSystem;
using SakiEngine.Core.SceneGraph;
using SakiEngine.Core.UI;
using SakiEngine.Core.Text;
using SakiEngine.Core.Utils;
using System;
// using SkiaSharp; // 不再需要

namespace SakiEngine.Launch.Menus
{
    /// <summary>
    /// 主菜单
    /// </summary>
    public class MainMenu : Menu
    {
        private SkiaTextElement _titleText;
        // Button text elements are no longer needed as fields
        // private SkiaTextElement _startText;
        // private SkiaTextElement _settingsText;
        // private SkiaTextElement _exitText;

        // 按钮 (Keep the fields if you need to reference them later, e.g., to disable)
        private Button _startButton;
        private Button _settingsButton;
        private Button _exitButton;
        
        // --- 渲染参数测试控件 (移除) ---
        // private SkiaTextElement _scaleInfoText;
        // private Button _scale1xButton;
        // private Button _scale2xButton;
        // private Button _scale3xButton;
        // private Button _scale4xButton;
        // private static float _currentScaleFactor = 1.0f; 
        // private SkiaTextElement _samplerInfoText;     
        // private Button _samplerPointButton;   
        // private Button _samplerLinearButton;  
        // private static SamplerState _currentSamplerState = SamplerState.LinearClamp; 
        // private SkiaTextElement _togglesInfoText; 
        // private Button _toggleAntialiasButton;
        // private SkiaTextElement _toggleAntialiasButtonText; 
        // private Button _cycleHintingButton;
        // private SkiaTextElement _cycleHintingButtonText;   
        // private Button _toggleSubpixelButton;
        // private SkiaTextElement _toggleSubpixelButtonText; 
        // private static SKPaintHinting _currentHintingLevel = SKPaintHinting.Full; 
        // -------------------------

        // 添加回 _isInitialized 字段
        private bool _isInitialized = false;

        /// <summary>
        /// 构造函数
        /// </summary>
        public MainMenu() : base("MainMenu", MenuType.Exclusive)
        {
            // Console.WriteLine("[MainMenu] Constructor called."); // Remove log
        }
        
        /// <summary>
        /// 初始化菜单
        /// </summary>
        protected override void Initialize()
        {
            // Console.WriteLine("[MainMenu] Initialize started."); // Remove log

            // 创建标题文本
            _titleText = new SkiaTextElement(
                "TitleText",
                LayerConstants.MenuText,
                new UIRectN(0.1f, 0.1f, 0.8f, 0.1f),
                "SakiEngine 演示"
            );
            _titleText.TextColor = Color.White;
            _titleText.Alignment = TextAlignment.Center;
            _titleText.SetFont(null, 32);
            AddChild(_titleText);

            // 使用 UIHelper 创建按钮
            _startButton = UIHelper.CreateAndAddButton(
                parent: this,
                id: "StartButton",
                layerId: LayerConstants.MenuElements,
                rect: new UIRectN(0.35f, 0.3f, 0.3f, 0.08f),
                text: "开始游戏",
                onClickAction: OnStartButtonClicked,
                backgroundColor: new Color(70, 70, 70, 200),
                textColor: Color.White,
                textSize: 24
            );

            _settingsButton = UIHelper.CreateAndAddButton(
                parent: this,
                id: "SettingsButton",
                layerId: LayerConstants.MenuElements,
                rect: new UIRectN(0.35f, 0.4f, 0.3f, 0.08f),
                text: "设置",
                onClickAction: OnSettingsButtonClicked,
                backgroundColor: new Color(70, 70, 70, 200),
                textColor: Color.White,
                textSize: 24
            );

            _exitButton = UIHelper.CreateAndAddButton(
                parent: this,
                id: "ExitButton",
                layerId: LayerConstants.MenuElements,
                rect: new UIRectN(0.35f, 0.5f, 0.3f, 0.08f),
                text: "退出",
                onClickAction: OnExitButtonClicked,
                backgroundColor: new Color(70, 70, 70, 200),
                textColor: Color.White,
                textSize: 24
            );

            // Console.WriteLine("[MainMenu] Initialize finished."); // Remove log
        }
        
        // --- 移除所有辅助方法 ---
        /*
        private SkiaTextElement CreateInfoText(...) { ... }
        private Button CreateParamButton(...) { ... }
        private SkiaTextElement AddButtonText(...) { ... }
        */

        /// <summary>
        /// 开始按钮点击事件
        /// </summary>
        private void OnStartButtonClicked(UIElement sender)
        {
            Console.WriteLine("Start button clicked!");
            // 这里可以添加开始游戏的逻辑
        }
        
        /// <summary>
        /// 设置按钮点击事件
        /// </summary>
        private void OnSettingsButtonClicked(UIElement sender)
        {
            // Console.WriteLine("[MainMenu] Settings button clicked. Pushing SettingsMenu..."); // 添加日志
            // 打开设置菜单
            GameInstance.Instance.MenuManager.PushMenu(new SettingsMenu()); // 取消注释
        }
        
        /// <summary>
        /// 退出按钮点击事件
        /// </summary>
        private void OnExitButtonClicked(UIElement sender)
        {
            // 退出游戏
            GameInstance.Instance.Exit();
        }

        // --- 移除所有参数按钮点击处理方法和相关辅助方法 ---
        /*
        private void OnScaleButtonClicked(float scale) { ... }
        private void OnSamplerButtonClicked(SamplerState state, string name) { ... }
        private void OnToggleAntialiasClicked() { ... }
        private void OnCycleHintingLevelClicked() { ... }
        private void OnToggleSubpixelClicked() { ... }
        private void RefreshTextRendering() { ... }
        private void UpdateAllButtonStates() { ... }
        private string GetSamplerStateName(SamplerState state) { ... }
        private string GetHintingLevelName(SKPaintHinting hinting) { ... }
        private string GetTogglesStateString() { ... }
        */

        public override void OnActivate()
        {
            if (!_isInitialized)
            {
                Initialize();
                _isInitialized = true;
            }
            // Let base class handle visibility/enabled state
            // base.OnActivate(); // Call base if it has logic
            Visible = true;
            Enabled = true;
        }

        // Base class Update/Draw handle children now
        // protected override void UpdateMenuLogic(GameTime gameTime) { ... }
    }
} 