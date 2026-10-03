(function () {
    const G = (typeof self !== 'undefined' ? self : window);

    const LIMITS = Object.freeze({
        voiceMaxSeconds: 300,
        roundMaxSeconds: 60,
        meshMaxFileBytes: 102400,
        meshVoiceMaxSeconds: 20,
        waveformBars: 40,
        voiceBitrate: 32000,
        roundVideoBitrate: 1000000,
        roundAudioBitrate: 64000,
        roundSize: 480,
        photoMaxDimension: 1600,
        photoQuality: 0.82,
        meshPhotoMaxDimension: 640,
        meshPhotoQuality: 0.6,
        uploadMaxBytes: 50 * 1024 * 1024,
        minVoiceSeconds: 0.5,
    });

    const SPEEDS = Object.freeze([1, 1.5, 2]);
    const SPEED_KEY = 'nym_voice_speed';
    const OPENED_KEY = 'nym_once_opened';
    const REMOTE_OPENED_KEY = 'nym_once_remote_opened';
    const TRANSCRIPTS_KEY = 'nym_voice_transcripts';
    const RECEIPT_OPENED = 'opened';
    const MESH_ONCE_RECEIPT_PREFIX = 'nymonce:';

    const KINDS = ['voice', 'round', 'photo', 'video'];
    const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    const RX_MIME = /^(audio|video|image)\/[a-z0-9.+-]{1,40}$/;
    const RX_DURATION = /^\d{1,4}(\.\d)?$/;
    const RX_SIZE = /^\d{1,10}$/;
    const RX_WAVE = /^[A-Za-z0-9_-]{1,64}$/;
    const RX_ONCE_ID = /^[0-9a-f]{16}$/;
    const RX_KEY = /^[0-9a-f]{64}$/;
    const RX_NONCE = /^[0-9a-f]{24}$/;
    const RX_IN_TEXT = /(https?:\/\/[^\s#<>"]+)#(nym:[A-Za-z0-9=;:.\/_+-]+)/g;
    const RX_LOCAL_IN_TEXT = /nymlocal:([A-Za-z0-9]{1,40})#(nym:[A-Za-z0-9=;:.\/_+-]+)/g;
    const KIND_PREFIX = { voice: 'audio/', round: 'video/', photo: 'image/', video: 'video/' };
    const PORTABLE_VOICE_RATE = 16000;
    const PORTABLE_AUDIO = ['audio/mp4', 'audio/aac', 'audio/mpeg', 'audio/wav'];
    const VOICE_CONVERT = Object.freeze({
        timeoutMs: 8000,
        minPeak: 1e-4,
        slackSeconds: 1.5,
        slackFraction: 0.3,
        probeLength: 1600,
        probeFreq: 440,
        probeAmp: 0.5,
        probeTolerance: 0.02,
    });

    function formatDurationValue(seconds) {
        const d = Math.max(0, Math.min(3600, Number(seconds) || 0));
        return (Math.round(d * 10) / 10).toFixed(1);
    }

    function encodeWaveform(levels) {
        let out = '';
        for (const v of (levels || [])) {
            const n = Math.max(0, Math.min(63, Math.round(Number(v) || 0)));
            out += B64[n];
        }
        return out;
    }

    function decodeWaveform(str) {
        const out = [];
        if (typeof str !== 'string') return out;
        for (const ch of str) {
            const i = B64.indexOf(ch);
            if (i < 0) return [];
            out.push(i);
        }
        return out;
    }

    function computeWaveform(samples, bars) {
        const n = bars || LIMITS.waveformBars;
        const src = Array.isArray(samples) ? samples : Array.from(samples || []);
        const len = src.length;
        const values = new Array(n).fill(0);
        if (!len) return values;
        for (let i = 0; i < n; i++) {
            const start = Math.min(len - 1, Math.floor(i * len / n));
            const end = Math.min(len, Math.max(start + 1, Math.floor((i + 1) * len / n)));
            let peak = 0;
            for (let j = start; j < end; j++) {
                const v = Math.abs(Number(src[j]) || 0);
                if (v > peak) peak = v;
            }
            values[i] = peak;
        }
        let max = 0;
        for (const v of values) if (v > max) max = v;
        if (max <= 0) return values.map(() => 0);
        return values.map(v => Math.round(v / max * 63));
    }

    function dbfsToLevel(db) {
        const d = Number(db);
        if (!isFinite(d)) return 0;
        if (d >= 0) return 1;
        if (d <= -60) return 0;
        return Math.pow(10, d / 20);
    }

    function waveformToImeta(levels) {
        return (levels || []).map(v => Math.round(Math.max(0, Math.min(63, v)) * 100 / 63));
    }

    function encodeDescriptor(d) {
        if (!d || KINDS.indexOf(d.kind) < 0 || !RX_MIME.test(d.mime || '')) return '';
        if (d.mime.indexOf(KIND_PREFIX[d.kind]) !== 0) return '';
        const parts = ['v=1', 'k=' + d.kind, 'm=' + d.mime];
        if (d.duration != null && isFinite(d.duration)) parts.push('d=' + formatDurationValue(d.duration));
        if (d.size != null && isFinite(d.size) && d.size >= 0) parts.push('s=' + Math.floor(d.size));
        if (d.waveform && d.waveform.length) parts.push('w=' + encodeWaveform(d.waveform));
        if (d.once) {
            if (!RX_ONCE_ID.test(d.onceId || '')) return '';
            const hasKey = !!(d.key || d.nonce);
            if (hasKey && (!RX_KEY.test(d.key || '') || !RX_NONCE.test(d.nonce || ''))) return '';
            parts.push('o=1', 'i=' + d.onceId);
            if (hasKey) parts.push('x=' + d.key, 'n=' + d.nonce);
        }
        return 'nym:' + parts.join(';');
    }

    function attachDescriptor(url, d) {
        const enc = encodeDescriptor(d);
        if (!enc || typeof url !== 'string' || !url) return '';
        return url.split('#')[0] + '#' + enc;
    }

    function parseDescriptor(frag) {
        if (typeof frag !== 'string' || frag.indexOf('nym:') !== 0) return null;
        const map = Object.create(null);
        for (const part of frag.slice(4).split(';')) {
            const eq = part.indexOf('=');
            if (eq <= 0) continue;
            const k = part.slice(0, eq);
            if (!(k in map)) map[k] = part.slice(eq + 1);
        }
        if (map.v !== '1') return null;
        const kind = map.k;
        if (KINDS.indexOf(kind) < 0) return null;
        const mime = map.m || '';
        if (!RX_MIME.test(mime) || mime.indexOf(KIND_PREFIX[kind]) !== 0) return null;
        const out = { kind, mime, duration: null, size: null, waveform: [], once: false, onceId: '', key: '', nonce: '' };
        if (map.d != null) {
            if (!RX_DURATION.test(map.d)) return null;
            const dur = parseFloat(map.d);
            if (!(dur >= 0 && dur <= 3600)) return null;
            out.duration = dur;
        }
        if (map.s != null) {
            if (!RX_SIZE.test(map.s)) return null;
            out.size = parseInt(map.s, 10);
        }
        if (map.w != null) {
            if (!RX_WAVE.test(map.w)) return null;
            out.waveform = decodeWaveform(map.w);
        }
        if (map.o != null) {
            if (map.o !== '1' || !RX_ONCE_ID.test(map.i || '')) return null;
            const hasKey = map.x != null || map.n != null;
            if (hasKey && (!RX_KEY.test(map.x || '') || !RX_NONCE.test(map.n || ''))) return null;
            out.once = true;
            out.onceId = map.i;
            out.key = hasKey ? map.x : '';
            out.nonce = hasKey ? map.n : '';
        }
        return out;
    }

    function parseMediaUrl(full) {
        if (typeof full !== 'string') return null;
        const hash = full.indexOf('#');
        if (hash < 0) return null;
        const base = full.slice(0, hash);
        const remote = /^https?:\/\/[^\s#<>"]+$/.test(base);
        if (!remote && !/^nymlocal:[A-Za-z0-9]{1,40}$/.test(base)) return null;
        const d = parseDescriptor(full.slice(hash + 1));
        if (!d) return null;
        if (remote && d.once && !d.key) return null;
        if (remote && (d.kind === 'photo' || d.kind === 'video') && !d.once) return null;
        d.local = !remote;
        d.url = base;
        d.fullUrl = full;
        return d;
    }

    function findMediaNotes(content) {
        const out = [];
        if (typeof content !== 'string' || content.indexOf('#nym:') < 0) return out;
        const scan = (rx) => {
            rx.lastIndex = 0;
            let m;
            while ((m = rx.exec(content)) !== null) {
                const d = parseMediaUrl(m[0]);
                if (d) {
                    d.index = m.index;
                    d.length = m[0].length;
                    out.push(d);
                }
            }
        };
        scan(RX_IN_TEXT);
        scan(RX_LOCAL_IN_TEXT);
        out.sort((a, b) => a.index - b.index);
        return out;
    }

    function imetaTagsForContent(content, fallbacksFor) {
        const tags = [];
        const seen = new Set();
        for (const d of findMediaNotes(content)) {
            if (d.once || seen.has(d.fullUrl) || d.url.indexOf('nymlocal:') === 0) continue;
            seen.add(d.fullUrl);
            const tag = ['imeta', 'url ' + d.fullUrl, 'm ' + d.mime];
            if (d.size != null) tag.push('size ' + d.size);
            if (d.duration != null) tag.push('duration ' + formatDurationValue(d.duration));
            if (d.kind === 'voice' && d.waveform.length) tag.push('waveform ' + waveformToImeta(d.waveform).join(' '));
            const mirrors = typeof fallbacksFor === 'function' ? (fallbacksFor(d.url) || []) : [];
            for (const mu of mirrors) tag.push('fallback ' + mu);
            tags.push(tag);
        }
        return tags;
    }

    function stripMediaNotes(content) {
        if (typeof content !== 'string') return '';
        let out = content;
        const found = findMediaNotes(content);
        for (let i = found.length - 1; i >= 0; i--) {
            out = out.slice(0, found[i].index) + out.slice(found[i].index + found[i].length);
        }
        return out;
    }

    const ONCE_LABELS = {
        photo: 'View-once photo',
        video: 'View-once video',
        voice: 'View-once voice message',
        round: 'View-once video',
    };

    function onceLabel(kind) {
        return ONCE_LABELS[kind] || ONCE_LABELS.photo;
    }

    function plainLabel(d, tr) {
        if (!d) return '';
        const T = typeof tr === 'function' ? tr : (x) => x;
        if (d.once) return T(onceLabel(d.kind));
        const dur = d.duration != null ? ' (' + formatClock(d.duration) + ')' : '';
        if (d.kind === 'voice') return T('Voice message') + dur;
        if (d.kind === 'round') return T('Video note') + dur;
        if (d.kind === 'photo') return T('Photo');
        if (d.kind === 'video') return T('Video');
        return '';
    }

    function previewText(content, tr) {
        if (typeof content !== 'string') return '';
        const found = findMediaNotes(content);
        if (!found.length) return content;
        let out = content;
        for (let i = found.length - 1; i >= 0; i--) {
            const d = found[i];
            const label = plainLabel(d, tr);
            let start = d.index;
            const prefix = onceLabel(d.kind) + ': ';
            if (d.once && out.slice(Math.max(0, start - prefix.length), start) === prefix) start -= prefix.length;
            out = out.slice(0, start) + label + out.slice(d.index + d.length);
        }
        return out.replace(/[ \t]+/g, ' ').replace(/ *\n */g, '\n').trim();
    }

    function onceContent(kind, fullUrl) {
        return onceLabel(kind) + ': ' + fullUrl;
    }

    function formatClock(seconds) {
        const s = Math.max(0, Math.floor(Number(seconds) || 0));
        const m = Math.floor(s / 60);
        const r = s % 60;
        return m + ':' + (r < 10 ? '0' : '') + r;
    }

    function formatBytes(n) {
        const b = Math.max(0, Number(n) || 0);
        if (b < 1024) return b + ' B';
        if (b < 1024 * 1024) return (Math.round(b / 102.4) / 10).toFixed(1) + ' KB';
        return (Math.round(b / (1024 * 102.4)) / 10).toFixed(1) + ' MB';
    }

    function nextSpeed(current) {
        const i = SPEEDS.indexOf(Number(current));
        return SPEEDS[(i + 1) % SPEEDS.length];
    }

    function parseSpeed(raw) {
        const v = Number(raw);
        return SPEEDS.indexOf(v) >= 0 ? v : 1;
    }

    function speedLabel(v) {
        return (v === 1.5 ? '1.5' : String(Math.round(v))) + '×';
    }

    function scaledDimensions(w, h, max) {
        const W = Math.max(0, Math.floor(Number(w) || 0));
        const H = Math.max(0, Math.floor(Number(h) || 0));
        if (!W || !H) return { width: W, height: H };
        const longest = Math.max(W, H);
        if (longest <= max) return { width: W, height: H };
        const scale = max / longest;
        return { width: Math.max(1, Math.round(W * scale)), height: Math.max(1, Math.round(H * scale)) };
    }

    function extForMime(mime) {
        const base = String(mime || '').split(';')[0].trim().toLowerCase();
        const map = {
            'audio/mp4': 'm4a', 'audio/aac': 'aac', 'audio/webm': 'webm', 'audio/ogg': 'ogg', 'audio/mpeg': 'mp3', 'audio/wav': 'wav',
            'video/mp4': 'mp4', 'video/webm': 'webm', 'video/quicktime': 'mov',
            'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'image/gif': 'gif',
        };
        return map[base] || 'bin';
    }

    function baseMime(mime) {
        return String(mime || '').split(';')[0].trim().toLowerCase();
    }

    function mimeCodecs(mime) {
        const m = /codecs\s*=\s*"?([^";]+)"?/i.exec(String(mime || ''));
        return m ? m[1].trim().toLowerCase() : '';
    }

    function isPortableVoiceMime(recorded, requested) {
        const base = baseMime(recorded) || baseMime(requested);
        if (PORTABLE_AUDIO.indexOf(base) < 0) return false;
        const codecs = mimeCodecs(recorded) || (baseMime(requested) === base ? mimeCodecs(requested) : '');
        return !/opus|vorbis|flac/.test(codecs);
    }

    function encodeWav(samples, sampleRate) {
        const src = samples || [];
        const n = src.length;
        const rate = Math.max(1, Math.floor(Number(sampleRate) || PORTABLE_VOICE_RATE));
        const out = new Uint8Array(44 + n * 2);
        const v = new DataView(out.buffer);
        const str = (o, s) => { for (let i = 0; i < s.length; i++) out[o + i] = s.charCodeAt(i); };
        str(0, 'RIFF');
        v.setUint32(4, 36 + n * 2, true);
        str(8, 'WAVE');
        str(12, 'fmt ');
        v.setUint32(16, 16, true);
        v.setUint16(20, 1, true);
        v.setUint16(22, 1, true);
        v.setUint32(24, rate, true);
        v.setUint32(28, rate * 2, true);
        v.setUint16(32, 2, true);
        v.setUint16(34, 16, true);
        str(36, 'data');
        v.setUint32(40, n * 2, true);
        for (let i = 0; i < n; i++) {
            const x = Math.max(-1, Math.min(1, Number(src[i]) || 0));
            v.setInt16(44 + i * 2, x < 0 ? Math.round(x * 32768) : Math.round(x * 32767), true);
        }
        return out;
    }

    const MODEL_DOWNLOAD = Object.freeze({ pollMs: 1000, stallMs: 20000, maxMs: 600000 });

    function modelDownloadStage(s, limits) {
        const st = s || {};
        const lim = Object.assign({}, MODEL_DOWNLOAD, limits || {});
        if (st.canceled) return 'canceled';
        if (st.installResult === false) return 'failed';
        if (st.status === 'available' || st.installResult === true) return 'done';
        if (st.status === 'unavailable') return 'failed';
        const elapsed = Number(st.elapsedMs) || 0;
        if (elapsed >= lim.maxMs) return 'timeout';
        if (st.status === 'downloading' || st.sawDownloading) return 'downloading';
        if (elapsed >= lim.stallMs) return 'stalled';
        return 'starting';
    }

    function checkPortableVoice(samples, rate, expectedSeconds) {
        const n = samples && samples.length ? samples.length : 0;
        if (!n) return { ok: false, reason: 'empty' };
        let peak = 0;
        for (let i = 0; i < n; i++) {
            const x = samples[i];
            if (typeof x !== 'number' || !isFinite(x)) return { ok: false, reason: 'nan' };
            const a = Math.abs(x);
            if (a > peak) peak = a;
        }
        if (peak < VOICE_CONVERT.minPeak) return { ok: false, reason: 'silent' };
        const want = Number(expectedSeconds);
        if (want > 0) {
            const got = n / Math.max(1, Number(rate) || PORTABLE_VOICE_RATE);
            const slack = Math.max(VOICE_CONVERT.slackSeconds, want * VOICE_CONVERT.slackFraction);
            if (Math.abs(got - want) > slack) return { ok: false, reason: 'length' };
        }
        return { ok: true, reason: '' };
    }

    function voiceProbeSignal() {
        const n = VOICE_CONVERT.probeLength;
        const out = new Float32Array(n);
        for (let i = 0; i < n; i++) {
            out[i] = VOICE_CONVERT.probeAmp * Math.sin(2 * Math.PI * VOICE_CONVERT.probeFreq * i / PORTABLE_VOICE_RATE);
        }
        return out;
    }

    function voiceProbeMatches(expected, actual) {
        if (!expected || !actual || actual.length < expected.length) return false;
        for (let i = 0; i < expected.length; i++) {
            const a = actual[i];
            if (typeof a !== 'number' || !isFinite(a)) return false;
            if (Math.abs(a - expected[i]) > VOICE_CONVERT.probeTolerance) return false;
        }
        return true;
    }

    function meshFileName(d) {
        if (!d || KINDS.indexOf(d.kind) < 0) return '';
        if ((d.kind === 'photo' || d.kind === 'video') && !d.once) return '';
        const parts = ['nym', 'k=' + d.kind];
        if (d.duration != null && isFinite(d.duration)) parts.push('d=' + Math.round(Math.max(0, Math.min(3600, d.duration)) * 10));
        if (d.waveform && d.waveform.length) parts.push('w=' + encodeWaveform(d.waveform));
        if (d.once) {
            if (!RX_ONCE_ID.test(d.onceId || '')) return '';
            parts.push('o=' + d.onceId);
        }
        return parts.join('.') + '.' + extForMime(d.mime);
    }

    function parseMeshFileName(name, mime) {
        if (typeof name !== 'string') return null;
        const segs = name.split('.');
        if (segs.length < 3 || segs[0] !== 'nym') return null;
        segs.pop();
        const map = Object.create(null);
        for (const s of segs.slice(1)) {
            const eq = s.indexOf('=');
            if (eq <= 0) continue;
            map[s.slice(0, eq)] = s.slice(eq + 1);
        }
        const kind = map.k;
        if (KINDS.indexOf(kind) < 0) return null;
        const m = baseMime(mime);
        if (!RX_MIME.test(m) || m.indexOf(KIND_PREFIX[kind]) !== 0) return null;
        const out = { kind, mime: m, duration: null, waveform: [], once: false, onceId: '' };
        if (map.d != null) {
            if (!/^\d{1,5}$/.test(map.d)) return null;
            out.duration = Math.min(3600, parseInt(map.d, 10) / 10);
        }
        if (map.w != null) {
            if (!RX_WAVE.test(map.w)) return null;
            out.waveform = decodeWaveform(map.w);
        }
        if (map.o != null) {
            if (!RX_ONCE_ID.test(map.o)) return null;
            out.once = true;
            out.onceId = map.o;
        }
        if ((kind === 'photo' || kind === 'video') && !out.once) return null;
        return out;
    }

    function meshOnceReceiptId(onceId) {
        return MESH_ONCE_RECEIPT_PREFIX + onceId;
    }

    function parseMeshOnceReceiptId(id) {
        if (typeof id !== 'string' || id.indexOf(MESH_ONCE_RECEIPT_PREFIX) !== 0) return '';
        const v = id.slice(MESH_ONCE_RECEIPT_PREFIX.length);
        return RX_ONCE_ID.test(v) ? v : '';
    }

    const REASONS = Object.freeze({
        voiceOffline: "You're offline. Voice messages need the internet or the Bluetooth mesh.",
        voiceNoMic: "This device can't record audio here.",
        voiceMesh: 'Over the Bluetooth mesh, voice messages are capped at 20 seconds and arrive slowly.',
        roundOffline: "You're offline. Video notes need the internet.",
        roundMesh: 'Video notes are too large for the Bluetooth mesh. Send a voice message instead.',
        roundNoCamera: 'No camera is available for video notes.',
        onceChannel: 'View once is only for private messages and groups.',
        onceOffline: "You're offline. View-once media needs the internet or the Bluetooth mesh.",
        onceMeshUnsupported: "This app can't send direct messages over the Bluetooth mesh, so view once is unavailable here.",
        onceMesh: 'Sent over the encrypted Bluetooth mesh, up to 100 KB.',
        hdOffline: "You're offline. Media needs the internet or the Bluetooth mesh.",
        hdMesh: 'The Bluetooth mesh is slow and carries at most 100 KB per file, so original quality usually will not fit.',
        meshTooLarge: 'This file is {size}. The Bluetooth mesh carries at most 100 KB per file.',
        transcribeUnavailable: "On-device transcription isn't available on this device.",
    });

    function featureState(feature, ctx) {
        const c = ctx || {};
        const route = c.route || 'online';
        const surface = c.surface || 'channel';
        const ok = (extra) => Object.assign({ state: 'ok', reason: '' }, extra || {});
        const warn = (reason, extra) => Object.assign({ state: 'warn', reason }, extra || {});
        const off = (reason) => ({ state: 'off', reason });
        switch (feature) {
            case 'voice':
                if (c.canRecordAudio === false) return off(REASONS.voiceNoMic);
                if (route === 'offline') return off(REASONS.voiceOffline);
                if (route === 'mesh') return warn(REASONS.voiceMesh, { maxSeconds: LIMITS.meshVoiceMaxSeconds, maxBytes: LIMITS.meshMaxFileBytes });
                return ok({ maxSeconds: LIMITS.voiceMaxSeconds, maxBytes: LIMITS.uploadMaxBytes });
            case 'round':
                if (c.canRecordVideo === false) return off(REASONS.roundNoCamera);
                if (route === 'offline') return off(REASONS.roundOffline);
                if (route === 'mesh') return off(REASONS.roundMesh);
                return ok({ maxSeconds: LIMITS.roundMaxSeconds, maxBytes: LIMITS.uploadMaxBytes });
            case 'once':
                if (surface === 'channel') return off(REASONS.onceChannel);
                if (route === 'offline') return off(REASONS.onceOffline);
                if (route === 'mesh') {
                    if (surface !== 'dm' || !c.meshDm) return off(REASONS.onceMeshUnsupported);
                    return warn(REASONS.onceMesh, { maxBytes: LIMITS.meshMaxFileBytes });
                }
                return ok({ maxBytes: LIMITS.uploadMaxBytes });
            case 'hd':
                if (route === 'offline') return off(REASONS.hdOffline);
                if (route === 'mesh') return warn(REASONS.hdMesh, { maxBytes: LIMITS.meshMaxFileBytes });
                return ok({ maxBytes: LIMITS.uploadMaxBytes });
            case 'transcribe':
                if (c.canTranscribe === false) return off(c.transcribeReason || REASONS.transcribeUnavailable);
                return ok();
            default:
                return off('');
        }
    }

    function meshSizeCheck(bytes) {
        const n = Math.max(0, Number(bytes) || 0);
        if (n <= LIMITS.meshMaxFileBytes) return { ok: true, reason: '' };
        return { ok: false, reason: REASONS.meshTooLarge.replace('{size}', formatBytes(n)) };
    }

    function preferredMime(kind, isTypeSupported) {
        const test = typeof isTypeSupported === 'function' ? isTypeSupported : () => false;
        const list = kind === 'round'
            ? ['video/mp4;codecs=avc1.42E01E,mp4a.40.2', 'video/mp4', 'video/webm;codecs=vp9,opus', 'video/webm;codecs=vp8,opus', 'video/webm']
            : ['audio/mp4;codecs=mp4a.40.2', 'audio/mp4', 'audio/webm;codecs=opus', 'audio/ogg;codecs=opus', 'audio/webm'];
        for (const m of list) {
            try { if (test(m)) return m; } catch (_) { }
        }
        return '';
    }

    function hexToBytes(hex) {
        const out = new Uint8Array(hex.length >> 1);
        for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
        return out;
    }

    function bytesToHex(bytes) {
        return Array.from(bytes, b => b.toString(16).padStart(2, '0')).join('');
    }

    function randomHex(n, cryptoImpl) {
        const c = cryptoImpl || G.crypto;
        const b = new Uint8Array(n);
        c.getRandomValues(b);
        return bytesToHex(b);
    }

    function newOnceSecret(cryptoImpl) {
        return { onceId: randomHex(8, cryptoImpl), key: randomHex(32, cryptoImpl), nonce: randomHex(12, cryptoImpl) };
    }

    async function encryptOnce(bytes, keyHex, nonceHex, cryptoImpl) {
        const c = (cryptoImpl || G.crypto).subtle;
        const k = await c.importKey('raw', hexToBytes(keyHex), { name: 'AES-GCM' }, false, ['encrypt']);
        const ct = await c.encrypt({ name: 'AES-GCM', iv: hexToBytes(nonceHex) }, k, bytes);
        return new Uint8Array(ct);
    }

    async function decryptOnce(bytes, keyHex, nonceHex, cryptoImpl) {
        const c = (cryptoImpl || G.crypto).subtle;
        const k = await c.importKey('raw', hexToBytes(keyHex), { name: 'AES-GCM' }, false, ['decrypt']);
        const pt = await c.decrypt({ name: 'AES-GCM', iv: hexToBytes(nonceHex) }, k, bytes);
        return new Uint8Array(pt);
    }

    function readJsonMap(storage, key) {
        try {
            const raw = storage && storage.getItem(key);
            const v = raw ? JSON.parse(raw) : {};
            return v && typeof v === 'object' && !Array.isArray(v) ? v : {};
        } catch (_) {
            return {};
        }
    }

    function writeJsonMap(storage, key, map, cap) {
        try {
            const keys = Object.keys(map);
            if (cap && keys.length > cap) {
                keys.sort((a, b) => (map[a] && map[a].t || 0) - (map[b] && map[b].t || 0));
                for (const k of keys.slice(0, keys.length - cap)) delete map[k];
            }
            storage && storage.setItem(key, JSON.stringify(map));
        } catch (_) { }
    }

    function createOnceStore(storage) {
        return {
            isOpened(onceId) { return !!readJsonMap(storage, OPENED_KEY)[onceId]; },
            markOpened(onceId, nowMs) {
                const m = readJsonMap(storage, OPENED_KEY);
                if (m[onceId]) return false;
                m[onceId] = { t: nowMs || Date.now() };
                writeJsonMap(storage, OPENED_KEY, m, 2000);
                return true;
            },
            remoteOpenedBy(onceId) {
                const v = readJsonMap(storage, REMOTE_OPENED_KEY)[onceId];
                return v && Array.isArray(v.by) ? v.by.slice() : [];
            },
            markRemoteOpened(onceId, byPubkey, nowMs) {
                const m = readJsonMap(storage, REMOTE_OPENED_KEY);
                const cur = m[onceId] && Array.isArray(m[onceId].by) ? m[onceId] : { by: [], t: 0 };
                const who = String(byPubkey || '');
                if (cur.by.indexOf(who) >= 0) return false;
                cur.by.push(who);
                cur.t = nowMs || Date.now();
                m[onceId] = cur;
                writeJsonMap(storage, REMOTE_OPENED_KEY, m, 2000);
                return true;
            },
        };
    }

    function createTranscriptStore(storage) {
        return {
            get(key) {
                const v = readJsonMap(storage, TRANSCRIPTS_KEY)[key];
                return v && typeof v.text === 'string' ? v.text : null;
            },
            set(key, text, nowMs) {
                const m = readJsonMap(storage, TRANSCRIPTS_KEY);
                m[key] = { text: String(text || '').slice(0, 20000), t: nowMs || Date.now() };
                writeJsonMap(storage, TRANSCRIPTS_KEY, m, 200);
            },
            count() {
                return Object.keys(readJsonMap(storage, TRANSCRIPTS_KEY)).length;
            },
            clear() {
                try { storage.removeItem(TRANSCRIPTS_KEY); } catch (_) { }
            },
        };
    }

    G.NymMediaNotes = {
        LIMITS, SPEEDS, SPEED_KEY, OPENED_KEY, REMOTE_OPENED_KEY, TRANSCRIPTS_KEY, RECEIPT_OPENED, REASONS,
        formatDurationValue, encodeWaveform, decodeWaveform, computeWaveform, dbfsToLevel, waveformToImeta,
        encodeDescriptor, attachDescriptor, parseDescriptor, parseMediaUrl, findMediaNotes,
        imetaTagsForContent, stripMediaNotes, previewText, plainLabel, onceLabel, onceContent,
        formatClock, formatBytes, nextSpeed, parseSpeed, speedLabel, scaledDimensions,
        extForMime, baseMime, mimeCodecs, isPortableVoiceMime, encodeWav, PORTABLE_VOICE_RATE,
        VOICE_CONVERT, checkPortableVoice, MODEL_DOWNLOAD, modelDownloadStage, voiceProbeSignal, voiceProbeMatches, meshFileName, parseMeshFileName, meshOnceReceiptId, parseMeshOnceReceiptId,
        featureState, meshSizeCheck, preferredMime,
        hexToBytes, bytesToHex, randomHex, newOnceSecret, encryptOnce, decryptOnce,
        createOnceStore, createTranscriptStore,
    };
})();
