(function () {
    if (typeof NYM === 'undefined') return;

    const P = () => window.NymDmPolls;
    const STORE_KEY = 'nym_dm_poll_votes_';
    const MAX_AVATARS = 8;

    function nowSec() {
        return Math.floor(Date.now() / 1000);
    }

    function load(key) {
        try {
            const raw = localStorage.getItem(key);
            const v = raw ? JSON.parse(raw) : null;
            return v && typeof v === 'object' ? v : {};
        } catch (_) { return {}; }
    }

    function save(key, value) {
        try { localStorage.setItem(key, JSON.stringify(value)); } catch (_) { }
    }

    Object.assign(NYM.prototype, {

        _dpx(text, vars) {
            let s = typeof this.uiText === 'function' ? this.uiText(text) : text;
            if (vars) for (const k of Object.keys(vars)) s = s.split('{' + k + '}').join(String(vars[k]));
            return s;
        },

        _dpStore() {
            if (!this._dpVotes || this._dpVotesPk !== (this.pubkey || '')) {
                this._dpVotesPk = this.pubkey || '';
                this._dpVotes = load(STORE_KEY + this._dpVotesPk);
            }
            return this._dpVotes;
        },

        _dpSave() {
            this._dpVotes = P().prune(this._dpStore());
            save(STORE_KEY + this._dpVotesPk, this._dpVotes);
        },

        _dpRefusal() {
            if (!this.inPMMode) return '';
            if (!this.currentGroup && this.currentPM && typeof this.isVerifiedBot === 'function' && this.isVerifiedBot(this.currentPM)) {
                return this._dpx(P().STRINGS.botRefused);
            }
            return '';
        },

        async publishDmPoll(question, options) {
            const content = P().buildPollContent(question, options);
            if (!content) return false;
            const refusal = this._dpRefusal();
            if (refusal) {
                this.displaySystemMessage(refusal);
                return false;
            }
            let ok = false;
            if (this.currentGroup) ok = await this.sendGroupMessage(content, this.currentGroup);
            else if (this.currentPM) ok = await this.sendPM(content, this.currentPM);
            if (!ok) this.displaySystemMessage(this._dpx(P().STRINGS.sendFailed));
            return !!ok;
        },

        _dpLocate(pollId) {
            const found = typeof this._ctFindMessage === 'function' ? this._ctFindMessage(pollId) : null;
            if (!found || !found.msg || found.msg.nymMessageId !== pollId) return null;
            const poll = P().parsePoll(found.msg.content);
            return poll ? { msg: found.msg, key: found.key, poll } : null;
        },

        _dpAllowed(msg) {
            if (msg.isGroup) {
                const g = this.groupConversations && this.groupConversations.get(msg.groupId);
                if (!g) return [];
                const out = Array.isArray(g.members) ? g.members.slice() : [];
                if (g.createdBy && out.indexOf(g.createdBy) < 0) out.push(g.createdBy);
                return out;
            }
            return [this.pubkey, msg.conversationPubkey].filter(Boolean);
        },

        _dpTally(msg, poll) {
            const entry = this._dpStore()[msg.nymMessageId];
            return P().tally(entry, { options: poll.options.length, author: msg.pubkey, allowed: this._dpAllowed(msg) });
        },

        _dpControlRumor(msg, extraTags, content, ts) {
            const tags = [];
            if (msg.isGroup) {
                const g = this.groupConversations.get(msg.groupId);
                if (!g || !Array.isArray(g.members)) return null;
                for (const pk of g.members) tags.push(['p', pk]);
                tags.push(['g', msg.groupId]);
                if (g.name) tags.push(['subject', g.name]);
            } else {
                if (!msg.conversationPubkey) return null;
                tags.push(['p', msg.conversationPubkey]);
            }
            for (const t of extraTags) tags.push(t);
            tags.push(['x', this._generateSharedEventId()]);
            return { kind: 14, created_at: ts, tags, content, pubkey: this.pubkey };
        },

        async _dpSend(msg, rumor) {
            if (typeof this._canSendGiftWraps === 'function' && !this._canSendGiftWraps()) return;
            if (msg.isGroup) {
                const g = this.groupConversations.get(msg.groupId);
                if (!g) return;
                await this._sendGiftWrapsAsync(g.members, rumor, null, msg.groupId);
                return;
            }
            await this._sendGiftWrapsAsync([this.pubkey, msg.conversationPubkey], rumor, null);
        },

        async dmPollVote(pollId, optionIndex) {
            const loc = this._dpLocate(pollId);
            if (!loc) return;
            const { msg, poll } = loc;
            const idx = Number(optionIndex);
            if (!Number.isInteger(idx) || idx < 0 || idx >= poll.options.length) return;
            if (this._dpAllowed(msg).indexOf(this.pubkey) < 0) return;
            const t = this._dpTally(msg, poll);
            if (t.closed) {
                this.displaySystemMessage(this._dpx(P().STRINGS.closedNotice));
                return;
            }
            if (t.choices[this.pubkey] === idx) return;
            const store = this._dpStore();
            const ts = P().nextVoteTs(store[pollId], this.pubkey, nowSec());
            const rumor = this._dpControlRumor(msg, P().voteTags(pollId, idx), P().voteContent(poll.options[idx]), ts);
            if (!rumor) return;
            window.nymHapticTap && window.nymHapticTap();
            store[pollId] = P().applyVote(store[pollId], this.pubkey, idx, ts).entry;
            this._dpSave();
            this._dpRefresh(pollId);
            await this._dpSend(msg, rumor);
        },

        async dmPollClose(pollId) {
            const loc = this._dpLocate(pollId);
            if (!loc || loc.msg.pubkey !== this.pubkey) return;
            const { msg, poll } = loc;
            if (this._dpTally(msg, poll).closed) return;
            const store = this._dpStore();
            const ts = P().nextVoteTs(store[pollId], this.pubkey, nowSec());
            const rumor = this._dpControlRumor(msg, P().closeTags(pollId), P().closeContent(poll.question), ts);
            if (!rumor) return;
            store[pollId] = P().applyClose(store[pollId], this.pubkey, ts).entry;
            this._dpSave();
            this._dpRefresh(pollId);
            await this._dpSend(msg, rumor);
        },

        _dpHandleControl(rumor, senderPubkey, groupId, senderVerified) {
            const c = P().parseControl(rumor, nowSec());
            if (!c) return false;
            if (!c.valid || senderVerified !== true || !senderPubkey) return true;
            if (groupId && typeof this._isGroupRosterMember === 'function' && !this._isGroupRosterMember(groupId, senderPubkey)) return true;
            const store = this._dpStore();
            const r = c.type === 'vote'
                ? P().applyVote(store[c.pollId], senderPubkey, c.option, c.ts)
                : P().applyClose(store[c.pollId], senderPubkey, c.ts);
            if (!r.changed) return true;
            store[c.pollId] = r.entry;
            this._dpSave();
            this._dpRefresh(c.pollId);
            return true;
        },

        _dpRefresh(pollId) {
            const els = document.querySelectorAll(`.poll-container[data-dm-poll="${pollId}"]`);
            const loc = this._dpLocate(pollId);
            if (!loc) return;
            if (!els.length) {
                if (this.channelDOMCache && typeof this.channelDOMCache.delete === 'function') this.channelDOMCache.delete(loc.key);
                return;
            }
            const html = this._dpCardHtml(loc.msg);
            if (!html) return;
            els.forEach((el) => {
                const parent = el.parentNode;
                el.outerHTML = html;
                if (parent) this._dpPaintBars(parent);
            });
            if (typeof this.ensureListProfiles === 'function') {
                const fresh = document.querySelector(`.poll-container[data-dm-poll="${pollId}"]`);
                if (fresh) this.ensureListProfiles(fresh, Object.keys(this._dpTally(loc.msg, loc.poll).choices));
            }
        },

        _dpPaintBars(root) {
            if (!root || typeof root.querySelectorAll !== 'function') return;
            root.querySelectorAll('.dm-poll .poll-option-bar[data-pct]').forEach((b) => { b.style.width = b.dataset.pct + '%'; });
        },

        _dpCardHtml(message) {
            if (!message || !(message.isPM || message.isGroup) || !message.nymMessageId) return null;
            const poll = P().parsePoll(message.content);
            if (!poll) return null;
            const esc = (s) => this.escapeHtml(String(s));
            const pollId = message.nymMessageId;
            const t = this._dpTally(message, poll);
            const mine = Object.prototype.hasOwnProperty.call(t.choices, this.pubkey) ? t.choices[this.pubkey] : -1;
            const canVote = !t.closed && this._dpAllowed(message).indexOf(this.pubkey) >= 0;
            const options = poll.options.map((text, i) => {
                const voters = t.order.filter((pk) => t.choices[pk] === i);
                const pct = P().percent(t.counts[i], t.total);
                const avatars = voters.slice(0, MAX_AVATARS).map((pk) => {
                    const sk = this._safePubkey(pk);
                    return `<img src="${esc(this.getAvatarUrl(pk))}" class="poll-voter-avatar" data-avatar-pubkey="${sk}" title="${esc(this.getNymFromPubkey(pk))}" alt="" decoding="async" loading="lazy">`;
                }).join('');
                const extra = voters.length > MAX_AVATARS ? `<span class="poll-voter-extra">+${voters.length - MAX_AVATARS}</span>` : '';
                const action = canVote ? ` data-action="dmPollVote" role="button" tabindex="0"` : ' aria-disabled="true"';
                return `<div class="poll-option${mine === i ? ' poll-option-selected' : ''}" data-poll-id="${pollId}" data-option-index="${i}"${action} aria-pressed="${mine === i}">
                    <div class="poll-option-bar" data-pct="${pct}"></div>
                    <div class="poll-option-content">
                        <span class="poll-option-text">${esc(text)}</span>
                        <span class="poll-option-pct">${t.total > 0 ? pct + '%' : ''}</span>
                    </div>
                    <div class="poll-voters">${avatars}${extra}</div>
                </div>`;
            }).join('');
            const isAuthor = message.pubkey === this.pubkey;
            const closeBtn = isAuthor && !t.closed
                ? `<button class="poll-close-btn" data-action="dmPollClose" data-poll-id="${pollId}">${esc(this._dpx(P().STRINGS.closePoll))}</button>`
                : '';
            const closedTag = t.closed ? `<span class="poll-closed-tag">${esc(this._dpx(P().STRINGS.closed))}</span>` : '';
            const votes = t.total === 1 ? this._dpx(P().STRINGS.oneVote) : this._dpx(P().STRINGS.manyVotes, { n: t.total });
            return `<div class="poll-container dm-poll${t.closed ? ' poll-closed' : ''}" data-dm-poll="${pollId}" data-poll-id="${pollId}">
                <div class="poll-header">📊 ${esc(this._dpx(P().STRINGS.header))}${closedTag}</div>
                <div class="poll-question">${esc(poll.question)}</div>
                <div class="poll-options">${options}</div>
                <div class="poll-footer-row"><span class="poll-footer" data-action="dmPollVoters" data-poll-id="${pollId}">${esc(votes)}</span>${closeBtn}</div>
            </div>`;
        },

        dmPollVoters(pollId, anchorEl, ev) {
            const loc = this._dpLocate(pollId);
            if (!loc || typeof this.showPollVotersModal !== 'function') return;
            const t = this._dpTally(loc.msg, loc.poll);
            const votes = new Map(t.order.map((pk) => [pk, t.choices[pk]]));
            const options = loc.poll.options.map((text, index) => ({ index, text }));
            this.showPollVotersModal(pollId, anchorEl, ev, { votes, options });
        },

        _dpPreview(text) {
            const poll = P().parsePoll(text);
            return poll ? '📊 ' + this._dpx(P().STRINGS.header) + ': ' + poll.question : text;
        },
    });

    const origCard = NYM.prototype._gtCardHtml;
    NYM.prototype._gtCardHtml = function (message) {
        try {
            const held = message && message.slowHeld && !message._heldShown;
            const html = held ? null : this._dpCardHtml(message);
            if (html) return html;
        } catch (_) { }
        return typeof origCard === 'function' ? origCard.apply(this, arguments) : null;
    };

    const origLinkPreviews = NYM.prototype._attachLinkPreviews;
    NYM.prototype._attachLinkPreviews = function (el) {
        const r = typeof origLinkPreviews === 'function' ? origLinkPreviews.apply(this, arguments) : undefined;
        try {
            this._dpPaintBars(el);
            const box = el && el.querySelector && el.querySelector('.dm-poll');
            if (box && typeof this.ensureListProfiles === 'function') {
                const pks = Array.from(box.querySelectorAll('img.poll-voter-avatar')).map((i) => i.dataset.avatarPubkey).filter(Boolean);
                if (pks.length) this.ensureListProfiles(box, pks);
            }
        } catch (_) { }
        return r;
    };

    const origEdit = NYM.prototype.startEditMessage;
    NYM.prototype.startEditMessage = function (data) {
        try {
            if (data && data.messageId && this._dpLocate(data.messageId)) return;
        } catch (_) { }
        return typeof origEdit === 'function' ? origEdit.apply(this, arguments) : undefined;
    };

    const A = window.NYM_ACTIONS || (window.NYM_ACTIONS = {});
    const nym = () => window.nym;
    Object.assign(A, {
        dmPollVote: function (e, t) {
            if (e && e.stopPropagation) e.stopPropagation();
            if (nym()) nym().dmPollVote(t.dataset.pollId, parseInt(t.dataset.optionIndex, 10));
        },
        dmPollClose: function (e, t) {
            if (e && e.stopPropagation) e.stopPropagation();
            if (nym()) nym().dmPollClose(t.dataset.pollId);
        },
        dmPollVoters: function (e, t) {
            if (nym()) nym().dmPollVoters(t.dataset.pollId, t, e);
        },
    });
})();
