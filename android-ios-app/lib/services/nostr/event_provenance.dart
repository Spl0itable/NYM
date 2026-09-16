import '../../models/nostr_event.dart';

/// The raw event behind a rendered message, and which relays delivered it.
///
/// Nothing else keeps either. A message is mapped into a [Message] the moment
/// it arrives and the event is dropped, and every dedup layer in the stack
/// exists to throw away all but the first copy — which is exactly the set that
/// answers "where did this come from". So both are recorded here, and the
/// recording happens BEFORE the dedup rather than after, or this would report
/// one relay for every message in the app and look like it worked.
class EventProvenance {
  EventProvenance({this.maxEvents = 1500, this.maxRelaysPerEvent = 40});

  /// About what a person might scroll back and inspect, not about correctness.
  final int maxEvents;

  /// One event seen on more relays than this is not more informative.
  final int maxRelaysPerEvent;

  final Map<String, ProvenanceRecord> _byId = <String, ProvenanceRecord>{};

  ProvenanceRecord? of(String eventId) => _byId[eventId];

  /// Records a delivery. Called once per copy, including the copies about to
  /// be deduped away.
  void record(NostrEvent event, String? relayUrl) {
    if (event.id.length != 64) return;
    var rec = _byId.remove(event.id);
    if (rec == null) {
      if (_byId.length >= maxEvents) {
        // Insertion order is arrival order; the oldest is the least likely to
        // still be on screen.
        _byId.remove(_byId.keys.first);
      }
      rec = ProvenanceRecord(event: event, firstSeen: DateTime.now());
    }
    // Re-seated so the cap evicts by last seen rather than first.
    _byId[event.id] = rec;
    addSource(event.id, relayUrl);
  }

  /// Records a delivery that did not come off a relay socket, or adds a relay
  /// to an event already held.
  void addSource(String eventId, String? source) {
    final rec = _byId[eventId];
    if (rec == null) return;
    final label = (source == null || source.isEmpty) ? '(UNATTRIBUTED)' : source;
    if (label != '(UNATTRIBUTED)') rec.relays.remove('(UNATTRIBUTED)');
    if (rec.relays.contains(label)) return;
    if (rec.relays.length >= maxRelaysPerEvent) return;
    rec.relays.add(label);
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

/// Process-wide, like appAttestRegistry: the transports write it and the event
/// details panel reads it, and neither owns the other.
EventProvenance eventProvenance = EventProvenance();
