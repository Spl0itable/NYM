// p2p.js - Peer-to-peer file sharing: WebRTC data channels, WebTorrent, transfers UI

Object.assign(NYM.prototype, {

    // Handle incoming P2P signaling events
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

    // Handle P2P file status events (e.g., unseeded notifications)
    handleP2PFileStatusEvent(event) {
        try {
            const data = JSON.parse(event.content);
            if (data.status === 'unseeded' && data.offerId) {
                this.p2pUnseededOffers.add(data.offerId);
                // Update UI to show file is no longer available
                this.updateFileOfferUI(data.offerId, 'unseeded');
            }
        } catch (e) {
            // Try tag-based approach
            const offerIdTag = event.tags.find(t => t[0] === 'offer_id');
            const statusTag = event.tags.find(t => t[0] === 'status');
            if (offerIdTag && statusTag && statusTag[1] === 'unseeded') {
                this.p2pUnseededOffers.add(offerIdTag[1]);
                this.updateFileOfferUI(offerIdTag[1], 'unseeded');
            }
        }
    },

    // Share a file via P2P
    async shareP2PFile(file) {
        if (!this.connected || !this.pubkey) {
            this.displaySystemMessage('Must be connected to share files');
            return;
        }

        // Compute file hash for identification
        const arrayBuffer = await file.arrayBuffer();
        const hashBuffer = await crypto.subtle.digest('SHA-256', arrayBuffer);
        const hashArray = Array.from(new Uint8Array(hashBuffer));
        const fileHash = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');

        // Create unique offer ID
        const offerId = fileHash.substring(0, 16) + '-' + Date.now().toString(36);

        // Store file for seeding
        this.p2pPendingFiles.set(offerId, file);

        // Create file offer metadata
        const fileOffer = {
            offerId: offerId,
            name: file.name,
            size: file.size,
            type: file.type || 'application/octet-stream',
            hash: fileHash,
            seederPubkey: this.pubkey,
            timestamp: Math.floor(Date.now() / 1000)
        };

        // Store offer locally
        this.p2pFileOffers.set(offerId, fileOffer);

        // Determine channel info and kind for the offer event
        let tags = [
            ['n', this.nym],
            ['offer', JSON.stringify(fileOffer)]
        ];

        let kind;

        const now = Math.floor(Date.now() / 1000);

        if (this.currentGeohash) {
            kind = 20000; // Geohash channel kind
            tags.push(['g', this.currentGeohash]);
        } else {
            this.displaySystemMessage('No channel selected for file sharing');
            return;
        }

        // Create and sign the file offer event
        const event = {
            kind: kind,
            created_at: now,
            tags: tags,
            content: `Sharing file through Nymchat: ${file.name} (${this.formatFileSize(file.size)})`,
            pubkey: this.pubkey
        };

        const signedEvent = await this.signEvent(event);

        // Create optimistic message for immediate display
        const optimisticMessage = {
            id: signedEvent.id,
            author: this.nym,
            pubkey: this.pubkey,
            content: event.content,
            created_at: event.created_at,
            _seq: ++this._msgSeq,
            timestamp: new Date(event.created_at * 1000),
            channel: this.currentChannel,
            geohash: this.currentGeohash || '',
            isOwn: true,
            isHistorical: false,
            isFileOffer: true,
            fileOffer: fileOffer
        };

        // Display locally immediately
        this.displayMessage(optimisticMessage);

        // Broadcast to relays
        this.sendToRelay(['EVENT', signedEvent]);

        this.displaySystemMessage(`File "${file.name}" is now available for P2P download`);
    },

    // Format file size for display
    formatFileSize(bytes) {
        if (bytes < 1024) return bytes + ' B';
        if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
        if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
        return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
    },

    // Get file type category for icon styling
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

    // Request a file from a seeder
    async requestP2PFile(offerId) {
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

        // Update UI to show connecting
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

        // Create transfer state
        const transferId = offerId + '-' + Date.now().toString(36);
        this.p2pActiveTransfers.set(transferId, {
            offerId: offerId,
            offer: offer,
            status: 'connecting',
            bytesReceived: 0,
            startTime: Date.now()
        });
        this.p2pReceivedChunks.set(transferId, []);

        // Create WebRTC connection
        await this.createP2PConnection(offer.seederPubkey, transferId, true);
    },

    // Create a WebRTC peer connection
    async createP2PConnection(peerPubkey, transferId, isInitiator) {
        const connectionId = peerPubkey + '-' + transferId;

        // Create new RTCPeerConnection
        const pc = new RTCPeerConnection({
            iceServers: this.p2pIceServers
        });

        this.p2pConnections.set(connectionId, pc);

        // Trickle ICE candidates to the peer
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
                // Give it a moment to recover before declaring error
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

        // Connection timeout - 30 seconds to establish
        const connectionTimeout = setTimeout(() => {
            const transfer = this.p2pActiveTransfers.get(transferId);
            if (transfer && transfer.status === 'connecting') {
                this.updateTransferStatus(transferId, 'error', 'Connection timed out - peer may be offline');
                this.cleanupP2PConnection(connectionId, transferId);
            }
        }, 30000);

        // Clear timeout when connected
        const origOnIceChange = pc.oniceconnectionstatechange;
        pc.oniceconnectionstatechange = (e) => {
            if (pc.iceConnectionState === 'connected' || pc.iceConnectionState === 'completed') {
                clearTimeout(connectionTimeout);
            }
            origOnIceChange.call(this, e);
        };

        if (isInitiator) {
            // Create data channel for receiving file
            const dc = pc.createDataChannel('fileTransfer', {
                ordered: true
            });
            this.setupDataChannel(dc, transferId, false);
            this.p2pDataChannels.set(connectionId, dc);

            // Create and send offer
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
            // Wait for data channel from peer
            pc.ondatachannel = (event) => {
                const dc = event.channel;
                this.setupDataChannel(dc, transferId, true);
                this.p2pDataChannels.set(connectionId, dc);
            };
        }

        return pc;
    },

    // Cleanup a P2P connection and associated resources
    cleanupP2PConnection(connectionId, transferId) {
        const pc = this.p2pConnections.get(connectionId);
        if (pc) {
            try { pc.close(); } catch (e) { /* ignore */ }
            this.p2pConnections.delete(connectionId);
        }
        const dc = this.p2pDataChannels.get(connectionId);
        if (dc) {
            try { dc.close(); } catch (e) { /* ignore */ }
            this.p2pDataChannels.delete(connectionId);
        }
    },

    // Setup data channel handlers
    setupDataChannel(dc, transferId, isSender) {
        dc.binaryType = 'arraybuffer';

        dc.onopen = () => {
            if (isSender) {
                // Start sending file
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
            // Check if transfer completed
            const transfer = this.p2pActiveTransfers.get(transferId);
            if (transfer && transfer.status !== 'complete' && transfer.status !== 'error') {
                this.updateTransferStatus(transferId, 'error', 'Connection closed');
            }
        };
    },

    // Start sending file chunks
    async startSendingFile(transferId, dataChannel) {
        const transfer = this.p2pActiveTransfers.get(transferId);
        if (!transfer) return;

        const file = this.p2pPendingFiles.get(transfer.offerId);
        if (!file) {
            try {
                dataChannel.send(JSON.stringify({ type: 'error', message: 'File no longer available' }));
            } catch (e) { /* channel may be closed */ }
            this.updateTransferStatus(transferId, 'error', 'File no longer available');
            return;
        }

        // Send file metadata first as JSON string
        dataChannel.send(JSON.stringify({
            type: 'metadata',
            name: file.name,
            size: file.size,
            mimeType: file.type
        }));

        // Small delay to ensure metadata is received before binary data
        await new Promise(resolve => setTimeout(resolve, 50));

        // Read and send file in chunks
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
                // Small delay to ensure all data chunks are flushed before sending complete
                await new Promise(resolve => setTimeout(resolve, 100));
                try {
                    dataChannel.send(JSON.stringify({ type: 'complete' }));
                } catch (e) { /* ignore */ }
                transfer.status = 'complete';
                return;
            }

            const chunk = file.slice(offset, offset + chunkSize);
            const arrayBuffer = await chunk.arrayBuffer();

            // Apply backpressure: only wait when the queue is actually full.
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

                // Continue sending without an artificial setTimeout(0) hop
                // when the channel has headroom — keeps throughput high.
                if (dataChannel.bufferedAmount < HIGH_WATER) {
                    Promise.resolve().then(sendNextChunk);
                } else {
                    setTimeout(sendNextChunk, 0);
                }
            }
        };

        sendNextChunk();
    },

    // Handle received file chunk
    handleFileChunk(transferId, data) {
        const transfer = this.p2pActiveTransfers.get(transferId);
        if (!transfer) return;

        // Handle JSON string messages (metadata, complete, error)
        if (typeof data === 'string') {
            try {
                const msg = JSON.parse(data);

                if (msg.type === 'metadata') {
                    transfer.metadata = msg;
                    return;
                } else if (msg.type === 'complete') {
                    this.completeFileTransfer(transferId);
                    return;
                } else if (msg.type === 'error') {
                    this.updateTransferStatus(transferId, 'error', msg.message);
                    return;
                }
            } catch (e) {
                // Not JSON, ignore
            }
            return;
        }

        // Binary chunk (ArrayBuffer)
        if (data instanceof ArrayBuffer) {
            const chunks = this.p2pReceivedChunks.get(transferId);
            if (chunks) {
                chunks.push(data);
                transfer.bytesReceived += data.byteLength;

                // Update progress
                if (transfer.offer) {
                    const progress = Math.min(100, (transfer.bytesReceived / transfer.offer.size) * 100);
                    this.updateTransferProgress(transferId, progress);
                }
            }
        }
    },

    // Complete file transfer and trigger download
    completeFileTransfer(transferId) {
        const transfer = this.p2pActiveTransfers.get(transferId);
        const chunks = this.p2pReceivedChunks.get(transferId);

        if (!transfer || !chunks) return;

        // Combine chunks into blob
        const blob = new Blob(chunks, {
            type: transfer.metadata?.mimeType || transfer.offer?.type || 'application/octet-stream'
        });

        // Create download link
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = transfer.metadata?.name || transfer.offer?.name || 'download';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);

        // Update status
        this.updateTransferStatus(transferId, 'complete', 'Download complete!');

        // Cleanup
        this.p2pReceivedChunks.delete(transferId);

        this.displaySystemMessage(`File "${transfer.offer?.name || 'file'}" downloaded successfully`);
    },

    // Update transfer progress UI
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

    // Update transfer status
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

    // Send P2P signaling message via Nostr
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

    // Handle incoming SDP offer
    async handleP2POffer(senderPubkey, data) {
        const { sdp, transferId, offerId } = data;

        // Check if we have this file to offer
        if (!this.p2pPendingFiles.has(offerId)) {
            return; // We don't have this file
        }

        // Create transfer state for sending
        this.p2pActiveTransfers.set(transferId, {
            offerId: offerId,
            offer: this.p2pFileOffers.get(offerId),
            status: 'connecting',
            bytesSent: 0,
            startTime: Date.now()
        });

        // Create peer connection and set remote description
        const pc = await this.createP2PConnection(senderPubkey, transferId, false);
        await pc.setRemoteDescription(new RTCSessionDescription(sdp));

        // Create and send answer
        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);

        this.sendP2PSignal(senderPubkey, {
            type: 'answer',
            sdp: pc.localDescription,
            transferId: transferId
        });
    },

    // Handle incoming SDP answer
    async handleP2PAnswer(senderPubkey, data) {
        const { sdp, transferId } = data;
        const connectionId = senderPubkey + '-' + transferId;

        const pc = this.p2pConnections.get(connectionId);
        if (pc) {
            await pc.setRemoteDescription(new RTCSessionDescription(sdp));
        }
    },

    // Handle incoming ICE candidate
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

    // Open P2P transfers modal
    openP2PTransfersModal() {
        const modal = document.getElementById('p2pTransfersModal');
        const list = document.getElementById('p2pTransfersList');

        if (!modal || !list) return;

        // Build transfer list
        list.innerHTML = '';

        if (this.p2pActiveTransfers.size === 0 && this.p2pPendingFiles.size === 0) {
            list.innerHTML = '<div class="p2p-empty-state">No active transfers</div>';
        } else {
            const fragment = document.createDocumentFragment();

            // Show seeding files
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
                                <button class="p2p-transfer-btn cancel" onclick="nym.stopSeeding('${offerId}')">Stop</button>
                            </div>
                        </div>
                    `;
                    fragment.appendChild(item);
                }
            });

            // Show active transfers
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
                            <div class="p2p-transfer-progress-fill" style="width: ${progress.toFixed(1)}%"></div>
                        </div>
                        <div class="p2p-transfer-status">
                            <span class="p2p-transfer-status-text ${transfer.status}">${transfer.status}</span>
                            <div class="p2p-transfer-actions">
                                <button class="p2p-transfer-btn cancel" onclick="nym.cancelTransfer('${transferId}')">Cancel</button>
                            </div>
                        </div>
                    `;
                    fragment.appendChild(item);
                }
            });

            list.appendChild(fragment);
        }

        modal.classList.add('active');
    },

    // Stop seeding a file and broadcast unseeded event
    async stopSeeding(offerId) {
        const offer = this.p2pFileOffers.get(offerId);
        this.p2pPendingFiles.delete(offerId);
        this.p2pUnseededOffers.add(offerId);

        // Stop torrent seeding if applicable
        this.stopSeedingTorrent(offerId);

        // Close any active transfer connections for this offer
        const transfersToCancel = [];
        this.p2pActiveTransfers.forEach((transfer, transferId) => {
            if (transfer.offerId === offerId) {
                transfersToCancel.push(transferId);
            }
        });
        transfersToCancel.forEach(transferId => this.cancelTransfer(transferId));

        // Broadcast unseeded event via Nostr so peers know the file is no longer available
        if (offer && this.pubkey) {
            try {
                let tags = [
                    ['offer_id', offerId],
                    ['status', 'unseeded']
                ];
                if (offer.hash) tags.push(['x', offer.hash]);
                if (this.currentGeohash) tags.push(['g', this.currentGeohash]);

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

        // Update any visible file offer UI to show unseeded status
        this.updateFileOfferUI(offerId, 'unseeded');

        this.displaySystemMessage('Stopped seeding file' + (offer ? `: ${offer.name}` : ''));
        this.openP2PTransfersModal(); // Refresh modal
    },

    // Update file offer UI element to reflect current status
    updateFileOfferUI(offerId, status) {
        const offerEl = document.querySelector(`[data-offer-id="${offerId}"]`);
        if (!offerEl) return;

        if (status === 'unseeded') {
            // Update the seeding indicator or download button to show unavailable
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

    // Initialize WebTorrent client (lazy)
    getTorrentClient() {
        if (!this.torrentClient && typeof WebTorrent !== 'undefined') {
            this.torrentClient = new WebTorrent();
            this.torrentClient.on('error', (err) => {
                console.error('WebTorrent error:', err);
            });
        }
        return this.torrentClient;
    },

    // Share a file via WebTorrent (creates a torrent and seeds it)
    // Handle torrent file sharing - either a .torrent file or seed via WebTorrent
    async shareP2PFileTorrent(file) {
        if (!this.connected || !this.pubkey) {
            this.displaySystemMessage('Must be connected to share files');
            return;
        }

        const client = this.getTorrentClient();
        if (!client) {
            this.displaySystemMessage('WebTorrent is not available. Falling back to direct P2P.');
            return this.shareP2PFile(file);
        }

        if (!this.currentGeohash) {
            this.displaySystemMessage('No channel selected for file sharing');
            return;
        }

        const isTorrentFile = file.name.endsWith('.torrent') || file.type === 'application/x-bittorrent';

        if (isTorrentFile) {
            // User selected a .torrent file - read it and add to client
            this.displaySystemMessage(`Loading torrent file "${file.name}"...`);
            const torrentBuffer = await file.arrayBuffer();

            client.add(new Uint8Array(torrentBuffer), (torrent) => {
                this.onTorrentReady(torrent, file.name);
            });
        } else {
            // Regular file - create a new torrent and seed it
            this.displaySystemMessage(`Creating torrent for "${file.name}"...`);
            client.seed(file, { announceList: [] }, (torrent) => {
                this.onTorrentReady(torrent, null);
            });
        }
    },

    // Common handler once a torrent is ready (seeded or loaded from .torrent)
    onTorrentReady(torrent, originalTorrentFileName) {
        // Use the first file in the torrent for display info
        const torrentFile = torrent.files[0];
        const displayName = torrentFile ? torrentFile.name : (originalTorrentFileName || 'Unknown');
        const displaySize = torrent.length || 0;

        const offerId = torrent.infoHash.substring(0, 16) + '-' + Date.now().toString(36);

        // Store torrent reference
        this.torrentSeeds.set(offerId, torrent);

        // Store a placeholder in pending files for the transfers modal
        const placeholderFile = new File([], displayName, { type: 'application/x-bittorrent' });
        this.p2pPendingFiles.set(offerId, placeholderFile);

        // Create file offer metadata with magnet URI
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

        // Store offer locally
        this.p2pFileOffers.set(offerId, fileOffer);

        // Build tags for the Nostr event
        const now = Math.floor(Date.now() / 1000);
        const tags = [
            ['n', this.nym],
            ['offer', JSON.stringify(fileOffer)],
            ['g', this.currentGeohash]
        ];

        // Create and broadcast the file offer event
        const event = {
            kind: 20000,
            created_at: now,
            tags: tags,
            content: `Sharing file via torrent: ${displayName} (${this.formatFileSize(displaySize)})`,
            pubkey: this.pubkey
        };

        this.signEvent(event).then(signedEvent => {
            const optimisticMessage = {
                id: signedEvent.id,
                author: this.nym,
                pubkey: this.pubkey,
                content: event.content,
                created_at: event.created_at,
                _seq: ++this._msgSeq,
                timestamp: new Date(event.created_at * 1000),
                channel: this.currentChannel,
                geohash: this.currentGeohash || '',
                isOwn: true,
                isHistorical: false,
                isFileOffer: true,
                fileOffer: fileOffer
            };

            this.displayMessage(optimisticMessage);
            this.sendToRelay(['EVENT', signedEvent]);
            this.displaySystemMessage(`Seeding torrent: "${displayName}"`);
        });
    },

    // Download a file via WebTorrent
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

        const client = this.getTorrentClient();
        if (!client) {
            this.displaySystemMessage('WebTorrent is not available in this browser');
            return;
        }

        // Update UI
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

        // Check if already downloading this torrent
        const existingTorrent = client.get(offer.infoHash || offer.magnetURI);
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

        client.add(offer.magnetURI, (torrent) => {
            const transfer = this.p2pActiveTransfers.get(transferId);
            if (!transfer) return; // Was cancelled

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
                // Download complete - save each file
                torrent.files.forEach((file) => {
                    file.getBlob((err, blob) => {
                        if (err) {
                            this.displaySystemMessage('Error saving file: ' + err.message);
                            return;
                        }

                        const url = URL.createObjectURL(blob);
                        const a = document.createElement('a');
                        a.href = url;
                        a.download = file.name;
                        document.body.appendChild(a);
                        a.click();
                        document.body.removeChild(a);
                        URL.revokeObjectURL(url);
                    });
                });

                this.updateTransferStatus(transferId, 'complete', 'Download complete!');
                this.displaySystemMessage(`Torrent download complete: "${offer.name}"`);

                // Keep seeding for a bit, then remove
                setTimeout(() => {
                    try { torrent.destroy(); } catch (e) { /* ignore */ }
                    this.p2pActiveTransfers.delete(transferId);
                }, 60000);
            });

            torrent.on('error', (err) => {
                this.updateTransferStatus(transferId, 'error', 'Torrent error: ' + err.message);
            });
        });
    },

    // Stop seeding a torrent
    stopSeedingTorrent(offerId) {
        const torrent = this.torrentSeeds.get(offerId);
        if (torrent) {
            try { torrent.destroy(); } catch (e) { /* ignore */ }
            this.torrentSeeds.delete(offerId);
        }
    },

    // Cancel an active transfer
    cancelTransfer(transferId) {
        const transfer = this.p2pActiveTransfers.get(transferId);
        if (transfer) {
            // If it's a torrent transfer, destroy the torrent
            if (transfer.isTorrent && transfer.torrent) {
                try { transfer.torrent.destroy(); } catch (e) { /* ignore */ }
            }

            // Close any associated WebRTC connections and data channels
            const connectionsToDelete = [];
            this.p2pConnections.forEach((pc, connectionId) => {
                if (connectionId.endsWith(transferId)) {
                    try { pc.close(); } catch (e) { /* ignore */ }
                    connectionsToDelete.push(connectionId);
                }
            });
            connectionsToDelete.forEach(id => {
                this.p2pConnections.delete(id);
                if (this.p2pDataChannels.has(id)) {
                    try { this.p2pDataChannels.get(id).close(); } catch (e) { /* ignore */ }
                    this.p2pDataChannels.delete(id);
                }
            });

            this.p2pActiveTransfers.delete(transferId);
            this.p2pReceivedChunks.delete(transferId);
            this.displaySystemMessage('Transfer cancelled');
            this.openP2PTransfersModal(); // Refresh modal
        }
    },

});
