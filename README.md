# SakiEngine 演示项目

这是一个使用 SakiEngine 框架构建的演示项目，展示了其核心功能，包括 UI 系统、菜单管理和使用 SkiaSharp 进行的高级文本渲染。

## 功能特性

*   **菜单系统:** 包含主菜单和设置菜单。
*   **UI 元素:** 演示了按钮 (`Button`)、下拉菜单 (`Dropdown`) 和文本元素 (`SkiaTextElement`) 的使用。
*   **设置:**
    *   **显示模式:** 可在窗口化和全屏模式之间切换。
    *   **分辨率:** 在窗口化模式下可选择不同的屏幕分辨率。
    *   **渲染参数:** 调整字体缩放、纹理采样模式和字体微调（Hinting）。
    *   **文本渲染选项:** 启用/禁用抗锯齿和子像素渲染。
*   **配置持久化:** 游戏设置（分辨率、显示模式、渲染选项等）会自动保存到用户目录下的配置文件中。
*   **文本渲染:** 使用 SkiaSharp 实现高质量、可缩放的文本渲染。

## 技术栈

*   **游戏框架:** [MonoGame](https://www.monogame.net/)
*   **文本渲染:** [SkiaSharp](https://github.com/mono/SkiaSharp)
*   **语言:** C#
*   **平台:** .NET

## 如何运行

1.  **确保安装了 .NET SDK:** 您需要安装适用于您操作系统的 .NET SDK (推荐 .NET 6 或更高版本)。您可以从 [官方 .NET 网站](https://dotnet.microsoft.com/download) 下载。
2.  **克隆仓库 (如果尚未完成):**
    ```bash
    git clone <repository-url>
    cd SakiEngine # 或者您的项目根目录
    ```
3.  **运行项目:**
    在项目根目录下打开终端或命令行，然后执行以下命令：
    ```bash
    dotnet run --project SakiEngine.Launch
    ```
    这将构建并启动 `SakiEngine.Launch` 项目。

## 配置文件

游戏设置会自动保存到以下位置的一个 `settings.bin` 文件中：

*   **Windows:** `%APPDATA%\AimesSoft_SakiEngine\settings.bin`
*   **macOS:** `~/Library/Application Support/AimesSoft_SakiEngine/settings.bin`
*   **Linux:** `~/.config/AimesSoft_SakiEngine/settings.bin` (或 `$XDG_CONFIG_HOME/AimesSoft_SakiEngine/settings.bin`)

您可以删除此文件以恢复默认设置。

## 项目结构 (简要)

*   `SakiEngine.Core/`: 包含引擎的核心组件，如游戏实例 (`GameInstance`)、场景图 (`SceneGraph`)、UI 元素 (`UI`)、文本渲染 (`Text`) 等。
*   `SakiEngine.Launch/`: 包含游戏启动逻辑 (`Game1.cs`) 和特定于此演示的菜单 (`Menus`)。
*   `Content/`: 包含游戏资源，如字体文件。 