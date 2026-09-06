#include "erika_windows_smtc.h"

#include <SystemMediaTransportControlsInterop.h>
#include <shcore.h>
#include <shlwapi.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/base.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <limits>
#include <utility>

namespace erika_flutter {
namespace {

winrt::Windows::Foundation::TimeSpan MicrosToTimeSpan(uint64_t micros) {
  using namespace std::chrono;
  return duration_cast<winrt::Windows::Foundation::TimeSpan>(
      microseconds(micros));
}

winrt::Windows::Storage::Streams::IRandomAccessStream ArtworkStream(
    const std::vector<uint8_t>& artwork) {
  if (artwork.size() > std::numeric_limits<UINT>::max()) {
    throw winrt::hresult_invalid_argument();
  }
  winrt::com_ptr<IStream> stream;
  stream.attach(SHCreateMemStream(artwork.data(),
                                  static_cast<UINT>(artwork.size())));
  if (!stream) {
    winrt::throw_hresult(E_OUTOFMEMORY);
  }
  return winrt::capture<
      winrt::Windows::Storage::Streams::IRandomAccessStream>(
      CreateRandomAccessStreamOverStream, stream.get(), BSOS_DEFAULT);
}

}

struct ErikaWindowsSmtc::Impl {
  struct CallbackState {
    CommandHandler handler;
    std::atomic<bool> enabled{true};
  };

  Impl(HWND window, CommandHandler command_handler)
      : callback_state(std::make_shared<CallbackState>()) {
    callback_state->handler = std::move(command_handler);
    try {
      auto interop = winrt::get_activation_factory<
          winrt::Windows::Media::SystemMediaTransportControls,
          ISystemMediaTransportControlsInterop>();
      winrt::check_hresult(interop->GetForWindow(
          window, winrt::guid_of<winrt::Windows::Media::SystemMediaTransportControls>(),
          winrt::put_abi(controls)));
      controls.IsEnabled(true);
      controls.IsPlayEnabled(true);
      controls.IsPauseEnabled(true);
      controls.IsStopEnabled(false);
      controls.IsNextEnabled(false);
      controls.IsPreviousEnabled(false);
      button_token = controls.ButtonPressed(
          [state = callback_state](const auto&, const auto& args) {
            if (!state->enabled.load(std::memory_order_acquire)) {
              return;
            }
            using Button =
                winrt::Windows::Media::SystemMediaTransportControlsButton;
            if (args.Button() == Button::Play) {
              state->handler(ErikaSmtcCommand::play, 0);
            } else if (args.Button() == Button::Pause) {
              state->handler(ErikaSmtcCommand::pause, 0);
            } else if (args.Button() == Button::Previous) {
              state->handler(ErikaSmtcCommand::previous, 0);
            } else if (args.Button() == Button::Next) {
              state->handler(ErikaSmtcCommand::next, 0);
            }
          });
      seek_token = controls.PlaybackPositionChangeRequested(
          [state = callback_state](const auto&, const auto& args) {
            if (!state->enabled.load(std::memory_order_acquire)) {
              return;
            }
            const auto ticks = args.RequestedPlaybackPosition().count();
            state->handler(
                ErikaSmtcCommand::seek,
                ticks <= 0 ? 0 : static_cast<uint64_t>(ticks / 10));
          });
    } catch (...) {
      controls = nullptr;
    }
  }

  ~Impl() {
    callback_state->enabled.store(false, std::memory_order_release);
    if (controls) {
      controls.ButtonPressed(button_token);
      controls.PlaybackPositionChangeRequested(seek_token);
      controls.IsEnabled(false);
    }
  }

  void Update(const ErikaSmtcState& state) {
    if (!controls) {
      return;
    }
    try {
      if (!has_state ||
          state.metadata_revision != last_state.metadata_revision) {
        auto display = controls.DisplayUpdater();
        display.Type(winrt::Windows::Media::MediaPlaybackType::Music);
        auto properties = display.MusicProperties();
        properties.Title(winrt::to_hstring(state.title));
        properties.Artist(winrt::to_hstring(state.artist));
        properties.AlbumTitle(winrt::to_hstring(state.album));
        if (!state.artwork.empty()) {
          display.Thumbnail(
              winrt::Windows::Storage::Streams::RandomAccessStreamReference::CreateFromStream(
                  ArtworkStream(state.artwork)));
        } else {
          display.Thumbnail(nullptr);
        }
        display.Update();
      }

      if (!has_state || state.duration_micros != last_state.duration_micros ||
          state.position_micros != last_state.position_micros) {
        winrt::Windows::Media::SystemMediaTransportControlsTimelineProperties timeline;
        timeline.StartTime(MicrosToTimeSpan(0));
        timeline.MinSeekTime(MicrosToTimeSpan(0));
        timeline.Position(MicrosToTimeSpan(
            std::min(state.position_micros, state.duration_micros)));
        timeline.MaxSeekTime(MicrosToTimeSpan(state.duration_micros));
        timeline.EndTime(MicrosToTimeSpan(state.duration_micros));
        controls.UpdateTimelineProperties(timeline);
      }
      if (!has_state || state.playback_rate != last_state.playback_rate) {
        controls.PlaybackRate(state.playback_rate);
      }
      if (!has_state ||
          state.previous_enabled != last_state.previous_enabled) {
        controls.IsPreviousEnabled(state.previous_enabled);
      }
      if (!has_state || state.next_enabled != last_state.next_enabled) {
        controls.IsNextEnabled(state.next_enabled);
      }
      if (!has_state || state.playing != last_state.playing ||
          state.stopped != last_state.stopped) {
        controls.PlaybackStatus(
            state.playing
                ? winrt::Windows::Media::MediaPlaybackStatus::Playing
                : state.stopped
                      ? winrt::Windows::Media::MediaPlaybackStatus::Stopped
                      : winrt::Windows::Media::MediaPlaybackStatus::Paused);
      }
      last_state = state;
      has_state = true;
    } catch (...) {
    }
  }

  void Clear() {
    if (!controls) {
      return;
    }
    try {
      controls.DisplayUpdater().ClearAll();
      controls.PlaybackStatus(
          winrt::Windows::Media::MediaPlaybackStatus::Closed);
      has_state = false;
    } catch (...) {
    }
  }

  std::shared_ptr<CallbackState> callback_state;
  winrt::Windows::Media::SystemMediaTransportControls controls{nullptr};
  winrt::event_token button_token{};
  winrt::event_token seek_token{};
  ErikaSmtcState last_state{};
  bool has_state = false;
};

ErikaWindowsSmtc::ErikaWindowsSmtc(HWND window, CommandHandler handler)
    : impl_(std::make_unique<Impl>(window, std::move(handler))) {}

ErikaWindowsSmtc::~ErikaWindowsSmtc() = default;

bool ErikaWindowsSmtc::available() const {
  return impl_->controls != nullptr;
}

void ErikaWindowsSmtc::Update(const ErikaSmtcState& state) {
  impl_->Update(state);
}

void ErikaWindowsSmtc::Clear() {
  impl_->Clear();
}

}
