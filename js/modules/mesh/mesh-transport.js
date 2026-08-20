// mesh-transport.js - Web Bluetooth transport for the mesh.

(function () {
    const G = (typeof self !== 'undefined' ? self : window);
    const P = () => G.NymMeshProtocol;

    function isSupported() {
        return typeof navigator !== 'undefined' &&
            !!navigator.bluetooth &&
            typeof navigator.bluetooth.requestDevice === 'function';
    }

    class WebBluetoothTransport {
        constructor(opts) {
            opts = opts || {};
            this.onFrame = opts.onFrame || (() => { });
            this.onLinkChange = opts.onLinkChange || (() => { });
            this.log = opts.log || (() => { });
            this.links = new Map();
            this.watched = new Set();
            this.started = false;
            this._retryAt = new Map();
            this._failStreak = new Map();
        }

        get linkCount() {
            let n = 0;
            for (const l of this.links.values()) if (l.characteristic) n++;
            return n;
        }

        get linkList() {
            return [...this.links.values()].map(l => ({
                id: l.id,
                name: l.device.name || l.id.slice(0, 8),
                connected: !!l.characteristic,
            }));
        }

        async start() {
            if (this.started) return;
            this.started = true;
            await this.reconnectKnown();
        }

        async stop() {
            this.started = false;
            for (const link of this.links.values()) {
                try { if (link.device.gatt && link.device.gatt.connected) link.device.gatt.disconnect(); } catch (_) { }
            }
            this.links.clear();
            this.onLinkChange();
        }

        // Devices the user already granted. Chrome exposes these without a
        // prompt, so a reload does not make the user re-pick every peer.
        async reconnectKnown() {
            if (!navigator.bluetooth.getDevices) return;
            let devices = [];
            try { devices = await navigator.bluetooth.getDevices(); } catch (_) { return; }
            for (const device of devices) {
                this._track(device);
                this._watch(device);
                this._connect(device).catch(() => { });
            }
        }

        // Must be called from a user gesture: the chooser is browser UI.
        async addPeer() {
            const service = P().MeshConst.serviceUuid;
            const device = await navigator.bluetooth.requestDevice({
                filters: [{ services: [service] }],
                optionalServices: [service],
            });
            this._track(device);
            this._watch(device);
            await this._connect(device);
            return device.name || device.id;
        }

        async forgetPeer(id) {
            const link = this.links.get(id);
            if (!link) return;
            try { if (link.device.gatt && link.device.gatt.connected) link.device.gatt.disconnect(); } catch (_) { }
            try { if (link.device.forget) await link.device.forget(); } catch (_) { }
            this.links.delete(id);
            this.onLinkChange();
        }

        _track(device) {
            if (this.links.has(device.id)) return;
            this.links.set(device.id, { id: device.id, device, characteristic: null });
            device.addEventListener('gattserverdisconnected', () => {
                const link = this.links.get(device.id);
                if (link) link.characteristic = null;
                this.log('link down: ' + (device.name || device.id));
                this.onLinkChange();
                this._scheduleReconnect(device);
            });
        }

        // An advertisement means the peer is in range again — the cue to
        // reconnect without waiting on a timer.
        _watch(device) {
            if (this.watched.has(device.id) || !device.watchAdvertisements) return;
            this.watched.add(device.id);
            device.addEventListener('advertisementreceived', (e) => {
                const link = this.links.get(device.id);
                if (link) link.rssi = e.rssi;
                if (this.started && (!link || !link.characteristic)) {
                    this._connect(device).catch(() => { });
                }
            });
            device.watchAdvertisements().catch(() => this.watched.delete(device.id));
        }

        _scheduleReconnect(device) {
            if (!this.started) return;
            const streak = (this._failStreak.get(device.id) || 0) + 1;
            this._failStreak.set(device.id, streak);
            const delay = Math.min(30000, 1000 * Math.pow(2, Math.min(streak, 5)));
            setTimeout(() => {
                if (this.started) this._connect(device).catch(() => { });
            }, delay);
        }

        async _connect(device) {
            if (!this.started || !device.gatt) return;
            const link = this.links.get(device.id);
            if (!link || link.connecting || link.characteristic) return;
            link.connecting = true;
            try {
                const server = device.gatt.connected ? device.gatt : await device.gatt.connect();
                const service = await server.getPrimaryService(P().MeshConst.serviceUuid);
                const characteristic = await service.getCharacteristic(P().MeshConst.characteristicUuid);
                characteristic.addEventListener('characteristicvaluechanged', (e) => {
                    const v = e.target.value;
                    if (!v) return;
                    const bytes = new Uint8Array(v.buffer, v.byteOffset, v.byteLength).slice();
                    this.onFrame({ data: bytes, linkId: device.id, rssi: link.rssi || 0 });
                });
                await characteristic.startNotifications();
                link.characteristic = characteristic;
                this._failStreak.delete(device.id);
                this.log('link up: ' + (device.name || device.id));
                this.onLinkChange(device.id);
            } catch (err) {
                this.log('connect failed (' + (device.name || device.id) + '): ' + (err && err.message));
                this._scheduleReconnect(device);
                throw err;
            } finally {
                link.connecting = false;
            }
        }

        // Broadcasts a frame to every live link. [exceptLinkId] suppresses the
        // hop a relayed packet arrived on.
        async broadcast(bytes, exceptLinkId) {
            const targets = [];
            for (const link of this.links.values()) {
                if (!link.characteristic) continue;
                if (exceptLinkId && link.id === exceptLinkId) continue;
                targets.push(link);
            }
            for (const link of targets) {
                try {
                    if (link.characteristic.writeValueWithoutResponse) {
                        await link.characteristic.writeValueWithoutResponse(bytes);
                    } else {
                        await link.characteristic.writeValue(bytes);
                    }
                } catch (err) {
                    link.characteristic = null;
                    this.log('write failed: ' + (err && err.message));
                    this.onLinkChange();
                    this._scheduleReconnect(link.device);
                }
            }
            return targets.length > 0;
        }
    }

    G.NymMeshTransport = { isSupported, WebBluetoothTransport };
})();
