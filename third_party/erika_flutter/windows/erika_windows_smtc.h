#ifndef FLUTTER_PLUGIN_ERIKA_WINDOWS_SMTC_H_
#define FLUTTER_PLUGIN_ERIKA_WINDOWS_SMTC_H_

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace erika_flutter {

enum class ErikaSmtcCommand {
  play,
  pause,
  toggle,
  seek,
  previous,
  next,
};

struct ErikaSmtcState {
  int64_t player_id = 0;
  std::string title;
  std::string artist;
  std::string album;
  std::vector<uint8_t> artwork;
  uint64_t metadata_revision = 0;
  uint64_t duration_micros = 0;
  uint64_t position_micros = 0;
  double playback_rate = 1.0;
  bool playing = false;
  bool stopped = true;
  bool previous_enabled = false;
  bool next_enabled = false;
};

class ErikaWindowsSmtc {
 public:
  using CommandHandler =
      std::function<void(ErikaSmtcCommand, uint64_t position_micros)>;

  ErikaWindowsSmtc(HWND window, CommandHandler handler);
  ~ErikaWindowsSmtc();

  ErikaWindowsSmtc(const ErikaWindowsSmtc&) = delete;
  ErikaWindowsSmtc& operator=(const ErikaWindowsSmtc&) = delete;

  bool available() const;
  void Update(const ErikaSmtcState& state);
  void Clear();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}

#endif
