# SakiEngine

## 基于Flutter开发的视觉小说游戏引擎

### 项目截图

#### 主界面

![主界面](Git/main.png)

#### 对话系统

![对话系统](Git/dialog.png)

#### 历史记录

![历史记录](Git/history.png)

#### 对话场景

![对话场景](Git/say.png)

### 项目简介

SakiEngine 是一个基于 Flutter 的现代化视觉小说游戏引擎，专为跨平台游戏开发而设计。

### 主要特性

- **类Renpy语法**：使用类似Renpy的脚本语法，降低游戏开发门槛
- **自适应窗口**：游戏窗口可以自由拉伸，画面智能适配
- **低性能占用**：轻量级引擎，确保流畅的游戏体验
- **强大的UI系统**：丰富的界面控件和交互支持
- **模块化系统**：支持项目特定的自定义模块，实现个性化定制
- **真正的跨平台**：支持多个主流平台
  - Windows
  - Linux
  - macOS
  - Android
  - iOS

### 开发状态

项目目前处于积极开发中。主要功能已经实现，正在持续优化和完善：

- [X]  基础对话系统
- [X]  角色立绘支持
- [X]  场景管理
- [X]  多平台适配
- [X]  对话记录系统
- [X]  回滚系统
- [X]  选择分支系统
- [X]  存档和读档系统
- [X]  项目模块化系统
- [X]  自动项目创建工具
- [X]  音乐、音效和语音系统
- [X]  场景切换效果
- [X]  转场动画
- [X]  脚本内持久化变量设置
- [ ]  更多高级脚本特性
- [ ]  性能进一步优化
- [ ]  更多平台细节适配

### 特色功能

- [X]  自动角色站位，多角色会自动分配位置
- [X]  自动对话框震动，检测到感叹号字符会自动震动
- [X]  自带普通旁白和电影旁白，电影旁白会有上下黑边
- [X]  有单独的存档格式.sakisav，市面已存在的反编译工具目前无法直接支持
- [X]  支持切换深色/浅色模式，就像app一样改变UI的色调
- [X]  随意拉伸窗口，内部画面会自适应
- [X]  无限个存档位
- [X]  支持直接播放webp动图

### 部署指南

#### 前提条件

- 安装 Flutter SDK（建议使用最新稳定版）
- 配置相应平台的开发环境（Android Studio、Xcode等）

#### 快速开始

##### 开发环境启动（推荐）

克隆仓库后，在根目录执行以下单命令即可进入启动器：

```bash
# macOS/Linux 启动器
./saki.sh

# Windows 启动器
saki.bat

# 跳过启动器，直接启动指定游戏（示例项目）
./saki.sh SakiEngine
saki.bat SakiEngine

# 其他项目（项目名=Game 目录名）
./saki.sh <项目名>
saki.bat <项目名>
```

首次运行时，脚本会自动执行工具链引导：

- 若系统已安装 Flutter/Node.js：直接使用系统工具链
- 若系统缺失：自动下载到本仓库 `.saki_toolchain/` 并继续启动
- 后续运行会复用已下载内容

默认缓存目录：

- `tool/toolchain_cache/flutter/`
- `tool/toolchain_cache/node/`

当前脚本架构：

- `saki.sh / saki.bat / run.sh / build.sh` 仅做入口转发
- 核心运行/构建逻辑统一在 JS（`tool/saki_cli.js`、`scripts/build.js`、`run.js` 等）
- 后续新增功能优先只改 JS 一套逻辑

也可以直接使用统一 CLI：

```bash
node tool/saki_cli.js saki [项目名]
node tool/saki_cli.js run
node tool/saki_cli.js build [项目名|平台] [平台]
```

启动器（`Launcher/`）当前已覆盖：

- 检测您的操作系统（macOS/Linux/Windows）
- 扫描可用的游戏项目
- GUI 创建新项目（替代 `scripts/create_new_project.sh` 交互）
- 设置默认游戏项目（写入 `default_game.txt`）
- 在程序内执行 `run.sh/build.sh` 对应的核心流程（含日志输出）
- 运行模式可切换为 `内置控制台` / `系统终端`（系统终端模式更适合 `flutter run` 热重载）

##### 兼容旧脚本入口

```bash
# 旧版 shell 启动方式（仍可用）
./run.sh

# Node 版本（跨平台）
node run.js
```

##### 手动方式（项目内直接运行）

1. 进入目标游戏目录（示例：`SakiEngine`）

```bash
cd Game/SakiEngine
```

2. 获取依赖并运行

```bash
flutter pub get
flutter run -d macos --dart-define=SAKI_GAME_PATH="$PWD"
```

#### 构建发布版

#### GitHub Action 触发规则

- 仅支持**独立游戏项目仓库**触发编译（仓库根目录需包含 `pubspec.yaml` 与 `Assets/`）
- 仅在 `push -> main` 且**提交信息包含 `[build]`** 时触发构建发布
- 默认执行全平台构建（Android / iOS / macOS / Windows / Linux），并发布 Release
- 发布成功后会自动执行版本号 `patch` 递增
- 不带 `[build]` 的提交不会触发构建
- 如果仓库不是独立游戏项目仓库，流程会自动跳过构建/发布

#### macOS 单机交叉构建桌面发布版

SakiEngine 的命令行和 Launcher 支持在一台 macOS 设备上生成三种桌面发布包：

- macOS：使用 Flutter/Xcode 原生构建。
- Linux x64：使用仓库内置 Linux Runner、原生插件和 macOS AOT snapshotter。
- Windows x64：使用仓库内置 Windows Runner、原生插件和 macOS AOT snapshotter。

Linux/Windows 交叉构建不会下载目标 Runner、Flutter Embedder、插件 DLL/SO 或 Erika
运行库；缺少文件或 SHA-256 不匹配时会直接失败。Erika 的 C API 产物随目标包进入仓库；
维护者也可在目标包工作流勾选 `erika_source_build`，使用 Erika 自身的 target/profile
交叉构建链从源码重建。构建机仍需预先具备清单指定的 Flutter SDK 和已经解析好的 Dart
依赖，目标包会严格检查 Flutter Engine revision，不能混用其他 Flutter 版本。

当前内置目标包架构为 Linux x64 和 Windows x64。游戏若新增桌面原生插件，构建器会拒绝
复用旧 Runner，并提示维护者重新运行
`.github/workflows/build-cross-target-packs.yml`，避免生成启动后缺插件的静默坏包。

命令行示例：

```bash
# 以下三条命令均可在 macOS 上执行
./build.sh SakiEngine macos
./build.sh SakiEngine linux
./build.sh SakiEngine windows
```

Launcher 在 macOS 上也会同时显示 macOS、Linux、Windows；Linux/Windows 自动进入离线
交叉编译路径，输出位置与 Flutter 原生构建保持一致：

- `Game/<项目>/build/linux/x64/release/bundle`
- `Game/<项目>/build/windows/x64/runner/Release`

#### 本地构建

```bash
# 方式1：交互选择游戏项目 + 目标平台
./build.sh

# 方式2：指定平台（项目默认使用 default_game.txt，可在交互中切换）
./build.sh macos

# 方式3：指定游戏项目 + 平台
./build.sh SakiEngine macos
```

`build.sh` 会直接在 `Game/<项目>` 目录构建，不再修改 `Engine/pubspec.yaml`。发布构建时会先将 `.sks` 预编译到 `Game/<项目>/.saki_cache/`（隐藏缓存目录，不提交 Git），并自动排除 `GameScript*` 原始脚本资源打包。

#### 资源单包（SakiPack）

发布构建流程会自动执行资源打包，生成：

- `Game/<项目>/.saki_cache/game.sakipak`

该文件会合并 `Assets/` 与 `GameScript*` 下的资源（以及 `default_game.txt`）为单个二进制包。  
运行时引擎会优先从 `game.sakipak` 读取文本/图片资源；音频与视频会按需解包到临时文件后播放，对上层脚本仍保持原有虚拟路径（`Assets/...`）不变。

调试模式（桌面 Debug）仍默认走文件系统直读，便于热更新与排查问题。

#### Windows 用户注意事项

Windows 推荐直接使用：

```bat
saki.bat
```

为避免新电脑首次构建时 `media_kit` 下载失败（`mpv-dev*.7z` 校验问题），建议先执行：

```bat
tool\cache_media_kit_windows_deps.bat
```

该命令会把 Windows 依赖缓存到：

`third_party\media_kit_libs_windows_video_hotfix\prebuilt\`

然后再运行 `saki.bat <项目名>` 即可优先使用本地缓存，不依赖构建阶段在线下载。

如果需要继续使用 shell 脚本，可使用以下方式之一：

1. **Git Bash**（推荐）

   - 安装 Git for Windows 后自带
   - 右键选择 "Git Bash Here" 然后运行 `./run.sh`
2. **WSL (Windows Subsystem for Linux)**

   - 在 Microsoft Store 安装 Ubuntu 或其他 Linux 发行版
   - 在 WSL 终端中运行脚本
3. **PowerShell + bash**

   - 如果安装了 Git Bash，可在 PowerShell 中运行：`bash ./run.sh`

#### 分发打包（含工具链与 media_kit 依赖）

可执行：

```bash
./tool/package_distribution.sh
```

该脚本会生成：

- 分发目录：`dist/SakiEngine-distribution-时间戳/SakiEngine/`
- 分发压缩包：`dist/SakiEngine-distribution-时间戳/SakiEngine-distribution-时间戳.zip`

并自动拉取并打包：

- Flutter stable（Windows / Linux / macOS）
- Node.js LTS（Windows-x64 / Linux-x64 / macOS-x64 / macOS-arm64）
- media_kit Windows 预置依赖（`mpv-dev*.7z` + `ANGLE.7z`）

#### 项目结构

```
SakiEngine/
├── saki.sh             # Launcher 单入口（macOS/Linux）
├── saki.bat            # Launcher 单入口（Windows）
├── run.sh              # 统一启动脚本（跨平台）
├── build.sh            # 发布构建脚本（支持交互选择项目/平台）
├── default_game.txt    # 默认游戏配置文件
├── Launcher/           # SakiEngine 图形化启动器（Flutter 项目）
├── scripts/            # 工具脚本目录
│   ├── select_game.sh       # 游戏项目选择器
│   ├── create_new_project.sh # 新项目创建工具
│   ├── run_legacy_macos.sh  # 传统macOS启动脚本
│   └── ...                  # 其他工具脚本
├── Engine/             # Flutter引擎主目录
│   ├── lib/           # 引擎源码（作为 Flutter package 被引用）
│   │   ├── src/       # 引擎核心代码（仅通用能力）
│   │   ├── sakiengine.dart # 对外 API（runSakiEngine/registerProjectModule）
│   │   └── main.dart  # 兼容入口（内部调用 runSakiEngine）
│   └── pubspec.yaml   # 依赖配置
└── Game/              # 游戏项目目录
    ├── SakiEngine/    # 轻量演示项目
    └── YourGame/      # 您的游戏项目（建议独立仓库，按需克隆到此目录）
```

### 新项目创建

SakiEngine 提供了便捷的项目创建工具，可以快速搭建新的视觉小说项目：

#### 创建新项目

```bash
./scripts/create_new_project.sh
```

**创建工具会自动：**

- 创建完整的项目目录结构
- 生成基础的配置文件（角色、姿势、系统配置）
- 创建示例剧情脚本
- 生成 `ProjectCode` 项目代码包（项目逻辑不写入引擎）
- 创建完整 Flutter 项目骨架（`Game/<项目>/pubspec.yaml`、`lib/main.dart`、平台目录）
- 配置主题颜色和Bundle ID
- 配置对引擎包 `../../Engine` 的依赖
- 生成项目级 CI 文件（`.github/workflows`）与项目内 `build.sh`

#### 项目模块化系统

每个新项目都会自动创建对应的Flutter模块，支持：

- **自定义主题**：项目特有的颜色、字体、界面风格
- **自定义界面**：主菜单、游戏界面、存档界面等
- **项目配置**：特殊的引擎参数和功能开关
- **智能回退**：未自定义的组件自动使用引擎默认实现

项目模块位置：`Game/项目名/ProjectCode/lib/项目名小写/项目名_module.dart`
项目入口：`Game/项目名/lib/main.dart`

#### 快速开始新项目

1. **创建项目**

```bash
./scripts/create_new_project.sh
```

2. **选择并运行**

```bash
./run.sh  # 选择新创建的项目
```

3. **自定义项目模块**

```bash
# 编辑项目模块文件
Game/yourproject/ProjectCode/lib/yourproject/yourproject_module.dart
```

### VSCode 语法高亮插件

项目根目录包含一个专门为 SakiEngine 开发的 VSCode 语法高亮插件 `vscode-sakiengine-syntax`，支持以下文件类型的语法高亮：

- `.sks` - 剧本文件 (Script Files)
- `.sks` - 配置文件 (Configuration Files)
- `.sks` - 坐标管理文件 (Position Management Files)
- `.sks` - 角色定义文件 (Character Definition Files)

#### 安装方法

1. 在 VSCode 中打开扩展视图
2. 选择 "从 VSIX 安装"
3. 导航到项目根目录下的 `vscode-sakiengine-syntax` 文件夹
4. 选择最新版本的 `.vsix` 文件进行安装

通过这个插件，你可以获得更好的代码编辑体验，包括语法高亮、代码着色等功能，让脚本编写更加直观和高效。

### 脚本语法示例

SakiEngine 使用 `.sks` 脚本文件，语法简单直观，类似 Renpy，但更加简洁：

```sks
// 开始标签
label start
// 设置背景场景
scene bg school 

// 角色对话（角色标识 姿势 表情 对话）
yk pose2 happy "欢迎来到SakiEngine！"

// 选择菜单
menu
"给她巧克力" choice_chocolate
"保持沉默" choice_silence
"表情测试" choice_expressions
endmenu

// 巧克力选项
label choice_chocolate
yk "呀，谢谢！"
"嘿嘿，喜欢吗？"
yk happy "当然喜欢！"
return

// 沉默选项
label choice_silence
yk sad "你怎么不说话？"
yk "不理你了。"
return

// 表情变化
label choice_expressions
yk pose1 "这是不同的姿势和表情"
yk happy "开心的表情"
yk sad "难过的表情"
return
```

### 脚本内嵌多语言

SakiEngine 支持在同一条 `""` 文本中写多语言片段，运行时只显示当前语言对应内容：

```sks
yk "/zhs 你好/ /zhc 你好呀/ /jp こんにちは/ /en Hello/"
```

也支持“已有文本 + 新增语言片段”的渐进写法（默认语言文本无需立刻包 `/zhs.../`）：

```sks
yk "你好 /en Hello/"
```

默认脚本语言可在 `GameScript/configs/configs.sks` 中设置：

```sks
script_default_language: zhs // zhs / zhc / en / jp
```

说明：
- 对 `.sks` 中所有 `""` 包裹文本生效（如对话、`menu` 选项、角色配置显示名等）
- 推荐语法是 `/tag 文本/ /tag 文本/`；写成紧贴的 `...//tag .../` 也会被兼容解析
- 如果当前语言缺失对应片段，会按默认脚本语言回退
- 不含语言标记的旧文本会保持原样显示（兼容旧项目）

### 图像绘制语法

SakiEngine 支持五种主要的图像显示方式：

#### 场景背景 (scene)

```sks
// 显示背景图片，自动铺满窗口
scene bg school          // 显示学校背景，铺满整个窗口
scene bg sunset_beach    // 显示夕阳海滩背景，自动缩放适配
```

#### 角色立绘 (show)

```sks
// 显示角色立绘，自动调节窗口内站位
show yk pose1 happy      // 显示yk角色，引擎自动分配站位
show alice pose2 sad     // 显示alice角色，自动与其他角色协调位置
show character          // 多角色同时显示时自动分配最佳站位
```

#### 动画效果 (anime)

```sks
// 播放WebP动图，自动铺满窗口，默认播放一次后消失
anime flash_effect       // 播放闪光动画，播放完自动消失
anime explosion          // 播放爆炸效果，默认一次性播放

// 使用参数控制播放行为
anime rain keep          // 播放雨滴动画，播放完后保持显示
anime fire loop          // 播放火焰动画，循环播放不停止
anime magic keep loop    // 播放魔法效果，循环播放且保持显示
```

#### 项目画布 (canvas)

```sks
// 显示项目模块注册的持续绘制效果；覆盖游戏画面，但不遮挡 UI
canvas pixel_rain

// 清除当前画布
hide canvas
```

项目通过 `GameModule.scriptCanvases` 注册画布 ID、显示名与绘制回调。Debug
模式下按 `Shift+V` 可打开画布预览/放置网格，双击把命令放到当前对话前。

#### CG插图 (cg)

```sks
// 显示CG图片，结合scene和show特性：铺满窗口 + 自动识别切换
cg ending_kiss          // 显示CG，自动铺满窗口
cg battle_scene         // CG会自动识别和切换到对应场景
cg romantic_moment      // 支持CG之间的自动过渡和识别
```

### 文本标签语法

SakiEngine 支持在对话文本中使用特殊标签来控制显示效果：

#### 等待标签 [w]

```sks
// 在指定位置暂停文字显示
yk "你好...[w=1]我是小雪。"        // 在省略号后暂停1秒
alice "等等[w=5]让我想想..."       // 在"等等"后暂停5秒文字显示
```

#### 文字大小标签 [size]

```sks
// 改变文字大小
"这是[size=1.3]大字[/size]和正常字。"     // 显示大字
"[size=0.8]小字提示[/size]正常对话"       // 显示小字
"[size=1.5]重要提醒！[/size]"             // 显示更大的字
```

#### 快进标签 [pass]

```sks
// 跳过打字机效果，瞬间显示文字
"[pass]这段文字会瞬间显示出来！[/pass]"          // 整句瞬间显示
"正常显示[pass]后面瞬间显示[/pass]"             // 部分瞬间显示
```

### 转场效果语法

SakiEngine 支持多种场景转场效果，使用 `with 转场类型` 语法：

#### 淡入淡出 (fade)

```sks
// 黑屏淡入淡出转场，经典过渡效果
scene sky with fade           // 先淡出到黑屏，再淡入新场景
```

#### 溶解 (diss/dissolve)

```sks
// 图片直接渐变过渡，无黑屏阶段
scene home with diss          // 旧场景溶解到新场景
scene school with dissolve    // 支持 dissolve 别名
```

#### 擦除 (wipe)

```sks
// 旋转扇形擦除效果，适合时空转换
scene flashback with wipe     // 扇形旋转覆盖并显示新场景
```

#### 睁眼 (blink/eyeopen) ⭐ 新增

```sks
// 从黑屏睁眼显示场景，不会遮挡UI
scene bedroom with blink      // 适合醒来场景
scene reality with eyeopen    // 从梦境/回忆回到现实
scene world with eye          // 支持简写别名
```

**睁眼转场特点：**
- 🎬 从完全黑屏开始（已经闭眼状态）
- 👁️ 上下遮罩移开，逐渐显示新场景
- ✅ **不会遮挡UI**（对话框、菜单等保持可见）
- 💡 只有睁眼过程，没有闭眼过程

**睁眼转场适用场景：**
- 💤 角色从睡梦中醒来
- 👁️ 失去意识后恢复
- 🔄 从回忆/幻觉回到现实
- ⚡ 从黑屏过渡到新场景

#### 转场效果对比表

| 转场类型 | 关键词 | 视觉效果 | 是否遮挡UI | 适用场景 |
|---------|--------|---------|-----------|---------|
| 淡入淡出 | `fade` | 黑屏渐变 | ✅ 遮挡 | 通用场景切换 |
| 溶解 | `diss`, `dissolve` | 图片直接渐变 | ❌ 不遮挡 | 平滑的场景过渡 |
| 擦除 | `wipe` | 旋转扇形擦除 | ✅ 遮挡 | 时空转换、特效 |
| 睁眼 | `blink`, `eyeopen`, `eye` | 黑屏入，上下移开 | ❌ **不遮挡** | 醒来、恢复意识 |

### 语法特点

- **无需缩进**：所有命令都在同一级别
- **使用 `//` 注释**：支持单行注释说明
- **简单的角色对话语法**：角色名 + 可选姿势 + 可选表情 + 对话内容
- **灵活的图像控制**：支持背景、立绘、动画、CG等多种显示方式
- **富文本标签**：支持等待、大小、快进等文字效果
- **直观的选择菜单系统**：menu/endmenu 包围选择项

### 许可证

本项目使用开源许可证。详细信息请参见 LICENSE 文件。

### 示例游戏

引擎仓库内默认保留轻量演示项目 `Game/SakiEngine`。

《空之歌：每当磁针再次振动，我便在此等待》已迁移到独立仓库：
https://github.com/MCDFsteve/SoraNoUta-SakiEngine

可按需克隆到 `Game/` 目录并切换默认项目：

```bash
git clone https://github.com/MCDFsteve/SoraNoUta-SakiEngine.git Game/SoraNoUta
echo SoraNoUta > default_game.txt
```

### 贡献

欢迎提交 Issues 和 Pull Requests！
