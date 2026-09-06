# erika_flutter

Flutter plugin for the Erika media playback engine.

The plugin keeps Dart out of the hot path:

- Dart exposes low-frequency player commands and event streams.
- The native plugins expose two surface strategies: `ErikaWindowOverlayVideoView`
  for the recommended window-hosted overlay path (Metal on macOS/iOS/tvOS, a D3D11
  swapchain on Windows), and `ErikaVideoView` for platform-view embedding. On
  Android both widgets route through the same native-view selector: SDR uses a
  real `TextureView`, while requested extended-linear output uses a
  `SurfaceView` with Hybrid Composition.
- The macOS plugin loads the Erika dynamic library.
- The iOS plugin links the Erika static library.
- The tvOS plugin links the Erika static library and hosts its Metal layer in an
  Apple TV platform view.
- The Windows plugin builds and links the Erika C ABI DLL.
- The Android plugin builds `liberika_capi.so` per ABI and drives its native
  surface from `Choreographer`.
- The HarmonyOS plugin registers a Flutter external texture, attaches its
  `OHNativeWindow` to Erika, and uses OHAudio for low-latency PCM output.
- Erika owns playback, rendering, audio, timing, and overlays through
  `ErikaPresenterHandle`.

## Video Surfaces

Use `ErikaWindowOverlayVideoView` for full-player macOS/iOS/tvOS UIs. It reserves a
Flutter layout rect while the plugin hosts a sibling native `CAMetalLayer`, so
video stays outside Flutter's platform-view compositor.

On Windows `ErikaWindowOverlayVideoView` hosts a window-level Direct3D 11
swapchain as a sibling surface, following the same overlay model.

Use `ErikaVideoView` when a standard Flutter platform view is required for a
small embedder, compatibility path, or diagnostics.

On Android the SDR video surface is a native `TextureView`. An
`ErikaOutputMode.extendedLinear` player instead creates a `SurfaceView` through
`PlatformViewLink`/Hybrid Composition, because scRGB must bypass Flutter's
texture-layer composition. The plugin forwards the borrowed `Surface` to Erika
and handles creation, resize, destruction, audio focus, HDR eligibility, and
vsync ticks.

## macOS Setup

The macOS plugin's podspec build phase downloads and bundles a verified,
codesigned
`liberika_capi.dylib`. It defaults to an arm64+x86_64 universal library. A
consuming project can set `ERIKA_MACOS_ARCHS=arm64`, `x86_64`, or
`arm64,x86_64`; `universal` remains the default. Prebuilt mode selects the
matching `macos-arm64`, `macos-x64`, or `macos-universal` archive. At runtime
the plugin loads the library via `dlopen`.

The macOS plugin publishes title, artist, album, artwork, playback state, and
timeline through Now Playing, and handles system play, pause, stop, and seek
commands through Remote Command Center.

Overrides: `ERIKA_CAPI_DYLIB` forces the runtime dylib path; `ERIKA_MACOS_CAPI_DYLIB`
points the build phase at an explicit dylib to bundle instead of building.

## Native binaries

The plugin downloads the matching `v0.1.7` native runtime by default on macOS,
Windows, iOS, tvOS, Android, and OpenHarmony. Every archive is pinned by SHA-256;
a missing or invalid archive fails with an explicit error instead of silently
requiring a Rust, FFmpeg, or NDK toolchain. See the
[release guide](https://github.com/AimesSoft/Erika/blob/main/docs/releasing.md).
Android downloads one approximately 20–22 MB runtime archive per requested ABI;
it does not fetch the four-ABI C API bundle or its static libraries.

When debugging local Erika changes from an Erika checkout, set
`ERIKA_FORCE_SOURCE_BUILD=1`. A custom `ERIKA_PREBUILT_TAG` must be accompanied
by the matching `ERIKA_PREBUILT_SHA256`. A custom multi-ABI Android build uses
the per-ABI variables `ERIKA_PREBUILT_SHA256_ARM64_V8A`,
`ERIKA_PREBUILT_SHA256_ARMEABI_V7A`, `ERIKA_PREBUILT_SHA256_X86_64`, and
`ERIKA_PREBUILT_SHA256_X86` instead.

For source builds, select macOS with `ERIKA_MACOS_ARCHS=arm64|x86_64|universal`,
Windows with `ERIKA_WINDOWS_ARCH=x64|arm64`, and Android with
`ERIKA_ANDROID_ABIS=arm64-v8a,armeabi-v7a,x86_64,x86`. For direct native builds,
`xtask --target`, `ERIKA_NATIVE_TARGET`, and `cargo build --target` must name the
same target. See the
[build guide](https://github.com/AimesSoft/Erika/blob/main/docs/building.md).

## iOS Setup

The iOS CocoaPod script phase downloads the verified C ABI static library.
Rust is required only for an explicit source build.

The host app must enable **Background Modes > Audio, AirPlay, and Picture in Picture** under Xcode's Signing & Capabilities, or add `audio` to `UIBackgroundModes` in `Info.plist`. The player registers Now Playing metadata and playback controls with Control Center. Pass an `ErikaMediaMetadata` value to provide the title, artist, album, and encoded artwork bytes.

Background playback is disabled by default. Create the player with `ErikaPlayer(allowBackgroundPlayback: true)` to keep audio playing in the background. iOS does not guarantee continued background playback unless the host app also enables the Background Mode described above.

```dart
final player = ErikaPlayer(
  allowBackgroundPlayback: true,
);

final artwork = await rootBundle.load('assets/cover.jpg');
await player.open(
  mediaUrl,
  metadata: ErikaMediaMetadata(
    title: 'Title',
    artist: 'Artist',
    album: 'Album',
    artwork: artwork.buffer.asUint8List(),
  ),
);
await player.play();
```

`allowBackgroundPlayback` is a player creation option and cannot be changed after the native player has been created. When it is `false`, playback pauses as the app enters the background and remains paused on return. When it is `true`, video decoding is suspended while audio continues in the background, and video resumes when the app becomes active. Control Center supports play, pause, and position changes. Artwork must contain complete encoded image bytes in a format supported by `UIImage`, such as JPEG or PNG, rather than raw pixels.

## System Media Navigation

Playlist apps can enable the system previous and next buttons for the active
item. Erika emits a `systemMediaNavigationRequested` event instead of choosing
the next media item itself, so Dart remains the source of truth for the
playlist. Update the capabilities whenever the active item changes.

```dart
import 'dart:async';

import 'package:erika_flutter/erika_flutter.dart';

class PlaylistController {
  final ErikaPlayer player = ErikaPlayer(allowBackgroundPlayback: true);
  final List<({String title, String url})> items = <({String title, String url})>[
    (title: 'Episode 1', url: 'https://example.com/episode-1.mp4'),
    (title: 'Episode 2', url: 'https://example.com/episode-2.mp4'),
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

The capabilities default to disabled and work on iOS, tvOS, macOS, Android,
Windows, and HarmonyOS. Disable both buttons and reject duplicate requests while an item
is switching, then update the index, metadata, and capabilities after a
successful switch. Only `previous` and `next` are emitted by this API. Play,
pause, stop, and seek continue to be handled directly by the native
system-media integration.

## tvOS Setup

The tvOS CocoaPod script phase downloads the verified C ABI static library for
Apple TV devices and simulators. An explicit source build uses Rust's tier-3
tvOS targets and requires nightly with its source component:

- `rustup toolchain install nightly --component rust-src`

The script selects `aarch64-apple-tvos`, `aarch64-apple-tvos-sim`, or
`x86_64-apple-tvos` from the active Xcode SDK and architecture, then compiles it
with `-Z build-std=std,panic_abort`.

## Windows Setup

The Windows plugin (`ErikaFlutterPluginCApi`) downloads the verified Erika C ABI
runtime (`erika_capi.dll`) during the CMake build,
automatically following the CMake generator's x64 or ARM64 architecture and
staging the DLL next to the app. A consuming project can explicitly select the
architecture with the `ERIKA_WINDOWS_ARCH=x64|arm64` CMake cache entry or
environment variable. Advanced integrations can set
`ERIKA_NATIVE_TARGET=x86_64-pc-windows-msvc|aarch64-pc-windows-msvc` directly.
Normal consumers only need Visual Studio Build Tools with C++/WinRT and a
Windows SDK. An explicit source build additionally requires:

- Rust toolchain with the matching MSVC target (`rustup target add x86_64-pc-windows-msvc` or `rustup target add aarch64-pc-windows-msvc`)
- Visual Studio Build Tools with x64/ARM64 C++ tools + Windows SDK
- Native dependencies built into `third_party/dist/<target>/`
  (via the repo `xtask deps build` flow)

Set `ERIKA_REPO_ROOT` together with `ERIKA_FORCE_SOURCE_BUILD=1` when developing
against an Erika checkout.

The Windows plugin publishes title, artist, album, artwork, playback state, and
timeline through System Media Transport Controls (SMTC), and handles system
play, pause, and seek commands. A Windows SDK with C++/WinRT is required; the
plugin links the required WinRT system libraries automatically.

## Android Setup

The Android Gradle plugin downloads the verified runtime for each selected ABI.
Android API 26 or newer is required. The generated `jniLibs` include both
`liberika_capi.so` and the matching NDK `libc++_shared.so`. By default arm64 and
x86_64 are selected; override
this with `-PerikaAndroidAbis=arm64-v8a,x86_64` or `ERIKA_ANDROID_ABIS`.

Android `content://` media and subtitle URIs are opened through
`ContentResolver`, detached, and passed to Erika as owned `fd://` sources with
their provider offset and length.

Android uses MediaSession and a media notification for lock-screen, Bluetooth,
and system media controls. With `allowBackgroundPlayback: true`, a
`mediaPlayback` foreground service keeps audio running while video decoding is
suspended. The plugin manifest declares the foreground-service and Android 13+
notification permissions, but the host app must request `POST_NOTIFICATIONS`
at runtime as appropriate for its product flow. If permission is denied, the
media session remains available while notification visibility depends on the
Android version and system policy.

Android's minimum remains API 26. Extended-linear output additionally needs the
native-window dataspace API (API 28+); API 26/27 continue in SDR and report the
specific fallback. On API 34+, the plugin observes
`Display.registerHdrSdrRatioChangedListener` and publishes real ratio changes
to Erika, allowing wgpu to update subsequent frame targets and output status
without reattaching the surface. On API 35 it also applies per-`SurfaceView`
desired HDR headroom without changing the host window globally.

## HarmonyOS Setup

The HarmonyOS module requires DevEco Studio's OpenHarmony Native SDK. Its CMake
build downloads and verifies `liberika_capi.so`, then packages it beside
`liberika_flutter.so`. Rust and the `aarch64-unknown-linux-ohos` target are only
required when `ERIKA_FORCE_SOURCE_BUILD=1` is explicitly selected.

HarmonyOS uses AVSession to publish metadata, artwork, playback state, position,
and playback rate, and handles system play, pause, stop, and seek commands.

Use `ErikaVideoView` on HarmonyOS. It registers a Flutter external texture,
obtains the texture surface as an `OHNativeWindow`, and renders through wgpu
Vulkan. Audio uses OHAudio with interleaved f32 PCM.

Video decoding defaults to HarmonyOS AVCodec hardware decoding for H.264 and
HEVC. AVCodec renders into a Surface whose `OHNativeBuffer` is imported as a
Vulkan external image and resolved with a Vulkan YCbCr sampler, so frames reach
the compositor without a CPU copy. Devices that do not expose the required
Vulkan extensions fall back to FFmpeg software decoding and CPU upload; the
fallback is reported through `VideoDecoderChanged` events and the presenter
diagnostics rather than failing playback.

## HTTP Headers

For HTTP(S) video playback, pass request headers through `httpHeaders`:

```dart
await player.open(
  'https://example.com/video.mp4',
  httpHeaders: <String, String>{
    'Authorization': 'Bearer token',
    'Referer': 'https://example.com/',
  },
);
```

Headers are sent with HEAD, Range GET, and prefetch requests, and only apply to
HTTP(S) URLs. Headers are ignored for `content://` and local-file playback.
Avoid writing sensitive values such as Authorization and Cookie to application
logs.

Headers the playback engine derives itself are rejected instead of merged:
`Range`, `Host`, `Content-Length`, `Transfer-Encoding`, and `Connection`
(case-insensitive) make `open` throw, as do names and values that are not valid
HTTP field tokens. If the bundled native library is a 0.1.3-or-earlier prebuilt
that predates HTTP header support, an `open` that carries headers throws rather
than silently dropping them.

Headers apply to the media source only — external subtitle tracks and danmaku
sidecar files are still fetched without them.

## Output Mode

`ErikaPlayer()` lets the Apple plugins choose SDR or Apple EDR from the current
screen and environment; Android defaults to SDR. To force Apple EDR from Dart:

```dart
final player = ErikaPlayer(
  outputMode: ErikaOutputMode.appleEdr,
  edrHeadroom: 4.0,
);
```

Use `ErikaOutputMode.sdr` to force SDR output.

Android's high-headroom mode is FP16 **extended-linear scRGB**, not HDR10/PQ:

```dart
final player = ErikaPlayer(
  outputMode: ErikaOutputMode.extendedLinear,
  edrHeadroom: 4.0,
);
```

`edrHeadroom` is a content-headroom ceiling. If it is omitted for an
extended-linear player, Erika uses a 4x content ceiling while the
`SurfaceView` receives desired headroom `0` (system auto). An explicit value is
also applied as the per-`SurfaceView` desired headroom on API 35. The current
display HDR/SDR ratio, when available, further bounds the effective wgpu target.

The mode activates only when all of these hold: the display/surface is
HDR-capable, the view is a Hybrid-Composition `SurfaceView`, wgpu selected
Vulkan, the surface exposes `Rgba16Float`, and the configured native window
reads back `ADATASPACE_SCRGB_LINEAR` (`406913024`, `0x18410000`). GLES,
`TextureView`, missing FP16 support, and dataspace failures explicitly fall
back to SDR. Android scRGB uses BT.709 primaries with `1.0 = 80 nit`; it does
not use PQ or HDR10 metadata.

Always query the negotiated state instead of trusting the request:

```dart
final status = await player.getOutputStatus();
if (!status.extendedLinearActive) {
  debugPrint(
    'Erika output fallback: '
    '${status.fallbackReason.label} (${status.fallbackReason.nativeValue})',
  );
}
```

`ErikaOutputStatus` contains 13 fields: `requestedMode`, `activeEncoding`,
`surfaceFormat`, `nativeDataSpace`, `requestedHeadroom`, `activeHeadroom`,
`activeHeadroomKnown`, `extendedLinearActive`, `fallbackReason`,
`fallbackCount`, `dataSpaceFailures`, `headroomUpdates`, and
`extendedLinearFrames`. Active Android scRGB is
`androidExtendedLinearScRgb + sixteenBitFloat + nativeDataSpace 406913024`.
On API 34+, `activeHeadroom` is the current display HDR/SDR ratio and
`activeHeadroomKnown` is true when Android exposes a valid ratio. If the ratio
is unavailable, the value is only a fallback and `activeHeadroomKnown` is
false. `headroomUpdates` increments only when the known state or ratio really
changes; duplicate listener notifications are ignored.

`ErikaOutputFallbackReason` values are stable ABI codes:

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

`player.screenshot()` returns raw SDR RGBA8 for the current composited frame
(video + subtitle + danmaku), even when the display is Apple EDR or Android
extended-linear. Metal and Android/wgpu implement capture; the current Windows
D3D11 Flutter path does not return screenshot bytes.

Non-HDR emulator/device coverage verifies the explicit SDR fallback and its
reason. Active extended-linear output is not yet claimed as device-validated;
acceptance still requires an API 35 HDR device with `Rgba16Float +
SCRGB_LINEAR`, live HDR/SDR-ratio updates, rotation/background recovery,
multiple players, and SDR screenshot checks.

## Upscaler

Select ArtCNN at creation time, or switch it later at runtime:

```dart
final player = ErikaPlayer(upscaler: ErikaUpscalerMode.artCnnC4F16Ds);
await player.setUpscaler(ErikaUpscalerMode.artCnnC4F16Ds);
```

Use `ErikaUpscalerMode.off` to disable it. Call
`player.getUpscalerStatus()` to inspect the requested mode, active backend,
fallback count, upscaled frame count, and recent GPU timings. Apple uses Metal;
Android uses wgpu/Vulkan compute for both planar and MediaCodec Surface frames.
GLES 3.0 keeps normal playback and reports an explicit `inactive` fallback.
