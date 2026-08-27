// threads.js - Slack-style message threads.

Object.assign(NYM.prototype, {

    // The SVG shared by the hover button and the reply-count row.
    THREAD_ICON_SVG: '<svg viewBox="0 0 20 20"><path fill="currentColor" fill-rule="evenodd" d="M10 3a7 7 0 1 0 3.394 13.124.75.75 0 0 1 .542-.074l2.794.68-.68-2.794a.75.75 0 0 1 .073-.542A7 7 0 0 0 10 3m-8.5 7a8.5 8.5 0 1 1 16.075 3.859l.904 3.714a.75.75 0 0 1-.906.906l-3.714-.904A8.5 8.5 0 0 1 1.5 10M6 8.25a.75.75 0 0 1 .75-.75h6.5a.75.75 0 0 1 0 1.5h-6.5A.75.75 0 0 1 6 8.25M6.75 11a.75.75 0 0 0 0 1.5h4.5a.75.75 0 0 0 0-1.5z" clip-rule="evenodd"></path></svg>',

    threadsEnabled() {
        return !this.settings || this.settings.threadsEnabled !== false;
    },

    // The id a reply's thread tag points at: the shared cross-recipient id for
    // PMs/groups, the event id for channel messages.
    threadKeyForMessage(msg) {
        if (!msg) return null;
        return (msg.isPM && msg.nymMessageId) ? msg.nymMessageId : msg.id;
    },

    // Whether a message can be a thread root: it needs an id every client can
    // reference (a real event id or shared nymMessageId, not an optimistic
    // temp id), and must not itself be a reply.
    _threadEligibleRoot(msg) {
        if (!msg || msg.threadRoot) return false;
        const key = this.threadKeyForMessage(msg);
        if (!key) return false;
        if (msg.isPM) return !!msg.nymMessageId;
        return /^[0-9a-f]{64}$/i.test(key);
    },

    // Extract the thread root from a channel event's tags (NIP-10 marked tags).
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

    // Extract the thread root from a PM/group rumor's tags.
    threadRootFromRumorTags(tags) {
        if (!Array.isArray(tags)) return null;
        const t = tags.find(t => Array.isArray(t) && t[0] === 'nymthread' && t[1]);
        return t ? String(t[1]) : null;
    },

    // The in-memory store list a message lives in.
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

    // True when a reply's root message is present locally. A reply whose root
    // we never saw falls back to rendering inline so it is never lost.
    _threadRootExistsFor(msg) {
        if (!msg || !msg.threadRoot) return false;
        const list = this._threadListForMessage(msg);
        if (!list) return false;
        const rootId = msg.threadRoot;
        return list.some(m => m !== msg && this.threadKeyForMessage(m) === rootId);
    },

    // True when a message is HIDDEN behind a collapsed thread: it is a reply
    // whose root we hold (so it renders inside the thread instead of inline)
    // and whose thread view isn't the one currently open.
    //
    // Such a message never reaches the screen even while its conversation is on
    // screen, so the notification gates must not treat "viewing the
    // conversation" as "the user saw it" for it. Without this an @mention or a
    // quote-reply landing in a thread played its sound
    // (`_onThreadReplyArrived`) and was never recorded: the bell modal stayed
    // empty for a message the user was told about but could not see.
    _threadReplyHidden(message) {
        if (!message || !message.threadRoot) return false;
        if (typeof this.threadsEnabled !== 'function' || !this.threadsEnabled()) return false;
        if (!this._threadRootExistsFor(message)) return false;
        const at = this.activeThread;
        return !(at && at.rootId === message.threadRoot);
    },

    // A thread is a conversation of its own, so the flat rules of the channel /
    // PM / group it hangs under are the wrong ones to judge its replies by. Two
    // predicates carry the difference, and both are no-ops for a message that
    // is not a thread reply.

    // True when the reply landed in a thread the USER started. Opening a thread
    // on your own message is joining a conversation, so its replies reach you
    // the way a mention does. Without this, replying under someone's message
    // notified them of nothing at all: a channel only ever notified on an
    // @mention, and the reply was collapsed out of sight.
    _threadReplyRootIsMine(message) {
        if (!message || !message.threadRoot) return false;
        const list = this._threadListForMessage(message);
        if (!list) return false;
        const root = list.find(m =>
            m !== message && this.threadKeyForMessage(m) === message.threadRoot);
        if (!root) return false;
        return !!root.isOwn || (!!this.pubkey && root.pubkey === this.pubkey);
    },

    // True when `threadNotifyMentionsOnly` holds this reply back: the setting is
    // on and the reply neither @mentions nor quote-replies the user. It is the
    // thread-scoped twin of `groupNotifyMentionsOnly`, and it applies wherever a
    // thread hangs — channel, PM or group.
    _threadReplySuppressed(message) {
        if (!message || !message.threadRoot) return false;
        if (typeof this.threadsEnabled !== 'function' || !this.threadsEnabled()) return false;
        if (!this.threadNotifyMentionsOnly) return false;
        return !this.isMentioned(message.content);
    },

    // True when this reply reaches the user whatever the conversation's own
    // rules say — it is in a thread they started. An @mention already passes
    // every gate, so only the thread-ownership half needs lifting here, and
    // `threadNotifyMentionsOnly` turns it off.
    _threadReplyElevated(message) {
        if (!message || !message.threadRoot) return false;
        if (typeof this.threadsEnabled !== 'function' || !this.threadsEnabled()) return false;
        if (this.threadNotifyMentionsOnly) return false;
        return this._threadReplyRootIsMine(message);
    },

    // Reply-count lookup, cached per store list. The cache keys on the list's
    // identity and length so inserts (push/splice) and slice reassignments
    // both invalidate it naturally.
    _threadReplyCountFor(msg) {
        const list = this._threadListForMessage(msg);
        if (!list || !list.length) return 0;
        const c = this._threadCountCache;
        if (!c || c.list !== list || c.len !== list.length) {
            const map = new Map();
            for (const m of list) {
                if (m && m.threadRoot) map.set(m.threadRoot, (map.get(m.threadRoot) || 0) + 1);
            }
            this._threadCountCache = { list, len: list.length, map };
        }
        const key = this.threadKeyForMessage(msg);
        return key ? (this._threadCountCache.map.get(key) || 0) : 0;
    },

    // All replies for a root, chronological.
    _threadRepliesFor(rootMsg) {
        const list = this._threadListForMessage(rootMsg) || [];
        const rootId = this.threadKeyForMessage(rootMsg);
        return list
            .filter(m => m && m.threadRoot === rootId && !this.deletedEventIds.has(m.id) &&
                !(m.nymMessageId && this.deletedEventIds.has(m.nymMessageId)) &&
                !(m.pubkey !== this.pubkey && (this.blockedUsers.has(m.pubkey) || m.blocked)))
            .sort((a, b) => this._compareMessages(a, b));
    },

    // Nymbot in channel threads 
    // `nym#abcd`, the shape quote-replies use, so /api/bot can tell the bot's
    // own turns apart from the humans' in a thread transcript.
    _threadMessageAuthor(msg) {
        const nym = (msg && msg.author) || 'nym';
        const suffix = (msg && msg.pubkey && typeof this.getPubkeySuffix === 'function')
            ? this.getPubkeySuffix(msg.pubkey) : '';
        return suffix ? `${nym}#${suffix}` : nym;
    },

    // The channel thread's messages, root first then replies, chronological.
    _threadChannelChain(rootId, storageKey) {
        if (!rootId || !storageKey || !this.threadsEnabled()) return [];
        const list = this.messages.get(storageKey) || [];
        const root = list.find(m => m && m.id === rootId);
        if (!root) return [];
        return [root, ...this._threadRepliesFor(root)];
    },

    // The Nymbot message a plain thread reply is answering, shaped like a
    // pendingQuote so the bot command path treats a thread reply exactly like a
    // quote-reply. Null unless Nymbot is the thread's root or its last speaker
    // — a thread nobody asked the bot into still needs an explicit ?command or
    // @Nymbot mention. Call this BEFORE publishing the outgoing message, so the
    // user's own message isn't the thread's last one yet.
    _threadBotQuoteContext(rootId, storageKey) {
        const chain = this._threadChannelChain(rootId, storageKey)
            .filter(m => String(m.content || '').trim());
        if (!chain.length) return null;
        const last = chain[chain.length - 1];
        if (!chain[0].isBot && !last.isBot) return null;
        const botMsgs = chain.filter(m => m.isBot);
        if (!botMsgs.length) return null;
        // An unfinished game lives in the newest [gc:] token in the thread;
        // quoting a bot message without it would route the guess to ?ask and
        // drop the game.
        let target = null;
        for (let i = botMsgs.length - 1; i >= 0; i--) {
            if (/\[gc:[A-Za-z0-9+/=]+\]/.test(botMsgs[i].content || '')) { target = botMsgs[i]; break; }
        }
        if (!target) target = botMsgs[botMsgs.length - 1];
        const text = String(target.content || '');
        return { author: this._threadMessageAuthor(target), text, fullText: text };
    },

    // One entry's text, with the wire envelope off: quote block, and for the
    // bot its @mention and zap prompt. Left in, the model mimics the format
    // instead of answering. The quote is redundant here anyway — in a thread
    // the message it quotes is its own entry.
    _threadEntryText(msg) {
        let text = String((msg && msg.content) || '')
            .split('\n').filter(l => !l.startsWith('>')).join('\n');
        if (msg && msg.isBot) text = this._stripBotEnvelope(text);
        return text.replace(/\n{3,}/g, '\n\n').trim();
    },

    // The @mention a bot reply opens with and the zap prompt it can close
    // with. The `[gc:]` token stays — ?guess reads the live game out of it.
    _stripBotEnvelope(text) {
        return String(text || '')
            .replace(/^@[^\s]+[ \t]+/, '')
            .replace(/^[ \t]*\u26a1.*$/gm, '');
    },

    // The thread transcript as bot conversation context, in the same
    // {author, text} shape _extractQuoteChain produces. `exclude` drops the
    // message just published (it is sent separately as the question).
    _threadBotConversation(rootId, storageKey, opts = {}) {
        const limit = opts.limit || 20;
        // Normalised like the entries: the caller hands it over as published.
        const exclude = opts.exclude ? this._threadEntryText({ content: opts.exclude }) : '';
        const entries = this._threadChannelChain(rootId, storageKey)
            .filter(m => !m._spamGated)
            .map(m => ({ author: this._threadMessageAuthor(m), text: this._threadEntryText(m).slice(0, 1000) }))
            .filter(e => e.text);
        if (exclude && entries.length && entries[entries.length - 1].text === exclude) {
            entries.pop();
        }
        return entries.slice(-limit);
    },

    // Find a message by its thread key within a conversation context.
    _threadFindMessage(ctx, id) {
        const list = ctx.isPM ? (this.pmMessages.get(ctx.storageKey) || [])
            : (this.messages.get(ctx.storageKey) || []);
        return list.find(m => this.threadKeyForMessage(m) === id) || null;
    },

    // Resolve the conversation context for a message element (which column it
    // sits in under column view, otherwise the active conversation).
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
            return g && g.name ? g.name : 'Group chat';
        }
        if (ctx.type === 'pm') {
            const nym = ctx.nym || this.getNymFromPubkey(ctx.pubkey);
            return `@${this.stripPubkeySuffix(nym || 'nym')}`;
        }
        return '';
    },

    // Open the thread for the message element/button `target` (hover button,
    // reply-count row, or long-press menu item).
    openMessageThread(target, opts = {}) {
        if (!this.threadsEnabled()) return;
        const msgEl = target && target.closest ? target.closest('[data-message-id]') : null;
        if (!msgEl) return;
        const ctx = this._threadCtxForElement(msgEl);
        if (!ctx) return;
        const id = msgEl.dataset.messageId;
        let msg = this._threadFindMessage(ctx, id);
        if (!msg) return;
        // Opening "the thread" of a reply means opening its root's thread.
        if (msg.threadRoot) {
            const root = this._threadFindMessage(ctx, msg.threadRoot);
            if (root) {
                msg = root;
            } else {
                // The root is no longer in the local store (bounded cache /
                // replay window). The thread still exists — open it keyed by
                // the reply's root reference; the view renders "Original
                // message unavailable" above whatever replies remain, instead
                // of dead-ending on the "cannot start a thread yet" toast
                // (that toast is for unconfirmed OWN messages, not this).
                this.openThreadView(msg.threadRoot, ctx);
                return;
            }
        }
        if (!this._threadEligibleRoot(msg)) {
            // A stray body click on an unsendable/system row stays quiet; the
            // explicit affordances (button, menu item) explain themselves.
            if (!opts.silent) {
                this.displaySystemMessage('This message cannot start a thread yet — try again once it has finished sending.');
            }
            return;
        }
        this.openThreadView(this.threadKeyForMessage(msg), ctx);
    },

    // The container the thread view renders into: the focused column's list in
    // column view, otherwise the single shared messages container.
    _threadContainerFor(ctx) {
        if (this._cvActive) {
            const col = this._cvColumnForKey(ctx.storageKey);
            if (!col || !col.listEl) return null;
            if (this._cvFocusedId !== col.id) this._cvFocusColumn(col.id);
            return col.listEl;
        }
        return document.getElementById('messagesContainer');
    },

    // Swap the current view to the thread: same container, same composer.
    openThreadView(rootId, ctx, opts = {}) {
        if (!this.threadsEnabled() || !rootId || !ctx) return;
        const container = this._threadContainerFor(ctx);
        if (!container) return;

        this.activeThread = { rootId, ctx };
        this._threadContainer = container;
        this._renderThreadView(container);
        this._setThreadComposerHint(true);

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

    // Full render of the open thread into its container: back bar, the root
    // message, a divider, then the replies (chronological).
    _renderThreadView(container) {
        const at = this.activeThread;
        if (!at || !container) return;
        container.innerHTML = '';
        // Invalidate the single-view DOM cache so leaving the thread does a
        // full conversation re-render instead of restoring thread rows.
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

        // Backfill zap receipts for the thread's messages, same as the main
        // conversation render does.
        if (typeof this._backfillZapReceipts === 'function') {
            const ids = [];
            for (const m of (root ? [root, ...replies] : replies)) {
                if (m.id) ids.push(m.id);
                if (m.isPM && m.nymMessageId && m.nymMessageId !== m.id) ids.push(m.nymMessageId);
            }
            if (ids.length) this._backfillZapReceipts(ids);
        }
    },

    // Render one message into the thread container through displayMessage's
    // thread mode (shallow clone so the store object never carries the flag).
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

    // Composer hint while replying in a thread; the original placeholder is
    // restored on close.
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

    // The thread root the composer should attach to the message being sent,
    // or null when not in a thread view (or it belongs to another
    // conversation — never mis-thread a send).
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

    // True when the thread view currently owns `container`, so ordinary
    // conversation messages must not render into it (they are stored and
    // reappear when the thread closes).
    _threadViewOccupies(container) {
        return !!(this.activeThread && this._threadContainer && container === this._threadContainer);
    },

    // Leave the thread view and restore the conversation in the same container.
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
        // Step the nav history back past the thread entry so Forward can
        // reopen it — only when the close came from the user (the back bar),
        // not from navigation itself.
        if (opts.nav !== false) {
            const current = this.navigationHistory && this.navigationHistory[this.navigationIndex];
            if (current && current.type === 'thread' && this.navigationIndex > 0) {
                this.navigateBack();
            }
        }
    },

    // Open the thread a bell-history entry came from. The notification names
    // the thread it happened in, so tapping it must land IN that thread —
    // dropping the user at the flat conversation leaves them hunting for the
    // reply behind whichever "N replies" row it collapsed into.
    //
    // Returns false when the entry names no thread (or threads are off), so the
    // caller keeps its plain open-the-conversation behaviour.
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
        // Same ordering as `_navOpenThread`: the caller has already switched the
        // conversation, and the thread view takes the container from there.
        this.openThreadView(info.threadRoot, ctx);
        return true;
    },

    // Called by _navigateTo for 'thread' history entries: make sure the
    // conversation is open first, then swap to the thread without re-pushing.
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

    // ---- Live updates -----------------------------------------------------

    // A reply for the visible conversation arrived (or was just sent): refresh
    // the root's reply-count row and, when its thread is open, append it there.
    _onThreadReplyArrived(message) {
        this._threadCountCache = null;
        this._refreshThreadIndicators(message.threadRoot, message);

        // Thread renders are silent in displayMessage (a re-render must never
        // replay sounds), so a LIVE reply landing in the OPEN thread plays its
        // one mention/PM sound here — the same gates as the normal live-message
        // path, which plays a sound for a mention the user can see.
        //
        // A reply for a COLLAPSED thread is deliberately NOT sounded here: it is
        // off screen, so it goes through the real notification path
        // (`showNotification`) like any other message the user cannot see, which
        // plays the sound AND records the bell entry. Sounding it here as well
        // was the whole bug — the tone fired while the notification modal stayed
        // empty, because the conversation being open suppressed the notification.
        if (!this._threadReplyHidden(message) &&
            !message.isHistorical && !message.isOwn && !message.isBot &&
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

    // Remove INLINE copies of a root's replies from the conversation view
    // (never from an open thread view). A reply renders inline when its root
    // hasn't hydrated/arrived yet — the "never lost" fallback — but once the
    // root IS here the reply belongs to the thread, and the DOM dedupe would
    // otherwise keep the stray inline copy forever: the message shows both
    // "escaped" at top level and inside its thread.
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

    // Update/create the "N replies" row on every rendered copy of the root
    // (single view and columns; never inside an active thread view).
    _refreshThreadIndicators(rootId, sampleMsg) {
        if (!rootId) return;
        const list = sampleMsg ? this._threadListForMessage(sampleMsg) : null;
        const rootMsg = list ? (list.find(m => this.threadKeyForMessage(m) === rootId) || null) : null;
        const count = rootMsg ? this._threadRepliesFor(rootMsg).length : 0;
        // The root being present means its replies belong in the thread, not
        // inline — clear any that escaped while the root was still missing.
        if (rootMsg && count > 0) this._sweepInlineThreadReplies(rootMsg);
        // `.message` rows only — the hover reaction button carries the same
        // data-message-id and must never receive an indicator.
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
        });
    },

    _buildThreadIndicator(rootId) {
        // A full-width row wrapping the pill, so it always breaks onto its own
        // line beneath the reactions/zaps row instead of wrapping inline with
        // the message content (the flex `.message` floated a bare pill to the
        // top-right — a fit-content flex item next to the bubble).
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

    // Append the reply-count row while building a root message's element.
    _appendThreadIndicator(messageEl, message, count) {
        const rootId = this.threadKeyForMessage(message);
        if (!rootId) return;
        const indicator = this._buildThreadIndicator(rootId);
        const countEl = indicator.querySelector('.thread-indicator-count');
        if (countEl) countEl.textContent = count === 1 ? '1 reply' : `${this.abbreviateNumber(count)} replies`;
        messageEl.appendChild(indicator);
    },

    // Clear thread state when the active conversation changes underneath the
    // view. No re-render here: the caller is about to render the new
    // conversation into the same container anyway.
    _closeThreadViewOnSwitch() {
        if (!this.activeThread) return;
        const container = this._threadContainer;
        this.activeThread = null;
        this._threadContainer = null;
        this._setThreadComposerHint(false);
        if (container) container.classList.remove('thread-view-active');
    },

    // Column view: focusing a different column while a thread is open exits
    // the thread (its column gets its conversation back).
    _threadOnColumnFocus(colKey) {
        const at = this.activeThread;
        if (at && at.ctx && at.ctx.storageKey !== colKey) {
            this.closeThreadView({ nav: false });
        }
    },

    // Settings toggle: re-render so replies collapse into threads or flow back
    // inline immediately.
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

// Clicking a message body opens its thread (threads enabled only). Interactive
// children — links, media, buttons, badges, the author, timestamps — keep their
// own behavior; a text selection or a just-fired long-press never triggers it.
// Quoted blocks are excluded here rather than relying on the quote handler
// stopping the event first: that handler is delegated on the conversation
// container, which never sees a click inside a column's own list.
(function () {
    document.addEventListener('click', function (e) {
        var n = window.nym;
        if (!n || typeof n.threadsEnabled !== 'function' || !n.threadsEnabled()) return;
        if (typeof n.openMessageThread !== 'function') return;
        var msgEl = e.target && e.target.closest && e.target.closest('.message[data-message-id]');
        if (!msgEl) return;
        if (msgEl.closest('.thread-view-active')) return;
        // Bubble layout: the row spans the full width with the bubble
        // (.message-content) aligned to one side, so the blank flex area next
        // to it must not read as a message click — own bubbles sit right and
        // the whole empty left half would otherwise open the thread.
        if (document.body.classList.contains('chat-bubbles')) {
            var contentEl = e.target.closest('.message-content');
            if (!contentEl || contentEl.closest('.message[data-message-id]') !== msgEl) return;
        }
        if (e.target.closest('a, button, img, video, audio, input, textarea, select, code, pre, ' +
            '.author-clickable, .clickable-timestamp, .reaction-badge, .add-reaction-btn, ' +
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
