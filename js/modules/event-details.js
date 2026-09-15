// event-details.js — the raw event behind a message, and where it came from.

(function () {
    /// Raw events are held for the panel and nothing else, so the cap is about
    /// what a person might scroll back and inspect, not about correctness.
    const MAX_EVENTS = 1500;
    /// A single event seen on more relays than this is not more informative.
    const MAX_RELAYS_PER_EVENT = 40;

    Object.assign(NYM.prototype, {

        /// Records the event and the relay it arrived on. Called once per
        /// delivery — including the deliveries that are about to be deduped
        /// away, which is the entire point.
        recordEventProvenance(event, relayUrl) {
            if (!event || typeof event.id !== 'string' || event.id.length !== 64) return;
            if (!this._eventProvenance) this._eventProvenance = new Map();
            const store = this._eventProvenance;

            let rec = store.get(event.id);
            if (!rec) {
                if (store.size >= MAX_EVENTS) {
                    // Insertion order is arrival order; the oldest is the one
                    // least likely to still be on screen.
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
                // A frame the proxy did not tag, or a mesh/backfill delivery.
                // Named rather than dropped: "we do not know" is a different
                // answer from "no relay", and the panel should not imply the
                // second when it means the first.
                rec.relays.push('(UNATTRIBUTED)');
            }
        },

        /// Records a delivery that did not come off a relay socket at all.
        recordEventProvenanceSource(event, label) {
            if (!event || typeof event.id !== 'string') return;
            this.recordEventProvenance(event, null);
            const rec = this._eventProvenance && this._eventProvenance.get(event.id);
            if (!rec) return;
            const i = rec.relays.indexOf('(UNATTRIBUTED)');
            if (i >= 0) rec.relays.splice(i, 1);
            if (!rec.relays.includes(label)) rec.relays.push(label);
        },

        /// Adds a relay to an event already recorded. The proxy reports the
        /// relays it deduped away as bare notes rather than re-sending the
        /// event, so this is the other half of that.
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

        // -------------------------------------------------------------------

        openEventDetails(eventId) {
            const modal = document.getElementById('eventDetailsModal');
            const body = document.getElementById('eventDetailsBody');
            if (!modal || !body) return;
            body.textContent = '';
            body.appendChild(this._buildEventDetails(eventId));

            // Copy lives in the modal's own footer, like every other modal in
            // the app, so the payload is handed to that button rather than to
            // one built inside the body. Nothing to copy when the event is no
            // longer held, and a button that silently copies '' is worse than
            // one that is not there.
            const copyBtn = document.getElementById('eventDetailsCopyBtn');
            if (copyBtn) {
                const rec = this.eventProvenance(eventId);
                // nm-hidden, not the hidden attribute: .icon-btn sets
                // display:inline-flex, which outranks the UA rule for [hidden]
                // and would leave the button on screen.
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

        _edRow(label, value, opts) {
            const row = document.createElement('div');
            row.className = 'event-detail-row';
            const l = document.createElement('span');
            l.className = 'event-detail-label';
            l.textContent = label;
            const v = document.createElement('span');
            v.className = 'event-detail-value' + ((opts && opts.mono) ? ' mono' : '');
            v.textContent = value;
            row.appendChild(l);
            row.appendChild(v);
            return row;
        },

        _buildEventDetails(eventId) {
            const frag = document.createDocumentFragment();
            const rec = this.eventProvenance(eventId);

            if (!rec) {
                const p = document.createElement('div');
                p.className = 'event-detail-empty';
                // Honest about why, because "no details" with no reason reads
                // as a bug.
                p.textContent = 'The raw event for this message is no longer held. '
                    + 'Events are kept for the most recent ' + MAX_EVENTS
                    + ' received this session; ones restored from the archive on '
                    + 'a later launch, and messages carried over the mesh, are not '
                    + 'in that set.';
                frag.appendChild(p);
                return frag;
            }

            const ev = rec.event;
            const json = JSON.stringify(ev, null, 2);

            const h1 = document.createElement('div');
            h1.className = 'event-detail-section';
            h1.textContent = 'Event';
            frag.appendChild(h1);

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

            // Proof of work, reported the way the filter counts it rather than
            // by leading zeros alone — the two disagree exactly when a sender
            // got lucky under a cheap commitment, which is worth being able to
            // see on a specific message.
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

            // ---- relays ----
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

            // ---- raw ----
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
