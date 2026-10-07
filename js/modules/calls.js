Object.assign(NYM.prototype, {

    _genCallId() {
        return 'call-' + Math.random().toString(36).slice(2) + Date.now().toString(36);
    },

    _nymForPubkey(pubkey) {
        const resolved = typeof this.resolveDisplayNym === 'function'
            ? this.resolveDisplayNym(pubkey, '') : '';
        if (resolved && resolved.toLowerCase() !== 'nym') return resolved;
        const u = this.users && this.users.get(pubkey);
        if (u && u.nym) return typeof this.parseNymFromDisplay === 'function' ? this.parseNymFromDisplay(u.nym) : u.nym;
        return (pubkey || '').slice(0, 8);
    },

    _callPeerName(pubkey, hint) {
        const convo = this.pmConversations && this.pmConversations.get(pubkey);
        const stored = convo ? '' : (hint || '');
        const raw = typeof this.resolveDisplayNym === 'function' ? this.resolveDisplayNym(pubkey, stored) : stored;
        return typeof this.parseNymFromDisplay === 'function' ? this.parseNymFromDisplay(raw) : (raw || 'nym');
    },

    _callMissedToast(pubkey, hint, isGroup, groupId) {
        const info = { type: 'call', pubkey, isGroup: !!isGroup, groupId: groupId || null };
        if (typeof this._clNotifLocked === 'function' && this._clNotifLocked(info)) {
            this.displaySystemMessage(this._clRedactText().body);
            return;
        }
        this.displaySystemMessage('Missed call from ' + this._callPeerName(pubkey, hint) + '#' + this.getPubkeySuffix(pubkey));
    },

    // `self` renders a plain "You" with no decorations.
    _callNymHtml(pubkey, opts) {
        opts = opts || {};
        if (opts.self || pubkey === this.pubkey) return 'You';
        const base = this.stripPubkeySuffix(opts.name || this._nymForPubkey(pubkey));
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

    // profileOnly trims the message-only actions that don't apply during a call.
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
        const rj = document.getElementById('rejoinCallBtn');
        if (rj) rj.classList.toggle('nm-call-hidden', !(show && !this.currentPM && this.canRejoinGroupCall(this.currentGroup)));
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
        if (this.activeCall || this.incomingCall || this._callStarting) {
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

        this._callStarting = true;
        let stream;
        try { stream = await this._getLocalMedia(kind); } finally { this._callStarting = false; }
        if (!stream) return;
        if (this.activeCall || this.incomingCall) {
            stream.getTracks().forEach(t => { try { t.stop(); } catch (e) { } });
            return;
        }

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
        this._watchLocalTracks(this.activeCall);
        if (typeof this._chBegin === 'function') this._chBegin(this.activeCall, 'out', isGroup ? '' : targets[0]);

        this._broadcastCallSignal(targets, { type: 'invite', callId, kind, isGroup, groupId, members: this.activeCall.members });
        this._ringWakes(targets);
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
            const now = Math.floor(Date.now() / 1000);
            const expiresAt = now + this._callSignalTtl(payload && payload.type);
            const rumor = {
                kind: this.CALL_SIGNALING_KIND,
                created_at: now,
                tags: [['p', targetPubkey], ['expiration', String(expiresAt)]],
                content: JSON.stringify({ ...payload, nym: this.nym }),
                pubkey: this.pubkey
            };
            const groupId = this._callSignalGroupId(payload && payload.callId);
            await this._sendGiftWrapsAsync([targetPubkey], rumor, expiresAt, groupId);
        } catch (e) {
            console.error('Call signal error:', e);
        }
    },

    _WAKE_MAX: 300,
    _WAKE_TTL_MS: 60 * 86400000,

    _shouldShareWake(acceptCalls, isFriend, registered) {
        if (!registered) return false;
        if (acceptCalls === 'disabled') return false;
        if (acceptCalls === 'friends' && !isFriend) return false;
        return true;
    },

    _parseWake(v) {
        if (typeof v !== 'string') return null;
        const w = v.trim().toLowerCase();
        return /^[0-9a-f]{64}$/.test(w) ? w : null;
    },

    _wakeBook() {
        if (this._wakes) return this._wakes;
        let map = {};
        try { map = JSON.parse(localStorage.getItem('nym_call_wakes') || '{}') || {}; } catch (_) { map = {}; }
        this._wakes = map;
        return map;
    },

    _rememberWake(peer, value) {
        const wake = this._parseWake(value);
        if (!wake || !peer || !this.pubkey) return;
        const map = this._wakeBook();
        const key = this.pubkey + ':' + peer;
        const now = Date.now();
        map[key] = { w: wake, t: now };
        const keys = Object.keys(map).filter(k => map[k] && now - map[k].t <= this._WAKE_TTL_MS)
            .sort((a, b) => map[b].t - map[a].t);
        const kept = {};
        keys.slice(0, this._WAKE_MAX).forEach(k => { kept[k] = map[k]; });
        this._wakes = kept;
        try { localStorage.setItem('nym_call_wakes', JSON.stringify(kept)); } catch (_) { }
    },

    _wakeFor(peer) {
        if (!peer || !this.pubkey) return null;
        const r = this._wakeBook()[this.pubkey + ':' + peer];
        if (!r || Date.now() - r.t > this._WAKE_TTL_MS) return null;
        return this._parseWake(r.w);
    },

    _ringWakes(targets) {
        if (typeof fetch !== 'function') return;
        targets.forEach(pk => {
            const wake = this._wakeFor(pk);
            if (!wake) return;
            try {
                fetch('/ring/ring', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ wake }),
                    credentials: 'omit',
                    keepalive: true
                }).catch(() => { });
            } catch (_) { }
        });
    },

    _CALL_INVITE_TTL_SEC: 86400,
    _CALL_SIGNAL_TTL_SEC: 600,

    _callSignalTtl(type) {
        return type === 'invite' ? this._CALL_INVITE_TTL_SEC : this._CALL_SIGNAL_TTL_SEC;
    },

    _callSignalExpired(tags, nowSec) {
        if (!Array.isArray(tags)) return false;
        const tag = tags.find(t => Array.isArray(t) && t[0] === 'expiration');
        if (!tag) return false;
        const exp = Number(tag[1]);
        if (!Number.isFinite(exp) || !/^\d+$/.test(String(tag[1]))) return false;
        return nowSec > exp;
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
        if (this.blockedUsers && this.blockedUsers.has(sender)) return;
        if (this._callSignalExpired(event.tags, Math.floor(Date.now() / 1000))) return;
        let data;
        try { data = JSON.parse(event.content); } catch (e) { return; }
        if (data && data.wake !== undefined) this._rememberWake(sender, data.wake);
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
            case 'video': this._onCallVideo(sender, data); break;
            case 'present-state': this._onPresentState(sender, data); break;
            case 'present-request': this._onPresentRequest(sender, data); break;
            case 'reaction': this._onCallReaction(sender, data); break;
            case 'chat': this._onCallChat(sender, data); break;
            case 'chat-reaction': this._onCallChatReaction(sender, data); break;
            case 'chat-typing': this._onCallChatTyping(sender, data); break;
            case 'chat-read': this._onCallChatRead(sender, data); break;
        }
    },

    // Records persist 24h to match the notification window.
    _CALL_SEEN_TTL_SEC: 86400,
    // Higher rank wins on merge so an answered status isn't lost to a synced pending one.
    _CALL_STATUS_RANK: { seen: 0, pending: 1, missed: 2, declined: 3, answered: 4 },

    _getSeenCalls() {
        if (this._seenCalls) return this._seenCalls;
        let map = {};
        try { map = JSON.parse(localStorage.getItem('nym_seen_calls') || '{}') || {}; } catch (_) { map = {}; }
        this._seenCalls = map;
        return map;
    },

    // Normalize a stored value (legacy number or {t,s}) to {t,s} or null.
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

    // Merge seen-call maps from other devices so calls handled elsewhere aren't re-rung or shown as missed.
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
        if (nowAnswered.length && typeof this._retractMissedCallNotification === 'function') {
            nowAnswered.forEach(id => this._retractMissedCallNotification(id));
        }
        if (typeof this._chAnsweredElsewhere === 'function') nowAnswered.forEach(id => this._chAnsweredElsewhere(id));
    },

    _recordMissedCall(callerPubkey, callerNym, kind, callId, isGroup, groupId, whenMs) {
        if (!callerPubkey || !callId) return;
        const niceKind = kind === 'video' ? 'video' : 'audio';
        const baseTitle = this._callPeerName(callerPubkey, callerNym || this._nymForPubkey(callerPubkey));
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
        if (typeof this._chMissed === 'function') this._chMissed(callId, callerPubkey, niceKind, isGroup, groupId, whenMs);
    },

    _onCallInvite(sender, data, event) {
        if (this._hasSeenCall(data.callId)) return;
        const linkJoin = typeof this._gtLinkJoinMatches === 'function' && this._gtLinkJoinMatches(sender, data);

        const glare = this._callGlare(sender, data);

        const pref = (this.settings && this.settings.acceptCalls) || 'enabled';
        if (pref === 'disabled' && !linkJoin && !glare) return;
        if (pref === 'friends' && !this.isFriend(sender) && !linkJoin && !glare) return;
        if (this.blockedUsers && this.blockedUsers.has(sender)) return;

        // Stale invites within the seen-call window are logged as missed calls rather than dropped.
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

        if (glare === 'keep') return;
        if (glare === 'yield') this._endCall();

        if (this.activeCall || this.incomingCall) {
            this._markCallSeen(data.callId, 'missed');
            this._sendCallSignal(sender, { type: 'reject', callId: data.callId, reason: 'busy' });
            const busyNym = data.nym || this._nymForPubkey(sender);
            this._callMissedToast(sender, busyNym, data.isGroup, data.groupId);
            this._recordMissedCall(sender, busyNym, data.kind, data.callId, data.isGroup, data.groupId);
            return;
        }

        const isGroup = !!data.isGroup;
        const groupId = data.groupId || null;
        const members = [sender, this.pubkey];
        if (isGroup && (groupId || linkJoin)) {
            const g = groupId && this.groupConversations && this.groupConversations.get(groupId);
            const roster = (g && Array.isArray(g.members) && g.members.length) ? g.members : null;
            const claimed = Array.isArray(data.members) ? data.members : [];
            claimed.forEach(pk => {
                if (pk && pk !== sender && pk !== this.pubkey && !members.includes(pk) &&
                    (!roster || roster.includes(pk))) {
                    members.push(pk);
                }
            });
        }

        this.incomingCall = {
            callId: data.callId,
            kind: data.kind === 'video' ? 'video' : 'audio',
            isGroup,
            groupId,
            from: sender,
            nym: data.nym || this._nymForPubkey(sender),
            members,
            acceptedPeers: new Set(),
            timeout: null,
            chAt: Date.now()
        };
        if (linkJoin || glare === 'yield') {
            if (linkJoin) this._gtLinkJoin = null;
            this.acceptCall();
            return;
        }
        this._showIncomingCallUI();
        this._startRingtone();
        this.incomingCall.timeout = setTimeout(() => {
            if (this.incomingCall && this.incomingCall.callId === data.callId) {
                const inc = this.incomingCall;
                this._stopRingtone();
                this._hideIncomingCallUI();
                this.incomingCall = null;
                this._markCallSeen(inc.callId, 'missed');
                this._callMissedToast(inc.from, inc.nym, inc.isGroup, inc.groupId);
                this._recordMissedCall(inc.from, inc.nym, inc.kind, inc.callId, inc.isGroup, inc.groupId);
            }
        }, 45000);
    },

    _callGlare(sender, data) {
        const ac = this.activeCall;
        if (!ac || ac.isGroup || data.isGroup || ac.status !== 'outgoing' || ac.gtLinkId || data.link) return null;
        if (!data.callId || ac.callId === data.callId) return null;
        if (ac.members.find(pk => pk !== this.pubkey) !== sender) return null;
        return ac.callId < data.callId ? 'keep' : 'yield';
    },

    async acceptCall() {
        const inc = this.incomingCall;
        if (!inc || inc.accepting) return;
        inc.accepting = true;
        this._stopRingtone();
        if (inc.timeout) clearTimeout(inc.timeout);
        this._hideIncomingCallUI();

        const stream = await this._getLocalMedia(inc.kind);
        if (this.incomingCall !== inc) {
            if (stream) stream.getTracks().forEach(t => { try { t.stop(); } catch (e) { } });
            return;
        }
        this._markCallSeen(inc.callId, stream ? 'answered' : 'declined');
        if (!stream) {
            this._sendCallSignal(inc.from, { type: 'reject', callId: inc.callId, reason: 'media' });
            if (typeof this._chDeclined === 'function') this._chDeclined(inc);
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
        this._watchLocalTracks(this.activeCall);
        if (typeof this._chBegin === 'function') this._chBegin(this.activeCall, 'in', inc.from, inc.chAt);
        this.incomingCall = null;

        this._showCallOverlay();
        this._setCallStatus('Connecting…');
        this._armCallWatchdog(this.activeCall);

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
        if (typeof this._chDeclined === 'function') this._chDeclined(inc);
        this.incomingCall = null;
    },

    _isCallParticipant(call, sender) {
        return !!(call && Array.isArray(call.members) && call.members.includes(sender));
    },

    _onCallAccept(sender, data) {
        if (this.activeCall && this.activeCall.callId === data.callId) {
            if (!this._isCallParticipant(this.activeCall, sender)) return;
            if (this.activeCall.status === 'outgoing') {
                this.activeCall.status = 'connecting';
                if (this.activeCall.ringTimeout) clearTimeout(this.activeCall.ringTimeout);
                this._setCallStatus('Connecting…');
                this._armCallWatchdog(this.activeCall);
            }
            this._connectToPeer(sender);
            return;
        }
        if (this.incomingCall && this.incomingCall.callId === data.callId) {
            if (!this._isCallParticipant(this.incomingCall, sender)) return;
            this.incomingCall.acceptedPeers.add(sender);
        }
    },

    _onCallReject(sender, data) {
        const ac = this.activeCall;
        if (!ac || ac.callId !== data.callId) return;
        if (!this._isCallParticipant(ac, sender)) return;
        if (!ac.isGroup) {
            this.displaySystemMessage(data.reason === 'busy' ? 'User is busy' : 'Call declined');
            this._endCall();
            return;
        }
        if (!ac.declined) ac.declined = new Set();
        ac.declined.add(sender);
        if (ac.status !== 'outgoing') return;
        const others = ac.members.filter(pk => pk !== this.pubkey);
        if (others.length && others.every(pk => ac.declined.has(pk))) {
            this.displaySystemMessage('Everyone declined the call');
            this._endCall();
        }
    },

    _watchLocalTracks(ac) {
        if (!ac || !ac.localStream) return;
        ac.localStream.getTracks().forEach(t => this._watchLocalTrack(ac, t));
    },

    _watchLocalTrack(ac, track) {
        if (!track) return;
        track.onended = () => this._onLocalTrackEnded(ac, track);
    },

    _onLocalTrackEnded(ac, track) {
        if (this.activeCall !== ac || !ac.localStream.getTracks().includes(track)) return;
        if (track.kind === 'audio') {
            this.displaySystemMessage('Microphone access was lost, so the call ended');
            this.hangupCall();
            return;
        }
        ac.localStream.removeTrack(track);
        if (!ac.sharing) {
            ac.peers.forEach(entry => { if (entry.videoSender) { try { entry.videoSender.replaceTrack(null); } catch (e) { } } });
        }
        ac.cameraOff = true;
        const others = ac.members.filter(pk => pk !== this.pubkey);
        this._broadcastCallSignal(others, { type: 'video', callId: ac.callId, on: false });
        this.displaySystemMessage('Camera access was lost. The call continues with audio.');
        this._updateCallVideoBtn();
        this._updateCameraSwitchBtn();
        this._renderCallGrid();
    },

    _onCallCancel(sender, data) {
        if (this.incomingCall && this.incomingCall.callId === data.callId) {
            if (sender !== this.incomingCall.from) return;
            const inc = this.incomingCall;
            this._stopRingtone();
            if (inc.timeout) clearTimeout(inc.timeout);
            this._markCallSeen(inc.callId, 'missed');
            this._hideIncomingCallUI();
            this.incomingCall = null;
            this._callMissedToast(inc.from, inc.nym, inc.isGroup, inc.groupId);
            this._recordMissedCall(inc.from, inc.nym, inc.kind, inc.callId, inc.isGroup, inc.groupId);
        }
    },

    _onCallHangup(sender, data) {
        this._onLeftCallHangup(sender, data);
        const inc = this.incomingCall;
        if (inc && inc.callId === data.callId && !inc.isGroup && sender === inc.from) {
            this._onCallCancel(sender, data);
            return;
        }
        if (!this.activeCall || this.activeCall.callId !== data.callId) return;
        if (!this._isCallParticipant(this.activeCall, sender)) return;
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
        const early = this.activeCall.earlyIce && this.activeCall.earlyIce.get(peerPubkey);
        if (early) this.activeCall.earlyIce.delete(peerPubkey);
        const entry = {
            pc,
            stream: new MediaStream(),
            pendingCandidates: early || [],
            haveRemote: false,
            videoSender: null,
            nym: this._nymForPubkey(peerPubkey)
        };
        if (this.activeCall.peerVideo && this.activeCall.peerVideo.has(peerPubkey)) entry.videoOn = this.activeCall.peerVideo.get(peerPubkey);
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
                } catch (e) { }
            }
            this._sendCallSignal(peerPubkey, { type: 'share', callId: this.activeCall.callId, on: true });
        }
        if (this.activeCall.kind === 'video' && this.activeCall.localStream.getVideoTracks().length) {
            this._sendCallSignal(peerPubkey, { type: 'video', callId: this.activeCall.callId, on: !this.activeCall.cameraOff });
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
            const ac = this.activeCall;
            if (ac && !ac.isGroup && ac.peers.get(peerPubkey) === entry) {
                if (pc.connectionState === 'connected') {
                    entry.restarting = false;
                    this._clearCallWatchdog(ac);
                } else if (pc.connectionState === 'disconnected' || pc.connectionState === 'failed') {
                    this._armCallWatchdog(ac);
                    if (!entry.restarting && this.pubkey < peerPubkey) {
                        entry.restarting = true;
                        this._makeOffer(peerPubkey, { iceRestart: true });
                    }
                }
            }
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

    async _makeOffer(peerPubkey, opts) {
        const ac = this.activeCall;
        const entry = ac && ac.peers.get(peerPubkey);
        if (!entry) return;
        if (opts && opts.iceRestart && entry.pc.signalingState !== 'stable') return;
        try {
            const offer = await entry.pc.createOffer(opts || undefined);
            await entry.pc.setLocalDescription(offer);
            if (this.activeCall !== ac) return;
            this._sendCallSignal(peerPubkey, { type: 'offer', callId: ac.callId, sdp: entry.pc.localDescription });
        } catch (e) {
            console.error('Make offer error:', e);
        }
    },

    async _onCallOffer(sender, data) {
        if (!this.activeCall || this.activeCall.callId !== data.callId) return;
        if (!this._isCallParticipant(this.activeCall, sender)) return;
        if (!this.activeCall.peers.has(sender)) this._connectToPeer(sender);
        const entry = this.activeCall.peers.get(sender);
        if (!entry) return;
        const collision = this._offerCollision(sender, entry.pc.signalingState);
        if (collision === 'ignore') return;
        try {
            if (collision === 'rollback') {
                await entry.pc.setLocalDescription({ type: 'rollback' });
                entry.renegotiate = true;
            }
            await entry.pc.setRemoteDescription(new RTCSessionDescription(data.sdp));
            entry.haveRemote = true;
            await this._flushCandidates(sender);
            const answer = await entry.pc.createAnswer();
            await entry.pc.setLocalDescription(answer);
            this._sendCallSignal(sender, { type: 'answer', callId: this.activeCall.callId, sdp: entry.pc.localDescription });
            if (entry.renegotiate) {
                entry.renegotiate = false;
                this._makeOffer(sender);
            }
        } catch (e) {
            console.error('Handle offer error:', e);
        }
    },

    _offerCollision(peerPubkey, signalingState) {
        if (signalingState === 'stable' || signalingState === 'have-remote-offer') return 'answer';
        if (signalingState === 'have-local-offer') return this.pubkey < peerPubkey ? 'ignore' : 'rollback';
        return 'ignore';
    },

    async _onCallAnswer(sender, data) {
        if (!this._isCallParticipant(this.activeCall, sender)) return;
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
        const ac = this.activeCall;
        if (!ac || ac.callId !== data.callId || !data.candidate) return;
        if (!this._isCallParticipant(ac, sender)) return;
        const entry = ac.peers.get(sender);
        if (!entry) {
            if (!ac.earlyIce) ac.earlyIce = new Map();
            const list = ac.earlyIce.get(sender) || [];
            if (list.length < 64) list.push(data.candidate);
            ac.earlyIce.set(sender, list);
            return;
        }
        if (entry.haveRemote) {
            try { await entry.pc.addIceCandidate(new RTCIceCandidate(data.candidate)); } catch (e) { }
        } else {
            entry.pendingCandidates.push(data.candidate);
        }
    },

    async _flushCandidates(peerPubkey) {
        const entry = this.activeCall && this.activeCall.peers.get(peerPubkey);
        if (!entry) return;
        for (const c of entry.pendingCandidates) {
            try { await entry.pc.addIceCandidate(new RTCIceCandidate(c)); } catch (e) { }
        }
        entry.pendingCandidates = [];
    },

    _removePeer(peerPubkey) {
        if (!this.activeCall) return;
        const entry = this.activeCall.peers.get(peerPubkey);
        if (entry) {
            try { entry.pc.close(); } catch (e) { }
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

    _CALL_LOST_MS: 30000,

    _armCallWatchdog(ac) {
        if (!ac || ac.isGroup || ac.lostTimer) return;
        ac.lostTimer = setTimeout(() => {
            ac.lostTimer = null;
            if (this.activeCall !== ac) return;
            for (const entry of ac.peers.values()) {
                if (entry.pc.connectionState === 'connected') return;
            }
            this.displaySystemMessage('Call connection lost');
            this.hangupCall();
        }, this._CALL_LOST_MS);
    },

    _clearCallWatchdog(ac) {
        if (ac && ac.lostTimer) { clearTimeout(ac.lostTimer); ac.lostTimer = null; }
    },

    hangupCall() {
        if (!this.activeCall) return;
        const left = this.activeCall;
        if (left.isGroup && left.groupId && left.status !== 'outgoing' && left.peers.size > 0) {
            this._leftGroupCall = {
                callId: left.callId, groupId: left.groupId, kind: left.kind,
                members: left.members.slice(), remaining: new Set(left.peers.keys()), at: Date.now()
            };
        }
        const targets = this.activeCall.members.filter(pk => pk !== this.pubkey);
        if (this.activeCall.status === 'outgoing') this._broadcastCallSignal(targets, { type: 'cancel', callId: this.activeCall.callId });
        this._broadcastCallSignal(targets, { type: 'hangup', callId: this.activeCall.callId });
        this._endCall();
    },

    _endCall() {
        const ac = this.activeCall;
        if (ac) {
            if (typeof this._chFinish === 'function') this._chFinish(ac);
            if (ac.ringTimeout) clearTimeout(ac.ringTimeout);
            if (ac.timerInterval) clearInterval(ac.timerInterval);
            this._clearCallWatchdog(ac);
            ac.peers.forEach(entry => { try { entry.pc.close(); } catch (e) { } });
            ac.peers.clear();
            if (ac.chatTypers) { ac.chatTypers.forEach(e => { if (e.timeout) clearTimeout(e.timeout); }); ac.chatTypers.clear(); }
            if (this._callTypingStopTimer) { clearTimeout(this._callTypingStopTimer); this._callTypingStopTimer = null; }
            this._callTypingThrottle = 0;
            if (ac.localStream) ac.localStream.getTracks().forEach(t => { try { t.stop(); } catch (e) { } });
            if (ac.screenStream) ac.screenStream.getTracks().forEach(t => { try { t.stop(); } catch (e) { } });
        }
        this.activeCall = null;
        this._stopRingtone();
        this._hideCallOverlay();
        this._refreshCallButtons();
    },

    _REJOIN_WINDOW_MS: 3 * 60 * 60 * 1000,

    canRejoinGroupCall(groupId) {
        const r = this._leftGroupCall;
        if (!r || !groupId || r.groupId !== groupId || this.activeCall || this.incomingCall) return false;
        if (!r.remaining.size || Date.now() - r.at > this._REJOIN_WINDOW_MS) return false;
        return true;
    },

    _onLeftCallHangup(sender, data) {
        const r = this._leftGroupCall;
        if (!r || r.callId !== data.callId) return;
        r.remaining.delete(sender);
        if (!r.remaining.size) {
            this._leftGroupCall = null;
            this._refreshCallButtons();
        }
    },

    async rejoinGroupCall(groupId) {
        const gid = groupId || this.currentGroup;
        if (!this.canRejoinGroupCall(gid) || this._callStarting) return;
        const r = this._leftGroupCall;
        this._callStarting = true;
        let stream;
        try { stream = await this._getLocalMedia(r.kind); } finally { this._callStarting = false; }
        if (!stream) return;
        if (this.activeCall || this.incomingCall || this._leftGroupCall !== r) {
            stream.getTracks().forEach(t => { try { t.stop(); } catch (e) { } });
            return;
        }
        this._leftGroupCall = null;
        this.activeCall = {
            callId: r.callId,
            kind: r.kind,
            isGroup: true,
            groupId: r.groupId,
            localStream: stream,
            status: 'connecting',
            peers: new Map(),
            members: r.members.slice(),
            muted: false,
            cameraOff: false,
            facingMode: 'user',
            startedAt: 0,
            timerInterval: null,
            ringTimeout: null
        };
        this._initCallExtras(this.activeCall);
        this._watchLocalTracks(this.activeCall);
        this._showCallOverlay();
        this._setCallStatus('Connecting…');
        const others = this.activeCall.members.filter(pk => pk !== this.pubkey);
        this._broadcastCallSignal(others, { type: 'accept', callId: r.callId });
        r.remaining.forEach(pk => this._connectToPeer(pk));
        this._refreshCallButtons();
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

    async toggleCallVideo() {
        const ac = this.activeCall;
        if (!ac) return;
        if (!ac.localStream.getVideoTracks().length) {
            await this._upgradeCallToVideo();
            return;
        }
        ac.cameraOff = !ac.cameraOff;
        ac.localStream.getVideoTracks().forEach(t => { t.enabled = !ac.cameraOff; });
        const others = ac.members.filter(pk => pk !== this.pubkey);
        this._broadcastCallSignal(others, { type: 'video', callId: ac.callId, on: !ac.cameraOff });
        this._updateCallVideoBtn();
        this._renderCallGrid();
    },

    async _getCameraTrack() {
        try {
            const stream = await navigator.mediaDevices.getUserMedia({
                audio: false,
                video: { width: { ideal: 1280 }, height: { ideal: 720 }, facingMode: 'user' }
            });
            const track = stream.getVideoTracks()[0] || null;
            stream.getTracks().forEach(t => { if (t !== track) { try { t.stop(); } catch (e) { } } });
            return track;
        } catch (e) {
            this.displaySystemMessage('Could not access camera: ' + (e.message || e.name || e));
            return null;
        }
    },

    async _upgradeCallToVideo() {
        const ac = this.activeCall;
        if (!ac || ac.upgradingVideo) return;
        ac.upgradingVideo = true;
        let track;
        try { track = await this._getCameraTrack(); } finally { ac.upgradingVideo = false; }
        if (!track) return;
        if (this.activeCall !== ac) { try { track.stop(); } catch (e) { } return; }
        this._watchLocalTrack(ac, track);
        ac.localStream.addTrack(track);
        ac.kind = 'video';
        ac.cameraOff = false;
        ac.facingMode = 'user';
        ac.peers.forEach((entry, pk) => {
            if (entry.videoSender) {
                if (!ac.sharing) { try { entry.videoSender.replaceTrack(track); } catch (e) { } }
                return;
            }
            try {
                entry.videoSender = entry.pc.addTrack(track, ac.localStream);
                this._makeOffer(pk);
            } catch (e) { }
        });
        const others = ac.members.filter(pk => pk !== this.pubkey);
        this._broadcastCallSignal(others, { type: 'video', callId: ac.callId, on: true });
        this._onCallKindChanged();
    },

    _onCallVideo(sender, data) {
        const ac = this.activeCall;
        if (!ac || ac.callId !== data.callId) return;
        if (!this._isCallParticipant(ac, sender)) return;
        const on = data.on === true;
        if (!ac.peerVideo) ac.peerVideo = new Map();
        ac.peerVideo.set(sender, on);
        const entry = ac.peers.get(sender);
        if (entry) entry.videoOn = on;
        if (on && ac.kind !== 'video') {
            ac.kind = 'video';
            this._onCallKindChanged();
            return;
        }
        this._renderCallGrid();
    },

    _onCallKindChanged() {
        this._refreshCallTitle();
        this._updateCallVideoBtn();
        this._updateCameraSwitchBtn();
        this._renderCallGrid();
    },

    _updateCallVideoBtn() {
        const btn = document.getElementById('callVideoBtn');
        const ac = this.activeCall;
        if (!btn || !ac) return;
        const hasCam = ac.localStream.getVideoTracks().length > 0;
        const off = !hasCam || ac.cameraOff;
        btn.classList.remove('nm-call-hidden');
        btn.classList.toggle('active', hasCam && ac.cameraOff);
        const label = off ? 'Turn on camera' : 'Turn off camera';
        btn.title = typeof this.uiText === 'function' ? this.uiText(label) : label;
        btn.setAttribute('aria-label', btn.title);
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
        this._watchLocalTrack(ac, newTrack);
        if (!newTrack) { stream.getTracks().forEach(t => t.stop()); ac.switchingCamera = false; this._updateCallControls(); return; }
        newTrack.enabled = !ac.cameraOff;
        const oldTrack = ac.localStream.getVideoTracks()[0];
        if (oldTrack) { ac.localStream.removeTrack(oldTrack); try { oldTrack.stop(); } catch (e) { } }
        ac.localStream.addTrack(newTrack);
        if (!ac.sharing) {
            ac.peers.forEach(entry => { if (entry.videoSender) { try { entry.videoSender.replaceTrack(newTrack); } catch (e) { } } });
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
            } catch (e) { }
        }
        if (!this.activeCall || this.activeCall !== ac) return;
        btn.classList.toggle('nm-call-hidden', !show);
    },

    _callSinkSupported() {
        return typeof HTMLMediaElement !== 'undefined' && !!HTMLMediaElement.prototype
            && typeof HTMLMediaElement.prototype.setSinkId === 'function';
    },

    async _callAudioOutputs() {
        if (!this._callSinkSupported()) return [];
        const md = navigator.mediaDevices;
        if (!md || typeof md.enumerateDevices !== 'function') return [];
        try {
            const devices = await md.enumerateDevices();
            return devices.filter(d => d.kind === 'audiooutput' && d.deviceId)
                .map(d => ({ deviceId: d.deviceId, label: d.label || '' }));
        } catch (e) {
            return [];
        }
    },

    async _updateCallOutputBtn() {
        const btn = document.getElementById('callOutputBtn');
        if (!btn) return;
        const ac = this.activeCall;
        const outs = ac ? await this._callAudioOutputs() : [];
        if (this.activeCall !== ac) return;
        btn.classList.toggle('nm-call-hidden', outs.length < 2);
        if (outs.length < 2) this._closeCallOutputMenu();
        if (ac && !this._callDeviceWatch && navigator.mediaDevices && typeof navigator.mediaDevices.addEventListener === 'function') {
            this._callDeviceWatch = () => { if (this.activeCall) this._updateCallOutputBtn(); };
            try { navigator.mediaDevices.addEventListener('devicechange', this._callDeviceWatch); } catch (e) { }
        }
    },

    _applyCallSink(video) {
        if (!video || !this._callSinkId || typeof video.setSinkId !== 'function') return Promise.resolve();
        return video.setSinkId(this._callSinkId).catch(() => { });
    },

    async selectCallAudioOutput(deviceId) {
        if (!deviceId || !this._callSinkSupported()) return;
        this._callSinkId = deviceId;
        const vids = Array.from(document.querySelectorAll('#callGrid .call-tile:not([data-tile="local"]) video'));
        await Promise.all(vids.map(v => this._applyCallSink(v)));
        this._closeCallOutputMenu();
    },

    async toggleCallOutputMenu() {
        const menu = document.getElementById('callOutputMenu');
        if (!menu) return;
        if (menu.classList.contains('active')) { this._closeCallOutputMenu(); return; }
        this._closeCallReactions();
        this._closePresenterMenu();
        const outs = await this._callAudioOutputs();
        const ui = (t) => (typeof this.uiText === 'function' ? this.uiText(t) : t);
        menu.innerHTML = '';
        const head = document.createElement('div');
        head.className = 'call-presenter-head';
        head.textContent = ui('Audio output');
        menu.appendChild(head);
        const current = this._callSinkId || 'default';
        outs.forEach((o, i) => {
            const b = document.createElement('button');
            b.type = 'button';
            b.className = 'call-output-option' + (o.deviceId === current ? ' selected' : '');
            b.dataset.action = 'selectCallOutput';
            b.dataset.deviceId = o.deviceId;
            b.textContent = o.label || ui('Speaker') + ' ' + (i + 1);
            menu.appendChild(b);
        });
        menu.classList.add('active');
    },

    _closeCallOutputMenu() {
        const menu = document.getElementById('callOutputMenu');
        if (menu) menu.classList.remove('active');
    },

    _callTitleHtml(opts) {
        if (!this.activeCall) return '';
        const fetch = !(opts && opts.noFetch);
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
            if (fetch && typeof this.ensureListProfiles === 'function') this.ensureListProfiles(null, others.slice(0, 4), () => this._refreshCallTitle({ noFetch: true }));
            return `${prefix}<span class="group-header-row call-title-id"><span class="group-header-icon">${groupSvg}</span>${avatars}<span class="group-name-text ${others.length ? 'nm-grp-ml8' : ''}">${this.escapeHtml(name)}</span></span>`;
        }
        const peer = this.activeCall.members.find(pk => pk !== this.pubkey);
        if (fetch && peer && typeof this.ensureListProfiles === 'function') this.ensureListProfiles(null, [peer], () => this._refreshCallTitle({ noFetch: true }));
        const avatar = `<img src="${this.escapeHtml(this.getAvatarUrl(peer))}" class="avatar-message call-title-avatar" data-avatar-pubkey="${this._safePubkey(peer)}" alt="" decoding="async" loading="lazy">`;
        return `${prefix}<span class="call-title-id">${avatar}<span class="call-title-nym">${this._callNymHtml(peer)}</span></span>`;
    },

    _refreshCallTitle(opts) {
        const title = document.getElementById('callTitle');
        if (title && this.activeCall) title.innerHTML = this._callTitleHtml(opts);
    },

    _showCallOverlay() {
        const ov = document.getElementById('callOverlay');
        if (!ov || !this.activeCall) return;
        ov.classList.add('active');
        const title = document.getElementById('callTitle');
        if (title) title.innerHTML = this._callTitleHtml();
        this._updateCallVideoBtn();
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
        this._updateCallOutputBtn();
        this._renderCallGrid();
    },

    _hideCallOverlay() {
        const ov = document.getElementById('callOverlay');
        if (ov) ov.classList.remove('active');
        this._hideCallMentionAutocomplete();
        const grid = document.getElementById('callGrid');
        if (grid) grid.innerHTML = '';
        ['callChatPanel', 'callReactionsBar', 'callPresenterMenu', 'callOutputMenu'].forEach(id => {
            const el = document.getElementById(id); if (el) el.classList.remove('active');
        });
        if (this._callDeviceWatch && navigator.mediaDevices && typeof navigator.mediaDevices.removeEventListener === 'function') {
            try { navigator.mediaDevices.removeEventListener('devicechange', this._callDeviceWatch); } catch (e) { }
        }
        this._callDeviceWatch = null;
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
            else this._applyCallSink(video);
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

        const peerEntry = !isLocal && pubkey ? this.activeCall.peers.get(pubkey) : null;
        const peerOff = !!(peerEntry && peerEntry.videoOn === false);
        const hasVideo = stream && stream.getVideoTracks().length > 0
            && (sharing || (this.activeCall.kind === 'video' && !(isLocal && this.activeCall.cameraOff) && !peerOff));
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
        } catch (e) { }
    },

    _stopRingtone() {
        if (this._ringInterval) { clearInterval(this._ringInterval); this._ringInterval = null; }
        if (this._ringCtx) { try { this._ringCtx.close(); } catch (e) { } this._ringCtx = null; }
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
                try { entry.videoSender.replaceTrack(track); } catch (e) { }
            } else {
                try {
                    entry.videoSender = entry.pc.addTrack(track, stream);
                    this._makeOffer(pk);
                } catch (e) { }
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
        ac.peers.forEach(entry => { if (entry.videoSender) { try { entry.videoSender.replaceTrack(cam); } catch (e) { } } });
        if (ac.screenStream) ac.screenStream.getTracks().forEach(t => { try { t.stop(); } catch (e) { } });
        ac.screenStream = null;
        ac.sharing = false;
        const others = ac.members.filter(pk => pk !== this.pubkey);
        this._broadcastCallSignal(others, { type: 'share', callId: ac.callId, on: false });
        this._updateCallControls();
        this._renderCallGrid();
    },

    _onCallShare(sender, data) {
        const ac = this.activeCall;
        if (!ac || ac.callId !== data.callId || !this._isCallParticipant(ac, sender)) return;
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
        if (!ac || ac.callId !== data.callId || !this._isCallMod() || !this._isCallParticipant(ac, sender)) return;
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
        if (!ac || ac.callId !== data.callId || !this.isValidReactionEmoji(data.emoji)) return;
        if (!this._isCallParticipant(ac, sender)) return;
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
        if (!this._isCallParticipant(ac, sender)) return;
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
        if (!this._isCallParticipant(ac, sender)) return;
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

    // Broadcast to all members so the sender records us as a reader; non-senders ignore unknown mids.
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
        if (!this._isCallParticipant(ac, sender)) return;
        const mine = ac.chatLog.find(m => m.mid === data.mid && m.isSelf);
        if (!mine) return;
        if (!ac.chatReaders) ac.chatReaders = new Map();
        if (!ac.chatReaders.has(data.mid)) ac.chatReaders.set(data.mid, new Map());
        ac.chatReaders.get(data.mid).set(sender, this._nymForPubkey(sender));
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
                window.nymHaptic && window.nymHaptic('selection');
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

    // Match on the raw text and escape segments individually so the regex can't split an HTML entity.
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

    callChatReact(e, node) {
        if (!this.activeCall || !node) return;
        const row = node.closest ? node.closest('.call-chat-msg') : null;
        if (row) this._showCallChatQuickReact(row, e);
    },

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
        popup.className = 'quick-react-popup call-quick-react active';
        popup.style.position = 'fixed';
        popup.style.zIndex = '10050';
        popup.innerHTML = this._callQuickEmojis().map(emoji => {
            const cm = typeof emoji === 'string' && emoji.match(/^:([a-zA-Z0-9_]+):$/);
            if (cm && this.customEmojis && this.customEmojis.has(cm[1])) {
                return `<button class="quick-react-emoji" data-emoji=":${this.escapeHtml(cm[1])}:">${this.renderCustomEmojiImg(cm[1])}</button>`;
            }
            return `<button class="quick-react-emoji" data-emoji="${this.escapeHtml(emoji)}">${this.escapeHtml(emoji)}</button>`;
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
                window.nymHaptic && window.nymHaptic('selection');
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
        if (!ac || ac.callId !== data.callId || !data.mid || !this.isValidReactionEmoji(data.emoji)) return;
        if (!this._isCallParticipant(ac, sender)) return;
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
            addBtn.setAttribute('role', 'button');
            addBtn.setAttribute('aria-label', typeof this.uiText === 'function' ? this.uiText('Add reaction') : 'Add reaction');
            addBtn.tabIndex = 0;
            addBtn.addEventListener('keydown', (e) => {
                if (e.key !== 'Enter' && e.key !== ' ') return;
                e.preventDefault();
                addBtn.click();
            });
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

    // Invoked from the shared block/unblock paths so blocking updates the live call.
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
