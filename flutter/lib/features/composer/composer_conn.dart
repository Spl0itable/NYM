class ComposerConnStrings {
  const ComposerConnStrings._();

  static const String connecting =
      'Connecting… messages will send when connected';
  static const String offline =
      'Offline – messages will send when you reconnect';
  static const String mesh = 'Offline – sending over the Bluetooth mesh';
  static const String queued = 'Waiting to send';

  static Map<String, String> toJson() => {
        'connecting': connecting,
        'offline': offline,
        'mesh': mesh,
      };

  static String forState(String state) => toJson()[state] ?? '';
}

String composerConnState({
  required bool relayOpen,
  required bool meshCarries,
  required bool deviceOffline,
  required bool connectFailed,
}) {
  if (relayOpen) return '';
  if (meshCarries) return 'mesh';
  if (deviceOffline || connectFailed) return 'offline';
  return 'connecting';
}

bool _relaysEverConnected = false;

bool composerConnectFailed(int connectedRelays) {
  if (connectedRelays > 0) {
    _relaysEverConnected = true;
    return false;
  }
  return _relaysEverConnected;
}

void resetComposerConnMemoryForTest() => _relaysEverConnected = false;
