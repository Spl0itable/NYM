/// Public channel history window: only 24h can be refetched, so older copies are pruned; PMs are exempt.
library;

const Duration kChannelHistoryMaxAge = Duration(hours: 24);

/// Oldest `createdAt` (seconds) a public channel message may have and still be kept.
int channelWindowFloorSec() =>
    DateTime.now().subtract(kChannelHistoryMaxAge).millisecondsSinceEpoch ~/
    1000;
