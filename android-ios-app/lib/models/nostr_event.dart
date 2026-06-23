import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

/// A Nostr event (NIP-01). Mirrors the plain-object events the PWA passes
/// around. Tags are `List<List<String>>`.
class NostrEvent {
  NostrEvent({
    this.id = '',
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    this.tags = const [],
    this.content = '',
    this.sig = '',
  });

  String id;
  final String pubkey;
  final int createdAt;
  final int kind;
  final List<List<String>> tags;
  final String content;
  String sig;

  /// NIP-01 serialization used for computing the event id:
  /// `[0, pubkey, created_at, kind, tags, content]` → sha256 hex.
  String computeId() {
    final serialized = jsonEncode([
      0,
      pubkey,
      createdAt,
      kind,
      tags,
      content,
    ]);
    final digest = sha256.convert(utf8.encode(serialized));
    return digest.toString();
  }

  /// First value of the first tag matching [name], or null.
  String? tagValue(String name) {
    for (final t in tags) {
      if (t.isNotEmpty && t[0] == name && t.length > 1) return t[1];
    }
    return null;
  }

  /// All tags matching [name].
  Iterable<List<String>> tagsNamed(String name) =>
      tags.where((t) => t.isNotEmpty && t[0] == name);

  Map<String, dynamic> toJson() => {
        'id': id,
        'pubkey': pubkey,
        'created_at': createdAt,
        'kind': kind,
        'tags': tags,
        'content': content,
        'sig': sig,
      };

  factory NostrEvent.fromJson(Map<String, dynamic> j) {
    return NostrEvent(
      id: (j['id'] ?? '') as String,
      pubkey: j['pubkey'] as String,
      createdAt: (j['created_at'] as num).toInt(),
      kind: (j['kind'] as num).toInt(),
      tags: ((j['tags'] as List?) ?? const [])
          .map((t) => (t as List).map((e) => e.toString()).toList())
          .toList(),
      content: (j['content'] ?? '') as String,
      sig: (j['sig'] ?? '') as String,
    );
  }

  NostrEvent copyWith({
    String? id,
    String? pubkey,
    int? createdAt,
    int? kind,
    List<List<String>>? tags,
    String? content,
    String? sig,
  }) {
    return NostrEvent(
      id: id ?? this.id,
      pubkey: pubkey ?? this.pubkey,
      createdAt: createdAt ?? this.createdAt,
      kind: kind ?? this.kind,
      tags: tags ?? this.tags,
      content: content ?? this.content,
      sig: sig ?? this.sig,
    );
  }
}

/// An unsigned event ("rumor" in NIP-59) — has an id but no signature.
class UnsignedEvent {
  UnsignedEvent({
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    this.tags = const [],
    this.content = '',
  });

  final String pubkey;
  final int createdAt;
  final int kind;
  final List<List<String>> tags;
  final String content;

  Map<String, dynamic> toJson() => {
        'pubkey': pubkey,
        'created_at': createdAt,
        'kind': kind,
        'tags': tags,
        'content': content,
      };

  String computeId() {
    final serialized = jsonEncode([0, pubkey, createdAt, kind, tags, content]);
    return sha256.convert(utf8.encode(serialized)).toString();
  }
}
