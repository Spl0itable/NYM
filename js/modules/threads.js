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
        return !held.some(m => m && m !== msg && this.threadKeyForMessage(m) === rootId);
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
        const ver = this._cfVersion || 0;
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

    // Null unless Nymbot is the root or last speaker; call before publishing the outgoing message.
    _threadBotQuoteContext(rootId, storageKey) {
        const chain = this._threadChannelChain(rootId, storageKey)
            .filter(m => String(m.content || '').trim());
        if (!chain.length) return null;
        const last = chain[chain.length - 1];
        if (!chain[0].isBot && !last.isBot) return null;
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
        return String(text || '')
            .replace(/^@[^\s]+[ \t]+/, '')
            .replace(/^[ \t]*\u26a1.*$/gm, '');
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

    _threadCtxLabel(ctx) {
        if (!ctx) return '';
        if (ctx.type === 'channel') return `#${ctx.geohash || ctx.channel || ''}`;
        if (ctx.type === 'group') {
            const g = this.groupConversations && this.groupConversations.get(ctx.groupId);
            return g ? (typeof this._groupLabel === 'function' ? this._groupLabel(g) : (g.name || 'Group')) : 'Group chat';
        }
        if (ctx.type === 'pm') {
            return `@${this.resolveDisplayNym(ctx.pubkey, ctx.nym || '')}`;
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
        this._setThreadComposerHint(true);
        this._threadMarkOpenSeen();

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
    <span class="thread-view-context">${this.escapeHtml(this._threadCtxLabel(at.ctx))}</span>`;
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

        if (typeof this._backfillZapReceipts === 'function') {
            const ids = [];
            for (const m of (root ? [root, ...replies] : replies)) {
                if (m.id) ids.push(m.id);
                if (m.isPM && m.nymMessageId && m.nymMessageId !== m.id) ids.push(m.nymMessageId);
            }
            if (ids.length) this._backfillZapReceipts(ids);
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

    _updateThreadDivider(count) {
        const container = this._threadContainer;
        const text = container && container.querySelector('.thread-replies-divider .thread-divider-text');
        if (!text) return;
        if (typeof count !== 'number') {
            const at = this.activeThread;
            const root = at ? this._threadFindMessage(at.ctx, at.rootId) : null;
            count = root ? this._threadRepliesFor(root).length : 0;
        }
        text.textContent = count === 0 ? 'No replies yet'
            : (count === 1 ? '1 reply' : `${this.abbreviateNumber(count)} replies`);
    },

    _setThreadComposerHint(active) {
        const input = document.getElementById('messageInput');
        if (!input) return;
        if (active) {
            if (input.dataset.prevPlaceholder === undefined) {
                input.dataset.prevPlaceholder = input.placeholder || '';
            }
            input.placeholder = 'Reply in thread...';
        } else if (input.dataset.prevPlaceholder !== undefined) {
            input.placeholder = input.dataset.prevPlaceholder;
            delete input.dataset.prevPlaceholder;
        }
    },

    // Null outside a thread view or when it belongs to another conversation (never mis-thread a send).
    _threadRootForSend() {
        const at = this.activeThread;
        if (!at || !this.threadsEnabled()) return null;
        const ctx = at.ctx;
        if (this._cvActive) {
            const col = this._cvColumns && this._cvColumns.find(c => c.id === this._cvFocusedId);
            return (col && col.key === ctx.storageKey) ? at.rootId : null;
        }
        if (ctx.type === 'group') return (this.inPMMode && this.currentGroup === ctx.groupId) ? at.rootId : null;
        if (ctx.type === 'pm') return (this.inPMMode && this.currentPM === ctx.pubkey) ? at.rootId : null;
        const key = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
        return (!this.inPMMode && key === ctx.storageKey) ? at.rootId : null;
    },

    // Ordinary conversation messages must not render into an occupied container.
    _threadViewOccupies(container) {
        return !!(this.activeThread && this._threadContainer && container === this._threadContainer);
    },

    closeThreadView(opts = {}) {
        const at = this.activeThread;
        if (!at) return;
        const container = this._threadContainer;
        this.activeThread = null;
        this._threadContainer = null;
        this._setThreadComposerHint(false);
        if (container) {
            container.classList.remove('thread-view-active');
            this.renderMessagesWithVirtualScroll(container, at.ctx.storageKey, true, !!at.ctx.isPM);
        }
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
        }
        this.openThreadView(entry.rootId, ctx, { push: false });
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
            const container = this._threadContainer;
            const dedupeId = (message.isPM && message.nymMessageId) ? message.nymMessageId : message.id;
            if (!container.querySelector(`[data-message-id="${dedupeId}"]`)) {
                this._renderThreadMessage(message, container);
                this._updateThreadDivider();
                if (message.isOwn) this._scheduleScrollToBottom(true);
            }
        }
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
        if (!this.activeThread) return;
        const container = this._threadContainer;
        this.activeThread = null;
        this._threadContainer = null;
        this._setThreadComposerHint(false);
        if (container) container.classList.remove('thread-view-active');
    },

    _threadOnColumnFocus(colKey) {
        const at = this.activeThread;
        if (at && at.ctx && at.ctx.storageKey !== colKey) {
            this.closeThreadView({ nav: false });
        }
    },

    applyThreadsEnabled() {
        this._threadCountCache = null;
        if (!this.threadsEnabled()) this._closeThreadViewOnSwitch();
        if (this._cvActive) {
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
