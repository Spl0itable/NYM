import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:app_links/app_links.dart';
import 'package:nym_bar/services/notification_service.dart';
import 'package:nym_bar/services/fips_ble_bridge.dart';

class WebViewScreen extends StatefulWidget {
const WebViewScreen({super.key});

@override
State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
static final Uri _baseUri = Uri.parse('https://web.nymchat.app');
static final Uri _fallbackUri = Uri.parse('https://spl0itable.github.io/NYM/');
static const String _userAgentToken = 'NymchatApp/1.0';
late final WebViewController _controller;
bool _isLoading = true;
DateTime? _lastCacheCleared;
StreamSubscription<String>? _notificationSubscription;
StreamSubscription<Uri>? _appLinksSubscription;
late final AppLinks _appLinks;
Uri? _pendingDeepLink;
bool _hasTriedFallback = false;
final ImagePicker _imagePicker = ImagePicker();
String? _localNostrPubkey;

// Dynamic theme colors from PWA
Color _themeBackgroundColor = const Color(0xFF0A0A0F);
bool _isLightMode = false;

// ASCII logo loaded from asset file (protected from accidental modifications)
String _asciiLogo = '';

@override
void initState() {
  super.initState();
  _loadAsciiLogo();
  _requestLocationPermission();
  _requestCameraPermission();
  _initializeWebView();
  if (!kIsWeb) {
    _scheduleCacheClear();
    _initializeAppLinks();
  }
  _notificationSubscription = NotificationService().payloadStream.listen(_handleDeepLink);
}

Future<void> _loadAsciiLogo() async {
  try {
    final logo = await rootBundle.loadString('assets/text/nymchat_logo.txt');
    if (mounted) {
      setState(() => _asciiLogo = logo);
    }
  } catch (e) {
    debugPrint('[ASCII Logo] Failed to load: $e');
  }
}

Future<void> _initializeAppLinks() async {
_appLinks = AppLinks();

// Handle initial app link (cold start)
try {
final initialUri = await _appLinks.getInitialLink();
if (initialUri != null) {
debugPrint('[App Links] Initial link: $initialUri');
_handleAppLink(initialUri);
}
} catch (e) {
debugPrint('[App Links] Error getting initial link: $e');
}

// Handle app links while app is running (warm start)
_appLinksSubscription = _appLinks.uriLinkStream.listen(
(Uri uri) {
debugPrint('[App Links] Received link: $uri');
_handleAppLink(uri);
},
onError: (err) {
debugPrint('[App Links] Stream error: $err');
},
);
}

void _handleAppLink(Uri uri) {
String deepLinkPath;

// Convert URI to deep link path
if (uri.scheme == 'nymchat') {
// nymchat://channel/geohash or nymchat://pm/nym
deepLinkPath = uri.path.isEmpty ? '/${uri.host}${uri.path}' : uri.path;
} else if (uri.host == 'web.nymchat.app' || uri.host == 'nymchat.app') {
// https://web.nymchat.app/#geohash or https://web.nymchat.app/channel/geohash
if (uri.fragment.isNotEmpty) {
// Hash fragment URL
deepLinkPath = '#${uri.fragment}';
} else if (uri.path.isNotEmpty && uri.path != '/') {
deepLinkPath = uri.path;
} else {
// Just the base URL, go to home
deepLinkPath = '';
}
} else {
// Unknown domain, treat as potential deep link
deepLinkPath = uri.path.isNotEmpty ? uri.path : (uri.fragment.isNotEmpty ? '#${uri.fragment}' : '');
}

debugPrint('[App Links] Converted to deep link path: $deepLinkPath');

if (deepLinkPath.isNotEmpty) {
_handleDeepLink(deepLinkPath);
}
}

Future<void> _requestLocationPermission() async {
if (kIsWeb) return;
await Permission.location.request();
}

Future<void> _requestCameraPermission() async {
if (kIsWeb) return;
// Request camera and microphone permissions proactively on both iOS and Android
// to ensure they're granted before the user tries to take a photo or record video
final cameraStatus = await Permission.camera.status;
if (cameraStatus.isDenied) {
await Permission.camera.request();
}

// Also request microphone for video recording
final micStatus = await Permission.microphone.status;
if (micStatus.isDenied) {
await Permission.microphone.request();
}
}

void _initializeWebView() {
final initialPayload = NotificationService().takeInitialPayload();
final initialTarget = _resolveDeepLink(initialPayload);
final initialUri = (initialTarget != null && _isInternalUri(initialTarget)) ? initialTarget : _baseUri;

if (initialTarget != null && !_isInternalUri(initialTarget)) {
WidgetsBinding.instance.addPostFrameCallback((_) {
_launchExternalBrowser(initialTarget.toString());
});
}

// Create controller with platform-specific params
late final PlatformWebViewControllerCreationParams params;

if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
// Use WebKit-specific params for iOS/macOS
params = WebKitWebViewControllerCreationParams(
allowsInlineMediaPlayback: true,
mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
);
} else {
params = const PlatformWebViewControllerCreationParams();
}
_controller = WebViewController.fromPlatformCreationParams(params);

// Android: configure WebView for file uploads
if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
final platformController = _controller.platform;
if (platformController is AndroidWebViewController) {
// Enable mixed content (HTTPS page loading HTTP resources) for file uploads
platformController.setMediaPlaybackRequiresUserGesture(false);

// Surface JS console output to Flutter logs to aid debugging
try {
platformController.setOnConsoleMessage((message) {
debugPrint('[WebView Console][${message.level.name}] ${message.message}');
});
} catch (e) {
debugPrint('Failed to set onConsoleMessage: $e');
}
}
}

// iOS: wire up <input type="file"> support, especially for camera capture
if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
final platformController = _controller.platform;
if (platformController is WebKitWebViewController) {
// Surface JS console output to Flutter logs to aid debugging
try {
platformController.setOnConsoleMessage((message) {
debugPrint('[WebView Console][${message.level.name}] ${message.message}');
});
} catch (e) {
debugPrint('Failed to set onConsoleMessage: $e');
}
}
}

if (!kIsWeb) {
_controller.setUserAgent(_buildCustomUserAgent());
}

if (kIsWeb) {
_controller.loadRequest(initialUri);
WidgetsBinding.instance.addPostFrameCallback((_) {
if (mounted) {
setState(() => _isLoading = false);
}
});
return;
}

_controller
..setJavaScriptMode(JavaScriptMode.unrestricted)
..setNavigationDelegate(NavigationDelegate(
onPageStarted: (url) => setState(() => _isLoading = true),
onPageFinished: (url) {
setState(() => _isLoading = false);
_injectNotificationBridge();
_pendingDeepLink = null;
// Handle pending PM navigation after page load
if (_pendingPMNym != null) {
// Delay to ensure PWA is fully initialized
Future.delayed(const Duration(milliseconds: 1500), () {
if (mounted) {
_handlePendingPMNym();
}
});
}
},
onWebResourceError: (error) {
debugPrint('Web resource error: ${error.description}');

// If primary domain fails and we haven't tried fallback yet, load fallback
if (!_hasTriedFallback && (error.errorCode == -2 || error.errorCode == -6 || error.errorCode == -8)) {
debugPrint('Primary domain failed (error ${error.errorCode}), loading fallback: $_fallbackUri');
_hasTriedFallback = true;
_controller.loadRequest(
_fallbackUri,
headers: {'Cache-Control': 'max-age=14400'},
);
return;
}

if (_pendingDeepLink != null && _pendingDeepLink != _baseUri) {
debugPrint('Deep link failed, falling back to base URL');
_controller.loadRequest(
_baseUri,
headers: {'Cache-Control': 'max-age=14400'},
);
_pendingDeepLink = null;
}
},
onNavigationRequest: (request) {
final uri = Uri.parse(request.url);
debugPrint('[NYM Bridge] Navigation request: ${request.url}');
// Handle lightning: URIs for wallet integration
if (uri.scheme == 'lightning') {
debugPrint('[NYM Bridge] Lightning URI detected, launching external: ${request.url}');
_launchExternalBrowser(request.url);
return NavigationDecision.prevent;
}
// Allow web.nymchat.app and fallback domain navigation, block other external URLs
if (uri.host != 'web.nymchat.app' && uri.host != 'spl0itable.github.io') {
debugPrint('[NYM Bridge] External URL detected, launching external: ${request.url}');
_launchExternalBrowser(request.url);
return NavigationDecision.prevent;
}
return NavigationDecision.navigate;
},
))
..enableZoom(false)
..loadRequest(
initialUri,
headers: {'Cache-Control': 'max-age=14400'},
);

_controller.setBackgroundColor(const Color(0xFF0A0A0F));

_controller
..addJavaScriptChannel(
'FlutterNotification',
onMessageReceived: (message) async {
try {
final data = jsonDecode(message.message) as Map<String, dynamic>;
final title = (data['title'] as String? ?? '').trim();
final body = (data['body'] as String? ?? '').trim();
final payload = (data['payload'] as String? ?? '').trim();
if (title.isNotEmpty || body.isNotEmpty) {
await NotificationService().showNotification(
title: title.isEmpty ? 'Nymchat' : title,
body: body,
payload: payload.isEmpty ? null : payload,
);
}
} catch (e) {
try {
final parts = message.message.split('|');
if (parts.length >= 2) {
await NotificationService().showNotification(
title: parts[0],
body: parts[1],
payload: parts.length > 2 ? parts[2] : null,
);
}
} catch (innerError) {
debugPrint('Notification error: $innerError');
}
}
},
)
..addJavaScriptChannel(
'FlutterLauncher',
onMessageReceived: (message) {
debugPrint('[NYM Bridge] FlutterLauncher received: ${message.message}');
_launchExternalBrowser(message.message);
},
)
..addJavaScriptChannel(
'FlutterImagePicker',
onMessageReceived: (message) async {
debugPrint('[NYM Bridge] FlutterImagePicker received: ${message.message}');
await _handleiOSImagePicker(message.message);
},
)
..addJavaScriptChannel(
'FlutterFilePicker',
onMessageReceived: (message) async {
debugPrint('[NYM Bridge] FlutterFilePicker received: ${message.message}');
await _handleFilePicker(message.message);
},
)
..addJavaScriptChannel(
'FlutterMediaPicker',
onMessageReceived: (message) async {
debugPrint('[NYM Bridge] FlutterMediaPicker received: ${message.message}');
await _handleMediaPicker(message.message);
},
)
..addJavaScriptChannel(
'FIPSBLEBridge',
onMessageReceived: (message) async {
debugPrint('[NYM Bridge] FIPSBLEBridge received: ${message.message}');
await _handleFIPSBLEMessage(message.message);
},
)
..addJavaScriptChannel(
'FlutterTheme',
onMessageReceived: (message) {
_handleThemeChange(message.message);
},
)
..addJavaScriptChannel(
'FlutterClipboard',
onMessageReceived: (message) async {
debugPrint('[NYM Bridge] FlutterClipboard received: ${message.message}');
try {
final data = jsonDecode(message.message) as Map<String, dynamic>;
final action = data['action'] as String?;
final text = data['text'] as String?;

if (action == 'copy' && text != null) {
await Clipboard.setData(ClipboardData(text: text));
debugPrint('[NYM Bridge] Copied to clipboard: ${text.length} chars');
}
} catch (e) {
// Fallback: treat the message as plain text to copy
await Clipboard.setData(ClipboardData(text: message.message));
debugPrint('[NYM Bridge] Copied plain text to clipboard');
}
},
)
..setOnJavaScriptAlertDialog((request) async {
await _showDialog(
title: 'Alert',
message: request.message,
actions: [
TextButton(
onPressed: () => Navigator.of(context).pop(),
child: const Text('OK'),
),
],
);
})
..setOnJavaScriptConfirmDialog((request) async {
final result = await _showDialog<bool>(
title: 'Confirm',
message: request.message,
actions: [
TextButton(
onPressed: () => Navigator.of(context).pop(false),
child: const Text('Cancel'),
),
TextButton(
onPressed: () => Navigator.of(context).pop(true),
child: const Text('OK'),
),
],
);
return result ?? false;
})
..setOnJavaScriptTextInputDialog((request) async {
final controller = TextEditingController(text: request.defaultText ?? '');
final result = await _showDialog<String>(
title: 'Input',
message: request.message,
content: TextField(
controller: controller,
autofocus: true,
decoration: const InputDecoration(border: OutlineInputBorder()),
),
actions: [
TextButton(
onPressed: () => Navigator.of(context).pop(null),
child: const Text('Cancel'),
),
TextButton(
onPressed: () => Navigator.of(context).pop(controller.text),
child: const Text('OK'),
),
],
);
return result ?? '';
});
}

Future<T?> _showDialog<T>({
required String title,
required String message,
Widget? content,
required List<Widget> actions,
}) {
return showDialog<T>(
context: context,
builder: (context) => AlertDialog(
title: Text(title),
content: Column(
mainAxisSize: MainAxisSize.min,
crossAxisAlignment: CrossAxisAlignment.start,
children: [
Text(message),
if (content != null) ...[
const SizedBox(height: 16),
content,
],
],
),
actions: actions,
),
);
}

void _injectNotificationBridge() {
if (kIsWeb) {
return;
}

// Inject CSS to disable text selection (prevents long-press text highlighting)
// while still allowing clipboard operations via JavaScript
_controller.runJavaScript('''
(function() {
if (window.nymTextSelectionDisabled) return;
window.nymTextSelectionDisabled = true;

const style = document.createElement('style');
style.textContent = \`
* {
-webkit-user-select: none !important;
-moz-user-select: none !important;
-ms-user-select: none !important;
user-select: none !important;
-webkit-touch-callout: none !important;
}
input, textarea, [contenteditable="true"] {
-webkit-user-select: text !important;
-moz-user-select: text !important;
-ms-user-select: text !important;
user-select: text !important;
}
\`;
document.head.appendChild(style);
console.log('[NYM Bridge] Text selection disabled');
})();
''');

_controller.runJavaScript('''
(function() {
if (window.nymBridgeInjected) return;
window.nymBridgeInjected = true;

console.log('[NYM Bridge] Injecting Flutter bridges...');

// Fix btoa for Unicode (Android WebView can fail on non-ASCII)
try {
window.originalBtoa = window.btoa;
window.btoa = function(str) {
try {
// Try native btoa first
return window.originalBtoa(str);
} catch (e) {
// Fallback: UTF-8 encode then base64
const utf8Bytes = new TextEncoder().encode(str);
let binary = '';
utf8Bytes.forEach(byte => binary += String.fromCharCode(byte));
return window.originalBtoa(binary);
}
};
} catch (e) {
console.warn('[NYM Bridge] Failed to patch btoa', e);
}

// Disable excessive console logging to prevent memory issues
// Store original console methods
window.originalConsole = {
log: console.log,
warn: console.warn,
error: console.error,
info: console.info
};

// Replace console methods with limited buffer versions
let consoleBuffer = [];
const MAX_CONSOLE_ENTRIES = 100;

const createLimitedConsole = (originalFn, type) => {
return function(...args) {
// Keep only last MAX_CONSOLE_ENTRIES
consoleBuffer.push({ type, args, time: Date.now() });
if (consoleBuffer.length > MAX_CONSOLE_ENTRIES) {
consoleBuffer.shift();
}
// Only call original for errors and warnings
if (type === 'error' || type === 'warn') {
originalFn.apply(console, args);
}
};
};

console.log = createLimitedConsole(window.originalConsole.log, 'log');
console.info = createLimitedConsole(window.originalConsole.info, 'info');
console.warn = createLimitedConsole(window.originalConsole.warn, 'warn');
console.error = createLimitedConsole(window.originalConsole.error, 'error');

// Add method to clear console buffer if needed
window.nymClearConsole = () => {
consoleBuffer = [];
};

// Clear console buffer every 5 minutes
setInterval(() => {
consoleBuffer = [];
}, 300000);

// Store original Notification
window.originalNotification = window.Notification;

window.Notification = function(title, options) {
console.log('[NYM Bridge] Notification constructor called:', title, options);
const body = options?.body || '';
const tag = options?.tag || '';

// Store channelInfo globally for the click handler to access
const channelInfo = options?.data?.channelInfo || null;

// Build deep link payload from channelInfo if available
let payload = '';
if (channelInfo) {
if (channelInfo.type === 'pm') {
// PM notification - use nym if available, otherwise try to extract from title or use pubkey
const nym = channelInfo.nym || (title ? title.split('#')[0].replace('PM from ', '').trim() : null);
const pubkey = channelInfo.pubkey || '';
if (nym) {
payload = '/pm/' + encodeURIComponent(nym);
if (pubkey) {
payload += '?pubkey=' + pubkey;
}
} else if (pubkey) {
payload = '/pm/' + pubkey;
}
} else if (channelInfo.type === 'community' && channelInfo.communityId) {
payload = '/community/' + channelInfo.communityId;
} else if (channelInfo.type === 'geohash' && channelInfo.geohash) {
// Geohash channel - use geohash as primary identifier for deep link
payload = '/channel/' + channelInfo.geohash;
} else if (channelInfo.channel) {
payload = '/channel/' + channelInfo.channel;
}
}

const message = JSON.stringify({
title: title || '',
body: body,
payload: payload || tag || '',
channelInfo: channelInfo
});
console.log('[NYM Bridge] Sending notification to Flutter:', message);
FlutterNotification.postMessage(message);

// Return a mock notification object that implements the Notification interface
const mockNotification = {
close: function() { console.log('[NYM Bridge] Mock notification close called'); },
onclick: null,
onclose: null,
onerror: null,
onshow: null,
title: title,
body: body,
tag: tag,
data: options?.data
};

// Store the onclick handler from the PWA if provided
if (options?.onclick) {
mockNotification.onclick = options.onclick;
}

return mockNotification;
};

window.Notification.permission = "granted";
window.Notification.requestPermission = function() {
return Promise.resolve("granted");
};

// Disable Web Push in WebView to avoid Google Play Services dependency
try {
// If Permissions API is present, always resolve notifications as granted to trigger in-app fallback
if (navigator.permissions && navigator.permissions.query) {
const originalQuery = navigator.permissions.query.bind(navigator.permissions);
navigator.permissions.query = function(descriptor) {
try {
if (descriptor && (descriptor.name === 'notifications' || descriptor.name === 'push')) {
return Promise.resolve({ state: 'granted' });
}
} catch (e) {}
return originalQuery(descriptor);
}
}

// Intercept service worker ready and neutralize PushManager methods
if (navigator.serviceWorker && navigator.serviceWorker.ready) {
navigator.serviceWorker.ready.then(function(reg) {
try {
if (reg && reg.pushManager) {
const reason = new Error('Push disabled in embedded app environment');
reg.pushManager.subscribe = function() { return Promise.reject(reason); };
reg.pushManager.getSubscription = function() { return Promise.resolve(null); };
reg.pushManager.permissionState = function() { return Promise.resolve('denied'); };
}
} catch (e) { console.warn('[NYM Bridge] Failed to patch PushManager', e); }
}).catch(function(e){ console.warn('[NYM Bridge] serviceWorker.ready failed', e); });
}

// Some apps feature-detect PushManager on window; make it undefined
try { if ('PushManager' in window) { window.PushManager = undefined; } } catch (e) {}
} catch (e) {
console.warn('[NYM Bridge] Push override error', e);
}

// Create a helper for opening external URLs (including lightning URIs)
window.nymOpenExternal = function(url) {
console.log('[NYM Bridge] nymOpenExternal called with:', url);
if (window.FlutterLauncher && window.FlutterLauncher.postMessage) {
window.FlutterLauncher.postMessage(url);
return true;
} else {
console.error('[NYM Bridge] FlutterLauncher not available!');
return false;
}
};

// Create clipboard helper for copying text to system clipboard
window.nymCopyToClipboard = function(text) {
console.log('[NYM Bridge] nymCopyToClipboard called');
if (window.FlutterClipboard && window.FlutterClipboard.postMessage) {
window.FlutterClipboard.postMessage(JSON.stringify({ action: 'copy', text: text }));
return true;
} else {
console.error('[NYM Bridge] FlutterClipboard not available!');
return false;
}
};

// Override navigator.clipboard.writeText to use Flutter clipboard
if (navigator.clipboard) {
const originalWriteText = navigator.clipboard.writeText ? navigator.clipboard.writeText.bind(navigator.clipboard) : null;
navigator.clipboard.writeText = function(text) {
console.log('[NYM Bridge] navigator.clipboard.writeText intercepted');
if (window.FlutterClipboard && window.FlutterClipboard.postMessage) {
window.FlutterClipboard.postMessage(JSON.stringify({ action: 'copy', text: text }));
return Promise.resolve();
} else if (originalWriteText) {
return originalWriteText(text);
}
return Promise.resolve();
};
}

// Override document.execCommand for copy operations
const originalExecCommand = document.execCommand.bind(document);
document.execCommand = function(command, showUI, value) {
if (command === 'copy') {
console.log('[NYM Bridge] document.execCommand(copy) intercepted');
const selection = window.getSelection();
const text = selection ? selection.toString() : '';
if (text && window.FlutterClipboard && window.FlutterClipboard.postMessage) {
window.FlutterClipboard.postMessage(JSON.stringify({ action: 'copy', text: text }));
return true;
}
}
return originalExecCommand(command, showUI, value);
};

console.log('[NYM Bridge] Clipboard bridge installed');

// Intercept window.open for lightning: URIs and popup windows
window.originalOpen = window.open;
window.open = function(url, target, features) {
console.log('[NYM Bridge] window.open called with:', url, target, features);
if (url && typeof url === 'string') {
const urlLower = url.toLowerCase();
// Route lightning: URIs through Flutter
if (urlLower.startsWith('lightning:')) {
console.log('[NYM Bridge] Lightning URI detected, routing to Flutter');
const success = window.nymOpenExternal(url);
if (success) return null;
}
// Route popup windows (with features like width, height, popup) through Flutter
if (features && (features.includes('popup') || (features.includes('width') && features.includes('height')))) {
console.log('[NYM Bridge] Popup window detected, routing to default browser');
const success = window.nymOpenExternal(url);
if (success) return null;
}
}
return window.originalOpen(url, target, features);
};

console.log('[NYM Bridge] Bridges installed successfully');

// Inject CSS to fix small checkboxes, form elements, and notification positioning
const style = document.createElement('style');
style.textContent = \`
/* Make checkboxes larger and more visible */
input[type="checkbox"] {
width: 20px !important;
height: 20px !important;
min-width: 20px !important;
min-height: 20px !important;
transform: scale(1.2);
cursor: pointer;
}

/* Also fix radio buttons */
input[type="radio"] {
width: 20px !important;
height: 20px !important;
min-width: 20px !important;
min-height: 20px !important;
transform: scale(1.2);
cursor: pointer;
}

/* Fix in-app notification popup for WebView environment */
/* Account for safe area and ensure visibility */
.notification {
position: fixed !important;
top: env(safe-area-inset-top, 20px) !important;
right: 20px !important;
z-index: 99999 !important;
max-width: calc(100vw - 40px) !important;
pointer-events: auto !important;
opacity: 1 !important;
visibility: visible !important;
}

/* Ensure notification is above all WebView overlays */
.notification-title,
.notification-body,
.notification-time {
pointer-events: auto !important;
}
\`;
document.head.appendChild(style);
console.log('[NYM Bridge] Injected checkbox/radio CSS fixes and notification positioning');

// ═══════════════════════════════════════════════════════════════════════
// macOS Input Accessory Bar Fix
// When iOS app runs on macOS, the keyboard accessory bar appears as a
// phantom black bar at bottom when text fields are focused. Hide it.
// ═══════════════════════════════════════════════════════════════════════
const isiOSAppOnMac = (
navigator.platform === 'MacIntel' ||
navigator.platform === 'MacARM' ||
(navigator.userAgent.includes('Mac') && 'ontouchend' in document)
);

if (isiOSAppOnMac) {
console.log('[NYM Bridge] Detected iOS app running on macOS - applying keyboard fixes');

// The accessory bar on macOS is approximately 48-56 pixels
const ACCESSORY_BAR_HEIGHT = 56;

// Add CSS to handle the accessory bar
const macStyle = document.createElement('style');
macStyle.id = 'nym-macos-keyboard-fix';
macStyle.textContent = \`
/* Prevent any resize/jump when accessory bar appears on macOS */
html, body {
height: 100% !important;
overflow: auto !important;
}

/* When input is focused, add bottom padding to account for accessory bar */
body.nym-input-focused {
padding-bottom: \${ACCESSORY_BAR_HEIGHT}px !important;
box-sizing: border-box !important;
}

/* Smooth scrolling for auto-scroll behavior */
html {
scroll-behavior: smooth;
}
\`;
document.head.appendChild(macStyle);

// Track focus state to manage layout shifts
let focusedInput = null;
let scrollTimeout = null;

// Function to scroll focused element into view above the accessory bar
const scrollInputIntoView = (element) => {
if (!element) return;

// Clear any pending scroll
if (scrollTimeout) {
clearTimeout(scrollTimeout);
}

// Delay slightly to let the accessory bar animate in
scrollTimeout = setTimeout(() => {
const rect = element.getBoundingClientRect();
const viewportHeight = window.innerHeight;
const safeAreaBottom = ACCESSORY_BAR_HEIGHT + 20; // accessory bar + padding

// Check if the element is too close to the bottom (would be covered by accessory bar)
const elementBottom = rect.bottom;
const availableSpace = viewportHeight - safeAreaBottom;

if (elementBottom > availableSpace) {
// Need to scroll up to make room
const scrollAmount = elementBottom - availableSpace + 10; // +10 extra padding

// Find scrollable parent or use window
let scrollParent = element.closest('[style*="overflow"], [style*="scroll"]');
if (!scrollParent) {
// Try to find any scrollable container
scrollParent = document.scrollingElement || document.documentElement;
}

// Scroll the element into better position
element.scrollIntoView({
behavior: 'smooth',
block: 'center',
inline: 'nearest'
});

// Additional nudge if still covered
setTimeout(() => {
const newRect = element.getBoundingClientRect();
if (newRect.bottom > availableSpace) {
window.scrollBy({
top: newRect.bottom - availableSpace + 20,
behavior: 'smooth'
});
}
}, 150);
}
}, 100);
};

document.addEventListener('focusin', (e) => {
if (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA' || e.target.isContentEditable) {
focusedInput = e.target;
document.body.classList.add('nym-input-focused');

// Scroll the input into view above the accessory bar
scrollInputIntoView(e.target);

// On macOS, pressing Enter should blur the field (submit behavior)
// since there's no "Done" button on the accessory bar
e.target.addEventListener('keydown', function handleEnter(ke) {
if (ke.key === 'Enter' && !ke.shiftKey && e.target.tagName !== 'TEXTAREA') {
e.target.blur();
e.target.removeEventListener('keydown', handleEnter);
}
});
}
}, true);

document.addEventListener('focusout', (e) => {
if (e.target === focusedInput) {
focusedInput = null;
document.body.classList.remove('nym-input-focused');

// Clear any pending scroll
if (scrollTimeout) {
clearTimeout(scrollTimeout);
scrollTimeout = null;
}
}
}, true);

// Also handle resize events (in case accessory bar size changes)
let resizeTimeout = null;
window.addEventListener('resize', () => {
if (focusedInput) {
if (resizeTimeout) clearTimeout(resizeTimeout);
resizeTimeout = setTimeout(() => {
scrollInputIntoView(focusedInput);
}, 50);
}
});

// Attempt to hide the native input accessory via viewport manipulation
// This can help reduce the visual impact of the phantom bar
const viewportMeta = document.querySelector('meta[name="viewport"]');
if (viewportMeta) {
const currentContent = viewportMeta.content || '';
if (!currentContent.includes('interactive-widget')) {
viewportMeta.content = currentContent + ', interactive-widget=resizes-content';
}
}

console.log('[NYM Bridge] macOS keyboard fixes applied with auto-scroll');
}

// File input interception for both iOS and Android
const isMobile = /iPad|iPhone|iPod|Android/.test(navigator.userAgent);
const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent) && !window.MSStream;

if (isMobile && (window.FlutterImagePicker || window.FlutterFilePicker)) {
console.log('[NYM Bridge] Setting up mobile file input interceptor, isIOS:', isIOS);

// Track the active file input element that was clicked
window.nymActiveFileInputId = null;
// Flag to prevent double-triggering
window._nymPickerTriggered = false;

// Helper to determine if input is media (image/video) only
const isMediaOnlyInput = (input) => {
const accept = (input.accept || '').toLowerCase();
if (!accept) return false;
if (accept === '*/*') return false;
const acceptParts = accept.split(',').map(s => s.trim());
const onlyMedia = acceptParts.every(part =>
part.startsWith('image/') ||
part.startsWith('video/') ||
part === 'image/*' ||
part === 'video/*'
);
return onlyMedia;
};

// Helper to check if input accepts video
const acceptsVideo = (input) => {
const accept = (input.accept || '').toLowerCase();
return accept.includes('video/') || accept.includes('video/*');
};

// Helper to check if input is image-only (no video)
const isImageOnlyInput = (input) => {
const accept = (input.accept || '').toLowerCase();
if (!accept) return false;
const acceptParts = accept.split(',').map(s => s.trim());
const hasVideo = acceptParts.some(part =>
part.startsWith('video/') || part === 'video/*'
);
const hasImage = acceptParts.some(part =>
part.startsWith('image/') || part === 'image/*'
);
return hasImage && !hasVideo;
};

// Helper to get input type for logging
const getInputType = (input) => {
const id = input.id || '';
if (id === 'setupAvatarInput') return 'welcome-avatar';
if (id === 'setupBannerInput') return 'welcome-banner';
if (id === 'nickEditAvatarInput') return 'edit-nick-avatar';
if (id === 'nickEditBannerInput') return 'edit-nick-banner';
if (id === 'wallpaperFileInput') return 'wallpaper';
if (id === 'fileInput') return 'channel-message';
if (id === 'p2pFileInput') return 'p2p-file';
return 'unknown';
};

// Helper to trigger Flutter file picker for an input
const triggerFlutterPicker = (input, source) => {
// Prevent double-triggering within 300ms (reduced from 500ms for better responsiveness)
if (window._nymPickerTriggered) {
console.log('[NYM Bridge] Picker already triggered, skipping duplicate from:', source);
return;
}
window._nymPickerTriggered = true;
setTimeout(() => { window._nymPickerTriggered = false; }, 300);

const hasCapture = input.hasAttribute('capture');
const imageOnly = isImageOnlyInput(input);
const mediaOnly = isMediaOnlyInput(input);
const hasVideo = acceptsVideo(input);
const inputType = getInputType(input);

console.log('[NYM Bridge] Triggering Flutter picker from:', source, 'input:', input.id, 'type:', inputType, 'imageOnly:', imageOnly, 'mediaOnly:', mediaOnly, 'hasVideo:', hasVideo, 'hasCapture:', hasCapture);

if (imageOnly && window.FlutterImagePicker) {
// Image-only input - use image picker
if (hasCapture) {
console.log('[NYM Bridge] Calling FlutterImagePicker.postMessage(camera)');
window.FlutterImagePicker.postMessage('camera');
} else {
console.log('[NYM Bridge] Calling FlutterImagePicker.postMessage(choose)');
window.FlutterImagePicker.postMessage('choose');
}
} else if (hasVideo && window.FlutterMediaPicker) {
// Video or mixed media input - use media picker
if (hasCapture) {
console.log('[NYM Bridge] Calling FlutterMediaPicker.postMessage(camera)');
window.FlutterMediaPicker.postMessage('camera');
} else {
console.log('[NYM Bridge] Calling FlutterMediaPicker.postMessage(choose)');
window.FlutterMediaPicker.postMessage('choose');
}
} else if (window.FlutterFilePicker) {
// General file input - use file picker
console.log('[NYM Bridge] Calling FlutterFilePicker.postMessage');
window.FlutterFilePicker.postMessage(input.accept || '*/*');
} else if (window.FlutterImagePicker) {
console.log('[NYM Bridge] Fallback: FlutterImagePicker.postMessage(choose)');
window.FlutterImagePicker.postMessage('choose');
} else {
console.error('[NYM Bridge] No Flutter picker channel available!');
// Reset trigger flag immediately on error so user can retry
window._nymPickerTriggered = false;
}
};

// Map of button IDs to their corresponding file input IDs
const buttonToInputMap = {
'setupAvatarUploadBtn': 'setupAvatarInput',
'setupBannerUploadBtn': 'setupBannerInput',
'nickEditAvatarUploadBtn': 'nickEditAvatarInput',
'nickEditBannerUploadBtn': 'nickEditBannerInput',
'customWallpaperOption': 'wallpaperFileInput'
};

// Map of onclick function names to input IDs
const onclickToInputMap = {
'triggerSetupAvatarUpload': 'setupAvatarInput',
'triggerSetupBannerUpload': 'setupBannerInput',
'triggerNickEditAvatarUpload': 'nickEditAvatarInput',
'triggerNickEditBannerUpload': 'nickEditBannerInput',
'triggerWallpaperUpload': 'wallpaperFileInput'
};

// CRITICAL: Override HTMLInputElement.prototype.click FIRST
// This catches ALL .click() calls on file inputs
const originalClick = HTMLInputElement.prototype.click;
HTMLInputElement.prototype.click = function() {
if (this.type === 'file') {
window.nymActiveFileInputId = this.id || null;
const inputType = getInputType(this);
console.log('[NYM Bridge] HTMLInputElement.click intercepted for file input, id:', this.id, 'type:', inputType);
triggerFlutterPicker(this, 'prototype-click');
return; // Don't call original - we're handling it
}
return originalClick.apply(this, arguments);
};
console.log('[NYM Bridge] HTMLInputElement.prototype.click override installed');

// Override upload trigger functions using Object.defineProperty to make them non-writable
const createFlutterUploadTrigger = (inputId, name) => {
return function() {
console.log('[NYM Bridge] ' + name + '() called via function override');
window.nymActiveFileInputId = inputId;
const input = document.getElementById(inputId);
if (input) {
triggerFlutterPicker(input, 'fn-' + name);
} else {
console.error('[NYM Bridge] ' + name + ': input element not found:', inputId);
}
};
};

// Define trigger functions as non-configurable, non-writable properties
// This prevents the PWA from overwriting them
const defineUploadTrigger = (funcName, inputId, logName) => {
try {
Object.defineProperty(window, funcName, {
value: createFlutterUploadTrigger(inputId, logName),
writable: false,
configurable: false
});
console.log('[NYM Bridge] Defined non-writable', funcName);
} catch (e) {
// Property might already exist, try to overwrite
window[funcName] = createFlutterUploadTrigger(inputId, logName);
console.log('[NYM Bridge] Overwrote existing', funcName);
}
};

defineUploadTrigger('triggerWallpaperUpload', 'wallpaperFileInput', 'wallpaper');
defineUploadTrigger('triggerSetupAvatarUpload', 'setupAvatarInput', 'setup-avatar');
defineUploadTrigger('triggerSetupBannerUpload', 'setupBannerInput', 'setup-banner');
defineUploadTrigger('triggerNickEditAvatarUpload', 'nickEditAvatarInput', 'nick-avatar');
defineUploadTrigger('triggerNickEditBannerUpload', 'nickEditBannerInput', 'nick-banner');

// ALSO intercept buttons directly as a backup
const interceptUploadButton = (btn) => {
if (!btn || btn._nymIntercepted) return;
btn._nymIntercepted = true;

// Determine input ID from button ID or onclick
let inputId = buttonToInputMap[btn.id];
if (!inputId) {
const onclick = btn.getAttribute('onclick') || '';
for (const [funcName, inpId] of Object.entries(onclickToInputMap)) {
if (onclick.includes(funcName)) {
inputId = inpId;
break;
}
}
}
if (!inputId) return;

// Store the mapping on the element for later retrieval
btn._nymInputId = inputId;

// For buttons, add a high-priority touch/click handler
// Use touchend for mobile to fire before click
const handleInteraction = function(e) {
console.log('[NYM Bridge] Button interaction intercepted:', e.type, btn.id, '->', inputId);
e.preventDefault();
e.stopPropagation();
e.stopImmediatePropagation();

const input = document.getElementById(inputId);
if (input) {
window.nymActiveFileInputId = inputId;
triggerFlutterPicker(input, 'button-' + e.type);
} else {
console.error('[NYM Bridge] Input not found for button:', inputId);
}
return false;
};

btn.addEventListener('touchend', handleInteraction, { capture: true, passive: false });
btn.addEventListener('click', handleInteraction, { capture: true });

console.log('[NYM Bridge] Intercepted button:', btn.id || btn.className, 'inputId:', inputId);
};

// Intercept all existing upload buttons
const interceptAllUploadButtons = () => {
// By ID
Object.keys(buttonToInputMap).forEach(btnId => {
const btn = document.getElementById(btnId);
if (btn) interceptUploadButton(btn);
});

// By class (avatar-upload-btn)
document.querySelectorAll('.avatar-upload-btn').forEach(btn => {
interceptUploadButton(btn);
});

// By onclick attribute content
document.querySelectorAll('[onclick*="Avatar"], [onclick*="Wallpaper"]').forEach(btn => {
interceptUploadButton(btn);
});
};

// Run immediately
interceptAllUploadButtons();

// Use MutationObserver to catch dynamically added buttons
const observer = new MutationObserver((mutations) => {
let shouldCheck = false;
for (const mutation of mutations) {
if (mutation.addedNodes.length > 0) {
shouldCheck = true;
break;
}
}
if (shouldCheck) {
setTimeout(interceptAllUploadButtons, 50); // Small delay for DOM to settle
}
});
observer.observe(document.body, { childList: true, subtree: true });

// ALSO intercept at document level as final fallback
const documentClickHandler = function(e) {
const target = e.target;

// Direct click on file input
if (target && target.tagName === 'INPUT' && target.type === 'file') {
console.log('[NYM Bridge] Direct file input click intercepted:', target.id);
e.preventDefault();
e.stopPropagation();
window.nymActiveFileInputId = target.id || null;
triggerFlutterPicker(target, 'direct-input-click');
return false;
}

let buttonEl = target;
let inputId = null;

// Walk up DOM to find upload button
for (let i = 0; i < 5 && buttonEl; i++) {
if (buttonEl._nymInputId) {
inputId = buttonEl._nymInputId;
break;
}
if (buttonEl.id && buttonToInputMap[buttonEl.id]) {
inputId = buttonToInputMap[buttonEl.id];
break;
}
if (buttonEl.classList && buttonEl.classList.contains('avatar-upload-btn')) {
const modal = buttonEl.closest('.modal');
if (modal) {
if (modal.id === 'setupModal') inputId = 'setupAvatarInput';
else if (modal.id === 'nickEditModal') inputId = 'nickEditAvatarInput';
}
if (inputId) break;
}
const onclick = buttonEl.getAttribute && buttonEl.getAttribute('onclick');
if (onclick) {
for (const [funcName, inpId] of Object.entries(onclickToInputMap)) {
if (onclick.includes(funcName)) {
inputId = inpId;
break;
}
}
if (inputId) break;
}
buttonEl = buttonEl.parentElement;
}

if (inputId) {
console.log('[NYM Bridge] Document click handler found upload button:', inputId);
e.preventDefault();
e.stopPropagation();
e.stopImmediatePropagation();

const input = document.getElementById(inputId);
if (input) {
window.nymActiveFileInputId = inputId;
triggerFlutterPicker(input, 'doc-click');
}
return false;
}
};

document.addEventListener('click', documentClickHandler, true);
document.addEventListener('touchend', documentClickHandler, { capture: true, passive: false });

// Log diagnostic info
setTimeout(() => {
const diag = {
setupAvatarBtn: !!document.getElementById('setupAvatarUploadBtn'),
nickEditAvatarBtn: !!document.getElementById('nickEditAvatarUploadBtn'),
wallpaperBtn: !!document.getElementById('customWallpaperOption'),
setupAvatarInput: !!document.getElementById('setupAvatarInput'),
nickEditAvatarInput: !!document.getElementById('nickEditAvatarInput'),
wallpaperInput: !!document.getElementById('wallpaperFileInput'),
avatarBtnsByClass: document.querySelectorAll('.avatar-upload-btn').length,
setupModal: !!document.getElementById('setupModal'),
nickEditModal: !!document.getElementById('nickEditModal'),
fnWallpaper: typeof window.triggerWallpaperUpload,
fnSetupAvatar: typeof window.triggerSetupAvatarUpload,
fnNickAvatar: typeof window.triggerNickEditAvatarUpload
};
console.log('[NYM Bridge] Upload elements diagnostic:', JSON.stringify(diag));

// Test if our function overrides are in place
const testFn = window.triggerSetupAvatarUpload && window.triggerSetupAvatarUpload.toString();
console.log('[NYM Bridge] triggerSetupAvatarUpload source check:', testFn ? (testFn.includes('NYM Bridge') ? 'FLUTTER' : 'PWA') : 'undefined');
}, 2000);

console.log('[NYM Bridge] Mobile file input interceptor installed with enhanced interception');
}

// Periodic memory cleanup every 10 minutes
setInterval(() => {
if (window.gc) {
window.gc();
}
// Clear old cached data
consoleBuffer = [];
}, 600000);

// ═══════════════════════════════════════════════════════════════════════
// FIPS BLE Bridge - Offline Bluetooth messaging support
// ═══════════════════════════════════════════════════════════════════════

console.log('[NYM Bridge] Setting up FIPS BLE bridge...');

// Register pubkey with Flutter (call this from fips.js after generating keys)
window.fipsBLERegisterPubkey = function(pubkey) {
if (window.FIPSBLEBridge && window.FIPSBLEBridge.postMessage) {
window.FIPSBLEBridge.postMessage(JSON.stringify({
action: 'registerPubkey',
pubkey: pubkey
}));
console.log('[FIPS BLE] Pubkey registered with Flutter');
return true;
}
console.warn('[FIPS BLE] FIPSBLEBridge channel not available');
return false;
};

// Start BLE advertising (peripheral mode)
window.fipsBLEAdvertise = function() {
return new Promise((resolve, reject) => {
if (!window.FIPSBLEBridge) {
reject(new Error('FIPSBLEBridge not available'));
return;
}
window._fipsBLEResolve = resolve;
window.FIPSBLEBridge.postMessage(JSON.stringify({ action: 'advertise' }));
});
};

// Stop BLE advertising
window.fipsBLEStopAdvertise = function() {
return new Promise((resolve, reject) => {
if (!window.FIPSBLEBridge) {
reject(new Error('FIPSBLEBridge not available'));
return;
}
window._fipsBLEResolve = resolve;
window.FIPSBLEBridge.postMessage(JSON.stringify({ action: 'stopAdvertise' }));
});
};

// Start scanning for nearby FIPS nodes
window.fipsBleScan = function() {
return new Promise((resolve, reject) => {
if (!window.FIPSBLEBridge) {
reject(new Error('FIPSBLEBridge not available'));
return;
}
window._fipsBLEResolve = resolve;
window.FIPSBLEBridge.postMessage(JSON.stringify({ action: 'scan' }));
});
};

// Send encrypted message to peer via BLE
window.fipsBLESend = function(pubkey, data) {
return new Promise((resolve, reject) => {
if (!window.FIPSBLEBridge) {
reject(new Error('FIPSBLEBridge not available'));
return;
}
window._fipsBLEResolve = resolve;
window.FIPSBLEBridge.postMessage(JSON.stringify({
action: 'send',
pubkey: pubkey,
data: data
}));
});
};

// Get BLE status
window.fipsBLEGetStatus = function() {
return new Promise((resolve, reject) => {
if (!window.FIPSBLEBridge) {
reject(new Error('FIPSBLEBridge not available'));
return;
}
window._fipsBLEResolve = resolve;
window.FIPSBLEBridge.postMessage(JSON.stringify({ action: 'getStatus' }));
});
};

// Response handler from Flutter
window._fipsBLEResponse = function(response) {
if (window._fipsBLEResolve) {
window._fipsBLEResolve(response);
window._fipsBLEResolve = null;
}
};

// Callbacks that fips.js should implement:
// window._fipsBLEOnMessage(fromPubkey, encryptedData) - called when message received
// window._fipsBLEOnPeerConnected(pubkey) - called when peer connects
// window._fipsBLEOnPeerDisconnected(pubkey) - called when peer disconnects

console.log('[NYM Bridge] FIPS BLE bridge ready');

// ═══════════════════════════════════════════════════════════════════════
// Theme Color Bridge - Sync PWA theme colors to native app
// ═══════════════════════════════════════════════════════════════════════

console.log('[NYM Bridge] Setting up theme color bridge...');

// Function to extract and send current theme colors to Flutter
const sendThemeToFlutter = () => {
try {
const computed = getComputedStyle(document.body);
const isLightMode = document.body.classList.contains('light-mode');

// Get the --bg CSS variable which defines the main background color
let bgColor = computed.getPropertyValue('--bg').trim();

// Fallback: if CSS variable is empty, check body background
if (!bgColor) {
bgColor = computed.backgroundColor;
}

// Convert rgb/rgba to hex if needed
if (bgColor.startsWith('rgb')) {
const match = bgColor.match(/\\d+/g);
if (match && match.length >= 3) {
const r = parseInt(match[0]).toString(16).padStart(2, '0');
const g = parseInt(match[1]).toString(16).padStart(2, '0');
const b = parseInt(match[2]).toString(16).padStart(2, '0');
bgColor = '#' + r + g + b;
}
}

// Ensure it starts with #
if (!bgColor.startsWith('#')) {
bgColor = '#' + bgColor;
}

// Send to Flutter
if (window.FlutterTheme && window.FlutterTheme.postMessage) {
window.FlutterTheme.postMessage(JSON.stringify({
backgroundColor: bgColor,
isLightMode: isLightMode
}));
console.log('[NYM Bridge] Theme sent to Flutter:', bgColor, 'isLight:', isLightMode);
}
} catch (e) {
console.warn('[NYM Bridge] Failed to send theme to Flutter:', e);
}
};

// Send initial theme after a short delay (let CSS load)
setTimeout(sendThemeToFlutter, 100);
setTimeout(sendThemeToFlutter, 500); // Retry in case styles weren't ready

// Monitor for class changes on body (light-mode toggle)
const themeObserver = new MutationObserver((mutations) => {
for (const mutation of mutations) {
if (mutation.type === 'attributes' && mutation.attributeName === 'class') {
sendThemeToFlutter();
break;
}
}
});

themeObserver.observe(document.body, {
attributes: true,
attributeFilter: ['class']
});

// Monitor system color scheme changes
if (window.matchMedia) {
const colorSchemeQuery = window.matchMedia('(prefers-color-scheme: light)');
colorSchemeQuery.addEventListener('change', () => {
// Give the PWA time to update its styles
setTimeout(sendThemeToFlutter, 50);
});
}

// Also check periodically for theme changes (fallback for dynamically loaded styles)
setInterval(sendThemeToFlutter, 5000);

console.log('[NYM Bridge] Theme color bridge ready');

// Lightweight fetch logger for debugging Android upload issues
try {
const originalFetch = window.fetch;
window.fetch = async function(input, init) {
let url = (typeof input === 'string') ? input : (input && input.url ? input.url : '');
const isNostrUpload = url.includes('nostrmedia.com/upload');
if (isNostrUpload) {
// Log detailed request info
let authHeader = 'none';
if (init && init.headers) {
if (init.headers['Authorization']) authHeader = init.headers['Authorization'].substring(0, 30) + '...';
else if (init.headers.get && init.headers.get('Authorization')) authHeader = init.headers.get('Authorization').substring(0, 30) + '...';
}
window.originalConsole.info('[NYM Bridge] fetch upload start', {
url,
auth: authHeader,
hasBody: !!(init && init.body),
bodyType: init && init.body ? init.body.constructor.name : 'none'
});
}
try {
const resp = await originalFetch(input, init);
if (isNostrUpload) {
const clonedResp = resp.clone();
let bodyPreview = '';
try {
const text = await clonedResp.text();
bodyPreview = text.substring(0, 200);
} catch (e) {
bodyPreview = 'unable to read';
}
window.originalConsole.info('[NYM Bridge] fetch upload response', {
status: resp.status,
ok: resp.ok,
statusText: resp.statusText,
bodyPreview
});
}
return resp;
} catch (err) {
if (isNostrUpload) {
window.originalConsole.error('[NYM Bridge] fetch upload network error', {
name: err.name,
message: err.message,
stack: err.stack
});
}
throw err;
}
}
} catch (e) {
console.warn('[NYM Bridge] Failed to wrap fetch', e);
}
})();
''');
}

void _scheduleCacheClear() {
Future.doWhile(() async {
await Future.delayed(const Duration(hours: 4));
await _clearCache();
return mounted;
});
}

Future<void> _clearCache() async {
if (kIsWeb) {
return;
}
if (_lastCacheCleared != null &&
DateTime.now().difference(_lastCacheCleared!).inHours < 4) {
return;
}
await _controller.clearCache();
_lastCacheCleared = DateTime.now();
debugPrint('Cache cleared at ${_lastCacheCleared}');
}

Future<void> _launchExternalBrowser(String url) async {
final uri = Uri.parse(url);
if (await canLaunchUrl(uri)) {
await launchUrl(uri, mode: LaunchMode.externalApplication);
}
}

void _handleThemeChange(String message) {
try {
final data = jsonDecode(message) as Map<String, dynamic>;
final bgColor = data['backgroundColor'] as String?;
final isLight = data['isLightMode'] as bool? ?? false;

if (bgColor != null && bgColor.startsWith('#')) {
// Parse hex color (e.g., #0a0a0f or #f5f5f2)
final hexColor = bgColor.replaceFirst('#', '');
final colorValue = int.tryParse(hexColor, radix: 16);

if (colorValue != null) {
final newColor = Color(0xFF000000 | colorValue);

if (_themeBackgroundColor != newColor || _isLightMode != isLight) {
setState(() {
_themeBackgroundColor = newColor;
_isLightMode = isLight;
});

// Update system UI overlay style
_updateSystemUIStyle(newColor, isLight);

// Update WebView background color
_controller.setBackgroundColor(newColor);

debugPrint('[Theme] Updated to: $bgColor, isLight: $isLight');
}
}
}
} catch (e) {
debugPrint('[Theme] Error parsing theme message: $e');
}
}

void _updateSystemUIStyle(Color bgColor, bool isLight) {
final brightness = isLight ? Brightness.dark : Brightness.light;
final statusBarBrightness = isLight ? Brightness.light : Brightness.dark;

SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
statusBarColor: bgColor,
statusBarIconBrightness: brightness, // Icons color (Android)
statusBarBrightness: statusBarBrightness, // Status bar background (iOS)
systemNavigationBarColor: bgColor,
systemNavigationBarIconBrightness: brightness,
systemNavigationBarDividerColor: bgColor,
));
}

Future<void> _handleFIPSBLEMessage(String message) async {
try {
final data = jsonDecode(message) as Map<String, dynamic>;
final action = data['action'] as String?;

// If this is a pubkey registration, store it and initialize the bridge
if (action == 'registerPubkey') {
final pubkey = data['pubkey'] as String?;
if (pubkey != null && pubkey.isNotEmpty) {
_localNostrPubkey = pubkey;
debugPrint('[FIPS BLE] Registered pubkey: ${pubkey.substring(0, 16)}...');
await attachFIPSBLE(_controller, pubkey);
}
return;
}

// Forward other messages to the bridge
await handleFIPSBLEJSMessage(message);
} catch (e) {
debugPrint('[FIPS BLE] Error handling message: $e');
}
}

Future<void> _handleFilePicker(String acceptTypes) async {
try {
debugPrint('[File Picker] Opening file picker with accept: $acceptTypes');

// Use file_selector for general file picking
final List<XTypeGroup> typeGroups = [];

if (acceptTypes.isEmpty || acceptTypes == '*/*') {
// Accept all files
typeGroups.add(const XTypeGroup(label: 'All Files'));
} else {
// Parse accept types and create type groups
final accepts = acceptTypes.split(',').map((e) => e.trim()).toList();
typeGroups.add(XTypeGroup(label: 'Files', mimeTypes: accepts));
}

final XFile? selectedFile = await openFile(acceptedTypeGroups: typeGroups);

if (selectedFile == null) {
debugPrint('[File Picker] No file selected');
await _controller.runJavaScript('window.nymActiveFileInputId = null;');
return;
}

// Read file and inject into WebView
final bytes = await selectedFile.readAsBytes();
final base64Data = base64Encode(bytes);
final fileName = selectedFile.name;
final mimeType = selectedFile.mimeType ?? 'application/octet-stream';

debugPrint('[File Picker] Selected: $fileName, size: ${bytes.length}, mime: $mimeType');

final dataUrl = 'data:$mimeType;base64,$base64Data';
await _controller.runJavaScript('''
(function() {
try {
// Find the correct input: use tracked ID if available, otherwise fall back to generic query
let input = null;
const activeId = window.nymActiveFileInputId;

if (activeId) {
input = document.getElementById(activeId);
console.log('[NYM Bridge] File picker targeting input by ID:', activeId, 'found:', !!input);
}

// Fallback to first file input if ID lookup failed
if (!input) {
input = document.querySelector('input[type="file"]');
console.log('[NYM Bridge] File picker fallback to first input, found:', !!input);
}

if (!input) {
console.error('[NYM Bridge] No file input found');
window.nymActiveFileInputId = null;
return;
}

fetch('$dataUrl')
.then(res => res.blob())
.then(blob => {
const file = new File([blob], '$fileName', { type: '$mimeType' });
const dataTransfer = new DataTransfer();
dataTransfer.items.add(file);
input.files = dataTransfer.files;

const event = new Event('change', { bubbles: true });
input.dispatchEvent(event);

console.log('[NYM Bridge] File injected successfully into:', input.id || 'unnamed input', 'file:', file.name, file.size);

// Direct handler call with File object as fallback for avatar/banner inputs
// where change event may not work in WebView environments.
// The handler accepts File directly via instanceof check.
if (activeId === 'setupAvatarInput' && typeof handleSetupAvatarSelect === 'function') {
console.log('[NYM Bridge] Direct call: handleSetupAvatarSelect with File');
handleSetupAvatarSelect(file);
} else if (activeId === 'setupBannerInput' && typeof handleSetupBannerSelect === 'function') {
console.log('[NYM Bridge] Direct call: handleSetupBannerSelect with File');
handleSetupBannerSelect(file);
} else if (activeId === 'nickEditAvatarInput' && typeof handleNickEditAvatarSelect === 'function') {
console.log('[NYM Bridge] Direct call: handleNickEditAvatarSelect with File');
handleNickEditAvatarSelect(file);
} else if (activeId === 'nickEditBannerInput' && typeof handleNickEditBannerSelect === 'function') {
console.log('[NYM Bridge] Direct call: handleNickEditBannerSelect with File');
handleNickEditBannerSelect(file);
}

// Clear the active input reference
window.nymActiveFileInputId = null;
})
.catch(err => {
console.error('[NYM Bridge] File injection failed:', err);
window.nymActiveFileInputId = null;
});
} catch (e) {
console.error('[NYM Bridge] File injection error:', e);
window.nymActiveFileInputId = null;
}
})();
''');
} catch (e) {
debugPrint('[File Picker] Error: $e');
}
}

Future<void> _handleiOSImagePicker(String action) async {
try {
XFile? pickedFile;

if (action == 'camera') {
// Request camera permission first
final cameraStatus = await Permission.camera.request();
if (!cameraStatus.isGranted) {
debugPrint('[iOS Upload] Camera permission denied');
// If permanently denied, prompt user to open settings
if (cameraStatus.isPermanentlyDenied && mounted) {
final openSettings = await showDialog<bool>(
context: context,
builder: (context) => AlertDialog(
title: const Text('Camera Access Required'),
content: const Text('Please enable camera access in Settings to take photos.'),
actions: [
TextButton(
onPressed: () => Navigator.pop(context, false),
child: const Text('Cancel'),
),
TextButton(
onPressed: () => Navigator.pop(context, true),
child: const Text('Open Settings'),
),
],
),
);
if (openSettings == true) {
await openAppSettings();
}
}
return;
}
pickedFile = await _imagePicker.pickImage(
source: ImageSource.camera,
imageQuality: 85,
);
} else if (action == 'gallery') {
pickedFile = await _imagePicker.pickImage(
source: ImageSource.gallery,
imageQuality: 85,
);
} else {
// Show action sheet to choose between camera and gallery
if (!mounted) return;
final choice = await showModalBottomSheet<String>(
context: context,
builder: (context) => SafeArea(
child: Wrap(
children: [
ListTile(
leading: const Icon(Icons.camera_alt),
title: const Text('Take Photo'),
onTap: () => Navigator.pop(context, 'camera'),
),
ListTile(
leading: const Icon(Icons.photo_library),
title: const Text('Choose from Gallery'),
onTap: () => Navigator.pop(context, 'gallery'),
),
ListTile(
leading: const Icon(Icons.close),
title: const Text('Cancel'),
onTap: () => Navigator.pop(context, null),
),
],
),
),
);

if (choice == null) {
// User cancelled - notify JS and clear active input
await _controller.runJavaScript('''
window.nymImagePickerCancelled && window.nymImagePickerCancelled();
window.nymActiveFileInputId = null;
''');
return;
}

if (choice == 'camera') {
final cameraStatus = await Permission.camera.request();
if (!cameraStatus.isGranted) {
debugPrint('[iOS Upload] Camera permission denied');
// If permanently denied, prompt user to open settings
if (cameraStatus.isPermanentlyDenied && mounted) {
final openSettings = await showDialog<bool>(
context: context,
builder: (context) => AlertDialog(
title: const Text('Camera Access Required'),
content: const Text('Please enable camera access in Settings to take photos.'),
actions: [
TextButton(
onPressed: () => Navigator.pop(context, false),
child: const Text('Cancel'),
),
TextButton(
onPressed: () => Navigator.pop(context, true),
child: const Text('Open Settings'),
),
],
),
);
if (openSettings == true) {
await openAppSettings();
}
}
return;
}
pickedFile = await _imagePicker.pickImage(
source: ImageSource.camera,
imageQuality: 85,
);
} else {
pickedFile = await _imagePicker.pickImage(
source: ImageSource.gallery,
imageQuality: 85,
);
}
}

if (pickedFile == null) {
debugPrint('[iOS Upload] No image selected');
await _controller.runJavaScript('''
window.nymImagePickerCancelled && window.nymImagePickerCancelled();
window.nymActiveFileInputId = null;
''');
return;
}

// Read file and inject into WebView
final bytes = await pickedFile.readAsBytes();
final base64Data = base64Encode(bytes);
final fileName = pickedFile.name;
final mimeType = pickedFile.mimeType ?? 'image/jpeg';

debugPrint('[iOS Upload] Selected: $fileName, size: ${bytes.length}, mime: $mimeType');

final dataUrl = 'data:$mimeType;base64,$base64Data';
await _controller.runJavaScript('''
(function() {
try {
// Find the correct input: use tracked ID if available, otherwise fall back to generic query
let input = null;
const activeId = window.nymActiveFileInputId;

if (activeId) {
input = document.getElementById(activeId);
console.log('[NYM Bridge] iOS image picker targeting input by ID:', activeId, 'found:', !!input);
}

// Fallback to first file input if ID lookup failed
if (!input) {
input = document.querySelector('input[type="file"]');
console.log('[NYM Bridge] iOS image picker fallback to first input, found:', !!input);
}

if (!input) {
console.error('[NYM Bridge] No file input found');
window.nymActiveFileInputId = null;
return;
}

fetch('$dataUrl')
.then(res => res.blob())
.then(blob => {
const file = new File([blob], '$fileName', { type: '$mimeType' });
const dataTransfer = new DataTransfer();
dataTransfer.items.add(file);
input.files = dataTransfer.files;

const event = new Event('change', { bubbles: true });
input.dispatchEvent(event);

console.log('[NYM Bridge] iOS file injected successfully into:', input.id || 'unnamed input', 'file:', file.name, file.size);

// Direct handler call with File object as fallback for avatar/banner inputs
// where change event may not work in WebView environments.
// The handler accepts File directly via instanceof check.
if (activeId === 'setupAvatarInput' && typeof handleSetupAvatarSelect === 'function') {
console.log('[NYM Bridge] Direct call: handleSetupAvatarSelect with File');
handleSetupAvatarSelect(file);
} else if (activeId === 'setupBannerInput' && typeof handleSetupBannerSelect === 'function') {
console.log('[NYM Bridge] Direct call: handleSetupBannerSelect with File');
handleSetupBannerSelect(file);
} else if (activeId === 'nickEditAvatarInput' && typeof handleNickEditAvatarSelect === 'function') {
console.log('[NYM Bridge] Direct call: handleNickEditAvatarSelect with File');
handleNickEditAvatarSelect(file);
} else if (activeId === 'nickEditBannerInput' && typeof handleNickEditBannerSelect === 'function') {
console.log('[NYM Bridge] Direct call: handleNickEditBannerSelect with File');
handleNickEditBannerSelect(file);
}

// Clear the active input reference
window.nymActiveFileInputId = null;
})
.catch(err => {
console.error('[NYM Bridge] iOS file injection failed:', err);
window.nymActiveFileInputId = null;
});
} catch (e) {
console.error('[NYM Bridge] iOS file injection error:', e);
window.nymActiveFileInputId = null;
}
})();
''');
} catch (e) {
debugPrint('[iOS Upload] Error: $e');
}
}

Future<void> _handleMediaPicker(String action) async {
try {
XFile? pickedFile;

if (action == 'camera') {
// Request camera permission first
final cameraStatus = await Permission.camera.request();
if (!cameraStatus.isGranted) {
debugPrint('[Media Picker] Camera permission denied');
if (cameraStatus.isPermanentlyDenied && mounted) {
final openSettings = await showDialog<bool>(
context: context,
builder: (context) => AlertDialog(
title: const Text('Camera Access Required'),
content: const Text('Please enable camera access in Settings to record videos.'),
actions: [
TextButton(
onPressed: () => Navigator.pop(context, false),
child: const Text('Cancel'),
),
TextButton(
onPressed: () => Navigator.pop(context, true),
child: const Text('Open Settings'),
),
],
),
);
if (openSettings == true) {
await openAppSettings();
}
}
return;
}

// Show option to record photo or video
if (!mounted) return;
final recordChoice = await showModalBottomSheet<String>(
context: context,
builder: (context) => SafeArea(
child: Wrap(
children: [
ListTile(
leading: const Icon(Icons.camera_alt),
title: const Text('Take Photo'),
onTap: () => Navigator.pop(context, 'photo'),
),
ListTile(
leading: const Icon(Icons.videocam),
title: const Text('Record Video'),
onTap: () => Navigator.pop(context, 'video'),
),
ListTile(
leading: const Icon(Icons.close),
title: const Text('Cancel'),
onTap: () => Navigator.pop(context, null),
),
],
),
),
);

if (recordChoice == null) {
await _controller.runJavaScript('window.nymActiveFileInputId = null;');
return;
}

if (recordChoice == 'photo') {
pickedFile = await _imagePicker.pickImage(
source: ImageSource.camera,
imageQuality: 85,
);
} else {
// Request microphone permission for video recording
final micStatus = await Permission.microphone.request();
if (!micStatus.isGranted) {
debugPrint('[Media Picker] Microphone permission denied');
}
pickedFile = await _imagePicker.pickVideo(
source: ImageSource.camera,
maxDuration: const Duration(minutes: 10),
);
}
} else {
// Show action sheet to choose between camera and gallery
if (!mounted) return;
final choice = await showModalBottomSheet<String>(
context: context,
builder: (context) => SafeArea(
child: Wrap(
children: [
ListTile(
leading: const Icon(Icons.camera_alt),
title: const Text('Take Photo'),
onTap: () => Navigator.pop(context, 'camera_photo'),
),
ListTile(
leading: const Icon(Icons.videocam),
title: const Text('Record Video'),
onTap: () => Navigator.pop(context, 'camera_video'),
),
ListTile(
leading: const Icon(Icons.photo_library),
title: const Text('Choose Photo from Gallery'),
onTap: () => Navigator.pop(context, 'gallery_photo'),
),
ListTile(
leading: const Icon(Icons.video_library),
title: const Text('Choose Video from Gallery'),
onTap: () => Navigator.pop(context, 'gallery_video'),
),
ListTile(
leading: const Icon(Icons.close),
title: const Text('Cancel'),
onTap: () => Navigator.pop(context, null),
),
],
),
),
);

if (choice == null) {
await _controller.runJavaScript('window.nymActiveFileInputId = null;');
return;
}

if (choice == 'camera_photo') {
final cameraStatus = await Permission.camera.request();
if (!cameraStatus.isGranted) {
debugPrint('[Media Picker] Camera permission denied');
return;
}
pickedFile = await _imagePicker.pickImage(
source: ImageSource.camera,
imageQuality: 85,
);
} else if (choice == 'camera_video') {
final cameraStatus = await Permission.camera.request();
if (!cameraStatus.isGranted) {
debugPrint('[Media Picker] Camera permission denied');
return;
}
// Request microphone permission for video recording
final micStatus = await Permission.microphone.request();
if (!micStatus.isGranted) {
debugPrint('[Media Picker] Microphone permission denied');
}
pickedFile = await _imagePicker.pickVideo(
source: ImageSource.camera,
maxDuration: const Duration(minutes: 10),
);
} else if (choice == 'gallery_photo') {
pickedFile = await _imagePicker.pickImage(
source: ImageSource.gallery,
imageQuality: 85,
);
} else if (choice == 'gallery_video') {
pickedFile = await _imagePicker.pickVideo(
source: ImageSource.gallery,
);
}
}

if (pickedFile == null) {
debugPrint('[Media Picker] No media selected');
await _controller.runJavaScript('window.nymActiveFileInputId = null;');
return;
}

// Read file and inject into WebView
final bytes = await pickedFile.readAsBytes();
final base64Data = base64Encode(bytes);
final fileName = pickedFile.name;

// Determine MIME type - check file extension for videos
String mimeType = pickedFile.mimeType ?? 'application/octet-stream';
final lowerName = fileName.toLowerCase();
if (lowerName.endsWith('.mp4')) {
mimeType = 'video/mp4';
} else if (lowerName.endsWith('.mov')) {
mimeType = 'video/quicktime';
} else if (lowerName.endsWith('.avi')) {
mimeType = 'video/x-msvideo';
} else if (lowerName.endsWith('.webm')) {
mimeType = 'video/webm';
} else if (lowerName.endsWith('.jpg') || lowerName.endsWith('.jpeg')) {
mimeType = 'image/jpeg';
} else if (lowerName.endsWith('.png')) {
mimeType = 'image/png';
} else if (lowerName.endsWith('.gif')) {
mimeType = 'image/gif';
} else if (lowerName.endsWith('.heic')) {
mimeType = 'image/heic';
}

debugPrint('[Media Picker] Selected: $fileName, size: ${bytes.length}, mime: $mimeType');

final dataUrl = 'data:$mimeType;base64,$base64Data';
await _controller.runJavaScript('''
(function() {
try {
let input = null;
const activeId = window.nymActiveFileInputId;

if (activeId) {
input = document.getElementById(activeId);
console.log('[NYM Bridge] Media picker targeting input by ID:', activeId, 'found:', !!input);
}

if (!input) {
input = document.querySelector('input[type="file"]');
console.log('[NYM Bridge] Media picker fallback to first input, found:', !!input);
}

if (!input) {
console.error('[NYM Bridge] No file input found for media');
window.nymActiveFileInputId = null;
return;
}

fetch('$dataUrl')
.then(res => res.blob())
.then(blob => {
const file = new File([blob], '$fileName', { type: '$mimeType' });
const dataTransfer = new DataTransfer();
dataTransfer.items.add(file);
input.files = dataTransfer.files;

const event = new Event('change', { bubbles: true });
input.dispatchEvent(event);

console.log('[NYM Bridge] Media injected successfully:', input.id || 'unnamed input', 'file:', file.name, file.size, file.type);
window.nymActiveFileInputId = null;
})
.catch(err => {
console.error('[NYM Bridge] Media injection failed:', err);
window.nymActiveFileInputId = null;
});
} catch (e) {
console.error('[NYM Bridge] Media injection error:', e);
window.nymActiveFileInputId = null;
}
})();
''');
} catch (e) {
debugPrint('[Media Picker] Error: $e');
}
}

void _handleDeepLink(String payload) {
debugPrint('[Deep Link] Handling payload: $payload');
final target = _resolveDeepLink(payload);
if (target == null) return;

if (_isInternalUri(target)) {
_pendingDeepLink = target;
debugPrint('[Deep Link] Loading internal URI: $target');
if (kIsWeb) {
_controller.loadRequest(target);
} else {
_controller.loadRequest(
target,
headers: {'Cache-Control': 'max-age=14400'},
);
}
} else {
debugPrint('[Deep Link] Launching external: $target');
_launchExternalBrowser(target.toString());
}
}

void _handlePendingPMNym() {
if (_pendingPMNym == null && _pendingPMPubkey == null) return;

final nym = _pendingPMNym ?? '';
final pubkey = _pendingPMPubkey ?? '';
_pendingPMNym = null;
_pendingPMPubkey = null;

debugPrint('[Deep Link] Opening PM for nym: $nym, pubkey: $pubkey');

// Escape single quotes in nym for JavaScript string
final escapedNym = nym.replaceAll("'", "\\'");
final escapedPubkey = pubkey.replaceAll("'", "\\'");

// Inject JavaScript to open the PM after a delay to ensure the app is initialized
_controller.runJavaScript('''
(function() {
const targetNym = '$escapedNym';
const targetPubkey = '$escapedPubkey';

// Wait for nym object to be available
const tryOpenPM = (retryCount) => {
if (retryCount > 10) {
console.warn('[NYM Bridge] PM open timed out after 10 retries');
return;
}

if (typeof nym === 'undefined') {
// Retry after a short delay
setTimeout(() => tryOpenPM(retryCount + 1), 500);
return;
}

// Try opening by pubkey first (most reliable)
if (targetPubkey && nym.openUserPM) {
console.log('[NYM Bridge] Opening PM by pubkey from deep link:', targetPubkey);
nym.openUserPM(targetNym || 'User', targetPubkey);
return;
}

// Try opening by nym name
if (targetNym && nym.openUserPMByNym) {
console.log('[NYM Bridge] Opening PM for nym from deep link:', targetNym);
nym.openUserPMByNym(targetNym);
return;
}

// Alternative: try to find and click the PM in the list
if (targetNym) {
console.log('[NYM Bridge] Attempting to find PM for nym:', targetNym);
const pmItems = document.querySelectorAll('.pm-item');
for (const item of pmItems) {
const nymEl = item.querySelector('.pm-nym');
if (nymEl && nymEl.textContent.toLowerCase().includes(targetNym.toLowerCase())) {
item.click();
return;
}
}
}

// If pubkey available, try to find PM by pubkey
if (targetPubkey) {
const pmItems = document.querySelectorAll('.pm-item[data-pubkey]');
for (const item of pmItems) {
if (item.dataset.pubkey === targetPubkey) {
item.click();
return;
}
}
}

console.log('[NYM Bridge] PM not found, may need to start new conversation');
if (nym.displaySystemMessage) {
nym.displaySystemMessage('Could not find conversation. The user may need to message you first.');
}
};

setTimeout(() => tryOpenPM(0), 1000);
})();
''');
}

Uri? _resolveDeepLink(String? rawLink) {
if (rawLink == null || rawLink.trim().isEmpty) {
return null;
}

final trimmed = rawLink.trim();
debugPrint('[Deep Link] Resolving: $trimmed');

try {
// Handle notification payloads in path format (from PWA bridge)
// Convert /pm/nym to URL with special handling
// Convert /channel/channel/geohash or /channel/geohash to URL with hash fragment

if (trimmed.startsWith('/pm/')) {
// Private message deep link: /pm/{nym} or /pm/{nym}?pubkey={pubkey}
// Navigate to base URL and let the PWA handle opening the PM
String pmPath = trimmed.substring(4);
String? pubkey;

// Check for query parameters
if (pmPath.contains('?')) {
final queryStart = pmPath.indexOf('?');
final queryString = pmPath.substring(queryStart + 1);
pmPath = pmPath.substring(0, queryStart);

// Parse pubkey from query string
final params = Uri.splitQueryString(queryString);
pubkey = params['pubkey'];
}

// Decode URI component
final nym = Uri.decodeComponent(pmPath);
debugPrint('[Deep Link] PM deep link detected, nym: $nym, pubkey: $pubkey');

// Store nym and pubkey for post-navigation handling
_pendingPMNym = nym;
_pendingPMPubkey = pubkey;
return _baseUri;
} else if (trimmed.startsWith('/channel/')) {
// Channel deep link: /channel/{channel}/{geohash} or /channel/{geohash}
final parts = trimmed.substring(9).split('/');
String geohash;
if (parts.length >= 2) {
// /channel/channel/geohash format
geohash = parts[1].toLowerCase();
} else if (parts.isNotEmpty) {
// /channel/geohash format
geohash = parts[0].toLowerCase();
} else {
return _baseUri;
}
debugPrint('[Deep Link] Channel deep link detected, geohash: $geohash');
// Navigate to URL with hash fragment for geohash channel
return Uri.parse('${_baseUri.toString()}#$geohash');
} else if (trimmed.startsWith('/community/')) {
// Community deep link (future support)
final communityId = trimmed.substring(11);
debugPrint('[Deep Link] Community deep link detected, id: $communityId');
return _baseUri;
} else if (trimmed.startsWith('#')) {
// Hash fragment already - just append to base URL
return Uri.parse('${_baseUri.toString()}$trimmed');
}

// Check if it's a full URL
final parsed = Uri.parse(trimmed);
if (parsed.hasScheme) {
// Handle nymchat:// scheme
if (parsed.scheme == 'nymchat') {
// nymchat://channel/geohash or nymchat://pm/nym
final path = parsed.path.startsWith('/') ? parsed.path : '/${parsed.path}';
return _resolveDeepLink(path);
}
// Handle web.nymchat.app URLs with hash fragments
if ((parsed.host == 'web.nymchat.app' || parsed.host == 'nymchat.app') && parsed.fragment.isNotEmpty) {
return Uri.parse('${_baseUri.toString()}#${parsed.fragment}');
}
return parsed;
}

// Default: treat as geohash channel
if (_isValidGeohash(trimmed)) {
return Uri.parse('${_baseUri.toString()}#$trimmed');
}

return _baseUri.resolve(trimmed);
} catch (e) {
debugPrint('[Deep Link] Failed to parse deep link: $rawLink, error: $e');
return null;
}
}

// Validate geohash format (base32 characters, typically 1-12 chars)
bool _isValidGeohash(String hash) {
if (hash.isEmpty || hash.length > 12) return false;
final validChars = RegExp(r'^[0-9bcdefghjkmnpqrstuvwxyz]+$', caseSensitive: false);
return validChars.hasMatch(hash);
}

String? _pendingPMNym;
String? _pendingPMPubkey;

bool _isInternalUri(Uri uri) => uri.host == _baseUri.host;

String _buildCustomUserAgent() {
final platformFragment = switch (defaultTargetPlatform) {
TargetPlatform.android => 'Linux; Android',
TargetPlatform.iOS => 'iPhone; CPU iPhone OS',
TargetPlatform.macOS => 'Macintosh; Intel Mac OS X',
TargetPlatform.windows => 'Windows NT 10.0; Win64; x64',
TargetPlatform.linux => 'X11; Linux x86_64',
TargetPlatform.fuchsia => 'Fuchsia',
};

return 'Mozilla/5.0 ($platformFragment) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 $_userAgentToken';
}

@override
void dispose() {
_notificationSubscription?.cancel();
_appLinksSubscription?.cancel();
disposeFIPSBLE();
super.dispose();
}

@override
Widget build(BuildContext context) {
// Dynamic theme color from PWA (synced via JavaScript bridge)
final appBgColor = _themeBackgroundColor;
final mediaQuery = MediaQuery.of(context);
final topPadding = mediaQuery.padding.top;
final bottomPadding = mediaQuery.padding.bottom;

return Scaffold(
backgroundColor: appBgColor,
body: Stack(
children: [
// Top safe area fill (status bar / Dynamic Island area)
Positioned(
top: 0,
left: 0,
right: 0,
height: topPadding,
child: AnimatedContainer(
duration: const Duration(milliseconds: 200),
color: appBgColor,
),
),
// Bottom safe area fill (home indicator / navigation bar area)
Positioned(
bottom: 0,
left: 0,
right: 0,
height: bottomPadding,
child: AnimatedContainer(
duration: const Duration(milliseconds: 200),
color: appBgColor,
),
),
// Main content with SafeArea
SafeArea(
child: WebViewWidget(
controller: _controller,
gestureRecognizers: const {},
),
),
// Loading overlay
if (_isLoading)
AnimatedContainer(
duration: const Duration(milliseconds: 200),
decoration: BoxDecoration(
gradient: LinearGradient(
begin: Alignment.topCenter,
end: Alignment.bottomCenter,
colors: _isLightMode
? [
appBgColor,
const Color(0xFFE5E5E2).withValues(alpha: 0.8),
]
: [
appBgColor,
const Color(0xFF1A1A1A).withValues(alpha: 0.8),
],
),
),
child: Center(
child: Column(
mainAxisAlignment: MainAxisAlignment.center,
children: [
Image.asset(
'assets/images/NYM-favicon-circle.png',
width: 160,
height: 160,
fit: BoxFit.contain,
opacity: const AlwaysStoppedAnimation(0.95),
),
const SizedBox(height: 32),
Text(
_asciiLogo,
style: const TextStyle(
fontFamily: 'Courier New',
fontSize: 4.0,
fontWeight: FontWeight.w600,
color: Color(0xFF00FF00),
letterSpacing: 0,
height: 1.0,
shadows: [
Shadow(
color: Color(0xFF00FF00),
blurRadius: 10,
),
],
),
),
const SizedBox(height: 32),
SizedBox(
width: 40,
height: 40,
child: CircularProgressIndicator(
color: Theme.of(context).colorScheme.primary,
strokeWidth: 3,
),
),
],
),
),
),
],
),
);
}
}
