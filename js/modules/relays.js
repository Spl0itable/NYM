// relays.js - Relay pool, connection lifecycle, proxy worker, geo-relays, stats, retries

const EDGE_CHALLENGE_RELOAD_MIN_MS = 60000;
const EDGE_CHALLENGE_RELOAD_WINDOW_MS = 15 * 60 * 1000;
const EDGE_CHALLENGE_RELOAD_MAX = 3;
const EDGE_CHALLENGE_CONFIRM_MS = 1500;
const EDGE_CHALLENGE_NOTE_MIN_MS = 30000;
const HELD_EVENTS_MAX = 16;
const HELD_EVENTS_MS = 20000;
const HELD_SENDS_MAX = 200;
const COMPOSER_CONN_TEXT = {
    connecting: 'Connecting… messages will send when connected',
    offline: 'Offline – messages will send when you reconnect',
    mesh: 'Offline – sending over the Bluetooth mesh'
};
const COMPOSER_QUEUED_LABEL = 'Waiting to send';
const CONN_NOTICE_GRACE_MS = 2000;
const CONN_STATUS_OFFLINE = /Failed|Disconnected/;
const POOL_QUIET_MS = 60000;
const POOL_PROBE_TIMEOUT_MS = 10000;
const POOL_RESUME_FRESH_MS = 5000;
const POOL_PROBE_BACKOFF_MAX_MS = 10 * 60 * 1000;
const POOL_CONNECT_TIMEOUT_MS = 12000;

Object.assign(NYM.prototype, {

    // localStorage key for the persisted geo-relay directory.
    _GEO_RELAY_CACHE_KEY: 'nym_geo_relays',
    // 24h, matching bitchat iOS (geoRelayFetchIntervalSeconds) and Android (ONE_DAY_MS).
    _GEO_RELAY_TTL_MS: 24 * 60 * 60 * 1000,

    // Null when absent or unusable, never when merely stale, so a failed refresh can fall back to it.
    _loadGeoRelayCache() {
        try {
            const raw = localStorage.getItem(this._GEO_RELAY_CACHE_KEY);
            if (!raw) return null;
            const data = JSON.parse(raw);
            if (!data || !Array.isArray(data.relays) || !data.relays.length) return null;
            const ok = (arr) => (Array.isArray(arr) ? arr : []).filter(r =>
                r && typeof r.url === 'string' && Number.isFinite(r.lat) && Number.isFinite(r.lng));
            const relays = ok(data.relays);
            if (!relays.length) return null;
            return { fetchedAt: Number(data.fetchedAt) || 0, relays, vetted: ok(data.vetted) };
        } catch (_) {
            return null;
        }
    },

    _saveGeoRelayCache(relays, vetted) {
        const slim = (list) => (list || []).map(r => ({ url: r.url, lat: r.lat, lng: r.lng }));
        try {
            localStorage.setItem(this._GEO_RELAY_CACHE_KEY, JSON.stringify({
                fetchedAt: Date.now(),
                relays: slim(relays),
                vetted: slim(vetted),
            }));
        } catch (_) { /* Quota or private mode; the in-memory list still works. */ }
    },

    // Same CSV as bitchat; a cache within _GEO_RELAY_TTL_MS skips the network unless { force: true }.
    fetchGeoRelays(opts = {}) {
        const directCsvUrl = 'https://raw.githubusercontent.com/permissionlesstech/georelays/refs/heads/main/nostr_relays.csv';
        const base = this._getProxyBaseUrl();

        const vettedCsvUrl = 'https://raw.githubusercontent.com/permissionlesstech/bitchat/refs/heads/main/relays/online_relays_gps.csv';

        const cached = this._loadGeoRelayCache();
        if (cached) {
            // Adopt the cache immediately so geohash channels work while a refresh is in flight.
            this._adoptGeoRelays(cached.relays, cached.vetted, { persist: false });
            const age = Date.now() - cached.fetchedAt;
            if (!opts.force && age >= 0 && age < this._GEO_RELAY_TTL_MS) {
                return Promise.resolve();
            }
        }

        const clean = (arr) => Array.isArray(arr)
            ? arr.filter(r => r && r.url && Number.isFinite(r.lat) && Number.isFinite(r.lng))
            : [];

        const tryProxyJson = async () => {
            if (!base) return null;
            try {
                const res = await this._edgeFetch(`${base}?action=geo-relays`);
                if (!res.ok) return null;
                const data = await res.json();
                if (!data || !Array.isArray(data.relays)) return null;
                return { relays: clean(data.relays), vetted: clean(data.vetted) };
            } catch {
                return null;
            }
        };

        const fetchCsv = async (url) => {
            const res = await fetch(url, { cache: 'no-cache' });
            if (!res.ok) throw new Error(`HTTP ${res.status}`);
            return this._parseGeoRelaysCsv(await res.text());
        };

        return (async () => {
            let got = await tryProxyJson();
            if (!got || got.relays.length === 0) {
                // The vetted list is best-effort; without it we still match bitchat Android.
                const [relays, vetted] = await Promise.all([
                    fetchCsv(directCsvUrl),
                    fetchCsv(vettedCsvUrl).catch(() => []),
                ]);
                got = { relays, vetted };
            }
            if (got && got.relays.length > 0) {
                this._adoptGeoRelays(got.relays, got.vetted, { persist: true });
            }
        })().catch((err) => {
            // Any cached directory was already adopted above, so a failed refresh keeps what we had.
            console.warn(`[GeoRelays] CSV fetch failed (${this.geoRelays.length} geo relays):`, err.message);
        });
    },

    // `geoRelays` stays the union; the two lists stay apart so selection applies each client's own rule.
    _adoptGeoRelays(relays, vetted, { persist }) {
        const canon = (list) => (list || []).map(r => ({ ...r, url: this._canonicalRelayUrl(r.url) }));
        this._geoRelaysUpstream = canon(relays);
        this._geoRelaysVetted = canon(vetted);

        const byUrl = new Map();
        for (const r of this._geoRelaysUpstream) byUrl.set(r.url, r);
        for (const r of this._geoRelaysVetted) if (!byUrl.has(r.url)) byUrl.set(r.url, r);
        this.geoRelays = [...byUrl.values()];
        // Defensive: this can run from the constructor before allRelayUrls is seeded (see app.js).
        if (!this.allRelayUrls) this.allRelayUrls = new Set(this.defaultRelays || []);
        for (const r of this.geoRelays) this.allRelayUrls.add(r.url);

        if (persist) this._saveGeoRelayCache(this._geoRelaysUpstream, this._geoRelaysVetted);
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            this._poolSendRelayConfig();
        }
    },

    _parseGeoRelaysCsv(csv) {
        const parsed = [];
        const lines = csv.split('\n');
        for (let i = 0; i < lines.length; i++) {
            const line = lines[i].trim();
            if (!line) continue;
            if (i === 0 && line.toLowerCase().includes('relay url')) continue;
            const parts = line.split(',');
            if (parts.length < 3) continue;
            const host = parts[0].trim()
                .replace('https://', '').replace('http://', '')
                .replace('wss://', '').replace('ws://', '')
                .replace(/\/+$/, '');
            const lat = parseFloat(parts[1]);
            const lng = parseFloat(parts[2]);
            if (!host || isNaN(lat) || isNaN(lng)) continue;
            parsed.push({ url: `wss://${host}`, lat, lng });
        }
        return parsed;
    },

    // The union of what each bitchat client (iOS and Android) would pick.
    getClosestRelaysForGeohash(geohash, count = this.geoRelayCount) {
        try {
            const coords = this.decodeGeohash(geohash);
            if (!coords || typeof coords.lat !== 'number' || typeof coords.lng !== 'number') {
                return [];
            }

            const rank = (list) => list.map((relay, index) => ({
                url: relay.url,
                index,
                distance: this.calculateDistance(coords.lat, coords.lng, relay.lat, relay.lng),
            }));

            // Android's rule: distance only; the stable sort keeps directory order on ties like Kotlin's sortedBy.
            const upstream = rank(this._geoRelaysUpstream || this.geoRelays || []);
            upstream.sort((a, b) => (a.distance - b.distance) || (a.index - b.index));

            // iOS's rule: (distance, host) ascending.
            const vetted = rank(this._geoRelaysVetted || []);
            vetted.sort((a, b) => (a.distance - b.distance) || (a.url < b.url ? -1 : a.url > b.url ? 1 : 0));

            const out = [];
            const seen = new Set();
            for (const r of [...upstream.slice(0, count), ...vetted.slice(0, count)]) {
                if (seen.has(r.url)) continue;
                seen.add(r.url);
                out.push({ url: r.url, distance: r.distance });
            }
            // Closest-first overall, so callers taking a prefix still get the nearest relays.
            out.sort((a, b) => a.distance - b.distance);
            return out;
        } catch (error) {
            return [];
        }
    },

    // Ensure an event reaches the geo relays for a given geohash channel.
    // Only kind 20000 channel messages use geo relays; other kinds stay on
    // the default relays.
    ensureGeoRelayDelivery(signedEvent, geohash) {
        if (!geohash) return;
        if (!signedEvent || signedEvent.kind !== 20000) return;
        const closestRelays = this.getClosestRelaysForGeohash(geohash);
        if (closestRelays.length === 0) return;
        const geoUrls = new Set(closestRelays.map(r => r.url));

        // Pool mode: retry with GEO_EVENT to geo workers only.
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            setTimeout(() => {
                if (this._isAnyPoolOpen()) {
                    this._poolSendToRole('geo', ['GEO_EVENT', signedEvent, closestRelays.map(r => r.url)]);
                }
            }, 2000);
            return;
        }

        const msg = JSON.stringify(['EVENT', signedEvent]);

        const trySend = () => {
            for (const url of geoUrls) {
                const relay = this.relayPool.get(url);
                if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                    try { relay.ws.send(msg); } catch (_) {}
                }
            }
        };

        trySend();
        setTimeout(trySend, 2000);
    },

    startGeoRelayKeepAlive(geohash) {
        if (this._geoRelayKeepAliveInterval) {
            clearInterval(this._geoRelayKeepAliveInterval);
            this._geoRelayKeepAliveInterval = null;
        }
        if (!geohash || !this.isValidGeohash(geohash)) return;

        this._geoRelayKeepAliveGeohash = geohash;
        this._geoRelayKeepAliveInterval = setInterval(() => {
            if (this.currentGeohash !== this._geoRelayKeepAliveGeohash || document.hidden) return;
            if (this.settings && this.settings.groupChatPMOnlyMode) return;

            const closest = this.getClosestRelaysForGeohash(this._geoRelayKeepAliveGeohash);
            if (closest.length === 0) return;

            if (this.useRelayProxy) {
                const expected = new Set(closest.map(r => r.url).filter(u => !this.isRelayBlocked(u)));
                const present = new Set(this.poolConnectedRelays || []);
                let missing = 0;
                expected.forEach(u => { if (!present.has(u)) missing++; });
                if (missing > 0) this.connectToGeoRelays(this._geoRelayKeepAliveGeohash);
                return;
            }

            let alive = 0;
            const wanted = closest.filter(r => !this.isRelayBlocked(r.url));
            for (const r of wanted) {
                const relay = this.relayPool.get(r.url);
                if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) alive++;
            }
            if (alive < wanted.length) {
                this.connectToGeoRelays(this._geoRelayKeepAliveGeohash);
            }
        }, 30000);
    },

    stopGeoRelayKeepAlive() {
        if (this._geoRelayKeepAliveInterval) {
            clearInterval(this._geoRelayKeepAliveInterval);
            this._geoRelayKeepAliveInterval = null;
        }
        this._geoRelayKeepAliveGeohash = null;
    },

    async connectToGeoRelays(geohash) {
        if (!geohash || !this.isValidGeohash(geohash)) {
            return;
        }

        if (this.settings.groupChatPMOnlyMode) return;

        // Wait for the remote CSV so we match bitchat's relay set for this geohash.
        if (this._geoRelaysReady) {
            await this._geoRelaysReady;
        }

        const closestRelays = this.getClosestRelaysForGeohash(geohash, this.geoRelayCount);
        if (closestRelays.length === 0) {
            return;
        }
        const geoRelayUrls = new Set(closestRelays.map(r => r.url));

        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            const prev = this.geoRelayConnections.get(geohash);
            const changed = !prev || prev.size !== geoRelayUrls.size ||
                [...geoRelayUrls].some(u => !prev.has(u));
            this.geoRelayConnections.set(geohash, geoRelayUrls);
            for (const url of geoRelayUrls) this.currentGeoRelays.add(url);

            const present = new Set(this.poolConnectedRelays || []);
            const anyMissing = [...geoRelayUrls].some(u => !present.has(u) && !this.isRelayBlocked(u));

            if (changed || anyMissing) {
                this._poolSendRelayConfig();
                this._ensureAllShardsConnected();
                this.channelLoadedFromRelays.delete(geohash);
                this.subscribeToChannelTargeted(geohash, 'geohash');
            }
            return;
        }

        this.geoRelayConnections.set(geohash, geoRelayUrls);

        const connectionPromises = [];
        let newlyConnected = 0;
        for (const { url: relayUrl } of closestRelays) {
            // Already connected: ensure it has the standing kind-20000 sub.
            const existing = this.relayPool.get(relayUrl);
            if (existing && existing.ws && existing.ws.readyState === WebSocket.OPEN) {
                this.currentGeoRelays.add(relayUrl);
                this._ensureGeoRelayLiveSub(existing, relayUrl);
                continue;
            }

            if (this.blacklistedRelays.has(relayUrl) && !this.isBlacklistExpired(relayUrl)) {
                continue;
            }
            if (!this.shouldRetryRelay(relayUrl)) {
                continue;
            }

            connectionPromises.push(
                this.connectToRelayWithTimeout(relayUrl, 'relay', 3000).then(() => {
                    const relay = this.relayPool.get(relayUrl);
                    if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                        this.currentGeoRelays.add(relayUrl);
                        this._ensureGeoRelayLiveSub(relay, relayUrl);
                        this.updateConnectionStatus();
                        newlyConnected++;
                    }
                })
            );
        }

        await Promise.all(connectionPromises);

        this.updateRelayStatus();

        if (newlyConnected > 0) {
            this.channelLoadedFromRelays.delete(geohash);
            this.loadChannelFromRelays(geohash, 'geohash');
        }

        this.ensureDefaultRelaysConnected();
        // The geo-origin gate needs a source for the other geohash channels in view too.
        this.ensureGeoRelayCoverage();
    },

    // Direct mode covers only visible channels; the pool Worker can hold the whole ~415-entry directory.
    GEO_COVERAGE_MAX: 40,

    // Covers every geohash channel in view, not just the one on screen.
    async ensureGeoRelayCoverage() {
        if (this.useRelayProxy) return;   // The pool already carries all of them.
        if (this.settings && this.settings.groupChatPMOnlyMode) return;
        if (this._geoRelaysReady) await this._geoRelaysReady;

        const wanted = [];
        const seen = new Set();
        const add = (name) => {
            if (wanted.length >= this.GEO_COVERAGE_MAX) return;
            const gh = typeof name === 'string' ? name.toLowerCase() : '';
            if (!gh || !this.isValidGeohash(gh)) return;
            for (const r of this.getClosestRelaysForGeohash(gh)) {
                if (wanted.length >= this.GEO_COVERAGE_MAX) return;
                if (seen.has(r.url)) continue;
                seen.add(r.url);
                wanted.push(r.url);
            }
        };
        // On screen first, so the cap can never cut the channel being read.
        add(this.currentGeohash);
        for (const c of (this.userJoinedChannels || [])) add(c);
        for (const c of (this.pinnedChannels || [])) add(c);
        for (const k of (this.channels ? this.channels.keys() : [])) add(k);

        for (const relayUrl of wanted) {
            const existing = this.relayPool.get(relayUrl);
            if (existing && existing.ws && existing.ws.readyState === WebSocket.OPEN) {
                this.currentGeoRelays.add(relayUrl);
                this._ensureGeoRelayLiveSub(existing, relayUrl);
                continue;
            }
            if (this.blacklistedRelays.has(relayUrl) && !this.isBlacklistExpired(relayUrl)) continue;
            if (!this.shouldRetryRelay(relayUrl)) continue;
            try {
                await this.connectToRelayWithTimeout(relayUrl, 'relay', 3000);
                const relay = this.relayPool.get(relayUrl);
                if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                    this.currentGeoRelays.add(relayUrl);
                    this._ensureGeoRelayLiveSub(relay, relayUrl);
                }
            } catch (_) { /* One unreachable relay is not a failure. */ }
        }
        this.updateRelayStatus();
    },

    _ensureGeoRelayLiveSub(relay, relayUrl) {
        if (!relay || relay._geoLiveSub) return;
        relay._geoLiveSub = true;
        if (relay.subscriptions && relay.subscriptions.size > 0) return;
        this.subscribeToSingleRelay(relayUrl);
    },

    // Force the app relay (wss://relay.nymchat.app) to be connected.
    async ensureAppRelayConnected() {
        const url = this.appRelay;
        if (!url) return;
        if (!this.useRelayProxy) return;

        this.blacklistedRelays.delete(url);
        this.blacklistTimestamps.delete(url);
        this.failedRelays.delete(url);

        if (this.useRelayProxy) {
            if (!navigator.onLine) return;
            if (!this._isAnyPoolOpen()) {
                if (!this._poolReconnecting) this._schedulePoolReconnect();
                return;
            }
            const expectedShards = this._computeExpectedShards();
            const shard = expectedShards.find(s => Array.isArray(s.relays) && s.relays.includes(url));
            if (!shard) return;
            const existing = this.poolSockets.find(p => p.id === shard.id);
            const shardOpen = existing && existing.ws && existing.ws.readyState === WebSocket.OPEN;
            if (!shardOpen) this._reconnectPoolShard(shard);
            return;
        }

        const relay = this.relayPool.get(url);
        const isOpen = relay && relay.ws && relay.ws.readyState === WebSocket.OPEN;
        if (isOpen) return;

        if (this.reconnectingRelays && this.reconnectingRelays.has(url)) return;
        if (this.pendingConnections && this.pendingConnections.has(url)) return;

        await this.connectToRelay(url, 'relay');
        const r = this.relayPool.get(url);
        if (r && r.ws && r.ws.readyState === WebSocket.OPEN) {
            this.subscribeToSingleRelay(url);
            this.updateConnectionStatus();
        }
    },

    startAppRelayWatchdog() {
        if (this._appRelayWatchdog) return;
        if (!this.useRelayProxy) return;
        this.ensureAppRelayConnected();
        this._appRelayWatchdog = setInterval(() => {
            if (document.hidden) return;
            if (!navigator.onLine) return;
            this.ensureAppRelayConnected();
        }, 15000);
    },

    async ensureDefaultRelaysConnected() {
        if (this.useRelayProxy) return;

        for (const relayUrl of this.defaultRelays) {
            const relay = this.relayPool.get(relayUrl);
            const isConnected = relay && relay.ws && relay.ws.readyState === WebSocket.OPEN;

            if (!isConnected && this.shouldRetryRelay(relayUrl)) {
                await this.connectToRelayWithTimeout(relayUrl, 'relay', 3000);
                const r = this.relayPool.get(relayUrl);
                if (r && r.ws && r.ws.readyState === WebSocket.OPEN) {
                    this.subscribeToSingleRelay(relayUrl);
                    this.updateConnectionStatus();
                }
            }
        }
    },

    applyLowDataMode(enabled) {
        if (enabled) {
            if (this.useRelayProxy && this._isAnyPoolOpen()) {
                // _poolSendRelayConfig respects lowDataMode (defaults + DM relays + active geo relays).
                this._poolSendRelayConfig();
            } else {
                const keepRelays = new Set(this.defaultRelays);
                for (const url of this.currentGeoRelays) {
                    keepRelays.add(url);
                }
                for (const [url, relay] of this.relayPool) {
                    if (!keepRelays.has(url) && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                        relay.ws.close();
                        this.relayPool.delete(url);
                    }
                }
                this.updateConnectionStatus();
            }
        } else {
            if (this.useRelayProxy) {
                this._poolSendRelayConfig();
            } else {
                this.defaultRelays.forEach(relayUrl => {
                    if (!this.relayPool.has(relayUrl) && this.shouldRetryRelay(relayUrl)) {
                        this.connectToRelay(relayUrl, 'relay').then(() => {
                            const r = this.relayPool.get(relayUrl);
                            if (r && r.ws && r.ws.readyState === WebSocket.OPEN) {
                                this.subscribeToSingleRelay(relayUrl);
                                this.updateConnectionStatus();
                            }
                        });
                    }
                });
                this.geoRelays.forEach((relay, index) => {
                    const relayUrl = relay.url;
                    if (!this.relayPool.has(relayUrl) && this.shouldRetryRelay(relayUrl)) {
                        setTimeout(() => {
                            this.connectToRelayWithTimeout(relayUrl, 'relay', 3000).then(() => {
                                const r = this.relayPool.get(relayUrl);
                                if (r && r.ws && r.ws.readyState === WebSocket.OPEN) {
                                    this.subscribeToSingleRelay(relayUrl);
                                    this.updateConnectionStatus();
                                }
                            });
                        }, index * 50);
                    }
                });
            }
        }
    },

    cleanupGeoRelays(previousGeohash) {
        if (!previousGeohash) return;

        const previousGeoRelays = this.geoRelayConnections.get(previousGeohash);
        if (!previousGeoRelays) return;

        const stillNeededRelays = new Set();
        for (const [geohash, relays] of this.geoRelayConnections) {
            if (geohash !== previousGeohash) {
                for (const url of relays) {
                    stillNeededRelays.add(url);
                }
            }
        }

        const keepRelays = new Set(this.defaultRelays);

        for (const url of previousGeoRelays) {
            if (!stillNeededRelays.has(url) && !keepRelays.has(url)) {
                this.currentGeoRelays.delete(url);

                if (this.settings && this.settings.lowDataMode) {
                    if (this.useRelayProxy) {
                        // Pool mode: config is sent after the loop so the proxy drops the relay.
                    } else {
                        const relay = this.relayPool.get(url);
                        if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                            relay.ws.close();
                        }
                        this.relayPool.delete(url);
                    }
                }
            }
        }

        this.geoRelayConnections.delete(previousGeohash);

        if (this.settings && this.settings.lowDataMode && this.useRelayProxy) {
            this._poolSendRelayConfig();
        }

        this.updateConnectionStatus();
    },

    updateRelayStatus() {
        const listEl = document.getElementById('connectedRelaysList');
        if (!listEl) return;

        const connectedRelays = [];

        this.relayPool.forEach((relay, url) => {
            if (this.writeOnlyRelays && this.writeOnlyRelays.has(url)) return;
            connectedRelays.push(url);
        });

        let html = '';

        if (connectedRelays.length > 0) {
            html += '<div class="nm-relay-1"><strong class="nm-primary">Connected Relays:</strong><br/>';
            connectedRelays.slice(0, 20).forEach(url => {
                html += `<div class="nm-relay-2">• ${this.escapeHtml(url)}</div>`;
            });
            if (connectedRelays.length > 20) {
                html += `<div class="nm-relay-3">... and ${connectedRelays.length - 20} more</div>`;
            }
            html += '</div>';
        }

        html += `<div class="nm-relay-4">Total Connected: ${this.relayPool.size} relays</div>`;

        const gateSockets = (this.poolSockets || []).filter(p => p && typeof p.badgeGate === 'string');
        if (gateSockets.length) {
            const gated = gateSockets.filter(p => p.badgeGate !== 'off');
            if (gated.length) {
                const dropped = gated.reduce((n, p) => n + (p.unbadged || 0), 0);
                html += `<div class="nm-relay-4">Badge gate: ${this.escapeHtml(gated[0].badgeGate)} · ${dropped} unbadged message${dropped === 1 ? '' : 's'} dropped by this pool</div>`;
            } else {
                html += '<div class="nm-relay-4">Badge gate: off</div>';
            }
        }

        listEl.innerHTML = html || '<div class="nm-dim12">No relays connected</div>';
    },

    setupVisibilityMonitoring() {
        const reconcile = () => {
            if (typeof this.reconcilePendingPurchases === 'function') {
                try { this.reconcilePendingPurchases(); } catch (e) { }
            }
        };
        document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') reconcile(); });
        window.addEventListener('focus', reconcile);
        window.addEventListener('online', reconcile);
        setTimeout(reconcile, 4000);

        document.addEventListener('visibilitychange', () => {
            if (document.visibilityState === 'visible') {
                this._probePoolsNow();
                const delay = this.isFlutterWebView ? 200 : 500;
                setTimeout(() => {
                    this.clearRelayBlocksForReconnection();

                    this.checkConnectionHealth();

                    if (!this.connected && navigator.onLine) {
                        this.attemptReconnection();
                    }

                    if (this.useRelayProxy) {
                        if (this._isAnyWorkerPoolOpen()) {
                            this._poolSubscribe();
                            this._ensureAllShardsConnected();
                        } else if (!this._poolReconnecting && navigator.onLine) {
                            this._schedulePoolReconnect();
                        }
                    } else {
                        setTimeout(() => this.resubscribeAllRelays(), 250);
                        if (this._poolFallbackActive && navigator.onLine) {
                            this._schedulePoolReconnectInBackground(true);
                        }
                    }

                    if (typeof this.markVisibleChannelMessagesRead === 'function') {
                        this.markVisibleChannelMessagesRead();
                    }
                    if (typeof this._markVisibleGroupMessagesRead === 'function') {
                        this._markVisibleGroupMessagesRead();
                    }
                    // Background tabs may skip column render hooks, so reconcile columns on return.
                    if (typeof this._cvScheduleReconcile === 'function') {
                        this._cvScheduleReconcile(0);
                    }
                    if (typeof this._cvMarkVisibleColumnsRead === 'function') {
                        this._cvMarkVisibleColumnsRead();
                    }
                    if (typeof this._markOpenConversationReadOnReturn === 'function') {
                        this._markOpenConversationReadOnReturn();
                    }

                    this.backfillFromD1OnReconnect();
                    this._catchUpLiveGap();
                }, delay);
            } else {
                this._backgroundedAt = Date.now();
                this._noteLiveGap();

                if (this.reconnectionInterval) {
                    clearInterval(this.reconnectionInterval);
                    this.reconnectionInterval = null;
                }
            }
        });

        window.addEventListener('freeze', () => this._noteLiveGap());
        window.addEventListener('resume', () => {
            this._probePoolsNow();
            this._catchUpLiveGap();
        });
        window.addEventListener('online', () => this._probePoolsNow());

        window.addEventListener('focus', () => {
            const delay = this.isFlutterWebView ? 200 : 500;
            setTimeout(() => {
                this.clearRelayBlocksForReconnection();

                this.checkConnectionHealth();

                if (!this.connected && navigator.onLine) {
                    this.attemptReconnection();
                }

                if (this.useRelayProxy) {
                    if (this._isAnyWorkerPoolOpen()) {
                        this._poolSubscribe();
                        this._ensureAllShardsConnected();
                    } else if (!this._poolReconnecting && navigator.onLine) {
                        this._schedulePoolReconnect();
                    }
                } else {
                    setTimeout(() => this.resubscribeAllRelays(), 250);
                    if (this._poolFallbackActive && navigator.onLine) {
                        this._schedulePoolReconnectInBackground(true);
                    }
                }

                if (typeof this.markVisibleChannelMessagesRead === 'function') {
                    this.markVisibleChannelMessagesRead();
                }
                if (typeof this._markVisibleGroupMessagesRead === 'function') {
                    this._markVisibleGroupMessagesRead();
                }
                if (typeof this._cvMarkVisibleColumnsRead === 'function') {
                    this._cvMarkVisibleColumnsRead();
                }

                this.backfillFromD1OnReconnect();
            }, delay);
        });

        if (this.isFlutterWebView) {
            window.addEventListener('resume', () => {
                setTimeout(() => {
                    this.clearRelayBlocksForReconnection();

                    this.checkConnectionHealth();

                    if (!this.connected && navigator.onLine) {
                        this.attemptReconnection();
                    }

                    if (this.useRelayProxy) {
                        if (this._isAnyWorkerPoolOpen()) {
                            this._poolSubscribe();
                            this._ensureAllShardsConnected();
                        } else if (!this._poolReconnecting && navigator.onLine) {
                            this._schedulePoolReconnect();
                        }
                    } else {
                        setTimeout(() => this.resubscribeAllRelays(), 250);
                        if (this._poolFallbackActive && navigator.onLine) {
                            this._schedulePoolReconnectInBackground(true);
                        }
                    }

                    this.backfillFromD1OnReconnect();
                }, 200);
            });
        }
    },

    clearRelayBlocksForReconnection() {
        this.failedRelays.clear();

        // Preserve permanent rejections (auth-required, unsupported filter); those won't change.
        const keep = this._permanentBlacklist || new Set();
        this.blacklistedRelays.clear();
        this.blacklistTimestamps.clear();
        for (const url of keep) {
            this.blacklistedRelays.add(url);
            this.blacklistTimestamps.set(url, Date.now() + (10 * 365 * 24 * 3600 * 1000));
        }

        if (this.reconnectingRelays) {
            this.reconnectingRelays.clear();
        }

        this.reconnectionAttempts = 0;
        this.isReconnecting = false;
        this._poolReconnecting = false;
        this._poolReconnectRetries = 0;
    },

    async checkConnectionHealth() {

        if (this.useRelayProxy) {
            this.updateConnectionStatus();
            if (!this._isAnyWorkerPoolOpen() && !this._poolReconnecting && navigator.onLine) {
                this._schedulePoolReconnect();
            }
            return;
        }

        let actuallyConnected = 0;
        const deadRelays = [];

        this.relayPool.forEach((relay, url) => {
            if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                actuallyConnected++;
            } else {
                deadRelays.push(url);
            }
        });

        deadRelays.forEach(url => {
            this.relayPool.delete(url);
        });

        if (actuallyConnected === 0) {
            this.connected = false;
            this.updateConnectionStatus('Disconnected');

            if (this.reconnectingRelays) {
                this.reconnectingRelays.clear();
            }

            await this.reconnectToBroadcastRelays();

            if (this.currentGeohash) {
                setTimeout(() => {
                    this.connectToGeoRelays(this.currentGeohash);
                }, 3000);
            }

        } else {
            this.updateConnectionStatus();

            const missingEssential = this.defaultRelays.filter(url => !this.relayPool.has(url));
            if (missingEssential.length > 0) {
                this.reconnectToBroadcastRelays();
            }

            if (this.currentGeohash) {
                this.connectToGeoRelays(this.currentGeohash);
            }

            this.ensureDefaultRelaysConnected();
            this.ensureGeoRelayCoverage();
        }
    },

    async reconnectToBroadcastRelays() {
        if (this.useRelayProxy) {
            if (this._isAnyPoolOpen()) return;
            this._schedulePoolReconnect();
            return;
        }

        let connectedCount = 0;

        const relaysToConnect = [...this.defaultRelays];
        if (this.previouslyConnectedRelays && this.previouslyConnectedRelays.size > 0) {
            relaysToConnect.sort((a, b) => {
                const aWasConnected = this.previouslyConnectedRelays.has(a);
                const bWasConnected = this.previouslyConnectedRelays.has(b);
                if (aWasConnected && !bWasConnected) return -1;
                if (!aWasConnected && bWasConnected) return 1;
                return 0;
            });
        }

        for (const relayUrl of relaysToConnect) {
            if (!this.relayPool.has(relayUrl) ||
                (this.relayPool.get(relayUrl).ws &&
                    this.relayPool.get(relayUrl).ws.readyState !== WebSocket.OPEN)) {

                await this.connectToRelay(relayUrl, 'relay');
                const r = this.relayPool.get(relayUrl);
                if (r && r.ws && r.ws.readyState === WebSocket.OPEN) {
                    this.subscribeToSingleRelay(relayUrl);
                    connectedCount++;

                    if (connectedCount === 1) {
                        this.connected = true;
                        this.updateConnectionStatus();
                    }
                }

                await new Promise(resolve => setTimeout(resolve, 50));
            }
        }

        this.updateConnectionStatus();
    },

    setupNetworkMonitoring() {
        this.reconnectionAttempts = 0;
        this.maxReconnectionAttempts = 10;
        this.reconnectionInterval = null;

        window.addEventListener('online', () => {
            this.displaySystemMessage('Network connection restored, reconnecting...');
            this.reconnectionAttempts = 0;

            this.updateConnectionStatus('Reconnecting...');

            if (this.useRelayProxy) {
                this._poolReconnecting = false;
                this._poolReconnectRetries = 0;
                this._lastPoolReconnectSchedule = 0;
                this._schedulePoolReconnect();
                this._ensureAllShardsConnected();
                return;
            }

            if (this._poolFallbackActive) {
                this._schedulePoolReconnectInBackground(true);
            }

            if (this.reconnectionInterval) {
                clearInterval(this.reconnectionInterval);
                this.reconnectionInterval = null;
            }

            if (this.reconnectingRelays) {
                this.reconnectingRelays.clear();
            }

            this.relayPool.forEach((relay, url) => {
                if (!relay.ws || relay.ws.readyState !== WebSocket.OPEN) {
                    this.relayPool.delete(url);

                }
            });

            this.blacklistedRelays.clear();
            this.blacklistTimestamps.clear();
            this.isReconnecting = false;

            this.reconnectToBroadcastRelays();

            setTimeout(() => this.retryPendingDMsOnReconnect(), 3000);
            // Publish what the Bluetooth mesh carried while offline (mesh-outbox.js).
            setTimeout(() => this.flushMeshOutbox && this.flushMeshOutbox(), 3500);
        });

        window.addEventListener('offline', () => {

            this.relayPool.forEach((relay, url) => {
                if (relay.ws) {
                    try {
                        relay.ws.close();
                    } catch (e) {
                    }
                }
                this.relayPool.delete(url);
            });

            this.connected = false;
            this.displaySystemMessage('Network connection lost');
            this.updateConnectionStatus('Disconnected');
        });

        this.startReconnectionMonitoring();
    },

    startReconnectionMonitoring() {
        this.reconnectionInterval = null;

        const startMonitoring = () => {
            if (this.reconnectionInterval) {
                clearInterval(this.reconnectionInterval);
            }

            // Don't monitor during the initial connection; connectToRelays() handles it.
            if (this.initialConnectionInProgress) {
                return;
            }

            if (!this.connected && !document.hidden) {
                this.reconnectionInterval = setInterval(() => {
                    if (this.initialConnectionInProgress) {
                        return;
                    }
                    if (!document.hidden && !this.connected && navigator.onLine) {
                        this.attemptReconnection();
                    } else if (document.hidden) {
                        clearInterval(this.reconnectionInterval);
                        this.reconnectionInterval = null;
                    }
                }, 5000);
            }
        };

        const stopMonitoring = () => {
            if (this.reconnectionInterval) {
                clearInterval(this.reconnectionInterval);
                this.reconnectionInterval = null;
            }
        };

        document.addEventListener('visibilitychange', () => {
            if (document.visibilityState === 'visible') {
                setTimeout(() => {
                    this.checkConnectionHealth();
                    if (!this.connected && navigator.onLine) {
                        this.attemptReconnection();
                        startMonitoring();
                    }
                }, 200);
            } else {
                stopMonitoring();
            }
        });

        if (!document.hidden) {
            startMonitoring();
        }
    },

    async attemptReconnection() {
        if (this.useRelayProxy) {
            // Don't reset _poolReconnecting; _schedulePoolReconnect's guard prevents duplicate attempts.
            if (!this._poolReconnecting) {
                this._schedulePoolReconnect();
            }
            return;
        }

        if (this.isReconnecting) {
            return;
        }

        if (this.reconnectionAttempts >= this.maxReconnectionAttempts) {
            this.updateConnectionStatus('Disconnected - Click to reconnect');
            return;
        }

        this.isReconnecting = true;
        this.reconnectionAttempts++;

        this.updateConnectionStatus(`Reconnecting (${this.reconnectionAttempts}/${this.maxReconnectionAttempts})...`);

        try {
            this.relayPool.forEach((relay, url) => {
                if (!relay.ws || relay.ws.readyState !== WebSocket.OPEN) {
                    this.relayPool.delete(url);

                }
            });

            // In low data mode, only try the 5 defaults.
            const reconnectCandidates = this.settings && this.settings.lowDataMode
                ? this.defaultRelays
                : this.defaultRelays;
            let connected = false;
            for (const relayUrl of reconnectCandidates) {
                if (this.relayPool.has(relayUrl)) {
                    const relay = this.relayPool.get(relayUrl);
                    if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                        connected = true;
                        break;
                    }
                }

                await this.connectToRelayWithTimeout(relayUrl, 'relay', 3000);
                const relay = this.relayPool.get(relayUrl);
                if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                    this.subscribeToSingleRelay(relayUrl);
                    connected = true;
                    break;
                }
            }

            if (connected) {
                this.connected = true;
                this.reconnectionAttempts = 0;
                this.updateConnectionStatus();

                this.reconnectToBroadcastRelays();

                this.ensureDefaultRelaysConnected();

                if (this.currentGeohash) {
                    this.connectToGeoRelays(this.currentGeohash);
                }

                setTimeout(() => this.retryPendingDMsOnReconnect(), 2000);
                setTimeout(() => this.flushMeshOutbox && this.flushMeshOutbox(), 2500);
            }
        } catch (error) {
        } finally {
            this.isReconnecting = false;
        }
    },

    _loadQuietList() {
        const load = async () => {
            try {
                const d = await this._storageApiRequest('filter-get', {}, false);
                this._quiet = new Set([].concat(d.p || [], d.e || []));
                this._dropQuietFromView();
            } catch (_) { }
        };
        load();
        if (!this._quietTimer) this._quietTimer = setInterval(load, 600000);
    },

    _quietMessage(m) {
        const q = this._quiet;
        if (!q || !q.size || !m || m.isOwn) return false;
        return q.has(m.pubkey) || q.has(m.id);
    },

    _dropQuietFromView() {
        const q = this._quiet;
        if (!q || !q.size || typeof document === 'undefined') return;
        document.querySelectorAll('.message[data-message-id]').forEach((el) => {
            const d = el.dataset || {};
            if (d.pubkey === this.pubkey) return;
            if (q.has(d.messageId) || q.has(d.pubkey)) el.remove();
        });
    },

    _quietHit(ev) {
        const q = this._quiet;
        if (!q || !q.size) return false;
        if (this.pubkey && q.has(this.pubkey)) return true;
        return !!(ev && (q.has(ev.pubkey) || q.has(ev.id)));
    },

    async connectToRelays() {
        try {
            this.initialConnectionInProgress = true;
            this._loadQuietList();
            this.updateConnectionStatus('Connecting...');
            this.startAppRelayWatchdog();

            if (this.useRelayProxy) {
                let poolConnected = false;
                const maxRetries = 2;
                for (let attempt = 0; attempt < maxRetries; attempt++) {
                    try {
                        if (attempt > 0) {
                            const base = Math.min(2000 * Math.pow(2, attempt - 1), 8000);
                            const delay = this._jitter(base);
                            this.updateConnectionStatus(`Reconnecting (attempt ${attempt + 1})...`);
                            await new Promise(r => setTimeout(r, delay));
                        }
                        await this._connectToRelayPool();
                        poolConnected = true;
                        break;
                    } catch (poolErr) {
                        console.warn(`[NYM] Relay pool attempt ${attempt + 1}/${maxRetries} failed:`, poolErr.message);
                        if (attempt === maxRetries - 1) {
                            // All retries exhausted: use direct connections and keep retrying the pool in the background.
                            console.warn('[NYM] Relay pool failed, falling back to direct connections');
                            this.useRelayProxy = false;
                            this._poolFallbackActive = true;
                            this._noteAutoFallback();
                            this._schedulePoolReconnectInBackground();
                        }
                    }
                }

                if (this.useRelayProxy && poolConnected) {
                    this.connected = true;
                    this._startPoolShardHealthCheck();
                    if (typeof this._syncComposerVerifying === 'function') this._syncComposerVerifying();
                    this.updateConnectionStatus();

                    this._poolSubscribe();

                    // This is a first connect, which the reconnect paths never cover; without it a fresh login never announces.
                    try { this.schedulePqAnnouncement(); } catch (_) { }
                    try { if (typeof this.ensureAttestBadge === 'function') this.ensureAttestBadge(); } catch (_) { }

                    if (!this.settings.groupChatPMOnlyMode && this.currentChannel) {
                        this._renderChannelTitle(this.currentChannel, this.currentGeohash || this.currentChannel);
                    }

                    setTimeout(() => {
                        this._ensureChatViewMode();
                        if (window.pendingChannel || window.urlChannelRouted) return;
                        if (this._cvActive) return;
                        // Don't override if the user already navigated.
                        if (this.navigationHistory.length > 0) return;
                        if (this.settings.groupChatPMOnlyMode) {
                            this.navigateToLatestPMOrGroup();
                        } else {
                            const pinned = this.pinnedLandingChannel || { type: 'geohash', geohash: 'nymchat' };
                            this.currentChannel = '';
                            this.currentGeohash = '';
                            if (pinned.type === 'geohash' && pinned.geohash) {
                                this.switchChannel(pinned.geohash, pinned.geohash);
                            } else {
                                this.switchChannel('nymchat', 'nymchat');
                            }
                        }
                    }, 100);

                    if (this.messageQueue.length > 0) {
                        const queuedMessages = [...this.messageQueue];
                        this.messageQueue = [];
                        queuedMessages.forEach(msg => {
                            try {
                                const parsed = JSON.parse(msg);
                                this.sendToRelay(parsed);
                            } catch (e) { }
                        });
                    }

                    this.initialConnectionInProgress = false;
                    return;
                }
            }

            let initialConnected = false;
            let connectedRelayUrl = null;

            for (const relayUrl of this.defaultRelays) {
                if (this.relayPool.has(relayUrl)) {
                    const relay = this.relayPool.get(relayUrl);
                    if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                        initialConnected = true;
                        connectedRelayUrl = relayUrl;
                        break;
                    }
                }
            }

            if (!initialConnected) {
                const initialRelays = this.defaultRelays
                    .filter(url => this.shouldRetryRelay(url))
                    .slice(0, 5);

                if (initialRelays.length > 0) {
                    const connectionPromises = initialRelays.map(relayUrl =>
                        this.connectToRelayWithTimeout(relayUrl, 'relay', 2000).then(() => {
                            const relay = this.relayPool.get(relayUrl);
                            if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                                return relayUrl;
                            }
                            return null;
                        })
                    );

                    const firstSuccessful = await new Promise((resolve) => {
                        let pending = connectionPromises.length;
                        connectionPromises.forEach(p => {
                            p.then(result => {
                                if (result) resolve(result);
                                else {
                                    pending--;
                                    if (pending === 0) resolve(null);
                                }
                            });
                        });
                    });

                    if (firstSuccessful) {
                        initialConnected = true;
                        connectedRelayUrl = firstSuccessful;
                    }
                }

                if (!initialConnected) {
                    const remainingRelays = this.defaultRelays.slice(5);
                    for (const relayUrl of remainingRelays) {
                        if (!this.shouldRetryRelay(relayUrl)) {
                            continue;
                        }

                        await this.connectToRelayWithTimeout(relayUrl, 'relay', 2000);
                        const relay = this.relayPool.get(relayUrl);
                        if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                            initialConnected = true;
                            connectedRelayUrl = relayUrl;
                            break;
                        }
                    }
                }
            }

            if (!initialConnected) {
                throw new Error('Could not connect to any relay');
            }

            this.connected = true;
            if (typeof this._syncComposerVerifying === 'function') this._syncComposerVerifying();
            if (typeof this._syncComposerConnHint === 'function') this._syncComposerConnHint();

            if (this.messageQueue.length > 0) {
                const queuedMessages = [...this.messageQueue];
                this.messageQueue = [];
                queuedMessages.forEach(msg => {
                    try {
                        const parsed = JSON.parse(msg);
                        this.sendToRelay(parsed);
                    } catch (e) {
                    }
                });
            }

            if (!this.settings.groupChatPMOnlyMode && this.currentChannel) {
                this._renderChannelTitle(this.currentChannel, this.currentGeohash || this.currentChannel);
            }

            this.subscribeToAllRelays();

            // Announce post-quantum capability (see the pool branch above).
            try { this.schedulePqAnnouncement(); } catch (_) { }
            try { if (typeof this.ensureAttestBadge === 'function') this.ensureAttestBadge(); } catch (_) { }

            setTimeout(() => {
                this._ensureChatViewMode();
                // Skip if a URL channel is pending or was already routed.
                if (window.pendingChannel || window.urlChannelRouted) return;
                if (this._cvActive) return;
                // Don't override if the user already navigated.
                if (this.navigationHistory.length > 0) return;

                if (this.settings.groupChatPMOnlyMode) {
                    this.navigateToLatestPMOrGroup();
                } else {
                    const pinned = this.pinnedLandingChannel || { type: 'geohash', geohash: 'nymchat' };
                    this.currentChannel = '';
                    this.currentGeohash = '';

                    if (pinned.type === 'geohash' && pinned.geohash) {
                        this.switchChannel(pinned.geohash, pinned.geohash);
                    } else {
                        this.switchChannel('nymchat', 'nymchat');
                    }
                }
            }, 100);

            this.defaultRelays.forEach(relayUrl => {
                if (!this.relayPool.has(relayUrl) && this.shouldRetryRelay(relayUrl)) {
                    this.connectToRelay(relayUrl, 'relay').then(() => {
                        const r = this.relayPool.get(relayUrl);
                        if (r && r.ws && r.ws.readyState === WebSocket.OPEN) {
                            this.subscribeToSingleRelay(relayUrl);
                            this.updateConnectionStatus();
                        }
                    });
                }
            });

            if (!this.settings.lowDataMode && !this.settings.groupChatPMOnlyMode) {
                (this._geoRelaysReady || Promise.resolve()).then(() => {
                    const geoRelayUrls = (this.geoRelays || []).map(r => r.url || r).filter(Boolean);
                    for (const relayUrl of geoRelayUrls) {
                        if (!this.relayPool.has(relayUrl) && this.shouldRetryRelay(relayUrl)) {
                            this.connectToRelayWithTimeout(relayUrl, 'relay', this.relayTimeout).then(() => {
                                const r = this.relayPool.get(relayUrl);
                                if (r && r.ws && r.ws.readyState === WebSocket.OPEN) {
                                    this.subscribeToSingleRelay(relayUrl);
                                    this.updateConnectionStatus();
                                }
                            });
                        }
                    }
                });
            }

            if (!this.settings.lowDataMode && !this.settings.groupChatPMOnlyMode) {
                setTimeout(() => {
                    const relaysToConnect = [...this.allRelayUrls]
                        .filter(url =>
                            !this.relayPool.has(url) &&
                            !this.blacklistedRelays.has(url) &&
                            this.shouldRetryRelay(url))
                        .slice(0, this.maxRelaysForReq);
                    relaysToConnect.forEach((relayUrl, index) => {
                        setTimeout(() => {
                            this.connectToRelayWithTimeout(relayUrl, 'relay', this.relayTimeout).then(() => {
                                const r = this.relayPool.get(relayUrl);
                                if (r && r.ws && r.ws.readyState === WebSocket.OPEN) {
                                    this.subscribeToSingleRelay(relayUrl);
                                    this.updateConnectionStatus();
                                }
                            });
                        }, index * 100);
                    });
                }, 100);
            }

        } catch (error) {
            this.updateConnectionStatus('Connection Failed');
            this.displaySystemMessage('Failed to connect to relays: ' + error.message);

            if (typeof this._syncComposerVerifying === 'function') this._syncComposerVerifying();
        } finally {
            this.initialConnectionInProgress = false;
            if (typeof this._syncComposerConnHint === 'function') this._syncComposerConnHint();
        }
    },

    // Debounced so bursts of author-list changes don't rebuild every subscription each time.
    _scheduleCriticalResubscribe(delayMs = 750) {
        if (this._criticalResubscribeTimer) {
            clearTimeout(this._criticalResubscribeTimer);
        }
        this._criticalResubscribeTimer = setTimeout(() => {
            this._criticalResubscribeTimer = null;
            try { this.resubscribeAllRelays(); } catch (_) { }
        }, delayMs);
    },

    resubscribeAllRelays() {
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            this._poolSubscribe();
            return;
        }

        this.relayPool.forEach((relay, url) => {
            if (!relay.ws || relay.ws.readyState !== WebSocket.OPEN) return;
            this.closeSubscriptionsForRelay(url);
            this.subscribeToSingleRelay(url);
        });

        // Ephemeral pubkeys use independent REQs (metadata separation).
        this._refreshEphemeralSubscriptions();

        this._resubscribeChannels();
        this._catchUpLiveGap();
    },

    closeSubscriptionsForRelay(relayUrl) {
        const relay = this.relayPool.get(relayUrl);
        if (!relay || !relay.ws || relay.ws.readyState !== WebSocket.OPEN) return;

        if (relay.subscriptions) {
            relay.subscriptions.forEach(subId => {
                this._safeWsSend(relay.ws, JSON.stringify(["CLOSE", subId]), { critical: true });
            });
            relay.subscriptions.clear();
        } else {
            relay.subscriptions = new Set();
        }
    },

    _isGeoOrDiscoveredRelay(relayUrl) {
        const defaultSet = new Set(this.defaultRelays || []);
        return !defaultSet.has(relayUrl);
    },

    subscribeToSingleRelay(relayUrl) {
        if (this.writeOnlyRelays && this.writeOnlyRelays.has(relayUrl)) return;
        const relay = this.relayPool.get(relayUrl);
        if (!relay || !relay.ws || relay.ws.readyState !== WebSocket.OPEN) return;

        const ws = relay.ws;
        const since24h = Math.floor(Date.now() / 1000) - 86400;
        const isGeo = this._isGeoOrDiscoveredRelay(relayUrl);

        if (isGeo) {
            const subId = Math.random().toString(36).substring(2);
            if (!relay.subscriptions) relay.subscriptions = new Set();
            relay.subscriptions.add(subId);
            const filters = this._buildGeoFilters(since24h);
            this._safeWsSend(ws, JSON.stringify(this._normalizeReqPayload(["REQ", subId, ...filters])), { critical: true });
            return;
        }

        const subId = Math.random().toString(36).substring(2);

        if (!relay.subscriptions) {
            relay.subscriptions = new Set();
        }
        relay.subscriptions.add(subId);

        const filters = this._buildCriticalFilters(since24h);
        this._safeWsSend(ws, JSON.stringify(["REQ", subId, ...filters]), { critical: true });
    },

    _sendChannelReq(subId, filters, channelKey, channelType) {
        if (!filters || filters.length === 0) return;

        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            this._poolSend(["REQ", subId, ...filters]);
            return;
        }

        const reqStr = JSON.stringify(this._normalizeReqPayload(["REQ", subId, ...filters]));
        const targets = [];
        this.relayPool.forEach((relay, url) => {
            if (this.writeOnlyRelays && this.writeOnlyRelays.has(url)) return;
            if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                if (!relay.subscriptions) relay.subscriptions = new Set();
                relay.subscriptions.add(subId);
                targets.push(relay);
            }
        });
        this._broadcastAsync(targets, reqStr, { critical: true });
    },

    // Auto-CLOSEs ~300ms after the first EOSE or after a hard timeout (default 4s).
    _registerBackfillSub(subId, opts) {
        if (!subId) return;
        if (!this._backfillSubs) this._backfillSubs = new Map();
        if (this._backfillSubs.has(subId)) return;
        const timeoutMs = (opts && opts.timeoutMs) || 4000;

        let closed = false;
        const closeNow = () => {
            if (closed) return;
            closed = true;
            if (entry.timer) clearTimeout(entry.timer);
            if (this._backfillSubs) this._backfillSubs.delete(subId);
            const closeMsg = JSON.stringify(["CLOSE", subId]);
            if (this.useRelayProxy && this._isAnyPoolOpen()) {
                for (const p of this.poolSockets) {
                    this._safeWsSend(p.ws, closeMsg, { critical: true });
                }
            } else {
                this.relayPool.forEach((relay) => {
                    if (!relay || !relay.ws || relay.ws.readyState !== WebSocket.OPEN) return;
                    if (relay.subscriptions && relay.subscriptions.has(subId)) {
                        this._safeWsSend(relay.ws, closeMsg, { critical: true });
                        relay.subscriptions.delete(subId);
                    }
                });
            }
        };
        const entry = { timer: setTimeout(closeNow, timeoutMs), close: closeNow };
        this._backfillSubs.set(subId, entry);
    },

    _relayChannelBackfill(names) {
        if (this.useRelayProxy || this.inPMMode) return;
        const key = String(this.currentGeohash || this.currentChannel || '').toLowerCase();
        if (!key || !Array.isArray(names) || !names.includes(key)) return;
        if (!this._relayBackfilledChannels) this._relayBackfilledChannels = new Set();
        if (this._relayBackfilledChannels.has(key)) return;
        this._relayBackfilledChannels.add(key);
        const since = Math.floor(Date.now() / 1000) - 86400;
        const filters = [
            { kinds: [20000], '#g': [key], since, limit: 200 },
            { kinds: [23333], '#d': [key], since, limit: 200 }
        ];
        this._oneShotReqAcquire(() => {
            const subId = Math.random().toString(36).substring(2);
            this._registerBackfillSub(subId, { timeoutMs: 6000 });
            this._sendChannelReq(subId, filters, key, 'geohash');
            this._waitForEoseOrTimeout(subId, 6000).then(() => {
                this._oneShotReqDone();
                if (typeof this._refreshDirectHistoryNote === 'function') this._refreshDirectHistoryNote([key]);
            });
        });
    },

    _ensureChannelTypingSub(channelKey, channelType, force) {
        if (!channelKey) return;
        const isCurrent = channelKey === this.currentChannel || channelKey === this.currentGeohash;
        if (!isCurrent && !force) return;
        if (!this._channelTypingSubs) this._channelTypingSubs = new Map();
        if (this._channelTypingSubs.has(channelKey)) return;

        const sinceNow = Math.floor(Date.now() / 1000);
        const typingTag = this.isValidGeohash(channelKey) ? "#g" : "#d";
        const typingFilter = [{ kinds: [24420, 24421], [typingTag]: [channelKey], since: sinceNow }];
        const typingSubId = Math.random().toString(36).substring(2);
        this._channelTypingSubs.set(channelKey, typingSubId);
        this.channelSubscriptions.set(channelKey, typingSubId);
        this._sendChannelReq(typingSubId, typingFilter, channelKey, channelType);
    },

    // Kind 20000 is ephemeral and not stored, so only open a typing sub for the viewed channel.
    subscribeToChannelTargeted(channelKey, channelType) {
        if (this.channelLoadedFromRelays.has(channelKey)) {
            this._ensureChannelTypingSub(channelKey, channelType);
            return;
        }
        this.channelLoadedFromRelays.add(channelKey);
        this._ensureChannelTypingSub(channelKey, channelType);
    },

    // No-op: per-channel backfill REQs spammed relays; the broad kind-20000 sub covers stored events.
    subscribeToChannelBatch(channels) {
        if (!channels || channels.length === 0) return;
        channels.forEach(({ key }) => {
            if (key) this.channelLoadedFromRelays.add(key);
        });
    },

    loadChannelFromRelays(channelKey, channelType) {
        if (this.channelLoadedFromRelays.has(channelKey)) {
            this._ensureChannelTypingSub(channelKey, channelType);
            return;
        }

        // Storage key uses a # prefix for every channel with a g-tag.
        const storageKey = `#${channelKey}`;
        const currentMessages = this.messages.get(storageKey) || [];

        if (currentMessages.length < 50) {
            this._queueChannelSubscription(channelKey, channelType);
        } else {
            this.channelLoadedFromRelays.add(channelKey);
        }
    },

    async connectToRelayWithTimeout(relayUrl, type, timeout) {
        return Promise.race([
            this.connectToRelay(relayUrl, type),
            new Promise(resolve => setTimeout(resolve, timeout))
        ]);
    },

    shouldRetryRelay(relayUrl) {
        if (relayUrl === this.appRelay) return true;
        if (this.isRelayBlocked(relayUrl)) return false;

        if (this.relayPool.size > 0) {
            const s = this._getRelayStats().get(relayUrl);
            if (s && s.fails >= 3) {
                const coolDown = Math.min(
                    5 * 60 * 1000 * Math.pow(2, s.fails - 3),
                    6 * 60 * 60 * 1000
                );
                if (Date.now() - s.lastFail < coolDown) return false;
            }
        }

        const failedAttempt = this.failedRelays.get(relayUrl);
        if (!failedAttempt) return true;
        return Date.now() - failedAttempt > this.relayRetryDelay;
    },

    trackRelayFailure(relayUrl) {
        this.failedRelays.set(relayUrl, Date.now());
        if (navigator.onLine === false) return;
        const stats = this._getRelayStats();
        const s = stats.get(relayUrl) || { fails: 0, lastFail: 0, lastOk: 0 };
        s.fails++;
        s.lastFail = Date.now();
        stats.set(relayUrl, s);
        this._saveRelayStats();
    },

    clearRelayFailure(relayUrl) {
        this.failedRelays.delete(relayUrl);
        const stats = this._getRelayStats();
        const s = stats.get(relayUrl);
        if (s && s.fails > 0) {
            s.fails = 0;
            s.lastOk = Date.now();
            this._saveRelayStats();
        }
    },

    _getRelayStats() {
        if (!this._relayStatsMap) {
            this._relayStatsMap = new Map();
            try {
                const raw = JSON.parse(localStorage.getItem('nym_relay_stats') || '{}');
                for (const [url, s] of Object.entries(raw)) {
                    if (s && typeof s === 'object') this._relayStatsMap.set(url, s);
                }
            } catch (_) { }
        }
        return this._relayStatsMap;
    },

    _saveRelayStats() {
        if (this._relayStatsSaveTimer) return;
        this._relayStatsSaveTimer = setTimeout(() => {
            this._relayStatsSaveTimer = null;
            try {
                let stats = this._getRelayStats();
                // Keep the map bounded: drop the stalest entries past 200.
                if (stats.size > 200) {
                    const recency = (s) => Math.max(s.lastFail || 0, s.lastOk || 0);
                    stats = this._relayStatsMap = new Map(
                        [...stats.entries()]
                            .sort((a, b) => recency(b[1]) - recency(a[1]))
                            .slice(0, 200)
                    );
                }
                localStorage.setItem('nym_relay_stats', JSON.stringify(Object.fromEntries(stats)));
            } catch (_) { }
        }, 3000);
    },

    // True on the app's own domain, where the browser can reach wss://relay.nymchat.app directly.
    _d1Backed() {
        return !!(this._getApiHost && this._getApiHost()) && !!this.useRelayProxy;
    },

    _ensureChatViewMode() {
        if (this._cvActive || !this.settings || this.settings.chatViewMode !== 'columns') return;
        if (typeof this.applyChatViewMode === 'function') this.applyChatViewMode('columns');
    },

    _afterTransportSwitch() {
        this._ephSubscribedPks = new Set();
        this._lastResubscribeAt = 0;
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            this._poolSubscribe();
        } else {
            this._refreshEphemeralSubscriptions();
            this._resubscribeChannels();
            this._catchUpLiveGap();
        }
        this.retryPendingDMsOnReconnect();
        this._ensureChatViewMode();
        if (this._cvActive && typeof this._cvScheduleReconcile === 'function') this._cvScheduleReconcile(0);
        this.updateConnectionStatus();
    },

    _getApiHost() {
        try {
            const p = window.location.protocol;
            if (p === 'https:' || p === 'http:') return window.location.host || null;
        } catch (_) {}
        return null;
    },

    _fallbackToDirectConnections() {
        if (!this.useRelayProxy) return;

        this._stopPoolShardHealthCheck();

        for (const p of this.poolSockets) {
            p._closing = true;
            try { if (p.ws) p.ws.close(); } catch (_) { }
        }
        this.poolSockets = [];
        this.poolSocket = null;
        this.poolConnectedRelays = [];
        this.poolReady = false;
        this.relayPool.clear();
        if (this._poolRelayLastSeen) this._poolRelayLastSeen.clear();
        this._poolReconnecting = false;
        this._poolReconnectRetries = 0;

        this.useRelayProxy = false;
        this._poolFallbackActive = true;
        this._noteAutoFallback();
        console.warn('[NYM] Pool mode disabled, switching to direct relay connections');

        Promise.resolve(this.reconnectToBroadcastRelays()).catch(() => { }).then(() => {
            if (!this.useRelayProxy) this._afterTransportSwitch();
        });
        // Fallback sessions still need geo neighbourhoods for the geo-origin gate.
        this.ensureGeoRelayCoverage();
        if (this.currentGeohash) {
            this.connectToGeoRelays(this.currentGeohash);
        }

        this._schedulePoolReconnectInBackground();
    },

    _schedulePoolReconnectInBackground(immediate = false) {
        if (!this._poolFallbackActive) return;
        if (!this._getApiHost()) return;
        if (this._bgPoolReconnectInFlight) return;

        if (this._bgPoolReconnectTimer) {
            if (!immediate) return;
            clearTimeout(this._bgPoolReconnectTimer);
            this._bgPoolReconnectTimer = null;
        }

        if (typeof this._bgPoolReconnectAttempts !== 'number') {
            this._bgPoolReconnectAttempts = 0;
        }

        const tryRestore = () => {
            this._bgPoolReconnectTimer = null;
            if (!this._poolFallbackActive) return;
            if (!navigator.onLine) {
                this._bgPoolReconnectAttempts = 0;
                return;
            }

            this._bgPoolReconnectAttempts++;
            const wasRemoteApiFailed = this._remoteApiFailed;
            this._remoteApiFailed = false;
            this.useRelayProxy = true;
            this._poolConnecting = false;
            this._poolReconnecting = false;
            this._bgPoolReconnectInFlight = true;

            this._connectToRelayPool()
                .then(() => {
                    this._bgPoolReconnectInFlight = false;
                    if (this._userDirectMode) {
                        this._dropPoolSockets();
                        this.useRelayProxy = false;
                        return;
                    }
                    this._bgPoolReconnectAttempts = 0;
                    this._poolFallbackActive = false;
                    console.log('[NYM] Pool mode restored');
                    this._fallbackNoticeEpisode = false;
                    this._startPoolShardHealthCheck();
                    this.relayPool.forEach((relay) => {
                        try { if (relay.ws) relay.ws.close(); } catch (_) { }
                    });
                    this.relayPool.clear();
                    this._afterTransportSwitch();
                })
                .catch(() => {
                    this._bgPoolReconnectInFlight = false;
                    this._remoteApiFailed = wasRemoteApiFailed;
                    this.useRelayProxy = false;
                    if (!this._poolFallbackActive) return;
                    this._recoverFromEdgeChallenge().catch(() => { });
                    const expIdx = Math.min(this._bgPoolReconnectAttempts - 1, 4);
                    const base = Math.min(15000 * Math.pow(2, expIdx), 120000);
                    const delay = this._jitter(base);
                    this._bgPoolReconnectTimer = setTimeout(tryRestore, delay);
                });
        };

        const initialDelay = immediate ? 0 : 15000;
        this._bgPoolReconnectTimer = setTimeout(tryRestore, initialDelay);
    },

    fallbackNoticeEnabled() {
        try { return localStorage.getItem('nym_relay_fallback_notice_off') !== 'true'; } catch (_) { return true; }
    },

    setFallbackNoticeEnabled(on) {
        try {
            if (on) localStorage.removeItem('nym_relay_fallback_notice_off');
            else localStorage.setItem('nym_relay_fallback_notice_off', 'true');
        } catch (_) { }
        this._syncFallbackNoticeToggle();
    },

    _syncFallbackNoticeToggle() {
        if (typeof document === 'undefined') return;
        const sel = document.getElementById('fallbackNoticeToggle');
        if (sel) sel.checked = this.fallbackNoticeEnabled();
    },

    _noteAutoFallback() {
        if (this._userDirectMode || this._fallbackNoticeEpisode) return;
        this._fallbackNoticeEpisode = true;
        if (!this.fallbackNoticeEnabled() || typeof this.showToast !== 'function') return;
        const ui = (s) => (typeof this.uiText === 'function' ? this.uiText(s) : s);
        this.showToast(ui('Direct relay connections: the proxy was unreachable, so relays can see your IP address. The app will switch back when it recovers.'), {
            kind: 'info',
            action: ui("Don't show again"),
            onAction: () => this.setFallbackNoticeEnabled(false)
        });
    },

    _readUserDirectPref() {
        try { return localStorage.getItem('nym_relay_direct_mode') === 'true'; } catch (_) { return false; }
    },

    _writeUserDirectPref(direct) {
        try {
            if (direct) localStorage.setItem('nym_relay_direct_mode', 'true');
            else localStorage.removeItem('nym_relay_direct_mode');
        } catch (_) { }
    },

    _relayDirectAcknowledged() {
        try { return localStorage.getItem('nym_relay_direct_ack') === 'true'; } catch (_) { return false; }
    },

    _acknowledgeRelayDirect() {
        try { localStorage.setItem('nym_relay_direct_ack', 'true'); } catch (_) { }
    },

    _initRelayTransportMode() {
        this._syncFallbackNoticeToggle();
        const host = !!this._getApiHost();
        this._userDirectMode = host && this._readUserDirectPref();
        this.useRelayProxy = host && !this._userDirectMode;
    },

    canSwitchRelayTransport() {
        return !!this._getApiHost();
    },

    _stopPoolReconnectInBackground() {
        if (this._bgPoolReconnectTimer) {
            clearTimeout(this._bgPoolReconnectTimer);
            this._bgPoolReconnectTimer = null;
        }
        this._bgPoolReconnectAttempts = 0;
    },

    _dropPoolSockets(sockets) {
        const list = sockets || this.poolSockets.slice();
        for (const p of list) {
            p._closing = true;
            try { if (p.ws) p.ws.close(); } catch (_) { }
        }
        this.poolSockets = this.poolSockets.filter(p => !list.includes(p));
        if (!this.poolSockets.length) {
            this.poolSocket = null;
            this.poolConnectedRelays = [];
            this.poolReady = false;
            if (this._poolRelayLastSeen) this._poolRelayLastSeen.clear();
        }
    },

    async setUserDirectMode(direct) {
        if (!this.canSwitchRelayTransport()) return;
        this._writeUserDirectPref(!!direct);
        this._fallbackNoticeEpisode = !direct;
        if (direct) {
            this._userDirectMode = true;
            this._poolFallbackActive = false;
            this._stopPoolReconnectInBackground();
            if (this.useRelayProxy) await this._switchPoolToDirect();
            this.updateConnectionStatus();
            return;
        }
        this._userDirectMode = false;
        if (this.useRelayProxy) return;
        this._poolFallbackActive = true;
        this._schedulePoolReconnectInBackground(true);
    },

    relayTransportAction() {
        if (!this.canSwitchRelayTransport()) return null;
        if (this._userDirectMode) return 'proxy';
        if (this._poolFallbackActive) return 'retry';
        return 'direct';
    },

    relayTransportBusy() {
        return !!this._relayTransportSwitching || (this._poolFallbackActive === true && this._bgPoolReconnectInFlight === true);
    },

    async requestRelayTransportToggle() {
        if (this.relayTransportBusy()) return false;
        const action = this.relayTransportAction();
        if (action === 'retry') {
            this.retryProxyNow();
            return true;
        }
        if (action !== 'direct' && action !== 'proxy') return false;
        if (action === 'direct' && !this._relayDirectAcknowledged()) {
            const ui = (s) => (typeof this.uiText === 'function' ? this.uiText(s) : s);
            const message = ui("Nymchat will disconnect from the relay pool proxy and connect to each relay directly. Images, videos, voice messages, avatars, custom emoji, GIFs and link previews will also load straight from the sites that host them, and uploads will go straight to them. Relays and those sites will see your IP address, and the proxy's spam filtering won't apply. You can switch back anytime from Network Stats.");
            let ok;
            if (typeof window.showAppConfirm === 'function') {
                const res = await window.showAppConfirm(message, { title: ui('Use direct connections?'), okLabel: ui('Use direct') });
                ok = (res && typeof res === 'object') ? res.confirmed : res;
            } else {
                ok = typeof window.confirm === 'function' ? window.confirm(message) : true;
            }
            if (!ok) return false;
            this._acknowledgeRelayDirect();
        }
        this._relayTransportSwitching = true;
        try {
            await this.setUserDirectMode(action === 'direct');
        } finally {
            this._relayTransportSwitching = false;
        }
        return true;
    },

    retryProxyNow() {
        if (this._userDirectMode || !this._poolFallbackActive || this._bgPoolReconnectInFlight) return;
        this._schedulePoolReconnectInBackground(true);
    },

    async _switchPoolToDirect() {
        if (!this.useRelayProxy) return;
        this._stopPoolShardHealthCheck();
        const old = this.poolSockets.slice();
        const oldWs = new Set(old.map(p => p.ws).filter(Boolean));
        if (this.poolSocket) oldWs.add(this.poolSocket);
        for (const p of old) p._draining = true;
        for (const [url, entry] of [...this.relayPool]) {
            if (entry && oldWs.has(entry.ws)) this.relayPool.delete(url);
        }
        if (this._poolRelayLastSeen) this._poolRelayLastSeen.clear();
        this._poolReconnecting = false;
        this._poolReconnectRetries = 0;
        this.useRelayProxy = false;
        try { await this.reconnectToBroadcastRelays(); } catch (_) { }
        this.ensureGeoRelayCoverage();
        if (this.currentGeohash) this.connectToGeoRelays(this.currentGeohash);
        this._dropPoolSockets(old);
        for (const [url, entry] of [...this.relayPool]) {
            if (entry && oldWs.has(entry.ws)) this.relayPool.delete(url);
        }
        if (!this.useRelayProxy) this._afterTransportSwitch();
    },

    _getProxiedRelayUrl(relayUrl) {
        const host = this._getApiHost();
        if (!this.useRelayProxy || !host) return relayUrl;
        return `wss://${host}/api/relay?relay=${encodeURIComponent(relayUrl)}`;
    },

    _getRelayPoolUrl() {
        const host = this._getApiHost();
        if (!host) return null;
        return `wss://${host}/api/relay-pool`;
    },

    _isAnyPoolOpen() {
        return this.poolSockets.some(p => p.ws && p.ws.readyState === WebSocket.OPEN);
    },

    _isAnyWorkerPoolOpen() {
        return this.poolSockets.some(p => p.ws && p.ws.readyState === WebSocket.OPEN);
    },

    // Stable role-keyed shard ids so membership doesn't reshuffle as geo/discovered relays load.
    _shardRelaysByRole(allRelays, geoRelayUrls, dmRelays) {
        if (this.settings && this.settings.groupChatPMOnlyMode) {
            allRelays = this.defaultRelays;
            geoRelayUrls = [];
        }
        const blocked = new Set(['wss://relay.nosflare.com', 'wss://relay.nostraddress.com', 'wss://nostr-server-production.up.railway.app']);
        const permanent = this._permanentBlacklist || new Set();
        const isValid = (url) => typeof url === 'string' && url.startsWith('wss://') && !blocked.has(url) && !permanent.has(url);

        const geoSet = new Set((geoRelayUrls || []).filter(isValid));
        const appRelay = this.appRelay;
        const appValid = appRelay && isValid(appRelay);

        // Critical = default relays (+ DM relays), excluding the app relay.
        const critical = [...new Set([...this.defaultRelays, ...(dmRelays || [])])]
            .filter(url => isValid(url) && url !== appRelay);

        const reservedSet = new Set(critical);
        if (appValid) reservedSet.add(appRelay);

        const geo = [...geoSet].filter(url => !reservedSet.has(url));

        const geoForDiscovered = new Set(geo);
        const claimedCanon = new Set([...reservedSet, ...geoForDiscovered].map(u => this._canonicalRelayUrl(u)));
        const seenDiscoveredCanon = new Set();
        const discovered = [...new Set(allRelays || [])].filter(url => {
            if (!isValid(url) || reservedSet.has(url) || geoForDiscovered.has(url)) return false;
            const canon = this._canonicalRelayUrl(url);
            if (claimedCanon.has(canon) || seenDiscoveredCanon.has(canon)) return false;
            seenDiscoveredCanon.add(canon);
            return true;
        });

        const chunkArray = (arr, size) => {
            const chunks = [];
            for (let i = 0; i < arr.length; i += size) chunks.push(arr.slice(i, i + size));
            return chunks;
        };

        const size = this.RELAYS_PER_WORKER || 50;
        const shards = [];

        // Dedicated app relay shard so the default relays always have a live socket via the proxy.
        if (appValid) {
            shards.push({ id: 'app-0', role: 'critical', relays: [appRelay], dmRelays: [appRelay] });
        }

        const criticalDmRelays = (dmRelays || []).filter(url => isValid(url) && url !== appRelay);
        chunkArray(critical, size).forEach((chunk, i) => {
            shards.push({ id: `critical-${i}`, role: 'critical', relays: chunk, dmRelays: i === 0 ? criticalDmRelays : [] });
        });

        chunkArray(geo, size).forEach((chunk, i) => {
            shards.push({ id: `geo-${i}`, role: 'geo', relays: chunk, dmRelays: [] });
        });

        chunkArray(discovered, size).forEach((chunk, i) => {
            shards.push({ id: `discovered-${i}`, role: 'discovered', relays: chunk, dmRelays: [] });
        });

        const kept = NymRelayBlock.filterShards(shards, this._blockedRelaySet());
        if (kept.length === 0) kept.push({ id: 'critical-0', role: 'critical', relays: [], dmRelays: [] });
        return kept;
    },
    _poolAddMessageListener(handler) {
        for (const p of this.poolSockets) {
            if (p.ws) p.ws.addEventListener('message', handler);
        }
    },

    _poolRemoveMessageListener(handler) {
        for (const p of this.poolSockets) {
            if (p.ws) {
                try { p.ws.removeEventListener('message', handler); } catch (_) { }
            }
        }
    },

    async _edgeChallengePending() {
        if (!this._getApiHost()) return false;
        try {
            const resp = await fetch('/bundle-hash.txt?t=' + Date.now(), { cache: 'no-store', credentials: 'same-origin' });
            const challenged = resp.headers.get('cf-mitigated') === 'challenge';
            this._edgeHttpPasses = !challenged && resp.ok;
            return challenged;
        } catch (_) {
            return false;
        }
    },

    _reloadForEdgeChallenge() {
        const key = 'nym_edge_challenge_reloads';
        const now = Date.now();
        let times = [];
        try { times = JSON.parse(sessionStorage.getItem(key) || '[]'); } catch (_) { times = []; }
        if (!Array.isArray(times)) times = [];
        times = times.filter((t) => typeof t === 'number' && now - t < EDGE_CHALLENGE_RELOAD_WINDOW_MS);
        if (times.length && now - times[times.length - 1] < EDGE_CHALLENGE_RELOAD_MIN_MS) return false;
        if (times.length >= EDGE_CHALLENGE_RELOAD_MAX) return false;
        times.push(now);
        try { sessionStorage.setItem(key, JSON.stringify(times)); } catch (_) { }
        location.reload();
        return true;
    },

    async _logEdgeTrace() {
        try {
            const resp = await fetch('/cdn-cgi/trace', { cache: 'no-store', credentials: 'same-origin' });
            const text = await resp.text();
            const pick = (k) => (text.match(new RegExp('^' + k + '=(.*)$', 'm')) || [])[1] || '-';
            console.warn(`[NYM] This page reaches the edge as ip=${pick('ip')} over ${pick('http')} (colo ${pick('colo')}); compare with the address on the refused socket's event.`);
        } catch (_) { }
    },

    _noteEdgeResponse(resp) {
        if (!resp || resp.status !== 403 || !resp.headers || typeof resp.headers.get !== 'function') return resp;
        if (resp.headers.get('cf-mitigated') !== 'challenge') return resp;
        const now = Date.now();
        if (this._edgeChallengeNotedAt && now - this._edgeChallengeNotedAt < EDGE_CHALLENGE_NOTE_MIN_MS) return resp;
        this._edgeChallengeNotedAt = now;
        this._recoverFromEdgeChallenge().catch(() => { });
        return resp;
    },

    _noteProxiedMediaFailure() {
        const now = Date.now();
        if (this._edgeChallengeNotedAt && now - this._edgeChallengeNotedAt < EDGE_CHALLENGE_NOTE_MIN_MS) return;
        this._edgeChallengeNotedAt = now;
        this._recoverFromEdgeChallenge().catch(() => { });
    },

    async _edgeFetch(url, opts) {
        const resp = await fetch(url, opts);
        return this._noteEdgeResponse(resp);
    },

    _proxyUnreachable(errOrResponse) {
        if (!errOrResponse) return false;
        if (typeof errOrResponse.status !== 'number') {
            return errOrResponse.name === 'TypeError' || errOrResponse.name === 'TimeoutError';
        }
        const status = errOrResponse.status;
        if (status !== 502 && status !== 503 && (status < 520 || status > 527)) return false;
        const headers = errOrResponse.headers;
        const type = (headers && typeof headers.get === 'function' && headers.get('content-type')) || '';
        return !/^\s*(application\/([a-z0-9.-]+\+)?json|text\/plain)\b/i.test(type);
    },

    async _recoverFromEdgeChallenge() {
        if (!(await this._edgeChallengePending())) return false;
        await new Promise((r) => setTimeout(r, EDGE_CHALLENGE_CONFIRM_MS));
        if (!(await this._edgeChallengePending())) return false;
        return this._reloadForEdgeChallenge();
    },

    // Schedule a pool reconnection with exponential backoff, preventing concurrent attempts.
    _schedulePoolReconnect() {
        if (this._poolReconnecting) return;
        if (this.initialConnectionInProgress || this._poolConnecting) return;
        if (!this.useRelayProxy) return;
        if (!this._getApiHost()) return;

        const now = Date.now();
        if (this._lastPoolReconnectSchedule && now - this._lastPoolReconnectSchedule < 2000) return;
        this._lastPoolReconnectSchedule = now;

        const attempt = (retries) => {
            if (this._isAnyWorkerPoolOpen()) {
                this._poolReconnecting = false;
                return;
            }
            if (!navigator.onLine) {
                // Wait for the 'online' event to trigger reconnection instead.
                this._poolReconnecting = false;
                return;
            }

            const baseDelay = Math.min(3000 * Math.pow(2, retries), 30000);
            const delay = Math.floor(baseDelay * (0.5 + Math.random() * 0.5));
            this.updateConnectionStatus(retries > 0
                ? `Reconnecting (attempt ${retries + 1})...`
                : 'Reconnecting...');

            setTimeout(() => {
                // Another path may have reconnected while we waited.
                if (this._isAnyWorkerPoolOpen()) {
                    this._poolReconnecting = false;
                    return;
                }
                if (this.initialConnectionInProgress || this._poolConnecting) {
                    this._poolReconnecting = false;
                    return;
                }
                this._connectToRelayPool()
                    .then(() => {
                        this._poolReconnecting = false;
                        this._poolReconnectRetries = 0;
                        this._startPoolShardHealthCheck();
                        this._poolSubscribe();
                        this.retryPendingDMsOnReconnect();
                    })
                    .catch(async (err) => {
                        if (err && err.inProgress) {
                            attempt(retries);
                            return;
                        }
                        if (retries < 1) {
                            attempt(retries + 1);
                        } else {
                            this._poolReconnecting = false;
                            this._poolReconnectRetries = 0;
                            if (await this._recoverFromEdgeChallenge()) return;
                            if (this._edgeHttpPasses === true) {
                                console.warn('[NYM] The edge refuses the pool socket while plain requests pass. The clearance is not being honoured for WebSocket upgrades; check the Security Events row for /api/relay-pool.');
                                this._logEdgeTrace();
                            }
                            // 2 consecutive failures — fall back to direct relay connections
                            console.warn('[NYM] Relay pool failed after 2 attempts, falling back to direct connections');
                            this._fallbackToDirectConnections();
                        }
                    });
            }, delay);
        };

        this._poolReconnecting = true;
        attempt(this._poolReconnectRetries || 0);
    },

    // Retries until reconnected or no longer needed; _ensureAllShardsConnected is the safety net.
    _reconnectPoolShard(shard) {
        if (!this.useRelayProxy) return;
        if (!this._getApiHost()) return;
        const shardId = shard.id;

        if (!this._shardReconnecting) this._shardReconnecting = new Set();
        if (!this._shardReconnectAt) this._shardReconnectAt = new Map();
        // Self-heal a stuck flag: a stale timestamp lets a fresh call take over.
        if (this._shardReconnecting.has(shardId)) {
            const startedAt = this._shardReconnectAt.get(shardId) || 0;
            if (Date.now() - startedAt < 90000) return;
        }
        this._shardReconnecting.add(shardId);

        const attempt = (retries) => {
            this._shardReconnectAt.set(shardId, Date.now());
            const existing = this.poolSockets.find(p => p.id === shardId);
            if (existing && existing.ws && existing.ws.readyState === WebSocket.OPEN) {
                this._shardReconnecting.delete(shardId);
                return;
            }
            if (!this.useRelayProxy) {
                this._shardReconnecting.delete(shardId);
                return;
            }

            const baseDelay = Math.min(3000 * Math.pow(1.7, retries), 60000);
            const delay = Math.floor(baseDelay * (0.7 + Math.random() * 0.3));
            const fire = () => {
                const stillDown = this.poolSockets.find(p => p.id === shardId);
                if (stillDown && stillDown.ws && stillDown.ws.readyState === WebSocket.OPEN) {
                    this._shardReconnecting.delete(shardId);
                    return;
                }
                const pending = this._poolShardConnectPendingMs(stillDown);
                if (pending > 0) {
                    this._shardReconnectAt.set(shardId, Date.now());
                    setTimeout(fire, pending + 250);
                    return;
                }
                if (!this.useRelayProxy) {
                    this._shardReconnecting.delete(shardId);
                    return;
                }
                if (!navigator.onLine) {
                    attempt(retries + 1);
                    return;
                }

                this._connectSinglePoolWorker(shard)
                    .then(() => {
                        this._shardReconnecting.delete(shardId);
                        this._poolSubscribeOnWorker(shard.id);
                    })
                    .catch(() => {
                        // The health check stops us if the shard is no longer expected.
                        attempt(retries + 1);
                    });
            };
            setTimeout(fire, delay);
        };

        attempt(0);
    },

    _poolShardConnectPendingMs(entry) {
        if (!entry || !entry.ws || entry.ws.readyState !== WebSocket.CONNECTING) return 0;
        return Math.max(0, POOL_CONNECT_TIMEOUT_MS - (Date.now() - (entry._connectStartedAt || 0)));
    },

    _computeExpectedShards() {
        let geoRelayUrls = [];
        if (this.settings && this.settings.lowDataMode) {
            geoRelayUrls = [...this.currentGeoRelays];
        } else {
            geoRelayUrls = (this.geoRelays || []).map(r => r.url || r).filter(Boolean);
            for (const url of this.currentGeoRelays) {
                if (!geoRelayUrls.includes(url)) geoRelayUrls.unshift(url);
            }
        }
        return this._shardRelaysByRole([...this.allRelayUrls], geoRelayUrls, this.defaultRelays);
    },

    // Reconnect any expected shard that's missing, not OPEN, or a "zombie".
    _ensureAllShardsConnected() {
        if (!this.useRelayProxy) return;
        if (!this._getApiHost()) return;
        if (!navigator.onLine) return;
        if (!this._isAnyPoolOpen()) return;

        const ZOMBIE_MS = 45000;
        const now = Date.now();
        const expectedShards = this._computeExpectedShards();
        for (const shard of expectedShards) {
            const existing = this.poolSockets.find(p => p.id === shard.id);
            const isOpen = existing && existing.ws && existing.ws.readyState === WebSocket.OPEN;
            if (!isOpen) {
                this._reconnectPoolShard(shard);
                continue;
            }

            if (shard.relays && shard.relays.length > 0) {
                const healthy = existing.connectedRelays && existing.connectedRelays.length > 0;
                if (healthy) {
                    existing._healthyAt = now;
                } else if (existing._healthyAt && now - existing._healthyAt > ZOMBIE_MS) {
                    this._noteLiveGap(existing._healthyAt, true);
                    existing._closing = true;
                    try { existing.ws.close(); } catch (_) { }
                    existing.ws = null;
                    if (this._shardReconnecting) this._shardReconnecting.delete(shard.id);
                    this._reconnectPoolShard(shard);
                    continue;
                }
                if (this._poolShardDeaf(existing, now)) {
                    try { existing.ws.close(); } catch (_) { }
                }
            }
        }
    },

    _poolShardDeaf(p, now) {
        if (!this._poolProbeFails) this._poolProbeFails = new Map();
        if (p._probe) {
            if (now - p._probe.at < POOL_PROBE_TIMEOUT_MS) return false;
            p._probe = null;
            this._poolProbeFails.set(p.id, (this._poolProbeFails.get(p.id) || 0) + 1);
            return true;
        }
        const fails = this._poolProbeFails.get(p.id) || 0;
        const quiet = Math.min(POOL_QUIET_MS * Math.pow(2, fails), POOL_PROBE_BACKOFF_MAX_MS);
        if (now - Math.max(p._upstreamAt || 0, p._openedAt || 0) < quiet) return false;
        this._sendPoolProbe(p, now);
        return false;
    },

    _sendPoolProbe(p, now) {
        const bytes = new Uint8Array(32);
        crypto.getRandomValues(bytes);
        const probeId = Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
        p._probe = { id: 'nym-live-' + probeId.slice(0, 12), at: now };
        this._safeWsSend(p.ws, JSON.stringify(['REQ', p._probe.id, { ids: [probeId], limit: 1 }]), { critical: true });
    },

    _probePoolsNow() {
        if (!this.useRelayProxy || !Array.isArray(this.poolSockets)) return;
        const now = Date.now();
        let sent = false;
        for (const p of this.poolSockets) {
            if (!p || !p.ws || p.ws.readyState !== WebSocket.OPEN) continue;
            if (p._probe) {
                sent = true;
                continue;
            }
            if (now - Math.max(p._upstreamAt || 0, p._openedAt || 0) < POOL_RESUME_FRESH_MS) continue;
            this._sendPoolProbe(p, now);
            sent = true;
        }
        if (!sent) return;
        if (this._poolProbeCheckTimer) clearTimeout(this._poolProbeCheckTimer);
        this._poolProbeCheckTimer = setTimeout(() => {
            this._poolProbeCheckTimer = null;
            this._ensureAllShardsConnected();
        }, POOL_PROBE_TIMEOUT_MS + 250);
    },

    _settlePoolProbe(p) {
        const id = p._probe && p._probe.id;
        p._probe = null;
        p._upstreamAt = Date.now();
        if (this._poolProbeFails) this._poolProbeFails.delete(p.id);
        if (id) this._safeWsSend(p.ws, JSON.stringify(['CLOSE', id]), { critical: true });
    },

    _startPoolShardHealthCheck() {
        if (this._poolShardHealthTimer) clearInterval(this._poolShardHealthTimer);
        this._poolShardHealthTimer = setInterval(() => {
            this._ensureAllShardsConnected();
        }, 15000);
    },

    _stopPoolShardHealthCheck() {
        if (this._poolShardHealthTimer) {
            clearInterval(this._poolShardHealthTimer);
            this._poolShardHealthTimer = null;
        }
    },

    _connectToRelayPool() {
        if (this._poolConnecting || this.poolSockets.some(p => p.ws && p.ws.readyState === WebSocket.CONNECTING)) {
            return Promise.reject(Object.assign(new Error('Connection already in progress'), { inProgress: true }));
        }
        this._poolConnecting = true;

        let geoRelayUrls = [];

        if (this.settings && this.settings.lowDataMode) {
            // Low data: only defaults + DM relays (geo added on demand).
            geoRelayUrls = [];
        } else {
            geoRelayUrls = (this.geoRelays || []).map(r => r.url || r).filter(Boolean);
        }

        const shards = this._shardRelaysByRole(
            [...this.allRelayUrls],
            geoRelayUrls,
            this.defaultRelays
        );

        // Mark old sockets as intentionally closed to prevent reconnect loops.
        const oldSockets = this.poolSockets;
        this.poolSockets = [];
        this.poolSocket = null;
        for (const p of oldSockets) {
            p._closing = true;
            try { if (p.ws) p.ws.close(); } catch (_) { }
        }

        if (shards.length === 0) {
            this._poolConnecting = false;
            return Promise.reject(new Error('No relay shards to connect'));
        }

        const [firstShard, ...restShards] = shards;

        return new Promise((resolve, reject) => {
            this._connectSinglePoolWorker(firstShard).then(() => {
                this._poolConnecting = false;
                this.poolReady = true;
                this.connected = true;
                this._syncLegacyPoolSocket();
                resolve();
                if (restShards.length > 0) this._connectRemainingShards(restShards);
            }).catch((err) => {
                this._poolConnecting = false;
                reject(err);
            });
        });
    },

    _connectRemainingShards(shards) {
        const STAGGER_MS = 250;
        shards.forEach((shard, i) => {
            setTimeout(() => {
                if (!this.useRelayProxy) return;
                const existing = this.poolSockets.find(p => p.id === shard.id);
                if (existing && existing.ws && existing.ws.readyState === WebSocket.OPEN) return;
                if (this._poolShardConnectPendingMs(existing) > 0) return;
                this._connectSinglePoolWorker(shard)
                    .then(() => {
                        this._poolSubscribeOnWorker(shard.id);
                        this._resubscribeChannels();
                    })
                    .catch(() => {
                        this._reconnectPoolShard(shard);
                    });
            }, (i + 1) * STAGGER_MS);
        });
    },

    _connectSinglePoolWorker(shard) {
        return new Promise((resolve, reject) => {
            const url = this._getRelayPoolUrl();
            if (!url) return reject(new Error('Relay proxy unavailable on this host'));
            const ws = new WebSocket(url);

            const poolEntry = {
                id: shard.id,
                ws: ws,
                role: shard.role,
                relays: shard.relays,
                dmRelays: shard.dmRelays || [],
                connectedRelays: [],
                lastMessage: Date.now(),
                _connectStartedAt: Date.now()
            };

            const existingIdx = this.poolSockets.findIndex(p => p.id === shard.id);
            if (existingIdx >= 0) {
                const old = this.poolSockets[existingIdx];
                old._closing = true;
                try { if (old.ws) old.ws.close(); } catch (_) { }
                this.poolSockets[existingIdx] = poolEntry;
            } else {
                this.poolSockets.push(poolEntry);
            }

            const timeout = setTimeout(() => {
                if (ws.readyState !== WebSocket.OPEN) {
                    try { ws.close(); } catch (_) { }
                    reject(new Error(`Pool worker ${shard.id} connection timeout`));
                }
            }, POOL_CONNECT_TIMEOUT_MS);

            ws.onopen = () => {
                clearTimeout(timeout);
                wasOpen = true;

                ws.send(JSON.stringify(['RELAYS', {
                    relays: shard.relays || [],
                    dmRelays: shard.dmRelays || []
                }]));

                if (this._relayUnsupportedKinds && this._relayUnsupportedKinds.size > 0) {
                    const payload = {};
                    for (const [relay, kinds] of this._relayUnsupportedKinds) {
                        payload[relay] = [...kinds];
                    }
                    try { ws.send(JSON.stringify(['KIND_BLACKLIST', payload])); } catch (_) { }
                }

                poolEntry.lastMessage = Date.now();
                poolEntry._healthyAt = Date.now();
                poolEntry._openedAt = Date.now();
                this._syncLegacyPoolSocket();
                this._flushHeldEvents();

                resolve();
            };

            ws.onmessage = (event) => {
                try {
                    const dataLen = typeof event.data === 'string' ? event.data.length : (event.data.byteLength || 0);
                    this.relayStats.bytesReceived += dataLen;
                    poolEntry.lastMessage = Date.now();

                    const msg = JSON.parse(event.data);
                    if (!Array.isArray(msg)) return;

                    const msgType = msg[0];

                    if (msgType === 'POOL:PING') {
                        poolEntry.lastMessage = Date.now();
                        return;
                    }

                    if (msgType === 'POOL:RETRACT') {
                        if (typeof msg[1] === 'string' && /^[0-9a-f]{64}$/.test(msg[1]) && typeof this._applyVerifiedDeletion === 'function') {
                            this._applyVerifiedDeletion(msg[1]);
                        }
                        return;
                    }

                    if (msgType === 'POOL:RELAY_BAN') {
                        const banUrl = msg[1];
                        const banReason = typeof msg[2] === 'string' ? msg[2].slice(0, 300) : 'banned';
                        if (msg.length <= 3 && typeof banUrl === 'string' && banUrl.startsWith('wss://') && banUrl.length <= 512) {
                            this._permanentlyBlacklistRelay(banUrl, banReason);
                        }
                        return;
                    }

                    if (msgType === 'POOL:SHARDS') {
                        return;
                    }

                    if (msgType === 'EVENT' || msgType === 'EOSE' || msgType === 'OK' || msgType === 'POOL:SEEN') {
                        poolEntry._upstreamAt = Date.now();
                    }

                    if ((msgType === 'EOSE' || msgType === 'CLOSED') && poolEntry._probe && msg[1] === poolEntry._probe.id) {
                        this._settlePoolProbe(poolEntry);
                        return;
                    }

                    if (msgType === 'POOL:STATUS') {
                        if (poolEntry._draining) return;
                        const status = msg[1];
                        if (!status || typeof status !== 'object' || Array.isArray(status)) return;
                        poolEntry.connectedRelays = Array.isArray(status.connected)
                            ? status.connected.filter((u) => typeof u === 'string' && u.startsWith('wss://'))
                            : [];
                        if (poolEntry.connectedRelays.length > 0) poolEntry._healthyAt = Date.now();
                        poolEntry.badgeGate = typeof status.badgeGate === 'string' ? status.badgeGate : null;
                        poolEntry.unbadged = Number(status.unbadged) || 0;

                        if (status.latency) {
                            for (const [url, ms] of Object.entries(status.latency)) {
                                this.relayStats.latencyPerRelay.set(url, ms);
                            }
                        }

                        // Per-relay event counts are tracked post-dedup in handleRelayMessage.

                        this._mergePoolStatus();
                    } else if (msgType === 'EVENT') {
                        const evt = msg[2];
                        if (evt && typeof evt.created_at === 'number' && evt.created_at > 0) {
                            this._updateShardLastSeen(poolEntry.id, evt.created_at);
                            if (typeof evt.kind === 'number') {
                                if (!this._poolKindNewest) this._poolKindNewest = new Map();
                                if (evt.created_at > (this._poolKindNewest.get(evt.kind) || 0)) {
                                    this._poolKindNewest.set(evt.kind, evt.created_at);
                                }
                            }
                        }
                        this.handleRelayMessage(msg, 'relay-pool');
                    } else {
                        this.handleRelayMessage(msg, 'relay-pool');
                    }
                } catch {
                }
            };

            let wasOpen = false;
            let errorRejected = false;

            ws.onclose = () => {
                clearTimeout(timeout);

                // Skip reconnect logic if this socket was intentionally closed.
                if (poolEntry._closing) return;

                // Never opened: the caller's retry loop handles initial failures.
                if (!wasOpen) {
                    if (!errorRejected) reject(new Error(`Pool worker ${shard.id} closed before open`));
                    return;
                }

                this._noteLiveGap(poolEntry._upstreamAt, true);
                if (!this._reconnectingShards) this._reconnectingShards = new Set();
                this._reconnectingShards.add(shard.id);
                if (this._poolEventBaselines) this._poolEventBaselines.delete(shard.id);

                poolEntry.connectedRelays = [];
                poolEntry.ws = null;
                this._mergePoolStatus();
                this._syncLegacyPoolSocket();

                // If all workers are down, rebuild the pool; the direct app relay staying up must not suppress this.
                if (!this._isAnyWorkerPoolOpen()) {
                    this.poolReady = false;
                    this.connected = false;
                    this.updateConnectionStatus('Disconnected');
                    this._schedulePoolReconnect();
                } else {
                    this._reconnectPoolShard(shard);
                }
            };

            ws.onerror = () => {
                clearTimeout(timeout);
                errorRejected = true;
                reject(new Error(`Pool worker ${shard.id} connection error`));
            };
        });
    },



    _mergePoolStatus() {
        const allConnected = new Set();
        for (const p of this.poolSockets) {
            if (p.connectedRelays) {
                for (const url of p.connectedRelays) allConnected.add(url);
            }
        }
        this.poolConnectedRelays = [...allConnected];

        if (!this._poolRelayLastSeen) this._poolRelayLastSeen = new Map();
        const now = Date.now();
        const graceMs = 15000;

        for (const url of allConnected) {
            this._poolRelayLastSeen.set(url, now);
        }

        // Anything seen within the grace window stays as connected or recently-disconnected.
        for (const url of [...this._poolRelayLastSeen.keys()]) {
            const lastSeen = this._poolRelayLastSeen.get(url);
            const stillConnected = allConnected.has(url);
            if (!stillConnected && (now - lastSeen) > graceMs) {
                this._poolRelayLastSeen.delete(url);
                this.relayPool.delete(url);
                continue;
            }
            const existing = this.relayPool.get(url);
            if (stillConnected) {
                if (existing) {
                    existing.status = 'connected';
                } else {
                    this.relayPool.set(url, {
                        ws: this.poolSocket,
                        type: 'relay',
                        status: 'connected',
                        connectedAt: now
                    });
                }
            } else if (existing) {
                existing.status = 'reconnecting';
            }
        }

        for (const url of [...this.relayPool.keys()]) {
            if (!this._poolRelayLastSeen.has(url)) {
                const entry = this.relayPool.get(url);
                // Direct-mode entries have a ws other than the pool socket; leave those alone.
                if (entry && entry.type === 'relay' && entry.ws === this.poolSocket) {
                    this.relayPool.delete(url);
                }
            }
        }

        this.updateConnectionStatus();
    },

    // Legacy this.poolSocket points to the first open socket for external compat.
    _syncLegacyPoolSocket() {
        const open = this.poolSockets.find(p => p.ws && p.ws.readyState === WebSocket.OPEN);
        this.poolSocket = open ? open.ws : null;
    },

    // Strict relays (Pocket) reject filters with duplicate tag values.
    _normalizeFilters(filters) {
        if (!Array.isArray(filters)) return filters;
        const hexOnlyKeys = new Set(['ids', 'authors', '#e', '#p']);
        const seen = new Set();
        const out = [];
        for (const f of filters) {
            if (!f || typeof f !== 'object') continue;
            const cleaned = {};
            let invalid = false;
            for (const key of Object.keys(f)) {
                const v = f[key];
                if (Array.isArray(v)) {
                    let arr = [...new Set(v)];
                    if (hexOnlyKeys.has(key)) {
                        arr = arr.filter(s => this._isNostrHex64(s));
                        if (arr.length === 0) { invalid = true; break; }
                    }
                    cleaned[key] = arr;
                } else {
                    cleaned[key] = v;
                }
            }
            if (invalid) continue;
            const sig = JSON.stringify(
                Object.keys(cleaned).sort().reduce((acc, k) => {
                    const v = cleaned[k];
                    acc[k] = Array.isArray(v) ? [...v].sort() : v;
                    return acc;
                }, {})
            );
            if (seen.has(sig)) continue;
            seen.add(sig);
            out.push(cleaned);
        }
        return out;
    },

    _normalizeReqPayload(data) {
        if (!Array.isArray(data)) return data;
        if (data[0] === 'REQ') {
            const subId = data[1];
            const filters = data.slice(2);
            if (subId) this._trackSubKinds(subId, filters);
            return ['REQ', subId, ...this._normalizeFilters(filters)];
        }
        return data;
    },

    _trackSubKinds(subId, filters) {
        if (!this._subKinds) this._subKinds = new Map();
        const kinds = new Set();
        for (const f of filters) {
            if (f && Array.isArray(f.kinds)) {
                for (const k of f.kinds) if (typeof k === 'number') kinds.add(k);
            }
        }
        if (kinds.size === 0) return;
        if (this._subKinds.has(subId)) this._subKinds.delete(subId);
        this._subKinds.set(subId, kinds);
        if (this._subKinds.size > 2000) {
            const firstKey = this._subKinds.keys().next().value;
            this._subKinds.delete(firstKey);
        }
    },

    _extractUnsupportedKind(reason) {
        if (typeof reason !== 'string') return null;
        let m = reason.match(/\bNIP[\s\-_:]*(\d+)\b/i);
        if (m) return parseInt(m[1], 10);
        m = reason.match(/\bkinds?[\s\-_:]*(\d+)\b/i);
        if (m) return parseInt(m[1], 10);
        return null;
    },

    _recordUnsupportedKindRejection(relayUrl, subId, reason) {
        if (!relayUrl || relayUrl === 'relay-pool' || !subId) return;
        const specific = this._extractUnsupportedKind(reason);
        let kinds;
        if (specific !== null) {
            kinds = new Set([specific]);
        } else {
            kinds = this._subKinds && this._subKinds.get(subId);
        }
        if (!kinds || kinds.size === 0) return;
        if (!this._relayUnsupportedKinds) this._relayUnsupportedKinds = new Map();
        let set = this._relayUnsupportedKinds.get(relayUrl);
        if (!set) {
            set = new Set();
            this._relayUnsupportedKinds.set(relayUrl, set);
        }
        let added = false;
        for (const k of kinds) {
            if (!set.has(k)) { set.add(k); added = true; }
        }
        if (added) this._sendKindBlacklistToWorkers();
    },

    _trackSentEventKind(message) {
        if (!Array.isArray(message) || message[0] !== 'EVENT') return;
        const evt = message[1];
        if (!evt || typeof evt.id !== 'string' || typeof evt.kind !== 'number') return;
        if (!this._sentEventKinds) this._sentEventKinds = new Map();
        if (this._sentEventKinds.has(evt.id)) this._sentEventKinds.delete(evt.id);
        this._sentEventKinds.set(evt.id, evt.kind);
        if (this._sentEventKinds.size > 1000) {
            const firstKey = this._sentEventKinds.keys().next().value;
            this._sentEventKinds.delete(firstKey);
        }
    },

    _recordEventKindRejection(relayUrl, eventId) {
        if (!relayUrl || relayUrl === 'relay-pool' || !eventId) return;
        const kind = this._sentEventKinds && this._sentEventKinds.get(eventId);
        if (typeof kind !== 'number') return;
        if (!this._relayUnsupportedKinds) this._relayUnsupportedKinds = new Map();
        let set = this._relayUnsupportedKinds.get(relayUrl);
        if (!set) {
            set = new Set();
            this._relayUnsupportedKinds.set(relayUrl, set);
        }
        if (!set.has(kind)) {
            set.add(kind);
            this._sendKindBlacklistToWorkers();
        }
    },

    _sendKindBlacklistToWorkers() {
        if (!this.useRelayProxy || !this._isAnyPoolOpen()) return;
        if (!this._relayUnsupportedKinds || this._relayUnsupportedKinds.size === 0) return;
        const payload = {};
        for (const [relay, kinds] of this._relayUnsupportedKinds) {
            payload[relay] = [...kinds];
        }
        const msg = JSON.stringify(['KIND_BLACKLIST', payload]);
        for (const p of this.poolSockets) {
            this._safeWsSend(p.ws, msg, { critical: true });
        }
    },

    _poolSend(data) {
        if (Array.isArray(data) && data[0] === 'REQ') {
            data = this._normalizeReqPayload(data);
        }
        const msg = typeof data === 'string' ? data : JSON.stringify(data);
        const critical = Array.isArray(data) && (data[0] === 'EVENT' || data[0] === 'DM_EVENT' || data[0] === 'GEO_EVENT' || data[0] === 'CLOSE');
        if (Array.isArray(data) && (data[0] === 'EVENT' || data[0] === 'GEO_EVENT')) this._dmOutboxCharge(1);
        for (const p of this.poolSockets) {
            this._safeWsSend(p.ws, msg, { critical });
        }
    },

    // Role scoping is a no-op now; kept as an alias for existing callers.
    _poolSendToRole(role, data) {
        this._poolSend(data);
    },

    _poolSubscribeOnWorker(shardId) {
        const p = this.poolSockets.find(w => w.id === shardId);
        if (!p || !p.ws || p.ws.readyState !== WebSocket.OPEN) return;
        // Re-subscribe only this socket with the live sub ids, so one shard recycle doesn't re-REQ the pool.
        if (!this._lastPoolSubId || !this._lastPoolFilters) {
            this._poolSubscribe();
            return;
        }
        this._safeWsSend(p.ws, JSON.stringify(this._normalizeReqPayload(["REQ", this._lastPoolSubId, ...this._lastPoolFilters])), { critical: true });
        if (this._lastEphemeralSubId && this._lastEphemeralFilter) {
            this._safeWsSend(p.ws, JSON.stringify(this._normalizeReqPayload(["REQ", this._lastEphemeralSubId, this._lastEphemeralFilter])), { critical: true });
        }
        this._catchUpLiveGap();
    },

    _getShardSinceFloor(shardId) {
        const nowSec = Math.floor(Date.now() / 1000);
        const since24h = nowSec - 86400;
        if (!this._reconnectingShards || !this._reconnectingShards.has(shardId)) return since24h;
        const lastSeen = this._shardLastSeenAt && this._shardLastSeenAt.get(shardId);
        if (typeof lastSeen !== 'number' || lastSeen < since24h) return since24h;
        const buffered = lastSeen - 30;
        return buffered > since24h ? buffered : since24h;
    },

    _updateShardLastSeen(shardId, createdAt) {
        if (!shardId || typeof createdAt !== 'number' || createdAt <= 0) return;
        if (!this._shardLastSeenAt) this._shardLastSeenAt = new Map();
        const cur = this._shardLastSeenAt.get(shardId) || 0;
        if (createdAt <= cur) return;
        this._shardLastSeenAt.set(shardId, createdAt);
        if (typeof this._schedulePoolStatePersist === 'function') {
            this._schedulePoolStatePersist();
        }
    },

    _buildGeoFilters(since24h) {
        return this._buildCriticalFilters(since24h);
    },

    _buildCriticalFilters(since24h, channelSince) {
        const filters = [];
        const nowSec = Math.floor(Date.now() / 1000);
        const channelMode = !this.settings.groupChatPMOnlyMode;
        const d1Available = this._d1Backed();
        const chSince = d1Available ? nowSec : ((typeof channelSince === 'number') ? channelSince : since24h);
        const lim = (n) => d1Available ? 1 : n;

        if (this.pubkey) {
            filters.push({ kinds: [1059], "#p": [this.pubkey], limit: d1Available ? 1 : 500 });
        }
        if (channelMode) {
            // Deliberately unscoped: the sidebar discovers channels by watching this stream.
            filters.push({ kinds: [20000], since: chSince });
            filters.push({ kinds: [23333], since: chSince });
        }
        if (this.pubkey) {
            const f = { kinds: [7], "#p": [this.pubkey], "#k": ["20000", "23333"], limit: lim(100) };
            if (d1Available) f.since = nowSec;
            filters.push(f);
        }
        if (channelMode) {
            filters.push({ kinds: [7], "#k": ["20000", "23333"], since: chSince, limit: lim(100) });
        }
        {
            const f = { kinds: [7], "#k": ["1059"], limit: lim(100) };
            if (d1Available) f.since = nowSec;
            filters.push(f);
        }
        if (channelMode) {
            filters.push({ kinds: [5], "#k": ["20000", "23333", "1059"], since: d1Available ? nowSec : since24h, limit: lim(100) });
        }
        if (this.pubkey) {
            filters.push({ kinds: [9735], "#p": [this.pubkey], "#k": ["20000", "23333", "1059", "0"], since: chSince, limit: lim(200) });
        }
        if (channelMode) {
            filters.push({ kinds: [9735], "#k": ["20000", "23333"], since: chSince, limit: lim(100) });
        }
        filters.push({ kinds: [9735], "#k": ["1059"], since: chSince, limit: lim(100) });

        if (this.pubkey) {
            filters.push({ kinds: [25051], "#p": [this.pubkey], since: nowSec - 120, limit: lim(50) });
        }
        {
            const f = { kinds: [30078], "#t": ["nym-presence"], limit: lim(100) };
            if (d1Available) f.since = nowSec;
            filters.push(f);
        }
        if (channelMode) {
            filters.push({ kinds: [30078], "#t": ["nym-poll", "nym-poll-vote"], since: chSince, limit: lim(100) });
        }
        // Scoped to conversation partners, group members and ourselves; follows the send gate (pqSendCapable).
        if (this.pubkey && typeof this.pqEnabled === 'function' && this.pqEnabled()) {
            const pqAuthors = new Set([this.pubkey]);
            if (this.pmConversations) {
                for (const pk of this.pmConversations.keys()) {
                    if (this._isNostrHex64(pk)) pqAuthors.add(pk);
                }
            }
            if (this.groupConversations) {
                for (const [, group] of this.groupConversations) {
                    for (const pk of (group.members || [])) {
                        if (this._isNostrHex64(pk)) pqAuthors.add(pk);
                    }
                }
            }
            const authors = [...pqAuthors].slice(0, 500);
            if (d1Available) {
                filters.push({
                    kinds: [30078], "#t": [this.PQ_D_TAG], since: nowSec, limit: 1
                });
            } else {
                filters.push({
                    kinds: [30078], "#t": [this.PQ_D_TAG], authors,
                    limit: authors.length
                });
            }
        }
        if (d1Available) {
            filters.push({ kinds: [30078], "#t": ["nym-vouches"], since: nowSec, limit: 1 });
        } else {
            const vouchAuthors = this.nymchatPubkeys
                ? [...this.nymchatPubkeys].filter(pk => this._isNostrHex64(pk)).slice(0, 500)
                : [];
            if (vouchAuthors.length > 0) {
                filters.push({ kinds: [30078], "#t": ["nym-vouches"], authors: vouchAuthors, limit: vouchAuthors.length });
            }
        }
        {
            const f = { kinds: [30030], limit: d1Available ? 1 : 300 };
            if (d1Available) f.since = nowSec;
            filters.push(f);
        }
        if (this.pubkey) {
            filters.push({ kinds: [25052], since: d1Available ? nowSec : nowSec - 86400, limit: lim(100) });
            filters.push({ kinds: [10030], authors: [this.pubkey], limit: 1 });
        }
        if (d1Available) {
            if (this.pubkey) {
                filters.push({ kinds: [0], authors: [this.pubkey], since: nowSec, limit: 1 });
            }
        } else {
            const profileAuthors = this.pmConversations
                ? Array.from(this.pmConversations.keys()).filter(pk => typeof pk === 'string' && pk.length === 64)
                : [];
            if (this.pubkey && !profileAuthors.includes(this.pubkey)) {
                profileAuthors.push(this.pubkey);
            }
            if (profileAuthors.length > 0) {
                filters.push({ kinds: [0], authors: profileAuthors });
            }
        }

        return filters;
    },

    _isNostrHex64(s) {
        return typeof s === 'string' && s.length === 64 && /^[0-9a-f]{64}$/i.test(s);
    },

    // Raise broad filters' since to their oldest per-kind watermark; scoped filters and gift wraps are untouched.
    _applyReconnectSince(filters) {
        if (!this._poolKindNewest || this._poolKindNewest.size === 0) return;
        const GAP = 120;
        for (const f of filters) {
            if (!f || !Array.isArray(f.kinds) || f.kinds.length === 0) continue;
            if (f.authors || f['#p']) continue;
            if (f.kinds.includes(1059)) continue;
            let oldest = Infinity;
            for (const k of f.kinds) {
                const w = this._poolKindNewest.get(k);
                if (typeof w !== 'number') { oldest = -Infinity; break; }
                if (w < oldest) oldest = w;
            }
            if (!isFinite(oldest)) continue;
            const floor = oldest - GAP;
            if (typeof f.since !== 'number' || f.since < floor) f.since = floor;
        }
    },

    _poolSubscribe() {
        if (!this._isAnyPoolOpen()) return;

        if (this._lastPoolSubId) {
            if (!this._poolSubsRetiring) this._poolSubsRetiring = new Set();
            this._poolSubsRetiring.add(this._lastPoolSubId);
        }
        const nowSec = Math.floor(Date.now() / 1000);
        const isReconnect = this._poolHasSubscribed;
        this._poolHasSubscribed = true;
        const subId = Math.random().toString(36).substring(2);
        this._lastPoolSubId = subId;
        // With D1 backfill available, ask relays for a short real-time window only; else 24h.
        const since24h = nowSec - 86400;
        const d1Available = this._d1Backed();
        const channelSince = d1Available ? nowSec - 300 : since24h;
        const filters = this._buildCriticalFilters(since24h, channelSince);
        if (isReconnect) this._applyReconnectSince(filters);
        this._lastPoolFilters = filters;
        this._poolSend(["REQ", subId, ...filters]);
        this._schedulePoolSubRetire(this._poolSubRetireMaxMs);

        this._refreshEphemeralSubscriptions();

        this._resubscribeChannels();
        this._catchUpLiveGap();
    },

    _poolSubRetireGraceMs: 1500,
    _poolSubRetireMaxMs: 10000,

    _schedulePoolSubRetire(ms) {
        if (!this._poolSubsRetiring || !this._poolSubsRetiring.size) return;
        if (this._poolSubRetireTimer) clearTimeout(this._poolSubRetireTimer);
        this._poolSubRetireTimer = setTimeout(() => {
            this._poolSubRetireTimer = null;
            const ids = [...(this._poolSubsRetiring || [])];
            if (this._poolSubsRetiring) this._poolSubsRetiring.clear();
            for (const id of ids) {
                if (id !== this._lastPoolSubId) this._poolSend(["CLOSE", id]);
            }
        }, ms);
    },

    _notePoolSubLive(subId) {
        const live = this._lastPoolSubId;
        if (!live || typeof subId !== 'string') return;
        if (subId !== live && !subId.startsWith(live + '~')) return;
        if (!this._poolSubsRetiring || !this._poolSubsRetiring.size || this._poolSubRetireLiveFor === live) return;
        this._poolSubRetireLiveFor = live;
        this._schedulePoolSubRetire(this._poolSubRetireGraceMs);
    },

    _noteLiveGap(lastLiveAt, socketLost) {
        const now = Date.now();
        const at = lastLiveAt > 0 && lastLiveAt < now ? Math.max(lastLiveAt, now - 86400000) : now;
        if (!this._liveGapAt || at < this._liveGapAt) this._liveGapAt = at;
        if (socketLost) this._liveGapSocketLost = true;
        this._liveGapSeq = (this._liveGapSeq || 0) + 1;
    },

    _liveGapChannelKeys() {
        const keys = new Set();
        const current = this.currentGeohash || this.currentChannel;
        if (current) keys.add(current);
        if (this._cvActive && Array.isArray(this._cvColumns)) {
            for (const col of this._cvColumns) {
                const key = col && col.type === 'channel' ? (col.geohash || col.channel) : '';
                if (key) keys.add(key);
            }
        }
        if (this.userJoinedChannels) this.userJoinedChannels.forEach(k => { if (k) keys.add(k); });
        if (this.pinnedChannels) this.pinnedChannels.forEach(k => { if (k) keys.add(k); });
        if (typeof document !== 'undefined') {
            document.querySelectorAll('#channelList .channel-item').forEach(el => {
                const k = el.dataset && (el.dataset.geohash || el.dataset.channel);
                if (k) keys.add(k);
            });
        }
        if (this.channels) this.channels.forEach((v, k) => { if (k) keys.add(k); });
        return [...keys];
    },

    _scheduleLiveGapSettle(since) {
        if (this._liveGapSettleTimer) clearTimeout(this._liveGapSettleTimer);
        this._liveGapSettleSince = Math.min(since, this._liveGapSettleSince || since);
        this._liveGapSettleTimer = setTimeout(() => {
            const from = this._liveGapSettleSince;
            this._liveGapSettleTimer = null;
            this._liveGapSettleSince = 0;
            const passes = [];
            if (typeof this.channelRestoreManyFromD1 === 'function') {
                passes.push(Promise.resolve()
                    .then(() => this.channelRestoreManyFromD1(this._liveGapChannelKeys(), { force: true, since: from }))
                    .then((ok) => !!ok, () => false));
            }
            if (typeof this.pmRestoreFromD1 === 'function') {
                passes.push(Promise.resolve()
                    .then(() => this.pmRestoreFromD1())
                    .then(() => true, () => false));
            }
            if (!passes.length) return;
            Promise.all(passes).then((oks) => {
                if (oks.some(Boolean) && typeof this.recomputeAllUnreadCounts === 'function') this.recomputeAllUnreadCounts();
                if (typeof this._cvScheduleReconcile === 'function') this._cvScheduleReconcile(0);
            }, () => { });
        }, this._liveGapSettleMs || 35000);
    },

    _giftWrapBackdateSec: 172800,
    _giftWrapCatchUpLimit: 500,
    _giftWrapCatchUpWindowMs: 10000,
    _giftWrapCatchUpMaxKeys: 1000,

    _botAnonKeySet() {
        return new Set(typeof this.botAnonPubkeys === 'function' ? (this.botAnonPubkeys() || []) : []);
    },

    _giftWrapCatchUpFilter(floorSec) {
        const anon = this._botAnonKeySet();
        const eph = (typeof this._getAllSelfEphemeralPubkeys === 'function'
            ? (this._getAllSelfEphemeralPubkeys() || []) : []).filter((pk) => !anon.has(pk));
        const pks = [...new Set([this.pubkey, ...eph].filter(pk => typeof pk === 'string' && pk))]
            .slice(0, this._giftWrapCatchUpMaxKeys);
        if (!pks.length) return null;
        return {
            kinds: [1059],
            '#p': pks,
            since: Math.max(0, floorSec - this._giftWrapBackdateSec),
            limit: this._giftWrapCatchUpLimit
        };
    },

    _catchUpGiftWraps(floorSec) {
        if (!Number.isFinite(floorSec) || floorSec <= 0) return null;
        const filter = this._giftWrapCatchUpFilter(floorSec);
        if (!filter) return null;
        const subId = 'nym-gap-' + Math.random().toString(36).slice(2, 12);
        if (!this._subscriptionHandlers) this._subscriptionHandlers = new Map();
        this._subscriptionHandlers.set(subId, (type, data) => {
            if (type !== 'EVENT' || !data || data[0] !== subId) return;
            const ev = data[1];
            if (ev && ev.kind === 1059 && typeof ev.id === 'string' && ev.id) this._noteGapWrapFloor(ev.id, floorSec);
        });
        if (!this._gapWrapSubs) this._gapWrapSubs = new Set();
        this._gapWrapSubs.add(subId);
        this.sendRequestToAllRelays(['REQ', subId, filter]);
        setTimeout(() => {
            if (this._subscriptionHandlers) this._subscriptionHandlers.delete(subId);
            if (this._gapWrapSubs) this._gapWrapSubs.delete(subId);
            try { this.sendRequestToAllRelays(['CLOSE', subId]); } catch (_) { }
        }, this._giftWrapCatchUpWindowMs);
        return subId;
    },

    _noteGapWrapFloor(wrapId, floorSec) {
        if (!this._gapWrapFloors) this._gapWrapFloors = new Map();
        const floors = this._gapWrapFloors;
        floors.delete(wrapId);
        floors.set(wrapId, floorSec);
        while (floors.size > 2000) floors.delete(floors.keys().next().value);
    },

    _gapWrapVerdict(wrapId, rumor) {
        const floors = this._gapWrapFloors;
        if (!floors || !wrapId || !floors.has(wrapId)) return null;
        const floorSec = floors.get(wrapId);
        floors.delete(wrapId);
        const ts = rumor && Number.isFinite(rumor.created_at) ? rumor.created_at : 0;
        return { stale: ts < floorSec, floorSec };
    },

    _catchUpLiveGap() {
        if (!this._liveGapAt || this._liveGapInFlight) return;
        if (this.useRelayProxy && !this._isAnyPoolOpen()) return;
        const seqAt = this._liveGapSeq;
        const since = Math.floor(this._liveGapAt / 1000) - 300;
        this._catchUpGiftWraps(since);
        if (!this._getApiHost || !this._getApiHost()) return;
        this._liveGapInFlight = true;
        this.backfillFromD1OnReconnect({ force: true, since, socketLost: !!this._liveGapSocketLost, channels: this._liveGapChannelKeys() }).then((ok) => {
            if (!ok) return;
            if (this._liveGapSeq === seqAt) {
                this._liveGapAt = 0;
                this._liveGapSocketLost = false;
            }
            this._scheduleLiveGapSettle(since);
        }, () => { }).finally(() => {
            this._liveGapInFlight = false;
            if (typeof this._cvScheduleReconcile === 'function') this._cvScheduleReconcile(0);
            if (this._liveGapAt && this._liveGapSeq !== seqAt) this._catchUpLiveGap();
        });
    },

    // Direct mode only; in pool mode these come from D1 via the pool worker.
    _shardEphemeralKeys(ephPks, relayUrls, redundancy = 2) {
        const out = new Map(relayUrls.map(u => [u, []]));
        const n = relayUrls.length;
        if (!n || !ephPks.length) return out;
        // Fewer relays than the redundancy target: everyone gets everything.
        if (n <= redundancy) {
            for (const url of relayUrls) out.set(url, ephPks.slice());
            return out;
        }
        const hash = (str) => {
            let h = 0x811c9dc5;                       // FNV-1a, 32-bit
            for (let i = 0; i < str.length; i++) {
                h ^= str.charCodeAt(i);
                h = (h * 0x01000193) >>> 0;
            }
            return h;
        };
        for (const pk of ephPks) {
            const ranked = relayUrls
                .map(url => ({ url, score: hash(pk + '|' + url) }))
                .sort((a, b) => (b.score - a.score) || (a.url < b.url ? -1 : 1));
            for (let r = 0; r < redundancy; r++) out.get(ranked[r].url).push(pk);
        }
        return out;
    },

    _readableRelayUrls() {
        const urls = [];
        this.relayPool.forEach((relay, url) => {
            if (this.writeOnlyRelays && this.writeOnlyRelays.has(url)) return;
            if (relay.ws && relay.ws.readyState === WebSocket.OPEN) urls.push(url);
        });
        return urls.sort();
    },

    // One filter per relay carrying only that relay's shard.
    _sendShardedEphemeralReq(subId, ephPks, buildFilter) {
        const shards = this._shardEphemeralKeys(ephPks, this._readableRelayUrls());
        shards.forEach((keys, url) => {
            if (!keys.length) return;
            const relay = this.relayPool.get(url);
            if (!relay || !relay.ws || relay.ws.readyState !== WebSocket.OPEN) return;
            const msg = JSON.stringify(this._normalizeReqPayload(['REQ', subId, buildFilter(keys)]));
            this._safeWsSend(relay.ws, msg, { critical: true });
        });
    },

    _pmInboxRestore(keys) {
        if (!this._pmInboxQ) this._pmInboxQ = new Set();
        for (const k of Array.isArray(keys) ? keys : []) if (typeof k === 'string' && k) this._pmInboxQ.add(k);
        if (this._pmInboxRunning) return this._pmInboxRunning;
        const run = (async () => {
            const D = window.NymD1Cursor;
            if (!this._pmInboxDoneAt) this._pmInboxDoneAt = new Map();
            while (this._pmInboxQ.size) {
                const batch = [...this._pmInboxQ];
                this._pmInboxQ.clear();
                const now = Date.now();
                const due = D ? batch.filter((k) => !D.coalesce(this._pmInboxDoneAt.get(k), now)) : batch;
                if (due.length) await this._pmInboxPass(due);
            }
        })().finally(() => { if (this._pmInboxRunning === run) this._pmInboxRunning = null; });
        this._pmInboxRunning = run;
        return run;
    },

    async _pmInboxState(pk) {
        let st = this._pmInboxCur;
        if (!st || st.pk !== pk) {
            st = { pk, map: {}, loaded: false, holds: [], heldSince: 0 };
            this._pmInboxCur = st;
        }
        if (st.loaded) return st;
        if (typeof this.hydrateGate === 'function') {
            await Promise.race([this.hydrateGate(), new Promise((r) => setTimeout(r, 20000))]);
        }
        if (st.loaded || this.pubkey !== pk) return st;
        st.loaded = true;
        const rec = typeof this._pmCursorMetaFor === 'function' ? this._pmCursorMetaFor('pmInboxCursors', pk) : null;
        if (rec && rec.map && typeof rec.map === 'object') {
            st.map = window.NymD1Cursor.inboxStore(rec.map, [], null, null);
            if (Number.isFinite(rec.heldSince) && rec.heldSince > 0) st.heldSince = rec.heldSince;
        }
        return st;
    },

    async _pmInboxRead(chunk, extra) {
        const events = [];
        const resp = await this._storageApiStream('pm-get', Object.assign({ pubkeys: chunk }, extra || {}), false, { statsAction: 'pm-get:inbox' });
        await this._readNdjsonStream(resp, (ev) => { if (ev) events.push(ev); });
        return { events, headers: resp.headers };
    },

    async _pmInboxReplay(events, hold) {
        events.sort((a, b) => (a.created_at || 0) - (b.created_at || 0));
        this._restoreFromD1Depth = (this._restoreFromD1Depth || 0) + 1;
        try {
            for (let k = 0; k < events.length; k++) {
                const ev = events[k];
                if (!ev || typeof ev.id !== 'string') continue;
                try { await this.handleGiftWrapDM(ev, { fromD1: true }); } catch (_) { }
                const kind = hold && typeof this._pmWrapRetryable === 'function' ? this._pmWrapRetryable(ev) : false;
                if (kind) hold(ev, kind);
                if (k + 1 < events.length && typeof this._yieldIfDue === 'function') await this._yieldIfDue();
            }
        } finally {
            this._restoreFromD1Depth = Math.max(0, (this._restoreFromD1Depth || 1) - 1);
        }
    },

    async _pmInboxPass(keys) {
        const D = window.NymD1Cursor;
        const pk = this.pubkey;
        if (!D) {
            for (let i = 0; i < keys.length; i += 200) {
                const r = await this._pmInboxRead(keys.slice(i, i + 200));
                await this._pmInboxReplay(r.events, null);
            }
            return;
        }
        const st = await this._pmInboxState(pk);
        if (this.pubkey !== pk) return;
        const holdFor = (chunk, after) => (ev, kind) => {
            if (st.holds.some((h) => h.id === ev.id)) return;
            const now = Date.now();
            const persist = kind === 'hold';
            const since = persist && st.heldSince && now - st.heldSince < D.HOLD_MS ? st.heldSince : now;
            if (persist && !st.heldSince) st.heldSince = since;
            st.holds.push({ id: ev.id, ev, since, persist, keys: chunk.slice(), after: D.valid(after) ? after : null });
            while (st.holds.length > 500) st.holds.shift();
        };
        const done = (chunk) => { const t = Date.now(); for (const k of chunk) this._pmInboxDoneAt.set(k, t); };
        const legacyRead = async (chunk) => {
            const r = await this._pmInboxRead(chunk);
            if (this.pubkey !== pk) return;
            await this._pmInboxReplay(r.events, holdFor(chunk, null));
            const head = D.fromHead(r.headers.get('X-Cursor-Head'));
            if (head) st.map = D.inboxStore(st.map, chunk, head, null);
            done(chunk);
        };
        const plan = D.inboxPlan(keys, st.map);
        for (const chunk of plan.legacy) {
            try { await legacyRead(chunk); } catch (_) { }
            if (this.pubkey !== pk) return;
        }
        for (const group of plan.cursor) {
            let after = group.after;
            let best = null;
            let legacy = false;
            try {
                for (let page = 0; page < D.MAX_PAGES; page++) {
                    const r = await this._pmInboxRead(group.keys, { after, limit: D.PAGE_LIMIT });
                    if (this.pubkey !== pk) return;
                    const step = D.step(page, after, r.headers.get('X-Cursor'), r.headers.get('X-Has-More'));
                    if (!step.serverOk) {
                        legacy = true;
                        await this._pmInboxReplay(r.events, null);
                        break;
                    }
                    await this._pmInboxReplay(r.events, holdFor(group.keys, after));
                    best = D.newer(best, step.cursor);
                    if (!step.next) break;
                    after = step.next;
                }
            } catch (_) { }
            if (this.pubkey !== pk) return;
            if (legacy) {
                const next = {};
                for (const [k, v] of Object.entries(st.map)) if (!group.keys.includes(k)) next[k] = v;
                st.map = next;
                st.legacyServer = true;
                try { await this._pmInboxRead(group.keys).then((r) => this._pmInboxReplay(r.events, null)); } catch (_) { }
                done(group.keys);
                continue;
            }
            if (best) st.map = D.inboxStore(st.map, group.keys, best, null);
            done(group.keys);
        }
        if (st.legacyServer) st.map = {};
        await this._pmInboxRetryHeld();
        this._pmInboxCommit();
    },

    async _botAnonInboxRestore(keys) {
        const D = window.NymD1Cursor;
        const pk = this.pubkey;
        if (!D || typeof this._botAnonStream !== 'function' || typeof this._botAnonIdentities !== 'function') return;
        const st = await this._pmInboxState(pk);
        if (this.pubkey !== pk) return;
        if (!this._pmInboxDoneAt) this._pmInboxDoneAt = new Map();
        const ids = this._botAnonIdentities();
        for (const key of keys) {
            const id = ids.find((i) => i.pk === key);
            if (!id || D.coalesce(this._pmInboxDoneAt.get(key), Date.now())) continue;
            try {
                if (!D.valid(st.map[key])) {
                    const r = await this._botAnonStream(id, { since: 0, before: 0, limit: 1000 });
                    if (this.pubkey !== pk) return;
                    await this._pmInboxReplay(r.events, null);
                    const head = D.fromHead(r.headers.get('X-Cursor-Head'));
                    if (head) st.map = D.inboxStore(st.map, [key], head, null);
                } else {
                    let after = D.startAfter(st.map[key]);
                    let best = null;
                    let legacy = false;
                    for (let page = 0; page < D.MAX_PAGES; page++) {
                        const r = await this._botAnonStream(id, { after, limit: D.PAGE_LIMIT });
                        if (this.pubkey !== pk) return;
                        const step = D.step(page, after, r.headers.get('X-Cursor'), r.headers.get('X-Has-More'));
                        await this._pmInboxReplay(r.events, null);
                        if (!step.serverOk) { legacy = true; break; }
                        best = D.newer(best, step.cursor);
                        if (!step.next) break;
                        after = step.next;
                    }
                    if (legacy) {
                        const next = Object.assign({}, st.map);
                        delete next[key];
                        st.map = next;
                        const r = await this._botAnonStream(id, { since: 0, before: 0, limit: 1000 });
                        await this._pmInboxReplay(r.events, null);
                    } else if (best) {
                        st.map = D.inboxStore(st.map, [key], best, null);
                    }
                }
                this._pmInboxDoneAt.set(key, Date.now());
            } catch (_) { }
        }
        this._pmInboxCommit();
    },

    async _pmInboxRetryHeld() {
        const st = this._pmInboxCur;
        if (!st || st.pk !== this.pubkey || !st.holds.length || this._pmInboxRetrying) return false;
        this._pmInboxRetrying = true;
        let changed = false;
        try {
            const D = window.NymD1Cursor;
            const now = Date.now();
            const keep = [];
            for (const h of st.holds.slice()) {
                if (this._decryptedWrapIds && this._decryptedWrapIds.has(h.id)) { changed = true; continue; }
                if (now - h.since >= D.HOLD_MS) { changed = true; continue; }
                try { await this.handleGiftWrapDM(h.ev, { fromD1: true }); } catch (_) { }
                if (this._decryptedWrapIds && this._decryptedWrapIds.has(h.id)) { changed = true; continue; }
                keep.push(h);
            }
            if (this._pmInboxCur === st) {
                st.holds = keep;
                if (!keep.length) st.heldSince = 0;
            }
        } finally {
            this._pmInboxRetrying = false;
        }
        if (changed) this._pmInboxCommit();
        return changed;
    },

    _pmInboxCommit() {
        const st = this._pmInboxCur;
        const D = window.NymD1Cursor;
        if (!D || !st || st.pk !== this.pubkey || typeof this._pmMetaCommit !== 'function') return;
        const live = typeof this._getAllSelfEphemeralPubkeys === 'function' ? this._getAllSelfEphemeralPubkeys() : null;
        st.map = D.inboxStore(st.map, [], null, live);
        const now = Date.now();
        const out = Object.assign({}, st.map);
        const active = st.holds.filter((h) => h.persist && now - h.since < D.HOLD_MS);
        for (const h of active) {
            for (const k of h.keys) {
                if (!(k in out)) continue;
                if (!D.valid(h.after)) delete out[k];
                else out[k] = D.older(out[k], h.after);
            }
        }
        this._pmMetaCommit({ key: 'pmInboxCursors', pk: st.pk, map: out, heldSince: active.length ? st.heldSince || now : 0 });
    },

    async _recoverEphemeralHistory(ephPks) {
        if (!Array.isArray(ephPks) || ephPks.length === 0) return;
        const since = this._isFreshDevice
            ? 0
            : (this.lastPMSyncTime > 0 ? Math.max(0, this.lastPMSyncTime - 300) : 0);

        if (this._getApiHost && this._getApiHost() && typeof this._storageApiStream === 'function') {
            const anon = this._botAnonKeySet();
            const groupKeys = ephPks.filter((k) => !anon.has(k));
            const anonKeys = ephPks.filter((k) => anon.has(k));
            if (groupKeys.length) {
                try { await this._pmInboxRestore(groupKeys); } catch (_) { }
            }
            if (anonKeys.length) {
                try { await this._botAnonInboxRestore(anonKeys); } catch (_) { }
            }
            return;
        }

        const filter = { kinds: [1059], '#p': ephPks, limit: Math.min(ephPks.length * 20, 1000) };
        if (since > 0) filter.since = since;
        const subId = Math.random().toString(36).substring(2);
        this._registerBackfillSub(subId);

        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            this._poolSendToRole('critical', ['REQ', subId, filter]);
        } else {
            // Sharded: no relay gets the whole ephemeral set (_shardEphemeralKeys).
            this._sendShardedEphemeralReq(subId, ephPks, (keys) => {
                const f = { kinds: [1059], '#p': keys, limit: Math.min(keys.length * 20, 1000) };
                if (since > 0) f.since = since;
                return f;
            });
        }

        await this._waitForEoseOrTimeout(subId, 5000);
    },

    _scheduleEphemeralSubRefresh(delayMs = 2000) {
        this._ephSubRefreshPending = true;
        if (this._ephSubRefreshTimer) return;
        const run = () => {
            if (!this._ephSubRefreshPending) { this._ephSubRefreshTimer = null; return; }
            if (this._ephRefreshInFlight) {
                this._ephSubRefreshTimer = setTimeout(run, 1000);
                return;
            }
            this._ephSubRefreshPending = false;
            if (!this._ownEphemeralKeysCovered()) this._refreshEphemeralSubscriptions();
            this._ephSubRefreshTimer = setTimeout(run, delayMs);
        };
        run();
    },

    _closeEphemeralSubs(subIds) {
        for (const oldSubId of subIds || []) {
            if (this.useRelayProxy && this._isAnyPoolOpen()) {
                this._poolSendToRole('critical', ['CLOSE', oldSubId]);
            } else {
                const closeMsg = JSON.stringify(['CLOSE', oldSubId]);
                this.relayPool.forEach(relay => {
                    if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                        this._safeWsSend(relay.ws, closeMsg, { critical: true });
                    }
                });
            }
        }
    },

    _ephemeralSubTransportOpen() {
        if (this.useRelayProxy && this._isAnyPoolOpen()) return true;
        if (!this.relayPool) return false;
        for (const [, relay] of this.relayPool) {
            if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) return true;
        }
        return false;
    },

    _openEphemeralSub() {
        const superseded = this._ephemeralSubIds || [];
        this._ephemeralSubIds = [];
        const ephPks = this._getAllSelfEphemeralPubkeys();
        if (!ephPks.length) {
            this._ephSubscribedPks = new Set();
            return { subId: null, superseded };
        }

        const subId = Math.random().toString(36).substring(2);
        this._ephemeralSubIds.push(subId);
        const filter = { kinds: [1059], "#p": ephPks };
        if (this._d1Backed()) {
            filter.limit = 1;
        } else {
            filter.since = Math.floor(Date.now() / 1000) - 604800;
            filter.limit = 200 * ephPks.length;
        }
        this._lastEphemeralSubId = subId;
        this._lastEphemeralFilter = filter;

        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            this._poolSendToRole('critical', ['REQ', subId, filter]);
        } else {
            // Sharded; `filter` stays unsharded because the pool path and shard recycles reuse it.
            this._sendShardedEphemeralReq(subId, ephPks, (keys) => {
                const f = { kinds: [1059], '#p': keys };
                if (this._d1Backed()) {
                    f.limit = 1;
                } else {
                    f.since = Math.floor(Date.now() / 1000) - 604800;
                    f.limit = 200 * keys.length;
                }
                return f;
            });
        }
        this._ephSubscribedPks = this._ephemeralSubTransportOpen() ? new Set(ephPks) : new Set();
        return { subId, superseded };
    },

    async _refreshEphemeralSubscriptions() {
        if (this._ephRefreshInFlight) return;
        this._ephRefreshInFlight = true;
        try {
            const { subId, superseded } = this._openEphemeralSub();
            if (subId) await this._waitForEoseOrTimeout(subId, 5000);
            this._closeEphemeralSubs(superseded);
        } finally {
            this._ephRefreshInFlight = false;
        }
    },

    _ownEphemeralKeysCovered() {
        const have = this._ephSubscribedPks;
        const pks = this._getAllSelfEphemeralPubkeys();
        return !!have && have.size === pks.length && pks.every(pk => have.has(pk));
    },

    _ensureOwnEphemeralSub() {
        const pks = this._getAllSelfEphemeralPubkeys();
        const have = this._ephSubscribedPks;
        if (!pks.length || (have && pks.every(pk => have.has(pk)))) return false;
        if (!this._ephemeralSubTransportOpen()) return false;
        const { subId, superseded } = this._openEphemeralSub();
        if (!subId) {
            this._closeEphemeralSubs(superseded);
            return false;
        }
        this._waitForEoseOrTimeout(subId, 5000).then(() => this._closeEphemeralSubs(superseded));
        return true;
    },

    // Coalesced so back-to-back shard reconnects don't re-fire every channel's REQ.
    _resubscribeChannels() {
        const now = Date.now();
        if (this._lastResubscribeAt && now - this._lastResubscribeAt < 15000) return;
        this._lastResubscribeAt = now;

        // Channel history comes from the global sub and D1, so just clear stale tracking.
        this.channelLoadedFromRelays.clear();
        this.channelSubscriptions.clear();
        if (this._channelTypingSubs) this._channelTypingSubs.clear();

        // Typing kinds (24420/24421) aren't in the global subscription.
        const current = this.currentChannel || this.currentGeohash;
        if (current) this._ensureChannelTypingSub(current, 'geohash');

        this.backfillFromD1OnReconnect();
    },

    backfillFromD1OnReconnect(opts = {}) {
        if (!this._getApiHost || !this._getApiHost()) return Promise.resolve(false);
        const force = !!opts.force;
        if (!force && this._liveGapAt) return Promise.resolve(false);
        const now = Date.now();
        if (!force && this._lastD1BackfillAt && now - this._lastD1BackfillAt < 30000) return Promise.resolve(false);
        const extras = !this._lastD1BackfillAt || now - this._lastD1BackfillAt >= 30000;
        this._lastD1BackfillAt = now;
        if (force) {
            this._geohashActivityFetchedAt = 0;
            this._namedActivityFetchedAt = 0;
        }

        const restorePromises = [];

        const conversations = extras || !!opts.socketLost;
        if (conversations && typeof this.pmRestoreFromD1 === 'function') {
            restorePromises.push(this.pmRestoreFromD1().catch(() => { }));
        }

        // Other members' group messages are deposited under our ephemeral keys, so pull that inbox too.
        if (conversations && typeof this._recoverEphemeralHistory === 'function' &&
            typeof this._getAllSelfEphemeralPubkeys === 'function') {
            const ephPks = this._getAllSelfEphemeralPubkeys();
            if (ephPks && ephPks.length) {
                restorePromises.push(this._recoverEphemeralHistory(ephPks).catch(() => { }));
            }
        }

        let channelsRestored = Promise.resolve(true);
        if (typeof this.channelRestoreManyFromD1 === 'function') {
            const channels = new Set(Array.isArray(opts.channels) ? opts.channels : []);
            const current = this.currentGeohash || this.currentChannel;
            if (current) channels.add(current);
            if (this.userJoinedChannels) this.userJoinedChannels.forEach(k => channels.add(k));
            if (channels.size) {
                channelsRestored = this.channelRestoreManyFromD1([...channels], { force, since: opts.since }).catch(() => false);
                restorePromises.push(channelsRestored);
            }
        }

        const seedPromises = [];
        if (typeof this.fetchGeohashActivityFromD1 === 'function') {
            seedPromises.push(this.fetchGeohashActivityFromD1().catch(() => { }));
        }
        if (typeof this.fetchNamedChannelActivityFromD1 === 'function') {
            seedPromises.push(this.fetchNamedChannelActivityFromD1().catch(() => { }));
        }

        const settled = Promise.allSettled([...restorePromises, ...seedPromises]).then(() => {
            if ((restorePromises.length || seedPromises.length) && typeof this.recomputeAllUnreadCounts === 'function') {
                this.recomputeAllUnreadCounts();
            }
        });

        if (!extras) return settled.then(() => channelsRestored);

        if (typeof this._emojiRestoreFromD1 === 'function') {
            this._emojiRestoreFromD1().catch(() => { });
        }

        // Profile zaps are keyed on our pubkey and the relay window for #p zaps is tight.
        if (this.pubkey && typeof this._backfillZapReceiptsFromD1 === 'function') {
            this._backfillZapReceiptsFromD1([this.pubkey], 'profile').catch(() => { });
        }

        // Rebuild the web of trust from D1 vouch lists instead of relays.
        if (typeof this._fetchVouchesFromD1 === 'function') {
            this._fetchVouchesFromD1().catch(() => { });
        }
        return settled.then(() => channelsRestored);
    },

    _poolSendRelayConfig() {
        if (!this._isAnyPoolOpen()) return;
        if (this._poolSendRelayConfigTimer) return;
        this._poolSendRelayConfigTimer = setTimeout(() => {
            this._poolSendRelayConfigTimer = null;
            this._poolSendRelayConfigNow();
        }, 500);
    },

    _poolSendRelayConfigNow() {
        if (!this._isAnyPoolOpen()) return;

        let geoRelayUrls = [];

        if (this.settings && this.settings.lowDataMode) {
            geoRelayUrls = [...this.currentGeoRelays];
        } else {
            geoRelayUrls = (this.geoRelays || []).map(r => r.url || r).filter(Boolean);
            for (const url of this.currentGeoRelays) {
                if (!geoRelayUrls.includes(url)) geoRelayUrls.unshift(url);
            }
        }

        const shards = this._shardRelaysByRole(
            [...this.allRelayUrls],
            geoRelayUrls,
            this.defaultRelays
        );
        const shardById = new Map(shards.map(s => [s.id, s]));

        const arraysEqual = (a, b) => {
            if (!a || !b) return a === b;
            if (a.length !== b.length) return false;
            const setA = new Set(a);
            for (const v of b) if (!setA.has(v)) return false;
            return true;
        };

        // Each socket gets only its own shard's relays; sockets for vanished shards are closed.
        for (const p of this.poolSockets) {
            const shard = shardById.get(p.id);
            if (!shard) {
                p._closing = true;
                try { if (p.ws) p.ws.close(); } catch (_) { }
                continue;
            }
            if (!p.ws || p.ws.readyState !== WebSocket.OPEN) continue;
            if (arraysEqual(p.relays, shard.relays)) continue;
            p.relays = shard.relays;
            p.dmRelays = shard.dmRelays || [];
            this._safeWsSend(p.ws, JSON.stringify(['RELAYS', { relays: shard.relays, dmRelays: shard.dmRelays || [] }]), { critical: true });
        }
        this.poolSockets = this.poolSockets.filter(p => shardById.has(p.id));

        this._ensureAllShardsConnected();
    },

    _isUnsafeRelayUrl(url) {
        if (typeof url !== 'string') return true;
        let u;
        try { u = new URL(url.trim()); } catch (_) { return true; }
        if (u.protocol !== 'wss:') return true;
        const h = (u.hostname || '').toLowerCase();
        if (!h) return true;
        if (h === 'localhost' || h.endsWith('.localhost')) return true;
        if (h.endsWith('.onion') || h.endsWith('.i2p')) return true;
        if (/^\d{1,3}(\.\d{1,3}){3}$/.test(h)) return true;
        if (h.startsWith('[') || h.includes(':')) return true;
        return false;
    },

    async connectToRelay(relayUrl, type = 'relay') {
        if (this.useRelayProxy) return;

        if (relayUrl === this.appRelay) return;

        if (this._isUnsafeRelayUrl(relayUrl)) return;

        if (this.isRelayBlocked(relayUrl)) return;

        // Block known-bad relays entirely.
        if (relayUrl === 'wss://relay.nosflare.com' || relayUrl === 'wss://relay.nostraddress.com' || relayUrl === 'wss://nostr-server-production.up.railway.app') {
            return;
        }

        if (this.blacklistedRelays.has(relayUrl) && !this.isBlacklistExpired(relayUrl)) {
            return;
        }
        if (!this.shouldRetryRelay(relayUrl)) {
            return;
        }

        if (this.relayPool.has(relayUrl)) {
            const existingRelay = this.relayPool.get(relayUrl);
            if (existingRelay.ws && existingRelay.ws.readyState === WebSocket.OPEN) {
                return Promise.resolve();
            }
        }

        // Reuse an in-flight connection attempt's promise.
        if (this.pendingConnections.has(relayUrl)) {
            return this.pendingConnections.get(relayUrl);
        }

        const connectionPromise = new Promise((resolve) => {
            try {

                const wsTarget = this._getProxiedRelayUrl(relayUrl);
                const ws = new WebSocket(wsTarget);
                const wsCreatedAt = Date.now();
                let verificationTimeout;
                let connectionTimeout;

                connectionTimeout = setTimeout(() => {
                    if (ws.readyState !== WebSocket.OPEN) {
                        ws.close();
                        if (relayUrl !== this.appRelay) {
                            this.blacklistedRelays.add(relayUrl);
                            this.blacklistTimestamps.set(relayUrl, Date.now());
                        }
                        resolve(); // Resolve (not reject) — callers check relayPool state
                    }
                }, 5000);

                ws.onopen = () => {
                    clearTimeout(connectionTimeout);

                    if (this.isRelayBlocked(relayUrl)) {
                        try { ws.close(1000); } catch (_) { }
                        resolve();
                        return;
                    }

                    this.relayStats.latencyPerRelay.set(relayUrl, Date.now() - wsCreatedAt);

                    this.relayPool.set(relayUrl, {
                        ws,
                        type,
                        status: 'connected',
                        connectedAt: Date.now()
                    });

                    this.clearRelayFailure(relayUrl);
                    this._flushHeldEvents();
                    resolve();
                };

                ws.onmessage = (event) => {
                    try {
                        const dataLen = typeof event.data === 'string' ? event.data.length : (event.data.byteLength || 0);
                        this.relayStats.bytesReceived += dataLen;
                        const msg = JSON.parse(event.data);
                        this.handleRelayMessage(msg, relayUrl);
                    } catch (e) {
                    }
                };

                ws.onerror = () => {
                    clearTimeout(verificationTimeout);
                    clearTimeout(connectionTimeout);

                    if (relayUrl !== this.appRelay) {
                        this.blacklistedRelays.add(relayUrl);
                        this.blacklistTimestamps.set(relayUrl, Date.now());
                    }

                    resolve(); // Resolve (not reject) — callers check relayPool state
                };

                ws.onclose = (event) => {
                    clearTimeout(verificationTimeout);
                    clearTimeout(connectionTimeout);

                    const wasConnected = this.relayPool.has(relayUrl) &&
                        this.relayPool.get(relayUrl).ws === ws;

                    if (this.isRelayBlocked(relayUrl)) {
                        if (wasConnected) this.relayPool.delete(relayUrl);
                        this.updateConnectionStatus();
                        return;
                    }

                    // Only blacklist on actual connection failures, not normal closes.
                    const isConnectionFailure = !wasConnected && event.code !== 1000 && event.code !== 1001;

                    if (isConnectionFailure && relayUrl !== this.appRelay) {
                        this.blacklistedRelays.add(relayUrl);
                        this.blacklistTimestamps.set(relayUrl, Date.now());
                    }

                    if (wasConnected) {
                        if (!this.previouslyConnectedRelays) {
                            this.previouslyConnectedRelays = new Set();
                        }
                        this.previouslyConnectedRelays.add(relayUrl);
                    }

                    this.relayPool.delete(relayUrl);

                    this.updateConnectionStatus();

                    // Pool mode handles its own reconnections; previously connected relays skip the blacklist check.
                    if (!this.useRelayProxy && this.connected && (wasConnected || !this.blacklistedRelays.has(relayUrl))) {
                        if (!this.reconnectingRelays) {
                            this.reconnectingRelays = new Set();
                        }

                        if (this.reconnectingRelays.has(relayUrl)) {
                            return;
                        }

                        this.reconnectingRelays.add(relayUrl);

                        const isAppRelay = relayUrl === this.appRelay;
                        const attemptReconnect = (attempt = 0) => {
                            const maxAttempts = isAppRelay ? Infinity : 10;
                            // Faster initial delay for previously connected relays (1s vs 5s).
                            const baseDelay = (wasConnected || isAppRelay) ? 1000 : 5000;
                            const maxDelay = (wasConnected || isAppRelay) ? 30000 : 60000;

                            const delay = Math.min(baseDelay * Math.pow(1.5, attempt), maxDelay);

                            setTimeout(() => {
                                if (!navigator.onLine) {
                                    this.reconnectingRelays.delete(relayUrl);
                                    this.updateConnectionStatus();
                                    return;
                                }

                                if (!this.connected || this.isRelayBlocked(relayUrl)) {
                                    this.reconnectingRelays.delete(relayUrl);
                                    this.updateConnectionStatus();
                                    return;
                                }

                                this.connectToRelay(relayUrl, type).then(() => {
                                    // connectToRelay resolves even on failure.
                                    const relay = this.relayPool.get(relayUrl);
                                    const isConnected = relay && relay.ws && relay.ws.readyState === WebSocket.OPEN;

                                    if (isConnected) {
                                        this.subscribeToSingleRelay(relayUrl);
                                        this.updateConnectionStatus();
                                        this.reconnectingRelays.delete(relayUrl);

                                        if (this.reconnectingRelays.size === 0) {
                                            setTimeout(() => this.retryPendingDMsOnReconnect(), 1000);
                                        }
                                    } else {
                                        this.trackRelayFailure(relayUrl);
                                        this.updateConnectionStatus();
                                        if (attempt < maxAttempts - 1) {
                                            attemptReconnect(attempt + 1);
                                        } else {
                                            this.reconnectingRelays.delete(relayUrl);
                                            this.updateConnectionStatus();
                                        }
                                    }
                                });
                            }, delay);
                        };

                        attemptReconnect(0);
                    }
                };

            } catch (error) {
                if (relayUrl !== this.appRelay) {
                    this.blacklistedRelays.add(relayUrl);
                    this.blacklistTimestamps.set(relayUrl, Date.now());
                }
                this.trackRelayFailure(relayUrl);
                resolve();
            }
        });

        this.pendingConnections.set(relayUrl, connectionPromise);
        connectionPromise.finally(() => {
            this.pendingConnections.delete(relayUrl);
        });

        return connectionPromise;
    },

    isBlacklistExpired(relayUrl) {
        if (!this.blacklistTimestamps.has(relayUrl)) {
            return true; // Not in timestamp map, shouldn't be blacklisted
        }

        const blacklistedAt = this.blacklistTimestamps.get(relayUrl);
        const now = Date.now();

        if (now - blacklistedAt > this.blacklistDuration) {
            this.blacklistedRelays.delete(relayUrl);
            this.blacklistTimestamps.delete(relayUrl);
            return true;
        }

        return false;
    },

    _canonicalRelayUrl(url) {
        return NymRelayBlock.canon(url);
    },

    _blockedRelayState() {
        if (!this._blockedRelays) {
            let raw = null;
            try { raw = JSON.parse(localStorage.getItem('nym_blocked_relays') || 'null'); } catch (_) { }
            this._blockedRelays = NymRelayBlock.norm(raw, Date.now());
            this._blockedRelaySetCache = null;
        }
        return this._blockedRelays;
    },

    _blockedRelaySet() {
        if (!this._blockedRelaySetCache) this._blockedRelaySetCache = new Set(NymRelayBlock.list(this._blockedRelayState()));
        return this._blockedRelaySetCache;
    },

    isRelayBlocked(url) {
        return NymRelayBlock.isBlocked(this._blockedRelaySet(), url);
    },

    blockedRelayList() {
        return NymRelayBlock.list(this._blockedRelayState());
    },

    _blockedRelaysForSync() {
        return NymRelayBlock.norm(this._blockedRelayState(), Date.now());
    },

    _nip46SignerRelay() {
        try {
            if (localStorage.getItem('nym_nostr_login_method') !== 'nip46') return '';
            return localStorage.getItem('nym_nip46_relay') || '';
        } catch (_) { return ''; }
    },

    relayBlockGuard(url) {
        return NymRelayBlock.guard(url, {
            blocked: this._blockedRelaySet(),
            defaults: this.defaultRelays,
            writeOnly: [...(this.writeOnlyRelays || [])],
            signer: this._nip46SignerRelay()
        });
    },

    _relayReaderContext() {
        return { defaults: this.defaultRelays, writeOnly: [...(this.writeOnlyRelays || [])] };
    },

    blockRelay(url, opts) {
        const why = this.relayBlockGuard(url);
        if (why !== 'ok' && !(why === 'signer' && opts && opts.confirmed)) return why;
        this._setBlockedRelayState(NymRelayBlock.block(this._blockedRelayState(), url, Date.now()));
        return 'blocked';
    },

    unblockRelay(url) {
        if (!this.isRelayBlocked(url)) return false;
        this._setBlockedRelayState(NymRelayBlock.unblock(this._blockedRelayState(), url, Date.now()));
        return true;
    },

    applySyncedBlockedRelays(remote) {
        const now = Date.now();
        const merged = NymRelayBlock.keepReader(NymRelayBlock.merge(this._blockedRelayState(), remote, now), this._relayReaderContext(), now);
        const behind = JSON.stringify(merged) !== JSON.stringify(NymRelayBlock.norm(remote, now));
        this._setBlockedRelayState(merged, { quiet: true });
        if (behind && typeof this._debouncedNostrSettingsSave === 'function') this._debouncedNostrSettingsSave(3000);
    },

    _setBlockedRelayState(next, opts) {
        const before = this._blockedRelaySet();
        this._blockedRelays = next;
        this._blockedRelaySetCache = null;
        try { localStorage.setItem('nym_blocked_relays', JSON.stringify(next)); } catch (_) { }
        const after = this._blockedRelaySet();
        const changes = [];
        for (const u of after) if (!before.has(u)) changes.push([u, true]);
        for (const u of before) if (!after.has(u)) changes.push([u, false]);
        if (changes.length) this._applyRelayBlockChanges(changes);
        if (!(opts && opts.quiet) && typeof this._debouncedNostrSettingsSave === 'function') this._debouncedNostrSettingsSave(1500);
        return changes.length > 0;
    },

    _applyRelayBlockChanges(changes) {
        for (const [url, blocked] of changes) {
            if (blocked) this._dropBlockedRelay(url);
            else this._restoreUnblockedRelay(url);
        }
        if (this.useRelayProxy && typeof this._poolSendRelayConfig === 'function') this._poolSendRelayConfig();
        if (typeof this.updateBlockedRelaysList === 'function') this.updateBlockedRelaysList();
        if (typeof this.updateConnectionStatus === 'function') this.updateConnectionStatus();
    },

    _isPoolSocket(ws) {
        if (!ws) return false;
        if (ws === this.poolSocket) return true;
        return (this.poolSockets || []).some(p => p.ws === ws);
    },

    _dropBlockedRelay(url) {
        const C = NymRelayBlock.canon;
        for (const [u, relay] of [...this.relayPool]) {
            if (C(u) !== url) continue;
            if (relay && relay.ws && !this._isPoolSocket(relay.ws)) {
                try { relay.ws.close(); } catch (_) { }
            }
            this.relayPool.delete(u);
            if (this._poolRelayLastSeen) this._poolRelayLastSeen.delete(u);
        }
        if (this.useRelayProxy) return;
        if (this.currentGeoRelays) {
            for (const u of [...this.currentGeoRelays]) if (C(u) === url) this.currentGeoRelays.delete(u);
        }
        if (this.geoRelayConnections) {
            for (const set of this.geoRelayConnections.values()) {
                for (const u of [...set]) if (C(u) === url) set.delete(u);
            }
        }
    },

    _wantedRelaySpelling(url) {
        const C = NymRelayBlock.canon;
        const geohash = this.currentGeohash && this.isValidGeohash && this.isValidGeohash(this.currentGeohash) ? this.currentGeohash : '';
        const nearest = geohash && !(this.settings && this.settings.groupChatPMOnlyMode)
            ? this.getClosestRelaysForGeohash(geohash).map(r => r.url) : [];
        const geoHit = nearest.find(u => C(u) === url);
        if (geoHit) return { url: geoHit, geo: true };
        const def = (this.defaultRelays || []).find(u => C(u) === url);
        if (def) return { url: def, geo: false };
        if (this.settings && (this.settings.lowDataMode || this.settings.groupChatPMOnlyMode)) return null;
        const geo = (this.geoRelays || []).map(r => r.url || r).find(u => typeof u === 'string' && C(u) === url);
        if (geo) return { url: geo, geo: false };
        const found = [...(this.allRelayUrls || [])].find(u => C(u) === url);
        return found ? { url: found, geo: false } : null;
    },

    _restoreUnblockedRelay(url) {
        if (this.useRelayProxy) return;
        const want = this._wantedRelaySpelling(url);
        if (!want) return;
        for (const u of new Set([want.url, url])) {
            if (this.failedRelays) this.failedRelays.delete(u);
            this.blacklistedRelays.delete(u);
            this.blacklistTimestamps.delete(u);
        }
        this.connectToRelay(want.url, 'relay').then(() => {
            const r = this.relayPool.get(want.url);
            if (!r || !r.ws || r.ws.readyState !== WebSocket.OPEN) return;
            this.subscribeToSingleRelay(want.url);
            if (want.geo) {
                this.currentGeoRelays.add(want.url);
                this._ensureGeoRelayLiveSub(r, want.url);
            }
            this.updateConnectionStatus();
        }).catch(() => { });
    },

    relayBlockLeavesGeoBare(url) {
        const geohash = this.currentGeohash;
        if (!geohash || !this.isValidGeohash || !this.isValidGeohash(geohash)) return '';
        if (this.settings && this.settings.groupChatPMOnlyMode) return '';
        const nearest = this.getClosestRelaysForGeohash(geohash).map(r => r.url);
        const C = NymRelayBlock.canon;
        const target = C(url);
        if (!nearest.some(u => C(u) === target)) return '';
        const next = new Set(this._blockedRelaySet());
        next.add(target);
        return NymRelayBlock.geoAllBlocked(nearest, next) ? geohash : '';
    },

    updateBlockedRelaysList() {
        const list = document.getElementById('blockedRelaysList');
        if (!list) return;
        const urls = this.blockedRelayList();
        list.textContent = '';
        const t = (s) => (typeof this.uiText === 'function' ? this.uiText(s) : s);
        if (!urls.length) {
            const empty = document.createElement('div');
            empty.className = 'list-empty-msg';
            empty.textContent = t('No blocked relays');
            list.appendChild(empty);
            return;
        }
        const frag = document.createDocumentFragment();
        for (const url of urls) {
            const row = document.createElement('div');
            row.className = 'blocked-item';
            row.dataset.relayUrl = url;
            const span = document.createElement('span');
            span.className = 'blocked-relay-url';
            span.title = url;
            span.textContent = NymRelayBlock.shown(url);
            const btn = document.createElement('button');
            btn.className = 'unblock-btn';
            btn.type = 'button';
            btn.textContent = t('Unblock');
            btn.addEventListener('click', () => this.unblockRelay(url));
            row.appendChild(span);
            row.appendChild(btn);
            frag.appendChild(row);
        }
        list.appendChild(frag);
    },

    relayBlockGeoNote(url) {
        const geohash = this.currentGeohash;
        if (!geohash || !this.isValidGeohash || !this.isValidGeohash(geohash)) return '';
        const nearest = this.getClosestRelaysForGeohash(geohash).map(r => r.url);
        const C = NymRelayBlock.canon;
        if (!nearest.some(u => C(u) === C(url))) return '';
        if (!NymRelayBlock.geoAllBlocked(nearest, this._blockedRelaySet())) return '';
        return geohash;
    },

    _throttledProxyFetch(url, opts) {
        return new Promise((resolve, reject) => {
            this._proxyFetchQueue.push({ url, opts, resolve, reject });
            this._drainProxyFetchQueue();
        });
    },

    _drainProxyFetchQueue() {
        while (this._proxyFetchActive < this._proxyFetchMaxConcurrent && this._proxyFetchQueue.length > 0) {
            const { url, opts, resolve, reject } = this._proxyFetchQueue.shift();
            this._proxyFetchActive++;
            fetch(url, opts)
                .then(resolve, reject)
                .finally(() => {
                    this._proxyFetchActive--;
                    this._drainProxyFetchQueue();
                });
        }
    },

    // Uses the production host when running locally; null if remote is down.
    _getProxyBaseUrl() {
        const host = this._getApiHost();
        if (!host) return null;
        return `https://${host}/api/proxy`;
    },

    _mediaProxyBase() {
        if (this._userDirectMode) return null;
        return this._getProxyBaseUrl();
    },

    // Fetch a JSON resource through the Cloudflare proxy when available.
    async proxiedJsonFetch(targetUrl, opts = {}) {
        const base = this._getProxyBaseUrl();
        if (!base) return fetch(targetUrl, opts);
        const proxyUrl = `${base}?action=json&url=${encodeURIComponent(targetUrl)}`;
        let resp;
        try {
            resp = await this._edgeFetch(proxyUrl, opts);
        } catch (err) {
            if (!this._proxyUnreachable(err)) throw err;
            return fetch(targetUrl, opts);
        }
        return this._proxyUnreachable(resp) ? fetch(targetUrl, opts) : resp;
    },

    async fetchGeocode(lat, lng, zoom = 10) {
        const base = this._getProxyBaseUrl();
        const direct = `https://nominatim.openstreetmap.org/reverse?format=json&lat=${lat}&lon=${lng}&zoom=${zoom}&accept-language=en`;
        if (base) {
            let res = null;
            try {
                res = await this._edgeFetch(`${base}?action=geocode&lat=${lat}&lng=${lng}&zoom=${zoom}&lang=en`);
            } catch (err) {
                if (!this._proxyUnreachable(err)) throw err;
            }
            if (res && !this._proxyUnreachable(res)) {
                if (!res.ok) throw new Error(`Geocode failed: ${res.status}`);
                return res.json();
            }
        }
        const res = await fetch(direct, { headers: { 'Accept-Language': 'en' } });
        if (!res.ok) throw new Error(`Geocode failed: ${res.status}`);
        return res.json();
    },

    // Edge-cached proxy, with a direct Giphy fallback if the worker is unreachable.
    async fetchGiphy({ trending = false, query = '', apiKey }) {
        const base = this._mediaProxyBase();
        const directUrl = trending
            ? `https://api.giphy.com/v1/gifs/trending?api_key=${encodeURIComponent(apiKey)}&limit=20&rating=g`
            : `https://api.giphy.com/v1/gifs/search?api_key=${encodeURIComponent(apiKey)}&q=${encodeURIComponent(query)}&limit=20&rating=g`;
        if (base) {
            try {
                const params = trending
                    ? `trending=1&api_key=${encodeURIComponent(apiKey)}`
                    : `q=${encodeURIComponent(query)}&api_key=${encodeURIComponent(apiKey)}`;
                const res = await this._edgeFetch(`${base}?action=giphy&${params}`);
                if (res.ok) return await res.json();
            } catch (_) { /* fall through */ }
        }
        const res = await fetch(directUrl);
        if (!res.ok) throw new Error(`Giphy failed: ${res.status}`);
        return res.json();
    },

    sendToRelay(message) {
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            // Route EVENTs through broadcastEvent so geohash-tagged events use GEO_EVENT.
            if (Array.isArray(message) && message[0] === 'EVENT') {
                this.broadcastEvent(message);
            } else {
                this._poolSend(message);
            }
            return;
        }

        const msg = JSON.stringify(message);

        if (Array.isArray(message) && message[0] === 'EVENT') {
            this.broadcastEvent(message);
        } else if (Array.isArray(message) && message[0] === 'REQ') {
            this.sendRequestToAllRelays(message);
        } else {
            const targets = [];
            this.relayPool.forEach((relay) => {
                if (relay.ws && relay.ws.readyState === WebSocket.OPEN) targets.push(relay);
            });
            const critical = Array.isArray(message) && message[0] === 'CLOSE';
            this._broadcastAsync(targets, msg, { critical });
        }
    },

    _anyRelayOpen() {
        if (this._isAnyPoolOpen()) return true;
        for (const relay of this.relayPool.values()) {
            if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) return true;
        }
        return false;
    },

    _heldKept(h) {
        if (!h || !Array.isArray(h.message) || !h.message[1]) return false;
        const ev = h.message[1];
        if (h.kind === 'event' && ev.kind === 0) return true;
        return !!(this._queuedSends && this._queuedSends.has(ev.id));
    },

    _holdEvent(kind, message) {
        if (!this._heldEvents) this._heldEvents = [];
        const entry = { kind, message, at: Date.now() };
        const kept = this._heldKept(entry);
        const same = this._heldEvents.filter((h) => this._heldKept(h) === kept);
        if (same.length >= (kept ? HELD_SENDS_MAX : HELD_EVENTS_MAX)) {
            this._heldEvents.splice(this._heldEvents.indexOf(same[0]), 1);
        }
        this._heldEvents.push(entry);
    },

    _flushHeldEvents() {
        const list = this._heldEvents || [];
        this._heldEvents = [];
        const now = Date.now();
        for (const h of list) {
            if (now - h.at > HELD_EVENTS_MS && !this._heldKept(h)) continue;
            if (h.kind === 'dm') this.sendDMToRelays(h.message);
            else this.broadcastEvent(h.message);
        }
        this._dmOutboxDrain();
        this._syncComposerConnHint();
    },

    _noteQueuedSend(eventId, domId) {
        if (!eventId) return;
        if (!this._queuedSends) this._queuedSends = new Map();
        const dom = domId || eventId;
        this._queuedSends.set(eventId, dom);
        this._paintQueued(dom, true);
        this._syncComposerConnHint();
    },

    _settleQueuedSend(eventId) {
        const q = this._queuedSends;
        if (!q || !eventId || !q.has(eventId)) return;
        const dom = q.get(eventId);
        q.delete(eventId);
        if (!this._isQueuedDomId(dom)) this._paintQueued(dom, false);
        this._syncComposerConnHint();
    },

    _isQueuedDomId(domId) {
        const q = this._queuedSends;
        if (!q || !q.size || !domId) return false;
        for (const v of q.values()) if (v === domId) return true;
        return false;
    },

    _paintQueuedEl(el, on) {
        if (!el) return;
        el.classList.toggle('msg-queued', !!on);
        let tag = el.querySelector(':scope > .msg-queued-tag');
        if (on && !tag) {
            tag = document.createElement('span');
            tag.className = 'msg-queued-tag';
            const label = this._composerQueuedLabel();
            tag.textContent = typeof this.uiText === 'function' ? this.uiText(label) : label;
            el.appendChild(tag);
        } else if (!on && tag) {
            tag.remove();
        }
    },

    _paintQueued(domId, on) {
        if (typeof document === 'undefined' || !domId) return;
        const sel = `[data-message-id="${String(domId).replace(/["\\]/g, '\\$&')}"]`;
        document.querySelectorAll(sel).forEach((el) => this._paintQueuedEl(el, on));
    },

    _composerConnText(state) {
        return COMPOSER_CONN_TEXT[state] || '';
    },

    _composerQueuedLabel() {
        return COMPOSER_QUEUED_LABEL;
    },

    _composerConnStateFor(o) {
        if (o.relayOpen) return '';
        if (o.meshCarries) return 'mesh';
        if (o.deviceOffline || o.connectFailed) return 'offline';
        return 'connecting';
    },

    _composerConnState() {
        return this._composerConnStateFor({
            relayOpen: this._anyRelayOpen(),
            meshCarries: typeof this.meshShouldCarry === 'function' && !!this.meshShouldCarry(this.currentGeohash || this.currentChannel),
            deviceOffline: typeof navigator !== 'undefined' && navigator.onLine === false,
            connectFailed: !this.initialConnectionInProgress && /Failed|Disconnected/.test(this._connStatusText || '')
        });
    },

    _connNoticeGraceMs() {
        return CONN_NOTICE_GRACE_MS;
    },

    _connNoticeStep(memo, t, state, restart) {
        if (!state) return { since: null, armed: false, shown: '' };
        const m = memo && !restart ? memo : { since: null, armed: false };
        const since = m.since == null ? t : m.since;
        const armed = !!m.armed || t - since >= CONN_NOTICE_GRACE_MS;
        return { since, armed, shown: armed ? state : '' };
    },

    _connNoticeNow() {
        return typeof performance !== 'undefined' && typeof performance.now === 'function' ? performance.now() : Date.now();
    },

    _connNoticeArmed() {
        return !!(this._connNotice && this._connNotice.armed);
    },

    _armConnNoticeTimer(g) {
        const due = g.since != null && !g.armed ? g.since + CONN_NOTICE_GRACE_MS : null;
        if (this._connNoticeDue === due) return;
        if (this._connNoticeTimer) clearTimeout(this._connNoticeTimer);
        this._connNoticeTimer = null;
        this._connNoticeDue = due;
        if (due == null) return;
        this._connNoticeTimer = setTimeout(() => {
            this._connNoticeTimer = null;
            this._connNoticeDue = null;
            if (this._connNotice && this._connNotice.since != null) this._connNotice.armed = true;
            this._syncComposerConnHint();
        }, Math.max(0, due - this._connNoticeNow()));
    },

    _restartConnNotice() {
        this._connNotice = null;
        this._syncComposerConnHint();
    },

    _syncComposerConnHint() {
        if (typeof document === 'undefined') return;
        if (!this._connHintWired && typeof window !== 'undefined') {
            this._connHintWired = true;
            const resync = () => this._syncComposerConnHint();
            window.addEventListener('online', resync);
            window.addEventListener('offline', resync);
            document.addEventListener('visibilitychange', () => {
                if (document.visibilityState === 'visible') this._restartConnNotice();
            });
        }
        const raw = this.pubkey ? this._composerConnState() : '';
        const g = this._connNoticeStep(this._connNotice, this._connNoticeNow(), raw, false);
        this._connNotice = g;
        this._armConnNoticeTimer(g);
        this._paintConnStatus();
        const el = document.getElementById('composerConnHint');
        if (!el) return;
        const state = g.shown;
        const text = this._composerConnText(state);
        const shown = text && typeof this.uiText === 'function' ? this.uiText(text) : text;
        if (el.textContent !== shown) el.textContent = shown;
        el.hidden = !state;
        this._watchComposerConnHintPlace(el);
        if (state) this._placeComposerConnHint(el);
        if (typeof this._syncFloatOffsets === 'function') this._syncFloatOffsets();
    },

    _watchComposerConnHintPlace(el) {
        if (this._connHintRO || typeof ResizeObserver === 'undefined') return;
        const wrapper = el.parentElement;
        const container = el.closest('.input-container');
        if (!wrapper || !container) return;
        this._connHintRO = new ResizeObserver(() => {
            if (!el.hidden) this._placeComposerConnHint(el);
        });
        this._connHintRO.observe(wrapper);
        this._connHintRO.observe(container);
    },

    _placeComposerConnHint(el) {
        const wrapper = el.parentElement;
        const container = el.closest('.input-container');
        if (!wrapper || !container) return;
        const w = wrapper.getBoundingClientRect();
        const c = container.getBoundingClientRect();
        const cs = getComputedStyle(container);
        const innerL = c.left + (parseFloat(cs.borderLeftWidth) || 0) + (parseFloat(cs.paddingLeft) || 0);
        const innerR = c.right - (parseFloat(cs.borderRightWidth) || 0) - (parseFloat(cs.paddingRight) || 0);
        const l = (w.left - innerL).toFixed(2) + 'px';
        const r = (innerR - w.right).toFixed(2) + 'px';
        if (wrapper.style.getPropertyValue('--conn-hint-l') !== l) wrapper.style.setProperty('--conn-hint-l', l);
        if (wrapper.style.getPropertyValue('--conn-hint-r') !== r) wrapper.style.setProperty('--conn-hint-r', r);
    },

    sendDMToRelays(message, opts) {
        const ev = Array.isArray(message) && message[0] === 'EVENT' ? message[1] : null;
        if (!ev || typeof ev.id !== 'string' || !ev.id) return this._sendDMNow(message);
        const tier = opts && Number.isInteger(opts.tier) ? opts.tier : 0;
        this._dmOutboxPush(message, tier, 0);
        return this._dmOutboxDrain();
    },

    _dmOutboxW() {
        return (typeof self !== 'undefined' && self.NymWrapOutbox) || (typeof window !== 'undefined' && window.NymWrapOutbox) || null;
    },

    _dmOutboxPush(message, tier, tries) {
        if (!this._dmOutbox) this._dmOutbox = [[], [], []];
        if (!this._dmOutboxIds) this._dmOutboxIds = new Set();
        const id = message[1].id;
        if (this._dmOutboxIds.has(id)) return;
        const t = tier === 0 || tier === 1 || tier === 2 ? tier : 1;
        this._dmOutboxSeq = (this._dmOutboxSeq || 0) + 1;
        const entry = { id, tier: t, seq: this._dmOutboxSeq, message, tries: tries || 0 };
        if (tries) this._dmOutbox[t].unshift(entry);
        else this._dmOutbox[t].push(entry);
        this._dmOutboxIds.add(id);
        const cap = this.DM_OUTBOX_MAX || 2000;
        const all = this._dmOutbox[0].length + this._dmOutbox[1].length + this._dmOutbox[2].length;
        const W = this._dmOutboxW();
        if (all <= cap || !W) return;
        const flat = [].concat(this._dmOutbox[0], this._dmOutbox[1], this._dmOutbox[2]);
        const gone = new Set(W.queueEvict(flat, cap).evicted);
        for (let i = 0; i < 3; i++) this._dmOutbox[i] = this._dmOutbox[i].filter(e => !gone.has(e.id));
        gone.forEach(x => this._dmOutboxIds.delete(x));
        this._dmOutboxDropped = (this._dmOutboxDropped || 0) + gone.size;
        if (!this._dmOutboxDropWarnTs || Date.now() - this._dmOutboxDropWarnTs > 30000) {
            this._dmOutboxDropWarnTs = Date.now();
            console.warn('[Relay] DM outbox full; dropped', this._dmOutboxDropped, 'wraps');
        }
    },

    _dmOutboxSize() {
        const q = this._dmOutbox;
        return q ? q[0].length + q[1].length + q[2].length : 0;
    },

    _dmOutboxCharge(units) {
        const W = this._dmOutboxW();
        if (!W) return;
        this._dmOutboxBucket = W.bucketTake(this._dmOutboxBucket, Date.now(), units, this.DM_OUTBOX_BUCKET || W.RELAY_BUCKET, true).state;
    },

    _dmOutboxArm(ms) {
        if (this._dmOutboxTimer) return;
        this._dmOutboxTimer = setTimeout(() => {
            this._dmOutboxTimer = null;
            this._dmOutboxDrain();
        }, Math.max(50, ms));
    },

    _dmOutboxDrain() {
        if (!this._dmOutboxSize()) return 0;
        if (!this._anyRelayOpen()) {
            this._dmOutboxArm(1000);
            return 0;
        }
        const W = this._dmOutboxW();
        let sent = 0;
        while (this._dmOutboxSize()) {
            if (W) {
                const r = W.bucketTake(this._dmOutboxBucket, Date.now(), 1, this.DM_OUTBOX_BUCKET || W.RELAY_BUCKET);
                this._dmOutboxBucket = r.state;
                if (!r.ok) {
                    this._dmOutboxArm(r.waitMs);
                    break;
                }
            }
            const q = this._dmOutbox[0].length ? this._dmOutbox[0] : (this._dmOutbox[1].length ? this._dmOutbox[1] : this._dmOutbox[2]);
            const entry = q.shift();
            this._dmOutboxIds.delete(entry.id);
            this._dmOutboxTrackInflight(entry);
            sent = this._sendDMNow(entry.message);
        }
        return sent;
    },

    _dmOutboxTrackInflight(entry) {
        if (!this._dmInflight) this._dmInflight = new Map();
        const now = Date.now();
        this._dmInflight.delete(entry.id);
        this._dmInflight.set(entry.id, { message: entry.message, tier: entry.tier, tries: entry.tries, at: now });
        for (const [id, v] of this._dmInflight) {
            if (now - v.at <= 120000 && this._dmInflight.size <= 4000) break;
            this._dmInflight.delete(id);
        }
    },

    _dmOutboxRefused(eventId) {
        const v = this._dmInflight && this._dmInflight.get(eventId);
        if (!v) return false;
        this._dmInflight.delete(eventId);
        const W = this._dmOutboxW();
        if (W) {
            const st = W.bucketTake(this._dmOutboxBucket, Date.now(), 0, this.DM_OUTBOX_BUCKET || W.RELAY_BUCKET).state;
            this._dmOutboxBucket = { tokens: Math.min(st.tokens, 0), at: st.at };
        }
        if (v.tries + 1 > (this.DM_OUTBOX_MAX_TRIES || 8)) {
            this._dmOutboxFailed = (this._dmOutboxFailed || 0) + 1;
            return false;
        }
        this._dmOutboxPush(v.message, v.tier, v.tries + 1);
        this._dmOutboxDrain();
        return true;
    },

    _sendDMNow(message) {
        if (!this._anyRelayOpen()) {
            this._holdEvent('dm', message);
            return 0;
        }
        if (Array.isArray(message) && message[1]) this._settleQueuedSend(message[1].id);
        this._trackSentEventKind(message);
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            const eventObj = Array.isArray(message) && message[0] === 'EVENT' ? message[1] : message;
            this._poolSend(['DM_EVENT', eventObj]);
            return this.poolConnectedRelays.length;
        }

        const msg = JSON.stringify(message);
        const sent = new Set();
        const priority = [];
        const rest = [];

        for (const url of this.defaultRelays) {
            const relay = this.relayPool.get(url);
            if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                priority.push(relay);
                sent.add(url);
            }
        }
        this.relayPool.forEach((relay, url) => {
            if (!sent.has(url) && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                rest.push(relay);
            }
        });

        this._broadcastAsync(priority, msg, { critical: true });
        this._broadcastAsync(rest, msg, { critical: true });

        return sent.size;
    },

    sendRequestToAllRelays(message) {
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            this._poolSend(message);
            return;
        }

        const msg = JSON.stringify(message);
        const targets = [];
        this.relayPool.forEach((relay, url) => {
            if (this.writeOnlyRelays && this.writeOnlyRelays.has(url)) return;
            if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                targets.push(relay);
            }
        });
        this._broadcastAsync(targets, msg, { critical: true });
    },

    sendRequestToFewRelays(message, maxRelays = 5) {
        // Pool mode: critical relays only (profiles don't need geo).
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            this._poolSendToRole('critical', message);
            return;
        }

        const msg = JSON.stringify(message);
        let sent = 0;
        const subId = Array.isArray(message) && message[0] === 'REQ' ? message[1] : null;

        const sendTo = (relay, url) => {
            if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                if (this._safeWsSend(relay.ws, msg, { critical: true })) {
                    if (subId) {
                        if (!relay.subscriptions) relay.subscriptions = new Set();
                        relay.subscriptions.add(subId);
                    }
                    sent++;
                    return true;
                }
            }
            return false;
        };

        for (const url of this.defaultRelays) {
            if (sent >= maxRelays) break;
            if (this.writeOnlyRelays && this.writeOnlyRelays.has(url)) continue;
            const relay = this.relayPool.get(url);
            if (relay) sendTo(relay, url);
        }

        if (sent < maxRelays) {
            for (const [url, relay] of this.relayPool) {
                if (sent >= maxRelays) break;
                if (this.defaultRelays.includes(url)) continue;
                if (this.writeOnlyRelays && this.writeOnlyRelays.has(url)) continue;
                sendTo(relay, url);
            }
        }
    },

    // Uses the REQ's destinations so relays that never saw it don't answer "No such subscription".
    closeFewRelaysSub(subId) {
        if (!subId) return;
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            this._poolSendToRole('critical', ["CLOSE", subId]);
            return;
        }
        const closeMsg = JSON.stringify(["CLOSE", subId]);
        this.relayPool.forEach((relay) => {
            if (!relay || !relay.ws || relay.ws.readyState !== WebSocket.OPEN) return;
            if (relay.subscriptions && relay.subscriptions.has(subId)) {
                this._safeWsSend(relay.ws, closeMsg, { critical: true });
                relay.subscriptions.delete(subId);
            }
        });
    },

    broadcastEvent(message) {
        if (Array.isArray(message) && message[0] === 'EVENT' && this._quietHit(message[1])) return;
        if (!this._anyRelayOpen()) {
            this._holdEvent('event', message);
            return;
        }
        if (Array.isArray(message) && message[1]) this._settleQueuedSend(message[1].id);
        this._trackSentEventKind(message);
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            let evt = null;
            try {
                if (Array.isArray(message) && message[0] === 'EVENT' && message[1] && typeof message[1] === 'object') {
                    evt = message[1];
                }
            } catch (_) { }
            // Only geohash channel messages (kind 20000) target geo relays.
            const geohashTag = evt && evt.kind === 20000 && evt.tags && evt.tags.find(t => t[0] === 'g');
            if (geohashTag && geohashTag[1]) {
                const closestRelays = this.getClosestRelaysForGeohash(geohashTag[1]);
                if (closestRelays.length > 0) {
                    const geoMsg = JSON.stringify(['GEO_EVENT', evt, closestRelays.map(r => r.url)]);
                    for (const p of this.poolSockets) {
                        this._safeWsSend(p.ws, geoMsg, { critical: true });
                    }
                    return;
                }
            }
            this._poolSend(message);
            return;
        }

        const msg = JSON.stringify(message);

        let evt = null;
        try {
            if (Array.isArray(message) && message[0] === 'EVENT' && message[1] && typeof message[1] === 'object') {
                evt = message[1];
            }
        } catch (_) { }

        const is30078Fanout = evt && evt.kind === 30078 && evt.tags && evt.tags.some(t => t[0] === 't' && ['nym-poll', 'nym-poll-vote'].includes(t[1]));
        const wideFanout = evt && (evt.kind === 0 || evt.kind === 5 || evt.kind === 7 || evt.kind === 20000 || evt.kind === 23333 || evt.kind === 9734 || evt.kind === 9735 || evt.kind === 1059 || evt.kind === 25051 || evt.kind === 25052 || is30078Fanout);

        const writeOnly = this.writeOnlyRelays || new Set();
        const writeOnlyTargets = [];
        writeOnly.forEach(url => {
            const r = this.relayPool.get(url);
            if (r && r.ws && r.ws.readyState === WebSocket.OPEN) writeOnlyTargets.push(r);
        });

        if (wideFanout) {
            const sent = new Set(writeOnly);
            const geoTargets = [];
            const otherTargets = [];
            const geohashTag = evt && evt.tags && evt.tags.find(t => t[0] === 'g');
            if (geohashTag && geohashTag[1]) {
                const closestRelays = this.getClosestRelaysForGeohash(geohashTag[1]);
                for (const r of closestRelays) {
                    const relay = this.relayPool.get(r.url);
                    if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                        geoTargets.push(relay);
                        sent.add(r.url);
                    }
                }
            }
            this.relayPool.forEach((relay, url) => {
                if (!sent.has(url) && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                    otherTargets.push(relay);
                }
            });
            this._broadcastAsync(writeOnlyTargets, msg, { critical: true });
            this._broadcastAsync(geoTargets, msg, { critical: true });
            this._broadcastAsync(otherTargets, msg, { critical: true });
        } else {
            const targets = [];
            this.defaultRelays.forEach(relayUrl => {
                if (writeOnly.has(relayUrl)) return;
                const relay = this.relayPool.get(relayUrl);
                if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) targets.push(relay);
            });
            this._broadcastAsync(writeOnlyTargets, msg, { critical: true });
            this._broadcastAsync(targets, msg, { critical: true });
        }
    },

    subscribeToAllRelays() {
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            this._poolSubscribe();
            this.discoverChannels();
            setTimeout(() => {
                this.loadJoinedChannelsFromRelays();
            }, 2000);
            return;
        }

        const readableRelays = Array.from(this.relayPool.entries())
            .filter(([url, relay]) => relay.ws && relay.ws.readyState === WebSocket.OPEN);

        if (readableRelays.length === 0) {
            return;
        }

        readableRelays.forEach(([url, relay]) => {
            this.subscribeToSingleRelay(url);
        });

        this._refreshEphemeralSubscriptions();
        this._resubscribeChannels();
        this._catchUpLiveGap();

        this.discoverChannels();

        setTimeout(() => {
            this.loadJoinedChannelsFromRelays();
        }, 2000);
    },

    loadJoinedChannelsFromRelays() {
        if (this.settings.groupChatPMOnlyMode) return;

        // Debounce: don't re-batch joined channels more than once per 30s.
        const now = Date.now();
        if (this._lastJoinedChannelsLoadAt && now - this._lastJoinedChannelsLoadAt < 30000) return;

        const channelsToLoad = [];
        const seen = new Set();
        const add = (key, type) => {
            if (!key || seen.has(key)) return;
            if (this.channelLoadedFromRelays.has(key)) return;
            seen.add(key);
            channelsToLoad.push({ key, type });
        };

        this.userJoinedChannels.forEach(k => add(k, 'geohash'));
        this.commonGeohashes.forEach(g => add(g, 'geohash'));
        if (this.currentChannel) add(this.currentChannel, 'geohash');

        if (channelsToLoad.length === 0) return;
        this._lastJoinedChannelsLoadAt = now;

        const batchSize = this.channelSubscriptionBatchSize;
        for (let i = 0; i < channelsToLoad.length; i += batchSize) {
            const batch = channelsToLoad.slice(i, i + batchSize);
            setTimeout(() => {
                this.subscribeToChannelBatch(batch);
            }, Math.floor(i / batchSize) * 500);
        }
    },

    // true/false when the id is known-verified (cheap hash check), undefined when unknown.
    _verifiedIdCheck(event) {
        try {
            if (!this._verifiedEventIds) this._verifiedEventIds = new Set();
            const id = event && typeof event.id === 'string' ? event.id : null;
            if (!id || !this._verifiedEventIds.has(id)) return undefined;
            const NT = window.NostrTools;
            if (!NT || typeof NT.getEventHash !== 'function') return undefined;
            return NT.getEventHash(event) === id;
        } catch (_) {
            return false;
        }
    },

    _noteVerifiedEventId(id) {
        if (typeof id !== 'string' || !id) return;
        if (!this._verifiedEventIds) this._verifiedEventIds = new Set();
        this._verifiedEventIds.add(id);
        if (this._verifiedEventIds.size > 20000) {
            let toDrop = this._verifiedEventIds.size - 15000;
            for (const key of this._verifiedEventIds) {
                if (toDrop-- <= 0) break;
                this._verifiedEventIds.delete(key);
            }
        }
        // Persisted so the next session's replay skips the verify workers too (_hydrateDedupSets).
        if (typeof this._persistDedupSets === 'function') this._persistDedupSets();
    },

    _verifyRelayEvent(event) {
        try {
            const NT = window.NostrTools;
            if (!NT || typeof NT.verifyEvent !== 'function') return false;
            const cached = this._verifiedIdCheck(event);
            if (cached !== undefined) return cached;
            if (NT.verifyEvent(event) !== true) return false;
            this._noteVerifiedEventId(event.id);
            return true;
        } catch (_) {
            return false;
        }
    },

    async _verifyRelayEventAsync(event) {
        const cached = this._verifiedIdCheck(event);
        if (cached !== undefined) return cached;
        if (!this._getVerifyWorker()) return this._verifyRelayEvent(event);
        const ok = await this._workerVerify(event);
        if (ok === null) return this._verifyRelayEvent(event);
        if (ok === true) this._noteVerifiedEventId(event.id);
        return ok === true;
    },

    _getVerifyWorker() {
        if (this._verifyWorkerFailed) return null;
        if (this._verifyPool) return this._verifyPool.length ? this._verifyPool : null;
        if (typeof Worker !== 'function') {
            this._verifyWorkerFailed = true;
            return null;
        }
        this._verifyWorkerSeq = 0;
        this._verifyWorkerPending = new Map();
        this._verifyPool = [];
        const n = Math.max(1, Math.min(navigator.hardwareConcurrency || 2, 4));
        for (let i = 0; i < n; i++) {
            let w;
            try { w = new Worker('/js/verify-worker.js'); }
            catch (_) { continue; }
            const rec = { w, busy: 0 };
            w.onmessage = (e) => {
                const d = e.data || {};
                const p = this._verifyWorkerPending.get(d.seq);
                if (p) {
                    this._verifyWorkerPending.delete(d.seq);
                    rec.busy--;
                    p.resolve(d.ok === true);
                }
            };
            // Resolve the failed worker's in-flight checks with null so callers fall back to sync verification.
            w.onerror = () => this._dropVerifyWorker(rec);
            w.onmessageerror = () => this._dropVerifyWorker(rec);
            this._verifyPool.push(rec);
        }
        if (!this._verifyPool.length) { this._verifyWorkerFailed = true; return null; }
        return this._verifyPool;
    },

    _dropVerifyWorker(rec) {
        const pool = this._verifyPool;
        if (pool) {
            const i = pool.indexOf(rec);
            if (i >= 0) pool.splice(i, 1);
        }
        for (const [seq, p] of this._verifyWorkerPending) {
            if (p.rec !== rec) continue;
            this._verifyWorkerPending.delete(seq);
            p.resolve(null);
        }
        try { rec.w.terminate(); } catch (_) { }
        if (pool && !pool.length) this._verifyWorkerFailed = true;
    },

    _workerVerify(event) {
        return new Promise((resolve) => {
            const pool = this._getVerifyWorker();
            if (!pool || !pool.length) { resolve(null); return; }
            let rec = pool[0];
            for (const r of pool) if (r.busy < rec.busy) rec = r;
            const seq = ++this._verifyWorkerSeq;
            this._verifyWorkerPending.set(seq, { resolve, rec });
            rec.busy++;
            try {
                rec.w.postMessage({ seq, event });
            } catch (_) {
                this._verifyWorkerPending.delete(seq);
                rec.busy--;
                resolve(null);
            }
        });
    },

    _trackRelayKindData(relayUrl, kind, bytes) {
        if (typeof relayUrl !== 'string' || !relayUrl.startsWith('wss://')) relayUrl = 'relay-pool';
        if (!this.relayStats.kindStatsPerRelay) this.relayStats.kindStatsPerRelay = new Map();
        let perKind = this.relayStats.kindStatsPerRelay.get(relayUrl);
        if (!perKind) { perKind = new Map(); this.relayStats.kindStatsPerRelay.set(relayUrl, perKind); }
        let s = perKind.get(kind);
        if (!s) { s = { count: 0, bytes: 0 }; perKind.set(kind, s); }
        s.count++;
        s.bytes += bytes || 0;
    },

    _anyRelayConnected(urls) {
        if (this.useRelayProxy) {
            for (const u of (this.poolConnectedRelays || [])) if (urls.has(u)) return true;
            return false;
        }
        for (const u of urls) {
            const r = this.relayPool.get(u);
            if (r && r.ws && r.ws.readyState === WebSocket.OPEN) return true;
        }
        return false;
    },

    // Kind 20000 only: bitchat uses a geohash's nearest relays (iOS ∪ Android), so other sources sprayed the tag.
    _geoOriginAllows(event, relayUrl) {
        if (!event || event.kind !== 20000) return true;
        if (typeof relayUrl !== 'string' || !relayUrl) return true;
        const tags = Array.isArray(event.tags) ? event.tags : [];
        const tag = tags.find(t => Array.isArray(t) && t[0] === 'g');
        const geohash = tag && typeof tag[1] === 'string' ? tag[1].toLowerCase() : '';
        if (!geohash || !this.isValidGeohash(geohash)) return true;

        const closest = this.getClosestRelaysForGeohash(geohash);
        // Refusing here would empty every geohash channel on a cold start or failed CSV fetch.
        if (!closest.length) return true;

        const allow = new Set(closest.map(r => r.url));
        if (allow.has(relayUrl)) return true;
        // No admissible source is held, so rejecting would hide the channel rather than filter it.
        if (!this._anyRelayConnected(allow)) return true;
        return false;
    },

    _isAppRelayOnlyEvent(event) {
        if (!event || !Array.isArray(event.tags)) return false;
        if (!this.APP_RELAY_ONLY_KINDS.has(event.kind)) return false;
        const tagVal = (name) => {
            const t = event.tags.find(x => Array.isArray(x) && x[0] === name);
            return t && typeof t[1] === 'string' ? t[1].toLowerCase() : '';
        };
        const channel = event.kind === 23333 ? tagVal('d') : (tagVal('g') || tagVal('d'));
        return channel === this.APP_RELAY_ONLY_CHANNEL;
    },

    // FIFO gate: EVENTs verify in the worker; everything dispatches in arrival
    // order so EOSE/OK never overtake the events that preceded them
    handleRelayMessage(msg, relayUrl) {
        if (!Array.isArray(msg)) return;
        if (!this._relayMsgQueue) this._relayMsgQueue = [];
        const entry = { msg, relayUrl, ready: true, ok: true };
        if (msg[0] === 'EVENT') {
            const ev = msg[2];
            if (this._quietHit(ev)) return;
            const source = (typeof msg[3] === 'string' && msg[3].startsWith('wss://'))
                ? msg[3]
                : ((typeof relayUrl === 'string' && relayUrl.startsWith('wss://')) ? relayUrl : null);
            if (this._isAppRelayOnlyEvent(ev) && source !== this.appRelay) return;
            const cached = this._verifiedIdCheck(ev);
            if (cached !== undefined) {
                entry.ok = cached;
            } else if (!this._getVerifyWorker()) {
                entry.ok = this._verifyRelayEvent(ev);
            } else {
                entry.ready = false;
                this._workerVerify(ev).then((ok) => {
                    if (ok === null) ok = this._verifyRelayEvent(ev);
                    else if (ok === true) this._noteVerifiedEventId(ev.id);
                    entry.ok = ok === true;
                    entry.ready = true;
                    this._drainRelayMessageQueue();
                });
            }
        }
        this._relayMsgQueue.push(entry);
        this._drainRelayMessageQueue();
    },

    _drainRelayMessageQueue() {
        if (this._relayQueueDraining) return;
        this._relayQueueDraining = true;
        let rescheduled = false;
        try {
            const start = Date.now();
            while (this._relayMsgQueue.length && this._relayMsgQueue[0].ready) {
                const entry = this._relayMsgQueue.shift();
                if (entry.ok) this._dispatchRelayMessage(entry.msg, entry.relayUrl);
                if (Date.now() - start > 12 && this._relayMsgQueue.length && this._relayMsgQueue[0].ready) {
                    rescheduled = true;
                    let resumed = false;
                    const resume = () => {
                        if (resumed) return;
                        resumed = true;
                        if (this._relayQueueResume === resume) this._relayQueueResume = null;
                        this._relayQueueDraining = false;
                        this._drainRelayMessageQueue();
                    };
                    this._relayQueueResume = resume;
                    if (typeof this._yieldToIdle === 'function') this._yieldToIdle().then(resume, resume);
                    setTimeout(resume, 100);
                    return;
                }
            }
        } finally {
            if (!rescheduled) this._relayQueueDraining = false;
        }
    },

    _dispatchRelayMessage(msg, relayUrl) {
        const [type, ...data] = msg;

        if (this._subscriptionHandlers && this._subscriptionHandlers.size) {
            const handler = this._subscriptionHandlers.get(data[0]);
            if (handler) handler(type, data, relayUrl);
        }

        switch (type) {
            case 'EVENT':
                const [subscriptionId, event, sourceRelay] = data;

                if (event && event.id) {
                    const attributed = (typeof sourceRelay === 'string' && sourceRelay.startsWith('wss://'))
                        ? sourceRelay
                        : (relayUrl && relayUrl !== 'relay-pool' ? relayUrl : null);
                    // Before the dedup return: the duplicate copies are the list of relays this event came from.
                    if (typeof this.recordEventProvenance === 'function') {
                        this.recordEventProvenance(event, attributed);
                    }
                    if (this.eventDeduplication.has(event.id)) {
                        return;
                    }

                    this.eventDeduplication.set(event.id, true);
                    this.relayStats.totalEvents++;
                    this.relayStats.eventsThisSecond++;

                    const attributedRelay = attributed;
                    if (attributedRelay) {
                        const cur = this.relayStats.eventsPerRelay.get(attributedRelay) || 0;
                        this.relayStats.eventsPerRelay.set(attributedRelay, cur + 1);
                        // Same post-dedup event, so the per-kind view sums to the collapsed count.
                        if (typeof event.kind === 'number') {
                            this._trackRelayKindData(attributedRelay, event.kind, JSON.stringify(event).length);
                        }
                    }

                    if (this.eventDeduplication.size > 10000) {
                        const entriesToDelete = this.eventDeduplication.size - 10000;
                        let deleted = 0;
                        for (const key of this.eventDeduplication.keys()) {
                            if (deleted >= entriesToDelete) break;
                            this.eventDeduplication.delete(key);
                            deleted++;
                        }
                    }
                }

                this.handleEvent(event);
                break;
            case 'POOL:SEEN': {
                // A relay the proxy deduped away; this only adds the source.
                if (typeof this.noteEventRelay === 'function') {
                    this.noteEventRelay(data[0], data[1]);
                }
                break;
            }
            case 'OK': {
                const okEventId = data[0];
                const accepted = data[1];
                const reason = data[2] || '';
                const attributedRelay = (typeof data[3] === 'string' && data[3].startsWith('wss://'))
                    ? data[3] : relayUrl;
                const r = typeof reason === 'string' ? reason : '';
                const hasEventId = typeof okEventId === 'string' && okEventId.length > 0;
                if (accepted === true && hasEventId && this._dmInflight) this._dmInflight.delete(okEventId);
                if (this._isUnsupportedKind(reason)) {
                    if (hasEventId) this._recordEventKindRejection(attributedRelay, okEventId);
                    else this._permanentlyBlacklistRelay(attributedRelay, reason);
                } else if (this._isRelayWideRejection(reason)) {
                    this._permanentlyBlacklistRelay(attributedRelay, reason);
                } else if (accepted === false) {
                    if (this._isPermanentRejection(reason)) {
                        if (hasEventId) this._recordEventKindRejection(attributedRelay, okEventId);
                    } else if (/^mute[\s:]/i.test(r)) {
                        // NIP-01 mute: relay accepted but no subscribers
                    } else if (/event[\s_-]?too[\s_-]?large|\btoo[\s_-]large\b|\bsize[\s_]*\d+.*max[\s_]*\d+|created_at\b.*\b(too|in)\b.*(early|late|future|past)|timestamp.*too/i.test(r)) {
                        // Per-event problem, not the relay's fault
                    } else if (/rate-?limit|too many|concurrent|slow down/i.test(r)) {
                        if (hasEventId) this._dmOutboxRefused(okEventId);
                        this._noteRateLimit(attributedRelay);
                        this._recordRelayError(attributedRelay, reason);
                    } else if (/error|invalid/i.test(r)) {
                        this._recordRelayError(attributedRelay, reason);
                    }
                }
                break;
            }
            case 'EOSE': {
                const eoseSubId = data[0];
                this._notePoolSubLive(eoseSubId);
                if (this._eoseWaiters && this._eoseWaiters.has(eoseSubId)) {
                    const w = this._eoseWaiters.get(eoseSubId);
                    clearTimeout(w.timer);
                    this._eoseWaiters.delete(eoseSubId);
                    w.resolve();
                }
                if (this._backfillSubs && this._backfillSubs.has(eoseSubId)) {
                    const entry = this._backfillSubs.get(eoseSubId);
                    if (entry && !entry._eoseScheduled) {
                        entry._eoseScheduled = true;
                        setTimeout(() => entry.close(), 300);
                    }
                }
                break;
            }
            case 'AUTH': {
                // We don't implement NIP-42; drop relays asking for AUTH.
                const authRelay = (typeof data[0] === 'string' && data[0].startsWith('wss://'))
                    ? data[0] : relayUrl;
                this._permanentlyBlacklistRelay(authRelay, 'auth-required');
                break;
            }
            case 'CLOSED': {
                // Direct: ["CLOSED", subId, reason]; pool: ["CLOSED", subId, reason, relayUrl].
                const closedSubId = data[0];
                const reason = data[1] || '';
                const attributedRelay = (typeof data[2] === 'string' && data[2].startsWith('wss://'))
                    ? data[2] : relayUrl;
                if (this._backfillSubs && this._backfillSubs.has(closedSubId)) {
                    const entry = this._backfillSubs.get(closedSubId);
                    if (entry) {
                        if (entry.timer) clearTimeout(entry.timer);
                        this._backfillSubs.delete(closedSubId);
                    }
                }
                if (this._isUnsupportedKind(reason)) {
                    this._recordUnsupportedKindRejection(attributedRelay, closedSubId, reason);
                } else if (this._isRelayWideRejection(reason)) {
                    this._permanentlyBlacklistRelay(attributedRelay, reason);
                } else if (typeof reason === 'string' && /rate-?limit|too many|concurrent/i.test(reason)) {
                    this._noteRateLimit(attributedRelay);
                    this._recordRelayError(attributedRelay, reason);
                } else if (typeof reason === 'string' && /error|invalid|bad filter|malformed/i.test(reason)) {
                    this._recordRelayError(attributedRelay, reason);
                }
                break;
            }
            case 'NOTICE': {
                // Direct: ["NOTICE", reason]; pool: ["NOTICE", reason, relayUrl].
                const notice = data[0];
                const attributedRelay = (typeof data[1] === 'string' && data[1].startsWith('wss://'))
                    ? data[1] : relayUrl;
                if (this._isUnsupportedKind(notice)) {
                    // Per-REQ only: don't blacklist the relay for other kinds.
                } else if (this._isRelayWideRejection(notice)) {
                    this._permanentlyBlacklistRelay(attributedRelay, notice);
                } else if (typeof notice === 'string' && /rate-?limit|too many|concurrent/i.test(notice)) {
                    this._noteRateLimit(attributedRelay);
                    this._recordRelayError(attributedRelay, notice);
                } else if (typeof notice === 'string' && /error|invalid|bad filter|malformed/i.test(notice)) {
                    this._recordRelayError(attributedRelay, notice);
                }
                break;
            }
        }
    },

    async fetchProfileFromRelay(pubkey) {
        return new Promise((resolve) => {
            this.profileFetchQueue.push({ pubkey, resolve });

            if (this.profileFetchTimer) {
                clearTimeout(this.profileFetchTimer);
            }

            this.profileFetchTimer = setTimeout(() => {
                this.processBatchedProfileFetch();
            }, this.profileFetchBatchDelay);
        });
    },

    updateConnectionStatus(status) {
        try {
            this._renderConnectionStatus(status);
        } finally {
            if (typeof this._syncComposerConnHint === 'function') this._syncComposerConnHint();
        }
    },

    _renderConnectionStatus(status) {
        if (status && typeof status === 'string') this._connStatusText = status;
        else this._connStatusText = '';

        if (status && typeof status === 'string') {
            let color = '';
            if (status.includes('Connected') || status.includes('relays')) {
                color = 'var(--primary)';
            } else if (status.includes('Connecting') || status.includes('Discovering')) {
                color = 'var(--warning)';
            } else if (status.includes('Failed') || status.includes('Disconnected')) {
                color = 'var(--danger)';
            }
            this._setConnStatus(status, color);
        } else {
            // Pool mode: relayPool entries hold a stale poolSocket ref during single-worker reconnects.
            if (this.useRelayProxy) {
                const count = this.poolConnectedRelays.length;
                if (this._isAnyPoolOpen() && count > 0) {
                    this._setConnStatus(`Proxy Connected (${count} relays)`, 'var(--primary)');
                    this.connected = true;
                } else {
                    this._setConnStatus('Connecting...', 'var(--warning)');
                }
                return;
            }

            let actuallyConnected = 0;

            this.relayPool.forEach((relay, url) => {
                if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                    actuallyConnected++;
                } else {
                    this.relayPool.delete(url);
                }
            });

            if (actuallyConnected > 0) {
                this._setConnStatus(`Direct Connected (${actuallyConnected} relays)`, 'var(--primary)');
                this.connected = true;
            } else {
                this._setConnStatus('Disconnected', 'var(--danger)');
                this.connected = false;
            }

        }
    },

    _setConnStatus(text, color) {
        const prev = this._connStatusShown;
        this._connStatusShown = { text, color: color || (prev && prev.color) || '' };
        this._paintConnStatus();
    },

    _paintConnStatus() {
        const cur = this._connStatusShown;
        if (!cur || typeof document === 'undefined') return;
        const statusEl = document.getElementById('connectionStatus');
        const dot = document.getElementById('statusDot');
        const held = !this._connNoticeArmed();
        const text = held && CONN_STATUS_OFFLINE.test(cur.text) ? 'Connecting...' : cur.text;
        const color = held && cur.color === 'var(--danger)' ? 'var(--warning)' : cur.color;
        if (statusEl && statusEl.textContent !== text) statusEl.textContent = text;
        if (dot && color && dot.style.background !== color) dot.style.background = color;
    },

    _jitter(baseMs, spread = 0.25) {
        const factor = 1 - spread + Math.random() * spread * 2;
        return Math.max(0, Math.floor(baseMs * factor));
    },

    // Back off new REQs to relays that rate-limited us recently.
    _noteRateLimit(relayUrl) {
        if (!this._rateLimitedRelays) this._rateLimitedRelays = new Map();
        const now = Date.now();
        const key = relayUrl || 'relay-pool';
        const prev = this._rateLimitedRelays.get(key) || { count: 0, until: 0 };
        prev.count++;
        // 10s for the first hit, doubling up to 5 min.
        const backoff = Math.min(10000 * Math.pow(2, prev.count - 1), 300000);
        prev.until = now + backoff;
        this._rateLimitedRelays.set(key, prev);
        if (this._backfillSubs) {
            for (const [, entry] of this._backfillSubs) {
                try { entry.close(); } catch (_) { }
            }
        }
        // Decay the count so a one-off doesn't punish forever.
        setTimeout(() => {
            const cur = this._rateLimitedRelays.get(key);
            if (cur && cur.count > 0) cur.count--;
        }, 60000);
    },

    _isRateLimited(relayUrl) {
        if (!this._rateLimitedRelays) return false;
        const entry = this._rateLimitedRelays.get(relayUrl || 'relay-pool');
        return !!(entry && entry.until > Date.now());
    },

    _isPermanentRejection(reason) {
        if (typeof reason !== 'string') return false;
        return /auth[\s\-_:]*required/i.test(reason)
            || /\bauthentic/i.test(reason)
            || /nip-?42/i.test(reason)
            || /\bblocked\b/i.test(reason)
            || /\bbanned\b/i.test(reason)
            || /\brestricted\b/i.test(reason)
            || /\bforbidden\b/i.test(reason)
            || /\bunauthorized\b/i.test(reason)
            || /\bunsupported\b/i.test(reason)
            || /payment[\s\-_:]*required/i.test(reason)
            || /\bpaid\b/i.test(reason)
            || /\bpow\b/i.test(reason)
            || /\bprotected\b/i.test(reason)
            || /must have ['"]?h['"]?,?\s*['"]?e['"]?\s*or\s*['"]?a['"]?\s*tag/i.test(reason)
            || /\binvalid query\b/i.test(reason)
            || /\bconnection-failed\b/i.test(reason)
            || /kinds?\s*not\s*supported/i.test(reason)
            || /\bNIP[\s\-_:]*\d+\b/i.test(reason)
            || /\bnot\s+whitelisted\b/i.test(reason)
            || /\bauthor[\s\-_]+banned\b/i.test(reason)
            || /\bnot\s+allowed\b/i.test(reason)
            || /(does\s+not\s+have\s+permission|no\s+permission|permission\s+to\s+write)/i.test(reason)
            || /\bonly\s+members\b/i.test(reason)
            || /out\s+of\s+time\b/i.test(reason)
            || /\btop[\s\-]?up\b/i.test(reason)
            || /\baccepted\s+(repository|event)\b/i.test(reason)
            || /\bmust\s+reference\b/i.test(reason)
            || /\bweb\s+of\s+trust\b/i.test(reason)
            || /\bpolicy\s+violated\b/i.test(reason)
            || /\blow\s+trust\b/i.test(reason);
    },

    _isUnsupportedKind(reason) {
        if (typeof reason !== 'string') return false;
        return /kinds?\s*not\s*supported/i.test(reason)
            || /\bNIP[\s\-_:]*\d+\b/i.test(reason)
            || /\bkinds?[\s\-_:]*\d+\b/i.test(reason);
    },

    _isRelayWideRejection(reason) {
        if (typeof reason !== 'string') return false;
        return /auth[\s\-_:]*required/i.test(reason)
            || /\bauthentic/i.test(reason)
            || /nip-?42/i.test(reason)
            || /\bblocked\b/i.test(reason)
            || /\brestricted\b/i.test(reason)
            || /\bbanned\b/i.test(reason)
            || /\bforbidden\b/i.test(reason)
            || /\bunauthorized\b/i.test(reason)
            || /payment[\s\-_:]*required/i.test(reason)
            || /\bpaid\b/i.test(reason)
            || /must have ['"]?h['"]?,?\s*['"]?e['"]?\s*or\s*['"]?a['"]?\s*tag/i.test(reason)
            || /\binvalid query\b/i.test(reason)
            || /\bconnection-failed\b/i.test(reason)
            || /\bnot\s+whitelisted\b/i.test(reason)
            || /\bauthor[\s\-_]+banned\b/i.test(reason)
            || /\bnot\s+allowed\b/i.test(reason)
            || /(does\s+not\s+have\s+permission|no\s+permission|permission\s+to\s+write)/i.test(reason)
            || /\bonly\s+members\b/i.test(reason)
            || /out\s+of\s+time\b/i.test(reason)
            || /\btop[\s\-]?up\b/i.test(reason)
            || /\baccepted\s+(repository|event)\b/i.test(reason)
            || /\bmust\s+reference\b/i.test(reason)
            || /\bweb\s+of\s+trust\b/i.test(reason)
            || /\bpolicy\s+violated\b/i.test(reason)
            || /\blow\s+trust\b/i.test(reason);
    },

    // 5+ errors within 60s rests the relay for the blacklist window.
    _recordRelayError(relayUrl, reason) {
        if (!relayUrl || relayUrl === 'relay-pool') return;
        if (this._permanentBlacklist && this._permanentBlacklist.has(relayUrl)) return;
        if (!this._relayErrorCounts) this._relayErrorCounts = new Map();
        const now = Date.now();
        let entry = this._relayErrorCounts.get(relayUrl);
        if (!entry || (now - entry.firstAt) > 60000) {
            entry = { count: 0, firstAt: now };
            this._relayErrorCounts.set(relayUrl, entry);
        }
        entry.count++;
        if (entry.count >= 5) {
            this._relayErrorCounts.delete(relayUrl);
            this._restRelay(relayUrl);
        }
    },

    _restRelay(relayUrl) {
        if (!relayUrl || relayUrl === 'relay-pool') return;
        if (relayUrl === this.appRelay) return;
        if (this.defaultRelays && this.defaultRelays.includes(relayUrl)) return;
        this.blacklistedRelays.add(relayUrl);
        if (this.blacklistTimestamps) this.blacklistTimestamps.set(relayUrl, Date.now());
        this._noteRateLimit(relayUrl);
    },

    // Session-long; in pool mode a RELAYS update makes the worker drop the upstream connection.
    _permanentlyBlacklistRelay(relayUrl, reason) {
        if (!relayUrl || relayUrl === 'relay-pool') return;
        if (relayUrl === this.appRelay) return;
        // Default relays are curated and must stay eligible.
        if (this.defaultRelays && this.defaultRelays.includes(relayUrl)) return;
        if (!this._permanentBlacklist) this._permanentBlacklist = new Set();
        if (this._permanentBlacklist.has(relayUrl)) return;
        this._permanentBlacklist.add(relayUrl);

        // Far-future timestamp so existing skip checks (shouldRetryRelay etc.) honor it.
        this.blacklistedRelays.add(relayUrl);
        if (this.blacklistTimestamps) {
            this.blacklistTimestamps.set(relayUrl, Date.now() + (10 * 365 * 24 * 3600 * 1000));
        }

        const direct = this.relayPool && this.relayPool.get(relayUrl);
        if (direct && direct.ws) {
            try { direct.ws.close(); } catch (_) { }
            this.relayPool.delete(relayUrl);
        }

        if (this.currentGeoRelays) this.currentGeoRelays.delete(relayUrl);
        if (this.geoRelayConnections) {
            for (const set of this.geoRelayConnections.values()) set.delete(relayUrl);
        }

        if (this.useRelayProxy && typeof this._poolSendRelayConfig === 'function') {
            this._poolSendRelayConfig();
        }
    },

    // Serializes ephemeral-pubkey REQs so they don't burst in parallel.
    _waitForEoseOrTimeout(subId, timeoutMs = 2000) {
        return new Promise(resolve => {
            if (!this._eoseWaiters) this._eoseWaiters = new Map();
            if (this._eoseWaiters.has(subId)) {
                resolve();
                return;
            }
            const timer = setTimeout(() => {
                this._eoseWaiters.delete(subId);
                resolve();
            }, timeoutMs);
            this._eoseWaiters.set(subId, { resolve, timer });
        });
    },

    // Stay under per-relay "too many concurrent subscriptions" limits.
    _oneShotReqMax: 4,
    _oneShotReqAcquire(fn) {
        if (!this._oneShotReqState) this._oneShotReqState = { active: 0, queue: [] };
        const s = this._oneShotReqState;
        const run = () => {
            s.active++;
            try { fn(); } catch (_) { this._oneShotReqDone(); }
        };
        if (s.active < this._oneShotReqMax) run();
        else s.queue.push(run);
    },
    _oneShotReqDone() {
        if (!this._oneShotReqState) return;
        const s = this._oneShotReqState;
        s.active = Math.max(0, s.active - 1);
        if (s.active < this._oneShotReqMax && s.queue.length > 0) {
            const next = s.queue.shift();
            try { next(); } catch (_) { this._oneShotReqDone(); }
        }
    },

    // bufferedAmount-aware send with an optional per-socket queue for critical messages.
    _safeWsSend(ws, msg, opts) {
        if (!ws || ws.readyState !== WebSocket.OPEN) return false;
        const threshold = (opts && opts.threshold) || 1048576;
        if (ws.bufferedAmount > threshold) {
            if (opts && opts.critical) this._queueSocketSend(ws, msg);
            return false;
        }
        try {
            ws.send(msg);
            if (this.relayStats) this.relayStats.bytesSent = (this.relayStats.bytesSent || 0) + (typeof msg === 'string' ? msg.length : 0);
            return true;
        }
        catch (_) { return false; }
    },

    _queueSocketSend(ws, msg) {
        if (!ws._sendQueue) ws._sendQueue = [];
        if (ws._sendQueue.length >= this.MAX_SOCKET_QUEUE) {
            ws._droppedSends = (ws._droppedSends || 0) + 1;
            if (this.relayStats) {
                this.relayStats.droppedSends = (this.relayStats.droppedSends || 0) + 1;
            }
            if (!this._dropWarnTs || Date.now() - this._dropWarnTs > 30000) {
                this._dropWarnTs = Date.now();
                console.warn('[Relay] send queue full; dropped', ws._droppedSends, 'frames');
            }
            return;
        }
        ws._sendQueue.push(msg);
        if (ws._draining) return;
        ws._draining = true;
        const drain = () => {
            if (!ws || ws.readyState !== WebSocket.OPEN) {
                ws._draining = false;
                ws._sendQueue = null;
                return;
            }
            const drainTarget = 524288;
            while (ws._sendQueue && ws._sendQueue.length > 0 && ws.bufferedAmount < drainTarget) {
                try { ws.send(ws._sendQueue.shift()); }
                catch (_) { break; }
            }
            if (ws._sendQueue && ws._sendQueue.length > 0) {
                setTimeout(drain, 50);
            } else {
                ws._draining = false;
            }
        };
        setTimeout(drain, 50);
    },

    // Yields between chunks so slow relays don't block faster ones.
    _broadcastAsync(relays, msg, opts) {
        const list = Array.isArray(relays) ? relays : Array.from(relays || []);
        const chunkSize = (opts && opts.chunkSize) || 6;
        const sendOpts = { critical: !!(opts && opts.critical) };
        let i = 0;
        const step = () => {
            let count = 0;
            while (i < list.length && count < chunkSize) {
                const entry = list[i++];
                const ws = entry && (entry.ws || entry);
                this._safeWsSend(ws, msg, sendOpts);
                count++;
            }
            if (i < list.length) setTimeout(step, 0);
        };
        step();
    },

    // Backfill subs self-close on EOSE.
    closeChannelSubscription(channelKey, opts) {
        if (!channelKey) return;

        const subIds = [];
        if (this._channelTypingSubs && this._channelTypingSubs.has(channelKey)) {
            subIds.push(this._channelTypingSubs.get(channelKey));
            this._channelTypingSubs.delete(channelKey);
        }
        if (this.channelSubscriptions.has(channelKey)) {
            const sid = this.channelSubscriptions.get(channelKey);
            if (sid && !subIds.includes(sid)) subIds.push(sid);
            this.channelSubscriptions.delete(channelKey);
        }
        this.channelLoadedFromRelays.delete(channelKey);
        if (subIds.length === 0) return;

        const sendCloseFor = (subId) => {
            const closeMsg = JSON.stringify(["CLOSE", subId]);
            if (this.useRelayProxy && this._isAnyPoolOpen()) {
                for (const p of this.poolSockets) {
                    this._safeWsSend(p.ws, closeMsg, { critical: true });
                }
                return;
            }
            this.relayPool.forEach((relay) => {
                if (!relay || !relay.ws || relay.ws.readyState !== WebSocket.OPEN) return;
                if (relay.subscriptions && relay.subscriptions.has(subId)) {
                    this._safeWsSend(relay.ws, closeMsg, { critical: true });
                    relay.subscriptions.delete(subId);
                }
            });
        };
        for (const id of subIds) sendCloseFor(id);
    },

    // Coalesce so multiple channels share one batched REQ.
    _queueChannelSubscription(channelKey, channelType) {
        if (!channelKey) return;
        if (this.channelLoadedFromRelays.has(channelKey)) return;
        if (!this._pendingChannelLoadQueue) this._pendingChannelLoadQueue = [];
        if (this._pendingChannelLoadQueue.some(c => c.key === channelKey)) return;
        this._pendingChannelLoadQueue.push({ key: channelKey, type: channelType });

        const isCurrent = (channelKey === this.currentChannel || channelKey === this.currentGeohash);
        const delay = isCurrent ? 30 : 150;

        if (this._pendingChannelLoadTimer) clearTimeout(this._pendingChannelLoadTimer);
        this._pendingChannelLoadTimer = setTimeout(() => this._flushPendingChannelLoad(), delay);
    },

    _flushPendingChannelLoad() {
        if (this._pendingChannelLoadTimer) {
            clearTimeout(this._pendingChannelLoadTimer);
            this._pendingChannelLoadTimer = null;
        }
        // Rate-limited: defer so relays can clear their concurrent-sub counter; the queue keeps accumulating.
        if (this._isRateLimited('relay-pool')) {
            this._pendingChannelLoadTimer = setTimeout(() => this._flushPendingChannelLoad(), 5000);
            return;
        }
        const queue = this._pendingChannelLoadQueue || [];
        this._pendingChannelLoadQueue = [];
        if (queue.length === 0) return;
        if (queue.length === 1) {
            this.subscribeToChannelTargeted(queue[0].key, queue[0].type);
        } else {
            this.subscribeToChannelBatch(queue);
        }
    },

});
