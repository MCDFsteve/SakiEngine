using Microsoft.Xna.Framework;
using Microsoft.Xna.Framework.Graphics;
using SakiEngine.Core.GameCore;
using SakiEngine.Core.MenuSystem;
using SakiEngine.Core.SceneGraph;
using SakiEngine.Core.UI;
using SakiEngine.Core.Utils;
using System;
using SkiaSharp;
using SakiEngine.Core.Text;
using System.Collections.Generic;
using System.Linq; // For Select

namespace SakiEngine.Launch.Menus
{
    /// <summary>
    /// 设置菜单
    /// </summary>
    public class SettingsMenu : Menu
    {
        private SkiaTextElement _titleText;
        private Button _backButton;

        // 分辨率按钮
        private Dropdown _resolutionDropdown;
        // 新增：显示模式下拉菜单
        private Dropdown _displayModeDropdown;

        // --- 字体渲染参数测试控件 (保留) ---
        private SkiaTextElement _renderingParamsTitle;
        // 缩放
        private Dropdown _scaleDropdown;
        private float _currentScaleFactor = 2.0f;

        // SpriteBatch 采样器状态
        private Dropdown _samplerDropdown;
        private SamplerState _currentSamplerState = SamplerState.LinearClamp;

        // 开关和循环按钮
        private Dropdown _hintingDropdown;
        private SKPaintHinting _currentHintingLevel = SKPaintHinting.Full;
        // -------------------------------------------

        // REMOVED: 全屏/窗口化 按钮
        // private Button _fullscreenButton;
        // private Button _windowedButton;
        private bool _isFullscreen = false; // Keep track of state internally
        private Color _disabledColor = new Color(40, 40, 40, 180); // Keep for actually disabled (e.g., Res buttons in fullscreen)
        private Color _activeColor = new Color(90, 140, 90, 220); // Define a brighter color for the active setting (e.g., greenish)
        private Color _defaultButtonColor = new Color(70, 70, 70, 200); // Default color for inactive buttons

        // Toggle buttons
        private Button _toggleAntialiasButton;
        private Button _toggleSubpixelButton;

        /// <summary>
        /// 构造函数
        /// </summary>
        public SettingsMenu() : base("SettingsMenu", MenuType.Exclusive)
        {
        }

        /// <summary>
        /// 初始化菜单
        /// </summary>
        protected override void Initialize()
        {
            // --- 读取并应用已加载的设置 ---
            var settings = Game1.CurrentSettings;
            if (settings != null)
            {
                _currentScaleFactor = settings.ScaleFactor;
                _currentSamplerState = settings.SamplerState;
                _currentHintingLevel = settings.HintingLevel;
                _isFullscreen = settings.IsFullscreen; // Load initial state

                // 确保游戏状态与设置同步 (Initialize 可能在 Game1 应用设置之后调用)
                SkiaTextElement.TextRenderScale = _currentScaleFactor;
                GameInstance.CurrentTextSamplerState = _currentSamplerState;
                SkiaFontManager.UseAntialias = settings.UseAntialias;
                SkiaFontManager.CurrentHintingLevel = _currentHintingLevel;
                SkiaFontManager.UseSubpixelText = settings.UseSubpixelText;
                SkiaFontManager.UseLcdRenderText = settings.UseSubpixelText;
                // Autohint 会在 CycleHinting 中设置
            }
            // ------------------------------

            // 清空旧控件（如果重新初始化）
            if (_resolutionDropdown != null) RemoveChild(_resolutionDropdown);
            if (_displayModeDropdown != null) RemoveChild(_displayModeDropdown); // Clear new dropdown too
            if (_scaleDropdown != null) RemoveChild(_scaleDropdown);
            if (_samplerDropdown != null) RemoveChild(_samplerDropdown);
            if (_hintingDropdown != null) RemoveChild(_hintingDropdown);
            if (_toggleAntialiasButton != null) RemoveChild(_toggleAntialiasButton);
            if (_toggleSubpixelButton != null) RemoveChild(_toggleSubpixelButton);
            // REMOVED: Clear old buttons
            // if (_fullscreenButton != null) RemoveChild(_fullscreenButton);
            // if (_windowedButton != null) RemoveChild(_windowedButton);

            // 获取可用分辨率列表和名称 (使用新的 Point 接口)
            var resManager = GameInstance.Instance.ResolutionManager;
            var availableResolutionPoints = resManager.AvailableResolutions;
            var availableResolutionNames = resManager.AvailableResolutionNames;

            // Title
            _titleText = CreateInfoText("SettingsTitle", "设置", 0.1f, 0.05f, 0.8f, 0.08f);
            AddChild(_titleText); // Need to add the title back
            _titleText.TextColor = Color.White;
            _titleText.Alignment = TextAlignment.Center;
            _titleText.SetFont(null, 24);


            // Layout variables
            float currentY = 0.15f;
            float labelWidth = 0.3f;
            float controlWidth = 0.5f; // Make controls wider
            float controlHeight = 0.05f; // Standard height
            float startXLabel = 0.05f; // Start further left
            float startXControl = startXLabel + labelWidth + 0.01f;
            float verticalSpacing = 0.01f;
            float labelOffsetY = (controlHeight - 0.03f) / 2; // Adjust label vertical alignment
            float controlTextSize = 16f;

            // --- Display Mode Dropdown (NEW) ---
            AddChild(CreateInfoText("DisplayModeLabel", "显示模式:", startXLabel, currentY + labelOffsetY, labelWidth, 0.03f));
            _displayModeDropdown = new Dropdown("DisplayModeDropdown", LayerConstants.MenuElements, new UIRectN(startXControl, currentY, controlWidth, controlHeight));
            _displayModeDropdown.SetFont(null, controlTextSize);
            _displayModeDropdown.AddItem("窗口化"); // Index 0
            _displayModeDropdown.AddItem("全屏");   // Index 1
            _displayModeDropdown.SelectedIndex = _isFullscreen ? 1 : 0; // Set initial selection
            _displayModeDropdown.OnSelectionChanged += OnDisplayModeChanged;
            AddChild(_displayModeDropdown);
            currentY += controlHeight + verticalSpacing;
            // ------------------------------------

            // Resolution Dropdown
            AddChild(CreateInfoText("ResLabel", "分辨率:", startXLabel, currentY + labelOffsetY, labelWidth, 0.03f));
            _resolutionDropdown = new Dropdown("ResDropdown", LayerConstants.MenuElements, new UIRectN(startXControl, currentY, controlWidth, controlHeight));
            _resolutionDropdown.SetFont(null, controlTextSize);
            var currentWindowSize = resManager.CurrentWindowSize;
            int selectedResIndex = -1;
            for(int i=0; i < availableResolutionNames.Count; i++)
            {
                _resolutionDropdown.AddItem(availableResolutionNames[i]);
                if (!_isFullscreen && availableResolutionPoints[i] == currentWindowSize) // Only match if windowed
                {
                     selectedResIndex = i;
                }
            }
             if (selectedResIndex != -1) _resolutionDropdown.SelectedIndex = selectedResIndex;
            _resolutionDropdown.OnSelectionChanged += OnResolutionChanged;
            AddChild(_resolutionDropdown);
            currentY += controlHeight + verticalSpacing;

            // Rendering Params Title
            _renderingParamsTitle = CreateInfoText("RenderParamsTitle", "--- 渲染参数 ---", 0.1f, currentY, 0.8f, 0.05f);
            AddChild(_renderingParamsTitle); // Add title
            _renderingParamsTitle.Alignment = TextAlignment.Center;
            _renderingParamsTitle.SetFont(null, 18);
            _renderingParamsTitle.TextColor = Color.Cyan;
            currentY += 0.05f + verticalSpacing;

            // Scale Dropdown
            AddChild(CreateInfoText("ScaleLabel", "字体缩放:", startXLabel, currentY + labelOffsetY, labelWidth, 0.03f));
            _scaleDropdown = new Dropdown("ScaleDropdown", LayerConstants.MenuElements, new UIRectN(startXControl, currentY, controlWidth, controlHeight));
            _scaleDropdown.SetFont(null, controlTextSize);
            int selectedScaleIndex = -1;
            for (int i = 1; i <= 8; i++)
            {
                 _scaleDropdown.AddItem($"{i}x");
                 if (Math.Abs(_currentScaleFactor - i) < 0.01f)
                 {
                     selectedScaleIndex = i - 1;
                 }
            }
            if(selectedScaleIndex != -1) _scaleDropdown.SelectedIndex = selectedScaleIndex;
            _scaleDropdown.OnSelectionChanged += OnScaleChanged;
            AddChild(_scaleDropdown);
            currentY += controlHeight + verticalSpacing;

            // Sampler Dropdown
            AddChild(CreateInfoText("SamplerLabel", "纹理采样:", startXLabel, currentY + labelOffsetY, labelWidth, 0.03f));
            _samplerDropdown = new Dropdown("SamplerDropdown", LayerConstants.MenuElements, new UIRectN(startXControl, currentY, controlWidth, controlHeight));
            _samplerDropdown.SetFont(null, controlTextSize);
            _samplerDropdown.AddItem("最近邻"); // Index 0 -> PointClamp
            _samplerDropdown.AddItem("线性采样"); // Index 1 -> LinearClamp
            _samplerDropdown.SelectedIndex = (_currentSamplerState == SamplerState.PointClamp) ? 0 : 1;
            _samplerDropdown.OnSelectionChanged += OnSamplerChanged;
            AddChild(_samplerDropdown);
            currentY += controlHeight + verticalSpacing;

            // Hinting Dropdown
            AddChild(CreateInfoText("HintingLabel", "字体微调:", startXLabel, currentY + labelOffsetY, labelWidth, 0.03f));
            _hintingDropdown = new Dropdown("HintingDropdown", LayerConstants.MenuElements, new UIRectN(startXControl, currentY, controlWidth, controlHeight));
            _hintingDropdown.SetFont(null, controlTextSize);
            var hintingNames = new[] { "无", "轻微", "普通", "完全" };
            int selectedHintingIndex = -1;
            for(int i=0; i<hintingNames.Length; i++)
            {
                 _hintingDropdown.AddItem(hintingNames[i]);
                 if ((int)_currentHintingLevel == i) selectedHintingIndex = i;
            }
            if(selectedHintingIndex != -1) _hintingDropdown.SelectedIndex = selectedHintingIndex;
            _hintingDropdown.OnSelectionChanged += OnHintingChanged;
            AddChild(_hintingDropdown);
            currentY += controlHeight + verticalSpacing;

            // Keep Toggle Buttons for Antialias and Subpixel
            AddChild(CreateInfoText("AALabel", "抗锯齿:", startXLabel, currentY + labelOffsetY, labelWidth, 0.03f));
            _toggleAntialiasButton = UIHelper.CreateAndAddButton(this, "ToggleAA", LayerConstants.MenuElements, new UIRectN(startXControl, currentY, controlWidth, controlHeight),
                                                      GetAntialiasButtonText(),
                                                      (sender) => OnToggleAntialiasClicked(),
                                                      textSize: controlTextSize);
            AddChild(_toggleAntialiasButton); // Add toggle button
            currentY += controlHeight + verticalSpacing;

             AddChild(CreateInfoText("SubPxLabel", "子像素渲染:", startXLabel, currentY + labelOffsetY, labelWidth, 0.03f));
            _toggleSubpixelButton = UIHelper.CreateAndAddButton(this, "ToggleSubpixel", LayerConstants.MenuElements, new UIRectN(startXControl, currentY, controlWidth, controlHeight),
                                                      GetSubpixelButtonText(),
                                                      (sender) => OnToggleSubpixelClicked(),
                                                      textSize: controlTextSize);
            AddChild(_toggleSubpixelButton); // Add toggle button
            currentY += controlHeight + verticalSpacing * 2;

            // Only Back Button at the bottom
            float bottomButtonWidth = 0.2f; // Width for the back button
            float bottomButtonHeight = 0.05f;
            float bottomStartX = (1.0f - bottomButtonWidth) / 2; // Center the back button
            float bottomY = Math.Max(currentY, 1.0f - bottomButtonHeight - 0.03f);

            // REMOVED: Fullscreen/Windowed button creation
            // _fullscreenButton = ...
            // _windowedButton = ...

            _backButton = UIHelper.CreateAndAddButton(this, "BackButton", LayerConstants.MenuElements,
                                              new UIRectN(bottomStartX, bottomY, bottomButtonWidth, bottomButtonHeight), // Centered position
                                              "返回", OnBackClicked, textSize: 18f);
             AddChild(_backButton); // Add back button


            // Update initial states
            UpdateControlStates();
            // UpdateDisplayModeUI(); // Now handled by UpdateControlStates
        }

        /// <summary>
        /// 更新菜单逻辑 (移除旧逻辑)
        /// </summary>
        protected override void UpdateMenuLogic(GameTime gameTime)
        {
            // 无需更新
        }

        // REMOVED: OnFullscreenClicked method
        // private void OnFullscreenClicked(UIElement sender) { ... }

        // REMOVED: OnWindowedClicked method
        // private void OnWindowedClicked(UIElement sender) { ... }

        /// <summary>
        /// 返回按钮点击事件
        /// </summary>
        private void OnBackClicked(UIElement sender)
        {
            // 保存设置 (确保所有更改都已保存)
            Game1.CurrentSettings.ScaleFactor = _currentScaleFactor;
            Game1.CurrentSettings.SamplerState = _currentSamplerState;
            Game1.CurrentSettings.UseAntialias = SkiaFontManager.UseAntialias;
            Game1.CurrentSettings.HintingLevel = _currentHintingLevel;
            Game1.CurrentSettings.UseSubpixelText = SkiaFontManager.UseSubpixelText;
            // IsFullscreen and Resolution are saved in OnDisplayModeChanged/OnResolutionChanged
            Game1.CurrentSettings.Save();

            // 返回主菜单
            GameInstance.Instance.MenuManager.PopMenu();
        }

        // --- New Dropdown Event Handlers ---

        /// <summary>
        /// Handles selection change in the display mode dropdown.
        /// </summary>
        private void OnDisplayModeChanged(int index, string selectedName)
        {
            if (index < 0) return;

            bool wantFullscreen = (index == 1); // 0: Windowed, 1: Fullscreen

            if (wantFullscreen != _isFullscreen) // Only act if the state changes
            {
                _isFullscreen = wantFullscreen; // Update internal state first

                // Update settings object BEFORE applying changes
                Game1.CurrentSettings.IsFullscreen = _isFullscreen;

                if (_isFullscreen)
                {
                    // Switch to Fullscreen
                    var displayMode = GraphicsAdapter.DefaultAdapter.CurrentDisplayMode;
                    GameInstance.Instance.ResolutionManager.SetFullscreen(displayMode.Width, displayMode.Height);
                    // No need to update settings width/height here, they remain for windowed mode
                }
                else
                {
                    // Switch to Windowed
                    // Use the resolution stored in settings (ResolutionManager handles restoring)
                    GameInstance.Instance.ResolutionManager.SetWindowed(); // REMOVED parameters
                    // Update the resolution dropdown selection to match the restored window size
                }

                // Save settings immediately
                Game1.CurrentSettings.Save();

                // Update UI element states (like enabling/disabling resolution dropdown)
                UpdateControlStates();
            }
        }


        private void OnResolutionChanged(int index, string selectedName)
        {
            if (_isFullscreen) return; // Don't allow changing resolution in fullscreen via dropdown

            if (index < 0 || index >= GameInstance.Instance.ResolutionManager.AvailableResolutions.Count) return;

            var newSize = GameInstance.Instance.ResolutionManager.AvailableResolutions[index];
            GameInstance.Instance.ResolutionManager.ChangeResolution(newSize); // Applies change and updates CurrentWindowSize

            // Update settings only AFTER applying, so CurrentWindowSize is correct
            Game1.CurrentSettings.ResolutionWidth = GameInstance.Instance.ResolutionManager.CurrentWindowSize.X;
            Game1.CurrentSettings.ResolutionHeight = GameInstance.Instance.ResolutionManager.CurrentWindowSize.Y;
            Game1.CurrentSettings.Save();
        }

        private void OnScaleChanged(int index, string selectedValue)
        {
             if (index < 0) return;
            _currentScaleFactor = index + 1.0f;
            SkiaTextElement.TextRenderScale = _currentScaleFactor;
            Game1.CurrentSettings.ScaleFactor = _currentScaleFactor;
            Game1.CurrentSettings.Save();
            RefreshTextRendering();
        }

        private void OnSamplerChanged(int index, string selectedName)
        {
            if (index < 0) return;
            _currentSamplerState = (index == 0) ? SamplerState.PointClamp : SamplerState.LinearClamp;
            GameInstance.CurrentTextSamplerState = _currentSamplerState;
            Game1.CurrentSettings.SamplerState = _currentSamplerState;
            Game1.CurrentSettings.Save();
        }

        private void OnHintingChanged(int index, string selectedName)
        {
             if (index < 0) return;
            _currentHintingLevel = (SKPaintHinting)index;
            SkiaFontManager.CurrentHintingLevel = _currentHintingLevel;
            SkiaFontManager.UseAutohinted = _currentHintingLevel == SKPaintHinting.Normal || _currentHintingLevel == SKPaintHinting.Full;
            Game1.CurrentSettings.HintingLevel = _currentHintingLevel;
            Game1.CurrentSettings.Save();
            RefreshTextRendering();
        }

        // --- Keep Toggle Button Handlers ---
        private void OnToggleAntialiasClicked()
        {
            bool newState = !SkiaFontManager.UseAntialias;
            SkiaFontManager.UseAntialias = newState;
            Game1.CurrentSettings.UseAntialias = newState;
            Game1.CurrentSettings.Save();
            RefreshTextRendering();
            UIHelper.SetButtonText(_toggleAntialiasButton, GetAntialiasButtonText());
        }

        private void OnToggleSubpixelClicked()
        {
            bool newState = !SkiaFontManager.UseSubpixelText;
            SkiaFontManager.UseSubpixelText = newState;
            SkiaFontManager.UseLcdRenderText = newState; // Keep linked
            Game1.CurrentSettings.UseSubpixelText = newState;
            Game1.CurrentSettings.Save();
            RefreshTextRendering();
            UIHelper.SetButtonText(_toggleSubpixelButton, GetSubpixelButtonText());
        }

        // --- Helper Methods ---

        private void RefreshTextRendering()
        {
            GameInstance.Instance.TextRenderer.ClearCache();
        }

        // Updated state update method
        private void UpdateControlStates()
        {
            // --- Display Mode Dropdown ---
            if (_displayModeDropdown != null)
            {
                _displayModeDropdown.SelectedIndex = _isFullscreen ? 1 : 0;
            }

            // --- Resolution Dropdown ---
            bool isWindowed = !_isFullscreen;
            if (_resolutionDropdown != null)
            {
                _resolutionDropdown.Enabled = isWindowed;
                _resolutionDropdown.BackgroundColor = isWindowed ? _defaultButtonColor : _disabledColor;
                // _resolutionDropdown.ForegroundColor = isWindowed ? Color.White : Color.Gray; // Optional text color change

                if (isWindowed)
                {
                    // Reselect current resolution if windowed
                    var currentSize = GameInstance.Instance.ResolutionManager.CurrentWindowSize;
                    var availablePoints = GameInstance.Instance.ResolutionManager.AvailableResolutions;
                    int resIndex = -1;
                    for (int i = 0; i < availablePoints.Count; i++)
                    { if (availablePoints[i] == currentSize) { resIndex = i; break; } }

                    // Prevent infinite loop by checking if selection actually needs changing
                    if (resIndex != -1 && _resolutionDropdown.SelectedIndex != resIndex)
                    {
                         _resolutionDropdown.SelectedIndex = resIndex;
                    } else if (resIndex == -1) {
                        _resolutionDropdown.SelectedIndex = -1; // No matching resolution found
                    }
                }
            }


            // --- Other Dropdowns ---
            if(_scaleDropdown != null)
            {
                 int scaleIndex = (int)Math.Round(_currentScaleFactor) - 1;
                 if (scaleIndex >= 0 && scaleIndex < _scaleDropdown.Items.Count && _scaleDropdown.SelectedIndex != scaleIndex)
                     _scaleDropdown.SelectedIndex = scaleIndex;
            }

            if(_samplerDropdown != null)
            {
                 int samplerIndex = (_currentSamplerState == SamplerState.PointClamp) ? 0 : 1;
                 if (_samplerDropdown.SelectedIndex != samplerIndex)
                    _samplerDropdown.SelectedIndex = samplerIndex;
            }

            if(_hintingDropdown != null)
            {
                int hintIndex = (int)_currentHintingLevel;
                 if (hintIndex >= 0 && hintIndex < _hintingDropdown.Items.Count && _hintingDropdown.SelectedIndex != hintIndex)
                    _hintingDropdown.SelectedIndex = hintIndex;
            }

            // --- Toggle Buttons ---
            // Update text (already done in handlers, but good for initial state)
            if (_toggleAntialiasButton != null)
                 UIHelper.SetButtonText(_toggleAntialiasButton, GetAntialiasButtonText());
             if (_toggleSubpixelButton != null)
                 UIHelper.SetButtonText(_toggleSubpixelButton, GetSubpixelButtonText());

        }

        // REMOVED: UpdateDisplayModeUI method (merged into UpdateControlStates)
        // private void UpdateDisplayModeUI() { ... }


        // Modify CreateInfoText to not add child automatically
        private SkiaTextElement CreateInfoText(string id, string text, float x, float y, float w, float h)
        {
            var textElement = new SkiaTextElement(
                id,
                LayerConstants.MenuText, // Use a layer below controls?
                new UIRectN(x, y, w, h),
                text
            );
            textElement.TextColor = Color.LightGray;
            textElement.Alignment = TextAlignment.Left; // Align labels left
            textElement.SetFont(null, 16);
            // Do not AddChild here, let the caller do it
            return textElement;
        }

        // Keep text helpers for toggle buttons
        private string GetAntialiasButtonText() => $"{(SkiaFontManager.UseAntialias ? "禁用" : "启用")}";
        private string GetSubpixelButtonText() => $"{(SkiaFontManager.UseSubpixelText ? "禁用" : "启用")}";


    }
}