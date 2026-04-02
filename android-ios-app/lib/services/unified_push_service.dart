import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:unifiedpush/unifiedpush.dart';
import 'package:nym_bar/services/notification_service.dart';

/// UnifiedPush service for F-Droid and de-Googled devices
/// Allows users to choose their own push notification provider (ntfy, NextPush, etc.)
class UnifiedPushService {
  static final UnifiedPushService _instance = UnifiedPushService._internal();
  factory UnifiedPushService() => _instance;
  UnifiedPushService._internal();

  bool _isInitialized = false;
  String? _endpoint;
  
  /// Callback to send endpoint to PWA/server
  Function(String endpoint)? onEndpointReceived;
  
  /// Callback for incoming push messages
  Function(Map<String, dynamic> message)? onMessageReceived;

  /// Initialize UnifiedPush
  Future<void> initialize() async {
    if (_isInitialized) return;
    if (kIsWeb) {
      debugPrint('[UnifiedPush] Not supported on web');
      return;
    }

    try {
      UnifiedPush.initialize(
        onNewEndpoint: _onNewEndpoint,
        onRegistrationFailed: _onRegistrationFailed,
        onUnregistered: _onUnregistered,
        onMessage: _onMessage,
      );
      
      _isInitialized = true;
      debugPrint('[UnifiedPush] Initialized successfully');
    } catch (e) {
      debugPrint('[UnifiedPush] Initialization failed: $e');
    }
  }

  /// Register for push notifications
  /// Call this after initialization to request a push endpoint
  Future<void> register({String instance = 'default'}) async {
    if (!_isInitialized) {
      debugPrint('[UnifiedPush] Not initialized, call initialize() first');
      return;
    }

    try {
      // Check if a distributor is available
      final distributors = await UnifiedPush.getDistributors();
      
      if (distributors.isEmpty) {
        debugPrint('[UnifiedPush] No distributor available. User needs to install one (e.g., ntfy, NextPush)');
        return;
      }

      debugPrint('[UnifiedPush] Available distributors: $distributors');
      
      // Use the first available distributor or let user choose
      final distributor = distributors.first;
      await UnifiedPush.saveDistributor(distributor);
      
      // Register for push notifications
      await UnifiedPush.registerApp(instance);
      debugPrint('[UnifiedPush] Registration requested');
    } catch (e) {
      debugPrint('[UnifiedPush] Registration failed: $e');
    }
  }

  /// Unregister from push notifications
  Future<void> unregister({String instance = 'default'}) async {
    try {
      await UnifiedPush.unregister(instance);
      _endpoint = null;
      debugPrint('[UnifiedPush] Unregistered');
    } catch (e) {
      debugPrint('[UnifiedPush] Unregister failed: $e');
    }
  }

  /// Get current endpoint (if registered)
  String? get endpoint => _endpoint;

  /// Check if a distributor is available
  Future<bool> hasDistributor() async {
    if (kIsWeb) return false;
    try {
      final distributors = await UnifiedPush.getDistributors();
      return distributors.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  /// Get list of available distributors
  Future<List<String>> getDistributors() async {
    if (kIsWeb) return [];
    try {
      return await UnifiedPush.getDistributors();
    } catch (e) {
      return [];
    }
  }

  // Internal handlers - Updated for UnifiedPush 6.x API
  void _onNewEndpoint(PushEndpoint endpoint, String instance) {
    final endpointUrl = endpoint.url;
    debugPrint('[UnifiedPush] New endpoint: $endpointUrl (instance: $instance)');
    _endpoint = endpointUrl;
    
    // Notify callback if set
    onEndpointReceived?.call(endpointUrl);
  }

  void _onRegistrationFailed(FailedReason reason, String instance) {
    debugPrint('[UnifiedPush] Registration failed for instance: $instance, reason: $reason');
  }

  void _onUnregistered(String instance) {
    debugPrint('[UnifiedPush] Unregistered from instance: $instance');
    _endpoint = null;
  }

  void _onMessage(PushMessage message, String instance) {
    try {
      final messageStr = utf8.decode(message.content);
      debugPrint('[UnifiedPush] Message received: $messageStr');
      
      // Try to parse as JSON
      Map<String, dynamic> data;
      try {
        data = json.decode(messageStr) as Map<String, dynamic>;
      } catch (e) {
        // Not JSON, wrap in a simple message object
        data = {'message': messageStr};
      }
      
      // Notify callback if set
      onMessageReceived?.call(data);
      
      // Show local notification
      _showLocalNotification(data);
    } catch (e) {
      debugPrint('[UnifiedPush] Failed to process message: $e');
    }
  }

  void _showLocalNotification(Map<String, dynamic> data) {
    final title = data['title'] as String? ?? 'Nymchat';
    final body = data['body'] as String? ?? data['message'] as String? ?? '';
    final payload = data['payload'] as String? ?? data['deepLink'] as String? ?? '';
    
    NotificationService().showNotification(
      title: title,
      body: body,
      payload: payload,
    );
  }
}
