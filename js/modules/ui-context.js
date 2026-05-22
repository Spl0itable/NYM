// ui-context.js - Context menus, modals, gestures, sidebar, GIF picker, link previews, zap modals, event listeners

Object.assign(NYM.prototype, {

    setupMobileGestures() {
        if (window.innerWidth <= 768) {
            // Touch events for swipe to open menu
            document.addEventListener('touchstart', (e) => {
                const touch = e.touches[0];
                // Only track swipes starting from left edge
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
        // Close context menu sidebar via overlay click
        document.getElementById('contextMenuOverlay').addEventListener('click', () => {
            this.closeContextMenu();
        });

        // Close context menu sidebar via close button
        document.getElementById('ctxCloseBtn').addEventListener('click', () => {
            this.closeContextMenu();
        });

        // Context menu actions
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

        // Add zap handler
        document.getElementById('ctxZap').addEventListener('click', async () => {
            if (this.contextMenuData && this.contextMenuData.messageId) {
                const { messageId, pubkey, nym } = this.contextMenuData;

                // Close context menu immediately
                this.closeContextMenu();

                // Show loading message
                this.displaySystemMessage(`Checking if @${nym} can receive zaps...`);

                try {
                    // Always fetch fresh to ensure we have the latest
                    const lnAddress = await this.fetchLightningAddressForUser(pubkey);

                    if (lnAddress) {
                        // User has lightning address, show zap modal
                        this.showZapModal(messageId, pubkey, nym);
                    } else {
                        // No lightning address found
                        this.displaySystemMessage(`@${nym} cannot receive zaps (no lightning address set)`);
                    }
                } catch (error) {
                    this.displaySystemMessage(`Failed to check if @${nym} can receive zaps`);
                }
            }
        });

        // Gift Nymbot credits to this user
        document.getElementById('ctxGiftCredits').addEventListener('click', () => {
            if (this.contextMenuData) {
                const { pubkey, nym } = this.contextMenuData;
                this.closeContextMenu();
                this.showBotCreditsModal({ pubkey, nym });
            }
        });

        // Add slap handler
        let slapOption = document.getElementById('ctxSlap');
        if (!slapOption) {
            // Create slap option if it doesn't exist
            slapOption = document.createElement('div');
            slapOption.className = 'context-menu-item';
            slapOption.id = 'ctxSlap';
            slapOption.innerHTML = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" class="nm-ico8"><path d="M 1 8 Q 3 4 8 4 Q 11 4 13 6 L 15 4.5 L 15 11.5 L 13 10 Q 11 12 8 12 Q 3 12 1 8 Z" fill="none" /><circle cx="5" cy="7.5" r="0.7" fill="currentColor" stroke="none" /><path d="M 9 6.5 Q 10 8 9 9.5" stroke-linecap="round" /></svg>Slap with Trout';

            // Insert after PM option
            const pmOption = document.getElementById('ctxPM');
            if (pmOption && pmOption.nextSibling) {
                pmOption.parentNode.insertBefore(slapOption, pmOption.nextSibling);
            } else if (pmOption) {
                pmOption.parentNode.appendChild(slapOption);
            }
        }

        // Add hug handler
        let hugOption = document.getElementById('ctxHug');
        if (!hugOption) {
            hugOption = document.createElement('div');
            hugOption.className = 'context-menu-item';
            hugOption.id = 'ctxHug';
            hugOption.innerHTML = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" class="nm-ico8"><circle cx="6" cy="5" r="2" /><circle cx="10" cy="5" r="2" /><path d="M 2 14 C 2 10 4 9 6 9 C 7 9 7.5 9.5 8 10 C 8.5 9.5 9 9 10 9 C 12 9 14 10 14 14" stroke-linecap="round" stroke-linejoin="round" /><path d="M 4 11.5 Q 8 9 12 11.5" stroke-linecap="round" /></svg>Give warm Hug';

            // Insert after slap option
            if (slapOption && slapOption.nextSibling) {
                slapOption.parentNode.insertBefore(hugOption, slapOption.nextSibling);
            } else if (slapOption) {
                slapOption.parentNode.appendChild(hugOption);
            }
        }

        // Add report handler
        document.getElementById('ctxReport').addEventListener('click', () => {
            if (this.contextMenuData) {
                this.openReportModal();
            }
            this.closeContextMenu();
        });

        // Add the click handler for slap
        slapOption.addEventListener('click', () => {
            if (this.contextMenuData) {
                // Pass the pubkey directly as the argument
                this.cmdSlap(this.contextMenuData.pubkey);
            }
            this.closeContextMenu();
        });

        // Add the click handler for hug
        hugOption.addEventListener('click', () => {
            if (this.contextMenuData) {
                this.cmdHug(this.contextMenuData.pubkey);
            }
            this.closeContextMenu();
        });

        document.getElementById('ctxReact').addEventListener('click', () => {
            if (this.contextMenuData && this.contextMenuData.reactionId) {
                this.closeContextMenu();

                // Use a delay to ensure context menu closes first
                setTimeout(() => {
                    // Create a temporary button element for positioning (centered for mobile)
                    const tempButton = document.createElement('button');
                    tempButton.style.position = 'fixed';
                    tempButton.style.left = '50%';
                    tempButton.style.bottom = '50%';
                    tempButton.style.opacity = '0';
                    tempButton.style.pointerEvents = 'none';
                    document.body.appendChild(tempButton);

                    this.showEnhancedReactionPicker(this.contextMenuData.reactionId, tempButton);

                    // Remove temp button after modal is created
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
                // Pass the pubkey directly as the argument
                this.cmdBlock(this.contextMenuData.pubkey);
            }
            this.closeContextMenu();
        });

        document.getElementById('ctxCopyPubkey').addEventListener('click', async () => {
            if (this.contextMenuData && this.contextMenuData.pubkey) {
                try {
                    await navigator.clipboard.writeText(this.contextMenuData.pubkey);
                    this.displaySystemMessage(`Copied pubkey to clipboard`);
                } catch (err) {
                    this.displaySystemMessage('Failed to copy pubkey');
                }
            } else {
                this.displaySystemMessage('No pubkey available to copy');
            }
            this.closeContextMenu();
        });

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

        // Translate message handler
        document.getElementById('ctxTranslate').addEventListener('click', async () => {
            const data = this.contextMenuData;
            this.closeContextMenu();
            if (data && data.content) {
                // Strip quoted lines (> prefixed) to translate only the user's reply
                const nonQuotedContent = data.content.split('\n')
                    .filter(line => !line.startsWith('>'))
                    .join('\n').trim();
                await this.translateMessage(nonQuotedContent || data.content, data.messageId || data.reactionId);
            } else {
                this.displaySystemMessage('No message content to translate');
            }
        });

        // Add edit message handler
        document.getElementById('ctxEditMessage').addEventListener('click', () => {
            if (this.contextMenuData && this.contextMenuData.messageId && this.contextMenuData.pubkey === this.pubkey) {
                this.startEditMessage(this.contextMenuData);
            }
            this.closeContextMenu();
        });

        // Edit preview close button
        document.getElementById('editPreviewClose').addEventListener('click', () => {
            this.cancelEditMessage();
        });

        // Note: ctxDeleteMessage is wired via data-action="deleteMessageFromContext"
        // in index.html and dispatched through inline-bindings.js.
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

        // Enable message reporting only if there's a messageId
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

        // Reset form
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
            // Create NIP-56 kind 1984 report event
            const event = {
                kind: 1984,
                created_at: Math.floor(Date.now() / 1000),
                tags: [],
                content: reportDetails || '',
                pubkey: this.pubkey
            };

            // Add p tag (always required for user reports)
            event.tags.push(['p', pubkey, reportType]);

            // Add e tag if reporting a specific message
            if (reportMessage && messageId) {
                event.tags.push(['e', messageId, reportType]);
            }

            // Sign and publish the event
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

    showContextMenu(e, nym, pubkey, content = null, messageId = null, profileOnly = false, reactionId = null) {
        e.preventDefault();
        e.stopPropagation();

        const menu = document.getElementById('contextMenu');
        // Parse base nym from display format - this removes HTML tags
        const parsedNym = this.parseNymFromDisplay(nym);
        // Get just the base nym without any suffix
        const baseNym = this.stripPubkeySuffix(parsedNym);
        const suffix = this.getPubkeySuffix(pubkey);
        const fullNym = `${baseNym}#${suffix}`;

        // reactionId is the DOM-facing ID (nymMessageId for PMs), messageId is the real event ID
        this.contextMenuData = { nym: baseNym, pubkey, content, messageId, reactionId: reactionId || messageId };

        // Populate banner if available
        const ctxBannerImg = document.getElementById('ctxBannerImg');
        const bannerUrl = this.getBannerUrl(pubkey);
        if (ctxBannerImg) {
            if (bannerUrl) {
                ctxBannerImg.src = bannerUrl;
                ctxBannerImg.style.display = 'block';
                ctxBannerImg.style.cursor = 'pointer';
                ctxBannerImg.onerror = function () {
                    this.style.display = 'none';
                    menu.classList.remove('has-banner');
                };
                menu.classList.add('has-banner');
            } else {
                ctxBannerImg.style.display = 'none';
                menu.classList.remove('has-banner');
            }
        }

        // Populate avatar header
        const ctxAvatarImg = document.getElementById('ctxAvatarImg');
        const ctxAvatarNym = document.getElementById('ctxAvatarNym');
        if (ctxAvatarImg) {
            ctxAvatarImg.src = this.getAvatarUrl(pubkey);
            const fallback = this.generateAvatarSvg(pubkey);
            ctxAvatarImg.onerror = function () { this.onerror = null; this.src = fallback; };
        }
        if (ctxAvatarNym) {
            const flairHtml = this.getFlairForUser(pubkey);
            const userShopItems = this.getUserShopItems(pubkey);
            const supporterBadge = userShopItems?.supporter ?
                '<span class="supporter-badge"><span class="supporter-badge-icon">🏆</span><span class="supporter-badge-text">Supporter</span></span>' : '';
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
            // Show "Group Owner" or "Moderator" badge for the user in the current group
            if (this.inPMMode && this.currentGroup) {
                const grp = this.groupConversations.get(this.currentGroup);
                if (grp && grp.createdBy === pubkey) {
                    nymHtml += `<div class="context-menu-owner-label">Group Owner</div>`;
                } else if (grp && Array.isArray(grp.mods) && grp.mods.includes(pubkey)) {
                    nymHtml += `<div class="context-menu-owner-label">Moderator</div>`;
                }
            }
            ctxAvatarNym.innerHTML = nymHtml;
        }

        // Populate the full pubkey block
        const ctxFullPubkey = document.getElementById('ctxFullPubkey');
        if (ctxFullPubkey) {
            if (pubkey) {
                ctxFullPubkey.textContent = pubkey;
                ctxFullPubkey.style.display = '';
            } else {
                ctxFullPubkey.textContent = '';
                ctxFullPubkey.style.display = 'none';
            }
        }

        // Populate status row (online / away / offline)
        const ctxStatusRow = document.getElementById('ctxStatusRow');
        if (ctxStatusRow) {
            ctxStatusRow.textContent = '';
            const status = this.getEffectiveUserStatus(pubkey);
            const targetHidden = this.statusHiddenUsers && this.statusHiddenUsers.has(pubkey);
            if (this.settings.showStatus !== false && !targetHidden && status !== 'hidden') {
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

        // Group moderation entries: visibility only — actions are bound via
        // data-action in index.html and dispatched through inline-bindings.js,
        // which reads the target pubkey from this.contextMenuData.
        const grpForCtx = (this.inPMMode && this.currentGroup) ? this.groupConversations.get(this.currentGroup) : null;
        const targetIsMember = !!(grpForCtx && grpForCtx.members.includes(pubkey));
        const iAmOwner = !!(grpForCtx && grpForCtx.createdBy === this.pubkey);
        const iAmMod = !!(grpForCtx && Array.isArray(grpForCtx.mods) && grpForCtx.mods.includes(this.pubkey));
        const iCanModerate = iAmOwner || iAmMod;
        const targetIsOwner = !!(grpForCtx && grpForCtx.createdBy === pubkey);
        const targetIsMod = !!(grpForCtx && Array.isArray(grpForCtx.mods) && grpForCtx.mods.includes(pubkey));

        const showKickOrBan = !!(grpForCtx && targetIsMember && pubkey !== this.pubkey
            && iCanModerate
            && (iAmOwner || (!targetIsOwner && !targetIsMod)));
        const showAddMod = !!(grpForCtx && targetIsMember && pubkey !== this.pubkey
            && iAmOwner && !targetIsOwner && !targetIsMod);
        const showRemoveMod = !!(grpForCtx && targetIsMember && pubkey !== this.pubkey
            && iAmOwner && targetIsMod);
        const showTransfer = !!(grpForCtx && targetIsMember && pubkey !== this.pubkey && iAmOwner);

        const setDisplay = (id, show) => {
            const el = document.getElementById(id);
            if (el) el.style.display = show ? 'block' : 'none';
        };
        const kickOption = document.getElementById('ctxKickMember');
        setDisplay('ctxKickMember', showKickOrBan);
        setDisplay('ctxBanMember', showKickOrBan);
        setDisplay('ctxAddMod', showAddMod);
        setDisplay('ctxRemoveMod', showRemoveMod);
        setDisplay('ctxTransferOwner', showTransfer);

        // Add slap option if it doesn't exist
        let slapOption = document.getElementById('ctxSlap');
        if (!slapOption) {
            // Create slap option
            slapOption = document.createElement('div');
            slapOption.className = 'context-menu-item';
            slapOption.id = 'ctxSlap';
            slapOption.innerHTML = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" class="nm-ico8"><path d="M 1 8 Q 3 4 8 4 Q 11 4 13 6 L 15 4.5 L 15 11.5 L 13 10 Q 11 12 8 12 Q 3 12 1 8 Z" fill="none" /><circle cx="5" cy="7.5" r="0.7" fill="currentColor" stroke="none" /><path d="M 9 6.5 Q 10 8 9 9.5" stroke-linecap="round" /></svg>Slap with Trout';

            // Insert after PM option
            const pmOption = document.getElementById('ctxPM');
            if (pmOption && pmOption.nextSibling) {
                pmOption.parentNode.insertBefore(slapOption, pmOption.nextSibling);
            } else if (pmOption) {
                pmOption.parentNode.appendChild(slapOption);
            }
        }

        // Show slap option only if not yourself
        slapOption.style.display = pubkey === this.pubkey ? 'none' : 'block';

        // Add hug option if it doesn't exist
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

        // Show hug option only if not yourself
        hugOption.style.display = pubkey === this.pubkey ? 'none' : 'block';

        // Add zap option handling
        const zapOption = document.getElementById('ctxZap');
        if (zapOption) {
            // Show zap option if:
            // 1. Not your own message
            // 2. Has a valid message ID
            if (pubkey !== this.pubkey && messageId) {
                zapOption.style.display = 'block';
            } else {
                zapOption.style.display = 'none';
            }
        }

        // Hide friend option if it's your own message, toggle label
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

        // Hide block option if it's your own message
        const blockOption = document.getElementById('ctxBlock');
        if (pubkey === this.pubkey) {
            blockOption.style.display = 'none';
        } else {
            blockOption.style.display = 'block';
            const blockSvg = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" class="nm-ico8"><circle cx="8" cy="8" r="6" /><line x1="3.75" y1="3.75" x2="12.25" y2="12.25" stroke-width="1.5" stroke-linecap="round" /></svg>';
            blockOption.innerHTML = blockSvg + (this.blockedUsers.has(pubkey) ? 'Unblock User' : 'Block User');
        }

        // Hide PM option only for your own messages (Nymbot accepts private chats)
        document.getElementById('ctxPM').style.display = (pubkey === this.pubkey) ? 'none' : 'block';

        // Gift Nymbot credits — for other users, not yourself or Nymbot itself
        document.getElementById('ctxGiftCredits').style.display =
            (pubkey === this.pubkey || this.isVerifiedBot(pubkey)) ? 'none' : 'block';

        // Show "Edit Profile" only for own messages
        const editProfileOption = document.getElementById('ctxEditProfile');
        if (editProfileOption) {
            editProfileOption.style.display = pubkey === this.pubkey ? 'block' : 'none';
            editProfileOption.onclick = () => {
                this.closeContextMenu();
                editNick();
            };
        }

        // Show/hide quote option
        document.getElementById('ctxQuote').style.display = content ? 'block' : 'none';

        // Show/hide Copy Message option
        document.getElementById('ctxCopyMessage').style.display = content ? 'block' : 'none';

        // Show/hide React option
        const reactOption = document.getElementById('ctxReact');
        reactOption.style.display = messageId ? 'block' : 'none';

        // Show/hide Edit Message option - only for own messages with content
        const editOption = document.getElementById('ctxEditMessage');
        if (pubkey === this.pubkey && messageId && content) {
            editOption.style.display = 'block';
        } else {
            editOption.style.display = 'none';
        }

        // Show/hide Delete Message option - own messages, or mod/owner deleting
        // another member's message in the current group.
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

        // Hide report option for own messages
        document.getElementById('ctxReport').style.display = pubkey === this.pubkey ? 'none' : 'block';

        // In profile-only mode (e.g. nyms sidebar) show only PM, Report, Block
        if (profileOnly) {
            const ctxMention = document.getElementById('ctxMention');
            if (ctxMention) ctxMention.style.display = 'none';
            const ctxTranslate = document.getElementById('ctxTranslate');
            if (ctxTranslate) ctxTranslate.style.display = 'none';
            if (slapOption) slapOption.style.display = 'none';
            if (hugOption) hugOption.style.display = 'none';
            if (kickOption) kickOption.style.display = 'none';
            if (editOption) editOption.style.display = 'none';
            const idsToHide = ['ctxBanMember', 'ctxAddMod', 'ctxRemoveMod', 'ctxTransferOwner'];
            for (const id of idsToHide) {
                const el = document.getElementById(id);
                if (el) el.style.display = 'none';
            }
        }

        // Populate bio
        const ctxBio = document.getElementById('ctxBio');
        if (ctxBio) {
            const bio = this.getBio(pubkey);
            ctxBio.textContent = bio;
        }

        // Scroll sidebar to top
        menu.scrollTop = 0;

        // Show overlay and sidebar
        document.getElementById('contextMenuOverlay').classList.add('active');
        menu.classList.add('active');

        // Prevent the click from immediately closing the menu
        e.stopImmediatePropagation();
    },

    closeContextMenu() {
        const menu = document.getElementById('contextMenu');
        const wasOpen = menu && menu.classList.contains('active');
        menu.classList.remove('active');
        document.getElementById('contextMenuOverlay').classList.remove('active');
        if (wasOpen && typeof this._focusMessageInput === 'function') this._focusMessageInput();
    },

    // Unfurl a URL and return Open Graph metadata.
    // Uses CF proxy when available; falls back to direct fetch (may be blocked by CORS).
    async unfurlUrl(url) {
        // Check cache first
        if (this._unfurlCache.has(url)) return this._unfurlCache.get(url);

        try {
            let data;
            const base = this._getProxyBaseUrl();
            if (base) {
                try {
                    const resp = await fetch(`${base}?action=unfurl&url=${encodeURIComponent(url)}`);
                    if (!resp.ok) throw new Error(`Unfurl proxy returned ${resp.status}`);
                    data = await resp.json();
                } catch (proxyErr) {
                    // Unfurl proxy failed for this URL — try direct fetch.
                    // Don't treat as a global API outage: unfurl can fail per-URL
                    // (target site down, CORS, 5xx) without the proxy being down.
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
            } else {
                // Direct fetch fallback — works when the target sets CORS headers
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

            // Cache result
            this._unfurlCache.set(url, data);
            // Trim cache to max 200 entries
            if (this._unfurlCache.size > 200) {
                const first = this._unfurlCache.keys().next().value;
                this._unfurlCache.delete(first);
            }
            return data;
        } catch {
            return null;
        }
    },

    // Client-side Open Graph extraction (used when CF proxy is unavailable)
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
        let image = get('image') || '';
        if (image && !image.startsWith('http')) {
            try { image = new URL(image, pageUrl).href; } catch { image = ''; }
        }
        let favicon = '';
        const favMatch = html.match(/<link[^>]+rel=["'](?:icon|shortcut icon)["'][^>]+href=["']([^"']+)["']/i)
            || html.match(/<link[^>]+href=["']([^"']+)["'][^>]+rel=["'](?:icon|shortcut icon)["']/i);
        if (favMatch) {
            favicon = favMatch[1];
            if (!favicon.startsWith('http')) {
                try { favicon = new URL(favicon, pageUrl).href; } catch { favicon = ''; }
            }
        }
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

    // Render a rich link preview card for an unfurled URL
    _renderLinkPreview(meta) {
        if (!meta || (!meta.title && !meta.description)) return '';

        const imageHtml = meta.image
            ? `<img src="${this.escapeHtml(this.getProxiedMediaUrl(meta.image))}" class="link-preview-image" loading="lazy" data-error-action="errorHideElement">`
            : '';

        const faviconHtml = meta.favicon
            ? `<img src="${this.escapeHtml(this.getProxiedMediaUrl(meta.favicon))}" class="link-preview-favicon" loading="lazy" data-error-action="errorHideElement">`
            : '';

        const siteNameHtml = meta.siteName
            ? `<span class="link-preview-site">${faviconHtml}${this.escapeHtml(meta.siteName)}</span>`
            : '';

        let host = '';
        try { host = new URL(meta.url).hostname; } catch { }

        return `<a href="${this.escapeHtml(meta.url)}" target="_blank" rel="noopener" class="link-preview" data-action="stopPropagation">
            ${imageHtml}
            <div class="link-preview-text">
                ${siteNameHtml || `<span class="link-preview-site">${this.escapeHtml(host)}</span>`}
                <span class="link-preview-title">${this.escapeHtml(meta.title || '')}</span>
                <span class="link-preview-desc">${this.escapeHtml((meta.description || '').slice(0, 200))}</span>
            </div>
        </a>`;
    },

    // After a message is rendered, find URLs in it and attach link previews
    async _attachLinkPreviews(messageEl) {
        const links = messageEl.querySelectorAll('.message-content a[href^="http"]');
        if (links.length === 0) return;

        // Unfurl all links in the message
        const linksToUnfurl = Array.from(links);
        for (const link of linksToUnfurl) {
            const href = link.getAttribute('href');
            // Skip media URLs (already embedded as inline images/videos)
            if (/\.(jpg|jpeg|png|gif|webp|mp4|webm|ogg|mov)(\?.*)?$/i.test(href)) continue;

            const meta = await this.unfurlUrl(href);
            if (meta && (meta.title || meta.description)) {
                const previewHtml = this._renderLinkPreview(meta);
                if (previewHtml) {
                    const container = messageEl.querySelector('.message-content');
                    if (container) {
                        const previewEl = document.createElement('div');
                        previewEl.className = 'link-preview-container';
                        previewEl.innerHTML = previewHtml;
                        container.appendChild(previewEl);
                    }
                }
            }
        }
    },

    setupEventListeners() {
        // Click handler for status indicator to manually trigger reconnection
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

        // Delegated click handler for DM retry buttons (failed delivery indicator)
        const messagesContainer = document.getElementById('messagesContainer');
        if (messagesContainer) {
            messagesContainer.addEventListener('click', (e) => {
                const retryEl = e.target.closest('[data-retry-event-id]');
                if (retryEl) {
                    e.preventDefault();
                    e.stopPropagation();
                    this.manualRetryDM(retryEl.dataset.retryEventId);
                }
            });
        }

        // Quote preview close button
        document.getElementById('quotePreviewClose').addEventListener('click', () => {
            this.clearQuoteReply();
        });

        // Swipe-to-reply on mobile
        this.setupSwipeToReply();
        // Double-click to reply on desktop
        this.setupDoubleClickToReply();

        // Alt+Left / Alt+Right for channel back/forward navigation
        document.addEventListener('keydown', (e) => {
            if (e.altKey && e.key === 'ArrowLeft') {
                e.preventDefault();
                this.navigateBack();
            } else if (e.altKey && e.key === 'ArrowRight') {
                e.preventDefault();
                this.navigateForward();
            }
        });

        // Mouse back/forward buttons: browser intercepts these before JS can
        // preventDefault, so we integrate with the History API instead.
        // pushState is called in _pushNavigation; popstate handles back/forward.
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

        input.addEventListener('keydown', (e) => {
            const autocomplete = document.getElementById('autocompleteDropdown');
            const channelAc = document.getElementById('channelAutocomplete');
            const emojiAutocomplete = document.getElementById('emojiAutocomplete');
            const commandPalette = document.getElementById('commandPalette');

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
                    // contenteditable would insert a block element — insert a
                    // plain newline so the value stays clean text.
                    e.preventDefault();
                    this._insertTextAtCursor(input, '\n');
                } else if (e.key === 'Escape' && this.pendingEdit) {
                    e.preventDefault();
                    this.cancelEditMessage();
                } else if (e.key === 'Escape' && this.pendingQuote) {
                    e.preventDefault();
                    this.clearQuoteReply();
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
            // Render a just-completed :shortcode: as its custom emoji image.
            this._maybeRenderTypedEmoji(e.target);
            this.handleInputChange(e.target.value);
            this.autoResizeTextarea(e.target);
            this.updateTranslateInputBtn();
            // Signal typing for PMs, groups, and public channels
            if (e.target.value.trim().length > 0) {
                if (this.inPMMode) {
                    this.handleTypingSignal();
                } else if (this.currentGeohash) {
                    this.handleChannelTypingSignal();
                }
            }
        });

        // Use event delegation for channel clicks
        document.getElementById('channelList').addEventListener('click', (e) => {
            // Handle channel item clicks
            const channelItem = e.target.closest('.channel-item');
            if (channelItem && !e.target.closest('.pin-btn') && !e.target.closest('.hide-btn')) {
                e.preventDefault();
                e.stopPropagation();

                const channel = channelItem.dataset.channel;
                const geohash = channelItem.dataset.geohash || '';

                // Don't reload if already in channel
                if (!nym.inPMMode &&
                    channel === nym.currentChannel &&
                    geohash === nym.currentGeohash) {
                    return;
                }

                // Add debounce to prevent double-clicks
                if (channelItem.dataset.clicking === 'true') return;
                channelItem.dataset.clicking = 'true';

                nym.switchChannel(channel, geohash);

                // Reset click flag after a short delay
                setTimeout(() => {
                    delete channelItem.dataset.clicking;
                }, 1000);
            }
        });

        // Global click handler for closing dropdowns and modals
        document.addEventListener('click', (e) => {
            // Close command palette if clicking outside
            if (!e.target.closest('#commandPalette') && !e.target.closest('#messageInput')) {
                this.hideCommandPalette();
            }

            // Close emoji autocomplete if clicking outside
            if (!e.target.closest('#emojiAutocomplete') && !e.target.closest('#messageInput')) {
                this.hideEmojiAutocomplete();
            }

            // Close # channel autocomplete if clicking outside
            if (!e.target.closest('#channelAutocomplete') && !e.target.closest('#messageInput')) {
                this.hideChannelAutocomplete();
            }

            // Close @ mention autocomplete if clicking outside
            if (!e.target.closest('#autocompleteDropdown') && !e.target.closest('#messageInput')) {
                this.hideAutocomplete();
            }

            // Close enhanced emoji modal if clicking outside
            if (!e.target.closest('.enhanced-emoji-modal') &&
                !e.target.closest('.reaction-btn') &&
                !e.target.closest('.add-reaction-btn') &&
                !e.target.closest('.icon-btn.input-btn[title="Emoji"]') &&
                !e.target.closest('#ctxReact') &&
                !e.target.closest('#swipeReactEmojiBtn')) {
                this.closeEnhancedEmojiModal();
            }

            // Close GIF picker if clicking outside
            if (!e.target.closest('.gif-picker') &&
                !e.target.closest('.icon-btn[title="GIF"]')) {
                this.closeGifPicker();
            }

            // Close reactors/readers modal if clicking outside
            if (!e.target.closest('.reactors-modal') &&
                !e.target.closest('.reaction-badge')) {
                this.closeReactorsModal();
            }
            if (!e.target.closest('.readers-modal') &&
                !e.target.closest('.group-readers')) {
                this.closeReadersModal();
            }

            // Handle command palette item click
            if (e.target.closest('.command-item')) {
                this.selectCommand(e.target.closest('.command-item'));
            }
        });

        // File input
        document.getElementById('fileInput').addEventListener('change', (e) => {
            if (e.target.files && e.target.files.length) {
                this.uploadImage(Array.from(e.target.files));
                e.target.value = '';
            }
        });

        // Clipboard paste — auto-upload images/videos pasted into the message input
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
            // Plain-text paste — strip formatting so the contenteditable input
            // never accumulates foreign HTML.
            const text = e.clipboardData && e.clipboardData.getData('text/plain');
            if (text) {
                e.preventDefault();
                this._insertTextAtCursor(e.currentTarget, text);
            }
        });

        // P2P File input - auto-detect torrent files vs regular files
        document.getElementById('p2pFileInput').addEventListener('change', (e) => {
            if (e.target.files && e.target.files[0]) {
                const file = e.target.files[0];
                if (file.name.endsWith('.torrent') || file.type === 'application/x-bittorrent') {
                    this.shareP2PFileTorrent(file);
                } else {
                    this.shareP2PFile(file);
                }
                e.target.value = ''; // Reset for next selection
            }
        });

        // Long-press Send button (2s) for pseudonymous send (Nostr login users only)
        const sendBtn = document.getElementById('sendBtn');
        let sendLongPressTimer = null;
        let sendLongPressFired = false;

        const startSendLongPress = (e) => {
            sendLongPressFired = false;
            sendLongPressTimer = setTimeout(() => {
                if (this.nostrLoginMethod) {
                    sendLongPressFired = true;
                    window.nymHapticTap && window.nymHapticTap();
                    sendBtn.style.boxShadow = '0 0 15px rgb(from var(--primary) r g b / 0.4)';
                    sendBtn.textContent = 'ANON';
                    this.sendMessagePseudonymous();
                    setTimeout(() => {
                        sendBtn.textContent = 'SEND';
                        sendBtn.style.boxShadow = '';
                    }, 1000);
                }
            }, 2000);
            // Visual feedback: after 700ms start pulsing if Nostr logged in
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
            if (sendLongPressFired) {
                e.preventDefault();
                e.stopPropagation();
                sendLongPressFired = false;
            }
        };

        sendBtn.addEventListener('click', (e) => {
            if (!sendLongPressFired) {
                sendMessage();
            }
        });
        sendBtn.addEventListener('mousedown', startSendLongPress);
        sendBtn.addEventListener('touchstart', startSendLongPress, { passive: true });
        sendBtn.addEventListener('mouseup', cancelSendLongPress);
        sendBtn.addEventListener('mouseleave', cancelSendLongPress);
        sendBtn.addEventListener('touchend', cancelSendLongPress);
        sendBtn.addEventListener('touchcancel', cancelSendLongPress);

        // Long-press on messages to show quick emoji reaction popup
        const messagesEl = document.getElementById('messagesContainer');
        let msgLongPressTimer = null;
        let msgLongPressFired = false;

        const showQuickReactPopup = (msgEl, e) => {
            msgLongPressFired = true;
            const messageId = msgEl.dataset.messageId;
            if (!messageId) return;
            window.nymHapticTap && window.nymHapticTap();

            // Build the 6 emojis to show: recently used + defaults
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

            // Remove any existing quick react popup
            document.querySelectorAll('.quick-react-popup, .quick-context-menu').forEach(el => el.remove());

            // Highlight the long-pressed message and dim the others
            messagesEl.classList.add('has-long-press-highlight');
            messagesEl.querySelectorAll('.message.long-press-highlight').forEach(el => el.classList.remove('long-press-highlight'));
            msgEl.classList.add('long-press-highlight');

            const popup = document.createElement('div');
            popup.className = 'quick-react-popup';

            popup.innerHTML = quickEmojis.map(emoji => {
                const cm = typeof emoji === 'string' && emoji.match(/^:([a-zA-Z0-9_]+):$/);
                if (cm && this.customEmojis && this.customEmojis.has(cm[1])) {
                    return `<button class="quick-react-emoji" data-emoji=":${this.escapeHtml(cm[1])}:">${this.renderCustomEmojiImg(cm[1])}</button>`;
                }
                return `<button class="quick-react-emoji" data-emoji="${this.escapeHtml(emoji)}">${emoji}</button>`;
            }).join('') +
                `<button class="quick-react-expand" title="More reactions">
                    <svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                        <path d="M4 6 L8 10 L12 6"/>
                    </svg>
                </button>`;

            // Position near the long-press point
            const msgRect = msgEl.getBoundingClientRect();
            popup.style.position = 'fixed';

            // Position above the message, centered on press point
            const clientX = e.clientX || (e.touches && e.touches[0] ? e.touches[0].clientX : msgRect.left + msgRect.width / 2);
            const clientY = e.clientY || (e.touches && e.touches[0] ? e.touches[0].clientY : msgRect.top);

            // Append popup offscreen first to measure its actual rendered size
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

            // Build the quick context menu (Slap, Hug, Zap, Quote, Copy)
            const baseAuthor = this.parseNymFromDisplay(msgEl.dataset.author || 'anon');
            const targetPubkey = msgEl.dataset.pubkey || '';
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
                    action: () => {
                        if (window.confirm('Are you sure you want to delete this message? This will send a deletion request to relays.')) {
                            this.publishDeletionEvent(messageId, this.inPMMode ? 1059 : this.channelWire(this.currentGeohash).kind).then(() => {
                                this.displaySystemMessage('Deletion request sent to relays');
                            });
                        }
                    }
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

            // Trigger animation
            requestAnimationFrame(() => {
                popup.classList.add('active');
                if (quickCtxMenu) quickCtxMenu.classList.add('active');
            });

            const cleanupHighlight = () => {
                messagesEl.classList.remove('has-long-press-highlight');
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

            // Handle expand button to open full reaction picker
            const expandBtn = popup.querySelector('.quick-react-expand');
            const openFullPicker = (ev) => {
                ev.preventDefault();
                ev.stopPropagation();
                const popupLeft = popup.style.left;
                const popupTop = popup.style.top;
                closeAll();
                removeCloseListeners();

                // Create a temporary button for positioning the full picker
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

            // Handle emoji clicks via both click and touchend for reliability
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

            // Also handle touch on emoji buttons directly for mobile
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

            // Close on click/tap outside. Ignore any close events that fire
            // within 400ms of opening — these come from the same long-press
            // gesture (mouseup + click, or touchend) that triggered the popup.
            const openedAt = Date.now();
            const closePopup = (ev) => {
                if (popup.contains(ev.target)) return;
                if (quickCtxMenu && quickCtxMenu.contains(ev.target)) return;
                if (Date.now() - openedAt < 400) return;
                closeAll();
                removeCloseListeners();
            };
            const removeCloseListeners = () => {
                document.removeEventListener('mousedown', closePopup);
                document.removeEventListener('touchstart', closePopup);
            };
            // Use mousedown/touchstart (not mouseup/click) so the popup
            // closes on the start of a new gesture, not the end of the
            // opening gesture.
            document.addEventListener('mousedown', closePopup);
            document.addEventListener('touchstart', closePopup);
        };

        let msgLongPressStartX = 0;
        let msgLongPressStartY = 0;
        const MSG_LONG_PRESS_MOVE_THRESHOLD = 5;

        messagesEl.addEventListener('mousedown', (e) => {
            // Only trigger on primary (left) mouse button; ignore right/middle clicks
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

        // Cancel long-press react if the pointer moves (e.g. text selection drag)
        messagesEl.addEventListener('mousemove', (e) => {
            if (!msgLongPressTimer) return;
            const dx = e.clientX - msgLongPressStartX;
            const dy = e.clientY - msgLongPressStartY;
            if (dx * dx + dy * dy > MSG_LONG_PRESS_MOVE_THRESHOLD * MSG_LONG_PRESS_MOVE_THRESHOLD) {
                cancelMsgLongPress();
            }
        });
        // Cancel long-press react if a swipe gesture is detected
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
        // Use cursor position so autocomplete works mid-sentence
        const inputEl = document.getElementById('messageInput');
        const cursor = (inputEl && typeof inputEl.selectionStart === 'number')
            ? inputEl.selectionStart
            : value.length;
        const before = value.substring(0, cursor);

        // Check for @ mentions first (token immediately to the left of cursor)
        const mentionMatch = before.match(/(?:^|\s)@([^\s]*)$/);
        const isMentionActive = mentionMatch !== null;

        // Check for # channel references (# at start or after whitespace, followed by non-space chars)
        const hashMatch = before.match(/(?:^|\s)#([^\s]*)$/);
        const isChannelActive = hashMatch !== null;

        if (isMentionActive) {
            const search = mentionMatch[1];
            this.showAutocomplete(search);
            // Hide emoji autocomplete and channel autocomplete
            this.hideEmojiAutocomplete();
            this.hideChannelAutocomplete();
        } else if (isChannelActive) {
            const search = hashMatch[1];
            this.showChannelAutocomplete(search);
            this.hideAutocomplete();
            this.hideEmojiAutocomplete();
        } else {
            this.hideAutocomplete();
            this.hideChannelAutocomplete();

            // Only check for emoji autocomplete when not in a mention context.
            // Match a :shortcode token immediately to the left of the cursor
            // so it works mid-sentence (e.g., "hello :thum| world").
            const emojiMatch = before.match(/(?:^|\s):([a-z0-9_+-]*)$/i);
            if (emojiMatch) {
                this.showEmojiAutocomplete(emojiMatch[1]);
            } else {
                this.hideEmojiAutocomplete();
            }
        }

        // Check for commands (/ for local commands, ? for bot commands)
        if (value.startsWith('/')) {
            this.showCommandPalette(value);
        } else if (value.startsWith('?')) {
            this.showBotCommandPalette(value);
        } else {
            this.hideCommandPalette();
        }
    },

    autoResizeTextarea(textarea) {
        textarea.style.height = 'auto';
        textarea.style.height = Math.min(textarea.scrollHeight, 120) + 'px';
    },

    _emojiTokenForImg(img) {
        const code = img.dataset && img.dataset.emojiCode;
        return code ? ':' + code + ':' : (img.getAttribute('alt') || '');
    },

    _serializeRichInput(root) {
        let out = '';
        const nodes = root.childNodes;
        for (let i = 0; i < nodes.length; i++) {
            const node = nodes[i];
            if (node.nodeType === Node.TEXT_NODE) {
                out += node.nodeValue;
            } else if (node.nodeType === Node.ELEMENT_NODE) {
                if (node.tagName === 'IMG') {
                    out += this._emojiTokenForImg(node);
                } else if (node.tagName === 'BR') {
                    // A lone trailing <br> is browser filler — ignore it.
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
            if (node.tagName === 'IMG') return this._emojiTokenForImg(node).length;
            if (node.tagName === 'BR') return 1;
        }
        // Element wrappers and document fragments (from cloneContents) — sum children.
        let n = 0;
        const kids = node.childNodes;
        if (kids) for (let i = 0; i < kids.length; i++) n += this._richNodeLength(kids[i]);
        return n;
    },

    _renderRichInput(el, text) {
        el.textContent = '';
        if (!text) return;
        const frag = document.createDocumentFragment();
        const pushText = (s) => { if (s) frag.appendChild(document.createTextNode(s)); };
        const re = /:([a-zA-Z0-9_]+):/g;
        let last = 0, m;
        while ((m = re.exec(text)) !== null) {
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
        }
        pushText(text.slice(last));
        el.appendChild(frag);
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
        return this._richNodeLength(range.cloneContents());
    },

    _richLocate(el, target) {
        let acc = 0;
        const visit = (parent) => {
            const kids = parent.childNodes;
            for (let i = 0; i < kids.length; i++) {
                const child = kids[i];
                if (child.nodeType === Node.TEXT_NODE) {
                    const len = child.nodeValue.length;
                    if (target <= acc + len) return { node: child, offset: target - acc };
                    acc += len;
                } else if (child.nodeType === Node.ELEMENT_NODE && child.tagName === 'IMG') {
                    const len = this._emojiTokenForImg(child).length;
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

        // The caret only lives in window.getSelection() while the input is
        // focused; opening the emoji picker moves focus away. Remember the last
        // in-input caret so insertions land where the user left off.
        const saveSel = () => {
            const sel = window.getSelection();
            if (!sel || !sel.rangeCount) return;
            const r = sel.getRangeAt(0);
            if (!el.contains(r.startContainer)) return;
            const s = self._richSelectionOffset(el, r.startContainer, r.startOffset);
            const e = self._richSelectionOffset(el, r.endContainer, r.endOffset);
            if (s != null) el._savedSelStart = s;
            if (e != null) el._savedSelEnd = e;
        };
        el.addEventListener('keyup', saveSel);
        el.addEventListener('mouseup', saveSel);
        el.addEventListener('input', saveSel);
        el.addEventListener('focus', saveSel);

        Object.defineProperty(el, 'value', {
            configurable: true,
            get() { return self._serializeRichInput(el); },
            set(v) {
                const text = v == null ? '' : String(v);
                self._renderRichInput(el, text);
                // Mirror textarea behaviour: assigning value drops the caret at the end.
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

    // When the caret sits just after a complete :shortcode: for a known custom
    // emoji, re-render so it becomes an inline image. The :shortcode: token and
    // its emoji image share the same model length, so the caret offset is
    // unchanged by the re-render.
    _maybeRenderTypedEmoji(el) {
        if (!this.customEmojis || this.customEmojis.size === 0) return;
        const caret = el.selectionStart;
        const value = el.value;
        const m = value.slice(0, caret).match(/:([a-zA-Z0-9_]+):$/);
        if (!m || !this.customEmojis.has(m[1])) return;
        el.value = value;
        el.selectionStart = el.selectionEnd = caret;
    },

    // Insert plain text at the caret (used for Shift+Enter newlines and pastes)
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
            // Close emoji picker if open
            this.closeEnhancedEmojiModal();

            // Show GIF picker
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

        gifPicker.classList.add('active');

        // Load trending GIFs by default
        this.loadTrendingGifs();

        // Add search functionality
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

        // Resize the picker to sit above the on-screen keyboard on mobile.
        // Uses visualViewport which shrinks when the keyboard opens.
        this._setupGifPickerKeyboardResize();
    },

    _setupGifPickerKeyboardResize() {
        const gifPicker = document.getElementById('gifPicker');
        if (!gifPicker) return;

        const apply = () => {
            if (!gifPicker.classList.contains('active')) return;
            // Only adjust where the picker is fixed-positioned (mobile layout,
            // matching the <=768px CSS media query).
            if (window.innerWidth > 768 || !window.visualViewport) {
                gifPicker.style.bottom = '';
                gifPicker.style.maxHeight = '';
                return;
            }
            const vv = window.visualViewport;
            // Keyboard height is the slice of the layout viewport the visual
            // viewport lost — independent of how far the page has scrolled
            // (vv.offsetTop), so it stays correct after the focused field
            // scrolls into view.
            const keyboardOffset = Math.max(0, window.innerHeight - vv.height);
            if (keyboardOffset < 80) {
                // Keyboard closed — fall back to the CSS-defined placement.
                gifPicker.style.bottom = '';
                gifPicker.style.maxHeight = '';
                return;
            }
            // Sit just above the keyboard and cap the height to the visible area.
            gifPicker.style.bottom = (keyboardOffset + 8) + 'px';
            gifPicker.style.maxHeight = Math.max(180, vv.height - 24) + 'px';
        };

        if (this._gifViewportHandler && window.visualViewport) {
            window.visualViewport.removeEventListener('resize', this._gifViewportHandler);
            window.visualViewport.removeEventListener('scroll', this._gifViewportHandler);
        }
        this._gifViewportHandler = apply;
        if (window.visualViewport) {
            window.visualViewport.addEventListener('resize', apply);
            window.visualViewport.addEventListener('scroll', apply);
        }

        // The keyboard animation may not have settled when the first resize
        // event fires, so re-apply shortly after the search field is focused.
        const searchInput = gifPicker.querySelector('#gifSearchInput');
        if (searchInput) {
            searchInput.addEventListener('focus', () => {
                setTimeout(apply, 100);
                setTimeout(apply, 350);
            });
            searchInput.addEventListener('blur', () => setTimeout(apply, 100));
        }

        apply();
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

        // Re-render the current view from cached results so favorites/stars update
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
        <img src="${safeProxied}" alt="${safeTitle}" loading="lazy">
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
            item.onclick = () => this.insertGif(item.dataset.gifUrl);
        });
    },

    insertGif(gifUrl) {
        const input = document.getElementById('messageInput');
        const start = input.selectionStart;
        const end = input.selectionEnd;
        const text = input.value;

        // Insert GIF URL at cursor position
        const newText = text.substring(0, start) + gifUrl + text.substring(end);
        input.value = newText;

        // Position cursor after the inserted URL
        const newPosition = start + gifUrl.length;
        input.selectionStart = input.selectionEnd = newPosition;
        input.focus();

        // Close the GIF picker
        this.closeGifPicker();
    },

    closeGifPicker() {
        const gifPicker = document.getElementById('gifPicker');
        const wasOpen = gifPicker.classList.contains('active');
        gifPicker.classList.remove('active');
        gifPicker.innerHTML = '';
        gifPicker.style.bottom = '';
        gifPicker.style.maxHeight = '';
        if (this._gifViewportHandler && window.visualViewport) {
            window.visualViewport.removeEventListener('resize', this._gifViewportHandler);
            window.visualViewport.removeEventListener('scroll', this._gifViewportHandler);
            this._gifViewportHandler = null;
        }
        if (wasOpen && typeof this._focusMessageInput === 'function') this._focusMessageInput();
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
