# SakiEngine 开发启动器

该目录是 SakiEngine 的图形化启动器（Flutter 项目），用于替代根目录 `run.sh/build.sh` 的主要交互流程。

## 主要功能

- 扫描 `Game/*` 并选择默认项目
- GUI 创建新项目（非交互桥接 `scripts/create-new-project.js`）
- 运行项目（支持内置控制台和系统终端两种模式）
- 发布构建（构建前自动执行 `flutter clean`，再进行 `.sks` 预编译与发布资源清单生成）

## 启动方式

推荐在仓库根目录执行：

```bash
./saki.sh

# 直启指定项目（跳过 Launcher UI）
./saki.sh SakiEngine
./saki.sh <项目名>
```

Windows:

```bat
saki.bat
saki.bat SakiEngine
saki.bat <项目名>
```

首次运行会自动引导工具链：

- 系统已安装 Flutter/Node.js 时直接使用系统环境
- 系统缺失时自动下载到仓库内 `.saki_toolchain/` 并继续启动

脚本说明：

- `saki.sh / saki.bat` 仅负责入口转发
- 业务逻辑集中在 `tool/saki_cli.js`（跨平台）
