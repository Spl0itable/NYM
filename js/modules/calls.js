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

    // Decorated display name for call UI (overlay tiles + chat): base nym, the
    // #suffix, purchased flairs, the developer/bot verified badge and the friend
    // icon — mirroring how nyms render everywhere else. `self` renders a plain
    // "You" with no decorations.
    _callNymHtml(pubkey, opts) {
        opts = opts || {};
        if (opts.self || pubkey === this.pubkey) return 'You';
        const base = this.stripPubkeySuffix(this._nymForPubkey(pubkey));
        const suffix = this.getPubkeySuffix(pubkey);
        const flairHtml = (typeof this.getFlairForUser === 'function' && this.getFlairForUser(pubkey)) || '';
        const isDev = typeof this.isVerifiedDeveloper === 'function' && this.isVerifiedDeveloper(pubkey);
        const isBot = !isDev && typeof this.isVerifiedBot === 'function' && this.isVerifiedBot(pubkey);
        const verifiedBadge = (isDev || isBot)
            ? `<span class="verified-badge" title="${this.escapeHtml(isDev ? this.verifiedDeveloper.title : 'Nymchat Bot')}">✓</span>`
            : '';
        const shop = typeof this.getUserShopItems === 'function' ? this.getUserShopItems(pubkey) : null;
        const supporterBadge = (shop && shop.supporter)
            ? `<span class="supporter-badge"><span class="supporter-badge-icon">${this.getSupporterTrophyIcon()}</span><span class="supporter-badge-text">Supporter</span></span>`
            : '';
        const friendHtml = (typeof this.getFriendBadgeHtml === 'function' && this.getFriendBadgeHtml(pubkey)) || '';
        return `<span class="call-nym-base">${this.escapeHtml(base)}</span><span class="nym-suffix">#${suffix}</span>${flairHtml}${verifiedBadge}${supporterBadge}${friendHtml}`;
    },

    // Open the shared user context menu (block, friend, PM, report…) from a
    // nickname tapped in the call overlay or call chat. profileOnly trims the
    // message-only actions that don't apply during a call.
    showCallUserMenu(e, pubkey) {
        if (!pubkey || pubkey === this.pubkey) return;
        if (typeof this.showContextMenu !== 'function') return;
        this.showContextMenu(e, this._nymForPubkey(pubkey), pubkey, null, null, true);
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
            if (this.isVerifiedBot(this.currentPM)) {
                this.displaySystemMessage(kind === 'video'
                    ? 'You wish you could see my sexy body ദ്ദി(ᵔᗜᵔ)'
                    : 'You wish you could hear my sexy voice ദ്ദി(ᵔᗜᵔ)');
                return;
            }
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
            facingMode: 'user',
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
            const groupId = this._callSignalGroupId(payload && payload.callId);
            await this._sendGiftWrapsAsync([targetPubkey], rumor, null, groupId);
        } catch (e) {
            console.error('Call signal error:', e);
        }
    },

    _callSignalGroupId(callId) {
        const ac = this.activeCall;
        if (ac && ac.isGroup && ac.groupId && (!callId || ac.callId === callId)) return ac.groupId;
        const inc = this.incomingCall;
        if (inc && inc.isGroup && inc.groupId && (!callId || inc.callId === callId)) return inc.groupId;
        return null;
    },

    _broadcastCallSignal(targets, payload) {
        targets.forEach(t => this._sendCallSignal(t, payload));
    },

    handleCallSignalingEvent(event) {
        const sender = event.pubkey;
        if (sender === this.pubkey) return;
        // A blocked user can't ring, join, or signal into a call at all.
        if (this.blockedUsers && this.blockedUsers.has(sender)) return;
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
            case 'chat-reaction': this._onCallChatReaction(sender, data); break;
            case 'chat-typing': this._onCallChatTyping(sender, data); break;
            case 'chat-read': this._onCallChatRead(sender, data); break;
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
            facingMode: 'user',
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
        if (this.activeCall.sharing && this.activeCall.screenStream) {
            const st = this.activeCall.screenStream.getVideoTracks()[0];
            if (st) {
                try {
                    if (entry.videoSender) entry.videoSender.replaceTrack(st);
                    else entry.videoSender = pc.addTrack(st, this.activeCall.screenStream);
                } catch (e) { /* ignore */ }
            }
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
        this._clearCallChatTyping(peerPubkey);
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
            if (ac.chatTypers) { ac.chatTypers.forEach(e => { if (e.timeout) clearTimeout(e.timeout); }); ac.chatTypers.clear(); }
            if (this._callTypingStopTimer) { clearTimeout(this._callTypingStopTimer); this._callTypingStopTimer = null; }
            this._callTypingThrottle = 0;
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

    async switchCamera() {
        const ac = this.activeCall;
        if (!ac || ac.kind !== 'video' || ac.sharing || ac.switchingCamera) return;
        ac.switchingCamera = true;
        this._updateCallControls();
        const next = ac.facingMode === 'environment' ? 'user' : 'environment';
        let stream;
        try {
            stream = await navigator.mediaDevices.getUserMedia({
                audio: false,
                video: { width: { ideal: 1280 }, height: { ideal: 720 }, facingMode: { ideal: next } }
            });
        } catch (e) {
            ac.switchingCamera = false;
            this._updateCallControls();
            this.displaySystemMessage('Could not switch camera: ' + (e.message || e.name || e));
            return;
        }
        if (!this.activeCall || this.activeCall !== ac) { stream.getTracks().forEach(t => t.stop()); return; }
        const newTrack = stream.getVideoTracks()[0];
        if (!newTrack) { stream.getTracks().forEach(t => t.stop()); ac.switchingCamera = false; this._updateCallControls(); return; }
        newTrack.enabled = !ac.cameraOff;
        const oldTrack = ac.localStream.getVideoTracks()[0];
        if (oldTrack) { ac.localStream.removeTrack(oldTrack); try { oldTrack.stop(); } catch (e) { /* ignore */ } }
        ac.localStream.addTrack(newTrack);
        if (!ac.sharing) {
            ac.peers.forEach(entry => { if (entry.videoSender) { try { entry.videoSender.replaceTrack(newTrack); } catch (e) { /* ignore */ } } });
        }
        ac.facingMode = next;
        ac.switchingCamera = false;
        this._updateCallControls();
        this._renderCallGrid();
    },

    async _updateCameraSwitchBtn() {
        const btn = document.getElementById('callSwitchCamBtn');
        if (!btn) return;
        const ac = this.activeCall;
        let show = !!(ac && ac.kind === 'video');
        if (show && navigator.mediaDevices && navigator.mediaDevices.enumerateDevices) {
            try {
                const devices = await navigator.mediaDevices.enumerateDevices();
                show = devices.filter(d => d.kind === 'videoinput').length > 1;
            } catch (e) { /* keep showing */ }
        }
        if (!this.activeCall || this.activeCall !== ac) return;
        btn.classList.toggle('nm-call-hidden', !show);
    },

    _callTitleHtml() {
        if (!this.activeCall) return '';
        const kind = this.activeCall.kind === 'video' ? 'Video call' : 'Audio call';
        const prefix = `<span class="call-title-kind">${kind} ·</span>`;
        if (this.activeCall.isGroup) {
            const g = this.activeCall.groupId && this.groupConversations.get(this.activeCall.groupId);
            const name = g ? g.name : 'Group call';
            const others = (g && Array.isArray(g.members)) ? g.members.filter(pk => pk !== this.pubkey) : [];
            const avatars = others.slice(0, 4).map(pk =>
                `<img src="${this.escapeHtml(this.getAvatarUrl(pk))}" class="avatar-message group-header-avatar" data-avatar-pubkey="${this._safePubkey(pk)}" alt="" decoding="async" loading="lazy">`
            ).join('');
            const groupSvg = `<svg class="group-chat-icon group-header-svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="7" r="2.75"/><path d="M5 21v-1.5a7 7 0 0 1 14 0V21"/><circle cx="4.5" cy="9.5" r="2"/><path d="M1 20v-1a4.5 4.5 0 0 1 5.5-4.35"/><circle cx="19.5" cy="9.5" r="2"/><path d="M23 20v-1a4.5 4.5 0 0 0-5.5-4.35"/></svg>`;
            if (typeof this.ensureListProfiles === 'function') this.ensureListProfiles(null, others.slice(0, 4), () => this._refreshCallTitle());
            return `${prefix}<span class="group-header-row call-title-id"><span class="group-header-icon">${groupSvg}</span>${avatars}<span class="group-name-text ${others.length ? 'nm-grp-ml8' : ''}">${this.escapeHtml(name)}</span></span>`;
        }
        const peer = this.activeCall.members.find(pk => pk !== this.pubkey);
        if (peer && typeof this.ensureListProfiles === 'function') this.ensureListProfiles(null, [peer], () => this._refreshCallTitle());
        const avatar = `<img src="${this.escapeHtml(this.getAvatarUrl(peer))}" class="avatar-message call-title-avatar" data-avatar-pubkey="${this._safePubkey(peer)}" alt="" decoding="async" loading="lazy">`;
        return `${prefix}<span class="call-title-id">${avatar}<span class="call-title-nym">${this._callNymHtml(peer)}</span></span>`;
    },

    // Re-render the call overlay title in place when a peer's profile arrives.
    _refreshCallTitle() {
        const title = document.getElementById('callTitle');
        if (title && this.activeCall) title.innerHTML = this._callTitleHtml();
    },

    _showCallOverlay() {
        const ov = document.getElementById('callOverlay');
        if (!ov || !this.activeCall) return;
        ov.classList.add('active');
        const title = document.getElementById('callTitle');
        if (title) title.innerHTML = this._callTitleHtml();
        const videoBtn = document.getElementById('callVideoBtn');
        if (videoBtn) videoBtn.classList.toggle('nm-call-hidden', this.activeCall.kind !== 'video');
        const muteBtn = document.getElementById('callMuteBtn');
        if (muteBtn) { muteBtn.classList.remove('active'); muteBtn.title = 'Mute microphone'; }
        const chatMsgs = document.getElementById('callChatMessages');
        if (chatMsgs) chatMsgs.innerHTML = '';
        const chatInput = document.getElementById('callChatInput');
        if (chatInput) chatInput.value = '';
        this._renderCallChatTyping();
        this._hideCallMentionAutocomplete();
        this._setupCallChatInteractions();
        ['callChatPanel', 'callReactionsBar', 'callPresenterMenu'].forEach(id => {
            const el = document.getElementById(id); if (el) el.classList.remove('active');
        });
        this._updateCallControls();
        this._updateCameraSwitchBtn();
        this._renderCallGrid();
    },

    _hideCallOverlay() {
        const ov = document.getElementById('callOverlay');
        if (ov) ov.classList.remove('active');
        this._hideCallMentionAutocomplete();
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

        const isBlocked = (pk) => !!(this.blockedUsers && this.blockedUsers.has(pk));

        const desired = new Set(['local']);
        this.activeCall.peers.forEach((_e, pk) => { if (!isBlocked(pk)) desired.add('pk-' + this._safePubkey(pk)); });
        Array.from(grid.children).forEach(ch => { if (!desired.has(ch.dataset.tile)) grid.removeChild(ch); });

        const localStream = this.activeCall.sharing && this.activeCall.screenStream ? this.activeCall.screenStream : this.activeCall.localStream;
        this._ensureTile('local', 'You', localStream, true, this.pubkey, this.activeCall.sharing);
        this.activeCall.peers.forEach((entry, pk) => {
            if (isBlocked(pk)) return;
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
        if (pubkey) av.dataset.avatarPubkey = this._safePubkey(pubkey);
        av.src = this.getAvatarUrl(pubkey);
        const nameEl = tile.querySelector('.call-tile-name');
        nameEl.innerHTML = isLocal ? 'You' : this._callNymHtml(pubkey);
        if (!isLocal && pubkey) {
            nameEl.classList.add('call-clickable-nym');
            nameEl.dataset.action = 'callNickMenu';
            nameEl.dataset.pubkey = pubkey;
            if (typeof this.ensureListProfiles === 'function') {
                this.ensureListProfiles(null, [pubkey], () => {
                    const el = document.querySelector(`[data-tile="${id}"] .call-tile-name`);
                    if (el) el.innerHTML = this._callNymHtml(pubkey);
                });
            }
        }
        tile.classList.toggle('presenting', !!sharing);

        const hasVideo = stream && stream.getVideoTracks().length > 0
            && (sharing || (this.activeCall.kind === 'video' && !(isLocal && this.activeCall.cameraOff)));
        tile.classList.toggle('no-video', !hasVideo);
    },

    _showIncomingCallUI() {
        const inc = this.incomingCall;
        if (!inc) return;
        const name = document.getElementById('incomingCallName');
        if (name) {
            if (inc.from) name.innerHTML = this._callNymHtml(inc.from);
            else name.textContent = inc.nym || 'Someone';
        }
        const sub = document.getElementById('incomingCallSub');
        if (sub) sub.textContent = `Incoming ${inc.kind === 'video' ? 'video' : 'audio'} call${inc.isGroup ? ' (group)' : ''}`;
        const av = document.getElementById('incomingCallAvatar');
        if (av) {
            if (inc.from) av.dataset.avatarPubkey = this._safePubkey(inc.from);
            av.src = this.getAvatarUrl(inc.from);
        }
        if (inc.from && typeof this.ensureListProfiles === 'function') {
            this.ensureListProfiles(null, [inc.from], () => {
                const nameEl = document.getElementById('incomingCallName');
                if (nameEl && this.incomingCall && this.incomingCall.from === inc.from) {
                    nameEl.innerHTML = this._callNymHtml(inc.from);
                }
            });
        }
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
        ac.chatReactions = {};
        ac.chatTypers = new Map();
        ac.chatReaders = new Map();
        ac.sentChatReads = new Set();
        ac.presentRequests = new Set();
    },

    _isCallMod() {
        const ac = this.activeCall;
        return !!(ac && ac.isGroup && this._canModerate(ac.groupId, this.pubkey));
    },

    canShareScreen() {
        const ac = this.activeCall;
        if (!ac) return false;
        if (!ac.isGroup) return true;
        if (this._canModerate(ac.groupId, this.pubkey)) return true;
        if (!ac.shareRestricted) return true;
        return ac.presenter === this.pubkey;
    },

    async toggleScreenShare() {
        const ac = this.activeCall;
        if (!ac) return;
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
        ac.peers.forEach((entry, pk) => {
            if (entry.videoSender) {
                try { entry.videoSender.replaceTrack(track); } catch (e) { /* ignore */ }
            } else {
                try {
                    entry.videoSender = entry.pc.addTrack(track, stream);
                    this._makeOffer(pk);
                } catch (e) { /* ignore */ }
            }
        });
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
        this._showFlyReaction(String(data.emoji), null, sender);
    },

    _showFlyReaction(emoji, who, pubkey) {
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
        if (pubkey && pubkey !== this.pubkey) w.innerHTML = this._callNymHtml(pubkey);
        else w.textContent = who || '';
        el.appendChild(e);
        el.appendChild(w);
        layer.appendChild(el);
        setTimeout(() => { try { layer.removeChild(el); } catch (_) { } }, 3200);
    },

    sendCallChat() {
        const ac = this.activeCall;
        const input = document.getElementById('callChatInput');
        if (!ac || !input) return;
        // A mention pick (Enter/Tab) should complete the mention, not send.
        if (this._callMentionActive()) { this._selectCallMention(); return; }
        const text = input.value.trim();
        if (!text) return;
        input.value = '';
        this._hideCallMentionAutocomplete();
        this._sendCallTypingStop();
        const mid = this._genCallId();
        const others = ac.members.filter(pk => pk !== this.pubkey);
        this._broadcastCallSignal(others, { type: 'chat', callId: ac.callId, text: text.slice(0, 2000), mid });
        this._appendCallChat(this.pubkey, text, true, mid);
    },

    handleCallChatKeydown(e) {
        if (!e) return;
        // Mention autocomplete navigation takes precedence while it's open.
        if (this._callMentionActive()) {
            if (e.key === 'ArrowDown') { e.preventDefault(); this._navigateCallMention(1); return; }
            if (e.key === 'ArrowUp') { e.preventDefault(); this._navigateCallMention(-1); return; }
            if (e.key === 'Escape') { e.preventDefault(); this._hideCallMentionAutocomplete(); return; }
            if (e.key === 'Enter' || e.key === 'Tab') { e.preventDefault(); this._selectCallMention(); return; }
        }
        if (e.key === 'Enter' && !e.shiftKey) {
            e.preventDefault();
            this.sendCallChat();
        }
    },

    _onCallChat(sender, data) {
        const ac = this.activeCall;
        if (!ac || ac.callId !== data.callId || !data.text) return;
        if (this.blockedUsers && this.blockedUsers.has(sender)) return;
        this._clearCallChatTyping(sender);
        this._appendCallChat(sender, String(data.text).slice(0, 2000), false, data.mid);
        const panel = document.getElementById('callChatPanel');
        if (!panel || !panel.classList.contains('active')) {
            ac.chatUnread = (ac.chatUnread || 0) + 1;
            this._updateCallControls();
        } else {
            this._sendCallChatRead(sender, data.mid);
        }
    },

    _sendCallTypingSignal() {
        const ac = this.activeCall;
        if (!ac) return;
        if (!this.isTypingIndicatorAllowedFor(ac.isGroup ? 'group' : 'pm')) return;
        const now = Date.now();
        if (now - (this._callTypingThrottle || 0) < 3000) {
            this._armCallTypingStop();
            return;
        }
        this._callTypingThrottle = now;
        const others = ac.members.filter(pk => pk !== this.pubkey);
        this._broadcastCallSignal(others, { type: 'chat-typing', callId: ac.callId, status: 'start' });
        this._armCallTypingStop();
    },

    _armCallTypingStop() {
        if (this._callTypingStopTimer) clearTimeout(this._callTypingStopTimer);
        this._callTypingStopTimer = setTimeout(() => this._sendCallTypingStop(), 4000);
    },

    _sendCallTypingStop() {
        if (this._callTypingStopTimer) { clearTimeout(this._callTypingStopTimer); this._callTypingStopTimer = null; }
        this._callTypingThrottle = 0;
        const ac = this.activeCall;
        if (!ac) return;
        const others = ac.members.filter(pk => pk !== this.pubkey);
        this._broadcastCallSignal(others, { type: 'chat-typing', callId: ac.callId, status: 'stop' });
    },

    _onCallChatTyping(sender, data) {
        const ac = this.activeCall;
        if (!ac || ac.callId !== data.callId || !sender || sender === this.pubkey) return;
        if (!this.isTypingIndicatorAllowedFor(ac.isGroup ? 'group' : 'pm')) return;
        if (this.blockedUsers && this.blockedUsers.has(sender)) return;
        if (!ac.chatTypers) ac.chatTypers = new Map();
        if (data.status === 'stop') {
            const entry = ac.chatTypers.get(sender);
            if (entry && entry.timeout) clearTimeout(entry.timeout);
            ac.chatTypers.delete(sender);
        } else {
            const existing = ac.chatTypers.get(sender);
            if (existing && existing.timeout) clearTimeout(existing.timeout);
            const timeout = setTimeout(() => {
                if (ac.chatTypers) ac.chatTypers.delete(sender);
                this._renderCallChatTyping();
            }, 5000);
            ac.chatTypers.set(sender, { timeout });
        }
        this._renderCallChatTyping();
    },

    _renderCallChatTyping() {
        const el = document.getElementById('callChatTyping');
        const ac = this.activeCall;
        if (!el) return;
        const typers = ac && ac.chatTypers ? Array.from(ac.chatTypers.keys()) : [];
        if (!typers.length) {
            el.classList.remove('active');
            el.innerHTML = '';
            return;
        }
        const fmt = (pk) => this._callNymHtml(pk);
        let html;
        if (typers.length === 1) html = `${fmt(typers[0])} is typing`;
        else if (typers.length === 2) html = `${fmt(typers[0])} and ${fmt(typers[1])} are typing`;
        else html = `${typers.length} people are typing`;
        el.innerHTML = html;
        el.classList.add('active');
    },

    _clearCallChatTyping(pubkey) {
        const ac = this.activeCall;
        if (!ac || !ac.chatTypers) return;
        const entry = ac.chatTypers.get(pubkey);
        if (entry && entry.timeout) clearTimeout(entry.timeout);
        ac.chatTypers.delete(pubkey);
        this._renderCallChatTyping();
    },

    // Acknowledge a peer's chat message as read. Broadcast to all members so the
    // original sender records us as a reader; non-senders ignore unknown mids.
    _sendCallChatRead(senderPubkey, mid) {
        const ac = this.activeCall;
        if (!ac || !mid || !senderPubkey || senderPubkey === this.pubkey) return;
        if (!this.isReadReceiptAllowedFor(ac.isGroup ? 'group' : 'pm')) return;
        if (!ac.sentChatReads) ac.sentChatReads = new Set();
        if (ac.sentChatReads.has(mid)) return;
        ac.sentChatReads.add(mid);
        const others = ac.members.filter(pk => pk !== this.pubkey);
        this._broadcastCallSignal(others, { type: 'chat-read', callId: ac.callId, mid });
    },

    // Send read receipts for every received message still unacknowledged (called
    // when the chat panel is opened).
    _flushCallChatReads() {
        const ac = this.activeCall;
        if (!ac || !Array.isArray(ac.chatLog)) return;
        for (const m of ac.chatLog) {
            if (!m.isSelf && m.pubkey && m.mid) this._sendCallChatRead(m.pubkey, m.mid);
        }
    },

    _onCallChatRead(sender, data) {
        const ac = this.activeCall;
        if (!ac || ac.callId !== data.callId || !data.mid || !sender || sender === this.pubkey) return;
        const mine = ac.chatLog.find(m => m.mid === data.mid && m.isSelf);
        if (!mine) return;
        if (!ac.chatReaders) ac.chatReaders = new Map();
        if (!ac.chatReaders.has(data.mid)) ac.chatReaders.set(data.mid, new Map());
        ac.chatReaders.get(data.mid).set(sender, this.getNymFromPubkey(sender));
        this._renderCallChatReceipt(data.mid);
    },

    _renderCallChatReceipt(mid) {
        const ac = this.activeCall;
        if (!ac) return;
        const row = this._callChatRow(mid);
        if (!row) return;
        const el = row.querySelector('.call-chat-receipt, .call-chat-readers');
        if (!el) return;
        const readers = ac.chatReaders && ac.chatReaders.get(mid);
        if (ac.isGroup) {
            const has = this._syncReaderAvatars(el, readers);
            if (has && !el._readerLongPressBound) {
                this._bindCallReaderLongPress(el, mid);
                el._readerLongPressBound = true;
            }
        } else {
            const read = !!(readers && readers.size > 0);
            el.className = 'call-chat-receipt delivery-status ' + (read ? 'read' : 'sent');
            el.title = read ? 'Read' : 'Sent';
            el.textContent = read ? '✓✓' : '✓';
        }
    },

    _bindCallReaderLongPress(el, mid) {
        let timer = null;
        const start = (e) => {
            if (e.type === 'mousedown' && e.button !== 0) return;
            e.stopPropagation();
            timer = setTimeout(() => {
                timer = null;
                window.nymHapticTap && window.nymHapticTap();
                const ac = this.activeCall;
                const readers = ac && ac.chatReaders && ac.chatReaders.get(mid);
                if (readers && readers.size) {
                    this._showReadersModalFromMap(readers, el);
                    if (this.readersModal) this.readersModal.style.zIndex = '10060';
                }
            }, 500);
        };
        const cancel = (e) => { if (e) e.stopPropagation(); if (timer) { clearTimeout(timer); timer = null; } };
        el.addEventListener('mousedown', start);
        el.addEventListener('touchstart', start, { passive: false });
        el.addEventListener('mouseup', cancel);
        el.addEventListener('mouseleave', cancel);
        el.addEventListener('touchend', cancel);
        el.addEventListener('touchcancel', cancel);
        el.addEventListener('contextmenu', (e) => { e.preventDefault(); e.stopPropagation(); cancel(e); });
        el.style.cursor = 'pointer';
    },

    _appendCallChat(pubkey, text, isSelf, mid) {
        const ac = this.activeCall;
        mid = mid || this._genCallId();
        if (ac) ac.chatLog.push({ pubkey, text, isSelf, mid });
        const list = document.getElementById('callChatMessages');
        if (!list) return;
        const row = document.createElement('div');
        row.className = 'call-chat-msg' + (isSelf ? ' self' : '');
        row.dataset.mid = mid;
        if (pubkey) row.dataset.pk = pubkey;
        // Carry the sender's purchased message flair (style/supporter/aura) onto
        // the call-chat row, mirroring how channel/PM messages render cosmetics.
        const shop = pubkey && typeof this.getUserShopItems === 'function' ? this.getUserShopItems(pubkey) : null;
        if (shop) {
            if (shop.style) { row.classList.add(shop.style); }
            if (shop.supporter) row.classList.add('supporter-style');
            if (Array.isArray(shop.cosmetics) && shop.cosmetics.includes('cosmetic-aura-gold')) row.classList.add('cosmetic-aura-gold');
        }
        const n = document.createElement('span');
        n.className = 'call-chat-from';
        n.innerHTML = this._callNymHtml(pubkey, { self: isSelf });
        if (!isSelf && pubkey) {
            n.classList.add('call-clickable-nym');
            n.dataset.action = 'callNickMenu';
            n.dataset.pubkey = pubkey;
        }
        const t = document.createElement('span');
        t.className = 'call-chat-text';
        t.innerHTML = this._formatCallChatText(text);
        const reacts = document.createElement('div');
        reacts.className = 'call-chat-reactions';
        const reactBtn = document.createElement('button');
        reactBtn.className = 'call-chat-react-btn';
        reactBtn.type = 'button';
        reactBtn.title = 'React';
        reactBtn.dataset.action = 'callChatReact';
        reactBtn.dataset.mid = mid;
        reactBtn.textContent = '＋';
        row.appendChild(n);
        row.appendChild(t);
        row.appendChild(reacts);
        row.appendChild(reactBtn);
        if (isSelf) {
            const receipt = document.createElement('span');
            receipt.className = ac && ac.isGroup ? 'call-chat-readers' : 'call-chat-receipt delivery-status sent';
            receipt.dataset.mid = mid;
            if (!(ac && ac.isGroup)) { receipt.title = 'Sent'; receipt.textContent = '✓'; }
            row.appendChild(receipt);
        }
        if (pubkey && this.blockedUsers && this.blockedUsers.has(pubkey)) {
            row.classList.add('call-chat-blocked-hidden');
        }
        list.appendChild(row);
        list.scrollTop = list.scrollHeight;
    },

    // Decorate @mentions in call chat text. Matching runs over the RAW text and
    // each segment (and the mention name) is escaped individually — escaping
    // first would let the regex split an HTML entity (e.g. the &#39; for an
    // apostrophe right after a mention), corrupting the output.
    _formatCallChatText(text) {
        const raw = String(text == null ? '' : text);
        const re = /(^|\s)@([^\s#@]+)(#[0-9a-f]{4})?/gi;
        let out = '';
        let last = 0;
        let m;
        while ((m = re.exec(raw)) !== null) {
            const pre = m[1], name = m[2], sfx = m[3];
            out += this.escapeHtml(raw.slice(last, m.index)) + this.escapeHtml(pre);
            const suffixHtml = sfx ? `<span class="nym-suffix">${this.escapeHtml(sfx)}</span>` : '';
            out += `<span class="nm-mention">@${this.escapeHtml(name)}${suffixHtml}</span>`;
            last = m.index + m[0].length;
        }
        out += this.escapeHtml(raw.slice(last));
        return out;
    },

    _callChatRow(mid) {
        const list = document.getElementById('callChatMessages');
        if (!list) return null;
        return Array.from(list.children).find(r => r.dataset && r.dataset.mid === mid) || null;
    },

    // Open the quick-reaction popup for a call-chat message (from the ＋ button
    // or a long-press). The popup also exposes the user context menu.
    callChatReact(e, node) {
        if (!this.activeCall || !node) return;
        const row = node.closest ? node.closest('.call-chat-msg') : null;
        if (row) this._showCallChatQuickReact(row, e);
    },

    // Six quick emojis: most-recent first, padded with defaults, dropping any
    // custom shortcode whose pack is no longer known.
    _callQuickEmojis() {
        const defaults = ['👍', '❤️', '😂', '🔥', '👎', '😮'];
        const out = [];
        const seen = new Set();
        const known = (e) => {
            if (typeof e !== 'string') return false;
            const m = e.match(/^:([a-zA-Z0-9_]+):$/);
            return !m || (this.customEmojis && this.customEmojis.has(m[1]));
        };
        const add = (e) => { if (e && known(e) && !seen.has(e)) { seen.add(e); out.push(e); } };
        (Array.isArray(this.recentEmojis) ? this.recentEmojis : []).forEach(add);
        defaults.forEach(add);
        return out.slice(0, 6);
    },

    _showCallChatQuickReact(row, e) {
        const ac = this.activeCall;
        if (!ac || !row) return;
        const mid = row.dataset.mid;
        const pubkey = row.dataset.pk;
        const isSelf = row.classList.contains('self');
        document.querySelectorAll('.quick-react-popup, .quick-context-menu').forEach(el => el.remove());

        const popup = document.createElement('div');
        // Reuse the message quick-react styling, lifted above the call overlay.
        popup.className = 'quick-react-popup call-quick-react active';
        popup.style.position = 'fixed';
        popup.style.zIndex = '10050';
        popup.innerHTML = this._callQuickEmojis().map(emoji => {
            const cm = typeof emoji === 'string' && emoji.match(/^:([a-zA-Z0-9_]+):$/);
            if (cm && this.customEmojis && this.customEmojis.has(cm[1])) {
                return `<button class="quick-react-emoji" data-emoji=":${this.escapeHtml(cm[1])}:">${this.renderCustomEmojiImg(cm[1])}</button>`;
            }
            return `<button class="quick-react-emoji" data-emoji="${this.escapeHtml(emoji)}">${emoji}</button>`;
        }).join('')
            + `<button class="quick-react-expand" data-qr="more" title="More reactions"><svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6 L8 10 L12 6"/></svg></button>`
            + (!isSelf && pubkey ? `<button class="quick-react-expand" data-qr="menu" title="User options"><svg width="15" height="15" viewBox="0 0 16 16" fill="currentColor"><circle cx="8" cy="3" r="1.4"/><circle cx="8" cy="8" r="1.4"/><circle cx="8" cy="13" r="1.4"/></svg></button>` : '');

        popup.style.visibility = 'hidden';
        document.body.appendChild(popup);
        const w = popup.offsetWidth, h = popup.offsetHeight;
        popup.style.visibility = '';
        const rect = row.getBoundingClientRect();
        const cx = (e && e.clientX) || (rect.left + rect.width / 2);
        const cy = (e && e.clientY) || rect.top;
        popup.style.left = Math.max(8, Math.min(cx - w / 2, window.innerWidth - w - 8)) + 'px';
        popup.style.top = Math.max(8, cy - h - 10) + 'px';

        const openedAt = Date.now();
        const close = () => {
            popup.remove();
            document.removeEventListener('mousedown', onOutside, true);
            document.removeEventListener('touchstart', onOutside, true);
        };
        const onOutside = (ev) => {
            if (popup.contains(ev.target)) return;
            if (Date.now() - openedAt < 300) return;
            close();
        };

        const bind = (btn, fn) => {
            btn.addEventListener('click', fn);
            btn.addEventListener('touchend', fn);
        };
        popup.querySelectorAll('.quick-react-emoji').forEach(btn => {
            bind(btn, (ev) => {
                ev.preventDefault();
                ev.stopPropagation();
                this._toggleCallChatReaction(mid, btn.dataset.emoji);
                close();
            });
        });
        popup.querySelectorAll('.quick-react-expand').forEach(btn => {
            bind(btn, (ev) => {
                ev.preventDefault();
                ev.stopPropagation();
                if (btn.dataset.qr === 'menu') { close(); this.showCallUserMenu(ev, pubkey); return; }
                // More reactions: open the full picker anchored where the popup was.
                const left = popup.style.left, top = popup.style.top;
                close();
                const tmp = document.createElement('button');
                tmp.style.cssText = `position:fixed;left:${left};top:${top};opacity:0;pointer-events:none;`;
                document.body.appendChild(tmp);
                if (typeof this.showEnhancedReactionPicker === 'function') {
                    this.showEnhancedReactionPicker(null, tmp, (emoji) => this._toggleCallChatReaction(mid, emoji));
                }
                setTimeout(() => tmp.remove(), 100);
            });
        });

        // Defer attaching outside-close so the opening gesture doesn't trip it.
        setTimeout(() => {
            document.addEventListener('mousedown', onOutside, true);
            document.addEventListener('touchstart', onOutside, true);
        }, 0);
    },

    // Long-press a call-chat message to open the quick-react/context popup.
    // Bound once; the message list is delegated so it covers future rows.
    _setupCallChatInteractions() {
        if (this._callChatInteractionsBound) return;
        const list = document.getElementById('callChatMessages');
        if (!list) return;
        this._callChatInteractionsBound = true;
        let timer = null, fired = false, sx = 0, sy = 0;
        const MOVE = 10;
        const skip = (t) => t.closest('.call-chat-react-btn, .call-chat-reaction, .call-clickable-nym, .call-chat-readers');
        const cancel = () => { if (timer) { clearTimeout(timer); timer = null; } };
        list.addEventListener('touchstart', (ev) => {
            const row = ev.target.closest('.call-chat-msg');
            if (!row || skip(ev.target)) return;
            const t = ev.touches && ev.touches[0];
            if (!t) return;
            fired = false; sx = t.clientX; sy = t.clientY;
            cancel();
            timer = setTimeout(() => {
                timer = null; fired = true;
                window.nymHapticTap && window.nymHapticTap();
                this._showCallChatQuickReact(row, { clientX: sx, clientY: sy });
            }, 500);
        }, { passive: true });
        list.addEventListener('touchmove', (ev) => {
            if (!timer) return;
            const t = ev.touches && ev.touches[0];
            if (!t) return;
            if (Math.abs(t.clientX - sx) > MOVE || Math.abs(t.clientY - sy) > MOVE) cancel();
        }, { passive: true });
        list.addEventListener('touchend', (ev) => {
            cancel();
            if (fired) { ev.preventDefault(); fired = false; }
        });
        list.addEventListener('touchcancel', cancel);
    },

    callChatReactBadge(node) {
        if (!node) return;
        this._toggleCallChatReaction(node.dataset.mid, node.dataset.emoji);
    },

    _toggleCallChatReaction(mid, emoji) {
        const ac = this.activeCall;
        if (!ac || !mid || !emoji) return;
        const map = ac.chatReactions[mid] || (ac.chatReactions[mid] = {});
        const set = map[emoji] || (map[emoji] = new Set());
        let op;
        if (set.has(this.pubkey)) {
            set.delete(this.pubkey);
            if (!set.size) delete map[emoji];
            op = 'remove';
        } else {
            set.add(this.pubkey);
            op = 'add';
            if (typeof this.addToRecentEmojis === 'function') this.addToRecentEmojis(emoji);
        }
        const payload = { type: 'chat-reaction', callId: ac.callId, mid, emoji, op };
        const tags = typeof this.customEmojiTagsForContent === 'function' ? this.customEmojiTagsForContent(emoji) : [];
        if (tags.length) payload.emojiTags = tags;
        const others = ac.members.filter(pk => pk !== this.pubkey);
        this._broadcastCallSignal(others, payload);
        this._renderCallChatReactions(mid);
    },

    _onCallChatReaction(sender, data) {
        const ac = this.activeCall;
        if (!ac || ac.callId !== data.callId || !data.mid || !data.emoji) return;
        if (this.blockedUsers && this.blockedUsers.has(sender)) return;
        if (data.emojiTags && typeof this.ingestEmojiTags === 'function') this.ingestEmojiTags(data.emojiTags);
        const map = ac.chatReactions[data.mid] || (ac.chatReactions[data.mid] = {});
        const set = map[data.emoji] || (map[data.emoji] = new Set());
        if (data.op === 'remove') {
            set.delete(sender);
            if (!set.size) delete map[data.emoji];
        } else {
            set.add(sender);
        }
        this._renderCallChatReactions(data.mid);
    },

    _renderCallChatReactions(mid) {
        const ac = this.activeCall;
        if (!ac) return;
        const row = this._callChatRow(mid);
        if (!row) return;
        const cont = row.querySelector('.call-chat-reactions');
        if (!cont) return;
        cont.innerHTML = '';
        const map = ac.chatReactions[mid];
        if (!map) return;
        let hasAny = false;
        Object.keys(map).forEach(emoji => {
            const set = map[emoji];
            if (!set || !set.size) return;
            hasAny = true;
            const badge = document.createElement('button');
            badge.type = 'button';
            badge.className = 'call-chat-reaction' + (set.has(this.pubkey) ? ' self' : '');
            badge.dataset.action = 'callChatReactBadge';
            badge.dataset.mid = mid;
            badge.dataset.emoji = emoji;
            badge.innerHTML = this.renderReactionEmoji(emoji) + `<span class="call-chat-reaction-count">${set.size}</span>`;
            cont.appendChild(badge);
        });
        if (hasAny) {
            const addBtn = document.createElement('span');
            addBtn.className = 'add-reaction-btn';
            addBtn.title = 'Add reaction';
            addBtn.innerHTML = '<svg viewBox="0 0 20 20" class="nm-react-1"><path fill-rule="evenodd" clip-rule="evenodd" d="M15.5 1a.75.75 0 0 1 .75.75v2h2a.75.75 0 0 1 0 1.5h-2v2a.75.75 0 0 1-1.5 0v-2h-2a.75.75 0 0 1 0-1.5h2v-2A.75.75 0 0 1 15.5 1m-13 10a6.5 6.5 0 0 1 7.166-6.466.75.75 0 0 0 .152-1.493 8 8 0 1 0 7.14 7.139.75.75 0 0 0-1.492.152A7 7 0 0 1 15.5 11a6.5 6.5 0 1 1-13 0m4.25-.5a1.25 1.25 0 1 0 0-2.5 1.25 1.25 0 0 0 0 2.5m4.5 0a1.25 1.25 0 1 0 0-2.5 1.25 1.25 0 0 0 0 2.5M9 15c1.277 0 2.553-.724 3.06-2.173.148-.426-.209-.827-.66-.827H6.6c-.452 0-.808.4-.66.827C6.448 14.276 7.724 15 9 15"></path></svg>';
            addBtn.onclick = (e) => {
                e.stopPropagation();
                if (typeof this.showEnhancedReactionPicker === 'function') {
                    this.showEnhancedReactionPicker(null, addBtn, (emoji) => this._toggleCallChatReaction(mid, emoji));
                }
            };
            cont.appendChild(addBtn);
        }
    },

    toggleCallChat() {
        const panel = document.getElementById('callChatPanel');
        if (!panel) return;
        const open = panel.classList.toggle('active');
        if (open && this.activeCall) {
            this.activeCall.chatUnread = 0;
            this._updateCallControls();
            this._flushCallChatReads();
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

        const switchBtn = document.getElementById('callSwitchCamBtn');
        if (switchBtn) {
            switchBtn.disabled = !!(ac && (ac.sharing || ac.switchingCamera));
            switchBtn.title = ac && ac.facingMode === 'environment' ? 'Switch to front camera' : 'Switch to rear camera';
        }

        const shareBtn = document.getElementById('callShareBtn');
        if (shareBtn) {
            shareBtn.classList.toggle('nm-call-hidden', !ac);
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
            const show = this._isCallMod();
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

    // Mentions in the in-call chat are scoped to the call's own participants.
    _callMentionParticipants() {
        const ac = this.activeCall;
        if (!ac) return [];
        return ac.members.filter(pk => pk !== this.pubkey && !(this.blockedUsers && this.blockedUsers.has(pk)));
    },

    _callMentionActive() {
        const dd = document.getElementById('callMentionAutocomplete');
        return !!(dd && dd.classList.contains('active'));
    },

    handleCallChatInput(e) {
        const input = (e && e.target) || document.getElementById('callChatInput');
        if (!input) return;
        const cursor = typeof input.selectionStart === 'number' ? input.selectionStart : input.value.length;
        const before = input.value.substring(0, cursor);
        const m = before.match(/(?:^|\s)@([^\s@]*)$/);
        if (m) this._showCallMentionAutocomplete(m[1]);
        else this._hideCallMentionAutocomplete();
        if (input.value.trim()) this._sendCallTypingSignal();
    },

    _showCallMentionAutocomplete(search) {
        const dd = document.getElementById('callMentionAutocomplete');
        if (!dd) return;
        const s = (search || '').toLowerCase();
        const matches = this._callMentionParticipants().map(pk => {
            const base = this.stripPubkeySuffix(this._nymForPubkey(pk));
            const suffix = this.getPubkeySuffix(pk);
            return { pk, base, suffix, searchable: `${base}#${suffix}`.toLowerCase() };
        }).filter(u => u.searchable.includes(s))
            .sort((a, b) => a.searchable.localeCompare(b.searchable))
            .slice(0, 8);
        if (!matches.length) { this._hideCallMentionAutocomplete(); return; }
        dd.innerHTML = '';
        matches.forEach((u, i) => {
            const item = document.createElement('div');
            item.className = 'call-mention-item' + (i === 0 ? ' selected' : '');
            item.dataset.action = 'selectCallMention';
            item.dataset.pubkey = u.pk;
            const img = document.createElement('img');
            img.className = 'avatar-message';
            img.alt = '';
            img.loading = 'lazy';
            img.src = this.getAvatarUrl(u.pk);
            const strong = document.createElement('strong');
            strong.innerHTML = '@' + this._callNymHtml(u.pk);
            item.appendChild(img);
            item.appendChild(strong);
            dd.appendChild(item);
        });
        dd.classList.add('active');
        this._callMentionIndex = 0;
    },

    _hideCallMentionAutocomplete() {
        const dd = document.getElementById('callMentionAutocomplete');
        if (dd) { dd.classList.remove('active'); dd.innerHTML = ''; }
        this._callMentionIndex = -1;
    },

    _navigateCallMention(direction) {
        const items = document.querySelectorAll('#callMentionAutocomplete .call-mention-item');
        if (!items.length) return;
        items.forEach(el => el.classList.remove('selected'));
        let idx = (typeof this._callMentionIndex === 'number') ? this._callMentionIndex : -1;
        idx += direction;
        if (idx < 0) idx = items.length - 1;
        if (idx >= items.length) idx = 0;
        this._callMentionIndex = idx;
        items[idx].classList.add('selected');
        items[idx].scrollIntoView({ block: 'nearest' });
    },

    _selectCallMention() {
        const selected = document.querySelector('#callMentionAutocomplete .call-mention-item.selected')
            || document.querySelector('#callMentionAutocomplete .call-mention-item');
        if (selected) this._insertCallMention(selected.dataset.pubkey);
    },

    selectCallMention(node) {
        if (node && node.dataset) this._insertCallMention(node.dataset.pubkey);
    },

    _insertCallMention(pubkey) {
        const input = document.getElementById('callChatInput');
        if (!input || !pubkey) return;
        const base = this.stripPubkeySuffix(this._nymForPubkey(pubkey));
        const suffix = this.getPubkeySuffix(pubkey);
        const cursor = typeof input.selectionStart === 'number' ? input.selectionStart : input.value.length;
        const before = input.value.substring(0, cursor);
        const after = input.value.substring(cursor);
        const atIdx = before.lastIndexOf('@');
        if (atIdx === -1) { this._hideCallMentionAutocomplete(); return; }
        const insert = '@' + base + '#' + suffix + ' ';
        input.value = before.substring(0, atIdx) + insert + after;
        const pos = atIdx + insert.length;
        try { input.selectionStart = input.selectionEnd = pos; } catch (_) { }
        input.focus();
        this._hideCallMentionAutocomplete();
    },

    // Invoked from the shared block/unblock paths so blocking from the call's
    // own context menu (or anywhere) updates the live call: a blocked user's
    // chat is hidden and their video drops out of a group call, or the 1:1
    // call ends outright.
    _onUserBlockedForCall(pubkey) {
        const ac = this.activeCall;
        if (!ac || !pubkey) return;
        this._hideCallChatFrom(pubkey, true);
        this._clearCallChatTyping(pubkey);
        const inCall = ac.members.includes(pubkey) || (ac.peers && ac.peers.has(pubkey));
        if (!inCall) return;
        if (!ac.isGroup) {
            this.displaySystemMessage('Left the call — you blocked ' + this._nymForPubkey(pubkey));
            this.hangupCall();
            return;
        }
        // Drop them from the group call: close their connection, stop addressing
        // chat/reactions to them, and remove their tile.
        this._removePeer(pubkey);
        ac.members = ac.members.filter(pk => pk !== pubkey);
        this._renderCallGrid();
        this._updateCallControls();
    },

    _onUserUnblockedForCall(pubkey) {
        if (!this.activeCall || !pubkey) return;
        this._hideCallChatFrom(pubkey, false);
    },

    _hideCallChatFrom(pubkey, hide) {
        const list = document.getElementById('callChatMessages');
        if (!list) return;
        Array.from(list.children).forEach(r => {
            if (r.dataset && r.dataset.pk === pubkey) r.classList.toggle('call-chat-blocked-hidden', hide);
        });
    },

});
