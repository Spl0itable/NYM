// polls.js - Poll creation, voting, display, channel poll list
// Methods are attached to NYM.prototype.

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
        const nym = nymTag ? this.stripPubkeySuffix(nymTag[1]) : 'anon';
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
        messageEl.className = 'message poll-message';
        messageEl.dataset.messageId = pollId;
        messageEl.dataset.pollId = pollId;

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
            '<span class="supporter-badge"><span class="supporter-badge-icon">🏆</span><span class="supporter-badge-text">Supporter</span></span>' : '';
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
                return `<img src="${this.escapeHtml(vAvatar)}" class="poll-voter-avatar" title="${this.escapeHtml(vNym)}" alt="" onerror="this.onerror=null;this.src='https://robohash.org/${sk}.png?set=set1&size=80x80'">`;
            }).join('');
            const extraCount = count > 8 ? `<span class="poll-voter-extra">+${count - 8}</span>` : '';

            const selectedClass = hasVoted && votes.get(this.pubkey) === opt.index ? ' poll-option-selected' : '';

            return `
                <div class="poll-option${selectedClass}" data-poll-id="${pollId}" data-option-index="${opt.index}" onclick="nym.votePoll('${pollId}', ${opt.index})">
                    <div class="poll-option-bar" style="width: ${pct}%"></div>
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
        const displayAuthor = `<img src="${this.escapeHtml(avatarSrc)}" class="avatar-message" data-avatar-pubkey="${safePk}" alt="" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${safePk}.png?set=set1&size=80x80'">&lt;${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>${flairHtml}`;

        messageEl.innerHTML = `
            <span class="message-time" data-full-time="${fullTimestamp}" title="${fullTimestamp}">${timeStr}</span>
            <span class="message-author ${isOwn ? 'self' : ''} ${userColorClass}"><span class="bubble-time" data-full-time="${fullTimestamp}" title="${fullTimestamp}">${timeStr}</span><span class="author-clickable">${displayAuthor}${verifiedBadge}${supporterBadge}</span>&gt;</span>
            <div class="message-content">
                <div class="poll-container" data-poll-id="${pollId}">
                    <div class="poll-header">📊 Poll</div>
                    <div class="poll-question">${this.escapeHtml(question)}</div>
                    <div class="poll-options">${optionsHtml}</div>
                    <div class="poll-footer">${totalVotes} vote${totalVotes !== 1 ? 's' : ''}</div>
                </div>
                <span class="bubble-time-inner" data-full-time="${fullTimestamp}" title="${fullTimestamp}">${timeStr}</span>
            </div>
        `;

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

        // Insert in correct chronological order using created_at (integer seconds),
        // consistent with regular message DOM insertion in displayMessage().
        {
            const existingMessages = Array.from(container.querySelectorAll('[data-created-at]'));
            const msgCreatedAt = pollCreatedAt;

            let insertBefore = null;
            for (const existing of existingMessages) {
                const existingCreatedAt = parseInt(existing.dataset.createdAt) || 0;
                if (msgCreatedAt < existingCreatedAt) {
                    insertBefore = existing;
                    break;
                }
                if (msgCreatedAt === existingCreatedAt) {
                    const existingSeq = parseInt(existing.dataset.seq) || 0;
                    // Polls use seq=0, so they sort before same-second messages
                    if (0 < existingSeq) {
                        insertBefore = existing;
                        break;
                    }
                }
            }

            if (insertBefore) {
                container.insertBefore(messageEl, insertBefore);
            } else {
                container.appendChild(messageEl);
            }
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

        const optionsEl = container.querySelector('.poll-options');
        optionsEl.innerHTML = poll.options.map(opt => {
            const optVotes = Array.from(poll.votes.entries()).filter(([, idx]) => idx === opt.index);
            const count = optVotes.length;
            const pct = totalVotes > 0 ? Math.round((count / totalVotes) * 100) : 0;

            const voterAvatars = optVotes.slice(0, 8).map(([vpk]) => {
                const sk = this._safePubkey(vpk);
                const vAvatar = this.getAvatarUrl(vpk);
                const vNym = this.getNymFromPubkey(vpk);
                const vSuffix = this.getPubkeySuffix(vpk);
                return `<img src="${this.escapeHtml(vAvatar)}" class="poll-voter-avatar" title="${this.escapeHtml(vNym)}" alt="" onerror="this.onerror=null;this.src='https://robohash.org/${sk}.png?set=set1&size=80x80'">`;
            }).join('');
            const extraCount = count > 8 ? `<span class="poll-voter-extra">+${count - 8}</span>` : '';

            const selectedClass = hasVoted && poll.votes.get(this.pubkey) === opt.index ? ' poll-option-selected' : '';

            return `
                <div class="poll-option${selectedClass}" data-poll-id="${pollId}" data-option-index="${opt.index}" onclick="nym.votePoll('${pollId}', ${opt.index})">
                    <div class="poll-option-bar" style="width: ${pct}%"></div>
                    <div class="poll-option-content">
                        <span class="poll-option-text">${this.escapeHtml(opt.text)}</span>
                        <span class="poll-option-pct">${totalVotes > 0 ? pct + '%' : ''}</span>
                    </div>
                    <div class="poll-voters">${voterAvatars}${extraCount}</div>
                </div>
            `;
        }).join('');

        const pollFooter = container.querySelector('.poll-footer');
        if (pollFooter) pollFooter.textContent = `${totalVotes} vote${totalVotes !== 1 ? 's' : ''}`;
    },

    renderChannelPolls() {
        const geohash = this.currentGeohash;
        if (!geohash) return;

        const container = document.getElementById('messagesContainer');
        if (!container) return;

        // Collect polls for this channel, sorted by created_at
        const channelPolls = [];
        for (const [pollId, poll] of this.polls) {
            if (poll.geohash === geohash && !container.querySelector(`[data-poll-id="${pollId}"]`)) {
                channelPolls.push([pollId, poll]);
            }
        }

        if (channelPolls.length === 0) return;

        channelPolls.sort((a, b) => a[1].created_at - b[1].created_at);

        for (const [pollId, poll] of channelPolls) {
            const nym = poll.nym || 'anon';
            const isOwn = poll.pubkey === this.pubkey;
            this.displayPollMessage(pollId, nym, poll.pubkey, poll.question, poll.options, poll.votes, poll.created_at, isOwn);
        }
    },

});
