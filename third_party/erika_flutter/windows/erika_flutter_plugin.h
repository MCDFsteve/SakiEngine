#ifndef FLUTTER_PLUGIN_ERIKA_FLUTTER_PLUGIN_H_
#define FLUTTER_PLUGIN_ERIKA_FLUTTER_PLUGIN_H_

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <optional>
#include <thread>
#include <unordered_map>

#include "erika.h"
#include "erika_windows_smtc.h"

namespace erika_flutter {

class ErikaFlutterPlugin;

class ErikaEventStreamHandler
    : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  explicit ErikaEventStreamHandler(ErikaFlutterPlugin* plugin);

 protected:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnListenInternal(
      const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
      override;

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnCancelInternal(const flutter::EncodableValue* arguments) override;

 private:
  ErikaFlutterPlugin* plugin_;
};

class ErikaFlutterPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit ErikaFlutterPlugin(flutter::PluginRegistrarWindows* registrar);
  ~ErikaFlutterPlugin() override;

  ErikaFlutterPlugin(const ErikaFlutterPlugin&) = delete;
  ErikaFlutterPlugin& operator=(const ErikaFlutterPlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void SetEventSink(
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink);
  void ClearEventSink();

 private:
  struct ErikaNativeLibrary;
  struct ErikaOverlayWindow;
  struct PlayerHost;

  friend class ErikaEventStreamHandler;

  HWND FlutterWindow() const;
  double BackingScale() const;
  void StartFrameTimer();
  void StopFrameTimer();
  void PostFrameTick(HWND hwnd, uint64_t generation);
  void FrameTimerThreadMain(HWND hwnd,
                            HANDLE stop_event,
                            double interval_ms,
                            uint64_t generation);
  HWND EnsureFrameMessageWindow();
  void DestroyFrameMessageWindow();
  void RefreshFrameTimerForCurrentDisplay();
  static LRESULT CALLBACK FrameMessageWindowProc(HWND hwnd,
                                                 UINT message,
                                                 WPARAM wparam,
                                                 LPARAM lparam);
  void OnFrameTimer();
  std::optional<LRESULT> OnTopLevelWindowProc(HWND hwnd,
                                              UINT message,
                                              WPARAM wparam,
                                              LPARAM lparam);

  ErikaOverlayWindow& EnsureOverlayWindow();
  HWND RequestedOverlayFlutterWindow() const;
  void UpdateOverlayTarget(const flutter::EncodableMap& args);
  PlayerHost& PlayerFromArgs(const flutter::EncodableMap& args);
  void ResizeAttachedOverlay();
  int64_t CreatePlayer(const flutter::EncodableValue* arguments);
  void RemovePlayer(int64_t player_id);
  void SendEvent(flutter::EncodableValue event);
  void EnsureSmtc();
  void SetActivePlayer(int64_t player_id);
  void RefreshSmtc();
  void HandleSmtcCommand(ErikaSmtcCommand command, uint64_t position_micros);

  flutter::PluginRegistrarWindows* registrar_ = nullptr;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      event_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
  std::unordered_map<int64_t, std::unique_ptr<PlayerHost>> players_;
  std::unique_ptr<ErikaOverlayWindow> overlay_window_;
  std::unique_ptr<ErikaWindowsSmtc> smtc_;
  int64_t active_player_id_ = 0;
  int64_t requested_flutter_view_id_ = 0;
  bool overlay_uses_secondary_window_ = false;
  int64_t next_player_id_ = 1;
  int window_proc_delegate_id_ = 0;
  HWND frame_message_window_ = nullptr;
  HANDLE frame_timer_stop_event_ = nullptr;
  std::thread frame_timer_thread_;
  std::atomic<bool> frame_timer_running_{false};
  std::atomic<bool> frame_tick_pending_{false};
  std::atomic<uint64_t> frame_timer_generation_{0};
  double frame_timer_target_fps_ = 0.0;
  double frame_timer_interval_ms_ = 0.0;
  bool in_frame_timer_ = false;
};

}  // namespace erika_flutter

#endif  // FLUTTER_PLUGIN_ERIKA_FLUTTER_PLUGIN_H_
