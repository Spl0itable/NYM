/// The rolling window public channel history is kept for, on this device and in
/// the cache — the Dart side of the PWA's `channelHistoryMaxAgeMs` (app.js).
///
/// It is not a storage-pressure limit (the LRU store caps and the per-channel
/// message caps are); it is the shape of the product. Kinds 20000 / 23333 and
/// the kind 7 reactions targeting them are only retrievable for 24 hours:
/// `channel-get` floors its query at `CHANNEL_TTL_MS` (functions/api/storage.js)
/// and the relay filters ask for `since: now - 86400` (relays.js /
/// nostr_service.dart). Anything older that survives locally therefore exists on
/// no other client, and cannot be re-fetched by this one after a reload — so it
/// is pruned rather than shown indefinitely on a single device.
///
/// Private conversations are NOT bounded by this: PM and group history is
/// end-to-end encrypted, restored from the user's own D1 archive, and governed
/// by the per-message TTL the sender chose.
library;

const Duration kChannelHistoryMaxAge = Duration(hours: 24);

/// The oldest `createdAt` (seconds) a public channel message may have and still
/// be kept.
int channelWindowFloorSec() =>
    DateTime.now().subtract(kChannelHistoryMaxAge).millisecondsSinceEpoch ~/
    1000;
