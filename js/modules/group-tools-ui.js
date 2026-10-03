(function () {
    const T = () => window.NymGroupTools;
    const ico = (p) => `<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" class="nm-ico8">${p}</svg>`;
    const ICONS = {
        slowmode: ico('<circle cx="8" cy="9" r="5.5"/><path d="M8 6v3l2 1.5"/><path d="M6 1.5h4"/>'),
        approval: ico('<circle cx="6" cy="5.5" r="2.5"/><path d="M2 14c0-3 2-4.5 4-4.5"/><path d="M9.5 11.5l1.8 1.8 3.2-3.6"/>'),
        requests: ico('<circle cx="6" cy="5.5" r="2.5"/><path d="M2 14c0-3 2-4.5 4-4.5s4 1.5 4 4.5"/><path d="M12 4v4M10 6h4"/>'),
        event: ico('<rect x="2" y="3" width="12" height="11" rx="1.5"/><path d="M2 6.5h12M5.5 1.5v3M10.5 1.5v3"/>'),
        location: ico('<path d="M8 14.5s4.5-4.2 4.5-8a4.5 4.5 0 0 0-9 0c0 3.8 4.5 8 4.5 8z"/><circle cx="8" cy="6.5" r="1.6"/>'),
        callLink: ico('<path d="M6.5 9.5l3-3"/><path d="M7 4.5l1.2-1.2a2.5 2.5 0 0 1 3.5 3.5L10.5 8"/><path d="M9 11.5l-1.2 1.2a2.5 2.5 0 0 1-3.5-3.5L5.5 8"/>'),
    };
    const RSVP_KEY = 'nym_gt_rsvps_';
    const REMINDER_KEY = 'nym_gt_reminders';
    const CALL_LINKS_KEY = 'nym_gt_call_links_';
    const PENDING_JOINS_KEY = 'nym_gt_pending_joins_';
    const LIVE_KEY = 'nym_gt_live_share';
    const SUMMARY_TTL_MS = 10 * 60 * 1000;
    const LINK_JOIN_WAIT_MS = 120000;
    const TZ_OFFSETS = [-720, -660, -600, -540, -480, -420, -360, -300, -240, -210, -180, -120, -60, 0, 60, 120, 180, 210, 240, 270, 300, 330, 345, 360, 390, 420, 480, 540, 570, 600, 630, 660, 720, 765, 780, 840];

    function rand(bytes) {
        const a = new Uint8Array(bytes);
        crypto.getRandomValues(a);
        return Array.from(a, (b) => b.toString(16).padStart(2, '0')).join('');
    }

    function nowSec() {
        return Math.floor(Date.now() / 1000);
    }

    function load(key, fallback) {
        try {
            const raw = localStorage.getItem(key);
            return raw ? JSON.parse(raw) : fallback;
        } catch (_) { return fallback; }
    }

    function save(key, value) {
        try { localStorage.setItem(key, JSON.stringify(value)); } catch (_) { }
    }

    Object.assign(NYM.prototype, {

        _gx(text, vars) {
            let s = typeof this.uiText === 'function' ? this.uiText(text) : text;
            if (vars) for (const k of Object.keys(vars)) s = s.split('{' + k + '}').join(String(vars[k]));
            return s;
        },

        _gtNotice(text) {
            if (typeof this.displaySystemMessage === 'function') this.displaySystemMessage(text);
        },

        _gtRole(groupId, pubkey) {
            if (this._isGroupOwner(groupId, pubkey)) return 'owner';
            if (this._isGroupAdmin(groupId, pubkey)) return 'admin';
            if (this._isGroupMod(groupId, pubkey)) return 'mod';
            return 'member';
        },

        _gtNymTag(pk) {
            const raw = pk === this.pubkey ? this.nym : this.getNymFromPubkey(pk);
            return String(raw || 'nym').replace(/(#[0-9a-f]{4})+$/i, '') + '#' + this.getPubkeySuffix(pk);
        },

        _gtSurface() {
            if (this.inPMMode && this.currentGroup) return 'group';
            if (this.inPMMode && this.currentPM) return 'dm';
            return 'channel';
        },

        _gtAvail(feature, surface, peer) {
            const meshPeer = !!(peer && typeof this.meshPmPeerId === 'function' && this.meshPmPeerId(peer));
            return T().availability(feature, { surface, online: !!this.connected, meshPeer });
        },

        _gtGate(feature, surface, peer) {
            const a = this._gtAvail(feature, surface, peer);
            if (!a.ok) this._gtNotice(this._gx(a.reason || T().STRINGS.groupsNeedNet));
            return a;
        },

        _gtGroupSendBlocked(content, groupId) {
            const group = this.groupConversations.get(groupId);
            if (!group || !this.pubkey) return null;
            const role = this._gtRole(groupId, this.pubkey);
            const check = T().sendCheck('group', role, content);
            if (!check.ok) return this._gx(check.reason);
            const interval = T().normalizeSlowmode(group.slowmode);
            if (interval && !T().slowmodeExempt(role)) {
                const wait = this._gtSlowmodeWait(groupId);
                if (wait > 0) return this._gx(T().STRINGS.slowmodeWait, { time: T().formatWait(wait) });
            }
            return null;
        },

        _gtOwnSlowmodeMessages(groupId) {
            const list = this.pmMessages.get(this.getGroupConversationKey(groupId)) || [];
            return list.filter((m) => m && m.pubkey === this.pubkey && !m.gtAbsorbed && m.deliveryStatus !== 'failed')
                .map((m) => ({ id: String(m.nymMessageId || m.id), ts: Math.floor(m._originalCreatedAt || m.created_at || 0) }));
        },

        _gtSlowmodeWait(groupId) {
            const group = this.groupConversations.get(groupId);
            if (!group) return 0;
            const interval = T().normalizeSlowmode(group.slowmode);
            if (!interval) return 0;
            const last = T().slowmodeLastAccepted(this._gtOwnSlowmodeMessages(groupId), interval, group.slowmodeSince || 0);
            return T().slowmodeWait(interval, last, nowSec());
        },

        _gtSlowmodeIngest(groupId, list, senderPubkey) {
            const group = this.groupConversations.get(groupId);
            if (!group) return false;
            const interval = T().normalizeSlowmode(group.slowmode);
            const exempt = T().slowmodeExempt(this._gtRole(groupId, senderPubkey));
            const mine = list.filter((m) => m && m.pubkey === senderPubkey && !m.gtAbsorbed);
            const held = (!interval || exempt) ? [] : T().slowmodeHeld(
                mine.map((m) => ({ id: String(m.nymMessageId || m.id), ts: Math.floor(m._originalCreatedAt || m.created_at || 0) })),
                interval, group.slowmodeSince || 0);
            const heldSet = new Set(held);
            let flipped = false;
            for (const m of mine) {
                const h = heldSet.has(String(m.nymMessageId || m.id));
                if (!!m.slowHeld !== h) {
                    if (m.slowHeld !== undefined || h) flipped = true;
                    m.slowHeld = h || undefined;
                }
            }
            if (flipped && this.inPMMode && this.currentGroup === groupId && this.channelDOMCache) {
                this.channelDOMCache.delete(this.getGroupConversationKey(groupId));
            }
            return flipped;
        },

        _gtMentionsAll(message) {
            if (!message || message.isOwn || !message.isGroup || !message.groupId) return false;
            return T().notifiesAll('group', this._gtRole(message.groupId, message.pubkey), message.content);
        },

        _gtGroupRowMentioned(message) {
            if (!message || message.isOwn || !message.isGroup) return false;
            if (this._gtMentionsAll(message)) return true;
            return typeof this.isMentioned === 'function' && this.isMentioned(message.content);
        },

        async setGroupSlowmode(groupId, sec) {
            const group = this.groupConversations.get(groupId);
            if (!group) return;
            if (!this._canAdminister(groupId, this.pubkey)) {
                this._gtNotice(this._gx('Only the group owner or an admin can change this setting.'));
                return;
            }
            if (!this._gtGate('slowmode', 'group').ok) return;
            const next = T().normalizeSlowmode(sec);
            if (next === T().normalizeSlowmode(group.slowmode)) return;
            const ts = nowSec();
            group.slowmode = next;
            group.slowmodeSince = ts;
            group.metaUpdatedAt = ts;
            group.metaUpdatedBy = this.pubkey;
            this.groupConversations.set(groupId, group);
            this._saveGroupConversations();
            if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
            await this._broadcastGroupMetadata(groupId);
            this._gtNotice(next ? this._gx('Slowmode is on: members can send one message every {interval}.', { interval: T().slowmodeLabel(next) })
                : this._gx('Slowmode is off.'));
            this._gtRenderSlowBar();
        },

        async setGroupJoinApproval(groupId, on) {
            const group = this.groupConversations.get(groupId);
            if (!group) return;
            if (!this._canAdminister(groupId, this.pubkey)) {
                this._gtNotice(this._gx('Only the group owner or an admin can change this setting.'));
                return;
            }
            if (!this._gtGate('approval', 'group').ok) return;
            const next = !!on;
            if (next === (group.joinApproval === true)) return;
            group.joinApproval = next;
            group.metaUpdatedAt = nowSec();
            group.metaUpdatedBy = this.pubkey;
            this.groupConversations.set(groupId, group);
            this._saveGroupConversations();
            if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
            await this._broadcastGroupMetadata(groupId);
            this._gtNotice(next ? this._gx('Admins now approve join requests from invite links.')
                : this._gx('Invite links admit new members automatically again.'));
        },

        _gtMetaTags(group) {
            const slow = T().normalizeSlowmode(group && group.slowmode);
            return [
                ['slowmode', String(slow)],
                ['slowmode_since', String(slow ? (group.slowmodeSince || 0) : 0)],
                ['join_approval', group && group.joinApproval ? '1' : '0'],
            ];
        },

        _gtApplyMetaTags(grp, rumor, metaTs) {
            let changed = false;
            const tag = (k) => (rumor.tags || []).find((t) => Array.isArray(t) && t[0] === k);
            const slowTag = tag('slowmode');
            if (slowTag) {
                const v = T().normalizeSlowmode(slowTag[1]);
                const sinceTag = tag('slowmode_since');
                const claimed = sinceTag ? (parseInt(sinceTag[1], 10) || 0) : 0;
                const since = v ? ((claimed > 0 && claimed <= metaTs) ? claimed : metaTs) : 0;
                if (v !== T().normalizeSlowmode(grp.slowmode) || (v && since !== (grp.slowmodeSince || 0))) {
                    grp.slowmode = v;
                    grp.slowmodeSince = since;
                    changed = true;
                }
            }
            const apTag = tag('join_approval');
            if (apTag) {
                const v = apTag[1] === '1';
                if (v !== (grp.joinApproval === true)) { grp.joinApproval = v; changed = true; }
            }
            return changed;
        },

        _gtGroupSnapshot(group) {
            return {
                slowmode: T().normalizeSlowmode(group.slowmode) || undefined,
                slowmodeSince: group.slowmodeSince || undefined,
                joinApproval: group.joinApproval === true || undefined,
                joinRequests: Array.isArray(group.joinRequests) && group.joinRequests.length ? T().pruneJoinRequests(group.joinRequests, nowSec()) : undefined,
            };
        },

        _gtRestoreGroup(g, saved) {
            if (!g || !saved) return;
            if (saved.slowmode) g.slowmode = T().normalizeSlowmode(saved.slowmode);
            if (saved.slowmodeSince) g.slowmodeSince = saved.slowmodeSince;
            if (saved.joinApproval === true) g.joinApproval = true;
            if (Array.isArray(saved.joinRequests)) g.joinRequests = T().pruneJoinRequests(saved.joinRequests, nowSec());
        },

        async _gtQueueJoinRequest(groupId, joinerPubkey, viaPubkey, ts, forward) {
            const group = this.groupConversations.get(groupId);
            if (!group) return;
            const before = (group.joinRequests || []).length;
            group.joinRequests = T().addJoinRequest(group.joinRequests || [], { pubkey: joinerPubkey, ts, via: viaPubkey || '' }, nowSec());
            this.groupConversations.set(groupId, group);
            this._saveGroupConversations();
            this._debouncedNostrSettingsSave();
            if (!forward) {
                if (group.joinRequests.length > before && T().mayApproveJoins(this._gtRole(groupId, this.pubkey))) this._gtNotifyJoinRequest(groupId, joinerPubkey);
                return;
            }
            const deciders = [group.createdBy].concat(group.admins || []).filter((pk) => pk && pk !== this.pubkey && group.members.includes(pk));
            const base = [['g', groupId], ['subject', group.name], ['joiner', joinerPubkey], ['joiner_ts', String(ts)], ['x', this._generateSharedEventId()]];
            if (deciders.length) {
                const rumor = { kind: 14, created_at: nowSec(), tags: deciders.map((pk) => ['p', pk]).concat([['type', T().TYPES.joinPending]], base), content: '', pubkey: this.pubkey };
                await this._sendGiftWrapsAsync(deciders, rumor, null, groupId);
            }
            const deciderTags = [group.createdBy].concat(group.admins || []).filter((pk) => pk && group.members.includes(pk)).map((pk) => ['decider', pk]);
            const ack = { kind: 14, created_at: nowSec(), tags: [['p', joinerPubkey], ['g', groupId], ['subject', group.name], ['type', T().TYPES.joinWaiting]].concat(deciderTags, [['x', this._generateSharedEventId()]]), content: '', pubkey: this.pubkey };
            await this._sendGiftWrapsAsync([joinerPubkey], ack, null);
            if (group.joinRequests.length > before && T().mayApproveJoins(this._gtRole(groupId, this.pubkey))) this._gtNotifyJoinRequest(groupId, joinerPubkey);
        },

        async _gtNotifyJoinRequest(groupId, joinerPubkey) {
            const group = this.groupConversations.get(groupId);
            if (!group) return;
            if (!this.users.has(joinerPubkey) && typeof this.fetchProfileDirect === 'function') await this.fetchProfileDirect(joinerPubkey);
            const title = this._gx('Join request in {group}', { group: group.name || 'Group' });
            const body = this._gx('{nym} wants to join. Open the group menu to approve or decline.', { nym: this.getNymFromPubkey(joinerPubkey) });
            this.showNotification(title, body, { type: 'group', groupId, id: this.getGroupConversationKey(groupId), pubkey: joinerPubkey, eventId: 'join-req-' + groupId + '-' + joinerPubkey }, Date.now());
        },

        async gtDecideJoin(groupId, joinerPubkey, approve) {
            const group = this.groupConversations.get(groupId);
            if (!group) return;
            if (!T().mayApproveJoins(this._gtRole(groupId, this.pubkey))) {
                this._gtNotice(this._gx('Only the group owner or an admin can approve join requests.'));
                return;
            }
            if (!this._gtGate('approval', 'group').ok) return;
            const refreshList = () => { const m = document.getElementById('gtJoinRequestsModal'); if (m && m.classList.contains('active')) this.openJoinRequests(groupId); };
            const banned = Array.isArray(group.banned) && group.banned.includes(joinerPubkey);
            if (approve && !banned && !group.members.includes(joinerPubkey)) {
                if (group.members.length >= (this.MAX_GROUP_MEMBERS || 100)) {
                    this._gtNotice(this._gx('{group} is full. Remove someone to approve {nym}.', { group: group.name || 'Group', nym: this.getNymFromPubkey(joinerPubkey) }));
                    refreshList();
                    return;
                }
                const added = await this.addMemberToGroup(groupId, joinerPubkey);
                if (added !== true) {
                    refreshList();
                    return;
                }
            }
            group.joinRequests = T().removeJoinRequest(group.joinRequests || [], joinerPubkey);
            this.groupConversations.set(groupId, group);
            this._saveGroupConversations();
            this._debouncedNostrSettingsSave();
            const deciders = [group.createdBy].concat(group.admins || []).filter((pk) => pk && pk !== this.pubkey && group.members.includes(pk));
            if (deciders.length) {
                const rumor = { kind: 14, created_at: nowSec(), tags: deciders.map((pk) => ['p', pk]).concat([['g', groupId], ['subject', group.name], ['type', T().TYPES.joinResolved], ['joiner', joinerPubkey], ['decision', approve ? 'approve' : 'decline'], ['x', this._generateSharedEventId()]]), content: '', pubkey: this.pubkey };
                await this._sendGiftWrapsAsync(deciders, rumor, null, groupId);
            }
            if (approve) {
                if (banned) return;
                this._gtNotice(this._gx('Approved. {nym} was added to the group.', { nym: this.getNymFromPubkey(joinerPubkey) }));
            } else {
                const rumor = { kind: 14, created_at: nowSec(), tags: [['p', joinerPubkey], ['g', groupId], ['subject', group.name], ['type', T().TYPES.joinDeclined], ['x', this._generateSharedEventId()]], content: '', pubkey: this.pubkey };
                await this._sendGiftWrapsAsync([joinerPubkey], rumor, null);
                this._gtNotice(this._gx('Declined the join request from {nym}.', { nym: this.getNymFromPubkey(joinerPubkey) }));
            }
            if (document.getElementById('gtJoinRequestsModal') && document.getElementById('gtJoinRequestsModal').classList.contains('active')) this.openJoinRequests(groupId);
        },

        _gtPendingJoins() {
            if (!this._gtPending) {
                this._gtPending = load(PENDING_JOINS_KEY + (this.pubkey || ''), {}) || {};
                if (!this._pendingInviteJoins) this._pendingInviteJoins = new Set();
                for (const gid of Object.keys(this._gtPending)) this._pendingInviteJoins.add(gid);
            }
            return this._gtPending;
        },

        _gtSavePendingJoins() {
            save(PENDING_JOINS_KEY + (this.pubkey || ''), this._gtPendingJoins());
        },

        async _gtHandleGroupControl(msgType, rumor, groupId, senderPubkey, isOwn) {
            const TY = T().TYPES;
            const tagv = (k) => { const t = (rumor.tags || []).find((x) => Array.isArray(x) && x[0] === k && x[1]); return t ? t[1] : null; };
            if (msgType === 'group-invite' || msgType === 'group-add-member') {
                const pend = this._gtPendingJoins();
                if (pend[groupId]) { delete pend[groupId]; this._gtSavePendingJoins(); }
                return false;
            }
            if (msgType === TY.rsvp) {
                if (!isOwn) this._gtApplyRsvpRumor(rumor, groupId, senderPubkey);
                return true;
            }
            if (msgType === TY.joinPending) {
                if (isOwn) return true;
                const group = this.groupConversations.get(groupId);
                const joiner = tagv('joiner');
                if (!group || !joiner || !/^[0-9a-f]{64}$/.test(joiner)) return true;
                if (!this._isGroupRosterMember(groupId, senderPubkey)) return true;
                if (group.members.includes(joiner) || (group.banned || []).includes(joiner)) return true;
                const ts = parseInt(tagv('joiner_ts'), 10) || Math.floor(rumor.created_at || 0);
                await this._gtQueueJoinRequest(groupId, joiner, senderPubkey, Math.min(ts, nowSec()), false);
                return true;
            }
            if (msgType === TY.joinResolved) {
                if (isOwn) return true;
                const group = this.groupConversations.get(groupId);
                const joiner = tagv('joiner');
                if (!group || !joiner) return true;
                if (!T().mayApproveJoins(this._gtRole(groupId, senderPubkey))) return true;
                group.joinRequests = T().removeJoinRequest(group.joinRequests || [], joiner);
                this.groupConversations.set(groupId, group);
                this._saveGroupConversations();
                return true;
            }
            if (msgType === TY.joinWaiting || msgType === TY.joinDeclined) {
                if (isOwn) return true;
                const pend = this._gtPendingJoins();
                const p = pend[groupId];
                const fullReason = msgType === TY.joinDeclined && tagv('reason') === 'full';
                if (!p) {
                    if (fullReason) {
                        const group = this.groupConversations.get(groupId);
                        if (group && group.members.includes(this.pubkey) && senderPubkey !== this.pubkey
                            && (senderPubkey === group.joinedVia || this._isGroupOwner(groupId, senderPubkey) || this._isGroupAdmin(groupId, senderPubkey))) {
                            this._gcLeaveFull(groupId, group.name);
                        }
                    }
                    return true;
                }
                if (msgType === TY.joinWaiting) {
                    if (senderPubkey !== p.a) return true;
                    p.deciders = (rumor.tags || []).filter((t) => Array.isArray(t) && t[0] === 'decider' && /^[0-9a-f]{64}$/.test(t[1] || '')).map((t) => t[1]).slice(0, 20);
                    this._gtSavePendingJoins();
                    if (!p.waiting) {
                        p.waiting = true;
                        this._gtSavePendingJoins();
                        this._gtNotice(this._gx('Waiting for approval to join "{name}".', { name: p.n }));
                    }
                    return true;
                }
                const allowed = [p.a].concat(p.deciders || []);
                if (!allowed.includes(senderPubkey)) return true;
                delete pend[groupId];
                this._gtSavePendingJoins();
                if (this._pendingInviteJoins) this._pendingInviteJoins.delete(groupId);
                if (fullReason) {
                    this._gtNotice(this._gx("{group} is full, so you couldn't join.", { group: p.n || 'Group' }));
                    return true;
                }
                const body = this._gx('Your request to join "{name}" was declined.', { name: p.n });
                this._gtNotice(body);
                this.showNotification(this._gx('Join request declined'), body, { type: 'group', groupId, pubkey: senderPubkey, eventId: 'join-declined-' + groupId }, Date.now());
                return true;
            }
            return false;
        },

        openJoinRequests(groupId) {
            const group = this.groupConversations.get(groupId);
            if (!group) return;
            const { body } = this._ctModal('gtJoinRequestsModal', this._gx('Join requests'));
            const list = T().pruneJoinRequests(group.joinRequests || [], nowSec());
            const canDecide = T().mayApproveJoins(this._gtRole(groupId, this.pubkey));
            const full = (group.members || []).length >= (this.MAX_GROUP_MEMBERS || 100);
            const esc = (s) => this.escapeHtml(String(s));
            if (!list.length) {
                body.innerHTML = `<div class="ct-empty">${esc(this._gx('No pending join requests.'))}</div>`;
                return;
            }
            if (typeof this.ensureListProfiles === 'function') this.ensureListProfiles(null, list.map((r) => r.pubkey));
            body.innerHTML = list.map((r) => `<div class="gt-join-row" data-pubkey="${esc(r.pubkey)}">
                <img class="avatar-message" src="${esc(this.getAvatarUrl(r.pubkey))}" alt="">
                <div class="gt-join-info"><div class="gt-join-nym">${esc(this.getNymFromPubkey(r.pubkey))}</div>
                <div class="gt-join-time">${this.formatMessage('<t:' + r.ts + ':R>')}</div></div>
                ${canDecide ? `${full ? `<span class="gt-join-full">${esc(this._gx('Full'))}</span>` : ''}<button class="send-btn gt-join-approve" data-action="gtJoinApprove" data-group-id="${esc(groupId)}" data-pubkey="${esc(r.pubkey)}"${full ? ` disabled title="${esc(this._gx('Group is full'))}"` : ''}>${esc(this._gx('Approve'))}</button>
                <button class="icon-btn gt-join-decline" data-action="gtJoinDecline" data-group-id="${esc(groupId)}" data-pubkey="${esc(r.pubkey)}">${esc(this._gx('Decline'))}</button>` : ''}
            </div>`).join('');
        },

        async _gtEnsureSummary(groupId) {
            const group = this.groupConversations.get(groupId);
            if (!group || !this.pubkey) return null;
            if (!this._gtSummaries) this._gtSummaries = new Map();
            const adminPks = [group.createdBy].concat(group.admins || []).filter(Boolean);
            const fields = {
                description: group.description || '',
                avatar: group.avatar || '',
                banner: group.banner || '',
                memberCount: (group.members || []).length,
                adminNyms: adminPks.map((pk) => this._gtNymTag(pk)),
                approval: group.joinApproval === true,
            };
            const content = T().summaryContent(fields);
            const cached = this._gtSummaries.get(groupId);
            if (cached && cached.c === content && Date.now() - cached.at < SUMMARY_TTL_MS) return cached.s;
            try {
                const signed = await this.signEvent(T().summaryTemplate(groupId, this.pubkey, nowSec(), content));
                if (!signed || !/^[0-9a-f]{128}$/.test(signed.sig || '')) return null;
                const s = { t: signed.created_at, c: content, sig: signed.sig };
                this._gtSummaries.set(groupId, { c: content, at: Date.now(), s });
                return s;
            } catch (_) { return null; }
        },

        _gtVerifySummary(payload) {
            if (!payload || !payload.s) return null;
            const NT = window.NostrTools;
            if (!NT || typeof NT.verifyEvent !== 'function' || typeof NT.getEventHash !== 'function') return null;
            const ev = T().summaryTemplate(payload.g, payload.a, payload.s.t, payload.s.c);
            try {
                ev.id = NT.getEventHash(ev);
                ev.sig = payload.s.sig;
                if (!NT.verifyEvent(ev)) return null;
            } catch (_) { return null; }
            return T().parseSummaryContent(payload.s.c);
        },

        async gtInvitePreview(payload) {
            const fields = this._gtVerifySummary(payload);
            const p = T().invitePreview(payload, fields);
            const pending = this._gtPendingJoins()[payload.g];
            const esc = (s) => this.escapeHtml(String(s));
            return new Promise((resolve) => {
                const { modal, body } = this._ctModal('gtInvitePreviewModal', this._gx('Join group'));
                const banner = p.banner ? `<div class="gt-inv-banner"><img src="${esc(this.getProxiedMediaUrl(p.banner))}" alt="" data-error-action="groupImgError"></div>` : '<div class="gt-inv-banner gt-inv-banner-empty"></div>';
                const avatar = p.avatar ? `<img class="gt-inv-avatar" src="${esc(this.getProxiedMediaUrl(p.avatar))}" alt="" data-error-action="groupImgError">` : `<span class="gt-inv-avatar gt-inv-avatar-empty">${ICONS.requests}</span>`;
                const capMax = this.MAX_GROUP_MEMBERS || 100;
                const full = p.memberCount != null && p.memberCount >= capMax;
                const members = p.memberCount == null ? '' : `<div class="gt-inv-members">${esc(this._gx('{n}/{max} members', { n: p.memberCount, max: capMax }) + (full ? ' · ' + this._gx('Full') : ''))}</div>`;
                const admins = p.admins.length ? `<div class="gt-inv-admins">${esc(this._gx('Admins: {list}', { list: p.admins.join(', ') }))}</div>` : '';
                const desc = p.description ? `<div class="gt-inv-desc" role="button" tabindex="0" data-action="gtToggleInviteDesc" title="${esc(p.description)}">${esc(p.description)}</div>` : '';
                const note = !p.verified ? `<div class="gt-inv-note">${esc(this._gx('This link has no group details. Ask the sender for a fresh link to see them.'))}</div>`
                    : (p.approval ? `<div class="gt-inv-note">${esc(this._gx('An admin approves join requests for this group.'))}</div>` : '');
                const waiting = pending && pending.waiting;
                const joinLabel = full ? this._gx('Group is full') : (waiting ? this._gx('Waiting for approval') : this._gx('Join'));
                body.innerHTML = `<div class="gt-inv-card">${banner}<div class="gt-inv-head">${avatar}<div class="gt-inv-name">${esc(p.name)}</div></div>${desc}${members}${admins}${note}
                    <div class="gt-inv-actions"><button class="icon-btn" data-gt-inv="cancel">${esc(this._gx('Cancel'))}</button>
                    <button class="send-btn" data-gt-inv="join" ${(waiting || full) ? 'disabled' : ''}>${esc(joinLabel)}</button></div></div>`;
                let done = false;
                const finish = (v) => {
                    if (done) return;
                    done = true;
                    this._ctCloseModal('gtInvitePreviewModal');
                    modal.removeEventListener('click', onClick);
                    clearInterval(watch);
                    resolve(v);
                };
                const onClick = (e) => {
                    const b = e.target.closest('[data-gt-inv]');
                    if (b) { e.preventDefault(); finish(b.dataset.gtInv === 'join'); }
                };
                modal.addEventListener('click', onClick);
                const watch = setInterval(() => { if (!modal.classList.contains('active')) finish(false); }, 300);
            });
        },

        _gtRememberPendingJoin(payload) {
            const fields = this._gtVerifySummary(payload);
            const pend = this._gtPendingJoins();
            pend[payload.g] = { n: T().sanitizeName(payload.n, 40) || 'Group', a: payload.a, at: nowSec(), approval: !!(fields && fields.ap === 1), deciders: [], waiting: false };
            this._gtSavePendingJoins();
            if (!this._pendingInviteJoins) this._pendingInviteJoins = new Set();
            this._pendingInviteJoins.add(payload.g);
            return pend[payload.g];
        },

        _gtRsvpStore() {
            if (!this._gtRsvps) this._gtRsvps = load(RSVP_KEY + (this.pubkey || ''), {}) || {};
            return this._gtRsvps;
        },

        _gtSaveRsvps() {
            const s = this._gtRsvpStore();
            const ids = Object.keys(s);
            if (ids.length > 300) for (const id of ids.slice(0, ids.length - 300)) delete s[id];
            save(RSVP_KEY + (this.pubkey || ''), s);
        },

        _gtApplyRsvpRumor(rumor, groupId, senderPubkey) {
            if (!this._isGroupRosterMember(groupId, senderPubkey)) return;
            const tagv = (k) => { const t = (rumor.tags || []).find((x) => Array.isArray(x) && x[0] === k && x[1]); return t ? t[1] : null; };
            const eventId = tagv('e');
            if (!eventId || !/^[0-9a-f]{16}$/.test(eventId)) return;
            const store = this._gtRsvpStore();
            const r = T().applyRsvp(store[eventId] || {}, senderPubkey, tagv('rsvp'), Math.min(Math.floor(rumor.created_at || 0), nowSec() + 300));
            if (!r.changed) return;
            store[eventId] = r.entries;
            this._gtSaveRsvps();
            this._gtRefreshEventCards(eventId);
        },

        async gtRsvp(groupId, eventId, status) {
            const group = this.groupConversations.get(groupId);
            if (!group || !T().normalizeRsvp(status)) return;
            if (!this._gtGate('rsvp', 'group').ok) return;
            const found = this._gtFindEvent(groupId, eventId);
            const title = found ? found.title : '';
            const ts = Math.max(nowSec(), ((this._gtRsvpStore()[eventId] || {})[this.pubkey] || {}).ts + 1 || 0);
            const tags = group.members.map((pk) => ['p', pk]).concat([['g', groupId], ['subject', group.name]], T().rsvpTags(eventId, status), [['x', this._generateSharedEventId()]]);
            const rumor = { kind: 14, created_at: ts, tags, content: T().rsvpContent(status, title), pubkey: this.pubkey };
            const store = this._gtRsvpStore();
            const r = T().applyRsvp(store[eventId] || {}, this.pubkey, status, ts);
            store[eventId] = r.entries;
            this._gtSaveRsvps();
            this._gtRefreshEventCards(eventId);
            await this._sendGiftWrapsAsync(group.members, rumor, null, groupId);
        },

        _gtFindEvent(groupId, eventId) {
            const list = this.pmMessages.get(this.getGroupConversationKey(groupId)) || [];
            for (const m of list) {
                const ev = T().parseEvent(m && m.content);
                if (ev && ev.id === eventId) return ev;
            }
            return null;
        },

        _gtRefreshEventCards(eventId) {
            document.querySelectorAll(`.gt-event[data-gt-event="${eventId}"]`).forEach((el) => {
                const holder = el.closest('.message');
                const msgId = holder && holder.dataset.messageId;
                const found = msgId && this._ctFindMessage ? this._ctFindMessage(msgId) : null;
                if (!found) return;
                const html = this._gtCardHtml(found.msg);
                if (html) el.outerHTML = html;
            });
        },

        _gtReminders() {
            if (!this._gtRem) this._gtRem = load(REMINDER_KEY, {}) || {};
            return this._gtRem;
        },

        gtSetReminder(groupId, eventId, value) {
            const rem = this._gtReminders();
            const ev = this._gtFindEvent(groupId, eventId);
            if (value === '' || value == null || !ev) {
                delete rem[eventId];
            } else {
                const offset = parseInt(value, 10);
                if (T().REMINDER_OFFSETS_MIN.indexOf(offset) < 0) return;
                rem[eventId] = { offset, start: ev.start, title: ev.title, groupId, fired: false };
                const at = T().reminderAt(ev.start, offset);
                if (at * 1000 <= Date.now()) this._gtNotice(this._gx('That reminder time has already passed.'));
                else this._gtNotice(this._gx('Reminder set: {label}.', { label: this._gx(T().reminderLabel(offset)) }));
                if (typeof Notification !== 'undefined' && Notification.permission === 'default') {
                    try { Notification.requestPermission(); } catch (_) { }
                }
            }
            save(REMINDER_KEY, rem);
            this._gtArmReminders();
        },

        _gtArmReminders() {
            if (this._gtRemTimer) clearTimeout(this._gtRemTimer);
            const rem = this._gtReminders();
            let next = Infinity;
            const now = Date.now();
            let dirty = false;
            for (const id of Object.keys(rem)) {
                const r = rem[id];
                if (!r || r.fired) continue;
                const at = T().reminderAt(r.start, r.offset) * 1000;
                if (at <= now) {
                    r.fired = true;
                    dirty = true;
                    if (now - at < 3600000) this._gtFireReminder(id, r);
                } else next = Math.min(next, at);
            }
            if (dirty) save(REMINDER_KEY, rem);
            if (next !== Infinity) this._gtRemTimer = setTimeout(() => this._gtArmReminders(), Math.min(next - now + 50, 3600000));
        },

        _gtFireReminder(eventId, r) {
            const group = this.groupConversations.get(r.groupId);
            const title = this._gx('Reminder: {title}', { title: r.title });
            const body = this._gx('Starts {when}', { when: window.NymMessageFormat && window.NymMessageFormat.formatTimestamp ? window.NymMessageFormat.formatTimestamp(String(r.start), 'R') : new Date(r.start * 1000).toLocaleString() });
            this.showNotification(title, body + (group ? ' · ' + group.name : ''), { type: 'group', groupId: r.groupId, id: this.getGroupConversationKey(r.groupId), eventId: 'event-reminder-' + eventId }, Date.now());
        },

        _gtCardHtml(message) {
            if (!message || typeof message.content !== 'string') return null;
            const esc = (s) => this.escapeHtml(String(s));
            if (message.slowHeld && !message._heldShown) {
                return `<span class="gt-held">${esc(this._gx('Held by slowmode'))} <button class="gt-held-show" data-action="gtShowHeld">${esc(this._gx('Show'))}</button></span>`;
            }
            const surface = message.isGroup ? 'group' : (message.isPM ? 'dm' : 'channel');
            if (surface === 'group') {
                const ev = T().parseEvent(message.content);
                if (ev) return this._gtEventCardHtml(ev, message.groupId);
            }
            if (surface !== 'channel') {
                const loc = T().parseLocation(message.content);
                if (loc) return this._gtLocationCardHtml(loc, message);
            }
            return null;
        },

        _gtEventCardHtml(ev, groupId) {
            const esc = (s) => this.escapeHtml(String(s));
            const group = this.groupConversations.get(groupId);
            const entries = this._gtRsvpStore()[ev.id] || {};
            const tally = T().rsvpTally(entries, group ? group.members : null);
            const mine = entries[this.pubkey] ? entries[this.pubkey].s : null;
            const names = (list) => list.map((pk) => esc(this.getNymFromPubkey(pk))).join(', ');
            const labels = { going: this._gx('Going'), maybe: this._gx('Maybe'), no: this._gx("Can't") };
            const btn = (s) => `<button class="gt-rsvp-btn${mine === s ? ' active' : ''}" data-action="gtRsvp" data-status="${s}" data-event-id="${ev.id}" data-group-id="${esc(groupId)}" aria-pressed="${mine === s}">${esc(labels[s])} <span class="gt-rsvp-count">${tally[s].length}</span></button>`;
            const who = ['going', 'maybe', 'no'].filter((s) => tally[s].length).map((s) => `<div class="gt-rsvp-who-row"><span class="gt-rsvp-who-label">${esc(labels[s])}:</span> ${names(tally[s])}</div>`).join('');
            const rem = this._gtReminders()[ev.id];
            const opts = [`<option value="">${esc(this._gx('No reminder'))}</option>`].concat(T().REMINDER_OFFSETS_MIN.map((o) => `<option value="${o}"${rem && rem.offset === o ? ' selected' : ''}>${esc(this._gx(T().reminderLabel(o)))}</option>`)).join('');
            return `<div class="gt-card gt-event" data-gt-event="${ev.id}" data-group-id="${esc(groupId)}">
                <div class="gt-event-head">${ICONS.event}<span class="gt-event-title">${esc(ev.title)}</span></div>
                <div class="gt-event-when">${this.formatMessage('<t:' + ev.start + ':F>')} · ${this.formatMessage('<t:' + ev.start + ':R>')}</div>
                <div class="gt-event-tz">${esc(this._gx("Organizer's time zone: {tz}", { tz: T().tzLabel(ev.offset) }))}</div>
                ${ev.place ? `<div class="gt-event-where">${ICONS.location}<span>${esc(ev.place)}</span></div>` : ''}
                ${ev.note ? `<div class="gt-event-note">${esc(ev.note)}</div>` : ''}
                <div class="gt-rsvp-row">${btn('going')}${btn('maybe')}${btn('no')}</div>
                ${who ? `<div class="gt-rsvp-who">${who}</div>` : ''}
                <label class="gt-reminder">${esc(this._gx('Remind me'))} <select data-on-change="gtReminderChange" data-event-id="${ev.id}" data-group-id="${esc(groupId)}">${opts}</select></label>
            </div>`;
        },

        _gtLocationCardHtml(loc, message) {
            const esc = (s) => this.escapeHtml(String(s));
            const state = T().liveState(loc, nowSec());
            const coords = loc.lat + ', ' + loc.lon;
            let title = this._gx('Location');
            let sub = '';
            if (state === 'live') {
                title = this._gx('Live location');
                sub = this._gx('Live until {time}', { time: this.formatMessage('<t:' + loc.until + ':t>') });
            } else if (state === 'ended' || state === 'expired') {
                title = this._gx('Live location');
                sub = esc(this._gx('Live location ended'));
            }
            const own = message && message.isOwn && state === 'live' && this._gtLiveShare && this._gtLiveShare.id === loc.id;
            return `<div class="gt-card gt-loc${state === 'live' ? ' gt-loc-live' : ''}" data-gt-loc="${esc(loc.id || '')}">
                <canvas class="gt-map" width="320" height="160" data-lat="${loc.lat}" data-lon="${loc.lon}" data-acc="${loc.acc}" aria-label="${esc(this._gx('Map'))}"></canvas>
                <div class="gt-loc-head">${ICONS.location}<span class="gt-loc-title">${esc(title)}</span>${sub ? `<span class="gt-loc-sub">${sub}</span>` : ''}</div>
                <div class="gt-loc-coords">${esc(coords)}</div>
                <div class="gt-loc-precision">${esc(loc.acc ? this._gx('Accurate to about {d}', { d: T().precisionText(loc.acc) }) : this._gx('Precision unknown'))}</div>
                <div class="gt-loc-actions"><button class="icon-btn" data-action="gtCopyCoords" data-coords="${esc(coords)}">${esc(this._gx('Copy coordinates'))}</button>
                ${own ? `<button class="icon-btn danger" data-action="gtStopLive">${esc(this._gx('Stop sharing'))}</button>` : ''}</div>
            </div>`;
        },

        async _gtWorld() {
            if (!this._gtWorldP) {
                this._gtWorldP = fetch('/data/countries-110m.json', { cache: 'force-cache' })
                    .then((r) => (r.ok ? r.json() : null))
                    .then((j) => (j && window.NymGeoDecode ? window.NymGeoDecode.decodeByKind('world', j) : []))
                    .catch(() => []);
            }
            return this._gtWorldP;
        },

        _gtMapColors() {
            const cs = getComputedStyle(document.body);
            return {
                sea: cs.getPropertyValue('--bg-tertiary').trim() || '#0b1520',
                land: cs.getPropertyValue('--bg-secondary').trim() || '#1c2a39',
                edge: cs.getPropertyValue('--border').trim() || '#2c3e50',
                pin: cs.getPropertyValue('--primary').trim() || '#00ff88',
            };
        },

        _gtDrawFrame(canvas, frame, pin, accDeg, features) {
            const ctx = canvas.getContext && canvas.getContext('2d');
            if (!ctx) return;
            const w = canvas.width;
            const h = canvas.height;
            const col = this._gtMapColors();
            ctx.fillStyle = col.sea;
            ctx.fillRect(0, 0, w, h);
            const px = (lon) => (lon - frame.minLon) / (frame.maxLon - frame.minLon) * w;
            const py = (lat) => (frame.maxLat - lat) / (frame.maxLat - frame.minLat) * h;
            ctx.fillStyle = col.land;
            ctx.strokeStyle = col.edge;
            ctx.lineWidth = 0.8;
            for (const f of features || []) {
                const polys = f.type === 'Polygon' ? [f.coordinates] : (f.coordinates || []);
                for (const poly of polys) {
                    ctx.beginPath();
                    for (const ring of poly) {
                        ring.forEach((pt, i) => {
                            let lon = pt[0];
                            if (frame.maxLon > 180 && lon < frame.minLon) lon += 360;
                            if (frame.minLon < -180 && lon > frame.maxLon) lon -= 360;
                            const x = px(lon);
                            const y = py(pt[1]);
                            if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
                        });
                        ctx.closePath();
                    }
                    ctx.fill('evenodd');
                    ctx.stroke();
                }
            }
            if (pin) {
                const x = px(pin.lon);
                const y = py(pin.lat);
                if (accDeg > 0) {
                    const r = Math.max(4, accDeg / (frame.maxLon - frame.minLon) * w);
                    ctx.beginPath();
                    ctx.arc(x, y, Math.min(r, w), 0, Math.PI * 2);
                    ctx.globalAlpha = 0.18;
                    ctx.fillStyle = col.pin;
                    ctx.fill();
                    ctx.globalAlpha = 1;
                }
                ctx.beginPath();
                ctx.arc(x, y, 5, 0, Math.PI * 2);
                ctx.fillStyle = col.pin;
                ctx.fill();
                ctx.lineWidth = 2;
                ctx.strokeStyle = '#fff';
                ctx.stroke();
            }
        },

        async _gtDrawMaps(root) {
            const canvases = (root || document).querySelectorAll ? (root || document).querySelectorAll('canvas.gt-map:not([data-drawn])') : [];
            if (!canvases.length) return;
            const features = await this._gtWorld();
            canvases.forEach((c) => {
                const lat = parseFloat(c.dataset.lat);
                const lon = parseFloat(c.dataset.lon);
                const acc = parseFloat(c.dataset.acc) || 0;
                const frame = T().mapFrame(lat, lon, acc);
                c.dataset.drawn = '1';
                this._gtDrawFrame(c, frame, { lat, lon }, acc / 111320, features);
            });
        },

        _gtAbsorbLive(msg, list) {
            const loc = T().parseLocation(msg && msg.content);
            if (!loc || loc.kind === 'pin') return false;
            const first = list.find((m) => m && m !== msg && m.pubkey === msg.pubkey && !m.gtAbsorbed && (() => { const l = T().parseLocation(m.content); return l && l.kind !== 'pin' && l.id === loc.id; })());
            if (!first) return false;
            const cur = T().parseLocation(first.content);
            if (T().liveSupersedes(cur, loc)) {
                first.content = msg.content;
                if (first.conversationKey && typeof this.persistPMMessages === 'function') this.persistPMMessages(first.conversationKey);
                this._gtRefreshLocationCard(first);
            }
            return true;
        },

        _gtRefreshLocationCard(message) {
            const ids = [message.nymMessageId, message.id].filter((x) => typeof x === 'string' && x);
            let el = null;
            for (const id of ids) {
                el = document.querySelector(`[data-message-id="${id.replace(/["\\]/g, '\\$&')}"] .gt-loc`);
                if (el) break;
            }
            if (!el) return;
            const loc = T().parseLocation(message.content);
            if (!loc) return;
            const tmp = document.createElement('div');
            tmp.innerHTML = this._gtLocationCardHtml(loc, message);
            const fresh = tmp.firstElementChild;
            el.replaceWith(fresh);
            this._gtDrawMaps(fresh.parentNode);
        },

        _gtCurrentChat() {
            if (this.inPMMode && this.currentGroup) return { type: 'group', id: this.currentGroup };
            if (this.inPMMode && this.currentPM) return { type: 'dm', id: this.currentPM };
            return null;
        },

        async _gtSendToChat(chat, content) {
            if (!chat) return false;
            if (chat.type === 'group') return this.sendGroupMessage(content, chat.id, { gtInternal: true });
            if (this.connected) return this.sendPM(content, chat.id);
            const peerID = typeof this.meshPmPeerId === 'function' ? this.meshPmPeerId(chat.id) : null;
            if (peerID && typeof this.sendPMOverMesh === 'function') return this.sendPMOverMesh(content, chat.id, peerID);
            this._gtNotice(this._gx(T().STRINGS.locationNeedsNet));
            return false;
        },

        _gtPosition() {
            return new Promise((resolve) => {
                if (!navigator.geolocation) { resolve({ error: this._gx("This browser can't read your location.") }); return; }
                navigator.geolocation.getCurrentPosition(
                    (p) => resolve({ lat: p.coords.latitude, lon: p.coords.longitude, acc: p.coords.accuracy || 0 }),
                    (e) => resolve({ error: e && e.code === 1 ? this._gx('Location permission was denied.') : this._gx("Couldn't get your location. Try again or pick a spot on the map.") }),
                    { enableHighAccuracy: true, timeout: 15000, maximumAge: 10000 });
            });
        },

        openShareLocation(chat) {
            const c = chat || this._gtCurrentChat();
            const surface = c ? (c.type === 'group' ? 'group' : 'dm') : 'channel';
            const a = this._gtGate('location', surface, c && c.type === 'dm' ? c.id : null);
            if (!a.ok) return;
            this._gtLocChat = c;
            const { body } = this._ctModal('gtLocationModal', this._gx('Share location'));
            const esc = (s) => this.escapeHtml(String(s));
            const live = this._gtLiveShare;
            body.innerHTML = `<div class="gt-loc-menu">
                <p class="gt-hint">${esc(this._gx('Your location is end-to-end encrypted like a message. The card shows how precise it is.'))}${a.mesh ? ' ' + esc(this._gx('It will go over the Bluetooth mesh.')) : ''}</p>
                <button class="send-btn gt-wide" data-action="gtSendCurrentLocation">${esc(this._gx('Send current location'))}</button>
                <button class="icon-btn gt-wide" data-action="gtPickLocation">${esc(this._gx('Pick on map'))}</button>
                <div class="gt-sub-title">${esc(this._gx('Share live location'))}</div>
                <div class="gt-live-row">${T().LIVE_DURATIONS_SEC.map((s) => `<button class="icon-btn" data-action="gtStartLive" data-sec="${s}">${esc(this._gx(T().liveDurationLabel(s)))}</button>`).join('')}</div>
                ${live ? `<button class="icon-btn danger gt-wide" data-action="gtStopLive">${esc(this._gx('Stop sharing live location'))}</button>` : ''}
            </div>`;
        },

        async gtSendCurrentLocation() {
            const chat = this._gtLocChat;
            this._ctCloseModal('gtLocationModal');
            const pos = await this._gtPosition();
            if (pos.error) { this._gtNotice(pos.error); return; }
            const ok = await window.showAppConfirm(this._gx('Send your current location? Accurate to about {d}.', { d: T().precisionText(pos.acc) }), { title: this._gx('Share location'), okLabel: this._gx('Send') });
            if (!ok) return;
            const content = T().buildLocation({ lat: pos.lat, lon: pos.lon, acc: pos.acc, kind: 'pin' });
            if (content) await this._gtSendToChat(chat, content);
        },

        gtPickLocation() {
            const chat = this._gtLocChat;
            this._ctCloseModal('gtLocationModal');
            const { body } = this._ctModal('gtPickModal', this._gx('Pick on map'));
            const esc = (s) => this.escapeHtml(String(s));
            body.innerHTML = `<p class="gt-hint">${esc(this._gx('Tap the map to zoom in on a spot. The pin goes in the middle.'))}</p>
                <canvas class="gt-pick-map" width="640" height="320"></canvas>
                <div class="gt-pick-info"></div>
                <div class="gt-pick-actions"><button class="icon-btn" data-action="gtPickZoomOut">${esc(this._gx('Zoom out'))}</button>
                <button class="send-btn" data-action="gtPickSend">${esc(this._gx('Send this spot'))}</button></div>`;
            this._gtPick = { lat: 20, lon: 0, span: T().PICK_START_SPAN, chat };
            const canvas = body.querySelector('canvas');
            canvas.addEventListener('click', (e) => {
                const r = canvas.getBoundingClientRect();
                const n = T().pickTap(this._gtPick.lat, this._gtPick.lon, this._gtPick.span, (e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height);
                Object.assign(this._gtPick, n);
                this._gtDrawPick();
            });
            this._gtDrawPick();
        },

        async _gtDrawPick() {
            const modal = document.getElementById('gtPickModal');
            const canvas = modal && modal.querySelector('canvas');
            if (!canvas || !this._gtPick) return;
            const p = this._gtPick;
            const frame = { minLon: p.lon - p.span, maxLon: p.lon + p.span, minLat: p.lat - p.span / 2, maxLat: p.lat + p.span / 2 };
            const features = await this._gtWorld();
            const acc = T().pickAccuracy(p.span);
            this._gtDrawFrame(canvas, frame, { lat: p.lat, lon: p.lon }, acc / 111320, features);
            const info = modal.querySelector('.gt-pick-info');
            if (info) info.textContent = p.lat.toFixed(4) + ', ' + p.lon.toFixed(4) + ' · ' + this._gx('Accurate to about {d}', { d: T().precisionText(acc) });
        },

        gtPickZoomOut() {
            if (!this._gtPick) return;
            this._gtPick.span = T().pickZoomOut(this._gtPick.span);
            this._gtDrawPick();
        },

        async gtPickSend() {
            const p = this._gtPick;
            this._ctCloseModal('gtPickModal');
            if (!p) return;
            const content = T().buildLocation({ lat: p.lat, lon: p.lon, acc: T().pickAccuracy(p.span), kind: 'pin' });
            if (content) await this._gtSendToChat(p.chat, content);
        },

        async gtStartLive(sec) {
            const chat = this._gtLocChat;
            this._ctCloseModal('gtLocationModal');
            const dur = parseInt(sec, 10);
            if (T().LIVE_DURATIONS_SEC.indexOf(dur) < 0 || !chat) return;
            if (this._gtLiveShare) await this.gtStopLive(true);
            const pos = await this._gtPosition();
            if (pos.error) { this._gtNotice(pos.error); return; }
            const ok = await window.showAppConfirm(this._gx('Share your live location for {d}? Accurate to about {acc}. You can stop at any time.', { d: this._gx(T().liveDurationLabel(dur)), acc: T().precisionText(pos.acc) }), { title: this._gx('Share live location'), okLabel: this._gx('Share') });
            if (!ok) return;
            const share = { id: rand(4), chat, until: nowSec() + dur, seq: 0, lat: pos.lat, lon: pos.lon, acc: pos.acc };
            this._gtLiveShare = share;
            save(LIVE_KEY, share);
            await this._gtSendToChat(chat, T().buildLocation(Object.assign({ kind: 'live' }, share)));
            this._gtLiveLoop();
        },

        _gtLiveLoop() {
            const share = this._gtLiveShare;
            if (!share) return;
            if (navigator.geolocation && share.watchId == null) {
                try {
                    share.watchId = navigator.geolocation.watchPosition((p) => {
                        share.lat = p.coords.latitude;
                        share.lon = p.coords.longitude;
                        share.acc = p.coords.accuracy || share.acc;
                    }, () => { }, { enableHighAccuracy: true, maximumAge: 15000 });
                } catch (_) { }
            }
            if (share.timer) clearInterval(share.timer);
            share.timer = setInterval(async () => {
                if (this._gtLiveShare !== share) { clearInterval(share.timer); return; }
                if (nowSec() >= share.until) { await this.gtStopLive(true); return; }
                share.seq++;
                save(LIVE_KEY, Object.assign({}, share, { timer: undefined, watchId: undefined }));
                await this._gtSendToChat(share.chat, T().buildLocation(Object.assign({ kind: 'live' }, share)));
            }, T().LIMITS.liveUpdateSec * 1000);
        },

        async gtStopLive(silent) {
            const share = this._gtLiveShare;
            if (!share) return;
            this._gtLiveShare = null;
            try { localStorage.removeItem(LIVE_KEY); } catch (_) { }
            if (share.timer) clearInterval(share.timer);
            if (share.watchId != null && navigator.geolocation) { try { navigator.geolocation.clearWatch(share.watchId); } catch (_) { } }
            share.seq++;
            await this._gtSendToChat(share.chat, T().buildLocation(Object.assign({}, share, { kind: 'end' })));
            if (!silent || nowSec() < share.until) this._gtNotice(this._gx('Stopped sharing your live location.'));
            else this._gtNotice(this._gx('Your live location share ended.'));
        },

        _gtResumeLive() {
            const saved = load(LIVE_KEY, null);
            if (!saved || !saved.id || !saved.chat) return;
            if (nowSec() >= saved.until) {
                this._gtLiveShare = saved;
                this.gtStopLive(true);
                return;
            }
            this._gtLiveShare = Object.assign({}, saved, { timer: null, watchId: null });
            this._gtLiveLoop();
            this._gtNotice(this._gx('Still sharing your live location until {time}.', { time: new Date(saved.until * 1000).toLocaleTimeString() }));
        },

        openCreateEvent(groupId) {
            const gid = groupId || this.currentGroup;
            if (!gid || !this.groupConversations.has(gid)) {
                this._gtNotice(this._gx('Events can only be created in a group.'));
                return;
            }
            if (!this._gtGate('event', 'group').ok) return;
            const blocked = this._gtGroupSendBlocked('', gid);
            if (blocked) { this._gtNotice(blocked); return; }
            const esc = (s) => this.escapeHtml(String(s));
            const { body } = this._ctModal('gtEventModal', this._gx('New event'));
            const d = new Date(Date.now() + 3600000);
            d.setMinutes(0, 0, 0);
            const pad = (n) => String(n).padStart(2, '0');
            const dateVal = d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
            const timeVal = pad(d.getHours()) + ':' + pad(d.getMinutes());
            const devOff = -d.getTimezoneOffset();
            const offs = TZ_OFFSETS.indexOf(devOff) >= 0 ? TZ_OFFSETS : TZ_OFFSETS.concat([devOff]).sort((a, b) => a - b);
            const tzOpts = offs.map((o) => `<option value="${o}"${o === devOff ? ' selected' : ''}>${esc(T().tzLabel(o))}${o === devOff ? ' · ' + esc(this._gx('this device')) : ''}</option>`).join('');
            body.innerHTML = `<form class="gt-form" data-group-id="${esc(gid)}">
                <label>${esc(this._gx('Title'))}<input class="form-input" name="title" maxlength="${T().LIMITS.titleMax}" required></label>
                <div class="gt-form-row"><label>${esc(this._gx('Date'))}<input class="form-input" type="date" name="date" value="${dateVal}" required></label>
                <label>${esc(this._gx('Time'))}<input class="form-input" type="time" name="time" value="${timeVal}" required></label></div>
                <label>${esc(this._gx('Time zone'))}<select class="form-input" name="tz">${tzOpts}</select></label>
                <label>${esc(this._gx('Place (optional)'))}<input class="form-input" name="place" maxlength="${T().LIMITS.placeMax}"></label>
                <label>${esc(this._gx('Note (optional)'))}<input class="form-input" name="note" maxlength="${T().LIMITS.noteMax}"></label>
                <div class="gt-form-actions"><button type="button" class="icon-btn" data-action="ctCloseModal" data-modal-id="gtEventModal">${esc(this._gx('Cancel'))}</button>
                <button type="submit" class="send-btn">${esc(this._gx('Create event'))}</button></div></form>`;
            const form = body.querySelector('form');
            form.addEventListener('submit', (e) => { e.preventDefault(); this._gtSubmitEvent(form); });
            setTimeout(() => { try { form.title.focus(); } catch (_) { } }, 50);
        },

        async _gtSubmitEvent(form) {
            const gid = form.dataset.groupId;
            const title = form.elements.title.value;
            const dm = /^(\d{4})-(\d{2})-(\d{2})$/.exec(form.elements.date.value || '');
            const tm = /^(\d{2}):(\d{2})$/.exec(form.elements.time.value || '');
            if (!dm || !tm || !title.trim()) { this._gtNotice(this._gx('Add a title, date and time.')); return; }
            const offset = parseInt(form.elements.tz.value, 10) || 0;
            const start = T().wallToUtc(+dm[1], +dm[2], +dm[3], +tm[1], +tm[2], offset);
            const content = T().buildEventContent({ id: rand(8), title, start, offset, place: form.elements.place.value, note: form.elements.note.value });
            if (!content) { this._gtNotice(this._gx('Add a title, date and time.')); return; }
            this._ctCloseModal('gtEventModal');
            await this.sendGroupMessage(content, gid);
        },

        _gtCallLinks() {
            if (!this._gtLinks) this._gtLinks = load(CALL_LINKS_KEY + (this.pubkey || ''), []) || [];
            return this._gtLinks;
        },

        _gtSaveCallLinks() {
            save(CALL_LINKS_KEY + (this.pubkey || ''), this._gtCallLinks());
        },

        _gtCallLinkUrl(link) {
            return window.location.origin + window.location.pathname + '#call=' + T().encodeCallLink(link);
        },

        openCreateCallLink(context) {
            if (!this._gtGate('callLink', 'none').ok) return;
            if (!this._canSendGiftWraps()) { this._gtNotice(this._gx('Call links need a logged-in account.')); return; }
            const ctx = context || {};
            let name = '';
            if (ctx.groupId && this.groupConversations.has(ctx.groupId)) name = this.groupConversations.get(ctx.groupId).name || '';
            else if (ctx.pubkey) name = this.getNymFromPubkey(ctx.pubkey);
            const esc = (s) => this.escapeHtml(String(s));
            const { body } = this._ctModal('gtCallLinkModal', this._gx('New call link'));
            body.innerHTML = `<form class="gt-form">
                <label>${esc(this._gx('Name'))}<input class="form-input" name="name" maxlength="${T().LIMITS.linkNameMax}" value="${esc(T().sanitizeName(name || this._gx('Call')))}"></label>
                <div class="gt-chips" role="radiogroup" aria-label="${esc(this._gx('Call type'))}"><label class="gt-chip"><input type="radio" name="kind" value="audio" checked><span>${esc(this._gx('Voice'))}</span></label>
                <label class="gt-chip"><input type="radio" name="kind" value="video"><span>${esc(this._gx('Video'))}</span></label></div>
                <label>${esc(this._gx('Expires'))}<select class="form-input" name="exp">${T().CALL_LINK_EXPIRY_SEC.map((s) => `<option value="${s}"${s === 86400 ? ' selected' : ''}>${esc(this._gx(T().expiryLabel(s)))}</option>`).join('')}</select></label>
                <p class="gt-hint">${esc(this._gx('Anyone with the link can ask to join. You admit each person, and you can revoke the link at any time.'))}</p>
                <div class="gt-form-actions"><button type="button" class="icon-btn" data-action="ctCloseModal" data-modal-id="gtCallLinkModal">${esc(this._gx('Cancel'))}</button>
                <button type="submit" class="send-btn">${esc(this._gx('Create link'))}</button></div></form>`;
            const form = body.querySelector('form');
            form.addEventListener('submit', (e) => {
                e.preventDefault();
                const expSec = parseInt(form.elements.exp.value, 10) || 0;
                const link = {
                    id: rand(8), host: this.pubkey, kind: form.elements.kind.value === 'video' ? 'video' : 'audio',
                    exp: expSec ? nowSec() + expSec : 0, secret: rand(16), name: T().sanitizeName(form.elements.name.value) || 'Call',
                    createdAt: nowSec(),
                };
                if (ctx.groupId) link.groupId = ctx.groupId;
                this._gtLinks = T().addCallLink(this._gtCallLinks(), link);
                this._gtSaveCallLinks();
                this._gtShowCreatedLink(link, ctx);
            });
        },

        _gtShowCreatedLink(link, ctx) {
            const esc = (s) => this.escapeHtml(String(s));
            const url = this._gtCallLinkUrl(link);
            const { body } = this._ctModal('gtCallLinkModal', this._gx('Call link ready'));
            const chat = ctx && (ctx.groupId ? { type: 'group', id: ctx.groupId } : (ctx.pubkey ? { type: 'dm', id: ctx.pubkey } : null));
            this._gtLinkShareChat = chat;
            body.innerHTML = `<div class="gt-link-box" id="gtCreatedLink">${esc(url)}</div>
                <div class="gt-form-actions"><button class="icon-btn" data-action="gtCopyCallLink" data-link-id="${link.id}">${esc(this._gx('Copy link'))}</button>
                ${chat ? `<button class="send-btn" data-action="gtSendCallLink" data-link-id="${link.id}">${esc(this._gx('Send in this chat'))}</button>` : ''}</div>`;
        },

        openCallLinks() {
            const esc = (s) => this.escapeHtml(String(s));
            const { body } = this._ctModal('gtCallLinksModal', this._gx('Call links'));
            const links = this._gtCallLinks();
            const now = nowSec();
            const rows = links.map((l) => {
                const st = T().callLinkState(l, now);
                const stLabel = st === 'active' ? (l.exp ? this._gx('Active until {time}', { time: new Date(l.exp * 1000).toLocaleString() }) : this._gx('Active, never expires'))
                    : (st === 'revoked' ? this._gx('Revoked') : this._gx('Expired'));
                return `<div class="gt-link-row gt-link-${st}"><div class="gt-link-info"><div class="gt-link-name">${esc(l.name)} · ${esc(l.kind === 'video' ? this._gx('Video') : this._gx('Voice'))}</div>
                    <div class="gt-link-state">${esc(stLabel)}</div></div>
                    ${st === 'active' ? `<button class="icon-btn" data-action="gtCopyCallLink" data-link-id="${l.id}">${esc(this._gx('Copy'))}</button>
                    <button class="icon-btn danger" data-action="gtRevokeCallLink" data-link-id="${l.id}">${esc(this._gx('Revoke'))}</button>` : ''}</div>`;
            }).join('');
            body.innerHTML = `<button class="send-btn gt-wide" data-action="gtNewCallLink">${esc(this._gx('New call link'))}</button>
                ${rows || `<div class="ct-empty">${esc(this._gx('No call links yet.'))}</div>`}`;
        },

        gtRevokeCallLink(id) {
            this._gtLinks = T().revokeCallLink(this._gtCallLinks(), id);
            this._gtSaveCallLinks();
            this._gtNotice(this._gx('Call link revoked. Anyone who tries it now is told it was revoked.'));
            this.openCallLinks();
        },

        async gtCopyCallLink(id) {
            const link = this._gtCallLinks().find((l) => l.id === id);
            if (!link) return;
            try {
                await navigator.clipboard.writeText(this._gtCallLinkUrl(link));
                this._gtNotice(this._gx('Call link copied.'));
            } catch (_) {
                this._gtNotice(this._gx("Couldn't copy the link."));
            }
        },

        async gtSendCallLink(id) {
            const link = this._gtCallLinks().find((l) => l.id === id);
            const chat = this._gtLinkShareChat;
            this._ctCloseModal('gtCallLinkModal');
            if (!link || !chat) return;
            if (chat.type === 'group') await this.sendGroupMessage(this._gtCallLinkUrl(link), chat.id);
            else await this.sendPM(this._gtCallLinkUrl(link), chat.id);
        },

        async handleCallLinkFromUrl(token) {
            const link = T().parseCallLinkInput(token);
            if (!link) { this._gtNotice(this._gx(T().STRINGS.refusedInvalid)); return; }
            if (!this._gtGate('callLink', 'none').ok) return;
            if (link.host === this.pubkey) { this.openCallLinks(); return; }
            if (T().callLinkState(link, nowSec()) === 'expired') { this._gtNotice(this._gx(T().STRINGS.refusedExpired)); return; }
            if (!this._canSendGiftWraps()) { this._gtNotice(this._gx('Pick a nym or log in to join this call.')); return; }
            if (this.activeCall || this.incomingCall) { this._gtNotice(this._gx('Already in a call')); return; }
            if (!this.users.has(link.host) && typeof this.fetchProfileDirect === 'function') { try { await this.fetchProfileDirect(link.host); } catch (_) { } }
            const host = this.getNymFromPubkey(link.host) + '#' + this.getPubkeySuffix(link.host);
            const msg = link.kind === 'video'
                ? this._gx('Join the video call "{name}" hosted by {host}? The host admits you. Your camera and microphone are used once you join.', { name: link.name, host })
                : this._gx('Join the voice call "{name}" hosted by {host}? The host admits you. Your microphone is used once you join.', { name: link.name, host });
            const ok = await window.showAppConfirm(msg, { title: this._gx('Join call'), okLabel: this._gx('Ask to join') });
            if (!ok) return;
            const stream = await this._getLocalMedia(link.kind);
            if (!stream) return;
            stream.getTracks().forEach((t) => t.stop());
            this._gtLinkJoin = { id: link.id, host: link.host, kind: link.kind, at: Date.now() };
            await this._sendCallSignal(link.host, { type: T().CALL_SIGNALS.join, linkId: link.id, secret: link.secret, kind: link.kind });
            this._gtNotice(this._gx('Asked {host} to let you in…', { host }));
            setTimeout(() => {
                if (this._gtLinkJoin && this._gtLinkJoin.id === link.id && !this.activeCall) {
                    this._gtLinkJoin = null;
                    this._gtNotice(this._gx('The host did not answer. They may be offline.'));
                }
            }, LINK_JOIN_WAIT_MS);
        },

        _gtLinkJoinMatches(sender, data) {
            const j = this._gtLinkJoin;
            return !!(j && data && data.link === j.id && sender === j.host && Date.now() - j.at < LINK_JOIN_WAIT_MS);
        },

        async _gtOnCallSignal(sender, data) {
            const S = T().CALL_SIGNALS;
            if (data.type === S.refused) {
                const j = this._gtLinkJoin;
                if (!j || j.host !== sender || data.linkId !== j.id) return;
                this._gtLinkJoin = null;
                this._gtNotice(this._gx(T().callLinkRefusal(data.reason)));
                return;
            }
            if (data.type === S.memberAdd) {
                const ac = this.activeCall;
                if (!ac || ac.callId !== data.callId || !this._isCallParticipant(ac, sender)) return;
                if (typeof data.pubkey === 'string' && /^[0-9a-f]{64}$/.test(data.pubkey) && !ac.members.includes(data.pubkey)) ac.members.push(data.pubkey);
                return;
            }
            if (data.type !== S.join) return;
            const check = T().checkCallLinkJoin(this._gtCallLinks(), data.linkId, data.secret, nowSec());
            if (!check.ok) {
                if (check.reason !== 'unknown') this._sendCallSignal(sender, { type: S.refused, linkId: data.linkId, reason: check.reason === 'secret' ? 'invalid' : check.reason });
                return;
            }
            const link = this._gtCallLinks().find((l) => l.id === data.linkId);
            if (this.incomingCall || (this.activeCall && this.activeCall.kind !== link.kind)) {
                this._sendCallSignal(sender, { type: S.refused, linkId: link.id, reason: 'busy' });
                return;
            }
            if (!this.users.has(sender) && typeof this.fetchProfileDirect === 'function') { try { await this.fetchProfileDirect(sender); } catch (_) { } }
            const who = this.getNymFromPubkey(sender) + '#' + this.getPubkeySuffix(sender);
            this.showNotification(this._gx('Call link: {name}', { name: link.name }), this._gx('{nym} wants to join', { nym: who }), { type: 'call', pubkey: sender, eventId: 'call-link-' + link.id + '-' + sender + '-' + nowSec() }, Date.now());
            const admit = await window.showAppConfirm(this._gx('{nym} wants to join your call link "{name}".', { nym: who, name: link.name }), { title: this._gx('Join request'), okLabel: this._gx('Admit'), cancelLabel: this._gx('Decline') });
            const recheck = T().checkCallLinkJoin(this._gtCallLinks(), data.linkId, data.secret, nowSec());
            if (!admit || !recheck.ok) {
                this._sendCallSignal(sender, { type: S.refused, linkId: link.id, reason: admit ? recheck.reason : 'declined' });
                return;
            }
            await this._gtAdmitToCall(link, sender);
        },

        async _gtAdmitToCall(link, joiner) {
            const ac = this.activeCall;
            if (ac) {
                if (!ac.members.includes(joiner)) ac.members.push(joiner);
                ac.isGroup = true;
                const others = ac.members.filter((pk) => pk !== this.pubkey && pk !== joiner);
                this._broadcastCallSignal(others, { type: T().CALL_SIGNALS.memberAdd, callId: ac.callId, pubkey: joiner });
                this._sendCallSignal(joiner, { type: 'invite', callId: ac.callId, kind: ac.kind, isGroup: true, groupId: null, members: ac.members.slice(), link: link.id });
                return;
            }
            const stream = await this._getLocalMedia(link.kind);
            if (!stream) return;
            const callId = this._genCallId();
            this.activeCall = {
                callId, kind: link.kind, isGroup: false, groupId: null,
                localStream: stream, status: 'outgoing', peers: new Map(),
                members: [this.pubkey, joiner], muted: false, cameraOff: false, facingMode: 'user',
                startedAt: 0, timerInterval: null, ringTimeout: null, gtLinkId: link.id,
            };
            this._initCallExtras(this.activeCall);
            this._sendCallSignal(joiner, { type: 'invite', callId, kind: link.kind, isGroup: false, groupId: null, members: this.activeCall.members.slice(), link: link.id });
            this._showCallOverlay();
            this._setCallStatus(this._gx('Connecting…'));
            this.activeCall.ringTimeout = setTimeout(() => {
                if (this.activeCall && this.activeCall.callId === callId && this.activeCall.status === 'outgoing') {
                    this._sendCallSignal(joiner, { type: 'cancel', callId });
                    this._endCall();
                }
            }, 45000);
        },

        gtShowDescription(groupId) {
            const group = this.groupConversations.get(groupId || this.currentGroup);
            if (!group || !group.description) return;
            window.showAppAlert(group.description, { title: group.name || this._gx('Group') });
        },

        _gtGroupMenuHtml(groupId) {
            const group = this.groupConversations.get(groupId);
            if (!group) return '';
            const esc = (s) => this.escapeHtml(String(s));
            const role = this._gtRole(groupId, this.pubkey);
            const admin = role === 'owner' || role === 'admin';
            const checkbox = (on) => ico(on
                ? '<rect x="2.5" y="2.5" width="11" height="11" rx="2.5"/><path d="M 5 8 L 7 10 L 11 5.5"/>'
                : '<rect x="2.5" y="2.5" width="11" height="11" rx="2.5"/>');
            const offline = !this.connected;
            const dis = offline ? ` data-gt-disabled="1" title="${esc(this._gx(T().STRINGS.groupsNeedNet))}"` : '';
            const out = [];
            if (admin) {
                out.push(`<div class="context-menu-item gt-menu-row${offline ? ' gt-disabled' : ''}" data-action="gtOpenSlowmode" data-group-id="${esc(groupId)}"${dis}>${ICONS.slowmode}<span class="gt-menu-label">${esc(this._gx('Slowmode'))}</span><span class="gt-menu-value">${esc(this._gx(T().slowmodeLabel(group.slowmode)))}</span></div>`);
                out.push(`<div class="context-menu-item${offline ? ' gt-disabled' : ''}" data-action="gtToggleJoinApproval" data-group-id="${esc(groupId)}"${dis}>${checkbox(group.joinApproval === true)}${esc(this._gx('Admins approve join requests'))}</div>`);
                const n = T().pruneJoinRequests(group.joinRequests || [], nowSec()).length;
                if (group.joinApproval === true || n) out.push(`<div class="context-menu-item gt-menu-row" data-action="gtOpenJoinRequests" data-group-id="${esc(groupId)}">${ICONS.requests}<span class="gt-menu-label">${esc(this._gx('Join requests'))}</span>${n ? `<span class="gt-menu-badge">${n}</span>` : ''}</div>`);
            }
            out.push(`<div class="context-menu-item${offline ? ' gt-disabled' : ''}" data-action="gtCreateEvent" data-group-id="${esc(groupId)}"${dis}>${ICONS.event}${esc(this._gx('Create event'))}</div>`);
            out.push(`<div class="context-menu-item${offline ? ' gt-disabled' : ''}" data-action="gtShareLocationGroup" data-group-id="${esc(groupId)}"${dis}>${ICONS.location}${esc(this._gx('Share location'))}</div>`);
            out.push(`<div class="context-menu-item${offline ? ' gt-disabled' : ''}" data-action="gtCreateCallLinkGroup" data-group-id="${esc(groupId)}"${offline ? ` data-gt-disabled="1" title="${esc(this._gx(T().STRINGS.callNeedsNet))}"` : ''}>${ICONS.callLink}${esc(this._gx('Create call link'))}</div>`);
            return out.join('');
        },

        gtOpenSlowmode(groupId) {
            const group = this.groupConversations.get(groupId);
            if (!group) return;
            const esc = (s) => this.escapeHtml(String(s));
            const cur = T().normalizeSlowmode(group.slowmode);
            const { body } = this._ctModal('gtSlowmodeModal', this._gx('Slowmode'));
            body.innerHTML = `<p class="gt-hint">${esc(this._gx('Members can send one message per interval. The owner, admins and moderators are not limited.'))}</p>
                <div class="gt-slow-options">${T().SLOWMODE_SECONDS.map((s) => `<button class="icon-btn gt-slow-opt${s === cur ? ' active' : ''}" data-action="gtSetSlowmode" data-group-id="${esc(groupId)}" data-sec="${s}" aria-pressed="${s === cur}">${esc(this._gx(T().slowmodeLabel(s)))}</button>`).join('')}</div>`;
        },

        _gtRenderSlowBar() {
            let bar = document.getElementById('gtSlowBar');
            const gid = this.inPMMode ? this.currentGroup : null;
            const group = gid ? this.groupConversations.get(gid) : null;
            const interval = group ? T().normalizeSlowmode(group.slowmode) : 0;
            if (!interval) { if (bar) bar.classList.add('nm-hidden'); return; }
            if (!bar) {
                const row = document.querySelector('.message-input-row');
                if (!row || !row.parentNode) return;
                bar = document.createElement('div');
                bar.id = 'gtSlowBar';
                bar.className = 'gt-slow-bar';
                bar.setAttribute('role', 'status');
                row.parentNode.insertBefore(bar, row);
            }
            const exempt = T().slowmodeExempt(this._gtRole(gid, this.pubkey));
            const wait = exempt ? 0 : this._gtSlowmodeWait(gid);
            const label = this._gx('Slowmode: one message every {interval}', { interval: T().slowmodeLabel(interval) });
            const text = exempt ? label + ' · ' + this._gx("you're exempt") : (wait > 0 ? label + ' · ' + this._gx('send again in {time}', { time: T().formatWait(wait) }) : label);
            if (bar.textContent !== text) bar.textContent = text;
            bar.classList.toggle('gt-slow-wait', wait > 0);
            bar.classList.remove('nm-hidden');
        },

        _gtBroadcastItems(query) {
            if (!(this.inPMMode && this.currentGroup)) return [];
            return T().broadcastSuggestions('group', this._gtRole(this.currentGroup, this.pubkey), query);
        },

        _gtDecorateAutocomplete(search) {
            const dropdown = document.getElementById('autocompleteDropdown');
            if (!dropdown) return;
            dropdown.querySelectorAll('.gt-ac-broadcast').forEach((el) => el.remove());
            const words = this._gtBroadcastItems(search || '');
            if (!words.length) return;
            const frag = document.createDocumentFragment();
            for (const w of words) {
                const item = document.createElement('div');
                item.className = 'autocomplete-item gt-ac-broadcast';
                item.dataset.action = 'gtSelectBroadcast';
                item.dataset.word = w;
                const strong = document.createElement('strong');
                strong.textContent = '@' + w;
                const hint = document.createElement('span');
                hint.className = 'gt-ac-hint';
                hint.textContent = w === 'here' ? this._gx('Notify everyone in this group') : this._gx('Notify all members');
                item.appendChild(strong);
                item.appendChild(hint);
                frag.appendChild(item);
            }
            dropdown.insertBefore(frag, dropdown.firstChild);
            dropdown.querySelectorAll('.autocomplete-item').forEach((el, i) => el.classList.toggle('selected', i === 0));
            dropdown.classList.add('active');
            this.autocompleteIndex = 0;
        },

        gtSelectBroadcast(word) {
            const input = document.getElementById('messageInput');
            if (!input) return;
            const value = input.value;
            const at = value.lastIndexOf('@');
            input.value = (at >= 0 ? value.substring(0, at) : value) + '@' + word + ' ';
            input.focus();
            this.hideAutocomplete();
        },

        _gtChatMenuItems(key) {
            const k = String(key || '');
            const out = [];
            const svg = (s) => s.replace('class="nm-ico8"', '');
            if (k.startsWith('group-')) {
                const gid = k.slice(6);
                if (!this.groupConversations.has(gid)) return out;
                out.push({ label: this._gx('Create event'), svg: svg(ICONS.event), action: () => this.openCreateEvent(gid) });
                out.push({ label: this._gx('Share location'), svg: svg(ICONS.location), action: () => this.openShareLocation({ type: 'group', id: gid }) });
                out.push({ label: this._gx('Create call link'), svg: svg(ICONS.callLink), action: () => this.openCreateCallLink({ groupId: gid }) });
            } else if (k.startsWith('pm-')) {
                const peer = typeof this._ctPeerFromKey === 'function' ? this._ctPeerFromKey(k) : '';
                if (!peer) return out;
                out.push({ label: this._gx('Share location'), svg: svg(ICONS.location), action: () => this.openShareLocation({ type: 'dm', id: peer }) });
                out.push({ label: this._gx('Create call link'), svg: svg(ICONS.callLink), action: () => this.openCreateCallLink({ pubkey: peer }) });
            }
            return out;
        },

        _gtRefreshLocationButton() {
            const btn = document.getElementById('gtLocationBtn');
            if (!btn) return;
            btn.classList.toggle('nm-hidden', !(this.inPMMode && (this.currentGroup || this.currentPM)));
        },

        _gtStart() {
            if (this._gtStarted) return;
            this._gtStarted = true;
            this._gtPendingJoins();
            this._gtArmReminders();
            this._gtResumeLive();
            setInterval(() => {
                try { this._gtRenderSlowBar(); this._gtRefreshLocationButton(); } catch (_) { }
            }, 1000);
            setInterval(() => {
                try {
                    document.querySelectorAll('.gt-loc-live').forEach((el) => {
                        const holder = el.closest('.message');
                        const found = holder && this._ctFindMessage ? this._ctFindMessage(holder.dataset.messageId) : null;
                        if (found) this._gtRefreshLocationCard(found.msg);
                    });
                } catch (_) { }
            }, 30000);
        },
    });

    const origShowAutocomplete = NYM.prototype.showAutocomplete;
    NYM.prototype.showAutocomplete = function (search) {
        const r = origShowAutocomplete.apply(this, arguments);
        try { this._gtDecorateAutocomplete(search); } catch (_) { }
        return r;
    };

    const origSelectAutocomplete = NYM.prototype.selectAutocomplete;
    NYM.prototype.selectAutocomplete = function () {
        const sel = document.querySelector('.autocomplete-item.selected');
        if (sel && sel.classList.contains('gt-ac-broadcast')) { this.gtSelectBroadcast(sel.dataset.word); return; }
        return origSelectAutocomplete.apply(this, arguments);
    };

    const origChatItems = NYM.prototype._ctChatMenuItems;
    NYM.prototype._ctChatMenuItems = function (key) {
        const base = typeof origChatItems === 'function' ? origChatItems.apply(this, arguments) : [];
        let extra = [];
        try { extra = this._gtChatMenuItems(key); } catch (_) { }
        return base.concat(extra);
    };

    const origLinkPreviews = NYM.prototype._attachLinkPreviews;
    NYM.prototype._attachLinkPreviews = function (el) {
        const r = typeof origLinkPreviews === 'function' ? origLinkPreviews.apply(this, arguments) : undefined;
        try { this._gtDrawMaps(el); } catch (_) { }
        return r;
    };

    const origDisplay = NYM.prototype.displayMessage;
    NYM.prototype.displayMessage = function (message) {
        try {
            if (message && (message.isPM || message.isGroup) && message.conversationKey) {
                const list = this.pmMessages && this.pmMessages.get(message.conversationKey);
                if (list && this._gtAbsorbLive(message, list)) {
                    const i = list.indexOf(message);
                    if (i >= 0) list.splice(i, 1);
                    message.gtAbsorbed = true;
                    if (typeof this.persistPMMessages === 'function') this.persistPMMessages(message.conversationKey);
                    return;
                }
            }
        } catch (_) { }
        return origDisplay.apply(this, arguments);
    };

    const origHandleCallSignal = NYM.prototype.handleCallSignalingEvent;
    NYM.prototype.handleCallSignalingEvent = function (event) {
        let data = null;
        try { data = JSON.parse(event.content); } catch (_) { data = null; }
        const S = window.NymGroupTools && window.NymGroupTools.CALL_SIGNALS;
        if (data && S && (data.type === S.join || data.type === S.refused || data.type === S.memberAdd)) {
            if (event.pubkey === this.pubkey || (this.blockedUsers && this.blockedUsers.has(event.pubkey))) return;
            this._gtOnCallSignal(event.pubkey, data);
            return;
        }
        return origHandleCallSignal.apply(this, arguments);
    };

    if (typeof window !== 'undefined' && window.NYM_ACTIONS) {
        const nym = () => window.nym;
        const disabled = (t) => {
            if (t && t.dataset && t.dataset.gtDisabled) { nym()._gtNotice(t.getAttribute('title') || ''); return true; }
            return false;
        };
        Object.assign(window.NYM_ACTIONS, {
            gtShowHeld: function (e, t) {
                if (e && e.stopPropagation) e.stopPropagation();
                const el = t.closest('.message');
                const found = el && nym()._ctFindMessage(el.dataset.messageId);
                if (!found) return;
                found.msg._heldShown = true;
                const holder = t.closest('.gt-held');
                if (holder) holder.outerHTML = nym().formatMessageWithQuotes(found.msg.content, 0, false);
            },
            gtShowDescription: function (_e, t) { nym().gtShowDescription(t.dataset.groupId); },
            gtRsvp: function (e, t) { if (e && e.stopPropagation) e.stopPropagation(); nym().gtRsvp(t.dataset.groupId, t.dataset.eventId, t.dataset.status); },
            gtReminderChange: function (_e, t) { nym().gtSetReminder(t.dataset.groupId, t.dataset.eventId, t.value); },
            gtCopyCoords: async function (e, t) {
                if (e && e.stopPropagation) e.stopPropagation();
                try { await navigator.clipboard.writeText(t.dataset.coords); nym()._gtNotice(nym()._gx('Coordinates copied.')); } catch (_) { }
            },
            gtStopLive: function (e) { if (e && e.stopPropagation) e.stopPropagation(); nym()._ctCloseModal('gtLocationModal'); nym().gtStopLive(false); },
            gtOpenLocation: function () { nym().openShareLocation(); },
            gtSendCurrentLocation: function () { nym().gtSendCurrentLocation(); },
            gtPickLocation: function () { nym().gtPickLocation(); },
            gtPickZoomOut: function () { nym().gtPickZoomOut(); },
            gtPickSend: function () { nym().gtPickSend(); },
            gtStartLive: function (_e, t) { nym().gtStartLive(t.dataset.sec); },
            gtOpenSlowmode: function (_e, t) { if (disabled(t)) return; nym().closeGroupContextMenu(); nym().gtOpenSlowmode(t.dataset.groupId); },
            gtSetSlowmode: function (_e, t) { nym()._ctCloseModal('gtSlowmodeModal'); nym().setGroupSlowmode(t.dataset.groupId, parseInt(t.dataset.sec, 10)); },
            gtToggleJoinApproval: function (_e, t) {
                if (disabled(t)) return;
                const n = nym();
                const g = n.groupConversations.get(t.dataset.groupId);
                n.closeGroupContextMenu();
                if (g) n.setGroupJoinApproval(t.dataset.groupId, g.joinApproval !== true);
            },
            gtOpenJoinRequests: function (_e, t) { nym().closeGroupContextMenu(); nym().openJoinRequests(t.dataset.groupId); },
            gtJoinApprove: function (_e, t) { nym().gtDecideJoin(t.dataset.groupId, t.dataset.pubkey, true); },
            gtJoinDecline: function (_e, t) { nym().gtDecideJoin(t.dataset.groupId, t.dataset.pubkey, false); },
            gtCreateEvent: function (_e, t) { if (disabled(t)) return; nym().closeGroupContextMenu(); nym().openCreateEvent(t.dataset.groupId); },
            gtShareLocationGroup: function (_e, t) { if (disabled(t)) return; nym().closeGroupContextMenu(); nym().openShareLocation({ type: 'group', id: t.dataset.groupId }); },
            gtCreateCallLinkGroup: function (_e, t) { if (disabled(t)) return; nym().closeGroupContextMenu(); nym().openCreateCallLink({ groupId: t.dataset.groupId }); },
            gtOpenCallLinks: function () { nym().openCallLinks(); },
            gtOpenCallLinksAndCloseSidebar: function () { nym().openCallLinks(); if (typeof nym().closeSidebar === 'function') nym().closeSidebar(); },
            gtNewCallLink: function () { nym()._ctCloseModal('gtCallLinksModal'); nym().openCreateCallLink(nym()._gtCurrentChat() ? (nym().currentGroup ? { groupId: nym().currentGroup } : { pubkey: nym().currentPM }) : {}); },
            gtCopyCallLink: function (_e, t) { nym().gtCopyCallLink(t.dataset.linkId); },
            gtSendCallLink: function (_e, t) { nym().gtSendCallLink(t.dataset.linkId); },
            gtRevokeCallLink: function (_e, t) { nym().gtRevokeCallLink(t.dataset.linkId); },
            gtJoinCallLink: function (e, t) { if (e && e.stopPropagation) e.stopPropagation(); nym().handleCallLinkFromUrl(t.dataset.callLink); },
            gtSelectBroadcast: function (_e, t) { nym().gtSelectBroadcast(t.dataset.word); },
            gtToggleInviteDesc: function (_e, t) { t.classList.toggle('expanded'); },
        });
        const boot = () => {
            const n = window.nym;
            if (n && n.pubkey && typeof n._gtStart === 'function') n._gtStart();
            else setTimeout(boot, 2000);
        };
        setTimeout(boot, 1000);
    }
})();
