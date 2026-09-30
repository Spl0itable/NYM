import '../../models/nostr_event.dart';

/// Raw events and the relays that delivered them, recorded before dedup discards the extra copies.
class EventProvenance {
  EventProvenance({this.maxEvents = 1500, this.maxRelaysPerEvent = 40});

  final int maxEvents;

  final int maxRelaysPerEvent;

  static const Set<int> panelKinds = {20000, 23333};

  final Map<String, ProvenanceRecord> _byId = <String, ProvenanceRecord>{};

  ProvenanceRecord? of(String eventId) => _byId[eventId];

  /// Called once per copy, including copies about to be deduped away.
  void record(NostrEvent event, String? relayUrl) {
    if (event.id.length != 64) return;
    if (!panelKinds.contains(event.kind)) return;
    var rec = _byId.remove(event.id);
    if (rec == null) {
      if (_byId.length >= maxEvents) {
        // Insertion order is arrival order, so the oldest is evicted first.
        _byId.remove(_byId.keys.first);
      }
      rec = ProvenanceRecord(event: event, firstSeen: DateTime.now());
    }
    // Re-seated so the cap evicts by last seen rather than first.
    _byId[event.id] = rec;
    addSource(event.id, relayUrl);
  }

  /// Records a non-relay delivery, or adds a relay to an event already held.
  void addSource(String eventId, String? source) {
    final rec = _byId[eventId];
    if (rec == null) return;
    final label = (source == null || source.isEmpty) ? '(UNATTRIBUTED)' : source;
    if (label != '(UNATTRIBUTED)') rec.relays.remove('(UNATTRIBUTED)');
    if (rec.relays.contains(label)) return;
    if (rec.relays.length >= maxRelaysPerEvent) return;
    rec.relays.add(label);
  }

  void recordLocal(NostrEvent event, String label) {
    record(event, null);
    addSource(event.id, label);
  }

  void clear() => _byId.clear();
  int get length => _byId.length;
}

class ProvenanceRecord {
  ProvenanceRecord({required this.event, required this.firstSeen});

  final NostrEvent event;
  final DateTime firstSeen;
  final List<String> relays = <String>[];
}

/// Process-wide: transports write it and the event details panel reads it.
EventProvenance eventProvenance = EventProvenance();
