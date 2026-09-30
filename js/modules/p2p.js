// p2p.js - Peer-to-peer file sharing: WebRTC data channels, WebTorrent, transfers UI

const _RX_P2P_OFFER_ID = /^[0-9a-f]{16}-[0-9a-z]{1,12}$/;
const _RX_P2P_MIME = /^[a-z0-9][a-z0-9!#$&^_.+-]{0,126}\/[a-z0-9][a-z0-9!#$&^_.+-]{0,126}$/i;

Object.assign(NYM.prototype, {

    P2P_MAX_FILE_SIZE: 2 * 1024 * 1024 * 1024,

    sanitizeDownloadFilename(name) {
        let safe = String(name || '')
            .replace(/[\/\\]/g, '_')
            .replace(/[\x00-\x1f\x7f]/g, '')
            .replace(/^\.+/, '');
        safe = safe.replace(/\.(?=[^.]*\.)/g, '_');
        if (safe.length > 255) safe = safe.slice(safe.length - 255);
        return safe || 'download';
    },

    abortReceivedTransfer(transferId, message) {
        this.updateTransferStatus(transferId, 'error', message);
        this.p2pReceivedChunks.delete(transferId);
        const connectionsToDelete = [];
        this.p2pConnections.forEach((pc, connectionId) => {
            if (connectionId.endsWith(transferId)) {
                try { pc.close(); } catch (e) {}
                connectionsToDelete.push(connectionId);
            }
        });
        connectionsToDelete.forEach(id => {
            this.p2pConnections.delete(id);
            if (this.p2pDataChannels.has(id)) {
                try { this.p2pDataChannels.get(id).close(); } catch (e) {}
                this.p2pDataChannels.delete(id);
            }
        });
        this.displaySystemMessage(message);
    },

    getValidatedMagnetInfoHash(magnetURI) {
        if (typeof magnetURI !== 'string' || !magnetURI.startsWith('magnet:?')) return null;
        const match = magnetURI.match(/xt=urn:btih:([^&]+)/i);
        if (!match) return null;
        const hash = match[1];
        if (/^[a-fA-F0-9]{40}$/.test(hash)) return hash.toLowerCase();
        if (/^[a-zA-Z2-7]{32}$/.test(hash)) return hash.toUpperCase();
        return null;
    },

    handleP2PSignalingEvent(event) {
        try {
            const data = JSON.parse(event.content);
            const senderPubkey = event.pubkey;

            if (data.type === 'offer') {
                this.handleP2POffer(senderPubkey, data);
            } else if (data.type === 'answer') {
                this.handleP2PAnswer(senderPubkey, data);
            } else if (data.type === 'ice-candidate') {
                this.handleP2PIceCandidate(senderPubkey, data);
            }
        } catch (e) {
            console.error('P2P signaling error:', e);
        }
    },

    _isOfferSeeder(offerId, pubkey) {
        const offer = this.p2pFileOffers && this.p2pFileOffers.get(offerId);
        return !!(offer && pubkey && offer.seederPubkey === pubkey);
    },

    handleP2PFileStatusEvent(event) {
        if (!event || !event.pubkey) return;
        try {
            const data = JSON.parse(event.content);
            if (data.status === 'unseeded' && this.isValidOfferId(data.offerId)
                && this._isOfferSeeder(data.offerId, event.pubkey)) {
                this.p2pUnseededOffers.add(data.offerId);
                this.updateFileOfferUI(data.offerId, 'unseeded');
            }
        } catch (e) {
            const offerIdTag = (event.tags || []).find(t => t[0] === 'offer_id');
            const statusTag = (event.tags || []).find(t => t[0] === 'status');
            if (offerIdTag && statusTag && statusTag[1] === 'unseeded' && this.isValidOfferId(offerIdTag[1])
                && this._isOfferSeeder(offerIdTag[1], event.pubkey)) {
                this.p2pUnseededOffers.add(offerIdTag[1]);
                this.updateFileOfferUI(offerIdTag[1], 'unseeded');
            }
        }
    },

    async shareP2PFile(file) {
        if (!this.connected || !this.pubkey) {
            this.displaySystemMessage('Must be connected to share files');
            return;
        }

        const arrayBuffer = await file.arrayBuffer();
        const hashBuffer = await crypto.subtle.digest('SHA-256', arrayBuffer);
        const hashArray = Array.from(new Uint8Array(hashBuffer));
        const fileHash = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');

        const offerId = fileHash.substring(0, 16) + '-' + Date.now().toString(36);

        this.p2pPendingFiles.set(offerId, file);

        const fileOffer = {
            offerId: offerId,
            name: file.name,
            size: file.size,
            type: file.type || 'application/octet-stream',
            hash: fileHash,
            seederPubkey: this.pubkey,
            timestamp: Math.floor(Date.now() / 1000)
        };

        this.p2pFileOffers.set(offerId, fileOffer);

        const content = `Sharing file through Nymchat: ${file.name} (${this.formatFileSize(file.size)})`;
        const published = await this.publishFileOffer(fileOffer, content);
        if (published) {
            this.displaySystemMessage(`File "${file.name}" is now available for P2P download`);
        }
    },

    // Public geohash channel (broadcast), 1:1 PM, or private group (encrypted gift wrap).
    async publishFileOffer(fileOffer, content) {
        if (this.inPMMode && this.currentGroup) {
            await this.sendGroupMessage(content, this.currentGroup, { fileOffer });
            return true;
        }
        if (this.inPMMode && this.currentPM) {
            await this.sendPM(content, this.currentPM, { fileOffer });
            return true;
        }
        if (!this.currentGeohash) {
            this.displaySystemMessage('No channel selected for file sharing');
            return false;
        }

        const nowMs = Date.now();
        const now = Math.floor(nowMs / 1000);
        const wire = this.channelWire(this.currentGeohash);
        const event = {
            kind: wire.kind,
            created_at: now,
            tags: [
                ['n', this.nym],
                ['offer', JSON.stringify(fileOffer)],
                ['ms', String(nowMs)],
                [wire.tag, this.currentGeohash]
            ],
            content,
            pubkey: this.pubkey
        };

        const signedEvent = await this.signEvent(event);
        this.displayMessage({
            id: signedEvent.id,
            author: this.nym,
            pubkey: this.pubkey,
            content,
            created_at: now,
            _ms: nowMs,
            _seq: ++this._msgSeq,
            timestamp: new Date(now * 1000),
            channel: this.currentChannel,
            geohash: this.currentGeohash || '',
            isOwn: true,
            isHistorical: false,
            isFileOffer: true,
            fileOffer
        });
        this.sendToRelay(['EVENT', signedEvent]);
        return true;
    },

    isValidOfferId(offerId) {
        return typeof offerId === 'string' && _RX_P2P_OFFER_ID.test(offerId);
    },

    sanitizeFileOffer(raw, senderPubkey) {
        if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
        if (typeof senderPubkey !== 'string' || !/^[0-9a-f]{64}$/.test(senderPubkey)) return null;
        if (!this.isValidOfferId(raw.offerId)) return null;
        if (raw.seederPubkey !== undefined && raw.seederPubkey !== senderPubkey) return null;
        if (typeof raw.name !== 'string' || !raw.name || raw.name.length > 1024) return null;
        if (!Number.isSafeInteger(raw.size) || raw.size < 0) return null;
        const offer = {
            offerId: raw.offerId,
            name: raw.name,
            size: raw.size,
            type: (typeof raw.type === 'string' && _RX_P2P_MIME.test(raw.type)) ? raw.type : 'application/octet-stream',
            seederPubkey: senderPubkey,
            timestamp: Number.isSafeInteger(raw.timestamp) && raw.timestamp > 0 ? raw.timestamp : 0
        };
        if (raw.hash !== undefined) {
            if (typeof raw.hash !== 'string' || !/^[0-9a-f]{64}$/i.test(raw.hash)) return null;
            offer.hash = raw.hash.toLowerCase();
        }
        if (raw.magnetURI !== undefined) {
            if (typeof raw.magnetURI !== 'string' || raw.magnetURI.length > 4096) return null;
            if (!this.getValidatedMagnetInfoHash(raw.magnetURI)) return null;
            offer.magnetURI = raw.magnetURI;
        }
        if (raw.infoHash !== undefined) {
            if (typeof raw.infoHash !== 'string' || !/^[0-9a-f]{40}$/i.test(raw.infoHash)) return null;
            offer.infoHash = raw.infoHash.toLowerCase();
        }
        return offer;
    },

    parseFileOfferTag(tags, senderPubkey) {
        const offerTag = (tags || []).find(t => Array.isArray(t) && t[0] === 'offer');
        if (!offerTag || typeof offerTag[1] !== 'string' || offerTag[1].length > 16384) return null;
        try {
            const fileOffer = this.sanitizeFileOffer(JSON.parse(offerTag[1]), senderPubkey);
            if (fileOffer) {
                this.p2pFileOffers.set(fileOffer.offerId, fileOffer);
                return fileOffer;
            }
        } catch (e) {
            console.error('Error parsing file offer:', e);
        }
        return null;
    },

    formatFileSize(bytes) {
        bytes = Number(bytes);
        if (!Number.isFinite(bytes) || bytes < 0) bytes = 0;
        if (bytes < 1024) return bytes + ' B';
        if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
        if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
        return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
    },

    getFileTypeCategory(filename, mimeType) {
        const ext = filename.split('.').pop().toLowerCase();
        const audioExts = ['mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a', 'wma'];
        const videoExts = ['mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm'];
        const archiveExts = ['zip', 'rar', '7z', 'tar', 'gz', 'bz2'];
        const docExts = ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'rtf'];

        if (audioExts.includes(ext) || mimeType?.startsWith('audio/')) return 'audio';
        if (videoExts.includes(ext) || mimeType?.startsWith('video/')) return 'video';
        if (archiveExts.includes(ext)) return 'archive';
        if (docExts.includes(ext)) return 'document';
        return 'file';
    },

    async requestP2PFile(offerId) {
        if (!this.isValidOfferId(offerId)) return;
        const offer = this.p2pFileOffers.get(offerId);
        if (!offer) {
            this.displaySystemMessage('File offer not found');
            return;
        }

        if (offer.seederPubkey === this.pubkey) {
            this.displaySystemMessage('Cannot download your own file');
            return;
        }

        if (this.p2pUnseededOffers.has(offerId)) {
            this.displaySystemMessage('This file is no longer being seeded by the owner');
            return;
        }

        const btn = document.querySelector(`[data-offer-id="${offerId}"] .file-offer-btn`);
        const progressDiv = document.getElementById(`progress-${offerId}`);
        if (btn) {
            btn.textContent = 'Connecting...';
            btn.classList.add('downloading');
            btn.onclick = null;
        }
        if (progressDiv) {
            progressDiv.style.display = 'block';
        }

        const transferId = offerId + '-' + Date.now().toString(36);
        this.p2pActiveTransfers.set(transferId, {
            offerId: offerId,
            offer: offer,
            status: 'connecting',
            bytesReceived: 0,
            startTime: Date.now()
        });
        this.p2pReceivedChunks.set(transferId, []);

        await this.createP2PConnection(offer.seederPubkey, transferId, true);
    },

    async createP2PConnection(peerPubkey, transferId, isInitiator) {
        const connectionId = peerPubkey + '-' + transferId;

        const pc = new RTCPeerConnection({
            iceServers: this.p2pIceServers
        });

        this.p2pConnections.set(connectionId, pc);

        pc.onicecandidate = (event) => {
            if (event.candidate) {
                this.sendP2PSignal(peerPubkey, {
                    type: 'ice-candidate',
                    candidate: event.candidate,
                    transferId: transferId
                });
            }
        };

        pc.oniceconnectionstatechange = () => {
            const transfer = this.p2pActiveTransfers.get(transferId);
            if (pc.iceConnectionState === 'failed') {
                if (transfer) {
                    this.updateTransferStatus(transferId, 'error', 'Connection failed - peer may be offline');
                }
                this.cleanupP2PConnection(connectionId, transferId);
            } else if (pc.iceConnectionState === 'disconnected') {
                setTimeout(() => {
                    if (pc.iceConnectionState === 'disconnected' || pc.iceConnectionState === 'failed') {
                        if (transfer && transfer.status !== 'complete') {
                            this.updateTransferStatus(transferId, 'error', 'Connection lost');
                        }
                        this.cleanupP2PConnection(connectionId, transferId);
                    }
                }, 5000);
            } else if (pc.iceConnectionState === 'connected') {
                if (transfer) transfer.status = 'transferring';
            }
        };

        const connectionTimeout = setTimeout(() => {
            const transfer = this.p2pActiveTransfers.get(transferId);
            if (transfer && transfer.status === 'connecting') {
                this.updateTransferStatus(transferId, 'error', 'Connection timed out - peer may be offline');
                this.cleanupP2PConnection(connectionId, transferId);
            }
        }, 30000);

        const origOnIceChange = pc.oniceconnectionstatechange;
        pc.oniceconnectionstatechange = (e) => {
            if (pc.iceConnectionState === 'connected' || pc.iceConnectionState === 'completed') {
                clearTimeout(connectionTimeout);
            }
            origOnIceChange.call(this, e);
        };

        if (isInitiator) {
            const dc = pc.createDataChannel('fileTransfer', {
                ordered: true
            });
            this.setupDataChannel(dc, transferId, false);
            this.p2pDataChannels.set(connectionId, dc);

            const offer = await pc.createOffer();
            await pc.setLocalDescription(offer);

            const transfer = this.p2pActiveTransfers.get(transferId);
            this.sendP2PSignal(peerPubkey, {
                type: 'offer',
                sdp: pc.localDescription,
                transferId: transferId,
                offerId: transfer?.offerId
            });
        } else {
            pc.ondatachannel = (event) => {
                const dc = event.channel;
                this.setupDataChannel(dc, transferId, true);
                this.p2pDataChannels.set(connectionId, dc);
            };
        }

        return pc;
    },

    cleanupP2PConnection(connectionId, transferId) {
        const pc = this.p2pConnections.get(connectionId);
        if (pc) {
            try { pc.close(); } catch (e) {}
            this.p2pConnections.delete(connectionId);
        }
        const dc = this.p2pDataChannels.get(connectionId);
        if (dc) {
            try { dc.close(); } catch (e) {}
            this.p2pDataChannels.delete(connectionId);
        }
    },

    setupDataChannel(dc, transferId, isSender) {
        dc.binaryType = 'arraybuffer';

        dc.onopen = () => {
            if (isSender) {
                this.startSendingFile(transferId, dc);
            } else {
                this.updateTransferStatus(transferId, 'transferring', 'Receiving...');
            }
        };

        dc.onmessage = (event) => {
            if (!isSender) {
                this.handleFileChunk(transferId, event.data);
            }
        };

        dc.onerror = (error) => {
            console.error('Data channel error:', error);
            this.updateTransferStatus(transferId, 'error', 'Transfer error');
        };

        dc.onclose = () => {
            const transfer = this.p2pActiveTransfers.get(transferId);
            if (transfer && transfer.status !== 'complete' && transfer.status !== 'error') {
                this.updateTransferStatus(transferId, 'error', 'Connection closed');
            }
        };
    },

    async startSendingFile(transferId, dataChannel) {
        const transfer = this.p2pActiveTransfers.get(transferId);
        if (!transfer) return;

        const file = this.p2pPendingFiles.get(transfer.offerId);
        if (!file) {
            try {
                dataChannel.send(JSON.stringify({ type: 'error', message: 'File no longer available' }));
            } catch (e) {}
            this.updateTransferStatus(transferId, 'error', 'File no longer available');
            return;
        }

        dataChannel.send(JSON.stringify({
            type: 'metadata',
            name: file.name,
            size: file.size,
            mimeType: file.type
        }));

        // Small delay so metadata is received before binary data.
        await new Promise(resolve => setTimeout(resolve, 50));

        const chunkSize = this.P2P_CHUNK_SIZE;
        const HIGH_WATER = chunkSize * 16;   // start backpressure
        const LOW_WATER = chunkSize * 4;     // resume threshold
        let offset = 0;

        try { dataChannel.bufferedAmountLowThreshold = LOW_WATER; } catch (_) { }

        const waitForDrain = () => new Promise((resolve, reject) => {
            const onLow = () => {
                dataChannel.removeEventListener('bufferedamountlow', onLow);
                resolve();
            };
            const fallback = setTimeout(() => {
                dataChannel.removeEventListener('bufferedamountlow', onLow);
                resolve();
            }, 5000);
            dataChannel.addEventListener('bufferedamountlow', () => {
                clearTimeout(fallback);
                onLow();
            }, { once: true });
        });

        const sendNextChunk = async () => {
            if (dataChannel.readyState !== 'open') {
                this.updateTransferStatus(transferId, 'error', 'Connection closed during transfer');
                return;
            }

            if (offset >= file.size) {
                // Small delay so all data chunks flush before sending complete.
                await new Promise(resolve => setTimeout(resolve, 100));
                try {
                    dataChannel.send(JSON.stringify({ type: 'complete' }));
                } catch (e) {}
                transfer.status = 'complete';
                return;
            }

            const chunk = file.slice(offset, offset + chunkSize);
            const arrayBuffer = await chunk.arrayBuffer();

            if (dataChannel.bufferedAmount > HIGH_WATER) {
                await waitForDrain();
                if (dataChannel.readyState !== 'open') {
                    this.updateTransferStatus(transferId, 'error', 'Connection closed during transfer');
                    return;
                }
            }

            if (dataChannel.readyState === 'open') {
                dataChannel.send(arrayBuffer);
                offset += chunkSize;

                // Skip the setTimeout(0) hop when the channel has headroom to keep throughput high.
                if (dataChannel.bufferedAmount < HIGH_WATER) {
                    Promise.resolve().then(sendNextChunk);
                } else {
                    setTimeout(sendNextChunk, 0);
                }
            }
        };

        sendNextChunk();
    },

    handleFileChunk(transferId, data) {
        const transfer = this.p2pActiveTransfers.get(transferId);
        if (!transfer) return;

        if (typeof data === 'string') {
            try {
                const msg = JSON.parse(data);

                if (msg.type === 'metadata') {
                    transfer.metadata = msg;
                    return;
                } else if (msg.type === 'complete') {
                    Promise.resolve(this.completeFileTransfer(transferId)).catch(() => { });
                    return;
                } else if (msg.type === 'error') {
                    this.updateTransferStatus(transferId, 'error', msg.message);
                    return;
                }
            } catch (e) {
            }
            return;
        }

        if (data instanceof ArrayBuffer) {
            const chunks = this.p2pReceivedChunks.get(transferId);
            if (chunks) {
                const newTotal = transfer.bytesReceived + data.byteLength;
                if (newTotal > this.P2P_MAX_FILE_SIZE) {
                    this.abortReceivedTransfer(transferId, 'Transfer aborted: file exceeds maximum allowed size');
                    return;
                }
                if (transfer.offer && typeof transfer.offer.size === 'number' && newTotal > transfer.offer.size) {
                    this.abortReceivedTransfer(transferId, 'Transfer aborted: received more data than advertised');
                    return;
                }
                chunks.push(data);
                transfer.bytesReceived += data.byteLength;

                if (transfer.offer) {
                    const progress = Math.min(100, (transfer.bytesReceived / transfer.offer.size) * 100);
                    this.updateTransferProgress(transferId, progress);
                }
            }
        }
    },

    async completeFileTransfer(transferId) {
        const transfer = this.p2pActiveTransfers.get(transferId);
        const chunks = this.p2pReceivedChunks.get(transferId);

        if (!transfer || !chunks) return;

        const offer = transfer.offer;

        if (transfer.bytesReceived > this.P2P_MAX_FILE_SIZE) {
            this.abortReceivedTransfer(transferId, 'Transfer rejected: file exceeds maximum allowed size');
            return;
        }
        if (offer && typeof offer.size === 'number' && transfer.bytesReceived !== offer.size) {
            this.abortReceivedTransfer(transferId, 'Transfer rejected: received size does not match advertised size');
            return;
        }

        const blob = new Blob(chunks, { type: 'application/octet-stream' });

        if (offer && offer.hash) {
            try {
                const buffer = await blob.arrayBuffer();
                const hashBuffer = await crypto.subtle.digest('SHA-256', buffer);
                const hashHex = Array.from(new Uint8Array(hashBuffer)).map(b => b.toString(16).padStart(2, '0')).join('');
                if (hashHex !== String(offer.hash).toLowerCase()) {
                    this.abortReceivedTransfer(transferId, 'Transfer rejected: file content does not match advertised hash');
                    return;
                }
            } catch (e) {
                this.abortReceivedTransfer(transferId, 'Transfer rejected: could not verify file integrity');
                return;
            }
        } else {
            console.warn('P2P offer has no advertised hash; skipping integrity check for transfer', transferId);
        }

        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = this.sanitizeDownloadFilename(transfer.metadata?.name || offer?.name || 'download');
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);

        this.updateTransferStatus(transferId, 'complete', 'Download complete!');

        this.p2pReceivedChunks.delete(transferId);

        this.displaySystemMessage(`File "${transfer.offer?.name || 'file'}" downloaded successfully`);
    },

    updateTransferProgress(transferId, percent) {
        const transfer = this.p2pActiveTransfers.get(transferId);
        if (!transfer) return;

        const offerId = transfer.offerId;
        const progressFill = document.getElementById(`progress-fill-${offerId}`);
        const progressText = document.getElementById(`progress-text-${offerId}`);

        if (progressFill) {
            progressFill.style.width = percent.toFixed(1) + '%';
        }
        if (progressText) {
            const elapsed = (Date.now() - transfer.startTime) / 1000;
            const speed = transfer.bytesReceived / elapsed;
            progressText.textContent = `${percent.toFixed(1)}% • ${this.formatFileSize(Math.round(speed))}/s`;
        }
    },

    updateTransferStatus(transferId, status, message) {
        const transfer = this.p2pActiveTransfers.get(transferId);
        if (!transfer) return;

        transfer.status = status;

        const offerId = transfer.offerId;
        const progressText = document.getElementById(`progress-text-${offerId}`);
        const btn = document.querySelector(`[data-offer-id="${offerId}"] .file-offer-btn`);

        if (progressText) {
            progressText.textContent = message;
            progressText.className = 'file-offer-progress-text ' + status;
        }

        if (status === 'complete' && btn) {
            btn.textContent = 'Downloaded';
            btn.classList.remove('downloading');
        } else if (status === 'error' && btn) {
            btn.textContent = 'Retry';
            btn.classList.remove('downloading');
            btn.onclick = () => this.requestP2PFile(offerId);
        }
    },

    async sendP2PSignal(targetPubkey, data) {
        const event = {
            kind: this.P2P_SIGNALING_KIND,
            created_at: Math.floor(Date.now() / 1000),
            tags: [
                ['p', targetPubkey]
            ],
            content: JSON.stringify(data),
            pubkey: this.pubkey
        };

        const signedEvent = await this.signEvent(event);
        this.sendToRelay(['EVENT', signedEvent]);
    },

    async handleP2POffer(senderPubkey, data) {
        const { sdp, transferId, offerId } = data;

        if (!this.p2pPendingFiles.has(offerId)) {
            return;
        }

        const fileOffer = this.p2pFileOffers.get(offerId);
        if (!fileOffer || fileOffer.seederPubkey !== this.pubkey) {
            console.warn('Rejected P2P file request: offer seeder pubkey mismatch for', offerId);
            return;
        }

        this.p2pActiveTransfers.set(transferId, {
            offerId: offerId,
            offer: fileOffer,
            status: 'connecting',
            bytesSent: 0,
            startTime: Date.now()
        });

        const pc = await this.createP2PConnection(senderPubkey, transferId, false);
        await pc.setRemoteDescription(new RTCSessionDescription(sdp));

        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);

        this.sendP2PSignal(senderPubkey, {
            type: 'answer',
            sdp: pc.localDescription,
            transferId: transferId
        });
    },

    async handleP2PAnswer(senderPubkey, data) {
        const { sdp, transferId } = data;
        const connectionId = senderPubkey + '-' + transferId;

        const pc = this.p2pConnections.get(connectionId);
        if (pc) {
            await pc.setRemoteDescription(new RTCSessionDescription(sdp));
        }
    },

    async handleP2PIceCandidate(senderPubkey, data) {
        const { candidate, transferId } = data;
        const connectionId = senderPubkey + '-' + transferId;

        const pc = this.p2pConnections.get(connectionId);
        if (pc && candidate) {
            try {
                await pc.addIceCandidate(new RTCIceCandidate(candidate));
            } catch (e) {
                console.error('Error adding ICE candidate:', e);
            }
        }
    },

    openP2PTransfersModal() {
        const modal = document.getElementById('p2pTransfersModal');
        const list = document.getElementById('p2pTransfersList');

        if (!modal || !list) return;

        list.innerHTML = '';

        if (this.p2pActiveTransfers.size === 0 && this.p2pPendingFiles.size === 0) {
            list.innerHTML = '<div class="p2p-empty-state">No active transfers</div>';
        } else {
            const fragment = document.createDocumentFragment();

            this.p2pPendingFiles.forEach((file, offerId) => {
                const offer = this.p2pFileOffers.get(offerId);
                if (offer) {
                    const isTorrent = this.torrentSeeds.has(offerId);
                    const item = document.createElement('div');
                    item.className = 'p2p-transfer-item';
                    item.innerHTML = `
                        <div class="p2p-transfer-header">
                            <span class="p2p-transfer-filename">${this.escapeHtml(offer.name)}</span>
                            <span class="p2p-transfer-size">${this.formatFileSize(offer.size)}</span>
                        </div>
                        <div class="p2p-transfer-status">
                            <span class="p2p-transfer-status-text complete">Seeding${isTorrent ? ' (Torrent)' : ' (P2P)'}</span>
                            <div class="p2p-transfer-actions">
                                <button class="p2p-transfer-btn cancel" data-action="stopSeeding" data-offer-id="${this.escapeHtml(offerId)}">Stop</button>
                            </div>
                        </div>
                    `;
                    fragment.appendChild(item);
                }
            });

            this.p2pActiveTransfers.forEach((transfer, transferId) => {
                if (transfer.offer) {
                    const item = document.createElement('div');
                    item.className = 'p2p-transfer-item';
                    const progress = transfer.offer.size > 0 ? (transfer.bytesReceived / transfer.offer.size) * 100 : 0;
                    item.innerHTML = `
                        <div class="p2p-transfer-header">
                            <span class="p2p-transfer-filename">${this.escapeHtml(transfer.offer.name)}</span>
                            <span class="p2p-transfer-size">${this.formatFileSize(transfer.offer.size)}</span>
                        </div>
                        <div class="p2p-transfer-progress">
                            <div class="p2p-transfer-progress-fill" data-pct="${progress.toFixed(1)}"></div>
                        </div>
                        <div class="p2p-transfer-status">
                            <span class="p2p-transfer-status-text ${this.escapeHtml(transfer.status)}">${this.escapeHtml(transfer.status)}</span>
                            <div class="p2p-transfer-actions">
                                <button class="p2p-transfer-btn cancel" data-action="cancelTransfer" data-transfer-id="${this.escapeHtml(transferId)}">Cancel</button>
                            </div>
                        </div>
                    `;
                    const pf = item.querySelector('.p2p-transfer-progress-fill[data-pct]');
                    if (pf) pf.style.width = pf.dataset.pct + '%';
                    fragment.appendChild(item);
                }
            });

            list.appendChild(fragment);
        }

        modal.classList.add('active');
    },

    async stopSeeding(offerId) {
        const offer = this.p2pFileOffers.get(offerId);
        this.p2pPendingFiles.delete(offerId);
        this.p2pUnseededOffers.add(offerId);

        this.stopSeedingTorrent(offerId);

        const transfersToCancel = [];
        this.p2pActiveTransfers.forEach((transfer, transferId) => {
            if (transfer.offerId === offerId) {
                transfersToCancel.push(transferId);
            }
        });
        transfersToCancel.forEach(transferId => this.cancelTransfer(transferId));

        if (offer && this.pubkey) {
            try {
                let tags = [
                    ['offer_id', offerId],
                    ['status', 'unseeded']
                ];
                if (offer.hash) tags.push(['x', offer.hash]);
                if (this.currentGeohash) tags.push([this.channelWire(this.currentGeohash).tag, this.currentGeohash]);

                const event = {
                    kind: this.P2P_FILE_STATUS_KIND,
                    created_at: Math.floor(Date.now() / 1000),
                    tags: tags,
                    content: JSON.stringify({ offerId, name: offer.name, status: 'unseeded' }),
                    pubkey: this.pubkey
                };

                const signedEvent = await this.signEvent(event);
                this.sendToRelay(['EVENT', signedEvent]);
            } catch (e) {
                console.error('Failed to broadcast unseeded event:', e);
            }
        }

        this.updateFileOfferUI(offerId, 'unseeded');

        this.displaySystemMessage('Stopped seeding file' + (offer ? `: ${offer.name}` : ''));
        this.openP2PTransfersModal();
    },

    updateFileOfferUI(offerId, status) {
        if (!this.isValidOfferId(offerId)) return;
        const offerEl = document.querySelector(`[data-offer-id="${offerId}"]`);
        if (!offerEl) return;

        if (status === 'unseeded') {
            const seedingDiv = offerEl.querySelector('.file-offer-seeding');
            if (seedingDiv) {
                seedingDiv.innerHTML = `
                    <div class="file-offer-unseeded-dot"></div>
                    <span>No longer seeding</span>
                `;
                seedingDiv.className = 'file-offer-unseeded';
            }
            const actionDiv = offerEl.querySelector('.file-offer-actions');
            if (actionDiv) {
                const btn = actionDiv.querySelector('.file-offer-btn');
                if (btn) {
                    btn.textContent = 'Unavailable';
                    btn.classList.add('unavailable');
                    btn.onclick = null;
                    btn.style.cursor = 'default';
                }
            }
        }
    },

    async getTorrentClient() {
        if (!this.torrentClient) {
            if (typeof WebTorrent === 'undefined') {
                // ESM-only bundle: dynamic import, then expose the usual global.
                try {
                    const mod = await import(window.NYM_CDN.webtorrent);
                    window.WebTorrent = mod.default || mod.WebTorrent;
                } catch (_) { return null; }
            }
            if (typeof WebTorrent === 'undefined') return null;
            this.torrentClient = new WebTorrent();
            this.torrentClient.on('error', (err) => {
                console.error('WebTorrent error:', err);
            });
        }
        return this.torrentClient;
    },

    async shareP2PFileTorrent(file) {
        if (!this.connected || !this.pubkey) {
            this.displaySystemMessage('Must be connected to share files');
            return;
        }

        const client = await this.getTorrentClient();
        if (!client) {
            this.displaySystemMessage('WebTorrent is not available. Falling back to direct P2P.');
            return this.shareP2PFile(file);
        }

        if (!this.currentGeohash && !(this.inPMMode && (this.currentPM || this.currentGroup))) {
            this.displaySystemMessage('No channel selected for file sharing');
            return;
        }

        const isTorrentFile = file.name.endsWith('.torrent') || file.type === 'application/x-bittorrent';

        if (isTorrentFile) {
            this.displaySystemMessage(`Loading torrent file "${file.name}"...`);
            const torrentBuffer = await file.arrayBuffer();

            client.add(new Uint8Array(torrentBuffer), (torrent) => {
                this.onTorrentReady(torrent, file.name);
            });
        } else {
            this.displaySystemMessage(`Creating torrent for "${file.name}"...`);
            client.seed(file, { announceList: [] }, (torrent) => {
                this.onTorrentReady(torrent, null);
            });
        }
    },

    onTorrentReady(torrent, originalTorrentFileName) {
        const torrentFile = torrent.files[0];
        const displayName = torrentFile ? torrentFile.name : (originalTorrentFileName || 'Unknown');
        const displaySize = torrent.length || 0;

        const offerId = torrent.infoHash.substring(0, 16) + '-' + Date.now().toString(36);

        this.torrentSeeds.set(offerId, torrent);

        const placeholderFile = new File([], displayName, { type: 'application/x-bittorrent' });
        this.p2pPendingFiles.set(offerId, placeholderFile);

        const fileOffer = {
            offerId: offerId,
            name: displayName,
            size: displaySize,
            type: torrentFile ? (torrentFile.type || 'application/octet-stream') : 'application/octet-stream',
            seederPubkey: this.pubkey,
            timestamp: Math.floor(Date.now() / 1000),
            magnetURI: torrent.magnetURI,
            infoHash: torrent.infoHash
        };

        this.p2pFileOffers.set(offerId, fileOffer);

        const content = `Sharing file via torrent: ${displayName} (${this.formatFileSize(displaySize)})`;
        this.publishFileOffer(fileOffer, content).then(published => {
            if (published) this.displaySystemMessage(`Seeding torrent: "${displayName}"`);
        });
    },

    async downloadTorrent(offerId) {
        const offer = this.p2pFileOffers.get(offerId);
        if (!offer || !offer.magnetURI) {
            this.displaySystemMessage('Torrent info not found for this file');
            return;
        }

        if (offer.seederPubkey === this.pubkey) {
            this.displaySystemMessage('Cannot download your own file');
            return;
        }

        if (this.p2pUnseededOffers.has(offerId)) {
            this.displaySystemMessage('This file is no longer being seeded');
            return;
        }

        const magnetHash = this.getValidatedMagnetInfoHash(offer.magnetURI);
        if (!magnetHash) {
            this.displaySystemMessage('Invalid or malformed magnet link in this offer');
            return;
        }

        const advertisedHash = String(offer.infoHash || offer.hash || '').toLowerCase();
        if (/^[a-f0-9]{40}$/.test(advertisedHash) && magnetHash.length === 40 && magnetHash !== advertisedHash) {
            this.displaySystemMessage('Torrent rejected: magnet infohash does not match advertised hash');
            return;
        }

        const client = await this.getTorrentClient();
        if (!client) {
            this.displaySystemMessage('WebTorrent is not available in this browser');
            return;
        }

        const btn = document.querySelector(`[data-offer-id="${offerId}"] .file-offer-btn`);
        const progressDiv = document.getElementById(`progress-${offerId}`);
        if (btn) {
            btn.textContent = 'Connecting...';
            btn.classList.add('downloading');
            btn.onclick = null;
        }
        if (progressDiv) {
            progressDiv.style.display = 'block';
        }

        const existingTorrent = client.get(magnetHash);
        if (existingTorrent) {
            this.displaySystemMessage('Already downloading this torrent');
            return;
        }

        const transferId = offerId + '-torrent-' + Date.now().toString(36);
        this.p2pActiveTransfers.set(transferId, {
            offerId: offerId,
            offer: offer,
            status: 'connecting',
            bytesReceived: 0,
            startTime: Date.now(),
            isTorrent: true
        });

        const safeMagnetURI = 'magnet:?xt=urn:btih:' + magnetHash;

        client.add(safeMagnetURI, { announce: [] }, (torrent) => {
            const transfer = this.p2pActiveTransfers.get(transferId);
            if (!transfer) return;

            if (torrent.length > this.P2P_MAX_FILE_SIZE ||
                (typeof offer.size === 'number' && torrent.length > offer.size)) {
                try { torrent.destroy(); } catch (e) {}
                this.updateTransferStatus(transferId, 'error', 'Torrent rejected: larger than advertised size');
                this.p2pActiveTransfers.delete(transferId);
                this.displaySystemMessage('Torrent rejected: larger than advertised size');
                return;
            }

            transfer.status = 'transferring';
            transfer.torrent = torrent;

            torrent.on('download', () => {
                transfer.bytesReceived = torrent.downloaded;
                const progress = Math.min(100, (torrent.downloaded / torrent.length) * 100);
                this.updateTransferProgress(transferId, progress);

                if (btn) {
                    btn.textContent = `${progress.toFixed(1)}%`;
                }
            });

            torrent.on('done', () => {
                torrent.files.forEach((file) => {
                    file.getBlob((err, blob) => {
                        if (err) {
                            this.displaySystemMessage('Error saving file: ' + err.message);
                            return;
                        }

                        const safeBlob = new Blob([blob], { type: 'application/octet-stream' });
                        const url = URL.createObjectURL(safeBlob);
                        const a = document.createElement('a');
                        a.href = url;
                        a.download = this.sanitizeDownloadFilename(file.name);
                        document.body.appendChild(a);
                        a.click();
                        document.body.removeChild(a);
                        URL.revokeObjectURL(url);
                    });
                });

                this.updateTransferStatus(transferId, 'complete', 'Download complete!');
                this.displaySystemMessage(`Torrent download complete: "${offer.name}"`);

                setTimeout(() => {
                    try { torrent.destroy(); } catch (e) {}
                    this.p2pActiveTransfers.delete(transferId);
                }, 60000);
            });

            torrent.on('error', (err) => {
                this.updateTransferStatus(transferId, 'error', 'Torrent error: ' + err.message);
            });
        });
    },

    stopSeedingTorrent(offerId) {
        const torrent = this.torrentSeeds.get(offerId);
        if (torrent) {
            try { torrent.destroy(); } catch (e) {}
            this.torrentSeeds.delete(offerId);
        }
    },

    cancelTransfer(transferId) {
        const transfer = this.p2pActiveTransfers.get(transferId);
        if (transfer) {
            if (transfer.isTorrent && transfer.torrent) {
                try { transfer.torrent.destroy(); } catch (e) {}
            }

            const connectionsToDelete = [];
            this.p2pConnections.forEach((pc, connectionId) => {
                if (connectionId.endsWith(transferId)) {
                    try { pc.close(); } catch (e) {}
                    connectionsToDelete.push(connectionId);
                }
            });
            connectionsToDelete.forEach(id => {
                this.p2pConnections.delete(id);
                if (this.p2pDataChannels.has(id)) {
                    try { this.p2pDataChannels.get(id).close(); } catch (e) {}
                    this.p2pDataChannels.delete(id);
                }
            });

            this.p2pActiveTransfers.delete(transferId);
            this.p2pReceivedChunks.delete(transferId);
            this.displaySystemMessage('Transfer canceled');
            this.openP2PTransfersModal();
        }
    },

});
