// polls.js - Poll creation, voting, display, channel poll list

Object.assign(NYM.prototype, {

    async publishPoll(question, options) {
        if (!this.connected || !this.currentGeohash) {
            this.displaySystemMessage('Not connected or no channel selected.');
            return;
        }

        const now = Math.floor(Date.now() / 1000);
        const pollUniqueId = Math.random().toString(36).substring(2, 10);
        const tags = [
            ['d', `nym-poll-${pollUniqueId}`],
            ['t', 'nym-poll'],
            ['n', this.nym],
            ['g', this.currentGeohash],
            ['poll_question', question],
        ];
        options.forEach((opt, i) => {
            tags.push(['poll_option', String(i), opt]);
        });

        let event = {
            kind: 30078,
            created_at: now,
            tags: tags,
            content: question,
            pubkey: this.pubkey
        };

        const signedEvent = await this.signEvent(event);
        this.sendToRelay(["EVENT", signedEvent]);
        this.ensureGeoRelayDelivery(signedEvent, this.currentGeohash);

        // Store poll locally
        this.polls.set(signedEvent.id, {
            question,
            options: options.map((text, i) => ({ index: i, text })),
            votes: new Map(), // pubkey -> optionIndex
            pubkey: this.pubkey,
            nym: this.nym,
            geohash: this.currentGeohash,
            created_at: now
        });

        // Display poll as a message
        this.displayPollMessage(signedEvent.id, this.nym, this.pubkey, question, options.map((text, i) => ({ index: i, text })), new Map(), now, true);
    },

    async votePoll(pollId, optionIndex) {
        if (!this.connected) {
            this.displaySystemMessage('Not connected to relay.');
            return;
        }

        const poll = this.polls.get(pollId);
        if (!poll) return;

        // Check if user already voted
        if (poll.votes.has(this.pubkey)) {
            this.displaySystemMessage('You have already voted on this poll.');
            return;
        }

        const now = Math.floor(Date.now() / 1000);
        const tags = [
            ['d', `nym-poll-vote-${pollId}`],
            ['t', 'nym-poll-vote'],
            ['e', pollId],
            ['n', this.nym],
            ['g', poll.geohash],
            ['response', String(optionIndex)]
        ];

        let event = {
            kind: 30078,
            created_at: now,
            tags: tags,
            content: '',
            pubkey: this.pubkey
        };

        const signedEvent = await this.signEvent(event);
        this.sendToRelay(["EVENT", signedEvent]);
        this.ensureGeoRelayDelivery(signedEvent, poll.geohash);

        // Update local state
        poll.votes.set(this.pubkey, optionIndex);
        this.updatePollDisplay(pollId);
    },

    handlePollEvent(event) {
        // Check expiration tag - skip expired polls
        const expirationTag = event.tags.find(t => t[0] === 'expiration');
        if (expirationTag) {
            const expiresAt = parseInt(expirationTag[1]);
            if (expiresAt && expiresAt < Math.floor(Date.now() / 1000)) {
                return; // Poll has expired
            }
        }

        const questionTag = event.tags.find(t => t[0] === 'poll_question');
        const optionTags = event.tags.filter(t => t[0] === 'poll_option');
        const nymTag = event.tags.find(t => t[0] === 'n');
        const geohashTag = event.tags.find(t => t[0] === 'g');

        if (!questionTag || optionTags.length < 2) return;

        const question = questionTag[1];
        const options = optionTags.map(t => ({ index: parseInt(t[1]), text: t[2] }));
        const nym = nymTag ? this.stripPubkeySuffix(nymTag[1]) : 'nym';
        const geohash = geohashTag ? geohashTag[1] : '';

        if (!this.polls.has(event.id)) {
            const poll = {
                question,
                options,
                votes: new Map(),
                pubkey: event.pubkey,
                nym,
                geohash,
                created_at: event.created_at
            };
            this.polls.set(event.id, poll);

            // Replay any buffered votes that arrived before this poll
            if (this.pendingPollVotes.has(event.id)) {
                for (const vote of this.pendingPollVotes.get(event.id)) {
                    if (!poll.votes.has(vote.pubkey)) {
                        poll.votes.set(vote.pubkey, vote.optionIndex);
                    }
                }
                this.pendingPollVotes.delete(event.id);
            }

            // Only display if it's for the current channel
            if (geohash === this.currentGeohash) {
                this.displayPollMessage(event.id, nym, event.pubkey, question, options, poll.votes, event.created_at, event.pubkey === this.pubkey);
            }
        }
    },

    handlePollVoteEvent(event) {
        if (this.processedPollVoteIds.has(event.id)) return;
        this.processedPollVoteIds.add(event.id);

        // Check expiration tag - skip expired poll votes
        const expirationTag = event.tags.find(t => t[0] === 'expiration');
        if (expirationTag) {
            const expiresAt = parseInt(expirationTag[1]);
            if (expiresAt && expiresAt < Math.floor(Date.now() / 1000)) {
                return;
            }
        }

        // Prune if too large
        if (this.processedPollVoteIds.size > 3000) {
            const arr = Array.from(this.processedPollVoteIds);
            this.processedPollVoteIds = new Set(arr.slice(-2000));
        }

        const eTag = event.tags.find(t => t[0] === 'e');
        const responseTag = event.tags.find(t => t[0] === 'response');
        if (!eTag || !responseTag) return;

        const pollId = eTag[1];
        const optionIndex = parseInt(responseTag[1]);

        const poll = this.polls.get(pollId);
        if (!poll) {
            // Poll hasn't arrived yet — buffer the vote for when it does
            if (!this.pendingPollVotes.has(pollId)) {
                this.pendingPollVotes.set(pollId, []);
            }
            this.pendingPollVotes.get(pollId).push({ pubkey: event.pubkey, optionIndex });
            return;
        }

        // Don't allow double-voting
        if (poll.votes.has(event.pubkey)) return;

        poll.votes.set(event.pubkey, optionIndex);
        this.updatePollDisplay(pollId);
    },

    displayPollMessage(pollId, nym, pubkey, question, options, votes, created_at, isOwn) {
        const container = document.getElementById('messagesContainer');
        const messageEl = document.createElement('div');
        const pollUserShopItems = this.getUserShopItems(pubkey);
        const pollClasses = ['message', 'poll-message'];
        if (isOwn) pollClasses.push('self');
        if (pollUserShopItems?.style) pollClasses.push(pollUserShopItems.style);
        if (pollUserShopItems?.supporter) pollClasses.push('supporter-style');
        if (Array.isArray(pollUserShopItems?.cosmetics) &&
            pollUserShopItems.cosmetics.includes('cosmetic-aura-gold')) {
            pollClasses.push('cosmetic-aura-gold');
        }
        messageEl.className = pollClasses.join(' ');
        messageEl.dataset.messageId = pollId;
        messageEl.dataset.pollId = pollId;
        messageEl.dataset.pubkey = pubkey;
        messageEl.dataset.author = nym;

        const avatarSrc = this.getAvatarUrl(pubkey);
        const suffix = this.getPubkeySuffix(pubkey);
        const baseNym = this.stripPubkeySuffix(nym);

        const pollCreatedAt = Math.floor(created_at) || 0;
        const timestamp = new Date(pollCreatedAt * 1000);
        // Clamp timestamp to now so polls never appear in the future
        const now = new Date();
        const displayTimestamp = timestamp > now ? now : timestamp;
        messageEl.dataset.timestamp = displayTimestamp.getTime();
        messageEl.dataset.createdAt = pollCreatedAt;
        messageEl.dataset.ms = pollCreatedAt * 1000; // no millisecond stamp; sort at the second boundary
        messageEl.dataset.seq = 0; // polls have no arrival sequence; use 0 for consistent tiebreaking

        const timeStr = displayTimestamp.toLocaleTimeString([], {
            hour: '2-digit',
            minute: '2-digit',
            hour12: this.settings?.timeFormat === '12hr'
        });

        // Get user's shop items for styling (badges, flair, etc.)
        const userShopItems = this.getUserShopItems(pubkey);
        const flairHtml = this.getFlairForUser(pubkey);
        const supporterBadge = userShopItems?.supporter ?
            `<span class="supporter-badge"><span class="supporter-badge-icon">${this.getSupporterTrophyIcon()}</span><span class="supporter-badge-text">Supporter</span></span>` : '';
        const verifiedBadge = this.isVerifiedDeveloper(pubkey)
            ? `<span class="verified-badge" title="${this.verifiedDeveloper.title}">✓</span>`
            : this.isVerifiedBot(pubkey)
                ? '<span class="verified-badge" title="Nymchat Bot">✓</span>'
                : '';
        const userColorClass = this.getUserColorClass(pubkey);

        const totalVotes = votes.size;
        const hasVoted = votes.has(this.pubkey);

        let optionsHtml = options.map(opt => {
            const optVotes = Array.from(votes.entries()).filter(([, idx]) => idx === opt.index);
            const count = optVotes.length;
            const pct = totalVotes > 0 ? Math.round((count / totalVotes) * 100) : 0;

            // Voter avatars
            const voterAvatars = optVotes.slice(0, 8).map(([vpk]) => {
                const sk = this._safePubkey(vpk);
                const vAvatar = this.getAvatarUrl(vpk);
                const vNym = this.getNymFromPubkey(vpk);
                const vSuffix = this.getPubkeySuffix(vpk);
                return `<img src="${this.escapeHtml(vAvatar)}" class="poll-voter-avatar" data-avatar-pubkey="${sk}" title="${this.escapeHtml(vNym)}" alt="" decoding="async" loading="lazy">`;
            }).join('');
            const extraCount = count > 8 ? `<span class="poll-voter-extra">+${count - 8}</span>` : '';

            const selectedClass = hasVoted && votes.get(this.pubkey) === opt.index ? ' poll-option-selected' : '';

            return `
                <div class="poll-option${selectedClass}" data-poll-id="${pollId}" data-option-index="${opt.index}" data-action="votePoll">
                    <div class="poll-option-bar" data-pct="${pct}"></div>
                    <div class="poll-option-content">
                        <span class="poll-option-text">${this.escapeHtml(opt.text)}</span>
                        <span class="poll-option-pct">${totalVotes > 0 ? pct + '%' : ''}</span>
                    </div>
                    <div class="poll-voters">${voterAvatars}${extraCount}</div>
                </div>
            `;
        }).join('');

        // Prepare full timestamp for tooltip
        const fullTimestamp = displayTimestamp.toLocaleString('en-US', {
            year: 'numeric',
            month: 'short',
            day: 'numeric',
            hour: '2-digit',
            minute: '2-digit',
            second: '2-digit',
            hour12: this.settings?.timeFormat === '12hr'
        });

        const safePk = this._safePubkey(pubkey);
        const displayAuthor = `<img src="${this.escapeHtml(avatarSrc)}" class="avatar-message" data-avatar-pubkey="${safePk}" alt="" decoding="async" loading="lazy"><span class="nym-bracket">&lt;</span>${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>${flairHtml}`;

        const isMobile = window.innerWidth <= 768;
        const hoverButtons = !isMobile ? `
    <div class="msg-hover-buttons">
        <button class="reaction-btn" data-action="reactionShowPicker" data-message-id="${pollId}">
            <svg viewBox="0 0 20 20" class="nm-msg-2">
                <path fill-rule="evenodd" clip-rule="evenodd" d="M15.5 1a.75.75 0 0 1 .75.75v2h2a.75.75 0 0 1 0 1.5h-2v2a.75.75 0 0 1-1.5 0v-2h-2a.75.75 0 0 1 0-1.5h2v-2A.75.75 0 0 1 15.5 1m-13 10a6.5 6.5 0 0 1 7.166-6.466.75.75 0 0 0 .152-1.493 8 8 0 1 0 7.14 7.139.75.75 0 0 0-1.492.152A7 7 0 0 1 15.5 11a6.5 6.5 0 1 1-13 0m4.25-.5a1.25 1.25 0 1 0 0-2.5 1.25 1.25 0 0 0 0 2.5m4.5 0a1.25 1.25 0 1 0 0-2.5 1.25 1.25 0 0 0 0 2.5M9 15c1.277 0 2.553-.724 3.06-2.173.148-.426-.209-.827-.66-.827H6.6c-.452 0-.808.4-.66.827C6.448 14.276 7.724 15 9 15"></path>
            </svg>
        </button>
        <button class="translate-msg-btn" data-action="translateHoverMessage" title="Translate">
            <svg viewBox="0 0 24 24">
                <path d="m12.87 15.07-2.54-2.51.03-.03A17.52 17.52 0 0 0 14.07 6H17V4h-7V2H8v2H1v1.99h11.17C11.5 7.92 10.44 9.75 9 11.35 8.07 10.32 7.3 9.19 6.69 8h-2c.73 1.63 1.73 3.17 2.98 4.56l-5.09 5.02L4 19l5-5 3.11 3.11.76-2.04zM18.5 10h-2L12 22h2l1.12-3h4.75L21 22h2l-4.5-12zm-2.62 7 1.62-4.33L19.12 17h-3.24z"/>
            </svg>
        </button>
    </div>
` : '';

        messageEl.innerHTML = `
            <span class="message-time clickable-timestamp" data-full-time="${fullTimestamp}" title="${fullTimestamp}" data-action="showFullTimestamp">${timeStr}</span>
            <span class="message-author ${isOwn ? 'self' : ''} ${userColorClass}"><span class="bubble-time clickable-timestamp" data-full-time="${fullTimestamp}" title="${fullTimestamp}" data-action="showFullTimestamp">${timeStr}</span><span class="author-clickable">${displayAuthor}${verifiedBadge}${supporterBadge}</span><span class="nym-bracket">&gt;</span></span>
            <div class="message-content">
                <div class="poll-container" data-poll-id="${pollId}">
                    <div class="poll-header">📊 Poll</div>
                    <div class="poll-question">${this.escapeHtml(question)}</div>
                    <div class="poll-options">${optionsHtml}</div>
                    <div class="poll-footer" data-action="showPollVoters" data-poll-id="${pollId}">${totalVotes} vote${totalVotes !== 1 ? 's' : ''}</div>
                </div>
                <span class="bubble-time-inner clickable-timestamp" data-full-time="${fullTimestamp}" title="${fullTimestamp}" data-action="showFullTimestamp"><span class="bubble-time-text">${document.body.classList.contains('chat-bubbles') ? this._formatRelativeTime(displayTimestamp.getTime()) : timeStr}</span></span>${hoverButtons}
            </div>
        `;
        messageEl.querySelectorAll('.poll-option-bar[data-pct]').forEach(b => { b.style.width = b.dataset.pct + '%'; });

        // Add context menu to poll author (same as regular messages)
        const authorClickable = messageEl.querySelector('.author-clickable');
        if (authorClickable) {
            authorClickable.style.cursor = 'pointer';
            authorClickable.addEventListener('click', (e) => {
                e.preventDefault();
                e.stopPropagation();
                this.showContextMenu(e, displayAuthor, pubkey, `[Poll] ${question}`, pollId);
                return false;
            });
        }

        // Walk all timestamped descendants; in bubble mode messages live inside
        // .message-group > .message-group-stack, so the target may not be a
        // direct child of container — insert against the target's parent.
        {
            const existingMessages = Array.from(container.querySelectorAll('[data-created-at]'));
            const msgMs = pollCreatedAt * 1000;

            let insertBefore = null;
            for (const existing of existingMessages) {
                if (existing === messageEl) continue;
                const existingCreatedAt = parseInt(existing.dataset.createdAt) || 0;
                const existingMs = parseInt(existing.dataset.ms) || (existingCreatedAt * 1000);
                if (msgMs < existingMs) {
                    insertBefore = existing;
                    break;
                }
                if (msgMs === existingMs) {
                    const existingSeq = parseInt(existing.dataset.seq) || 0;
                    if (0 < existingSeq) {
                        insertBefore = existing;
                        break;
                    }
                }
            }

            if (insertBefore && insertBefore.parentNode) {
                insertBefore.parentNode.insertBefore(messageEl, insertBefore);
            } else {
                container.appendChild(messageEl);
            }
        }

        if (typeof this.ensureListProfiles === 'function') {
            this.ensureListProfiles(messageEl, [pubkey, ...votes.keys()]);
        }

        // In bubble layout polls need their own .message-group wrapper to get
        // the side avatar; the rewrap also splits adjacent same-author groups.
        if (!this._suppressBubbleRewrap
            && typeof this._rewrapBubbleGroups === 'function'
            && document.body.classList.contains('chat-bubbles')) {
            this._rewrapBubbleGroups(container);
        }

        this._scheduleScrollToBottom();
    },

    updatePollDisplay(pollId) {
        const poll = this.polls.get(pollId);
        if (!poll) return;

        const container = document.querySelector(`.poll-container[data-poll-id="${pollId}"]`);
        if (!container) return;

        const totalVotes = poll.votes.size;
        const hasVoted = poll.votes.has(this.pubkey);

        // Update each option in place so existing voter <img> nodes aren't
        // destroyed (an innerHTML rebuild made every avatar flicker on each vote).
        for (const opt of poll.options) {
            const optionEl = container.querySelector(`.poll-option[data-option-index="${opt.index}"]`);
            if (!optionEl) continue;

            const optVotes = Array.from(poll.votes.entries()).filter(([, idx]) => idx === opt.index);
            const count = optVotes.length;
            const pct = totalVotes > 0 ? Math.round((count / totalVotes) * 100) : 0;

            const bar = optionEl.querySelector('.poll-option-bar');
            if (bar) {
                bar.dataset.pct = pct;
                bar.style.width = pct + '%';
            }
            const pctEl = optionEl.querySelector('.poll-option-pct');
            if (pctEl) pctEl.textContent = totalVotes > 0 ? pct + '%' : '';

            optionEl.classList.toggle('poll-option-selected', hasVoted && poll.votes.get(this.pubkey) === opt.index);

            const votersEl = optionEl.querySelector('.poll-voters');
            if (votersEl) {
                const visibleVoters = optVotes.slice(0, 8).map(([vpk]) => vpk);
                const wantedKeys = visibleVoters.map(vpk => this._safePubkey(vpk));

                const currentImgs = Array.from(votersEl.querySelectorAll('img.poll-voter-avatar'));
                const orderMatches = currentImgs.length === wantedKeys.length
                    && currentImgs.every((img, i) => img.dataset.avatarPubkey === wantedKeys[i]);

                let extraEl = votersEl.querySelector('.poll-voter-extra');

                if (!orderMatches) {
                    const byKey = new Map();
                    for (const img of currentImgs) byKey.set(img.dataset.avatarPubkey, img);
                    for (const img of currentImgs) img.remove();
                    if (extraEl) extraEl.remove();
                    for (let i = 0; i < wantedKeys.length; i++) {
                        const sk = wantedKeys[i];
                        let img = byKey.get(sk);
                        if (!img) {
                            img = document.createElement('img');
                            img.src = this.getAvatarUrl(visibleVoters[i]);
                            img.className = 'poll-voter-avatar';
                            img.dataset.avatarPubkey = sk;
                            img.title = this.getNymFromPubkey(visibleVoters[i]);
                            img.alt = '';
                            img.loading = 'lazy';
                        }
                        votersEl.appendChild(img);
                    }
                }

                if (count > 8) {
                    if (!extraEl || !extraEl.isConnected) {
                        extraEl = document.createElement('span');
                        extraEl.className = 'poll-voter-extra';
                        votersEl.appendChild(extraEl);
                    }
                    extraEl.textContent = `+${count - 8}`;
                } else if (extraEl) {
                    extraEl.remove();
                }
            }
        }

        const pollFooter = container.querySelector('.poll-footer');
        if (pollFooter) pollFooter.textContent = `${totalVotes} vote${totalVotes !== 1 ? 's' : ''}`;

        if (typeof this.ensureListProfiles === 'function') {
            this.ensureListProfiles(container, [...poll.votes.keys()]);
        }
    },

    showPollVotersModal(pollId, anchorEl, ev) {
        if (ev && typeof ev.stopPropagation === 'function') ev.stopPropagation();
        const poll = this.polls.get(pollId);
        if (!poll || poll.votes.size === 0) return;

        this.closePollVotersModal();

        const optionLabel = new Map(poll.options.map(o => [o.index, o.text]));
        const MAX_ROWS = 100;
        const entries = Array.from(poll.votes.entries());
        const shown = entries.slice(0, MAX_ROWS);
        const rows = shown.map(([pubkey, optIdx]) => {
            const isYou = pubkey === this.pubkey;
            const knownUser = this.users && this.users.get && this.users.get(pubkey);
            const nym = knownUser ? this.parseNymFromDisplay(knownUser.nym) : (this.getNymFromPubkey ? this.getNymFromPubkey(pubkey) : 'nym');
            const suffix = this.getPubkeySuffix(pubkey);
            const choice = optionLabel.has(optIdx) ? optionLabel.get(optIdx) : `Option ${optIdx + 1}`;
            const avatar = this.getAvatarUrl(pubkey);
            const sk = this._safePubkey(pubkey);
            return `<div class="reactors-modal-user poll-voters-row" data-pubkey="${pubkey}">
                <img src="${this.escapeHtml(avatar)}" class="poll-voter-avatar" data-avatar-pubkey="${sk}" alt="" decoding="async" loading="lazy">
                <span class="reactors-modal-nym">${this.escapeHtml(nym)}<span class="nym-suffix">#${suffix}</span></span>
                ${isYou ? '<span class="reactors-modal-you">you</span>' : ''}
                <span class="poll-voters-choice">${this.escapeHtml(choice)}</span>
            </div>`;
        }).join('');
        const overflow = entries.length - shown.length;
        const overflowItem = overflow > 0 ? `<div class="reactors-modal-more">+${overflow} more</div>` : '';

        const modal = document.createElement('div');
        modal.className = 'reactors-modal poll-voters-modal';
        modal.innerHTML = `
            <div class="reactors-modal-header"><span>📊 Voters</span> <span class="reactors-modal-count">${poll.votes.size}</span></div>
            <div class="reactors-modal-list">${rows}${overflowItem}</div>
        `;
        document.body.appendChild(modal);
        this._pollVotersModal = modal;

        if (typeof this.ensureListProfiles === 'function') {
            this.ensureListProfiles(modal, shown.map(([pk]) => pk));
        }

        const rect = anchorEl.getBoundingClientRect();
        const modalRect = modal.getBoundingClientRect();
        let left = rect.left;
        if (left + modalRect.width > window.innerWidth - 10) {
            left = window.innerWidth - modalRect.width - 10;
        }
        if (left < 10) left = 10;
        modal.style.left = left + 'px';
        const spaceAbove = rect.top;
        if (spaceAbove > modalRect.height + 10) {
            modal.style.bottom = (window.innerHeight - rect.top + 6) + 'px';
        } else {
            modal.style.top = (rect.bottom + 6) + 'px';
        }

        modal.querySelectorAll('.poll-voters-row').forEach(el => {
            el.addEventListener('click', (e) => {
                e.stopPropagation();
                const pk = el.dataset.pubkey;
                if (pk && pk !== this.pubkey) {
                    const user = this.users.get(pk);
                    const baseNym = user ? this.parseNymFromDisplay(user.nym) : 'nym';
                    if (typeof this.openUserPM === 'function') this.openUserPM(baseNym, pk);
                }
                this.closePollVotersModal();
            });
        });

        const onDocClick = (e) => {
            if (!modal.contains(e.target) && e.target !== anchorEl) {
                this.closePollVotersModal();
            }
        };
        setTimeout(() => document.addEventListener('click', onDocClick), 0);
        this._pollVotersModalCloser = () => document.removeEventListener('click', onDocClick);
    },

    closePollVotersModal() {
        if (this._pollVotersModal) {
            this._pollVotersModal.remove();
            this._pollVotersModal = null;
        }
        if (this._pollVotersModalCloser) {
            this._pollVotersModalCloser();
            this._pollVotersModalCloser = null;
        }
    },

    renderChannelPolls() {
        const geohash = this.currentGeohash;
        if (!geohash) return;

        const container = document.getElementById('messagesContainer');
        if (!container) return;

        const channelPolls = [];
        for (const [pollId, poll] of this.polls) {
            if (poll.geohash !== geohash) continue;
            if (container.querySelector(`[data-poll-id="${pollId}"]`)) {
                this.updatePollDisplay(pollId);
            } else {
                channelPolls.push([pollId, poll]);
            }
        }

        if (channelPolls.length === 0) return;

        channelPolls.sort((a, b) => a[1].created_at - b[1].created_at);

        const prevSuppress = this._suppressBubbleRewrap;
        this._suppressBubbleRewrap = true;
        try {
            for (const [pollId, poll] of channelPolls) {
                const nym = poll.nym || 'nym';
                const isOwn = poll.pubkey === this.pubkey;
                this.displayPollMessage(pollId, nym, poll.pubkey, poll.question, poll.options, poll.votes, poll.created_at, isOwn);
            }
        } finally {
            this._suppressBubbleRewrap = prevSuppress;
        }

        if (typeof this._rewrapBubbleGroups === 'function'
            && document.body.classList.contains('chat-bubbles')) {
            this._rewrapBubbleGroups(container);
        }
    },

});
