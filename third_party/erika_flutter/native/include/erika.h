#ifndef ERIKA_H
#define ERIKA_H

/*
 * Erika media playback engine — C ABI.
 *
 * Full reference: docs/capi_reference.md. Embedding walkthrough:
 * docs/integration.md.
 *
 * Two independent entry points; pick one per integration:
 *   - ErikaHandle:          pull model. The host renders and pulls state.
 *   - ErikaPresenterHandle: push model. Erika owns decode/timing/audio/render;
 *                           the host gives it a surface and calls render_tick.
 *                           Compiled on macOS / iOS / Windows / Android /
 *                           OpenHarmony; on other targets
 *                           erika_presenter_create returns NULL.
 *
 * Conventions:
 *   - Every fallible call returns ErikaStatus; Ok (0) and NoEvent are the only
 *     non-error results. Panics are caught and surface as ErikaStatus_Panic.
 *   - On a non-Ok/NoEvent result a human-readable message is stored in a
 *     THREAD-LOCAL slot; read it on the same thread via
 *     erika_last_error_message() and free with erika_string_free().
 *   - Any char* Erika returns is caller-owned: free standalone strings with
 *     erika_string_free(); free strings inside ErikaTrackInfo /
 *     ErikaDanmakuTrackInfo with the matching *_info_free() function.
 *   - const char* arguments are borrowed for the call only and must be
 *     NUL-terminated UTF-8.
 *   - List getters use the counted-array idiom: pass (buf, capacity, &len);
 *     len is set to the total count, at most capacity records are written, and
 *     capacity 0 with a NULL buffer queries the count.
 *   - attach and resize functions take exact width/height in physical pixels.
 *     The scale is the independent logical-content/DPI scale used for UI such
 *     as danmaku; it never multiplies the surface extent.
 *   - A handle is not internally synchronized: do not call into one handle
 *     concurrently from multiple threads.
 */

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Opaque handles. ErikaHandle = pull model, ErikaPresenterHandle = push model. */
typedef struct ErikaHandle ErikaHandle;
typedef struct ErikaPresenterHandle ErikaPresenterHandle;

typedef struct ErikaHttpHeader {
  const char *name;
  const char *value;
} ErikaHttpHeader;

typedef enum ErikaStatus {
  ErikaStatus_Ok = 0,
  ErikaStatus_NullPointer = 1,
  ErikaStatus_InvalidUtf8 = 2,
  ErikaStatus_PlayerError = 3,
  ErikaStatus_Panic = 4,
  ErikaStatus_NoEvent = 5,
} ErikaStatus;

typedef enum ErikaState {
  ErikaState_Idle = 0,
  ErikaState_Opening = 1,
  ErikaState_Ready = 2,
  ErikaState_Playing = 3,
  ErikaState_Paused = 4,
  ErikaState_Stopped = 5,
  ErikaState_Closed = 6,
  ErikaState_Error = 7,
} ErikaState;

typedef enum ErikaEventKind {
  ErikaEventKind_None = 0,
  ErikaEventKind_StateChanged = 1,
  ErikaEventKind_DurationChanged = 2,
  ErikaEventKind_PositionChanged = 3,
  ErikaEventKind_TracksChanged = 4,
  ErikaEventKind_BufferingChanged = 5,
  ErikaEventKind_VideoParamsChanged = 6,
  ErikaEventKind_SurfaceAttached = 7,
  ErikaEventKind_SurfaceDetached = 8,
  ErikaEventKind_Error = 9,
  ErikaEventKind_TrackSelectionChanged = 10,
  ErikaEventKind_VideoDecoderChanged = 11,
  ErikaEventKind_AudioOutputChanged = 12,
} ErikaEventKind;

typedef enum ErikaTrackKind {
  ErikaTrackKind_Video = 0,
  ErikaTrackKind_Audio = 1,
  ErikaTrackKind_Subtitle = 2,
} ErikaTrackKind;

typedef enum ErikaTrackSource {
  ErikaTrackSource_Embedded = 0,
  ErikaTrackSource_External = 1,
} ErikaTrackSource;

typedef enum ErikaWgpuSurfaceKind {
  ErikaWgpuSurfaceKind_Unknown = 0,
  ErikaWgpuSurfaceKind_MacOsNsView = 1,
  ErikaWgpuSurfaceKind_MacOsCaMetalLayer = 2,
  ErikaWgpuSurfaceKind_IosUiView = 3,
  ErikaWgpuSurfaceKind_WindowsHwnd = 4,
  ErikaWgpuSurfaceKind_XlibWindow = 5,
  ErikaWgpuSurfaceKind_WaylandSurface = 6,
  ErikaWgpuSurfaceKind_AndroidNativeWindow = 7,
  ErikaWgpuSurfaceKind_OhosNativeWindow = 8,
} ErikaWgpuSurfaceKind;

typedef enum ErikaFlutterTextureKind {
  ErikaFlutterTextureKind_Unknown = 0,
  ErikaFlutterTextureKind_MacOsTextureRegistrar = 1,
  ErikaFlutterTextureKind_IosTextureRegistrar = 2,
  ErikaFlutterTextureKind_AndroidSurfaceTexture = 3,
  ErikaFlutterTextureKind_WindowsTextureRegistrar = 4,
  ErikaFlutterTextureKind_LinuxTextureRegistrar = 5,
} ErikaFlutterTextureKind;

typedef enum ErikaPresenterOutputMode {
  ErikaPresenterOutputMode_Sdr = 0,
  ErikaPresenterOutputMode_AppleEdr = 1,
  ErikaPresenterOutputMode_ExtendedLinear = 2,
  ErikaPresenterOutputMode_Auto = 3,
} ErikaPresenterOutputMode;

typedef enum ErikaActiveOutputEncoding {
  ErikaActiveOutputEncoding_SdrSrgb = 0,
  ErikaActiveOutputEncoding_AppleEdr = 1,
  ErikaActiveOutputEncoding_AndroidExtendedLinearScRgb = 2,
  ErikaActiveOutputEncoding_Hdr10Pq = 3,
} ErikaActiveOutputEncoding;

typedef enum ErikaOutputFallbackReason {
  ErikaOutputFallbackReason_None = 0,
  ErikaOutputFallbackReason_DisplayHdrUnsupported = 1,
  ErikaOutputFallbackReason_HybridCompositionRequired = 2,
  ErikaOutputFallbackReason_WgpuBackendNotVulkan = 3,
  ErikaOutputFallbackReason_Rgba16FloatSurfaceFormatUnavailable = 4,
  ErikaOutputFallbackReason_NativeWindowDataSpaceApiUnavailable = 5,
  ErikaOutputFallbackReason_ScrgbDataSpaceVerificationFailed = 6,
  ErikaOutputFallbackReason_SurfaceConfigureFailed = 7,
  ErikaOutputFallbackReason_LegacyAppleEdrUnsupported = 8,
} ErikaOutputFallbackReason;

typedef enum ErikaOutputSurfaceFormat {
  ErikaOutputSurfaceFormat_EightBitUnorm = 0,
  ErikaOutputSurfaceFormat_TenBitUnorm = 1,
  ErikaOutputSurfaceFormat_SixteenBitFloat = 2,
} ErikaOutputSurfaceFormat;

typedef enum ErikaLumaUpscalerMode {
  ErikaLumaUpscalerMode_Off = 0,
  ErikaLumaUpscalerMode_ArtCnnC4F16 = 1,
  ErikaLumaUpscalerMode_ArtCnnC4F32 = 2,
  ErikaLumaUpscalerMode_ArtCnnC4F16Ds = 3,
} ErikaLumaUpscalerMode;

typedef enum ErikaUpscalerBackendStatus {
  ErikaUpscalerBackendStatus_Off = 0,
  ErikaUpscalerBackendStatus_Inactive = 1,
  ErikaUpscalerBackendStatus_Building = 2,
  ErikaUpscalerBackendStatus_Scalar = 3,
  ErikaUpscalerBackendStatus_SimdgroupMatrix = 4,
} ErikaUpscalerBackendStatus;

typedef enum ErikaVideoAlphaMode {
  ErikaVideoAlphaMode_Opaque = 0,
  ErikaVideoAlphaMode_PackedAlphaRight = 1,
} ErikaVideoAlphaMode;

typedef struct ErikaPresenterConfig {
  int32_t output_mode;
  float edr_headroom;
  int32_t luma_upscaler;
  int32_t video_alpha_mode;
} ErikaPresenterConfig;

#define ERIKA_SUBTITLE_OVERRIDE_FONT_SIZE_FIELDS (1u << 2)
#define ERIKA_SUBTITLE_OVERRIDE_FONT_NAME (1u << 3)
#define ERIKA_SUBTITLE_OVERRIDE_COLORS (1u << 4)
#define ERIKA_SUBTITLE_OVERRIDE_ATTRIBUTES (1u << 5)
#define ERIKA_SUBTITLE_OVERRIDE_BORDER (1u << 6)
#define ERIKA_SUBTITLE_OVERRIDE_ALIGNMENT (1u << 7)
#define ERIKA_SUBTITLE_OVERRIDE_MARGINS (1u << 8)
#define ERIKA_SUBTITLE_OVERRIDE_BLUR (1u << 11)
#define ERIKA_SUBTITLE_OVERRIDE_ALL                                              \
  (ERIKA_SUBTITLE_OVERRIDE_FONT_SIZE_FIELDS |                                   \
   ERIKA_SUBTITLE_OVERRIDE_FONT_NAME | ERIKA_SUBTITLE_OVERRIDE_COLORS |         \
   ERIKA_SUBTITLE_OVERRIDE_ATTRIBUTES | ERIKA_SUBTITLE_OVERRIDE_BORDER |        \
   ERIKA_SUBTITLE_OVERRIDE_ALIGNMENT | ERIKA_SUBTITLE_OVERRIDE_MARGINS |        \
   ERIKA_SUBTITLE_OVERRIDE_BLUR)

typedef struct ErikaSubtitleStyle {
  const char *font_family;
  const char *font_file_path;
  uint32_t primary_color_rgba;
  uint32_t outline_color_rgba;
  double font_size;
  double outline_width;
  bool bold;
  bool italic;
  bool underline;
  bool strike_out;
  double spacing;
  double scale_x_percent;
  double scale_y_percent;
  int32_t border_style;
  double shadow_depth;
  double blur;
  int32_t alignment;
  int32_t margin_left;
  int32_t margin_right;
  int32_t margin_vertical;
  uint32_t override_mask;
} ErikaSubtitleStyle;

typedef struct ErikaSurfaceOutputCapabilities {
  bool extended_linear;
  bool direct_composition;
  float desired_headroom;
  int32_t fallback_reason;
} ErikaSurfaceOutputCapabilities;

typedef struct ErikaUpscalerStatus {
  int32_t requested_mode;
  int32_t active_backend;
  uint64_t fallback_count;
  uint64_t upscaled_frames;
  uint64_t last_encode_micros;
  uint64_t last_gpu_micros;
} ErikaUpscalerStatus;

typedef struct ErikaOutputStatus {
  int32_t requested_mode;
  int32_t active_encoding;
  int32_t surface_format;
  int32_t native_data_space;
  float requested_headroom;
  float active_headroom;
  bool active_headroom_known;
  bool extended_linear_active;
  int32_t fallback_reason;
  uint64_t fallback_count;
  uint64_t data_space_failures;
  uint64_t headroom_updates;
  uint64_t extended_linear_frames;
} ErikaOutputStatus;

/* Renderer memory snapshot. Per-resource fields are allocations tracked by
 * one presenter. device_current_allocated_bytes is Metal's device-wide
 * process counter and may include allocations owned by other presenters. */
typedef struct ErikaPresenterResourceStatus {
  uint64_t device_current_allocated_bytes;
  uint64_t device_recommended_working_set_bytes;
  uint64_t drawable_estimated_bytes;
  uint64_t video_frame_bytes;
  uint64_t overlay_atlas_bytes;
  uint64_t danmaku_atlas_bytes;
  uint64_t danmaku_vertex_buffer_bytes;
  uint64_t upscaler_bytes;
  uint64_t renderer_tracked_bytes;
  uint64_t presenter_cpu_danmaku_atlas_bytes;
  uint32_t drawable_count;
  uint64_t output_mode_switches;
} ErikaPresenterResourceStatus;

typedef struct ErikaSubtitleMemoryFontStatus {
  uintptr_t registered_count;
  uintptr_t registered_bytes;
  uintptr_t selected_count;
  uint64_t generation;
  uint64_t *selected_ids;
} ErikaSubtitleMemoryFontStatus;

typedef struct ErikaSubtitleMemoryFontFace {
  uint32_t index;
  char *families_json;
  char *post_script_name;
  uint16_t weight;
  bool italic;
  bool monospaced;
} ErikaSubtitleMemoryFontFace;

typedef struct ErikaSubtitleMemoryFontInfo {
  uint64_t id;
  uintptr_t byte_len;
  ErikaSubtitleMemoryFontFace *faces;
  uintptr_t face_count;
} ErikaSubtitleMemoryFontInfo;

typedef struct ErikaDanmakuConfig {
  bool enabled;
  /* NipaPlay/Flutter logical danmaku font size. Erika uses the NipaPlay
   * default danmaku font and multiplies by the surface scale for glyph pixels. */
  float font_size;
  float opacity;
  float display_area;
  float scroll_duration_seconds;
  float scroll_speed_factor;
  float track_gap_ratio;
  float outline_width;
  float shadow_offset_x;
  float shadow_offset_y;
  bool merge_duplicates;
  bool allow_stacking;
  bool allow_scroll_overwrite;
  uint32_t max_quantity;
  uint32_t max_lines_per_mode;
  bool block_top;
  bool block_bottom;
  bool block_scroll;
  int32_t shadow_style;
} ErikaDanmakuConfig;

typedef struct ErikaDanmakuTrackInfo {
  uint64_t id;
  bool enabled;
  int64_t offset_micros;
  uintptr_t item_count;
  char *name;
  char *source;
} ErikaDanmakuTrackInfo;

typedef struct ErikaVideoParams {
  uint32_t width;
  uint32_t height;
  uint32_t primaries;
  uint32_t transfer;
} ErikaVideoParams;

typedef struct ErikaTrackCounts {
  uint32_t video;
  uint32_t audio;
  uint32_t subtitle;
} ErikaTrackCounts;

typedef struct ErikaTrackSelection {
  int64_t video;
  int64_t audio;
  int64_t subtitle;
} ErikaTrackSelection;

typedef struct ErikaTrackInfo {
  int64_t id;
  ErikaTrackKind kind;
  ErikaTrackSource source;
  bool selected;
  bool can_remove;
  char *title;
  char *language;
  char *codec;
  uint32_t width;
  uint32_t height;
  uint32_t sample_rate;
  uint32_t channels;
  char *pixel_format;
  char *sample_format;
  char *profile;
  int32_t level;
  uint64_t bit_rate;
  uint32_t frame_rate_numerator;
  uint32_t frame_rate_denominator;
} ErikaTrackInfo;

typedef struct ErikaEvent {
  ErikaEventKind kind;
  ErikaStatus status;
  ErikaState state;
  int64_t duration_micros;
  uint64_t position_micros;
  bool buffering;
  ErikaVideoParams video;
  ErikaTrackCounts tracks;
} ErikaEvent;

typedef struct ErikaPresenterStats {
  uint64_t decoded_video_frames;
  uint64_t rendered_video_frames;
  uint64_t rendered_test_frames;
  uint64_t pushed_audio_frames;
  uint64_t overlay_frames;
  uint64_t danmaku_frames;
  uint64_t danmaku_items;
  uint64_t import_failures;
  uint64_t render_failures;
  uint64_t audio_failures;
  uint64_t software_video_frames;
  uint64_t hardware_video_frames;
  uint64_t zero_copy_video_frames;
  uint64_t cpu_video_frame_fallbacks;
  uint64_t last_render_micros;
  uint64_t last_render_current_micros;
  uint64_t audio_clock_read_frames;
  uint64_t audio_clock_queued_frames;
  uint64_t audio_clock_underflow_frames;
  /* 0 stable, 1 disconnected, 2 recovering, 3 failed. */
  int32_t audio_recovery_state;
  int32_t audio_last_error_code;
  uint64_t audio_recovery_attempts;
  uint64_t audio_recovery_count;
  uint64_t audio_recovery_failures;
  uint64_t direct_zero_copy_video_frames;
  uint64_t shared_handle_video_frames;
  uint64_t hdr_source_frames;
  uint64_t hdr10_output_frames;
  uint64_t sdr_tonemap_frames;
  uint64_t hdr10_metadata_updates;
  uint64_t hdr10_metadata_failures;
  uint64_t hdr10_output_failures;
  bool hdr10_output_active;
  uint64_t video_frame_backpressure_drops;
} ErikaPresenterStats;

/* ===== ErikaHandle (pull model) ===== */

/* Lifecycle and thread-local error retrieval. erika_create never fails. */
ErikaHandle *erika_create(void);
void erika_destroy(ErikaHandle *handle);
char *erika_last_error_message(void);
void erika_string_free(char *value);

/* Playback control. uri is a local path or HTTP(S) URL; times are microseconds.
 * open() synchronously probes streams and transitions to Ready. */
ErikaStatus erika_open(ErikaHandle *handle, const char *uri);
ErikaStatus erika_open_with_headers(
    ErikaHandle *handle,
    const char *uri,
    const ErikaHttpHeader *headers,
    uintptr_t header_count);
/* play enqueues work; observe StateChanged/Error for the authoritative result. */
ErikaStatus erika_play(ErikaHandle *handle);
ErikaStatus erika_pause(ErikaHandle *handle);
ErikaStatus erika_stop(ErikaHandle *handle);
ErikaStatus erika_close(ErikaHandle *handle);
ErikaStatus erika_seek(ErikaHandle *handle, uint64_t position_micros);
/* Tracks and subtitles. Subtitle track id -1 disables subtitles.
 * erika_tracks uses the counted-array idiom; free each filled record with
 * erika_track_info_free. */
ErikaStatus erika_add_external_subtitle(
    ErikaHandle *handle,
    const char *uri,
    int64_t *out_track_id);
ErikaStatus erika_remove_subtitle_track(ErikaHandle *handle, int64_t track_id);
ErikaStatus erika_select_audio_track(ErikaHandle *handle, int64_t track_id);
ErikaStatus erika_select_subtitle_track(ErikaHandle *handle, int64_t track_id);
ErikaStatus erika_track_selection(
    ErikaHandle *handle,
    ErikaTrackSelection *out_selection);
ErikaStatus erika_tracks(
    ErikaHandle *handle,
    ErikaTrackInfo *out_tracks,
    uintptr_t capacity,
    uintptr_t *out_len);
void erika_track_info_free(ErikaTrackInfo *track);
void erika_danmaku_track_info_free(ErikaDanmakuTrackInfo *track);
/* State and non-blocking event polling (returns NoEvent when the queue is empty). */
ErikaStatus erika_state(ErikaHandle *handle, ErikaState *out_state);
ErikaStatus erika_poll_event(ErikaHandle *handle, ErikaEvent *out_event);

/* Host-managed surface attach. raw_layer is a CAMetalLayer* cast to uint64_t;
 * for wgpu, raw_window/raw_display are platform handles for the given kind. */
ErikaStatus erika_attach_metal_layer(
    ErikaHandle *handle,
    uint64_t raw_layer,
    uint32_t width,
    uint32_t height,
    double scale);

ErikaStatus erika_attach_wgpu_surface(
    ErikaHandle *handle,
    ErikaWgpuSurfaceKind kind,
    uint64_t raw_window,
    uint64_t raw_display,
    uint32_t width,
    uint32_t height,
    double scale);

ErikaStatus erika_attach_wgpu_surface_with_output_capabilities(
    ErikaHandle *handle,
    ErikaWgpuSurfaceKind kind,
    uint64_t raw_window,
    uint64_t raw_display,
    uint32_t width,
    uint32_t height,
    double scale,
    ErikaSurfaceOutputCapabilities output_capabilities);

ErikaStatus erika_attach_flutter_texture(
    ErikaHandle *handle,
    ErikaFlutterTextureKind kind,
    int64_t texture_id,
    uint32_t width,
    uint32_t height,
    double scale);

ErikaStatus erika_detach_surface(ErikaHandle *handle);

/* ===== ErikaPresenterHandle (push model) — macOS / iOS / Windows / Android / OpenHarmony ===== */

/* Lifecycle and configuration. A NULL return means creation failed; check
 * erika_last_error_message. Config selects output mode, EDR headroom, upscaler. */
ErikaPresenterHandle *erika_presenter_create(void);
ErikaPresenterHandle *erika_presenter_create_with_config(ErikaPresenterConfig config);
ErikaPresenterHandle *erika_presenter_create_with_output_mode(
    int32_t output_mode,
    float edr_headroom);
ErikaPresenterHandle *erika_presenter_create_with_output_mode_and_alpha(
    int32_t output_mode,
    float edr_headroom,
    int32_t video_alpha_mode);
void erika_presenter_destroy(ErikaPresenterHandle *handle);

/* Playback and runtime parameters. volume is 0.0–1.0; rate 1.0 is normal speed;
 * set_upscaler takes an ErikaLumaUpscalerMode. Metal and capable wgpu/Vulkan
 * renderers execute ArtCNN; other backends retain native luma sampling and
 * report an explicit Inactive fallback. */
ErikaStatus erika_presenter_open(ErikaPresenterHandle *handle, const char *uri);
ErikaStatus erika_presenter_open_with_headers(
    ErikaPresenterHandle *handle,
    const char *uri,
    const ErikaHttpHeader *headers,
    uintptr_t header_count);
/* play enqueues work; observe StateChanged/Error for the authoritative result. */
ErikaStatus erika_presenter_play(ErikaPresenterHandle *handle);
ErikaStatus erika_presenter_pause(ErikaPresenterHandle *handle);
ErikaStatus erika_presenter_stop(ErikaPresenterHandle *handle);
ErikaStatus erika_presenter_close(ErikaPresenterHandle *handle);
ErikaStatus erika_presenter_seek(ErikaPresenterHandle *handle, uint64_t position_micros);
ErikaStatus erika_presenter_set_playback_rate(ErikaPresenterHandle *handle, double rate);
ErikaStatus erika_presenter_set_volume(ErikaPresenterHandle *handle, double volume);
ErikaStatus erika_presenter_set_upscaler(ErikaPresenterHandle *handle, int32_t mode);
ErikaStatus erika_presenter_set_subtitle_scale(ErikaPresenterHandle *handle, double scale);
/* Fallback subtitle font. NULL or empty clears that half of the selection.
 * A container ASS script keeps its own font unless the font-name override bit
 * is passed through erika_presenter_set_subtitle_style. */
ErikaStatus erika_presenter_set_subtitle_font(
    ErikaPresenterHandle *handle,
    const char *family,
    const char *file_path);
ErikaStatus erika_presenter_register_subtitle_memory_font(
    ErikaPresenterHandle *handle,
    const uint8_t *data,
    uintptr_t data_len,
    uint64_t *out_font_id);
ErikaStatus erika_presenter_select_subtitle_memory_fonts(
    ErikaPresenterHandle *handle,
    const uint64_t *font_ids,
    uintptr_t font_count);
ErikaStatus erika_presenter_clear_subtitle_memory_fonts(ErikaPresenterHandle *handle);
ErikaStatus erika_presenter_get_subtitle_memory_font_status(
    ErikaPresenterHandle *handle,
    ErikaSubtitleMemoryFontStatus *out_status);
ErikaStatus erika_presenter_set_subtitle_style(
    ErikaPresenterHandle *handle,
    ErikaSubtitleStyle style);
void erika_subtitle_memory_font_status_free(
    ErikaSubtitleMemoryFontStatus *status);
ErikaStatus erika_presenter_get_subtitle_memory_font_info(
    ErikaPresenterHandle *handle,
    uint64_t font_id,
    ErikaSubtitleMemoryFontInfo *out_info);
void erika_subtitle_memory_font_info_free(ErikaSubtitleMemoryFontInfo *info);
ErikaStatus erika_presenter_set_output_headroom(
    ErikaPresenterHandle *handle,
    float headroom,
    bool known);
ErikaStatus erika_presenter_get_upscaler_status(
    ErikaPresenterHandle *handle,
    ErikaUpscalerStatus *out_status);
ErikaStatus erika_presenter_get_output_status(
    ErikaPresenterHandle *handle,
    ErikaOutputStatus *out_status);
ErikaStatus erika_presenter_get_resource_status(
    ErikaPresenterHandle *handle,
    ErikaPresenterResourceStatus *out_status);
ErikaStatus erika_presenter_add_external_subtitle(
    ErikaPresenterHandle *handle,
    const char *uri,
    int64_t *out_track_id);
ErikaStatus erika_presenter_remove_subtitle_track(
    ErikaPresenterHandle *handle,
    int64_t track_id);
ErikaStatus erika_presenter_select_audio_track(
    ErikaPresenterHandle *handle,
    int64_t track_id);
ErikaStatus erika_presenter_select_subtitle_track(
    ErikaPresenterHandle *handle,
    int64_t track_id);
/* Danmaku (bullet comments). load_* replaces danmaku with one anonymous track;
 * add_*_track builds a named multi-track list. Input is Bilibili XML (*_file,
 * by path/URL) or JSON (*_json, inline). offset_micros shifts one track's
 * timeline; the global offset shifts all. The inline JSON schema is documented
 * in docs/capi_reference.md; layout behavior is in docs/danmaku_architecture.md. */
ErikaStatus erika_presenter_load_danmaku_file(
    ErikaPresenterHandle *handle,
    const char *uri);
ErikaStatus erika_presenter_load_danmaku_json(
    ErikaPresenterHandle *handle,
    const char *json);
ErikaStatus erika_presenter_add_danmaku_track_file(
    ErikaPresenterHandle *handle,
    const char *uri,
    const char *name,
    int64_t offset_micros,
    uint64_t *out_track_id);
ErikaStatus erika_presenter_add_danmaku_track_json(
    ErikaPresenterHandle *handle,
    const char *json,
    const char *name,
    int64_t offset_micros,
    uint64_t *out_track_id);
ErikaStatus erika_presenter_remove_danmaku_track(
    ErikaPresenterHandle *handle,
    uint64_t track_id);
ErikaStatus erika_presenter_set_danmaku_track_enabled(
    ErikaPresenterHandle *handle,
    uint64_t track_id,
    bool enabled);
ErikaStatus erika_presenter_set_danmaku_track_offset(
    ErikaPresenterHandle *handle,
    uint64_t track_id,
    int64_t offset_micros);
ErikaStatus erika_presenter_set_danmaku_global_offset(
    ErikaPresenterHandle *handle,
    int64_t offset_micros);
ErikaStatus erika_presenter_danmaku_tracks(
    ErikaPresenterHandle *handle,
    ErikaDanmakuTrackInfo *out_tracks,
    uintptr_t capacity,
    uintptr_t *out_len);
ErikaStatus erika_presenter_clear_danmaku(ErikaPresenterHandle *handle);
ErikaStatus erika_presenter_set_danmaku_enabled(
    ErikaPresenterHandle *handle,
    bool enabled);
ErikaStatus erika_presenter_set_debug_hud_enabled(
    ErikaPresenterHandle *handle,
    bool enabled);
ErikaStatus erika_presenter_set_danmaku_config(
    ErikaPresenterHandle *handle,
    ErikaDanmakuConfig config);
ErikaStatus erika_presenter_set_danmaku_config_ptr(
    ErikaPresenterHandle *handle,
    const ErikaDanmakuConfig *config);
ErikaStatus erika_presenter_get_danmaku_config(
    ErikaPresenterHandle *handle,
    ErikaDanmakuConfig *out_config);
ErikaStatus erika_presenter_set_danmaku_font(
    ErikaPresenterHandle *handle,
    const char *family,
    const char *file_path);
ErikaStatus erika_presenter_set_danmaku_block_words_json(
    ErikaPresenterHandle *handle,
    const char *json);
ErikaStatus erika_presenter_track_selection(
    ErikaPresenterHandle *handle,
    ErikaTrackSelection *out_selection);
ErikaStatus erika_presenter_tracks(
    ErikaPresenterHandle *handle,
    ErikaTrackInfo *out_tracks,
    uintptr_t capacity,
    uintptr_t *out_len);

/* Surface and presentation. attach_metal_layer for macOS/iOS (CAMetalLayer*),
 * attach_windows_hwnd for Windows (wraps attach_wgpu_surface with WindowsHwnd:
 * hwnd = HWND, hinstance = HINSTANCE). The renderer backend (native Metal,
 * native D3D11, or wgpu) is chosen by presenter config, not the attach call.
 * Call resize_surface on any drawable-size or scale change. */
ErikaStatus erika_presenter_attach_metal_layer(
    ErikaPresenterHandle *handle,
    uint64_t raw_layer,
    uint32_t width,
    uint32_t height,
    double scale);

/* Flutter compositor texture surface. The registrar texture_id identifies the
 * surface; before every render_tick, select the host-owned GPU target with
 * set_flutter_texture_buffer. On Apple, raw_texture is an id<MTLTexture> using
 * BGRA8Unorm. The texture remains owned by the host. */
ErikaStatus erika_presenter_attach_flutter_texture(
    ErikaPresenterHandle *handle,
    ErikaFlutterTextureKind kind,
    int64_t texture_id,
    uint32_t width,
    uint32_t height,
    double scale);

ErikaStatus erika_presenter_set_flutter_texture_buffer(
    ErikaPresenterHandle *handle,
    uint64_t raw_texture,
    uint32_t width,
    uint32_t height);

ErikaStatus erika_presenter_attach_wgpu_surface(
    ErikaPresenterHandle *handle,
    ErikaWgpuSurfaceKind kind,
    uint64_t raw_window,
    uint64_t raw_display,
    uint32_t width,
    uint32_t height,
    double scale);

ErikaStatus erika_presenter_attach_wgpu_surface_with_output_capabilities(
    ErikaPresenterHandle *handle,
    ErikaWgpuSurfaceKind kind,
    uint64_t raw_window,
    uint64_t raw_display,
    uint32_t width,
    uint32_t height,
    double scale,
    ErikaSurfaceOutputCapabilities output_capabilities);

ErikaStatus erika_presenter_attach_windows_hwnd(
    ErikaPresenterHandle *handle,
    uint64_t hwnd,
    uint64_t hinstance,
    uint32_t width,
    uint32_t height,
    double scale);

/* Windows only. Returns an AddRef'd IUnknown for a DirectComposition swap
 * chain created by an attachment whose direct_composition capability is true.
 * The caller owns the returned COM reference and must Release it. */
ErikaStatus erika_presenter_windows_composition_swapchain_iunknown(
    ErikaPresenterHandle *handle,
    void **out_swapchain);

ErikaStatus erika_presenter_resize_surface(
    ErikaPresenterHandle *handle,
    uint32_t width,
    uint32_t height,
    double scale);

ErikaStatus erika_presenter_detach_surface(ErikaPresenterHandle *handle);

/* Render loop and events. Call render_tick once per display frame from the
 * surface's display timer; time_seconds is the host display clock (presentation
 * timestamp) for the frame, used for vsync-quantized scheduling. out_stats may
 * be NULL. poll_event is non-blocking (NoEvent when idle). */
ErikaStatus erika_presenter_render_tick(
    ErikaPresenterHandle *handle,
    double time_seconds,
    ErikaPresenterStats *out_stats);
ErikaStatus erika_presenter_audio_only_tick(
    ErikaPresenterHandle *handle,
    ErikaPresenterStats *out_stats);
ErikaStatus erika_presenter_get_stats(
    ErikaPresenterHandle *handle,
    ErikaPresenterStats *out_stats);
ErikaStatus erika_presenter_poll_event(ErikaPresenterHandle *handle, ErikaEvent *out_event);

/* JSON bridge used by embedders whose platform channel already serializes
 * structured arguments. Returned strings are owned by Erika and must be
 * released with erika_string_free. poll_event_json returns NULL when idle. */
char *erika_presenter_invoke_json(
    ErikaPresenterHandle *handle,
    const char *method,
    const char *arguments_json);
char *erika_presenter_render_tick_json(
    ErikaPresenterHandle *handle,
    double time_seconds);
char *erika_presenter_poll_event_json(ErikaPresenterHandle *handle);

/* Screenshot: render the current composited frame (video + subtitle + danmaku)
 * off-screen into a caller-allocated RGBA8 buffer at the requested size.
 * out_capacity must be >= width*height*4. Fails if no frame is available yet. */
ErikaStatus erika_presenter_capture_frame_rgba(
    ErikaPresenterHandle *handle,
    uint32_t width,
    uint32_t height,
    uint8_t *out_rgba,
    uintptr_t out_capacity);

#ifdef __cplusplus
}
#endif

#endif
