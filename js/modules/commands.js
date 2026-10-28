const BOT_CHANNEL_RUN_MAX_MS = 150000;
const BOT_CHANNEL_RUN_GRACE_MS = 15000;
const BOT_CHANNEL_DETACHED_MS = 35000;
const BOT_CHANNEL_RUNS_KEY = 'nym_bot_channel_runs';

Object.assign(NYM.prototype, {

    _botContextKeeps(m) {
        if (!m || (m._optimistic && !m.isOwn)) return false;
        if (typeof this.isContentHidden === 'function') return !this.isContentHidden(m);
        return !m._spamGated && !(this.blockedUsers && this.blockedUsers.has(m.pubkey));
    },

    _botContextText(text, quoted) {
        const F = window.NymContentFilter;
        const s = typeof text === 'string' ? text : '';
        return F && typeof this._cfCtx === 'function' ? F.stripBlockedQuotes(this._cfCtx(), s, Array.isArray(quoted) ? quoted : []) : s;
    },

    _botChannelExcluded(key, includeHidden) {
        const F = window.NymContentFilter;
        if (!F || typeof this._cfCtx !== 'function') return false;
        const ctx = this._cfCtx();
        return includeHidden ? F.channelHidden(ctx, key) : F.channelBlocked(ctx, key);
    },

    async cmdShare() {
        this.shareChannel();
    },

    async _handleBotCommand(content, geohash, quoteContext, publishedContent, threadRoot, anon, as) {
        if (!as && typeof this.aiConsentAllowed === 'function' && !this.aiConsentAllowed('nymbot')) return anon ? 'failed' : undefined;
        const anonModel = anon ? window.NymAnonNymbot : null;
        if (anon && !anonModel) return 'unavailable';
        if (!this._getApiHost()) return anon ? 'unavailable' : undefined;
        if (typeof geohash === 'string' && geohash && !this.isValidChannelTag(geohash)) return anon ? 'unavailable' : undefined;
        const mentionRegex = /@nymbot(?:#[a-f0-9]{4})?/i;
        if (mentionRegex.test(content) && !content.startsWith('?')) {
            const question = content.replace(mentionRegex, '').trim();
            if (question) {
                content = '?ask ' + question;
            } else if (quoteContext && quoteContext.text) {
                const quotedText = quoteContext.text.replace(/^>\s*@[^:]+:\s*/gm, '').replace(/^>\s?/gm, '').trim();
                if (quotedText) {
                    content = '?ask ' + quotedText;
                }
            }
        }
        if (quoteContext && /^nymbot(?:#[a-f0-9]{4})?$/i.test(quoteContext.author)) {
            if (!content.startsWith('?')) {
                const hasGameToken = quoteContext.text && /\[gc:[A-Za-z0-9+/=]+\]/.test(quoteContext.text);
                content = hasGameToken ? '?guess ' + content : '?ask ' + content;
            }
        }
        const prefix = '?';
        if (!content.startsWith(prefix)) return;
        const parts = content.slice(prefix.length).trim().split(/\s+/);
        let command = parts[0];
        const args = parts.slice(1).join(' ');
        if (!command) return;
        const canonical = this.resolveCommandToken(prefix + command);
        if (canonical) command = canonical.slice(prefix.length);
        // The whole thread when the message came from one, otherwise the quote chain replied to.
        let conversation = [];
        if (['ask', 'guess'].includes(command.toLowerCase())) {
            const storageKey = geohash ? `#${geohash}` : this.currentChannel;
            if (threadRoot && typeof this._threadBotConversation === 'function') {
                conversation = this._threadBotConversation(threadRoot, storageKey, as ? { exclude: publishedContent, skip: (m) => this._sendAsUnsent(m) } : { exclude: publishedContent });
            }
            if (!conversation.length && quoteContext) {
                conversation = this._extractQuoteChain(quoteContext);
            }
        }
        let channelMessages = [];
        let activeUsers = [];
        const aiCommands = ['ask', 'summarize'];
        if (aiCommands.includes(command.toLowerCase())) {
            const msgLimit = 100;
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
                        let found = false;
                        if (this.messages.has(`#${name}`)) {
                            referencedChannels.add(`#${name}`);
                            found = true;
                        }
                        if (!found && !as) {
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
                        if (!found && !as) {
                            for (const chanKey of this.channels.keys()) {
                                if (chanKey.toLowerCase() === name || chanKey.toLowerCase().startsWith(name) || name.startsWith(chanKey.toLowerCase())) {
                                    const storeKey = `#${chanKey}`;
                                    referencedChannels.add(storeKey);
                                    found = true;
                                    break;
                                }
                            }
                        }
                        if (!found) {
                            const chanType = this.isValidGeohash(name) ? 'geohash' : 'standard';
                            channelsToFetch.push({ name, type: chanType });
                            referencedChannels.add(`#${name}`);
                        }
                    }
                    if (channelsToFetch.length > 0 && !as && !anon) {
                        for (const ch of channelsToFetch) {
                            this.channelLoadedFromRelays.delete(ch.name);
                            this.subscribeToChannelTargeted(ch.name, ch.type);
                        }
                        await new Promise(r => setTimeout(r, 2000));
                    }
                }
            }
            const currentKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
            if (referencedChannels.size === 0) {
                referencedChannels.add(currentKey);
            }
            for (const chanKey of referencedChannels) {
                if (chanKey !== currentKey && this._botChannelExcluded(chanKey, false)) continue;
                const msgs = (this.messages.get(chanKey) || []).filter(m => this._botContextKeeps(m));
                const mapped = msgs.slice(-msgLimit).map(m => ({
                    nym: this.resolveDisplayNym(m.pubkey, m.author || ''),
                    pubkey: m.pubkey || '',
                    content: this.truncateText(this._botContextText(m.content, m.quoted), 300),
                    timestamp: m.created_at || 0,
                    isBot: !!m.isBot,
                    channel: chanKey,
                    ...((anon && m._optimistic) || (as && this._sendAsUnsent(m)) ? { pending: true } : {})
                }));
                channelMessages.push(...mapped);
            }
            if (referencedChannels.size > 1) {
                channelMessages.sort((a, b) => a.timestamp - b.timestamp);
                channelMessages = channelMessages.slice(-msgLimit);
            }
            // user.channels stores raw geohashes without #, which may vary in precision.
            const channelKeys = referencedChannels;
            this.users.forEach((user, pubkey) => {
                if (typeof this.isPersonHidden === 'function' && this.isPersonHidden(pubkey, user.nym)) return;
                if (user.channels) {
                    let found = false;
                    for (const chanKey of channelKeys) {
                        const rawName = chanKey.startsWith('#') ? chanKey.substring(1) : chanKey;
                        for (const userChan of user.channels) {
                            // Either may be a prefix of the other to handle geohash precision differences.
                            if (userChan === rawName || userChan.startsWith(rawName) || rawName.startsWith(userChan)) {
                                found = true;
                                break;
                            }
                        }
                        if (found) break;
                    }
                    if (found) {
                        const shopItems = as && pubkey === this.pubkey
                            ? ((this.otherUsersShopItems && this.otherUsersShopItems.get(pubkey)) || null)
                            : this.getUserShopItems(pubkey);
                        activeUsers.push({
                            nym: user.nym + '#' + pubkey.slice(-4),
                            pubkey: pubkey,
                            flair: (shopItems?.flair && shopItems.flair.length) ? shopItems.flair.map(f => f.replace('flair-', '')).join(',') : null,
                            style: shopItems?.style ? shopItems.style.replace('style-', '') : null
                        });
                    }
                }
            });
        }
        const inMemoryCommands = ['top', 'last', 'seen', 'who'];
        if (inMemoryCommands.includes(command.toLowerCase())) {
            channelMessages = [];
            const asKey = as ? (geohash ? `#${geohash}` : this.currentChannel) : null;
            for (const [chanKey, msgs] of this.messages) {
                if (as && chanKey !== asKey) continue;
                if (this._botChannelExcluded(chanKey, true)) continue;
                const mapped = msgs.filter(m => this._botContextKeeps(m)).map(m => ({
                    nym: this.resolveDisplayNym(m.pubkey, m.author || ''),
                    pubkey: m.pubkey || '',
                    content: this.truncateText(this._botContextText(m.content, m.quoted), 300),
                    timestamp: m.created_at || 0,
                    isBot: !!m.isBot,
                    channel: chanKey,
                    ...((anon && m._optimistic) || (as && this._sendAsUnsent(m)) ? { pending: true } : {})
                }));
                channelMessages.push(...mapped);
            }
            channelMessages.sort((a, b) => a.timestamp - b.timestamp);
            activeUsers = [];
            const asRaw = asKey ? asKey.replace(/^#/, '') : '';
            this.users.forEach((user, pubkey) => {
                if (typeof this.isPersonHidden === 'function' && this.isPersonHidden(pubkey, user.nym)) return;
                if (as && !(asRaw && user.channels && [...user.channels].some((c) => c === asRaw || c.startsWith(asRaw) || asRaw.startsWith(c)))) return;
                if (user.nym) {
                    activeUsers.push({
                        nym: user.nym + '#' + pubkey.slice(-4),
                        pubkey: pubkey
                    });
                }
            });
        }
        if (anon) {
            const scrubbed = anonModel.scrubContext({ messages: channelMessages, users: activeUsers, self: [this.pubkey] });
            channelMessages = scrubbed.messages;
            activeUsers = scrubbed.users;
        } else if (as) {
            channelMessages = channelMessages.filter((m) => !m.pending);
            if (!channelMessages.some((m) => m.pubkey === this.pubkey)) activeUsers = activeUsers.filter((u) => u.pubkey !== this.pubkey);
        }
        const senderNym = anon
            ? anonModel.senderNym(anon.nym, anon.pubkey)
            : (as ? as.nym + '#' + as.pubkey.slice(-4) : String(this.nym || 'nym').replace(/#[0-9a-f]{4}$/i, '') + '#' + this.getPubkeySuffix(this.pubkey));
        const askerPubkey = anon ? undefined : (as ? as.pubkey : this.pubkey);
        const relay = as && typeof as.publish === 'function' ? as : (anon ? this._anonBotRelay(anon) : null);
        if (anon && !relay) return 'failed';
        const run = this._botChannelRunBegin(geohash, !!anon);
        let outcome;
        try {
            const apiHost = this._getApiHost();
            if (!apiHost) { this._botChannelRunEnd(run); return anon ? 'unavailable' : undefined; }
            const resp = await this._edgeFetch(`https://${apiHost}/api/bot`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ command, args, geohash, conversation, senderNym, askerPubkey, publishedContent, channelMessages, activeUsers, threadRoot: threadRoot || null, lang: (this.getUiLanguage && this.getUiLanguage()) || '', stream: true }),
                signal: run && run.ctrl ? run.ctrl.signal : undefined
            });
            outcome = resp.ok ? await this._botChannelRead(resp, run, geohash, relay) : { status: resp.status, reason: resp.status === 429 ? 'rate' : 'error' };
        } catch (e) {
            console.error('[nymbot] Command failed:', e);
            outcome = { status: 0, reason: run && run.timedOut ? 'timeout' : 'lost' };
        }
        const ev = outcome && outcome.event;
        if (ev && this.isValidBotChannelEvent(ev)) {
            await this._botChannelPublishReply(ev, relay, !!(run && run.landed));
            if (outcome.typing) this._botChannelRelayTyping(outcome.typing, geohash, relay);
            this._botChannelRunEnd(run);
            return null;
        }
        this._botChannelRunEnd(run);
        if (run && run.landed) return null;
        const failure = ev ? { status: 200, reason: 'error' } : (outcome || { status: 0, reason: 'lost' });
        if (anon) {
            return failure.reason === 'timeout' || failure.reason === 'lost' ? 'failed' : anonModel.outcome(failure.status || 0, false) || (failure.status === 200 ? 'failed' : null);
        }
        this._botChannelFailureNotice(failure);
        return undefined;
    },

    _botChannelRunBegin(geohash, anon) {
        if (!geohash) return null;
        if (!this._botChannelRuns) this._botChannelRuns = new Map();
        const now = Date.now();
        const run = {
            channel: geohash, anon: !!anon, startedAt: now, deadline: now + BOT_CHANNEL_RUN_MAX_MS,
            ctrl: typeof AbortController === 'function' ? new AbortController() : null, timer: null, ended: false, timedOut: false
        };
        let set = this._botChannelRuns.get(geohash);
        if (!set) { set = new Set(); this._botChannelRuns.set(geohash, set); }
        set.add(run);
        this._botChannelRunArm(run);
        if (!this._botChannelLeaveHooked && typeof window !== 'undefined' && typeof window.addEventListener === 'function') {
            this._botChannelLeaveHooked = true;
            window.addEventListener('pagehide', () => this._botChannelRunsSave());
        }
        this._botChannelRunsSave();
        this._botThinkingPaint(geohash);
        return run;
    },

    _botChannelRunArm(run) {
        if (!run || run.ended) return;
        if (run.timer) clearTimeout(run.timer);
        run.timer = setTimeout(() => {
            run.timedOut = true;
            if (run.ctrl) { try { run.ctrl.abort(); } catch (_) { } }
            else {
                this._botChannelRunEnd(run);
                if (run.recovered) this._botChannelFailureNotice({ status: 0, reason: 'timeout' });
            }
        }, Math.max(0, this._botChannelRunEndAt(run) - Date.now()));
    },

    _botChannelRunEndAt(run) {
        const end = run.deadline + BOT_CHANNEL_RUN_GRACE_MS;
        return Number.isFinite(run.goneAt) ? Math.min(end, run.goneAt + BOT_CHANNEL_DETACHED_MS) : end;
    },

    _botChannelRunEnd(run) {
        if (!run || run.ended) return;
        run.ended = true;
        if (run.timer) clearTimeout(run.timer);
        if (run.remoteId) this._botChannelRemoteEnd(run.channel, run.remoteId);
        const set = this._botChannelRuns && this._botChannelRuns.get(run.channel);
        if (set) {
            set.delete(run);
            if (!set.size) this._botChannelRuns.delete(run.channel);
        }
        this._botChannelRunsSave();
        this._botThinkingPaint(run.channel);
    },

    _botChannelRunsSave() {
        const now = Date.now();
        const out = [];
        if (this._botChannelRuns) {
            for (const set of this._botChannelRuns.values()) {
                for (const r of set) if (!r.anon) out.push(Object.assign({ channel: r.channel, startedAt: r.startedAt, deadline: r.deadline, seenAt: Number.isFinite(r.goneAt) ? r.goneAt : now }, r.remoteId ? { runId: r.remoteId } : {}));
            }
        }
        try {
            if (out.length) sessionStorage.setItem(BOT_CHANNEL_RUNS_KEY, JSON.stringify(out));
            else sessionStorage.removeItem(BOT_CHANNEL_RUNS_KEY);
        } catch (_) { }
    },

    _botChannelRunsRecover() {
        if (this._botChannelRunsRecovered || (this._botChannelRuns && this._botChannelRuns.size)) return;
        this._botChannelRunsRecovered = true;
        let saved = null;
        try {
            saved = JSON.parse(sessionStorage.getItem(BOT_CHANNEL_RUNS_KEY) || 'null');
            sessionStorage.removeItem(BOT_CHANNEL_RUNS_KEY);
        } catch (_) { saved = null; }
        if (!Array.isArray(saved) || !saved.length) return;
        const now = Date.now();
        let lost = false;
        for (const r of saved) {
            if (!r || typeof r.channel !== 'string' || !r.channel) continue;
            const deadline = Number(r.deadline);
            const runId = this._botChannelRunIdOf({ tags: [['run', r.runId]] });
            const seen = Number(r.seenAt);
            const goneAt = Number.isFinite(seen) && seen > 0 && seen <= now ? seen : now;
            if (runId && Number.isFinite(deadline) && this._botChannelRunEndAt({ deadline, goneAt }) > now && deadline <= now + BOT_CHANNEL_RUN_MAX_MS) {
                this._botChannelRunRestore(r.channel, Number(r.startedAt) || now, deadline, runId, goneAt);
            } else if (Number(r.startedAt) > now - 30 * 60 * 1000) {
                lost = true;
            }
        }
        this._botChannelRunsSave();
        if (lost) this._botChannelFailureNotice({ status: 0, reason: 'lost' });
    },

    _botChannelRunRestore(channel, startedAt, deadline, runId, goneAt) {
        if (!this._botChannelRuns) this._botChannelRuns = new Map();
        const run = {
            channel, anon: false, startedAt, deadline, ctrl: null, timer: null,
            ended: false, timedOut: false, remoteId: runId, recovered: true, goneAt
        };
        let set = this._botChannelRuns.get(channel);
        if (!set) { set = new Set(); this._botChannelRuns.set(channel, set); }
        set.add(run);
        this._botChannelRunArm(run);
        this._botThinkingPaint(channel);
    },

    _botChannelFailureNotice(failure) {
        const f = failure || {};
        let text = null;
        if (f.reason === 'rate' || f.status === 429) text = 'Too many requests to Nymbot right now. Try again in a minute.';
        else if (f.reason === 'timeout' || f.reason === 'lost' || !f.status || f.status >= 500 || f.status === 200) text = "Nymbot couldn't answer that one. Try again.";
        if (!text) return;
        const shown = typeof this.uiText === 'function' ? this.uiText(text) : text;
        if (typeof this.showToast === 'function') this.showToast(shown);
        else if (typeof this.displaySystemMessage === 'function') this.displaySystemMessage(shown);
    },

    async _botChannelRead(resp, run, geohash, as) {
        const type = (resp.headers && typeof resp.headers.get === 'function' && resp.headers.get('content-type')) || '';
        if (!/ndjson/i.test(type)) {
            const data = await resp.json();
            return data && data.event ? { status: resp.status, event: data.event } : { status: resp.status, reason: 'error' };
        }
        const handle = (line) => {
            if (!line || typeof line !== 'object') return null;
            const runId = this._botChannelRunIdOf(line.typing);
            if (run && runId && run.remoteId !== runId) {
                run.remoteId = runId;
                if (!run.ended) this._botChannelRunsSave();
            }
            if (line.state === 'done') return { status: 200, event: line.event || null, typing: line.typing || null };
            if (line.typing) this._botChannelRelayTyping(line.typing, geohash, as);
            if (line.state === 'thinking') {
                const limit = Number(line.limitMs);
                if (run && !run.ended && Number.isFinite(limit) && limit > 0 && limit <= 600000) {
                    run.deadline = Math.min(run.deadline, Date.now() + limit);
                    this._botChannelRunArm(run);
                }
                if (run && !run.ended && !run.anon) this._botChannelRunsSave();
                this._botThinkingPaint(geohash);
                return null;
            }
            if (line.state === 'failed') return { status: Number(line.status) || 0, reason: line.reason === 'rate' || line.reason === 'timeout' ? line.reason : 'error' };
            return null;
        };
        const parse = (raw) => { try { return JSON.parse(raw); } catch (_) { return null; } };
        if (!resp.body || typeof resp.body.getReader !== 'function') {
            const text = await resp.text();
            for (const raw of text.split('\n')) {
                const out = raw.trim() ? handle(parse(raw)) : null;
                if (out) return out;
            }
            return { status: 0, reason: 'lost' };
        }
        const reader = resp.body.getReader();
        const decoder = new TextDecoder();
        let buf = '';
        for (;;) {
            const { value, done } = await reader.read();
            if (done) break;
            buf += decoder.decode(value, { stream: true });
            let at;
            while ((at = buf.indexOf('\n')) !== -1) {
                const raw = buf.slice(0, at);
                buf = buf.slice(at + 1);
                const out = raw.trim() ? handle(parse(raw)) : null;
                if (out) {
                    try { reader.cancel(); } catch (_) { }
                    return out;
                }
            }
        }
        const tail = buf.trim() ? handle(parse(buf)) : null;
        return tail || { status: 0, reason: run && run.timedOut ? 'timeout' : 'lost' };
    },

    _botChannelRelayTyping(ev, geohash, as) {
        const bot = this.verifiedBot;
        if (!bot || !ev || ev.kind !== 24420 || ev.pubkey !== bot.pubkey || !Array.isArray(ev.tags)) return;
        const status = (ev.tags.find((t) => Array.isArray(t) && t[0] === 'typing') || [])[1];
        const chan = (ev.tags.find((t) => Array.isArray(t) && (t[0] === 'g' || t[0] === 'd')) || [])[1];
        if ((status !== 'start' && status !== 'stop') || !chan || String(chan).toLowerCase() !== String(geohash || 'nymchat').toLowerCase()) return;
        if (as && typeof as.publish === 'function') {
            try { as.publish(ev); } catch (_) { }
            return;
        }
        this.sendToRelay(['EVENT', ev]);
        if (typeof this.channelWire === 'function' && this.channelWire(chan).isGeohash && typeof this.ensureGeoRelayDelivery === 'function') {
            this.ensureGeoRelayDelivery(ev, chan);
        }
    },

    _anonBotRelay(anon) {
        const lane = anon && anon.lane;
        if (!lane) return null;
        if (!Array.isArray(anon.sends)) anon.sends = [];
        return {
            publish: (ev) => {
                const sent = Promise.resolve(anon.posted).catch(() => false).then(() => lane.publish(ev)).catch(() => null);
                anon.sends.push(sent);
                return sent;
            },
        };
    },

    async _botChannelPublishReply(ev, as, landed) {
        if (as && typeof as.publish === 'function') {
            as.publish(ev);
        } else if (typeof this._anyRelayOpen === 'function' && !this._anyRelayOpen()) {
            if (typeof this._noteQueuedSend === 'function') this._noteQueuedSend(ev.id);
            this.broadcastEvent(['EVENT', ev]);
        } else {
            const msg = JSON.stringify(['EVENT', ev]);
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
        if (!landed && typeof this.handleEvent === 'function' && typeof this._verifyRelayEventAsync === 'function') {
            try {
                if (await this._verifyRelayEventAsync(ev)) await this.handleEvent(ev);
            } catch (_) { }
        }
    },

    _botChannelRunIdOf(ev) {
        const tag = ev && Array.isArray(ev.tags) ? ev.tags.find((t) => Array.isArray(t) && t[0] === 'run') : null;
        const id = tag && typeof tag[1] === 'string' ? tag[1].toLowerCase() : '';
        return /^[0-9a-f]{8,64}$/.test(id) ? id : '';
    },

    _botChannelRemoteEnd(geohash, runId) {
        if (!this._botChannelRunsEnded) this._botChannelRunsEnded = new Set();
        if (runId) {
            this._botChannelRunsEnded.add(runId);
            if (this._botChannelRunsEnded.size > 400) this._botChannelRunsEnded = new Set([...this._botChannelRunsEnded].slice(-200));
        }
        const runs = this._botChannelTypingRuns && this._botChannelTypingRuns.get(geohash);
        if (runs) {
            runs.delete(runId);
            if (!runs.size) this._botChannelTypingRuns.delete(geohash);
        }
    },

    _botChannelTypingSignal(geohash, status, runId, ttlMs, askers) {
        if (!geohash) return;
        if (status === 'stop') {
            this._botChannelRemoteEnd(geohash, runId);
        } else if (!(runId && this._botChannelRunsEnded && this._botChannelRunsEnded.has(runId))) {
            if (!this._botChannelTypingRuns) this._botChannelTypingRuns = new Map();
            let runs = this._botChannelTypingRuns.get(geohash);
            if (!runs) { runs = new Map(); this._botChannelTypingRuns.set(geohash, runs); }
            runs.set(runId, { expires: Date.now() + ttlMs, askers: Array.isArray(askers) ? askers.slice(0, 4) : [] });
        }
        this._botThinkingPaint(geohash);
    },

    _botRunAskerHidden(run) {
        const askers = run && Array.isArray(run.askers) ? run.askers : [];
        return askers.length > 0 && typeof this.isPersonHidden === 'function' && askers.some((pk) => this.isPersonHidden(pk));
    },

    _botThinkingRefreshForFilters() {
        if (!this._botChannelTypingRuns) return;
        for (const geohash of Array.from(this._botChannelTypingRuns.keys())) this._botThinkingPaint(geohash);
    },

    _botThinkingPaint(geohash) {
        if (!this.verifiedBot || !geohash) return;
        if (!this.typingUsers) this.typingUsers = new Map();
        const convKey = `channel-${geohash}`;
        if (!this.typingUsers.has(convKey)) this.typingUsers.set(convKey, new Map());
        const typers = this.typingUsers.get(convKey);
        const botPk = this.verifiedBot.pubkey;
        const prev = typers.get(botPk);
        if (prev && prev.timeout) clearTimeout(prev.timeout);
        const now = Date.now();
        let until = 0;
        let next = Infinity;
        const set = this._botChannelRuns && this._botChannelRuns.get(geohash);
        if (set) for (const r of set) until = Math.max(until, this._botChannelRunEndAt(r));
        const runs = this._botChannelTypingRuns && this._botChannelTypingRuns.get(geohash);
        if (runs) {
            for (const [id, run] of runs) {
                const expires = typeof run === 'number' ? run : (run && run.expires) || 0;
                if (expires <= now) { runs.delete(id); continue; }
                if (this._botRunAskerHidden(run)) continue;
                until = Math.max(until, expires);
                next = Math.min(next, expires);
            }
            if (!runs.size) this._botChannelTypingRuns.delete(geohash);
        }
        if (until > now) {
            const wait = Math.max(1000, Math.min(next, until) - now);
            const timeout = setTimeout(() => this._botThinkingPaint(geohash), wait);
            typers.set(botPk, { nym: 'Nymbot', timeout, timestamp: now, ttlMs: until - now, run: true });
        } else if (prev) {
            typers.delete(botPk);
        }
        if (typeof this.renderTypingIndicator === 'function') this.renderTypingIndicator();
    },

    _botReplyLanded(geohash, ev) {
        if (!this.verifiedBot || !geohash) return;
        const runId = this._botChannelRunIdOf(ev);
        this._botChannelRemoteEnd(geohash, runId);
        const mine = runId && this._botChannelRuns && this._botChannelRuns.get(geohash);
        if (mine) {
            for (const r of Array.from(mine)) {
                if (r.remoteId !== runId) continue;
                r.landed = true;
                this._botChannelRunEnd(r);
            }
        }
        this._botThinkingPaint(geohash);
    },

    setupCommands() {
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
            '?changelog': { desc: 'Latest Nymchat release notes' },
            '?help': { desc: 'Show all Nymbot commands' },
        };
        this.botPMCommands = {
            '?help': { desc: 'Guide to premium, Pro models & credits (free)' },
            '?model': { desc: 'Pick a Pro frontier model (?model off for standard)' },
            '?image': { desc: 'Generate an image (--model <name> on Pro; ?image models)' },
            '?speak': { desc: 'Read text aloud as a voice clip' },
            '?buy': { desc: 'Buy Nymbot credits (Standard/Pro switch)' },
            '?balance': { desc: 'Check your standard & Pro credit balances' },
            '?gift': { desc: 'Gift Nymbot credits to another user' },
            '?transfer': { desc: 'Transfer ALL your Nymbot credits to another pubkey' },
            '?anon': { desc: 'Chat from a throwaway key Nymbot can never link to your nym' },
            '?clear': { desc: 'Clear Nymbot chat history and start fresh' },
        };
        this.commands = {
            '/help':          { desc: 'Show all commands',              cat: 'misc',       fn: () => this.showHelp() },
            '/join':          { desc: 'Join channel',                   cat: 'channels',   aliases: ['/j'], fn: (args) => this.cmdJoin(args) },
            '/j':             { aliasOf: '/join',                       fn: (args) => this.cmdJoin(args) },
            '/pm':            { desc: 'Send private message',           cat: 'pms',        fn: (args) => this.cmdPM(args) },
            '/nick':          { desc: 'Change nickname',                cat: 'misc',       fn: (args) => this.cmdNick(args) },
            '/who':           { desc: 'Show active users',              cat: 'channels',   aliases: ['/w'], fn: () => this.cmdWho() },
            '/w':             { aliasOf: '/who',                        fn: () => this.cmdWho() },
            '/clear':         { desc: 'Clear conversation',             cat: 'misc',       fn: () => this.cmdClear() },
            '/me':            { desc: 'Action message',                 cat: 'misc', fn: (args) => this.cmdMe(args) },
            '/bold':          { desc: 'Bold text (**text**)',           cat: 'formatting', aliases: ['/b'], fn: (args) => this.cmdBold(args) },
            '/b':             { aliasOf: '/bold',                       fn: (args) => this.cmdBold(args) },
            '/italic':        { desc: 'Italic text (*text*)',           cat: 'formatting', aliases: ['/i'], fn: (args) => this.cmdItalic(args) },
            '/i':             { aliasOf: '/italic',                     fn: (args) => this.cmdItalic(args) },
            '/underline':     { desc: 'Underline text (__text__)',      cat: 'formatting', aliases: ['/u'], fn: (args) => this.cmdUnderline(args) },
            '/u':             { aliasOf: '/underline',                  fn: (args) => this.cmdUnderline(args) },
            '/strike':        { desc: 'Strikethrough text (~~text~~)',  cat: 'formatting', aliases: ['/s'], fn: (args) => this.cmdStrike(args) },
            '/s':             { aliasOf: '/strike',                     fn: (args) => this.cmdStrike(args) },
            '/spoiler':       { desc: 'Spoiler text (||text||)',        cat: 'formatting', fn: (args) => this.cmdSpoiler(args) },
            '/subtext':       { desc: 'Small dimmed text (-# text)',    cat: 'formatting', fn: (args) => this.cmdSubtext(args) },
            '/timestamp':     { desc: 'Timestamp in each reader\'s time zone',  cat: 'formatting', fn: (args) => this.cmdTimestamp(args) },
            '/code':          { desc: 'Code block (`code`)',            cat: 'formatting', aliases: ['/c'], fn: (args) => this.cmdCode(args) },
            '/c':             { aliasOf: '/code',                       fn: (args) => this.cmdCode(args) },
            '/quote':         { desc: 'Quote text (> quote)',           cat: 'formatting', aliases: ['/q'], fn: (args) => this.cmdQuote(args) },
            '/q':             { aliasOf: '/quote',                      fn: (args) => this.cmdQuote(args) },
            '/brb':           { desc: 'Set away message',               cat: 'misc',       fn: (args) => this.cmdBRB(args) },
            '/back':          { desc: 'Clear away message',             cat: 'misc',       fn: () => this.cmdBack() },
            '/search':        { desc: 'Search this chat',               cat: 'misc',       fn: (args) => this.cmdSearch(args) },
            '/zap':           { desc: 'Zap profile',                    cat: 'misc',       fn: (args) => this.cmdZap(args) },
            '/block':         { desc: 'Block user/#channel',            cat: 'pms',        fn: (args) => this.cmdBlock(args) },
            '/unblock':       { desc: 'Unblock user/#channel',          cat: 'pms',        fn: (args) => this.cmdUnblock(args) },
            '/invite':        { desc: 'Invite to chat',                 cat: 'pms',        fn: (args) => this.cmdInvite(args) },
            '/group':         { desc: 'Create private group',           cat: 'groups',     fn: (args) => this.cmdGroup(args) },
            '/addmember':     { desc: 'Add group member',               cat: 'groups',     fn: (args) => this.cmdAddMember(args) },
            '/groupinfo':     { desc: 'Show group members',             cat: 'groups',     fn: () => this.cmdGroupInfo() },
            '/share':         { desc: 'Share #channel URL',             cat: 'channels',   fn: () => this.cmdShare() },
            '/leave':         { desc: 'Leave conversation',             cat: 'pms',        fn: () => this.cmdLeave() },
            '/poll':          { desc: 'Create poll',                    cat: 'channels',   fn: () => this.cmdPoll() },
            '/kick':          { desc: 'Remove member (owner/admin/mod)', cat: 'groups',     fn: (args) => this.cmdKick(args) },
            '/ban':           { desc: 'Ban member (owner/admin/mod)',  cat: 'groups',     fn: (args) => this.cmdBanFromGroup(args) },
            '/unban':         { desc: 'Unban member (owner/admin/mod)', cat: 'groups',     fn: (args) => this.cmdUnbanFromGroup(args) },
            '/addmod':        { desc: 'Promote to moderator (owner/admin)', cat: 'groups', fn: (args) => this.cmdAddMod(args) },
            '/removemod':     { desc: 'Remove moderator (owner/admin)',  cat: 'groups',     fn: (args) => this.cmdRemoveMod(args) },
            '/addadmin':      { desc: 'Promote to admin (owner)',       cat: 'groups',     fn: (args) => this.cmdAddAdmin(args) },
            '/removeadmin':   { desc: 'Remove admin (owner)',           cat: 'groups',     fn: (args) => this.cmdRemoveAdmin(args) },
            '/transferowner': { desc: 'Change group ownership',         cat: 'groups',     fn: (args) => this.cmdTransferOwner(args) },
            '/slap':          { desc: 'Slap someone with a trout 🐟',   cat: 'misc', fn: (args) => this.cmdSlap(args) },
            '/hug':           { desc: 'Give someone a warm hug 🫂',     cat: 'misc', fn: (args) => this.cmdHug(args) },
            '/quit':          { desc: 'Disconnect from Nymchat',        cat: 'misc',       fn: () => this.cmdQuit() }
        };
        this.commandCategories = [
            ['channels',   'Public Channels'],
            ['pms',        'Private Messages'],
            ['groups',     'Groups'],
            ['formatting', 'Formatting'],
            ['misc',       'Misc']
        ];
        this.kaomojiCategories = [
            ['Joy',       ['(◕‿◕)', '(◠‿◠)', '(*^‿^*)', '(≧◡≦)', 'ヽ(•‿•)ノ', '(´∇｀)', '＼(^o^)／']],
            ['Love',      ['(♥‿♥)', '(づ｡◕‿‿◕｡)づ', '♡(◡‿◡)', '(*♡∀♡)', '(❤ω❤)']],
            ['Sad',       ['(╥﹏╥)', '(｡•́︿•̀｡)', '(T_T)', '(ಥ_ಥ)', '(´；ω；`)', 'orz']],
            ['Anger',     ['(╬ಠ益ಠ)', 'ヽ(`Д´)ﾉ', '(ノಠ益ಠ)ノ', '凸(￣ヘ￣)', '(＃`Д´)']],
            ['Surprise',  ['(⊙_⊙)', '(°ロ°)', 'Σ(°△°)', '(ﾟοﾟ)']],
            ['Confused',  ['¯\\_(ツ)_/¯', '(•_•)?', '(°ヘ°)', '(￣～￣;)']],
            ['Tableflip', ['(╯°□°)╯︵ ┻━┻', '┬─┬ノ( º_ºノ)', '(ノಠ益ಠ)ノ彡┻━┻']],
            ['Animals',   ['(=^･ω･^=)', 'ʕ•ᴥ•ʔ', '(•ㅅ•)', '/ᐠ｡ꞈ｡ᐟ\\', '>°)))彡']],
            ['Misc',      ['(☞ﾟヮﾟ)☞', 'ᕦ(ò_óˇ)ᕤ', '(⌐■_■)', '(◔_◔)', '~(˘▽˘~)']],
        ];
        this.cmdI18nEnsure();
    },

    // Hides aliasOf entries so each command shows once.
    _visibleCommandEntries() {
        return Object.entries(this.commands).filter(([, info]) => !(info && info.aliasOf));
    },

    _formatCommandDisplay(cmd, info) {
        const shown = this.localizeCommandToken(cmd);
        if (!info || !info.aliases || info.aliases.length === 0) return shown;
        return `${shown}, ${info.aliases.join(', ')}`;
    },

    _groupCommandsByCategory(entries) {
        const cats = this.commandCategories || [['misc', 'Misc']];
        return cats
            .map(([key, label]) => [label, entries.filter(([, info]) => (info.cat || 'misc') === key)])
            .filter(([, items]) => items.length > 0);
    },

    showCommandPalette(input) {
        const palette = document.getElementById('commandPalette');
        const needle = input.toLowerCase();
        const matchingCommands = this._visibleCommandEntries().filter(([cmd, info]) => {
            if (cmd.startsWith(needle)) return true;
            if (this.localizeCommandToken(cmd).startsWith(needle)) return true;
            if (Array.isArray(info.aliases) && info.aliases.some(a => a.startsWith(needle))) return true;
            return false;
        });

        if (matchingCommands.length > 0) {
            let firstAssigned = false;
            palette.innerHTML = this._groupCommandsByCategory(matchingCommands).map(([label, items]) => {
                const rows = items.map(([cmd, info]) => {
                    const selected = firstAssigned ? '' : ' selected';
                    firstAssigned = true;
                    return `
                <div class="command-item${selected}" data-command="${this.localizeCommandToken(cmd)}">
                    <span class="command-name">${this._formatCommandDisplay(cmd, info)}</span>
                    <span class="command-desc">${info.desc}</span>
                </div>`;
                }).join('');
                return `<div class="command-category">${label}</div>${rows}`;
            }).join('');
            palette.classList.add('active');
            this.commandPaletteIndex = 0;
        } else {
            this.hideCommandPalette();
        }
    },

    // Returns { base, remainder, entries } where base is the typed prefix entries append to.
    _botPMSubcommands(cmd, rest) {
        if (cmd === '?model') {
            return {
                base: `${cmd} `,
                remainder: rest,
                entries: (this._botProModels || []).map(m =>
                    [m.key, `${m.label} — ${this._botProPriceLabel(m)}`]
                ).concat([['off', 'Back to standard multi-model routing']])
            };
        }
        return null;
    },

    showBotCommandPalette(input) {
        const palette = document.getElementById('commandPalette');
        // The premium Nymbot PM only supports PM commands; channel bot commands aren't wired there.
        const inBotPM = this.inPMMode && this.currentPM && this.isVerifiedBot(this.currentPM);
        const available = inBotPM ? this.botPMCommands : this.botCommands;
        const needle = input.toLowerCase();
        let matchingCommands = Object.entries(available)
            .filter(([cmd]) => cmd.startsWith(needle) || this.localizeCommandToken(cmd).startsWith(needle));
        if (inBotPM && matchingCommands.length === 0) {
            const m = /^(\?\S+)\s+(.*)$/.exec(input.toLowerCase());
            const ctx = m && this._botPMSubcommands(this.resolveCommandToken(m[1]) || m[1], m[2]);
            if (ctx) {
                // Completions append to what the user typed so a localized command name survives.
                const base = m[1] + ctx.base.slice(ctx.base.indexOf(' '));
                matchingCommands = ctx.entries
                    .filter(([sub]) => sub.startsWith(ctx.remainder))
                    .map(([sub, desc]) => [`${base}${sub}`, { desc }]);
            }
        }

        if (matchingCommands.length > 0) {
            palette.innerHTML = matchingCommands.map(([cmd, info], index) => `
                <div class="command-item ${index === 0 ? 'selected' : ''}" data-command="${this.localizeCommandToken(cmd)}">
                    <span class="command-name">${this.localizeCommandToken(cmd)}</span>
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
        if (selected && selected.dataset.command) {
            const cmd = selected.dataset.command;
            const input = document.getElementById('messageInput');
            input.value = cmd + ' ';
            input.focus();
            // Programmatic value changes don't fire the input handler, so re-evaluate the palette.
            if (cmd.startsWith('?')) {
                this.showBotCommandPalette(input.value);
            } else {
                this.hideCommandPalette();
            }
        }
    },

    handleCommand(command) {
        const parts = command.split(' ');
        const cmd = this.resolveCommandToken(parts[0]) || parts[0].toLowerCase();
        const args = parts.slice(1).join(' ');

        const commandInfo = this.commands[cmd];
        if (commandInfo) {
            commandInfo.fn(args);
        } else {
            this.displaySystemMessage(this.uiText(`Unknown command: {cmd}`, { cmd }));
        }
    },

    showHelp() {
        const groups = this._groupCommandsByCategory(this._visibleCommandEntries())
            .map(([label, items]) => {
                const lines = items
                    .map(([cmd, info]) => `<div class="help-cmd"><span class="help-cmd-name">${this.escapeHtml(this._formatCommandDisplay(cmd, info))}</span> — ${this.escapeHtml(info.desc)}</div>`)
                    .join('');
                return `<div class="help-category">${this.escapeHtml(label)}</div>${lines}`;
            })
            .join('');

        const footer = [
            'Markdown supported: **bold**, *italic*, __underline__, ~~strikethrough~~, ||spoiler||, `code`, > quote, -# subtext, - list, 1. list, <t:unix:f> timestamp',
            'Type : to quickly pick an emoji',
            'Type \\ to pick a kaomoji like ¯\\_(ツ)_/¯',
            'Nyms are shown as name#xxxx where xxxx is the last 4 characters of their pubkey',
            'Click on users for more options'
        ].map(line => this.escapeHtml(line)).join('<br><br>');

        this.displaySystemMessage(
            `<div class="help-output"><div class="help-title">Available commands</div>${groups}<div class="help-footer">${footer}</div></div>`,
            'system',
            { html: true }
        );
    },

    async cmdJoin(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /join #channel (e.g., /join #9q5, /join #nymchat, or /join nym)');
            return;
        }

        let channel = args.trim().toLowerCase();

        if (channel.startsWith('#')) {
            channel = channel.substring(1);
        }

        // Only letters (including international) and digits.
        channel = this.sanitizeChannelName(channel);

        if (!channel) {
            this.displaySystemMessage('Invalid channel name. Only letters and numbers are allowed.');
            return;
        }

        if (this.isChannelBlocked(channel, channel)) {
            this.displaySystemMessage(this.uiText(`Channel #{channel} is blocked. Use /unblock #{channel2} to unblock it first.`, { channel, channel2: channel }));
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
                this.leaveGroup(this.currentGroup);
            } else if (this.currentPM) {
                this.deletePMDirect(this.currentPM);
            }
            return;
        }

        if (this.currentGeohash === 'nymchat') {
            this.displaySystemMessage('Cannot leave the default #nymchat channel');
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

        if (this.isReservedNick(newNym)) {
            const result = await showDevNsecModal('nick');
            if (!result) {
                this.displaySystemMessage('Nickname change canceled.');
                return null;
            }
            this.applyDeveloperIdentity(result.secretKey, result.pubkey);
            this.displaySystemMessage(this.uiText(`Identity verified. You are now logged in as {nym}.`, { nym: this.nym }));
            return result;
        }

        this.nym = newNym;
        document.getElementById('currentNym').innerHTML = this.formatNymWithPubkey(this.nym, this.pubkey);
        this.updateSidebarAvatar();

        localStorage.setItem(`nym_nickname_${this.pubkey}`, newNym);
        // Mark as user-chosen so it qualifies for D1 mirroring.
        try { localStorage.setItem('nym_custom_nick', newNym); } catch (_) { }
        if (localStorage.getItem('nym_auto_ephemeral') === 'true') {
            localStorage.setItem('nym_auto_ephemeral_nick', newNym);
        }

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

        this.updateStoredNymsForPubkey(this.pubkey, newNym);
        this.updatePMNicknameFromProfile(this.pubkey, newNym);

        await this.saveToNostrProfile();

        const changeMessage = this.uiText("Your nym's new nick is now {nym}", { nym: this.nym });
        this.displaySystemMessage(changeMessage);
    },

    async cmdWho() {
        if (this.inPMMode) {
            this.displaySystemMessage('/who only works in public channels.');
            return;
        }
        const currentChannelKey = this.currentGeohash || this.currentChannel;
        const channelUserSet = this.channelUsers.get(currentChannelKey) || new Set();

        const users = Array.from(channelUserSet)
            .map(pubkey => this.users.get(pubkey))
            .filter(u => u && this._onlineIn(u, currentChannelKey, Date.now()))
            .filter(u => (typeof this.isPersonHidden === 'function'
                ? !this.isPersonHidden(u.pubkey, u.nym)
                : !this.blockedUsers.has(u.pubkey)))
            .map(u => {
                const baseNym = this.stripPubkeySuffix(u.nym);
                const suffix = this.getPubkeySuffix(u.pubkey);
                return `${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>`;
            })
            .join(', ');

        this.displaySystemMessage(`Online nyms in this channel: <span data-no-i18n>${users || 'none'}</span>`, 'system', { html: true, feed: true });
    },

    async cmdClear() {
        document.getElementById('messagesContainer').innerHTML = '';
        this.displaySystemMessage('Chat cleared');
    },

    async cmdInvite(args) {
        if (!args) {
            if (this.inPMMode && this.currentGroup) {
                this.displaySystemMessage('Usage: /invite @nym — adds a user to this group');
            } else if (this.inPMMode && this.currentPM) {
                this.startGroupFromPM(null);
            } else {
                this.displaySystemMessage('Usage: /invite @nym, /invite nym#xxxx, or /invite [pubkey]');
            }
            return;
        }

        if (this.inPMMode && this.currentGroup) {
            const targetInput = args.trim().replace(/^@/, '');
            const targetPubkey = this.resolvePubkeyFromNym(targetInput);
            if (!targetPubkey) {
                this.displaySystemMessage(this.uiText(`User @{targetInput} not found. They need to be visible in a channel first.`, { targetInput }));
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
            await this.addMembersToGroup(this.currentGroup, [targetPubkey]);
            return;
        }

        if (this.inPMMode && this.currentPM) {
            const extra = args && args.trim() ? this.resolvePubkeyFromNym(args.trim().replace(/^@/, '')) : null;
            if (args && args.trim() && !extra) {
                this.displaySystemMessage(this.uiText(`User @{v1} not found. They need to be visible in a channel first.`, { v1: args.trim().replace(/^@/, '') }));
                return;
            }
            this.startGroupFromPM(extra);
            return;
        }
        if (this.inPMMode) {
            this.displaySystemMessage('Use /group @nym to create a group with this person, or switch to a channel first');
            return;
        }

        const targetInput = this.normalizePubkeyInput(args) || args.trim().replace(/^@/, '');
        let targetPubkey = null;
        let matchedNym = null;

        if (/^[0-9a-f]{64}$/i.test(targetInput)) {
            targetPubkey = targetInput.toLowerCase();

            if (targetPubkey === this.pubkey) {
                this.displaySystemMessage("You can't invite yourself");
                return;
            }

            matchedNym = this.getNymFromPubkey(targetPubkey);
        } else {
            const hashIndex = targetInput.indexOf('#');
            let searchNym = targetInput;
            let searchSuffix = null;

            if (hashIndex !== -1) {
                searchNym = targetInput.substring(0, hashIndex);
                searchSuffix = targetInput.substring(hashIndex + 1);
            }

            const matches = [];
            this.users.forEach((user, pubkey) => {
                const baseNym = this.stripPubkeySuffix(user.nym);
                if (baseNym === searchNym || baseNym.toLowerCase() === searchNym.toLowerCase()) {
                    if (searchSuffix) {
                        if (pubkey.endsWith(searchSuffix)) {
                            matches.push({ nym: user.nym, pubkey: pubkey });
                        }
                    } else {
                        matches.push({ nym: user.nym, pubkey: pubkey });
                    }
                }
            });

            if (matches.length === 0) {
                this.displaySystemMessage(this.uiText(`User {targetInput} not found`, { targetInput }));
                return;
            }

            if (matches.length > 1 && !searchSuffix) {
                const matchList = matches.map(m =>
                    `${this.formatNymWithPubkey(m.nym, m.pubkey)}`
                ).join(', ');
                this.displaySystemMessage(`Multiple users found with nym "<span data-no-i18n>${this.escapeHtml(searchNym)}</span>": <span data-no-i18n>${matchList}</span>`, 'system', { html: true, feed: true });
                this.displaySystemMessage('Please specify using the #xxxx suffix or full pubkey', 'system', { feed: true });
                return;
            }

            targetPubkey = matches[0].pubkey;
            matchedNym = matches[0].nym;

            if (targetPubkey === this.pubkey) {
                this.displaySystemMessage("You can't invite yourself");
                return;
            }
        }

        const channelInfo = `#${this.currentGeohash}`;
        const joinCommand = `/join #${this.currentGeohash}`;

        const inviteMessage = `📨 Channel Invitation: You've been invited to join ${channelInfo}. Use ${joinCommand} to join!`;

        const sent = await this.sendPM(inviteMessage, targetPubkey);

        if (sent) {
            const displayNym = this.formatNymWithPubkey(matchedNym, targetPubkey);
            this.displaySystemMessage(`Invitation sent to <span data-no-i18n>${displayNym}</span> for <span data-no-i18n>${this.escapeHtml(channelInfo)}</span>`, 'system', { html: true });

            const publicNotice = `@${matchedNym} you've been invited to this channel! Check your PMs for details.`;
            await this.publishMessage(publicNotice, this.currentChannel, this.currentGeohash);
        } else {
            this.displaySystemMessage(`Failed to send invitation to <span data-no-i18n>${this.formatNymWithPubkey(matchedNym, targetPubkey)}</span>`, 'system', { html: true });
        }
    },

    async cmdAddMember(args) {
        if (this.inPMMode && this.currentPM && !this.currentGroup) {
            const extra = args && args.trim() ? this.resolvePubkeyFromNym(args.trim().replace(/^@/, '')) : null;
            if (args && args.trim() && !extra) {
                this.displaySystemMessage(this.uiText(`User @{v1} not found`, { v1: args.trim().replace(/^@/, '') }));
                return;
            }
            this.startGroupFromPM(extra);
            return;
        }
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
            this.displaySystemMessage(this.uiText(`User @{targetInput} not found`, { targetInput }));
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
        await this.addMembersToGroup(this.currentGroup, [targetPubkey]);
    },

    _resolveGroupTarget(args, usage) {
        if (!this.inPMMode || !this.currentGroup) {
            this.displaySystemMessage('You must be in a group conversation to use this command.');
            return null;
        }
        if (!args || !args.trim()) {
            this.displaySystemMessage(usage);
            return null;
        }
        const targetInput = args.trim().replace(/^@/, '');
        const targetPubkey = this.resolvePubkeyFromNym(targetInput);
        if (!targetPubkey) {
            this.displaySystemMessage(this.uiText(`User @{targetInput} not found. Try @nym#xxxx or a hex pubkey.`, { targetInput }));
            return null;
        }
        return targetPubkey;
    },

    async cmdKick(args) {
        const pk = this._resolveGroupTarget(args, 'Usage: /kick @nym (or hex pubkey)');
        if (!pk) return;
        if (pk === this.pubkey) { this.displaySystemMessage("You can't kick yourself."); return; }
        await this.kickFromGroup(pk);
    },

    async cmdBanFromGroup(args) {
        const pk = this._resolveGroupTarget(args, 'Usage: /ban @nym (or hex pubkey)');
        if (!pk) return;
        if (pk === this.pubkey) { this.displaySystemMessage("You can't ban yourself."); return; }
        await this.banFromGroup(pk);
    },

    async cmdUnbanFromGroup(args) {
        const pk = this._resolveGroupTarget(args, 'Usage: /unban @nym (or hex pubkey)');
        if (!pk) return;
        await this.unbanFromGroup(pk);
    },

    async cmdAddMod(args) {
        const pk = this._resolveGroupTarget(args, 'Usage: /addmod @nym (or hex pubkey)');
        if (!pk) return;
        await this.promoteModerator(pk);
    },

    async cmdRemoveMod(args) {
        const pk = this._resolveGroupTarget(args, 'Usage: /removemod @nym (or hex pubkey)');
        if (!pk) return;
        await this.revokeModerator(pk);
    },

    async cmdAddAdmin(args) {
        const pk = this._resolveGroupTarget(args, 'Usage: /addadmin @nym (or hex pubkey)');
        if (!pk) return;
        await this.promoteAdmin(pk);
    },

    async cmdRemoveAdmin(args) {
        const pk = this._resolveGroupTarget(args, 'Usage: /removeadmin @nym (or hex pubkey)');
        if (!pk) return;
        await this.revokeAdmin(pk);
    },

    async cmdTransferOwner(args) {
        const pk = this._resolveGroupTarget(args, 'Usage: /transferowner @nym (or hex pubkey)');
        if (!pk) return;
        if (pk === this.pubkey) { this.displaySystemMessage("You're already the owner."); return; }
        if (!(await window.showAppConfirm('Transfer group ownership to this user? You will lose owner privileges.', { danger: true, okLabel: 'Transfer' }))) return;
        await this.transferOwner(pk);
    },

    async cmdBlock(args) {
        if (!args) {
            if (this.inPMMode) {
                this.displaySystemMessage('Usage: /block nym, /block nym#xxxx, /block [pubkey], or /block #channel');
                return;
            }

            const currentChannelName = this.currentGeohash || this.currentChannel;
            if (this.currentGeohash === 'nymchat') {
                this.displaySystemMessage('Cannot block the default #nymchat channel');
                return;
            }

            if (await window.showAppConfirm(`Block channel #${currentChannelName}?`, { danger: true, okLabel: 'Block' })) {
                this.blockChannel(this.currentGeohash, this.currentGeohash);
                this.displaySystemMessage(this.isValidGeohash(this.currentGeohash)
                    ? this.uiText('Blocked geohash channel #{channel}', { channel: this.currentGeohash })
                    : this.uiText('Blocked channel #{channel}', { channel: this.currentGeohash }));

                this.switchChannel('nymchat', 'nymchat');

                this.updateBlockedChannelsList();

            }
            return;
        }

        const target = args.trim();

        if (target.startsWith('#') && !target.includes('@')) {
            const channelName = target.substring(1);

            if (this.currentGeohash === channelName) {
                if (await window.showAppConfirm(`Block and leave channel #${channelName}?`, { danger: true, okLabel: 'Block' })) {
                    this.blockChannel(channelName, channelName);
                    this.displaySystemMessage(this.isValidGeohash(channelName)
                        ? this.uiText('Blocked geohash channel #{channel}', { channel: channelName })
                        : this.uiText('Blocked channel #{channel}', { channel: channelName }));

                    this.switchChannel('nymchat', 'nymchat');

                    this.updateBlockedChannelsList();
                }
                return;
            }

            if (channelName === 'nymchat') {
                this.displaySystemMessage("Cannot block the default #nymchat channel");
                return;
            }

            this.blockChannel(channelName, channelName);
            if (this.isValidGeohash(channelName)) {
                this.displaySystemMessage(this.uiText(`Blocked geohash channel #{channelName}`, { channelName }));
            } else {
                this.displaySystemMessage(this.uiText(`Blocked channel #{channelName}`, { channelName }));
            }

            this.updateBlockedChannelsList();


            return;
        }

        let targetPubkey = this.normalizePubkeyInput(target);
        if (!targetPubkey) {
            targetPubkey = await this.findUserPubkey(target);
            if (!targetPubkey) return;
        }

        const nymHtml = this.getNymHtmlFromPubkey(targetPubkey);

        if (this.blockedUsers.has(targetPubkey)) {
            this.blockedUsers.delete(targetPubkey);
            this.saveBlockedUsers();
            this.showMessagesFromUnblockedUser(targetPubkey);

            this.displaySystemMessage(`Unblocked <span data-no-i18n>${nymHtml}</span>`, 'system', { html: true });
            this.updateUserList();
            this.updateBlockedList();
            if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
            return;
        }

        this.blockedUsers.add(targetPubkey);
        this.saveBlockedUsers();
        this.hideMessagesFromBlockedUser(targetPubkey);

        this.displaySystemMessage(`Blocked <span data-no-i18n>${nymHtml}</span>`, 'system', { html: true });
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

        if (target.startsWith('#')) {
            const channelName = target.substring(1);

            if (this.blockedChannels.has(channelName)) {
                if (this.isValidGeohash(channelName)) {
                    this.unblockChannel(channelName, channelName);
                    this.displaySystemMessage(this.uiText(`Unblocked geohash channel #{channelName}`, { channelName }));
                } else {
                    this.unblockChannel(channelName, '');
                    this.displaySystemMessage(this.uiText(`Unblocked channel #{channelName}`, { channelName }));
                }

                this.updateBlockedChannelsList();

            } else {
                this.displaySystemMessage(this.uiText(`Channel #{channelName} is not blocked`, { channelName }));
            }
            return;
        }

        const targetPubkey = await this.findUserPubkey(target);
        if (!targetPubkey) {
            this.displaySystemMessage(this.uiText(`User {target} not found or is not blocked`, { target }));
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

        this.displaySystemMessage(`Unblocked <span data-no-i18n>${this.formatNymWithPubkey(targetNym, targetPubkey)}</span>`, 'system', { html: true });
        this.updateUserList();
        this.updateBlockedList();
        if (typeof nostrSettingsSave === 'function') nostrSettingsSave();
    },

    _checkActionCommandRateLimit() {
        const now = Date.now();
        const windowMs = 30000; // 30s window
        const maxActions = 3;   // up to 3 action commands per window
        const tracker = this.actionCommandTracker || (this.actionCommandTracker = { timestamps: [], cooldownUntil: 0 });

        if (now < tracker.cooldownUntil) {
            const remaining = Math.ceil((tracker.cooldownUntil - now) / 1000);
            this.displaySystemMessage(this.uiText(`Slow down! You can use /me, /slap, or /hug again in {remaining}s`, { remaining }));
            return false;
        }

        tracker.timestamps = tracker.timestamps.filter(ts => now - ts < windowMs);
        if (tracker.timestamps.length >= maxActions) {
            tracker.cooldownUntil = now + 60000; // 1 minute cooldown
            this.displaySystemMessage('Too many action commands. Try again in 60s');
            return false;
        }

        tracker.timestamps.push(now);
        return true;
    },

    async cmdSlap(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /slap nym, /slap nym#xxxx, or /slap [pubkey]');
            return;
        }
        if (!this._checkActionCommandRateLimit()) return;

        const targetInput = this.normalizePubkeyInput(args) || args.trim().replace(/^@/, '');
        let targetNym = '';
        let targetPubkey = null;

        if (/^[0-9a-f]{64}$/i.test(targetInput)) {
            targetPubkey = targetInput.toLowerCase();
            const user = this.users.get(targetPubkey);
            if (user) {
                targetNym = this.parseNymFromDisplay(user.nym);
            } else {
                targetNym = `nym#${targetPubkey.slice(-4)}`;
            }
        } else {
            const hashIndex = targetInput.indexOf('#');
            let searchNym = targetInput;
            let searchSuffix = null;

            if (hashIndex !== -1) {
                searchNym = targetInput.substring(0, hashIndex);
                searchSuffix = targetInput.substring(hashIndex + 1);
            }

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
                this.displaySystemMessage(`Multiple users found with nym "<span data-no-i18n>${this.escapeHtml(searchNym)}</span>": <span data-no-i18n>${matchList}</span>`, 'system', { html: true, feed: true });
                this.displaySystemMessage('Please specify using the #xxxx suffix or full pubkey', 'system', { feed: true });
                return;
            }

            if (matches.length > 0) {
                targetNym = matches[0].nym;
                targetPubkey = matches[0].pubkey;
            } else {
                targetNym = searchNym;
            }
        }

        // Full @nym#suffix so the renderer attaches the avatar, suffix, and flair.
        const targetMention = targetPubkey
            ? `@${targetNym}#${this.getPubkeySuffix(targetPubkey)}`
            : `@${targetNym}`;
        const slapContent = `/me slaps ${targetMention} around a bit with a large trout 🐟`;

        try {
            await this._sendToCurrentTarget(slapContent);
        } catch (error) {
            this.displaySystemMessage(this.uiText('Failed to send slap: {error}', { error: error.message }));
        }
    },

    async cmdHug(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /hug nym, /hug nym#xxxx, or /hug [pubkey]');
            return;
        }
        if (!this._checkActionCommandRateLimit()) return;

        const targetInput = this.normalizePubkeyInput(args) || args.trim().replace(/^@/, '');
        let targetNym = '';
        let targetPubkey = null;

        if (/^[0-9a-f]{64}$/i.test(targetInput)) {
            targetPubkey = targetInput.toLowerCase();
            const user = this.users.get(targetPubkey);
            if (user) {
                targetNym = this.parseNymFromDisplay(user.nym);
            } else {
                targetNym = `nym#${targetPubkey.slice(-4)}`;
            }
        } else {
            const hashIndex = targetInput.indexOf('#');
            let searchNym = targetInput;
            let searchSuffix = null;

            if (hashIndex !== -1) {
                searchNym = targetInput.substring(0, hashIndex);
                searchSuffix = targetInput.substring(hashIndex + 1);
            }

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
                this.displaySystemMessage(`Multiple users found with nym "<span data-no-i18n>${this.escapeHtml(searchNym)}</span>": <span data-no-i18n>${matchList}</span>`, 'system', { html: true, feed: true });
                this.displaySystemMessage('Please specify using the #xxxx suffix or full pubkey', 'system', { feed: true });
                return;
            }

            if (matches.length > 0) {
                targetNym = matches[0].nym;
                targetPubkey = matches[0].pubkey;
            } else {
                targetNym = searchNym;
            }
        }

        const targetMention = targetPubkey
            ? `@${targetNym}#${this.getPubkeySuffix(targetPubkey)}`
            : `@${targetNym}`;
        const hugContent = `/me gives ${targetMention} a warm hug 🫂`;

        try {
            await this._sendToCurrentTarget(hugContent);
        } catch (error) {
            this.displaySystemMessage(this.uiText('Failed to send hug: {error}', { error: error.message }));
        }
    },

    async cmdMe(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /me action');
            return;
        }
        if (!this._checkActionCommandRateLimit()) return;

        const content = `/me ${args}`;

        try {
            await this._sendToCurrentTarget(content);
        } catch (error) {
            this.displaySystemMessage(this.uiText('Failed to send message: {error}', { error: error.message }));
        }
    },

    async _sendToCurrentTarget(content) {
        if (this.inPMMode && this.currentGroup) {
            return this.sendGroupMessage(content, this.currentGroup);
        }
        if (this.inPMMode && this.currentPM) {
            return this.sendPM(content, this.currentPM);
        }
        if (this.currentGeohash) {
            return this.publishMessage(content, this.currentGeohash, this.currentGeohash);
        }
        if (this.currentChannel) {
            return this.publishMessage(content, this.currentChannel, this.currentChannel);
        }
        throw new Error('No active conversation to send to');
    },

    async cmdBold(args) {
        if (!args) { this.displaySystemMessage('Usage: /bold text'); return; }
        try { await this._sendToCurrentTarget(`**${args}**`); }
        catch (error) { this.displaySystemMessage(this.uiText('Failed to send message: {error}', { error: error.message })); }
    },

    async cmdItalic(args) {
        if (!args) { this.displaySystemMessage('Usage: /italic text'); return; }
        try { await this._sendToCurrentTarget(`*${args}*`); }
        catch (error) { this.displaySystemMessage(this.uiText('Failed to send message: {error}', { error: error.message })); }
    },

    async cmdStrike(args) {
        if (!args) { this.displaySystemMessage('Usage: /strike text'); return; }
        try { await this._sendToCurrentTarget(`~~${args}~~`); }
        catch (error) { this.displaySystemMessage(this.uiText('Failed to send message: {error}', { error: error.message })); }
    },

    async cmdUnderline(args) {
        if (!args) { this.displaySystemMessage('Usage: /underline text'); return; }
        try { await this._sendToCurrentTarget(`__${args}__`); }
        catch (error) { this.displaySystemMessage(this.uiText('Failed to send message: {error}', { error: error.message })); }
    },

    async cmdSpoiler(args) {
        if (!args) { this.displaySystemMessage('Usage: /spoiler text'); return; }
        try { await this._sendToCurrentTarget(`||${args}||`); }
        catch (error) { this.displaySystemMessage(this.uiText('Failed to send message: {error}', { error: error.message })); }
    },

    async cmdSubtext(args) {
        if (!args) { this.displaySystemMessage('Usage: /subtext text'); return; }
        try { await this._sendToCurrentTarget(`-# ${args}`); }
        catch (error) { this.displaySystemMessage(this.uiText('Failed to send message: {error}', { error: error.message })); }
    },

    async cmdTimestamp(args) {
        if (!args || !args.trim()) {
            if (typeof this.openTimestampPicker === 'function') this.openTimestampPicker();
            return;
        }
        const parsed = window.NymFormat && typeof window.NymFormat.parseTimestampInput === 'function'
            ? window.NymFormat.parseTimestampInput(args) : null;
        if (!parsed) {
            this.displaySystemMessage('Usage: /timestamp YYYY-MM-DD HH:MM [t|T|d|D|f|F|R], or /timestamp with no arguments to pick a date');
            return;
        }
        try { await this._sendToCurrentTarget(parsed.tag); }
        catch (error) { this.displaySystemMessage(this.uiText('Failed to send message: {error}', { error: error.message })); }
    },

    async cmdCode(args) {
        if (!args) { this.displaySystemMessage('Usage: /code text'); return; }
        try { await this._sendToCurrentTarget(`\`\`\`\n${args}\n\`\`\``); }
        catch (error) { this.displaySystemMessage(this.uiText('Failed to send message: {error}', { error: error.message })); }
    },

    async cmdQuote(args) {
        if (!args) { this.displaySystemMessage('Usage: /quote text'); return; }
        try { await this._sendToCurrentTarget(`> ${args}`); }
        catch (error) { this.displaySystemMessage(this.uiText('Failed to send message: {error}', { error: error.message })); }
    },

    async cmdBRB(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /brb message (e.g., /brb lunch, back in 30)');
            return;
        }

        const state = await this.setAwayState(args.trim());

        this.displaySystemMessage(this.uiText(`Away message set: "{message}"`, { message: state.message }));
        this.displaySystemMessage('You will auto-reply to mentions in ALL channels while away');
    },

    async cmdBack() {
        if (await this.clearAwayState()) {
            this.displaySystemMessage('Away message cleared - you are back!');
        } else {
            this.displaySystemMessage('You were not away');
        }
    },

    async cmdQuit() {
        this.displaySystemMessage('Disconnecting from Nymchat...');

        localStorage.removeItem('nym_connection_mode');
        localStorage.removeItem('nym_relay_url');
        localStorage.removeItem('nym_nsec');
        nymSecretRemove('nym_dev_nsec');

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
        const refusal = typeof this._dpRefusal === 'function' ? this._dpRefusal() : '';
        if (refusal) {
            this.displaySystemMessage(refusal);
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
