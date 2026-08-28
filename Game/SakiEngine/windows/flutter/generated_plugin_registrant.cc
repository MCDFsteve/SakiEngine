//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <erika_flutter/erika_flutter_plugin_c_api.h>
#include <flutter_avif_windows/flutter_avif_windows_plugin.h>
#include <flutter_steamworks/flutter_steamworks_plugin_c_api.h>
#include <hotkey_manager_windows/hotkey_manager_windows_plugin_c_api.h>
#include <media_kit_libs_windows_video/media_kit_libs_windows_video_plugin_c_api.h>
#include <screen_retriever_windows/screen_retriever_windows_plugin_c_api.h>
#include <window_manager/window_manager_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  ErikaFlutterPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("ErikaFlutterPluginCApi"));
  FlutterAvifWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterAvifWindowsPlugin"));
  FlutterSteamworksPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterSteamworksPluginCApi"));
  HotkeyManagerWindowsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("HotkeyManagerWindowsPluginCApi"));
  MediaKitLibsWindowsVideoPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("MediaKitLibsWindowsVideoPluginCApi"));
  ScreenRetrieverWindowsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("ScreenRetrieverWindowsPluginCApi"));
  WindowManagerPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("WindowManagerPlugin"));
}
