# erika_flutter

[中文](README.zh.md) | [English](README.md) | [日本語](README.ja.md)

Erika メディア再生エンジン向けの Flutter plugin です。

この plugin は Dart を hot path から外します。

- Dart は低頻度の player command と event stream だけを公開します。
- native plugin は 2 種類の surface を提供します。推奨は `ErikaWindowOverlayVideoView`（macOS/iOS/tvOS は Metal、Windows は D3D11 swapchain）、platform view 用は `ErikaVideoView` です。Android では両方が同じ native-view selector を使い、SDR は実体のある `TextureView`、extended-linear request は Hybrid Composition `SurfaceView` になります。
- macOS plugin は Erika の dynamic library を読み込みます。
- iOS plugin は Erika の static library を link します。
- tvOS plugin は Erika の static library を link し、Apple TV platform view で Metal layer を host します。
- Windows plugin は Erika C ABI DLL を build して link します。
- Android plugin は ABI ごとに `liberika_capi.so` を build し、`Choreographer` から native surface を駆動します。
- HarmonyOS plugin は Flutter external texture を登録し、その `OHNativeWindow` を Erika に attach して、OHAudio で低レイテンシの PCM 出力を行います。
- Erika は `ErikaPresenterHandle` を通じて playback、rendering、audio、timing、overlay を担当します。

## Video Surfaces

フルプレイヤーの macOS/iOS/tvOS UI では `ErikaWindowOverlayVideoView` を使うのが推奨です。Flutter の layout では矩形領域を予約しつつ、plugin が横に native `CAMetalLayer` を持ち、video を Flutter platform-view compositor の外に置きます。

Windows では `ErikaWindowOverlayVideoView` が window-level の Direct3D 11 swapchain を sibling surface として host し、同じ overlay モデルに従います。

標準的な Flutter platform view が必要な場合は `ErikaVideoView` を使います。Android の SDR video surface は native `TextureView` です。`ErikaOutputMode.extendedLinear` player は `PlatformViewLink`/Hybrid Composition の `SurfaceView` を作ります。scRGB を Flutter texture-layer composition に通さないためです。plugin は borrowed `Surface`、lifecycle、resize、audio focus、HDR eligibility、vsync tick を Erika に接続します。

## macOS Setup

macOS CocoaPods build は既定で arm64+x86_64 universal dynamic library を生成します。依存 project は `ERIKA_MACOS_ARCHS=arm64`、`ERIKA_MACOS_ARCHS=x86_64`、または `ERIKA_MACOS_ARCHS=arm64,x86_64` で artifact architecture を選択できます。既定値は `universal` です。prebuilt mode は対応する `macos-arm64`、`macos-x64`、`macos-universal` archive を取得します。ローカル開発では plugin が `dlopen` で Erika を読み込み、`ERIKA_CAPI_DYLIB` で path を上書きできます。

dynamic library を build するには：

```sh
cargo run -p xtask -- deps build --all --profile lgpl
cargo build -p erika_capi
```

## Prebuilt package と source build

plugin は既定で現在の version に対応する `v0.1.7` native library を download し、SHA-256 を検証します。download または検証の失敗は明示的な error になり、source build へ暗黙に fallback しません。Erika checkout の local source を debug するときだけ `ERIKA_FORCE_SOURCE_BUILD=1` を設定してください。custom `ERIKA_PREBUILT_TAG` の single-ABI build には対応する `ERIKA_PREBUILT_SHA256` が必要です。Android multi-ABI build では `ERIKA_PREBUILT_SHA256_ARM64_V8A`、`ERIKA_PREBUILT_SHA256_ARMEABI_V7A`、`ERIKA_PREBUILT_SHA256_X86_64`、`ERIKA_PREBUILT_SHA256_X86` を ABI ごとに指定します。詳細は [release guide](https://github.com/AimesSoft/Erika/blob/main/docs/releasing.ja.md) を参照してください。
Android は要求された ABI ごとに約 20–22MB の runtime archive だけを download し、4 ABI combined C API bundle や static library は取得しません。

source build の architecture は macOS では `ERIKA_MACOS_ARCHS=arm64|x86_64|universal`、Windows では `ERIKA_WINDOWS_ARCH=x64|arm64`、Android では `ERIKA_ANDROID_ABIS=arm64-v8a,armeabi-v7a,x86_64,x86` で選択します。native library を直接 build する場合、`xtask --target`、`ERIKA_NATIVE_TARGET`、`cargo build --target` は同じ target にしてください。詳細は [build guide](https://github.com/AimesSoft/Erika/blob/main/docs/building.ja.md) を参照してください。

macOS plugin は Now Playing を通じてタイトル、アーティスト、アルバム、artwork、再生状態、timeline を公開し、Remote Command Center からの再生、一時停止、停止、seek を処理します。

## iOS Setup

iOS の CocoaPod script phase が、Xcode build 中に Erika の native dependency と C ABI static library を自動 build します。対応する iOS target の Rust toolchain が必要です。

- `rustup target add aarch64-apple-ios`

host app では、Xcode の Signing & Capabilities で **Background Modes > Audio, AirPlay, and Picture in Picture** を有効にするか、`Info.plist` の `UIBackgroundModes` に `audio` を追加してください。player は Now Playing 情報と再生 control を Control Center に登録します。タイトル、アーティスト、アルバム、エンコード済み artwork bytes を表示するには `ErikaMediaMetadata` を指定してください。

バックグラウンド再生はデフォルトで無効です。バックグラウンドで音声を継続する場合は、`ErikaPlayer(allowBackgroundPlayback: true)` を指定してください。host app で上記の Background Mode が有効でない場合、この option を指定しても iOS はバックグラウンド再生の継続を保証しません。

```dart
final player = ErikaPlayer(
  allowBackgroundPlayback: true,
);

final artwork = await rootBundle.load('assets/cover.jpg');
await player.open(
  mediaUrl,
  metadata: ErikaMediaMetadata(
    title: 'タイトル',
    artist: 'アーティスト',
    album: 'アルバム',
    artwork: artwork.buffer.asUint8List(),
  ),
);
await player.play();
```

`allowBackgroundPlayback` は player 作成時の option であり、native player の作成後には変更できません。`false` の場合、App がバックグラウンドに入ると再生を一時停止し、foreground に戻っても一時停止状態を維持します。`true` の場合、バックグラウンドでは動画 decode を停止して音声のみを継続し、App が active になると動画を再開します。Control Center から再生、一時停止、再生位置の変更ができます。artwork には raw pixel ではなく、JPEG や PNG など `UIImage` が対応する形式の完全な encoded image bytes を指定してください。

## System Media の前後移動

playlist app は active item に応じて system media panel の前へ・次へ button を有効に
できます。Erika 自身は次の media item を選択せず、
`systemMediaNavigationRequested` event を発行するため、Dart を playlist の唯一の
source of truth にできます。active item が変わるたびに capability を更新してください。

```dart
import 'dart:async';

import 'package:erika_flutter/erika_flutter.dart';

class PlaylistController {
  final ErikaPlayer player = ErikaPlayer(allowBackgroundPlayback: true);
  final List<({String title, String url})> items = <({String title, String url})>[
    (title: 'エピソード 1', url: 'https://example.com/episode-1.mp4'),
    (title: 'エピソード 2', url: 'https://example.com/episode-2.mp4'),
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

capability は既定で無効で、iOS、tvOS、macOS、Android、Windows、HarmonyOS に対応します。
item の切り替え中は両方の button を一時的に無効化して重複 request を拒否し、切り替え
成功後に index、metadata、capability を更新してください。この API が通知するのは
`previous` と `next` のみです。再生、一時停止、停止、seek は引き続き各 platform の
native system-media integration が直接処理します。

## tvOS Setup

tvOS の CocoaPod script phase が、Apple TV 実機または simulator 向けの native
dependency と C ABI static library を Xcode build 中に自動 build します。Rust の
tvOS target は tier 3 のため、source component 付き nightly が必要です：

- `rustup toolchain install nightly --component rust-src`

script は現在の Xcode SDK と architecture から `aarch64-apple-tvos`、
`aarch64-apple-tvos-sim`、または `x86_64-apple-tvos` を選び、
`-Z build-std=std,panic_abort` で compile します。

## Windows Setup

Windows plugin（`ErikaFlutterPluginCApi`）は CMake build 中に `build_erika_runtime.cmake` で Erika C ABI runtime（`erika_capi.dll`）を build し、CMake generator の x64 または ARM64 architecture に自動追従して DLL を app の隣に配置します。依存 project は CMake cache の `ERIKA_WINDOWS_ARCH=x64|arm64` または環境変数 `ERIKA_WINDOWS_ARCH` で明示的に選択できます。高度な用途では `ERIKA_NATIVE_TARGET=x86_64-pc-windows-msvc|aarch64-pc-windows-msvc` も指定できます。必要なもの：

- 対応する MSVC target の Rust toolchain（`rustup target add x86_64-pc-windows-msvc` または `rustup target add aarch64-pc-windows-msvc`）
- Visual Studio Build Tools の x64/ARM64 C++ tools + Windows SDK
- `third_party/dist/<target>/` に build 済みの native dependency（リポジトリの `xtask deps build` フロー）

plugin が Erika checkout を自動検出できない場合は `ERIKA_REPO_ROOT` を設定してください。

Windows plugin は System Media Transport Controls（SMTC）を通じてタイトル、アーティスト、アルバム、artwork、再生状態、timeline を公開し、system の再生、一時停止、seek を処理します。C++/WinRT を含む Windows SDK が必要で、必要な WinRT system library は plugin が自動的に link します。

## Android Setup

Android Gradle build は Erika の `xtask` で native dependency を構築し、選択した ABI 向けに Cargo で `erika_capi` を build します。Android API 26 以降、Android NDK、対応する Rust target が必要です。生成される `jniLibs` には `liberika_capi.so` と ABI に対応する NDK の `libc++_shared.so` が含まれます。既定は arm64 と x86_64 で、`-PerikaAndroidAbis=arm64-v8a,x86_64` または `ERIKA_ANDROID_ABIS` で変更できます。

Android の `content://` media/subtitle URI は `ContentResolver` で開いて detach し、provider の offset/length を含む所有権付き `fd://` source として Erika に渡します。

Android は MediaSession と media notification を使って lock screen、Bluetooth、system media control に接続します。`allowBackgroundPlayback: true` の場合は `mediaPlayback` foreground Service を起動し、video decode を停止したままバックグラウンドで音声を継続します。plugin Manifest には foreground service と Android 13+ の notification permission が宣言されていますが、host app は product flow に応じて `POST_NOTIFICATIONS` runtime permission を要求する必要があります。permission が拒否された場合も media session は動作しますが、notification の表示は Android version と system policy に依存します。

Android minimum は API 26 のままです。Extended-linear は native-window dataspace API
（API 28+）も必要で、API 26/27 は SDR playback を継続して該当 fallback を報告します。
API 34+ では plugin が `Display.registerHdrSdrRatioChangedListener` を監視し、実際の ratio
change を Erika に publish します。wgpu は surface を reattach せず後続 frame target と
output status を更新します。API 35 では host の global Window を変更せず、`SurfaceView`
ごとに desired HDR headroom も設定します。

## HarmonyOS Setup

HarmonyOS module には DevEco Studio の OpenHarmony Native SDK が必要です。CMake は
既定で `liberika_capi.so` を download、検証し、`liberika_flutter.so` と一緒に package
します。Rust の `aarch64-unknown-linux-ohos` target は
`ERIKA_FORCE_SOURCE_BUILD=1` を明示した source build でのみ必要です。

HarmonyOS は AVSession を通じて metadata、artwork、再生状態、位置、再生速度を公開し、system の再生、一時停止、停止、seek command を処理します。

HarmonyOS では `ErikaVideoView` を使ってください。Flutter external texture を登録し、
その texture surface を `OHNativeWindow` として取得して、wgpu Vulkan で描画します。
音声は OHAudio の interleaved f32 PCM です。

video decode は既定で HarmonyOS AVCodec の hardware decode（H.264 / HEVC）です。
AVCodec は Surface に描画し、その `OHNativeBuffer` を Vulkan external image として
import して Vulkan YCbCr sampler で解決するため、フレームは CPU コピーなしで
compositor に届きます。必要な Vulkan extension を持たない端末は FFmpeg software
decode と CPU upload に fallback します。fallback は再生を失敗させず、
`VideoDecoderChanged` event と presenter diagnostics から報告されます。

## HTTP ヘッダー

HTTP(S) video を再生する場合は、`httpHeaders` で request header を渡せます：

```dart
await player.open(
  'https://example.com/video.mp4',
  httpHeaders: <String, String>{
    'Authorization': 'Bearer token',
    'Referer': 'https://example.com/',
  },
);
```

header は HEAD、Range GET、prefetch request とともに送信され、HTTP(S) URL にだけ適用されます。
`content://` と local file の再生では header は無視されます。Authorization や Cookie などの
機密値を application log に出力しないでください。

playback engine 自身が生成する header は merge されず reject されます：`Range`、`Host`、
`Content-Length`、`Transfer-Encoding`、`Connection`（大文字小文字を区別しない）は `open` を
throw させます。HTTP field として不正な名前や値も同様です。同梱の native library が
0.1.3 以前の prebuilt（HTTP header 対応より前）の場合、header 付きの `open` は黙って
header を捨てずに throw します。

header が適用されるのは media source だけです。外部 subtitle track と danmaku sidecar は
まだ header なしで取得されます。

## Output Mode

`ErikaPlayer()` は Apple plugin に現在の screen と environment から SDR か Apple EDR を
選ばせ、Android は SDR が default です。Dart から Apple EDR を強制するには：

```dart
final player = ErikaPlayer(
  outputMode: ErikaOutputMode.appleEdr,
  edrHeadroom: 4.0,
);
```

`ErikaOutputMode.sdr` で SDR 出力を強制できます。

Android の high-headroom mode は FP16 **extended-linear scRGB** で、HDR10/PQ ではありません。

```dart
final player = ErikaPlayer(
  outputMode: ErikaOutputMode.extendedLinear,
  edrHeadroom: 4.0,
);
```

`edrHeadroom` は content-headroom ceiling です。extended-linear player で省略すると Erika
は default 4x content ceiling を使い、`SurfaceView` の desired headroom は `0`（system auto）
になります。明示値は API 35 の per-`SurfaceView` desired headroom にも使います。current
display HDR/SDR ratio が available なら wgpu effective target をさらに制限します。

display/surface が HDR capable、view が Hybrid Composition `SurfaceView`、wgpu が Vulkan、
surface が `Rgba16Float` を公開し、configured native window の readback が
`ADATASPACE_SCRGB_LINEAR`（`406913024`、`0x18410000`）の場合だけ active になります。
GLES、`TextureView`、FP16 不在、dataspace verification failure は SDR に明示 fallback します。
Android scRGB は BT.709 primaries、`1.0 = 80 nit` で、PQ/HDR10 metadata は使いません。

request ではなく negotiated state を必ず確認します。

```dart
final status = await player.getOutputStatus();
if (!status.extendedLinearActive) {
  debugPrint(
    'Erika output fallback: '
    '${status.fallbackReason.label} (${status.fallbackReason.nativeValue})',
  );
}
```

`ErikaOutputStatus` の 13 field は `requestedMode`、`activeEncoding`、
`surfaceFormat`、`nativeDataSpace`、`requestedHeadroom`、`activeHeadroom`、
`activeHeadroomKnown`、`extendedLinearActive`、`fallbackReason`、
`fallbackCount`、`dataSpaceFailures`、`headroomUpdates`、
`extendedLinearFrames` です。active Android scRGB は
`androidExtendedLinearScRgb + sixteenBitFloat + nativeDataSpace 406913024` です。
API 34+ で Android が valid ratio を公開すると、`activeHeadroom` は current display HDR/SDR
ratio、`activeHeadroomKnown` は true です。ratio unavailable の場合、この値は fallback
のみで `activeHeadroomKnown` は false です。known state または ratio が実際に変わった
場合だけ `headroomUpdates` が増え、duplicate listener notification は無視されます。

`ErikaOutputFallbackReason` は stable ABI code です。

| Code | Dart value | Stable label |
|------|------------|--------------|
| 0 | `none` | `none` |
| 1 | `displayHdrUnsupported` | `display_hdr_unsupported` |
| 2 | `hybridCompositionRequired` | `hybrid_composition_required` |
| 3 | `wgpuBackendNotVulkan` | `wgpu_backend_not_vulkan` |
| 4 | `rgba16FloatSurfaceFormatUnavailable` | `rgba16float_surface_format_unavailable` |
| 5 | `nativeWindowDataSpaceApiUnavailable` | `native_window_dataspace_api_unavailable` |
| 6 | `scrgbDataSpaceVerificationFailed` | `scrgb_dataspace_verification_failed` |
| 7 | `surfaceConfigureFailed` | `surface_configure_failed` |
| 8 | `legacyAppleEdrUnsupported` | `legacy_apple_edr_unsupported` |

`player.screenshot()` は current composited frame（video + subtitle + danmaku）の raw SDR
RGBA8 を返し、display が Apple EDR / Android extended-linear の場合も SDR のままです。
Metal と Android/wgpu は capture 実装済みですが、現在の Windows D3D11 Flutter path は
screenshot byte を返しません。

non-HDR emulator/device coverage は明示的 SDR fallback と reason を検証します。Active
extended-linear はまだ実機検証済みとは claim せず、API 35 HDR device で
`Rgba16Float + SCRGB_LINEAR`、live HDR/SDR-ratio update、rotation/background recovery、
multiple player、SDR screenshot の acceptance が必要です。

## Upscaler

作成時に ArtCNN を選択することも、runtime で切り替えることもできます。

```dart
final player = ErikaPlayer(upscaler: ErikaUpscalerMode.artCnnC4F16Ds);
await player.setUpscaler(ErikaUpscalerMode.artCnnC4F16Ds);
```

`ErikaUpscalerMode.off` で無効化します。`player.getUpscalerStatus()` では要求モード、実行 backend、fallback 回数、upscaled frame 数、最近の GPU timing を確認できます。Apple は Metal、Android は planar と MediaCodec Surface frame の両方で wgpu/Vulkan compute を使います。GLES 3.0 は通常再生を維持し、明示的な `inactive` fallback を報告します。
