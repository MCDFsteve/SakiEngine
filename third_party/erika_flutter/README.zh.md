# erika_flutter

[中文](README.zh.md) | [English](README.md) | [日本語](README.ja.md)

Erika 媒体播放引擎的 Flutter plugin。

插件让 Dart 不进入热路径：

- Dart 只暴露低频播放器命令和事件流。
- 原生插件提供两种 surface：推荐的 `ErikaWindowOverlayVideoView`（macOS/iOS/tvOS 为 Metal，Windows 为 D3D11 swapchain），以及 platform view 用的 `ErikaVideoView`。Android 上两者都通过同一套原生 view 选择器：SDR 使用真实 `TextureView`，请求 extended-linear 时使用 Hybrid Composition `SurfaceView`。
- macOS 插件加载 Erika 动态库。
- iOS 插件链接 Erika 静态库。
- tvOS 插件链接 Erika 静态库，并在 Apple TV platform view 中承载 Metal layer。
- Windows 插件构建并链接 Erika C ABI DLL。
- Android 插件按 ABI 构建 `liberika_capi.so`，并由 `Choreographer` 驱动原生 surface。
- HarmonyOS 插件注册 Flutter 外部纹理，把它的 `OHNativeWindow` attach 给 Erika，并用 OHAudio 做低延迟 PCM 输出。
- Erika 通过 `ErikaPresenterHandle` 负责播放、渲染、音频、时序和 overlay。

## Video Surfaces

全播放器 macOS/iOS/tvOS UI 推荐使用 `ErikaWindowOverlayVideoView`。它会在 Flutter 布局中预留矩形区域，同时插件在旁边托管一个原生 `CAMetalLayer`，让视频保持在 Flutter platform-view compositor 之外。

Windows 上 `ErikaWindowOverlayVideoView` 以 sibling surface 的形式托管一个 window-level Direct3D 11 swapchain，遵循同样的 overlay 模型。

需要标准 Flutter platform view 时则使用 `ErikaVideoView`。Android 的 SDR 视频 surface 是原生 `TextureView`；`ErikaOutputMode.extendedLinear` player 则通过 `PlatformViewLink`/Hybrid Composition 创建 `SurfaceView`，因为 scRGB 不能经过 Flutter texture-layer composition。插件把借用的 `Surface` 交给 Erika，并完整处理创建、resize、销毁、音频焦点、HDR eligibility 和 vsync tick。

## macOS Setup

macOS CocoaPods 构建默认生成 arm64+x86_64 universal 动态库。依赖项目可设置 `ERIKA_MACOS_ARCHS=arm64`、`ERIKA_MACOS_ARCHS=x86_64` 或 `ERIKA_MACOS_ARCHS=arm64,x86_64` 控制产物架构；`universal` 是默认值。预构建模式会对应下载 `macos-arm64`、`macos-x64` 或 `macos-universal` 包。本地开发时插件通过 `dlopen` 加载 Erika，也可设置 `ERIKA_CAPI_DYLIB` 覆盖运行时动态库路径。

构建动态库：

```sh
cargo run -p xtask -- deps build --all --profile lgpl
cargo build -p erika_capi
```

## 预构建包与源码构建

插件默认下载与当前版本对应的 `v0.1.7` 原生库，并校验 SHA-256。下载失败或校验不一致会明确报错，不会静默回退源码构建。只有在 Erika checkout 中调试源码时才设置 `ERIKA_FORCE_SOURCE_BUILD=1`。自定义 `ERIKA_PREBUILT_TAG` 时，单 ABI 构建须提供对应的 `ERIKA_PREBUILT_SHA256`；Android 多 ABI 构建则须分别提供 `ERIKA_PREBUILT_SHA256_ARM64_V8A`、`ERIKA_PREBUILT_SHA256_ARMEABI_V7A`、`ERIKA_PREBUILT_SHA256_X86_64` 和 `ERIKA_PREBUILT_SHA256_X86`。完整发布方式见 [发布指南](https://github.com/AimesSoft/Erika/blob/main/docs/releasing.zh.md)。
Android 会为每个实际请求的 ABI 只下载一个约 20–22MB 的 runtime 归档，不会获取四 ABI 合并 C API 包或其中的静态库。

源码构建时，macOS 使用 `ERIKA_MACOS_ARCHS=arm64|x86_64|universal`，Windows 使用 `ERIKA_WINDOWS_ARCH=x64|arm64`，Android 使用 `ERIKA_ANDROID_ABIS=arm64-v8a,armeabi-v7a,x86_64,x86`。直接构建原生库时，`xtask --target`、`ERIKA_NATIVE_TARGET` 和 `cargo build --target` 必须使用同一个 target。详细示例见 [构建指南](https://github.com/AimesSoft/Erika/blob/main/docs/building.zh.md)。

## iOS Setup

iOS CocoaPod script phase 会在 Xcode 构建期间自动构建 Erika 原生依赖和 C ABI static library。需要安装对应 iOS target 的 Rust toolchain：

- `rustup target add aarch64-apple-ios`

宿主应用必须在 Xcode 的 Signing & Capabilities 中启用 Background Modes > Audio, AirPlay, and Picture in Picture，或在 `Info.plist` 的 `UIBackgroundModes` 中加入 `audio`。iOS、tvOS 和 macOS 会注册 Now Playing 信息及系统播放控制；建议通过 `ErikaMediaMetadata` 提供标题、作者、专辑和封面图片字节。

后台播放默认关闭。需要后台继续播放音频时，创建播放器时设置 `ErikaPlayer(allowBackgroundPlayback: true)`。宿主未启用上述 Background Mode 时，即使设置该选项，iOS 也不会保证后台持续播放。

```dart
final player = ErikaPlayer(
  allowBackgroundPlayback: true,
);

final artwork = await rootBundle.load('assets/cover.jpg');
await player.open(
  mediaUrl,
  metadata: ErikaMediaMetadata(
    title: '标题',
    artist: '作者',
    album: '专辑',
    artwork: artwork.buffer.asUint8List(),
  ),
);
await player.play();
```

`allowBackgroundPlayback` 是播放器创建选项，播放器创建后不能动态修改。设为 `false` 时，App 进入后台会暂停播放，返回前台后保持暂停；设为 `true` 时，后台暂停视频解码但继续播放音频，返回前台后恢复视频。系统媒体面板支持播放、暂停和进度调整。封面应传入 JPEG、PNG 等完整编码图片字节，而不是原始像素数据。

## 系统媒体上一项与下一项

播放列表应用可以按当前条目启用系统媒体面板的上一项和下一项按钮。Erika 不会自行选择
媒体，而是发出 `systemMediaNavigationRequested` 事件，让 Dart 始终作为播放列表的唯一
数据源。当前条目变化后应同步更新按钮能力。

```dart
import 'dart:async';

import 'package:erika_flutter/erika_flutter.dart';

class PlaylistController {
  final ErikaPlayer player = ErikaPlayer(allowBackgroundPlayback: true);
  final List<({String title, String url})> items = <({String title, String url})>[
    (title: '第 1 集', url: 'https://example.com/episode-1.mp4'),
    (title: '第 2 集', url: 'https://example.com/episode-2.mp4'),
  ];

  StreamSubscription<ErikaPlayerEvent>? subscription;
  int index = 0;
  bool switching = false;

  Future<void> initialize() async {
    subscription = player.events.listen((ErikaPlayerEvent event) async {
      if (event.kind != ErikaEventKind.systemMediaNavigationRequested) {
        return;
      }
      switch (event.systemMediaCommand) {
        case ErikaSystemMediaCommand.previous:
          await openAt(index - 1);
        case ErikaSystemMediaCommand.next:
          await openAt(index + 1);
        case null:
          break;
      }
    });
    await openAt(0);
  }

  Future<void> openAt(int newIndex) async {
    if (switching || newIndex < 0 || newIndex >= items.length) {
      return;
    }
    switching = true;
    await player.setSystemMediaNavigation(
      previousEnabled: false,
      nextEnabled: false,
    );
    try {
      final item = items[newIndex];
      await player.open(
        item.url,
        metadata: ErikaMediaMetadata(title: item.title),
      );
      await player.play();
      index = newIndex;
    } finally {
      switching = false;
      await player.setSystemMediaNavigation(
        previousEnabled: index > 0,
        nextEnabled: index + 1 < items.length,
      );
    }
  }

  Future<void> dispose() async {
    await subscription?.cancel();
    await player.dispose();
  }
}
```

该能力默认关闭，并适用于 iOS、tvOS、macOS、Android、Windows 和 HarmonyOS。切集期间应暂时
关闭两个按钮并阻止重复请求；切换成功后再更新索引、metadata 和按钮能力。该 API 只上报
`previous` 和 `next`，播放、暂停、停止与进度调整仍由各平台的原生系统媒体集成直接处理。

## tvOS Setup

tvOS CocoaPod script phase 会在 Xcode 构建期间自动为 Apple TV 真机或模拟器构建
原生依赖和 C ABI 静态库。Rust 的 tvOS 目标属于 tier 3，因此需要安装带源码组件的
nightly：

- `rustup toolchain install nightly --component rust-src`

脚本会根据当前 Xcode SDK 与架构选择 `aarch64-apple-tvos`、
`aarch64-apple-tvos-sim` 或 `x86_64-apple-tvos`，并通过
`-Z build-std=std,panic_abort` 完成编译。

## Windows Setup

Windows 插件（`ErikaFlutterPluginCApi`）在 CMake 构建期间通过 `build_erika_runtime.cmake` 构建 Erika C ABI runtime（`erika_capi.dll`），自动跟随 CMake 的 x64 或 ARM64 生成器架构，并把 DLL 部署到 app 旁边。依赖项目也可通过 CMake cache `ERIKA_WINDOWS_ARCH=x64|arm64` 或环境变量 `ERIKA_WINDOWS_ARCH` 显式选择；高级场景可直接设置 `ERIKA_NATIVE_TARGET=x86_64-pc-windows-msvc|aarch64-pc-windows-msvc`。需要：

- 安装对应 MSVC target 的 Rust toolchain（`rustup target add x86_64-pc-windows-msvc` 或 `rustup target add aarch64-pc-windows-msvc`）
- Visual Studio Build Tools 的 x64/ARM64 C++ 工具 + Windows SDK
- 原生依赖已构建到 `third_party/dist/<target>/`（见仓库的 `xtask deps build` 流程）

若插件无法自动定位 Erika checkout，可设置 `ERIKA_REPO_ROOT`。

Windows 通过 System Media Transport Controls 发布标题、作者、专辑、封面、播放状态和时间线，并支持系统播放、暂停和进度调整。需要包含 C++/WinRT 的 Windows SDK；插件会自动链接所需的 WinRT 系统库。

## Android Setup

Android Gradle 构建会先调用 Erika 的 `xtask` 构建原生依赖，再用 Cargo 为选定 ABI 构建 `erika_capi`。需要 Android API 26 或更高版本，并安装 Android NDK 和对应 Rust target。生成的 `jniLibs` 会同时包含 `liberika_capi.so` 与匹配 ABI 的 NDK `libc++_shared.so`。默认构建 arm64 与 x86_64；可通过 `-PerikaAndroidAbis=arm64-v8a,x86_64` 或 `ERIKA_ANDROID_ABIS` 指定。

Android `content://` 媒体和字幕 URI 会通过 `ContentResolver` 打开并 detach，连同 provider 的 offset/length 作为由 Rust 接管所有权的 `fd://` source 传入 Erika。

Android 使用 MediaSession 和媒体通知接入锁屏、蓝牙耳机及系统媒体面板。`allowBackgroundPlayback: true` 时会启动 `mediaPlayback` 前台 Service，并在后台仅驱动音频；插件 Manifest 已声明前台服务和 Android 13+ 通知权限，但宿主应用仍需按产品流程向用户请求 `POST_NOTIFICATIONS` 运行时权限。该权限被拒绝时，系统媒体会话仍可工作，但通知展示取决于 Android 版本和系统策略。

Android 最低版本仍为 API 26。Extended-linear 还要求 native-window dataspace API（API
28+）；API 26/27 会继续 SDR 播放并报告对应 fallback。API 34+ 上，插件会监听
`Display.registerHdrSdrRatioChangedListener`，把真实 ratio 变化发布给 Erika，让 wgpu 无需
重新 attach surface 就能更新后续帧 target 和输出状态。API 35 上插件还会按
`SurfaceView` 设置 desired HDR headroom，不修改宿主的全局 Window。

## HarmonyOS Setup

HarmonyOS 模块需要 DevEco Studio 的 OpenHarmony Native SDK。CMake 默认下载并校验
`liberika_capi.so`，再与 `liberika_flutter.so` 一起打包。只有显式设置
`ERIKA_FORCE_SOURCE_BUILD=1` 时才需要 Rust 的 `aarch64-unknown-linux-ohos` target。

HarmonyOS 使用 AVSession 发布媒体元数据、封面、播放状态、进度和倍速，并接收系统播放、暂停、停止及进度调整命令。

HarmonyOS 上请使用 `ErikaVideoView`。它注册 Flutter 外部纹理，把纹理 surface 取为
`OHNativeWindow`，并通过 wgpu Vulkan 渲染。音频走 OHAudio，交错 f32 PCM。

视频解码默认使用 HarmonyOS AVCodec 硬解，支持 H.264 和 HEVC。AVCodec 渲染到
Surface，其 `OHNativeBuffer` 作为 Vulkan 外部图像导入，再由 Vulkan YCbCr sampler
解析，因此帧无需 CPU 拷贝即可到达合成器。不具备所需 Vulkan 扩展的设备回退到
FFmpeg 软解 + CPU 上传；回退会通过 `VideoDecoderChanged` 事件和 presenter 诊断
上报，而不是让播放失败。

## HTTP 请求头

播放 HTTP(S) 视频时，可以通过 `httpHeaders` 传递请求头：

```dart
await player.open(
  'https://example.com/video.mp4',
  httpHeaders: <String, String>{
    'Authorization': 'Bearer token',
    'Referer': 'https://example.com/',
  },
);
```

请求头会随 HEAD、Range GET 和预取请求发送，仅对 HTTP(S) URL 生效；`content://` 和本地
文件播放不使用这些请求头。请避免在应用日志中输出 Authorization、Cookie 等敏感值。

播放引擎自己生成的请求头会被拒绝而不是合并：`Range`、`Host`、`Content-Length`、
`Transfer-Encoding`、`Connection`（大小写不敏感）会让 `open` 抛出异常，不符合 HTTP
字段规则的名称和值同样如此。若打包的 native library 是 0.1.3 或更早的预编译产物（早于
HTTP 请求头支持），带请求头的 `open` 会抛出异常，而不是静默丢弃它们。

请求头只作用于媒体 source——外挂字幕轨道和弹幕 sidecar 文件仍然不带这些请求头拉取。

## Output Mode

`ErikaPlayer()` 会让 Apple 插件根据当前屏幕和环境选择 SDR 或 Apple EDR；Android 默认
为 SDR。若要从 Dart 强制 Apple EDR：

```dart
final player = ErikaPlayer(
  outputMode: ErikaOutputMode.appleEdr,
  edrHeadroom: 4.0,
);
```

使用 `ErikaOutputMode.sdr` 可强制 SDR 输出。

Android 的高 headroom 模式是 FP16 **extended-linear scRGB**，不是 HDR10/PQ：

```dart
final player = ErikaPlayer(
  outputMode: ErikaOutputMode.extendedLinear,
  edrHeadroom: 4.0,
);
```

`edrHeadroom` 是内容 headroom 上限。Extended-linear player 未传该参数时，Erika 使用默认
4x 内容上限，同时给 `SurfaceView` 传 desired headroom `0`（系统 auto）。显式值在 API 35
上还会作为 per-`SurfaceView` desired headroom。显示器当前 HDR/SDR ratio 可用时，会进一步
约束 wgpu 的有效 target。

只有显示器/surface 支持 HDR、view 是 Hybrid Composition `SurfaceView`、wgpu 选择
Vulkan、surface 暴露 `Rgba16Float`，且配置后的 native window 回读为
`ADATASPACE_SCRGB_LINEAR`（`406913024`、`0x18410000`）时，该模式才会激活。GLES、
`TextureView`、缺少 FP16 或 dataspace 验证失败都会明确回退 SDR。Android scRGB 使用
BT.709 primaries，`1.0 = 80 nit`；不使用 PQ 或 HDR10 metadata。

始终查询协商结果，不要把请求值当成实际输出：

```dart
final status = await player.getOutputStatus();
if (!status.extendedLinearActive) {
  debugPrint(
    'Erika output fallback: '
    '${status.fallbackReason.label} (${status.fallbackReason.nativeValue})',
  );
}
```

`ErikaOutputStatus` 有 13 个字段：`requestedMode`、`activeEncoding`、
`surfaceFormat`、`nativeDataSpace`、`requestedHeadroom`、`activeHeadroom`、
`activeHeadroomKnown`、`extendedLinearActive`、`fallbackReason`、
`fallbackCount`、`dataSpaceFailures`、`headroomUpdates`、
`extendedLinearFrames`。Android scRGB 真正激活时为
`androidExtendedLinearScRgb + sixteenBitFloat + nativeDataSpace 406913024`。
API 34+ 上，Android 暴露有效 ratio 时，`activeHeadroom` 是当前显示器 HDR/SDR ratio，
`activeHeadroomKnown` 为 true；ratio 不可用时，该值只是 fallback，
`activeHeadroomKnown` 为 false。只有 known 状态或 ratio 真实变化时，`headroomUpdates`
才增长；重复 listener 通知会被忽略。

`ErikaOutputFallbackReason` 是稳定 ABI 数值：

| 码 | Dart 值 | 稳定 label |
|----|---------|------------|
| 0 | `none` | `none` |
| 1 | `displayHdrUnsupported` | `display_hdr_unsupported` |
| 2 | `hybridCompositionRequired` | `hybrid_composition_required` |
| 3 | `wgpuBackendNotVulkan` | `wgpu_backend_not_vulkan` |
| 4 | `rgba16FloatSurfaceFormatUnavailable` | `rgba16float_surface_format_unavailable` |
| 5 | `nativeWindowDataSpaceApiUnavailable` | `native_window_dataspace_api_unavailable` |
| 6 | `scrgbDataSpaceVerificationFailed` | `scrgb_dataspace_verification_failed` |
| 7 | `surfaceConfigureFailed` | `surface_configure_failed` |
| 8 | `legacyAppleEdrUnsupported` | `legacy_apple_edr_unsupported` |

`player.screenshot()` 返回当前合成帧（视频 + 字幕 + 弹幕）的原始 SDR RGBA8；即使显示为
Apple EDR 或 Android extended-linear 也一样。Metal 与 Android/wgpu 已实现截图；当前
Windows D3D11 Flutter 路径不返回截图字节。

非 HDR 模拟器/设备覆盖验证的是明确 SDR 回退及其 reason。Active extended-linear 尚不宣称
已通过真机验证；仍需在 API 35 HDR 真机上验收 `Rgba16Float + SCRGB_LINEAR`、旋转/前后台
恢复、动态 HDR/SDR ratio 更新、多 player 和 SDR 截图。

## Upscaler

可以在创建时选择 ArtCNN，也可以在运行时切换：

```dart
final player = ErikaPlayer(upscaler: ErikaUpscalerMode.artCnnC4F16Ds);
await player.setUpscaler(ErikaUpscalerMode.artCnnC4F16Ds);
```

使用 `ErikaUpscalerMode.off` 关闭。`player.getUpscalerStatus()` 会返回请求模式、当前后端、fallback 次数、超分帧数和最近 GPU timing。Apple 使用 Metal；Android 对 planar 与 MediaCodec Surface 帧都使用 wgpu/Vulkan compute。GLES 3.0 会保持普通播放，并明确报告 `inactive` 回退。
