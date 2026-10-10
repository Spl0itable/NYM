(function () {
    const A = () => window.NymMessageActions;
    const C = () => window.NymChatTools;
    const ico = (p, vb) => `<svg width="16" height="16" viewBox="${vb || '0 0 16 16'}" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">${p}</svg>`;
    const ICONS = {
        reply: '<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M 3 6 C 3 4.5 4 3 6 3 C 6 4.5 5 5 4 5.5 C 3.5 5.8 3 6.3 3 7 L 3 9 L 6 9 L 6 6 Z" /><path d="M 9 6 C 9 4.5 10 3 12 3 C 12 4.5 11 5 10 5.5 C 9.5 5.8 9 6.3 9 7 L 9 9 L 12 9 L 12 6 Z" /></svg>',
        replyPrivately: ico('<path d="M6 4 2 8l4 4"/><path d="M2 8h6.5a5 5 0 0 1 5 5"/><rect x="10" y="2" width="4" height="3.5" rx="0.6"/><path d="M10.8 2V1.4a1.2 1.2 0 0 1 2.4 0V2"/>'),
        thread: '<svg width="16" height="16" viewBox="0 0 20 20"><path fill="currentColor" fill-rule="evenodd" d="M10 3a7 7 0 1 0 3.394 13.124.75.75 0 0 1 .542-.074l2.794.68-.68-2.794a.75.75 0 0 1 .073-.542A7 7 0 0 0 10 3m-8.5 7a8.5 8.5 0 1 1 16.075 3.859l.904 3.714a.75.75 0 0 1-.906.906l-3.714-.904A8.5 8.5 0 0 1 1.5 10M6 8.25a.75.75 0 0 1 .75-.75h6.5a.75.75 0 0 1 0 1.5h-6.5A.75.75 0 0 1 6 8.25M6.75 11a.75.75 0 0 0 0 1.5h4.5a.75.75 0 0 0 0-1.5z" clip-rule="evenodd"></path></svg>',
        copy: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="5" y="5" width="8" height="9" rx="1" /><path d="M 3 10 L 3 4 C 3 3.45 3.45 3 4 3 L 9 3" stroke-linecap="round" /></svg>',
        translate: '<svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><path d="m12.87 15.07-2.54-2.51.03-.03A17.52 17.52 0 0 0 14.07 6H17V4h-7V2H8v2H1v1.99h11.17C11.5 7.92 10.44 9.75 9 11.35 8.07 10.32 7.3 9.19 6.69 8h-2c.73 1.63 1.73 3.17 2.98 4.56l-5.09 5.02L4 19l5-5 3.11 3.11.76-2.04zM18.5 10h-2L12 22h2l1.12-3h4.75L21 22h2l-4.5-12zm-2.62 7 1.62-4.33L19.12 17h-3.24z"/></svg>',
        save: ico('<path d="M4 2.5h8v11l-4-3-4 3z"/>'),
        unsave: ico('<path d="M4 2.5h8v11l-4-3-4 3z"/><line x1="2.5" y1="2.5" x2="13.5" y2="13.5"/>'),
        keep: ico('<path d="M6 2h4l-.8 4 2.8 3H4l2.8-3z"/><line x1="8" y1="9" x2="8" y2="14"/>'),
        unkeep: ico('<path d="M6 2h4l-.8 4 2.8 3H4l2.8-3z"/><line x1="8" y1="9" x2="8" y2="14"/><line x1="2.5" y1="2.5" x2="13.5" y2="13.5"/>'),
        edit: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M 11.5 2.5 L 13.5 4.5 L 5 13 L 2 14 L 3 11 Z" stroke-linejoin="round" /><path d="M 10 4 L 12 6" stroke-linecap="round" /></svg>',
        delete: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M 3 5 L 13 5" stroke-linecap="round" /><path d="M 5 5 L 5 13 C 5 13.55 5.45 14 6 14 L 10 14 C 10.55 14 11 13.55 11 13 L 11 5" stroke-linejoin="round" /><path d="M 6.5 2 L 9.5 2" stroke-linecap="round" /><path d="M 7 7 L 7 11.5" stroke-linecap="round" /><path d="M 9 7 L 9 11.5" stroke-linecap="round" /></svg>',
        editHistory: ico('<path d="M 2.5 8 A 5.5 5.5 0 1 0 4.1 4.1"/><path d="M 2 2.5 L 2 5 L 4.5 5"/><path d="M 8 5 L 8 8 L 10 9.5"/>'),
        eventDetails: ico('<circle cx="8" cy="8" r="6"/><path d="M8 7.2v3.8"/><circle cx="8" cy="5" r="0.6" fill="currentColor" stroke="none"/>'),
        zap: '<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M 9 2 L 4 9 H 7 L 7 14 L 12 7 H 9 Z" /></svg>',
        report: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="8" cy="8" r="6" /><path d="M 8 5 L 8 8.5" stroke-linecap="round" stroke-width="2" /><circle cx="8" cy="10.5" r="0.8" fill="currentColor" stroke="none" /></svg>',
        more: ico('<path d="M8 3.5v9M3.5 8h9" stroke-width="1.8"/>'),
    };
    const LABELS = {
        reply: 'Reply',
        replyPrivately: 'Reply privately',
        thread: 'Reply in Thread',
        copy: 'Copy text',
        translate: 'Translate',
        save: 'Save message',
        unsave: 'Remove from Saved',
        keep: 'Keep in chat',
        unkeep: 'Unkeep',
        zap: 'Zap Bitcoin',
        edit: 'Edit Message',
        delete: 'Delete Message',
        editHistory: 'Edit history',
        eventDetails: 'Event details',
        report: 'Report',
    };
    const SHEET_MAX = 768;
    const HEX64 = /^[0-9a-f]{64}$/i;

    Object.assign(NYM.prototype, {
        _msgSheetNarrow() {
            if (window.matchMedia) return window.matchMedia('(max-width: ' + SHEET_MAX + 'px)').matches;
            return window.innerWidth <= SHEET_MAX;
        },

        _msgSheetText(s) {
            return typeof this.uiText === 'function' ? (this.uiText(s) || s) : s;
        },

        _msgActionContext(msgEl) {
            const messageId = msgEl.dataset.messageId || '';
            const pubkey = msgEl.dataset.pubkey || '';
            const baseNym = this.stripPubkeySuffix(this.resolveDisplayNym(pubkey, msgEl.dataset.author || ''));
            const contentEl = msgEl.querySelector('.message-content');
            const content = msgEl.dataset.rawContent
                || (contentEl && typeof this._extractNonQuotedText === 'function' ? this._extractNonQuotedText(contentEl) : '')
                || '';
            const self = !!pubkey && pubkey === this.pubkey;
            const found = messageId && typeof this._ctFindMessage === 'function' ? this._ctFindMessage(messageId) : null;
            const m = found ? found.msg : null;
            const tools = C();
            const gid = (this.inPMMode && this.currentGroup) ? this.currentGroup : null;
            const facts = {
                self,
                id: !!messageId,
                content: !!content,
                author: !!pubkey,
                threadable: !!(messageId && typeof this.threadsEnabled === 'function' && this.threadsEnabled()
                    && !msgEl.closest('.thread-view-active')),
                stored: !!m,
                replyPrivately: !!(m && tools && typeof this._ctSurfaceForKey === 'function'
                    && tools.replyPrivatelyAllowed({ surface: this._ctSurfaceForKey(found.key), pubkey: m.pubkey, self: this.pubkey, system: !m.pubkey })),
                saved: !!(m && typeof this.isMessageSaved === 'function' && this.isMessageSaved(m)),
                keepOffered: !!(m && typeof this.keepAvailableFor === 'function' && this.keepAvailableFor(m, found.key)),
                kept: !!(m && typeof this.isMessageKept === 'function' && this.isMessageKept(m)),
                modDelete: !!(gid && !self && messageId && typeof this._canModDeleteGroupMessage === 'function'
                    && this._canModDeleteGroupMessage(gid, this.pubkey, pubkey)),
                edited: !!(msgEl.querySelector('.edited-indicator') || (m && m.isEdited)),
                hexId: HEX64.test(messageId),
                bot: typeof this.isVerifiedBot === 'function' && this.isVerifiedBot(pubkey),
            };
            return {
                msgEl, messageId, pubkey, baseNym, content, self, found, facts,
                fullNym: `${baseNym}#${this.getPubkeySuffix(pubkey)}`,
                toolId: m ? (m.nymMessageId || m.id) : messageId,
            };
        },

        _msgActionRun(id, x) {
            switch (id) {
                case 'reply':
                    return () => this.setQuoteReply(x.fullNym, x.content, x.messageId);
                case 'replyPrivately':
                    return () => this.replyPrivately(x.toolId);
                case 'thread':
                    return () => this.openMessageThread(x.msgEl);
                case 'copy':
                    return async () => {
                        try {
                            await navigator.clipboard.writeText(x.content);
                            this.displaySystemMessage('Message copied to clipboard');
                        } catch (_) {
                            this.displaySystemMessage('Failed to copy message');
                        }
                    };
                case 'translate':
                    return () => this.translateMessage(x.content, x.messageId);
                case 'save':
                case 'unsave':
                    return () => {
                        const f = this._ctFindMessage(x.toolId);
                        if (f && this.isMessageSaved(f.msg)) this.removeSavedMessage(f.msg.nymMessageId || f.msg.id);
                        else this.saveMessage(x.toolId);
                    };
                case 'keep':
                case 'unkeep':
                    return () => this.toggleKeepMessage(x.toolId);
                case 'zap':
                    return async () => {
                        this.displaySystemMessage(`Checking if @${x.baseNym} can receive zaps...`);
                        try {
                            const lnAddress = await this.fetchLightningAddressForUser(x.pubkey);
                            if (lnAddress) this.showZapModal(x.messageId, x.pubkey, x.baseNym);
                            else this.displaySystemMessage(`@${x.baseNym} cannot receive zaps (no lightning address set)`);
                        } catch (_) {
                            this.displaySystemMessage(`Failed to check if @${x.baseNym} can receive zaps`);
                        }
                    };
                case 'edit':
                    return () => this.startEditMessage({ messageId: x.messageId, content: x.content, pubkey: x.pubkey });
                case 'delete':
                    return async () => {
                        if (x.self) {
                            if (!(await window.showAppConfirm('Are you sure you want to delete this message? This will send a deletion request to relays.', { danger: true, okLabel: 'Delete' }))) return;
                            this.publishDeletionEvent(x.messageId, this.inPMMode ? 1059 : this.channelWire(this.currentGeohash).kind).then(() => {
                                this.displaySystemMessage('Deletion request sent to relays');
                            });
                            return;
                        }
                        if (!(await window.showAppConfirm("Delete this member's message for everyone in the group?", { danger: true, okLabel: 'Delete' }))) return;
                        this.modDeleteGroupMessage(x.messageId, x.pubkey);
                    };
                case 'editHistory':
                    return () => this.openEditHistory(x.messageId);
                case 'eventDetails':
                    return () => this.openEventDetails(x.messageId);
                case 'report':
                    return () => {
                        this.contextMenuData = {
                            nym: x.baseNym, pubkey: x.pubkey, content: x.content,
                            messageId: x.messageId, reactionId: x.messageId,
                        };
                        this.openReportModal();
                    };
                default:
                    return null;
            }
        },

        messageActionItems(msgEl) {
            const x = this._msgActionContext(msgEl);
            const ids = A().buildMessageActions(x.facts);
            const items = [];
            for (const id of ids) {
                const action = this._msgActionRun(id, x);
                if (!action) continue;
                items.push({
                    id,
                    label: LABELS[id],
                    svg: ICONS[id] || '',
                    cls: A().actionTone(id) === 'normal' ? '' : A().actionTone(id),
                    action,
                });
            }
            return { items, ctx: x };
        },

        _msgSheetTime(msgEl) {
            const ts = parseInt(msgEl.dataset.timestamp, 10);
            if (!ts) return '';
            try {
                return new Date(ts).toLocaleTimeString('en-US', {
                    hour: '2-digit', minute: '2-digit', hour12: !this.settings || this.settings.timeFormat === '12hr',
                });
            } catch (_) { return ''; }
        },

        _msgSheetEmojiHtml(emoji) {
            const cm = typeof emoji === 'string' && emoji.match(/^:([a-zA-Z0-9_]+):$/);
            if (cm && this.customEmojis && this.customEmojis.has(cm[1])) return this.renderCustomEmojiImg(cm[1]);
            return this.escapeHtml(emoji);
        },

        closeMessageSheet() {
            const modal = document.getElementById('messageSheetModal');
            if (modal) modal.classList.remove('active');
            document.querySelectorAll('.messages-container.has-long-press-highlight').forEach((el) => el.classList.remove('has-long-press-highlight'));
            document.querySelectorAll('.message.long-press-highlight').forEach((el) => el.classList.remove('long-press-highlight'));
        },

        openMessageSheet(msgEl, emojis) {
            const { items, ctx } = this.messageActionItems(msgEl);
            const esc = (s) => this.escapeHtml(String(s == null ? '' : s));
            let modal = document.getElementById('messageSheetModal');
            if (!modal) {
                modal = document.createElement('div');
                modal.className = 'modal msg-sheet-modal';
                modal.id = 'messageSheetModal';
                modal.setAttribute('data-sheet', '');
                modal.setAttribute('role', 'dialog');
                modal.setAttribute('aria-label', this._msgSheetText('Message actions'));
                document.body.appendChild(modal);
            }
            const tr = (s) => this._msgSheetText(s);
            const preview = A().sheetPreview(ctx.content, tr);
            const avatar = this.getAvatarUrl(ctx.pubkey);
            const fallback = this.generateAvatarSvg(ctx.pubkey);
            const suffix = ctx.pubkey ? this.getPubkeySuffix(ctx.pubkey) : '';
            modal.innerHTML =
                '<div class="modal-content msg-sheet">' +
                `<button type="button" class="modal-close msg-sheet-close" data-sheet-close aria-label="${esc(tr('Close'))}">✕</button>` +
                '<div class="msg-sheet-preview" data-sheet-handle>' +
                `<img class="msg-sheet-avatar" alt="" src="${esc(avatar)}">` +
                '<div class="msg-sheet-meta">' +
                `<div class="msg-sheet-head"><span class="msg-sheet-author" data-no-i18n><span class="msg-sheet-nym">${window.NymSuffix.html(ctx.baseNym, suffix)}</span></span><span class="msg-sheet-time">${esc(this._msgSheetTime(msgEl))}</span></div>` +
                `<div class="msg-sheet-text" data-no-i18n>${this.mentionSuffixHtml(preview.text)}</div>` +
                '</div>' +
                (preview.thumb ? `<img class="msg-sheet-thumb" alt="" src="${esc(typeof this.getProxiedMediaUrl === 'function' ? this.getProxiedMediaUrl(preview.thumb) : preview.thumb)}">` : '') +
                '</div>' +
                '<div class="msg-sheet-react">' +
                emojis.map((e) => `<button type="button" class="msg-sheet-emoji" data-emoji="${esc(e)}">${this._msgSheetEmojiHtml(e)}</button>`).join('') +
                `<button type="button" class="msg-sheet-more" aria-label="${esc(tr('More reactions'))}">${ICONS.more}</button>` +
                '</div>' +
                '<div class="msg-sheet-actions">' +
                items.map((it) => `<button type="button" class="msg-sheet-action${it.cls ? ' ' + it.cls : ''}" data-msg-action="${it.id}">${it.svg}<span>${esc(it.label)}</span></button>`).join('') +
                '</div>' +
                '</div>';
            const img = modal.querySelector('.msg-sheet-avatar');
            if (img) img.onerror = function () { this.onerror = null; this.src = fallback; };
            const thumb = modal.querySelector('.msg-sheet-thumb');
            if (thumb) thumb.onerror = function () { this.remove(); };
            const closeThen = (fn) => {
                this.closeMessageSheet();
                if (typeof fn === 'function') fn();
            };
            modal.querySelector('.msg-sheet-close').onclick = () => this.closeMessageSheet();
            modal.querySelectorAll('.msg-sheet-emoji').forEach((b) => {
                b.onclick = (ev) => {
                    ev.stopPropagation();
                    const emoji = b.dataset.emoji;
                    closeThen(async () => {
                        await this.sendReaction(ctx.messageId, emoji);
                        this.addToRecentEmojis(emoji);
                    });
                };
            });
            modal.querySelector('.msg-sheet-more').onclick = (ev) => {
                ev.stopPropagation();
                const anchor = msgEl;
                closeThen(() => this.showEnhancedReactionPicker(ctx.messageId, anchor));
            };
            modal.querySelectorAll('.msg-sheet-action').forEach((b) => {
                b.onclick = (ev) => {
                    ev.stopPropagation();
                    const it = items.find((i) => i.id === b.dataset.msgAction);
                    closeThen(it && it.action);
                };
            });
            if (!this._msgSheetEscBound) {
                this._msgSheetEscBound = true;
                document.addEventListener('keydown', (e) => {
                    const m = document.getElementById('messageSheetModal');
                    if (e.key !== 'Escape' || !m || !m.classList.contains('active')) return;
                    e.preventDefault();
                    if (window.nymSheets && window.nymSheets.isSheet(m)) window.nymSheets.close(m);
                    else this.closeMessageSheet();
                });
            }
            modal.classList.add('active');
            return modal;
        },

        _userSheetMount() {
            const menu = document.getElementById('contextMenu');
            if (!menu) return;
            let wrap = document.getElementById('userSheetModal');
            if (!wrap) {
                wrap = document.createElement('div');
                wrap.className = 'modal user-sheet-modal';
                wrap.id = 'userSheetModal';
                wrap.setAttribute('data-sheet', '');
                wrap.setAttribute('data-sheet-expand', '');
                wrap.setAttribute('role', 'dialog');
                wrap.setAttribute('aria-label', this._msgSheetText('User actions'));
                wrap.innerHTML = '<div class="modal-content user-sheet">'
                    + `<button type="button" class="modal-close user-sheet-close" data-sheet-close aria-label="${this.escapeHtml(this._msgSheetText('Close'))}">✕</button>`
                    + '</div>';
                document.body.appendChild(wrap);
                wrap.querySelector('.user-sheet-close').onclick = () => this.closeContextMenu();
            }
            if (!this._userSheetHome) {
                this._userSheetHome = document.createComment('user-sheet-home');
                menu.before(this._userSheetHome);
            }
            const panel = wrap.querySelector('.user-sheet');
            if (menu.parentNode !== panel) panel.appendChild(menu);
            menu.classList.add('in-sheet');
            const head = menu.querySelector('.context-menu-avatar-header');
            if (head && !head.hasAttribute('data-sheet-handle')) head.setAttribute('data-sheet-handle', '');
            const overlay = document.getElementById('contextMenuOverlay');
            if (overlay) overlay.classList.remove('active');
            wrap.classList.add('active');
        },

        _userSheetUnmount() {
            const wrap = document.getElementById('userSheetModal');
            const menu = document.getElementById('contextMenu');
            if (wrap) wrap.classList.remove('active');
            if (menu && this._userSheetHome && menu.parentNode !== this._userSheetHome.parentNode) {
                this._userSheetHome.after(menu);
            }
            if (menu) menu.classList.remove('in-sheet');
        },
    });

    const USER_SHEET_HIDDEN = ['ctxReact', 'ctxQuote', 'ctxCopyMessage', 'ctxTranslate', 'ctxEditMessage',
        'ctxDeleteMessage', 'ctxSaveMessage', 'ctxReplyPrivately', 'ctxKeepMessage'];

    const origShow = NYM.prototype.showContextMenu;
    if (typeof origShow === 'function') {
        NYM.prototype.showContextMenu = function () {
            const r = origShow.apply(this, arguments);
            try {
                if (this._msgSheetNarrow()) {
                    for (const id of USER_SHEET_HIDDEN) {
                        const el = document.getElementById(id);
                        if (el) el.style.display = 'none';
                    }
                    this._userSheetMount();
                } else {
                    this._userSheetUnmount();
                }
            } catch (_) { }
            return r;
        };
    }

    const origClose = NYM.prototype.closeContextMenu;
    if (typeof origClose === 'function') {
        NYM.prototype.closeContextMenu = function () {
            const menu = document.getElementById('contextMenu');
            const r = origClose.apply(this, arguments);
            try {
                if (menu && !menu.classList.contains('active')) this._userSheetUnmount();
            } catch (_) { }
            return r;
        };
    }
})();
