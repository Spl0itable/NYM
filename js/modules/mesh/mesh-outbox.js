// mesh-outbox.js - The sender outbox.

const MESH_OUTBOX_KEY = 'nym_mesh_outbox';

// 24 hours, the same window the mesh's own store-and-forward keeps.
const MESH_OUTBOX_TTL_MS = 24 * 60 * 60 * 1000;

// Bounded because this survives reloads.
const MESH_OUTBOX_CAP = 200;

// So a relay set that is up but rejecting can't loop forever.
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

    // Fail the local bubble so an undelivered message doesn't still look sent.
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

    // Only offline sends belong here (`_sendChannelOverMesh` checks); `#mesh` is a real kind-20000 channel.
    meshOutboxQueue(entry) {
        if (!entry || !entry.localId || !entry.target || !entry.content) return;
        if (entry.kind !== 'channel') return;
        const list = this._meshOutboxLoad();
        // One echo, one entry: a retry must not publish the same message twice.
        if (list.some(e => e.localId === entry.localId)) return;
        list.push({
            kind: entry.kind,
            target: entry.target,
            content: entry.content,
            // Original send time, so the message keeps its place in the conversation.
            createdAt: entry.createdAt || Math.floor(Date.now() / 1000),
            localId: entry.localId,
            ...(this.pubkey ? { owner: this.pubkey } : {}),
            ...(entry.threadRoot ? { threadRoot: entry.threadRoot } : {}),
            ...(entry.meshMessageId ? { meshMessageId: entry.meshMessageId } : {}),
            // Reusing the send-time event means a gateway's copy shares the id and relays dedup it.
            ...(entry.signedEvent ? { signedEvent: entry.signedEvent } : {}),
            attempts: 0,
        });
        while (list.length > MESH_OUTBOX_CAP) this._meshOutboxDropped(list.shift());
        this._meshOutboxSave();
    },

    // Oldest first; called on every relay-connected edge and after startup; re-entrant calls are ignored.
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
                if (!this._meshOutboxMine(entry)) continue;
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

    _meshOutboxMine(entry) {
        const who = (entry && typeof entry.owner === 'string' && entry.owner)
            || (entry && entry.signedEvent && typeof entry.signedEvent.pubkey === 'string' && entry.signedEvent.pubkey)
            || '';
        return !who || who === this.pubkey;
    },

    // Channels only (offline PMs are refused in `sendMessage`); the relay proxy archives it to D1.
    async _publishMeshOutboxEntry(entry) {
        if (entry.kind !== 'channel') return false;
        // Prefer the send-time event: a rebuild would re-read nym and settings that may have changed.
        if (entry.signedEvent && entry.signedEvent.sig) {
            try {
                this.sendToRelay(['EVENT', entry.signedEvent]);
                this.ensureGeoRelayDelivery(entry.signedEvent, entry.target);
                // Reconcile the pending bubble the mesh send drew.
                this._replaceOptimisticMessage(
                    entry.localId, entry.signedEvent, `#${entry.target}`, false);
                return true;
            } catch (_) {
                // Fall through and rebuild rather than lose the message.
            }
        }
        if (typeof this.publishMessage !== 'function') return false;
        // The `nymmesh` tag lets radio recipients drop the Nostr copy.
        return !!await this.publishMessage(
            entry.content, entry.target, entry.target, null, entry.threadRoot || null,
            {
                createdAt: entry.createdAt,
                localId: entry.localId,
                extraTags: entry.meshMessageId ? [['nymmesh', entry.meshMessageId]] : [],
            });
    },

});
