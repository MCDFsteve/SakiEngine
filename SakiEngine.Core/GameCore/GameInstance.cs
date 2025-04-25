using Microsoft.Xna.Framework;
using Microsoft.Xna.Framework.Graphics;
using SakiEngine.Core.MenuSystem;
using SakiEngine.Core.SceneGraph;
using SakiEngine.Core.Text;
using SakiEngine.Core.UI;
using System;
using System.IO;
using System.Collections.Generic; // For List

namespace SakiEngine.Core.GameCore
{
    /// <summary>
    /// 游戏实例核心，管理游戏的生命周期和关键模块
    /// </summary>
    public class GameInstance : Game
    {
        // 单例实例
        public static GameInstance Instance { get; private set; } = null!;
        
        // --- 新增：内部渲染分辨率 ---
        public const int InternalWidth = 2560;
        public const int InternalHeight = 1440;
        public const float ReferenceHeight = 720f; // 基准高度，用于字体大小计算
        private RenderTarget2D _internalRenderTarget = null!;
        // -------------------------
        
        // 核心组件
        private GraphicsDeviceManager _graphics;
        private SpriteBatch _spriteBatch = null!;
        
        // 管理器
        private ResolutionManager _resolutionManager = null!;
        private MenuManager _menuManager = null!;
        
        // --- 新增: 暴露 GraphicsDeviceManager ---
        public GraphicsDeviceManager GraphicsDeviceManager => _graphics;
        // ------------------------------------
        
        // 字体系统
        private SkiaFontManager _skiaFontManager = null!;
        private SkiaTextRenderer _skiaTextRenderer = null!;
        
        // 通用资源
        private Texture2D _whitePixelTexture = null!;
        
        /// <summary>
        /// 分辨率管理器
        /// </summary>
        public ResolutionManager ResolutionManager => _resolutionManager;
        
        /// <summary>
        /// 菜单管理器
        /// </summary>
        public MenuManager MenuManager => _menuManager;
        
        /// <summary>
        /// Skia 字体管理器
        /// </summary>
        public SkiaFontManager FontManager => _skiaFontManager;
        
        /// <summary>
        /// Skia 文本渲染器
        /// </summary>
        public SkiaTextRenderer TextRenderer => _skiaTextRenderer;
        
        /// <summary>
        /// 白色像素纹理，用于绘制形状
        /// </summary>
        public Texture2D WhitePixelTexture => _whitePixelTexture;
        
        // --- 新增：文本绘制采样器状态 ---
        public static SamplerState CurrentTextSamplerState { get; set; } = SamplerState.LinearClamp;
        // -------------------------------
        
        // +++ Overlay Drawing Mechanism +++
        private readonly List<Action<SpriteBatch, int, int>> _overlayDrawActions = new();
        private readonly object _overlayLock = new object(); // Lock for thread safety if needed
        // +++ End Overlay Drawing Mechanism +++
        
        /// <summary>
        /// 构造函数
        /// </summary>
        public GameInstance()
        {
            Instance = this;
            _graphics = new GraphicsDeviceManager(this);
            Content.RootDirectory = "Content";
            IsMouseVisible = true;
        }
        
        /// <summary>
        /// 初始化游戏
        /// </summary>
        protected override void Initialize()
        {
            // 初始化分辨率管理器
            _resolutionManager = new ResolutionManager(this, _graphics);
            
            // 初始化菜单管理器
            _menuManager = new MenuManager();
            
            base.Initialize();
            
            // --- 重新添加：在 Initialize 之后创建 RenderTarget --- 
            _internalRenderTarget = new RenderTarget2D(
                GraphicsDevice,
                InternalWidth,
                InternalHeight,
                false, // Mipmap
                GraphicsDevice.PresentationParameters.BackBufferFormat,
                DepthFormat.None,
                0, // PreferMultiSampling > 0 ? GraphicsDevice.PresentationParameters.MultiSampleCount : 0,
                RenderTargetUsage.PreserveContents
            );
            // --------------------------------------------------
        }
        
        /// <summary>
        /// 加载游戏内容
        /// </summary>
        protected override void LoadContent()
        {
            _spriteBatch = new SpriteBatch(GraphicsDevice);
            
            // 创建白色像素纹理
            _whitePixelTexture = new Texture2D(GraphicsDevice, 1, 1);
            _whitePixelTexture.SetData(new[] { Color.White });
            
            // 获取字体目录路径
            string fontBasePath = Path.Combine(
                AppDomain.CurrentDomain.BaseDirectory, 
                "ContentRaw", "Fonts"
            );
            
            // 检查字体目录是否存在
            if (!Directory.Exists(fontBasePath))
            {
                // 尝试查找开发环境中的字体目录
                fontBasePath = Path.Combine(
                    AppDomain.CurrentDomain.BaseDirectory, 
                    "..", "..", "..", "..", 
                    "ContentRaw", "Fonts"
                );
                
                if (!Directory.Exists(fontBasePath))
                {
                    // 最后尝试创建目录
                    try {
                        Directory.CreateDirectory(fontBasePath);
                        Console.WriteLine($"已创建字体目录: {fontBasePath}");
                        
                        // 如果原始ContentRaw/Fonts目录存在，复制字体文件
                        string sourceDir = Path.Combine(
                            AppDomain.CurrentDomain.BaseDirectory,
                            "..", "..", "..", "..",
                            "ContentRaw", "Fonts"
                        );
                        
                        if (Directory.Exists(sourceDir))
                        {
                            foreach (var file in Directory.GetFiles(sourceDir))
                            {
                                string fileName = Path.GetFileName(file);
                                File.Copy(file, Path.Combine(fontBasePath, fileName), true);
                                Console.WriteLine($"已复制字体文件: {fileName}");
                            }
                        }
                    }
                    catch (Exception ex) {
                        Console.WriteLine($"创建字体目录失败: {ex.Message}");
                    }
                }
            }
            
            // 确保目录存在
            try
            {
                // 检查默认字体文件是否存在 (现在是 SourceHanSansCN-Medium.ttf)
                string defaultFontPathTTF = Path.Combine(fontBasePath, "SourceHanSansCN-Medium.ttf");
                // string defaultFontPathOTF = Path.Combine(fontBasePath, "SourceHanSansSC-Regular.otf"); // REMOVED
                
                // 只检查新的 TTF 文件
                if (!File.Exists(defaultFontPathTTF))
                {
                    Console.WriteLine($"默认字体文件 'SourceHanSansCN-Medium.ttf' 不存在，将使用系统默认字体");
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"处理字体目录时出错: {ex.Message}");
            }
            
            // 初始化 Skia 字体系统
            _skiaFontManager = new SkiaFontManager(GraphicsDevice, fontBasePath);
            _skiaTextRenderer = new SkiaTextRenderer(GraphicsDevice, _skiaFontManager);
        }
        
        /// <summary>
        /// 更新游戏逻辑
        /// </summary>
        protected override void Update(GameTime gameTime)
        {
            // 更新菜单系统
            _menuManager.Update(gameTime);
            
            base.Update(gameTime);
        }
        
        /// <summary>
        /// Registers an action to be drawn after the main UI pass, typically for overlays like dropdown lists.
        /// </summary>
        /// <param name="drawAction">The action taking SpriteBatch, internal width, and internal height.</param>
        public void RegisterOverlayDraw(Action<SpriteBatch, int, int> drawAction)
        {
            lock (_overlayLock)
            {
                 _overlayDrawActions.Add(drawAction);
            }
        }

        /// <summary>
        /// Executes and clears the registered overlay draw actions.
        /// </summary>
        private void DrawOverlays(SpriteBatch spriteBatch, int screenWidth, int screenHeight)
        {
             List<Action<SpriteBatch, int, int>> actionsToRun; // Local list to avoid holding lock during execution
            lock (_overlayLock)
            {
                if (_overlayDrawActions.Count == 0) return;
                actionsToRun = new List<Action<SpriteBatch, int, int>>(_overlayDrawActions); // Copy actions
                _overlayDrawActions.Clear(); // Clear original list
            }
            
            // Execute actions outside the lock
            foreach (var action in actionsToRun)
            {
                 try { action?.Invoke(spriteBatch, screenWidth, screenHeight); }
                 catch (Exception ex) { Console.WriteLine($"[GameInstance] Error executing overlay draw action: {ex.Message}"); }
            }
        }
        
        /// <summary>
        /// 绘制游戏 (Render Target 模式)
        /// </summary>
        protected override void Draw(GameTime gameTime)
        {
            // --- 1. 渲染到内部 Render Target ---
            GraphicsDevice.SetRenderTarget(_internalRenderTarget);
            GraphicsDevice.Clear(Color.Black);

            // Begin SpriteBatch for main UI rendering
            _spriteBatch.Begin(
                SpriteSortMode.Deferred,
                BlendState.AlphaBlend,
                CurrentTextSamplerState,
                DepthStencilState.None,
                RasterizerState.CullCounterClockwise
            );

            // Draw the menu system (which draws its elements)
            _menuManager.Draw(_spriteBatch, InternalWidth, InternalHeight);
            
             // --- ADDED: Execute Overlay Draw Actions within the same batch/target ---
             DrawOverlays(_spriteBatch, InternalWidth, InternalHeight);
             // --- END ADDED ---

            // End the main SpriteBatch
            _spriteBatch.End();

            // --- 2. 将内部 Render Target 绘制到屏幕 ---
            GraphicsDevice.SetRenderTarget(null);
            GraphicsDevice.Clear(Color.Black);

            Rectangle destinationRectangle = ResolutionManager.GetOutputDestinationRectangle();

            _spriteBatch.Begin(
                SpriteSortMode.Immediate, 
                BlendState.Opaque,
                SamplerState.LinearClamp,
                DepthStencilState.None,
                RasterizerState.CullCounterClockwise
            );
            
            _spriteBatch.Draw(
                _internalRenderTarget,
                destinationRectangle,
                Color.White
            );

            _spriteBatch.End();
            
            // base.Draw(gameTime); // Base draw is likely not needed now
        }
        
        /// <summary>
        /// 释放资源
        /// </summary>
        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                _skiaFontManager?.Dispose();
                _whitePixelTexture?.Dispose();
            }
            
            base.Dispose(disposing);
        }
    }
} 