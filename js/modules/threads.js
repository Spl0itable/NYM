// threads.js - Slack-style message threads.

Object.assign(NYM.prototype, {

    THREAD_ICON_SVG: '<svg viewBox="0 0 20 20"><path fill="currentColor" fill-rule="evenodd" d="M10 3a7 7 0 1 0 3.394 13.124.75.75 0 0 1 .542-.074l2.794.68-.68-2.794a.75.75 0 0 1 .073-.542A7 7 0 0 0 10 3m-8.5 7a8.5 8.5 0 1 1 16.075 3.859l.904 3.714a.75.75 0 0 1-.906.906l-3.714-.904A8.5 8.5 0 0 1 1.5 10M6 8.25a.75.75 0 0 1 .75-.75h6.5a.75.75 0 0 1 0 1.5h-6.5A.75.75 0 0 1 6 8.25M6.75 11a.75.75 0 0 0 0 1.5h4.5a.75.75 0 0 0 0-1.5z" clip-rule="evenodd"></path></svg>',

    threadsEnabled() {
        return !this.settings || this.settings.threadsEnabled !== false;
    },

    // The shared cross-recipient id for PMs/groups, the event id for channel messages.
    threadKeyForMessage(msg) {
        if (!msg) return null;
        return (msg.isPM && msg.nymMessageId) ? msg.nymMessageId : msg.id;
    },

    // Needs an id every client can reference (not an optimistic temp id) and must not be a reply.
    _threadEligibleRoot(msg) {
        if (!msg || msg.threadRoot) return false;
        const key = this.threadKeyForMessage(msg);
        if (!key) return false;
        if (msg.isPM) return !!msg.nymMessageId;
        return /^[0-9a-f]{64}$/i.test(key);
    },

    // NIP-10 marked tags.
    threadRootFromChannelTags(tags) {
        if (!Array.isArray(tags)) return null;
        let root = null;
        let reply = null;
        for (const t of tags) {
            if (!Array.isArray(t) || t[0] !== 'e' || !t[1]) continue;
            if (t[3] === 'root' && !root) root = t[1];
            else if (t[3] === 'reply' && !reply) reply = t[1];
        }
        const id = root || reply;
        return (id && /^[0-9a-f]{64}$/i.test(id)) ? id : null;
    },

    threadRootFromRumorTags(tags) {
        if (!Array.isArray(tags)) return null;
        const t = tags.find(t => Array.isArray(t) && t[0] === 'nymthread' && t[1]);
        return t ? String(t[1]) : null;
    },

    _threadListForMessage(msg) {
        if (!msg) return null;
        if (msg.isPM) {
            const key = msg.conversationKey ||
                (msg.isGroup && msg.groupId ? this.getGroupConversationKey(msg.groupId)
                    : (msg.conversationPubkey ? this.getPMConversationKey(msg.conversationPubkey) : null));
            return key ? (this.pmMessages.get(key) || null) : null;
        }
        const key = msg._storageKey || (msg.geohash ? `#${msg.geohash}` : msg.channel);
        return key ? (this.messages.get(key) || null) : null;
    },

    _botThreadForeign(msg, list) {
        if (!msg || !msg.isPM || msg.isGroup || !msg.threadRoot) return false;
        if (typeof this.isVerifiedBot !== 'function' || !this.isVerifiedBot(msg.conversationPubkey)) return false;
        const held = list || this._threadListForMessage(msg);
        if (!held) return true;
        const rootId = msg.threadRoot;
        const idx = typeof this._msgIndexOf === 'function' ? this._msgIndexOf(held) : null;
        if (!idx || idx.clash) return !held.some(m => m && m !== msg && this.threadKeyForMessage(m) === rootId);
        const m = idx.map.get(rootId);
        return !(m && m !== msg && this.threadKeyForMessage(m) === rootId);
    },

    _holdBotThreadOrphan(msg) {
        if (!this._botThreadOrphans) this._botThreadOrphans = new Map();
        const key = msg.threadRoot;
        let held = this._botThreadOrphans.get(key);
        if (!held) {
            held = [];
            this._botThreadOrphans.set(key, held);
        }
        if (!held.some(m => m.id === msg.id)) held.push(msg);
        if (held.length > 50) held.splice(0, held.length - 50);
        if (this._botThreadOrphans.size > 500) {
            this._botThreadOrphans.delete(this._botThreadOrphans.keys().next().value);
        }
    },

    _adoptBotThreadOrphans(root, conversationKey) {
        if (!root || root.threadRoot || !this._botThreadOrphans) return 0;
        const key = this.threadKeyForMessage(root);
        const held = key && this._botThreadOrphans.get(key);
        if (!held || !held.length) return 0;
        this._botThreadOrphans.delete(key);
        const list = this.pmMessages.get(conversationKey) || [];
        let added = 0;
        for (const m of held) {
            if (m.conversationKey !== conversationKey) continue;
            if (list.some(x => x.id === m.id)) continue;
            list.push(m);
            added++;
        }
        if (!added) return 0;
        list.sort((a, b) => this._compareMessages(a, b));
        this.pmMessages.set(conversationKey, list);
        if (typeof this.persistPMMessages === 'function') this.persistPMMessages(conversationKey);
        if (this.channelDOMCache) this.channelDOMCache.delete(conversationKey);
        return added;
    },

    _pruneForeignBotThreads(conversationKey) {
        const list = this.pmMessages.get(conversationKey);
        if (!Array.isArray(list) || !list.length) return 0;
        const kept = [];
        let dropped = 0;
        for (const m of list) {
            if (this._botThreadForeign(m, list)) { dropped++; continue; }
            kept.push(m);
        }
        if (!dropped) return 0;
        this.pmMessages.set(conversationKey, kept);
        if (typeof this.persistPMMessages === 'function') this.persistPMMessages(conversationKey);
        return dropped;
    },

    // A reply whose root we never saw renders inline so it is never lost.
    _threadRootExistsFor(msg) {
        if (!msg || !msg.threadRoot) return false;
        const list = this._threadListForMessage(msg);
        if (!list) return false;
        const rootId = msg.threadRoot;
        return list.some(m => m !== msg && this.threadKeyForMessage(m) === rootId);
    },

    // Hidden replies never reach the screen, so notification gates must not treat them as seen.
    _threadReplyHidden(message) {
        if (!message || !message.threadRoot) return false;
        if (typeof this.threadsEnabled !== 'function' || !this.threadsEnabled()) return false;
        if (!this._threadRootExistsFor(message)) return false;
        const V = typeof self !== 'undefined' ? self.NymNotifyView : null;
        const key = this._threadConvKeyForMessage(message);
        if (V && typeof this._notifView === 'function' && key) {
            return !V.threadOpen(this._notifView(), { key, root: message.threadRoot });
        }
        const at = this.activeThread;
        return !(at && at.rootId === message.threadRoot);
    },

    _notifSeesMessage(message, key) {
        const V = typeof self !== 'undefined' ? self.NymNotifyView : null;
        if (!V || typeof this._notifView !== 'function' || !key) return false;
        const root = (message && message.threadRoot && this.threadsEnabled() && this._threadRootExistsFor(message))
            ? message.threadRoot : '';
        return V.sees(this._notifView(), { key, root });
    },

        _threadConvKeyForMessage(msg) {
        if (!msg) return '';
        if (msg.isPM) {
            return msg.conversationKey ||
                (msg.isGroup && msg.groupId ? this.getGroupConversationKey(msg.groupId)
                    : (msg.conversationPubkey ? this.getPMConversationKey(msg.conversationPubkey) : '')) || '';
        }
        return msg._storageKey || (msg.geohash ? `#${msg.geohash}` : (msg.channel || ''));
    },

    _threadReplyJoinedByMe(message) {
        if (!message || !message.threadRoot) return false;
        const list = this._threadListForMessage(message);
        if (!list) return false;
        return list.some(m => m && m !== message && m.threadRoot === message.threadRoot &&
            m.id !== message.id && (!!m.isOwn || (!!this.pubkey && m.pubkey === this.pubkey)));
    },

    _threadReplyForMe(message) {
        return this._threadReplyRootIsMine(message) || this._threadReplyJoinedByMe(message);
    },

    // Replies in a thread the user started notify like a mention.
    _threadReplyRootIsMine(message) {
        if (!message || !message.threadRoot) return false;
        const list = this._threadListForMessage(message);
        if (!list) return false;
        const root = list.find(m =>
            m !== message && this.threadKeyForMessage(m) === message.threadRoot);
        if (!root) return false;
        return !!root.isOwn || (!!this.pubkey && root.pubkey === this.pubkey);
    },

    // Thread-scoped twin of `groupNotifyMentionsOnly`, for channel, PM or group threads.
    _threadReplySuppressed(message) {
        if (!message || !message.threadRoot) return false;
        if (typeof this.threadsEnabled !== 'function' || !this.threadsEnabled()) return false;
        if (!this.threadNotifyMentionsOnly) return false;
        return !this.isMentioned(message.content);
    },

    // Only the thread-ownership half needs lifting; an @mention already passes every gate.
    _threadReplyElevated(message) {
        if (!message || !message.threadRoot) return false;
        if (typeof this.threadsEnabled !== 'function' || !this.threadsEnabled()) return false;
        const V = typeof self !== 'undefined' ? self.NymNotifyView : null;
        const input = {
            kind: 'channel', thread: true, mention: false,
            ownRoot: this._threadReplyRootIsMine(message),
            ownReply: this._threadReplyJoinedByMe(message),
            threadMentionsOnly: !!this.threadNotifyMentionsOnly
        };
        if (V) return V.addressed(input);
        if (this.threadNotifyMentionsOnly) return false;
        return input.ownRoot || input.ownReply;
    },

    // Keyed on the list's identity and length so push/splice and reassignments invalidate it.
    _threadReplyCountFor(msg) {
        const list = this._threadListForMessage(msg);
        if (!list || !list.length) return 0;
        const c = this._threadCountCache;
        const ver = (this._cfVersion || 0) + ':' + (this._cfEditEpoch || 0);
        if (!c || c.list !== list || c.len !== list.length || c.ver !== ver) {
            const map = new Map();
            for (const m of list) {
                if (!m || !m.threadRoot || this._threadReplyFiltered(m)) continue;
                map.set(m.threadRoot, (map.get(m.threadRoot) || 0) + 1);
            }
            this._threadCountCache = { list, len: list.length, ver, map };
        }
        const key = this.threadKeyForMessage(msg);
        return key ? (this._threadCountCache.map.get(key) || 0) : 0;
    },

    _threadReplyFiltered(m) {
        if (!m) return true;
        if (typeof this.isContentHidden === 'function') return this.isContentHidden(m);
        return this.deletedEventIds.has(m.id) ||
            !!(m.nymMessageId && this.deletedEventIds.has(m.nymMessageId)) ||
            (typeof this._isMessageDeleted === 'function' && this._isMessageDeleted(m)) ||
            (m.pubkey !== this.pubkey && (this.blockedUsers.has(m.pubkey) || !!m.blocked));
    },

    _threadRepliesFor(rootMsg) {
        const list = this._threadListForMessage(rootMsg) || [];
        const rootId = this.threadKeyForMessage(rootMsg);
        return list
            .filter(m => m && m.threadRoot === rootId && !this._threadReplyFiltered(m))
            .sort((a, b) => this._compareMessages(a, b));
    },

    _refreshAllThreadIndicators() {
        this._threadCountCache = null;
        if (typeof document === 'undefined' || typeof this._refreshThreadIndicators !== 'function') return;
        const roots = new Set();
        document.querySelectorAll('.message[data-message-id] > .thread-indicator-row').forEach((row) => {
            const id = row.parentElement.dataset.messageId;
            if (id) roots.add(id);
        });
        for (const id of roots) {
            const sample = typeof this._findStoredMessage === 'function' ? this._findStoredMessage(id) : null;
            if (!sample) continue;
            try { this._refreshThreadIndicators(id, sample); } catch (_) { }
        }
    },

    // `nym#abcd`, the quote-reply shape, so /api/bot can tell the bot's turns from humans'.
    _threadMessageAuthor(msg) {
        const nym = this.resolveDisplayNym(msg && msg.pubkey, (msg && msg.author) || '');
        const suffix = (msg && msg.pubkey && typeof this.getPubkeySuffix === 'function')
            ? this.getPubkeySuffix(msg.pubkey) : '';
        return suffix ? `${nym}#${suffix}` : nym;
    },

    _threadChannelChain(rootId, storageKey) {
        if (!rootId || !storageKey || !this.threadsEnabled()) return [];
        const list = this.messages.get(storageKey) || [];
        const root = list.find(m => m && m.id === rootId);
        if (!root) return [];
        const head = this._threadReplyFiltered(root) ? [] : [root];
        return [...head, ...this._threadRepliesFor(root)];
    },

    // Null unless the thread is rooted on a Nymbot message; call before publishing the outgoing message.
    _threadBotQuoteContext(rootId, storageKey) {
        const chain = this._threadChannelChain(rootId, storageKey)
            .filter(m => String(m.content || '').trim());
        if (!chain.length) return null;
        if (chain[0].id !== rootId || !chain[0].isBot) return null;
        const botMsgs = chain.filter(m => m.isBot);
        if (!botMsgs.length) return null;
        // An unfinished game lives in the newest [gc:] token; quoting without it would drop the game.
        let target = null;
        for (let i = botMsgs.length - 1; i >= 0; i--) {
            if (/\[gc:[A-Za-z0-9+/=]+\]/.test(botMsgs[i].content || '')) { target = botMsgs[i]; break; }
        }
        if (!target) target = botMsgs[botMsgs.length - 1];
        const text = String(target.content || '');
        return { author: this._threadMessageAuthor(target), text, fullText: text };
    },

    // Strip the wire envelope, or the model mimics the format instead of answering.
    _threadEntryText(msg) {
        let text = String((msg && msg.content) || '')
            .split('\n').filter(l => !l.startsWith('>')).join('\n');
        if (msg && msg.isBot) text = this._stripBotEnvelope(text);
        return text.replace(/\n{3,}/g, '\n\n').trim();
    },

    // The `[gc:]` token stays; ?guess reads the live game out of it.
    _stripBotEnvelope(text) {
        return window.NymNickParse.stripEnvelope(String(text || ''));
    },

    // Same {author, text} shape as _extractQuoteChain; `exclude` drops the just-published message.
    _threadBotConversation(rootId, storageKey, opts = {}) {
        const limit = opts.limit || 20;
        const exclude = opts.exclude ? this._threadEntryText({ content: opts.exclude }) : '';
        const skip = typeof opts.skip === 'function' ? opts.skip : null;
        const entries = this._threadChannelChain(rootId, storageKey)
            .filter(m => !m._spamGated && !(skip && skip(m)))
            .map(m => ({ author: this._threadMessageAuthor(m), text: this._threadEntryText(m).slice(0, 1000) }))
            .filter(e => e.text);
        if (exclude && entries.length && entries[entries.length - 1].text === exclude) {
            entries.pop();
        }
        return entries.slice(-limit);
    },

    _threadFindMessage(ctx, id) {
        const list = ctx.isPM ? (this.pmMessages.get(ctx.storageKey) || [])
            : (this.messages.get(ctx.storageKey) || []);
        return list.find(m => this.threadKeyForMessage(m) === id) || null;
    },

    _threadCtxForElement(el) {
        const colEl = el && el.closest && el.closest('.cv-column');
        if (colEl && this._cvActive) {
            const col = (this._cvColumns || []).find(c => c.id === colEl.dataset.colId);
            if (col) {
                if (col.type === 'channel') return { type: 'channel', channel: col.channel, geohash: col.geohash || '', storageKey: col.key, isPM: false };
                if (col.type === 'pm') return { type: 'pm', pubkey: col.pubkey, nym: col.nym, storageKey: col.key, isPM: true };
                if (col.type === 'group') return { type: 'group', groupId: col.groupId, storageKey: col.key, isPM: true };
            }
        }
        if (el && el.closest && el.closest('.thread-view-active') && this.activeThread) {
            return this.activeThread.ctx;
        }
        if (this.inPMMode && this.currentGroup) {
            return { type: 'group', groupId: this.currentGroup, storageKey: this.getGroupConversationKey(this.currentGroup), isPM: true };
        }
        if (this.inPMMode && this.currentPM) {
            return { type: 'pm', pubkey: this.currentPM, nym: this.getNymFromPubkey(this.currentPM), storageKey: this.getPMConversationKey(this.currentPM), isPM: true };
        }
        const storageKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
        if (!storageKey) return null;
        return { type: 'channel', channel: this.currentChannel, geohash: this.currentGeohash || '', storageKey, isPM: false };
    },

    _threadCtxHtml(ctx) {
        if (!ctx) return '';
        if (ctx.type === 'channel') return this.escapeHtml(`#${ctx.geohash || ctx.channel || ''}`);
        if (ctx.type === 'group') {
            const g = this.groupConversations && this.groupConversations.get(ctx.groupId);
            return this.escapeHtml(g ? (typeof this._groupLabel === 'function' ? this._groupLabel(g) : (g.name || 'Group')) : 'Group chat');
        }
        if (ctx.type === 'pm') {
            return '@' + this.formatNymWithPubkey(this.resolveDisplayNym(ctx.pubkey, ctx.nym || ''), ctx.pubkey);
        }
        return '';
    },

    openMessageThread(target, opts = {}) {
        if (!this.threadsEnabled()) return;
        const msgEl = target && target.closest ? target.closest('[data-message-id]') : null;
        if (!msgEl) return;
        const ctx = this._threadCtxForElement(msgEl);
        if (!ctx) return;
        const id = msgEl.dataset.messageId;
        let msg = this._threadFindMessage(ctx, id);
        if (!msg) return;
        if (msg.threadRoot) {
            const root = this._threadFindMessage(ctx, msg.threadRoot);
            if (root) {
                msg = root;
            } else {
                // Root aged out of the local store: open by the reply's root reference instead of dead-ending.
                this.openThreadView(msg.threadRoot, ctx);
                return;
            }
        }
        if (!this._threadEligibleRoot(msg)) {
            // A stray body click on an unsendable/system row stays quiet.
            if (!opts.silent) {
                this.displaySystemMessage('This message cannot start a thread yet — try again once it has finished sending.');
            }
            return;
        }
        this.openThreadView(this.threadKeyForMessage(msg), ctx);
    },

    _threadContainerFor(ctx) {
        if (this._cvActive) {
            const col = this._cvColumnForKey(ctx.storageKey);
            if (!col || !col.listEl) return null;
            if (this._cvFocusedId !== col.id) this._cvFocusColumn(col.id);
            return col.listEl;
        }
        return document.getElementById('messagesContainer');
    },

    openThreadView(rootId, ctx, opts = {}) {
        if (!this.threadsEnabled() || !rootId || !ctx) return;
        const container = this._threadContainerFor(ctx);
        if (!container) return;

        this.activeThread = { rootId, ctx };
        this._threadContainer = container;
        this._renderThreadView(container);
        this._setThreadComposerHint();
        this._threadMarkOpenSeen();
        this._typingThrottleTime = 0;
        if (typeof this.renderTypingIndicator === 'function') this.renderTypingIndicator();

        if (opts.push !== false) {
            this._pushNavigation({
                type: 'thread',
                rootId,
                ctx: {
                    type: ctx.type,
                    channel: ctx.channel,
                    geohash: ctx.geohash,
                    pubkey: ctx.pubkey,
                    nym: ctx.nym,
                    groupId: ctx.groupId,
                    storageKey: ctx.storageKey,
                    isPM: !!ctx.isPM
                }
            });
        }
    },

    _renderThreadView(container) {
        const at = this.activeThread;
        if (!at || !container) return;
        this._threadHoldRows(container, at.ctx);
        container.innerHTML = '';
        // Invalidate the single-view DOM cache so leaving the thread re-renders the conversation.
        container.dataset.lastChannel = '';
        container.classList.add('thread-view-active');

        const bar = document.createElement('div');
        bar.className = 'thread-view-bar';
        bar.innerHTML = `
    <button class="thread-view-back" data-action="closeThreadView" title="Back to conversation" aria-label="Back to conversation">
        <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="15 18 9 12 15 6"></polyline></svg>
    </button>
    <span class="thread-view-icon">${this.THREAD_ICON_SVG}</span>
    <span class="thread-view-title">Thread</span>
    <span class="thread-view-context">${this._threadCtxHtml(at.ctx)}</span>`;
        container.appendChild(bar);

        const root = this._threadFindMessage(at.ctx, at.rootId);
        if (root) {
            this._renderThreadMessage(root, container);
        } else {
            const note = document.createElement('div');
            note.className = 'msg-empty-note';
            note.textContent = 'Original message unavailable';
            container.appendChild(note);
        }

        const divider = document.createElement('div');
        divider.className = 'thread-replies-divider';
        divider.innerHTML = `<span class="thread-divider-icon">${this.THREAD_ICON_SVG}</span><span class="thread-divider-text"></span>`;
        container.appendChild(divider);

        const replies = root ? this._threadRepliesFor(root) : [];
        this._suppressSound = true;
        this._suppressBubbleRewrap = true;
        for (const reply of replies) this._renderThreadMessage(reply, container);
        this._suppressSound = false;
        this._suppressBubbleRewrap = false;
        if (typeof this._recomputeAllBubbleGrouping === 'function') {
            this._recomputeAllBubbleGrouping(container);
        }

        this._updateThreadDivider(replies.length);
        this._scheduleScrollToBottom(true);

        if (typeof this._backfillZapReceiptsForMessages === 'function') {
            this._backfillZapReceiptsForMessages(root ? [root, ...replies] : replies);
        }
    },

    // Shallow clone so the store object never carries the thread flag.
    _renderThreadMessage(msg, container) {
        const clone = Object.assign({}, msg);
        clone._threadRender = true;
        const prev = this._threadRenderTarget;
        this._threadRenderTarget = container;
        try {
            this.displayMessage(clone);
        } finally {
            this._threadRenderTarget = prev;
        }
    },

    _updateThreadDivider(count, where, open) {
        const container = where || this._threadContainer;
        const text = container && container.querySelector('.thread-replies-divider .thread-divider-text');
        if (!text) return;
        if (typeof count !== 'number') {
            const at = open || this.activeThread;
            const root = at ? this._threadFindMessage(at.ctx, at.rootId) : null;
            count = root ? this._threadRepliesFor(root).length : 0;
        }
        text.textContent = count === 0 ? 'No replies yet'
            : (count === 1 ? '1 reply' : `${this.abbreviateNumber(count)} replies`);
    },

    _setThreadComposerHint() {
        if (typeof this._syncComposerPlaceholder === 'function') this._syncComposerPlaceholder();
    },

    // Null outside a thread view or when it belongs to another conversation (never mis-thread a send).
    _threadRootForSend() {
        const at = this.activeThread;
        if (!at || !this.threadsEnabled()) return null;
        const ctx = at.ctx;
        if (this._cvActive) {
            const col = this._cvColumns && this._cvColumns.find(c => c.id === this._cvFocusedId);
            return (col && col.key === ctx.storageKey && col.listEl === this._threadContainer) ? at.rootId : null;
        }
        if (ctx.type === 'group') return (this.inPMMode && this.currentGroup === ctx.groupId) ? at.rootId : null;
        if (ctx.type === 'pm') return (this.inPMMode && this.currentPM === ctx.pubkey) ? at.rootId : null;
        const key = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
        return (!this.inPMMode && key === ctx.storageKey) ? at.rootId : null;
    },

    // Ordinary conversation messages must not render into an occupied container.
    _threadViewOccupies(container) {
        if (this.activeThread && this._threadContainer && container === this._threadContainer) return true;
        return !!(container && this._cvThreads && this._cvThreads.size && this._cvThreads.has(container));
    },

    _threadOpenFor(key) {
        if (!key) return null;
        const at = this.activeThread;
        if (at && at.ctx && at.ctx.storageKey === key && this._threadContainer) return { at, container: this._threadContainer };
        if (this._cvThreads && this._cvThreads.size) {
            for (const [container, p] of this._cvThreads) {
                if (p.ctx && p.ctx.storageKey === key) return { at: p, container };
            }
        }
        return null;
    },

    _threadDropIn(list) {
        if (!list) return;
        if (this._cvThreads && this._cvThreads.delete(list)) list.classList.remove('thread-view-active');
        if (this.activeThread && this._threadContainer === list) this._closeThreadViewOnSwitch();
        this._threadDropHeldIn(list);
    },

    _threadDropHeldIn(list) {
        const held = this._threadHeld;
        if (held && held.container === list && !list.classList.contains('thread-view-active')) this._threadDropHeld();
        this._threadDropTail(list);
    },

    _threadDropColumns() {
        if (this._cvThreads) {
            for (const list of this._cvThreads.keys()) {
                list.classList.remove('thread-view-active');
                this._threadDropHeldIn(list);
            }
            this._cvThreads.clear();
        }
        const tc = this._threadContainer;
        if (this.activeThread && tc && tc.id !== 'messagesContainer') this._closeThreadViewOnSwitch();
    },

    _threadAnonLane(at) {
        return !!(at && at.ctx && typeof this._anonLaneMsg === 'function' && this._anonLaneMsg(at.rootId));
    },

    _threadQuietClose(pubkey, fn) {
        const prev = this._anonThreadClosing || null;
        this._anonThreadClosing = pubkey || null;
        try { return fn(); } finally { this._anonThreadClosing = prev; }
    },

    closeThreadView(opts = {}) {
        const at = this.activeThread;
        if (!at) return;
        this._threadQuietClose(this._threadAnonLane(at) ? at.ctx.pubkey : null, () => this._closeThreadViewNow(at, opts));
    },

    _threadHeldSig() {
        const size = (v) => (v && typeof v.size === 'number' ? v.size : 0);
        return [this._cfVersion || 0, this._cfEditEpoch || 0, this._cnFilterEpoch || 0, size(this.deletedEventIds),
            size(this.blockedUsers), size(this.blockedKeywords), size(this.friends), size(this.autoMutedPubkeys),
            typeof this._clientGatesActive === 'function' && this._clientGatesActive() ? 1 : 0,
            this.spamFilterEnabled === false ? 0 : 1, this.spamFilterAggressive === false ? 0 : 1,
            typeof document !== 'undefined' && document.body && document.body.classList.contains('chat-bubbles') ? 1 : 0].join('|');
    },

    _threadHoldRows(container, ctx) {
        const held = this._threadHeld;
        if (held && held.container === container && container.classList.contains('thread-view-active')) return;
        this._threadDropHeld();
        this._threadAttachTail(this._threadTail, true);
        const sc = container.parentElement;
        if (!ctx || !sc || !container.firstChild || container.classList.contains('thread-view-active')) return;
        const key = ctx.storageKey;
        if (!key || container.dataset.virtualScrollKey !== key) return;
        const isPM = container.dataset.virtualScrollIsPM === 'true';
        if (!isPM !== !ctx.isPM) return;
        const col = this._cvActive && typeof this._cvColumnForKey === 'function' ? this._cvColumnForKey(key) : null;
        const hold = document.createElement('div');
        hold.className = 'thread-held-rows';
        hold.hidden = true;
        hold.style.display = 'none';
        const away = Math.abs(sc.scrollTop) >= 2;
        this._threadHeld = {
            container, hold, key, isPM, col,
            lastChannel: container.dataset.lastChannel,
            scrollTop: sc.scrollTop,
            readerAway: !!sc._readerAway,
            scrolledUp: !!this.userScrolledUp,
            atBottom: col ? col._atBottom : undefined,
            place: away && typeof this._readerPlace === 'function' ? this._readerPlace(container, sc) : null,
            windowEnd: !isPM && this.channelWindowEnd ? this.channelWindowEnd.get(key) : undefined,
            rawLast: this._threadRawLast(key, isPM),
            sig: this._threadHeldSig()
        };
        const frag = document.createDocumentFragment();
        while (container.firstChild) frag.appendChild(container.firstChild);
        hold.appendChild(frag);
        sc.insertBefore(hold, container.nextSibling);
    },

    _threadRawLast(key, isPM) {
        const raw = (isPM ? this.pmMessages : this.messages);
        const list = raw && typeof raw.get === 'function' ? raw.get(key) : null;
        const m = Array.isArray(list) && list.length ? list[list.length - 1] : null;
        return m ? m.id : null;
    },

    _threadOwnSince(held) {
        const list = (held.isPM ? this.pmMessages : this.messages).get(held.key) || [];
        let i = list.length - 1;
        for (; i >= 0; i--) {
            const m = list[i];
            if (m && m.id === held.rawLast) break;
            if (m && !m.threadRoot && (m.isOwn || (this.pubkey && m.pubkey === this.pubkey))) return true;
        }
        return false;
    },

    _threadDropTail(container) {
        const tail = this._threadTail;
        if (!tail || (container && tail.container !== container)) return;
        this._threadTail = null;
        if (tail.hold.parentNode) tail.hold.parentNode.removeChild(tail.hold);
    },

    _threadDropHeld() {
        const held = this._threadHeld;
        this._threadHeld = null;
        if (held && held.hold.parentNode) held.hold.parentNode.removeChild(held.hold);
        return held;
    },

    _threadRowIds(root) {
        const ids = [];
        for (const el of root.querySelectorAll('[data-message-id]')) {
            if (el.classList.contains('poll-message')) continue;
            if (el.parentElement && el.parentElement.closest('[data-message-id]')) continue;
            ids.push(el.dataset.messageId);
        }
        return ids;
    },

    _threadHeldFit(held) {
        const list = held.isPM ? this.getFilteredPMMessages(held.key) : this.getFilteredMessages(held.key);
        const ids = this._threadRowIds(held.hold);
        if (!ids.length || !Array.isArray(list)) return null;
        const rowId = (m) => (m && m.isPM && m.nymMessageId) ? m.nymMessageId : (m && m.id);
        let last = -1;
        for (let i = list.length - 1; i >= 0; i--) {
            if (rowId(list[i]) === ids[ids.length - 1]) { last = i; break; }
        }
        const start = last - ids.length + 1;
        if (last < 0 || start < 0) return null;
        for (let i = 0; i < ids.length; i++) {
            if (rowId(list[start + i]) !== ids[i]) return null;
        }
        const end = !held.isPM && this.channelWindowEnd ? this.channelWindowEnd.get(held.key) : undefined;
        if (end !== held.windowEnd || (end !== undefined && this._threadOwnSince(held))) return null;
        return { list, start, last, trailing: end === undefined ? list.slice(last + 1) : [] };
    },

    _threadHeldCut(held, kids) {
        if (this._cvActive || held.container.id !== 'messagesContainer' || typeof document === 'undefined' || document.hidden) return 0;
        if (typeof this._frameOrTimer !== 'function') return 0;
        const sel = '.message[data-message-id], .me-message[data-message-id], .group-notice[data-message-id]';
        const rowsIn = (k) => (k.nodeType !== 1 ? 0 : (k.matches(sel) ? 1 : 0) + k.querySelectorAll(sel).length);
        let cut = 0;
        if (held.place) {
            const id = held.place.id;
            const at = kids.findIndex((k) => k.nodeType === 1 && (k.dataset.messageId === id || !!k.querySelector('[data-message-id="' + (window.CSS && CSS.escape ? CSS.escape(id) : id) + '"]')));
            if (at < 0) return 0;
            cut = Math.max(0, at - 2);
        } else if (Math.abs(held.scrollTop) < 2) {
            const want = this._threadViewRows(held.isPM);
            let rows = 0;
            cut = kids.length;
            while (cut > 0 && rows < want) rows += rowsIn(kids[--cut]);
            if (rows < want) return 0;
        } else {
            return 0;
        }
        while (cut > 0 && kids[cut - 1].nodeType === 1 && kids[cut - 1].matches('.cn-divider, .day-separator')) cut--;
        let first = cut;
        while (first < kids.length && !rowsIn(kids[first])) first++;
        return first < kids.length && cut > 0 && kids.slice(0, cut).some((k) => rowsIn(k) > 0) ? cut : 0;
    },

    _threadViewRows(isPM) {
        const h = (typeof window !== 'undefined' && window.innerHeight) || 800;
        return Math.min((isPM ? this.pmPageSize : this.channelPageSize) || 50, Math.max(12, Math.ceil(h / 32)));
    },

    _threadHeldBusy(held, fit) {
        if (fit.trailing.length <= this._threadViewRows(held.isPM)) return '';
        if (held.col || (!held.place && Math.abs(held.scrollTop) < 2)) return 'render';
        if (held.isPM || held.container.id !== 'messagesContainer') return '';
        return this._threadOwnSince(held) ? 'render' : 'detach';
    },

    _threadRowIndexOf(list, id) {
        for (let i = list.length - 1; i >= 0; i--) {
            const m = list[i];
            if (m && (((m.isPM && m.nymMessageId) ? m.nymMessageId : m.id) === id)) return i;
        }
        return -1;
    },

    _threadRestoreHeld(container, ctx, was) {
        const held = this._threadHeld;
        this._threadHeld = null;
        if (!held) return false;
        const sc = container.parentElement;
        const fit = held.container === container && ctx && held.key === ctx.storageKey
            && container.dataset.virtualScrollKey === held.key && !!container.querySelector(':scope > .thread-view-bar')
            && held.sig === this._threadHeldSig() && !!sc && (!held.col || (this._cvActive && held.col.listEl === container))
            ? this._threadHeldFit(held) : null;
        const busy = fit ? this._threadHeldBusy(held, fit) : '';
        if (!fit || busy === 'render') {
            if (held.hold.parentNode) held.hold.parentNode.removeChild(held.hold);
            return false;
        }
        if (busy === 'detach') {
            this.channelWindowEnd.set(held.key, fit.list[fit.last].id);
            fit.trailing = [];
        }
        const kids = Array.from(held.hold.childNodes);
        const cut = this._threadHeldCut(held, kids);
        container.innerHTML = '';
        const frag = document.createDocumentFragment();
        for (let i = cut; i < kids.length; i++) frag.appendChild(kids[i]);
        container.appendChild(frag);
        if (held.lastChannel !== undefined) container.dataset.lastChannel = held.lastChannel;
        const starts = held.isPM ? this.pmRenderedStart : this.channelRenderedStart;
        let shownFrom = fit.start;
        if (cut > 0) {
            const firstId = this._threadRowIds(container)[0];
            const at = firstId ? this._threadRowIndexOf(fit.list, firstId) : -1;
            if (at >= 0) shownFrom = at;
            starts.set(held.key, shownFrom);
            this._threadTail = { container, hold: held.hold, key: held.key, isPM: held.isPM, start: fit.start, top: container.firstChild, first: container.querySelector('[data-message-id]'), regroup: fit.trailing.length > 0 };
            const tail = this._threadTail;
            this._frameOrTimer(() => this._threadAttachTail(tail, false), true);
        } else {
            starts.set(held.key, fit.start);
            if (held.hold.parentNode) held.hold.parentNode.removeChild(held.hold);
        }
        if (fit.trailing.length) {
            this.virtualScroll.suppressAutoScroll = true;
            this._suppressSound = true;
            this._suppressBubbleRewrap = true;
            this._bulkAppending = true;
            try {
                for (const m of fit.trailing) this.displayMessage(m);
            } finally {
                this._bulkAppending = false;
                this._suppressSound = false;
                this._suppressBubbleRewrap = false;
                this.virtualScroll.suppressAutoScroll = false;
            }
            this._recomputeAllBubbleGrouping(container);
        }
        if (typeof this._backfillZapReceiptsForMessages === 'function') this._backfillZapReceiptsForMessages(fit.list.slice(shownFrom, fit.last + 1 + fit.trailing.length));
        if (typeof was !== 'number' || Math.abs(was - held.scrollTop) >= 1) sc.scrollTop = held.scrollTop;
        if (held.place && fit.trailing.length && typeof this._readerRestore === 'function') this._readerRestore(container, sc, held.place);
        sc._readerAway = held.readerAway;
        if (held.col) held.col._atBottom = held.atBottom;
        this.userScrolledUp = held.scrolledUp || busy === 'detach';
        if (typeof this._cnAfterRender === 'function') this._cnAfterRender(held.key);
        return true;
    },

    _threadAttachTail(tail, now) {
        if (!tail || this._threadTail !== tail) return;
        this._threadTail = null;
        const { container, hold, key } = tail;
        let top = tail.top && tail.top.parentNode === container ? tail.top : tail.first;
        while (top && top.parentNode && top.parentNode !== container) top = top.parentNode;
        const ok = !!hold.parentNode && container.isConnected && !!top && top.parentNode === container
            && container.dataset.virtualScrollKey === key && !container.classList.contains('thread-view-active');
        if (!ok) {
            if (hold.parentNode) hold.parentNode.removeChild(hold);
            return;
        }
        let shifted = false;
        for (let k = container.firstChild; k && k !== top; k = k.nextSibling) {
            if (k.nodeType === 1 && (k.hasAttribute('data-message-id') || k.querySelector('[data-message-id]'))) { shifted = true; break; }
        }
        const first = shifted ? top : container.firstChild;
        const sc = container.parentElement;
        const anchor = !now && typeof this._chWinAnchor === 'function' ? this._chWinAnchor(container, sc) : null;
        if (anchor && typeof this._chWinHold === 'function') this._chWinHold(sc);
        const frag = document.createDocumentFragment();
        while (hold.firstChild) frag.appendChild(hold.firstChild);
        hold.parentNode.removeChild(hold);
        container.insertBefore(frag, first);
        const starts = tail.isPM ? this.pmRenderedStart : this.channelRenderedStart;
        const cur = starts.get(key);
        starts.set(key, shifted && typeof cur === 'number' ? Math.min(cur, tail.start) : tail.start);
        if (shifted || tail.regroup) this._recomputeAllBubbleGrouping(container);
        if (anchor && typeof this._chWinRestore === 'function') {
            this._chWinRestore(sc, anchor);
            requestAnimationFrame(() => this._chWinRestore(sc, anchor));
        }
    },

    _closeThreadViewNow(at, opts) {
        const container = this._threadContainer;
        const held = this._threadHeld && container && this._threadHeld.container === container ? this._threadHeld : null;
        const was = held && container.parentElement ? container.parentElement.scrollTop : undefined;
        this.activeThread = null;
        this._threadContainer = null;
        this._setThreadComposerHint();
        if (container) {
            container.classList.remove('thread-view-active');
            const place = held ? held.place : null;
            if (!this._threadRestoreHeld(container, at.ctx, was)) {
                this.renderMessagesWithVirtualScroll(container, at.ctx.storageKey, true, !!at.ctx.isPM, null, place);
            }
        } else {
            this._threadDropHeld();
        }
        this._typingThrottleTime = 0;
        if (typeof this.renderTypingIndicator === 'function') this.renderTypingIndicator();
        // Only for user-initiated closes, not navigation itself.
        if (opts.nav !== false) {
            const current = this.navigationHistory && this.navigationHistory[this.navigationIndex];
            if (current && current.type === 'thread' && this.navigationIndex > 0) {
                this.navigateBack();
            }
        }
    },

    // Returns false when the entry names no thread (or threads are off).
    openThreadFromNotification(info) {
        if (!info || !info.threadRoot || !this.threadsEnabled()) return false;
        let ctx = null;
        if (info.type === 'geohash') {
            const key = info.geohash || info.channel || '';
            if (key) {
                ctx = {
                    type: 'channel', channel: info.channel || key, geohash: info.geohash || '',
                    storageKey: `#${key}`, isPM: false
                };
            }
        } else if (info.type === 'pm' && info.pubkey) {
            ctx = {
                type: 'pm', pubkey: info.pubkey,
                nym: info.nym || this.getNymFromPubkey(info.pubkey),
                storageKey: this.getPMConversationKey(info.pubkey), isPM: true
            };
        } else if (info.type === 'group' && info.groupId) {
            ctx = {
                type: 'group', groupId: info.groupId,
                storageKey: this.getGroupConversationKey(info.groupId), isPM: true
            };
        }
        if (!ctx || !ctx.storageKey) return false;
        // Same ordering as `_navOpenThread`: the caller has already switched the conversation.
        this.openThreadView(info.threadRoot, ctx);
        return true;
    },

    _navOpenThread(entry) {
        const ctx = entry.ctx || {};
        if (!this._cvActive) {
            if (ctx.type === 'channel') {
                if (this.inPMMode || this.currentChannel !== ctx.channel || (this.currentGeohash || '') !== (ctx.geohash || '')) {
                    this.switchChannel(ctx.channel, ctx.geohash || '');
                }
            } else if (ctx.type === 'pm') {
                if (!this.inPMMode || this.currentPM !== ctx.pubkey) {
                    this.openPM(this.stripPubkeySuffix(ctx.nym || this.getNymFromPubkey(ctx.pubkey)), ctx.pubkey);
                }
            } else if (ctx.type === 'group') {
                if (!this.inPMMode || this.currentGroup !== ctx.groupId) {
                    this.openGroup(ctx.groupId);
                }
            }
            this.openThreadView(entry.rootId, ctx, { push: false });
            return;
        }
        const col = this._cvColumnForKey(ctx.storageKey);
        const open = col ? this._threadOpenFor(col.key) : null;
        if (open && open.at.rootId === entry.rootId && open.container === col.listEl) {
            if (this._cvFocusedId !== col.id) this._cvFocusColumn(col.id);
        } else {
            this.openThreadView(entry.rootId, ctx, { push: false });
        }
        if (col) this._cvScrollToCol(col);
    },

    _onThreadReplyArrived(message) {
        this._threadCountCache = null;
        this._refreshThreadIndicators(message.threadRoot, message);

        // Only a live reply in the open thread sounds here; collapsed-thread replies go through showNotification.
        if (!this._threadReplyHidden(message) &&
            !message.isHistorical && !message.isOwn && !message.isBot &&
            !(this._sendAsQuiet instanceof Set && this._sendAsQuiet.has(message.id)) &&
            this.settings && this.settings.sound &&
            (message.isPM || (typeof this.isMentioned === 'function' && this.isMentioned(message.content)))) {
            this.playSound(this.settings.sound);
        }

        const at = this.activeThread;
        if (at && at.rootId === message.threadRoot && this._threadContainer) {
            this._threadAppendReply(message, this._threadContainer, at);
        }
        if (this._cvThreads && this._cvThreads.size) {
            for (const [container, p] of this._cvThreads) {
                if (p.rootId === message.threadRoot) this._threadAppendReply(message, container, p);
            }
        }
    },

    _threadAppendReply(message, container, open) {
        const dedupeId = (message.isPM && message.nymMessageId) ? message.nymMessageId : message.id;
        if (container.querySelector(`[data-message-id="${dedupeId}"]`)) return;
        this._renderThreadMessage(message, container);
        this._updateThreadDivider(undefined, container, open);
        if (message.isOwn && container === this._threadContainer) this._scheduleScrollToBottom(true);
    },

    // Once the root is here, drop stray inline copies of its replies (never from an open thread view).
    _sweepInlineThreadReplies(rootMsg) {
        if (!rootMsg || typeof document === 'undefined') return;
        if (!this.threadsEnabled()) return;
        const rootId = this.threadKeyForMessage(rootMsg);
        if (!rootId) return;
        const list = this._threadListForMessage(rootMsg) || [];
        for (const m of list) {
            if (!m || m.threadRoot !== rootId) continue;
            for (const id of [m.id, m.nymMessageId]) {
                if (!id) continue;
                const sel = `.message[data-message-id="${String(id).replace(/"/g, '\\"')}"]`;
                document.querySelectorAll(sel).forEach(el => {
                    if (el.closest('.thread-view-active')) return;
                    el.remove();
                });
                if (this.renderedMessageIds) this.renderedMessageIds.delete(id);
            }
        }
    },

    _refreshThreadIndicators(rootId, sampleMsg) {
        if (!rootId) return;
        const list = sampleMsg ? this._threadListForMessage(sampleMsg) : null;
        const rootMsg = list ? (list.find(m => this.threadKeyForMessage(m) === rootId) || null) : null;
        const count = rootMsg ? this._threadRepliesFor(rootMsg).length : 0;
        if (rootMsg && count > 0) this._sweepInlineThreadReplies(rootMsg);
        // `.message` rows only; the hover reaction button carries the same data-message-id.
        document.querySelectorAll(`.message[data-message-id="${rootId}"]`).forEach(el => {
            if (el.closest('.thread-view-active')) return;
            let row = el.querySelector(':scope > .thread-indicator-row');
            if (count <= 0) {
                if (row) row.remove();
                return;
            }
            if (!row) {
                row = this._buildThreadIndicator(rootId);
                el.appendChild(row);
            }
            const countEl = row.querySelector('.thread-indicator-count');
            if (countEl) countEl.textContent = count === 1 ? '1 reply' : `${this.abbreviateNumber(count)} replies`;
            const btn = row.querySelector('.thread-indicator');
            const key = sampleMsg ? this._threadConvKeyForMessage(sampleMsg) : '';
            if (btn && key && typeof this._threadHasUnreadNotif === 'function') {
                this._applyThreadIndicatorNew(btn, this._threadHasUnreadNotif(key, rootId));
            }
        });
    },

    _threadMarkOpenSeen() {
        const at = this.activeThread;
        if (!at || !at.ctx || typeof this._markThreadNotificationsSeen !== 'function') return;
        if (typeof document !== 'undefined' && document.hidden) return;
        if (typeof this._anonLaneMsg === 'function' && this._anonLaneMsg(at.rootId)) return;
        if (at.ctx.type === 'pm' && this.isVerifiedBot(at.ctx.pubkey)
            && !(this.pmMessages.get(at.ctx.storageKey) || []).some((x) => x && (x.id === at.rootId || x.nymMessageId === at.rootId))) return;
        this._markThreadNotificationsSeen(at.ctx.storageKey, at.rootId);
    },

    _threadIndicatorKeyFor(el) {
        const msgEl = el && el.closest ? el.closest('.message[data-message-id]') : null;
        if (!msgEl) return null;
        const ctx = this._threadCtxForElement(msgEl);
        return ctx && ctx.storageKey ? { key: ctx.storageKey, root: msgEl.dataset.messageId } : null;
    },

    _applyThreadIndicatorNew(btn, isNew) {
        if (!btn) return;
        btn.classList.toggle('thread-indicator-new', !!isNew);
        let badge = btn.querySelector('.thread-indicator-badge');
        if (isNew && !badge) {
            badge = document.createElement('span');
            badge.className = 'thread-indicator-badge';
            badge.textContent = typeof this.uiText === 'function' ? this.uiText('New') : 'New';
            const count = btn.querySelector('.thread-indicator-count');
            if (count && count.nextSibling) btn.insertBefore(badge, count.nextSibling);
            else btn.appendChild(badge);
        } else if (!isNew && badge) {
            badge.remove();
        }
    },

    _refreshThreadNewMarks() {
        if (typeof document === 'undefined' || typeof this._threadHasUnreadNotif !== 'function') return;
        const btns = document.querySelectorAll('.message[data-message-id] > .thread-indicator-row > .thread-indicator');
        if (!btns || !btns.length) return;
        btns.forEach(btn => {
            if (btn.closest('.thread-view-active')) return;
            const where = this._threadIndicatorKeyFor(btn);
            this._applyThreadIndicatorNew(btn, !!where && this._threadHasUnreadNotif(where.key, where.root));
        });
    },

    _buildThreadIndicator(rootId) {
        // Full-width row so the pill always breaks onto its own line.
        const row = document.createElement('div');
        row.className = 'thread-indicator-row';
        const btn = document.createElement('button');
        btn.className = 'thread-indicator';
        btn.type = 'button';
        btn.dataset.action = 'openMessageThread';
        btn.title = 'View thread';
        btn.innerHTML = `<span class="thread-indicator-icon">${this.THREAD_ICON_SVG}</span><span class="thread-indicator-count"></span><span class="thread-indicator-open">View thread</span>`;
        row.appendChild(btn);
        return row;
    },

    _appendThreadIndicator(messageEl, message, count) {
        const rootId = this.threadKeyForMessage(message);
        if (!rootId) return;
        const indicator = this._buildThreadIndicator(rootId);
        const countEl = indicator.querySelector('.thread-indicator-count');
        if (countEl) countEl.textContent = count === 1 ? '1 reply' : `${this.abbreviateNumber(count)} replies`;
        const key = this._threadConvKeyForMessage(message);
        if (key && typeof this._threadHasUnreadNotif === 'function') {
            this._applyThreadIndicatorNew(indicator.querySelector('.thread-indicator'), this._threadHasUnreadNotif(key, rootId));
        }
        messageEl.appendChild(indicator);
    },

    // No re-render: the caller is about to render the new conversation into the same container.
    _closeThreadViewOnSwitch() {
        this._threadDropHeld();
        if (!this.activeThread) return;
        const container = this._threadContainer;
        this.activeThread = null;
        this._threadContainer = null;
        this._setThreadComposerHint();
        this._typingThrottleTime = 0;
        if (container) container.classList.remove('thread-view-active');
    },

    _threadOnColumnFocus(colKey) {
        const col = typeof this._cvColumnForKey === 'function' ? this._cvColumnForKey(colKey) : null;
        const list = col ? col.listEl : null;
        const at = this.activeThread;
        const tc = this._threadContainer;
        if (at && tc && tc === list && at.ctx && at.ctx.storageKey === colKey) return;
        if (at) {
            const parkable = tc && tc !== list && tc.isConnected && at.ctx
                && (this._cvColumns || []).some((c) => c.listEl === tc && c.key === at.ctx.storageKey);
            if (parkable) {
                if (!this._cvThreads) this._cvThreads = new Map();
                this._cvThreads.set(tc, at);
                this.activeThread = null;
                this._threadContainer = null;
            } else if (tc && tc === list) {
                this._closeThreadViewOnSwitch();
            } else {
                this.closeThreadView({ nav: false });
            }
        }
        const parked = list && this._cvThreads ? this._cvThreads.get(list) : null;
        if (parked) {
            this._cvThreads.delete(list);
            if (parked.ctx && parked.ctx.storageKey === colKey && this.threadsEnabled()) {
                this.activeThread = parked;
                this._threadContainer = list;
                this._threadMarkOpenSeen();
            } else {
                list.classList.remove('thread-view-active');
                this._threadDropHeldIn(list);
            }
        }
        this._typingThrottleTime = 0;
    },

    applyThreadsEnabled() {
        this._threadCountCache = null;
        if (!this.threadsEnabled()) this._closeThreadViewOnSwitch();
        if (this._cvActive) {
            this._threadDropColumns();
            if (typeof this._cvRenderAll === 'function') this._cvRenderAll();
        } else if (typeof this.rerenderCurrentView === 'function') {
            this.rerenderCurrentView();
        }
    }
});

// Interactive children keep their behavior; this is on `document` so it runs before delegated handlers.
(function () {
    document.addEventListener('click', function (e) {
        var n = window.nym;
        if (!n || typeof n.threadsEnabled !== 'function' || !n.threadsEnabled()) return;
        if (typeof n.openMessageThread !== 'function') return;
        var msgEl = e.target && e.target.closest && e.target.closest('.message[data-message-id]');
        if (!msgEl) return;
        if (msgEl.closest('.thread-view-active')) return;
        // Bubble layout: the blank flex area beside the bubble must not open the thread.
        if (document.body.classList.contains('chat-bubbles')) {
            var contentEl = e.target.closest('.message-content');
            if (!contentEl || contentEl.closest('.message[data-message-id]') !== msgEl) return;
        }
        if (e.target.closest('a, button, img, video, audio, input, textarea, select, code, pre, ' +
            '.nm-mention, .author-clickable, .clickable-timestamp, .reaction-badge, .add-reaction-btn, ' +
            '.zap-badge, .add-zap-btn, .thread-indicator, .thread-indicator-row, .msg-hover-buttons, [data-action], ' +
            '.file-offer, .message-gallery, blockquote, .quote-author, .poll-card, .spoiler, ' +
            '.crypto-verified-badge, .crypto-pq-badge, .group-readers, .channel-readers, ' +
            '.delivery-status, .read-more-btn')) return;
        var sel = window.getSelection && window.getSelection();
        if (sel && String(sel).length > 0) return;
        if (Date.now() < (window._nymMediaClickSuppressUntil || 0)) return;
        n.openMessageThread(msgEl, { silent: true });
    }, false);
})();
