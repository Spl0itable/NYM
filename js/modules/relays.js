// relays.js - Relay pool, connection lifecycle, proxy worker, geo-relays, stats, retries

Object.assign(NYM.prototype, {

    // Fetch geo relay list from the same remote CSV that bitchat uses.
    // Falls back to the hardcoded list if fetch fails.
    // Returns a promise so connectToGeoRelays can await the fresh data
    // before selecting relays, ensuring we match bitchat's relay set.
    fetchGeoRelays() {
        const directCsvUrl = 'https://raw.githubusercontent.com/permissionlesstech/georelays/refs/heads/main/nostr_relays.csv';
        const base = this._getProxyBaseUrl();

        const tryProxyJson = async () => {
            if (!base) return null;
            try {
                const res = await fetch(`${base}?action=geo-relays`);
                if (!res.ok) return null;
                const data = await res.json();
                if (!data || !Array.isArray(data.relays)) return null;
                return data.relays.filter(r => r && r.url && Number.isFinite(r.lat) && Number.isFinite(r.lng));
            } catch {
                return null;
            }
        };

        const fetchAndParseCsvLocally = async () => {
            const res = await fetch(directCsvUrl, { cache: 'no-cache' });
            if (!res.ok) throw new Error(`HTTP ${res.status}`);
            const csv = await res.text();
            return this._parseGeoRelaysCsv(csv);
        };

        return (async () => {
            let relays = await tryProxyJson();
            if (!relays || relays.length === 0) {
                relays = await fetchAndParseCsvLocally();
            }
            if (relays && relays.length > 0) {
                this.geoRelays = relays;
                for (const r of relays) this.allRelayUrls.add(r.url);
                if (this.useRelayProxy && this._isAnyPoolOpen()) {
                    this._poolSendRelayConfig();
                }
            }
        })().catch((err) => {
            console.warn(`[GeoRelays] CSV fetch failed (${this.geoRelays.length} geo relays):`, err.message);
        });
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

    // Find the N closest relays to a geohash location
    getClosestRelaysForGeohash(geohash, count = this.geoRelayCount) {
        try {
            // Decode geohash to get center coordinates
            const coords = this.decodeGeohash(geohash);
            if (!coords || typeof coords.lat !== 'number' || typeof coords.lng !== 'number') {
                return [];
            }

            // Calculate distance from geohash center to each geo-located relay
            const relaysWithDistance = this.geoRelays.map(relay => ({
                url: relay.url,
                distance: this.calculateDistance(coords.lat, coords.lng, relay.lat, relay.lng)
            }));

            // Sort by distance (closest first)
            relaysWithDistance.sort((a, b) => a.distance - b.distance);

            // Return the N closest relays
            return relaysWithDistance.slice(0, count);
        } catch (error) {
            return [];
        }
    },

    // Ensure an event reaches the geo relays for a given geohash channel
    ensureGeoRelayDelivery(signedEvent, geohash) {
        if (!geohash) return;
        const closestRelays = this.getClosestRelaysForGeohash(geohash);
        if (closestRelays.length === 0) return;
        const geoUrls = new Set(closestRelays.map(r => r.url));

        // Multiplexed pool mode: retry with GEO_EVENT to geo workers only
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            setTimeout(() => {
                if (this._isAnyPoolOpen()) {
                    this._poolSendToRole('geo', ['GEO_EVENT', signedEvent, closestRelays.map(r => r.url)]);
                }
            }, 2000);
            return;
        }

        // Legacy (direct connection) mode: explicitly send to each geo relay.
        const msg = JSON.stringify(['EVENT', signedEvent]);

        const trySend = () => {
            for (const url of geoUrls) {
                const relay = this.relayPool.get(url);
                if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                    try { relay.ws.send(msg); } catch (_) { /* noop */ }
                }
            }
        };

        // Immediate attempt (may already be connected)
        trySend();
        // Retry after geo relays have had more time to connect
        setTimeout(trySend, 2000);
    },

    // Keep geo relays for the active geohash channel connected by periodically
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
                const expected = new Set(closest.map(r => r.url));
                const present = new Set(this.poolConnectedRelays || []);
                let missing = 0;
                expected.forEach(u => { if (!present.has(u)) missing++; });
                if (missing > 0) this.connectToGeoRelays(this._geoRelayKeepAliveGeohash);
                return;
            }

            let alive = 0;
            for (const r of closest) {
                const relay = this.relayPool.get(r.url);
                if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) alive++;
            }
            if (alive < closest.length) {
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

    // Connect to geo-specific relays for a geohash channel
    async connectToGeoRelays(geohash) {
        if (!geohash || !this.isValidGeohash(geohash)) {
            return;
        }

        // Skip geo relay connections in group chat & PM only mode
        if (this.settings.groupChatPMOnlyMode) return;

        // Wait for the remote CSV relay list to load so we match
        // the same relay set that bitchat uses for this geohash.
        if (this._geoRelaysReady) {
            await this._geoRelaysReady;
        }

        const closestRelays = this.getClosestRelaysForGeohash(geohash, this.geoRelayCount);
        if (closestRelays.length === 0) {
            return;
        }
        const geoRelayUrls = new Set(closestRelays.map(r => r.url));

        // Multiplexed pool mode: keep geo relays in the pool config
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            const prev = this.geoRelayConnections.get(geohash);
            const changed = !prev || prev.size !== geoRelayUrls.size ||
                [...geoRelayUrls].some(u => !prev.has(u));
            this.geoRelayConnections.set(geohash, geoRelayUrls);
            for (const url of geoRelayUrls) this.currentGeoRelays.add(url);

            // Verify the mapped relays are actually connected in the pool
            const present = new Set(this.poolConnectedRelays || []);
            const anyMissing = [...geoRelayUrls].some(u => !present.has(u));

            if (changed || anyMissing) {
                this._poolSendRelayConfig();
                this._ensureAllShardsConnected();
                this.channelLoadedFromRelays.delete(geohash);
                this.subscribeToChannelTargeted(geohash, 'geohash');
            }
            return;
        }

        // Direct connection mode
        this.geoRelayConnections.set(geohash, geoRelayUrls);

        const connectionPromises = [];
        let newlyConnected = 0;
        for (const { url: relayUrl } of closestRelays) {
            // Already connected — ensure it has the standing kind-20000 sub
            const existing = this.relayPool.get(relayUrl);
            if (existing && existing.ws && existing.ws.readyState === WebSocket.OPEN) {
                this.currentGeoRelays.add(relayUrl);
                this._ensureGeoRelayLiveSub(existing, relayUrl);
                continue;
            }

            // Skip if blacklisted or recently failed
            if (this.blacklistedRelays.has(relayUrl) && !this.isBlacklistExpired(relayUrl)) {
                continue;
            }
            if (!this.shouldRetryRelay(relayUrl)) {
                continue;
            }

            // Connect concurrently — only 5 geo relays, no stagger needed
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

        // Wait for all connection attempts to complete
        await Promise.all(connectionPromises);

        // Update network stats to reflect newly connected geo relays
        this.updateRelayStatus();

        if (newlyConnected > 0) {
            this.channelLoadedFromRelays.delete(geohash);
            this.loadChannelFromRelays(geohash, 'geohash');
        }

        // Always ensure default relays (first 5 broadcast relays) are connected
        this.ensureDefaultRelaysConnected();
    },

    // Give a geo relay the kind-20000 subscription once
    _ensureGeoRelayLiveSub(relay, relayUrl) {
        if (!relay || relay._geoLiveSub) return;
        relay._geoLiveSub = true;
        if (relay.subscriptions && relay.subscriptions.size > 0) return;
        this.subscribeToSingleRelay(relayUrl);
    },

    // Force the app relay (wss://relay.nymchat.app) to be connected
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

    stopAppRelayWatchdog() {
        if (this._appRelayWatchdog) {
            clearInterval(this._appRelayWatchdog);
            this._appRelayWatchdog = null;
        }
    },

    // Ensure the first 5 broadcast relays are always connected regardless of channel
    async ensureDefaultRelaysConnected() {
        // Pool mode: proxy manages all connections
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
                // Pool mode: _poolSendRelayConfig respects lowDataMode
                // and sends only defaults + DM relays + active geo relays
                this._poolSendRelayConfig();
            } else {
                // Direct mode: disconnect all relays except the 5 defaults
                // and active geo relays for the current channel
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
                // Pool mode: restore full relay config
                this._poolSendRelayConfig();
            } else {
                // Direct mode: reconnect to all broadcast and geo relays
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

        // Get relays that were connected for the previous geohash
        const previousGeoRelays = this.geoRelayConnections.get(previousGeohash);
        if (!previousGeoRelays) return;

        // Check if any of these relays are still needed for other geohash channels
        const stillNeededRelays = new Set();
        for (const [geohash, relays] of this.geoRelayConnections) {
            if (geohash !== previousGeohash) {
                for (const url of relays) {
                    stillNeededRelays.add(url);
                }
            }
        }

        // Build set of relays that should never be disconnected
        const keepRelays = new Set(this.defaultRelays);

        for (const url of previousGeoRelays) {
            if (!stillNeededRelays.has(url) && !keepRelays.has(url)) {
                this.currentGeoRelays.delete(url);

                // Low data mode: actively close the connection to free resources
                if (this.settings && this.settings.lowDataMode) {
                    if (this.useRelayProxy) {
                        // Pool mode: send updated config so proxy drops the relay
                        // (batched after the loop below)
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

        // Remove the cached connection entry for the old geohash
        this.geoRelayConnections.delete(previousGeohash);

        // Low data mode + pool: send updated relay config so the proxy
        // disconnects relays that are no longer in the set
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

        listEl.innerHTML = html || '<div class="nm-dim12">No relays connected</div>';
    },

    setupVisibilityMonitoring() {
        // Track when app becomes visible/hidden
        document.addEventListener('visibilitychange', () => {
            if (document.visibilityState === 'visible') {
                const delay = this.isFlutterWebView ? 200 : 500;
                setTimeout(() => {
                    this.clearRelayBlocksForReconnection();

                    this.checkConnectionHealth();

                    if (!this.connected && navigator.onLine) {
                        this.attemptReconnection();
                    }

                    if (this.useRelayProxy) {
                        if (this._isAnyPoolOpen()) {
                            this._poolSubscribe();
                            this._ensureAllShardsConnected();
                        }
                        if (!this._isAnyPoolOpen() && !this._poolReconnecting && navigator.onLine) {
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

                    this.backfillFromR2OnReconnect();
                }, delay);
            } else {
                this._backgroundedAt = Date.now();

                if (this.reconnectionInterval) {
                    clearInterval(this.reconnectionInterval);
                    this.reconnectionInterval = null;
                }
            }
        });

        // Also listen for page focus (for desktop)
        window.addEventListener('focus', () => {
            const delay = this.isFlutterWebView ? 200 : 500;
            setTimeout(() => {
                // Clear failed relays and blacklist to allow immediate reconnection
                this.clearRelayBlocksForReconnection();

                this.checkConnectionHealth();

                // If disconnected, immediately start reconnection attempts
                if (!this.connected && navigator.onLine) {
                    this.attemptReconnection();
                }

                // Pool mode: only resubscribe if sockets are healthy
                if (this.useRelayProxy) {
                    if (this._isAnyPoolOpen()) {
                        this._poolSubscribe();
                        this._ensureAllShardsConnected();
                    }
                    if (!this._isAnyPoolOpen() && !this._poolReconnecting && navigator.onLine) {
                        this._schedulePoolReconnect();
                    }
                } else {
                    // Always refresh subscriptions when window regains focus
                    setTimeout(() => this.resubscribeAllRelays(), 250);
                    if (this._poolFallbackActive && navigator.onLine) {
                        this._schedulePoolReconnectInBackground(true);
                    }
                }

                if (typeof this.markVisibleChannelMessagesRead === 'function') {
                    this.markVisibleChannelMessagesRead();
                }

                this.backfillFromR2OnReconnect();
            }, delay);
        });

        // For Flutter WebView, also check on resume event
        if (this.isFlutterWebView) {
            window.addEventListener('resume', () => {
                setTimeout(() => {
                    // Clear failed relays and blacklist to allow immediate reconnection
                    this.clearRelayBlocksForReconnection();

                    this.checkConnectionHealth();

                    // If disconnected, immediately start reconnection attempts
                    if (!this.connected && navigator.onLine) {
                        this.attemptReconnection();
                    }

                    // Pool mode: only resubscribe if sockets are healthy
                    if (this.useRelayProxy) {
                        if (this._isAnyPoolOpen()) {
                            this._poolSubscribe();
                            this._ensureAllShardsConnected();
                        }
                        if (!this._isAnyPoolOpen() && !this._poolReconnecting && navigator.onLine) {
                            this._schedulePoolReconnect();
                        }
                    } else {
                        // Always refresh subscriptions when app resumes
                        setTimeout(() => this.resubscribeAllRelays(), 250);
                        if (this._poolFallbackActive && navigator.onLine) {
                            this._schedulePoolReconnectInBackground(true);
                        }
                    }

                    this.backfillFromR2OnReconnect();
                }, 200);
            });
        }
    },

    // Clear relay blocks (failed list, blacklist, reconnecting set) to allow fresh reconnection attempts
    clearRelayBlocksForReconnection() {
        // Clear failed relays so they can be retried immediately
        this.failedRelays.clear();

        // Clear blacklist and timestamps, but preserve permanent rejections
        // (auth-required, unsupported filter) since those won't change.
        const keep = this._permanentBlacklist || new Set();
        this.blacklistedRelays.clear();
        this.blacklistTimestamps.clear();
        for (const url of keep) {
            this.blacklistedRelays.add(url);
            this.blacklistTimestamps.set(url, Date.now() + (10 * 365 * 24 * 3600 * 1000));
        }

        // Clear reconnecting set to allow fresh attempts
        if (this.reconnectingRelays) {
            this.reconnectingRelays.clear();
        }

        // Reset reconnection attempt counter so we get a fresh set of attempts
        this.reconnectionAttempts = 0;
        this.isReconnecting = false;
        this._poolReconnecting = false;
        this._poolReconnectRetries = 0;
    },

    async checkConnectionHealth() {

        if (this.useRelayProxy) {
            const now = Date.now();
            const STALE_MS = 120000;
            let closedAny = false;
            for (const p of this.poolSockets) {
                if (p.ws && p.ws.readyState === WebSocket.OPEN) {
                    const silenceMs = now - (p.lastMessage || 0);
                    if (silenceMs > STALE_MS) {
                        p.ws.close();
                        closedAny = true;
                    }
                }
            }
            if (closedAny) {
                this._mergePoolStatus();
                this._syncLegacyPoolSocket();
            }
            this.updateConnectionStatus();
            if (!this._isAnyPoolOpen() && !this._poolReconnecting && navigator.onLine) {
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

        // Clean up dead relays
        deadRelays.forEach(url => {
            this.relayPool.delete(url);
        });

        // If we have no actual connections, force reconnect
        if (actuallyConnected === 0) {
            this.connected = false;
            this.updateConnectionStatus('Disconnected');

            // Clear reconnecting set to allow fresh attempts
            if (this.reconnectingRelays) {
                this.reconnectingRelays.clear();
            }

            // Try to reconnect to broadcast relays
            await this.reconnectToBroadcastRelays();

            // ALSO reconnect to discovered relays after a short delay
            setTimeout(() => {
                this.retryDiscoveredRelays();
            }, 2000);

            // Reconnect to geo relays if we're in a geohash channel
            if (this.currentGeohash) {
                setTimeout(() => {
                    this.connectToGeoRelays(this.currentGeohash);
                }, 3000);
            }

        } else {
            // We have some connections, but update status to reflect actual count
            this.updateConnectionStatus();

            // If we're missing default relays, try to restore them
            const missingEssential = this.defaultRelays.filter(url => !this.relayPool.has(url));
            if (missingEssential.length > 0) {
                this.reconnectToBroadcastRelays();
            }

            // Retry any disconnected relays from allRelayUrls (skipped in low data mode)
            if (!this.settings || !this.settings.lowDataMode) {
                const missingRelays = [...this.allRelayUrls].filter(url =>
                    !this.relayPool.has(url)
                );

                if (missingRelays.length > 0) {
                    setTimeout(() => {
                        this.retryDiscoveredRelays();
                    }, 1000);
                }
            }

            // Check geo relay health if we're in a geohash channel
            if (this.currentGeohash) {
                this.connectToGeoRelays(this.currentGeohash);
            }

            // Always ensure default relays (first 5 broadcast) are connected
            this.ensureDefaultRelaysConnected();
        }
    },

    async reconnectToBroadcastRelays() {
        // Multiplexed pool mode: just reconnect the single pool socket
        if (this.useRelayProxy) {
            if (this._isAnyPoolOpen()) return;
            this._schedulePoolReconnect();
            return;
        }

        let connectedCount = 0;

        // Always reconnect default relays so PMs/groups stay reachable
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
                        // After first successful connection
                        this.connected = true;
                        this.updateConnectionStatus();
                    }
                }

                // Small delay between connections to avoid overwhelming
                await new Promise(resolve => setTimeout(resolve, 50));
            }
        }

        this.updateConnectionStatus();
    },

    setupNetworkMonitoring() {
        // Track reconnection attempts
        this.reconnectionAttempts = 0;
        this.maxReconnectionAttempts = 10;
        this.reconnectionInterval = null;

        // Listen for online/offline events
        window.addEventListener('online', () => {
            this.displaySystemMessage('Network connection restored, reconnecting...');
            this.reconnectionAttempts = 0; // Reset attempts on network restore

            // Force update connection status
            this.updateConnectionStatus('Reconnecting...');

            // Multiplexed pool mode: just reconnect the pool
            if (this.useRelayProxy) {
                this._poolReconnecting = false; // Reset so schedule can run
                this._poolReconnectRetries = 0;  // Reset backoff on network restore
                this._lastPoolReconnectSchedule = 0; // Clear debounce for network restore
                this._schedulePoolReconnect();
                return;
            }

            // Fell back to direct mode earlier — try to restore the pool now
            if (this._poolFallbackActive) {
                this._schedulePoolReconnectInBackground(true);
            }

            // Clear any existing reconnection interval
            if (this.reconnectionInterval) {
                clearInterval(this.reconnectionInterval);
                this.reconnectionInterval = null;
            }

            // Clear all reconnecting flags to allow fresh attempts
            if (this.reconnectingRelays) {
                this.reconnectingRelays.clear();
            }

            // Clear relay pool of dead connections
            this.relayPool.forEach((relay, url) => {
                if (!relay.ws || relay.ws.readyState !== WebSocket.OPEN) {
                    this.relayPool.delete(url);

                }
            });

            // Clear blacklist temporarily to allow retry
            this.blacklistedRelays.clear();
            this.blacklistTimestamps.clear();
            this.isReconnecting = false;

            // Reconnect via the serialized helper
            this.reconnectToBroadcastRelays();

            // Retry any pending DMs after network restore
            setTimeout(() => this.retryPendingDMsOnReconnect(), 3000);
        });

        window.addEventListener('offline', () => {

            // Force cleanup of relay pool
            this.relayPool.forEach((relay, url) => {
                if (relay.ws) {
                    try {
                        relay.ws.close();
                    } catch (e) {
                        // Ignore close errors
                    }
                }
                this.relayPool.delete(url);
            });

            this.connected = false;
            this.displaySystemMessage('Network connection lost');
            this.updateConnectionStatus('Disconnected');
        });

        // Start automatic reconnection monitoring
        this.startReconnectionMonitoring();
    },

    startReconnectionMonitoring() {
        // Only monitor when app is visible/active
        this.reconnectionInterval = null;

        const startMonitoring = () => {
            // Clear any existing interval
            if (this.reconnectionInterval) {
                clearInterval(this.reconnectionInterval);
            }

            // Don't start monitoring during initial connection - let connectToRelays() handle it
            if (this.initialConnectionInProgress) {
                return;
            }

            // Only start if disconnected and visible
            if (!this.connected && !document.hidden) {
                this.reconnectionInterval = setInterval(() => {
                    // Skip during initial connection
                    if (this.initialConnectionInProgress) {
                        return;
                    }
                    // Only attempt if still visible
                    if (!document.hidden && !this.connected && navigator.onLine) {
                        this.attemptReconnection();
                    } else if (document.hidden) {
                        // Stop monitoring if app goes to background
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

        // Listen for visibility changes
        document.addEventListener('visibilitychange', () => {
            if (document.visibilityState === 'visible') {
                // App came to foreground - check immediately then start monitoring
                setTimeout(() => {
                    this.checkConnectionHealth();
                    if (!this.connected && navigator.onLine) {
                        this.attemptReconnection();
                        startMonitoring();
                    }
                }, 200);
            } else {
                // App went to background - stop monitoring
                stopMonitoring();
            }
        });

        // Start monitoring if currently visible and needed
        if (!document.hidden) {
            startMonitoring();
        }
    },

    async attemptReconnection() {
        // Pool mode: delegate to the guarded pool reconnect
        if (this.useRelayProxy) {
            // Don't reset _poolReconnecting — let _schedulePoolReconnect's guard prevent duplicate attempts
            if (!this._poolReconnecting) {
                this._schedulePoolReconnect();
            }
            return;
        }

        // Prevent multiple simultaneous reconnection attempts
        if (this.isReconnecting) {
            return;
        }

        // Check if we've exceeded max attempts
        if (this.reconnectionAttempts >= this.maxReconnectionAttempts) {
            this.updateConnectionStatus('Disconnected - Click to reconnect');
            return;
        }

        this.isReconnecting = true;
        this.reconnectionAttempts++;

        this.updateConnectionStatus(`Reconnecting (${this.reconnectionAttempts}/${this.maxReconnectionAttempts})...`);

        try {
            // Clear dead connections first
            this.relayPool.forEach((relay, url) => {
                if (!relay.ws || relay.ws.readyState !== WebSocket.OPEN) {
                    this.relayPool.delete(url);

                }
            });

            // Try to connect to at least one broadcast relay
            // In low data mode, only try the 5 defaults
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
                this.reconnectionAttempts = 0; // Reset on success
                this.updateConnectionStatus();

                // Reconnect to other relays in background
                this.reconnectToBroadcastRelays();

                // Always ensure default relays (first 5 broadcast) are connected
                this.ensureDefaultRelaysConnected();

                // Also reconnect to geo relays if we're in a geohash channel
                if (this.currentGeohash) {
                    this.connectToGeoRelays(this.currentGeohash);
                }

                // Retry any pending DMs that haven't been delivered
                setTimeout(() => this.retryPendingDMsOnReconnect(), 2000);
            }
        } catch (error) {
            //
        } finally {
            this.isReconnecting = false;
        }
    },

    async connectToRelays() {
        try {
            this.initialConnectionInProgress = true;
            this.updateConnectionStatus('Connecting...');
            this.startAppRelayWatchdog();

            // Use multiplexed relay pool when running on Cloudflare (or remote proxy)
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
                            // All retries exhausted — fall back to direct connections on any host
                            console.warn('[NYM] Relay pool failed, falling back to direct connections');
                            if (!this._isCloudflareHost) {
                                this._fallbackToLocal();
                            } else {
                                // Temporarily disable pool mode to allow direct connections,
                                // but schedule background reconnect to restore pool mode later
                                this.useRelayProxy = false;
                                this._poolFallbackActive = true;
                                this._schedulePoolReconnectInBackground();
                            }
                            // Fall through to direct relay connection code below
                        }
                    }
                }

                if (this.useRelayProxy && poolConnected) {
                    this.connected = true;
                    this._startPoolKeepalive();
                    this._startPoolShardHealthCheck();
                    document.getElementById('messageInput').disabled = false;
                    document.getElementById('sendBtn').disabled = false;
                    this.updateConnectionStatus();

                    // Subscribe to events via the pool
                    this._poolSubscribe();

                    // Set initial channel label
                    if (!this.settings.groupChatPMOnlyMode && this.currentChannel) {
                        this._renderChannelTitle(this.currentChannel, this.currentGeohash || this.currentChannel);
                    }

                    // Switch to pinned landing channel (or PM-only mode landing)
                    setTimeout(() => {
                        if (window.pendingChannel || window.urlChannelRouted) return;
                        // Don't override if user already navigated (e.g. joined a channel from search, created a group)
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

                    // Process any queued messages
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

                    if (!this.settings.lowDataMode) {
                        setTimeout(() => {
                            this.discoverRelaysViaNip66().then(() => {
                                if (this._isAnyPoolOpen()) this._poolSendRelayConfig();
                            });
                        }, 100);
                    }

                    this.initialConnectionInProgress = false;
                    return;
                }
            }

            // Check if we're already connected to ANY default relay from pre-connection
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

            // If not already connected, try to connect to default relays in parallel for speed
            if (!initialConnected) {
                // Get first 5 available relays for parallel connection attempt
                const initialRelays = this.defaultRelays
                    .filter(url => this.shouldRetryRelay(url))
                    .slice(0, 5);

                if (initialRelays.length > 0) {
                    // Create connection promises that resolve with relay URL on success
                    const connectionPromises = initialRelays.map(relayUrl =>
                        this.connectToRelayWithTimeout(relayUrl, 'relay', 2000).then(() => {
                            const relay = this.relayPool.get(relayUrl);
                            if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                                return relayUrl;
                            }
                            return null;
                        })
                    );

                    // Wait for first successful connection (Promise.any-like behavior)
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

                // If parallel attempt failed, fall back to sequential for remaining relays
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

            // Enable input immediately after first relay connects
            document.getElementById('messageInput').disabled = false;
            document.getElementById('sendBtn').disabled = false;
            this.connected = true;

            // Process any queued messages that were waiting for connection
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

            // Set initial channel label
            if (!this.settings.groupChatPMOnlyMode && this.currentChannel) {
                this._renderChannelTitle(this.currentChannel, this.currentGeohash || this.currentChannel);
            }

            // Start subscriptions on all connected relays
            this.subscribeToAllRelays();

            // Switch to the pinned landing channel or PM-only mode landing
            setTimeout(() => {
                // Skip if a URL channel is pending or was already routed
                if (window.pendingChannel || window.urlChannelRouted) return;
                // Don't override if user already navigated (e.g. joined a channel from search, created a group)
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

            // Connect to remaining default relays in background
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

            // GEO relays
            if (!this.settings.lowDataMode) {
                (this._geoRelaysReady || Promise.resolve()).then(() => {
                    // Connect GEO relays (second priority after defaults)
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

            // Discover additional relays via NIP-66 and connect to them
            if (!this.settings.lowDataMode) {
                setTimeout(() => {
                    this.discoverRelaysViaNip66().then(() => {
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
                    });
                }, 100);
            }

        } catch (error) {
            this.updateConnectionStatus('Connection Failed');
            this.displaySystemMessage('Failed to connect to relays: ' + error.message);

            // Re-enable input anyway in case user wants to retry
            document.getElementById('messageInput').disabled = false;
            document.getElementById('sendBtn').disabled = false;
        } finally {
            this.initialConnectionInProgress = false;
        }
    },

    // Debounced wrapper around resubscribeAllRelays. Used when the critical
    // subscription's author lists change (e.g. PM contacts added during
    // hydration) so we don't tear down and rebuild every relay subscription
    // for each individual addition.
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
        // Multiplexed pool mode: re-subscribe through proxy
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            this._poolSubscribe();
            return;
        }

        this.relayPool.forEach((relay, url) => {
            if (!relay.ws || relay.ws.readyState !== WebSocket.OPEN) return;
            this.closeSubscriptionsForRelay(url);
            this.subscribeToSingleRelay(url);
        });

        // Subscribe to ephemeral pubkeys as independent REQs
        this._refreshEphemeralSubscriptions();

        // Re-send channel-targeted subscriptions lost during disconnect
        this._resubscribeChannels();
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
            // Initialize subscriptions set if it doesn't exist
            relay.subscriptions = new Set();
        }
    },

    // Determine if a relay URL is a geo or discovered relay (not a default relay)
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

        // Geo/discovered relays only get channel-message kinds (20000, 23333)
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

    // Register a subId as a short-lived backfill sub: auto-CLOSEs ~300ms
    // after the first EOSE arrives, or after a hard timeout (default 4s) if
    // no EOSE comes. Keeps concurrent sub count near zero in steady state.
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

    // Open a persistent typing-only sub for the currently-viewed channel.
    // No-op if not the current channel or if one already exists.
    _ensureChannelTypingSub(channelKey, channelType) {
        if (!channelKey) return;
        const isCurrent = channelKey === this.currentChannel || channelKey === this.currentGeohash;
        if (!isCurrent) return;
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

    // kind 20000 events are ephemeral and not stored by relays, so per-channel
    // backfill is pointless. Live messages flow via the broad kind-20000 sub.
    // Only open a typing sub (kind 24420/24421) for the currently-viewed channel.
    subscribeToChannelTargeted(channelKey, channelType) {
        if (this.channelLoadedFromRelays.has(channelKey)) {
            this._ensureChannelTypingSub(channelKey, channelType);
            return;
        }
        this.channelLoadedFromRelays.add(channelKey);
        this._ensureChannelTypingSub(channelKey, channelType);
    },

    // Per-channel backfill REQs were causing massive relay spam. Now a no-op:
    // the broad kind-20000 sub covers any stored events; typing subs are only
    // opened for the currently-viewed channel via subscribeToChannelTargeted.
    subscribeToChannelBatch(channels) {
        if (!channels || channels.length === 0) return;
        channels.forEach(({ key }) => {
            if (key) this.channelLoadedFromRelays.add(key);
        });
    },

    // Load messages for a channel from relays - called when switching channels
    loadChannelFromRelays(channelKey, channelType) {
        // Already backfilled this session — just ensure typing sub exists for current channel
        if (this.channelLoadedFromRelays.has(channelKey)) {
            this._ensureChannelTypingSub(channelKey, channelType);
            return;
        }

        // Check if we have few messages for this channel (under 50)
        // Storage key uses #prefix for channels with a geohash/g-tag (both geohash and non-geohash)
        const storageKey = `#${channelKey}`;
        const currentMessages = this.messages.get(storageKey) || [];

        // If we have very few messages, send a targeted request
        if (currentMessages.length < 50) {
            this._queueChannelSubscription(channelKey, channelType);
        } else {
            // Mark as loaded so we don't recheck on every channel switch
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
        const failedAttempt = this.failedRelays.get(relayUrl);
        if (!failedAttempt) return true;

        const now = Date.now();
        const canRetry = now - failedAttempt > this.relayRetryDelay;

        if (!canRetry) {
            //
        }

        return canRetry;
    },

    trackRelayFailure(relayUrl) {
        this.failedRelays.set(relayUrl, Date.now());
    },

    clearRelayFailure(relayUrl) {
        this.failedRelays.delete(relayUrl);
    },

    _detectCloudflareHost() {
        try {
            const host = window.location.hostname;
            if (host === 'web.nymchat.app') return true;
        } catch {
            // Not in a browser context
        }
        return false;
    },

    // Returns the host to use for API endpoints, or null when this instance
    // can't reach the proxy (local dev, third-party host, etc.).
    _getApiHost() {
        if (this._isCloudflareHost) return window.location.host;
        return null;
    },

    // Mark the remote API as unavailable and fall back to local/direct
    _fallbackToLocal() {
        if (this._isCloudflareHost || this._remoteApiFailed) return;
        this._remoteApiFailed = true;
        this.useRelayProxy = false;
        this._poolFallbackActive = true;
        console.warn('[NYM] Remote API unreachable, falling back to direct connections');
        this._schedulePoolReconnectInBackground();
    },

    // Fall back from pool mode to direct relay connections (works on any host including Cloudflare).
    // Unlike _fallbackToLocal, this does NOT mark the remote API as failed — only disables pool mode.
    _fallbackToDirectConnections() {
        if (!this.useRelayProxy) return; // Already in direct mode

        this._stopPoolShardHealthCheck();

        // Close all pool sockets
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

        // Disable pool mode so all relay methods use direct connections
        this.useRelayProxy = false;
        this._poolFallbackActive = true;
        console.warn('[NYM] Pool mode disabled, switching to direct relay connections');

        // Connect directly to relays
        this.reconnectToBroadcastRelays();
        if (this.currentGeohash) {
            this.connectToGeoRelays(this.currentGeohash);
        }

        // Keep trying to restore pool mode in the background
        this._schedulePoolReconnectInBackground();
    },

    // Try to restore pool mode in the background
    _schedulePoolReconnectInBackground(immediate = false) {
        if (!this._poolFallbackActive) return;
        if (!this._isCloudflareHost) return;
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
                    this._bgPoolReconnectAttempts = 0;
                    this._poolFallbackActive = false;
                    console.log('[NYM] Pool mode restored');
                    this._startPoolKeepalive();
                    this._startPoolShardHealthCheck();
                    this._poolSubscribe();
                    this.relayPool.forEach((relay) => {
                        try { if (relay.ws) relay.ws.close(); } catch (_) { }
                    });
                    this.relayPool.clear();
                    this.updateConnectionStatus();
                    this.retryPendingDMsOnReconnect();
                })
                .catch(() => {
                    this._bgPoolReconnectInFlight = false;
                    this._remoteApiFailed = wasRemoteApiFailed;
                    this.useRelayProxy = false;
                    if (!this._poolFallbackActive) return;
                    const expIdx = Math.min(this._bgPoolReconnectAttempts - 1, 4);
                    const base = Math.min(15000 * Math.pow(2, expIdx), 120000);
                    const delay = this._jitter(base);
                    this._bgPoolReconnectTimer = setTimeout(tryRestore, delay);
                });
        };

        const initialDelay = immediate ? 0 : 15000;
        this._bgPoolReconnectTimer = setTimeout(tryRestore, initialDelay);
    },

    _getProxiedRelayUrl(relayUrl) {
        const host = this._getApiHost();
        if (!this.useRelayProxy || !host) return relayUrl;
        return `wss://${host}/api/relay?relay=${encodeURIComponent(relayUrl)}`;
    },

    // Multiplexed relay pool (multi-worker WebSocket proxy)
    _getRelayPoolUrl() {
        const host = this._getApiHost();
        if (!host) return null;
        return `wss://${host}/api/relay-pool`;
    },

    // Returns true if any pool worker socket is open
    _isAnyPoolOpen() {
        return this.poolSockets.some(p => p.ws && p.ws.readyState === WebSocket.OPEN);
    },

    // Shard relays into role-based worker groups, splitting large groups into chunks
    _shardRelaysByRole(allRelays, geoRelayUrls, dmRelays) {
        const blocked = new Set(['wss://relay.nosflare.com', 'wss://relay.nostraddress.com', 'wss://nostr-server-production.up.railway.app']);
        const permanent = this._permanentBlacklist || new Set();
        const isValid = (url) => !blocked.has(url) && !permanent.has(url);

        // Categorize relays by role
        const geoSet = new Set(geoRelayUrls || []);

        // Critical = default relays (deduplicated)
        const critical = [...new Set([...this.defaultRelays, ...(dmRelays || [])])]
            .filter(isValid);

        // Geo = CSV relays not already in critical
        const criticalSet = new Set(critical);
        const geo = [...geoSet].filter(url => isValid(url) && !criticalSet.has(url));

        // Discovered = any URL in allRelays that isn't already critical or geo (NIP-66 / NIP-65)
        const geoSetForDiscovered = new Set(geo);
        const discovered = [...new Set(allRelays || [])]
            .filter(url => isValid(url) && !criticalSet.has(url) && !geoSetForDiscovered.has(url));

        // Split each category into chunks of RELAYS_PER_WORKER
        const chunkArray = (arr, size) => {
            const chunks = [];
            for (let i = 0; i < arr.length; i += size) {
                chunks.push(arr.slice(i, i + size));
            }
            return chunks.length > 0 ? chunks : [[]];
        };

        const shards = [];
        const criticalChunks = chunkArray(critical, this.RELAYS_PER_WORKER);
        criticalChunks.forEach((chunk, i) => {
            shards.push({
                id: `critical-${i}`,
                role: 'critical',
                relays: chunk,
                dmRelays: i === 0 ? (dmRelays || []) : []
            });
        });

        const geoChunks = chunkArray(geo, this.RELAYS_PER_WORKER);
        if (geo.length > 0) {
            geoChunks.forEach((chunk, i) => {
                shards.push({
                    id: `geo-${i}`,
                    role: 'geo',
                    relays: chunk,
                    dmRelays: []
                });
            });
        }

        if (discovered.length > 0) {
            const discoveredChunks = chunkArray(discovered, this.RELAYS_PER_WORKER);
            discoveredChunks.forEach((chunk, i) => {
                shards.push({
                    id: `discovered-${i}`,
                    role: 'discovered',
                    relays: chunk,
                    dmRelays: []
                });
            });
        }

        return shards;
    },

    // Add a message listener to all open pool sockets
    _poolAddMessageListener(handler) {
        for (const p of this.poolSockets) {
            if (p.ws) p.ws.addEventListener('message', handler);
        }
    },

    // Remove a message listener from all pool sockets
    _poolRemoveMessageListener(handler) {
        for (const p of this.poolSockets) {
            if (p.ws) {
                try { p.ws.removeEventListener('message', handler); } catch (_) { }
            }
        }
    },

    // Schedule a pool reconnection with exponential backoff, preventing concurrent attempts.
    _schedulePoolReconnect() {
        if (this._poolReconnecting) return;
        if (!this.useRelayProxy) return;
        if (!this._isCloudflareHost) return;

        // Debounce: prevent rapid-fire reconnect scheduling from multiple event handlers
        const now = Date.now();
        if (this._lastPoolReconnectSchedule && now - this._lastPoolReconnectSchedule < 2000) return;
        this._lastPoolReconnectSchedule = now;

        const attempt = (retries) => {
            if (this._isAnyPoolOpen()) {
                this._poolReconnecting = false;
                return;
            }
            if (!navigator.onLine) {
                // Wait for the 'online' event to trigger reconnection instead
                this._poolReconnecting = false;
                return;
            }

            const baseDelay = Math.min(3000 * Math.pow(2, retries), 30000);
            const delay = Math.floor(baseDelay * (0.5 + Math.random() * 0.5));
            this.updateConnectionStatus(retries > 0
                ? `Reconnecting (attempt ${retries + 1})...`
                : 'Reconnecting...');

            setTimeout(() => {
                // Re-check: another path may have reconnected while we waited
                if (this._isAnyPoolOpen()) {
                    this._poolReconnecting = false;
                    return;
                }
                this._connectToRelayPool()
                    .then(() => {
                        this._poolReconnecting = false;
                        this._poolReconnectRetries = 0;
                        this._startPoolKeepalive();
                        this._startPoolShardHealthCheck();
                        this._poolSubscribe();
                        this.retryPendingDMsOnReconnect();
                    })
                    .catch(() => {
                        if (retries < 1) {
                            attempt(retries + 1);
                        } else {
                            this._poolReconnecting = false;
                            this._poolReconnectRetries = 0;
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

    // Reconnect a single failed pool worker shard.
    // Retries until the shard reconnects or is no longer needed; the periodic
    // health check (_ensureAllShardsConnected) acts as a final safety net.
    _reconnectPoolShard(shard) {
        if (!this.useRelayProxy) return;
        if (!this._isCloudflareHost) return;
        const shardId = shard.id;

        if (!this._shardReconnecting) this._shardReconnecting = new Set();
        if (this._shardReconnecting.has(shardId)) return;
        this._shardReconnecting.add(shardId);

        const attempt = (retries) => {
            const existing = this.poolSockets.find(p => p.id === shardId);
            if (existing && existing.ws && existing.ws.readyState === WebSocket.OPEN) {
                this._shardReconnecting.delete(shardId);
                return;
            }
            if (!this.useRelayProxy || !navigator.onLine) {
                this._shardReconnecting.delete(shardId);
                return;
            }

            const baseDelay = Math.min(3000 * Math.pow(1.7, retries), 60000);
            const delay = Math.floor(baseDelay * (0.7 + Math.random() * 0.3));
            setTimeout(() => {
                const stillDown = this.poolSockets.find(p => p.id === shardId);
                if (stillDown && stillDown.ws && stillDown.ws.readyState === WebSocket.OPEN) {
                    this._shardReconnecting.delete(shardId);
                    return;
                }
                if (!this.useRelayProxy || !navigator.onLine) {
                    this._shardReconnecting.delete(shardId);
                    return;
                }

                this._connectSinglePoolWorker(shard)
                    .then(() => {
                        this._shardReconnecting.delete(shardId);
                        this._startPoolKeepalive();
                        this._poolSubscribeOnWorker(shard.id);
                    })
                    .catch(() => {
                        // Keep retrying — every shard matters for full relay coverage.
                        // The health check will stop us if the shard is no longer expected.
                        attempt(retries + 1);
                    });
            }, delay);
        };

        attempt(0);
    },

    // Compute the current expected shard set from configured relays.
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

    // Reconnect any expected shard that's missing or not in OPEN state.
    _ensureAllShardsConnected() {
        if (!this.useRelayProxy) return;
        if (!this._isCloudflareHost) return;
        if (!navigator.onLine) return;
        if (!this._isAnyPoolOpen()) return;

        const expectedShards = this._computeExpectedShards();
        for (const shard of expectedShards) {
            const existing = this.poolSockets.find(p => p.id === shard.id);
            const isOpen = existing && existing.ws && existing.ws.readyState === WebSocket.OPEN;
            if (!isOpen) {
                this._reconnectPoolShard(shard);
            }
        }
    },

    _startPoolShardHealthCheck() {
        if (this._poolShardHealthTimer) clearInterval(this._poolShardHealthTimer);
        this._poolShardHealthTimer = setInterval(() => {
            if (document.hidden) return;
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
        // Prevent concurrent connection attempts
        if (this._poolConnecting) {
            return Promise.reject(new Error('Connection already in progress'));
        }
        if (this.poolSockets.some(p => p.ws && p.ws.readyState === WebSocket.CONNECTING)) {
            return Promise.reject(new Error('Connection already in progress'));
        }
        this._poolConnecting = true;

        // Gather all relay URLs
        let geoRelayUrls = [];

        if (this.settings && this.settings.lowDataMode) {
            // Low data: only defaults + DM relays (geo added on-demand)
            geoRelayUrls = [];
        } else {
            geoRelayUrls = (this.geoRelays || []).map(r => r.url || r).filter(Boolean);
        }

        const shards = this._shardRelaysByRole(
            [...this.allRelayUrls],
            geoRelayUrls,
            this.defaultRelays
        );

        // Close any existing pool sockets (mark as intentional to prevent reconnect loops)
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

    // Connect a single pool worker for a shard of relays
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
                lastMessage: Date.now()
            };

            // Add to poolSockets array (replace if same id exists)
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
            }, 12000);

            ws.onopen = () => {
                clearTimeout(timeout);
                wasOpen = true;

                ws.send(JSON.stringify(['RELAYS', {
                    relays: shard.relays,
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
                this._syncLegacyPoolSocket();

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

                    if (msgType === 'POOL:RELAY_BAN') {
                        const banUrl = msg[1];
                        const banReason = msg[2] || 'banned';
                        if (typeof banUrl === 'string' && banUrl.startsWith('wss://')) {
                            this._permanentlyBlacklistRelay(banUrl, banReason);
                        }
                        return;
                    }

                    if (msgType === 'POOL:STATUS') {
                        const status = msg[1];
                        poolEntry.connectedRelays = status.connected || [];

                        // Update per-relay latency from this worker
                        if (status.latency) {
                            for (const [url, ms] of Object.entries(status.latency)) {
                                this.relayStats.latencyPerRelay.set(url, ms);
                            }
                        }

                        // Per-relay event counts are tracked in handleRelayMessage
                        // post-dedup so counts match the headline unique-event total.

                        // Merge connected relays from ALL workers
                        this._mergePoolStatus();
                    } else if (msgType === 'EVENT') {
                        const evt = msg[2];
                        if (evt && typeof evt.created_at === 'number' && evt.created_at > 0) {
                            this._updateShardLastSeen(poolEntry.id, evt.created_at);
                        }
                        this.handleRelayMessage(msg, 'relay-pool');
                    } else {
                        this.handleRelayMessage(msg, 'relay-pool');
                    }
                } catch {
                    // Parse error
                }
            };

            let wasOpen = false;
            let errorRejected = false;

            ws.onclose = () => {
                clearTimeout(timeout);

                // Skip reconnect logic if this socket was intentionally closed
                if (poolEntry._closing) return;

                // If we never opened, onerror already rejected — don't schedule reconnects
                // (the caller's retry loop handles reconnection for initial failures)
                if (!wasOpen) {
                    if (!errorRejected) reject(new Error(`Pool worker ${shard.id} closed before open`));
                    return;
                }

                if (!this._reconnectingShards) this._reconnectingShards = new Set();
                this._reconnectingShards.add(shard.id);
                if (this._poolEventBaselines) this._poolEventBaselines.delete(shard.id);

                poolEntry.connectedRelays = [];
                poolEntry.ws = null;
                this._mergePoolStatus();
                this._syncLegacyPoolSocket();

                // If ALL workers are down, update status and trigger full reconnect
                if (!this._isAnyPoolOpen()) {
                    this.poolReady = false;
                    this.connected = false;
                    this.updateConnectionStatus('Disconnected');
                    this._schedulePoolReconnect();
                } else {
                    // Only this worker died — reconnect just this shard
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

    // Merge POOL:STATUS from all workers into unified state
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

        // Anything seen within the grace window stays in the pool map as
        // either connected (in allConnected) or recently-disconnected.
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

        // Anything in relayPool that isn't tracked any more (e.g. switched
        // out of pool mode) gets cleaned up.
        for (const url of [...this.relayPool.keys()]) {
            if (!this._poolRelayLastSeen.has(url)) {
                const entry = this.relayPool.get(url);
                // Direct-mode entries have a ws other than the pool socket;
                // leave those alone.
                if (entry && entry.type === 'relay' && entry.ws === this.poolSocket) {
                    this.relayPool.delete(url);
                }
            }
        }

        this.updateConnectionStatus();
    },

    // Keep legacy this.poolSocket pointing to first open socket for external compat
    _syncLegacyPoolSocket() {
        const open = this.poolSockets.find(p => p.ws && p.ws.readyState === WebSocket.OPEN);
        this.poolSocket = open ? open.ws : null;
    },

    // Start client-side keepalive: detect stale worker connections
    _startPoolKeepalive() {
        if (this._poolKeepaliveTimer) clearInterval(this._poolKeepaliveTimer);
        this._poolKeepaliveTimer = setInterval(() => {
            if (!this._isAnyPoolOpen()) {
                clearInterval(this._poolKeepaliveTimer);
                this._poolKeepaliveTimer = null;
                return;
            }
            const now = Date.now();
            for (const p of this.poolSockets) {
                if (p.ws && p.ws.readyState === WebSocket.OPEN) {
                    const silenceSec = (now - (p.lastMessage || 0)) / 1000;
                    if (silenceSec > 90) {
                        p.ws.close();
                    }
                }
            }
        }, 30000);
    },

    // Normalize a filter array: dedup values inside any array field (kinds,
    // authors, ids, #X tags) and drop entirely-duplicate filter objects.
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
        for (const p of this.poolSockets) {
            this._safeWsSend(p.ws, msg, { critical });
        }
    },

    _poolSendToRole(role, data) {
        if (Array.isArray(data) && data[0] === 'REQ') {
            data = this._normalizeReqPayload(data);
        }
        const msg = typeof data === 'string' ? data : JSON.stringify(data);
        const critical = Array.isArray(data) && (data[0] === 'EVENT' || data[0] === 'DM_EVENT' || data[0] === 'GEO_EVENT' || data[0] === 'CLOSE');
        for (const p of this.poolSockets) {
            if (p.role === role) this._safeWsSend(p.ws, msg, { critical });
        }
    },

    _poolSubscribeOnWorker(shardId) {
        const p = this.poolSockets.find(w => w.id === shardId);
        if (!p || !p.ws || p.ws.readyState !== WebSocket.OPEN) return;

        if (p._lastSubId) {
            this._safeWsSend(p.ws, JSON.stringify(["CLOSE", p._lastSubId]), { critical: true });
            p._lastSubId = null;
        }

        const sinceFloor = this._getShardSinceFloor(p.id);

        const isGeoOrDiscovered = p.role === 'geo' || p.role === 'discovered';
        const filters = isGeoOrDiscovered
            ? this._buildGeoFilters(sinceFloor)
            : this._buildCriticalFilters(sinceFloor);

        const subId = Math.random().toString(36).substring(2);
        p._lastSubId = subId;

        const msg = JSON.stringify(this._normalizeReqPayload(["REQ", subId, ...filters]));
        this._safeWsSend(p.ws, msg, { critical: true });

        if (!isGeoOrDiscovered) {
            this._refreshEphemeralSubscriptions();
        }
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
        const filters = [];
        if (!this.settings.groupChatPMOnlyMode) {
            filters.push({ kinds: [20000], since: since24h });
            filters.push({ kinds: [23333], since: since24h });
        }
        return filters;
    },

    _buildCriticalFilters(since24h) {
        const filters = [];
        const nowSec = Math.floor(Date.now() / 1000);
        const channelMode = !this.settings.groupChatPMOnlyMode;

        // Critical real-time filters — proxy splits these into individual subs (one per filter)
        if (this.pubkey) {
            filters.push({ kinds: [1059], "#p": [this.pubkey], limit: 500 });
        }
        if (channelMode) {
            filters.push({ kinds: [20000], since: since24h });
            filters.push({ kinds: [23333], since: since24h });
        }
        if (this.pubkey) {
            filters.push({ kinds: [7], "#p": [this.pubkey], "#k": ["20000", "23333"], limit: 100 });
        }
        if (channelMode) {
            filters.push({ kinds: [7], "#k": ["20000", "23333"], since: since24h, limit: 100 });
        }
        filters.push({ kinds: [7], "#k": ["1059"], limit: 100 });
        if (channelMode) {
            filters.push({ kinds: [5], "#k": ["20000", "23333", "1059"], since: since24h, limit: 100 });
        }
        const zapFilter = this._buildZapReceiptFilter();
        if (zapFilter) filters.push(zapFilter);
        if (this.pubkey) {
            filters.push({
                kinds: [9735],
                "#p": [this.pubkey],
                "#k": ["20000", "23333", "1059", "0"],
                since: since24h,
                limit: 200
            });
        }

        // Less critical — anything past position 9 is bundled into a single sub upstream
        if (this.pubkey) {
            filters.push({ kinds: [25051], "#p": [this.pubkey], since: nowSec - 120, limit: 50 });
        }
        filters.push({ kinds: [30078], "#t": ["nym-presence"], limit: 100 });
        if (channelMode) {
            filters.push({ kinds: [30078], "#t": ["nym-poll", "nym-poll-vote"], since: since24h, limit: 100 });
        }
        filters.push({ kinds: [30078], "#t": ["nym-vouches"], limit: 1000 });
        filters.push({ kinds: [30030], limit: 300 });
        if (this.pubkey) {
            filters.push({ kinds: [25052], since: nowSec - 86400, limit: 100 });
            filters.push({ kinds: [10030], authors: [this.pubkey], limit: 1 });
        }
        const profileAuthors = this.pmConversations
            ? Array.from(this.pmConversations.keys()).filter(pk => typeof pk === 'string' && pk.length === 64)
            : [];
        // Keep a live kind 0 subscription on our own pubkey so profile edits made
        // in another Nostr client arrive in real time and get mirrored to R2.
        if (this.pubkey && !profileAuthors.includes(this.pubkey)) {
            profileAuthors.push(this.pubkey);
        }
        if (profileAuthors.length > 0) {
            filters.push({ kinds: [0], authors: profileAuthors });
        }

        return filters;
    },

    _isNostrHex64(s) {
        return typeof s === 'string' && s.length === 64 && /^[0-9a-f]{64}$/i.test(s);
    },

    _collectVisibleEventIds() {
        this._zapReceiptEventIds.clear();
        this.messages.forEach((msgs) => {
            for (const msg of msgs) {
                if (this._isNostrHex64(msg.id)) this._zapReceiptEventIds.add(msg.id);
            }
        });
        if (this.pmMessages) {
            this.pmMessages.forEach((msgs) => {
                for (const msg of msgs) {
                    if (this._isNostrHex64(msg.id)) this._zapReceiptEventIds.add(msg.id);
                }
            });
        }
    },

    _poolSubscribe() {
        if (!this._isAnyPoolOpen()) return;

        // Close previous subscriptions to avoid duplicate event streams
        if (this._lastCriticalSubId) {
            this._poolSendToRole('critical', ["CLOSE", this._lastCriticalSubId]);
        }
        if (this._lastGeoSubId) {
            this._poolSendToRole('geo', ["CLOSE", this._lastGeoSubId]);
            this._poolSendToRole('discovered', ["CLOSE", this._lastGeoSubId]);
        }
        const since24h = Math.floor(Date.now() / 1000) - 86400;

        // Critical shards (default + DM relays): full subscription set
        const criticalSubId = Math.random().toString(36).substring(2);
        this._lastCriticalSubId = criticalSubId;
        const criticalFilters = this._buildCriticalFilters(since24h);
        this._poolSendToRole('critical', ["REQ", criticalSubId, ...criticalFilters]);

        // Geo + discovered shards: channel-message kinds (20000, 23333)
        const geoSubId = Math.random().toString(36).substring(2);
        this._lastGeoSubId = geoSubId;
        const geoFilters = this._buildGeoFilters(since24h);
        this._poolSendToRole('geo', ["REQ", geoSubId, ...geoFilters]);
        this._poolSendToRole('discovered', ["REQ", geoSubId, ...geoFilters]);

        // Subscribe to ephemeral pubkeys as independent REQs (metadata separation)
        this._refreshEphemeralSubscriptions();

        // Re-subscribe to channel-targeted subscriptions that were lost on disconnect
        this._resubscribeChannels();
    },

    // History fetch for ephemeral pubkeys
    async _recoverEphemeralHistory(ephPks) {
        if (!Array.isArray(ephPks) || ephPks.length === 0) return;
        const since = this._isFreshDevice
            ? 0
            : (this.lastPMSyncTime > 0 ? Math.max(0, this.lastPMSyncTime - 300) : 0);

        const filter = { kinds: [1059], '#p': ephPks, limit: 500 * ephPks.length };
        if (since > 0) filter.since = since;
        const subId = Math.random().toString(36).substring(2);
        this._registerBackfillSub(subId);

        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            this._poolSendToRole('critical', ['REQ', subId, filter]);
        } else {
            const req = JSON.stringify(this._normalizeReqPayload(['REQ', subId, filter]));
            this.relayPool.forEach((relay, url) => {
                if (this.writeOnlyRelays && this.writeOnlyRelays.has(url)) return;
                if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                    this._safeWsSend(relay.ws, req, { critical: true });
                }
            });
        }

        await this._waitForEoseOrTimeout(subId, 5000);
    },

    // Subscribe to gift wraps (kind 1059) for all of our ephemeral pubkeys
    async _refreshEphemeralSubscriptions() {
        if (this._ephRefreshInFlight) return;
        this._ephRefreshInFlight = true;
        try {
            for (const oldSubId of (this._ephemeralSubIds || [])) {
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
            this._ephemeralSubIds = [];

            const ephPks = this._getAllSelfEphemeralPubkeys();
            if (!ephPks.length) return;

            const since = Math.floor(Date.now() / 1000) - 604800;
            const subId = Math.random().toString(36).substring(2);
            this._ephemeralSubIds.push(subId);
            const filter = { kinds: [1059], "#p": ephPks, since, limit: 200 * ephPks.length };

            if (this.useRelayProxy && this._isAnyPoolOpen()) {
                this._poolSendToRole('critical', ['REQ', subId, filter]);
            } else {
                const msg = JSON.stringify(this._normalizeReqPayload(['REQ', subId, filter]));
                this.relayPool.forEach((relay, url) => {
                    if (this.writeOnlyRelays && this.writeOnlyRelays.has(url)) return;
                    if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                        this._safeWsSend(relay.ws, msg, { critical: true });
                    }
                });
            }

            await this._waitForEoseOrTimeout(subId, 5000);
        } finally {
            this._ephRefreshInFlight = false;
        }
    },

    // Re-subscribe to active channel subscriptions after a relay reconnection.
    // Coalesces rapid back-to-back calls (e.g. multiple shard reconnects) so
    // we don't wipe and re-fire every joined channel's REQ each time.
    _resubscribeChannels() {
        const now = Date.now();
        if (this._lastResubscribeAt && now - this._lastResubscribeAt < 15000) return;
        this._lastResubscribeAt = now;

        // Clear stale channel tracking — old subscription IDs are invalid after reconnect
        this.channelLoadedFromRelays.clear();
        this.channelSubscriptions.clear();
        if (this._channelTypingSubs) this._channelTypingSubs.clear();

        // Re-subscribe to current channel immediately
        if (this.currentChannel) {
            this.subscribeToChannelTargeted(this.currentChannel, 'geohash');
        }

        // Re-load joined channels and common geohashes with a small delay
        // to avoid overwhelming relays right after reconnection
        setTimeout(() => {
            this.loadJoinedChannelsFromRelays();
        }, 1000);

        this.backfillFromR2OnReconnect();
    },

    backfillFromR2OnReconnect() {
        if (!this._getApiHost || !this._getApiHost()) return;
        const now = Date.now();
        if (this._lastR2BackfillAt && now - this._lastR2BackfillAt < 30000) return;
        this._lastR2BackfillAt = now;

        if (typeof this.pmRestoreFromR2 === 'function') {
            this.pmRestoreFromR2().catch(() => { });
        }

        if (typeof this.channelRestoreFromR2 === 'function') {
            const channels = new Set();
            const current = this.currentGeohash || this.currentChannel;
            if (current) channels.add(current);
            if (this.userJoinedChannels) this.userJoinedChannels.forEach(k => channels.add(k));
            channels.forEach(name => this.channelRestoreFromR2(name).catch(() => { }));
        }
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

        // Gather current relay sets
        let geoRelayUrls = [];

        if (this.settings && this.settings.lowDataMode) {
            // Low data: include current geo relays + defaults + DM
            geoRelayUrls = [...this.currentGeoRelays];
        } else {
            geoRelayUrls = (this.geoRelays || []).map(r => r.url || r).filter(Boolean);
            // Include current geo relays for priority
            for (const url of this.currentGeoRelays) {
                if (!geoRelayUrls.includes(url)) geoRelayUrls.unshift(url);
            }
        }

        const shards = this._shardRelaysByRole(
            [...this.allRelayUrls],
            geoRelayUrls,
            this.defaultRelays
        );

        // Determine which shards are new vs existing
        const existingIds = new Set(this.poolSockets.map(p => p.id));
        const newShardIds = new Set(shards.map(s => s.id));

        const arraysEqual = (a, b) => {
            if (!a || !b) return a === b;
            if (a.length !== b.length) return false;
            const setA = new Set(a);
            for (const v of b) if (!setA.has(v)) return false;
            return true;
        };

        for (const shard of shards) {
            const existing = this.poolSockets.find(p => p.id === shard.id);
            if (existing && existing.ws && existing.ws.readyState === WebSocket.OPEN) {
                const sameRelays = arraysEqual(existing.relays, shard.relays);
                const sameDm = arraysEqual(existing.dmRelays || [], shard.dmRelays || []);
                if (sameRelays && sameDm) continue;
                existing.relays = shard.relays;
                existing.dmRelays = shard.dmRelays || [];
                existing.ws.send(JSON.stringify(['RELAYS', {
                    relays: shard.relays,
                    dmRelays: shard.dmRelays || []
                }]));
            } else if (!existingIds.has(shard.id)) {
                // New shard — connect a new worker
                this._connectSinglePoolWorker(shard).then(() => {
                    this._poolSubscribeOnWorker(shard.id);
                }).catch(() => { });
            }
        }

        // Close workers for shards that no longer exist (e.g., all discovered relays removed)
        for (const p of this.poolSockets) {
            if (!newShardIds.has(p.id)) {
                p._closing = true;
                if (p.ws && p.ws.readyState === WebSocket.OPEN) p.ws.close();
            }
        }

        // Remove closed entries
        this.poolSockets = this.poolSockets.filter(p => newShardIds.has(p.id));
    },

    async connectToRelay(relayUrl, type = 'relay') {
        // Pool mode: all relay connections are managed by the multiplexed pool worker
        if (this.useRelayProxy) return;

        if (relayUrl === this.appRelay) return;

        // Block known-bad relays entirely - never connect
        if (relayUrl === 'wss://relay.nosflare.com' || relayUrl === 'wss://relay.nostraddress.com' || relayUrl === 'wss://nostr-server-production.up.railway.app') {
            return;
        }

        // Skip blacklisted/retry-throttled relays (no pending tracking needed)
        if (this.blacklistedRelays.has(relayUrl) && !this.isBlacklistExpired(relayUrl)) {
            return;
        }
        if (!this.shouldRetryRelay(relayUrl)) {
            return;
        }

        // Skip if already connected
        if (this.relayPool.has(relayUrl)) {
            const existingRelay = this.relayPool.get(relayUrl);
            if (existingRelay.ws && existingRelay.ws.readyState === WebSocket.OPEN) {
                return Promise.resolve();
            }
        }

        // Deduplicate: if a connection attempt is already in-flight, reuse its promise
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

                // Add connection timeout (5 seconds)
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

                    // Track connection latency
                    this.relayStats.latencyPerRelay.set(relayUrl, Date.now() - wsCreatedAt);

                    this.relayPool.set(relayUrl, {
                        ws,
                        type,
                        status: 'connected',
                        connectedAt: Date.now()
                    });

                    this.clearRelayFailure(relayUrl);
                    resolve();
                };

                ws.onmessage = (event) => {
                    try {
                        // Track relay stats
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

                    // Immediately blacklist on connection error (but never the app relay)
                    if (relayUrl !== this.appRelay) {
                        this.blacklistedRelays.add(relayUrl);
                        this.blacklistTimestamps.set(relayUrl, Date.now());
                    }

                    resolve(); // Resolve (not reject) — callers check relayPool state
                };

                ws.onclose = (event) => {
                    clearTimeout(verificationTimeout);
                    clearTimeout(connectionTimeout);

                    // Track if this relay was previously successfully connected
                    const wasConnected = this.relayPool.has(relayUrl) &&
                        this.relayPool.get(relayUrl).ws === ws;

                    // Only blacklist on actual connection failures, not normal closes
                    const isConnectionFailure = !wasConnected && event.code !== 1000 && event.code !== 1001;

                    if (isConnectionFailure && relayUrl !== this.appRelay) {
                        this.blacklistedRelays.add(relayUrl);
                        this.blacklistTimestamps.set(relayUrl, Date.now());
                    }

                    // Track previously connected relays for prioritized reconnection
                    if (wasConnected) {
                        if (!this.previouslyConnectedRelays) {
                            this.previouslyConnectedRelays = new Set();
                        }
                        this.previouslyConnectedRelays.add(relayUrl);
                    }

                    // Immediately remove from pool and update status
                    this.relayPool.delete(relayUrl);

                    // Force status update after disconnect
                    this.updateConnectionStatus();

                    // Reconnect ALL relay types (broadcast, nosflare, AND read relays)
                    // Pool mode handles its own reconnections — skip individual relay reconnect
                    // For previously connected relays, always attempt reconnection (no blacklist check)
                    if (!this.useRelayProxy && this.connected && (wasConnected || !this.blacklistedRelays.has(relayUrl))) {
                        // Track disconnections
                        if (!this.reconnectingRelays) {
                            this.reconnectingRelays = new Set();
                        }

                        // Only reconnect if not already reconnecting this URL
                        if (this.reconnectingRelays.has(relayUrl)) {
                            return;
                        }

                        this.reconnectingRelays.add(relayUrl);

                        // Implement exponential backoff for reconnection
                        // Use faster reconnection for previously connected relays
                        const isAppRelay = relayUrl === this.appRelay;
                        const attemptReconnect = (attempt = 0) => {
                            const maxAttempts = isAppRelay ? Infinity : 10;
                            // Faster initial delay for previously connected relays (1s vs 5s)
                            const baseDelay = (wasConnected || isAppRelay) ? 1000 : 5000;
                            const maxDelay = (wasConnected || isAppRelay) ? 30000 : 60000;

                            // Calculate exponential backoff delay
                            const delay = Math.min(baseDelay * Math.pow(1.5, attempt), maxDelay);

                            setTimeout(() => {
                                // Check WebSocket state and network connectivity
                                if (!navigator.onLine) {
                                    this.reconnectingRelays.delete(relayUrl);
                                    this.updateConnectionStatus();
                                    return;
                                }

                                // Check if we're still supposed to be connected
                                if (!this.connected) {
                                    this.reconnectingRelays.delete(relayUrl);
                                    this.updateConnectionStatus();
                                    return;
                                }

                                this.connectToRelay(relayUrl, type).then(() => {
                                    // Check if actually connected (connectToRelay resolves even on failure)
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

                        // Start reconnection attempts
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

        // Track in-flight connection and clean up when settled
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
            // Expired, remove from blacklist
            this.blacklistedRelays.delete(relayUrl);
            this.blacklistTimestamps.delete(relayUrl);
            return true;
        }

        return false;
    },

    // NIP-66 relay discovery: query monitor relays for kind 30166 events
    // and merge any new clearnet wss URLs into allRelayUrls. Skipped in low
    // data mode. Cached in localStorage between sessions.
    async discoverRelaysViaNip66({ force = false } = {}) {
        if (this.settings && this.settings.lowDataMode) return;
        if (this._nip66Running) return;

        const now = Date.now();
        const interval = this.relayDiscoveryInterval || 24 * 3600 * 1000;
        if (!force && this._nip66Done && this._nip66LastRun && (now - this._nip66LastRun) < interval) return;

        // Try the localStorage cache first
        if (!force) {
            try {
                const cached = localStorage.getItem('nym_discovered_relays');
                if (cached) {
                    const data = JSON.parse(cached);
                    if (data && data.timestamp && (now - data.timestamp) < interval && Array.isArray(data.relays) && data.relays.length > 0) {
                        this._mergeDiscoveredRelays(data.relays);
                        this._nip66Done = true;
                        this._nip66LastRun = now;
                        return;
                    }
                }
            } catch (_) { }
        }

        const monitors = this.monitorRelays || [
            'wss://relay.nostr.watch',
            'wss://history.nostr.watch',
            'wss://relaypag.es'
        ];

        this._nip66Running = true;

        const all = new Set();
        const fetches = monitors.map(url =>
            this._fetchRelaysFromMonitor(url).then(list => {
                for (const u of list) all.add(u);
            }).catch(() => { })
        );

        // Overall wall-time cap on top of per-monitor timeouts
        await Promise.race([
            Promise.allSettled(fetches),
            new Promise(resolve => setTimeout(resolve, 12000))
        ]);

        const added = this._mergeDiscoveredRelays([...all]);

        if (all.size > 0) {
            try {
                localStorage.setItem('nym_discovered_relays', JSON.stringify({
                    timestamp: now,
                    relays: [...all]
                }));
            } catch (_) { }
        }

        if (added > 0) {
            if (this.useRelayProxy) {
                if (this._isAnyPoolOpen()) this._poolSendRelayConfig();
            } else {
                this.retryDiscoveredRelays();
            }
        }

        this._nip66Running = false;
        this._nip66Done = true;
        this._nip66LastRun = now;
        this._nip66LastAdded = added;
    },

    _mergeDiscoveredRelays(urls) {
        const blocked = new Set([
            'wss://relay.nosflare.com',
            'wss://relay.nostraddress.com',
            'wss://nostr-server-production.up.railway.app'
        ]);
        let added = 0;
        for (const raw of urls) {
            if (added >= this.nip66MaxNewRelays) break;
            const url = this._normalizeNip66RelayUrl(raw);
            if (!url) continue;
            if (blocked.has(url)) continue;
            if (this.allRelayUrls.has(url)) continue;
            this.allRelayUrls.add(url);
            added++;
        }
        return added;
    },

    // Connect to a NIP-66 monitor relay (via proxy when enabled) and collect
    // kind 30166 events for the last 3 hours.
    _fetchRelaysFromMonitor(monitorUrl) {
        return new Promise((resolve) => {
            const found = new Set();
            let ws;
            try {
                ws = new WebSocket(this._getProxiedRelayUrl(monitorUrl));
            } catch (_) {
                return resolve([]);
            }

            const subId = 'relay-disc-' + Math.random().toString(36).slice(2, 9);
            let done = false;

            const finish = () => {
                if (done) return;
                done = true;
                try {
                    if (ws.readyState === WebSocket.OPEN) {
                        try { ws.send(JSON.stringify(['CLOSE', subId])); } catch (_) { }
                    }
                    ws.close();
                } catch (_) { }
                resolve([...found]);
            };

            const timeout = setTimeout(finish, 10000);

            ws.onopen = () => {
                const since3h = Math.floor(Date.now() / 1000) - 3 * 3600;
                try {
                    ws.send(JSON.stringify(['REQ', subId, { kinds: [30166], since: since3h, limit: 1000 }]));
                } catch (_) {
                    clearTimeout(timeout);
                    finish();
                }
            };

            ws.onmessage = (event) => {
                try {
                    const msg = JSON.parse(event.data);
                    if (!Array.isArray(msg)) return;
                    if (msg[0] === 'EVENT' && msg[1] === subId) {
                        const evt = msg[2];
                        if (!evt || evt.kind !== 30166 || !Array.isArray(evt.tags)) return;
                        const dTag = evt.tags.find(t => t[0] === 'd');
                        if (!dTag || typeof dTag[1] !== 'string') return;
                        const relayUrl = dTag[1];
                        if (!relayUrl.startsWith('wss://')) return;
                        // Skip auth- or payment-gated relays
                        const rTags = evt.tags.filter(t => t[0] === 'R');
                        if (rTags.some(t => t[1] === 'auth' || t[1] === 'payment')) return;
                        // Optional clearnet check via 'n' tag
                        const nTag = evt.tags.find(t => t[0] === 'n');
                        if (nTag && nTag[1] && nTag[1] !== 'clearnet') return;
                        found.add(relayUrl);
                    } else if (msg[0] === 'EOSE' && msg[1] === subId) {
                        clearTimeout(timeout);
                        finish();
                    }
                } catch (_) { }
            };

            ws.onerror = () => {
                clearTimeout(timeout);
                finish();
            };
            ws.onclose = () => {
                clearTimeout(timeout);
                finish();
            };
        });
    },

    _normalizeNip66RelayUrl(raw) {
        if (typeof raw !== 'string') return null;
        let s = raw.trim();
        if (!s) return null;
        if (s.startsWith('ws://')) return null;
        if (!s.startsWith('wss://')) {
            if (/^[a-z][a-z0-9+.-]*:\/\//i.test(s)) return null;
            s = 'wss://' + s;
        }
        try {
            const u = new URL(s);
            if (u.protocol !== 'wss:') return null;
            if (!u.hostname || !u.hostname.includes('.')) return null;
            if (u.hostname === 'localhost' || /^\d+\.\d+\.\d+\.\d+$/.test(u.hostname)) return null;
            if (u.hostname.endsWith('.onion') || u.hostname.endsWith('.i2p')) return null;
            const path = u.pathname.replace(/\/+$/, '');
            return `wss://${u.hostname}${u.port ? ':' + u.port : ''}${path}`;
        } catch (_) {
            return null;
        }
    },

    async retryDiscoveredRelays() {
        // Low data mode: discovered relays are not used — skip entirely
        if (this.settings && this.settings.lowDataMode) return;

        // Pool mode: just update the pool config with any new discovered relays
        if (this.useRelayProxy) {
            this._poolSendRelayConfig();
            return;
        }

        // Clean expired blacklist entries first
        for (const relayUrl of this.blacklistedRelays) {
            this.isBlacklistExpired(relayUrl);
        }

        // Try to connect to any relays in allRelayUrls that we're not connected to
        const relaysToTry = [];

        // From unified relay set (CSV + defaults)
        for (const relay of this.allRelayUrls) {
            if (!this.relayPool.has(relay) &&
                !this.blacklistedRelays.has(relay) &&
                this.shouldRetryRelay(relay)) {
                relaysToTry.push(relay);
            }
        }

        if (relaysToTry.length > 0) {
            // Connect concurrently — browser handles WebSocket concurrency natively
            for (const relayUrl of relaysToTry) {
                this.connectToRelayWithTimeout(relayUrl, 'relay', this.relayTimeout).then(() => {
                    const r = this.relayPool.get(relayUrl);
                    if (r && r.ws && r.ws.readyState === WebSocket.OPEN) {
                        this.subscribeToSingleRelay(relayUrl);
                        this.updateConnectionStatus();
                    }
                });
            }
        }
    },

    // Enqueue a fetch through the concurrency-limited proxy queue.
    // Returns a Promise that resolves/rejects like a normal fetch.
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

    // Returns the base URL for the Cloudflare proxy endpoint (translation, media, unfurl).
    // Routes through the production host when running locally. Returns null if remote is down.
    _getProxyBaseUrl() {
        if (!this.useRelayProxy) return null;
        const host = this._getApiHost();
        if (!host) return null;
        return `https://${host}/api/proxy`;
    },

    // Fetch a JSON resource through the Cloudflare proxy when available.
    // Falls back to a direct fetch only if the proxy is unreachable.
    async proxiedJsonFetch(targetUrl, opts = {}) {
        const base = this._getProxyBaseUrl();
        if (!base) return fetch(targetUrl, opts);
        const proxyUrl = `${base}?action=json&url=${encodeURIComponent(targetUrl)}`;
        try {
            return await fetch(proxyUrl, opts);
        } catch (_) {
            return fetch(targetUrl, opts);
        }
    },

    // Reverse-geocode via the edge-cached proxy endpoint, with a direct
    // Nominatim fallback if the worker is unreachable or returns an error.
    async fetchGeocode(lat, lng, zoom = 10) {
        const base = this._getProxyBaseUrl();
        const direct = `https://nominatim.openstreetmap.org/reverse?format=json&lat=${lat}&lon=${lng}&zoom=${zoom}&accept-language=en`;
        if (base) {
            try {
                const res = await fetch(`${base}?action=geocode&lat=${lat}&lng=${lng}&zoom=${zoom}&lang=en`);
                if (res.ok) return await res.json();
            } catch (_) { /* fall through */ }
        }
        const res = await fetch(direct, { headers: { 'Accept-Language': 'en' } });
        if (!res.ok) throw new Error(`Geocode failed: ${res.status}`);
        return res.json();
    },

    // Fetch trending or search Giphy results via the edge-cached proxy
    // endpoint, with a direct Giphy fallback if the worker is unreachable.
    async fetchGiphy({ trending = false, query = '', apiKey }) {
        const base = this._getProxyBaseUrl();
        const directUrl = trending
            ? `https://api.giphy.com/v1/gifs/trending?api_key=${encodeURIComponent(apiKey)}&limit=20&rating=g`
            : `https://api.giphy.com/v1/gifs/search?api_key=${encodeURIComponent(apiKey)}&q=${encodeURIComponent(query)}&limit=20&rating=g`;
        if (base) {
            try {
                const params = trending
                    ? `trending=1&api_key=${encodeURIComponent(apiKey)}`
                    : `q=${encodeURIComponent(query)}&api_key=${encodeURIComponent(apiKey)}`;
                const res = await fetch(`${base}?action=giphy&${params}`);
                if (res.ok) return await res.json();
            } catch (_) { /* fall through */ }
        }
        const res = await fetch(directUrl);
        if (!res.ok) throw new Error(`Giphy failed: ${res.status}`);
        return res.json();
    },

    sendToRelay(message) {
        // Multiplexed pool mode: send everything through the single socket
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            // For EVENT messages, route through broadcastEvent so geohash-tagged
            // events use GEO_EVENT (geo relay prioritization) instead of plain EVENT.
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

    // Send DM events (kind 1059) with priority to the default relays
    sendDMToRelays(message) {
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
        // Multiplexed pool mode: route to critical shards only (profiles don't need geo/discovered)
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

    // Close a sub that was opened via sendRequestToFewRelays. Routes through
    // the same destinations the REQ used so we don't send CLOSE to relays
    // that never received the REQ (which would respond "No such subscription").
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
        this._trackSentEventKind(message);
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            let evt = null;
            try {
                if (Array.isArray(message) && message[0] === 'EVENT' && message[1] && typeof message[1] === 'object') {
                    evt = message[1];
                }
            } catch (_) { }
            const geohashTag = evt && evt.tags && evt.tags.find(t => t[0] === 'g');
            if (geohashTag && geohashTag[1]) {
                const closestRelays = this.getClosestRelaysForGeohash(geohashTag[1]);
                if (closestRelays.length > 0) {
                    const geoMsg = JSON.stringify(['GEO_EVENT', evt, closestRelays.map(r => r.url)]);
                    const plainMsg = JSON.stringify(message);
                    for (const p of this.poolSockets) {
                        const out = p.role === 'geo' ? geoMsg : plainMsg;
                        this._safeWsSend(p.ws, out, { critical: true });
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
        // Multiplexed pool mode: subscription through all pool workers
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

        // Send discovery subscriptions to each relay (small limits)
        readableRelays.forEach(([url, relay]) => {
            this.subscribeToSingleRelay(url);
        });

        // Also do channel discovery
        this.discoverChannels();

        // Wait 2 seconds for initial discovery to populate channels, then load full history
        setTimeout(() => {
            this.loadJoinedChannelsFromRelays();
        }, 2000);
    },

    // Pre-load messages for user-joined channels using batch subscriptions
    loadJoinedChannelsFromRelays() {
        // Skip channel loading in group chat & PM only mode
        if (this.settings.groupChatPMOnlyMode) return;

        // Debounce: don't re-batch joined channels more than once per 30s
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

        // Batch load in chunks
        const batchSize = this.channelSubscriptionBatchSize;
        for (let i = 0; i < channelsToLoad.length; i += batchSize) {
            const batch = channelsToLoad.slice(i, i + batchSize);
            // Stagger batch requests to avoid overwhelming relays
            setTimeout(() => {
                this.subscribeToChannelBatch(batch);
            }, Math.floor(i / batchSize) * 500);
        }
    },

    handleRelayMessage(msg, relayUrl) {
        if (!Array.isArray(msg)) return;

        const [type, ...data] = msg;

        switch (type) {
            case 'EVENT':
                const [subscriptionId, event, sourceRelay] = data;

                if (event && event.id) {
                    if (this.eventDeduplication.has(event.id)) {
                        return;
                    }

                    this.eventDeduplication.set(event.id, true);
                    this.relayStats.totalEvents++;
                    this.relayStats.eventsThisSecond++;

                    const attributedRelay = (typeof sourceRelay === 'string' && sourceRelay.startsWith('wss://'))
                        ? sourceRelay
                        : (relayUrl && relayUrl !== 'relay-pool' ? relayUrl : null);
                    if (attributedRelay) {
                        const cur = this.relayStats.eventsPerRelay.get(attributedRelay) || 0;
                        this.relayStats.eventsPerRelay.set(attributedRelay, cur + 1);
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
            case 'OK': {
                const okEventId = data[0];
                const accepted = data[1];
                const reason = data[2] || '';
                const attributedRelay = (typeof data[3] === 'string' && data[3].startsWith('wss://'))
                    ? data[3] : relayUrl;
                const r = typeof reason === 'string' ? reason : '';
                const hasEventId = typeof okEventId === 'string' && okEventId.length > 0;
                if (this._isUnsupportedKind(reason)) {
                    if (hasEventId) this._recordEventKindRejection(attributedRelay, okEventId);
                    else this._permanentlyBlacklistRelay(attributedRelay, reason);
                } else if (this._isRelayWideRejection(reason)) {
                    this._permanentlyBlacklistRelay(attributedRelay, reason);
                } else if (accepted === false) {
                    if (this._isPermanentRejection(reason)) {
                        if (hasEventId) this._recordEventKindRejection(attributedRelay, okEventId);
                        else this._permanentlyBlacklistRelay(attributedRelay, reason);
                    } else if (/^mute[\s:]/i.test(r)) {
                        // NIP-01 mute: relay accepted but no subscribers
                    } else if (/event[\s_-]?too[\s_-]?large|\btoo[\s_-]large\b|\bsize[\s_]*\d+.*max[\s_]*\d+|created_at\b.*\b(too|in)\b.*(early|late|future|past)|timestamp.*too/i.test(r)) {
                        // Per-event problem, not the relay's fault
                    } else if (/rate-?limit|too many|concurrent/i.test(r)) {
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
                // We don't implement NIP-42. Drop the relay that's asking
                // for AUTH so we don't waste connections on it.
                const authRelay = (typeof data[0] === 'string' && data[0].startsWith('wss://'))
                    ? data[0] : relayUrl;
                this._permanentlyBlacklistRelay(authRelay, 'auth-required');
                break;
            }
            case 'CLOSED': {
                // Direct: ["CLOSED", subId, reason]
                // Pool (proxy-attributed): ["CLOSED", subId, reason, relayUrl]
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
                } else if (this._isPermanentRejection(reason)) {
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
                // Direct: ["NOTICE", reason]
                // Pool (proxy-attributed): ["NOTICE", reason, relayUrl]
                const notice = data[0];
                const attributedRelay = (typeof data[1] === 'string' && data[1].startsWith('wss://'))
                    ? data[1] : relayUrl;
                if (this._isUnsupportedKind(notice)) {
                    // Per-REQ only: don't blacklist the relay for other kinds.
                } else if (this._isPermanentRejection(notice)) {
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
            // Add to queue
            this.profileFetchQueue.push({ pubkey, resolve });

            // Clear existing timer
            if (this.profileFetchTimer) {
                clearTimeout(this.profileFetchTimer);
            }

            // Set timer to process batch
            this.profileFetchTimer = setTimeout(() => {
                this.processBatchedProfileFetch();
            }, this.profileFetchBatchDelay);
        });
    },

    updateConnectionStatus(status) {
        const statusEl = document.getElementById('connectionStatus');
        const dot = document.getElementById('statusDot');

        // If status is a custom message, show it
        if (status && typeof status === 'string') {
            statusEl.textContent = status;

            // Update dot color based on status text
            if (status.includes('Connected') || status.includes('relays')) {
                dot.style.background = 'var(--primary)';
            } else if (status.includes('Connecting') || status.includes('Discovering')) {
                dot.style.background = 'var(--warning)';
            } else if (status.includes('Failed') || status.includes('Disconnected')) {
                dot.style.background = 'var(--danger)';
            }
        } else {
            // Pool mode: relayPool entries hold a stale legacy poolSocket ref
            // and report disconnected during single-worker reconnects.
            if (this.useRelayProxy) {
                const count = this.poolConnectedRelays.length;
                if (this._isAnyPoolOpen() && count > 0) {
                    statusEl.textContent = `Connected (${count} relays)`;
                    dot.style.background = 'var(--primary)';
                    this.connected = true;
                } else {
                    statusEl.textContent = 'Connecting...';
                    dot.style.background = 'var(--warning)';
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
                statusEl.textContent = `Connected (${actuallyConnected} relays)`;
                dot.style.background = 'var(--primary)';
                this.connected = true;
            } else {
                statusEl.textContent = 'Disconnected';
                dot.style.background = 'var(--danger)';
                this.connected = false;
            }

        }
    },

    // Apply +/- 25% jitter to a base delay to avoid thundering herd on reconnect
    _jitter(baseMs, spread = 0.25) {
        const factor = 1 - spread + Math.random() * spread * 2;
        return Math.max(0, Math.floor(baseMs * factor));
    },

    // Track relays that have rate-limited us recently. We back off new
    // REQs to those relays for a short window so we stop antagonizing them.
    _noteRateLimit(relayUrl) {
        if (!this._rateLimitedRelays) this._rateLimitedRelays = new Map();
        const now = Date.now();
        const key = relayUrl || 'relay-pool';
        const prev = this._rateLimitedRelays.get(key) || { count: 0, until: 0 };
        prev.count++;
        // Back off 10s for first hit, doubling up to 5 min
        const backoff = Math.min(10000 * Math.pow(2, prev.count - 1), 300000);
        prev.until = now + backoff;
        this._rateLimitedRelays.set(key, prev);
        // Aggressively close all non-essential backfill subs to clear the queue
        if (this._backfillSubs) {
            for (const [, entry] of this._backfillSubs) {
                try { entry.close(); } catch (_) { }
            }
        }
        // Decay the count over time so a one-off doesn't punish forever
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

    // Count error responses per relay. If a relay sends 5+ errors within
    // 60s (rate-limit, malformed-filter, etc.), drop it for the session.
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
            this._permanentlyBlacklistRelay(relayUrl, `repeated errors: ${reason}`);
        }
    },

    // Add a relay to the permanent (session-long) blacklist and disconnect it.
    // Subsequent reconnect attempts skip it; in pool mode we also send a
    // RELAYS update so the worker drops the upstream connection.
    _permanentlyBlacklistRelay(relayUrl, reason) {
        if (!relayUrl || relayUrl === 'relay-pool') return;
        if (relayUrl === this.appRelay) return;
        if (!this._permanentBlacklist) this._permanentBlacklist = new Set();
        if (this._permanentBlacklist.has(relayUrl)) return;
        this._permanentBlacklist.add(relayUrl);

        // Also push into the regular blacklist with a far-future timestamp
        // so existing skip checks (shouldRetryRelay etc.) honor it.
        this.blacklistedRelays.add(relayUrl);
        if (this.blacklistTimestamps) {
            this.blacklistTimestamps.set(relayUrl, Date.now() + (10 * 365 * 24 * 3600 * 1000));
        }

        // Direct mode: close + remove from pool
        const direct = this.relayPool && this.relayPool.get(relayUrl);
        if (direct && direct.ws) {
            try { direct.ws.close(); } catch (_) { }
            this.relayPool.delete(relayUrl);
        }

        // Drop from our active geo sets so we stop trying to reach it
        if (this.currentGeoRelays) this.currentGeoRelays.delete(relayUrl);
        if (this.geoRelayConnections) {
            for (const set of this.geoRelayConnections.values()) set.delete(relayUrl);
        }

        // Pool mode: re-send relay config so workers drop this upstream
        if (this.useRelayProxy && typeof this._poolSendRelayConfig === 'function') {
            this._poolSendRelayConfig();
        }
    },

    // Resolve when EOSE arrives for the given subId (or after timeoutMs).
    // Used to serialize ephemeral-pubkey REQs so they don't burst in parallel.
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

    // Cap concurrent one-shot REQs (profile/LN/etc) so we don't trip
    // per-relay "too many concurrent subscriptions" rate limits.
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

    // bufferedAmount-aware send with optional per-socket queue for critical messages
    _safeWsSend(ws, msg, opts) {
        if (!ws || ws.readyState !== WebSocket.OPEN) return false;
        const threshold = (opts && opts.threshold) || 1048576;
        if (ws.bufferedAmount > threshold) {
            if (opts && opts.critical) this._queueSocketSend(ws, msg);
            return false;
        }
        try { ws.send(msg); return true; }
        catch (_) { return false; }
    },

    _queueSocketSend(ws, msg) {
        if (!ws._sendQueue) ws._sendQueue = [];
        if (ws._sendQueue.length > 256) return;
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

    // Async fan-out: yields between chunks so slow relays don't block faster ones
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

    // Close the persistent typing sub for a channel (if any). Backfill subs
    // self-close on EOSE so they don't need explicit cleanup here.
    closeChannelSubscription(channelKey, opts) {
        if (!channelKey) return;

        const subIds = [];
        if (this._channelTypingSubs && this._channelTypingSubs.has(channelKey)) {
            subIds.push(this._channelTypingSubs.get(channelKey));
            this._channelTypingSubs.delete(channelKey);
        }
        // Legacy: any leftover sub tracked via channelSubscriptions
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

    // Coalesce channel subscription requests over a short window so multiple
    // channels share one batched REQ instead of firing one REQ each.
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
        // If we're being rate-limited, defer the flush to give relays time
        // to clear their concurrent-sub counter. The queue accumulates
        // channels in the meantime so the next flush is a single batch.
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
