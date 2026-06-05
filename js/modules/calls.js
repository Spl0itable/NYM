// calls.js - P2P audio/video calling for 1:1 PMs and group chats over NIP-17 gift-wrapped signaling

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
        this._initCallExtras(this.activeCall);

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
        if (!this._canSendGiftWraps()) {
            console.error('Call signal error: gift-wrap signing unavailable');
            return;
        }
        try {
            const rumor = {
                kind: this.CALL_SIGNALING_KIND,
                created_at: Math.floor(Date.now() / 1000),
                tags: [['p', targetPubkey]],
                content: JSON.stringify({ ...payload, nym: this.nym }),
                pubkey: this.pubkey
            };
            await this._sendGiftWrapsAsync([targetPubkey], rumor, null);
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
            case 'share': this._onCallShare(sender, data); break;
            case 'present-state': this._onPresentState(sender, data); break;
            case 'present-request': this._onPresentRequest(sender, data); break;
            case 'reaction': this._onCallReaction(sender, data); break;
            case 'chat': this._onCallChat(sender, data); break;
        }
    },

    // Records persist 24h to match the notification window so a call answered or
    // missed in the last day isn't re-surfaced on reopen.
    _CALL_SEEN_TTL_SEC: 86400,
    // Higher rank wins on merge so a resolution (answered) isn't lost to a weaker
    // status (pending) synced from another device.
    _CALL_STATUS_RANK: { seen: 0, pending: 1, missed: 2, declined: 3, answered: 4 },

    _getSeenCalls() {
        if (this._seenCalls) return this._seenCalls;
        let map = {};
        try { map = JSON.parse(localStorage.getItem('nym_seen_calls') || '{}') || {}; } catch (_) { map = {}; }
        this._seenCalls = map;
        return map;
    },

    // Normalize a stored value (legacy number or {t,s}) to {t,s} or null
    _normCallRecord(v) {
        if (typeof v === 'number') return { t: v, s: 'seen' };
        if (v && typeof v === 'object' && typeof v.t === 'number') return { t: v.t, s: v.s || 'seen' };
        return null;
    },

    _seenCallsForSync() {
        const map = this._getSeenCalls();
        const ids = Object.keys(map).sort((a, b) => {
            const ra = this._normCallRecord(map[a]), rb = this._normCallRecord(map[b]);
            return (rb ? rb.t : 0) - (ra ? ra.t : 0);
        }).slice(0, 100);
        const out = {};
        ids.forEach(id => { const r = this._normCallRecord(map[id]); if (r) out[id] = r; });
        return out;
    },

    _hasSeenCall(callId) {
        if (!callId) return false;
        return Object.prototype.hasOwnProperty.call(this._getSeenCalls(), callId);
    },

    _callStatus(callId) {
        const r = this._normCallRecord(this._getSeenCalls()[callId]);
        return r ? r.s : null;
    },

    _persistSeenCalls(map) {
        const cutoff = Math.floor(Date.now() / 1000) - this._CALL_SEEN_TTL_SEC;
        for (const id in map) {
            const r = this._normCallRecord(map[id]);
            if (!r || r.t < cutoff) delete map[id];
        }
        try { localStorage.setItem('nym_seen_calls', JSON.stringify(map)); } catch (_) { }
    },

    _markCallSeen(callId, status) {
        if (!callId) return;
        const map = this._getSeenCalls();
        const rank = this._CALL_STATUS_RANK;
        const next = status || 'pending';
        const existing = this._normCallRecord(map[callId]);
        const keep = existing && (rank[existing.s] || 0) > (rank[next] || 0) ? existing.s : next;
        map[callId] = { t: Math.floor(Date.now() / 1000), s: keep };
        this._persistSeenCalls(map);
        if (typeof this._debouncedNostrSettingsSave === 'function') this._debouncedNostrSettingsSave();
    },

    // Merge a synced seen-call map from another device so a call handled or
    // answered elsewhere isn't re-rung or shown as missed after a reload here.
    _mergeSeenCalls(incoming) {
        if (!incoming || typeof incoming !== 'object') return;
        const map = this._getSeenCalls();
        const cutoff = Math.floor(Date.now() / 1000) - this._CALL_SEEN_TTL_SEC;
        const rank = this._CALL_STATUS_RANK;
        const nowAnswered = [];
        for (const id in incoming) {
            const r = this._normCallRecord(incoming[id]);
            if (!r || r.t < cutoff) continue;
            const cur = this._normCallRecord(map[id]);
            if (!cur) {
                map[id] = { t: r.t, s: r.s };
                if (r.s === 'answered') nowAnswered.push(id);
                continue;
            }
            const s = (rank[r.s] || 0) > (rank[cur.s] || 0) ? r.s : cur.s;
            map[id] = { t: Math.max(cur.t, r.t), s };
            if (s === 'answered' && cur.s !== 'answered') nowAnswered.push(id);
        }
        this._persistSeenCalls(map);
        // A call answered elsewhere retracts any missed-call we already surfaced
        if (nowAnswered.length && typeof this._retractMissedCallNotification === 'function') {
            nowAnswered.forEach(id => this._retractMissedCallNotification(id));
        }
    },

    _recordMissedCall(callerPubkey, callerNym, kind, callId, isGroup, groupId, whenMs) {
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
            this._addNotificationToHistory(baseTitle, body, channelInfo, whenMs || Date.now());
        }
    },

    _onCallInvite(sender, data, event) {
        // Skip calls already handled here or answered/seen on another device
        if (this._hasSeenCall(data.callId)) return;

        // Honor accept prefs/blocks for ringing and missed-call records alike
        const pref = (this.settings && this.settings.acceptCalls) || 'enabled';
        if (pref === 'disabled') return;
        if (pref === 'friends' && !this.isFriend(sender)) return;
        if (this.blockedUsers && this.blockedUsers.has(sender)) return;

        // A stale invite can't be answered (e.g. it arrived while the app was
        // closed). Within the seen-call window, log it as a missed call so it
        // surfaces in notifications on reopen rather than being dropped silently.
        const createdAt = event && event.created_at ? event.created_at : 0;
        const ageSec = createdAt ? (Math.floor(Date.now() / 1000) - createdAt) : 0;
        if (ageSec > 60) {
            if (ageSec <= this._CALL_SEEN_TTL_SEC) {
                this._markCallSeen(data.callId, 'missed');
                this._recordMissedCall(sender, data.nym, data.kind, data.callId, data.isGroup, data.groupId, createdAt * 1000);
            }
            return;
        }
        this._markCallSeen(data.callId, 'pending');

        if (this.activeCall || this.incomingCall) {
            this._markCallSeen(data.callId, 'missed');
            this._sendCallSignal(sender, { type: 'reject', callId: data.callId, reason: 'busy' });
            return;
        }

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
                this._markCallSeen(inc.callId, 'missed');
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
        this._markCallSeen(inc.callId, 'answered');
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
        this._initCallExtras(this.activeCall);
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
        this._markCallSeen(inc.callId, 'declined');
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
            this._markCallSeen(inc.callId, 'missed');
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
            videoSender: null,
            nym: this._nymForPubkey(peerPubkey)
        };
        this.activeCall.peers.set(peerPubkey, entry);

        this.activeCall.localStream.getTracks().forEach(t => {
            const sender = pc.addTrack(t, this.activeCall.localStream);
            if (t.kind === 'video') entry.videoSender = sender;
        });
        if (this.activeCall.sharing && this.activeCall.screenStream && entry.videoSender) {
            const st = this.activeCall.screenStream.getVideoTracks()[0];
            if (st) { try { entry.videoSender.replaceTrack(st); } catch (e) { /* ignore */ } }
            this._sendCallSignal(peerPubkey, { type: 'share', callId: this.activeCall.callId, on: true });
        }
        if (this._isCallMod() && (this.activeCall.shareRestricted || this.activeCall.presenter)) {
            this._sendCallSignal(peerPubkey, { type: 'present-state', callId: this.activeCall.callId, restricted: !!this.activeCall.shareRestricted, presenter: this.activeCall.presenter || null });
        }

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
            if (ac.screenStream) ac.screenStream.getTracks().forEach(t => { try { t.stop(); } catch (e) { /* ignore */ } });
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
        const chatMsgs = document.getElementById('callChatMessages');
        if (chatMsgs) chatMsgs.innerHTML = '';
        ['callChatPanel', 'callReactionsBar', 'callPresenterMenu'].forEach(id => {
            const el = document.getElementById(id); if (el) el.classList.remove('active');
        });
        this._updateCallControls();
        this._renderCallGrid();
    },

    _hideCallOverlay() {
        const ov = document.getElementById('callOverlay');
        if (ov) ov.classList.remove('active');
        const grid = document.getElementById('callGrid');
        if (grid) grid.innerHTML = '';
        ['callChatPanel', 'callReactionsBar', 'callPresenterMenu'].forEach(id => {
            const el = document.getElementById(id); if (el) el.classList.remove('active');
        });
        const fly = document.getElementById('callReactionsFly');
        if (fly) fly.innerHTML = '';
    },

    _renderCallGrid() {
        const grid = document.getElementById('callGrid');
        if (!grid || !this.activeCall) return;

        const desired = new Set(['local']);
        this.activeCall.peers.forEach((_e, pk) => desired.add('pk-' + this._safePubkey(pk)));
        Array.from(grid.children).forEach(ch => { if (!desired.has(ch.dataset.tile)) grid.removeChild(ch); });

        const localStream = this.activeCall.sharing && this.activeCall.screenStream ? this.activeCall.screenStream : this.activeCall.localStream;
        this._ensureTile('local', 'You', localStream, true, this.pubkey, this.activeCall.sharing);
        this.activeCall.peers.forEach((entry, pk) => {
            this._ensureTile('pk-' + this._safePubkey(pk), entry.nym, entry.stream, false, pk, this.activeCall.sharingPeers.has(pk));
        });

        grid.dataset.count = String(grid.children.length);
    },

    _ensureTile(id, label, stream, isLocal, pubkey, sharing) {
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
            const badge = document.createElement('div');
            badge.className = 'call-tile-badge';
            badge.textContent = 'Presenting';
            tile.appendChild(video);
            tile.appendChild(av);
            tile.appendChild(name);
            tile.appendChild(badge);
            grid.appendChild(tile);
        }
        const video = tile.querySelector('video');
        if (video.srcObject !== stream) video.srcObject = stream || null;
        const av = tile.querySelector('.call-tile-avatar');
        av.src = this.getAvatarUrl(pubkey);
        tile.querySelector('.call-tile-name').textContent = label || '';
        tile.classList.toggle('presenting', !!sharing);

        const hasVideo = this.activeCall.kind === 'video'
            && stream && stream.getVideoTracks().length > 0
            && (sharing || !(isLocal && this.activeCall.cameraOff));
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

    _initCallExtras(ac) {
        ac.sharing = false;
        ac.screenStream = null;
        ac.sharingPeers = new Set();
        ac.shareRestricted = false;
        ac.presenter = null;
        ac.chatLog = [];
        ac.chatUnread = 0;
        ac.presentRequests = new Set();
    },

    _isCallMod() {
        const ac = this.activeCall;
        return !!(ac && ac.isGroup && this._canModerate(ac.groupId, this.pubkey));
    },

    canShareScreen() {
        const ac = this.activeCall;
        if (!ac || ac.kind !== 'video') return false;
        if (!ac.isGroup) return true;
        if (this._canModerate(ac.groupId, this.pubkey)) return true;
        if (!ac.shareRestricted) return true;
        return ac.presenter === this.pubkey;
    },

    async toggleScreenShare() {
        const ac = this.activeCall;
        if (!ac || ac.kind !== 'video') return;
        if (ac.sharing) { this._stopScreenShare(); return; }
        if (!this.canShareScreen()) { this.requestToPresent(); return; }
        await this._startScreenShare();
    },

    async _startScreenShare() {
        const ac = this.activeCall;
        if (!ac || ac.sharing) return;
        if (!navigator.mediaDevices || !navigator.mediaDevices.getDisplayMedia) {
            this.displaySystemMessage('Screen sharing is not supported on this device');
            return;
        }
        let stream;
        try {
            stream = await navigator.mediaDevices.getDisplayMedia({ video: true, audio: false });
        } catch (e) { return; }
        if (!this.activeCall || this.activeCall !== ac) { stream.getTracks().forEach(t => t.stop()); return; }
        const track = stream.getVideoTracks()[0];
        if (!track) { stream.getTracks().forEach(t => t.stop()); return; }
        ac.screenStream = stream;
        ac.sharing = true;
        ac.peers.forEach(entry => { if (entry.videoSender) { try { entry.videoSender.replaceTrack(track); } catch (e) { /* ignore */ } } });
        track.addEventListener('ended', () => this._stopScreenShare());
        const others = ac.members.filter(pk => pk !== this.pubkey);
        this._broadcastCallSignal(others, { type: 'share', callId: ac.callId, on: true });
        this._updateCallControls();
        this._renderCallGrid();
    },

    _stopScreenShare() {
        const ac = this.activeCall;
        if (!ac || !ac.sharing) return;
        const cam = ac.localStream ? (ac.localStream.getVideoTracks()[0] || null) : null;
        ac.peers.forEach(entry => { if (entry.videoSender) { try { entry.videoSender.replaceTrack(cam); } catch (e) { /* ignore */ } } });
        if (ac.screenStream) ac.screenStream.getTracks().forEach(t => { try { t.stop(); } catch (e) { /* ignore */ } });
        ac.screenStream = null;
        ac.sharing = false;
        const others = ac.members.filter(pk => pk !== this.pubkey);
        this._broadcastCallSignal(others, { type: 'share', callId: ac.callId, on: false });
        this._updateCallControls();
        this._renderCallGrid();
    },

    _onCallShare(sender, data) {
        const ac = this.activeCall;
        if (!ac || ac.callId !== data.callId) return;
        if (data.on) ac.sharingPeers.add(sender); else ac.sharingPeers.delete(sender);
        this._renderCallGrid();
    },

    requestToPresent() {
        const ac = this.activeCall;
        if (!ac || !ac.isGroup) return;
        const mods = ac.members.filter(pk => pk !== this.pubkey && this._canModerate(ac.groupId, pk));
        if (!mods.length) { this.displaySystemMessage('No moderator available to grant presenting'); return; }
        this._broadcastCallSignal(mods, { type: 'present-request', callId: ac.callId });
        this.displaySystemMessage('Requested to present');
    },

    _onPresentRequest(sender, data) {
        const ac = this.activeCall;
        if (!ac || ac.callId !== data.callId || !this._isCallMod()) return;
        ac.presentRequests.add(sender);
        this.displaySystemMessage((data.nym ? this.parseNymFromDisplay(data.nym) : this._nymForPubkey(sender)) + ' requested to present');
        this._renderPresenterMenu();
        this._updateCallControls();
    },

    _broadcastPresentState() {
        const ac = this.activeCall;
        if (!ac) return;
        const others = ac.members.filter(pk => pk !== this.pubkey);
        this._broadcastCallSignal(others, { type: 'present-state', callId: ac.callId, restricted: !!ac.shareRestricted, presenter: ac.presenter || null });
    },

    _onPresentState(sender, data) {
        const ac = this.activeCall;
        if (!ac || ac.callId !== data.callId || !ac.isGroup) return;
        if (!this._canModerate(ac.groupId, sender)) return;
        const wasPresenter = ac.presenter === this.pubkey;
        ac.shareRestricted = !!data.restricted;
        ac.presenter = data.presenter || null;
        this._enforceShareRestriction();
        if (!wasPresenter && ac.presenter === this.pubkey) this.displaySystemMessage('You can now share your screen');
        this._updateCallControls();
        this._renderPresenterMenu();
    },

    setScreenShareRestricted(on) {
        const ac = this.activeCall;
        if (!ac || !this._isCallMod()) return;
        ac.shareRestricted = !!on;
        this._broadcastPresentState();
        this._enforceShareRestriction();
        this._renderPresenterMenu();
        this._updateCallControls();
    },

    toggleScreenShareRestricted() {
        const ac = this.activeCall;
        if (!ac) return;
        this.setScreenShareRestricted(!ac.shareRestricted);
    },

    assignPresenter(pubkey) {
        const ac = this.activeCall;
        if (!ac || !this._isCallMod()) return;
        ac.presenter = pubkey || null;
        if (pubkey) ac.presentRequests.delete(pubkey);
        this._broadcastPresentState();
        this._renderPresenterMenu();
        this._updateCallControls();
    },

    _enforceShareRestriction() {
        const ac = this.activeCall;
        if (ac && ac.sharing && !this.canShareScreen()) this._stopScreenShare();
    },

    _callReactionDefaults() { return ['👍', '❤️', '😂', '😮', '👏', '🎉', '🙌', '🔥']; },

    // Last-used first (shared with the message reaction picker), padded with
    // defaults, dropping any custom shortcode whose pack is no longer known.
    _callReactionBarEmojis() {
        const out = [];
        const seen = new Set();
        const known = (e) => {
            if (typeof e !== 'string') return false;
            const m = e.match(/^:([a-zA-Z0-9_]+):$/);
            return !m || (this.customEmojis && this.customEmojis.has(m[1]));
        };
        const add = (e) => { if (e && known(e) && !seen.has(e)) { seen.add(e); out.push(e); } };
        (Array.isArray(this.recentEmojis) ? this.recentEmojis : []).forEach(add);
        this._callReactionDefaults().forEach(add);
        return out.slice(0, 8);
    },

    _renderCallReactionsBar() {
        const bar = document.getElementById('callReactionsBar');
        if (!bar) return;
        bar.innerHTML = '';
        this._callReactionBarEmojis().forEach(em => {
            const b = document.createElement('button');
            b.className = 'call-react-btn';
            b.type = 'button';
            b.dataset.action = 'sendCallReaction';
            b.dataset.emoji = em;
            b.innerHTML = this.renderReactionEmoji(em);
            bar.appendChild(b);
        });
        const more = document.createElement('button');
        more.className = 'call-react-btn call-react-more';
        more.type = 'button';
        more.dataset.action = 'openCallReactionPicker';
        more.title = 'More emoji';
        more.textContent = '＋';
        bar.appendChild(more);
    },

    openCallReactionPicker() {
        const btn = document.getElementById('callReactBtn');
        if (!btn || typeof this.showEnhancedReactionPicker !== 'function') return;
        this._closeCallReactions();
        this.showEnhancedReactionPicker(null, btn, (emoji) => this.sendCallReaction(emoji));
    },

    sendCallReaction(emoji) {
        const ac = this.activeCall;
        if (!ac || !emoji) return;
        if (typeof this.addToRecentEmojis === 'function') this.addToRecentEmojis(emoji);
        const tags = typeof this.customEmojiTagsForContent === 'function' ? this.customEmojiTagsForContent(emoji) : [];
        const payload = { type: 'reaction', callId: ac.callId, emoji };
        if (tags.length) payload.emojiTags = tags;
        const others = ac.members.filter(pk => pk !== this.pubkey);
        this._broadcastCallSignal(others, payload);
        this._showFlyReaction(emoji, 'You');
        this._closeCallReactions();
    },

    _onCallReaction(sender, data) {
        const ac = this.activeCall;
        if (!ac || ac.callId !== data.callId || !data.emoji) return;
        if (data.emojiTags && typeof this.ingestEmojiTags === 'function') this.ingestEmojiTags(data.emojiTags);
        const who = data.nym ? this.parseNymFromDisplay(data.nym) : this._nymForPubkey(sender);
        this._showFlyReaction(String(data.emoji), who);
    },

    _showFlyReaction(emoji, who) {
        const layer = document.getElementById('callReactionsFly');
        if (!layer) return;
        const el = document.createElement('div');
        el.className = 'call-react-fly-item';
        el.style.left = (8 + Math.random() * 74) + '%';
        const e = document.createElement('span');
        e.className = 'call-react-emoji';
        e.innerHTML = this.renderReactionEmoji(String(emoji).slice(0, 64));
        const w = document.createElement('span');
        w.className = 'call-react-who';
        w.textContent = who || '';
        el.appendChild(e);
        el.appendChild(w);
        layer.appendChild(el);
        setTimeout(() => { try { layer.removeChild(el); } catch (_) { } }, 3200);
    },

    sendCallChat() {
        const ac = this.activeCall;
        const input = document.getElementById('callChatInput');
        if (!ac || !input) return;
        const text = input.value.trim();
        if (!text) return;
        input.value = '';
        const others = ac.members.filter(pk => pk !== this.pubkey);
        this._broadcastCallSignal(others, { type: 'chat', callId: ac.callId, text: text.slice(0, 2000) });
        this._appendCallChat('You', text, true);
    },

    handleCallChatKeydown(e) {
        if (e && e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            this.sendCallChat();
        }
    },

    _onCallChat(sender, data) {
        const ac = this.activeCall;
        if (!ac || ac.callId !== data.callId || !data.text) return;
        const who = data.nym ? this.parseNymFromDisplay(data.nym) : this._nymForPubkey(sender);
        this._appendCallChat(who, String(data.text).slice(0, 2000), false);
        const panel = document.getElementById('callChatPanel');
        if (!panel || !panel.classList.contains('active')) {
            ac.chatUnread = (ac.chatUnread || 0) + 1;
            this._updateCallControls();
        }
    },

    _appendCallChat(who, text, isSelf) {
        const ac = this.activeCall;
        if (ac) ac.chatLog.push({ who, text, isSelf });
        const list = document.getElementById('callChatMessages');
        if (!list) return;
        const row = document.createElement('div');
        row.className = 'call-chat-msg' + (isSelf ? ' self' : '');
        const n = document.createElement('span');
        n.className = 'call-chat-from';
        n.textContent = who;
        const t = document.createElement('span');
        t.className = 'call-chat-text';
        t.textContent = text;
        row.appendChild(n);
        row.appendChild(t);
        list.appendChild(row);
        list.scrollTop = list.scrollHeight;
    },

    toggleCallChat() {
        const panel = document.getElementById('callChatPanel');
        if (!panel) return;
        const open = panel.classList.toggle('active');
        if (open && this.activeCall) {
            this.activeCall.chatUnread = 0;
            this._updateCallControls();
            const input = document.getElementById('callChatInput');
            if (input) setTimeout(() => { try { input.focus(); } catch (_) { } }, 30);
        }
        this._closeCallReactions();
        this._closePresenterMenu();
    },

    toggleCallReactions() {
        const bar = document.getElementById('callReactionsBar');
        if (!bar) return;
        if (!bar.classList.contains('active')) this._renderCallReactionsBar();
        bar.classList.toggle('active');
        this._closePresenterMenu();
    },

    _closeCallReactions() {
        const bar = document.getElementById('callReactionsBar');
        if (bar) bar.classList.remove('active');
    },

    toggleCallPresenterMenu() {
        const menu = document.getElementById('callPresenterMenu');
        if (!menu) return;
        const open = menu.classList.toggle('active');
        if (open) this._renderPresenterMenu();
        this._closeCallReactions();
    },

    _closePresenterMenu() {
        const menu = document.getElementById('callPresenterMenu');
        if (menu) menu.classList.remove('active');
    },

    _updateCallControls() {
        const ac = this.activeCall;
        const video = !!(ac && ac.kind === 'video');

        const shareBtn = document.getElementById('callShareBtn');
        if (shareBtn) {
            shareBtn.classList.toggle('nm-call-hidden', !video);
            shareBtn.classList.toggle('active', !!(ac && ac.sharing));
            const allowed = this.canShareScreen();
            if (ac && ac.sharing) shareBtn.title = 'Stop sharing screen';
            else shareBtn.title = allowed ? 'Share screen' : 'Request to present';
            shareBtn.classList.toggle('request-mode', !!(ac && !ac.sharing && !allowed));
        }

        const chatBtn = document.getElementById('callChatBtn');
        if (chatBtn) {
            const badge = chatBtn.querySelector('.call-btn-badge');
            const n = ac ? (ac.chatUnread || 0) : 0;
            if (badge) {
                badge.textContent = n > 9 ? '9+' : String(n);
                badge.classList.toggle('nm-call-hidden', n <= 0);
            }
        }

        const presenterBtn = document.getElementById('callPresenterBtn');
        if (presenterBtn) {
            const show = video && this._isCallMod();
            presenterBtn.classList.toggle('nm-call-hidden', !show);
            const badge = presenterBtn.querySelector('.call-btn-badge');
            const n = ac ? ac.presentRequests.size : 0;
            if (badge) {
                badge.textContent = n > 9 ? '9+' : String(n);
                badge.classList.toggle('nm-call-hidden', n <= 0);
            }
        }
    },

    _renderPresenterMenu() {
        const menu = document.getElementById('callPresenterMenu');
        const ac = this.activeCall;
        if (!menu || !ac) return;
        if (!this._isCallMod()) { menu.classList.remove('active'); menu.innerHTML = ''; return; }

        menu.innerHTML = '';

        const restrictRow = document.createElement('label');
        restrictRow.className = 'call-presenter-restrict';
        const cb = document.createElement('input');
        cb.type = 'checkbox';
        cb.checked = !!ac.shareRestricted;
        cb.dataset.action = 'toggleScreenShareRestricted';
        const rl = document.createElement('span');
        rl.textContent = 'Only the presenter can share';
        restrictRow.appendChild(cb);
        restrictRow.appendChild(rl);
        menu.appendChild(restrictRow);

        const reqs = Array.from(ac.presentRequests).filter(pk => ac.members.includes(pk));
        if (reqs.length) {
            const h = document.createElement('div');
            h.className = 'call-presenter-head';
            h.textContent = 'Requests';
            menu.appendChild(h);
            reqs.forEach(pk => menu.appendChild(this._presenterRow(pk, true)));
        }

        const head = document.createElement('div');
        head.className = 'call-presenter-head';
        head.textContent = 'Participants';
        menu.appendChild(head);
        ac.members.forEach(pk => menu.appendChild(this._presenterRow(pk, false)));
    },

    _presenterRow(pk, isRequest) {
        const ac = this.activeCall;
        const row = document.createElement('div');
        row.className = 'call-presenter-row';
        const name = document.createElement('span');
        name.className = 'call-presenter-name';
        name.textContent = (pk === this.pubkey ? 'You' : this._nymForPubkey(pk)) + (ac.presenter === pk ? ' · presenter' : '');
        row.appendChild(name);
        if (ac.presenter === pk) {
            const btn = document.createElement('button');
            btn.type = 'button';
            btn.className = 'call-presenter-action clear';
            btn.textContent = 'Clear';
            btn.dataset.action = 'clearCallPresenter';
            row.appendChild(btn);
        } else {
            const btn = document.createElement('button');
            btn.type = 'button';
            btn.className = 'call-presenter-action';
            btn.textContent = isRequest ? 'Approve' : 'Make presenter';
            btn.dataset.action = 'makeCallPresenter';
            btn.dataset.pubkey = pk;
            row.appendChild(btn);
        }
        return row;
    },

});
