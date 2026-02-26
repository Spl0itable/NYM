import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';
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
  Uri? _pendingDeepLink;
  bool _hasTriedFallback = false;
  final ImagePicker _imagePicker = ImagePicker();
  String? _localNostrPubkey;

  @override
  void initState() {
    super.initState();
    _requestLocationPermission();
    _requestCameraPermission();
    _initializeWebView();
    if (!kIsWeb) {
      _scheduleCacheClear();
    }
    _notificationSubscription = NotificationService().payloadStream.listen(_handleDeepLink);
  }

  Future<void> _requestLocationPermission() async {
    if (kIsWeb) return;
    await Permission.location.request();
  }

  Future<void> _requestCameraPermission() async {
    if (kIsWeb) return;
    // Request camera permission proactively on iOS to ensure it's granted
    // before the user tries to take a photo
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final status = await Permission.camera.status;
      if (status.isDenied) {
        await Permission.camera.request();
      }
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

    // Create controller with platform params so we can access Android-specific hooks
    final PlatformWebViewControllerCreationParams params =
        const PlatformWebViewControllerCreationParams();
    _controller = WebViewController.fromPlatformCreationParams(params);

    // Android: wire up <input type="file"> support via native picker
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

        platformController.setOnShowFileSelector((fileParams) async {
          try {
            // Map acceptTypes from the page to file_selector type groups
            final accepts = fileParams.acceptTypes;
            
            // Check if this is an image-only input
            final isImageOnly = accepts.isNotEmpty && 
                accepts.every((type) => type.startsWith('image/') || type == 'image/*' || type.startsWith('video/') || type == 'video/*');

            final groups = <XTypeGroup>[];
            
            if (accepts.isEmpty || accepts.contains('*/*')) {
              // Accept all files - don't restrict
              groups.add(const XTypeGroup(label: 'All Files'));
            } else if (isImageOnly) {
              // Image/video only
              groups.add(
                XTypeGroup(
                  label: 'Media',
                  mimeTypes: accepts,
                  extensions: const ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'mp4', 'mov', 'avi'],
                ),
              );
            } else {
              // Other specific types
              groups.add(XTypeGroup(label: 'Files', mimeTypes: accepts));
            }

            final List<XFile> selectedFiles;
            if (fileParams.mode == FileSelectorMode.openMultiple) {
              selectedFiles = await openFiles(acceptedTypeGroups: groups);
            } else {
              final file = await openFile(acceptedTypeGroups: groups);
              selectedFiles = (file != null) ? [file] : [];
            }

            if (selectedFiles.isEmpty) return <String>[];

            // Android WebView workaround: read file bytes and inject as data URL
            // so JavaScript can access the file content via FileReader
            for (final xfile in selectedFiles) {
              try {
                final bytes = await xfile.readAsBytes();
                final base64Data = base64Encode(bytes);
                final fileName = xfile.name;
                final mimeType = xfile.mimeType ?? 'application/octet-stream';
                
                debugPrint('[Android Upload] Selected: $fileName, size: ${bytes.length}, mime: $mimeType');
                
                // Inject the file into the page's <input> element as a data URL
                // This makes it accessible to JavaScript FileReader
                final dataUrl = 'data:$mimeType;base64,$base64Data';
                await _controller.runJavaScript('''
                  (function() {
                    try {
                      const input = document.querySelector('input[type="file"]');
                      if (!input) {
                        console.error('[NYM Bridge] No file input found');
                        return;
                      }
                      
                      // Fetch the data URL and create a File object
                      fetch('$dataUrl')
                        .then(res => res.blob())
                        .then(blob => {
                          const file = new File([blob], '$fileName', { type: '$mimeType' });
                          const dataTransfer = new DataTransfer();
                          dataTransfer.items.add(file);
                          input.files = dataTransfer.files;
                          
                          // Trigger change event so the PWA knows a file was selected
                          const event = new Event('change', { bubbles: true });
                          input.dispatchEvent(event);
                          
                          console.log('[NYM Bridge] File injected successfully:', file.name, file.size);
                        })
                        .catch(err => console.error('[NYM Bridge] File injection failed:', err));
                    } catch (e) {
                      console.error('[NYM Bridge] File injection error:', e);
                    }
                  })();
                ''');
              } catch (e) {
                debugPrint('[Android Upload] Failed to read file ${xfile.name}: $e');
              }
            }

            // Return empty array to WebView since we're handling files via JS injection
            return <String>[];
          } catch (e) {
            debugPrint('Android file selector error: $e');
            return <String>[];
          }
        });
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

    _controller.setBackgroundColor(const Color(0xFF0D0D0D));

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
        'FIPSBLEBridge',
        onMessageReceived: (message) async {
          debugPrint('[NYM Bridge] FIPSBLEBridge received: ${message.message}');
          await _handleFIPSBLEMessage(message.message);
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
            if (channelInfo.type === 'pm' && channelInfo.nym) {
              payload = '/pm/' + channelInfo.nym;
            } else if (channelInfo.type === 'community' && channelInfo.communityId) {
              payload = '/community/' + channelInfo.communityId;
            } else if (channelInfo.type === 'geohash' && channelInfo.channel && channelInfo.geohash) {
              payload = '/channel/' + channelInfo.channel + '/' + channelInfo.geohash;
            } else if (channelInfo.channel) {
              payload = '/channel/' + channelInfo.channel;
            }
          }
          
          const message = JSON.stringify({
            title: title || '',
            body: body,
            payload: payload || tag || ''
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
        
        // Inject CSS to fix small checkboxes and improve form elements
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
        \`;
        document.head.appendChild(style);
        console.log('[NYM Bridge] Injected checkbox/radio CSS fixes');
        
        // File input interception for both iOS and Android
        const isMobile = /iPad|iPhone|iPod|Android/.test(navigator.userAgent);
        const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent) && !window.MSStream;
        
        if (isMobile && (window.FlutterImagePicker || window.FlutterFilePicker)) {
          console.log('[NYM Bridge] Setting up mobile file input interceptor');
          
          // Helper to determine if input is image-only
          const isImageOnlyInput = (input) => {
            const accept = (input.accept || '').toLowerCase();
            // If no accept or explicitly accepts images/videos, treat as image picker
            // BUT if it accepts any file type (*/*) or doesn't restrict to image/video, use file picker
            if (!accept) return false; // No restriction = use file picker
            if (accept === '*/*') return false; // All files = use file picker
            
            // Check if ONLY images/videos are accepted
            const acceptParts = accept.split(',').map(s => s.trim());
            const onlyMedia = acceptParts.every(part => 
              part.startsWith('image/') || 
              part.startsWith('video/') || 
              part === 'image/*' || 
              part === 'video/*'
            );
            return onlyMedia;
          };
          
          // Intercept clicks on file inputs
          document.addEventListener('click', function(e) {
            const target = e.target;
            if (target && target.tagName === 'INPUT' && target.type === 'file') {
              e.preventDefault();
              e.stopPropagation();
              
              const hasCapture = target.hasAttribute('capture');
              const imageOnly = isImageOnlyInput(target);
              
              console.log('[NYM Bridge] Intercepted file input click, imageOnly:', imageOnly, 'hasCapture:', hasCapture, 'accept:', target.accept);
              
              // Store reference to the input for later
              window.nymActiveFileInput = target;
              
              if (imageOnly && window.FlutterImagePicker) {
                // Use image picker for image/video inputs
                if (hasCapture) {
                  window.FlutterImagePicker.postMessage('camera');
                } else {
                  window.FlutterImagePicker.postMessage('choose');
                }
              } else if (window.FlutterFilePicker) {
                // Use file picker for general files
                window.FlutterFilePicker.postMessage(target.accept || '*/*');
              } else if (window.FlutterImagePicker) {
                // Fallback to image picker if file picker not available
                window.FlutterImagePicker.postMessage('choose');
              }
              return false;
            }
          }, true);
          
          // Also intercept programmatic clicks
          const originalClick = HTMLInputElement.prototype.click;
          HTMLInputElement.prototype.click = function() {
            if (this.type === 'file') {
              const hasCapture = this.hasAttribute('capture');
              const imageOnly = isImageOnlyInput(this);
              
              console.log('[NYM Bridge] Intercepted programmatic file input click, imageOnly:', imageOnly);
              
              window.nymActiveFileInput = this;
              
              if (imageOnly && window.FlutterImagePicker) {
                if (hasCapture) {
                  window.FlutterImagePicker.postMessage('camera');
                } else {
                  window.FlutterImagePicker.postMessage('choose');
                }
                return;
              } else if (window.FlutterFilePicker) {
                window.FlutterFilePicker.postMessage(this.accept || '*/*');
                return;
              } else if (window.FlutterImagePicker) {
                window.FlutterImagePicker.postMessage('choose');
                return;
              }
            }
            return originalClick.apply(this, arguments);
          };
          
          console.log('[NYM Bridge] Mobile file input interceptor installed');
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
        await _controller.runJavaScript('window.nymFilePickerCancelled && window.nymFilePickerCancelled();');
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
            const input = window.nymActiveFileInput || document.querySelector('input[type="file"]');
            if (!input) {
              console.error('[NYM Bridge] No file input found');
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
                
                console.log('[NYM Bridge] File injected successfully:', file.name, file.size);
                window.nymActiveFileInput = null;
              })
              .catch(err => console.error('[NYM Bridge] File injection failed:', err));
          } catch (e) {
            console.error('[NYM Bridge] File injection error:', e);
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
          // User cancelled - notify JS
          await _controller.runJavaScript('window.nymImagePickerCancelled && window.nymImagePickerCancelled();');
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
        await _controller.runJavaScript('window.nymImagePickerCancelled && window.nymImagePickerCancelled();');
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
            const input = document.querySelector('input[type="file"]');
            if (!input) {
              console.error('[NYM Bridge] No file input found');
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
                
                console.log('[NYM Bridge] iOS file injected successfully:', file.name, file.size);
              })
              .catch(err => console.error('[NYM Bridge] iOS file injection failed:', err));
          } catch (e) {
            console.error('[NYM Bridge] iOS file injection error:', e);
          }
        })();
      ''');
    } catch (e) {
      debugPrint('[iOS Upload] Error: $e');
    }
  }

  void _handleDeepLink(String payload) {
    final target = _resolveDeepLink(payload);
    if (target == null) return;
    if (_isInternalUri(target)) {
      _pendingDeepLink = target;
      if (kIsWeb) {
        _controller.loadRequest(target);
      } else {
        _controller.loadRequest(
          target,
          headers: {'Cache-Control': 'max-age=14400'},
        );
      }
    } else {
      _launchExternalBrowser(target.toString());
    }
  }

  Uri? _resolveDeepLink(String? rawLink) {
    if (rawLink == null || rawLink.trim().isEmpty) {
      return null;
    }

    final trimmed = rawLink.trim();
    try {
      final parsed = Uri.parse(trimmed);
      if (parsed.hasScheme) {
        return parsed;
      }
      return _baseUri.resolve(trimmed);
    } catch (e) {
      debugPrint('Failed to parse deep link: $rawLink, error: $e');
      return null;
    }
  }

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
    disposeFIPSBLE();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            WebViewWidget(
              controller: _controller,
              gestureRecognizers: const {},
            ),
            if (_isLoading)
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      const Color(0xFF0D0D0D),
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
                        '''                                            ##\\                  ##\\     
                                            ## |                 ## |    
#######\\  ##\\   ##\\ ######\\####\\   #######\\ #######\\   ######\\ ######\\   
##  __##\\ ## |  ## |##  _##  _##\\ ##  _____|##  __##\\  \\____##\\\\_##  _|  
## |  ## |## |  ## |## / ## / ## |## /      ## |  ## | ####### | ## |    
## |  ## |## |  ## |## | ## | ## |## |      ## |  ## |##  __## | ## |##\\ 
## |  ## |\\####### |## | ## | ## |\\#######\\ ## |  ## |\\####### | \\####  |
\\__|  \\__| \\____## |\\__| \\__| \\__| \\_______|\\__|  \\__| \\_______|  \\____/ 
          ##\\   ## |                                                     
          \\######  |                                                     
           \\______/                                                      ''',
                        style: const TextStyle(
                          fontFamily: 'Courier New',
                          fontSize: 6,
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
      ),
    );
  }
}
