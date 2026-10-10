(function () {
    // Raw events are held only for this panel.
    const MAX_EVENTS = 1500;
    const MAX_RELAYS_PER_EVENT = 40;
    const PANEL_KINDS = new Set([20000, 23333]);
    const ARCHIVE_MISS_RETRY_MS = 20000;
    const RELAY_LOOKUP_MS = 8000;

    Object.assign(NYM.prototype, {

        // Called once per delivery, including those about to be deduped.
        recordEventProvenance(event, relayUrl) {
            if (!event || typeof event.id !== 'string' || event.id.length !== 64) return;
            if (!PANEL_KINDS.has(event.kind)) return;
            if (!this._eventProvenance) this._eventProvenance = new Map();
            const store = this._eventProvenance;

            let rec = store.get(event.id);
            if (!rec) {
                if (store.size >= MAX_EVENTS) {
                    const oldest = store.keys().next();
                    if (!oldest.done) store.delete(oldest.value);
                }
                rec = { event, relays: [], firstSeen: Date.now() };
                store.set(event.id, rec);
            } else {
                // Re-seat so the cap evicts by last-seen rather than first.
                store.delete(event.id);
                store.set(event.id, rec);
            }

            const url = typeof relayUrl === 'string' && relayUrl.startsWith('wss://')
                ? relayUrl : null;
            if (url && !rec.relays.includes(url) && rec.relays.length < MAX_RELAYS_PER_EVENT) {
                rec.relays.push(url);
            } else if (!url && !rec.relays.includes('(UNATTRIBUTED)')
                && rec.relays.length < MAX_RELAYS_PER_EVENT) {
                // Untagged or mesh/backfill deliveries are named, since "unknown" differs from "no relay".
                rec.relays.push('(UNATTRIBUTED)');
            }
        },

        recordEventProvenanceSource(event, label) {
            if (!event || typeof event.id !== 'string') return;
            this.recordEventProvenance(event, null);
            const rec = this._eventProvenance && this._eventProvenance.get(event.id);
            if (!rec) return;
            const i = rec.relays.indexOf('(UNATTRIBUTED)');
            if (i >= 0) rec.relays.splice(i, 1);
            if (!rec.relays.includes(label)) rec.relays.push(label);
        },

        // The proxy reports deduped relays as bare notes, so they are added here.
        noteEventRelay(eventId, relayUrl) {
            if (!this._eventProvenance) return;
            const rec = this._eventProvenance.get(eventId);
            if (!rec) return;
            if (typeof relayUrl !== 'string' || !relayUrl.startsWith('wss://')) return;
            if (rec.relays.includes(relayUrl)) return;
            if (rec.relays.length >= MAX_RELAYS_PER_EVENT) return;
            rec.relays.push(relayUrl);
        },

        eventProvenance(eventId) {
            return (this._eventProvenance && this._eventProvenance.get(eventId)) || null;
        },

        openEventDetails(eventId) {
            const modal = document.getElementById('eventDetailsModal');
            const body = document.getElementById('eventDetailsBody');
            if (!modal || !body) return;
            body.textContent = '';
            body.dataset.eventId = eventId;
            body.appendChild(this._buildEventDetails(eventId));
            if (!this.eventProvenance(eventId)) {
                this._fetchArchivedEvent(eventId);
                this._fetchEventFromRelays(eventId);
            }

            // Copy lives in the modal footer; omit it when the event is no longer held.
            const copyBtn = document.getElementById('eventDetailsCopyBtn');
            if (copyBtn) {
                const rec = this.eventProvenance(eventId);
                // nm-hidden, not [hidden]: .icon-btn's display:inline-flex outranks the UA [hidden] rule.
                if (rec) {
                    copyBtn.dataset.nostrCopy = JSON.stringify(rec.event, null, 2);
                    copyBtn.classList.remove('nm-hidden');
                } else {
                    delete copyBtn.dataset.nostrCopy;
                    copyBtn.classList.add('nm-hidden');
                }
            }

            modal.classList.add('active');
            if (typeof this.closeTimestampPopup === 'function') this.closeTimestampPopup();
        },

        closeEventDetails() {
            const modal = document.getElementById('eventDetailsModal');
            if (modal) modal.classList.remove('active');
        },

        _rerenderEventDetails(eventId) {
            const rec = this.eventProvenance(eventId);
            if (!rec) return false;
            const modal = document.getElementById('eventDetailsModal');
            const body = document.getElementById('eventDetailsBody');
            if (!modal || !modal.classList.contains('active') || !body) return false;
            if (body.dataset.eventId !== eventId) return false;
            body.textContent = '';
            body.appendChild(this._buildEventDetails(eventId));
            const copyBtn = document.getElementById('eventDetailsCopyBtn');
            if (copyBtn) {
                copyBtn.dataset.nostrCopy = JSON.stringify(rec.event, null, 2);
                copyBtn.classList.remove('nm-hidden');
            }
            return true;
        },

        _fetchArchivedEvent(eventId) {
            if (typeof this._storageApiRequest !== 'function') return;
            if (!this._archivedEventMisses) this._archivedEventMisses = new Map();
            const missedAt = this._archivedEventMisses.get(eventId);
            if (missedAt && Date.now() - missedAt < ARCHIVE_MISS_RETRY_MS) return;
            this._storageApiRequest('event-get', { ids: [eventId] }, false)
                .then((res) => {
                    const ev = res && Array.isArray(res.events) ? res.events[0] : null;
                    if (!ev || ev.id !== eventId) {
                        this._archivedEventMisses.set(eventId, Date.now());
                        return;
                    }
                    this._archivedEventMisses.delete(eventId);
                    this.recordEventProvenanceSource(ev, 'NYMCHAT ARCHIVE');
                    this._rerenderEventDetails(eventId);
                })
                .catch(() => { });
        },

        _fetchEventFromRelays(eventId) {
            if (typeof this.sendToRelay !== 'function') return;
            if (!/^[0-9a-f]{64}$/.test(eventId)) return;
            if (!this._relayLookupInflight) this._relayLookupInflight = new Set();
            if (this._relayLookupInflight.has(eventId)) return;
            this._relayLookupInflight.add(eventId);
            if (!this._subscriptionHandlers) this._subscriptionHandlers = new Map();
            const subId = 'ev-' + Math.random().toString(36).slice(2, 10);
            let settled = false;
            const cleanup = () => {
                if (settled) return;
                settled = true;
                clearTimeout(timer);
                this._subscriptionHandlers.delete(subId);
                this._relayLookupInflight.delete(eventId);
                try { this.sendToRelay(['CLOSE', subId]); } catch (_) { }
            };
            const timer = setTimeout(cleanup, RELAY_LOOKUP_MS);
            this._subscriptionHandlers.set(subId, (type, data, relayUrl) => {
                if (type === 'EVENT' && data[0] === subId) {
                    const ev = data[1];
                    if (!ev || ev.id !== eventId) return;
                    const source = (typeof data[2] === 'string' && data[2].startsWith('wss://'))
                        ? data[2]
                        : (relayUrl && relayUrl !== 'relay-pool' ? relayUrl : null);
                    this.recordEventProvenance(ev, source);
                    if (!this.eventProvenance(eventId)) this.recordEventProvenanceSource(ev, 'RELAY LOOKUP');
                    this._rerenderEventDetails(eventId);
                    cleanup();
                } else if (type === 'EOSE' && data[0] === subId) {
                    cleanup();
                }
            });
            try {
                this.sendToRelay(['REQ', subId, { ids: [eventId], limit: 1 }]);
            } catch (_) {
                cleanup();
            }
        },

        _buildPartialEventDetails(eventId, frag) {
            const found = typeof this._findMessageById === 'function'
                ? this._findMessageById(eventId) : null;
            const msg = found && found.msg;

            frag.appendChild(this._edRow('ID', eventId, { mono: true }));

            if (msg) {
                if (msg.pubkey) frag.appendChild(this._edRow('Public key', msg.pubkey, { mono: true }));
                if (typeof this.neventForMessage === 'function' && msg.pubkey) {
                    const hints = typeof this._nostrRefRelayHints === 'function'
                        ? this._nostrRefRelayHints() : [];
                    const nevent = this.neventForMessage(eventId, msg.pubkey, hints);
                    if (nevent) frag.appendChild(this._edRow('nevent', nevent, { mono: true }));
                }
                if (msg.author) frag.appendChild(this._edRow('Nym', msg.author, { nym: true }));
                const ch = msg.geohash || msg.channel;
                if (ch) frag.appendChild(this._edRow('Channel', ch));
                const created = Number(msg.created_at) || 0;
                if (created) {
                    frag.appendChild(this._edRow('Created at',
                        `${created} (${new Date(created * 1000).toISOString()})`));
                }
                if (typeof this.powBitsForId === 'function') {
                    const actual = this.powBitsForId(eventId);
                    const target = Number(msg.powTarget);
                    frag.appendChild(this._edRow('Proof of work',
                        Number.isFinite(target) && target > 0
                            ? `${actual} bits, committed ${target}`
                            : `${actual} bits, no commitment`));
                }
            }

            const h2 = document.createElement('div');
            h2.className = 'event-detail-section';
            h2.textContent = 'Raw event';
            frag.appendChild(h2);
            const p = document.createElement('div');
            p.className = 'event-detail-empty';
            p.textContent = msg
                ? 'Looking for the signed event in the archive. Only what this '
                + 'client stored for display is shown above: the signature and '
                + 'tags live in the event itself, which is not kept once a '
                + 'message has been rendered.'
                : 'Nothing is held for this event id.';
            frag.appendChild(p);
            return frag;
        },

        _edRow(label, value, opts) {
            const row = document.createElement('div');
            row.className = 'event-detail-row';
            const l = document.createElement('span');
            l.className = 'event-detail-label';
            l.textContent = label;
            const v = document.createElement('span');
            v.className = 'event-detail-value' + ((opts && opts.mono) ? ' mono' : '');
            if (opts && opts.nym && window.NymSuffix) v.innerHTML = window.NymSuffix.labelHtml(value);
            else v.textContent = value;
            row.appendChild(l);
            row.appendChild(v);
            return row;
        },

        _buildEventDetails(eventId) {
            const frag = document.createDocumentFragment();
            const rec = this.eventProvenance(eventId);

            if (!rec) return this._buildPartialEventDetails(eventId, frag);

            const ev = rec.event;
            const json = JSON.stringify(ev, null, 2);

            frag.appendChild(this._edRow('ID', ev.id, { mono: true }));
            frag.appendChild(this._edRow('Public key', ev.pubkey || '', { mono: true }));
            if (typeof this.neventForMessage === 'function') {
                const hints = typeof this._nostrRefRelayHints === 'function'
                    ? this._nostrRefRelayHints() : [];
                const nevent = this.neventForMessage(ev.id, ev.pubkey || '', hints);
                if (nevent) frag.appendChild(this._edRow('nevent', nevent, { mono: true }));
            }
            frag.appendChild(this._edRow('Kind', String(ev.kind)));
            const created = Number(ev.created_at) || 0;
            frag.appendChild(this._edRow('Created at',
                `${created} (${new Date(created * 1000).toISOString()})`));
            if (Number.isFinite(ev.stored_at) && ev.stored_at > 0) {
                frag.appendChild(this._edRow('Archived at',
                    new Date(ev.stored_at).toISOString()));
            }
            frag.appendChild(this._edRow('First seen', new Date(rec.firstSeen).toISOString()));
            frag.appendChild(this._edRow('Signature', ev.sig || '', { mono: true }));
            frag.appendChild(this._edRow('Size', `${json.length} bytes, ${(ev.tags || []).length} tags`));

            // Proof of work as the filter counts it, not just leading zeros.
            if (typeof this.validatedPowBits === 'function') {
                const nonce = (ev.tags || []).find(t => Array.isArray(t) && t[0] === 'nonce');
                const target = nonce && nonce[2] ? parseInt(nonce[2], 10) : 0;
                const actual = (typeof this.powBitsForId === 'function')
                    ? this.powBitsForId(ev.id) : 0;
                const validated = this.validatedPowBits(ev);
                frag.appendChild(this._edRow('Proof of work',
                    nonce
                        ? `${actual} bits, committed ${target || '?'}, counts as ${validated}`
                        : `${actual} bits, no commitment, counts as 0`));
            }

            const badge = (ev.tags || []).find(t => Array.isArray(t) && t[0] === 'nymattest');
            if (badge && typeof this.verifyAttestBadge === 'function') {
                const tier = this.verifyAttestBadge(badge[1], ev.pubkey);
                frag.appendChild(this._edRow('App attestation',
                    tier ? tier : 'present but does not verify'));
            }

            const h2 = document.createElement('div');
            h2.className = 'event-detail-section';
            h2.textContent = `Received from ${rec.relays.length} `
                + (rec.relays.length === 1 ? 'source' : 'sources');
            frag.appendChild(h2);

            const list = document.createElement('div');
            list.className = 'event-detail-relays';
            if (rec.relays.length === 0) {
                const none = document.createElement('div');
                none.className = 'event-detail-empty';
                none.textContent = 'No source recorded.';
                list.appendChild(none);
            } else {
                for (const url of rec.relays) {
                    const item = document.createElement('div');
                    item.className = 'event-detail-relay';
                    item.textContent = url;
                    if (url === this.appRelay) {
                        const tag = document.createElement('span');
                        tag.className = 'event-detail-relay-tag';
                        tag.textContent = 'app relay';
                        item.appendChild(tag);
                    }
                    list.appendChild(item);
                }
            }
            frag.appendChild(list);

            const h3 = document.createElement('div');
            h3.className = 'event-detail-section';
            h3.textContent = 'Raw event';
            frag.appendChild(h3);

            const pre = document.createElement('pre');
            pre.className = 'event-detail-json';
            pre.textContent = json;
            frag.appendChild(pre);

            return frag;
        }
    });
})();
