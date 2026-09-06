#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <fstream>
#include <sstream>

#include "flutter_window.h"
#include "utils.h"

namespace {

std::wstring Utf16FromUtf8(const std::string& value) {
  if (value.empty()) return std::wstring();
  const int length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (length <= 0) return std::wstring();
  std::wstring converted(length, L'\0');
  if (::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
                            static_cast<int>(value.size()), converted.data(),
                            length) <= 0) {
    return std::wstring();
  }
  return converted;
}

std::wstring ReadBundleProductName() {
  wchar_t executable_path[MAX_PATH] = {};
  const DWORD length =
      ::GetModuleFileNameW(nullptr, executable_path, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) return L"SakiEngine";
  std::wstring setting_path(executable_path, length);
  const size_t separator = setting_path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) return L"SakiEngine";
  setting_path.resize(separator + 1);
  setting_path.append(L"saki_product_name.txt");

  std::ifstream input(setting_path, std::ios::binary);
  if (!input) return L"SakiEngine";
  std::ostringstream contents;
  contents << input.rdbuf();
  std::string value = contents.str();
  while (!value.empty() &&
         (value.back() == '\n' || value.back() == '\r' || value.back() == ' ')) {
    value.pop_back();
  }
  const std::wstring converted = Utf16FromUtf8(value);
  return converted.empty() ? L"SakiEngine" : converted;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  // Disable thread merge to improve frame pacing on high-refresh displays.
  // Attention: This may impact plugin performance and may be incompatible with future Flutter releases.
  project.set_ui_thread_policy(flutter::UIThreadPolicy::RunOnSeparateThread);

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(ReadBundleProductName(), origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
