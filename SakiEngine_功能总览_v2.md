

SakiEngine 功能总览与技术蓝图

（最后更新：2025-04-28）

本文件汇总了此前所有讨论的功能需求与实现思路，供 Cursor 生成代码或团队成员阅读。
若无特别说明，所有源码均采用 Flutter 3.x + Dart 2.x 环境。

⸻

0. 命名与目标
	•	引擎：SakiEngine（取名自《来自新世界》女主角 早季 Saki）。
	•	首部作品：《引入新世界 / Use World::New;》。
	•	目标：在 Flutter 基础上做一款高性能、可扩展、Ren’Py 级易用的视觉小说引擎。

⸻

1. 解决方案目录结构

SakiEngine/
├─ SakiEngine.Core/          ← 引擎运行时（GameCore / Menu / Scene …）
├─ SakiEngine.Content/       ← 剧本脚本 + 资源（编译成 Dart 库）
├─ SakiEngine.Launch/          ← 可执行项目 / 启动器
├─ MiniGames/                ← 可选独立小游戏 Dart 插件
├─ ContentRaw/               ← png / wav / svg / mp4 等原素材
├─ ContentProcessed/         ← avif / ogg / webm(vp9+α) 产物
└─ build.ps1 / build.yml     ← CI & 资源转换脚本



⸻

2. 运行时模块

模块	主要职责
GameCore	Flutter 主循环，DI 容器
MenuSystem	栈式菜单（Overlay / Exclusive）+ 输入焦点
SceneGraph / RenderScheduler	可视对象树 + 层排序 + 预合成
ScriptRunner	Dart DSL，Label 跳转 / Call / Return
TweenManager	动画时间线与过渡管理
AudioEngine	OGG 播放、Seek、Loop、淡入淡出、Bus 替换
VideoEngine	VP9+α 透明视频，Seek / Loop / 倍速 / 倒放
LocaleManager	多语言表 + 运行时热切换 + Glyph 替换
VarStore / Var<T>	全局/局部/持久变量
SaveManager	帧快照环 + MessagePack 存档
InputRouter	ActionId ↔ 物理输入；设备热插拔 & UI 更新
CursorManager	自定义光标（支持 SVG / 动画 / Tween）



⸻

3. 渲染层与分辨率
	•	固定 16∶9：1280×720 / 1600×900 / 1920×1080，窗口不可自由拉伸。
	•	UIRectN 归一化坐标：所有对象位置、大小用 0‑1 百分比；ScaleN 可单独拉伸。
	•	图层号 LayerId:int：任何对象（角色 / 背景 / 菜单 / Cursor）都可自由设层。
	•	高斯模糊：字段 BlurRadius，可 tween，可作用于对象或整层。
	•	SVG：运行时使用 Svg.Skia 按需栅格化；release 可提前 bake 到 Avif。

⸻

4. 资源转换流水线（build.ps1）

类型	原扩展	目标扩展	命令（增量执行）
图片	png／jpg	avif(Q100)	magick $in -quality 100 $out
音频	wav／flac	ogg(q5)	ffmpeg -i $in -c:a libvorbis -qscale 5 $out
视频	mp4／mov	webm(vp9+α)	ffmpeg -i $in -c:v libvpx-vp9 -pix_fmt yuva420p -lossless 1 $out

	•	若目标文件已存在且魔数正确、时间戳 ≥ 源文件 ⇒ 跳过转码。
	•	生成 Content.manifest.json：逻辑 ID（无后缀）→ 实际文件。

⸻

5. 脚本 DSL 核心示例

Script.create()
      .label("start")
      .background("bg_room_day")
      .show("alice_happy", layer:0)
      .say("早季", "<b>早上好！</b><pause=0.3/>准备好了？")
      .choice(("出门","go_out"), ("继续睡","sleep"))
      .jump("end");

	•	标签跨多个 .dart 文件，由 [SakiLabel] 自动注册。
	•	Look‑ahead 5 条命令自动预取资源；手动 .preload(...) 可强制加载。

⸻

6. 富文本 & Typewriter
	•	BBCode 子集 + 自定义：<b> <i> <color> <wave> <ruby> <speed> <pause>…
	•	逐字显示，自动对中文标点做 150 ms 逗号 / 300 ms 句号 停顿。
	•	Typewriter 事件流：BeginSentence • Comma • PauseCustom • EndSentence
→ 可驱动 语音播放 / Live2D 嘴形。

⸻

7. 动画系统
	•	AnimationClip + 多种 Track（位置、旋转、缩放、模糊、透明）。
	•	SequenceClip / ParallelClip 任意嵌套。
	•	Tween 语法糖：.TweenMove() .TweenBlur() .Animate("fadeIn").

⸻

8. 音频 & 视频高级功能

能力	AudioEngine	VideoEngine
循环 & 无穷	✓	✓
Seek / GetPos	✓	✓
倍速 / 倒放	✓	✓ (跳帧)
淡入淡出 / 替换	✓	—
指针持久化到存档	✓	✓



⸻

9. 存档系统
	•	开发期：JSON；发行版：Magic+Ver | MessagePack(LZ4) | CRC32。
	•	每行对白生成 Frame‑Snapshot：
	1.	SceneGraph 差量
	2.	ActiveMediaList (id+pos+loops)
	3.	VM 指针与 Var 增量
	•	存档保留最近 N（默认 20）帧快照，读档/回滚秒级恢复。

⸻

10. 变量系统

Var<int>("coins", 0, persistent:true).value += 5;
Var<String>("temp", scope:VarScope.LocalScript).value = "foo";

作用域：Global / LocalScript / Scene；加 persistent:true 自动入存档。

⸻

11. 输入抽象 & UI 热切换
	•	ActionId ←→ 物理按键 / 手柄按钮 / 触摸手势（InputMap).
	•	InputRouter 检测设备变动 → 触发 OnDeviceChanged 事件：
	•	UI 控件实现 IInputAware.refreshInputGlyph() → 图标瞬换。
	•	自定义按键存 bindings_user.json，热重载即生效。

⸻

12. 自定义 Cursor

CursorManager.set("ui/cursor_arrow.svg", hotspotN:(0.1,0.05));
CursorManager.push("ui/cursor_hand"); … CursorManager.pop();

光标是 CursorTrack : SceneObject，支持层级、Tween、模糊、动画。

⸻

13. MiniGame 插件
	•	Dart 插件实现 IGameModule（initialize/update/draw/dispose）。
	•	MiniGameHostMenu 加载并包在菜单栈中；输入独立。
	•	Dev 可用 Dart 热加载；正式版走预编译 Dart 库。

⸻

14. 本地化流程
	1.	编剧在脚本中直接写 中文原文。
	2.	loc-extract 导出 loc_master.csv（hash→zh）。
	3.	译者填 en / ja 列。
	4.	loc-compile → Lang_xx.dart（Release）或 CSV 热加载（Debug）。
	5.	运行时 LocaleManager.set("ja") 即刻刷新 UI / 对话 / Glyph 图标。

⸻

15. 调试功能
	•	F9：FPS / DrawCall / VRAM / VarStore / 输入栈 / 媒体列表。
	•	F11：手动循环输入设备（强测 UI 切换）。
	•	文件修改自动热重载：脚本 Dart 库 / CSV / Raw 资源。

⸻

16. 构建依赖

工具	用途
Flutter 3.x SDK	编译
Dart 2.x	渲染
FFmpeg 6.x	OGG / VP9 转码
ImageMagick 7.x	PNG → AVIF
Svg.Skia	SVG 栅格
MessagePack-CSharp 2.x	存档
Roslyn Scripting	Dev 小游戏



⸻

17. 下一步（Cursor TODO 快查）
	1.	SvgRenderer + UIRectN 完整实施
	2.	Typewriter rich-text + Beat 事件
	3.	AudioEngine.Seek & VideoEngine.Seek + 持久化
	4.	VarStore & Save 集成
	5.	InputRouter Glyph 热切换
	6.	MiniGameHostMenu & IGameModule 接口
	7.	build.ps1 转码增量&魔数检测

完成这些即可达到我们讨论的“近乎完美”的功能范围。
Enjoy coding!