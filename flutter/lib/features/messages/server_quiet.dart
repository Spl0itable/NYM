class ServerQuiet {
  ServerQuiet._();

  static Set<String> keys = const <String>{};

  static bool hides(String? pubkey, String? id) {
    if (keys.isEmpty) return false;
    return (pubkey != null && keys.contains(pubkey)) ||
        (id != null && keys.contains(id));
  }
}
