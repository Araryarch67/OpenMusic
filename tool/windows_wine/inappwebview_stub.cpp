// Stands in for flutter_inappwebview_windows in the Wine test build
// (tool/build_windows_wine.sh): the real plugin needs MSVC and Edge WebView2.
// Its Dart calls then fail as "not implemented", which the app shows as
// sign-in being unavailable.
#include <flutter_plugin_registrar.h>

#include "flutter_inappwebview_windows/flutter_inappwebview_windows_plugin_c_api.h"

void FlutterInappwebviewWindowsPluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef) {}
