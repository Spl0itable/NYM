(function () {
    const NM = () => window.NymMediaNotes;
    const LOCK_GLYPH = '\u2191';
    const TRASH_SVG = '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><polyline points="3 6 5 6 21 6"></polyline><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"></path><path d="M10 11v6M14 11v6"></path></svg>';
    const SEND_SVG = '<svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor" aria-hidden="true"><path d="M3.4 20.4 21 12 3.4 3.6 3.4 10l12.6 2-12.6 2z"></path></svg>';
    const ONCE_SVG = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="12" r="9" stroke-dasharray="4 3"></circle><path d="M10.5 9.5 12 8.5v7"></path></svg>';
    const HOLD_MS = 250;
    const CANCEL_DX = 80;
    const LOCK_DY = 60;
    const SAMPLE_MS = 50;

    Object.assign(NYM.prototype, {

        _mt(text, vars) {
            let s = typeof this.uiText === 'function' ? this.uiText(text) : text;
            if (vars) for (const k of Object.keys(vars)) s = s.split('{' + k + '}').join(String(vars[k]));
            return s;
        },

        _mediaSurface() {
            if (!this.inPMMode) return 'channel';
            return this.currentGroup ? 'group' : 'dm';
        },

        _mediaRoute() {
            if (!this.inPMMode) {
                const ch = this.currentGeohash || this.currentChannel;
                if (typeof this.meshShouldCarry === 'function' && this.meshShouldCarry(ch)) return 'mesh';
            }
            return this.connected ? 'online' : 'offline';
        },

        _mediaCaps() {
            const md = navigator.mediaDevices;
            const canMedia = !!(md && typeof md.getUserMedia === 'function' && typeof window.MediaRecorder === 'function');
            return { canRecordAudio: canMedia, canRecordVideo: canMedia };
        },

        mediaFeatureState(feature) {
            return NM().featureState(feature, Object.assign({
                surface: this._mediaSurface(),
                route: this._mediaRoute(),
                meshDm: false,
            }, this._mediaCaps()));
        },

        _mediaTarget() {
            return {
                group: this.inPMMode ? (this.currentGroup || null) : null,
                pm: this.inPMMode && !this.currentGroup ? (this.currentPM || null) : null,
                geohash: this.inPMMode ? null : (this.currentGeohash || null),
                threadRoot: typeof this._threadRootForSend === 'function' ? this._threadRootForSend() : null,
            };
        },

        async _sendMediaNoteContent(content, target) {
            const t = target || this._mediaTarget();
            if (t.group) return this.sendGroupMessage(content, t.group, { threadRoot: t.threadRoot });
            if (t.pm) return this.sendPM(content, t.pm, { threadRoot: t.threadRoot });
            if (t.geohash) return this.publishMessage(content, t.geohash, t.geohash, null, t.threadRoot);
            return false;
        },

        _mediaNotice(text) {
            if (typeof this.displaySystemMessage === 'function') this.displaySystemMessage(text);
        },

        setupMediaNotesUI() {
            if (this._mediaUiReady) return;
            this._mediaUiReady = true;
            this._onceStore = NM().createOnceStore(window.localStorage);
            this._transcripts = NM().createTranscriptStore(window.localStorage);
            if (!this._meshLocalMedia) this._meshLocalMedia = new Map();
            this._setupVoiceButton();
            const vbtn = document.getElementById('videoNoteBtn');
            if (vbtn && !vbtn._nymBound) {
                vbtn._nymBound = true;
                vbtn.addEventListener('click', (e) => { e.preventDefault(); this.openVideoNoteRecorder(); });
            }
            this._refreshMediaButtons();
            setInterval(() => this._refreshMediaButtons(), 1500);
            this._observeMediaNotes();
            this._registerMediaActions();
            this._setupVoiceScrub();
        },

        _setupVoiceScrub() {
            document.addEventListener('pointerdown', (e) => {
                const wave = e.target && e.target.closest ? e.target.closest('.nym-voice-wave') : null;
                if (!wave) return;
                this._scrub = { el: wave.closest('.nym-voice'), id: e.pointerId };
                try { wave.setPointerCapture(e.pointerId); } catch (_) { }
            }, true);
            document.addEventListener('pointermove', (e) => {
                const s = this._scrub;
                if (!s || s.id !== e.pointerId || !(e.buttons & 1)) return;
                if (this._voiceEl === s.el) this._voiceSeekFromEvent(s.el, e);
            }, true);
            const end = (e) => { if (this._scrub && this._scrub.id === e.pointerId) this._scrub = null; };
            document.addEventListener('pointerup', end, true);
            document.addEventListener('pointercancel', end, true);
            document.addEventListener('keydown', (e) => {
                const wave = e.target && e.target.closest ? e.target.closest('.nym-voice-wave') : null;
                if (!wave || (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight')) return;
                e.preventDefault();
                const el = wave.closest('.nym-voice');
                const a = this._voiceEl === el ? this._voiceAudio : null;
                const d = a && isFinite(a.duration) && a.duration > 0 ? a.duration : (parseFloat(el.dataset.dur) || 0);
                if (!d) return;
                const cur = a ? a.currentTime : 0;
                const next = Math.max(0, Math.min(d, cur + (e.key === 'ArrowRight' ? 5 : -5)));
                this._voiceSeek(el, next / d);
            }, true);
        },

        _refreshMediaButtons() {
            const pairs = [['voiceRecordBtn', 'voice', 'Voice message'], ['videoNoteBtn', 'round', 'Video note']];
            for (const [id, feature, label] of pairs) {
                const btn = document.getElementById(id);
                if (!btn) continue;
                const st = this.mediaFeatureState(feature);
                btn.classList.toggle('media-off', st.state === 'off');
                btn.classList.toggle('media-warn', st.state === 'warn');
                const title = st.reason ? this._mt(label) + ' — ' + this._mt(st.reason) : this._mt(label);
                if (btn.getAttribute('title') !== title) btn.setAttribute('title', title);
                btn.setAttribute('aria-disabled', st.state === 'off' ? 'true' : 'false');
            }
            if (this._composerAttachments && this._composerAttachments.length) this._renderMediaOptions();
        },

        _registerMediaActions() {
            const A = window.NYM_ACTIONS || (window.NYM_ACTIONS = {});
            const self = this;
            Object.assign(A, {
                nymVoiceToggle(e, t) { e.stopPropagation(); self._voiceToggle(t.closest('.nym-voice')); },
                nymVoiceSeek(e, t) { e.stopPropagation(); self._voiceSeekFromEvent(t.closest('.nym-voice'), e); },
                nymVoiceSpeed(e) { e.stopPropagation(); self._cycleVoiceSpeed(); },
                nymVoiceTranscribe(e, t) { e.stopPropagation(); self._transcribeVoice(t.closest('.nym-voice')); },
                nymModelCancel(e, t) { e.stopPropagation(); const el = t.closest('.nym-voice'); if (el && el._modelView) el._modelView.cancel(); },
                nymModelRetry(e, t) { e.stopPropagation(); self._transcribeVoice(t.closest('.nym-voice'), { consented: true }); },
                nymSpeechTranscriptsClear(e) { e.stopPropagation(); self.clearSavedTranscripts(); },
                nymRoundToggle(e, t) { e.stopPropagation(); self._roundToggle(t.closest('.nym-round')); },
                nymOnceOpen(e, t) { e.stopPropagation(); self._openOnce(t.closest('.nym-once')); },
                nymOnceClose(e) { e.stopPropagation(); self._closeOnceViewer(); },
                nymMediaHd(e) { e.stopPropagation(); self._toggleComposerHd(); },
                nymMediaOnce(e) { e.stopPropagation(); self._toggleComposerOnce(); },
                nymRetryNote(e) { e.stopPropagation(); self._retryFailedNote(); },
                nymVideoNoteRecord(e) { e.stopPropagation(); self._videoNoteRecordToggle(); },
                nymVideoNoteSend(e) { e.stopPropagation(); self._videoNoteSend(); },
                nymVideoNoteCancel(e) { e.stopPropagation(); self.closeVideoNoteRecorder(); },
                nymVideoNoteOnce(e) { e.stopPropagation(); self._videoNoteToggleOnce(); },
                nymVoiceRecCancel(e) { e.stopPropagation(); self._stopVoiceRecording(false); },
                nymVoiceRecSend(e) { e.stopPropagation(); self._stopVoiceRecording(true); },
                nymVoiceRecOnce(e) { e.stopPropagation(); self._voiceToggleOnce(); },
            });
        },

        _observeMediaNotes() {
            const run = (root) => {
                if (!root || root.nodeType !== 1) return;
                const list = root.matches && root.matches('[data-nym-note]') ? [root] : [];
                root.querySelectorAll && root.querySelectorAll('[data-nym-note]:not([data-hyd])').forEach((el) => list.push(el));
                for (const el of list) this._hydrateMediaNote(el);
            };
            run(document.body);
            const obs = new MutationObserver((muts) => {
                for (const m of muts) for (const n of m.addedNodes) run(n);
            });
            obs.observe(document.body, { childList: true, subtree: true });
            this._mediaObserver = obs;
        },

        _localMediaFor(el) {
            const id = el && el.dataset ? el.dataset.localId : '';
            if (!id) return null;
            return (this._meshLocalMedia && this._meshLocalMedia.get(id)) || null;
        },

        _hydrateMediaNote(el) {
            if (!el || el.dataset.hyd) return;
            el.dataset.hyd = '1';
            const kind = el.dataset.nymNote;
            const local = el.dataset.localId ? this._localMediaFor(el) : null;
            if (el.dataset.localId && !local) {
                el.classList.add('nym-note-gone');
                const gone = document.createElement('span');
                gone.className = 'nym-note-gone-text';
                gone.textContent = this._mt('This mesh file is no longer on this device.');
                el.appendChild(gone);
            }
            if (kind === 'voice') {
                const speed = el.querySelector('.nym-voice-speed');
                if (speed) speed.textContent = NM().speedLabel(this._voiceSpeed());
                const play = el.querySelector('.nym-voice-play');
                if (play) play.setAttribute('aria-label', this._mt('Play voice message'));
                const tx = el.querySelector('.nym-voice-tx');
                if (tx) tx.textContent = this._mt('Transcribe');
                const cached = this._transcripts && this._transcripts.get(this._voiceKey(el));
                if (cached != null) this._showTranscript(el, cached);
            } else if (kind === 'round') {
                const hit = el.querySelector('.nym-round-hit');
                if (hit) hit.setAttribute('aria-label', this._mt('Play video note with sound'));
                if (local) {
                    const v = el.querySelector('video');
                    if (v) v.src = local.url;
                }
            } else if (kind === 'photo' || kind === 'video') {
                const media = el.querySelector('.nym-local-media');
                if (media && local) {
                    media.src = local.url;
                    if (kind === 'photo') media.dataset.action = 'expandImageFromData';
                }
            } else if (kind === 'once') {
                this._renderOnceState(el);
            }
        },

        _voiceKey(el) {
            return el.dataset.raw || ('local:' + (el.dataset.localId || ''));
        },

        _voiceSpeed() {
            let raw = null;
            try { raw = localStorage.getItem(NM().SPEED_KEY); } catch (_) { }
            return NM().parseSpeed(raw);
        },

        _cycleVoiceSpeed() {
            const next = NM().nextSpeed(this._voiceSpeed());
            try { localStorage.setItem(NM().SPEED_KEY, String(next)); } catch (_) { }
            document.querySelectorAll('.nym-voice-speed').forEach((b) => { b.textContent = NM().speedLabel(next); });
            if (this._voiceAudio) this._voiceAudio.playbackRate = next;
            return next;
        },

        _voiceSourceUrl(el) {
            if (el.dataset.localId) {
                const local = this._localMediaFor(el);
                return local ? local.url : '';
            }
            return el.dataset.src || '';
        },

        _voiceToggle(el) {
            if (!el) return;
            if (this._voiceEl === el && this._voiceAudio && !el.classList.contains('nym-voice-failed')) {
                if (this._voiceAudio.paused) this._voiceAudio.play().catch(() => this._voiceFailed(el));
                else this._voiceAudio.pause();
                return;
            }
            this._voiceStop();
            el.classList.remove('nym-voice-failed');
            el._mirrorIdx = 0;
            const src = this._voiceSourceUrl(el);
            if (!src) {
                this._voiceFailed(el);
                return;
            }
            const audio = new Audio();
            audio.preload = 'auto';
            audio.src = src;
            audio.playbackRate = this._voiceSpeed();
            this._voiceAudio = audio;
            this._voiceEl = el;
            const dur = () => (isFinite(audio.duration) && audio.duration > 0) ? audio.duration : (parseFloat(el.dataset.dur) || 0);
            const paint = () => this._paintVoiceProgress(el, audio.currentTime, dur());
            audio.addEventListener('timeupdate', paint);
            audio.addEventListener('play', () => el.classList.add('playing'));
            audio.addEventListener('pause', () => el.classList.remove('playing'));
            audio.addEventListener('ended', () => {
                el.classList.remove('playing');
                this._paintVoiceProgress(el, 0, dur(), true);
            });
            audio.addEventListener('error', () => this._voiceFallback(el, audio));
            if (el._pendingSeek != null) {
                const frac = el._pendingSeek;
                el._pendingSeek = null;
                audio.addEventListener('loadedmetadata', () => { audio.currentTime = frac * dur(); }, { once: true });
            }
            audio.play().catch(() => { });
        },

        _voiceFallback(el, audio) {
            const raw = el.dataset.raw;
            const mirrors = raw && this.mediaFallbacks ? (this.mediaFallbacks.get(raw) || []) : [];
            const tried = el._mirrorIdx || 0;
            if (tried < mirrors.length && typeof this.getProxiedMediaUrl === 'function') {
                el._mirrorIdx = tried + 1;
                audio.src = this.getProxiedMediaUrl(mirrors[tried]);
                audio.play().catch(() => { });
                return;
            }
            this._voiceFailed(el);
        },

        _voiceFailed(el) {
            el.classList.remove('playing');
            el.classList.add('nym-voice-failed');
            const time = el.querySelector('.nym-voice-time');
            const mime = el.dataset.mime || '';
            const unsupported = /webm|ogg/.test(mime) && !this._canPlayMime(mime);
            if (time) time.textContent = unsupported ? this._mt("Can't play this format here") : this._mt("Couldn't load");
        },

        _canPlayMime(mime) {
            try { return !!document.createElement('audio').canPlayType(mime); } catch (_) { return false; }
        },

        _voiceStop() {
            if (this._voiceAudio) {
                try { this._voiceAudio.pause(); } catch (_) { }
                this._voiceAudio.removeAttribute('src');
            }
            if (this._voiceEl) {
                this._voiceEl.classList.remove('playing');
                this._paintVoiceProgress(this._voiceEl, 0, parseFloat(this._voiceEl.dataset.dur) || 0, true);
            }
            this._voiceAudio = null;
            this._voiceEl = null;
        },

        _paintVoiceProgress(el, pos, dur, reset) {
            const bars = el.querySelectorAll('.nym-voice-bar');
            const frac = dur > 0 ? Math.max(0, Math.min(1, pos / dur)) : 0;
            const played = reset ? 0 : Math.round(frac * bars.length);
            bars.forEach((b, i) => b.classList.toggle('played', i < played));
            const wave = el.querySelector('.nym-voice-wave');
            if (wave) wave.setAttribute('aria-valuenow', String(Math.round(frac * 100)));
            const time = el.querySelector('.nym-voice-time');
            if (time && !el.classList.contains('nym-voice-failed')) {
                time.textContent = NM().formatClock(reset ? dur : pos);
            }
        },

        _voiceSeekFromEvent(el, e) {
            if (!el) return;
            const wave = el.querySelector('.nym-voice-wave');
            if (!wave) return;
            const r = wave.getBoundingClientRect();
            const x = (e && typeof e.clientX === 'number') ? e.clientX : r.left;
            const frac = r.width > 0 ? Math.max(0, Math.min(1, (x - r.left) / r.width)) : 0;
            this._voiceSeek(el, frac);
        },

        _voiceSeek(el, frac) {
            if (this._voiceEl === el && this._voiceAudio) {
                const a = this._voiceAudio;
                const d = isFinite(a.duration) && a.duration > 0 ? a.duration : (parseFloat(el.dataset.dur) || 0);
                if (d > 0) a.currentTime = frac * d;
                this._paintVoiceProgress(el, frac * d, d);
                return;
            }
            el._pendingSeek = frac;
            this._voiceToggle(el);
        },

        _roundToggle(el) {
            if (!el) return;
            const v = el.querySelector('video');
            if (!v) return;
            if (el.classList.contains('sound')) {
                el.classList.remove('sound');
                v.muted = true;
                v.loop = true;
                v.play().catch(() => { });
                return;
            }
            document.querySelectorAll('.nym-round.sound').forEach((o) => {
                if (o === el) return;
                o.classList.remove('sound');
                const ov = o.querySelector('video');
                if (ov) { ov.muted = true; ov.loop = true; }
            });
            this._voiceStop();
            el.classList.add('sound');
            v.loop = false;
            v.muted = false;
            v.currentTime = 0;
            const onTime = () => {
                const p = v.duration > 0 ? v.currentTime / v.duration : 0;
                el.style.setProperty('--p', String(Math.max(0, Math.min(1, p))));
            };
            v.addEventListener('timeupdate', onTime);
            v.addEventListener('ended', () => {
                v.removeEventListener('timeupdate', onTime);
                el.classList.remove('sound');
                el.style.setProperty('--p', '0');
                v.muted = true;
                v.loop = true;
                v.play().catch(() => { });
            }, { once: true });
            v.play().catch(() => {
                el.classList.remove('sound');
                v.muted = true;
            });
        },

        async _transcribeCapability(lang) {
            const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
            if (!SR) return { ok: false, reason: this._mt('This browser has no speech recognition, so transcription is unavailable.') };
            if (typeof SR.available !== 'function' || !('processLocally' in SR.prototype)) {
                return { ok: false, reason: this._mt("This browser only transcribes by sending audio to a server, so Nymchat doesn't use it.") };
            }
            let status = 'unavailable';
            try { status = await SR.available({ langs: [lang], processLocally: true }); } catch (_) { }
            if (status === 'available') return { ok: true, SR, status };
            if (status === 'downloadable' || status === 'downloading') return { ok: true, SR, needsInstall: true, status };
            return { ok: false, reason: this._mt('No on-device speech model is available for {lang}.', { lang }) };
        },

        _transcribeLang() {
            return (navigator.language || 'en-US');
        },

        async _voiceBytes(el) {
            if (el.dataset.localId) {
                const local = this._localMediaFor(el);
                if (!local) throw new Error('gone');
                return await local.blob.arrayBuffer();
            }
            const resp = await fetch(el.dataset.src);
            if (!resp.ok) throw new Error('HTTP ' + resp.status);
            return await resp.arrayBuffer();
        },

        async _transcribeVoice(el, opts) {
            if (!el || el.dataset.transcribing || el._modelView) return;
            const key = this._voiceKey(el);
            const cached = this._transcripts.get(key);
            if (cached != null) { this._showTranscript(el, cached); return; }
            const lang = this._transcribeLang();
            const cap = await this._transcribeCapability(lang);
            if (!cap.ok) {
                this._showTranscript(el, null, cap.reason);
                return;
            }
            if (cap.needsInstall) {
                const running = this._speechInstalls && this._speechInstalls.get(lang);
                if (!running && !(opts && opts.consented) && cap.status !== 'downloading') {
                    const ok = await window.showAppConfirm(
                        this._mt('Transcription runs on this device. A speech model for {lang} needs to be downloaded once. The audio never leaves this device.', { lang }),
                        { okLabel: this._mt('Download model') });
                    if (!ok) return;
                }
                if (!(await this._installSpeechModel(el, cap.SR, lang))) return;
            }
            el.dataset.transcribing = '1';
            this._showTranscript(el, null, this._mt('Transcribing on this device…'));
            try {
                const bytes = await this._voiceBytes(el);
                const text = await this._runLocalRecognition(cap.SR, bytes, lang);
                this._transcripts.set(key, text);
                this._showTranscript(el, text);
            } catch (err) {
                this._showTranscript(el, null, this._mt("Couldn't transcribe this message."));
            } finally {
                delete el.dataset.transcribing;
            }
        },

        _modelLimits() {
            return Object.assign({}, NM().MODEL_DOWNLOAD, this._modelDownloadLimits || {});
        },

        _startSpeechInstall(SR, lang) {
            const M = NM();
            const lim = this._modelLimits();
            const opts = { langs: [lang], processLocally: true };
            const job = {
                lang, startedAt: Date.now(), status: 'downloadable', installResult: undefined,
                sawDownloading: false, canceled: false, stage: 'starting', listeners: new Set(), watchers: 0,
            };
            const notify = () => job.listeners.forEach((f) => { try { f(job); } catch (_) { } });
            try {
                Promise.resolve(SR.install(opts)).then((r) => { job.installResult = r === true; }, () => { job.installResult = false; });
            } catch (_) {
                job.installResult = false;
            }
            const final = ['done', 'failed', 'stalled', 'timeout', 'canceled'];
            job.promise = (async () => {
                for (;;) {
                    job.stage = M.modelDownloadStage({
                        status: job.status, installResult: job.installResult, elapsedMs: Date.now() - job.startedAt,
                        sawDownloading: job.sawDownloading, canceled: job.canceled,
                    }, lim);
                    notify();
                    if (final.indexOf(job.stage) >= 0) return job.stage;
                    await new Promise((r) => setTimeout(r, lim.pollMs));
                    if (job.installResult !== undefined || job.canceled) continue;
                    try { job.status = await this._voiceWithin(SR.available(opts), Math.max(2000, lim.pollMs * 5)); } catch (_) { }
                    if (job.status === 'downloading') job.sawDownloading = true;
                }
            })();
            return job;
        },

        _modelStageText(stage) {
            if (stage === 'downloading') return this._mt('Downloading the speech model…');
            if (stage === 'preparing') return this._mt('Preparing the speech model…');
            return this._mt('Starting the speech model download…');
        },

        _mountModelProgress(el, job) {
            const foot = el.querySelector('.nym-voice-foot') || el;
            const old = el.querySelector('.nym-model-dl');
            if (old) old.remove();
            const tx = el.querySelector('.nym-voice-tx');
            const box = el.querySelector('.nym-voice-transcript');
            if (tx) tx.hidden = true;
            if (box) box.hidden = true;
            const panel = document.createElement('div');
            panel.className = 'nym-model-dl';
            panel.setAttribute('role', 'group');
            panel.setAttribute('aria-label', this._mt('Speech model download'));
            const row = document.createElement('div');
            row.className = 'nym-model-dl-row';
            const stage = document.createElement('span');
            stage.className = 'nym-model-dl-stage';
            stage.setAttribute('aria-live', 'polite');
            const meta = document.createElement('span');
            meta.className = 'nym-model-dl-meta';
            row.appendChild(stage);
            row.appendChild(meta);
            const bar = document.createElement('div');
            bar.className = 'nym-model-dl-bar';
            bar.setAttribute('role', 'progressbar');
            bar.setAttribute('aria-label', this._mt('Speech model download'));
            bar.appendChild(document.createElement('span'));
            const cancel = document.createElement('button');
            cancel.type = 'button';
            cancel.className = 'nym-model-dl-cancel';
            cancel.dataset.action = 'nymModelCancel';
            cancel.textContent = this._mt('Cancel');
            panel.appendChild(row);
            panel.appendChild(bar);
            panel.appendChild(cancel);
            foot.appendChild(panel);
            let shown = job.stage;
            const paint = () => {
                const text = this._modelStageText(shown);
                if (stage.textContent !== text) stage.textContent = text;
                const clock = NM().formatClock((Date.now() - job.startedAt) / 1000);
                if (meta.textContent !== clock) meta.textContent = clock;
                bar.setAttribute('aria-valuetext', text + ' ' + clock);
            };
            const onJob = (j) => { if (j.stage === 'starting' || j.stage === 'downloading') shown = j.stage; paint(); };
            job.listeners.add(onJob);
            job.watchers++;
            const timer = setInterval(paint, 500);
            paint();
            let resolveCancel;
            const view = {
                canceled: new Promise((r) => { resolveCancel = r; }),
                cancel() {
                    resolveCancel('canceled');
                },
                setStage(s) { shown = s; paint(); },
                remove() {
                    clearInterval(timer);
                    job.listeners.delete(onJob);
                    panel.remove();
                    if (el._modelView === view) el._modelView = null;
                },
            };
            el._modelView = view;
            return view;
        },

        async _installSpeechModel(el, SR, lang) {
            if (!this._speechInstalls) this._speechInstalls = new Map();
            let job = this._speechInstalls.get(lang);
            if (!job) {
                job = this._startSpeechInstall(SR, lang);
                this._speechInstalls.set(lang, job);
                const own = job;
                job.promise.then(() => { if (this._speechInstalls.get(lang) === own) this._speechInstalls.delete(lang); });
            }
            const view = this._mountModelProgress(el, job);
            const outcome = await Promise.race([job.promise, view.canceled]);
            if (outcome === 'canceled') {
                job.watchers--;
                if (job.watchers <= 0) job.canceled = true;
                view.remove();
                this._showTranscript(el, null, this._mt('Canceled. Your browser may still finish the download in the background.'));
                this._showTranscribeButton(el);
                return false;
            }
            job.watchers--;
            if (outcome === 'done') {
                view.setStage('preparing');
                try { await this._voiceWithin(SR.available({ langs: [lang], processLocally: true }), 3000); } catch (_) { }
                view.remove();
                return true;
            }
            view.remove();
            let msg;
            if (outcome === 'stalled') msg = this._mt("The speech model download didn't start. This browser may not offer on-device speech models.");
            else if (outcome === 'timeout') msg = this._mt('The speech model download is taking too long.');
            else msg = this._mt("The speech model couldn't be downloaded.");
            this._showModelRetry(el, msg);
            this._voiceErrorToast(msg);
            return false;
        },

        _showTranscribeButton(el) {
            const tx = el.querySelector('.nym-voice-tx');
            if (tx) tx.hidden = false;
        },

        _showModelRetry(el, msg) {
            this._showTranscript(el, null, msg);
            const box = el.querySelector('.nym-voice-transcript');
            if (!box) return;
            box.appendChild(document.createTextNode(' '));
            const retry = document.createElement('button');
            retry.type = 'button';
            retry.className = 'nym-model-retry';
            retry.dataset.action = 'nymModelRetry';
            retry.textContent = this._mt('Retry');
            box.appendChild(retry);
        },

        async refreshSpeechModelSettings() {
            const status = document.getElementById('speechModelStatus');
            const clear = document.getElementById('speechTranscriptsClearBtn');
            if (!status) return;
            if (!this._transcripts) this._transcripts = NM().createTranscriptStore(window.localStorage);
            const n = this._transcripts.count();
            if (clear) {
                clear.textContent = this._mt('Delete saved transcripts ({count})', { count: n });
                clear.disabled = n === 0;
            }
            status.textContent = this._mt('Checking…');
            const lang = this._transcribeLang();
            let cap;
            try { cap = await this._transcribeCapability(lang); } catch (_) { cap = { ok: false, reason: this._mt('No on-device speech model is available for {lang}.', { lang }) }; }
            let text;
            if (!cap.ok) text = cap.reason;
            else if (!cap.needsInstall) text = this._mt('The speech model for {lang} is downloaded on this device and is reused for every transcription.', { lang });
            else if (cap.status === 'downloading' || (this._speechInstalls && this._speechInstalls.get(lang))) text = this._mt('The speech model for {lang} is downloading.', { lang });
            else text = this._mt('The speech model for {lang} is not downloaded yet. It downloads the first time you transcribe a voice message.', { lang });
            status.textContent = text;
        },

        async clearSavedTranscripts() {
            if (!this._transcripts) this._transcripts = NM().createTranscriptStore(window.localStorage);
            const n = this._transcripts.count();
            if (!n) return;
            const ok = await window.showAppConfirm(this._mt('Delete {count} saved transcripts from this device?', { count: n }), { okLabel: this._mt('Delete'), danger: true });
            if (!ok) return;
            this._transcripts.clear();
            document.querySelectorAll('.nym-voice').forEach((el) => {
                if (el.dataset.transcribing || el._modelView) return;
                const box = el.querySelector('.nym-voice-transcript');
                if (box) { box.hidden = true; box.textContent = ''; }
                this._showTranscribeButton(el);
            });
            await this.refreshSpeechModelSettings();
        },

        async _runLocalRecognition(SR, bytes, lang) {
            const AC = window.AudioContext || window.webkitAudioContext;
            const ctx = new AC();
            try {
                const buf = await ctx.decodeAudioData(bytes.slice(0));
                const dest = ctx.createMediaStreamDestination();
                const src = ctx.createBufferSource();
                src.buffer = buf;
                src.connect(dest);
                const track = dest.stream.getAudioTracks()[0];
                const rec = new SR();
                rec.lang = lang;
                rec.continuous = true;
                rec.interimResults = false;
                rec.processLocally = true;
                if (rec.processLocally !== true) throw new Error('local processing refused');
                const parts = [];
                return await new Promise((resolve, reject) => {
                    rec.onresult = (e) => {
                        for (let i = e.resultIndex; i < e.results.length; i++) {
                            if (e.results[i].isFinal) parts.push(e.results[i][0].transcript);
                        }
                    };
                    rec.onerror = (e) => reject(new Error((e && e.error) || 'error'));
                    rec.onend = () => resolve(parts.join(' ').replace(/\s+/g, ' ').trim());
                    rec.start(track);
                    src.onended = () => setTimeout(() => { try { rec.stop(); } catch (_) { } }, 800);
                    src.start();
                });
            } finally {
                try { await ctx.close(); } catch (_) { }
            }
        },

        _showTranscript(el, text, note) {
            const box = el.querySelector('.nym-voice-transcript');
            if (!box) return;
            box.hidden = false;
            box.classList.toggle('note', text == null);
            box.textContent = text == null ? (note || '') : (text || this._mt('No speech found.'));
            const tx = el.querySelector('.nym-voice-tx');
            if (tx && text != null) tx.hidden = true;
        },

        _onceKind(el) {
            return el.dataset.kind || 'photo';
        },

        _renderOnceState(el) {
            const id = el.dataset.onceId;
            const msg = el.closest('.message');
            const own = !!(msg && msg.classList.contains('self'));
            const label = el.querySelector('.nym-once-label');
            if (label) label.textContent = this._mt(NM().onceLabel(this._onceKind(el)));
            const state = el.querySelector('.nym-once-state');
            const btn = el.querySelector('.nym-once-open');
            let text;
            let done = false;
            if (own) {
                const by = this._onceStore.remoteOpenedBy(id);
                const inGroup = !!(msg && msg.dataset.groupId);
                text = by.length ? (inGroup && by.length > 1 ? this._mt('Opened by {n}', { n: by.length }) : this._mt('Opened')) : this._mt('Sent');
                done = true;
            } else if (this._onceStore.isOpened(id)) {
                text = this._mt('Opened');
                done = true;
            } else {
                text = this._mt('Tap to view once');
            }
            if (state) state.textContent = text;
            el.classList.toggle('opened', done);
            el.classList.toggle('own', own);
            if (btn) btn.setAttribute('aria-disabled', done ? 'true' : 'false');
        },

        _refreshOnce(onceId) {
            document.querySelectorAll('.nym-once[data-once-id="' + onceId + '"]').forEach((el) => this._renderOnceState(el));
        },

        async _onceBytes(el) {
            if (el.dataset.localId) {
                const local = this._localMediaFor(el);
                if (!local) throw new Error('gone');
                return new Uint8Array(await local.blob.arrayBuffer());
            }
            const resp = await fetch(el.dataset.src);
            if (!resp.ok) throw new Error('HTTP ' + resp.status);
            const ct = new Uint8Array(await resp.arrayBuffer());
            return await NM().decryptOnce(ct, el.dataset.key, el.dataset.nonce);
        },

        async _openOnce(el) {
            if (!el) return;
            const id = el.dataset.onceId;
            const msg = el.closest('.message');
            if (msg && msg.classList.contains('self')) {
                await window.showAppAlert(this._mt("You sent this as view once, so it can't be opened from here."));
                return;
            }
            if (this._onceStore.isOpened(id)) return;
            const ok = await window.showAppConfirm(
                this._mt("View once: after you close it, Nymchat won't show it again. A modified app or another device could still keep a copy."),
                { okLabel: this._mt('View'), title: this._mt(NM().onceLabel(this._onceKind(el))) });
            if (!ok) return;
            let bytes;
            try {
                bytes = await this._onceBytes(el);
            } catch (_) {
                await window.showAppAlert(this._mt("This view-once media couldn't be loaded. Try again later."));
                return;
            }
            this._onceStore.markOpened(id);
            this._refreshOnce(id);
            this._sendOnceOpened(el, id);
            const blob = new Blob([bytes], { type: el.dataset.mime || 'application/octet-stream' });
            this._showOnceViewer(blob, this._onceKind(el));
            if (el.dataset.localId && this._meshLocalMedia) {
                const local = this._meshLocalMedia.get(el.dataset.localId);
                if (local) {
                    try { URL.revokeObjectURL(local.url); } catch (_) { }
                    this._meshLocalMedia.delete(el.dataset.localId);
                }
            }
        },

        _sendOnceOpened(el, onceId) {
            const msg = el.closest('.message');
            if (el.dataset.localId) {
                const local = this._localMediaFor(el);
                if (local && local.peerID && this._mesh && this._mesh.running) {
                    this._mesh.sendReadReceipt(local.peerID, NM().meshOnceReceiptId(onceId)).catch(() => { });
                }
                return;
            }
            const sender = msg && msg.dataset.pubkey;
            if (!sender || typeof this.sendNymReceipt !== 'function') return;
            const groupId = msg.dataset.groupId || null;
            this.sendNymReceipt(onceId, NM().RECEIPT_OPENED, sender, groupId ? 'group' : 'pm', groupId).catch(() => { });
            if (this.pubkey && sender !== this.pubkey) {
                this.sendNymReceipt(onceId, NM().RECEIPT_OPENED, this.pubkey, 'pm').catch(() => { });
            }
        },

        handleOnceOpenedReceipt(rumor, senderPubkey, senderVerified) {
            const tags = (rumor && rumor.tags) || [];
            const type = tags.find((t) => Array.isArray(t) && t[0] === 'receipt');
            if (!type || type[1] !== NM().RECEIPT_OPENED) return false;
            if (senderVerified !== true) return true;
            if (!this._onceStore) this._onceStore = NM().createOnceStore(window.localStorage);
            const self = !!this.pubkey && senderPubkey === this.pubkey;
            for (const t of tags) {
                if (!Array.isArray(t) || t[0] !== 'x' || !/^[0-9a-f]{16}$/.test(t[1] || '')) continue;
                const changed = self ? this._onceStore.markOpened(t[1]) : this._onceStore.markRemoteOpened(t[1], senderPubkey);
                if (changed) this._refreshOnce(t[1]);
            }
            return true;
        },

        _showOnceViewer(blob, kind) {
            this._closeOnceViewer();
            const url = URL.createObjectURL(blob);
            const wrap = document.createElement('div');
            wrap.className = 'once-viewer';
            wrap.id = 'onceViewer';
            wrap.setAttribute('role', 'dialog');
            wrap.setAttribute('aria-modal', 'true');
            let media;
            if (kind === 'video') {
                media = document.createElement('video');
                media.controls = true;
                media.autoplay = true;
                media.playsInline = true;
                media.setAttribute('controlsList', 'nodownload');
            } else if (kind === 'voice') {
                media = document.createElement('audio');
                media.controls = true;
                media.autoplay = true;
                media.setAttribute('controlsList', 'nodownload');
            } else {
                media = document.createElement('img');
                media.alt = '';
                media.draggable = false;
            }
            media.className = 'once-viewer-media';
            media.src = url;
            media.addEventListener('contextmenu', (e) => e.preventDefault());
            const note = document.createElement('div');
            note.className = 'once-viewer-note';
            note.textContent = this._mt('View once. Closing this removes it from Nymchat. A modified app or another device could still keep a copy.');
            const close = document.createElement('button');
            close.type = 'button';
            close.className = 'once-viewer-close';
            close.dataset.action = 'nymOnceClose';
            close.textContent = this._mt('Close');
            wrap.appendChild(media);
            wrap.appendChild(note);
            wrap.appendChild(close);
            document.body.appendChild(wrap);
            this._onceViewerUrl = url;
            this._onceViewerKey = (e) => { if (e.key === 'Escape') this._closeOnceViewer(); };
            document.addEventListener('keydown', this._onceViewerKey, true);
        },

        _closeOnceViewer() {
            const el = document.getElementById('onceViewer');
            if (el) {
                el.querySelectorAll('video,audio').forEach((m) => { try { m.pause(); } catch (_) { } m.removeAttribute('src'); });
                el.remove();
            }
            if (this._onceViewerUrl) {
                try { URL.revokeObjectURL(this._onceViewerUrl); } catch (_) { }
                this._onceViewerUrl = null;
            }
            if (this._onceViewerKey) {
                document.removeEventListener('keydown', this._onceViewerKey, true);
                this._onceViewerKey = null;
            }
        },

        _setupVoiceButton() {
            const btn = document.getElementById('voiceRecordBtn');
            if (!btn || btn._nymBound) return;
            btn._nymBound = true;
            btn.addEventListener('contextmenu', (e) => e.preventDefault());
            btn.addEventListener('pointerdown', (e) => {
                if (e.button !== undefined && e.button !== 0) return;
                e.preventDefault();
                if (this._voiceRec) return;
                const st = this.mediaFeatureState('voice');
                if (st.state === 'off') {
                    this._mediaNotice(this._mt(st.reason));
                    return;
                }
                try { btn.setPointerCapture(e.pointerId); } catch (_) { }
                this._voiceGesture = { x: e.clientX, y: e.clientY, at: Date.now(), id: e.pointerId };
                this._startVoiceRecording(st);
            });
            btn.addEventListener('pointermove', (e) => {
                const g = this._voiceGesture;
                const rec = this._voiceRec;
                if (!g || !rec || rec.locked) return;
                const dx = e.clientX - g.x;
                const dy = e.clientY - g.y;
                rec.dragX = dx;
                if (dx < -CANCEL_DX) {
                    this._voiceGesture = null;
                    this._stopVoiceRecording(false);
                    return;
                }
                if (dy < -LOCK_DY) {
                    this._voiceGesture = null;
                    this._lockVoiceRecording();
                    return;
                }
                this._renderVoiceBar();
            });
            const release = (e) => {
                const g = this._voiceGesture;
                this._voiceGesture = null;
                const rec = this._voiceRec;
                if (!g || !rec || rec.locked) return;
                if (Date.now() - g.at < HOLD_MS) {
                    this._lockVoiceRecording();
                    return;
                }
                if (e.type === 'pointercancel') { this._stopVoiceRecording(false); return; }
                this._stopVoiceRecording(true);
            };
            btn.addEventListener('pointerup', release);
            btn.addEventListener('pointercancel', release);
            btn.addEventListener('keydown', (e) => {
                if (e.key !== 'Enter' && e.key !== ' ') return;
                e.preventDefault();
                if (this._voiceRec) return;
                const st = this.mediaFeatureState('voice');
                if (st.state === 'off') { this._mediaNotice(this._mt(st.reason)); return; }
                this._startVoiceRecording(st).then(() => this._lockVoiceRecording());
            });
        },

        async _startVoiceRecording(st) {
            const target = this._mediaTarget();
            const route = this._mediaRoute();
            const rec = {
                target, route, st, startedAt: Date.now(), locked: false, once: false,
                chunks: [], samples: [], stream: null, recorder: null, mime: '', dragX: 0,
                maxSeconds: st.maxSeconds || NM().LIMITS.voiceMaxSeconds, stopped: false, limitHit: false,
            };
            this._voiceRec = rec;
            this._voiceStop();
            this._renderVoiceBar();
            try {
                rec.stream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true, channelCount: 1 } });
            } catch (err) {
                this._voiceRec = null;
                this._renderVoiceBar();
                this._mediaNotice(this._mt("Microphone access was denied, so voice messages can't be recorded."));
                return;
            }
            if (this._voiceRec !== rec) { rec.stream.getTracks().forEach((t) => t.stop()); return; }
            try {
                rec.mime = NM().preferredMime('voice', (m) => window.MediaRecorder.isTypeSupported(m));
                try {
                    rec.recorder = new MediaRecorder(rec.stream, Object.assign({ audioBitsPerSecond: NM().LIMITS.voiceBitrate }, rec.mime ? { mimeType: rec.mime } : {}));
                } catch (_) {
                    rec.mime = '';
                    rec.recorder = new MediaRecorder(rec.stream);
                }
                rec.recorder.ondataavailable = (e) => { if (e.data && e.data.size) rec.chunks.push(e.data); };
                rec.stopPromise = new Promise((r) => { rec.recorder.onstop = r; });
                rec.recorder.start(250);
            } catch (err) {
                rec.stream.getTracks().forEach((t) => { try { t.stop(); } catch (_) { } });
                this._voiceRec = null;
                this._renderVoiceBar();
                this._voiceErrorToast(this._mt("Voice messages can't be recorded in this browser: {error}", { error: (err && err.message) || this._mt('unknown error') }));
                return;
            }
            rec.startedAt = Date.now();
            try {
                const AC = window.AudioContext || window.webkitAudioContext;
                rec.audioCtx = new AC();
                const srcNode = rec.audioCtx.createMediaStreamSource(rec.stream);
                const an = rec.audioCtx.createAnalyser();
                an.fftSize = 1024;
                srcNode.connect(an);
                const buf = new Float32Array(an.fftSize);
                rec.sampleTimer = setInterval(() => {
                    an.getFloatTimeDomainData(buf);
                    let sum = 0;
                    for (let i = 0; i < buf.length; i++) sum += buf[i] * buf[i];
                    rec.samples.push(Math.min(1, Math.sqrt(sum / buf.length) * 3));
                }, SAMPLE_MS);
            } catch (_) { }
            rec.tick = setInterval(() => {
                const secs = (Date.now() - rec.startedAt) / 1000;
                if (secs >= rec.maxSeconds && !rec.limitHit) {
                    rec.limitHit = true;
                    this._lockVoiceRecording();
                    this._finishVoiceCapture(rec);
                }
                this._renderVoiceBar();
            }, 200);
            this._renderVoiceBar();
        },

        _lockVoiceRecording() {
            const rec = this._voiceRec;
            if (!rec) return;
            rec.locked = true;
            rec.dragX = 0;
            this._renderVoiceBar();
        },

        _voiceToggleOnce() {
            const rec = this._voiceRec;
            if (!rec) return;
            const st = this.mediaFeatureState('once');
            if (st.state === 'off') { this._mediaNotice(this._mt(st.reason)); return; }
            rec.once = !rec.once;
            this._renderVoiceBar();
        },

        async _finishVoiceCapture(rec) {
            if (rec.stopped) return rec.blob;
            rec.stopped = true;
            rec.duration = Math.min(rec.maxSeconds, (Date.now() - rec.startedAt) / 1000);
            clearInterval(rec.sampleTimer);
            if (rec.recorder && rec.recorder.state !== 'inactive') {
                try { rec.recorder.stop(); } catch (_) { }
                await this._voiceWithin(rec.stopPromise, this._voiceStopTimeoutMs || 3000).catch(() => { });
            }
            if (rec.stream) rec.stream.getTracks().forEach((t) => { try { t.stop(); } catch (_) { } });
            if (rec.audioCtx) { try { Promise.resolve(rec.audioCtx.close()).catch(() => { }); } catch (_) { } }
            const type = NM().baseMime((rec.recorder && rec.recorder.mimeType) || rec.mime) || 'audio/webm';
            rec.blob = new Blob(rec.chunks, { type });
            return rec.blob;
        },

        async _stopVoiceRecording(send) {
            const rec = this._voiceRec;
            if (!rec) return;
            clearInterval(rec.tick);
            let blob = null;
            try {
                blob = await this._finishVoiceCapture(rec);
            } catch (err) {
                if (send) this._voiceSendFailed(err);
                send = false;
            } finally {
                this._voiceRec = null;
                this._renderVoiceBar();
            }
            if (!send) return;
            if (!blob || rec.duration < NM().LIMITS.minVoiceSeconds) {
                this._mediaNotice(this._mt('Hold to record, release to send. Tap to record hands-free.'));
                return;
            }
            await this._sendVoiceNote({
                blob, duration: rec.duration, samples: rec.samples, target: rec.target, route: rec.route, once: rec.once,
                recordedMime: (rec.recorder && rec.recorder.mimeType) || '', requestedMime: rec.mime || '',
            });
        },

        _renderVoiceBar() {
            const wrap = document.querySelector('.input-wrapper');
            let bar = document.getElementById('voiceRecBar');
            const rec = this._voiceRec;
            const btn = document.getElementById('voiceRecordBtn');
            if (btn) btn.classList.toggle('recording', !!rec);
            if (!rec) {
                if (bar) bar.remove();
                return;
            }
            if (!bar) {
                bar = document.createElement('div');
                bar.id = 'voiceRecBar';
                bar.className = 'voice-rec-bar';
                bar.innerHTML = '<button type="button" class="voice-rec-cancel" data-action="nymVoiceRecCancel">' + TRASH_SVG + '</button>'
                    + '<span class="voice-rec-dot" aria-hidden="true"></span>'
                    + '<span class="voice-rec-time"></span>'
                    + '<span class="voice-rec-wave" aria-hidden="true"></span>'
                    + '<span class="voice-rec-hint"></span>'
                    + '<button type="button" class="voice-rec-once" data-action="nymVoiceRecOnce">' + ONCE_SVG + '</button>'
                    + '<button type="button" class="voice-rec-send" data-action="nymVoiceRecSend">' + SEND_SVG + '</button>';
                if (wrap) wrap.appendChild(bar);
                else document.body.appendChild(bar);
            }
            const secs = rec.stopped ? rec.duration : (Date.now() - rec.startedAt) / 1000;
            const remaining = Math.max(0, rec.maxSeconds - secs);
            bar.querySelector('.voice-rec-time').textContent = NM().formatClock(secs) + ' / ' + NM().formatClock(rec.maxSeconds);
            const hint = bar.querySelector('.voice-rec-hint');
            let hintText;
            if (rec.limitHit) hintText = this._mt('Limit reached ({max}). Send or delete.', { max: NM().formatClock(rec.maxSeconds) });
            else if (remaining <= 10) hintText = this._mt('{s} s left', { s: Math.ceil(remaining) });
            else if (rec.st && rec.st.state === 'warn') hintText = this._mt(rec.st.reason);
            else if (rec.locked) hintText = this._mt('Recording hands-free');
            else hintText = '‹ ' + this._mt('Slide to cancel') + '  ·  ' + LOCK_GLYPH + ' ' + this._mt('Slide up to lock');
            if (hint.textContent !== hintText) hint.textContent = hintText;
            bar.classList.toggle('locked', rec.locked);
            bar.classList.toggle('warn', remaining <= 10 || rec.limitHit);
            const onceBtn = bar.querySelector('.voice-rec-once');
            const onceSt = this.mediaFeatureState('once');
            onceBtn.hidden = !rec.locked || onceSt.state === 'off';
            onceBtn.classList.toggle('on', !!rec.once);
            onceBtn.setAttribute('aria-pressed', rec.once ? 'true' : 'false');
            onceBtn.setAttribute('title', this._mt('View once'));
            onceBtn.setAttribute('aria-label', this._mt('View once'));
            bar.querySelector('.voice-rec-send').hidden = !rec.locked;
            bar.querySelector('.voice-rec-send').setAttribute('aria-label', this._mt('Send voice message'));
            bar.querySelector('.voice-rec-cancel').setAttribute('aria-label', this._mt('Delete recording'));
            const waveEl = bar.querySelector('.voice-rec-wave');
            const recent = rec.samples.slice(-32);
            const levels = recent.length ? recent.map((v) => Math.round(Math.min(1, v) * 15)) : [];
            const sig = levels.join(',');
            if (waveEl.dataset.sig !== sig) {
                waveEl.dataset.sig = sig;
                waveEl.innerHTML = levels.map((l) => '<span class="voice-rec-lvl h' + l + '"></span>').join('');
            }
            bar.style.setProperty('--drag', Math.min(0, rec.dragX || 0) + 'px');
        },

        async _uploadNoteBlob(file, label) {
            const r = await this._uploadFileWithProgress(file, label, { registerFallbacks: true });
            return r;
        },

        _voiceWithin(promise, ms) {
            let timer = null;
            const limit = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('timeout')), ms); });
            return Promise.race([Promise.resolve(promise), limit]).finally(() => clearTimeout(timer));
        },

        _voiceCloseQuietly(ac) {
            try { Promise.resolve(ac && ac.close && ac.close()).catch(() => { }); } catch (_) { }
        },

        async _webAudioFaithful(OAC, ms) {
            const M = NM();
            const rate = M.PORTABLE_VOICE_RATE;
            const probe = M.voiceProbeSignal();
            const off = new OAC(1, probe.length, rate);
            const buf = off.createBuffer(1, probe.length, rate);
            if (typeof buf.copyToChannel === 'function') buf.copyToChannel(probe, 0);
            else buf.getChannelData(0).set(probe);
            const src = off.createBufferSource();
            src.buffer = buf;
            src.connect(off.destination);
            src.start();
            const rendered = await this._voiceWithin(off.startRendering(), ms);
            return M.voiceProbeMatches(probe, rendered.getChannelData(0));
        },

        async _portableVoiceBlob(blob, expectedSeconds) {
            const M = NM();
            const AC = window.AudioContext || window.webkitAudioContext;
            const OAC = window.OfflineAudioContext || window.webkitOfflineAudioContext;
            if (!AC || !OAC) return null;
            const ms = this._voiceConvertTimeoutMs || M.VOICE_CONVERT.timeoutMs;
            if (!(await this._webAudioFaithful(OAC, ms))) return null;
            const ac = new AC();
            let decoded;
            try {
                decoded = await this._voiceWithin(ac.decodeAudioData(await blob.arrayBuffer()), ms);
            } finally {
                this._voiceCloseQuietly(ac);
            }
            const rate = M.PORTABLE_VOICE_RATE;
            if (!decoded || !(decoded.duration > 0)) return null;
            const off = new OAC(1, Math.max(1, Math.ceil(decoded.duration * rate)), rate);
            const src = off.createBufferSource();
            src.buffer = decoded;
            src.connect(off.destination);
            src.start();
            const rendered = await this._voiceWithin(off.startRendering(), ms);
            const samples = rendered.getChannelData(0);
            if (!M.checkPortableVoice(samples, rate, expectedSeconds).ok) return null;
            return new Blob([M.encodeWav(samples, rate)], { type: 'audio/wav' });
        },

        _voiceWaveform(samples) {
            const M = NM();
            const bars = M.LIMITS.waveformBars;
            try {
                const clean = Array.from(samples || [], (v) => (typeof v === 'number' && isFinite(v) ? v : 0));
                const out = M.computeWaveform(clean, bars);
                if (Array.isArray(out) && out.every((v) => Number.isFinite(v))) return out;
            } catch (_) { }
            return new Array(bars).fill(0);
        },

        _voiceErrorToast(text) {
            if (typeof this.showToast === 'function') this.showToast(text, { kind: 'error' });
            else this._mediaNotice(text);
        },

        _voiceSendFailed(err) {
            this._voiceErrorToast(this._mt("Couldn't send the voice message: {error}", { error: (err && err.message) || this._mt('unknown error') }));
        },

        async _sendVoiceNote(n) {
            const M = NM();
            try {
                let blob = n.blob;
                if (!blob || !blob.size) throw new Error(this._mt('the recording is empty'));
                if (n.route !== 'mesh' && !M.isPortableVoiceMime(n.recordedMime || blob.type, n.requestedMime)) {
                    try { blob = (await this._portableVoiceBlob(blob, n.duration)) || blob; } catch (_) { }
                }
                const mime = M.baseMime(blob.type) || 'audio/webm';
                const waveform = this._voiceWaveform(n.samples);
                const bytes = new Uint8Array(await blob.arrayBuffer());
                const desc = { kind: 'voice', mime, duration: n.duration, size: bytes.length, waveform };
                if (n.route === 'mesh') {
                    await this._sendNoteOverMesh(desc, bytes, n.target);
                    return;
                }
                await this._uploadAndSendNote(desc, bytes, n.target, !!n.once, this._mt('Sending voice message…'));
            } catch (err) {
                if (err && err.name === 'AbortError') return;
                this._voiceSendFailed(err);
            }
        },

        async _uploadAndSendNote(desc, bytes, target, once, label) {
            const M = NM();
            this._lastFailedNote = null;
            try {
                let body = bytes;
                let secret = null;
                if (once) {
                    secret = M.newOnceSecret();
                    body = await M.encryptOnce(bytes, secret.key, secret.nonce);
                }
                const file = new Blob([body], { type: once ? 'application/octet-stream' : desc.mime });
                const { url } = await this._uploadNoteBlob(file, label);
                const full = M.attachDescriptor(url, Object.assign({}, desc, once ? Object.assign({ once: true }, secret) : {}));
                if (!full) throw new Error('descriptor');
                const content = once ? M.onceContent(desc.kind, full) : full;
                await this._sendMediaNoteContent(content, target);
            } catch (err) {
                if (err && err.name === 'AbortError') return;
                this._lastFailedNote = { desc, bytes, target, once, label };
                const msg = this.escapeHtml(this._mt("Couldn't send: {error}", { error: (err && err.message) || 'upload failed' }));
                const html = msg + ' <button type="button" class="nym-retry-note" data-action="nymRetryNote">' + this.escapeHtml(this._mt('Retry')) + '</button>';
                if (typeof this.showToast === 'function') this.showToast(html, { html: true, kind: 'error' });
                this.displaySystemMessage(html, 'system', { html: true, feed: true });
            }
        },

        async _retryFailedNote() {
            const f = this._lastFailedNote;
            if (!f) return;
            await this._uploadAndSendNote(f.desc, f.bytes, f.target, f.once, f.label);
        },

        _storeLocalMedia(blob, extra) {
            if (!this._meshLocalMedia) this._meshLocalMedia = new Map();
            const id = NM().randomHex(8);
            this._meshLocalMedia.set(id, Object.assign({ blob, url: URL.createObjectURL(blob) }, extra || {}));
            return id;
        },

        async _sendNoteOverMesh(desc, bytes, target) {
            const M = NM();
            const size = M.meshSizeCheck(bytes.length);
            if (!size.ok) {
                this._mediaNotice(this._mt(M.REASONS.meshTooLarge, { size: M.formatBytes(bytes.length) }));
                return false;
            }
            const mesh = this._mesh;
            if (!mesh || !mesh.running) {
                this._mediaNotice(this._mt("The Bluetooth mesh isn't running."));
                return false;
            }
            const name = M.meshFileName(desc) || ('file.' + M.extForMime(desc.mime));
            let ok = false;
            try { ok = await mesh.sendFileBroadcast(name, desc.mime, bytes); } catch (_) { ok = false; }
            if (!ok) {
                this._mediaNotice(this._mt(M.REASONS.meshTooLarge, { size: M.formatBytes(bytes.length) }));
                return false;
            }
            if (mesh.linkCount === 0) this._mediaNotice(this._mt('No mesh device in range — waiting for Bluetooth range.'));
            const id = this._storeLocalMedia(new Blob([bytes], { type: desc.mime }), {});
            const content = M.attachDescriptor('nymlocal:' + id, desc);
            const channel = (target && target.geohash) || this.currentGeohash;
            const now = Date.now();
            this.displayMessage({
                id: 'mesh-file-' + id,
                author: this.nym,
                pubkey: this.pubkey,
                content,
                created_at: Math.floor(now / 1000),
                _ms: now,
                _seq: ++this._msgSeq,
                timestamp: new Date(now),
                channel,
                geohash: channel,
                isOwn: true,
                isMesh: true,
                isPM: false,
            });
            return true;
        },

        _meshFileCardHtml(f) {
            const esc = (v) => this.escapeHtml(String(v == null ? '' : v));
            const local = this._meshLocalMedia && this._meshLocalMedia.get(f.localId);
            const url = local && local.url && /^blob:/.test(local.url) ? local.url : '';
            const category = typeof this.getFileTypeCategory === 'function' ? this.getFileTypeCategory(String(f.name || ''), String(f.type || '')) : 'file';
            const size = typeof this.formatFileSize === 'function' ? this.formatFileSize(f.size) : NM().formatBytes(f.size || 0);
            const action = url
                ? `<div class="file-offer-actions"><a class="file-offer-btn" href="${esc(url)}" download="${esc(f.name)}">${esc(this._mt('Save'))}</a></div>`
                : `<div class="file-offer-unseeded"><div class="file-offer-unseeded-dot"></div><span>${esc(this._mt('No longer available'))}</span></div>`;
            return `<div class="file-offer mesh-file" data-mesh-file="${esc(f.localId)}">`
                + `<div class="file-offer-header"><div class="file-offer-icon ${esc(category)}">`
                + '<svg viewBox="0 0 24 24" stroke-width="2"><path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"></path><polyline points="13 2 13 9 20 9"></polyline></svg>'
                + `</div><div class="file-offer-info"><div class="file-offer-name" title="${esc(f.name)}">${esc(f.name)}</div>`
                + `<div class="file-offer-meta">${esc(size)} • ${esc(f.type || 'application/octet-stream')} • ${esc(this._mt('Bluetooth mesh'))}</div></div></div>`
                + action + '</div>';
        },

        async sendFileOverMesh(file) {
            const M = NM();
            if (!file) return false;
            const bytes = new Uint8Array(await file.arrayBuffer());
            if (!M.meshSizeCheck(bytes.length).ok) {
                this._mediaNotice(this._mt(M.REASONS.meshTooLarge, { size: M.formatBytes(bytes.length) }));
                return false;
            }
            const mesh = this._mesh;
            if (!mesh || !mesh.running) {
                this._mediaNotice(this._mt("The Bluetooth mesh isn't running."));
                return false;
            }
            const mime = M.baseMime(file.type) || 'application/octet-stream';
            const name = String(file.name || ('file.' + M.extForMime(mime))).slice(0, 120);
            let ok = false;
            try { ok = await mesh.sendFileBroadcast(name, mime, bytes); } catch (_) { ok = false; }
            if (!ok) {
                this._mediaNotice(this._mt(M.REASONS.meshTooLarge, { size: M.formatBytes(bytes.length) }));
                return false;
            }
            if (mesh.linkCount === 0) this._mediaNotice(this._mt('No mesh device in range — waiting for Bluetooth range.'));
            const id = this._storeLocalMedia(new Blob([bytes], { type: mime }), { name });
            const now = Date.now();
            const channel = this.currentGeohash;
            this.displayMessage({
                id: 'mesh-file-' + id, author: this.nym, pubkey: this.pubkey,
                content: name,
                meshFile: { localId: id, name, size: bytes.length, type: mime },
                created_at: Math.floor(now / 1000), _ms: now, _seq: ++this._msgSeq, timestamp: new Date(now),
                channel, geohash: channel, isOwn: true, isMesh: true, isPM: false,
            });
            return true;
        },

        onMeshFile(f) {
            const M = NM();
            const mime = M.baseMime(f.mimeType);
            const note = M.parseMeshFileName(f.fileName, mime);
            const blob = new Blob([f.bytes], { type: mime || 'application/octet-stream' });
            const name = String(f.fileName || 'file').slice(0, 120);
            const id = this._storeLocalMedia(blob, { peerID: f.senderPeerID, name });
            let content;
            let meshFile = null;
            if (note) {
                const desc = Object.assign({}, note);
                content = M.attachDescriptor('nymlocal:' + id, desc);
                if (note.once) content = M.onceContent(note.kind === 'round' ? 'video' : note.kind, content);
            } else if (/^image\//.test(mime)) {
                content = M.attachDescriptor('nymlocal:' + id, { kind: 'photo', mime });
            } else if (/^video\//.test(mime)) {
                content = M.attachDescriptor('nymlocal:' + id, { kind: 'video', mime });
            } else if (/^audio\//.test(mime)) {
                content = M.attachDescriptor('nymlocal:' + id, { kind: 'voice', mime });
            }
            if (!content) {
                content = name;
                meshFile = { localId: id, name, size: f.bytes ? f.bytes.length : 0, type: mime || 'application/octet-stream' };
            }
            if (f.isDirect) {
                this._onMeshPrivateMessage({
                    senderPeerID: f.senderPeerID,
                    senderNickname: f.senderNickname,
                    senderNostrPubkey: f.senderNostrPubkey,
                    messageId: 'file-' + id,
                    content,
                    meshFile,
                    timestampMs: f.timestampMs || Date.now(),
                });
                return;
            }
            this._onMeshPublicMessage({
                senderPeerID: f.senderPeerID,
                senderNickname: f.senderNickname,
                senderNostrPubkey: f.senderNostrPubkey,
                content,
                meshFile,
                timestampMs: f.timestampMs || Date.now(),
                channel: null,
            });
        },

        onMeshReceipt(r) {
            const onceId = NM().parseMeshOnceReceiptId(r && r.messageId);
            if (!onceId || !r.isRead) return;
            if (!this._onceStore) this._onceStore = NM().createOnceStore(window.localStorage);
            if (this._onceStore.markRemoteOpened(onceId, 'mesh:' + r.fromPeerID)) this._refreshOnce(onceId);
        },

        async _compressImage(file, maxDim, quality) {
            if (!/^image\/(jpeg|png|webp)$/i.test(file.type || '')) return null;
            let bmp;
            try { bmp = await createImageBitmap(file); } catch (_) { return null; }
            const dims = NM().scaledDimensions(bmp.width, bmp.height, maxDim);
            const canvas = document.createElement('canvas');
            canvas.width = dims.width;
            canvas.height = dims.height;
            const g = canvas.getContext('2d');
            g.fillStyle = '#fff';
            g.fillRect(0, 0, dims.width, dims.height);
            g.drawImage(bmp, 0, 0, dims.width, dims.height);
            try { bmp.close(); } catch (_) { }
            const blob = await new Promise((r) => canvas.toBlob(r, 'image/jpeg', quality));
            if (!blob) return null;
            if (blob.size >= file.size) return null;
            return new File([blob], (file.name || 'photo').replace(/\.[^.]+$/, '') + '.jpg', { type: 'image/jpeg' });
        },

        async attachmentVariant(rec) {
            const M = NM();
            if (rec.kind === 'image') {
                if (rec.compressed === undefined) {
                    rec.compressed = await this._compressImage(rec.file, M.LIMITS.photoMaxDimension, M.LIMITS.photoQuality);
                }
                rec.originalSize = rec.file.size;
                rec.compressedSize = rec.compressed ? rec.compressed.size : rec.file.size;
                if (!this._composerHd && rec.compressed) return rec.compressed;
            } else {
                rec.originalSize = rec.file.size;
                rec.compressedSize = rec.file.size;
            }
            return rec.file;
        },

        async prepareAttachmentUpload(rec) {
            const M = NM();
            const file = await this.attachmentVariant(rec);
            const once = !!this._composerOnce && this.mediaFeatureState('once').state !== 'off';
            rec.wantOnce = once;
            rec.wantHd = !!this._composerHd;
            if (!once) {
                rec.secret = null;
                return file;
            }
            rec.secret = M.newOnceSecret();
            const bytes = new Uint8Array(await file.arrayBuffer());
            const ct = await M.encryptOnce(bytes, rec.secret.key, rec.secret.nonce);
            rec.onceMime = M.baseMime(file.type) || 'image/jpeg';
            rec.onceSize = bytes.length;
            return new Blob([ct], { type: 'application/octet-stream' });
        },

        attachmentContentFor(rec) {
            const M = NM();
            if (!rec.uploadedAs || !rec.uploadedAs.once || !rec.uploadedAs.secret) return rec.url;
            const kind = rec.kind === 'video' ? 'video' : 'photo';
            const full = M.attachDescriptor(rec.url, Object.assign({ kind, mime: rec.uploadedAs.mime, size: rec.uploadedAs.size, once: true }, rec.uploadedAs.secret));
            return full ? M.onceContent(kind, full) : '';
        },

        attachmentStale(rec) {
            if (!rec || rec.status !== 'done' || !rec.uploadedAs) return false;
            const wantOnce = !!this._composerOnce && this.mediaFeatureState('once').state !== 'off';
            const hdMatters = rec.kind === 'image' && rec.compressed;
            return rec.uploadedAs.once !== wantOnce || (hdMatters && rec.uploadedAs.hd !== !!this._composerHd);
        },

        _reuploadStaleAttachments() {
            const list = this._composerAttachments || [];
            for (const rec of list) {
                if (this.attachmentStale(rec) && typeof this.retryComposerAttachment === 'function') {
                    this.retryComposerAttachment(rec.id);
                }
            }
        },

        _toggleComposerHd() {
            this._composerHd = !this._composerHd;
            this._renderMediaOptions();
            this._reuploadStaleAttachments();
        },

        _toggleComposerOnce() {
            const st = this.mediaFeatureState('once');
            if (st.state === 'off') { this._mediaNotice(this._mt(st.reason)); return; }
            this._composerOnce = !this._composerOnce;
            this._renderMediaOptions();
            this._reuploadStaleAttachments();
        },

        _renderMediaOptions() {
            const host = document.getElementById('composerPanels');
            if (!host) return;
            let bar = document.getElementById('mediaOptionsBar');
            const list = (this._composerAttachments || []).filter((a) => !a.gif);
            if (!list.length) {
                if (bar) bar.remove();
                this._composerHd = false;
                this._composerOnce = false;
                return;
            }
            if (!bar) {
                bar = document.createElement('div');
                bar.id = 'mediaOptionsBar';
                bar.className = 'media-options-bar';
                host.insertBefore(bar, host.firstChild);
            }
            const M = NM();
            const hdSt = this.mediaFeatureState('hd');
            const onceSt = this.mediaFeatureState('once');
            let orig = 0, comp = 0, known = true, anyImage = false;
            for (const r of list) {
                if (r.originalSize == null) { known = false; continue; }
                orig += r.originalSize;
                comp += r.compressedSize;
                if (r.kind === 'image') anyImage = true;
            }
            const size = known ? (this._composerHd ? M.formatBytes(orig) : M.formatBytes(comp)) : '…';
            const other = known && anyImage && orig !== comp ? (this._composerHd ? M.formatBytes(comp) : M.formatBytes(orig)) : '';
            const hdLabel = this._composerHd ? this._mt('HD · original quality') : this._mt('Standard quality');
            const sizeLine = other
                ? this._mt('{size} (the other option: {other})', { size, other })
                : (anyImage || !known ? size : this._mt('{size} · videos are sent as they are', { size }));
            const sig = [this._composerHd, this._composerOnce, size, other, hdSt.state, onceSt.state, this.getUiLanguage ? this.getUiLanguage() : ''].join('|');
            if (bar.dataset.sig === sig) return;
            bar.dataset.sig = sig;
            const esc = (s) => this.escapeHtml(s);
            const hdNote = hdSt.state === 'warn' && this._composerHd ? `<span class="media-opt-note">${esc(this._mt(hdSt.reason))}</span>` : '';
            const onceBtn = onceSt.state === 'off' ? ''
                : `<button type="button" class="media-opt once ${this._composerOnce ? 'on' : ''}" data-action="nymMediaOnce" aria-pressed="${this._composerOnce ? 'true' : 'false'}">${ONCE_SVG}<span>${esc(this._mt('View once'))}</span></button>`;
            const onceNote = this._composerOnce
                ? `<span class="media-opt-note">${esc(this._mt('Opens once, then disappears in Nymchat. A modified app or another device could still keep a copy.'))}</span>` : '';
            bar.innerHTML = `<button type="button" class="media-opt hd ${this._composerHd ? 'on' : ''}" data-action="nymMediaHd" aria-pressed="${this._composerHd ? 'true' : 'false'}"><span class="media-opt-hd">HD</span><span>${esc(hdLabel)}</span></button>`
                + `<span class="media-opt-size">${esc(sizeLine)}</span>${onceBtn}${hdNote}${onceNote}`;
            if (typeof this._refreshComposerOffsets === 'function') this._refreshComposerOffsets();
        },

        async sendImagesOverMesh(files) {
            const M = NM();
            const mesh = this._mesh;
            if (!mesh || !mesh.running) { this._mediaNotice(this._mt("The Bluetooth mesh isn't running.")); return; }
            const hd = !!this._composerHd;
            for (const f of files) {
                let file = f;
                if (/^image\//.test(f.type) && !/gif/.test(f.type) && !hd) {
                    file = (await this._compressImage(f, M.LIMITS.meshPhotoMaxDimension, M.LIMITS.meshPhotoQuality)) || f;
                }
                const bytes = new Uint8Array(await file.arrayBuffer());
                const check = M.meshSizeCheck(bytes.length);
                if (!check.ok) {
                    this._mediaNotice(this._mt(M.REASONS.meshTooLarge, { size: M.formatBytes(bytes.length) }));
                    continue;
                }
                const mime = M.baseMime(file.type) || 'application/octet-stream';
                const kind = /^video\//.test(mime) ? 'video' : 'photo';
                const desc = { kind, mime };
                let ok = false;
                try { ok = await mesh.sendFileBroadcast((file.name || ('photo.' + M.extForMime(mime))).slice(0, 120), mime, bytes); } catch (_) { ok = false; }
                if (!ok) { this._mediaNotice(this._mt(M.REASONS.meshTooLarge, { size: M.formatBytes(bytes.length) })); continue; }
                const id = this._storeLocalMedia(new Blob([bytes], { type: mime }), {});
                const now = Date.now();
                const channel = this.currentGeohash;
                this.displayMessage({
                    id: 'mesh-file-' + id, author: this.nym, pubkey: this.pubkey,
                    content: M.attachDescriptor('nymlocal:' + id, desc),
                    created_at: Math.floor(now / 1000), _ms: now, _seq: ++this._msgSeq, timestamp: new Date(now),
                    channel, geohash: channel, isOwn: true, isMesh: true, isPM: false,
                });
            }
        },

        openVideoNoteRecorder() {
            const st = this.mediaFeatureState('round');
            if (st.state === 'off') { this._mediaNotice(this._mt(st.reason)); return; }
            if (document.getElementById('videoNoteModal')) return;
            const modal = document.createElement('div');
            modal.id = 'videoNoteModal';
            modal.className = 'video-note-modal';
            modal.setAttribute('role', 'dialog');
            modal.setAttribute('aria-modal', 'true');
            modal.innerHTML = '<div class="video-note-card">'
                + '<div class="video-note-circle"><video class="video-note-preview" muted playsinline autoplay></video><span class="video-note-ring"></span></div>'
                + '<div class="video-note-time"></div><div class="video-note-hint"></div>'
                + '<div class="video-note-actions">'
                + '<button type="button" class="video-note-cancel" data-action="nymVideoNoteCancel"></button>'
                + '<button type="button" class="video-note-rec" data-action="nymVideoNoteRecord"><span></span></button>'
                + '<button type="button" class="video-note-once" data-action="nymVideoNoteOnce">' + ONCE_SVG + '</button>'
                + '<button type="button" class="video-note-send" data-action="nymVideoNoteSend" disabled></button>'
                + '</div></div>';
            document.body.appendChild(modal);
            this._videoNote = { target: this._mediaTarget(), st, once: false, chunks: [], state: 'idle', maxSeconds: st.maxSeconds || NM().LIMITS.roundMaxSeconds };
            this._renderVideoNote();
            this._startVideoNoteCamera();
        },

        async _startVideoNoteCamera() {
            const vn = this._videoNote;
            if (!vn) return;
            try {
                const size = NM().LIMITS.roundSize;
                vn.stream = await navigator.mediaDevices.getUserMedia({
                    video: { facingMode: 'user', width: { ideal: size }, height: { ideal: size }, aspectRatio: { ideal: 1 } },
                    audio: { echoCancellation: true, noiseSuppression: true },
                });
            } catch (_) {
                this.closeVideoNoteRecorder();
                this._mediaNotice(this._mt("Camera or microphone access was denied, so video notes can't be recorded."));
                return;
            }
            if (this._videoNote !== vn) { vn.stream.getTracks().forEach((t) => t.stop()); return; }
            const v = document.querySelector('#videoNoteModal .video-note-preview');
            if (v) { v.srcObject = vn.stream; v.play().catch(() => { }); }
            this._renderVideoNote();
        },

        _videoNoteRecordToggle() {
            const vn = this._videoNote;
            if (!vn || !vn.stream) return;
            if (vn.state === 'recording') { this._videoNoteStop(); return; }
            if (vn.state !== 'idle') return;
            vn.mime = NM().preferredMime('round', (m) => window.MediaRecorder.isTypeSupported(m));
            try {
                vn.recorder = new MediaRecorder(vn.stream, Object.assign({
                    videoBitsPerSecond: NM().LIMITS.roundVideoBitrate,
                    audioBitsPerSecond: NM().LIMITS.roundAudioBitrate,
                }, vn.mime ? { mimeType: vn.mime } : {}));
            } catch (_) {
                vn.recorder = new MediaRecorder(vn.stream);
            }
            vn.chunks = [];
            vn.recorder.ondataavailable = (e) => { if (e.data && e.data.size) vn.chunks.push(e.data); };
            vn.stopPromise = new Promise((r) => { vn.recorder.onstop = r; });
            vn.recorder.start(500);
            vn.startedAt = Date.now();
            vn.state = 'recording';
            vn.tick = setInterval(() => {
                const secs = (Date.now() - vn.startedAt) / 1000;
                if (secs >= vn.maxSeconds) this._videoNoteStop();
                this._renderVideoNote();
            }, 200);
            this._renderVideoNote();
        },

        async _videoNoteStop() {
            const vn = this._videoNote;
            if (!vn || vn.state !== 'recording') return;
            clearInterval(vn.tick);
            vn.duration = Math.min(vn.maxSeconds, (Date.now() - vn.startedAt) / 1000);
            vn.state = 'stopping';
            try { vn.recorder.stop(); } catch (_) { }
            await vn.stopPromise;
            const type = NM().baseMime(vn.recorder.mimeType || vn.mime) || 'video/webm';
            vn.blob = new Blob(vn.chunks, { type });
            vn.state = 'review';
            vn.stream.getTracks().forEach((t) => t.stop());
            const v = document.querySelector('#videoNoteModal .video-note-preview');
            if (v) {
                v.srcObject = null;
                vn.reviewUrl = URL.createObjectURL(vn.blob);
                v.src = vn.reviewUrl;
                v.loop = true;
                v.muted = true;
                v.play().catch(() => { });
            }
            this._renderVideoNote();
        },

        _videoNoteToggleOnce() {
            const vn = this._videoNote;
            if (!vn) return;
            const st = this.mediaFeatureState('once');
            if (st.state === 'off') { this._mediaNotice(this._mt(st.reason)); return; }
            vn.once = !vn.once;
            this._renderVideoNote();
        },

        async _videoNoteSend() {
            const vn = this._videoNote;
            if (!vn || vn.state !== 'review' || !vn.blob) return;
            const blob = vn.blob;
            const desc = { kind: 'round', mime: NM().baseMime(blob.type) || 'video/webm', duration: vn.duration, size: blob.size };
            const target = vn.target;
            const once = vn.once;
            this.closeVideoNoteRecorder();
            const bytes = new Uint8Array(await blob.arrayBuffer());
            await this._uploadAndSendNote(desc, bytes, target, once, this._mt('Sending video note…'));
        },

        closeVideoNoteRecorder() {
            const vn = this._videoNote;
            this._videoNote = null;
            if (vn) {
                clearInterval(vn.tick);
                try { if (vn.recorder && vn.recorder.state !== 'inactive') vn.recorder.stop(); } catch (_) { }
                if (vn.stream) vn.stream.getTracks().forEach((t) => t.stop());
                if (vn.reviewUrl) { try { URL.revokeObjectURL(vn.reviewUrl); } catch (_) { } }
            }
            const m = document.getElementById('videoNoteModal');
            if (m) m.remove();
        },

        _renderVideoNote() {
            const vn = this._videoNote;
            const m = document.getElementById('videoNoteModal');
            if (!vn || !m) return;
            const secs = vn.state === 'recording' ? (Date.now() - vn.startedAt) / 1000 : (vn.duration || 0);
            m.querySelector('.video-note-time').textContent = NM().formatClock(secs) + ' / ' + NM().formatClock(vn.maxSeconds);
            const p = Math.max(0, Math.min(1, secs / vn.maxSeconds));
            m.querySelector('.video-note-circle').style.setProperty('--p', String(p));
            const hint = m.querySelector('.video-note-hint');
            hint.textContent = vn.state === 'review'
                ? this._mt('Send it, or delete and try again.')
                : (vn.state === 'recording' ? this._mt('Tap to stop. Video notes are up to {max}.', { max: NM().formatClock(vn.maxSeconds) })
                    : this._mt('Tap the button to start recording.'));
            m.classList.toggle('recording', vn.state === 'recording');
            const cancel = m.querySelector('.video-note-cancel');
            cancel.textContent = this._mt(vn.state === 'review' ? 'Delete' : 'Cancel');
            const send = m.querySelector('.video-note-send');
            send.textContent = this._mt('Send');
            send.disabled = vn.state !== 'review';
            const rec = m.querySelector('.video-note-rec');
            rec.setAttribute('aria-label', this._mt(vn.state === 'recording' ? 'Stop recording' : 'Start recording'));
            rec.hidden = vn.state === 'review';
            const onceBtn = m.querySelector('.video-note-once');
            const onceSt = this.mediaFeatureState('once');
            onceBtn.hidden = onceSt.state === 'off';
            onceBtn.classList.toggle('on', !!vn.once);
            onceBtn.setAttribute('aria-pressed', vn.once ? 'true' : 'false');
            onceBtn.setAttribute('aria-label', this._mt('View once'));
            onceBtn.setAttribute('title', this._mt('View once'));
        },
    });

})();
