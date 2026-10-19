/// Linux stand-in for `flutter_inappwebview`.
///
/// The real implementation links WPE WebKit. OpenMusic only opens a WebView
/// for the YouTube Music sign-in, and that flow is mobile only, so the Linux
/// build uses this no-op instead of pulling a system WebKit into the desktop
/// app. Registering nothing leaves `InAppWebViewPlatform.instance` unset, so
/// any accidental WebView use on Linux fails loudly instead of half working.
class LinuxInAppWebViewPlatform {
  static void registerWith() {}
}
