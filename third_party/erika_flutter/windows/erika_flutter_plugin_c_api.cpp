#include "include/erika_flutter/erika_flutter_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "erika_flutter_plugin.h"

void ErikaFlutterPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  erika_flutter::ErikaFlutterPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
