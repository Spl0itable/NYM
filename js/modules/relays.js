// relays.js - Relay pool, connection lifecycle, proxy worker, geo-relays, stats, retries
// Methods are attached to NYM.prototype.

Object.assign(NYM.prototype, {

    // Fetch geo relay list from the same remote CSV that bitchat uses.
    // Falls back to the hardcoded list if fetch fails.
    // Returns a promise so connectToGeoRelays can await the fresh data
    // before selecting relays, ensuring we match bitchat's relay set.
    fetchGeoRelays() {
        const url = 'https://raw.githubusercontent.com/permissionlesstech/georelays/refs/heads/main/nostr_relays.csv';
        return fetch(url, { cache: 'no-cache' })
            .then(res => {
                if (!res.ok) throw new Error(`HTTP ${res.status}`);
                return res.text();
            })
            .then(csv => {
                const parsed = [];
                const lines = csv.split('\n');
                for (let i = 0; i < lines.length; i++) {
                    const line = lines[i].trim();
                    if (!line) continue;
                    if (i === 0 && line.toLowerCase().includes('relay url')) continue;
                    const parts = line.split(',');
                    if (parts.length < 3) continue;
                    let host = parts[0].trim()
                        .replace('https://', '').replace('http://', '')
                        .replace('wss://', '').replace('ws://', '')
                        .replace(/\/+$/, '');
                    const lat = parseFloat(parts[1]);
                    const lng = parseFloat(parts[2]);
                    if (!host || isNaN(lat) || isNaN(lng)) continue;
                    parsed.push({ url: `wss://${host}`, lat, lng });
                }
                if (parsed.length > 0) {
                    this.geoRelays = parsed;
                    // Add all CSV relay URLs to the unified relay set
                    for (const r of parsed) {
                        this.allRelayUrls.add(r.url);
                    }
                    // If the relay pool proxy is already connected, update
                    // its config so it connects to the full CSV relay set
                    if (this.useRelayProxy && this._isAnyPoolOpen()) {
                        this._poolSendRelayConfig();
                    }
                }
            })
            .catch((err) => {
                console.warn(`[GeoRelays] CSV fetch failed (${this.geoRelays.length} geo relays):`, err.message);
            });
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

        // Multiplexed pool mode: add geo relays to the pool config
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            const closestRelays = this.getClosestRelaysForGeohash(geohash, this.geoRelayCount);
            if (closestRelays.length > 0) {
                const geoRelayUrls = new Set(closestRelays.map(r => r.url));
                this.geoRelayConnections.set(geohash, geoRelayUrls);
                for (const r of closestRelays) {
                    this.currentGeoRelays.add(r.url);
                }
                this._poolSendRelayConfig();
                this.channelLoadedFromRelays.delete(geohash);
                this.subscribeToChannelTargeted(geohash, 'geohash');
            }
            return;
        }

        // Check if we already have cached geo relays for this geohash
        if (this.geoRelayConnections.has(geohash)) {
            const cachedRelays = this.geoRelayConnections.get(geohash);
            // Verify connections are still alive
            let activeCount = 0;
            for (const url of cachedRelays) {
                const relay = this.relayPool.get(url);
                if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                    activeCount++;
                }
            }
            // If we have at least half of our target connections, don't reconnect
            if (activeCount >= Math.floor(this.geoRelayCount / 2)) {
                return;
            }
        }

        // Find closest relays for this geohash
        const closestRelays = this.getClosestRelaysForGeohash(geohash, this.geoRelayCount);
        if (closestRelays.length === 0) {
            return;
        }

        // Store which relays are for this geohash
        const geoRelayUrls = new Set(closestRelays.map(r => r.url));
        this.geoRelayConnections.set(geohash, geoRelayUrls);

        // Connect to each geo relay with staggered timing
        const connectionPromises = [];
        for (let i = 0; i < closestRelays.length; i++) {
            const relayUrl = closestRelays[i].url;

            // Skip if already connected — but ensure it has the channel subscription
            if (this.relayPool.has(relayUrl)) {
                const existing = this.relayPool.get(relayUrl);
                if (existing.ws && existing.ws.readyState === WebSocket.OPEN) {
                    this.currentGeoRelays.add(relayUrl);
                    this.subscribeRelayToChannel(existing, relayUrl, geohash);
                    continue;
                }
            }

            // Skip if blacklisted or recently failed
            if (this.blacklistedRelays.has(relayUrl) && !this.isBlacklistExpired(relayUrl)) {
                continue;
            }
            if (!this.shouldRetryRelay(relayUrl)) {
                continue;
            }

            // Connect concurrently — only 5 geo relays, no stagger needed
            const connectionPromise = this.connectToRelayWithTimeout(relayUrl, 'relay', 3000).then(() => {
                const relay = this.relayPool.get(relayUrl);
                if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                    this.currentGeoRelays.add(relayUrl);
                    this.subscribeRelayToChannel(relay, relayUrl, geohash);
                    this.updateConnectionStatus();
                }
            });
            connectionPromises.push(connectionPromise);
        }

        // Wait for all connection attempts to complete
        await Promise.all(connectionPromises);

        // Log final geo relay count
        const connectedGeoRelays = Array.from(this.currentGeoRelays).filter(url => {
            const relay = this.relayPool.get(url);
            return relay && relay.ws && relay.ws.readyState === WebSocket.OPEN;
        });

        // Update network stats to reflect newly connected geo relays
        this.updateRelayStatus();

        // Re-subscribe the channel on all geo relays that just connected,
        // since the initial subscription may have fired before they were ready
        if (connectedGeoRelays.length > 0) {
            this.channelLoadedFromRelays.delete(geohash);
            this.loadChannelFromRelays(geohash, 'geohash');
        }

        // Always ensure default relays (first 5 broadcast relays) are connected
        this.ensureDefaultRelaysConnected();
    },

    // Send a channel subscription (REQ) directly to a single relay
    subscribeRelayToChannel(relay, relayUrl, channelKeyOverride) {
        if (!relay || !relay.ws || relay.ws.readyState !== WebSocket.OPEN) return;
        const channelKey = channelKeyOverride || this.currentGeohash || this.currentChannel;
        if (!channelKey) return;

        // Re-use the existing subscription ID so the relay pool treats
        // responses as part of the same logical subscription, or create one.
        let subId = this.channelSubscriptions.get(channelKey);
        if (!subId) {
            subId = Math.random().toString(36).substring(2);
            this.channelSubscriptions.set(channelKey, subId);
        }

        const since24h = Math.floor(Date.now() / 1000) - 86400;
        const filters = [
            {
                kinds: [20000],
                '#g': [channelKey],
                since: since24h,
                limit: this.channelMessageLimit
            },
            {
                kinds: [30078],
                '#t': ['nym-poll', 'nym-poll-vote'],
                '#g': [channelKey],
                since: since24h,
                limit: 50
            },
            {
                kinds: [7],
                '#k': ['20000'],
                since: since24h,
                limit: this.channelMessageLimit
            },
            {
                kinds: [5],
                since: since24h,
                limit: 50
            }
        ];

        if (!relay.subscriptions) {
            relay.subscriptions = new Set();
        }
        relay.subscriptions.add(subId);
        relay.ws.send(JSON.stringify(['REQ', subId, ...filters]));
    },

    // Ensure the first 5 broadcast relays are always connected regardless of channel
    async ensureDefaultRelaysConnected() {
        // Pool mode: proxy manages all connections
        if (this.useRelayProxy) return;

        // Check defaults AND DM relays so PMs/groups stay reachable
        const essentialRelays = [...new Set([...this.defaultRelays, ...(this.bitchatDMRelays || [])])];
        for (const relayUrl of essentialRelays) {
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
                // Direct mode: disconnect all relays except the 5 defaults,
                // active geo relays for the current channel, and write-only relays
                const keepRelays = new Set(this.defaultRelays);
                for (const url of this.currentGeoRelays) {
                    keepRelays.add(url);
                }
                keepRelays.add('wss://sendit.nosflare.com');
                // Add DM relays so PMs still work
                if (this.bitchatDMRelays) {
                    for (const url of this.bitchatDMRelays) {
                        keepRelays.add(url);
                    }
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
                                    this.subscribeRelayToChannel(r, relayUrl);
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
        for (const url of this.defaultRelays) keepRelays.add(url);
        if (this.bitchatDMRelays) {
            for (const url of this.bitchatDMRelays) keepRelays.add(url);
        }
        keepRelays.add('wss://sendit.nosflare.com');

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
        const writeOnlyRelays = [];

        this.relayPool.forEach((relay, url) => {
            if (relay.type === 'write') {
                writeOnlyRelays.push(url);
            } else {
                connectedRelays.push(url);
            }
        });

        let html = '';

        if (connectedRelays.length > 0 || writeOnlyRelays.length > 0) {
            html += '<div style="margin-bottom: 10px;"><strong style="color: var(--primary);">Connected Relays:</strong><br/>';
            connectedRelays.slice(0, 20).forEach(url => {
                html += `<div style="font-size: 11px; margin-left: 10px;">• ${this.escapeHtml(url)}</div>`;
            });
            if (connectedRelays.length > 20) {
                html += `<div style="font-size: 11px; margin-left: 10px; color: var(--text-dim);">... and ${connectedRelays.length - 20} more</div>`;
            }
            writeOnlyRelays.forEach(url => {
                html += `<div style="font-size: 11px; margin-left: 10px;">• ${this.escapeHtml(url)} (write-only)</div>`;
            });
            html += '</div>';
        }

        html += `<div style="margin-top: 10px; font-size: 12px; color: var(--text-bright);">Total Connected: ${this.relayPool.size} relays</div>`;

        listEl.innerHTML = html || '<div style="color: var(--text-dim); font-size: 12px;">No relays connected</div>';
    },

    setupVisibilityMonitoring() {
        // Track when app becomes visible/hidden
        document.addEventListener('visibilitychange', () => {
            if (document.visibilityState === 'visible') {
                // Resume globe animation if it was paused by backgrounding
                if (this._globeWasActive && this.globe && this.globe.animate) {
                    this._globeWasActive = false;
                    this.globeAnimationActive = true;
                    requestAnimationFrame(this.globe.animate);
                }

                const delay = this.isFlutterWebView ? 200 : 500;
                setTimeout(() => {
                    // Clear failed relays and blacklist to allow immediate reconnection
                    this.clearRelayBlocksForReconnection();

                    this.checkConnectionHealth();

                    if (!this.connected && navigator.onLine) {
                        this.attemptReconnection();
                    }

                    // Pool mode: only resubscribe if sockets are healthy;
                    // if sockets were closed by checkConnectionHealth, the onclose
                    // handlers will schedule reconnection + resubscription automatically.
                    if (this.useRelayProxy) {
                        if (this._isAnyPoolOpen()) {
                            this._poolSubscribe();
                        }
                        // If no pool sockets are open and nothing is reconnecting, kick it off
                        if (!this._isAnyPoolOpen() && !this._poolReconnecting && navigator.onLine) {
                            this._schedulePoolReconnect();
                        }
                    } else {
                        // Always refresh subscriptions when we come back to foreground
                        setTimeout(() => this.resubscribeAllRelays(), 250);
                    }
                }, delay);
            } else {
                // Record when app went to background so we can measure staleness
                this._backgroundedAt = Date.now();

                // Pause globe animation when backgrounded to save GPU/CPU
                if (this.globeAnimationActive) {
                    this._globeWasActive = true;
                    this.globeAnimationActive = false;
                }

                // Stop monitoring when app goes to background
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
                    }
                    if (!this._isAnyPoolOpen() && !this._poolReconnecting && navigator.onLine) {
                        this._schedulePoolReconnect();
                    }
                } else {
                    // Always refresh subscriptions when window regains focus
                    setTimeout(() => this.resubscribeAllRelays(), 250);
                }
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
                        }
                        if (!this._isAnyPoolOpen() && !this._poolReconnecting && navigator.onLine) {
                            this._schedulePoolReconnect();
                        }
                    } else {
                        // Always refresh subscriptions when app resumes
                        setTimeout(() => this.resubscribeAllRelays(), 250);
                    }
                }, 200);
            });
        }
    },

    // Clear relay blocks (failed list, blacklist, reconnecting set) to allow fresh reconnection attempts
    clearRelayBlocksForReconnection() {
        // Clear failed relays so they can be retried immediately
        this.failedRelays.clear();

        // Clear blacklist and timestamps
        this.blacklistedRelays.clear();
        this.blacklistTimestamps.clear();

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

        // Pool mode: check individual poolSockets for staleness
        // (browser throttles timers when backgrounded so keepalive may not fire)
        if (this.useRelayProxy) {
            const now = Date.now();
            const STALE_MS = 120000; // >3 missed POOL:PING cycles (30s each) + margin
            let closedAny = false;
            for (const p of this.poolSockets) {
                if (p.ws && p.ws.readyState === WebSocket.OPEN) {
                    const silenceMs = now - (p.lastMessage || 0);
                    if (silenceMs > STALE_MS) {
                        // Connection is likely a zombie — close to trigger reconnect
                        p.ws.close();
                        closedAny = true;
                    }
                }
            }
            if (closedAny) {
                // onclose handlers will fire and trigger reconnection;
                // force status update so UI reflects disconnected state immediately
                this._mergePoolStatus();
                this._syncLegacyPoolSocket();
            }
        }

        // First, check if we think we're connected
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

            // If we're missing default or DM relays, try to restore them
            const essentialRelays = [...new Set([...this.defaultRelays, ...(this.bitchatDMRelays || [])])];
            const missingEssential = essentialRelays.filter(url => !this.relayPool.has(url));
            if (missingEssential.length > 0) {
                this.reconnectToBroadcastRelays();
            }

            // Retry any disconnected relays from allRelayUrls (skipped in low data mode)
            if (!this.settings || !this.settings.lowDataMode) {
                const missingRelays = [...this.allRelayUrls].filter(url =>
                    !this.relayPool.has(url) &&
                    url !== 'wss://sendit.nosflare.com'
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

        // Always reconnect defaults + DM relays so PMs/groups stay reachable
        const relaysToConnect = [...new Set([...this.defaultRelays, ...(this.bitchatDMRelays || [])])];
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

            // Use multiplexed relay pool when running on Cloudflare (or remote proxy)
            if (this.useRelayProxy) {
                // Wait for geo relay CSV so the pool connects to all relays right away
                try {
                    await Promise.race([
                        this._geoRelaysReady || Promise.resolve(),
                        new Promise(r => setTimeout(r, 3000))
                    ]);
                } catch (_) { }

                let poolConnected = false;
                const maxRetries = 2;
                for (let attempt = 0; attempt < maxRetries; attempt++) {
                    try {
                        if (attempt > 0) {
                            const delay = Math.min(2000 * Math.pow(2, attempt - 1), 8000);
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
                                this._schedulePoolReconnectInBackground();
                            }
                            // Fall through to direct relay connection code below
                        }
                    }
                }

                if (this.useRelayProxy && poolConnected) {
                    this.connected = true;
                    this._startPoolKeepalive();
                    document.getElementById('messageInput').disabled = false;
                    document.getElementById('sendBtn').disabled = false;
                    this.updateConnectionStatus();

                    // Subscribe to events via the pool
                    this._poolSubscribe();

                    // Set initial channel label
                    if (!this.settings.groupChatPMOnlyMode && this.currentChannel) {
                        const channelLabel = `#${this.escapeHtml(this.currentChannel)}`;
                        const channelType = this.isValidGeohash(this.currentChannel) ? '(Geohash)' : '(Ephemeral)';
                        document.getElementById('currentChannel').innerHTML = `${channelLabel} <span style="font-size: 12px; color: var(--text-dim);">${channelType}</span>`;
                    }

                    // Switch to pinned landing channel (or PM-only mode landing)
                    setTimeout(() => {
                        if (window.pendingChannel || window.urlChannelRouted) return;
                        // Don't override if user already navigated (e.g. joined a channel from search, created a group)
                        if (this.navigationHistory.length > 0) return;
                        if (this.settings.groupChatPMOnlyMode) {
                            this.navigateToLatestPMOrGroup();
                        } else {
                            const pinned = this.pinnedLandingChannel || { type: 'geohash', geohash: 'nym' };
                            this.currentChannel = '';
                            this.currentGeohash = '';
                            if (pinned.type === 'geohash' && pinned.geohash) {
                                this.switchChannel(pinned.geohash, pinned.geohash);
                            } else {
                                this.switchChannel('nym', 'nym');
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
                const channelLabel = `#${this.escapeHtml(this.currentChannel)}`;
                const channelType = this.isValidGeohash(this.currentChannel) ? '(Geohash)' : '(Ephemeral)';
                document.getElementById('currentChannel').innerHTML = `${channelLabel} <span style="font-size: 12px; color: var(--text-dim);">${channelType}</span>`;
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
                    const pinned = this.pinnedLandingChannel || { type: 'geohash', geohash: 'nym' };
                    this.currentChannel = '';
                    this.currentGeohash = '';

                    if (pinned.type === 'geohash' && pinned.geohash) {
                        this.switchChannel(pinned.geohash, pinned.geohash);
                    } else {
                        this.switchChannel('nym', 'nym');
                    }
                }
            }, 100);

            // Connect to sendit.nosflare.com for write-only (no subscriptions)
            const senditRelay = 'wss://sendit.nosflare.com';
            if (this.shouldRetryRelay(senditRelay)) {
                this.connectToRelay(senditRelay, 'write').then(() => {
                    this.updateConnectionStatus();
                });
            }

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

            // GEO relays, then DM relays
            if (!this.settings.lowDataMode) {
                (this._geoRelaysReady || Promise.resolve()).then(() => {
                    // Connect GEO relays (second priority after defaults)
                    const geoRelayUrls = (this.geoRelays || []).map(r => r.url || r).filter(Boolean);
                    for (const relayUrl of geoRelayUrls) {
                        if (!this.relayPool.has(relayUrl) && this.shouldRetryRelay(relayUrl)) {
                            this.connectToRelayWithTimeout(relayUrl, 'relay', this.relayTimeout).then(() => {
                                const r = this.relayPool.get(relayUrl);
                                if (r && r.ws && r.ws.readyState === WebSocket.OPEN) {
                                    this.subscribeRelayToChannel(r, relayUrl);
                                    this.updateConnectionStatus();
                                }
                            });
                        }
                    }

                    // Connect bitchatDMRelays (third priority)
                    if (this.bitchatDMRelays) {
                        this.bitchatDMRelays.forEach(relayUrl => {
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
                    }
                });
            } else {
                // In low data mode, connect to DM relays so PMs work
                if (this.bitchatDMRelays) {
                    this.bitchatDMRelays.forEach(relayUrl => {
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
                }
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

    resubscribeAllRelays() {
        // Multiplexed pool mode: re-subscribe through proxy
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            this._poolSubscribe();
            return;
        }

        this.relayPool.forEach((relay, url) => {
            if (relay.type === 'write') return; // write-only
            if (!relay.ws || relay.ws.readyState !== WebSocket.OPEN) return;

            // Close existing subscriptions before resubscribing
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

        // Never send subscriptions to nosflare (write-only)
        if (relay.type === 'write') return;

        // Close all active subscriptions for this relay
        if (relay.subscriptions) {
            relay.subscriptions.forEach(subId => {
                relay.ws.send(JSON.stringify(["CLOSE", subId]));
            });
            relay.subscriptions.clear();
        } else {
            // Initialize subscriptions set if it doesn't exist
            relay.subscriptions = new Set();
        }
    },

    // Determine if a relay URL is a geo or discovered relay (not a default/DM relay)
    _isGeoOrDiscoveredRelay(relayUrl) {
        const defaultSet = new Set(this.defaultRelays || []);
        const dmSet = new Set(this.bitchatDMRelays || []);
        return !defaultSet.has(relayUrl) && !dmSet.has(relayUrl);
    },

    subscribeToSingleRelay(relayUrl) {
        const relay = this.relayPool.get(relayUrl);
        if (!relay || !relay.ws || relay.ws.readyState !== WebSocket.OPEN) return;

        // Never send REQ to nosflare (write-only)
        if (relay.type === 'write') return;

        const ws = relay.ws;
        const since24h = Math.floor(Date.now() / 1000) - 86400;
        const isGeo = this._isGeoOrDiscoveredRelay(relayUrl);

        // Geo/discovered relays only get kind 20000
        if (isGeo) {
            const subId = Math.random().toString(36).substring(2);
            if (!relay.subscriptions) relay.subscriptions = new Set();
            relay.subscriptions.add(subId);
            const filters = this._buildGeoFilters(since24h);
            ws.send(JSON.stringify(["REQ", subId, ...filters]));
            return;
        }

        // Critical (default + DM) relays get the full subscription set
        const subId = Math.random().toString(36).substring(2);

        // Track this subscription
        if (!relay.subscriptions) {
            relay.subscriptions = new Set();
        }
        relay.subscriptions.add(subId);

        const filters = this._buildCriticalFilters(since24h);

        // Send single REQ with all filters
        ws.send(JSON.stringify(["REQ", subId, ...filters]));
    },

    // This is called when a user switches to a channel that hasn't been fully loaded
    subscribeToChannelTargeted(channelKey, channelType) {
        // Skip if already loaded
        if (this.channelLoadedFromRelays.has(channelKey)) {
            return;
        }

        // Mark as loaded to prevent duplicate requests
        this.channelLoadedFromRelays.add(channelKey);

        const subId = Math.random().toString(36).substring(2);
        const since24h = Math.floor(Date.now() / 1000) - 86400; // 24 hours ago
        let filters = [];

        // Subscribe to channel messages (geohash and non-geohash both use the g tag)
        filters = [
            {
                kinds: [20000],
                "#g": [channelKey],
                since: since24h,
                limit: this.channelMessageLimit
            },
            {
                kinds: [30078],
                "#t": ["nym-poll", "nym-poll-vote"],
                "#g": [channelKey],
                since: since24h,
                limit: 50
            },
            {
                kinds: [7],
                "#k": ["20000"],
                since: since24h,
                limit: this.channelMessageLimit
            },
            {
                kinds: [5],
                since: since24h,
                limit: 50
            }
        ];

        if (filters.length === 0) return;

        // Multiplexed pool mode: send REQ through single socket
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            // For geohash channels, use GEO_REQ so geo relays get the
            // subscription first — they have the most relevant data
            if (channelType === 'geohash' && channelKey) {
                const closestRelays = this.getClosestRelaysForGeohash(channelKey);
                if (closestRelays.length > 0) {
                    this._poolSend(["GEO_REQ", closestRelays.map(r => r.url), subId, ...filters]);
                    this.channelSubscriptions.set(channelKey, subId);
                    return;
                }
            }
            this._poolSend(["REQ", subId, ...filters]);
            this.channelSubscriptions.set(channelKey, subId);
            return;
        }

        // Direct mode: send to geo relays first, then all others
        const reqStr = JSON.stringify(["REQ", subId, ...filters]);
        const sentUrls = new Set();

        // Geo relays first for geohash channels
        if (channelType === 'geohash' && channelKey) {
            const closestRelays = this.getClosestRelaysForGeohash(channelKey);
            for (const r of closestRelays) {
                const relay = this.relayPool.get(r.url);
                if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN && relay.type !== 'write') {
                    if (!relay.subscriptions) relay.subscriptions = new Set();
                    relay.subscriptions.add(subId);
                    relay.ws.send(reqStr);
                    sentUrls.add(r.url);
                }
            }
        }

        // Then all other readable relays
        this.relayPool.forEach((relay, url) => {
            if (!sentUrls.has(url) && relay.ws && relay.ws.readyState === WebSocket.OPEN &&
                relay.type !== 'write') {
                if (!relay.subscriptions) relay.subscriptions = new Set();
                relay.subscriptions.add(subId);
                relay.ws.send(reqStr);
            }
        });

        // Store the subscription ID for this channel
        this.channelSubscriptions.set(channelKey, subId);
    },

    // Batch multiple channel subscriptions into fewer REQs for efficiency
    subscribeToChannelBatch(channels) {
        if (!channels || channels.length === 0) return;

        // Only geohash channels
        const geohashChannels = [];
        const since24h = Math.floor(Date.now() / 1000) - 86400;

        channels.forEach(({ key, type }) => {
            // Skip already loaded channels
            if (this.channelLoadedFromRelays.has(key)) return;
            geohashChannels.push(key);
        });

        // Build batched filters
        const filters = [];

        if (geohashChannels.length > 0) {
            filters.push({
                kinds: [20000],
                "#g": geohashChannels,
                since: since24h,
                limit: this.channelMessageLimit * geohashChannels.length
            });
            filters.push({
                kinds: [30078],
                "#t": ["nym-poll", "nym-poll-vote"],
                "#g": geohashChannels,
                since: since24h,
                limit: 50 * geohashChannels.length
            });
            // Mark as loaded
            geohashChannels.forEach(ch => this.channelLoadedFromRelays.add(ch));
        }

        if (filters.length === 0) return;

        const subId = Math.random().toString(36).substring(2);

        // Multiplexed pool mode
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            // Collect geo relays for all channels in the batch
            if (geohashChannels.length > 0) {
                const geoUrls = new Set();
                for (const ch of geohashChannels) {
                    const closest = this.getClosestRelaysForGeohash(ch);
                    for (const r of closest) geoUrls.add(r.url);
                }
                if (geoUrls.size > 0) {
                    this._poolSend(["GEO_REQ", [...geoUrls], subId, ...filters]);
                    return;
                }
            }
            this._poolSend(["REQ", subId, ...filters]);
            return;
        }

        // Direct mode: send to geo relays first, then all others
        const reqStr = JSON.stringify(["REQ", subId, ...filters]);
        const sentUrls = new Set();

        // Geo relays first
        if (geohashChannels.length > 0) {
            for (const ch of geohashChannels) {
                const closest = this.getClosestRelaysForGeohash(ch);
                for (const r of closest) {
                    if (sentUrls.has(r.url)) continue;
                    const relay = this.relayPool.get(r.url);
                    if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN && relay.type !== 'write') {
                        if (!relay.subscriptions) relay.subscriptions = new Set();
                        relay.subscriptions.add(subId);
                        relay.ws.send(reqStr);
                        sentUrls.add(r.url);
                    }
                }
            }
        }

        // Then all other readable relays
        this.relayPool.forEach((relay, url) => {
            if (!sentUrls.has(url) && relay.ws && relay.ws.readyState === WebSocket.OPEN &&
                relay.type !== 'write') {
                if (!relay.subscriptions) relay.subscriptions = new Set();
                relay.subscriptions.add(subId);
                relay.ws.send(reqStr);
            }
        });
    },

    // Load messages for a channel from relays - called when switching channels
    loadChannelFromRelays(channelKey, channelType) {
        // Only load if we haven't already sent a targeted request
        if (this.channelLoadedFromRelays.has(channelKey)) {
            return;
        }

        // Check if we have few messages for this channel (under 50)
        // Storage key uses #prefix for channels with a geohash/g-tag (both geohash and non-geohash)
        const storageKey = `#${channelKey}`;
        const currentMessages = this.messages.get(storageKey) || [];

        // If we have very few messages, send a targeted request
        if (currentMessages.length < 50) {
            this.subscribeToChannelTargeted(channelKey, channelType);
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
            if (host.endsWith('.pages.dev') || host.endsWith('.workers.dev')) return true;
            // Known Cloudflare Pages custom domains for this app
            if (host === 'web.nymchat.app' || host === 'app.nymchat.app' || host === 'nymchat.app') return true;
        } catch {
            // Not in a browser context
        }
        return false;
    },

    // Returns the host to use for API endpoints.
    // When running on Cloudflare, use the current host; otherwise use the production host
    // so that local/PWA instances still route through the relay proxy pool and bot.
    _getApiHost() {
        if (this._isCloudflareHost) return window.location.host;
        if (this._remoteApiFailed) return null;
        return 'web.nymchat.app';
    },

    // Mark the remote API as unavailable and fall back to local/direct connections
    _fallbackToLocal() {
        if (this._isCloudflareHost || this._remoteApiFailed) return;
        this._remoteApiFailed = true;
        this.useRelayProxy = false;
        console.warn('[NYM] Remote API unreachable, falling back to direct connections');
    },

    // Fall back from pool mode to direct relay connections (works on any host including Cloudflare).
    // Unlike _fallbackToLocal, this does NOT mark the remote API as failed — only disables pool mode.
    _fallbackToDirectConnections() {
        if (!this.useRelayProxy) return; // Already in direct mode

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
        this._poolReconnecting = false;
        this._poolReconnectRetries = 0;

        // Disable pool mode so all relay methods use direct connections
        this.useRelayProxy = false;
        console.warn('[NYM] Pool mode disabled, switching to direct relay connections');

        // Connect directly to relays
        this.reconnectToBroadcastRelays();
        if (this.currentGeohash) {
            this.connectToGeoRelays(this.currentGeohash);
        }
    },

    // Try to restore pool mode in the background (used after initial pool failure on Cloudflare).
    // Periodically attempts to reconnect to the pool while direct connections are active.
    _schedulePoolReconnectInBackground() {
        if (this._bgPoolReconnectTimer) return;
        let attempts = 0;

        const tryRestore = () => {
            attempts++;
            if (attempts > 2) {
                // Give up restoring pool mode
                clearTimeout(this._bgPoolReconnectTimer);
                this._bgPoolReconnectTimer = null;
                return;
            }
            // Temporarily re-enable pool mode to attempt connection
            this.useRelayProxy = true;
            this._poolConnecting = false;
            this._poolReconnecting = false;
            this._connectToRelayPool()
                .then(() => {
                    // Pool restored — switch back to pool mode
                    clearTimeout(this._bgPoolReconnectTimer);
                    this._bgPoolReconnectTimer = null;
                    console.log('[NYM] Pool mode restored');
                    this._startPoolKeepalive();
                    this._poolSubscribe();
                    // Close direct relay connections (pool handles them now)
                    this.relayPool.forEach((relay, url) => {
                        try { if (relay.ws) relay.ws.close(); } catch (_) { }
                    });
                    this.relayPool.clear();
                    this.updateConnectionStatus();
                })
                .catch(() => {
                    // Failed — stay in direct mode
                    this.useRelayProxy = false;
                    const delay = Math.min(30000 * Math.pow(2, attempts - 1), 120000);
                    this._bgPoolReconnectTimer = setTimeout(tryRestore, delay);
                });
        };

        // First attempt after 30 seconds
        this._bgPoolReconnectTimer = setTimeout(tryRestore, 30000);
    },

    _getProxiedRelayUrl(relayUrl) {
        if (!this.useRelayProxy) return relayUrl;
        return `wss://${this._getApiHost()}/api/relay?relay=${encodeURIComponent(relayUrl)}`;
    },

    // Multiplexed relay pool (multi-worker WebSocket proxy)
    _getRelayPoolUrl() {
        return `wss://${this._getApiHost()}/api/relay-pool`;
    },

    // Returns true if any pool worker socket is open
    _isAnyPoolOpen() {
        return this.poolSockets.some(p => p.ws && p.ws.readyState === WebSocket.OPEN);
    },

    // Shard relays into role-based worker groups, splitting large groups into chunks
    _shardRelaysByRole(allRelays, geoRelayUrls, dmRelays) {
        const blocked = new Set(['wss://relay.nosflare.com', 'wss://relay.nostraddress.com', 'wss://nostr-server-production.up.railway.app']);
        const writeOnly = new Set(['wss://sendit.nosflare.com']);
        const isValid = (url) => !blocked.has(url) && !writeOnly.has(url);

        // Categorize relays by role
        const geoSet = new Set(geoRelayUrls || []);

        // Critical = defaults + DM relays (deduplicated)
        const critical = [...new Set([...this.defaultRelays, ...(dmRelays || this.bitchatDMRelays || [])])]
            .filter(isValid);

        // Geo = CSV relays not already in critical
        const criticalSet = new Set(critical);
        const geo = [...geoSet].filter(url => isValid(url) && !criticalSet.has(url));

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
                dmRelays: i === 0 ? (dmRelays || this.bitchatDMRelays || []) : []
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

        // Write-only relays go to the first critical shard
        if (shards.length > 0) {
            shards[0].writeOnly = [...writeOnly];
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

    // Reconnect a single failed pool worker shard
    _reconnectPoolShard(shard) {
        if (!this.useRelayProxy) return;
        const shardId = shard.id;

        // Prevent concurrent reconnect attempts for the same shard
        if (!this._shardReconnecting) this._shardReconnecting = new Set();
        if (this._shardReconnecting.has(shardId)) return;
        this._shardReconnecting.add(shardId);

        const attempt = (retries) => {
            // Check if this shard already reconnected
            const existing = this.poolSockets.find(p => p.id === shardId);
            if (existing && existing.ws && existing.ws.readyState === WebSocket.OPEN) {
                this._shardReconnecting.delete(shardId);
                return;
            }
            if (!navigator.onLine) {
                this._shardReconnecting.delete(shardId);
                return;
            }

            const delay = Math.min(3000 * Math.pow(2, retries), 30000);
            setTimeout(() => {
                const stillDown = this.poolSockets.find(p => p.id === shardId);
                if (stillDown && stillDown.ws && stillDown.ws.readyState === WebSocket.OPEN) {
                    this._shardReconnecting.delete(shardId);
                    return;
                }

                this._connectSinglePoolWorker(shard)
                    .then(() => {
                        this._shardReconnecting.delete(shardId);
                        this._startPoolKeepalive();
                        this._poolSubscribeOnWorker(shard.id);
                        // Re-send channel-targeted subscriptions to the reconnected shard
                        this._resubscribeChannels();
                    })
                    .catch(() => {
                        if (retries < 1) {
                            attempt(retries + 1);
                        } else {
                            this._shardReconnecting.delete(shardId);
                        }
                    });
            }, delay);
        };

        attempt(0);
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
            this.bitchatDMRelays
        );

        // Close any existing pool sockets (mark as intentional to prevent reconnect loops)
        const oldSockets = this.poolSockets;
        this.poolSockets = [];
        this.poolSocket = null;
        for (const p of oldSockets) {
            p._closing = true;
            try { if (p.ws) p.ws.close(); } catch (_) { }
        }

        // Connect all shards in parallel, resolve when at least one opens
        const workerPromises = shards.map(shard => this._connectSinglePoolWorker(shard));

        return new Promise((resolve, reject) => {
            let resolved = false;
            let failures = 0;

            for (const p of workerPromises) {
                p.then(() => {
                    if (!resolved) {
                        resolved = true;
                        this._poolConnecting = false;
                        this.poolReady = true;
                        this.connected = true;
                        // Set legacy poolSocket to first open socket for external compat
                        this._syncLegacyPoolSocket();
                        resolve();
                    }
                }).catch(() => {
                    failures++;
                    if (failures === workerPromises.length && !resolved) {
                        this._poolConnecting = false;
                        reject(new Error('All relay pool workers failed to connect'));
                    }
                });
            }
        });
    },

    // Connect a single pool worker for a shard of relays
    _connectSinglePoolWorker(shard) {
        return new Promise((resolve, reject) => {
            const url = this._getRelayPoolUrl();
            const ws = new WebSocket(url);

            const poolEntry = {
                id: shard.id,
                ws: ws,
                role: shard.role,
                relays: shard.relays,
                dmRelays: shard.dmRelays || [],
                writeOnly: shard.writeOnly || [],
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
                    ws.close();
                    reject(new Error(`Pool worker ${shard.id} connection timeout`));
                }
            }, 5000);

            ws.onopen = () => {
                clearTimeout(timeout);
                wasOpen = true;

                // Send RELAYS config for this shard
                ws.send(JSON.stringify(['RELAYS', {
                    relays: shard.relays,
                    writeOnly: shard.writeOnly || [],
                    dmRelays: shard.dmRelays || []
                }]));

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

                    if (msgType === 'POOL:STATUS') {
                        const status = msg[1];
                        poolEntry.connectedRelays = status.connected || [];

                        // Update per-relay latency from this worker
                        if (status.latency) {
                            for (const [url, ms] of Object.entries(status.latency)) {
                                this.relayStats.latencyPerRelay.set(url, ms);
                            }
                        }

                        // Update per-relay event counts from this worker
                        if (status.events) {
                            for (const [url, count] of Object.entries(status.events)) {
                                this.relayStats.eventsPerRelay.set(url, count);
                            }
                        }

                        // Merge connected relays from ALL workers
                        this._mergePoolStatus();
                    } else if (msgType === 'EVENT') {
                        this.relayStats.totalEvents++;
                        this.relayStats.eventsThisSecond++;
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

                // Clear this worker's connected relays and re-merge
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
        const allConnected = [];
        for (const p of this.poolSockets) {
            if (p.connectedRelays) {
                allConnected.push(...p.connectedRelays);
            }
        }
        this.poolConnectedRelays = [...new Set(allConnected)];

        // Sync relayPool map for UI status tracking
        this.relayPool.clear();
        for (const url of this.poolConnectedRelays) {
            const relayType = url === 'wss://sendit.nosflare.com' ? 'write' : 'relay';
            this.relayPool.set(url, {
                ws: this.poolSocket,
                type: relayType,
                status: 'connected',
                connectedAt: Date.now()
            });
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

    // Send data to ALL open pool worker sockets
    _poolSend(data) {
        const msg = typeof data === 'string' ? data : JSON.stringify(data);
        for (const p of this.poolSockets) {
            if (p.ws && p.ws.readyState === WebSocket.OPEN) {
                try { p.ws.send(msg); } catch (_) { }
            }
        }
    },

    // Send data only to pool workers matching a specific role
    _poolSendToRole(role, data) {
        const msg = typeof data === 'string' ? data : JSON.stringify(data);
        for (const p of this.poolSockets) {
            if (p.role === role && p.ws && p.ws.readyState === WebSocket.OPEN) {
                try { p.ws.send(msg); } catch (_) { }
            }
        }
    },

    // Subscribe on a specific worker (by shard id) after reconnection
    _poolSubscribeOnWorker(shardId) {
        const p = this.poolSockets.find(w => w.id === shardId);
        if (!p || !p.ws || p.ws.readyState !== WebSocket.OPEN) return;

        const since24h = Math.floor(Date.now() / 1000) - 86400;

        // Geo/discovered shards only get kind 20000
        const isGeoOrDiscovered = p.role === 'geo' || p.role === 'discovered';
        const filters = isGeoOrDiscovered
            ? this._buildGeoFilters(since24h)
            : this._buildCriticalFilters(since24h);

        const subId = Math.random().toString(36).substring(2);

        const msg = JSON.stringify(["REQ", subId, ...filters]);
        try { p.ws.send(msg); } catch (_) { }

        // Also subscribe to ephemeral pubkeys on critical shards
        if (!isGeoOrDiscovered) {
            this._refreshEphemeralSubscriptions();
        }
    },

    // Build geo-only filters (kind 20000) for geo/discovered relay shards
    _buildGeoFilters(since24h) {
        const filters = [];
        if (!this.settings.groupChatPMOnlyMode) {
            filters.push({ kinds: [20000], since: since24h, limit: 100 });
        }
        return filters;
    },

    // Build full subscription filters for critical (default + DM) relay shards
    _buildCriticalFilters(since24h) {
        const filters = [];

        // Skip geohash channel subscriptions in group chat & PM only mode
        if (!this.settings.groupChatPMOnlyMode) {
            filters.push({ kinds: [20000], since: since24h, limit: 100 });
            filters.push({ kinds: [30078], "#t": ["nym-poll", "nym-poll-vote"], since: since24h, limit: 100 });
            filters.push({ kinds: [7], "#k": ["20000"], since: since24h, limit: 100 });
            filters.push({ kinds: [5], "#k": ["20000", "1059"], since: since24h, limit: 100 });
        }

        filters.push({ kinds: [30078], "#t": ["nym-presence"], limit: 100 });
        filters.push({ kinds: [7], "#k": ["1059"], limit: 100 });
        filters.push({ kinds: [30078], "#d": ["nym-shop-active"], limit: 100 });

        // Zap receipts: scope to visible message event IDs if available
        const zapFilter = this._buildZapReceiptFilter();
        if (zapFilter) filters.push(zapFilter);

        if (this.pubkey) {
            // Gift wraps to our real pubkey (1:1 DMs, bootstrapping, resyncs)
            filters.push(
                { kinds: [1059], "#p": [this.pubkey], limit: 500 },
                { kinds: [7], "#p": [this.pubkey], "#k": ["20000"], limit: 100 },
                { kinds: [30078], authors: [this.pubkey], "#d": ["nym-shop-purchases", "nym-shop-active"], limit: 100 },
                { kinds: [30078], "#p": [this.pubkey], limit: 50 },
                { kinds: [25051], "#p": [this.pubkey], since: Math.floor(Date.now() / 1000) - 120, limit: 50 },
                { kinds: [25052], since: Math.floor(Date.now() / 1000) - 86400, limit: 100 }
            );
            // Ephemeral pubkey subscriptions are sent as independent REQs
        }

        return filters;
    },

    // Collect event IDs from all currently stored channel messages (max 100 per channel)
    _collectVisibleEventIds() {
        this._zapReceiptEventIds.clear();
        this.messages.forEach((msgs) => {
            for (const msg of msgs) {
                if (msg.id) this._zapReceiptEventIds.add(msg.id);
            }
        });
        // Also include PM message IDs if any
        if (this.pmMessages) {
            this.pmMessages.forEach((msgs) => {
                for (const msg of msgs) {
                    if (msg.id) this._zapReceiptEventIds.add(msg.id);
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

        // Geo + discovered shards: only kind 20000
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

    // History fetch for a set of ephemeral pubkeys
    _recoverEphemeralHistory(ephPks) {
        if (!Array.isArray(ephPks) || ephPks.length === 0) return;
        const mkSubId = () => Math.random().toString(36).substring(2);
        const since = this._isFreshDevice
            ? 0
            : (this.lastPMSyncTime > 0 ? Math.max(0, this.lastPMSyncTime - 300) : 0);
        const buildFilter = (pk) => {
            const f = { kinds: [1059], '#p': [pk], limit: 500 };
            if (since > 0) f.since = since;
            return f;
        };

        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            for (const pk of ephPks) {
                this._poolSendToRole('critical', ['REQ', mkSubId(), buildFilter(pk)]);
            }
            return;
        }
        const reqs = ephPks.map(pk => JSON.stringify(['REQ', mkSubId(), buildFilter(pk)]));
        this.relayPool.forEach(relay => {
            if (relay.ws && relay.ws.readyState === WebSocket.OPEN && relay.type !== 'write') {
                for (const req of reqs) {
                    try { relay.ws.send(req); } catch (_) { }
                }
            }
        });
    },

    // Send independent REQ subscriptions for each ephemeral pubkey
    _refreshEphemeralSubscriptions() {
        // Close previous ephemeral subscriptions
        for (const oldSubId of this._ephemeralSubIds) {
            if (this.useRelayProxy && this._isAnyPoolOpen()) {
                this._poolSend(['CLOSE', oldSubId]);
            } else {
                const closeMsg = JSON.stringify(['CLOSE', oldSubId]);
                this.relayPool.forEach(relay => {
                    if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                        try { relay.ws.send(closeMsg); } catch (_) { }
                    }
                });
            }
        }
        this._ephemeralSubIds = [];

        const ephPks = this._getAllSelfEphemeralPubkeys();
        if (!ephPks.length) return;

        // Always go back a full 7 days to catch messages sent to this ephemeral
        // key while the device was offline or before ephemeral key sync occurred.
        const since = Math.floor(Date.now() / 1000) - 604800;

        for (const ephPk of ephPks) {
            const subId = Math.random().toString(36).substring(2);
            this._ephemeralSubIds.push(subId);
            const filter = { kinds: [1059], "#p": [ephPk], since, limit: 200 };

            if (this.useRelayProxy && this._isAnyPoolOpen()) {
                this._poolSend(['REQ', subId, filter]);
            } else {
                const msg = JSON.stringify(['REQ', subId, filter]);
                this.relayPool.forEach((relay, url) => {
                    if (relay.ws && relay.ws.readyState === WebSocket.OPEN && relay.type !== 'write') {
                        try { relay.ws.send(msg); } catch (_) { }
                    }
                });
            }
        }
    },

    // Re-subscribe to active channel subscriptions after a relay reconnection.
    // Clears stale tracking state so subscribeToChannelTargeted() will re-send REQs.
    _resubscribeChannels() {
        // Clear stale channel tracking — old subscription IDs are invalid after reconnect
        this.channelLoadedFromRelays.clear();
        this.channelSubscriptions.clear();

        // Re-subscribe to current channel immediately
        if (this.currentChannel) {
            this.subscribeToChannelTargeted(this.currentChannel, 'geohash');
        }

        // Re-load joined channels and common geohashes with a small delay
        // to avoid overwhelming relays right after reconnection
        setTimeout(() => {
            this.loadJoinedChannelsFromRelays();
        }, 1000);
    },

    // Re-shard and update relay config across all workers.
    // Called when geo relays change.
    _poolSendRelayConfig() {
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
            this.bitchatDMRelays
        );

        // Determine which shards are new vs existing
        const existingIds = new Set(this.poolSockets.map(p => p.id));
        const newShardIds = new Set(shards.map(s => s.id));

        // Update existing workers with new relay configs
        for (const shard of shards) {
            const existing = this.poolSockets.find(p => p.id === shard.id);
            if (existing && existing.ws && existing.ws.readyState === WebSocket.OPEN) {
                // Update relay list for this worker
                existing.relays = shard.relays;
                existing.dmRelays = shard.dmRelays || [];
                existing.writeOnly = shard.writeOnly || [];
                existing.ws.send(JSON.stringify(['RELAYS', {
                    relays: shard.relays,
                    writeOnly: shard.writeOnly || [],
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

        // Block known-bad relays entirely - never connect
        if (relayUrl === 'wss://relay.nosflare.com' || relayUrl === 'wss://relay.nostraddress.com' || relayUrl === 'wss://nostr-server-production.up.railway.app') {
            return; // Silently skip blocked relays
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
                        if (Array.isArray(msg) && msg[0] === 'EVENT') {
                            this.relayStats.totalEvents++;
                            this.relayStats.eventsThisSecond++;
                            const prev = this.relayStats.eventsPerRelay.get(relayUrl) || 0;
                            this.relayStats.eventsPerRelay.set(relayUrl, prev + 1);
                        }
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
                        const attemptReconnect = (attempt = 0) => {
                            const maxAttempts = 10;
                            // Faster initial delay for previously connected relays (1s vs 5s)
                            const baseDelay = wasConnected ? 1000 : 5000;
                            const maxDelay = wasConnected ? 30000 : 60000;

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
                                        // Re-subscribe after reconnection (except write-only relays)
                                        if (type !== 'write') {
                                            this.subscribeToSingleRelay(relayUrl);
                                        }
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
                relay !== 'wss://sendit.nosflare.com' &&
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
                        this.subscribeRelayToChannel(r, relayUrl);
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
        const host = this._getApiHost();
        if (!host) return null;
        return `https://${host}/api/proxy`;
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
            // For EVENT messages, send to broadcast relays and nosflare
            this.broadcastEvent(message);
        } else if (Array.isArray(message) && message[0] === 'REQ') {
            // For REQ messages, send to all relays EXCEPT sendit.nosflare.com
            this.sendRequestToAllRelaysExceptNosflare(message);
        } else {
            // For other messages (CLOSE, etc.), send to all relays
            this.relayPool.forEach((relay, url) => {
                if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                    relay.ws.send(msg);
                }
            });
        }
    },

    // Send DM events (kind 1059) with priority to bitchat's hardcoded relays
    sendDMToRelays(message) {
        // Multiplexed pool mode: proxy handles DM relay prioritization
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            const eventObj = Array.isArray(message) && message[0] === 'EVENT' ? message[1] : message;
            this._poolSend(['DM_EVENT', eventObj]);
            return this.poolConnectedRelays.length;
        }

        const msg = JSON.stringify(message);
        const sent = new Set();

        // Priority: always send to bitchat's DM relays first
        for (const url of this.bitchatDMRelays) {
            const relay = this.relayPool.get(url);
            if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                relay.ws.send(msg);
                sent.add(url);
            }
        }

        // Then fan out to all other connected relays for maximum propagation
        this.relayPool.forEach((relay, url) => {
            if (!sent.has(url) && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                relay.ws.send(msg);
            }
        });

        return sent.size;
    },

    sendRequestToAllRelaysExceptNosflare(message) {
        // Multiplexed pool mode: proxy already excludes write-only relays from REQ
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            this._poolSend(message);
            return;
        }

        const msg = JSON.stringify(message);

        // Send REQ to all connected relays EXCEPT nosflare (write-only)
        this.relayPool.forEach((relay, url) => {
            if (relay.ws && relay.ws.readyState === WebSocket.OPEN && relay.type !== 'write') {
                relay.ws.send(msg);
            }
        });
    },

    sendRequestToFewRelays(message, maxRelays = 5) {
        // Multiplexed pool mode: route to critical shards only (profiles don't need geo/discovered)
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            this._poolSendToRole('critical', message);
            return;
        }

        const msg = JSON.stringify(message);
        let sent = 0;

        // Prefer broadcast relays (more likely to have profiles)
        for (const url of this.defaultRelays) {
            if (sent >= maxRelays) break;
            const relay = this.relayPool.get(url);
            if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN && relay.type !== 'write') {
                relay.ws.send(msg);
                sent++;
            }
        }

        // Fill from pool if needed
        if (sent < maxRelays) {
            for (const [url, relay] of this.relayPool) {
                if (sent >= maxRelays) break;
                if (this.defaultRelays.includes(url)) continue; // already sent
                if (relay.ws && relay.ws.readyState === WebSocket.OPEN && relay.type !== 'write') {
                    relay.ws.send(msg);
                    sent++;
                }
            }
        }
    },

    broadcastEvent(message) {
        // Multiplexed pool mode: proxy handles fan-out to all relays
        if (this.useRelayProxy && this._isAnyPoolOpen()) {
            // For geohash channel events, use GEO_EVENT so the proxy
            // sends to geo relays first (same priority as DM_EVENT).
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
                    // Send GEO_EVENT to geo workers, plain EVENT to the rest
                    const geoMsg = ['GEO_EVENT', evt, closestRelays.map(r => r.url)];
                    const plainMsg = message;
                    for (const p of this.poolSockets) {
                        if (p.ws && p.ws.readyState === WebSocket.OPEN) {
                            try {
                                p.ws.send(JSON.stringify(p.role === 'geo' ? geoMsg : plainMsg));
                            } catch (_) { }
                        }
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
        const wideFanout = evt && (evt.kind === 0 || evt.kind === 5 || evt.kind === 7 || evt.kind === 20000 || evt.kind === 9734 || evt.kind === 9735 || evt.kind === 1059 || evt.kind === 25051 || evt.kind === 25052 || is30078Fanout);

        if (wideFanout) {
            const sent = new Set();
            const geohashTag = evt && evt.tags && evt.tags.find(t => t[0] === 'g');
            if (geohashTag && geohashTag[1]) {
                const closestRelays = this.getClosestRelaysForGeohash(geohashTag[1]);
                for (const r of closestRelays) {
                    const relay = this.relayPool.get(r.url);
                    if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                        relay.ws.send(msg);
                        sent.add(r.url);
                    }
                }
            }

            // Then send to every other connected relay for propagation
            this.relayPool.forEach((relay, url) => {
                if (!sent.has(url) && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                    relay.ws.send(msg);
                }
            });
        } else {
            // Broadcast relays + nosflare
            this.defaultRelays.forEach(relayUrl => {
                const relay = this.relayPool.get(relayUrl);
                if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                    relay.ws.send(msg);
                }
            });

            // Also send to nosflare if connected, to ensure a widely reachable write endpoint
            const nosflare = this.relayPool.get('wss://sendit.nosflare.com');
            if (nosflare && nosflare.ws && nosflare.ws.readyState === WebSocket.OPEN) {
                nosflare.ws.send(msg);
            }
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

        // Get all relays except nosflare
        const readableRelays = Array.from(this.relayPool.entries())
            .filter(([url, relay]) => relay.type !== 'write' && relay.ws && relay.ws.readyState === WebSocket.OPEN);

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

        const channelsToLoad = [];

        // Add user-joined channels
        this.userJoinedChannels.forEach(channelKey => {
            channelsToLoad.push({
                key: channelKey,
                type: 'geohash'
            });
        });

        // Add common geohashes
        this.commonGeohashes.forEach(geohash => {
            if (!this.channelLoadedFromRelays.has(geohash)) {
                channelsToLoad.push({ key: geohash, type: 'geohash' });
            }
        });

        // Also load current channel if not loaded
        if (this.currentChannel && !this.channelLoadedFromRelays.has(this.currentChannel)) {
            channelsToLoad.push({
                key: this.currentChannel,
                type: 'geohash'
            });
        }

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
                const [subscriptionId, event] = data;

                // Deduplicate events by ID
                if (event && event.id) {
                    if (this.eventDeduplication.has(event.id)) {
                        // We've already processed this event
                        return;
                    }

                    // Mark event as seen
                    this.eventDeduplication.set(event.id, true);

                    // Clean up old events periodically (keep last 10000)
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
            case 'OK':
                // Event was accepted
                break;
            case 'EOSE':
                // End of stored events
                break;
            case 'NOTICE':
                const notice = data[0];
                break;
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
            // Multiplexed pool mode: use pool-reported count across all workers
            if (this.useRelayProxy && this._isAnyPoolOpen()) {
                const count = this.poolConnectedRelays.length;
                if (count > 0) {
                    statusEl.textContent = `Connected (${count} relays)`;
                    dot.style.background = 'var(--primary)';
                    this.connected = true;
                } else {
                    statusEl.textContent = 'Connecting...';
                    dot.style.background = 'var(--warning)';
                }
                return;
            }

            // Check actual WebSocket connection states, not just pool size
            let actuallyConnected = 0;

            this.relayPool.forEach((relay, url) => {
                if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                    actuallyConnected++;
                } else {
                    // Clean up dead connections from pool
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

});
