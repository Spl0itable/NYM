// commands.js - Slash-command parsing and handlers (cmdJoin, cmdNick, cmdZap, ...) plus bot commands and palette

Object.assign(NYM.prototype, {

    // Add a command for sharing
    async cmdShare() {
        this.shareChannel();
    },

    async _handleBotCommand(content, geohash, quoteContext, publishedContent) {
        if (!this.useRelayProxy) return;
        // Support @Nymbot mentions anywhere in the message as an alias for ?ask
        const mentionRegex = /@nymbot(?:#[a-f0-9]{4})?/i;
        if (mentionRegex.test(content) && !content.startsWith('?')) {
            // Remove the @nymbot mention and use the rest as the question
            const question = content.replace(mentionRegex, '').trim();
            if (question) {
                content = '?ask ' + question;
            } else if (quoteContext && quoteContext.text) {
                // User just typed @Nymbot with no question — use the quoted text as the question
                const quotedText = quoteContext.text.replace(/^>\s*@[^:]+:\s*/gm, '').replace(/^>\s?/gm, '').trim();
                if (quotedText) {
                    content = '?ask ' + quotedText;
                }
            }
        }
        // If replying to a Nymbot message without an explicit command, treat as ?ask or ?guess
        if (quoteContext && /^nymbot(?:#[a-f0-9]{4})?$/i.test(quoteContext.author)) {
            if (!content.startsWith('?')) {
                // If the quoted message contains a wordplay game token, route to ?guess
                const hasGameToken = quoteContext.text && /\[gc:[A-Za-z0-9+/=]+\]/.test(quoteContext.text);
                content = hasGameToken ? '?guess ' + content : '?ask ' + content;
            }
        }
        const prefix = '?';
        if (!content.startsWith(prefix)) return;
        const parts = content.slice(prefix.length).trim().split(/\s+/);
        const command = parts[0];
        const args = parts.slice(1).join(' ');
        if (!command) return;
        // Build conversation context from quote chain for ?ask and ?guess commands
        let conversation = [];
        if (quoteContext && ['ask', 'guess'].includes(command.toLowerCase())) {
            conversation = this._extractQuoteChain(quoteContext);
        }
        // Gather channel context for AI-aware commands (ask, summarize)
        let channelMessages = [];
        let activeUsers = [];
        const aiCommands = ['ask', 'summarize'];
        if (aiCommands.includes(command.toLowerCase())) {
            const msgLimit = 100;
            // Check if the user referenced specific channels with #hashtags in their ?ask
            // e.g. "?ask #dr5r what's happening there?" pulls context from #dr5r
            const referencedChannels = new Set();
            if (command.toLowerCase() === 'ask' && args) {
                const channelRefRegex = /(?:^|[^a-z0-9])#([a-z0-9_-]+)/gi;
                let channelRefMatch;
                const channelRefNames = [];
                while ((channelRefMatch = channelRefRegex.exec(args)) !== null) {
                    channelRefNames.push(channelRefMatch[1].toLowerCase());
                }
                if (channelRefNames.length > 0) {
                    const channelsToFetch = [];
                    for (const name of channelRefNames) {
                        // Case-insensitive lookup across messages Map
                        let found = false;
                        // Exact match (case-sensitive) first
                        if (this.messages.has(`#${name}`)) {
                            referencedChannels.add(`#${name}`);
                            found = true;
                        }
                        if (!found) {
                            // Case-insensitive and bidirectional prefix match
                            for (const key of this.messages.keys()) {
                                if (!key.startsWith('#')) continue;
                                const stored = key.substring(1).toLowerCase();
                                if (stored === name || stored.startsWith(name) || name.startsWith(stored)) {
                                    referencedChannels.add(key);
                                    found = true;
                                    break;
                                }
                            }
                        }
                        // Also check sidebar channels Map (may have channel with no messages yet)
                        if (!found) {
                            for (const chanKey of this.channels.keys()) {
                                if (chanKey.toLowerCase() === name || chanKey.toLowerCase().startsWith(name) || name.startsWith(chanKey.toLowerCase())) {
                                    const storeKey = `#${chanKey}`;
                                    referencedChannels.add(storeKey);
                                    found = true;
                                    break;
                                }
                            }
                        }
                        // Not found anywhere — queue for relay fetch
                        if (!found) {
                            const chanType = this.isValidGeohash(name) ? 'geohash' : 'standard';
                            channelsToFetch.push({ name, type: chanType });
                            referencedChannels.add(`#${name}`);
                        }
                    }
                    // Fetch any channels we don't have messages for from relays
                    if (channelsToFetch.length > 0) {
                        for (const ch of channelsToFetch) {
                            this.channelLoadedFromRelays.delete(ch.name);
                            this.subscribeToChannelTargeted(ch.name, ch.type);
                        }
                        // Brief wait for relay messages to arrive
                        await new Promise(r => setTimeout(r, 2000));
                    }
                }
            }
            // Default to current channel if no referenced channels found
            const currentKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
            if (referencedChannels.size === 0) {
                referencedChannels.add(currentKey);
            }
            // Collect messages from all referenced channels
            for (const chanKey of referencedChannels) {
                const msgs = this.messages.get(chanKey) || [];
                const mapped = msgs.slice(-msgLimit).map(m => ({
                    nym: m.author || 'anon',
                    pubkey: m.pubkey || '',
                    content: (m.content || '').slice(0, 300),
                    timestamp: m.created_at || 0,
                    isBot: !!m.isBot,
                    channel: chanKey
                }));
                channelMessages.push(...mapped);
            }
            // Sort merged messages by timestamp if pulling from multiple channels
            if (referencedChannels.size > 1) {
                channelMessages.sort((a, b) => a.timestamp - b.timestamp);
                channelMessages = channelMessages.slice(-msgLimit);
            }
            // Collect active users from referenced channels
            // user.channels stores raw geohashes (no # prefix) which may vary in precision
            const channelKeys = referencedChannels;
            this.users.forEach((user, pubkey) => {
                if (user.channels) {
                    let found = false;
                    for (const chanKey of channelKeys) {
                        const rawName = chanKey.startsWith('#') ? chanKey.substring(1) : chanKey;
                        for (const userChan of user.channels) {
                            // Match if either is a prefix of the other (handles geohash precision differences)
                            if (userChan === rawName || userChan.startsWith(rawName) || rawName.startsWith(userChan)) {
                                found = true;
                                break;
                            }
                        }
                        if (found) break;
                    }
                    if (found) {
                        const shopItems = this.getUserShopItems(pubkey);
                        activeUsers.push({
                            nym: user.nym + '#' + pubkey.slice(-4),
                            pubkey: pubkey,
                            flair: shopItems?.flair ? shopItems.flair.replace('flair-', '') : null,
                            style: shopItems?.style ? shopItems.style.replace('style-', '') : null
                        });
                    }
                }
            });
        }
        // For top/last/seen/who, gather messages from ALL channels in memory
        const inMemoryCommands = ['top', 'last', 'seen', 'who'];
        if (inMemoryCommands.includes(command.toLowerCase())) {
            channelMessages = [];
            for (const [chanKey, msgs] of this.messages) {
                const mapped = msgs.map(m => ({
                    nym: m.author || 'anon',
                    pubkey: m.pubkey || '',
                    content: (m.content || '').slice(0, 300),
                    timestamp: m.created_at || 0,
                    isBot: !!m.isBot,
                    channel: chanKey
                }));
                channelMessages.push(...mapped);
            }
            channelMessages.sort((a, b) => a.timestamp - b.timestamp);
            // Gather all known active users
            activeUsers = [];
            this.users.forEach((user, pubkey) => {
                if (user.nym) {
                    activeUsers.push({
                        nym: user.nym + '#' + pubkey.slice(-4),
                        pubkey: pubkey
                    });
                }
            });
        }
        try {
            const resp = await fetch(`https://${this._getApiHost()}/api/bot`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ command, args, geohash, conversation, senderNym: this.nym + '#' + this.getPubkeySuffix(this.pubkey), publishedContent, channelMessages, activeUsers })
            });
            if (!resp.ok) return;
            const data = await resp.json();
            if (data.event) {
                // Publish the signed bot event to all connected relays
                const msg = JSON.stringify(['EVENT', data.event]);
                if (this.useRelayProxy && this.poolSockets.length > 0) {
                    for (const pool of this.poolSockets) {
                        if (pool.ws && pool.ws.readyState === WebSocket.OPEN) {
                            try { pool.ws.send(msg); } catch { }
                        }
                    }
                } else {
                    for (const [, ws] of this.relayPool) {
                        if (ws.readyState === WebSocket.OPEN) {
                            try { ws.send(msg); } catch { }
                        }
                    }
                }
            }
        } catch (e) {
            console.error('[nymbot] Command failed:', e);
        }
    },

    setupCommands() {
        // Bot commands (? prefix) — shown in command palette when user types ?
        this.botCommands = {
            '?ask': { desc: 'Ask Nymbot a question (or @Nymbot)' },
            '?summarize': { desc: 'Summarize recent channel conversation' },
            '?flip': { desc: 'Flip a coin' },
            '?8ball': { desc: 'Ask the magic 8-ball' },
            '?pick': { desc: 'Pick between options (e.g. ?pick a, b, c)' },
            '?time': { desc: 'Show current UTC time' },
            '?math': { desc: 'Calculate a math expression' },
            '?joke': { desc: 'Tell a random joke' },
            '?riddle': { desc: 'Get a riddle' },
            '?trivia': { desc: 'Random trivia question' },
            '?define': { desc: 'Define a word' },
            '?translate': { desc: 'Translate text (e.g. ?translate es Hello)' },
            '?units': { desc: 'Convert units (e.g. ?units 5km to miles)' },
            '?btc': { desc: 'Show Bitcoin price' },
            '?news': { desc: 'Show latest news headlines' },
            '?who': { desc: 'Who is online in this channel' },
            '?about': { desc: 'About Nymbot' },
            '?nostr': { desc: 'What is Nostr?' },
            '?wordplay': { desc: 'Word games (anagram, scramble, wordle)' },
            '?top': { desc: 'Show top chatters' },
            '?last': { desc: 'Show last message from a user' },
            '?seen': { desc: 'When was a user last seen' },
            '?help': { desc: 'Show all Nymbot commands' },
        };
        this.commands = {
            '/help': { desc: 'Show available commands', fn: () => this.showHelp() },
            '/join': { desc: 'Join a channel', fn: (args) => this.cmdJoin(args) },
            '/j': { desc: 'Shortcut for /join', fn: (args) => this.cmdJoin(args) },
            '/pm': { desc: 'Send private message', fn: (args) => this.cmdPM(args) },
            '/nick': { desc: 'Change your nym', fn: (args) => this.cmdNick(args) },
            '/who': { desc: 'List active nyms', fn: () => this.cmdWho() },
            '/w': { desc: 'Shortcut for /who', fn: () => this.cmdWho() },
            '/clear': { desc: 'Clear chat messages', fn: () => this.cmdClear() },
            '/block': { desc: 'Block a user or #channel', fn: (args) => this.cmdBlock(args) },
            '/unblock': { desc: 'Unblock a user', fn: (args) => this.cmdUnblock(args) },
            '/slap': { desc: 'Slap someone with a trout 🐟', fn: (args) => this.cmdSlap(args) },
            '/hug': { desc: 'Give someone a warm hug 🫂', fn: (args) => this.cmdHug(args) },
            '/me': { desc: 'Action message', fn: (args) => this.cmdMe(args) },
            '/shrug': { desc: 'Send a shrug', fn: () => this.cmdShrug() },
            '/bold': { desc: 'Send bold text (**text**)', fn: (args) => this.cmdBold(args) },
            '/b': { desc: 'Shortcut for /bold', fn: (args) => this.cmdBold(args) },
            '/italic': { desc: 'Send italic text (*text*)', fn: (args) => this.cmdItalic(args) },
            '/i': { desc: 'Shortcut for /italic', fn: (args) => this.cmdItalic(args) },
            '/strike': { desc: 'Send strikethrough text (~~text~~)', fn: (args) => this.cmdStrike(args) },
            '/s': { desc: 'Shortcut for /strike', fn: (args) => this.cmdStrike(args) },
            '/code': { desc: 'Send code block', fn: (args) => this.cmdCode(args) },
            '/c': { desc: 'Shortcut for /code', fn: (args) => this.cmdCode(args) },
            '/quote': { desc: 'Send quoted text', fn: (args) => this.cmdQuote(args) },
            '/q': { desc: 'Shortcut for /quote', fn: (args) => this.cmdQuote(args) },
            '/brb': { desc: 'Set away message', fn: (args) => this.cmdBRB(args) },
            '/back': { desc: 'Clear away message', fn: () => this.cmdBack() },
            '/zap': { desc: 'Zap a user profile', fn: (args) => this.cmdZap(args) },
            '/invite': { desc: 'Invite a user to channel, or add to group when in a group chat', fn: (args) => this.cmdInvite(args) },
            '/group': { desc: 'Create a private group: /group @user1 @user2 [GroupName]', fn: (args) => this.cmdGroup(args) },
            '/addmember': { desc: 'Add a member to the current group chat', fn: (args) => this.cmdAddMember(args) },
            '/groupinfo': { desc: 'Show members of the current group', fn: () => this.cmdGroupInfo() },
            '/share': { desc: 'Share current channel URL', fn: () => this.cmdShare() },
            '/leave': { desc: 'Leave current channel, group chat, or PM', fn: () => this.cmdLeave() },
            '/quit': { desc: 'Disconnect from Nymchat', fn: () => this.cmdQuit() },
            '/poll': { desc: 'Create a poll', fn: () => this.cmdPoll() }
        };
    },

    showCommandPalette(input) {
        const palette = document.getElementById('commandPalette');
        const matchingCommands = Object.entries(this.commands)
            .filter(([cmd]) => cmd.startsWith(input.toLowerCase()));

        if (matchingCommands.length > 0) {
            palette.innerHTML = matchingCommands.map(([cmd, info], index) => `
                <div class="command-item ${index === 0 ? 'selected' : ''}" data-command="${cmd}">
                    <span class="command-name">${cmd}</span>
                    <span class="command-desc">${info.desc}</span>
                </div>
            `).join('');
            palette.classList.add('active');
            this.commandPaletteIndex = 0;
        } else {
            this.hideCommandPalette();
        }
    },

    showBotCommandPalette(input) {
        const palette = document.getElementById('commandPalette');
        const matchingCommands = Object.entries(this.botCommands)
            .filter(([cmd]) => cmd.startsWith(input.toLowerCase()));

        if (matchingCommands.length > 0) {
            palette.innerHTML = matchingCommands.map(([cmd, info], index) => `
                <div class="command-item ${index === 0 ? 'selected' : ''}" data-command="${cmd}">
                    <span class="command-name">${cmd}</span>
                    <span class="command-desc">${info.desc}</span>
                </div>
            `).join('');
            palette.classList.add('active');
            this.commandPaletteIndex = 0;
        } else {
            this.hideCommandPalette();
        }
    },

    hideCommandPalette() {
        document.getElementById('commandPalette').classList.remove('active');
        this.commandPaletteIndex = -1;
    },

    navigateCommandPalette(direction) {
        const items = document.querySelectorAll('.command-item');
        if (items.length === 0) return;

        items[this.commandPaletteIndex]?.classList.remove('selected');

        this.commandPaletteIndex += direction;
        if (this.commandPaletteIndex < 0) this.commandPaletteIndex = items.length - 1;
        if (this.commandPaletteIndex >= items.length) this.commandPaletteIndex = 0;

        items[this.commandPaletteIndex].classList.add('selected');
        items[this.commandPaletteIndex].scrollIntoView({ block: 'nearest' });
    },

    selectCommand(element = null) {
        const selected = element || document.querySelector('.command-item.selected');
        if (selected) {
            const cmd = selected.dataset.command;
            const input = document.getElementById('messageInput');
            input.value = cmd + ' ';
            input.focus();
            this.hideCommandPalette();
        }
    },

    handleCommand(command) {
        const parts = command.split(' ');
        const cmd = parts[0].toLowerCase();
        const args = parts.slice(1).join(' ');

        const commandInfo = this.commands[cmd];
        if (commandInfo) {
            commandInfo.fn(args);
        } else {
            this.displaySystemMessage(`Unknown command: ${cmd}`);
        }
    },

    // Command implementations
    showHelp() {
        const helpText = Object.entries(this.commands)
            .map(([cmd, info]) => `${cmd} - ${info.desc}  \n`)
            .join('');

        this.displaySystemMessage(
            `Available commands:  \n${helpText}\n\nMarkdown supported: **bold**, *italic*, ~~strikethrough~~, \`code\`, > quote\n\nType : to quickly pick an emoji\n\nNyms are shown as name#xxxx where xxxx is the last 4 characters of their pubkey\n\nClick on users for more options`
        );
    },

    async cmdJoin(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /join #channel (e.g., /join #9q5, /join #nymchat, or /join nym)');
            return;
        }

        let channel = args.trim().toLowerCase();

        // Strip leading # if present
        if (channel.startsWith('#')) {
            channel = channel.substring(1);
        }

        // Sanitize: only allow letters (including international) and digits
        channel = this.sanitizeChannelName(channel);

        if (!channel) {
            this.displaySystemMessage('Invalid channel name. Only letters and numbers are allowed.');
            return;
        }

        // Blocked channels cannot be joined — unblock first
        if (this.isChannelBlocked(channel, channel)) {
            this.displaySystemMessage(`Channel #${channel} is blocked. Use /unblock #${channel} to unblock it first.`);
            return;
        }

        this.addChannel(channel, channel);
        this.switchChannel(channel, channel);
        this.userJoinedChannels.add(channel);
        this.saveUserChannels();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    async cmdLeave() {
        if (this.inPMMode) {
            if (this.currentGroup) {
                // Leave and delete the current group chat
                this.leaveGroup(this.currentGroup);
            } else if (this.currentPM) {
                // Delete the current PM conversation
                this.deletePMDirect(this.currentPM);
            }
            return;
        }

        if (this.currentGeohash === 'nym') {
            this.displaySystemMessage('Cannot leave the default #nym channel');
            return;
        }

        this.removeChannel(this.currentChannel, this.currentGeohash);
    },

    async cmdNick(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /nick newnym');
            return;
        }

        const oldNym = this.nym;
        const newNym = args.trim().substring(0, 20);

        if (oldNym === newNym) {
            this.displaySystemMessage('That is already your current nym');
            return;
        }

        // Check if reserved nickname
        if (this.isReservedNick(newNym)) {
            const result = await showDevNsecModal('nick');
            if (!result) {
                this.displaySystemMessage('Nickname change cancelled.');
                return null;
            }
            // Verified - apply developer identity
            this.applyDeveloperIdentity(result.secretKey, result.pubkey);
            this.displaySystemMessage(`Identity verified. You are now logged in as ${this.nym}.`);
            return result;
        }

        this.nym = newNym;
        document.getElementById('currentNym').innerHTML = this.formatNymWithPubkey(this.nym, this.pubkey);
        this.updateSidebarAvatar();

        // Persist nickname to localStorage so it survives page reloads
        localStorage.setItem(`nym_nickname_${this.pubkey}`, newNym);
        // Also update the auto-ephemeral nick so persistent sessions use the new name
        if (localStorage.getItem('nym_auto_ephemeral') === 'true') {
            localStorage.setItem('nym_auto_ephemeral_nick', newNym);
        }

        // Update the users map so other parts of the app see the new nym
        const existingUser = this.users.get(this.pubkey);
        if (existingUser) {
            existingUser.nym = newNym;
            this.users.set(this.pubkey, existingUser);
        } else {
            this.users.set(this.pubkey, {
                nym: newNym,
                pubkey: this.pubkey,
                lastSeen: Date.now(),
                status: 'online',
                channels: new Set()
            });
        }

        // Update already-rendered messages and PM sidebar entries with the new nickname
        this.updatePMNicknameFromProfile(this.pubkey, newNym);

        // Publish updated kind 0 profile so other users see the new nickname
        await this.saveToNostrProfile();

        const changeMessage = `Your nym's new nick is now ${this.nym}`;
        this.displaySystemMessage(changeMessage);
    },

    async cmdWho() {
        const currentChannelKey = this.currentGeohash || this.currentChannel;
        const channelUserSet = this.channelUsers.get(currentChannelKey) || new Set();

        const users = Array.from(channelUserSet)
            .map(pubkey => this.users.get(pubkey))
            .filter(u => u && Date.now() - u.lastSeen < 300000)
            .filter(u => !this.blockedUsers.has(u.nym))
            .map(u => {
                const baseNym = this.stripPubkeySuffix(u.nym);
                const suffix = this.getPubkeySuffix(u.pubkey);
                return `${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>`;
            })
            .join(', ');

        this.displaySystemMessage(`Online nyms in this channel: ${users || 'none'}`, 'system', { html: true });
    },

    async cmdClear() {
        document.getElementById('messagesContainer').innerHTML = '';
        this.displaySystemMessage('Chat cleared');
    },

    async cmdInvite(args) {
        if (!args) {
            if (this.inPMMode && this.currentGroup) {
                this.displaySystemMessage('Usage: /invite @nym — adds a user to this group');
            } else {
                this.displaySystemMessage('Usage: /invite @nym, /invite nym#xxxx, or /invite [pubkey]');
            }
            return;
        }

        // When viewing a group, /invite adds the user to that group
        if (this.inPMMode && this.currentGroup) {
            const targetInput = args.trim().replace(/^@/, '');
            const targetPubkey = this.resolvePubkeyFromNym(targetInput);
            if (!targetPubkey) {
                this.displaySystemMessage(`User @${targetInput} not found. They need to be visible in a channel first.`);
                return;
            }
            if (targetPubkey === this.pubkey) {
                this.displaySystemMessage("You're already in this group");
                return;
            }
            if (this.isVerifiedBot(targetPubkey)) {
                this.displaySystemMessage("Nymbot can't be added to group chats. Use ?ask or @Nymbot in a channel instead.");
                return;
            }
            await this.addMemberToGroup(this.currentGroup, targetPubkey);
            return;
        }

        if (this.inPMMode) {
            this.displaySystemMessage('Use /group @nym to create a group with this person, or switch to a channel first');
            return;
        }

        const targetInput = args.trim().replace(/^@/, '');
        let targetPubkey = null;
        let matchedNym = null;

        // Check if input is a pubkey (64 hex characters)
        if (/^[0-9a-f]{64}$/i.test(targetInput)) {
            targetPubkey = targetInput.toLowerCase();

            if (targetPubkey === this.pubkey) {
                this.displaySystemMessage("You can't invite yourself");
                return;
            }

            matchedNym = this.getNymFromPubkey(targetPubkey);
        } else {
            // Check if input has #xxxx suffix
            const hashIndex = targetInput.indexOf('#');
            let searchNym = targetInput;
            let searchSuffix = null;

            if (hashIndex !== -1) {
                searchNym = targetInput.substring(0, hashIndex);
                searchSuffix = targetInput.substring(hashIndex + 1);
            }

            // Find user by nym, considering suffix if provided
            const matches = [];
            this.users.forEach((user, pubkey) => {
                const baseNym = this.stripPubkeySuffix(user.nym);
                if (baseNym === searchNym || baseNym.toLowerCase() === searchNym.toLowerCase()) {
                    if (searchSuffix) {
                        // If suffix provided, only match exact pubkey suffix
                        if (pubkey.endsWith(searchSuffix)) {
                            matches.push({ nym: user.nym, pubkey: pubkey });
                        }
                    } else {
                        // No suffix provided, collect all matches
                        matches.push({ nym: user.nym, pubkey: pubkey });
                    }
                }
            });

            if (matches.length === 0) {
                this.displaySystemMessage(`User ${targetInput} not found`);
                return;
            }

            if (matches.length > 1 && !searchSuffix) {
                // Multiple users with same nym, show them
                const matchList = matches.map(m =>
                    `${this.formatNymWithPubkey(m.nym, m.pubkey)}`
                ).join(', ');
                this.displaySystemMessage(`Multiple users found with nym "${this.escapeHtml(searchNym)}": ${matchList}`, 'system', { html: true });
                this.displaySystemMessage('Please specify using the #xxxx suffix or full pubkey');
                return;
            }

            // Single match or exact suffix match
            targetPubkey = matches[0].pubkey;
            matchedNym = matches[0].nym;

            if (targetPubkey === this.pubkey) {
                this.displaySystemMessage("You can't invite yourself");
                return;
            }
        }

        // Create channel info for geohash channel
        const channelInfo = `#${this.currentGeohash}`;
        const joinCommand = `/join #${this.currentGeohash}`;

        // Send an invitation as a PM
        const inviteMessage = `📨 Channel Invitation: You've been invited to join ${channelInfo}. Use ${joinCommand} to join!`;

        // Send as PM
        const sent = await this.sendPM(inviteMessage, targetPubkey);

        if (sent) {
            const displayNym = this.formatNymWithPubkey(matchedNym, targetPubkey);
            this.displaySystemMessage(`Invitation sent to ${displayNym} for ${this.escapeHtml(channelInfo)}`, 'system', { html: true });

            // Also send a mention in the current channel
            const publicNotice = `@${matchedNym} you've been invited to this channel! Check your PMs for details.`;
            await this.publishMessage(publicNotice, this.currentChannel, this.currentGeohash);
        } else {
            this.displaySystemMessage(`Failed to send invitation to ${this.formatNymWithPubkey(matchedNym, targetPubkey)}`, 'system', { html: true });
        }
    },

    // /addmember @nym — add a member to the currently viewed group
    async cmdAddMember(args) {
        if (!this.inPMMode || !this.currentGroup) {
            this.displaySystemMessage('You must be in a group conversation to use /addmember');
            return;
        }
        if (!args) {
            this.displaySystemMessage('Usage: /addmember @nym');
            return;
        }
        const targetInput = args.trim().replace(/^@/, '');
        const targetPubkey = this.resolvePubkeyFromNym(targetInput);
        if (!targetPubkey) {
            this.displaySystemMessage(`User @${targetInput} not found`);
            return;
        }
        if (targetPubkey === this.pubkey) {
            this.displaySystemMessage("You're already in this group");
            return;
        }
        if (this.isVerifiedBot(targetPubkey)) {
            this.displaySystemMessage("Nymbot can't be added to group chats. Use ?ask or @Nymbot in a channel instead.");
            return;
        }
        await this.addMemberToGroup(this.currentGroup, targetPubkey);
    },

    async cmdBlock(args) {
        if (!args) {
            // If no args, check if in a channel that can be blocked
            if (this.inPMMode) {
                this.displaySystemMessage('Usage: /block nym, /block nym#xxxx, /block [pubkey], or /block #channel');
                return;
            }

            // Check current channel
            const currentChannelName = this.currentGeohash || this.currentChannel;
            if (this.currentGeohash === 'nym') {
                this.displaySystemMessage('Cannot block the default #nym channel');
                return;
            }

            // Block current channel
            if (confirm(`Block channel #${currentChannelName}?`)) {
                this.blockChannel(this.currentGeohash, this.currentGeohash);
                this.displaySystemMessage(`Blocked geohash channel #${this.currentGeohash}`);

                // Switch to #nym
                this.switchChannel('nym', 'nym');

                this.updateBlockedChannelsList();

            }
            return;
        }

        const target = args.trim();

        // Check if it's a channel block
        if (target.startsWith('#') && !target.includes('@')) {
            const channelName = target.substring(1);

            // Check if it's current channel
            if (this.currentGeohash === channelName) {
                // Block current channel and switch to #nym
                if (confirm(`Block and leave channel #${channelName}?`)) {
                    this.blockChannel(channelName, channelName);
                    this.displaySystemMessage(`Blocked geohash channel #${channelName}`);

                    // Switch to #nym
                    this.switchChannel('nym', 'nym');

                    this.updateBlockedChannelsList();
                }
                return;
            }

            // Don't allow blocking #nym
            if (channelName === 'nym') {
                this.displaySystemMessage("Cannot block the default #nym channel");
                return;
            }

            // Block channel (geohash or non-geohash)
            this.blockChannel(channelName, channelName);
            if (this.isValidGeohash(channelName)) {
                this.displaySystemMessage(`Blocked geohash channel #${channelName}`);
            } else {
                this.displaySystemMessage(`Blocked channel #${channelName}`);
            }

            this.updateBlockedChannelsList();


            return;
        }

        // Check if input is already a pubkey (64 hex characters)
        let targetPubkey;
        if (/^[0-9a-f]{64}$/i.test(target)) {
            targetPubkey = target.toLowerCase();
        } else {
            // User blocking - use findUserPubkey for nym lookup
            targetPubkey = await this.findUserPubkey(target);
            if (!targetPubkey) return;
        }

        const targetNym = this.getNymFromPubkey(targetPubkey);
        const cleanNym = this.getCleanNym ? this.getCleanNym(targetNym) : targetNym.replace(/<[^>]*>/g, '');

        // Check if already blocked to toggle
        if (this.blockedUsers.has(targetPubkey)) {
            // Unblock
            this.blockedUsers.delete(targetPubkey);
            this.saveBlockedUsers();
            this.showMessagesFromUnblockedUser(targetPubkey);

            this.displaySystemMessage(`Unblocked ${cleanNym}`);
            this.updateUserList();
            this.updateBlockedList();
            if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
            return;
        }

        this.blockedUsers.add(targetPubkey);
        this.saveBlockedUsers();
        this.hideMessagesFromBlockedUser(targetPubkey);

        this.displaySystemMessage(`Blocked ${cleanNym}`);
        this.updateUserList();
        this.updateBlockedList();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    async cmdUnblock(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /unblock nym, /unblock nym#xxxx, /unblock [pubkey], or /unblock #channel');
            return;
        }

        const target = args.trim();

        // Check if it's a channel unblock
        if (target.startsWith('#')) {
            const channelName = target.substring(1);

            if (this.blockedChannels.has(channelName)) {
                if (this.isValidGeohash(channelName)) {
                    this.unblockChannel(channelName, channelName);
                    this.displaySystemMessage(`Unblocked geohash channel #${channelName}`);
                } else {
                    this.unblockChannel(channelName, '');
                    this.displaySystemMessage(`Unblocked channel #${channelName}`);
                }

                this.updateBlockedChannelsList();

            } else {
                this.displaySystemMessage(`Channel #${channelName} is not blocked`);
            }
            return;
        }

        // User unblock - use findUserPubkey
        const targetPubkey = await this.findUserPubkey(target);
        if (!targetPubkey) {
            this.displaySystemMessage(`User ${target} not found or is not blocked`);
            return;
        }

        const targetNym = this.getNymFromPubkey(targetPubkey);

        if (!this.blockedUsers.has(targetPubkey)) {
            this.displaySystemMessage(`User is not blocked`);
            return;
        }

        this.blockedUsers.delete(targetPubkey);
        this.saveBlockedUsers();
        this.showMessagesFromUnblockedUser(targetPubkey);

        this.displaySystemMessage(`Unblocked ${this.formatNymWithPubkey(targetNym, targetPubkey)}`, 'system', { html: true });
        this.updateUserList();
        this.updateBlockedList();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    async cmdSlap(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /slap nym, /slap nym#xxxx, or /slap [pubkey]');
            return;
        }

        const targetInput = args.trim().replace(/^@/, '');
        let targetNym = '';

        // Check if input is a pubkey (64 hex characters)
        if (/^[0-9a-f]{64}$/i.test(targetInput)) {
            const targetPubkey = targetInput.toLowerCase();
            const user = this.users.get(targetPubkey);
            if (user) {
                // Get the base nym without HTML tags and flair
                targetNym = this.parseNymFromDisplay(user.nym);
            } else {
                targetNym = `anon#${targetPubkey.slice(-4)}`;
            }
        } else {
            const hashIndex = targetInput.indexOf('#');
            let searchNym = targetInput;
            let searchSuffix = null;

            if (hashIndex !== -1) {
                searchNym = targetInput.substring(0, hashIndex);
                searchSuffix = targetInput.substring(hashIndex + 1);
            }

            // Find matching users
            const matches = [];
            this.users.forEach((user, pubkey) => {
                // Strip HTML from user nym for comparison
                const cleanNym = this.parseNymFromDisplay(user.nym);
                if (cleanNym === searchNym || cleanNym.toLowerCase() === searchNym.toLowerCase()) {
                    if (searchSuffix) {
                        if (pubkey.endsWith(searchSuffix)) {
                            matches.push({ nym: cleanNym, pubkey: pubkey });
                        }
                    } else {
                        matches.push({ nym: cleanNym, pubkey: pubkey });
                    }
                }
            });

            if (matches.length > 1 && !searchSuffix) {
                const matchList = matches.map(m =>
                    `${this.formatNymWithPubkey(m.nym, m.pubkey)}`
                ).join(', ');
                this.displaySystemMessage(`Multiple users found with nym "${this.escapeHtml(searchNym)}": ${matchList}`, 'system', { html: true });
                this.displaySystemMessage('Please specify using the #xxxx suffix or full pubkey');
                return;
            }

            // Use the target nym for the action (without HTML tags)
            targetNym = matches.length > 0 ? matches[0].nym : searchNym;
        }

        // Create the slap message content  
        const slapContent = `/me slaps ${targetNym} around a bit with a large trout 🐟`;

        // Send the message using the appropriate method based on current context
        try {
            if (this.inPMMode && this.currentPM) {
                // Send as PM
                await this.sendPM(slapContent, this.currentPM);
            } else if (this.currentGeohash) {
                // Send to geohash channel
                await this.publishMessage(slapContent, this.currentGeohash, this.currentGeohash);
            }
        } catch (error) {
            this.displaySystemMessage('Failed to send slap: ' + error.message);
        }
    },

    async cmdHug(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /hug nym, /hug nym#xxxx, or /hug [pubkey]');
            return;
        }

        const targetInput = args.trim().replace(/^@/, '');
        let targetNym = '';

        // Check if input is a pubkey (64 hex characters)
        if (/^[0-9a-f]{64}$/i.test(targetInput)) {
            const targetPubkey = targetInput.toLowerCase();
            const user = this.users.get(targetPubkey);
            if (user) {
                targetNym = this.parseNymFromDisplay(user.nym);
            } else {
                targetNym = `anon#${targetPubkey.slice(-4)}`;
            }
        } else {
            const hashIndex = targetInput.indexOf('#');
            let searchNym = targetInput;
            let searchSuffix = null;

            if (hashIndex !== -1) {
                searchNym = targetInput.substring(0, hashIndex);
                searchSuffix = targetInput.substring(hashIndex + 1);
            }

            // Find matching users
            const matches = [];
            this.users.forEach((user, pubkey) => {
                const cleanNym = this.parseNymFromDisplay(user.nym);
                if (cleanNym === searchNym || cleanNym.toLowerCase() === searchNym.toLowerCase()) {
                    if (searchSuffix) {
                        if (pubkey.endsWith(searchSuffix)) {
                            matches.push({ nym: cleanNym, pubkey: pubkey });
                        }
                    } else {
                        matches.push({ nym: cleanNym, pubkey: pubkey });
                    }
                }
            });

            if (matches.length > 1 && !searchSuffix) {
                const matchList = matches.map(m =>
                    `${this.formatNymWithPubkey(m.nym, m.pubkey)}`
                ).join(', ');
                this.displaySystemMessage(`Multiple users found with nym "${this.escapeHtml(searchNym)}": ${matchList}`, 'system', { html: true });
                this.displaySystemMessage('Please specify using the #xxxx suffix or full pubkey');
                return;
            }

            targetNym = matches.length > 0 ? matches[0].nym : searchNym;
        }

        const hugContent = `/me gives ${targetNym} a warm hug 🫂`;

        try {
            if (this.inPMMode && this.currentPM) {
                await this.sendPM(hugContent, this.currentPM);
            } else if (this.currentGeohash) {
                await this.publishMessage(hugContent, this.currentGeohash, this.currentGeohash);
            }
        } catch (error) {
            this.displaySystemMessage('Failed to send hug: ' + error.message);
        }
    },

    async cmdMe(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /me action');
            return;
        }

        const content = `/me ${args}`;

        try {
            if (this.inPMMode && this.currentPM) {
                // Send as PM
                await this.sendPM(content, this.currentPM);
            } else if (this.currentGeohash) {
                // Send to geohash channel
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
            }
        } catch (error) {
            this.displaySystemMessage('Failed to send message: ' + error.message);
        }
    },

    async cmdShrug() {
        const content = '¯\\_(ツ)_/¯';

        try {
            if (this.inPMMode && this.currentPM) {
                await this.sendPM(content, this.currentPM);
            } else if (this.currentGeohash) {
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
            }
        } catch (error) {
            this.displaySystemMessage('Failed to send message: ' + error.message);
        }
    },

    async cmdBold(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /bold text');
            return;
        }

        const content = `**${args}**`;

        try {
            if (this.inPMMode && this.currentPM) {
                await this.sendPM(content, this.currentPM);
            } else if (this.currentGeohash) {
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
            }
        } catch (error) {
            this.displaySystemMessage('Failed to send message: ' + error.message);
        }
    },

    async cmdItalic(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /italic text');
            return;
        }

        const content = `*${args}*`;

        try {
            if (this.inPMMode && this.currentPM) {
                await this.sendPM(content, this.currentPM);
            } else if (this.currentGeohash) {
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
            }
        } catch (error) {
            this.displaySystemMessage('Failed to send message: ' + error.message);
        }
    },

    async cmdStrike(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /strike text');
            return;
        }

        const content = `~~${args}~~`;

        try {
            if (this.inPMMode && this.currentPM) {
                await this.sendPM(content, this.currentPM);
            } else if (this.currentGeohash) {
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
            }
        } catch (error) {
            this.displaySystemMessage('Failed to send message: ' + error.message);
        }
    },

    async cmdCode(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /code text');
            return;
        }

        const content = `\`\`\`\n${args}\n\`\`\``;

        try {
            if (this.inPMMode && this.currentPM) {
                await this.sendPM(content, this.currentPM);
            } else if (this.currentGeohash) {
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
            }
        } catch (error) {
            this.displaySystemMessage('Failed to send message: ' + error.message);
        }
    },

    async cmdQuote(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /quote text');
            return;
        }

        const content = `> ${args}`;

        try {
            if (this.inPMMode && this.currentPM) {
                await this.sendPM(content, this.currentPM);
            } else if (this.currentGeohash) {
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
            }
        } catch (error) {
            this.displaySystemMessage('Failed to send message: ' + error.message);
        }
    },

    async cmdBRB(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /brb message (e.g., /brb lunch, back in 30)');
            return;
        }

        const message = args.trim();
        this.awayMessages.set(this.pubkey, message);

        // Update user status
        if (this.users.has(this.pubkey)) {
            this.users.get(this.pubkey).status = 'away';
        }

        this.displaySystemMessage(`Away message set: "${message}"`);
        this.displaySystemMessage('You will auto-reply to mentions in ALL channels while away');

        // Broadcast away status to other users
        this.publishPresence('away', message);

        // Clear session storage for BRB responses to allow fresh responses
        const keysToRemove = [];
        for (let i = 0; i < sessionStorage.length; i++) {
            const key = sessionStorage.key(i);
            if (key && key.startsWith(`brb_universal_${this.pubkey}_`)) {
                keysToRemove.push(key);
            }
        }
        keysToRemove.forEach(key => sessionStorage.removeItem(key));

        this.updateUserList();
    },

    async cmdBack() {
        if (this.awayMessages.has(this.pubkey)) {
            this.awayMessages.delete(this.pubkey);

            // Update user status
            if (this.users.has(this.pubkey)) {
                this.users.get(this.pubkey).status = 'online';
            }

            this.displaySystemMessage('Away message cleared - you are back!');

            // Broadcast online status to other users
            this.publishPresence('online');

            // Clear all universal BRB response keys
            const keysToRemove = [];
            for (let i = 0; i < sessionStorage.length; i++) {
                const key = sessionStorage.key(i);
                if (key && key.startsWith(`brb_universal_${this.pubkey}_`)) {
                    keysToRemove.push(key);
                }
            }
            keysToRemove.forEach(key => sessionStorage.removeItem(key));

            this.updateUserList();
        } else {
            this.displaySystemMessage('You were not away');
        }
    },

    async cmdQuit() {
        this.displaySystemMessage('Disconnecting from Nymchat...');

        // Clear saved connection preferences
        localStorage.removeItem('nym_connection_mode');
        localStorage.removeItem('nym_relay_url');
        localStorage.removeItem('nym_nsec'); // Clear saved nsec
        localStorage.removeItem('nym_dev_nsec'); // Clear developer nsec

        // Clear pubkey-specific lightning address
        if (this.pubkey) {
            localStorage.removeItem(`nym_lightning_address_${this.pubkey}`);
        }

        if (this.ws) {
            this.ws.close();
        }
        setTimeout(() => {
            location.reload();
        }, 1000);
    },

    cmdPoll() {
        if (this.inPMMode) {
            this.displaySystemMessage('Polls can only be created in channels, not in private messages.');
            return;
        }
        document.getElementById('pollQuestion').value = '';
        const container = document.getElementById('pollOptionsContainer');
        container.innerHTML = `
            <label class="form-label">Options</label>
            <div class="poll-option-input-row">
                <input type="text" class="form-input" placeholder="Option 1" maxlength="100" data-poll-option>
            </div>
            <div class="poll-option-input-row">
                <input type="text" class="form-input" placeholder="Option 2" maxlength="100" data-poll-option>
            </div>
        `;
        document.getElementById('pollAddOptionBtn').style.display = '';
        document.getElementById('pollModal').classList.add('active');
    },

});
