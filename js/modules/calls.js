// calls.js - P2P audio/video calling for 1:1 PMs and group chats over Nostr signaling

Object.assign(NYM.prototype, {

    _genCallId() {
        return 'call-' + Math.random().toString(36).slice(2) + Date.now().toString(36);
    },

    _nymForPubkey(pubkey) {
        const u = this.users && this.users.get(pubkey);
        if (u && u.nym) return typeof this.parseNymFromDisplay === 'function' ? this.parseNymFromDisplay(u.nym) : u.nym;
        return (pubkey || '').slice(0, 8);
    },

    _refreshCallButtons() {
        const a = document.getElementById('audioCallBtn');
        const v = document.getElementById('videoCallBtn');
        if (!a || !v) return;
        const show = !!(this.inPMMode && (this.currentPM || this.currentGroup));
        a.classList.toggle('nm-call-hidden', !show);
        v.classList.toggle('nm-call-hidden', !show);
    },

    initiateAudioCall() { this.startCall('audio'); },
    initiateVideoCall() { this.startCall('video'); },

    async _getLocalMedia(kind) {
        try {
            const constraints = kind === 'video'
                ? { audio: true, video: { width: { ideal: 1280 }, height: { ideal: 720 }, facingMode: 'user' } }
                : { audio: true, video: false };
            return await navigator.mediaDevices.getUserMedia(constraints);
        } catch (e) {
            this.displaySystemMessage('Could not access ' + (kind === 'video' ? 'camera/microphone' : 'microphone') + ': ' + (e.message || e.name || e));
            return null;
        }
    },

    async startCall(kind) {
        if (!this.connected || !this.pubkey) {
            this.displaySystemMessage('Must be connected to start a call');
            return;
        }
        if (this.activeCall || this.incomingCall) {
            this.displaySystemMessage('Already in a call');
            return;
        }

        let isGroup = false, groupId = null, targets;
        if (this.inPMMode && this.currentPM) {
            targets = [this.currentPM];
        } else if (this.currentGroup) {
            const g = this.groupConversations.get(this.currentGroup);
            if (!g) return;
            isGroup = true;
            groupId = this.currentGroup;
            targets = g.members.filter(pk => pk !== this.pubkey);
            if (!targets.length) {
                this.displaySystemMessage('No one to call in this group');
                return;
            }
        } else {
            return;
        }

        const stream = await this._getLocalMedia(kind);
        if (!stream) return;

        const callId = this._genCallId();
        this.activeCall = {
            callId, kind, isGroup, groupId,
            localStream: stream,
            status: 'outgoing',
            peers: new Map(),
            members: [this.pubkey, ...targets],
            muted: false,
            cameraOff: false,
            startedAt: 0,
            timerInterval: null,
            ringTimeout: null
        };

        this._broadcastCallSignal(targets, { type: 'invite', callId, kind, isGroup, groupId, members: this.activeCall.members });
        this._showCallOverlay();
        this._setCallStatus(isGroup ? 'Ringing group…' : 'Calling…');

        this.activeCall.ringTimeout = setTimeout(() => {
            if (this.activeCall && this.activeCall.callId === callId && this.activeCall.status === 'outgoing') {
                this._broadcastCallSignal(targets, { type: 'cancel', callId });
                this.displaySystemMessage('No answer');
                this._endCall();
            }
        }, 45000);
    },

    async _sendCallSignal(targetPubkey, payload) {
        try {
            const event = {
                kind: this.CALL_SIGNALING_KIND,
                created_at: Math.floor(Date.now() / 1000),
                tags: [['p', targetPubkey]],
                content: JSON.stringify({ ...payload, nym: this.nym }),
                pubkey: this.pubkey
            };
            const signed = await this.signEvent(event);
            this.sendToRelay(['EVENT', signed]);
        } catch (e) {
            console.error('Call signal error:', e);
        }
    },

    _broadcastCallSignal(targets, payload) {
        targets.forEach(t => this._sendCallSignal(t, payload));
    },

    handleCallSignalingEvent(event) {
        const sender = event.pubkey;
        if (sender === this.pubkey) return;
        let data;
        try { data = JSON.parse(event.content); } catch (e) { return; }
        switch (data.type) {
            case 'invite': this._onCallInvite(sender, data, event); break;
            case 'accept': this._onCallAccept(sender, data); break;
            case 'reject': this._onCallReject(sender, data); break;
            case 'cancel': this._onCallCancel(sender, data); break;
            case 'hangup': this._onCallHangup(sender, data); break;
            case 'offer': this._onCallOffer(sender, data); break;
            case 'answer': this._onCallAnswer(sender, data); break;
            case 'ice': this._onCallIce(sender, data); break;
        }
    },

    _getSeenCalls() {
        if (this._seenCalls) return this._seenCalls;
        let map = {};
        try { map = JSON.parse(localStorage.getItem('nym_seen_calls') || '{}') || {}; } catch (_) { map = {}; }
        this._seenCalls = map;
        return map;
    },

    _seenCallsForSync() {
        const map = this._getSeenCalls();
        const ids = Object.keys(map).sort((a, b) => map[b] - map[a]).slice(0, 100);
        const out = {};
        ids.forEach(id => { out[id] = map[id]; });
        return out;
    },

    _hasSeenCall(callId) {
        if (!callId) return false;
        return Object.prototype.hasOwnProperty.call(this._getSeenCalls(), callId);
    },

    _persistSeenCalls(map) {
        const nowSec = Math.floor(Date.now() / 1000);
        const cutoff = nowSec - 3600;
        for (const id in map) { if (map[id] < cutoff) delete map[id]; }
        try { localStorage.setItem('nym_seen_calls', JSON.stringify(map)); } catch (_) { }
    },

    _markCallSeen(callId) {
        if (!callId) return;
        const map = this._getSeenCalls();
        map[callId] = Math.floor(Date.now() / 1000);
        this._persistSeenCalls(map);
        if (typeof this._debouncedNostrSettingsSave === 'function') this._debouncedNostrSettingsSave();
    },

    // Merge a synced seen-call map from another device so a handled call
    // isn't re-rung after a reload elsewhere
    _mergeSeenCalls(incoming) {
        if (!incoming || typeof incoming !== 'object') return;
        const map = this._getSeenCalls();
        const cutoff = Math.floor(Date.now() / 1000) - 3600;
        for (const id in incoming) {
            const ts = incoming[id];
            if (typeof ts !== 'number' || ts < cutoff) continue;
            if (!map[id] || ts > map[id]) map[id] = ts;
        }
        this._persistSeenCalls(map);
    },

    _recordMissedCall(callerPubkey, callerNym, kind, callId, isGroup, groupId) {
        if (!callerPubkey || !callId) return;
        const niceKind = kind === 'video' ? 'video' : 'audio';
        const baseTitle = callerNym || this._nymForPubkey(callerPubkey);
        let body = `Missed ${niceKind} call`;
        if (isGroup && groupId && this.groupConversations) {
            const g = this.groupConversations.get(groupId);
            if (g && g.name) body += ` in ${g.name}`;
        }
        const channelInfo = {
            type: 'call',
            pubkey: callerPubkey,
            callKind: niceKind,
            isGroup: !!isGroup,
            groupId: groupId || null,
            eventId: `missed-call-${callId}`,
            nym: baseTitle
        };
        if (typeof this._addNotificationToHistory === 'function') {
            this._addNotificationToHistory(baseTitle, body, channelInfo, Date.now());
        }
    },

    _onCallInvite(sender, data, event) {
        // Drop replayed/stale invites so a reload doesn't ring on old signaling events
        const createdAt = event && event.created_at ? event.created_at : 0;
        if (createdAt && (Math.floor(Date.now() / 1000) - createdAt) > 60) return;
        if (this._hasSeenCall(data.callId)) return;
        this._markCallSeen(data.callId);

        if (this.activeCall || this.incomingCall) {
            this._sendCallSignal(sender, { type: 'reject', callId: data.callId, reason: 'busy' });
            return;
        }
        const pref = (this.settings && this.settings.acceptCalls) || 'enabled';
        if (pref === 'disabled') return;
        if (pref === 'friends' && !this.isFriend(sender)) return;
        if (this.blockedUsers && this.blockedUsers.has(sender)) return;

        this.incomingCall = {
            callId: data.callId,
            kind: data.kind === 'video' ? 'video' : 'audio',
            isGroup: !!data.isGroup,
            groupId: data.groupId || null,
            from: sender,
            nym: data.nym || this._nymForPubkey(sender),
            members: Array.isArray(data.members) ? data.members : [sender, this.pubkey],
            acceptedPeers: new Set(),
            timeout: null
        };
        this._showIncomingCallUI();
        this._startRingtone();
        this.incomingCall.timeout = setTimeout(() => {
            if (this.incomingCall && this.incomingCall.callId === data.callId) {
                const inc = this.incomingCall;
                this._stopRingtone();
                this._hideIncomingCallUI();
                this.incomingCall = null;
                this.displaySystemMessage('Missed call from ' + inc.nym);
                this._recordMissedCall(inc.from, inc.nym, inc.kind, inc.callId, inc.isGroup, inc.groupId);
            }
        }, 45000);
    },

    async acceptCall() {
        const inc = this.incomingCall;
        if (!inc) return;
        this._stopRingtone();
        if (inc.timeout) clearTimeout(inc.timeout);
        this._hideIncomingCallUI();

        const stream = await this._getLocalMedia(inc.kind);
        if (!stream) {
            this._sendCallSignal(inc.from, { type: 'reject', callId: inc.callId, reason: 'media' });
            this.incomingCall = null;
            return;
        }

        const earlyPeers = Array.from(inc.acceptedPeers || []);
        this.activeCall = {
            callId: inc.callId,
            kind: inc.kind,
            isGroup: inc.isGroup,
            groupId: inc.groupId,
            localStream: stream,
            status: 'connecting',
            peers: new Map(),
            members: inc.members.slice(),
            muted: false,
            cameraOff: false,
            startedAt: 0,
            timerInterval: null,
            ringTimeout: null
        };
        this.incomingCall = null;

        this._showCallOverlay();
        this._setCallStatus('Connecting…');

        const others = this.activeCall.members.filter(pk => pk !== this.pubkey);
        this._broadcastCallSignal(others, { type: 'accept', callId: this.activeCall.callId });

        this._connectToPeer(inc.from);
        earlyPeers.forEach(pk => { if (pk !== this.pubkey && pk !== inc.from) this._connectToPeer(pk); });
    },

    rejectCall() {
        const inc = this.incomingCall;
        if (!inc) return;
        this._stopRingtone();
        if (inc.timeout) clearTimeout(inc.timeout);
        this._hideIncomingCallUI();
        this._sendCallSignal(inc.from, { type: 'reject', callId: inc.callId, reason: 'declined' });
        this.incomingCall = null;
    },

    _onCallAccept(sender, data) {
        if (this.activeCall && this.activeCall.callId === data.callId) {
            if (this.activeCall.status === 'outgoing') {
                this.activeCall.status = 'connecting';
                if (this.activeCall.ringTimeout) clearTimeout(this.activeCall.ringTimeout);
                this._setCallStatus('Connecting…');
            }
            if (!this.activeCall.members.includes(sender)) this.activeCall.members.push(sender);
            this._connectToPeer(sender);
            return;
        }
        if (this.incomingCall && this.incomingCall.callId === data.callId) {
            this.incomingCall.acceptedPeers.add(sender);
        }
    },

    _onCallReject(sender, data) {
        if (!this.activeCall || this.activeCall.callId !== data.callId) return;
        if (!this.activeCall.isGroup) {
            this.displaySystemMessage(data.reason === 'busy' ? 'User is busy' : 'Call declined');
            this._endCall();
        }
    },

    _onCallCancel(sender, data) {
        if (this.incomingCall && this.incomingCall.callId === data.callId) {
            const inc = this.incomingCall;
            this._stopRingtone();
            if (inc.timeout) clearTimeout(inc.timeout);
            this._hideIncomingCallUI();
            this.incomingCall = null;
            this.displaySystemMessage('Missed call from ' + inc.nym);
            this._recordMissedCall(inc.from, inc.nym, inc.kind, inc.callId, inc.isGroup, inc.groupId);
        }
    },

    _onCallHangup(sender, data) {
        if (!this.activeCall || this.activeCall.callId !== data.callId) return;
        this._removePeer(sender);
        if (!this.activeCall.isGroup || this.activeCall.peers.size === 0) {
            this.displaySystemMessage('Call ended');
            this._endCall();
        } else {
            this._renderCallGrid();
        }
    },

    _connectToPeer(peerPubkey) {
        if (!this.activeCall || peerPubkey === this.pubkey) return;
        if (this.activeCall.peers.has(peerPubkey)) return;

        const pc = new RTCPeerConnection({ iceServers: this.p2pIceServers });
        const entry = {
            pc,
            stream: new MediaStream(),
            pendingCandidates: [],
            haveRemote: false,
            nym: this._nymForPubkey(peerPubkey)
        };
        this.activeCall.peers.set(peerPubkey, entry);

        this.activeCall.localStream.getTracks().forEach(t => pc.addTrack(t, this.activeCall.localStream));

        pc.onicecandidate = (e) => {
            if (e.candidate && this.activeCall) {
                this._sendCallSignal(peerPubkey, { type: 'ice', callId: this.activeCall.callId, candidate: e.candidate });
            }
        };
        pc.ontrack = (e) => {
            entry.stream = (e.streams && e.streams[0]) ? e.streams[0] : entry.stream;
            this._renderCallGrid();
        };
        pc.onconnectionstatechange = () => {
            if (pc.connectionState === 'connected') {
                this._onPeerConnected();
            } else if ((pc.connectionState === 'failed' || pc.connectionState === 'closed') && this.activeCall) {
                if (this.activeCall.isGroup) {
                    if (pc.connectionState === 'failed') { this._removePeer(peerPubkey); this._renderCallGrid(); }
                }
            }
        };

        this._renderCallGrid();

        if (this.pubkey < peerPubkey) this._makeOffer(peerPubkey);
    },

    async _makeOffer(peerPubkey) {
        const entry = this.activeCall && this.activeCall.peers.get(peerPubkey);
        if (!entry) return;
        try {
            const offer = await entry.pc.createOffer();
            await entry.pc.setLocalDescription(offer);
            this._sendCallSignal(peerPubkey, { type: 'offer', callId: this.activeCall.callId, sdp: entry.pc.localDescription });
        } catch (e) {
            console.error('Make offer error:', e);
        }
    },

    async _onCallOffer(sender, data) {
        if (!this.activeCall || this.activeCall.callId !== data.callId) return;
        if (!this.activeCall.peers.has(sender)) this._connectToPeer(sender);
        const entry = this.activeCall.peers.get(sender);
        if (!entry) return;
        try {
            await entry.pc.setRemoteDescription(new RTCSessionDescription(data.sdp));
            entry.haveRemote = true;
            await this._flushCandidates(sender);
            const answer = await entry.pc.createAnswer();
            await entry.pc.setLocalDescription(answer);
            this._sendCallSignal(sender, { type: 'answer', callId: this.activeCall.callId, sdp: entry.pc.localDescription });
        } catch (e) {
            console.error('Handle offer error:', e);
        }
    },

    async _onCallAnswer(sender, data) {
        const entry = this.activeCall && this.activeCall.peers.get(sender);
        if (!entry) return;
        if (entry.pc.signalingState === 'stable') return;
        try {
            await entry.pc.setRemoteDescription(new RTCSessionDescription(data.sdp));
            entry.haveRemote = true;
            await this._flushCandidates(sender);
        } catch (e) {
            console.error('Handle answer error:', e);
        }
    },

    async _onCallIce(sender, data) {
        const entry = this.activeCall && this.activeCall.peers.get(sender);
        if (!entry || !data.candidate) return;
        if (entry.haveRemote) {
            try { await entry.pc.addIceCandidate(new RTCIceCandidate(data.candidate)); } catch (e) { /* ignore */ }
        } else {
            entry.pendingCandidates.push(data.candidate);
        }
    },

    async _flushCandidates(peerPubkey) {
        const entry = this.activeCall && this.activeCall.peers.get(peerPubkey);
        if (!entry) return;
        for (const c of entry.pendingCandidates) {
            try { await entry.pc.addIceCandidate(new RTCIceCandidate(c)); } catch (e) { /* ignore */ }
        }
        entry.pendingCandidates = [];
    },

    _removePeer(peerPubkey) {
        if (!this.activeCall) return;
        const entry = this.activeCall.peers.get(peerPubkey);
        if (entry) {
            try { entry.pc.close(); } catch (e) { /* ignore */ }
            this.activeCall.peers.delete(peerPubkey);
        }
    },

    _onPeerConnected() {
        if (!this.activeCall) return;
        if (this.activeCall.status !== 'active') {
            this.activeCall.status = 'active';
            this._startCallTimer();
        }
    },

    hangupCall() {
        if (!this.activeCall) return;
        const targets = this.activeCall.members.filter(pk => pk !== this.pubkey);
        this._broadcastCallSignal(targets, { type: 'hangup', callId: this.activeCall.callId });
        this._endCall();
    },

    _endCall() {
        const ac = this.activeCall;
        if (ac) {
            if (ac.ringTimeout) clearTimeout(ac.ringTimeout);
            if (ac.timerInterval) clearInterval(ac.timerInterval);
            ac.peers.forEach(entry => { try { entry.pc.close(); } catch (e) { /* ignore */ } });
            ac.peers.clear();
            if (ac.localStream) ac.localStream.getTracks().forEach(t => { try { t.stop(); } catch (e) { /* ignore */ } });
        }
        this.activeCall = null;
        this._stopRingtone();
        this._hideCallOverlay();
    },

    toggleCallMute() {
        if (!this.activeCall) return;
        this.activeCall.muted = !this.activeCall.muted;
        this.activeCall.localStream.getAudioTracks().forEach(t => { t.enabled = !this.activeCall.muted; });
        const btn = document.getElementById('callMuteBtn');
        if (btn) {
            btn.classList.toggle('active', this.activeCall.muted);
            btn.title = this.activeCall.muted ? 'Unmute microphone' : 'Mute microphone';
        }
    },

    toggleCallVideo() {
        if (!this.activeCall || this.activeCall.kind !== 'video') return;
        this.activeCall.cameraOff = !this.activeCall.cameraOff;
        this.activeCall.localStream.getVideoTracks().forEach(t => { t.enabled = !this.activeCall.cameraOff; });
        const btn = document.getElementById('callVideoBtn');
        if (btn) {
            btn.classList.toggle('active', this.activeCall.cameraOff);
            btn.title = this.activeCall.cameraOff ? 'Turn on camera' : 'Turn off camera';
        }
        this._renderCallGrid();
    },

    _callTitleText() {
        if (!this.activeCall) return '';
        if (this.activeCall.isGroup) {
            const g = this.activeCall.groupId && this.groupConversations.get(this.activeCall.groupId);
            return g ? g.name : 'Group call';
        }
        const peer = this.activeCall.members.find(pk => pk !== this.pubkey);
        return this._nymForPubkey(peer);
    },

    _showCallOverlay() {
        const ov = document.getElementById('callOverlay');
        if (!ov || !this.activeCall) return;
        ov.classList.add('active');
        const title = document.getElementById('callTitle');
        if (title) title.textContent = (this.activeCall.kind === 'video' ? 'Video call · ' : 'Audio call · ') + this._callTitleText();
        const videoBtn = document.getElementById('callVideoBtn');
        if (videoBtn) videoBtn.classList.toggle('nm-call-hidden', this.activeCall.kind !== 'video');
        const muteBtn = document.getElementById('callMuteBtn');
        if (muteBtn) { muteBtn.classList.remove('active'); muteBtn.title = 'Mute microphone'; }
        this._renderCallGrid();
    },

    _hideCallOverlay() {
        const ov = document.getElementById('callOverlay');
        if (ov) ov.classList.remove('active');
        const grid = document.getElementById('callGrid');
        if (grid) grid.innerHTML = '';
    },

    _renderCallGrid() {
        const grid = document.getElementById('callGrid');
        if (!grid || !this.activeCall) return;

        const desired = new Set(['local']);
        this.activeCall.peers.forEach((_e, pk) => desired.add('pk-' + this._safePubkey(pk)));
        Array.from(grid.children).forEach(ch => { if (!desired.has(ch.dataset.tile)) grid.removeChild(ch); });

        this._ensureTile('local', 'You', this.activeCall.localStream, true, this.pubkey);
        this.activeCall.peers.forEach((entry, pk) => {
            this._ensureTile('pk-' + this._safePubkey(pk), entry.nym, entry.stream, false, pk);
        });

        grid.dataset.count = String(grid.children.length);
    },

    _ensureTile(id, label, stream, isLocal, pubkey) {
        const grid = document.getElementById('callGrid');
        if (!grid) return;
        let tile = grid.querySelector(`[data-tile="${id}"]`);
        if (!tile) {
            tile = document.createElement('div');
            tile.className = 'call-tile';
            tile.dataset.tile = id;
            const video = document.createElement('video');
            video.autoplay = true;
            video.playsInline = true;
            if (isLocal) video.muted = true;
            const av = document.createElement('img');
            av.className = 'call-tile-avatar';
            av.alt = '';
            const name = document.createElement('div');
            name.className = 'call-tile-name';
            tile.appendChild(video);
            tile.appendChild(av);
            tile.appendChild(name);
            grid.appendChild(tile);
        }
        const video = tile.querySelector('video');
        if (video.srcObject !== stream) video.srcObject = stream || null;
        const av = tile.querySelector('.call-tile-avatar');
        av.src = this.getAvatarUrl(pubkey);
        tile.querySelector('.call-tile-name').textContent = label || '';

        const hasVideo = this.activeCall.kind === 'video'
            && stream && stream.getVideoTracks().length > 0
            && !(isLocal && this.activeCall.cameraOff);
        tile.classList.toggle('no-video', !hasVideo);
    },

    _showIncomingCallUI() {
        const inc = this.incomingCall;
        if (!inc) return;
        const name = document.getElementById('incomingCallName');
        if (name) name.textContent = inc.nym || 'Someone';
        const sub = document.getElementById('incomingCallSub');
        if (sub) sub.textContent = `Incoming ${inc.kind === 'video' ? 'video' : 'audio'} call${inc.isGroup ? ' (group)' : ''}`;
        const av = document.getElementById('incomingCallAvatar');
        if (av) av.src = this.getAvatarUrl(inc.from);
        const modal = document.getElementById('incomingCallModal');
        if (modal) modal.classList.add('active');
    },

    _hideIncomingCallUI() {
        const modal = document.getElementById('incomingCallModal');
        if (modal) modal.classList.remove('active');
    },

    _startRingtone() {
        try {
            this._ringCtx = new (window.AudioContext || window.webkitAudioContext)();
            const ctx = this._ringCtx;
            const playBeep = () => {
                if (!this._ringCtx) return;
                const o = ctx.createOscillator();
                const g = ctx.createGain();
                o.connect(g);
                g.connect(ctx.destination);
                o.frequency.value = 480;
                g.gain.value = 0.07;
                o.start();
                o.stop(ctx.currentTime + 0.4);
            };
            playBeep();
            this._ringInterval = setInterval(playBeep, 2000);
        } catch (e) { /* ignore */ }
    },

    _stopRingtone() {
        if (this._ringInterval) { clearInterval(this._ringInterval); this._ringInterval = null; }
        if (this._ringCtx) { try { this._ringCtx.close(); } catch (e) { /* ignore */ } this._ringCtx = null; }
    },

    _startCallTimer() {
        if (!this.activeCall) return;
        this.activeCall.startedAt = Date.now();
        if (this.activeCall.timerInterval) clearInterval(this.activeCall.timerInterval);
        this.activeCall.timerInterval = setInterval(() => this._setCallStatus(this._callTimerText()), 1000);
        this._setCallStatus(this._callTimerText());
    },

    _callTimerText() {
        if (!this.activeCall || !this.activeCall.startedAt) return 'Connecting…';
        const s = Math.floor((Date.now() - this.activeCall.startedAt) / 1000);
        const m = Math.floor(s / 60);
        return `${m}:${String(s % 60).padStart(2, '0')}`;
    },

    _setCallStatus(t) {
        const el = document.getElementById('callStatus');
        if (el) el.textContent = t;
    },

});
