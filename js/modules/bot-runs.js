const BOT_RUN_MAX_AGE_MS = 3600000;
const BOT_RUN_CLAIM_FIRST_MS = 3000;
const BOT_RUN_CLAIM_CAP_MS = 60000;
const BOT_RUN_POLL_MS = 5000;
const BOT_RUN_STEER_CHARS = 2000;
const BOT_RUN_DEFAULT_LIMIT = 3;
const BOT_RUN_CEILING = 10;
const BOT_RUN_HEX64 = /^[0-9a-f]{64}$/i;

Object.assign(NYM.prototype, {

    botRuns() {
        if (!(this._botRuns instanceof Map)) this._botRuns = new Map();
        return this._botRuns;
    },

    botRunNotes() {
        if (!(this._botRunNotes instanceof Map)) this._botRunNotes = new Map();
        return this._botRunNotes;
    },

    _botRunNow() { return Date.now(); },

    _botRunSleep(ms) { return new Promise((r) => setTimeout(r, ms)); },

    _botRunJitter(ms) { return Math.round(ms * (0.8 + Math.random() * 0.4)); },

    _botRunText(s) {
        return typeof this.uiText === 'function' ? this.uiText(s) : s;
    },

    botMaxRuns() {
        let v = 0;
        try { v = parseInt(localStorage.getItem('nym_botpm_max_runs') || '0', 10); } catch (_) { v = 0; }
        if (!Number.isFinite(v) || v < 1) return 0;
        return Math.min(BOT_RUN_CEILING, v);
    },

    botEffectiveMaxRuns() {
        return this.botMaxRuns() || BOT_RUN_DEFAULT_LIMIT;
    },

    setBotMaxRuns(n, opts) {
        const v = Math.floor(Number(n) || 0);
        const clean = v < 1 ? 0 : Math.min(BOT_RUN_CEILING, v);
        try {
            if (clean) localStorage.setItem('nym_botpm_max_runs', String(clean));
            else localStorage.removeItem('nym_botpm_max_runs');
        } catch (_) { }
        if (!(opts && opts.fromSync) && typeof this._debouncedNostrSettingsSave === 'function') this._debouncedNostrSettingsSave(1500);
        this._botRunsSyncLimitSelect();
    },

    _botRunsSyncLimitSelect() {
        if (typeof document === 'undefined' || !document.getElementById) return;
        const sel = document.getElementById('botMaxRunsSelect');
        if (sel) sel.value = String(this.botEffectiveMaxRuns());
    },

    botSendGuardTake(key) {
        if (!(this._botSendGuard instanceof Set)) this._botSendGuard = new Set();
        if (this._botSendGuard.has(key)) return false;
        this._botSendGuard.add(key);
        return true;
    },

    botSendGuardRelease(key) {
        if (this._botSendGuard instanceof Set) this._botSendGuard.delete(key);
    },

    botReplyToFromRumor(rumor) {
        const tags = rumor && Array.isArray(rumor.tags) ? rumor.tags : [];
        const tag = tags.find((t) => Array.isArray(t) && t[0] === 'nymreply' && typeof t[1] === 'string');
        return tag && BOT_RUN_HEX64.test(tag[1]) ? tag[1].toLowerCase() : null;
    },

    _botReplyAnchor(list, msg) {
        if (!msg || !msg.replyTo || !Array.isArray(list)) return false;
        const asker = list.find((m) => m && m.isOwn && m.nymMessageId === msg.replyTo);
        if (!asker) return false;
        msg._anchorAt = asker.created_at || 0;
        const ms = Number(asker._ms);
        msg._anchorMs = Number.isFinite(ms) && ms > 0 ? ms : (asker.created_at || 0) * 1000;
        return true;
    },

    _botOwnMessageForWrap(wrapId) {
        const bot = this.verifiedBot;
        if (!bot || !wrapId || !(this.pmMessages instanceof Map)) return null;
        const list = this.pmMessages.get(this.getPMConversationKey(bot.pubkey)) || [];
        return list.find((m) => m && m.isOwn && m.id === wrapId) || null;
    },

    _botRunInflightKey() {
        return 'nym_botpm_inflight_' + (this.pubkey || '');
    },

    _botRunLoadInflight() {
        try {
            const raw = JSON.parse(localStorage.getItem(this._botRunInflightKey()) || '[]');
            return Array.isArray(raw) ? raw : [];
        } catch (_) { return []; }
    },

    _botRunPersist() {
        const out = [];
        for (const run of this.botRuns().values()) {
            const extra = Object.assign({}, run.extra);
            delete extra.pqAnnouncement;
            out.push({ id: run.id, eventId: run.eventId, thread: run.thread, content: run.label, startedAt: run.startedAt, extra });
        }
        try {
            if (out.length) localStorage.setItem(this._botRunInflightKey(), JSON.stringify(out));
            else localStorage.removeItem(this._botRunInflightKey());
        } catch (_) { }
    },

    _botRunMake(spec) {
        return {
            id: String(spec.id || spec.eventId || '').toLowerCase(),
            eventId: spec.eventId,
            thread: spec.thread || '',
            content: spec.content || '',
            label: String(spec.content || '').slice(0, 80),
            startedAt: Number(spec.startedAt) || this._botRunNow(),
            extra: Object.assign({}, spec.extra || {}, { eventId: spec.eventId }),
            state: 'running',
            cap: null,
            steer: null,
            progress: '',
            stopped: false,
            gen: 0,
            ctrl: null
        };
    },

    _botRunStart(spec) {
        const runs = this.botRuns();
        const id = String(spec.id || spec.eventId || '').toLowerCase();
        if (!id || !spec.eventId) return null;
        if (runs.has(id)) return runs.get(id);
        const run = this._botRunMake(spec);
        runs.set(id, run);
        this.botRunNotes().delete(id);
        this._botRunPersist();
        this._botRunChanged(run);
        run.done = this._botRunSend(run);
        return run;
    },

    _botRunGone(run, gen) {
        return run.stopped || this.botRuns().get(run.id) !== run || (gen !== undefined && run.gen !== gen);
    },

    _botRunBody(run, maxRuns) {
        const body = Object.assign({}, run.extra);
        const limit = maxRuns || this.botMaxRuns();
        if (limit) body.maxRuns = Math.min(BOT_RUN_CEILING, Math.max(1, limit));
        else delete body.maxRuns;
        return body;
    },

    async _botRunSend(run, maxRuns) {
        run.state = 'running';
        run.cap = null;
        const gen = ++run.gen;
        const ctrl = typeof AbortController === 'function' ? new AbortController() : null;
        run.ctrl = ctrl;
        this._botRunChanged(run);
        let status, data;
        try {
            ({ status, data } = await this._botMoneyRequest('pm', this._botRunBody(run, maxRuns), { timeout: 180000, signal: ctrl ? ctrl.signal : undefined }));
        } catch (_) {
            if (this._botRunGone(run, gen)) return;
            return this._botRunClaim(run);
        }
        if (this._botRunGone(run, gen)) return;
        return this._botRunHandle(run, status, data || {});
    },

    async _botRunHandle(run, status, data) {
        if (this._botRunGone(run)) return;
        if (typeof this._markBotPMReceipts === 'function') this._markBotPMReceipts('read');
        if (data && data.runCap) {
            if (data.free) {
                this._botRunNote(run, { kind: 'capFree', text: String(data.error || '') });
                this._botRunEnd(run);
                this._botOpenBuy(false);
                return;
            }
            run.state = 'capped';
            run.cap = {
                error: String(data.error || ''),
                running: Math.max(0, Math.floor(Number(data.running) || 0)),
                limit: Math.max(1, Math.floor(Number(data.limit) || BOT_RUN_DEFAULT_LIMIT)),
                ceiling: Math.max(1, Math.floor(Number(data.ceiling) || BOT_RUN_CEILING))
            };
            this._botRunChanged(run);
            return;
        }
        if (status === 202 || (data && data.pending)) return this._botRunClaim(run);
        if (data && data.noCredits) {
            this._botRunEnd(run);
            this._botShowNoCredits(data);
            return;
        }
        if (data && data.priceUnavailable) {
            this._botRunEnd(run);
            if (typeof this._showBotPriceRetry === 'function') this._showBotPriceRetry(run.content, run.eventId);
            return;
        }
        if (status >= 400 || !data || data.error) {
            this._botRunNote(run, { kind: 'error', text: 'Nymbot: ' + ((data && data.error) || 'request failed') });
            this._botRunEnd(run);
            return;
        }
        const steer = run.steer;
        this._botRunEnd(run);
        if (steer && !data.stopped) this._botRunNote(run, { kind: 'steerLate', steerText: steer });
        await this._botRunDeliver(run, data);
    },

    _botOpenBuy(pro) {
        if (typeof this.botAnonReady === 'function' && this.botAnonReady() && typeof this.openBotAnonModal === 'function') this.openBotAnonModal();
        else if (typeof this.showBotCreditsModal === 'function') this.showBotCreditsModal(null, pro ? 'pro' : 'standard');
    },

    _botShowNoCredits(data) {
        const msg = data.error
            || (data.pro
                ? `You're out of Nymbot Pro credits (${this._creditFigure((data.balanceCredits != null ? data.balanceCredits : data.balance) || 0)} left). Type ?buy and switch to Pro, or ?model off for standard replies.`
                : `You're out of Nymbot credits (${this._creditFigure(this._replyBalance(data) || 0)} left). Zap Nymbot or type ?buy to purchase more.`);
        this.displaySystemMessage(msg);
        if (this._replyBalance(data) !== null) {
            if (data.pro) this._setBotProCreditDisplay(this._replyBalance(data));
            else this._setBotCreditDisplay(this._replyBalance(data));
        }
        this._botOpenBuy(!!data.pro);
    },

    async _botRunDeliver(run, data) {
        const replyTo = (typeof data.replyTo === 'string' && BOT_RUN_HEX64.test(data.replyTo)) ? data.replyTo.toLowerCase() : run.id;
        if (data.event) {
            this.sendDMToRelays(['EVENT', data.event]);
            await this.handleGiftWrapDM(data.event, { botReplyTo: replyTo });
        }
        if (data.selfEvent && BOT_RUN_HEX64.test(data.selfEvent.id || '')) {
            this.sendDMToRelays(['EVENT', data.selfEvent]);
        }
        const replyBalance = this._replyBalance(data);
        if (replyBalance !== null) {
            const replyCost = this._replyCost(data);
            if (data.pro) this._setBotProCreditDisplay(replyBalance);
            else this._setBotCreditDisplay(replyBalance);
            if (data.pro && replyCost) {
                const sel = this._getBotProModel();
                if (sel && replyCost > (sel.credits || 1)) {
                    this.displaySystemMessage(`Long reply used ${this._creditFigure(replyCost)} Pro credits. Pro balance: ${this._creditFigure(replyBalance)}.`);
                }
            } else if (!data.pro && replyCost > 1) {
                this.displaySystemMessage(`${data.taskType || 'Heavy'} reply used ${this._creditFigure(replyCost)} credits. Balance: ${this._creditFigure(replyBalance)}.`);
            }
            if (data.lowBalance) {
                this.displaySystemMessage(data.pro
                    ? `Nymbot Pro credits running low: ${this._creditFigure(replyBalance)} left. Type ?buy and switch to Pro to top up.`
                    : `Nymbot credits running low: ${this._creditFigure(replyBalance)} credit${replyBalance === 1 ? '' : 's'} left. Type ?buy to top up.`);
            }
        }
    },

    async _botRunClaim(run) {
        if (this._botRunGone(run)) return;
        const gen = run.gen;
        run.state = 'claiming';
        this._botRunChanged(run);
        let step = 0;
        for (;;) {
            if (this._botRunGone(run, gen)) return;
            if (this._botRunNow() - run.startedAt > BOT_RUN_MAX_AGE_MS) return this._botRunFail(run);
            await this._botRunSleep(this._botRunJitter(Math.min(BOT_RUN_CLAIM_CAP_MS, BOT_RUN_CLAIM_FIRST_MS * Math.pow(2, step))));
            step++;
            if (this._botRunGone(run, gen)) return;
            let status, data;
            try {
                ({ status, data } = await this._botMoneyRequest('pm-claim', { eventId: run.eventId }));
            } catch (_) { continue; }
            if (this._botRunGone(run, gen)) return;
            data = data || {};
            if (status === 200) return this._botRunHandle(run, status, data);
            if (status === 202 || data.pending) continue;
            if (status === 404 && data.unknown) return this._botRunFail(run);
            if (status === 429) continue;
            try {
                ({ status, data } = await this._botMoneyRequest('pm', this._botRunBody(run), { timeout: 180000 }));
            } catch (_) { continue; }
            if (this._botRunGone(run, gen)) return;
            data = data || {};
            if (status === 202 || data.pending) continue;
            return this._botRunHandle(run, status, data);
        }
    },

    _botRunFail(run) {
        this._botRunNote(run, { kind: 'failed', spec: { id: run.id, eventId: run.eventId, thread: run.thread, content: run.content, extra: run.extra } });
        this._botRunEnd(run);
    },

    _botRunNote(run, note) {
        this.botRunNotes().set(run.id, Object.assign({ at: this._botRunNow() }, note));
        this._botRunRender(run.id);
    },

    _botRunEnd(run) {
        const runs = this.botRuns();
        if (runs.get(run.id) === run) runs.delete(run.id);
        run.gen++;
        this._botRunPersist();
        this._botRunChanged(run);
        this._botRunPumpWaiting();
    },

    _botRunPumpWaiting() {
        for (const r of this.botRuns().values()) {
            if (r.state === 'waiting') {
                this._botRunSend(r);
                return;
            }
        }
    },

    _botRunLiveCount() {
        let n = 0;
        for (const r of this.botRuns().values()) if (r.state === 'running' || r.state === 'claiming') n++;
        return n;
    },

    _botRunChanged(run) {
        const live = this._botRunLiveCount() > 0;
        if (live !== !!this._botRunTypingOn) {
            this._botRunTypingOn = live;
            if (typeof this._setBotTyping === 'function') {
                try { this._setBotTyping(live); } catch (_) { }
            }
        }
        if (run) this._botRunRender(run.id);
        this._botRunsRenderIndicator();
        this._botRunsSchedulePoll();
    },

    async botRunStop(id) {
        const key = String(id || '').toLowerCase();
        const run = this.botRuns().get(key);
        let wasSent = !run;
        if (run) {
            wasSent = run.state === 'running' || run.state === 'claiming';
            run.stopped = true;
            try { if (run.ctrl) run.ctrl.abort(); } catch (_) { }
            this._botRunNote(run, { kind: 'stopped' });
            this._botRunEnd(run);
        }
        if (wasSent) {
            try { await this._botMoneyRequest('pm-cancel', { replyTo: key }); } catch (_) { }
            if (!run && Array.isArray(this._botRemoteRuns)) {
                this._botRemoteRuns = this._botRemoteRuns.filter((r) => r.replyTo !== key);
                this._botRunsRenderIndicator();
            }
        }
    },

    botRunStopAll() {
        return Promise.all(this.botRunsList().map((r) => this.botRunStop(r.id)));
    },

    async botRunSteerSend(id, text) {
        const t = String(text || '').trim();
        if (!t) return 'empty';
        if (t.length > BOT_RUN_STEER_CHARS) return 'tooLong';
        const key = String(id || '').toLowerCase();
        let status, data;
        try {
            ({ status, data } = await this._botMoneyRequest('pm-steer', { replyTo: key, text: t }));
        } catch (_) { return 'retry'; }
        if (status === 200 && data && data.ok) {
            const run = this.botRuns().get(key);
            if (run) run.steer = t;
            return 'ok';
        }
        if (status === 413) return 'tooLong';
        if (status === 429 || !status) return 'retry';
        return 'finished';
    },

    async botRunOpenSteer(id) {
        if (typeof window.showAppPrompt !== 'function') return;
        const key = String(id || '').toLowerCase();
        const text = await window.showAppPrompt('Nymbot passes this to the running request at its next step. It does not change what the request can spend.', {
            title: 'Add instructions',
            placeholder: 'For example: also cover the pricing',
            okLabel: 'Send to this request',
            cancelLabel: 'Cancel',
            multiline: true,
            maxLength: BOT_RUN_STEER_CHARS
        });
        if (text == null || !String(text).trim()) return;
        const out = await this.botRunSteerSend(key, text);
        if (out === 'ok') this.displaySystemMessage(this._botRunText('Passed on. It applies at the next step.'));
        else if (out === 'tooLong') this.displaySystemMessage(this._botRunText('That is too long. Instructions can be up to 2,000 characters.'));
        else if (out === 'retry') this.displaySystemMessage(this._botRunText('Could not pass that on. Try again in a moment.'));
        else if (out === 'finished') {
            const run = this.botRuns().get(key);
            const remote = (this._botRemoteRuns || []).find((r) => r.replyTo === key);
            await this._botRunOfferAsMessage(String(text).trim(), run ? run.thread : (remote ? remote.thread : ''));
        }
    },

    async _botRunOfferAsMessage(text, thread) {
        if (typeof window.showAppConfirm !== 'function') return;
        const ok = await window.showAppConfirm('Send your instructions as a new message instead?', {
            title: 'That request has finished',
            okLabel: 'Send as a message',
            cancelLabel: 'Cancel'
        });
        if (ok) this._botRunSendAsMessage(text, thread);
    },

    _botRunSendAsMessage(text, thread) {
        if (!this.verifiedBot || !text) return;
        this.sendPM(text, this.verifiedBot.pubkey, { threadRoot: thread || null });
    },

    botRunSendSteerNote(id) {
        const key = String(id || '').toLowerCase();
        const note = this.botRunNotes().get(key);
        if (!note || note.kind !== 'steerLate') return;
        const own = this._botOwnMessageById(key);
        this.botRunNotes().delete(key);
        this._botRunRender(key);
        this._botRunSendAsMessage(note.steerText, own && own.threadRoot ? own.threadRoot : '');
    },

    _botOwnMessageById(id) {
        const bot = this.verifiedBot;
        if (!bot || !(this.pmMessages instanceof Map)) return null;
        const list = this.pmMessages.get(this.getPMConversationKey(bot.pubkey)) || [];
        return list.find((m) => m && m.isOwn && m.nymMessageId === id) || null;
    },

    botRunCapOptions(id) {
        const run = this.botRuns().get(String(id || '').toLowerCase());
        if (!run || run.state !== 'capped' || !run.cap) return [];
        return run.cap.limit >= run.cap.ceiling ? ['wait'] : ['start', 'always', 'wait'];
    },

    _botRunCapAlwaysN(cap) {
        return Math.min(cap.running + 1, cap.ceiling);
    },

    botRunCapStart(id) {
        const run = this.botRuns().get(String(id || '').toLowerCase());
        if (!run || run.state !== 'capped' || !run.cap) return;
        this._botRunSend(run, run.cap.running + 1);
    },

    botRunCapAlways(id) {
        const run = this.botRuns().get(String(id || '').toLowerCase());
        if (!run || run.state !== 'capped' || !run.cap) return;
        this.setBotMaxRuns(this._botRunCapAlwaysN(run.cap));
        this._botRunSend(run);
    },

    botRunCapWait(id) {
        const run = this.botRuns().get(String(id || '').toLowerCase());
        if (!run || run.state !== 'capped') return;
        run.state = 'waiting';
        this._botRunChanged(run);
    },

    botRunRetry(id) {
        const key = String(id || '').toLowerCase();
        const note = this.botRunNotes().get(key);
        if (!note || note.kind !== 'failed' || !note.spec) return;
        this.botRunNotes().delete(key);
        this._botRunStart(Object.assign({}, note.spec, { startedAt: this._botRunNow() }));
    },

    _botRunsResume() {
        const runs = this.botRuns();
        const now = this._botRunNow();
        for (const e of this._botRunLoadInflight()) {
            if (!e || typeof e.id !== 'string' || typeof e.eventId !== 'string') continue;
            if (runs.has(e.id.toLowerCase())) continue;
            if (now - (Number(e.startedAt) || 0) > BOT_RUN_MAX_AGE_MS) continue;
            const run = this._botRunMake(e);
            runs.set(run.id, run);
            this._botRunClaim(run);
        }
        this._botRunPersist();
    },

    async _botRunsPoll() {
        if (!this.pubkey) return;
        let status, data;
        try {
            ({ status, data } = await this._botMoneyRequest('pm-runs', {}));
        } catch (_) { return; }
        if (status !== 200 || !data || !Array.isArray(data.runs)) {
            this._botRemoteRuns = [];
            this._botRunsRenderIndicator();
            return;
        }
        const rows = data.runs.filter((r) => r && typeof r.replyTo === 'string' && r.app !== 'nymbot');
        this._botRemoteRuns = rows;
        const runs = this.botRuns();
        for (const r of rows) {
            const run = runs.get(r.replyTo.toLowerCase());
            if (!run) continue;
            run.progress = typeof r.progress === 'string' ? r.progress : '';
            if (/applied your update/i.test(run.progress)) run.steer = null;
            this._botRunRender(run.id);
        }
        const waiting = [...runs.values()].find((r) => r.state === 'waiting');
        if (waiting && waiting.cap && rows.length < waiting.cap.limit) this._botRunSend(waiting);
        this._botRunsRenderIndicator();
    },

    botRunsList() {
        const out = [];
        const seen = new Set();
        for (const run of this.botRuns().values()) {
            seen.add(run.id);
            out.push({ id: run.id, label: run.label, progress: run.progress, state: run.state, startedAt: run.startedAt, thread: run.thread, remote: false });
        }
        for (const r of this._botRemoteRuns || []) {
            const id = r.replyTo.toLowerCase();
            if (seen.has(id)) continue;
            seen.add(id);
            out.push({ id, label: r.label || '', progress: r.progress || '', state: 'running', startedAt: Number(r.startedAt) || 0, thread: r.thread || '', remote: true });
        }
        return out.sort((a, b) => b.startedAt - a.startedAt);
    },

    _botChatOpen() {
        return !!(this.inPMMode && this.verifiedBot && this.currentPM === this.verifiedBot.pubkey && !this.currentGroup);
    },

    _botRunsPollWanted() {
        if (!this.pubkey) return false;
        if (this._botRunsSheetOpen) return true;
        if (!this._botChatOpen()) return false;
        return this.botRuns().size > 0 || (this._botRemoteRuns || []).length > 0;
    },

    _botRunsSchedulePoll(immediate) {
        if (this._botRunsPollTimer || !this._botRunsPollWanted()) return;
        this._botRunsPollTimer = setTimeout(async () => {
            this._botRunsPollTimer = null;
            if (!this._botRunsPollWanted()) return;
            await this._botRunsPoll();
            this._botRunsSchedulePoll();
        }, immediate ? 0 : BOT_RUN_POLL_MS);
    },

    botRunsOnChatOpen() {
        if (!this._botRunsResumed) {
            this._botRunsResumed = true;
            this._botRunsResume();
        }
        this._botRunsPoll().then(() => this._botRunsSchedulePoll()).catch(() => { });
        this._botRunsRenderIndicator();
        setTimeout(() => this._botRunRenderAll(), 0);
        setTimeout(() => this._botRunRenderAll(), 400);
    },

    _botRunRenderAll() {
        if (typeof document === 'undefined' || !document.querySelectorAll) return;
        const ids = new Set([...this.botRuns().keys(), ...this.botRunNotes().keys()]);
        document.querySelectorAll('.bot-run-status').forEach((box) => {
            const el = box.closest('.message');
            const id = el && el.dataset ? String(el.dataset.messageId || '').toLowerCase() : '';
            if (!ids.has(id)) box.remove();
        });
        for (const id of ids) this._botRunRender(id);
    },

    _botRunAge(startedAt) {
        const min = Math.floor(Math.max(0, this._botRunNow() - (Number(startedAt) || 0)) / 60000);
        return min < 1 ? 'Started just now' : `Started ${min} min ago`;
    },

    _botRunEsc(s) {
        return typeof this.escapeHtml === 'function' ? this.escapeHtml(String(s == null ? '' : s))
            : String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
    },

    _botRunStatusHtml(id) {
        const T = (s) => this._botRunEsc(this._botRunText(s));
        const run = this.botRuns().get(id);
        const note = this.botRunNotes().get(id);
        const btn = (action, label, extra) => `<button type="button" class="bot-run-btn${extra ? ' ' + extra : ''}" data-action="${action}" data-run-id="${id}">${label}</button>`;
        const parts = [];
        if (run) {
            if (run.state === 'capped' && run.cap) {
                const opts = this.botRunCapOptions(id);
                const buttons = [];
                if (opts.includes('start')) buttons.push(btn('botRunCapStart', T('Start anyway')));
                if (opts.includes('always')) buttons.push(btn('botRunCapAlways', T(`Always allow up to ${this._botRunCapAlwaysN(run.cap)}`)));
                if (opts.includes('wait')) buttons.push(btn('botRunCapWait', T('Wait')));
                parts.push(`<div class="bot-run-line">${this._botRunEsc(run.cap.error)}</div><div class="bot-run-actions">${buttons.join('')}</div>`);
            } else {
                const line = run.state === 'waiting' ? 'Waiting for a free slot'
                    : run.state === 'claiming' ? 'Still working on that one…' : 'Nymbot is thinking';
                const progress = run.state === 'running' && run.progress ? `<span class="bot-run-progress">${this._botRunEsc(run.progress)}</span>` : '';
                const buttons = [];
                if (run.state !== 'waiting') buttons.push(btn('botRunSteer', T('Add instructions')));
                buttons.push(btn('botRunStop', T('Stop'), 'danger'));
                parts.push(`<div class="bot-run-line"><span class="bot-run-dot" aria-hidden="true"></span>${T(line)}${progress}</div><div class="bot-run-actions">${buttons.join('')}</div>`);
            }
        } else if (note) {
            if (note.kind === 'stopped') parts.push(`<div class="bot-run-note">${T('Stopped.')}</div>`);
            else if (note.kind === 'failed') parts.push(`<div class="bot-run-note error">${T('Nymbot could not finish that one. Try again; it will not be charged twice.')}</div><div class="bot-run-actions">${btn('botRunRetry', T('Try again'))}</div>`);
            else if (note.kind === 'steerLate') parts.push(`<div class="bot-run-note"><strong>${T('That request has finished')}</strong> ${T('Send your instructions as a new message instead?')}</div><div class="bot-run-actions">${btn('botRunSendSteer', T('Send as a message'))}</div>`);
            else parts.push(`<div class="bot-run-note${note.kind === 'error' ? ' error' : ''}">${this._botRunEsc(note.text || '')}</div>`);
        }
        return parts.join('');
    },

    _botRunDecorate(el, message) {
        if (!el || !message || !message.isOwn || !this.verifiedBot) return;
        if (message.conversationPubkey && message.conversationPubkey !== this.verifiedBot.pubkey) return;
        const id = message.nymMessageId ? String(message.nymMessageId).toLowerCase() : '';
        if (!id || (!this.botRuns().has(id) && !this.botRunNotes().has(id))) return;
        this._botRunPaint(el, id);
    },

    _botRunPaint(el, id) {
        let box = el.querySelector(':scope > .bot-run-status');
        const html = this._botRunStatusHtml(id);
        if (!html) { if (box) box.remove(); return; }
        if (!box) {
            box = document.createElement('div');
            box.className = 'bot-run-status';
            box.setAttribute('role', 'status');
            el.appendChild(box);
        }
        if (box.innerHTML !== html) box.innerHTML = html;
    },

    _botRunRender(id) {
        if (typeof document === 'undefined' || !document.querySelectorAll) return;
        document.querySelectorAll(`.message[data-message-id="${id}"]`).forEach((el) => {
            if (el.dataset.pubkey && this.pubkey && el.dataset.pubkey !== this.pubkey) return;
            this._botRunPaint(el, id);
        });
        if (this._botRunsSheetOpen) this._botRunsRenderSheet();
    },

    _botRunsRenderIndicator() {
        if (typeof document === 'undefined' || !document.getElementById) return;
        const n = this.botRunsList().length;
        const count = document.getElementById('botRunsCount');
        if (count) {
            count.textContent = String(n);
            count.classList.toggle('nm-hidden', n === 0);
        }
        const stopAll = document.getElementById('botStopAllBtn');
        if (stopAll) stopAll.classList.toggle('nm-hidden', n === 0);
        if (this._botRunsSheetOpen) this._botRunsRenderSheet();
    },

    openBotRunsSheet() {
        const modal = typeof document !== 'undefined' ? document.getElementById('botRunsModal') : null;
        if (!modal) return;
        this._botRunsSheetOpen = true;
        this._botRunsSyncLimitSelect();
        this._botRunsRenderSheet();
        modal.classList.add('active');
        if (!modal._botRunsWatch && typeof MutationObserver === 'function') {
            modal._botRunsWatch = new MutationObserver(() => {
                if (!modal.classList.contains('active')) {
                    this._botRunsSheetOpen = false;
                    this._botRunsRenderIndicator();
                }
            });
            modal._botRunsWatch.observe(modal, { attributes: true, attributeFilter: ['class'] });
        }
        this._botRunsPoll().then(() => this._botRunsSchedulePoll()).catch(() => { });
    },

    _botRunsRenderSheet() {
        const list = typeof document !== 'undefined' ? document.getElementById('botRunsList') : null;
        if (!list) return;
        const rows = this.botRunsList();
        if (!rows.length) {
            list.innerHTML = '<div class="bot-runs-empty">Nothing is running right now.</div>';
            return;
        }
        const esc = (s) => this._botRunEsc(s);
        list.innerHTML = rows.map((r) => {
            const state = r.state === 'waiting' ? 'Waiting for a free slot'
                : r.state === 'claiming' ? 'Still working on that one…'
                    : r.state === 'capped' ? 'Waiting for a free slot' : '';
            const meta = [r.remote ? 'On another device' : '', this._botRunAge(r.startedAt)].filter(Boolean).join(' · ');
            const steer = r.state === 'running' || r.state === 'claiming'
                ? `<button type="button" class="bot-run-btn" data-action="botRunSteer" data-run-id="${r.id}">Add instructions</button>` : '';
            return `<div class="bot-runs-row">
                <div class="bot-runs-row-main">
                    <div class="bot-runs-row-label" data-no-i18n>${esc(r.label)}</div>
                    ${r.progress ? `<div class="bot-runs-row-progress">${esc(r.progress)}</div>` : ''}
                    ${state ? `<div class="bot-runs-row-progress">${state}</div>` : ''}
                    <div class="bot-runs-row-meta">${meta}</div>
                </div>
                <div class="bot-run-actions">
                    <button type="button" class="bot-run-btn" data-action="botRunOpen" data-run-id="${r.id}">Open</button>
                    ${steer}
                    <button type="button" class="bot-run-btn danger" data-action="botRunStop" data-run-id="${r.id}">Stop</button>
                </div>
            </div>`;
        }).join('');
        if (typeof this.i18nApplyNow === 'function') this.i18nApplyNow(list);
    },

    botRunOpen(id) {
        const key = String(id || '').toLowerCase();
        if (typeof window.closeModal === 'function') window.closeModal('botRunsModal');
        if (!this.verifiedBot) return;
        if (!this._botChatOpen() && typeof this.openPM === 'function') {
            this.openPM(this.parseNymFromDisplay(this.getNymFromPubkey(this.verifiedBot.pubkey)), this.verifiedBot.pubkey);
        }
        setTimeout(() => {
            const el = document.querySelector(`.message[data-message-id="${key}"]`);
            if (el && typeof el.scrollIntoView === 'function') el.scrollIntoView({ block: 'center', behavior: 'smooth' });
        }, 150);
    }
});
