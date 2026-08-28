#include "erika_flutter_plugin.h"

#include <flutter/event_channel.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <d2d1effects.h>
#include <dcomp.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cctype>
#include <cmath>
#include <cstdlib>
#include <cwchar>
#include <fstream>
#include <filesystem>
#include <iomanip>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace erika_flutter {
namespace {

constexpr int64_t kWindowOverlayViewId = -1;
constexpr wchar_t kOverlayWindowClassName[] = L"ErikaFlutterVideoOverlay";
constexpr wchar_t kFrameMessageWindowClassName[] = L"ErikaFlutterFrameScheduler";
constexpr wchar_t kFlutterRegularHostWindowClassName[] =
    L"FLUTTER_HOST_WINDOW";
constexpr UINT kFrameTimerMessage = WM_APP + 1;
constexpr UINT kSmtcMessage = WM_APP + 2;
constexpr double kFrameTimerMinFps = 1.0;
constexpr double kFrameTimerMaxFps = 1000.0;
constexpr double kFrameTimerDefaultFps = 60.0;
constexpr double kFrameTimerMinIntervalMs = 1.0;
constexpr DWORD kWaitableTimerHighResolutionFlag = 0x00000002;

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

class PluginError : public std::runtime_error {
 public:
  explicit PluginError(const std::string& message) : std::runtime_error(message) {}
};

void CheckHResult(HRESULT result, const char* operation) {
  if (SUCCEEDED(result)) {
    return;
  }
  std::ostringstream message;
  message << operation << " failed (HRESULT=0x" << std::hex << std::uppercase
          << static_cast<uint32_t>(result) << ")";
  throw PluginError(message.str());
}

std::string LastErrorMessage() {
  const DWORD error = GetLastError();
  if (error == 0) {
    return {};
  }

  LPWSTR buffer = nullptr;
  const DWORD size = FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, error, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      reinterpret_cast<LPWSTR>(&buffer), 0, nullptr);
  if (size == 0 || buffer == nullptr) {
    return "Win32 error " + std::to_string(error);
  }

  const int utf8_size =
      WideCharToMultiByte(CP_UTF8, 0, buffer, static_cast<int>(size), nullptr, 0,
                          nullptr, nullptr);
  std::string result(static_cast<size_t>(std::max(0, utf8_size)), '\0');
  if (utf8_size > 0) {
    WideCharToMultiByte(CP_UTF8, 0, buffer, static_cast<int>(size),
                        result.data(), utf8_size, nullptr, nullptr);
  }
  LocalFree(buffer);
  while (!result.empty() &&
         (result.back() == '\n' || result.back() == '\r' || result.back() == ' ')) {
    result.pop_back();
  }
  return result.empty() ? "Win32 error " + std::to_string(error) : result;
}

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return {};
  }
  const int size =
      MultiByteToWideChar(CP_UTF8, 0, value.data(),
                          static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) {
    return {};
  }
  std::wstring result(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      result.data(), size);
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return {};
  }
  const int size =
      WideCharToMultiByte(CP_UTF8, 0, value.data(),
                          static_cast<int>(value.size()), nullptr, 0, nullptr,
                          nullptr);
  if (size <= 0) {
    return {};
  }
  std::string result(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      result.data(), size, nullptr, nullptr);
  return result;
}

std::string PathToUtf8(const std::filesystem::path& path) {
  return WideToUtf8(path.wstring());
}

std::string SafeUtf8Message(const char* message) {
  if (message == nullptr || *message == '\0') {
    return "Unknown Erika plugin error.";
  }
  const int wide_size = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, message, -1, nullptr, 0);
  if (wide_size > 0) {
    return std::string(message);
  }
  const int fallback_size =
      MultiByteToWideChar(CP_ACP, 0, message, -1, nullptr, 0);
  if (fallback_size <= 0) {
    return "Erika plugin error contained invalid text.";
  }
  std::wstring wide(static_cast<size_t>(fallback_size), L'\0');
  MultiByteToWideChar(CP_ACP, 0, message, -1, wide.data(), fallback_size);
  if (!wide.empty() && wide.back() == L'\0') {
    wide.pop_back();
  }
  auto result = WideToUtf8(wide);
  return result.empty() ? "Erika plugin error contained invalid text." : result;
}

std::optional<std::filesystem::path> EnvironmentPath(const wchar_t* name) {
  const DWORD size = GetEnvironmentVariableW(name, nullptr, 0);
  if (size == 0) {
    return std::nullopt;
  }
  std::wstring value(size, L'\0');
  const DWORD written = GetEnvironmentVariableW(name, value.data(), size);
  if (written == 0) {
    return std::nullopt;
  }
  value.resize(written);
  if (value.empty()) {
    return std::nullopt;
  }
  return std::filesystem::path(value);
}

std::filesystem::path ExecutableDirectory() {
  std::wstring buffer(MAX_PATH, L'\0');
  DWORD size = GetModuleFileNameW(nullptr, buffer.data(),
                                 static_cast<DWORD>(buffer.size()));
  while (size == buffer.size()) {
    buffer.resize(buffer.size() * 2);
    size = GetModuleFileNameW(nullptr, buffer.data(),
                              static_cast<DWORD>(buffer.size()));
  }
  if (size == 0) {
    return {};
  }
  buffer.resize(size);
  return std::filesystem::path(buffer).parent_path();
}

std::filesystem::path SourceTreeRoot() {
#if defined(ERIKA_REPO_ROOT_PATH)
  return std::filesystem::path(ERIKA_REPO_ROOT_PATH);
#else
  std::filesystem::path source_file(__FILE__);
  return source_file.parent_path()  // windows
      .parent_path()                // erika_flutter
      .parent_path()                // packages
      .parent_path();               // repo root
#endif
}

std::filesystem::path LogFilePath() {
  if (auto value = EnvironmentPath(L"ERIKA_FLUTTER_LOG_FILE")) {
    return *value;
  }
  if (auto value = EnvironmentPath(L"LOCALAPPDATA")) {
    return *value / L"Erika" / L"erika_flutter_windows.log";
  }
  return std::filesystem::temp_directory_path() / L"erika_flutter_windows.log";
}

std::string TimestampForLog() {
  const auto now = std::chrono::system_clock::now();
  const auto time = std::chrono::system_clock::to_time_t(now);
  std::tm local_time{};
  localtime_s(&local_time, &time);
  std::ostringstream stream;
  stream << std::put_time(&local_time, "%Y-%m-%d %H:%M:%S");
  return stream.str();
}

void DebugLog(const std::string& message) {
  const std::string line = TimestampForLog() + " [tid " +
                           std::to_string(GetCurrentThreadId()) + "] " +
                           message;
  OutputDebugStringW((L"ErikaFlutterPlugin: " + Utf8ToWide(line) + L"\n").c_str());
  static std::mutex log_mutex;
  std::lock_guard<std::mutex> lock(log_mutex);
  try {
    const auto path = LogFilePath();
    std::filesystem::create_directories(path.parent_path());
    std::ofstream file(path, std::ios::app | std::ios::binary);
    file << line << "\n";
  } catch (...) {
  }
}

double NowSeconds() {
  using clock = std::chrono::steady_clock;
  const auto now = clock::now().time_since_epoch();
  return std::chrono::duration<double>(now).count();
}

double ScaleForWindow(HWND hwnd) {
  if (hwnd == nullptr) {
    return 1.0;
  }
  const UINT dpi = GetDpiForWindow(hwnd);
  if (dpi == 0) {
    return 1.0;
  }
  return std::max(1.0, static_cast<double>(dpi) / 96.0);
}

HWND RootHostWindow(HWND flutter_window) {
  if (flutter_window == nullptr) {
    return nullptr;
  }
  const HWND root = GetAncestor(flutter_window, GA_ROOT);
  return root != nullptr ? root : flutter_window;
}

struct FlutterRegularHostSearch {
  DWORD process_id = 0;
  HWND result = nullptr;
};

BOOL CALLBACK FindFlutterRegularHostWindow(HWND window, LPARAM parameter) {
  auto* search = reinterpret_cast<FlutterRegularHostSearch*>(parameter);
  DWORD process_id = 0;
  GetWindowThreadProcessId(window, &process_id);
  if (process_id != search->process_id) {
    return TRUE;
  }

  wchar_t class_name[64] = {};
  if (GetClassNameW(window, class_name, 64) == 0 ||
      std::wcscmp(class_name, kFlutterRegularHostWindowClassName) != 0) {
    return TRUE;
  }
  search->result = window;
  return FALSE;
}

HWND ResolveFlutterRegularHostWindow() {
  FlutterRegularHostSearch search{GetCurrentProcessId(), nullptr};
  EnumWindows(FindFlutterRegularHostWindow,
              reinterpret_cast<LPARAM>(&search));
  return search.result;
}

int LogicalToPhysical(HWND hwnd, double value) {
  return static_cast<int>(std::llround(value * ScaleForWindow(hwnd)));
}

std::optional<double> RefreshRateForWindow(HWND hwnd) {
  HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  if (monitor == nullptr) {
    return std::nullopt;
  }

  MONITORINFOEXW monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  if (!GetMonitorInfoW(monitor, &monitor_info)) {
    return std::nullopt;
  }

  DEVMODEW mode{};
  mode.dmSize = sizeof(mode);
  if (!EnumDisplaySettingsW(monitor_info.szDevice, ENUM_CURRENT_SETTINGS,
                            &mode)) {
    return std::nullopt;
  }
  if ((mode.dmFields & DM_DISPLAYFREQUENCY) == 0 ||
      mode.dmDisplayFrequency <= 1) {
    return std::nullopt;
  }
  const double fps = static_cast<double>(mode.dmDisplayFrequency);
  if (!std::isfinite(fps) || fps < kFrameTimerMinFps ||
      fps > kFrameTimerMaxFps) {
    return std::nullopt;
  }
  return fps;
}

double FrameTimerTargetFps(HWND hwnd) {
  const auto env = EnvironmentPath(L"ERIKA_FLUTTER_TARGET_FPS");
  if (env) {
    try {
      const double fps = std::stod(env->wstring());
      if (std::isfinite(fps) && fps > 0.0) {
        return std::clamp(fps, kFrameTimerMinFps, kFrameTimerMaxFps);
      }
    } catch (...) {
    }
  }
  if (auto refresh_rate = RefreshRateForWindow(hwnd)) {
    return std::clamp(*refresh_rate, kFrameTimerMinFps, kFrameTimerMaxFps);
  }
  return kFrameTimerDefaultFps;
}

double FrameTimerIntervalMs(double fps) {
  if (!std::isfinite(fps) || fps <= 0.0) {
    fps = kFrameTimerDefaultFps;
  }
  return std::max(kFrameTimerMinIntervalMs, 1000.0 / fps);
}

LARGE_INTEGER RelativeWaitTimeForMilliseconds(double milliseconds) {
  LARGE_INTEGER due_time{};
  due_time.QuadPart =
      -std::max<LONGLONG>(1, static_cast<LONGLONG>(
                                 std::llround(milliseconds * 10000.0)));
  return due_time;
}

bool FrameTraceEnabled() {
  const auto value = EnvironmentPath(L"ERIKA_FLUTTER_FRAME_TRACE");
  if (!value) {
    return false;
  }
  const auto text = value->wstring();
  return text != L"0" && text != L"false" && text != L"FALSE";
}

std::string StatusName(ErikaStatus status) {
  switch (status) {
    case ErikaStatus_Ok:
      return "Ok";
    case ErikaStatus_NullPointer:
      return "NullPointer";
    case ErikaStatus_InvalidUtf8:
      return "InvalidUtf8";
    case ErikaStatus_PlayerError:
      return "PlayerError";
    case ErikaStatus_Panic:
      return "Panic";
    case ErikaStatus_NoEvent:
      return "NoEvent";
  }
  return "Unknown";
}

void Check(ErikaStatus status,
           const char* operation,
           const std::string& native_error = {}) {
  if (status == ErikaStatus_Ok) {
    return;
  }
  std::string message = std::string(operation) + " failed with ErikaStatus_" +
                        StatusName(status) + " (" +
                        std::to_string(static_cast<int>(status)) + ")";
  if (!native_error.empty()) {
    message += ": " + native_error;
  }
  DebugLog(message);
  throw PluginError(message);
}

const EncodableMap& DictionaryArgs(const EncodableValue* arguments) {
  if (arguments == nullptr) {
    throw PluginError("Arguments must be a dictionary.");
  }
  const auto* map = std::get_if<EncodableMap>(arguments);
  if (map == nullptr) {
    throw PluginError("Arguments must be a dictionary.");
  }
  return *map;
}

const EncodableValue* FindArg(const EncodableMap& args, const char* name) {
  const auto it = args.find(EncodableValue(std::string(name)));
  if (it == args.end()) {
    return nullptr;
  }
  return &it->second;
}

std::optional<int64_t> Int64Value(const EncodableValue* value) {
  if (value == nullptr || std::holds_alternative<std::monostate>(*value)) {
    return std::nullopt;
  }
  if (const auto* v = std::get_if<int32_t>(value)) {
    return static_cast<int64_t>(*v);
  }
  if (const auto* v = std::get_if<int64_t>(value)) {
    return *v;
  }
  if (const auto* v = std::get_if<double>(value)) {
    if (std::isfinite(*v)) {
      return static_cast<int64_t>(*v);
    }
  }
  if (const auto* v = std::get_if<std::string>(value)) {
    try {
      return std::stoll(*v);
    } catch (...) {
      return std::nullopt;
    }
  }
  return std::nullopt;
}

int64_t RequiredInt64(const EncodableMap& args, const char* name) {
  const auto value = Int64Value(FindArg(args, name));
  if (!value) {
    throw PluginError(std::string(name) + " is required.");
  }
  return *value;
}

std::optional<double> DoubleValue(const EncodableValue* value) {
  if (value == nullptr || std::holds_alternative<std::monostate>(*value)) {
    return std::nullopt;
  }
  if (const auto* v = std::get_if<double>(value)) {
    return std::isfinite(*v) ? std::optional<double>(*v) : std::nullopt;
  }
  if (const auto* v = std::get_if<int32_t>(value)) {
    return static_cast<double>(*v);
  }
  if (const auto* v = std::get_if<int64_t>(value)) {
    return static_cast<double>(*v);
  }
  if (const auto* v = std::get_if<std::string>(value)) {
    try {
      const double parsed = std::stod(*v);
      return std::isfinite(parsed) ? std::optional<double>(parsed)
                                   : std::nullopt;
    } catch (...) {
      return std::nullopt;
    }
  }
  return std::nullopt;
}

std::optional<bool> BoolValue(const EncodableValue* value) {
  if (value == nullptr || std::holds_alternative<std::monostate>(*value)) {
    return std::nullopt;
  }
  if (const auto* v = std::get_if<bool>(value)) {
    return *v;
  }
  if (const auto* v = std::get_if<int32_t>(value)) {
    return *v != 0;
  }
  if (const auto* v = std::get_if<int64_t>(value)) {
    return *v != 0;
  }
  if (const auto* v = std::get_if<std::string>(value)) {
    std::string lower = *v;
    std::transform(lower.begin(), lower.end(), lower.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    if (lower == "1" || lower == "true" || lower == "yes" || lower == "on") {
      return true;
    }
    if (lower == "0" || lower == "false" || lower == "no" ||
        lower == "off") {
      return false;
    }
  }
  return std::nullopt;
}

std::optional<std::string> StringValue(const EncodableValue* value) {
  if (value == nullptr || std::holds_alternative<std::monostate>(*value)) {
    return std::nullopt;
  }
  if (const auto* v = std::get_if<std::string>(value)) {
    return *v;
  }
  return std::nullopt;
}

std::string RequiredString(const EncodableMap& args, const char* name) {
  const auto value = StringValue(FindArg(args, name));
  if (!value) {
    throw PluginError(std::string(name) + " is required.");
  }
  return *value;
}

int64_t OptionalTrackId(const EncodableValue* value) {
  const auto track_id = Int64Value(value);
  if (!track_id || *track_id < 0) {
    return -1;
  }
  return *track_id;
}

ErikaDanmakuConfig DefaultDanmakuConfig() {
  ErikaDanmakuConfig config{};
  config.enabled = true;
  config.font_size = 30.0f;
  config.opacity = 1.0f;
  config.display_area = 1.0f;
  config.scroll_duration_seconds = 10.0f;
  config.scroll_speed_factor = 1.0f;
  config.track_gap_ratio = 0.15f;
  config.outline_width = 1.0f;
  config.shadow_offset_x = 1.0f;
  config.shadow_offset_y = 1.0f;
  config.allow_scroll_overwrite = true;
  config.shadow_style = 3;
  return config;
}

EncodableValue NullableString(char* value) {
  if (value == nullptr) {
    return EncodableValue();
  }
  return EncodableValue(std::string(value));
}

EncodableValue TrackSelectionToMap(const ErikaTrackSelection& selection) {
  return EncodableValue(EncodableMap{
      {EncodableValue("video"), EncodableValue(static_cast<int64_t>(selection.video))},
      {EncodableValue("audio"), EncodableValue(static_cast<int64_t>(selection.audio))},
      {EncodableValue("subtitle"),
       EncodableValue(static_cast<int64_t>(selection.subtitle))},
  });
}

EncodableValue UpscalerStatusToMap(const ErikaUpscalerStatus& status) {
  return EncodableValue(EncodableMap{
      {EncodableValue("requestedMode"),
       EncodableValue(static_cast<int32_t>(status.requested_mode))},
      {EncodableValue("activeBackend"),
       EncodableValue(static_cast<int32_t>(status.active_backend))},
      {EncodableValue("fallbackCount"),
       EncodableValue(static_cast<int64_t>(status.fallback_count))},
      {EncodableValue("upscaledFrames"),
       EncodableValue(static_cast<int64_t>(status.upscaled_frames))},
      {EncodableValue("lastEncodeMicros"),
       EncodableValue(static_cast<int64_t>(status.last_encode_micros))},
      {EncodableValue("lastGpuMicros"),
       EncodableValue(static_cast<int64_t>(status.last_gpu_micros))},
  });
}

EncodableValue PresenterStatsToMap(const ErikaPresenterStats& stats) {
  return EncodableValue(EncodableMap{
      {EncodableValue("decodedVideoFrames"),
       EncodableValue(static_cast<int64_t>(stats.decoded_video_frames))},
      {EncodableValue("renderedVideoFrames"),
       EncodableValue(static_cast<int64_t>(stats.rendered_video_frames))},
      {EncodableValue("renderedTestFrames"),
       EncodableValue(static_cast<int64_t>(stats.rendered_test_frames))},
      {EncodableValue("pushedAudioFrames"),
       EncodableValue(static_cast<int64_t>(stats.pushed_audio_frames))},
      {EncodableValue("overlayFrames"),
       EncodableValue(static_cast<int64_t>(stats.overlay_frames))},
      {EncodableValue("danmakuFrames"),
       EncodableValue(static_cast<int64_t>(stats.danmaku_frames))},
      {EncodableValue("danmakuItems"),
       EncodableValue(static_cast<int64_t>(stats.danmaku_items))},
      {EncodableValue("importFailures"),
       EncodableValue(static_cast<int64_t>(stats.import_failures))},
      {EncodableValue("renderFailures"),
       EncodableValue(static_cast<int64_t>(stats.render_failures))},
      {EncodableValue("audioFailures"),
       EncodableValue(static_cast<int64_t>(stats.audio_failures))},
      {EncodableValue("softwareVideoFrames"),
       EncodableValue(static_cast<int64_t>(stats.software_video_frames))},
      {EncodableValue("hardwareVideoFrames"),
       EncodableValue(static_cast<int64_t>(stats.hardware_video_frames))},
      {EncodableValue("zeroCopyVideoFrames"),
       EncodableValue(static_cast<int64_t>(stats.zero_copy_video_frames))},
      {EncodableValue("cpuVideoFrameFallbacks"),
       EncodableValue(static_cast<int64_t>(stats.cpu_video_frame_fallbacks))},
      {EncodableValue("lastRenderMicros"),
       EncodableValue(static_cast<int64_t>(stats.last_render_micros))},
      {EncodableValue("lastRenderCurrentMicros"),
       EncodableValue(static_cast<int64_t>(stats.last_render_current_micros))},
      {EncodableValue("audioClockReadFrames"),
       EncodableValue(static_cast<int64_t>(stats.audio_clock_read_frames))},
      {EncodableValue("audioClockQueuedFrames"),
       EncodableValue(static_cast<int64_t>(stats.audio_clock_queued_frames))},
      {EncodableValue("audioClockUnderflowFrames"),
       EncodableValue(static_cast<int64_t>(stats.audio_clock_underflow_frames))},
      {EncodableValue("directZeroCopyVideoFrames"),
       EncodableValue(static_cast<int64_t>(stats.direct_zero_copy_video_frames))},
      {EncodableValue("sharedHandleVideoFrames"),
       EncodableValue(static_cast<int64_t>(stats.shared_handle_video_frames))},
      {EncodableValue("hdrSourceFrames"),
       EncodableValue(static_cast<int64_t>(stats.hdr_source_frames))},
      {EncodableValue("hdr10OutputFrames"),
       EncodableValue(static_cast<int64_t>(stats.hdr10_output_frames))},
      {EncodableValue("sdrTonemapFrames"),
       EncodableValue(static_cast<int64_t>(stats.sdr_tonemap_frames))},
      {EncodableValue("hdr10MetadataUpdates"),
       EncodableValue(static_cast<int64_t>(stats.hdr10_metadata_updates))},
      {EncodableValue("hdr10MetadataFailures"),
       EncodableValue(static_cast<int64_t>(stats.hdr10_metadata_failures))},
      {EncodableValue("hdr10OutputFailures"),
       EncodableValue(static_cast<int64_t>(stats.hdr10_output_failures))},
      {EncodableValue("hdr10OutputActive"),
       EncodableValue(stats.hdr10_output_active)},
      {EncodableValue("videoFrameBackpressureDrops"),
       EncodableValue(
           static_cast<int64_t>(stats.video_frame_backpressure_drops))},
  });
}

EncodableValue OutputStatusToMap(const ErikaOutputStatus& status) {
  EncodableMap map;
  map[EncodableValue("requestedMode")] =
      EncodableValue(status.requested_mode);
  map[EncodableValue("activeEncoding")] =
      EncodableValue(status.active_encoding);
  map[EncodableValue("surfaceFormat")] =
      EncodableValue(status.surface_format);
  map[EncodableValue("nativeDataSpace")] =
      EncodableValue(status.native_data_space);
  map[EncodableValue("requestedHeadroom")] =
      EncodableValue(static_cast<double>(status.requested_headroom));
  map[EncodableValue("activeHeadroom")] =
      EncodableValue(static_cast<double>(status.active_headroom));
  map[EncodableValue("activeHeadroomKnown")] =
      EncodableValue(status.active_headroom_known);
  map[EncodableValue("extendedLinearActive")] =
      EncodableValue(status.extended_linear_active);
  map[EncodableValue("fallbackReason")] =
      EncodableValue(status.fallback_reason);
  map[EncodableValue("fallbackCount")] =
      EncodableValue(static_cast<int64_t>(status.fallback_count));
  map[EncodableValue("dataSpaceFailures")] =
      EncodableValue(static_cast<int64_t>(status.data_space_failures));
  map[EncodableValue("headroomUpdates")] =
      EncodableValue(static_cast<int64_t>(status.headroom_updates));
  map[EncodableValue("extendedLinearFrames")] =
      EncodableValue(static_cast<int64_t>(status.extended_linear_frames));
  return EncodableValue(std::move(map));
}

EncodableValue ResourceStatusToMap(const ErikaPresenterResourceStatus& status) {
  EncodableMap map;
  map[EncodableValue("deviceCurrentAllocatedBytes")] =
      EncodableValue(static_cast<int64_t>(status.device_current_allocated_bytes));
  map[EncodableValue("deviceRecommendedWorkingSetBytes")] =
      EncodableValue(
          static_cast<int64_t>(status.device_recommended_working_set_bytes));
  map[EncodableValue("drawableEstimatedBytes")] =
      EncodableValue(static_cast<int64_t>(status.drawable_estimated_bytes));
  map[EncodableValue("videoFrameBytes")] =
      EncodableValue(static_cast<int64_t>(status.video_frame_bytes));
  map[EncodableValue("overlayAtlasBytes")] =
      EncodableValue(static_cast<int64_t>(status.overlay_atlas_bytes));
  map[EncodableValue("danmakuAtlasBytes")] =
      EncodableValue(static_cast<int64_t>(status.danmaku_atlas_bytes));
  map[EncodableValue("danmakuVertexBufferBytes")] =
      EncodableValue(static_cast<int64_t>(status.danmaku_vertex_buffer_bytes));
  map[EncodableValue("upscalerBytes")] =
      EncodableValue(static_cast<int64_t>(status.upscaler_bytes));
  map[EncodableValue("rendererTrackedBytes")] =
      EncodableValue(static_cast<int64_t>(status.renderer_tracked_bytes));
  map[EncodableValue("presenterCpuDanmakuAtlasBytes")] =
      EncodableValue(static_cast<int64_t>(status.presenter_cpu_danmaku_atlas_bytes));
  map[EncodableValue("drawableCount")] =
      EncodableValue(static_cast<int64_t>(status.drawable_count));
  map[EncodableValue("outputModeSwitches")] =
      EncodableValue(static_cast<int64_t>(status.output_mode_switches));
  return EncodableValue(std::move(map));
}

EncodableValue SubtitleMemoryFontStatusToMap(
    const ErikaSubtitleMemoryFontStatus& status) {
  EncodableList selected_ids;
  selected_ids.reserve(status.selected_count);
  for (uintptr_t index = 0; index < status.selected_count; ++index) {
    selected_ids.emplace_back(static_cast<int64_t>(status.selected_ids[index]));
  }
  return EncodableValue(EncodableMap{
      {EncodableValue("registeredCount"),
       EncodableValue(static_cast<int64_t>(status.registered_count))},
      {EncodableValue("registeredBytes"),
       EncodableValue(static_cast<int64_t>(status.registered_bytes))},
      {EncodableValue("selectedCount"),
       EncodableValue(static_cast<int64_t>(status.selected_count))},
      {EncodableValue("generation"),
       EncodableValue(static_cast<int64_t>(status.generation))},
      {EncodableValue("selectedIds"), EncodableValue(std::move(selected_ids))},
  });
}

}  // namespace

struct ErikaFlutterPlugin::ErikaNativeLibrary {
  using CreateFn = ErikaPresenterHandle* (*)();
  using CreateWithConfigFn = ErikaPresenterHandle* (*)(ErikaPresenterConfig);
  using CreateWithOutputModeFn = ErikaPresenterHandle* (*)(int32_t, float);
  using DestroyFn = void (*)(ErikaPresenterHandle*);
  using OpenFn = ErikaStatus (*)(ErikaPresenterHandle*, const char*);
  using OpenWithHeadersFn = ErikaStatus (*)(ErikaPresenterHandle*, const char*, const ErikaHttpHeader*, uintptr_t);
  using CommandFn = ErikaStatus (*)(ErikaPresenterHandle*);
  using SeekFn = ErikaStatus (*)(ErikaPresenterHandle*, uint64_t);
  using SetPlaybackRateFn = ErikaStatus (*)(ErikaPresenterHandle*, double);
  using SetVolumeFn = ErikaStatus (*)(ErikaPresenterHandle*, double);
  using SetUpscalerFn = ErikaStatus (*)(ErikaPresenterHandle*, int32_t);
  using SetSubtitleScaleFn = ErikaStatus (*)(ErikaPresenterHandle*, double);
  using SetSubtitleFontFn =
      ErikaStatus (*)(ErikaPresenterHandle*, const char*, const char*);
  using SetSubtitleStyleFn =
      ErikaStatus (*)(ErikaPresenterHandle*, ErikaSubtitleStyle);
  using RegisterSubtitleMemoryFontFn = ErikaStatus (*)(
      ErikaPresenterHandle*, const uint8_t*, uintptr_t, uint64_t*);
  using SelectSubtitleMemoryFontsFn = ErikaStatus (*)(
      ErikaPresenterHandle*, const uint64_t*, uintptr_t);
  using GetSubtitleMemoryFontStatusFn = ErikaStatus (*)(
      ErikaPresenterHandle*, ErikaSubtitleMemoryFontStatus*);
  using GetUpscalerStatusFn =
      ErikaStatus (*)(ErikaPresenterHandle*, ErikaUpscalerStatus*);
  using GetOutputStatusFn =
      ErikaStatus (*)(ErikaPresenterHandle*, ErikaOutputStatus*);
  using GetResourceStatusFn =
      ErikaStatus (*)(ErikaPresenterHandle*, ErikaPresenterResourceStatus*);
  using SelectTrackFn = ErikaStatus (*)(ErikaPresenterHandle*, int64_t);
  using AddExternalSubtitleFn =
      ErikaStatus (*)(ErikaPresenterHandle*, const char*, int64_t*);
  using RemoveSubtitleTrackFn = ErikaStatus (*)(ErikaPresenterHandle*, int64_t);
  using LoadDanmakuFn = ErikaStatus (*)(ErikaPresenterHandle*, const char*);
  using AddDanmakuTrackFn =
      ErikaStatus (*)(ErikaPresenterHandle*, const char*, const char*, int64_t,
                      uint64_t*);
  using RemoveDanmakuTrackFn = ErikaStatus (*)(ErikaPresenterHandle*, uint64_t);
  using SetDanmakuTrackEnabledFn =
      ErikaStatus (*)(ErikaPresenterHandle*, uint64_t, bool);
  using SetDanmakuTrackOffsetFn =
      ErikaStatus (*)(ErikaPresenterHandle*, uint64_t, int64_t);
  using SetDanmakuGlobalOffsetFn =
      ErikaStatus (*)(ErikaPresenterHandle*, int64_t);
  using DanmakuTracksFn =
      ErikaStatus (*)(ErikaPresenterHandle*, ErikaDanmakuTrackInfo*, uintptr_t,
                      uintptr_t*);
  using ClearDanmakuFn = ErikaStatus (*)(ErikaPresenterHandle*);
  using SetDanmakuEnabledFn = ErikaStatus (*)(ErikaPresenterHandle*, bool);
  using SetDebugHudEnabledFn = ErikaStatus (*)(ErikaPresenterHandle*, bool);
  using SetDanmakuConfigFn =
      ErikaStatus (*)(ErikaPresenterHandle*, const ErikaDanmakuConfig*);
  using GetDanmakuConfigFn =
      ErikaStatus (*)(ErikaPresenterHandle*, ErikaDanmakuConfig*);
  using SetDanmakuFontFn =
      ErikaStatus (*)(ErikaPresenterHandle*, const char*, const char*);
  using TrackSelectionFn =
      ErikaStatus (*)(ErikaPresenterHandle*, ErikaTrackSelection*);
  using TracksFn =
      ErikaStatus (*)(ErikaPresenterHandle*, ErikaTrackInfo*, uintptr_t,
                      uintptr_t*);
  using TrackInfoFreeFn = void (*)(ErikaTrackInfo*);
  using DanmakuTrackInfoFreeFn = void (*)(ErikaDanmakuTrackInfo*);
  using AttachWindowsHwndFn =
      ErikaStatus (*)(ErikaPresenterHandle*, uint64_t, uint64_t, uint32_t,
                      uint32_t, double);
  using AttachWgpuSurfaceWithOutputCapabilitiesFn = ErikaStatus (*)(
      ErikaPresenterHandle*, ErikaWgpuSurfaceKind, uint64_t, uint64_t,
      uint32_t, uint32_t, double, ErikaSurfaceOutputCapabilities);
  using GetWindowsCompositionSwapchainFn =
      ErikaStatus (*)(ErikaPresenterHandle*, void**);
  using ResizeSurfaceFn =
      ErikaStatus (*)(ErikaPresenterHandle*, uint32_t, uint32_t, double);
  using RenderTickFn =
      ErikaStatus (*)(ErikaPresenterHandle*, double, ErikaPresenterStats*);
  using PollEventFn = ErikaStatus (*)(ErikaPresenterHandle*, ErikaEvent*);
  using LastErrorMessageFn = char* (*)();
  using StringFreeFn = void (*)(char*);

  static std::shared_ptr<ErikaNativeLibrary> Shared() {
    static std::mutex mutex;
    static std::weak_ptr<ErikaNativeLibrary> weak;
    std::lock_guard<std::mutex> lock(mutex);
    if (auto shared = weak.lock()) {
      return shared;
    }
    auto shared = std::shared_ptr<ErikaNativeLibrary>(new ErikaNativeLibrary());
    weak = shared;
    return shared;
  }

  ~ErikaNativeLibrary() {
    if (module != nullptr) {
      FreeLibrary(module);
      module = nullptr;
    }
  }

  ErikaPresenterHandle* CreatePresenter(ErikaPresenterConfig config) const {
    if (create_with_config != nullptr) {
      return create_with_config(config);
    }
    if (config.video_alpha_mode != ErikaVideoAlphaMode_Opaque) {
      throw PluginError(
          "The loaded erika_capi.dll does not support transparent-video "
          "presenter configuration. Update the bundled Erika runtime.");
    }
    if (create_with_output_mode != nullptr) {
      return create_with_output_mode(config.output_mode, config.edr_headroom);
    }
    return create();
  }

  std::string TakeLastError() const {
    if (last_error_message == nullptr) {
      return {};
    }
    char* raw = last_error_message();
    if (raw == nullptr) {
      return {};
    }
    std::string message = SafeUtf8Message(raw);
    if (string_free != nullptr) {
      string_free(raw);
    }
    return message;
  }

  HMODULE module = nullptr;
  CreateFn create = nullptr;
  CreateWithConfigFn create_with_config = nullptr;
  CreateWithOutputModeFn create_with_output_mode = nullptr;
  DestroyFn destroy = nullptr;
  OpenFn open = nullptr;
  OpenWithHeadersFn open_with_headers = nullptr;
  CommandFn play = nullptr;
  CommandFn pause = nullptr;
  CommandFn stop = nullptr;
  CommandFn close = nullptr;
  SeekFn seek = nullptr;
  SetPlaybackRateFn set_playback_rate = nullptr;
  SetVolumeFn set_volume = nullptr;
  SetUpscalerFn set_upscaler = nullptr;
  SetSubtitleScaleFn set_subtitle_scale = nullptr;
  SetSubtitleFontFn set_subtitle_font = nullptr;
  SetSubtitleStyleFn set_subtitle_style = nullptr;
  RegisterSubtitleMemoryFontFn register_subtitle_memory_font = nullptr;
  SelectSubtitleMemoryFontsFn select_subtitle_memory_fonts = nullptr;
  CommandFn clear_subtitle_memory_fonts = nullptr;
  GetSubtitleMemoryFontStatusFn get_subtitle_memory_font_status = nullptr;
  void (*free_subtitle_memory_font_status)(ErikaSubtitleMemoryFontStatus*) = nullptr;
  GetUpscalerStatusFn get_upscaler_status = nullptr;
  GetOutputStatusFn get_output_status = nullptr;
  GetResourceStatusFn get_resource_status = nullptr;
  SelectTrackFn select_audio_track = nullptr;
  SelectTrackFn select_subtitle_track = nullptr;
  AddExternalSubtitleFn add_external_subtitle = nullptr;
  RemoveSubtitleTrackFn remove_subtitle_track = nullptr;
  LoadDanmakuFn load_danmaku_file = nullptr;
  LoadDanmakuFn load_danmaku_json = nullptr;
  AddDanmakuTrackFn add_danmaku_track_file = nullptr;
  AddDanmakuTrackFn add_danmaku_track_json = nullptr;
  RemoveDanmakuTrackFn remove_danmaku_track = nullptr;
  SetDanmakuTrackEnabledFn set_danmaku_track_enabled = nullptr;
  SetDanmakuTrackOffsetFn set_danmaku_track_offset = nullptr;
  SetDanmakuGlobalOffsetFn set_danmaku_global_offset = nullptr;
  DanmakuTracksFn danmaku_tracks = nullptr;
  ClearDanmakuFn clear_danmaku = nullptr;
  SetDanmakuEnabledFn set_danmaku_enabled = nullptr;
  SetDebugHudEnabledFn set_debug_hud_enabled = nullptr;
  SetDanmakuConfigFn set_danmaku_config = nullptr;
  GetDanmakuConfigFn get_danmaku_config = nullptr;
  SetDanmakuFontFn set_danmaku_font = nullptr;
  LoadDanmakuFn set_danmaku_block_words_json = nullptr;
  TrackSelectionFn track_selection = nullptr;
  TracksFn tracks = nullptr;
  TrackInfoFreeFn free_track_info = nullptr;
  DanmakuTrackInfoFreeFn free_danmaku_track_info = nullptr;
  AttachWindowsHwndFn attach_windows_hwnd = nullptr;
  AttachWgpuSurfaceWithOutputCapabilitiesFn
      attach_wgpu_surface_with_output_capabilities = nullptr;
  GetWindowsCompositionSwapchainFn windows_composition_swapchain = nullptr;
  ResizeSurfaceFn resize_surface = nullptr;
  CommandFn detach_surface = nullptr;
  RenderTickFn render_tick = nullptr;
  PollEventFn poll_event = nullptr;
  LastErrorMessageFn last_error_message = nullptr;
  StringFreeFn string_free = nullptr;

 private:
  ErikaNativeLibrary() {
    const auto loaded = OpenLibrary();
    module = loaded.first;
    DebugLog("loaded Erika C API from " + PathToUtf8(loaded.second));

    create = LoadRequired<CreateFn>("erika_presenter_create");
    create_with_config =
        LoadOptional<CreateWithConfigFn>("erika_presenter_create_with_config");
    create_with_output_mode = LoadOptional<CreateWithOutputModeFn>(
        "erika_presenter_create_with_output_mode");
    destroy = LoadRequired<DestroyFn>("erika_presenter_destroy");
    open = LoadRequired<OpenFn>("erika_presenter_open");
    open_with_headers = LoadOptional<OpenWithHeadersFn>("erika_presenter_open_with_headers");
    play = LoadRequired<CommandFn>("erika_presenter_play");
    pause = LoadRequired<CommandFn>("erika_presenter_pause");
    stop = LoadRequired<CommandFn>("erika_presenter_stop");
    close = LoadRequired<CommandFn>("erika_presenter_close");
    seek = LoadRequired<SeekFn>("erika_presenter_seek");
    set_playback_rate =
        LoadOptional<SetPlaybackRateFn>("erika_presenter_set_playback_rate");
    set_volume = LoadOptional<SetVolumeFn>("erika_presenter_set_volume");
    set_upscaler =
        LoadOptional<SetUpscalerFn>("erika_presenter_set_upscaler");
    set_subtitle_scale = LoadOptional<SetSubtitleScaleFn>(
        "erika_presenter_set_subtitle_scale");
    set_subtitle_font =
        LoadOptional<SetSubtitleFontFn>("erika_presenter_set_subtitle_font");
    set_subtitle_style = LoadOptional<SetSubtitleStyleFn>(
        "erika_presenter_set_subtitle_style");
    register_subtitle_memory_font = LoadOptional<RegisterSubtitleMemoryFontFn>(
        "erika_presenter_register_subtitle_memory_font");
    select_subtitle_memory_fonts = LoadOptional<SelectSubtitleMemoryFontsFn>(
        "erika_presenter_select_subtitle_memory_fonts");
    clear_subtitle_memory_fonts = LoadOptional<CommandFn>(
        "erika_presenter_clear_subtitle_memory_fonts");
    get_subtitle_memory_font_status = LoadOptional<GetSubtitleMemoryFontStatusFn>(
        "erika_presenter_get_subtitle_memory_font_status");
    free_subtitle_memory_font_status = LoadOptional<void (*)(ErikaSubtitleMemoryFontStatus*)>(
        "erika_subtitle_memory_font_status_free");
    get_upscaler_status = LoadOptional<GetUpscalerStatusFn>(
        "erika_presenter_get_upscaler_status");
    get_output_status = LoadOptional<GetOutputStatusFn>(
        "erika_presenter_get_output_status");
    get_resource_status = LoadOptional<GetResourceStatusFn>(
        "erika_presenter_get_resource_status");
    select_audio_track =
        LoadRequired<SelectTrackFn>("erika_presenter_select_audio_track");
    select_subtitle_track =
        LoadRequired<SelectTrackFn>("erika_presenter_select_subtitle_track");
    add_external_subtitle =
        LoadRequired<AddExternalSubtitleFn>("erika_presenter_add_external_subtitle");
    remove_subtitle_track =
        LoadRequired<RemoveSubtitleTrackFn>("erika_presenter_remove_subtitle_track");
    load_danmaku_file =
        LoadOptional<LoadDanmakuFn>("erika_presenter_load_danmaku_file");
    load_danmaku_json =
        LoadOptional<LoadDanmakuFn>("erika_presenter_load_danmaku_json");
    add_danmaku_track_file = LoadOptional<AddDanmakuTrackFn>(
        "erika_presenter_add_danmaku_track_file");
    add_danmaku_track_json = LoadOptional<AddDanmakuTrackFn>(
        "erika_presenter_add_danmaku_track_json");
    remove_danmaku_track = LoadOptional<RemoveDanmakuTrackFn>(
        "erika_presenter_remove_danmaku_track");
    set_danmaku_track_enabled = LoadOptional<SetDanmakuTrackEnabledFn>(
        "erika_presenter_set_danmaku_track_enabled");
    set_danmaku_track_offset = LoadOptional<SetDanmakuTrackOffsetFn>(
        "erika_presenter_set_danmaku_track_offset");
    set_danmaku_global_offset = LoadOptional<SetDanmakuGlobalOffsetFn>(
        "erika_presenter_set_danmaku_global_offset");
    danmaku_tracks =
        LoadOptional<DanmakuTracksFn>("erika_presenter_danmaku_tracks");
    clear_danmaku =
        LoadOptional<ClearDanmakuFn>("erika_presenter_clear_danmaku");
    set_danmaku_enabled = LoadOptional<SetDanmakuEnabledFn>(
        "erika_presenter_set_danmaku_enabled");
    set_debug_hud_enabled = LoadOptional<SetDebugHudEnabledFn>(
        "erika_presenter_set_debug_hud_enabled");
    set_danmaku_config = LoadOptional<SetDanmakuConfigFn>(
        "erika_presenter_set_danmaku_config_ptr");
    get_danmaku_config = LoadOptional<GetDanmakuConfigFn>(
        "erika_presenter_get_danmaku_config");
    set_danmaku_font =
        LoadOptional<SetDanmakuFontFn>("erika_presenter_set_danmaku_font");
    set_danmaku_block_words_json = LoadOptional<LoadDanmakuFn>(
        "erika_presenter_set_danmaku_block_words_json");
    track_selection =
        LoadRequired<TrackSelectionFn>("erika_presenter_track_selection");
    tracks = LoadRequired<TracksFn>("erika_presenter_tracks");
    free_track_info = LoadRequired<TrackInfoFreeFn>("erika_track_info_free");
    free_danmaku_track_info = LoadOptional<DanmakuTrackInfoFreeFn>(
        "erika_danmaku_track_info_free");
    attach_windows_hwnd =
        LoadRequired<AttachWindowsHwndFn>("erika_presenter_attach_windows_hwnd");
    attach_wgpu_surface_with_output_capabilities =
        LoadRequired<AttachWgpuSurfaceWithOutputCapabilitiesFn>(
            "erika_presenter_attach_wgpu_surface_with_output_capabilities");
    windows_composition_swapchain =
        LoadOptional<GetWindowsCompositionSwapchainFn>(
            "erika_presenter_windows_composition_swapchain_iunknown");
    resize_surface =
        LoadRequired<ResizeSurfaceFn>("erika_presenter_resize_surface");
    detach_surface =
        LoadRequired<CommandFn>("erika_presenter_detach_surface");
    render_tick = LoadRequired<RenderTickFn>("erika_presenter_render_tick");
    poll_event = LoadRequired<PollEventFn>("erika_presenter_poll_event");
    last_error_message =
        LoadOptional<LastErrorMessageFn>("erika_last_error_message");
    string_free = LoadOptional<StringFreeFn>("erika_string_free");
  }

  static std::pair<HMODULE, std::filesystem::path> OpenLibrary() {
    std::vector<std::filesystem::path> candidates;
    if (auto value = EnvironmentPath(L"ERIKA_CAPI_DLL")) {
      candidates.push_back(*value);
    }
    if (auto value = EnvironmentPath(L"ERIKA_CAPI_DYLIB")) {
      candidates.push_back(*value);
    }
    const auto exe_dir = ExecutableDirectory();
    if (!exe_dir.empty()) {
      candidates.push_back(exe_dir / L"erika_capi.dll");
    }
    const auto repo_root = SourceTreeRoot();
    candidates.push_back(repo_root / L"target" / L"debug" / L"erika_capi.dll");
    candidates.push_back(repo_root / L"target" / L"release" / L"erika_capi.dll");
    candidates.push_back(L"erika_capi.dll");

    std::ostringstream failures;
    for (const auto& candidate : candidates) {
      SetLastError(0);
      if (HMODULE module = LoadLibraryW(candidate.c_str())) {
        return {module, candidate};
      }
      failures << PathToUtf8(candidate) << " (" << LastErrorMessage() << "); ";
    }
    throw PluginError("Unable to load erika_capi.dll. Tried: " +
                      failures.str());
  }

  template <typename T>
  T LoadRequired(const char* symbol) const {
    auto* raw = GetProcAddress(module, symbol);
    if (raw == nullptr) {
      throw PluginError(std::string("Missing Erika C ABI symbol: ") + symbol);
    }
    return reinterpret_cast<T>(raw);
  }

  template <typename T>
  T LoadOptional(const char* symbol) const {
    auto* raw = GetProcAddress(module, symbol);
    if (raw == nullptr) {
      return nullptr;
    }
    return reinterpret_cast<T>(raw);
  }
};

struct ErikaFlutterPlugin::ErikaOverlayWindow {
  explicit ErikaOverlayWindow(HWND flutter_window)
      : flutter(flutter_window),
        host(RootHostWindow(flutter_window)),
        scale(ScaleForWindow(host)) {
    RegisterWindowClass();
    hwnd = CreateWindowExW(
        WS_EX_NOACTIVATE | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW,
        kOverlayWindowClassName, L"Erika Video Surface",
        WS_POPUP | WS_CLIPSIBLINGS | WS_CLIPCHILDREN, 0, 0, 1, 1,
        nullptr, nullptr, GetModuleHandleW(nullptr), this);
    if (hwnd == nullptr) {
      throw PluginError("Unable to create Windows video overlay HWND: " +
                        LastErrorMessage());
    }
    ShowWindow(hwnd, SW_HIDE);
  }

  ~ErikaOverlayWindow() {
    ShutdownComposition();
    if (hwnd != nullptr) {
      DestroyWindow(hwnd);
      hwnd = nullptr;
    }
  }

  void ConfigureComposition(std::string requested_blend_mode,
                            double requested_opacity) {
    if (requested_blend_mode.empty()) {
      requested_blend_mode = "srcOver";
    }
    if (requested_blend_mode != "srcOver" &&
        requested_blend_mode != "overlay") {
      throw PluginError("Windows DirectComposition supports only srcOver and "
                        "overlay blend modes.");
    }
    blend_mode = std::move(requested_blend_mode);
    opacity = std::clamp(requested_opacity, 0.0, 1.0);
    if (composition_mode && composition_device) {
      ApplyCompositionState();
    }
  }

  void SetCompositionMode(bool enabled) {
    if (composition_mode == enabled) {
      if (enabled) {
        EnsureComposition();
        ApplyCompositionState();
      }
      return;
    }
    composition_mode = enabled;
    if (enabled) {
      ShowWindow(hwnd, SW_HIDE);
      EnsureComposition();
      ApplyCompositionState();
      return;
    }
    ClearCompositionContent();
  }

  void SetCompositionContent(void* raw_content) {
    if (raw_content == nullptr) {
      throw PluginError("Erika returned a null DirectComposition swap chain.");
    }
    Microsoft::WRL::ComPtr<IUnknown> next_content;
    next_content.Attach(static_cast<IUnknown*>(raw_content));
    EnsureComposition();
    if (composition_content.Get() == next_content.Get()) {
      return;
    }
    CheckHResult(content_visual->SetContent(next_content.Get()),
                 "IDCompositionVisual::SetContent");
    composition_content = std::move(next_content);
    ApplyCompositionState();
  }

  void ClearCompositionContent() {
    if (!composition_device || !content_visual) {
      composition_content.Reset();
      return;
    }
    CheckHResult(content_visual->SetContent(nullptr),
                 "IDCompositionVisual::SetContent(null)");
    composition_content.Reset();
    CheckHResult(composition_target->SetRoot(nullptr),
                 "IDCompositionTarget::SetRoot(null)");
    CheckHResult(composition_device->Commit(),
                 "IDCompositionDevice::Commit(clear)");
  }

  void SetFrame(double x,
                double y,
                double width,
                double height,
                bool is_visible,
                std::optional<int64_t> generation,
                const std::optional<std::string>& debug_label) {
    if (!is_visible && generation && active_generation != 0 &&
        *generation != active_generation) {
      return;
    }
    if (generation) {
      active_generation = *generation;
    }
    logical_x = x;
    logical_y = y;
    logical_width = width;
    logical_height = height;
    visible = is_visible && width > 0.0 && height > 0.0;
    host = RootHostWindow(flutter);
    scale = ScaleForWindow(composition_mode ? flutter : host);

    if (debug_label) {
      SetWindowTextW(hwnd, Utf8ToWide(*debug_label).c_str());
    }

    if (composition_mode) {
      ShowWindow(hwnd, SW_HIDE);
      EnsureComposition();
      ApplyCompositionState();
      return;
    }

    if (!visible) {
      ShowWindow(hwnd, SW_HIDE);
      return;
    }

    POINT client_origin{0, 0};
    if (host != nullptr) {
      ClientToScreen(host, &client_origin);
    }
    const int px = client_origin.x + LogicalToPhysical(host, logical_x);
    const int py = client_origin.y + LogicalToPhysical(host, logical_y);
    const int pw = std::max(1, LogicalToPhysical(host, logical_width));
    const int ph = std::max(1, LogicalToPhysical(host, logical_height));
    const HWND insert_after = host != nullptr ? host : HWND_BOTTOM;
    SetWindowPos(hwnd, insert_after, px, py, pw, ph,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
  }

  uint32_t PixelWidth() const {
    return static_cast<uint32_t>(
        std::max<int64_t>(
            1, LogicalToPhysical(composition_mode ? flutter : host,
                                 logical_width)));
  }

  uint32_t PixelHeight() const {
    return static_cast<uint32_t>(
        std::max<int64_t>(
            1, LogicalToPhysical(composition_mode ? flutter : host,
                                 logical_height)));
  }

  void RefreshScaleAndReposition() {
    SetFrame(logical_x, logical_y, logical_width, logical_height, visible,
             active_generation, std::nullopt);
  }

  static void RegisterWindowClass() {
    static bool registered = false;
    if (registered) {
      return;
    }
    WNDCLASSEXW window_class{};
    window_class.cbSize = sizeof(window_class);
    window_class.style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC;
    window_class.lpfnWndProc = &ErikaOverlayWindow::WndProc;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
    window_class.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
    window_class.lpszClassName = kOverlayWindowClassName;
    if (!RegisterClassExW(&window_class) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
      throw PluginError("Unable to register Windows video overlay class: " +
                        LastErrorMessage());
    }
    registered = true;
  }

  static LRESULT CALLBACK WndProc(HWND hwnd,
                                  UINT message,
                                  WPARAM wparam,
                                  LPARAM lparam) {
    if (message == WM_NCCREATE) {
      auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
      SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    }

    switch (message) {
      case WM_ERASEBKGND:
        return 1;
      case WM_NCHITTEST:
        return HTTRANSPARENT;
      default:
        return DefWindowProcW(hwnd, message, wparam, lparam);
    }
  }

  void EnsureComposition() {
    if (composition_device) {
      return;
    }
    if (flutter == nullptr) {
      throw PluginError("No Flutter HWND is available for DirectComposition.");
    }

    CheckHResult(
        DCompositionCreateDevice2(
            nullptr, __uuidof(IDCompositionDesktopDevice),
            reinterpret_cast<void**>(desktop_device.ReleaseAndGetAddressOf())),
        "DCompositionCreateDevice2");
    CheckHResult(desktop_device.As(&composition_device),
                 "QueryInterface(IDCompositionDevice3)");
    CheckHResult(composition_device->CreateVisual(
                     root_visual.ReleaseAndGetAddressOf()),
                 "IDCompositionDevice::CreateVisual(root)");
    CheckHResult(composition_device->CreateVisual(
                     content_visual.ReleaseAndGetAddressOf()),
                 "IDCompositionDevice::CreateVisual(content)");
    CheckHResult(root_visual->AddVisual(content_visual.Get(), FALSE, nullptr),
                 "IDCompositionVisual::AddVisual");
    CheckHResult(composition_device->CreateEffectGroup(
                     opacity_effect.ReleaseAndGetAddressOf()),
                 "IDCompositionDevice::CreateEffectGroup");
    CheckHResult(content_visual->SetEffect(opacity_effect.Get()),
                 "IDCompositionVisual::SetEffect(opacity)");
    CheckHResult(composition_device->CreateBlendEffect(
                     overlay_blend_effect.ReleaseAndGetAddressOf()),
                 "IDCompositionDevice3::CreateBlendEffect");
    CheckHResult(overlay_blend_effect->SetMode(D2D1_BLEND_MODE_OVERLAY),
                 "IDCompositionBlendEffect::SetMode");

    HRESULT target_result = desktop_device->CreateTargetForHwnd(
        flutter, TRUE, composition_target.ReleaseAndGetAddressOf());
    if (FAILED(target_result)) {
      target_result = desktop_device->CreateTargetForHwnd(
          flutter, FALSE, composition_target.ReleaseAndGetAddressOf());
    }
    CheckHResult(target_result,
                 "IDCompositionDesktopDevice::CreateTargetForHwnd");
  }

  void ApplyCompositionState() {
    if (!composition_device) {
      return;
    }
    IDCompositionEffect* effect = blend_mode == "overlay"
                                     ? overlay_blend_effect.Get()
                                     : nullptr;
    CheckHResult(root_visual->SetEffect(effect),
                 "IDCompositionVisual::SetEffect");
    CheckHResult(opacity_effect->SetOpacity(static_cast<float>(opacity)),
                 "IDCompositionEffectGroup::SetOpacity");
    CheckHResult(content_visual->SetOffsetX(static_cast<float>(
                     LogicalToPhysical(flutter, logical_x))),
                 "IDCompositionVisual::SetOffsetX");
    CheckHResult(content_visual->SetOffsetY(static_cast<float>(
                     LogicalToPhysical(flutter, logical_y))),
                 "IDCompositionVisual::SetOffsetY");
    CheckHResult(
        composition_target->SetRoot(
            composition_mode && visible && composition_content
                ? root_visual.Get()
                : nullptr),
        "IDCompositionTarget::SetRoot");
    CheckHResult(composition_device->Commit(),
                 "IDCompositionDevice::Commit");
  }

  void ShutdownComposition() {
    if (composition_target && composition_device) {
      composition_target->SetRoot(nullptr);
      composition_device->Commit();
    }
    composition_content.Reset();
    overlay_blend_effect.Reset();
    opacity_effect.Reset();
    content_visual.Reset();
    root_visual.Reset();
    composition_target.Reset();
    composition_device.Reset();
    desktop_device.Reset();
  }

  HWND flutter = nullptr;
  HWND host = nullptr;
  HWND hwnd = nullptr;
  double scale = 1.0;
  double logical_x = 0.0;
  double logical_y = 0.0;
  double logical_width = 1.0;
  double logical_height = 1.0;
  bool visible = false;
  bool composition_mode = false;
  std::string blend_mode = "srcOver";
  double opacity = 1.0;
  int64_t active_generation = 0;
  int64_t owner_player_id = 0;
  Microsoft::WRL::ComPtr<IDCompositionDesktopDevice> desktop_device;
  Microsoft::WRL::ComPtr<IDCompositionDevice3> composition_device;
  Microsoft::WRL::ComPtr<IDCompositionTarget> composition_target;
  Microsoft::WRL::ComPtr<IDCompositionVisual2> root_visual;
  Microsoft::WRL::ComPtr<IDCompositionVisual2> content_visual;
  Microsoft::WRL::ComPtr<IDCompositionEffectGroup> opacity_effect;
  Microsoft::WRL::ComPtr<IDCompositionBlendEffect> overlay_blend_effect;
  Microsoft::WRL::ComPtr<IUnknown> composition_content;
};

struct ErikaFlutterPlugin::PlayerHost {
  PlayerHost(int64_t player_id,
             std::shared_ptr<ErikaNativeLibrary> native_library,
             ErikaPresenterConfig config)
      : id(player_id),
        library(std::move(native_library)),
        video_alpha_mode(config.video_alpha_mode) {
    smtc_state.player_id = player_id;
    handle = library->CreatePresenter(config);
    if (handle == nullptr) {
      std::string message = "erika_presenter_create returned null";
      const auto detail = library->TakeLastError();
      if (!detail.empty()) {
        message += ": " + detail;
      }
      DebugLog(message);
      throw PluginError(message);
    }
    RefreshDanmakuConfigSnapshot();
  }

  ~PlayerHost() {
    if (handle != nullptr) {
      library->detach_surface(handle);
      library->destroy(handle);
      handle = nullptr;
    }
  }

  void Open(const std::string& uri, const EncodableMap& args) {
    const auto* raw_headers = FindArg(args, "httpHeaders");
    const EncodableMap* headers = nullptr;
    if (raw_headers != nullptr &&
        !std::holds_alternative<std::monostate>(*raw_headers)) {
      headers = std::get_if<EncodableMap>(raw_headers);
      if (headers == nullptr) {
        throw PluginError("httpHeaders must be a map of string names to string values.");
      }
    }
    if (headers != nullptr && !headers->empty()) {
      // Never fall back to the headerless entry point here: silently dropping
      // the headers turns an authenticated stream into an opaque 403.
      if (library->open_with_headers == nullptr) {
        throw PluginError(
            "The loaded Erika native library does not export "
            "erika_presenter_open_with_headers, so httpHeaders cannot be applied. "
            "Update the bundled erika_capi.dll (a prebuilt from 0.1.3 or earlier "
            "predates HTTP header support).");
      }
      std::vector<std::string> names;
      std::vector<std::string> values;
      std::vector<ErikaHttpHeader> native_headers;
      names.reserve(headers->size());
      values.reserve(headers->size());
      native_headers.reserve(headers->size());
      for (const auto& entry : *headers) {
        const auto name = StringValue(&entry.first);
        const auto value = StringValue(&entry.second);
        if (!name || !value) {
          throw PluginError("httpHeaders must contain string names and values.");
        }
        names.push_back(*name);
        values.push_back(*value);
      }
      for (size_t index = 0; index < names.size(); ++index) {
        native_headers.push_back({names[index].c_str(), values[index].c_str()});
      }
      Check(library->open_with_headers(handle, uri.c_str(), native_headers.data(),
                                       native_headers.size()), "open",
            library->TakeLastError());
      return;
    }
    Check(library->open(handle, uri.c_str()), "open", library->TakeLastError());
  }

  void SetMediaMetadata(const EncodableMap& metadata) {
    const auto title = StringValue(FindArg(metadata, "title"));
    if (!title || title->empty()) {
      throw PluginError("metadata.title is required.");
    }
    smtc_state.title = *title;
    smtc_state.artist = StringValue(FindArg(metadata, "artist")).value_or("");
    smtc_state.album = StringValue(FindArg(metadata, "album")).value_or("");
    smtc_state.artwork.clear();
    if (const auto* value = FindArg(metadata, "artwork"); value != nullptr) {
      if (const auto* bytes = std::get_if<std::vector<uint8_t>>(value)) {
        smtc_state.artwork = *bytes;
      } else if (!std::holds_alternative<std::monostate>(*value)) {
        throw PluginError("metadata.artwork must contain image bytes.");
      }
    }
    ++smtc_state.metadata_revision;
  }

  void ClearMediaMetadata() {
    smtc_state.title.clear();
    smtc_state.artist.clear();
    smtc_state.album.clear();
    smtc_state.artwork.clear();
    ++smtc_state.metadata_revision;
  }

  void PrepareForOpen() {
    smtc_state.playing = false;
    smtc_state.stopped = false;
    smtc_state.duration_micros = 0;
    smtc_state.position_micros = 0;
  }

  void SetSystemMediaNavigation(bool previous_enabled, bool next_enabled) {
    smtc_state.previous_enabled = previous_enabled;
    smtc_state.next_enabled = next_enabled;
  }

  void Play() {
    Check(library->play(handle), "play", library->TakeLastError());
    smtc_state.playing = true;
    smtc_state.stopped = false;
  }
  void Pause() {
    Check(library->pause(handle), "pause", library->TakeLastError());
    smtc_state.playing = false;
    smtc_state.stopped = false;
  }
  void Stop() {
    Check(library->stop(handle), "stop", library->TakeLastError());
    smtc_state.playing = false;
    smtc_state.stopped = true;
    smtc_state.position_micros = 0;
  }
  void Close() {
    Check(library->close(handle), "close", library->TakeLastError());
    smtc_state.playing = false;
    smtc_state.stopped = true;
    smtc_state.duration_micros = 0;
    smtc_state.position_micros = 0;
  }

  void Seek(uint64_t position_micros) {
    Check(library->seek(handle, position_micros), "seek",
          library->TakeLastError());
    smtc_state.position_micros = position_micros;
  }

  void SetPlaybackRate(double rate) {
    if (library->set_playback_rate == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_set_playback_rate");
    }
    Check(library->set_playback_rate(handle, rate), "set_playback_rate",
          library->TakeLastError());
    smtc_state.playback_rate = rate;
  }

  void SetVolume(double volume) {
    if (library->set_volume == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_set_volume");
    }
    const double clamped = std::isfinite(volume) ? std::clamp(volume, 0.0, 1.0) : 1.0;
    Check(library->set_volume(handle, clamped), "set_volume",
          library->TakeLastError());
  }

  void SetUpscaler(int32_t mode) {
    if (library->set_upscaler == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_set_upscaler");
    }
    Check(library->set_upscaler(handle, mode), "set_upscaler",
          library->TakeLastError());
  }

  void SetSubtitleScale(double scale) {
    if (library->set_subtitle_scale == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_set_subtitle_scale");
    }
    const double clamped = std::isfinite(scale) ? std::clamp(scale, 0.25, 4.0) : 1.0;
    Check(library->set_subtitle_scale(handle, clamped), "set_subtitle_scale");
  }

  void SetSubtitleFont(const std::optional<std::string>& family,
                       const std::optional<std::string>& file_path) {
    if (library->set_subtitle_font == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_set_subtitle_font");
    }
    Check(library->set_subtitle_font(handle, family ? family->c_str() : nullptr,
                                     file_path ? file_path->c_str() : nullptr),
          "set_subtitle_font");
  }

  void SetSubtitleStyle(const std::optional<std::string>& font_family,
                        const std::optional<std::string>& font_file_path,
                        uint32_t primary_rgba, uint32_t outline_rgba,
                        double font_size, double outline_width, bool bold,
                        bool italic, bool underline, bool strike_out,
                        double spacing, double scale_x_percent,
                        double scale_y_percent, int32_t border_style,
                        double shadow_depth, double blur, int32_t alignment,
                        int32_t margin_left, int32_t margin_right,
                        int32_t margin_vertical, uint32_t override_mask) {
    if (library->set_subtitle_style == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_set_subtitle_style");
    }
    ErikaSubtitleStyle style{};
    style.font_family = font_family ? font_family->c_str() : nullptr;
    style.font_file_path = font_file_path ? font_file_path->c_str() : nullptr;
    style.primary_color_rgba = primary_rgba;
    style.outline_color_rgba = outline_rgba;
    style.font_size = font_size;
    style.outline_width = outline_width;
    style.bold = bold;
    style.italic = italic;
    style.underline = underline;
    style.strike_out = strike_out;
    style.spacing = spacing;
    style.scale_x_percent = scale_x_percent;
    style.scale_y_percent = scale_y_percent;
    style.border_style = border_style;
    style.shadow_depth = shadow_depth;
    style.blur = blur;
    style.alignment = alignment;
    style.margin_left = margin_left;
    style.margin_right = margin_right;
    style.margin_vertical = margin_vertical;
    style.override_mask = override_mask;
    Check(library->set_subtitle_style(handle, style),
          "set_subtitle_style");
  }

  uint64_t RegisterSubtitleMemoryFont(const std::vector<uint8_t>& data) {
    if (library->register_subtitle_memory_font == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_register_subtitle_memory_font");
    }
    uint64_t font_id = 0;
    Check(library->register_subtitle_memory_font(handle, data.data(), data.size(),
                                                  &font_id),
          "register_subtitle_memory_font");
    return font_id;
  }

  void SelectSubtitleMemoryFonts(const EncodableList& values) {
    if (library->select_subtitle_memory_fonts == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_select_subtitle_memory_fonts");
    }
    std::vector<uint64_t> ids;
    ids.reserve(values.size());
    for (const auto& value : values) {
      const auto font_id = Int64Value(&value);
      if (!font_id || *font_id <= 0) {
        throw PluginError("fontIds must contain positive integers.");
      }
      ids.push_back(static_cast<uint64_t>(*font_id));
    }
    Check(library->select_subtitle_memory_fonts(handle, ids.data(), ids.size()),
          "select_subtitle_memory_fonts");
  }

  void ClearSubtitleMemoryFonts() {
    if (library->clear_subtitle_memory_fonts == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_clear_subtitle_memory_fonts");
    }
    Check(library->clear_subtitle_memory_fonts(handle),
          "clear_subtitle_memory_fonts");
  }

  EncodableValue GetSubtitleMemoryFontStatus() {
    if (library->get_subtitle_memory_font_status == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_get_subtitle_memory_font_status");
    }
    ErikaSubtitleMemoryFontStatus status{};
    Check(library->get_subtitle_memory_font_status(handle, &status),
          "get_subtitle_memory_font_status");
    auto result = SubtitleMemoryFontStatusToMap(status);
    if (library->free_subtitle_memory_font_status != nullptr) {
      library->free_subtitle_memory_font_status(&status);
    }
    return result;
  }

  EncodableValue GetUpscalerStatus() {
    if (library->get_upscaler_status == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_get_upscaler_status");
    }
    ErikaUpscalerStatus status{};
    Check(library->get_upscaler_status(handle, &status), "get_upscaler_status");
    return UpscalerStatusToMap(status);
  }

  EncodableValue GetOutputStatus() {
    if (library->get_output_status == nullptr) {
      throw PluginError(
          "Missing Erika C ABI symbol: erika_presenter_get_output_status");
    }
    ErikaOutputStatus status{};
    const ErikaStatus result = library->get_output_status(handle, &status);
    if (result != ErikaStatus_Ok) {
      Check(result, "get_output_status", library->TakeLastError());
    }
    return OutputStatusToMap(status);
  }

  EncodableValue GetResourceStatus() {
    if (library->get_resource_status == nullptr) {
      throw PluginError(
          "Missing Erika C ABI symbol: erika_presenter_get_resource_status");
    }
    ErikaPresenterResourceStatus status{};
    const ErikaStatus result = library->get_resource_status(handle, &status);
    if (result != ErikaStatus_Ok) {
      Check(result, "get_resource_status", library->TakeLastError());
    }
    return ResourceStatusToMap(status);
  }

  EncodableValue GetPresenterStats() const {
    return PresenterStatsToMap(latest_presenter_stats);
  }

  int64_t AddExternalSubtitle(const std::string& uri) {
    int64_t track_id = 0;
    Check(library->add_external_subtitle(handle, uri.c_str(), &track_id),
          "add_external_subtitle");
    return track_id;
  }

  void RemoveSubtitleTrack(int64_t track_id) {
    Check(library->remove_subtitle_track(handle, track_id),
          "remove_subtitle_track");
  }

  void SelectAudioTrack(int64_t track_id) {
    Check(library->select_audio_track(handle, track_id), "select_audio_track");
  }

  void SelectSubtitleTrack(int64_t track_id) {
    Check(library->select_subtitle_track(handle, track_id),
          "select_subtitle_track");
  }

  void LoadDanmakuFile(const std::string& uri) {
    if (library->load_danmaku_file == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_load_danmaku_file");
    }
    Check(library->load_danmaku_file(handle, uri.c_str()), "load_danmaku_file");
  }

  void LoadDanmakuJson(const std::string& json) {
    if (library->load_danmaku_json == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_load_danmaku_json");
    }
    Check(library->load_danmaku_json(handle, json.c_str()), "load_danmaku_json");
  }

  uint64_t AddDanmakuTrackFile(const std::string& uri,
                               const std::optional<std::string>& name,
                               int64_t offset_micros) {
    if (library->add_danmaku_track_file == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_add_danmaku_track_file");
    }
    uint64_t track_id = 0;
    Check(library->add_danmaku_track_file(
              handle, uri.c_str(), name ? name->c_str() : nullptr,
              offset_micros, &track_id),
          "add_danmaku_track_file");
    return track_id;
  }

  uint64_t AddDanmakuTrackJson(const std::string& json,
                               const std::optional<std::string>& name,
                               int64_t offset_micros) {
    if (library->add_danmaku_track_json == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_add_danmaku_track_json");
    }
    uint64_t track_id = 0;
    Check(library->add_danmaku_track_json(
              handle, json.c_str(), name ? name->c_str() : nullptr,
              offset_micros, &track_id),
          "add_danmaku_track_json");
    return track_id;
  }

  void RemoveDanmakuTrack(uint64_t track_id) {
    if (library->remove_danmaku_track == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_remove_danmaku_track");
    }
    Check(library->remove_danmaku_track(handle, track_id),
          "remove_danmaku_track");
  }

  void SetDanmakuTrackEnabled(uint64_t track_id, bool enabled) {
    if (library->set_danmaku_track_enabled == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_set_danmaku_track_enabled");
    }
    Check(library->set_danmaku_track_enabled(handle, track_id, enabled),
          "set_danmaku_track_enabled");
  }

  void SetDanmakuTrackOffset(uint64_t track_id, int64_t offset_micros) {
    if (library->set_danmaku_track_offset == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_set_danmaku_track_offset");
    }
    Check(library->set_danmaku_track_offset(handle, track_id, offset_micros),
          "set_danmaku_track_offset");
  }

  void SetDanmakuGlobalOffset(int64_t offset_micros) {
    if (library->set_danmaku_global_offset == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_set_danmaku_global_offset");
    }
    Check(library->set_danmaku_global_offset(handle, offset_micros),
          "set_danmaku_global_offset");
  }

  EncodableValue DanmakuTracks() {
    if (library->danmaku_tracks == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_danmaku_tracks");
    }
    uintptr_t len = 0;
    Check(library->danmaku_tracks(handle, nullptr, 0, &len), "danmaku_tracks");
    std::vector<ErikaDanmakuTrackInfo> tracks(len);
    if (len > 0) {
      Check(library->danmaku_tracks(handle, tracks.data(), len, &len),
            "danmaku_tracks");
    }
    EncodableList result;
    result.reserve(tracks.size());
    for (auto& track : tracks) {
      result.push_back(EncodableValue(EncodableMap{
          {EncodableValue("id"), EncodableValue(static_cast<int64_t>(track.id))},
          {EncodableValue("enabled"), EncodableValue(track.enabled)},
          {EncodableValue("offsetMicros"),
           EncodableValue(static_cast<int64_t>(track.offset_micros))},
          {EncodableValue("itemCount"),
           EncodableValue(static_cast<int64_t>(track.item_count))},
          {EncodableValue("name"), NullableString(track.name)},
          {EncodableValue("source"), NullableString(track.source)},
      }));
      if (library->free_danmaku_track_info != nullptr) {
        library->free_danmaku_track_info(&track);
      }
    }
    return EncodableValue(result);
  }

  void ClearDanmaku() {
    if (library->clear_danmaku == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_clear_danmaku");
    }
    Check(library->clear_danmaku(handle), "clear_danmaku");
  }

  void SetDanmakuEnabled(bool enabled) {
    if (library->set_danmaku_enabled == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_set_danmaku_enabled");
    }
    Check(library->set_danmaku_enabled(handle, enabled),
          "set_danmaku_enabled");
    current_danmaku_config.enabled = enabled;
  }

  void SetDebugHudEnabled(bool enabled) {
    if (library->set_debug_hud_enabled == nullptr) {
      throw PluginError(
          "Missing Erika C ABI symbol: erika_presenter_set_debug_hud_enabled");
    }
    Check(library->set_debug_hud_enabled(handle, enabled),
          "set_debug_hud_enabled");
  }

  void SetDanmakuConfig(const ErikaDanmakuConfig& config) {
    if (library->set_danmaku_config == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_set_danmaku_config_ptr");
    }
    ErikaDanmakuConfig copy = config;
    Check(library->set_danmaku_config(handle, &copy), "set_danmaku_config");
    current_danmaku_config = copy;
  }

  void SetDanmakuFont(const std::optional<std::string>& family,
                      const std::optional<std::string>& file_path) {
    if (library->set_danmaku_font == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_set_danmaku_font");
    }
    Check(library->set_danmaku_font(handle, family ? family->c_str() : nullptr,
                                    file_path ? file_path->c_str() : nullptr),
          "set_danmaku_font");
  }

  void SetDanmakuBlockWordsJson(const std::string& json) {
    if (library->set_danmaku_block_words_json == nullptr) {
      throw PluginError("Missing Erika C ABI symbol: erika_presenter_set_danmaku_block_words_json");
    }
    Check(library->set_danmaku_block_words_json(handle, json.c_str()),
          "set_danmaku_block_words_json");
  }

  EncodableValue Tracks() {
    uintptr_t len = 0;
    Check(library->tracks(handle, nullptr, 0, &len), "tracks");
    std::vector<ErikaTrackInfo> tracks(len);
    if (len > 0) {
      Check(library->tracks(handle, tracks.data(), len, &len), "tracks");
    }
    EncodableList result;
    result.reserve(tracks.size());
    for (auto& track : tracks) {
      result.push_back(EncodableValue(EncodableMap{
          {EncodableValue("id"), EncodableValue(static_cast<int64_t>(track.id))},
          {EncodableValue("kind"),
           EncodableValue(static_cast<int32_t>(track.kind))},
          {EncodableValue("source"),
           EncodableValue(static_cast<int32_t>(track.source))},
          {EncodableValue("selected"), EncodableValue(track.selected)},
          {EncodableValue("canRemove"), EncodableValue(track.can_remove)},
          {EncodableValue("title"), NullableString(track.title)},
          {EncodableValue("language"), NullableString(track.language)},
          {EncodableValue("codec"), NullableString(track.codec)},
          {EncodableValue("width"),
           EncodableValue(static_cast<int32_t>(track.width))},
          {EncodableValue("height"),
           EncodableValue(static_cast<int32_t>(track.height))},
          {EncodableValue("sampleRate"),
           EncodableValue(static_cast<int32_t>(track.sample_rate))},
          {EncodableValue("channels"),
           EncodableValue(static_cast<int32_t>(track.channels))},
          {EncodableValue("pixelFormat"), NullableString(track.pixel_format)},
          {EncodableValue("sampleFormat"), NullableString(track.sample_format)},
          {EncodableValue("profile"), NullableString(track.profile)},
          {EncodableValue("level"),
           EncodableValue(static_cast<int32_t>(track.level))},
          {EncodableValue("bitRate"),
           EncodableValue(static_cast<int64_t>(track.bit_rate))},
          {EncodableValue("frameRateNumerator"),
           EncodableValue(static_cast<int32_t>(track.frame_rate_numerator))},
          {EncodableValue("frameRateDenominator"),
           EncodableValue(static_cast<int32_t>(track.frame_rate_denominator))},
      }));
      library->free_track_info(&track);
    }
    return EncodableValue(result);
  }

  EncodableValue TrackSelection() {
    ErikaTrackSelection selection{};
    Check(library->track_selection(handle, &selection), "track_selection");
    return TrackSelectionToMap(selection);
  }

  void AttachOverlay(ErikaOverlayWindow& overlay) {
    const uint32_t width = overlay.PixelWidth();
    const uint32_t height = overlay.PixelHeight();
    const double scale = overlay.scale;
    const uint64_t hinstance = reinterpret_cast<uint64_t>(GetModuleHandleW(nullptr));
    composition_surface = RequiresComposition(overlay);
    overlay.SetCompositionMode(composition_surface);
    if (composition_surface) {
      overlay.ClearCompositionContent();
      ErikaSurfaceOutputCapabilities capabilities{};
      capabilities.direct_composition = true;
      capabilities.fallback_reason = ErikaOutputFallbackReason_None;
      Check(library->attach_wgpu_surface_with_output_capabilities(
                handle, ErikaWgpuSurfaceKind_WindowsHwnd,
                reinterpret_cast<uint64_t>(overlay.flutter), hinstance, width,
                height, scale, capabilities),
            "attach_wgpu_surface_with_output_capabilities",
            library->TakeLastError());
      attached_hwnd = overlay.flutter;
      attached_overlay = &overlay;
      RefreshCompositionContent();
    } else {
      Check(library->attach_windows_hwnd(
                handle, reinterpret_cast<uint64_t>(overlay.hwnd), hinstance,
                width, height, scale),
            "attach_windows_hwnd", library->TakeLastError());
      attached_hwnd = overlay.hwnd;
      attached_overlay = nullptr;
    }
    attached_view_id = kWindowOverlayViewId;
    surface_attached = true;
    attached_surface_width = width;
    attached_surface_height = height;
    attached_surface_scale = scale;
    start_time_seconds = NowSeconds();
  }

  void ResizeOverlay(ErikaOverlayWindow& overlay) {
    const HWND expected_hwnd = composition_surface ? overlay.flutter : overlay.hwnd;
    if (!surface_attached || attached_hwnd != expected_hwnd) {
      return;
    }
    const uint32_t width = overlay.PixelWidth();
    const uint32_t height = overlay.PixelHeight();
    const double scale = overlay.scale;
    if (width == attached_surface_width &&
        height == attached_surface_height &&
        std::abs(scale - attached_surface_scale) < 0.0001) {
      return;
    }
    Check(library->resize_surface(handle, width, height, scale),
          "resize_surface", library->TakeLastError());
    attached_surface_width = width;
    attached_surface_height = height;
    attached_surface_scale = scale;
    if (composition_surface) {
      RefreshCompositionContent();
    }
  }

  bool RequiresComposition(const ErikaOverlayWindow& overlay) const {
    return video_alpha_mode != ErikaVideoAlphaMode_Opaque ||
           overlay.blend_mode == "overlay";
  }

  void RefreshCompositionContent() {
    if (!composition_surface || attached_overlay == nullptr) {
      return;
    }
    if (library->windows_composition_swapchain == nullptr) {
      throw PluginError(
          "The loaded erika_capi.dll does not expose the DirectComposition "
          "swap chain. Update the bundled Erika runtime.");
    }
    void* swapchain = nullptr;
    Check(library->windows_composition_swapchain(handle, &swapchain),
          "windows_composition_swapchain_iunknown",
          library->TakeLastError());
    attached_overlay->SetCompositionContent(swapchain);
  }

  void Detach(std::optional<int64_t> view_id) {
    if (view_id && attached_view_id != *view_id) {
      return;
    }
    if (composition_surface && attached_overlay != nullptr &&
        attached_overlay->owner_player_id == id) {
      try {
        attached_overlay->ClearCompositionContent();
      } catch (const std::exception& error) {
        DebugLog(std::string("DirectComposition detach failed: ") +
                 error.what());
      }
    }
    attached_hwnd = nullptr;
    attached_overlay = nullptr;
    composition_surface = false;
    attached_view_id = 0;
    surface_attached = false;
    attached_surface_width = 0;
    attached_surface_height = 0;
    attached_surface_scale = 0.0;
    library->detach_surface(handle);
  }

  void RenderTick(flutter::EventSink<EncodableValue>* event_sink) {
    if (surface_attached) {
      ErikaPresenterStats stats{};
      const double time_seconds = NowSeconds() - start_time_seconds;
      const auto status = library->render_tick(handle, time_seconds, &stats);
      if (status != ErikaStatus_Ok) {
        DebugLog("render_tick failed with ErikaStatus_" + StatusName(status) +
                 " (" + std::to_string(static_cast<int>(status)) + "): " +
                 library->TakeLastError());
      } else {
        latest_presenter_stats = stats;
        if (composition_surface) {
          try {
            RefreshCompositionContent();
          } catch (const std::exception& error) {
            DebugLog(std::string("DirectComposition swap chain rebind failed: ") +
                     error.what());
          }
        }
      }
    }
    PollEvents(event_sink);
  }

  void PollEvents(flutter::EventSink<EncodableValue>* event_sink) {
    while (true) {
      ErikaEvent event{};
      const auto status = library->poll_event(handle, &event);
      if (status == ErikaStatus_Ok) {
        if (event.kind == ErikaEventKind_StateChanged) {
          smtc_state.playing = event.state == ErikaState_Playing;
          smtc_state.stopped = event.state == ErikaState_Stopped ||
                               event.state == ErikaState_Closed ||
                               event.state == ErikaState_Idle;
        } else if (event.kind == ErikaEventKind_DurationChanged) {
          smtc_state.duration_micros = event.duration_micros;
        } else if (event.kind == ErikaEventKind_PositionChanged) {
          smtc_state.position_micros = event.position_micros;
        }
        if (event.kind == ErikaEventKind_Error) {
          DebugLog("player " + std::to_string(id) +
                   " event error status=ErikaStatus_" +
                   StatusName(event.status) + " (" +
                   std::to_string(static_cast<int>(event.status)) + "): " +
                   library->TakeLastError());
        }
        if (event_sink != nullptr) {
          event_sink->Success(EventToMap(event));
        }
        continue;
      }
      if (status != ErikaStatus_NoEvent) {
        DebugLog("poll_event failed with ErikaStatus_" + StatusName(status) +
                 " (" + std::to_string(static_cast<int>(status)) + "): " +
                 library->TakeLastError());
      }
      break;
    }
  }

  ErikaDanmakuConfig DanmakuConfigFromArgs(const EncodableMap& args) const {
    ErikaDanmakuConfig config = current_danmaku_config;
    if (auto value = BoolValue(FindArg(args, "enabled"))) {
      config.enabled = *value;
    }
    if (auto value = DoubleValue(FindArg(args, "fontSize"))) {
      config.font_size = static_cast<float>(*value);
    }
    if (auto value = DoubleValue(FindArg(args, "opacity"))) {
      config.opacity = static_cast<float>(*value);
    }
    if (auto value = DoubleValue(FindArg(args, "displayArea"))) {
      config.display_area = static_cast<float>(*value);
    }
    if (auto value = DoubleValue(FindArg(args, "scrollDurationSeconds"))) {
      config.scroll_duration_seconds = static_cast<float>(*value);
    }
    if (auto value = DoubleValue(FindArg(args, "scrollSpeedFactor"))) {
      config.scroll_speed_factor = static_cast<float>(*value);
    }
    if (auto value = DoubleValue(FindArg(args, "trackGapRatio"))) {
      config.track_gap_ratio = static_cast<float>(*value);
    }
    if (auto value = DoubleValue(FindArg(args, "outlineWidth"))) {
      config.outline_width = static_cast<float>(*value);
    }
    if (auto value = DoubleValue(FindArg(args, "shadowOffsetX"))) {
      config.shadow_offset_x = static_cast<float>(*value);
    }
    if (auto value = DoubleValue(FindArg(args, "shadowOffsetY"))) {
      config.shadow_offset_y = static_cast<float>(*value);
    }
    if (auto value = BoolValue(FindArg(args, "mergeDuplicates"))) {
      config.merge_duplicates = *value;
    }
    if (auto value = BoolValue(FindArg(args, "allowStacking"))) {
      config.allow_stacking = *value;
    }
    if (auto value = BoolValue(FindArg(args, "allowScrollOverwrite"))) {
      config.allow_scroll_overwrite = *value;
    }
    if (auto value = Int64Value(FindArg(args, "maxQuantity")); value && *value > 0) {
      config.max_quantity = static_cast<uint32_t>(*value);
    }
    if (auto value = Int64Value(FindArg(args, "maxLinesPerMode"));
        value && *value > 0) {
      config.max_lines_per_mode = static_cast<uint32_t>(*value);
    }
    if (auto value = BoolValue(FindArg(args, "blockTop"))) {
      config.block_top = *value;
    }
    if (auto value = BoolValue(FindArg(args, "blockBottom"))) {
      config.block_bottom = *value;
    }
    if (auto value = BoolValue(FindArg(args, "blockScroll"))) {
      config.block_scroll = *value;
    }
    if (auto value = Int64Value(FindArg(args, "shadowStyle"))) {
      config.shadow_style = static_cast<int32_t>(*value);
    }
    return config;
  }

  EncodableValue EventToMap(const ErikaEvent& event) {
    EncodableMap map{
        {EncodableValue("playerId"), EncodableValue(id)},
        {EncodableValue("kind"), EncodableValue(static_cast<int32_t>(event.kind))},
        {EncodableValue("status"),
         EncodableValue(static_cast<int32_t>(event.status))},
        {EncodableValue("state"),
         EncodableValue(static_cast<int32_t>(event.state))},
        {EncodableValue("durationMicros"),
         EncodableValue(static_cast<int64_t>(event.duration_micros))},
        {EncodableValue("positionMicros"),
         EncodableValue(static_cast<int64_t>(event.position_micros))},
        {EncodableValue("buffering"), EncodableValue(event.buffering)},
        {EncodableValue("video"),
         EncodableValue(EncodableMap{
             {EncodableValue("width"),
              EncodableValue(static_cast<int32_t>(event.video.width))},
             {EncodableValue("height"),
              EncodableValue(static_cast<int32_t>(event.video.height))},
             {EncodableValue("primaries"),
              EncodableValue(static_cast<int32_t>(event.video.primaries))},
             {EncodableValue("transfer"),
              EncodableValue(static_cast<int32_t>(event.video.transfer))},
         })},
        {EncodableValue("tracks"),
         EncodableValue(EncodableMap{
             {EncodableValue("video"),
              EncodableValue(static_cast<int32_t>(event.tracks.video))},
             {EncodableValue("audio"),
              EncodableValue(static_cast<int32_t>(event.tracks.audio))},
             {EncodableValue("subtitle"),
              EncodableValue(static_cast<int32_t>(event.tracks.subtitle))},
         })},
    };
    if (event.kind == ErikaEventKind_TracksChanged ||
        event.kind == ErikaEventKind_TrackSelectionChanged) {
      try {
        map[EncodableValue("trackList")] = Tracks();
        map[EncodableValue("trackSelection")] = TrackSelection();
      } catch (const std::exception& error) {
        DebugLog(std::string("failed to add track details to event: ") +
                 error.what());
        map[EncodableValue("trackList")] = EncodableValue(EncodableList{});
        map[EncodableValue("trackSelection")] =
            TrackSelectionToMap(ErikaTrackSelection{-1, -1, -1});
      }
    }
    return EncodableValue(map);
  }

  void RefreshDanmakuConfigSnapshot() {
    current_danmaku_config = DefaultDanmakuConfig();
    if (library->get_danmaku_config == nullptr) {
      return;
    }
    ErikaDanmakuConfig config{};
    if (library->get_danmaku_config(handle, &config) == ErikaStatus_Ok) {
      current_danmaku_config = config;
    }
  }

  int64_t id = 0;
  ErikaSmtcState smtc_state{};
  std::shared_ptr<ErikaNativeLibrary> library;
  ErikaPresenterHandle* handle = nullptr;
  HWND attached_hwnd = nullptr;
  ErikaOverlayWindow* attached_overlay = nullptr;
  int64_t attached_view_id = 0;
  bool surface_attached = false;
  bool composition_surface = false;
  int32_t video_alpha_mode = ErikaVideoAlphaMode_Opaque;
  uint32_t attached_surface_width = 0;
  uint32_t attached_surface_height = 0;
  double attached_surface_scale = 0.0;
  double start_time_seconds = NowSeconds();
  ErikaDanmakuConfig current_danmaku_config = DefaultDanmakuConfig();
  ErikaPresenterStats latest_presenter_stats{};
};

ErikaEventStreamHandler::ErikaEventStreamHandler(ErikaFlutterPlugin* plugin)
    : plugin_(plugin) {}

std::unique_ptr<flutter::StreamHandlerError<EncodableValue>>
ErikaEventStreamHandler::OnListenInternal(
    const EncodableValue* arguments,
    std::unique_ptr<flutter::EventSink<EncodableValue>>&& events) {
  plugin_->SetEventSink(std::move(events));
  return nullptr;
}

std::unique_ptr<flutter::StreamHandlerError<EncodableValue>>
ErikaEventStreamHandler::OnCancelInternal(const EncodableValue* arguments) {
  plugin_->ClearEventSink();
  return nullptr;
}

void ErikaFlutterPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_unique<flutter::MethodChannel<EncodableValue>>(
          registrar->messenger(), "erika_flutter/player",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<ErikaFlutterPlugin>(registrar);

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

ErikaFlutterPlugin::ErikaFlutterPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {
  event_channel_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
      registrar_->messenger(), "erika_flutter/events",
      &flutter::StandardMethodCodec::GetInstance());
  event_channel_->SetStreamHandler(
      std::make_unique<ErikaEventStreamHandler>(this));

  window_proc_delegate_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        return OnTopLevelWindowProc(hwnd, message, wparam, lparam);
      });
  StartFrameTimer();
}

ErikaFlutterPlugin::~ErikaFlutterPlugin() {
  StopFrameTimer();
  smtc_.reset();
  DestroyFrameMessageWindow();
  if (window_proc_delegate_id_ != 0) {
    registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_delegate_id_);
    window_proc_delegate_id_ = 0;
  }
  if (event_channel_) {
    event_channel_->SetStreamHandler(nullptr);
  }
  players_.clear();
  overlay_window_.reset();
}

void ErikaFlutterPlugin::SetEventSink(
    std::unique_ptr<flutter::EventSink<EncodableValue>> sink) {
  event_sink_ = std::move(sink);
  StartFrameTimer();
  OnFrameTimer();
}

void ErikaFlutterPlugin::ClearEventSink() {
  event_sink_.reset();
}

HWND ErikaFlutterPlugin::FlutterWindow() const {
  auto* view = registrar_->GetView();
  if (view == nullptr) {
    return nullptr;
  }
  return view->GetNativeWindow();
}

HWND ErikaFlutterPlugin::RequestedOverlayFlutterWindow() const {
  if (!overlay_uses_secondary_window_) {
    return FlutterWindow();
  }
  return ResolveFlutterRegularHostWindow();
}

void ErikaFlutterPlugin::UpdateOverlayTarget(const EncodableMap& args) {
  const int64_t flutter_view_id =
      Int64Value(FindArg(args, "flutterViewId")).value_or(0);
  const bool secondary_window =
      BoolValue(FindArg(args, "secondaryWindow")).value_or(false);
  if (requested_flutter_view_id_ == flutter_view_id &&
      overlay_uses_secondary_window_ == secondary_window) {
    return;
  }
  requested_flutter_view_id_ = flutter_view_id;
  overlay_uses_secondary_window_ = secondary_window;
  DebugLog("overlay target changed flutterViewId=" +
           std::to_string(flutter_view_id) +
           " secondaryWindow=" +
           std::string(secondary_window ? "true" : "false"));
}

double ErikaFlutterPlugin::BackingScale() const {
  return ScaleForWindow(FlutterWindow());
}

void ErikaFlutterPlugin::StartFrameTimer() {
  if (frame_timer_running_.load(std::memory_order_acquire)) {
    return;
  }
  HWND source_hwnd = FlutterWindow();
  const double target_fps = FrameTimerTargetFps(source_hwnd);
  const double interval_ms = FrameTimerIntervalMs(target_fps);
  HWND hwnd = EnsureFrameMessageWindow();
  if (hwnd == nullptr) {
    return;
  }

  HANDLE stop_event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (stop_event == nullptr) {
    DebugLog("CreateEventW for frame scheduler failed: " + LastErrorMessage());
    return;
  }

  const uint64_t generation =
      frame_timer_generation_.fetch_add(1, std::memory_order_acq_rel) + 1;
  frame_tick_pending_.store(false, std::memory_order_release);
  frame_timer_target_fps_ = target_fps;
  frame_timer_interval_ms_ = interval_ms;
  frame_timer_stop_event_ = stop_event;
  frame_timer_running_.store(true, std::memory_order_release);
  try {
    frame_timer_thread_ = std::thread(
        &ErikaFlutterPlugin::FrameTimerThreadMain, this, hwnd, stop_event,
        interval_ms, generation);
  } catch (const std::exception& error) {
    frame_timer_running_.store(false, std::memory_order_release);
    frame_timer_generation_.fetch_add(1, std::memory_order_acq_rel);
    frame_timer_stop_event_ = nullptr;
    CloseHandle(stop_event);
    DebugLog(std::string("frame scheduler thread failed: ") + error.what());
    return;
  }

  DebugLog("frame scheduler started interval_ms=" +
           std::to_string(interval_ms) + " target_fps=" +
           std::to_string(target_fps) + " generation=" +
           std::to_string(generation));
}

void ErikaFlutterPlugin::StopFrameTimer() {
  if (!frame_timer_running_.exchange(false, std::memory_order_acq_rel)) {
    return;
  }
  frame_timer_generation_.fetch_add(1, std::memory_order_acq_rel);
  HANDLE stop_event = frame_timer_stop_event_;
  if (stop_event != nullptr) {
    SetEvent(stop_event);
  }
  if (frame_timer_thread_.joinable()) {
    frame_timer_thread_.join();
  }
  if (stop_event != nullptr) {
    CloseHandle(stop_event);
    frame_timer_stop_event_ = nullptr;
  }
  frame_tick_pending_.store(false, std::memory_order_release);
  DebugLog("frame scheduler stopped");
}

void ErikaFlutterPlugin::PostFrameTick(HWND hwnd, uint64_t generation) {
  if (!frame_timer_running_.load(std::memory_order_acquire) ||
      generation != frame_timer_generation_.load(std::memory_order_acquire)) {
    return;
  }
  bool expected = false;
  if (!frame_tick_pending_.compare_exchange_strong(
          expected, true, std::memory_order_acq_rel)) {
    return;
  }
  if (!PostMessageW(hwnd, kFrameTimerMessage, reinterpret_cast<WPARAM>(this),
                    static_cast<LPARAM>(generation))) {
    frame_tick_pending_.store(false, std::memory_order_release);
    DebugLog("PostMessage frame tick failed: " + LastErrorMessage());
  }
}

void ErikaFlutterPlugin::FrameTimerThreadMain(HWND hwnd,
                                              HANDLE stop_event,
                                              double interval_ms,
                                              uint64_t generation) {
  SetLastError(0);
  bool high_resolution = true;
  HANDLE timer =
      CreateWaitableTimerExW(nullptr, nullptr,
                             kWaitableTimerHighResolutionFlag, TIMER_ALL_ACCESS);
  if (timer == nullptr) {
    const auto high_resolution_error = LastErrorMessage();
    high_resolution = false;
    timer = CreateWaitableTimerExW(nullptr, nullptr, 0, TIMER_ALL_ACCESS);
    if (timer != nullptr) {
      DebugLog("high resolution waitable timer unavailable: " +
               high_resolution_error + "; using regular waitable timer");
    }
  }

  auto run_timeout_loop = [&]() {
    const DWORD wait_ms =
        static_cast<DWORD>(std::max(1.0, std::ceil(interval_ms)));
    while (frame_timer_running_.load(std::memory_order_acquire) &&
           generation ==
               frame_timer_generation_.load(std::memory_order_acquire)) {
      const DWORD wait = WaitForSingleObject(stop_event, wait_ms);
      if (wait != WAIT_TIMEOUT) {
        break;
      }
      PostFrameTick(hwnd, generation);
    }
  };

  if (timer == nullptr) {
    DebugLog("CreateWaitableTimerExW failed: " + LastErrorMessage() +
             "; using wait timeout loop");
    run_timeout_loop();
    return;
  }

  DebugLog(std::string("frame scheduler timer armed high_resolution=") +
           (high_resolution ? "true" : "false"));
  HANDLE wait_handles[] = {stop_event, timer};
  using clock = std::chrono::steady_clock;
  const auto period = std::chrono::duration_cast<clock::duration>(
      std::chrono::duration<double, std::milli>(interval_ms));
  auto next_tick = clock::now();
  while (frame_timer_running_.load(std::memory_order_acquire) &&
         generation == frame_timer_generation_.load(std::memory_order_acquire)) {
    next_tick += period;
    auto now = clock::now();
    const double late_ms =
        std::chrono::duration<double, std::milli>(now - next_tick).count();
    if (late_ms > interval_ms * 4.0) {
      next_tick = now + period;
    }
    const double delay_ms =
        std::chrono::duration<double, std::milli>(next_tick - now).count();
    if (delay_ms <= 0.05) {
      PostFrameTick(hwnd, generation);
      continue;
    }

    auto due_time = RelativeWaitTimeForMilliseconds(delay_ms);
    if (!SetWaitableTimer(timer, &due_time, 0, nullptr, nullptr, FALSE)) {
      DebugLog("SetWaitableTimer failed: " + LastErrorMessage() +
               "; using wait timeout loop");
      CloseHandle(timer);
      run_timeout_loop();
      return;
    }

    const DWORD wait = WaitForMultipleObjects(2, wait_handles, FALSE, INFINITE);
    if (wait == WAIT_OBJECT_0) {
      break;
    }
    if (wait == WAIT_OBJECT_0 + 1) {
      PostFrameTick(hwnd, generation);
      continue;
    }
    DebugLog("frame scheduler wait failed: " + LastErrorMessage());
    break;
  }
  CancelWaitableTimer(timer);
  CloseHandle(timer);
}

HWND ErikaFlutterPlugin::EnsureFrameMessageWindow() {
  if (frame_message_window_ != nullptr) {
    return frame_message_window_;
  }

  WNDCLASSEXW window_class{};
  window_class.cbSize = sizeof(window_class);
  window_class.lpfnWndProc = &ErikaFlutterPlugin::FrameMessageWindowProc;
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.lpszClassName = kFrameMessageWindowClassName;
  if (!RegisterClassExW(&window_class) &&
      GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    DebugLog("Unable to register frame scheduler window class: " +
             LastErrorMessage());
    return nullptr;
  }

  frame_message_window_ = CreateWindowExW(
      0, kFrameMessageWindowClassName, L"Erika Frame Scheduler", 0, 0, 0, 0, 0,
      HWND_MESSAGE, nullptr, GetModuleHandleW(nullptr), this);
  if (frame_message_window_ == nullptr) {
    DebugLog("Unable to create frame scheduler message HWND: " +
             LastErrorMessage());
  }
  return frame_message_window_;
}

void ErikaFlutterPlugin::DestroyFrameMessageWindow() {
  if (frame_message_window_ != nullptr) {
    DestroyWindow(frame_message_window_);
    frame_message_window_ = nullptr;
  }
}

void ErikaFlutterPlugin::RefreshFrameTimerForCurrentDisplay() {
  if (!frame_timer_running_.load(std::memory_order_acquire)) {
    return;
  }
  const double target_fps = FrameTimerTargetFps(FlutterWindow());
  const double interval_ms = FrameTimerIntervalMs(target_fps);
  if (std::abs(interval_ms - frame_timer_interval_ms_) <= 0.05) {
    return;
  }

  DebugLog("frame scheduler display refresh changed old_fps=" +
           std::to_string(frame_timer_target_fps_) + " new_fps=" +
           std::to_string(target_fps) + " old_interval_ms=" +
           std::to_string(frame_timer_interval_ms_) + " new_interval_ms=" +
           std::to_string(interval_ms));
  StopFrameTimer();
  StartFrameTimer();
}

LRESULT CALLBACK ErikaFlutterPlugin::FrameMessageWindowProc(HWND hwnd,
                                                            UINT message,
                                                            WPARAM wparam,
                                                            LPARAM lparam) {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }

  auto* plugin = reinterpret_cast<ErikaFlutterPlugin*>(
      GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (message == kFrameTimerMessage && plugin != nullptr) {
    const auto generation = static_cast<uint64_t>(lparam);
    if (plugin == reinterpret_cast<ErikaFlutterPlugin*>(wparam) &&
        plugin->frame_timer_running_.load(std::memory_order_acquire) &&
        generation ==
            plugin->frame_timer_generation_.load(std::memory_order_acquire)) {
      plugin->frame_tick_pending_.store(false, std::memory_order_release);
      plugin->OnFrameTimer();
    }
    return 0;
  }
  if (message == kSmtcMessage && plugin != nullptr) {
    plugin->HandleSmtcCommand(static_cast<ErikaSmtcCommand>(wparam),
                              static_cast<uint64_t>(lparam));
    return 0;
  }

  if (message == WM_NCDESTROY && plugin != nullptr) {
    if (plugin->frame_message_window_ == hwnd) {
      plugin->frame_message_window_ = nullptr;
    }
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

void ErikaFlutterPlugin::OnFrameTimer() {
  if (in_frame_timer_) {
    return;
  }
  in_frame_timer_ = true;
  static bool trace_enabled = FrameTraceEnabled();
  static auto last_tick = std::chrono::steady_clock::now();
  static uint64_t tick_count = 0;
  const auto tick_started = std::chrono::steady_clock::now();
  for (auto& entry : players_) {
    entry.second->RenderTick(event_sink_.get());
  }
  RefreshSmtc();
  if (trace_enabled) {
    tick_count += 1;
    const auto elapsed = std::chrono::duration<double, std::milli>(
        tick_started - last_tick);
    const auto work = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - tick_started);
    if (tick_count % 60 == 0 || elapsed.count() > 24.0 || work.count() > 8.0) {
      DebugLog("frame_tick count=" + std::to_string(tick_count) +
               " delta_ms=" + std::to_string(elapsed.count()) +
               " work_ms=" + std::to_string(work.count()) +
               " players=" + std::to_string(players_.size()));
    }
    last_tick = tick_started;
  }
  in_frame_timer_ = false;
}

std::optional<LRESULT> ErikaFlutterPlugin::OnTopLevelWindowProc(
    HWND hwnd,
    UINT message,
    WPARAM wparam,
    LPARAM lparam) {
  if (message == WM_MOVE || message == WM_MOVING || message == WM_SIZE ||
      message == WM_SIZING || message == WM_EXITSIZEMOVE ||
      message == WM_SHOWWINDOW || message == WM_DPICHANGED ||
      message == WM_WINDOWPOSCHANGED) {
    if (overlay_window_) {
      overlay_window_->RefreshScaleAndReposition();
      ResizeAttachedOverlay();
    }
    RefreshFrameTimerForCurrentDisplay();
  }
  if (message == WM_DESTROY) {
    StopFrameTimer();
    smtc_.reset();
    for (auto& entry : players_) {
      entry.second->Detach(std::nullopt);
    }
    overlay_window_.reset();
  }
  return std::nullopt;
}

ErikaFlutterPlugin::ErikaOverlayWindow& ErikaFlutterPlugin::EnsureOverlayWindow() {
  HWND parent = RequestedOverlayFlutterWindow();
  if (parent == nullptr) {
    throw PluginError(overlay_uses_secondary_window_
                          ? "No detached Flutter HWND is available for Erika overlay."
                          : "No Flutter HWND is available for Erika overlay.");
  }
  if (!overlay_window_ || overlay_window_->flutter != parent) {
    const std::string blend_mode =
        overlay_window_ ? overlay_window_->blend_mode : "srcOver";
    const double opacity = overlay_window_ ? overlay_window_->opacity : 1.0;
    overlay_window_ = std::make_unique<ErikaOverlayWindow>(parent);
    overlay_window_->ConfigureComposition(blend_mode, opacity);
    StartFrameTimer();
    for (auto& entry : players_) {
      if (entry.second->attached_view_id == kWindowOverlayViewId) {
        entry.second->AttachOverlay(*overlay_window_);
      }
    }
  }
  return *overlay_window_;
}

ErikaFlutterPlugin::PlayerHost& ErikaFlutterPlugin::PlayerFromArgs(
    const EncodableMap& args) {
  const int64_t player_id = RequiredInt64(args, "playerId");
  const auto it = players_.find(player_id);
  if (it == players_.end()) {
    throw PluginError("Erika player " + std::to_string(player_id) +
                      " was not found.");
  }
  return *it->second;
}

void ErikaFlutterPlugin::ResizeAttachedOverlay() {
  if (!overlay_window_) {
    return;
  }
  for (auto& entry : players_) {
    if (entry.second->attached_view_id == kWindowOverlayViewId) {
      try {
        entry.second->ResizeOverlay(*overlay_window_);
      } catch (const std::exception& error) {
        DebugLog(std::string("resize_surface failed: ") + error.what());
      }
    }
  }
}

int64_t ErikaFlutterPlugin::CreatePlayer(const EncodableValue* arguments) {
  ErikaPresenterConfig config{};
  config.output_mode = ErikaPresenterOutputMode_Sdr;
  config.edr_headroom = 1.0f;
  config.luma_upscaler = ErikaLumaUpscalerMode_Off;

  if (arguments != nullptr && std::holds_alternative<EncodableMap>(*arguments)) {
    const auto& args = std::get<EncodableMap>(*arguments);
    if (auto value = Int64Value(FindArg(args, "outputMode"))) {
      config.output_mode = static_cast<int32_t>(*value);
    }
    if (auto value = DoubleValue(FindArg(args, "edrHeadroom"))) {
      config.edr_headroom = static_cast<float>(std::max(1.0, *value));
    }
    if (auto value = Int64Value(FindArg(args, "videoAlphaMode"))) {
      config.video_alpha_mode = static_cast<int32_t>(*value);
    }
  }

  const int64_t id = next_player_id_++;
  players_[id] = std::make_unique<PlayerHost>(
      id, ErikaNativeLibrary::Shared(), config);
  StartFrameTimer();
  OnFrameTimer();
  return id;
}

void ErikaFlutterPlugin::EnsureSmtc() {
  if (smtc_) {
    return;
  }
  HWND window = RootHostWindow(FlutterWindow());
  if (window == nullptr) {
    return;
  }
  HWND message_window = EnsureFrameMessageWindow();
  if (message_window == nullptr) {
    return;
  }
  smtc_ = std::make_unique<ErikaWindowsSmtc>(
      window, [message_window](ErikaSmtcCommand command,
                               uint64_t position_micros) {
        PostMessageW(message_window, kSmtcMessage,
                     static_cast<WPARAM>(command),
                     static_cast<LPARAM>(position_micros));
      });
  if (!smtc_->available()) {
    smtc_.reset();
  }
}

void ErikaFlutterPlugin::SetActivePlayer(int64_t player_id) {
  active_player_id_ = player_id;
  EnsureSmtc();
  RefreshSmtc();
}

void ErikaFlutterPlugin::RefreshSmtc() {
  if (!smtc_ || active_player_id_ == 0) {
    return;
  }
  const auto it = players_.find(active_player_id_);
  if (it == players_.end()) {
    smtc_->Clear();
    active_player_id_ = 0;
    return;
  }
  smtc_->Update(it->second->smtc_state);
}

void ErikaFlutterPlugin::HandleSmtcCommand(ErikaSmtcCommand command,
                                           uint64_t position_micros) {
  const auto it = players_.find(active_player_id_);
  if (it == players_.end()) {
    return;
  }
  try {
    if (command == ErikaSmtcCommand::play) {
      it->second->Play();
    } else if (command == ErikaSmtcCommand::pause) {
      it->second->Pause();
    } else if (command == ErikaSmtcCommand::toggle) {
      if (it->second->smtc_state.playing) {
        it->second->Pause();
      } else {
        it->second->Play();
      }
    } else if (command == ErikaSmtcCommand::seek) {
      it->second->Seek(position_micros);
    } else if (command == ErikaSmtcCommand::previous ||
               command == ErikaSmtcCommand::next) {
      const bool enabled = command == ErikaSmtcCommand::previous
                               ? it->second->smtc_state.previous_enabled
                               : it->second->smtc_state.next_enabled;
      if (enabled) {
        SendEvent(EncodableValue(EncodableMap{
            {EncodableValue("playerId"), EncodableValue(active_player_id_)},
            {EncodableValue("kind"), EncodableValue(13)},
            {EncodableValue("navigation"),
             EncodableValue(command == ErikaSmtcCommand::previous ? "previous"
                                                                   : "next")},
        }));
      }
    }
    OnFrameTimer();
  } catch (const std::exception& error) {
    DebugLog(std::string("SMTC command failed: ") + error.what());
  }
}

void ErikaFlutterPlugin::RemovePlayer(int64_t player_id) {
  const auto it = players_.find(player_id);
  if (it == players_.end()) {
    return;
  }
  // Hide the shared HWND before destroying the presenter. Presenter teardown
  // may wait for decoder threads, and leaving the overlay visible during that
  // wait exposes the transparent Flutter cutout as an apparently frozen app.
  if (overlay_window_ && overlay_window_->owner_player_id == player_id) {
    overlay_window_->SetFrame(0.0, 0.0, 0.0, 0.0, false, std::nullopt,
                              std::nullopt);
    overlay_window_->owner_player_id = 0;
  }
  if (active_player_id_ == player_id) {
    active_player_id_ = 0;
    if (smtc_) {
      smtc_->Clear();
    }
  }
  players_.erase(it);
}

void ErikaFlutterPlugin::SendEvent(EncodableValue event) {
  if (event_sink_ != nullptr) {
    event_sink_->Success(event);
  }
}

void ErikaFlutterPlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto& method = method_call.method_name();
  try {
    if (method == "create") {
      const int64_t player_id = CreatePlayer(method_call.arguments());
      OnFrameTimer();
      result->Success(EncodableValue(player_id));
      return;
    }

    const EncodableMap& args = DictionaryArgs(method_call.arguments());

    if (method == "dispose") {
      RemovePlayer(RequiredInt64(args, "playerId"));
      OnFrameTimer();
      result->Success();
    } else if (method == "open") {
      auto& player = PlayerFromArgs(args);
      if (const auto* value = FindArg(args, "metadata"); value != nullptr) {
        if (const auto* metadata = std::get_if<EncodableMap>(value)) {
          player.SetMediaMetadata(*metadata);
        } else if (std::holds_alternative<std::monostate>(*value)) {
          player.ClearMediaMetadata();
        } else {
          throw PluginError("metadata must be a map.");
        }
      } else {
        player.ClearMediaMetadata();
      }
      player.PrepareForOpen();
      player.Open(RequiredString(args, "uri"), args);
      OnFrameTimer();
      result->Success();
    } else if (method == "play") {
      auto& player = PlayerFromArgs(args);
      player.Play();
      SetActivePlayer(player.id);
      OnFrameTimer();
      result->Success();
    } else if (method == "pause") {
      PlayerFromArgs(args).Pause();
      OnFrameTimer();
      result->Success();
    } else if (method == "stop") {
      PlayerFromArgs(args).Stop();
      OnFrameTimer();
      result->Success();
    } else if (method == "close") {
      PlayerFromArgs(args).Close();
      OnFrameTimer();
      result->Success();
    } else if (method == "seek") {
      PlayerFromArgs(args).Seek(
          static_cast<uint64_t>(std::max<int64_t>(
              0, RequiredInt64(args, "positionMicros"))));
      OnFrameTimer();
      result->Success();
    } else if (method == "setPlaybackRate") {
      PlayerFromArgs(args).SetPlaybackRate(
          DoubleValue(FindArg(args, "rate")).value_or(1.0));
      result->Success();
    } else if (method == "setMediaMetadata") {
      const auto* value = FindArg(args, "metadata");
      const auto* metadata = value == nullptr ? nullptr : std::get_if<EncodableMap>(value);
      if (metadata == nullptr) {
        throw PluginError("metadata is required.");
      }
      PlayerFromArgs(args).SetMediaMetadata(*metadata);
      RefreshSmtc();
      result->Success();
    } else if (method == "setSystemMediaNavigation") {
      PlayerFromArgs(args).SetSystemMediaNavigation(
          BoolValue(FindArg(args, "previousEnabled")).value_or(false),
          BoolValue(FindArg(args, "nextEnabled")).value_or(false));
      RefreshSmtc();
      result->Success();
    } else if (method == "setVolume") {
      PlayerFromArgs(args).SetVolume(
          DoubleValue(FindArg(args, "volume")).value_or(1.0));
      result->Success();
    } else if (method == "setUpscaler") {
      PlayerFromArgs(args).SetUpscaler(
          static_cast<int32_t>(RequiredInt64(args, "mode")));
      result->Success();
    } else if (method == "setSubtitleScale") {
      PlayerFromArgs(args).SetSubtitleScale(
          DoubleValue(FindArg(args, "scale")).value_or(1.0));
      result->Success();
    } else if (method == "registerSubtitleMemoryFont") {
      const auto* data = std::get_if<std::vector<uint8_t>>(FindArg(args, "data"));
      if (data == nullptr || data->empty()) {
        throw PluginError("data is required.");
      }
      result->Success(EncodableValue(static_cast<int64_t>(
          PlayerFromArgs(args).RegisterSubtitleMemoryFont(*data))));
    } else if (method == "selectSubtitleMemoryFonts") {
      const auto* ids = std::get_if<EncodableList>(FindArg(args, "fontIds"));
      if (ids == nullptr) {
        throw PluginError("fontIds is required.");
      }
      PlayerFromArgs(args).SelectSubtitleMemoryFonts(*ids);
      result->Success();
    } else if (method == "clearSubtitleMemoryFonts") {
      PlayerFromArgs(args).ClearSubtitleMemoryFonts();
      result->Success();
    } else if (method == "getSubtitleMemoryFontStatus") {
      result->Success(PlayerFromArgs(args).GetSubtitleMemoryFontStatus());
    } else if (method == "setSubtitleStyle") {
      auto& host = PlayerFromArgs(args);
      const bool has_style = FindArg(args, "fontFamily") != nullptr ||
                             FindArg(args, "fontFilePath") != nullptr ||
                             FindArg(args, "primaryColorRgba") != nullptr ||
                             FindArg(args, "outlineColorRgba") != nullptr ||
                             FindArg(args, "fontSize") != nullptr ||
                             FindArg(args, "outlineWidth") != nullptr ||
                             FindArg(args, "bold") != nullptr ||
                             FindArg(args, "italic") != nullptr ||
                             FindArg(args, "underline") != nullptr ||
                             FindArg(args, "strikeOut") != nullptr ||
                             FindArg(args, "spacing") != nullptr ||
                             FindArg(args, "scaleXPercent") != nullptr ||
                             FindArg(args, "scaleYPercent") != nullptr ||
                             FindArg(args, "borderStyle") != nullptr ||
                             FindArg(args, "shadowDepth") != nullptr ||
                             FindArg(args, "blur") != nullptr ||
                             FindArg(args, "alignment") != nullptr ||
                             FindArg(args, "marginLeft") != nullptr ||
                             FindArg(args, "marginRight") != nullptr ||
                             FindArg(args, "marginVertical") != nullptr ||
                             FindArg(args, "overrideMask") != nullptr;
      if (has_style) {
        const int64_t primary =
            Int64Value(FindArg(args, "primaryColorRgba")).value_or(0xFFFFFFFF);
        const int64_t outline =
            Int64Value(FindArg(args, "outlineColorRgba")).value_or(0x0000007F);
        host.SetSubtitleStyle(
            StringValue(FindArg(args, "fontFamily")),
            StringValue(FindArg(args, "fontFilePath")),
            static_cast<uint32_t>(primary), static_cast<uint32_t>(outline),
            DoubleValue(FindArg(args, "fontSize")).value_or(48.0),
            DoubleValue(FindArg(args, "outlineWidth")).value_or(2.0),
            BoolValue(FindArg(args, "bold")).value_or(false),
            BoolValue(FindArg(args, "italic")).value_or(false),
            BoolValue(FindArg(args, "underline")).value_or(false),
            BoolValue(FindArg(args, "strikeOut")).value_or(false),
            DoubleValue(FindArg(args, "spacing")).value_or(0.0),
            DoubleValue(FindArg(args, "scaleXPercent")).value_or(100.0),
            DoubleValue(FindArg(args, "scaleYPercent")).value_or(100.0),
            static_cast<int32_t>(
                Int64Value(FindArg(args, "borderStyle")).value_or(1)),
            DoubleValue(FindArg(args, "shadowDepth")).value_or(0.0),
            DoubleValue(FindArg(args, "blur")).value_or(0.0),
            static_cast<int32_t>(
                Int64Value(FindArg(args, "alignment")).value_or(2)),
            static_cast<int32_t>(
                Int64Value(FindArg(args, "marginLeft")).value_or(48)),
            static_cast<int32_t>(
                Int64Value(FindArg(args, "marginRight")).value_or(48)),
            static_cast<int32_t>(
                Int64Value(FindArg(args, "marginVertical")).value_or(54)),
            static_cast<uint32_t>(
                Int64Value(FindArg(args, "overrideMask")).value_or(0)));
      }
      result->Success();
    } else if (method == "getUpscalerStatus") {
      result->Success(PlayerFromArgs(args).GetUpscalerStatus());
    } else if (method == "getOutputStatus") {
      result->Success(PlayerFromArgs(args).GetOutputStatus());
    } else if (method == "getPresenterStats") {
      result->Success(PlayerFromArgs(args).GetPresenterStats());
    } else if (method == "getResourceStatus") {
      result->Success(PlayerFromArgs(args).GetResourceStatus());
    } else if (method == "setDebugHudEnabled") {
      PlayerFromArgs(args).SetDebugHudEnabled(
          BoolValue(FindArg(args, "enabled")).value_or(false));
      result->Success();
    } else if (method == "addExternalSubtitle") {
      const int64_t track_id =
          PlayerFromArgs(args).AddExternalSubtitle(RequiredString(args, "uri"));
      OnFrameTimer();
      result->Success(EncodableValue(track_id));
    } else if (method == "removeSubtitleTrack") {
      PlayerFromArgs(args).RemoveSubtitleTrack(
          RequiredInt64(args, "trackId"));
      OnFrameTimer();
      result->Success();
    } else if (method == "loadDanmakuFile") {
      PlayerFromArgs(args).LoadDanmakuFile(RequiredString(args, "uri"));
      result->Success();
    } else if (method == "loadDanmakuJson") {
      PlayerFromArgs(args).LoadDanmakuJson(RequiredString(args, "json"));
      result->Success();
    } else if (method == "addDanmakuTrackFile") {
      result->Success(EncodableValue(static_cast<int64_t>(
          PlayerFromArgs(args).AddDanmakuTrackFile(
              RequiredString(args, "uri"), StringValue(FindArg(args, "name")),
              Int64Value(FindArg(args, "offsetMicros")).value_or(0)))));
    } else if (method == "addDanmakuTrackJson") {
      result->Success(EncodableValue(static_cast<int64_t>(
          PlayerFromArgs(args).AddDanmakuTrackJson(
              RequiredString(args, "json"), StringValue(FindArg(args, "name")),
              Int64Value(FindArg(args, "offsetMicros")).value_or(0)))));
    } else if (method == "removeDanmakuTrack") {
      PlayerFromArgs(args).RemoveDanmakuTrack(
          static_cast<uint64_t>(RequiredInt64(args, "trackId")));
      result->Success();
    } else if (method == "setDanmakuTrackEnabled") {
      PlayerFromArgs(args).SetDanmakuTrackEnabled(
          static_cast<uint64_t>(RequiredInt64(args, "trackId")),
          BoolValue(FindArg(args, "enabled")).value_or(true));
      result->Success();
    } else if (method == "setDanmakuTrackOffset") {
      PlayerFromArgs(args).SetDanmakuTrackOffset(
          static_cast<uint64_t>(RequiredInt64(args, "trackId")),
          Int64Value(FindArg(args, "offsetMicros")).value_or(0));
      result->Success();
    } else if (method == "setDanmakuGlobalOffset") {
      PlayerFromArgs(args).SetDanmakuGlobalOffset(
          Int64Value(FindArg(args, "offsetMicros")).value_or(0));
      result->Success();
    } else if (method == "danmakuTracks") {
      result->Success(PlayerFromArgs(args).DanmakuTracks());
    } else if (method == "clearDanmaku") {
      PlayerFromArgs(args).ClearDanmaku();
      result->Success();
    } else if (method == "setDanmakuEnabled") {
      PlayerFromArgs(args).SetDanmakuEnabled(
          BoolValue(FindArg(args, "enabled")).value_or(true));
      result->Success();
    } else if (method == "setDanmakuConfig") {
      auto& host = PlayerFromArgs(args);
      host.SetDanmakuConfig(host.DanmakuConfigFromArgs(args));
      const bool has_font = FindArg(args, "customFontFamily") != nullptr ||
                            FindArg(args, "customFontFilePath") != nullptr;
      if (has_font) {
        host.SetDanmakuFont(StringValue(FindArg(args, "customFontFamily")),
                            StringValue(FindArg(args, "customFontFilePath")));
      }
      if (auto block_words = StringValue(FindArg(args, "blockWordsJson"))) {
        host.SetDanmakuBlockWordsJson(*block_words);
      }
      result->Success();
    } else if (method == "selectAudioTrack") {
      PlayerFromArgs(args).SelectAudioTrack(OptionalTrackId(FindArg(args, "trackId")));
      OnFrameTimer();
      result->Success();
    } else if (method == "selectSubtitleTrack") {
      PlayerFromArgs(args).SelectSubtitleTrack(
          OptionalTrackId(FindArg(args, "trackId")));
      OnFrameTimer();
      result->Success();
    } else if (method == "tracks") {
      result->Success(PlayerFromArgs(args).Tracks());
    } else if (method == "screenshot") {
      result->Success();
    } else if (method == "attachView") {
      auto& host = PlayerFromArgs(args);
      const int64_t view_id = RequiredInt64(args, "viewId");
      if (view_id != kWindowOverlayViewId) {
        throw PluginError("Erika video view " + std::to_string(view_id) +
                          " was not found.");
      }
      auto& overlay = EnsureOverlayWindow();
      overlay.ConfigureComposition(
          StringValue(FindArg(args, "blendMode")).value_or("srcOver"),
          DoubleValue(FindArg(args, "opacity")).value_or(1.0));
      host.AttachOverlay(overlay);
      overlay.owner_player_id = host.id;
      OnFrameTimer();
      result->Success();
    } else if (method == "detachView") {
      PlayerFromArgs(args).Detach(RequiredInt64(args, "viewId"));
      OnFrameTimer();
      result->Success();
    } else if (method == "attachOverlay") {
      auto& host = PlayerFromArgs(args);
      UpdateOverlayTarget(args);
      auto& overlay = EnsureOverlayWindow();
      overlay.ConfigureComposition(
          StringValue(FindArg(args, "blendMode")).value_or("srcOver"),
          DoubleValue(FindArg(args, "opacity")).value_or(1.0));
      host.AttachOverlay(overlay);
      overlay.owner_player_id = host.id;
      OnFrameTimer();
      result->Success(EncodableValue(kWindowOverlayViewId));
    } else if (method == "detachOverlay") {
      auto& host = PlayerFromArgs(args);
      const auto generation = Int64Value(FindArg(args, "generation"));
      if (generation && overlay_window_ &&
          *generation != overlay_window_->active_generation) {
        result->Success();
        return;
      }
      host.Detach(kWindowOverlayViewId);
      OnFrameTimer();
      if (overlay_window_) {
        overlay_window_->SetFrame(0.0, 0.0, 0.0, 0.0, false, generation,
                                  std::nullopt);
        if (overlay_window_->owner_player_id == host.id) {
          overlay_window_->owner_player_id = 0;
        }
      }
      result->Success();
    } else if (method == "setOverlayFrame") {
      const bool visible =
          BoolValue(FindArg(args, "visible")).value_or(true);
      const auto generation = Int64Value(FindArg(args, "generation"));
      if (!visible && generation && overlay_window_ &&
          *generation != overlay_window_->active_generation) {
        result->Success();
        return;
      }
      UpdateOverlayTarget(args);
      auto& overlay = EnsureOverlayWindow();
      const int64_t player_id = RequiredInt64(args, "playerId");
      auto& host = PlayerFromArgs(args);
      if (!visible && overlay.owner_player_id != 0 &&
          overlay.owner_player_id != player_id) {
        result->Success();
        return;
      }
      if (visible) {
        overlay.owner_player_id = player_id;
      }
      overlay.ConfigureComposition(
          StringValue(FindArg(args, "blendMode")).value_or("srcOver"),
          DoubleValue(FindArg(args, "opacity")).value_or(1.0));
      if (host.surface_attached &&
          host.attached_view_id == kWindowOverlayViewId &&
          host.composition_surface != host.RequiresComposition(overlay)) {
        host.AttachOverlay(overlay);
      }
      overlay.SetFrame(DoubleValue(FindArg(args, "x")).value_or(0.0),
                       DoubleValue(FindArg(args, "y")).value_or(0.0),
                       DoubleValue(FindArg(args, "width")).value_or(0.0),
                       DoubleValue(FindArg(args, "height")).value_or(0.0),
                       visible, generation,
                       StringValue(FindArg(args, "debugLabel")));
      if (!visible && overlay.owner_player_id == player_id) {
        overlay.owner_player_id = 0;
      }
      ResizeAttachedOverlay();
      OnFrameTimer();
      result->Success();
    } else {
      result->NotImplemented();
    }
  } catch (const std::exception& error) {
    const auto message = SafeUtf8Message(error.what());
    DebugLog("method " + method + " failed: " + message);
    result->Error("ERIKA_ERROR", message);
  }
}

}  // namespace erika_flutter
