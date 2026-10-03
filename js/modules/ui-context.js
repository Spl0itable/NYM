// ui-context.js - Context menus, modals, gestures, sidebar, GIF picker, link previews, zap modals, event listeners

Object.assign(NYM.prototype, {

    setupMobileGestures() {
        if (window.innerWidth <= 768) {
            document.addEventListener('touchstart', (e) => {
                const touch = e.touches[0];
                // Only track swipes starting from the left edge.
                if (touch.clientX < 50) {
                    this.swipeStartX = touch.clientX;
                }
            });

            document.addEventListener('touchmove', (e) => {
                if (this.swipeStartX !== null) {
                    const touch = e.touches[0];
                    const swipeDistance = touch.clientX - this.swipeStartX;

                    if (swipeDistance > this.swipeThreshold) {
                        this.toggleSidebar();
                        this.swipeStartX = null;
                    }
                }
            });

            document.addEventListener('touchend', () => {
                this.swipeStartX = null;
            });
        }
    },

    closeSidebar() {
        const sidebar = document.getElementById('sidebar');
        sidebar.classList.remove('open');
        document.getElementById('mobileOverlay').classList.remove('active');
    },

    setupContextMenu() {
        this._setupMenuLayers();
        document.getElementById('contextMenuOverlay').addEventListener('click', () => {
            this.closeContextMenu();
        });

        document.getElementById('ctxCloseBtn').addEventListener('click', () => {
            this.closeContextMenu();
        });

        document.getElementById('ctxMention').addEventListener('click', () => {
            if (this.contextMenuData) {
                const baseNym = this.contextMenuData.nym;
                const pubkey = this.contextMenuData.pubkey;
                const suffix = this.getPubkeySuffix(pubkey);
                const fullNym = `${baseNym}#${suffix}`;
                this.insertMention(fullNym);
            }
            this.closeContextMenu();
        });

        document.getElementById('ctxPM').addEventListener('click', () => {
            if (this.contextMenuData) {
                const baseNym = this.contextMenuData.nym;
                const suffix = this.getPubkeySuffix(this.contextMenuData.pubkey);
                const fullNym = `${baseNym}#${suffix}`;
                this.openUserPM(fullNym, this.contextMenuData.pubkey);
            }
            this.closeContextMenu();
        });

        document.getElementById('ctxZap').addEventListener('click', async () => {
            if (this.contextMenuData && this.contextMenuData.messageId) {
                const { messageId, pubkey, nym } = this.contextMenuData;

                this.closeContextMenu();

                this.displaySystemMessage(`Checking if @${nym} can receive zaps...`);

                try {
                    const lnAddress = await this.fetchLightningAddressForUser(pubkey);

                    if (lnAddress) {
                        this.showZapModal(messageId, pubkey, nym);
                    } else {
                        this.displaySystemMessage(`@${nym} cannot receive zaps (no lightning address set)`);
                    }
                } catch (error) {
                    this.displaySystemMessage(`Failed to check if @${nym} can receive zaps`);
                }
            }
        });

        document.getElementById('ctxGiftCredits').addEventListener('click', () => {
            if (this.contextMenuData) {
                const { pubkey, nym } = this.contextMenuData;
                this.closeContextMenu();
                this.showBotCreditsModal({ pubkey, nym });
            }
        });

        let slapOption = document.getElementById('ctxSlap');
        if (!slapOption) {
            slapOption = document.createElement('div');
            slapOption.className = 'context-menu-item';
            slapOption.id = 'ctxSlap';
            slapOption.innerHTML = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" class="nm-ico8"><path d="M 1 8 Q 3 4 8 4 Q 11 4 13 6 L 15 4.5 L 15 11.5 L 13 10 Q 11 12 8 12 Q 3 12 1 8 Z" fill="none" /><circle cx="5" cy="7.5" r="0.7" fill="currentColor" stroke="none" /><path d="M 9 6.5 Q 10 8 9 9.5" stroke-linecap="round" /></svg>Slap with Trout';

            const pmOption = document.getElementById('ctxPM');
            if (pmOption && pmOption.nextSibling) {
                pmOption.parentNode.insertBefore(slapOption, pmOption.nextSibling);
            } else if (pmOption) {
                pmOption.parentNode.appendChild(slapOption);
            }
        }

        let hugOption = document.getElementById('ctxHug');
        if (!hugOption) {
            hugOption = document.createElement('div');
            hugOption.className = 'context-menu-item';
            hugOption.id = 'ctxHug';
            hugOption.innerHTML = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" class="nm-ico8"><circle cx="6" cy="5" r="2" /><circle cx="10" cy="5" r="2" /><path d="M 2 14 C 2 10 4 9 6 9 C 7 9 7.5 9.5 8 10 C 8.5 9.5 9 9 10 9 C 12 9 14 10 14 14" stroke-linecap="round" stroke-linejoin="round" /><path d="M 4 11.5 Q 8 9 12 11.5" stroke-linecap="round" /></svg>Give warm Hug';

            if (slapOption && slapOption.nextSibling) {
                slapOption.parentNode.insertBefore(hugOption, slapOption.nextSibling);
            } else if (slapOption) {
                slapOption.parentNode.appendChild(hugOption);
            }
        }

        document.getElementById('ctxReport').addEventListener('click', () => {
            if (this.contextMenuData) {
                this.openReportModal();
            }
            this.closeContextMenu();
        });

        slapOption.addEventListener('click', () => {
            if (this.contextMenuData) {
                this.cmdSlap(this.contextMenuData.pubkey);
            }
            this.closeContextMenu();
        });

        hugOption.addEventListener('click', () => {
            if (this.contextMenuData) {
                this.cmdHug(this.contextMenuData.pubkey);
            }
            this.closeContextMenu();
        });

        document.getElementById('ctxReact').addEventListener('click', () => {
            if (this.contextMenuData && this.contextMenuData.reactionId) {
                this.closeContextMenu();

                setTimeout(() => {
                    const tempButton = document.createElement('button');
                    tempButton.style.position = 'fixed';
                    tempButton.style.left = '50%';
                    tempButton.style.bottom = '50%';
                    tempButton.style.opacity = '0';
                    tempButton.style.pointerEvents = 'none';
                    document.body.appendChild(tempButton);

                    this.showEnhancedReactionPicker(this.contextMenuData.reactionId, tempButton);

                    setTimeout(() => tempButton.remove(), 100);
                }, 100);
            }
        });

        document.getElementById('ctxQuote').addEventListener('click', () => {
            if (this.contextMenuData && this.contextMenuData.content) {
                const baseNym = this.contextMenuData.nym;
                const suffix = this.getPubkeySuffix(this.contextMenuData.pubkey);
                const fullNym = `${baseNym}#${suffix}`;
                this.setQuoteReply(fullNym, this.contextMenuData.content);
            }
            this.closeContextMenu();
        });

        document.getElementById('ctxFriend').addEventListener('click', () => {
            if (this.contextMenuData) {
                this.toggleFriend(this.contextMenuData.pubkey);
            }
            this.closeContextMenu();
        });

        document.getElementById('ctxBlock').addEventListener('click', () => {
            if (this.contextMenuData) {
                this.cmdBlock(this.contextMenuData.pubkey);
            }
            this.closeContextMenu();
        });

        // Copies whichever form is on screen.
        document.getElementById('ctxCopyPubkey').addEventListener('click', async () => {
            if (this.contextMenuData && this.contextMenuData.pubkey) {
                const format = this.getPubkeyDisplayFormat();
                const value = this.formatPubkeyForDisplay(this.contextMenuData.pubkey, format);
                try {
                    await navigator.clipboard.writeText(value);
                    this.displaySystemMessage(`Copied ${format === 'npub' ? 'npub' : 'hex pubkey'} to clipboard`);
                } catch (err) {
                    this.displaySystemMessage('Failed to copy pubkey');
                }
            } else {
                this.displaySystemMessage('No pubkey available to copy');
            }
            this.closeContextMenu();
        });

        // npub ⇄ hex: bitchat speaks hex over the mesh, so the raw form stays one click away.
        const togglePubkeyFormat = () => {
            this.togglePubkeyDisplayFormat();
            this._renderContextMenuPubkey(this.contextMenuData && this.contextMenuData.pubkey);
            this._refreshPubkeySlideoutFormat();
        };
        document.getElementById('ctxTogglePubkeyFormat').addEventListener('click', togglePubkeyFormat);
        const ctxFullPubkeyEl = document.getElementById('ctxFullPubkey');
        if (ctxFullPubkeyEl) ctxFullPubkeyEl.addEventListener('click', togglePubkeyFormat);

        document.getElementById('ctxCopyMessage').addEventListener('click', async () => {
            if (this.contextMenuData && this.contextMenuData.content) {
                try {
                    await navigator.clipboard.writeText(this.contextMenuData.content);
                    this.displaySystemMessage('Message copied to clipboard');
                } catch (err) {
                    this.displaySystemMessage('Failed to copy message');
                }
            } else {
                this.displaySystemMessage('No message content to copy');
            }
            this.closeContextMenu();
        });

        document.getElementById('ctxTranslate').addEventListener('click', async () => {
            const data = this.contextMenuData;
            this.closeContextMenu();
            if (data && data.content) {
                const nonQuotedContent = data.content.split('\n')
                    .filter(line => !line.startsWith('>'))
                    .join('\n').trim();
                await this.translateMessage(nonQuotedContent || data.content, data.messageId || data.reactionId);
            } else {
                this.displaySystemMessage('No message content to translate');
            }
        });

        document.getElementById('ctxEditMessage').addEventListener('click', () => {
            if (this.contextMenuData && this.contextMenuData.messageId && this.contextMenuData.pubkey === this.pubkey) {
                this.startEditMessage(this.contextMenuData);
            }
            this.closeContextMenu();
        });

        document.getElementById('editPreviewClose').addEventListener('click', () => {
            this.cancelEditMessage();
        });

        // ctxDeleteMessage is wired via data-action in index.html and dispatched through inline-bindings.js.
    },

    openReportModal() {
        if (!this.contextMenuData) return;

        const modal = document.getElementById('reportModal');
        const targetNym = document.getElementById('reportTargetNym');
        const reportMessageCheckbox = document.getElementById('reportMessage');

        const baseNym = this.contextMenuData.nym;
        const suffix = this.getPubkeySuffix(this.contextMenuData.pubkey);
        const fullNym = `${baseNym}#${suffix}`;

        targetNym.textContent = fullNym;

        if (this.contextMenuData.messageId) {
            reportMessageCheckbox.disabled = false;
            reportMessageCheckbox.checked = true;
        } else {
            reportMessageCheckbox.disabled = true;
            reportMessageCheckbox.checked = false;
        }

        modal.style.display = 'flex';
    },

    closeReportModal() {
        const modal = document.getElementById('reportModal');
        modal.style.display = 'none';

        document.getElementById('reportType').value = 'nudity';
        document.getElementById('reportDetails').value = '';
        document.getElementById('reportMessage').checked = true;
    },

    async submitReport() {
        if (!this.contextMenuData) return;

        const reportType = document.getElementById('reportType').value;
        const reportDetails = document.getElementById('reportDetails').value;
        const reportMessage = document.getElementById('reportMessage').checked;

        const pubkey = this.contextMenuData.pubkey;
        const messageId = this.contextMenuData.messageId;

        try {
            // NIP-56 kind 1984 report event.
            const event = {
                kind: 1984,
                created_at: Math.floor(Date.now() / 1000),
                tags: [],
                content: reportDetails || '',
                pubkey: this.pubkey
            };

            // p tag is always required for user reports.
            event.tags.push(['p', pubkey, reportType]);

            if (reportMessage && messageId) {
                event.tags.push(['e', messageId, reportType]);
            }

            const signedEvent = await this.signEvent(event);

            if (signedEvent) {
                this.sendToRelay(["EVENT", signedEvent]);
                this.displaySystemMessage(`Report submitted successfully`);
                this.closeReportModal();
            }

        } catch (err) {
            this.displaySystemMessage('Failed to submit report');
        }
    },

    // Shared by card open and refresh so both build the same nym markup.
    _ctxNymHtml(pubkey, baseNym, suffix) {
        const flairHtml = this.getFlairForUser(pubkey);
        const userShopItems = this.getUserShopItems(pubkey);
        const supporterBadge = userShopItems?.supporter ?
            `<span class="supporter-badge"><span class="supporter-badge-icon">${this.getSupporterTrophyIcon()}</span><span class="supporter-badge-text">Supporter</span></span>` : '';
        const verifiedBadge = this.isVerifiedDeveloper(pubkey)
            ? `<span class="verified-badge nm-ctx-1" title="${this.verifiedDeveloper.title}">✓</span>`
            : this.isVerifiedBot(pubkey)
                ? '<span class="verified-badge nm-ctx-1" title="Nymchat Bot">✓</span>'
                : '';
        const ctxFriendBadge = pubkey !== this.pubkey && this.isFriend(pubkey)
            ? '<span class="friend-badge" title="Friend"><svg width="12" height="12" viewBox="0 0 16 16" fill="currentColor" class="nm-ctx-2"><circle cx="6" cy="5" r="2.5" /><path d="M 1.5 14 C 1.5 10.5 3.5 9 6 9 C 8.5 9 10.5 10.5 10.5 14" /><line x1="13" y1="6" x2="13" y2="10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /><line x1="11" y1="8" x2="15" y2="8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" /></svg></span>'
            : '';
        let nymHtml = `${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>${flairHtml}${supporterBadge}${verifiedBadge}${ctxFriendBadge}`;
        if (this.isVerifiedDeveloper(pubkey)) {
            nymHtml += `<div class="context-menu-dev-label">Nymchat Developer</div>`;
        } else if (this.isVerifiedBot(pubkey)) {
            nymHtml += `<div class="context-menu-dev-label">Nymchat Bot</div>`;
        }
        if (this.inPMMode && this.currentGroup) {
            const grp = this.groupConversations.get(this.currentGroup);
            if (grp && grp.createdBy === pubkey) {
                nymHtml += `<div class="context-menu-owner-label">Group Owner</div>`;
            } else if (grp && Array.isArray(grp.mods) && grp.mods.includes(pubkey)) {
                nymHtml += `<div class="context-menu-owner-label">Moderator</div>`;
            }
        }
        return nymHtml;
    },

    // Shared by card open and late banner arrival so both behave identically.
    _applyCtxBanner(bannerUrl) {
        const img = document.getElementById('ctxBannerImg');
        const menu = document.getElementById('contextMenu');
        if (!img) return;
        if (bannerUrl) {
            img.src = bannerUrl;
            img.style.display = 'block';
            img.style.cursor = 'pointer';
            img.onerror = function () {
                this.onerror = null;
                this.style.display = 'none';
                if (menu) menu.classList.remove('has-banner');
            };
            if (menu) menu.classList.add('has-banner');
        } else {
            img.style.display = 'none';
            if (menu) menu.classList.remove('has-banner');
        }
    },

    // Refreshes banner, bio and nym block for kind 0 data arriving after open; avatars use _flushAvatarUpdates.
    updateRenderedProfileCard(pubkey) {
        if (!pubkey) return;
        if (!this.contextMenuData || this.contextMenuData.pubkey !== pubkey) return;

        this._applyCtxBanner(this.getBannerUrl(pubkey));

        const ctxBio = document.getElementById('ctxBio');
        if (ctxBio) {
            const bio = this.getBio(pubkey);
            if (ctxBio.textContent !== bio) ctxBio.textContent = bio;
        }

        const ctxAvatarNym = document.getElementById('ctxAvatarNym');
        if (ctxAvatarNym) {
            // The live nym, not the one the clicked row carried when the card was opened.
            const baseNym = this.resolveDisplayNym(pubkey, '');
            const html = this._ctxNymHtml(pubkey, baseNym, this.getPubkeySuffix(pubkey));
            if (ctxAvatarNym.innerHTML !== html) ctxAvatarNym.innerHTML = html;
            if (this.contextMenuData) this.contextMenuData.nym = baseNym;
        }
    },

    // Called by users.js when a banner blob finishes downloading.
    updateRenderedBanner(pubkey) {
        if (!pubkey) return;
        if (!this.contextMenuData || this.contextMenuData.pubkey !== pubkey) return;
        this._applyCtxBanner(this.getBannerUrl(pubkey));
    },

    showContextMenu(e, nym, pubkey, content = null, messageId = null, profileOnly = false, reactionId = null, backToGroupId = null) {
        e.preventDefault();
        e.stopPropagation();

        const menu = document.getElementById('contextMenu');
        const parsedNym = this.resolveDisplayNym(pubkey, nym);
        const baseNym = this.stripPubkeySuffix(parsedNym);
        const suffix = this.getPubkeySuffix(pubkey);
        const fullNym = `${baseNym}#${suffix}`;

        // reactionId is the DOM-facing ID (nymMessageId for PMs); messageId is the real event ID.
        this.contextMenuData = { nym: baseNym, pubkey, content, messageId, reactionId: reactionId || messageId };

        // Shown only when opened from a group context menu, to return to it.
        this._ctxBackToGroup = backToGroupId || null;
        const ctxBackBtn = document.getElementById('ctxBackBtn');
        if (ctxBackBtn) ctxBackBtn.classList.toggle('nm-hidden', !backToGroupId);

        this._applyCtxBanner(this.getBannerUrl(pubkey));

        const ctxAvatarImg = document.getElementById('ctxAvatarImg');
        const ctxAvatarNym = document.getElementById('ctxAvatarNym');
        if (ctxAvatarImg) {
            ctxAvatarImg.src = this.getAvatarUrl(pubkey);
            const fallback = this.generateAvatarSvg(pubkey);
            ctxAvatarImg.onerror = function () { this.onerror = null; this.src = fallback; };
        }
        if (ctxAvatarNym) {
            ctxAvatarNym.innerHTML = this._ctxNymHtml(pubkey, baseNym, suffix);
        }

        // npub by default (see users.js).
        this._renderContextMenuPubkey(pubkey);

        const ctxStatusRow = document.getElementById('ctxStatusRow');
        if (ctxStatusRow) {
            ctxStatusRow.textContent = '';
            const status = this.getEffectiveUserStatus(pubkey);
            const targetHidden = this.statusHiddenUsers && this.statusHiddenUsers.has(pubkey);
            if (!targetHidden && status !== 'hidden') {
                const dot = document.createElement('span');
                dot.className = `user-status-dot status-${status}`;
                const label = document.createElement('span');
                label.textContent = status === 'online' ? 'Online'
                    : status === 'away' ? 'Away'
                        : 'Offline';
                ctxStatusRow.appendChild(dot);
                ctxStatusRow.appendChild(label);
                ctxStatusRow.style.display = '';
            } else {
                ctxStatusRow.style.display = 'none';
            }
        }

        // Visibility only: actions are bound via data-action and dispatched through inline-bindings.js.
        const gid = (this.inPMMode && this.currentGroup) ? this.currentGroup : null;
        const grpForCtx = gid ? this.groupConversations.get(gid) : null;
        const targetIsMember = !!(grpForCtx && grpForCtx.members.includes(pubkey));
        const other = !!(grpForCtx && targetIsMember && pubkey !== this.pubkey);
        const iAmOwner = !!(gid && this._isGroupOwner(gid, this.pubkey));
        const iCanAdminister = !!(gid && this._canAdminister(gid, this.pubkey));
        const iCanModerate = !!(gid && this._canModerate(gid, this.pubkey));
        const iOutrank = !!(gid && (iAmOwner || this._outranks(gid, this.pubkey, pubkey)));
        const targetIsAdmin = !!(gid && this._isGroupAdmin(gid, pubkey));
        const targetIsMod = !!(gid && this._isGroupMod(gid, pubkey));

        const showKickOrBan = other && iCanModerate && iOutrank;
        const showAddMod = other && iCanAdminister && iOutrank && !targetIsMod && !targetIsAdmin;
        const showRemoveMod = other && iCanAdminister && iOutrank && targetIsMod;
        const showAddAdmin = other && iAmOwner && !targetIsAdmin;
        const showRemoveAdmin = other && iAmOwner && targetIsAdmin;
        const showTransfer = other && iAmOwner;

        const setDisplay = (id, show) => {
            const el = document.getElementById(id);
            if (el) el.style.display = show ? 'block' : 'none';
        };
        const kickOption = document.getElementById('ctxKickMember');
        setDisplay('ctxKickMember', showKickOrBan);
        setDisplay('ctxBanMember', showKickOrBan);
        setDisplay('ctxAddMod', showAddMod);
        setDisplay('ctxRemoveMod', showRemoveMod);
        setDisplay('ctxAddAdmin', showAddAdmin);
        setDisplay('ctxRemoveAdmin', showRemoveAdmin);
        setDisplay('ctxTransferOwner', showTransfer);
        const reportOption = document.getElementById('ctxReport');
        if (reportOption && kickOption) {
            if (!this._ctxReportHome) {
                this._ctxReportHome = document.createComment('ctx-report-home');
                reportOption.before(this._ctxReportHome);
            }
            if (showKickOrBan) kickOption.before(reportOption);
            else this._ctxReportHome.after(reportOption);
        }

        let slapOption = document.getElementById('ctxSlap');
        if (!slapOption) {
            slapOption = document.createElement('div');
            slapOption.className = 'context-menu-item';
            slapOption.id = 'ctxSlap';
            slapOption.innerHTML = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" class="nm-ico8"><path d="M 1 8 Q 3 4 8 4 Q 11 4 13 6 L 15 4.5 L 15 11.5 L 13 10 Q 11 12 8 12 Q 3 12 1 8 Z" fill="none" /><circle cx="5" cy="7.5" r="0.7" fill="currentColor" stroke="none" /><path d="M 9 6.5 Q 10 8 9 9.5" stroke-linecap="round" /></svg>Slap with Trout';

            const pmOption = document.getElementById('ctxPM');
            if (pmOption && pmOption.nextSibling) {
                pmOption.parentNode.insertBefore(slapOption, pmOption.nextSibling);
            } else if (pmOption) {
                pmOption.parentNode.appendChild(slapOption);
            }
        }

        slapOption.style.display = pubkey === this.pubkey ? 'none' : 'block';

        let hugOption = document.getElementById('ctxHug');
        if (!hugOption) {
            hugOption = document.createElement('div');
            hugOption.className = 'context-menu-item';
            hugOption.id = 'ctxHug';
            hugOption.innerHTML = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" class="nm-ico8"><circle cx="6" cy="5" r="2" /><circle cx="10" cy="5" r="2" /><path d="M 2 14 C 2 10 4 9 6 9 C 7 9 7.5 9.5 8 10 C 8.5 9.5 9 9 10 9 C 12 9 14 10 14 14" stroke-linecap="round" stroke-linejoin="round" /><path d="M 4 11.5 Q 8 9 12 11.5" stroke-linecap="round" /></svg>Give warm Hug';

            if (slapOption && slapOption.nextSibling) {
                slapOption.parentNode.insertBefore(hugOption, slapOption.nextSibling);
            } else if (slapOption) {
                slapOption.parentNode.appendChild(hugOption);
            }
        }

        hugOption.style.display = pubkey === this.pubkey ? 'none' : 'block';

        const zapOption = document.getElementById('ctxZap');
        if (zapOption) {
            if (pubkey !== this.pubkey && messageId) {
                zapOption.style.display = 'block';
            } else {
                zapOption.style.display = 'none';
            }
        }

        const friendOption = document.getElementById('ctxFriend');
        if (pubkey === this.pubkey) {
            friendOption.style.display = 'none';
        } else {
            friendOption.style.display = 'block';
            const isFriend = this.friends.has(pubkey);
            const friendSvg = isFriend
                ? '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" class="nm-ico8"><circle cx="6" cy="5" r="2.5" /><path d="M 1.5 14 C 1.5 10.5 3.5 9 6 9 C 8.5 9 10.5 10.5 10.5 14" stroke-linecap="round" /><line x1="11" y1="8" x2="15" y2="8" stroke-linecap="round" stroke-width="1.5" /></svg>'
                : '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" class="nm-ico8"><circle cx="6" cy="5" r="2.5" /><path d="M 1.5 14 C 1.5 10.5 3.5 9 6 9 C 8.5 9 10.5 10.5 10.5 14" stroke-linecap="round" /><line x1="13" y1="6" x2="13" y2="10" stroke-linecap="round" stroke-width="1.5" /><line x1="11" y1="8" x2="15" y2="8" stroke-linecap="round" stroke-width="1.5" /></svg>';
            friendOption.innerHTML = friendSvg + (isFriend ? 'Remove Friend' : 'Add Friend');
        }

        const blockOption = document.getElementById('ctxBlock');
        if (pubkey === this.pubkey) {
            blockOption.style.display = 'none';
        } else {
            blockOption.style.display = 'block';
            const blockSvg = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" class="nm-ico8"><circle cx="8" cy="8" r="6" /><line x1="3.75" y1="3.75" x2="12.25" y2="12.25" stroke-width="1.5" stroke-linecap="round" /></svg>';
            blockOption.innerHTML = blockSvg + (this.blockedUsers.has(pubkey) ? 'Unblock User' : 'Block User');
        }

        // Hide PM only for your own messages (Nymbot accepts private chats).
        document.getElementById('ctxPM').style.display = (pubkey === this.pubkey) ? 'none' : 'block';

        const addToGroupOption = document.getElementById('ctxAddToGroup');
        if (addToGroupOption) {
            const canStartGroup = pubkey !== this.pubkey && !this.isVerifiedBot(pubkey) &&
                !(this.inPMMode && this.currentGroup);
            addToGroupOption.classList.toggle('nm-hidden', !canStartGroup);
        }

        document.getElementById('ctxGiftCredits').style.display =
            (pubkey === this.pubkey || this.isVerifiedBot(pubkey)) ? 'none' : 'block';

        const editProfileOption = document.getElementById('ctxEditProfile');
        if (editProfileOption) {
            editProfileOption.style.display = pubkey === this.pubkey ? 'block' : 'none';
            editProfileOption.onclick = () => {
                this.closeContextMenu();
                editNick();
            };
        }

        document.getElementById('ctxQuote').style.display = content ? 'block' : 'none';

        document.getElementById('ctxCopyMessage').style.display = content ? 'block' : 'none';

        // Hidden for mention/sidebar clicks that carry no message body.
        const ctxTranslateOption = document.getElementById('ctxTranslate');
        if (ctxTranslateOption) ctxTranslateOption.style.display = content ? 'block' : 'none';

        const reactOption = document.getElementById('ctxReact');
        reactOption.style.display = messageId ? 'block' : 'none';

        const editOption = document.getElementById('ctxEditMessage');
        if (pubkey === this.pubkey && messageId && content) {
            editOption.style.display = 'block';
        } else {
            editOption.style.display = 'none';
        }

        // Own messages, or a mod/owner deleting another member's message in the current group.
        const deleteOption = document.getElementById('ctxDeleteMessage');
        let canDeleteOwn = pubkey === this.pubkey && messageId;
        let canModDelete = false;
        if (!canDeleteOwn && messageId && this.inPMMode && this.currentGroup && pubkey !== this.pubkey) {
            const grp = this.groupConversations.get(this.currentGroup);
            if (grp) {
                const ownerSelf = grp.createdBy === this.pubkey;
                const modSelf = Array.isArray(grp.mods) && grp.mods.includes(this.pubkey);
                const targetIsOwner = grp.createdBy === pubkey;
                // Mods can delete anyone but the owner; the owner can delete anyone.
                canModDelete = (ownerSelf || (modSelf && !targetIsOwner));
            }
        }
        deleteOption.style.display = (canDeleteOwn || canModDelete) ? 'block' : 'none';

        document.getElementById('ctxReport').style.display = pubkey === this.pubkey ? 'none' : 'block';

        // In profile-only mode (e.g. nyms sidebar) show only PM, Report, Block.
        if (profileOnly) {
            const ctxMention = document.getElementById('ctxMention');
            if (ctxMention) ctxMention.style.display = 'none';
            const ctxTranslate = document.getElementById('ctxTranslate');
            if (ctxTranslate) ctxTranslate.style.display = 'none';
            if (slapOption) slapOption.style.display = 'none';
            if (hugOption) hugOption.style.display = 'none';
            if (kickOption) kickOption.style.display = 'none';
            if (editOption) editOption.style.display = 'none';
            const idsToHide = ['ctxBanMember', 'ctxAddMod', 'ctxRemoveMod', 'ctxAddAdmin', 'ctxRemoveAdmin', 'ctxTransferOwner'];
            for (const id of idsToHide) {
                const el = document.getElementById(id);
                if (el) el.style.display = 'none';
            }
        }

        const ctxBio = document.getElementById('ctxBio');
        if (ctxBio) {
            const bio = this.getBio(pubkey);
            ctxBio.textContent = bio;
        }

        menu.scrollTop = 0;

        document.getElementById('contextMenuOverlay').classList.add('active');
        menu.classList.add('active');

        // Prevent the click from immediately closing the menu.
        e.stopImmediatePropagation();
    },

    closeContextMenu() {
        if (this._menuLayerHold('contextMenu', () => this.closeContextMenu())) return;
        const menu = document.getElementById('contextMenu');
        const wasOpen = menu && menu.classList.contains('active');
        menu.classList.remove('active');
        document.getElementById('contextMenuOverlay').classList.remove('active');
        if (wasOpen && typeof this._focusMessageInput === 'function') this._focusMessageInput();
    },

    _MENU_LAYER_IDS: ['contextMenu', 'groupContextMenu'],

    _setupMenuLayers() {
        if (this._menuLayersBound) return;
        this._menuLayersBound = true;
        document.addEventListener('click', (e) => this._menuLayerClick(e), true);
        document.addEventListener('submit', (e) => this._menuLayerSubmit(e), true);
        window.addEventListener('keydown', (e) => this._menuLayerKey(e), true);
    },

    _menuLayerModals() {
        return Array.from(document.querySelectorAll('.modal')).filter((m) =>
            m.isConnected && !m.closest('.context-menu') && getComputedStyle(m).display !== 'none');
    },

    _menuLayerFresh(before) {
        return this._menuLayerModals().filter((m) => !before.has(m));
    },

    _menuLayerIsDismiss(t) {
        if (t.classList && t.classList.contains('modal')) return true;
        const el = t.closest('.modal-close, #appDialogCancelBtn, [data-dismiss], [data-action]');
        if (!el || !el.closest('.modal')) return false;
        if (el.matches('.modal-close, #appDialogCancelBtn, [data-dismiss]')) return true;
        return /^(ctCloseModal|closeModal|close[A-Z]\w*Modal|cancel\w*)$/.test(el.dataset.action || '');
    },

    _menuLayerFlagDismiss() {
        this._menuLayerDismissing = true;
        clearTimeout(this._menuLayerDismissTimer);
        this._menuLayerDismissTimer = setTimeout(() => { this._menuLayerDismissing = false; }, 0);
    },

    _menuLayerClick(e) {
        const t = e.target;
        if (!t || !t.closest) return;
        if (this._menuLayer && this._menuLayerIsDismiss(t)) this._menuLayerFlagDismiss();
        const menu = t.closest('.context-menu.active');
        if (!menu || menu.hasAttribute('inert') || this._MENU_LAYER_IDS.indexOf(menu.id) < 0) return;
        const opener = t.closest('.context-menu-item, [data-action], button');
        const g = { menu, opener: opener && menu.contains(opener) ? opener : null, before: new Set(this._menuLayerModals()), close: null, settled: false };
        this._menuGesture = g;
        setTimeout(() => { if (!g.settled) this._menuLayerSettle(g); }, 0);
    },

    _menuLayerHold(id, close) {
        const g = this._menuGesture;
        if (g && !g.settled && g.menu.id === id) {
            if (!g.close) queueMicrotask(() => { if (!g.settled) this._menuLayerSettle(g); });
            g.close = close;
            return true;
        }
        if (this._menuLayer && this._menuLayer.menu.id === id) this._menuLayerEnd('drop');
        return false;
    },

    _menuLayerSettle(g) {
        g.settled = true;
        if (this._menuGesture === g) this._menuGesture = null;
        if (g.menu.classList.contains('active') && this._menuLayerFresh(g.before).length) {
            this._menuLayerStart(g);
            return;
        }
        if (g.close) g.close();
    },

    _menuLayerStart(g) {
        if (this._menuLayer) this._menuLayerEnd('drop');
        const menu = g.menu;
        const layer = { menu, overlay: document.getElementById(menu.id + 'Overlay'), opener: g.opener, before: g.before, done: false };
        this._menuLayer = layer;
        menu.setAttribute('inert', '');
        menu.classList.add('ctx-under-modal');
        if (layer.overlay) layer.overlay.classList.add('ctx-under-modal');
        layer.observer = new MutationObserver(() => this._menuLayerCheck());
        layer.observer.observe(document.body, { subtree: true, childList: true, attributes: true, attributeFilter: ['class', 'style'] });
    },

    _menuLayerCheck() {
        const layer = this._menuLayer;
        if (!layer) return;
        if (!layer.menu.classList.contains('active')) { this._menuLayerEnd('drop'); return; }
        if (this._menuLayerFresh(layer.before).length) return;
        this._menuLayerEnd(this._menuLayerDismissing && !layer.done ? 'restore' : 'close');
    },

    _menuLayerEnd(mode) {
        const layer = this._menuLayer;
        if (!layer) return;
        this._menuLayer = null;
        if (layer.observer) layer.observer.disconnect();
        layer.menu.removeAttribute('inert');
        layer.menu.classList.remove('ctx-under-modal');
        if (layer.overlay) layer.overlay.classList.remove('ctx-under-modal');
        if (mode === 'restore') {
            const o = layer.opener;
            if (o && o.isConnected && layer.menu.contains(o)) {
                if (!o.hasAttribute('tabindex') && o.tabIndex < 0) o.setAttribute('tabindex', '-1');
                try { o.focus({ preventScroll: true }); } catch (_) { }
            }
        } else if (mode === 'close' && layer.menu.classList.contains('active')) {
            this._menuLayerCloseMenu(layer.menu);
        }
    },

    _menuLayerCloseMenu(menu) {
        if (menu.id === 'groupContextMenu') this.closeGroupContextMenu();
        else this.closeContextMenu();
    },

    _menuLayerSubmit(e) {
        const layer = this._menuLayer;
        const modal = layer && e.target && e.target.closest ? e.target.closest('.modal') : null;
        if (modal && !layer.before.has(modal)) layer.done = true;
    },

    _menuLayerKey(e) {
        if (e.key !== 'Escape') return;
        const layer = this._menuLayer;
        if (layer) {
            this._menuLayerFlagDismiss();
            const fresh = this._menuLayerFresh(layer.before);
            const top = fresh[fresh.length - 1];
            setTimeout(() => {
                if (this._menuLayer !== layer || !top || !top.isConnected || getComputedStyle(top).display === 'none') return;
                const close = top.querySelector('#appDialogCancelBtn, .modal-close, [data-action="ctCloseModal"]');
                if (close) close.click();
            }, 0);
            return;
        }
        if (e.defaultPrevented || this._menuLayerModals().length) return;
        const a = document.activeElement;
        const open = this._MENU_LAYER_IDS.map((id) => document.getElementById(id)).filter((m) => m && m.classList.contains('active'));
        if (!open.length || (a && a !== document.body && !open.some((m) => m.contains(a)))) return;
        e.preventDefault();
        open.forEach((m) => this._menuLayerCloseMenu(m));
    },

    UNFURL_TTL_MS: 7 * 24 * 60 * 60 * 1000,
    UNFURL_MISS_TTL_MS: 60 * 60 * 1000,
    UNFURL_CACHE_MAX: 200,

    _loadUnfurlCache() {
        if (this._unfurlCacheLoaded) return;
        this._unfurlCacheLoaded = true;
        if (!this._unfurlCache) this._unfurlCache = new Map();
        try {
            const raw = localStorage.getItem('nym_unfurl_cache');
            if (!raw) return;
            const now = Date.now();
            for (const [url, entry] of Object.entries(JSON.parse(raw) || {})) {
                if (!entry || typeof entry.at !== 'number') continue;
                const ttl = entry.data ? this.UNFURL_TTL_MS : this.UNFURL_MISS_TTL_MS;
                if (now - entry.at > ttl) continue;
                this._unfurlCache.set(url, entry);
            }
        } catch (_) { }
    },

    _saveUnfurlCache() {
        if (this._unfurlSaveTimer) return;
        this._unfurlSaveTimer = setTimeout(() => {
            this._unfurlSaveTimer = null;
            try {
                const out = {};
                for (const [url, entry] of this._unfurlCache) {
                    if (entry && entry.data) out[url] = entry;
                }
                localStorage.setItem('nym_unfurl_cache', JSON.stringify(out));
            } catch (_) { }
        }, 2000);
    },

    _cacheUnfurl(url, data) {
        this._unfurlCache.set(url, { at: Date.now(), data: data || null });
        while (this._unfurlCache.size > this.UNFURL_CACHE_MAX) {
            this._unfurlCache.delete(this._unfurlCache.keys().next().value);
        }
        this._saveUnfurlCache();
        return data || null;
    },

    // CF proxy when available, else direct fetch (may hit CORS); results incl. misses are cached and shared.
    unfurlUrl(url) {
        this._loadUnfurlCache();
        const hit = this._unfurlCache.get(url);
        if (hit) {
            const ttl = hit.data ? this.UNFURL_TTL_MS : this.UNFURL_MISS_TTL_MS;
            if (Date.now() - hit.at <= ttl) return Promise.resolve(hit.data);
            this._unfurlCache.delete(url);
        }
        if (!this._unfurlInflight) this._unfurlInflight = new Map();
        const pending = this._unfurlInflight.get(url);
        if (pending) return pending;
        const p = this._unfurlFetch(url)
            .then(data => this._cacheUnfurl(url, data))
            .catch(() => this._cacheUnfurl(url, null))
            .finally(() => this._unfurlInflight.delete(url));
        this._unfurlInflight.set(url, p);
        return p;
    },

    async _unfurlFetch(url) {
        try {
            let data;
            let proxied = null;
            const base = this._getProxyBaseUrl();
            if (base) {
                try {
                    proxied = await this._edgeFetch(`${base}?action=unfurl&url=${encodeURIComponent(url)}`);
                } catch (err) {
                    if (!this._proxyUnreachable(err)) return null;
                }
            }
            if (proxied && !this._proxyUnreachable(proxied)) {
                if (!proxied.ok) return null;
                data = await proxied.json();
            } else {
                // Direct fetch fallback: works when the target sets CORS headers.
                const resp = await fetch(url, {
                    headers: { 'Accept': 'text/html' },
                    redirect: 'follow',
                });
                if (!resp.ok) return null;
                const contentType = (resp.headers.get('content-type') || '').toLowerCase();
                if (!contentType.includes('text/html')) return null;
                const html = await resp.text();
                data = this._extractOpenGraph(html, url);
            }
            if (!data || data.error) return null;
            return data;
        } catch {
            return null;
        }
    },

    _extractOpenGraph(html, pageUrl) {
        const get = (property) => {
            const ogMatch = html.match(new RegExp(`<meta[^>]+property=["']og:${property}["'][^>]+content=["']([^"']+)["']`, 'i'))
                || html.match(new RegExp(`<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:${property}["']`, 'i'));
            if (ogMatch) return ogMatch[1];
            const twMatch = html.match(new RegExp(`<meta[^>]+name=["']twitter:${property}["'][^>]+content=["']([^"']+)["']`, 'i'))
                || html.match(new RegExp(`<meta[^>]+content=["']([^"']+)["'][^>]+name=["']twitter:${property}["']`, 'i'));
            if (twMatch) return twMatch[1];
            return null;
        };
        const title = get('title') || (html.match(/<title[^>]*>([^<]+)<\/title>/i) || [])[1] || '';
        const description = get('description')
            || (html.match(/<meta[^>]+name=["']description["'][^>]+content=["']([^"']+)["']/i) || [])[1] || '';
        // The page controls these, so resolve then re-check the scheme.
        const resolveHttp = (raw) => {
            if (!raw) return '';
            try {
                const u = new URL(raw, pageUrl);
                return (u.protocol === 'http:' || u.protocol === 'https:') ? u.href : '';
            } catch { return ''; }
        };
        const image = resolveHttp(get('image'));
        const favMatch = html.match(/<link[^>]+rel=["'](?:icon|shortcut icon)["'][^>]+href=["']([^"']+)["']/i)
            || html.match(/<link[^>]+href=["']([^"']+)["'][^>]+rel=["'](?:icon|shortcut icon)["']/i);
        const favicon = favMatch ? resolveHttp(favMatch[1]) : '';
        const decode = (s) => s.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'");
        return {
            url: pageUrl,
            title: decode(title).slice(0, 300),
            description: decode(description).slice(0, 500),
            image,
            siteName: decode(get('site_name') || ''),
            type: get('type') || '',
            favicon,
        };
    },

    _renderLinkPreview(meta) {
        if (!meta || (!meta.title && !meta.description)) return '';

        // Cached entries may predate the extractor's scheme check, so re-guard here.
        const imageSrc = this.safeUrl(meta.image);
        const imageHtml = imageSrc
            ? `<img src="${this.escapeHtml(this.getProxiedMediaUrl(imageSrc))}" class="link-preview-image" decoding="async" loading="lazy" data-error-action="errorHideElement">`
            : '';

        const faviconSrc = this.safeUrl(meta.favicon);
        const faviconHtml = faviconSrc
            ? `<img src="${this.escapeHtml(this.getProxiedMediaUrl(faviconSrc))}" class="link-preview-favicon" decoding="async" loading="lazy" data-error-action="errorHideElement">`
            : '';

        const siteNameHtml = meta.siteName
            ? `<span class="link-preview-site">${faviconHtml}${this.escapeHtml(meta.siteName)}</span>`
            : '';

        let host = '';
        try { host = new URL(meta.url).hostname; } catch { }

        const safeHref = this.escapeHtml(this.safeUrl(meta.url));
        if (!safeHref) return '';

        return `<a href="${safeHref}" target="_blank" rel="noopener" class="link-preview" data-action="stopPropagation">
            ${imageHtml}
            <div class="link-preview-text">
                ${siteNameHtml || `<span class="link-preview-site">${this.escapeHtml(host)}</span>`}
                <span class="link-preview-title">${this.escapeHtml(meta.title || '')}</span>
                <span class="link-preview-desc">${this.escapeHtml((meta.description || '').slice(0, 200))}</span>
            </div>
        </a>`;
    },

    // Idempotent; opts.scope/container/flag let Nostr reference cards unfurl their own body's links.
    _attachLinkPreviews(messageEl, opts = {}) {
        const flag = opts.flag || 'previewsAttached';
        if (messageEl.dataset[flag] === '1') return;
        const scope = opts.scope || messageEl;
        const links = opts.scope
            ? scope.querySelectorAll('a[href^="http"]')
            : scope.querySelectorAll('.message-content a[href^="http"]');
        if (links.length === 0) return;
        const container = opts.container || messageEl.querySelector('.message-content');
        if (!container) return;
        messageEl.dataset[flag] = '1';

        const seen = new Set();
        const hrefs = [];
        for (const link of links) {
            const href = link.getAttribute('href');
            if (!href || seen.has(href)) continue;
            if (typeof link.closest === 'function' && link.closest('.spoiler')) continue;
            // Skip media URLs (already embedded inline).
            if (/\.(jpg|jpeg|png|gif|webp|mp4|webm|ogg|mov)(\?.*)?$/i.test(href)) continue;
            seen.add(href);
            hrefs.push(href);
        }
        if (hrefs.length === 0) return;

        const paint = (meta) => {
            if (!meta || (!meta.title && !meta.description)) return;
            const html = this._renderLinkPreview(meta);
            if (!html || !container.isConnected) return;
            const el = document.createElement('div');
            el.className = 'link-preview-container';
            el.innerHTML = html;
            container.appendChild(el);
        };

        const run = () => {
            this._loadUnfurlCache();
            for (const href of hrefs) {
                const hit = this._unfurlCache.get(href);
                if (hit && Date.now() - hit.at <= (hit.data ? this.UNFURL_TTL_MS : this.UNFURL_MISS_TTL_MS)) {
                    paint(hit.data);
                    continue;
                }
                this.unfurlUrl(href).then(paint).catch(() => { });
            }
        };

        // Defer until near the viewport so a 50-message window doesn't burst proxy requests.
        if (typeof IntersectionObserver !== 'function') { run(); return; }
        if (!this._unfurlObserver) {
            this._unfurlObserver = new IntersectionObserver((entries) => {
                for (const en of entries) {
                    if (!en.isIntersecting) continue;
                    this._unfurlObserver.unobserve(en.target);
                    const cb = en.target._unfurlRun;
                    if (cb) { en.target._unfurlRun = null; cb(); }
                }
            }, { rootMargin: '200px' });
        }
        messageEl._unfurlRun = run;
        this._unfurlObserver.observe(messageEl);
    },

    setupEventListeners() {
        const statusIndicator = document.querySelector('.status-indicator');
        if (statusIndicator) {
            statusIndicator.style.cursor = 'pointer';
            statusIndicator.addEventListener('click', () => {
                if (!this.connected && !this.initialConnectionInProgress) {
                    this.clearRelayBlocksForReconnection();
                    this.displaySystemMessage('Manual reconnection attempt...');
                    this.attemptReconnection();
                }
            });
        }

        const messagesContainer = document.getElementById('messagesContainer');
        if (messagesContainer) {
            messagesContainer.addEventListener('click', (e) => {
                const retryEl = e.target.closest('[data-retry-event-id]');
                if (retryEl) {
                    e.preventDefault();
                    e.stopPropagation();
                    this.manualRetryDM(retryEl.dataset.retryEventId);
                    return;
                }
            });
        }

        // Delegated on document because column view renders outside #messagesContainer; mentions only in message bodies.
        document.addEventListener('click', (e) => {
            if (!e.target.closest) return;
            const mentionEl = e.target.closest('.nm-mention');
            if (!mentionEl || !mentionEl.closest('.message-content')) return;
            if (e.target.closest('a, button, .reaction-badge, .add-reaction-btn')) return;
            const pubkey = this._resolveMentionPubkey(mentionEl);
            if (!pubkey) return;
            e.preventDefault();
            e.stopPropagation();
            const nym = this.resolveDisplayNym(pubkey, '');
            const suffix = this.getPubkeySuffix(pubkey);
            this.showContextMenu(e, `${nym}#${suffix}`, pubkey, null, null, false);
        });

        // Delegated on document because column view renders outside #messagesContainer.
        document.addEventListener('click', (e) => {
            const bq = e.target.closest && e.target.closest('.message-content > blockquote');
            if (!bq || !bq.closest('.message[data-message-id]')) return;
            if (e.target.closest('a, button, img, .reaction-badge, .add-reaction-btn, .nm-mention, code, pre')) return;
            e.preventDefault();
            e.stopPropagation();
            this._scrollToQuotedMessage(bq);
        });

        document.getElementById('quotePreviewClose').addEventListener('click', () => {
            this.clearQuoteReply();
        });

        this.setupSwipeToReply();
        this.setupDoubleClickToReply();

        document.addEventListener('keydown', (e) => {
            if (e.altKey && e.key === 'ArrowLeft') {
                e.preventDefault();
                this.navigateBack();
            } else if (e.altKey && e.key === 'ArrowRight') {
                e.preventDefault();
                this.navigateForward();
            }
        });

        // Browsers intercept mouse back/forward before JS, so use the History API (pushState in _pushNavigation).
        window.addEventListener('popstate', (e) => {
            if (e.state && e.state._nym_nav != null) {
                const targetIndex = e.state._nym_nav;
                if (targetIndex < this.navigationIndex) {
                    this.navigationIndex = targetIndex;
                    this._navigateTo(this.navigationHistory[this.navigationIndex]);
                    this._updateNavButtons();
                } else if (targetIndex > this.navigationIndex) {
                    this.navigationIndex = targetIndex;
                    this._navigateTo(this.navigationHistory[this.navigationIndex]);
                    this._updateNavButtons();
                }
            }
        });

        const input = document.getElementById('messageInput');
        this._initRichMessageInput(input);
        this._watchComposerDock(input);

        ['autocompleteDropdown', 'channelAutocomplete', 'emojiAutocomplete', 'commandPalette', 'kaomojiAutocomplete'].forEach((id) => {
            const dd = document.getElementById(id);
            if (dd) dd.addEventListener('mousedown', (e) => e.preventDefault());
        });

        input.addEventListener('keydown', (e) => {
            const autocomplete = document.getElementById('autocompleteDropdown');
            const channelAc = document.getElementById('channelAutocomplete');
            const emojiAutocomplete = document.getElementById('emojiAutocomplete');
            const commandPalette = document.getElementById('commandPalette');
            const kaomojiAc = document.getElementById('kaomojiAutocomplete');

            if (autocomplete.classList.contains('active')) {
                if (e.key === 'ArrowDown') {
                    e.preventDefault();
                    this.navigateAutocomplete(1);
                } else if (e.key === 'ArrowUp') {
                    e.preventDefault();
                    this.navigateAutocomplete(-1);
                } else if (e.key === 'Enter' || e.key === 'Tab') {
                    e.preventDefault();
                    this.selectAutocomplete();
                } else if (e.key === 'Escape') {
                    e.preventDefault();
                    this.hideAutocomplete();
                }
            } else if (channelAc && channelAc.classList.contains('active')) {
                if (e.key === 'ArrowDown') {
                    e.preventDefault();
                    this.navigateChannelAutocomplete(1);
                } else if (e.key === 'ArrowUp') {
                    e.preventDefault();
                    this.navigateChannelAutocomplete(-1);
                } else if (e.key === 'Enter' || e.key === 'Tab') {
                    e.preventDefault();
                    this.selectChannelAutocomplete();
                } else if (e.key === 'Escape') {
                    e.preventDefault();
                    this.hideChannelAutocomplete();
                }
            } else if (emojiAutocomplete.classList.contains('active')) {
                if (e.key === 'ArrowDown') {
                    e.preventDefault();
                    this.navigateEmojiAutocomplete(1);
                } else if (e.key === 'ArrowUp') {
                    e.preventDefault();
                    this.navigateEmojiAutocomplete(-1);
                } else if (e.key === 'Enter' || e.key === 'Tab') {
                    e.preventDefault();
                    this.selectEmojiAutocomplete();
                } else if (e.key === 'Escape') {
                    e.preventDefault();
                    this.hideEmojiAutocomplete();
                }
            } else if (kaomojiAc && kaomojiAc.classList.contains('active')) {
                if (e.key === 'ArrowDown') {
                    e.preventDefault();
                    this.navigateKaomojiAutocomplete(1);
                } else if (e.key === 'ArrowUp') {
                    e.preventDefault();
                    this.navigateKaomojiAutocomplete(-1);
                } else if (e.key === 'Enter' || e.key === 'Tab') {
                    e.preventDefault();
                    this.selectKaomojiAutocomplete();
                } else if (e.key === 'Escape') {
                    e.preventDefault();
                    this.hideKaomojiAutocomplete();
                }
            } else if (commandPalette.classList.contains('active')) {
                if (e.key === 'ArrowDown') {
                    e.preventDefault();
                    this.navigateCommandPalette(1);
                } else if (e.key === 'ArrowUp') {
                    e.preventDefault();
                    this.navigateCommandPalette(-1);
                } else if (e.key === 'Enter' || e.key === 'Tab') {
                    e.preventDefault();
                    this.selectCommand();
                } else if (e.key === 'Escape') {
                    e.preventDefault();
                    this.hideCommandPalette();
                }
            } else {
                if (e.key === 'Enter' && !e.shiftKey) {
                    e.preventDefault();
                    this.sendMessage();
                } else if (e.key === 'Enter' && e.shiftKey) {
                    // contenteditable would insert a block element; insert a plain newline instead.
                    e.preventDefault();
                    this._insertTextAtCursor(input, '\n');
                } else if (e.key === 'Escape' && this.pendingEdit) {
                    e.preventDefault();
                    this.cancelEditMessage();
                } else if (e.key === 'Escape' && this.pendingQuote) {
                    e.preventDefault();
                    this.clearQuoteReply();
                } else if (e.key === 'Backspace' || e.key === 'Delete') {
                    // Hidden markers have no caret position, so delete the whole marker (nymRichMarkerDelete).
                    if (this._deleteRichMarker(input, e.key === 'Delete')) e.preventDefault();
                } else if (e.key === 'ArrowUp' && input.value === '') {
                    e.preventDefault();
                    this.navigateHistory(-1);
                } else if (e.key === 'ArrowDown' && input.value === '') {
                    e.preventDefault();
                    this.navigateHistory(1);
                }
            }
        });

        input.addEventListener('input', (e) => {
            // Drop browser filler nodes so :empty placeholder styling works.
            if (!e.target.value && e.target.innerHTML !== '') e.target.innerHTML = '';
            this._maybeRenderTypedEmoji(e.target);
            this._maybeRenderRichFormat(e.target);
            this.handleInputChange(e.target.value);
            this.autoResizeTextarea(e.target);
            this.updateTranslateInputBtn();
            if (e.target.value.trim().length > 0) {
                if (this.inPMMode) {
                    this.handleTypingSignal();
                } else if (this.currentGeohash) {
                    this.handleChannelTypingSignal();
                }
            }
        });

        document.getElementById('channelList').addEventListener('click', (e) => {
            if (e.target.closest('.row-menu-btn')) return;
            const channelItem = e.target.closest('.channel-item');
            if (channelItem && !e.target.closest('.pin-btn') && !e.target.closest('.hide-btn')) {
                e.preventDefault();
                e.stopPropagation();

                const channel = channelItem.dataset.channel;
                const geohash = channelItem.dataset.geohash || '';

                if (!nym.inPMMode &&
                    channel === nym.currentChannel &&
                    geohash === nym.currentGeohash) {
                    return;
                }

                // Debounce double-clicks.
                if (channelItem.dataset.clicking === 'true') return;
                channelItem.dataset.clicking = 'true';

                nym.switchChannel(channel, geohash);

                setTimeout(() => {
                    delete channelItem.dataset.clicking;
                }, 1000);
            }
        });

        document.addEventListener('click', (e) => {
            if (!e.target.closest('#commandPalette') && !e.target.closest('#messageInput')) {
                this.hideCommandPalette();
            }

            if (!e.target.closest('#emojiAutocomplete') && !e.target.closest('#messageInput')) {
                this.hideEmojiAutocomplete();
            }

            if (!e.target.closest('#kaomojiAutocomplete') && !e.target.closest('#messageInput')) {
                this.hideKaomojiAutocomplete();
            }

            if (!e.target.closest('#channelAutocomplete') && !e.target.closest('#messageInput')) {
                this.hideChannelAutocomplete();
            }

            if (!e.target.closest('#autocompleteDropdown') && !e.target.closest('#messageInput')) {
                this.hideAutocomplete();
            }

            if (!e.target.closest('.enhanced-emoji-modal') &&
                !e.target.closest('.reaction-btn') &&
                !e.target.closest('.add-reaction-btn') &&
                !e.target.closest('#emojiInputBtn') &&
                !e.target.closest('#ctxReact') &&
                !e.target.closest('.call-react-more') &&
                !e.target.closest('#swipeReactEmojiBtn')) {
                this.closeEnhancedEmojiModal();
            }

            if (!e.target.closest('.gif-picker') &&
                !e.target.closest('#emojiInputBtn')) {
                this.closeGifPicker();
            }

            if (!e.target.closest('.reactors-modal') &&
                !e.target.closest('.reaction-badge')) {
                this.closeReactorsModal();
            }
            if (!e.target.closest('.readers-modal') &&
                !e.target.closest('.group-readers') &&
                !e.target.closest('.channel-readers')) {
                this.closeReadersModal();
            }
            if (!e.target.closest('.timestamp-popup') &&
                !e.target.closest('.clickable-timestamp')) {
                if (typeof this.closeTimestampPopup === 'function') this.closeTimestampPopup();
            }

            const commandItem = e.target.closest('.command-item');
            if (commandItem && !commandItem.classList.contains('kaomoji-item')) {
                this.selectCommand(commandItem);
            }
        });

        // Anchored popups dismiss on scroll; capture phase catches inner containers too.
        document.addEventListener('scroll', () => {
            if (this.reactorsModal && typeof this.closeReactorsModal === 'function') this.closeReactorsModal();
            if (this.readersModal && typeof this.closeReadersModal === 'function') this.closeReadersModal();
            if (this._pollVotersModal && typeof this.closePollVotersModal === 'function') this.closePollVotersModal();
        }, { passive: true, capture: true });

        document.getElementById('fileInput').addEventListener('change', (e) => {
            if (e.target.files && e.target.files.length) {
                this.uploadImage(Array.from(e.target.files));
                e.target.value = '';
            }
        });

        document.getElementById('messageInput').addEventListener('paste', (e) => {
            const items = e.clipboardData && e.clipboardData.items;
            if (items) {
                const mediaFiles = [];
                for (const item of items) {
                    if (item.type.startsWith('image/') || item.type.startsWith('video/')) {
                        const file = item.getAsFile();
                        if (file) mediaFiles.push(file);
                    }
                }
                if (mediaFiles.length) {
                    e.preventDefault();
                    this.uploadImage(mediaFiles);
                    return;
                }
            }
            // Plain-text paste so the contenteditable never accumulates foreign HTML.
            const text = e.clipboardData && e.clipboardData.getData('text/plain');
            if (text) {
                e.preventDefault();
                this._insertTextAtCursor(e.currentTarget, text);
            }
        });

        document.getElementById('p2pFileInput').addEventListener('change', (e) => {
            if (e.target.files && e.target.files[0]) {
                const file = e.target.files[0];
                if (typeof this.sendFileOverMesh === 'function' && typeof this._mediaRoute === 'function' && this._mediaRoute() === 'mesh') {
                    this.sendFileOverMesh(file);
                } else if (file.name.endsWith('.torrent') || file.type === 'application/x-bittorrent') {
                    this.shareP2PFileTorrent(file);
                } else {
                    this.shareP2PFile(file);
                }
                e.target.value = '';
            }
        });

        // Long-press Send (2s) for pseudonymous send (Nostr login users only).
        const sendBtn = document.getElementById('sendBtn');
        let sendLongPressTimer = null;
        let sendLongPressFired = false;
        let sendSuppressClickUntil = 0;

        const startSendLongPress = (e) => {
            if (e && e.type === 'mousedown' && e.button !== 0) return;
            if (sendLongPressTimer) return;
            sendLongPressFired = false;
            sendLongPressTimer = setTimeout(() => {
                sendLongPressTimer = null;
                if (this.nostrLoginMethod) {
                    sendLongPressFired = true;
                    sendSuppressClickUntil = Date.now() + 800;
                    window.nymHapticTap && window.nymHapticTap();
                    sendBtn.style.boxShadow = '0 0 15px rgb(from var(--primary) r g b / 0.4)';
                    sendBtn.textContent = 'ANON';
                    this.sendMessagePseudonymous();
                    setTimeout(() => {
                        sendBtn.textContent = 'SEND';
                        sendBtn.style.boxShadow = '';
                        sendLongPressFired = false;
                    }, 1000);
                }
            }, 2000);
            if (this.nostrLoginMethod) {
                setTimeout(() => {
                    if (sendLongPressTimer) {
                        sendBtn.style.transition = 'box-shadow 0.3s ease';
                        sendBtn.style.boxShadow = '0 0 10px rgb(from var(--primary) r g b / 0.2)';
                    }
                }, 700);
            }
        };

        const cancelSendLongPress = (e) => {
            if (sendLongPressTimer) {
                clearTimeout(sendLongPressTimer);
                sendLongPressTimer = null;
                sendBtn.style.boxShadow = '';
            }
            if (sendLongPressFired && e && e.cancelable) {
                e.preventDefault();
                e.stopPropagation();
            }
        };

        sendBtn.addEventListener('click', (e) => {
            if (sendLongPressFired || Date.now() < sendSuppressClickUntil) {
                e.preventDefault();
                e.stopPropagation();
                return;
            }
            sendMessage();
        });
        sendBtn.addEventListener('mousedown', startSendLongPress);
        sendBtn.addEventListener('touchstart', startSendLongPress, { passive: false });
        sendBtn.addEventListener('mouseup', cancelSendLongPress);
        sendBtn.addEventListener('mouseleave', cancelSendLongPress);
        sendBtn.addEventListener('touchend', cancelSendLongPress);
        sendBtn.addEventListener('touchcancel', cancelSendLongPress);
        sendBtn.addEventListener('contextmenu', (e) => { e.preventDefault(); e.stopPropagation(); });

        // Bound to .main-content to cover single view and every column; modals live outside it.
        const messagesEl = document.querySelector('.main-content') || document.getElementById('messagesContainer');
        const _dimScroller = (el) => el && el.closest('.messages-container');
        let msgLongPressTimer = null;
        let msgLongPressFired = false;

        const showQuickReactPopup = (msgEl, e) => {
            msgLongPressFired = true;
            window._nymMediaClickSuppressUntil = Date.now() + 800;
            const messageId = msgEl.dataset.messageId;
            if (!messageId) return;
            window.nymHapticTap && window.nymHapticTap();

            const defaultEmojis = ['👍', '❤️', '😂', '🔥', '👎', '😮'];
            let quickEmojis = [];

            if (this.recentEmojis.length >= 6) {
                quickEmojis = this.recentEmojis.slice(0, 6);
            } else if (this.recentEmojis.length > 0) {
                quickEmojis = [...this.recentEmojis];
                for (const emoji of defaultEmojis) {
                    if (quickEmojis.length >= 6) break;
                    if (!quickEmojis.includes(emoji)) {
                        quickEmojis.push(emoji);
                    }
                }
            } else {
                quickEmojis = defaultEmojis.slice(0, 6);
            }

            document.querySelectorAll('.quick-react-popup, .quick-context-menu').forEach(el => el.remove());

            document.querySelectorAll('.messages-container.has-long-press-highlight').forEach(el => el.classList.remove('has-long-press-highlight'));
            document.querySelectorAll('.message.long-press-highlight').forEach(el => el.classList.remove('long-press-highlight'));
            const _dimEl = _dimScroller(msgEl);
            if (_dimEl) _dimEl.classList.add('has-long-press-highlight');
            msgEl.classList.add('long-press-highlight');

            const popup = document.createElement('div');
            popup.className = 'quick-react-popup';

            popup.innerHTML = quickEmojis.map(emoji => {
                const cm = typeof emoji === 'string' && emoji.match(/^:([a-zA-Z0-9_]+):$/);
                if (cm && this.customEmojis && this.customEmojis.has(cm[1])) {
                    return `<button class="quick-react-emoji" data-emoji=":${this.escapeHtml(cm[1])}:">${this.renderCustomEmojiImg(cm[1])}</button>`;
                }
                return `<button class="quick-react-emoji" data-emoji="${this.escapeHtml(emoji)}">${this.escapeHtml(emoji)}</button>`;
            }).join('') +
                `<button class="quick-react-expand" title="More reactions">
                    <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                        <path d="M4 6 L8 10 L12 6"/>
                    </svg>
                </button>`;

            const msgRect = msgEl.getBoundingClientRect();
            popup.style.position = 'fixed';

            const clientX = e.clientX || (e.touches && e.touches[0] ? e.touches[0].clientX : msgRect.left + msgRect.width / 2);
            const clientY = e.clientY || (e.touches && e.touches[0] ? e.touches[0].clientY : msgRect.top);

            // Append offscreen first to measure its rendered size.
            popup.style.position = 'fixed';
            popup.style.visibility = 'hidden';
            document.body.appendChild(popup);
            const actualPopupWidth = popup.offsetWidth;
            const actualPopupHeight = popup.offsetHeight;
            popup.style.visibility = '';

            let left = clientX - actualPopupWidth / 2;
            left = Math.max(10, Math.min(left, window.innerWidth - actualPopupWidth - 10));
            let top = clientY - 55;
            top = Math.max(10, top);

            popup.style.left = left + 'px';
            popup.style.top = top + 'px';

            const targetPubkey = msgEl.dataset.pubkey || '';
            const baseAuthor = this.resolveDisplayNym(targetPubkey, msgEl.dataset.author || '');
            const targetBaseNym = this.stripPubkeySuffix(baseAuthor);
            const contentEl = msgEl.querySelector('.message-content');
            const messageContent = msgEl.dataset.rawContent
                || (contentEl ? this._extractNonQuotedText(contentEl) : '');
            const isSelf = targetPubkey === this.pubkey;

            const ctxItems = [];
            if (!isSelf && targetPubkey) {
                ctxItems.push({
                    id: 'qctxSlap',
                    label: 'Slap with Trout',
                    svg: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3"><path d="M 1 8 Q 3 4 8 4 Q 11 4 13 6 L 15 4.5 L 15 11.5 L 13 10 Q 11 12 8 12 Q 3 12 1 8 Z" /><circle cx="5" cy="7.5" r="0.7" fill="currentColor" stroke="none" /><path d="M 9 6.5 Q 10 8 9 9.5" stroke-linecap="round" /></svg>',
                    action: () => { this.cmdSlap(targetPubkey); }
                });
                ctxItems.push({
                    id: 'qctxHug',
                    label: 'Give warm Hug',
                    svg: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="6" cy="5" r="2" /><circle cx="10" cy="5" r="2" /><path d="M 2 14 C 2 10 4 9 6 9 C 7 9 7.5 9.5 8 10 C 8.5 9.5 9 9 10 9 C 12 9 14 10 14 14" stroke-linecap="round" stroke-linejoin="round" /><path d="M 4 11.5 Q 8 9 12 11.5" stroke-linecap="round" /></svg>',
                    action: () => { this.cmdHug(targetPubkey); }
                });
            }
            if (!isSelf && messageId && targetPubkey) {
                ctxItems.push({
                    id: 'qctxZap',
                    label: 'Zap Bitcoin',
                    cls: 'lightning',
                    svg: '<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M 9 2 L 4 9 H 7 L 7 14 L 12 7 H 9 Z" /></svg>',
                    action: async () => {
                        this.displaySystemMessage(`Checking if @${targetBaseNym} can receive zaps...`);
                        try {
                            const lnAddress = await this.fetchLightningAddressForUser(targetPubkey);
                            if (lnAddress) {
                                this.showZapModal(messageId, targetPubkey, targetBaseNym);
                            } else {
                                this.displaySystemMessage(`@${targetBaseNym} cannot receive zaps (no lightning address set)`);
                            }
                        } catch (error) {
                            this.displaySystemMessage(`Failed to check if @${targetBaseNym} can receive zaps`);
                        }
                    }
                });
            }
            if (messageId && this.threadsEnabled && this.threadsEnabled() && !msgEl.closest('.thread-view-active')) {
                ctxItems.push({
                    id: 'qctxThread',
                    label: 'Reply in Thread',
                    svg: '<svg width="16" height="16" viewBox="0 0 20 20"><path fill="currentColor" fill-rule="evenodd" d="M10 3a7 7 0 1 0 3.394 13.124.75.75 0 0 1 .542-.074l2.794.68-.68-2.794a.75.75 0 0 1 .073-.542A7 7 0 0 0 10 3m-8.5 7a8.5 8.5 0 1 1 16.075 3.859l.904 3.714a.75.75 0 0 1-.906.906l-3.714-.904A8.5 8.5 0 0 1 1.5 10M6 8.25a.75.75 0 0 1 .75-.75h6.5a.75.75 0 0 1 0 1.5h-6.5A.75.75 0 0 1 6 8.25M6.75 11a.75.75 0 0 0 0 1.5h4.5a.75.75 0 0 0 0-1.5z" clip-rule="evenodd"></path></svg>',
                    action: () => { this.openMessageThread(msgEl); }
                });
            }
            if (messageContent) {
                ctxItems.push({
                    id: 'qctxQuote',
                    label: 'Quote Message',
                    svg: '<svg width="16" height="16" viewBox="0 0 16 16" fill="currentColor"><path d="M 3 6 C 3 4.5 4 3 6 3 C 6 4.5 5 5 4 5.5 C 3.5 5.8 3 6.3 3 7 L 3 9 L 6 9 L 6 6 Z" /><path d="M 9 6 C 9 4.5 10 3 12 3 C 12 4.5 11 5 10 5.5 C 9.5 5.8 9 6.3 9 7 L 9 9 L 12 9 L 12 6 Z" /></svg>',
                    action: () => {
                        const suffix = this.getPubkeySuffix(targetPubkey);
                        const fullNym = `${targetBaseNym}#${suffix}`;
                        this.setQuoteReply(fullNym, messageContent);
                    }
                });
                ctxItems.push({
                    id: 'qctxCopy',
                    label: 'Copy Message',
                    svg: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="5" y="5" width="8" height="9" rx="1" /><path d="M 3 10 L 3 4 C 3 3.45 3.45 3 4 3 L 9 3" stroke-linecap="round" /></svg>',
                    action: async () => {
                        try {
                            await navigator.clipboard.writeText(messageContent);
                            this.displaySystemMessage('Message copied to clipboard');
                        } catch (err) {
                            this.displaySystemMessage('Failed to copy message');
                        }
                    }
                });
                ctxItems.push({
                    id: 'qctxTranslate',
                    label: 'Translate Message',
                    svg: '<svg width="16" height="16" viewBox="0 0 24 24" fill="currentColor"><path d="m12.87 15.07-2.54-2.51.03-.03A17.52 17.52 0 0 0 14.07 6H17V4h-7V2H8v2H1v1.99h11.17C11.5 7.92 10.44 9.75 9 11.35 8.07 10.32 7.3 9.19 6.69 8h-2c.73 1.63 1.73 3.17 2.98 4.56l-5.09 5.02L4 19l5-5 3.11 3.11.76-2.04zM18.5 10h-2L12 22h2l1.12-3h4.75L21 22h2l-4.5-12zm-2.62 7 1.62-4.33L19.12 17h-3.24z"/></svg>',
                    action: () => {
                        this.translateMessage(messageContent, messageId);
                    }
                });
            }
            if (isSelf && messageId && messageContent) {
                ctxItems.push({
                    id: 'qctxEdit',
                    label: 'Edit Message',
                    svg: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M 11.5 2.5 L 13.5 4.5 L 5 13 L 2 14 L 3 11 Z" stroke-linejoin="round" /><path d="M 10 4 L 12 6" stroke-linecap="round" /></svg>',
                    action: () => {
                        this.startEditMessage({ messageId, content: messageContent, pubkey: targetPubkey });
                    }
                });
            }
            if (isSelf && messageId) {
                ctxItems.push({
                    id: 'qctxDelete',
                    label: 'Delete Message',
                    cls: 'danger',
                    svg: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><path d="M 3 5 L 13 5" stroke-linecap="round" /><path d="M 5 5 L 5 13 C 5 13.55 5.45 14 6 14 L 10 14 C 10.55 14 11 13.55 11 13 L 11 5" stroke-linejoin="round" /><path d="M 6.5 2 L 9.5 2" stroke-linecap="round" /><path d="M 7 7 L 7 11.5" stroke-linecap="round" /><path d="M 9 7 L 9 11.5" stroke-linecap="round" /></svg>',
                    action: async () => {
                        if (!(await window.showAppConfirm('Are you sure you want to delete this message? This will send a deletion request to relays.', { danger: true, okLabel: 'Delete' }))) return;
                        this.publishDeletionEvent(messageId, this.inPMMode ? 1059 : this.channelWire(this.currentGeohash).kind).then(() => {
                            this.displaySystemMessage('Deletion request sent to relays');
                        });
                    }
                });
            }

            if (!isSelf && targetPubkey) {
                ctxItems.push({
                    id: 'qctxReport',
                    label: 'Report',
                    cls: 'report',
                    svg: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="8" cy="8" r="6" /><path d="M 8 5 L 8 8.5" stroke-linecap="round" stroke-width="2" /><circle cx="8" cy="10.5" r="0.8" fill="currentColor" stroke="none" /></svg>',
                    action: () => {
                        this.contextMenuData = {
                            nym: targetBaseNym,
                            pubkey: targetPubkey,
                            content: messageContent,
                            messageId,
                            reactionId: messageId
                        };
                        this.openReportModal();
                    }
                });
                ctxItems.push({
                    id: 'qctxBlock',
                    label: this.blockedUsers.has(targetPubkey) ? 'Unblock User' : 'Block User',
                    cls: 'danger',
                    svg: '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="8" cy="8" r="6" /><line x1="3.75" y1="3.75" x2="12.25" y2="12.25" stroke-width="1.5" stroke-linecap="round" /></svg>',
                    action: () => { this.cmdBlock(targetPubkey); }
                });
            }

            let quickCtxMenu = null;
            if (ctxItems.length > 0) {
                quickCtxMenu = document.createElement('div');
                quickCtxMenu.className = 'quick-context-menu';
                quickCtxMenu.innerHTML = ctxItems.map(item =>
                    `<button class="quick-context-item${item.cls ? ' ' + item.cls : ''}" data-qctx-id="${item.id}">${item.svg}<span>${item.label}</span></button>`
                ).join('');

                quickCtxMenu.style.position = 'fixed';
                quickCtxMenu.style.visibility = 'hidden';
                document.body.appendChild(quickCtxMenu);
                const ctxMenuWidth = quickCtxMenu.offsetWidth;
                const ctxMenuHeight = quickCtxMenu.offsetHeight;
                quickCtxMenu.style.visibility = '';

                let ctxLeft = clientX - ctxMenuWidth / 2;
                ctxLeft = Math.max(10, Math.min(ctxLeft, window.innerWidth - ctxMenuWidth - 10));
                let ctxTop = top + actualPopupHeight + 8;
                if (ctxTop + ctxMenuHeight > window.innerHeight - 10) {
                    ctxTop = Math.max(10, top - ctxMenuHeight - 8);
                }
                quickCtxMenu.style.left = ctxLeft + 'px';
                quickCtxMenu.style.top = ctxTop + 'px';
            }

            requestAnimationFrame(() => {
                popup.classList.add('active');
                if (quickCtxMenu) quickCtxMenu.classList.add('active');
            });

            const cleanupHighlight = () => {
                document.querySelectorAll('.messages-container.has-long-press-highlight').forEach(el => el.classList.remove('has-long-press-highlight'));
                msgEl.classList.remove('long-press-highlight');
            };

            const closeAll = () => {
                popup.remove();
                if (quickCtxMenu) quickCtxMenu.remove();
                cleanupHighlight();
            };

            if (quickCtxMenu) {
                quickCtxMenu.addEventListener('click', (ev) => {
                    ev.stopPropagation();
                    const btn = ev.target.closest('.quick-context-item');
                    if (!btn) return;
                    const item = ctxItems.find(i => i.id === btn.dataset.qctxId);
                    if (!item) return;
                    closeAll();
                    removeCloseListeners();
                    item.action();
                });
                quickCtxMenu.querySelectorAll('.quick-context-item').forEach(btn => {
                    btn.addEventListener('touchend', (ev) => {
                        ev.preventDefault();
                        ev.stopPropagation();
                        const item = ctxItems.find(i => i.id === btn.dataset.qctxId);
                        if (!item) return;
                        closeAll();
                        removeCloseListeners();
                        item.action();
                    });
                });
            }

            const expandBtn = popup.querySelector('.quick-react-expand');
            const openFullPicker = (ev) => {
                ev.preventDefault();
                ev.stopPropagation();
                const popupLeft = popup.style.left;
                const popupTop = popup.style.top;
                closeAll();
                removeCloseListeners();

                const tempButton = document.createElement('button');
                tempButton.style.position = 'fixed';
                tempButton.style.left = popupLeft;
                tempButton.style.top = popupTop;
                tempButton.style.opacity = '0';
                tempButton.style.pointerEvents = 'none';
                document.body.appendChild(tempButton);

                this.showEnhancedReactionPicker(messageId, tempButton);
                setTimeout(() => tempButton.remove(), 100);
            };
            expandBtn.addEventListener('click', openFullPicker);
            expandBtn.addEventListener('touchend', openFullPicker);

            popup.addEventListener('click', async (ev) => {
                ev.stopPropagation();
                const btn = ev.target.closest('.quick-react-emoji');
                if (!btn) return;
                const emoji = btn.dataset.emoji;
                closeAll();
                removeCloseListeners();
                await this.sendReaction(messageId, emoji);
                this.addToRecentEmojis(emoji);
            });

            popup.querySelectorAll('.quick-react-emoji').forEach(btn => {
                btn.addEventListener('touchend', async (ev) => {
                    ev.preventDefault();
                    ev.stopPropagation();
                    const emoji = btn.dataset.emoji;
                    closeAll();
                    removeCloseListeners();
                    await this.sendReaction(messageId, emoji);
                    this.addToRecentEmojis(emoji);
                });
            });

            // Ignore closes within 400ms of opening; they come from the opening long-press gesture.
            const openedAt = Date.now();
            const closePopup = (ev) => {
                if (popup.contains(ev.target)) return;
                if (quickCtxMenu && quickCtxMenu.contains(ev.target)) return;
                if (Date.now() - openedAt < 400) return;
                closeAll();
                removeCloseListeners();
            };
            const closeOnScroll = () => {
                if (Date.now() - openedAt < 400) return;
                closeAll();
                removeCloseListeners();
            };
            const removeCloseListeners = () => {
                document.removeEventListener('mousedown', closePopup);
                document.removeEventListener('touchstart', closePopup);
                document.removeEventListener('scroll', closeOnScroll, { capture: true });
            };
            // Close on the start of a new gesture, not the end of the opening one.
            document.addEventListener('mousedown', closePopup);
            document.addEventListener('touchstart', closePopup);
            document.addEventListener('scroll', closeOnScroll, { passive: true, capture: true });
        };

        let msgLongPressStartX = 0;
        let msgLongPressStartY = 0;
        const MSG_LONG_PRESS_MOVE_THRESHOLD = 5;

        messagesEl.addEventListener('mousedown', (e) => {
            // Primary button only.
            if (e.button !== 0) return;
            if (e.target.closest('.reaction-badge, .add-reaction-btn, .reaction-btn, .quick-react-popup, .group-readers, .group-reader-avatar, .group-reader-overflow')) return;
            const msgEl = e.target.closest('.message[data-message-id]');
            if (!msgEl) return;
            msgLongPressFired = false;
            msgLongPressStartX = e.clientX;
            msgLongPressStartY = e.clientY;
            msgLongPressTimer = setTimeout(() => {
                showQuickReactPopup(msgEl, e);
            }, 500);
        });

        messagesEl.addEventListener('touchstart', (e) => {
            if (e.target.closest('.reaction-badge, .add-reaction-btn, .reaction-btn, .quick-react-popup, .group-readers, .group-reader-avatar, .group-reader-overflow')) return;
            const msgEl = e.target.closest('.message[data-message-id]');
            if (!msgEl) return;
            msgLongPressFired = false;
            const t = e.touches && e.touches[0];
            if (t) {
                msgLongPressStartX = t.clientX;
                msgLongPressStartY = t.clientY;
            }
            msgLongPressTimer = setTimeout(() => {
                showQuickReactPopup(msgEl, e);
            }, 500);
        }, { passive: true });

        const cancelMsgLongPress = () => {
            if (msgLongPressTimer) {
                clearTimeout(msgLongPressTimer);
                msgLongPressTimer = null;
            }
        };

        messagesEl.addEventListener('mousemove', (e) => {
            if (!msgLongPressTimer) return;
            const dx = e.clientX - msgLongPressStartX;
            const dy = e.clientY - msgLongPressStartY;
            if (dx * dx + dy * dy > MSG_LONG_PRESS_MOVE_THRESHOLD * MSG_LONG_PRESS_MOVE_THRESHOLD) {
                cancelMsgLongPress();
            }
        });
        messagesEl.addEventListener('touchmove', cancelMsgLongPress, { passive: true });
        messagesEl.addEventListener('mouseup', cancelMsgLongPress);
        messagesEl.addEventListener('mouseleave', cancelMsgLongPress);
        messagesEl.addEventListener('touchend', (e) => {
            cancelMsgLongPress();
            if (msgLongPressFired) {
                e.preventDefault();
                msgLongPressFired = false;
            }
        });
        messagesEl.addEventListener('touchcancel', cancelMsgLongPress);

    },

    handleInputChange(value) {
        const inputEl = document.getElementById('messageInput');
        const cursor = (inputEl && typeof inputEl.selectionStart === 'number')
            ? inputEl.selectionStart
            : value.length;
        const before = value.substring(0, cursor);

        const mentionMatch = before.match(/(?:^|\s)@([^\s]*)$/);
        const isMentionActive = mentionMatch !== null;

        const hashMatch = before.match(/(?:^|\s)#([^\s]*)$/);
        const isChannelActive = hashMatch !== null;

        const kaomojiMatch = before.match(/(?:^|\s)\\([a-z]*)$/i);

        if (isMentionActive) {
            const search = mentionMatch[1];
            this.showAutocomplete(search);
            this.hideEmojiAutocomplete();
            this.hideChannelAutocomplete();
            this.hideKaomojiAutocomplete();
        } else if (isChannelActive) {
            const search = hashMatch[1];
            this.showChannelAutocomplete(search);
            this.hideAutocomplete();
            this.hideEmojiAutocomplete();
            this.hideKaomojiAutocomplete();
        } else if (kaomojiMatch) {
            this.showKaomojiAutocomplete(kaomojiMatch[1]);
            this.hideAutocomplete();
            this.hideChannelAutocomplete();
            this.hideEmojiAutocomplete();
        } else {
            this.hideAutocomplete();
            this.hideChannelAutocomplete();
            this.hideKaomojiAutocomplete();

            // Match a :shortcode token left of the cursor so it works mid-sentence.
            const emojiMatch = before.match(/(?:^|\s):([a-z0-9_+-]*)$/i);
            if (emojiMatch) {
                this.showEmojiAutocomplete(emojiMatch[1]);
            } else {
                this.hideEmojiAutocomplete();
            }
        }

        if (value.startsWith('/')) {
            this.showCommandPalette(value);
        } else if (value.startsWith('?')) {
            this.showBotCommandPalette(value);
        } else {
            this.hideCommandPalette();
        }
    },

    autoResizeTextarea(textarea) {
        if (!textarea || !textarea.style) return;
        const container = textarea.closest('.input-container');
        const cs = getComputedStyle(textarea);
        const padV = parseFloat(cs.paddingTop) + parseFloat(cs.paddingBottom);
        const borderV = parseFloat(cs.borderTopWidth) + parseFloat(cs.borderBottomWidth);
        let lh = parseFloat(cs.lineHeight);
        if (!lh) lh = parseFloat(cs.fontSize) * 1.4;
        textarea.style.height = 'auto';
        const prevMin = textarea.style.minHeight;
        textarea.style.minHeight = '0px';
        const contentH = textarea.scrollHeight;
        textarea.style.minHeight = prevMin;
        const expand = (contentH - padV) > lh * 1.5;
        this._composerRowBase = Math.max(parseFloat(cs.minHeight) || 0, Math.ceil(lh)) + padV + borderV;
        if (container) container.classList.toggle('composer-popout', expand);
        textarea.style.height = '';
        this._refreshComposerOffsets();
        // Every draft mutation ends up here, so it's the hook the attachment strip needs (rich-compose.js).
        if (textarea.id === 'messageInput') {
            if (typeof this.updateComposerMediaPreviews === 'function') this.updateComposerMediaPreviews();
        }
    },

    _syncComposerDock(wrapper) {
        if (!wrapper) return;
        const docked = [...wrapper.querySelectorAll('[data-composer-dock]')].some((el) => el.offsetHeight > 0);
        if (wrapper.classList.contains('composer-docked') !== docked) wrapper.classList.toggle('composer-docked', docked);
    },

    _watchComposerDock(input) {
        const wrapper = input && input.closest('.input-wrapper');
        if (!wrapper || wrapper._dockObserver || typeof MutationObserver === 'undefined') return;
        wrapper._dockObserver = new MutationObserver(() => this._syncComposerDock(wrapper));
        wrapper._dockObserver.observe(wrapper, { subtree: true, childList: true, attributes: true, attributeFilter: ['class', 'hidden', 'style'] });
        this._syncComposerDock(wrapper);
    },

    _refreshComposerOffsets() {
        const input = document.getElementById('messageInput');
        const wrapper = input && input.closest('.input-wrapper');
        const container = input && input.closest('.input-container');
        if (!wrapper) return;
        const base = this._composerRowBase || 64;
        wrapper.style.setProperty('--composer-row-base', base + 'px');
        const expanded = !!(container && container.classList.contains('composer-popout'));
        const overhang = expanded ? Math.max(0, input.offsetHeight - base) : 0;
        wrapper.style.setProperty('--popout-overhang', overhang + 'px');
        // The toolbar/attachment stack sits between the field and the chips, so `bottom:100%` anchors must clear it.
        const panels = document.getElementById('composerPanels');
        const panelsH = (panels && panels.offsetHeight > 0) ? panels.offsetHeight + 8 : 0;
        wrapper.style.setProperty('--composer-panels-h', panelsH + 'px');
        // The upload panel sits in the same stack, so it clears the panels and is cleared by what's above.
        const up = document.getElementById('uploadProgress');
        const uploadH = (up && up.offsetHeight > 0) ? up.offsetHeight + 8 : 0;
        wrapper.style.setProperty('--composer-upload-h', uploadH + 'px');
        const ep = document.getElementById('editPreview');
        const qp = document.getElementById('quotePreview');
        const preview = (ep && ep.offsetHeight > 0) ? ep : ((qp && qp.offsetHeight > 0) ? qp : null);
        const previewH = preview ? preview.offsetHeight : 0;
        wrapper.style.setProperty('--ac-offset',
            (overhang + panelsH + uploadH + (previewH ? previewH + 8 : 0)) + 'px');
    },

    _renderContextMenuPubkey(pubkey) {
        const el = document.getElementById('ctxFullPubkey');
        const copyLabel = document.getElementById('ctxCopyPubkeyLabel');
        const toggle = document.getElementById('ctxTogglePubkeyFormat');
        const toggleLabel = document.getElementById('ctxTogglePubkeyFormatLabel');
        const isNpub = this.getPubkeyDisplayFormat() === 'npub';
        if (copyLabel) copyLabel.textContent = isNpub ? 'Copy npub' : 'Copy hex pubkey';
        if (toggleLabel) toggleLabel.textContent = isNpub ? 'Show hex' : 'Show npub';
        if (toggle) toggle.style.display = pubkey ? '' : 'none';
        if (!el) return;
        if (!pubkey) {
            el.textContent = '';
            el.style.display = 'none';
            return;
        }
        el.textContent = this.formatPubkeyForDisplay(pubkey);
        el.style.display = '';
    },

    // Keep the nick-edit slide-out in step with the context menu's format choice.
    _refreshPubkeySlideoutFormat() {
        const value = document.getElementById('pubkeySlideoutValue');
        const label = document.getElementById('pubkeySlideoutLabel');
        // The label, not the button: the button carries a swap icon beside it.
        const formatLabel = document.getElementById('pubkeySlideoutFormatLabel');
        const copyBtn = document.getElementById('pubkeySlideoutCopy');
        const isNpub = this.getPubkeyDisplayFormat() === 'npub';
        if (label) label.textContent = isNpub ? 'Full Public Key (npub)' : 'Full Public Key (hex)';
        if (formatLabel) formatLabel.textContent = isNpub ? 'Show hex' : 'Show npub';
        if (copyBtn) copyBtn.textContent = isNpub ? 'Copy npub' : 'Copy hex pubkey';
        if (value && this.pubkey) value.textContent = this.formatPubkeyForDisplay(this.pubkey);
    },

    _emojiTokenForImg(img) {
        const code = img.dataset && img.dataset.emojiCode;
        return code ? ':' + code + ':' : (img.getAttribute('alt') || '');
    },

    // Atomic nodes (emoji <img>, mention chip) count as one unit in the caret/length math; null otherwise.
    _richAtomicToken(node) {
        if (!node || node.nodeType !== Node.ELEMENT_NODE) return null;
        if (node.tagName === 'IMG') return this._emojiTokenForImg(node);
        if (node.dataset && typeof node.dataset.mention === 'string') return node.dataset.mention;
        // Hidden markers still stand for their delimiter so the draft round-trips and offsets stay aligned.
        if (node.dataset && typeof node.dataset.mark === 'string') return node.dataset.mark;
        return null;
    },

    // Serializes back to its data-mention text ("@base#suffix") when the message is read for sending.
    _buildInputMentionChip(base, sfx, pubkey, rawText) {
        const span = document.createElement('span');
        span.className = 'input-mention';
        span.setAttribute('contenteditable', 'false');
        span.dataset.mention = rawText;
        const img = document.createElement('img');
        img.className = 'avatar-message';
        img.src = this.getAvatarUrl(pubkey);
        img.setAttribute('data-avatar-pubkey', this._safePubkey(pubkey) || '');
        img.alt = '';
        img.draggable = false;
        span.appendChild(img);
        span.appendChild(document.createTextNode('@' + base));
        const sfxSpan = document.createElement('span');
        sfxSpan.className = 'nym-suffix';
        sfxSpan.textContent = '#' + sfx;
        span.appendChild(sfxSpan);
        const flairHtml = this.getFlairForUser(pubkey) || '';
        if (flairHtml) {
            const tmpl = document.createElement('template');
            tmpl.innerHTML = flairHtml;
            span.appendChild(tmpl.content);
        }
        return span;
    },

    _serializeRichInput(root) {
        let out = '';
        const nodes = root.childNodes;
        for (let i = 0; i < nodes.length; i++) {
            const node = nodes[i];
            if (node.nodeType === Node.TEXT_NODE) {
                out += node.nodeValue;
            } else if (node.nodeType === Node.ELEMENT_NODE) {
                const atomTok = this._richAtomicToken(node);
                if (atomTok != null) {
                    out += atomTok;
                } else if (node.tagName === 'BR') {
                    // A lone trailing <br> is browser filler; ignore it.
                    if (i !== nodes.length - 1) out += '\n';
                } else {
                    out += this._serializeRichInput(node);
                }
            }
        }
        return out;
    },

    _richNodeLength(node) {
        if (node.nodeType === Node.TEXT_NODE) return node.nodeValue.length;
        if (node.nodeType === Node.ELEMENT_NODE) {
            const atomTok = this._richAtomicToken(node);
            if (atomTok != null) return atomTok.length;
            if (node.tagName === 'BR') return 1;
        }
        let n = 0;
        const kids = node.childNodes;
        if (kids) for (let i = 0; i < kids.length; i++) n += this._richNodeLength(kids[i]);
        return n;
    },

    // Emoji shortcodes and mentions become chips; everything else stays plain so the caret model matches.
    _renderRichPlain(text, frag) {
        const pushText = (s) => { if (s) frag.appendChild(document.createTextNode(s)); };
        const re = /:([a-zA-Z0-9_]+):|@([^\s@#]+)#([0-9a-f]{4})/gi;
        let last = 0, m;
        while ((m = re.exec(text)) !== null) {
            if (m[1] !== undefined) {
                const code = m[1];
                const url = this.customEmojis && this.customEmojis.get(code);
                if (!url) continue;
                pushText(text.slice(last, m.index));
                const img = document.createElement('img');
                img.className = 'custom-emoji';
                img.src = this.getProxiedEmojiUrl(url);
                img.alt = ':' + code + ':';
                img.title = ':' + code + ':';
                img.dataset.emojiCode = code;
                img.draggable = false;
                frag.appendChild(img);
                last = re.lastIndex;
            } else if (m[2] !== undefined) {
                const base = m[2];
                const sfx = m[3].toLowerCase();
                const pubkey = this._pubkeyForSuffix ? this._pubkeyForSuffix(sfx) : null;
                if (!pubkey) continue; // Unknown user — leave the mention as plain text
                pushText(text.slice(last, m.index));
                frag.appendChild(this._buildInputMentionChip(base, sfx, pubkey, m[0]));
                last = re.lastIndex;
            }
        }
        pushText(text.slice(last));
    },

    // Inline construct: its whole span; heading/quote: the line prefix; fenced block: the two fences.
    _richIsRevealed(node, sel) {
        if (!sel || !node.reveal) return false;
        const s = Math.min(sel.start, sel.end), e = Math.max(sel.start, sel.end);
        for (let i = 0; i < node.reveal.length; i++) {
            const r = node.reveal[i];
            if (e >= r[0] && s <= r[1]) return true;
        }
        return false;
    },

    // Hidden and revealed spellings have the same model length, so toggling never moves the caret.
    _richMarkNode(src, shown) {
        const span = document.createElement('span');
        span.className = shown ? 'rich-mark rich-mark-shown' : 'rich-mark';
        if (shown) span.textContent = src;
        else span.dataset.mark = src;
        return span;
    },

    _renderRichNodes(nodes, text, parent, sel) {
        for (let i = 0; i < nodes.length; i++) {
            const n = nodes[i];
            if (n.kind === 'text') {
                this._renderRichPlain(text.slice(n.start, n.end), parent);
                continue;
            }
            const shown = this._richIsRevealed(n, sel);
            const wrap = document.createElement('span');
            wrap.className = 'rich-md rich-md-' + n.type
                + (shown ? ' rich-md-open' : '')
                + (n.emptyBody ? ' rich-md-blank' : '');
            if (n.label) wrap.dataset.label = n.label;
            if (n.open) wrap.appendChild(this._richMarkNode(n.open, shown));
            this._renderRichNodes(n.children || [], text, wrap, sel);
            if (n.close) wrap.appendChild(this._richMarkNode(n.close, shown));
            parent.appendChild(wrap);
        }
    },

    // Omits offsets on purpose so ordinary keystrokes don't re-render the field.
    _richTreeSig(nodes, sel) {
        let out = '';
        for (let i = 0; i < nodes.length; i++) {
            const n = nodes[i];
            if (n.kind === 'text') { out += '.'; continue; }
            out += n.type + (this._richIsRevealed(n, sel) ? '!' : '')
                + '(' + this._richTreeSig(n.children || [], sel) + ')';
        }
        return out;
    },

    _renderRichInput(el, text, sel) {
        el.textContent = '';
        el._richFormatSig = '';
        if (!text) return;
        let tree = null;
        if (typeof this._richParseFormat === 'function') {
            try { tree = this._richParseFormat(text); } catch (_) { tree = null; }
        }
        const frag = document.createDocumentFragment();
        if (tree) {
            this._renderRichNodes(tree, text, frag, sel);
            el._richFormatSig = this._richTreeSig(tree, sel);
        } else {
            this._renderRichPlain(text, frag);
        }
        this._richPadBoundaries(frag);
        el.appendChild(frag);
    },

    // Empty text nodes after wrappers give the caret an outside position, so typing after a run isn't swallowed.
    _richPadBoundaries(frag) {
        const kids = [...frag.childNodes];
        for (const child of kids) {
            if (child.nodeType !== Node.ELEMENT_NODE) continue;
            if (this._richAtomicToken(child) != null) continue;
            const next = child.nextSibling;
            if (next && next.nodeType === Node.TEXT_NODE) continue;
            frag.insertBefore(document.createTextNode(''), next);
        }
    },

    // Re-render only when displayed formatting changes; the caret is restored by model offset.
    _maybeRenderRichFormat(el) {
        if (!el || el._richComposing) return;
        if (typeof this._richParseFormat !== 'function') return;
        const text = el.value;
        const start = el.selectionStart, end = el.selectionEnd;
        let tree;
        try { tree = this._richParseFormat(text); } catch (_) { return; }
        const sig = this._richTreeSig(tree, { start, end });
        if (sig === (el._richFormatSig || '')) return;
        this._renderRichInput(el, text, { start, end });
        el._savedSelStart = start;
        el._savedSelEnd = end;
        this._setRichCaret(el, start, end);
    },

    _richSelectionOffset(el, container, offsetInContainer) {
        if (!container || !el.contains(container)) return null;
        const range = document.createRange();
        range.selectNodeContents(el);
        try {
            range.setEnd(container, offsetInContainer);
        } catch (_) {
            return null;
        }
        return this._richNodeLength(range.cloneContents())
            + this._richOutwardSkip(el, container, offsetInContainer);
    },

    // The browser reports the inner offset at a hidden closing marker; resolve outward to match what was typed.
    _richOutwardSkip(el, container, offsetInContainer) {
        let cur;
        if (container.nodeType === Node.TEXT_NODE) {
            // Only at the very end of the text; anywhere else is unambiguous.
            if (offsetInContainer !== container.nodeValue.length) return 0;
            cur = container;
        } else if (container.nodeType === Node.ELEMENT_NODE) {
            if (offsetInContainer === 0) return 0;
            cur = container.childNodes[offsetInContainer - 1] || null;
        } else {
            return 0;
        }
        let add = 0;
        while (cur && cur !== el) {
            for (let sib = cur.nextSibling; sib; sib = sib.nextSibling) {
                const tok = sib.nodeType === Node.ELEMENT_NODE
                    ? this._richAtomicToken(sib) : null;
                // Real content after us means this is not the end of a run.
                if (tok == null) return add;
                add += tok.length;
            }
            cur = cur.parentNode;
        }
        return add;
    },

    _richLocate(el, target) {
        let acc = 0;
        const visit = (parent) => {
            const kids = parent.childNodes;
            for (let i = 0; i < kids.length; i++) {
                const child = kids[i];
                const atomTok = child.nodeType === Node.ELEMENT_NODE ? this._richAtomicToken(child) : null;
                if (child.nodeType === Node.TEXT_NODE) {
                    const len = child.nodeValue.length;
                    if (target <= acc + len) return { node: child, offset: target - acc };
                    acc += len;
                } else if (atomTok != null) {
                    const len = atomTok.length;
                    if (target <= acc) return { node: parent, offset: i };
                    if (target < acc + len) return { node: parent, offset: i + 1 };
                    acc += len;
                } else if (child.nodeType === Node.ELEMENT_NODE && child.tagName === 'BR') {
                    if (target <= acc) return { node: parent, offset: i };
                    acc += 1;
                } else if (child.nodeType === Node.ELEMENT_NODE) {
                    const r = visit(child);
                    if (r) return r;
                }
            }
            return null;
        };
        return visit(el) || { node: el, offset: el.childNodes.length };
    },

    _setRichCaret(el, start, end) {
        const s = this._richLocate(el, Math.max(0, start));
        const e = this._richLocate(el, Math.max(0, end));
        const range = document.createRange();
        try {
            range.setStart(s.node, s.offset);
            range.setEnd(e.node, e.offset);
        } catch (_) {
            return;
        }
        const sel = window.getSelection();
        if (!sel) return;
        sel.removeAllRanges();
        sel.addRange(range);
    },

    _initRichMessageInput(el) {
        if (!el || el._richInit) return;
        el._richInit = true;
        const self = this;
        el._savedSelStart = 0;
        el._savedSelEnd = 0;

        // Remember the last in-input caret; the emoji picker moves focus away.
        const saveSel = () => {
            const sel = window.getSelection();
            if (!sel || !sel.rangeCount) return;
            const r = sel.getRangeAt(0);
            if (!el.contains(r.startContainer)) return;
            const s = self._richSelectionOffset(el, r.startContainer, r.startOffset);
            const e = self._richSelectionOffset(el, r.endContainer, r.endOffset);
            if (s != null) el._savedSelStart = s;
            if (e != null) el._savedSelEnd = e;
            // Caret moves also reveal/hide markdown markers.
            self._maybeRenderRichFormat(el);
        };
        el.addEventListener('keyup', saveSel);
        el.addEventListener('mouseup', saveSel);
        el.addEventListener('input', saveSel);
        el.addEventListener('focus', saveSel);

        // Apply typed text through the model so it can't land inside a run's wrapper; IME composition is left alone.
        el.addEventListener('beforeinput', (e) => {
            if (el._richComposing) return;
            const kind = e.inputType;
            if (kind !== 'insertText' && kind !== 'insertLineBreak'
                && kind !== 'insertParagraph') return;
            const insert = kind === 'insertText' ? (e.data == null ? '' : e.data) : '\n';
            if (!insert) return;
            // Fast path: with no hidden marker in the field the browser's own insertion is safe.
            if (kind === 'insertText' && !el.querySelector('.rich-mark')) return;
            e.preventDefault();
            self._insertTextAtCursor(el, insert);
        });

        // Never re-render mid-composition: it cancels the IME composition.
        el.addEventListener('compositionstart', () => { el._richComposing = true; });
        el.addEventListener('compositionend', () => {
            el._richComposing = false;
            self._maybeRenderRichFormat(el);
        });

        Object.defineProperty(el, 'value', {
            configurable: true,
            get() { return self._serializeRichInput(el); },
            set(v) {
                const text = v == null ? '' : String(v);
                self._renderRichInput(el, text);
                // Mirror textarea behavior: assigning value drops the caret at the end.
                el._savedSelStart = el._savedSelEnd = text.length;
                self._setRichCaret(el, text.length, text.length);
            }
        });

        Object.defineProperty(el, 'selectionStart', {
            configurable: true,
            get() {
                const sel = window.getSelection();
                if (sel && sel.rangeCount) {
                    const r = sel.getRangeAt(0);
                    const o = self._richSelectionOffset(el, r.startContainer, r.startOffset);
                    if (o != null) { el._savedSelStart = o; return o; }
                }
                return el._savedSelStart || 0;
            },
            set(v) { el._savedSelStart = el._savedSelEnd = v; self._setRichCaret(el, v, v); }
        });

        Object.defineProperty(el, 'selectionEnd', {
            configurable: true,
            get() {
                const sel = window.getSelection();
                if (sel && sel.rangeCount) {
                    const r = sel.getRangeAt(0);
                    const o = self._richSelectionOffset(el, r.endContainer, r.endOffset);
                    if (o != null) { el._savedSelEnd = o; return o; }
                }
                return el._savedSelEnd || 0;
            },
            set(v) { el._savedSelStart = el._savedSelEnd = v; self._setRichCaret(el, v, v); }
        });

        Object.defineProperty(el, 'disabled', {
            configurable: true,
            get() { return el.getAttribute('contenteditable') !== 'true'; },
            set(v) {
                el.setAttribute('contenteditable', v ? 'false' : 'true');
                el.classList.toggle('input-disabled', !!v);
            }
        });

        el.setSelectionRange = function (s, e) {
            el._savedSelStart = s;
            el._savedSelEnd = e;
            self._setRichCaret(el, s, e);
        };
    },

    // Returns true when it handled the key.
    _deleteRichMarker(el, forward) {
        if (!el || el.disabled || typeof this._richMarkerDelete !== 'function') return false;
        const start = el.selectionStart, end = el.selectionEnd;
        // Only a collapsed caret: a selection deletes what it visibly covers.
        if (start !== end) return false;
        let edit;
        try {
            edit = this._richMarkerDelete(el.value, start, !!forward);
        } catch (_) {
            return false;
        }
        if (!edit) return false;
        el.value = edit.text;
        el.setSelectionRange(edit.caret, edit.caret);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        return true;
    },

    // Shortcode and image share the same model length, so the caret offset is unchanged.
    _maybeRenderTypedEmoji(el) {
        if (!this.customEmojis || this.customEmojis.size === 0) return;
        const caret = el.selectionStart;
        const value = el.value;
        const m = value.slice(0, caret).match(/:([a-zA-Z0-9_]+):$/);
        if (!m || !this.customEmojis.has(m[1])) return;
        el.value = value;
        el.selectionStart = el.selectionEnd = caret;
    },

    _insertTextAtCursor(el, text) {
        const start = el.selectionStart;
        const end = el.selectionEnd;
        const v = el.value;
        el.value = v.slice(0, start) + text + v.slice(end);
        const pos = start + text.length;
        el.selectionStart = el.selectionEnd = pos;
        el.dispatchEvent(new Event('input', { bubbles: true }));
    },

    toggleGifPicker() {
        const gifPicker = document.getElementById('gifPicker');

        if (gifPicker.classList.contains('active')) {
            this.closeGifPicker();
        } else {
            this.closeEnhancedEmojiModal({ keepFocus: true });

            this.showGifPicker();
        }
    },

    showGifPicker() {
        const gifPicker = document.getElementById('gifPicker');

        gifPicker.innerHTML = `
<div class="gif-modal-header">
    <input type="text" class="gif-search-input" placeholder="Search GIFs..." id="gifSearchInput">
    <button class="modal-close gif-modal-close" data-action="closeGifPicker" aria-label="Close">&#x2715;</button>
</div>
<div id="gifResults" class="gif-grid"></div>
<div class="gif-attribution">Powered by <a href="https://giphy.com" target="_blank">GIPHY</a></div>
`;

        if (typeof this._composerPickerTabs === 'function') this._composerPickerTabs(gifPicker, 'gif');

        // Reparent to <body> so position:fixed anchors to the viewport.
        const button = document.getElementById('emojiInputBtn');
        document.body.appendChild(gifPicker);
        gifPicker.style.position = 'fixed';
        if (window.innerWidth <= 768) {
            gifPicker.style.bottom = '60px';
            gifPicker.style.left = '50%';
            gifPicker.style.transform = 'translateX(-50%)';
            gifPicker.style.right = 'auto';
            gifPicker.style.maxWidth = '90%';
        } else if (button) {
            const rect = button.getBoundingClientRect();
            gifPicker.style.bottom = (window.innerHeight - rect.top + 10) + 'px';
            gifPicker.style.right = Math.min(window.innerWidth - rect.right + 50, 10) + 'px';
            gifPicker.style.left = '';
            gifPicker.style.transform = '';
        }

        gifPicker.classList.add('active');
        if (typeof this._composerPickerOpened === 'function') this._composerPickerOpened(gifPicker, 'gif');

        this.loadTrendingGifs();

        const searchInput = gifPicker.querySelector('#gifSearchInput');
        searchInput.addEventListener('input', (e) => {
            clearTimeout(this.gifSearchTimeout);
            const query = e.target.value.trim();

            if (query) {
                this.gifSearchTimeout = setTimeout(() => {
                    this.searchGifs(query);
                }, 500);
            } else {
                this.loadTrendingGifs();
            }
        });
    },

    async loadTrendingGifs() {
        const resultsDiv = document.getElementById('gifResults');
        resultsDiv.innerHTML = '<div class="gif-loading">Loading trending GIFs...</div>';

        try {
            const data = await this.fetchGiphy({ trending: true, apiKey: this.giphyApiKey });

            this.displayGifs(data.data, { showFavorites: true });
        } catch (error) {
            if (this._getFavoriteGifs().length) {
                this.displayGifs([], { showFavorites: true });
            } else {
                resultsDiv.innerHTML = '<div class="gif-error">Failed to load GIFs</div>';
            }
        }
    },

    async searchGifs(query) {
        const resultsDiv = document.getElementById('gifResults');
        resultsDiv.innerHTML = '<div class="gif-loading">Searching GIFs...</div>';

        try {
            const data = await this.fetchGiphy({ query, apiKey: this.giphyApiKey });

            if (data.data.length === 0) {
                resultsDiv.innerHTML = '<div class="gif-error">No GIFs found</div>';
            } else {
                this.displayGifs(data.data);
            }
        } catch (error) {
            resultsDiv.innerHTML = '<div class="gif-error">Failed to search GIFs</div>';
        }
    },

    _getFavoriteGifs() {
        if (!this._favoriteGifs) {
            let stored;
            try { stored = JSON.parse(localStorage.getItem('nym_favorite_gifs') || '[]'); } catch (_) { }
            this._favoriteGifs = Array.isArray(stored)
                ? stored.filter(g => g && typeof g.url === 'string').map(g => ({ url: g.url, title: typeof g.title === 'string' ? g.title : '' }))
                : [];
        }
        return this._favoriteGifs;
    },

    saveFavoriteGifs() {
        this._favoriteGifs = this._getFavoriteGifs().slice(0, 100);
        localStorage.setItem('nym_favorite_gifs', JSON.stringify(this._favoriteGifs));
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    isFavoriteGif(url) {
        return this._getFavoriteGifs().some(g => g.url === url);
    },

    toggleFavoriteGif(url, title) {
        if (!url) return;
        const favs = this._getFavoriteGifs();
        const idx = favs.findIndex(g => g.url === url);
        if (idx >= 0) favs.splice(idx, 1);
        else favs.unshift({ url, title: title || '' });
        this.saveFavoriteGifs();

        if (this._lastGifRender) {
            this.displayGifs(this._lastGifRender.gifs, { showFavorites: this._lastGifRender.showFavorites });
        }
    },

    _gifItemHtml(originalUrl, title) {
        const safeOriginal = this.escapeHtml(originalUrl);
        const safeProxied = this.escapeHtml(this.getProxiedMediaUrl(originalUrl));
        const safeTitle = this.escapeHtml(title || '');
        const fav = this.isFavoriteGif(originalUrl);
        const favLabel = fav ? 'Unfavorite GIF' : 'Favorite GIF';
        return `
    <div class="gif-item" data-gif-url="${safeOriginal}" data-gif-title="${safeTitle}">
        <img src="${safeProxied}" alt="${safeTitle}" decoding="async" loading="lazy">
        <button class="gif-fav-btn${fav ? ' active' : ''}" data-gif-fav="${safeOriginal}" title="${favLabel}" aria-label="${favLabel}">
            <svg viewBox="0 0 24 24" width="14" height="14"><path d="M12 2 L14.9 8.6 L22 9.3 L16.5 14 L18.2 21 L12 17.3 L5.8 21 L7.5 14 L2 9.3 L9.1 8.6 Z"/></svg>
        </button>
    </div>
`;
    },

    displayGifs(gifs, { showFavorites = false } = {}) {
        const resultsDiv = document.getElementById('gifResults');
        if (!resultsDiv) return;

        this._lastGifRender = { gifs, showFavorites };

        const parts = [];
        if (showFavorites) {
            const favs = this._getFavoriteGifs();
            if (favs.length) {
                parts.push('<div class="gif-section-label">Favorites</div>');
                parts.push(favs.map(g => this._gifItemHtml(g.url, g.title)).join(''));
                if (gifs.length) parts.push('<div class="gif-section-label">Trending</div>');
            }
        }
        parts.push(gifs.map(gif => this._gifItemHtml(gif.images.fixed_height.url, gif.title)).join(''));
        resultsDiv.innerHTML = parts.join('');

        resultsDiv.querySelectorAll('.gif-fav-btn').forEach(btn => {
            btn.onclick = (e) => {
                e.stopPropagation();
                const item = btn.closest('.gif-item');
                this.toggleFavoriteGif(btn.dataset.gifFav, item ? item.dataset.gifTitle : '');
            };
        });
        resultsDiv.querySelectorAll('.gif-item').forEach(item => {
            item.onclick = () => this.insertGif(item.dataset.gifUrl, item.dataset.gifTitle);
        });
    },

    insertGif(gifUrl, title) {
        if (typeof this.pickComposerGif === 'function' && this.pickComposerGif(gifUrl, title)) {
            this.closeGifPicker();
            return;
        }
        const input = document.getElementById('messageInput');
        const start = input.selectionStart;
        const end = input.selectionEnd;
        const text = input.value;

        const newText = text.substring(0, start) + gifUrl + text.substring(end);
        input.value = newText;

        const newPosition = start + gifUrl.length;
        input.selectionStart = input.selectionEnd = newPosition;
        input.focus();

        this.closeGifPicker();
    },

    closeGifPicker(opts) {
        const gifPicker = document.getElementById('gifPicker');
        const wasOpen = gifPicker.classList.contains('active');
        gifPicker.classList.remove('active');
        gifPicker.innerHTML = '';
        gifPicker.style.cssText = '';
        if (wasOpen && typeof this._composerPickerClosed === 'function') this._composerPickerClosed('gif');
        if (wasOpen && !(opts && opts.keepFocus) && typeof this._focusMessageInput === 'function') this._focusMessageInput();
    },

    toggleSidebar() {
        const sidebar = document.getElementById('sidebar');
        const overlay = document.getElementById('mobileOverlay');
        const isOpen = sidebar.classList.contains('open');

        if (isOpen) {
            sidebar.classList.remove('open');
            overlay.classList.remove('active');
        } else {
            sidebar.classList.add('open');
            overlay.classList.add('active');
        }
    },

});
