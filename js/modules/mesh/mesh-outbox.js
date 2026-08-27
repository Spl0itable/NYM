// mesh-outbox.js - The sender outbox.

const MESH_OUTBOX_KEY = 'nym_mesh_outbox';

// 24 hours, the same window the mesh's own store-and-forward keeps. Past it a
// message is stale enough that surfacing it would confuse rather than help.
const MESH_OUTBOX_TTL_MS = 24 * 60 * 60 * 1000;

// Most retained sends. Bounded because this survives reloads.
const MESH_OUTBOX_CAP = 200;

// Publish attempts before an entry is given up on, so a relay set that is up
// but rejecting cannot loop forever.
const MESH_OUTBOX_MAX_ATTEMPTS = 3;

Object.assign(NYM.prototype, {

    MESH_OUTBOX_TTL_MS,
    MESH_OUTBOX_CAP,
    MESH_OUTBOX_MAX_ATTEMPTS,

    // store 
    _meshOutboxLoad() {
        if (this._meshOutbox) return this._meshOutbox;
        let list = [];
        try {
            const raw = localStorage.getItem(MESH_OUTBOX_KEY);
            const parsed = raw ? JSON.parse(raw) : null;
            if (Array.isArray(parsed)) {
                // A corrupt row costs one message, never the whole queue.
                list = parsed.filter(e => e && typeof e === 'object'
                    && e.kind === 'channel'
                    && typeof e.target === 'string' && e.target
                    && typeof e.content === 'string' && e.content
                    && typeof e.createdAt === 'number'
                    && typeof e.localId === 'string' && e.localId);
            }
        } catch (_) { list = []; }
        if (list.length > MESH_OUTBOX_CAP) list = list.slice(-MESH_OUTBOX_CAP);
        this._meshOutbox = list;
        return list;
    },

    _meshOutboxSave() {
        try {
            localStorage.setItem(MESH_OUTBOX_KEY, JSON.stringify(this._meshOutbox || []));
        } catch (_) { }
    },

    // Fails the local bubble for a message that left the queue undelivered, so
    // the user is not left with something that still looks sent.
    _meshOutboxDropped(entry) {
        if (!entry || !entry.localId) return;
        if (typeof this._markOptimisticFailed !== 'function') return;
        const where = entry.target ? `#${entry.target}` : 'the mesh';
        try {
            this._markOptimisticFailed(entry.localId, `#${entry.target || ''}`, {
                message: `sent over Bluetooth to ${where}, but never reached the relays`,
            });
        } catch (_) { }
    },

    // Drops everything past the TTL. Returns whether anything went.
    _meshOutboxPrune() {
        const list = this._meshOutboxLoad();
        const cutoff = Math.floor((Date.now() - MESH_OUTBOX_TTL_MS) / 1000);
        const kept = [];
        let dropped = false;
        for (const e of list) {
            if (e.createdAt <= cutoff) { this._meshOutboxDropped(e); dropped = true; continue; }
            kept.push(e);
        }
        if (!dropped) return false;
        this._meshOutbox = kept;
        this._meshOutboxSave();
        return true;
    },

    // Retains a mesh-carried send so it reaches Nostr once relays return.
    //
    // Only a send made while OFFLINE belongs here — one made with the internet
    // up already went out both ways. `_sendChannelOverMesh` applies that test
    // before calling. `#mesh` is retained like any other channel: it is backed
    // by a real kind-20000 channel, so the Nostr copy is where it belongs.
    meshOutboxQueue(entry) {
        if (!entry || !entry.localId || !entry.target || !entry.content) return;
        if (entry.kind !== 'channel') return;
        const list = this._meshOutboxLoad();
        // One echo, one entry: a retry path calling this again must not publish
        // the same message twice.
        if (list.some(e => e.localId === entry.localId)) return;
        list.push({
            kind: entry.kind,
            target: entry.target,
            content: entry.content,
            // Replayed with the time the user actually sent, so the message
            // keeps its place in the conversation rather than jumping to the
            // bottom whenever the internet happened to come back.
            createdAt: entry.createdAt || Math.floor(Date.now() / 1000),
            localId: entry.localId,
            ...(entry.threadRoot ? { threadRoot: entry.threadRoot } : {}),
            ...(entry.meshMessageId ? { meshMessageId: entry.meshMessageId } : {}),
            // The event signed at send time, when there was one. Gateway mode
            // may already be carrying this exact event to the relays; reusing
            // it means the two copies share an id and the relays treat the
            // second as a duplicate, instead of the proof-of-work nonce alone
            // making them two different messages.
            ...(entry.signedEvent ? { signedEvent: entry.signedEvent } : {}),
            attempts: 0,
        });
        while (list.length > MESH_OUTBOX_CAP) this._meshOutboxDropped(list.shift());
        this._meshOutboxSave();
    },

    // Publishes everything the queue still holds, oldest first.
    //
    // Called on every relay-connected edge and once after startup, which
    // between them cover both ways the internet comes back: regaining signal
    // mid-session, and loading online after a session that queued while
    // offline. Re-entrant calls are ignored — a flush already running will
    // publish anything a second call would have.
    async flushMeshOutbox() {
        if (this._meshOutboxFlushing) return;
        this._meshOutboxPrune();
        const list = this._meshOutboxLoad();
        if (!list.length) return;
        if (!this.connected) return;
        this._meshOutboxFlushing = true;
        try {
            // Snapshot: publishing mutates the live array.
            for (const entry of list.slice()) {
                if (!this._meshOutbox.includes(entry)) continue;
                let sent = false;
                try {
                    sent = await this._publishMeshOutboxEntry(entry);
                } catch (_) { sent = false; }
                if (sent) {
                    this._meshOutbox = this._meshOutbox.filter(e => e !== entry);
                } else {
                    entry.attempts = (entry.attempts || 0) + 1;
                    if (entry.attempts >= MESH_OUTBOX_MAX_ATTEMPTS) {
                        this._meshOutbox = this._meshOutbox.filter(e => e !== entry);
                        this._meshOutboxDropped(entry);
                    }
                }
            }
        } finally {
            this._meshOutboxFlushing = false;
            this._meshOutboxSave();
        }
    },

    // Publishes one retained send. Returns whether it went out.
    //
    // Only channels: the composer never routes a PM over the radio here (an
    // offline PM is refused outright, `sendMessage`), so a channel message is
    // the only thing the mesh carries that Nostr can still deliver later. The
    // published event lands in D1 the same way any other channel message does —
    // the relay proxy that carries the broadcast is what archives it — so the
    // replay restores the message for late readers, not just live ones.
    async _publishMeshOutboxEntry(entry) {
        if (entry.kind !== 'channel') return false;
        // Prefer the event signed at send time. Beyond matching whatever a
        // gateway already published, it is what the user actually wrote: a
        // rebuild would re-read the current nym and settings, which may have
        // changed in the hours this sat queued.
        if (entry.signedEvent && entry.signedEvent.sig) {
            try {
                this.sendToRelay(['EVENT', entry.signedEvent]);
                this.ensureGeoRelayDelivery(entry.signedEvent, entry.target);
                // Reconcile the bubble the mesh send drew, so it stops looking
                // pending — publishMessage does this for the rebuilt path.
                this._replaceOptimisticMessage(
                    entry.localId, entry.signedEvent, `#${entry.target}`, false);
                return true;
            } catch (_) {
                // Fall through and rebuild rather than lose the message.
            }
        }
        if (typeof this.publishMessage !== 'function') return false;
        // The `nymmesh` tag lets a peer who already received this over the radio
        // drop the Nostr copy instead of showing it twice.
        return !!await this.publishMessage(
            entry.content, entry.target, entry.target, null, entry.threadRoot || null,
            {
                createdAt: entry.createdAt,
                localId: entry.localId,
                extraTags: entry.meshMessageId ? [['nymmesh', entry.meshMessageId]] : [],
            });
    },

});
