import 'webview_platform_initializer_stub.dart'
    if (dart.library.html) 'webview_platform_initializer_web.dart';

void configureWebViewPlatform() {
  configureWebViewPlatformImpl();
}