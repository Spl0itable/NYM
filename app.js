// Guided Tutorial
(function () {
    const state = {
        steps: [],
        idx: 0,
        started: false,
        overlay: null,
        card: null,
        highlight: null,
        elTitle: null,
        elBody: null,
        elProgress: null,
        btnPrev: null,
        btnNext: null,
        btnSkip: null,
        sidebarInitiallyOpen: null,
        _onResize: null,
        _onScroll: null
    };

    function $(sel) { return document.querySelector(sel); }

    function buildSteps() {
        state.steps = [
            {
                title: 'NYM Tutorial',
                body: 'Take a quick tour so you know what’s where. You can skip anytime. And use the /help command in any channel to learn more.',
                selector: null
            },
            {
                title: 'Your Nym',
                body: 'Tap here to edit your nickname for this session.',
                selector: '.nym-display',
                onBefore: ensureSidebarOpenOnMobile
            },
            {
                title: 'Connection',
                body: 'The current relay connection status.',
                selector: '.status-indicator',
                onBefore: ensureSidebarOpenOnMobile
            },
            {
                title: 'Main Menu',
                body: 'Create or join a channel. Buy addon packs in the shop to change the styling of your messages and nickname. Edit settings such as sorting geohash channels by proximity, adding a Bitcoin lightning address, changing the app\'s theme, manage blocked users and keywords, and more. Logout to terminate session and start anew.',
                selector: (window.innerWidth > 768 ? '.header-actions' : '.sidebar-actions'),
                onBefore: () => { if (window.innerWidth <= 768) return ensureSidebarOpenOnMobile(); }
            },
            {
                title: 'Channels',
                body: 'Browse and switch channels. Each channel type is denoted by a unique, colorful badge (Ephemeral is blue, Geohash is yellow, Public community is green, and Private community is pink). Use the search or "+ Channel" button in menu to join or create. Note: only users who used a Nostr login method can view public/private communities.',
                selector: '#channelList',
                onBefore: ensureSidebarOpenOnMobile
            },
            {
                title: 'Explore Geohash',
                body: 'Tap the globe to explore geohash channels on a 3D globe.',
                selector: '.discover-icon',
                onBefore: ensureSidebarOpenOnMobile
            },
            {
                title: 'Private Messages',
                body: 'Your one‑on‑one, end-to-end encrypted messages live here.',
                selector: '#pmList',
                onBefore: ensureSidebarOpenOnMobile
            },
            {
                title: 'Active Nyms',
                body: 'See who is currently active. Tap a nym to PM them.',
                selector: '#userList',
                onBefore: ensureSidebarOpenOnMobile
            },
            {
                title: 'Messages',
                body: 'Channel messages appear here. Tap a nym\'s nickname for quick actions such as to react with emoji, zap Bitcoin, PM, mention, block and more from the context menu.',
                selector: '#messagesContainer',
                onBefore: ensureSidebarClosedOnMobile
            },
            {
                title: 'Compose',
                body: 'Type your message, add emoji or upload an image, then SEND. Markdown is supported. You can also type commands for other actions, such as creating an away message and many more.',
                selector: '.input-container'
            },
            {
                title: 'Share',
                body: 'Invite others to a channel with a shareable link.',
                selector: '#shareChannelBtn'
            },
            {
                title: 'All set!',
                body: 'That\'s it. Enjoy NYM! Check out all of the available commands by typing the /help command in any channel.',
                selector: null,
                final: true
            }
        ];
    }

    function ensureSidebarOpenOnMobile() {
        if (window.innerWidth > 768) return Promise.resolve();

        const sidebar = $('#sidebar');
        const overlay = $('#mobileOverlay');
        if (!sidebar) return Promise.resolve();

        // Already open
        if (sidebar.classList.contains('open')) return Promise.resolve();

        // Open it and wait for transition to complete
        sidebar.classList.add('open');
        overlay && overlay.classList.add('active');

        return new Promise((resolve) => {
            let settled = false;

            const done = () => {
                if (settled) return;
                settled = true;
                sidebar.removeEventListener('transitionend', onEnd);
                clearTimeout(timer);
                // small delay to allow layout to settle before measuring
                setTimeout(() => resolve(), 30);
            };

            const onEnd = (e) => {
                if (e.propertyName === 'transform') {
                    done();
                }
            };

            sidebar.addEventListener('transitionend', onEnd, { once: true });
            // Fallback timeout in case transitionend doesn’t fire
            const timer = setTimeout(done, 400);
        });
    }

    // Close the sidebar on mobile and wait for transition
    function ensureSidebarClosedOnMobile() {
        if (window.innerWidth > 768) return Promise.resolve();

        const sidebar = $('#sidebar');
        const overlay = $('#mobileOverlay');
        if (!sidebar) return Promise.resolve();

        // Already closed
        if (!sidebar.classList.contains('open')) {
            overlay && overlay.classList.remove('active');
            return Promise.resolve();
        }

        // Close it and wait for transition to complete
        sidebar.classList.remove('open');
        overlay && overlay.classList.remove('active');

        return new Promise((resolve) => {
            let settled = false;

            const done = () => {
                if (settled) return;
                settled = true;
                sidebar.removeEventListener('transitionend', onEnd);
                clearTimeout(timer);
                // small delay to allow layout to settle before measuring
                setTimeout(() => resolve(), 30);
            };

            const onEnd = (e) => {
                if (e.propertyName === 'transform') {
                    done();
                }
            };

            sidebar.addEventListener('transitionend', onEnd, { once: true });
            // Fallback timeout
            const timer = setTimeout(done, 400);
        });
    }

    function restoreSidebarAfterTutorial() {
        if (window.innerWidth <= 768) {
            const sidebar = $('#sidebar');
            const overlay = $('#mobileOverlay');
            if (!sidebar) return;

            const initiallyOpen = !!state.sidebarInitiallyOpen;
            const currentlyOpen = sidebar.classList.contains('open');

            // Restore to the initial open/closed state
            if (initiallyOpen && !currentlyOpen) {
                sidebar.classList.add('open');
                overlay && overlay.classList.add('active');
            } else if (!initiallyOpen && currentlyOpen) {
                sidebar.classList.remove('open');
                overlay && overlay.classList.remove('active');
            }
        }
    }

    function getTargetEl(step) {
        if (!step.selector) return null;
        if (typeof step.selector === 'function') {
            const resolvedSelector = step.selector();
            return resolvedSelector ? $(resolvedSelector) : null;
        }
        return $(step.selector) || null;
    }

    function positionStep() {
        const step = state.steps[state.idx];
        const target = getTargetEl(step);
        const highlight = state.highlight;
        const card = state.card;

        // Reset display
        highlight.style.display = 'none';

        // If there is a target, try to highlight and position near it
        if (target && target.getBoundingClientRect) {
            const rect = target.getBoundingClientRect();

            // If target is off-screen, scroll into view then re-position
            const fullyOutVert = rect.bottom < 0 || rect.top > window.innerHeight;
            const fullyOutHorz = rect.right < 0 || rect.left > window.innerWidth;
            if (fullyOutVert || fullyOutHorz) {
                try {
                    target.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'center' });
                } catch (_) { }
                setTimeout(positionStep, 250);
                return;
            }

            const pad = 8;
            const hlLeft = Math.max(8, rect.left - pad);
            const hlTop = Math.max(8, rect.top - pad);
            const hlWidth = Math.min(window.innerWidth - hlLeft - 8, rect.width + pad * 2);
            const hlHeight = Math.min(window.innerHeight - hlTop - 8, rect.height + pad * 2);

            highlight.style.display = 'block';
            highlight.style.left = `${hlLeft}px`;
            highlight.style.top = `${hlTop}px`;
            highlight.style.width = `${hlWidth}px`;
            highlight.style.height = `${hlHeight}px`;

            // Place card relative to target
            card.style.visibility = 'hidden';
            card.style.left = '12px';
            card.style.top = '12px';

            // Wait a frame to measure
            requestAnimationFrame(() => {
                const cRect = card.getBoundingClientRect();
                const spaceBelow = window.innerHeight - rect.bottom;
                const spaceAbove = rect.top;

                let top;
                if (spaceBelow > cRect.height + 16) {
                    top = rect.bottom + 12;
                } else if (spaceAbove > cRect.height + 16) {
                    top = rect.top - cRect.height - 12;
                } else {
                    // fallback: bottom area
                    top = Math.min(window.innerHeight - cRect.height - 12, Math.max(12, rect.bottom + 12));
                }

                let left = rect.left + (rect.width - cRect.width) / 2;
                left = Math.max(12, Math.min(left, window.innerWidth - cRect.width - 12));

                card.style.left = `${left}px`;
                card.style.top = `${top}px`;
                card.style.visibility = 'visible';
            });
        } else {
            // Center the card for generic/welcome/final steps
            highlight.style.display = 'none';
            card.style.visibility = 'hidden';
            requestAnimationFrame(() => {
                const cRect = card.getBoundingClientRect();
                const left = Math.max(12, (window.innerWidth - cRect.width) / 2);
                const top = Math.max(12, (window.innerHeight - cRect.height) / 2);
                card.style.left = `${left}px`;
                card.style.top = `${top}px`;
                card.style.visibility = 'visible';
            });
        }
    }

    function renderStep() {
        const step = state.steps[state.idx];

        const updateAndPosition = () => {
            state.elTitle.textContent = step.title || 'NYM';
            state.elBody.textContent = step.body || '';
            state.elProgress.textContent = `Step ${state.idx + 1} of ${state.steps.length}`;

            state.btnPrev.disabled = state.idx === 0;
            state.btnNext.textContent = (step.final || state.idx === state.steps.length - 1) ? 'Done' : 'Next';

            positionStep();
        };

        if (step.onBefore && typeof step.onBefore === 'function') {
            try {
                const maybe = step.onBefore();
                if (maybe && typeof maybe.then === 'function') {
                    return maybe.then(updateAndPosition);
                }
            } catch (_) {
                // fall through to update
            }
        }
        updateAndPosition();
    }

    function nextStep() {
        const last = state.steps.length - 1;
        if (state.idx >= last) {
            endTutorial(true);
            return;
        }
        state.idx++;
        // Skip steps if target not found
        skipIfTargetMissingForward();
    }

    function prevStep() {
        if (state.idx <= 0) {
            renderStep();
            return;
        }
        state.idx--;
        skipIfTargetMissingBackward();
    }

    function skipIfTargetMissingForward() {
        // Move forward to first step that has a valid target (or no selector)
        let guard = 0;
        while (guard++ < state.steps.length) {
            const step = state.steps[state.idx];
            const target = getTargetEl(step);
            if (!step.selector || (target && target.getBoundingClientRect)) break;
            if (state.idx >= state.steps.length - 1) break;
            state.idx++;
        }
        renderStep();
    }

    function skipIfTargetMissingBackward() {
        // Move backward to first step that has a valid target (or no selector)
        let guard = 0;
        while (guard++ < state.steps.length) {
            const step = state.steps[state.idx];
            const target = getTargetEl(step);
            if (!step.selector || (target && target.getBoundingClientRect)) break;
            if (state.idx <= 0) break;
            state.idx--;
        }
        renderStep();
    }

    function startTutorial() {
        if (state.started) return;
        // Don’t start while the initial setup modal is open
        const setupActive = document.getElementById('setupModal')?.classList.contains('active');
        if (setupActive) return;

        buildSteps();

        state.overlay = document.getElementById('tutorialOverlay');
        state.card = document.getElementById('tutorialCard');
        state.highlight = document.getElementById('tutorialHighlight');
        state.elTitle = document.getElementById('tutorialTitle');
        state.elBody = document.getElementById('tutorialBody');
        state.elProgress = document.getElementById('tutorialProgress');
        state.btnPrev = document.getElementById('tutorialPrevBtn');
        state.btnNext = document.getElementById('tutorialNextBtn');
        state.btnSkip = document.getElementById('tutorialSkipBtn');

        state.sidebarInitiallyOpen = document.getElementById('sidebar')?.classList.contains('open');

        state.overlay.classList.add('active');
        state.overlay.style.display = 'flex';
        state.started = true;
        state.idx = 0;

        // Wire events
        state.btnPrev.onclick = prevStep;
        state.btnNext.onclick = () => {
            const isFinal = state.idx === state.steps.length - 1 || state.steps[state.idx].final;
            if (isFinal) endTutorial(true);
            else nextStep();
        };
        state.btnSkip.onclick = () => endTutorial(true);
        state._onResize = () => positionStep();
        state._onScroll = () => positionStep();
        window.addEventListener('resize', state._onResize);
        window.addEventListener('scroll', state._onScroll, true);
        document.addEventListener('keydown', keyHandler);

        renderStep();
    }

    function keyHandler(e) {
        if (!state.started) return;
        if (e.key === 'Escape') {
            endTutorial(true);
        } else if (e.key === 'ArrowRight' || e.key === 'Enter') {
            state.btnNext.click();
        } else if (e.key === 'ArrowLeft') {
            state.btnPrev.click();
        }
    }

    function endTutorial(markSeen) {
        // Hide
        state.overlay?.classList.remove('active');
        if (state.overlay) state.overlay.style.display = 'none';
        if (state.highlight) state.highlight.style.display = 'none';

        // Save flag
        if (markSeen) {
            try { localStorage.setItem('nym_tutorial_seen', 'true'); } catch (_) { }
        }

        // Clean up
        window.removeEventListener('resize', state._onResize);
        window.removeEventListener('scroll', state._onScroll, true);
        document.removeEventListener('keydown', keyHandler);

        restoreSidebarAfterTutorial();

        state.started = false;
    }

    // Expose helper to app
    window.maybeStartTutorial = function (force = false) {
        try {
            if (!force) {
                const seen = localStorage.getItem('nym_tutorial_seen') === 'true';
                if (seen) return;
            }
            // Delay a bit to let UI settle after login/restore
            setTimeout(() => startTutorial(), 300);
        } catch (_) {
            setTimeout(() => startTutorial(), 300);
        }
    };
})();

// NYM - Ephemeral Nostr Chat
class NYM {
    constructor() {
        this.relayPool = new Map();
        this.blacklistedRelays = new Set();
        this.relayKinds = new Map();
        this.relayVerificationTimeout = 10000;
        this.monitorRelays = ['wss://relay.nostr.watch', 'wss://monitorlizard.nostr1.com'];
        this.broadcastRelays = [
            'wss://relay.damus.io',
            'wss://offchain.pub',
            'wss://relay.primal.net',
            'wss://nos.lol',
            'wss://nostr21.com',
            'wss://sendit.nosflare.com',
            'wss://a.nos.lol',
            'wss://adre.su',
            'wss://alien.macneilmediagroup.com',
            'wss://articles.layer3.news',
            'wss://black.nostrcity.club',
            'wss://bostr.bitcointxoko.com',
            'wss://bostr.shop',
            'wss://bostr.syobon.net',
            'wss://bucket.coracle.social',
            'wss://chorus.pjv.me',
            'wss://communities.nos.social',
            'wss://cyberspace.nostr1.com',
            'wss://dev-nostr.bityacht.io',
            'wss://dev-relay.lnfi.network',
            'wss://fanfares.nostr1.com',
            'wss://freelay.sovbit.host',
            'wss://gnostr.com',
            'wss://inbox.azzamo.net',
            'wss://ithurtswhenip.ee',
            'wss://khatru.nostrver.se',
            'wss://kitchen.zap.cooking',
            'wss://knostr.neutrine.com',
            'wss://librerelay.aaroniumii.com',
            'wss://multiplexer.huszonegy.world',
            'wss://n.ok0.org',
            'wss://no.str.cr',
            'wss://nostrelites.org',
            'wss://nostr-01.yakihonne.com',
            'wss://nostr-02.dorafactory.org',
            'wss://nostr-02.yakihonne.com',
            'wss://nostr-03.dorafactory.org',
            'wss://nostr-1.nbo.angani.co',
            'wss://nostr-2.21crypto.ch',
            'wss://nostr-dev.wellorder.net',
            'wss://nostr-pub.wellorder.net',
            'wss://nostr-relay-1.trustlessenterprise.com',
            'wss://nostr-relay.amethyst.name',
            'wss://nostr-relay.cbrx.io',
            'wss://nostr-relay.moe.gift',
            'wss://nostr-relay.online',
            'wss://nostr-relay.psfoundation.info',
            'wss://nostr-relay.schnitzel.world',
            'wss://nostr-relay.shirogaku.xyz',
            'wss://nostr-relay.zimage.com',
            'wss://nostr-rs-relay-ishosta.phamthanh.me',
            'wss://nostr-rs-relay.dev.fedibtc.com',
            'wss://nostr-verif.slothy.win',
            'wss://nostr-verified.wellorder.net',
            'wss://nostr.0x7e.xyz',
            'wss://nostr.21crypto.ch',
            'wss://nostr.2b9t.xyz',
            'wss://nostr.4rs.nl',
            'wss://nostr.agentcampfire.com',
            'wss://nostr.azzamo.net',
            'wss://nostr.bilthon.dev',
            'wss://nostr.blankfors.se',
            'wss://nostr.camalolo.com',
            'wss://nostr.carroarmato0.be',
            'wss://nostr.chaima.info',
            'wss://nostr.coincards.com',
            'wss://nostr.coincrowd.fund',
            'wss://nostr.community.ath.cx',
            'wss://nostr.data.haus',
            'wss://nostr.dbtc.link',
            'wss://nostr.easydns.ca',
            'wss://nostr.einundzwanzig.space',
            'wss://nostr.excentered.com',
            'wss://nostr.fbxl.net',
            'wss://nostr.hekster.org',
            'wss://nostr.hifish.org',
            'wss://nostr.hoppe-relay.it.com',
            'wss://nostr.huszonegy.world',
            'wss://nostr.jfischer.org',
            'wss://nostr.kalf.org',
            'wss://nostr.kungfu-g.rip',
            'wss://nostr.l484.com',
            'wss://nostr.liberty.fans',
            'wss://nostr.lojong.info',
            'wss://nostr.makibisskey.work',
            'wss://nostr.massmux.com',
            'wss://nostr.middling.mydns.jp',
            'wss://nostr.mom',
            'wss://nostr.myshosholoza.co.za',
            'wss://nostr.n7ekb.net',
            'wss://nostr.namek.link',
            'wss://nostr.night7.space',
            'wss://nostr.nodeofsven.com',
            'wss://nostr.notribe.net',
            'wss://nostr.novacisko.cz',
            'wss://nostr.now',
            'wss://nostr.overmind.lol',
            'wss://nostr.oxtr.dev',
            'wss://nostr.plantroon.com',
            'wss://nostr.prl.plus',
            'wss://nostr.rblb.it',
            'wss://nostr.red5d.dev',
            'wss://nostr.rikmeijer.nl',
            'wss://nostr.rohoss.com',
            'wss://nostr.roundrockbitcoiners.com',
            'wss://nostr.rtvslawenia.com',
            'wss://nostr.sagaciousd.com',
            'wss://nostr.sathoarder.com',
            'wss://nostr.satstralia.com',
            'wss://nostr.slothy.win',
            'wss://nostr.smut.cloud',
            'wss://nostr.spaceshell.xyz',
            'wss://nostr.spicyz.io',
            'wss://nostr.stakey.net',
            'wss://nostr.tac.lol',
            'wss://nostr.tadryanom.me',
            'wss://nostr.tavux.tech',
            'wss://nostr.tegila.com.br',
            'wss://nostr.thaliyal.com',
            'wss://nostr.thebiglake.org',
            'wss://nostr.veladan.dev',
            'wss://nostr.vulpem.com',
            'wss://nostr.yael.at',
            'wss://nostr.zenon.network',
            'wss://nostrelay.circum.space',
            'wss://nostrelay.memory-art.xyz',
            'wss://nostrja-kari.heguro.com',
            'wss://nostrue.com',
            'wss://noxir.kpherox.dev',
            'wss://nproxy.kristapsk.lv',
            'wss://orangepiller.org',
            'wss://orangesync.tech',
            'wss://portal-relay.pareto.space',
            'wss://premium.primal.net',
            'wss://prl.plus',
            'wss://promenade.fiatjaf.com',
            'wss://purplerelay.com',
            'wss://pyramid.fiatjaf.com',
            'wss://r.bitcoinhold.net',
            'wss://relay-admin.thaliyal.com',
            'wss://relay-dev.satlantis.io',
            'wss://relay-rpi.edufeed.org',
            'wss://relay-testnet.k8s.layer3.news',
            'wss://relay.13room.space',
            'wss://relay.21e6.cz',
            'wss://relay.agorist.space',
            'wss://relay.angor.io',
            'wss://relay.anzenkodo.workers.dev',
            'wss://relay.artiostr.ch',
            'wss://relay.artx.market',
            'wss://relay.arx-ccn.com',
            'wss://relay.bankless.at',
            'wss://relay.barine.co',
            'wss://relay.bitcoinartclock.com',
            'wss://relay.bitcoinveneto.org',
            'wss://relay.bullishbounty.com',
            'wss://relay.chakany.systems',
            'wss://relay.chorus.community',
            'wss://relay.coinos.io',
            'wss://relay.conduit.market',
            'wss://relay.copylaradio.com',
            'wss://relay.cosmicbolt.net',
            'wss://relay.credenso.cafe',
            'wss://relay.cypherflow.ai',
            'wss://relay.davidebtc.me',
            'wss://relay.degmods.com',
            'wss://relay.digitalezukunft.cyou',
            'wss://relay.dwadziesciajeden.pl',
            'wss://relay.etch.social',
            'wss://relay.evanverma.com',
            'wss://relay.fountain.fm',
            'wss://relay.fr13nd5.com',
            'wss://relay.freeplace.nl',
            'wss://relay.froth.zone',
            'wss://relay.g1sms.fr',
            'wss://relay.getsafebox.app',
            'wss://relay.goodmorningbitcoin.com',
            'wss://relay.hasenpfeffr.com',
            'wss://relay.hivetalk.org',
            'wss://relay.hodl.ar',
            'wss://relay.holzeis.me',
            'wss://relay.illuminodes.com',
            'wss://relay.javi.space',
            'wss://relay.jeffg.fyi',
            'wss://relay.laantungir.net',
            'wss://relay.letsfo.com',
            'wss://relay.lexingtonbitcoin.org',
            'wss://relay.lnfi.network',
            'wss://relay.lumina.rocks',
            'wss://relay.magiccity.live',
            'wss://relay.mattybs.lol',
            'wss://relay.mccormick.cx',
            'wss://relay.mess.ch',
            'wss://relay.minibolt.info',
            'wss://relay.mostro.network',
            'wss://relay.mwaters.net',
            'wss://relay.netstr.io',
            'wss://relay.nosto.re',
            'wss://relay.nostr.com.au',
            'wss://relay.nostr.net',
            'wss://relay.nostr.wirednet.jp',
            'wss://relay.nostrcal.com',
            'wss://relay.nostrcheck.me',
            'wss://relay.nostrdice.com',
            'wss://relay.nostrhub.fr',
            'wss://relay.nostrhub.tech',
            'wss://relay.nostriot.com',
            'wss://relay.nostromo.social',
            'wss://relay.nostx.io',
            'wss://relay.notoshi.win',
            'wss://relay.nsnip.io',
            'wss://relay.oldenburg.cool',
            'wss://relay.orangepill.ovh',
            'wss://relay.puresignal.news',
            'wss://relay.ru.ac.th',
            'wss://relay.satlantis.io',
            'wss://relay.satsdays.com',
            'wss://relay.siamdev.cc',
            'wss://relay.sigit.io',
            'wss://relay.sincensura.org',
            'wss://relay.stream.labs.h3.se',
            'wss://relay.tagayasu.xyz',
            'wss://relay.tapestry.ninja',
            'wss://relay.toastr.net',
            'wss://relay.usefusion.ai',
            'wss://relay.utxo.farm',
            'wss://relay.varke.eu',
            'wss://relay.verified-nostr.com',
            'wss://relay.vrtmrz.net',
            'wss://relay.wavefunc.live',
            'wss://relay.wavlake.com',
            'wss://relay.wellorder.net',
            'wss://relay.wolfcoil.com',
            'wss://relay.zone667.com',
            'wss://relay01.lnfi.network',
            'wss://relay02.lnfi.network',
            'wss://relay03.lnfi.network',
            'wss://relay04.lnfi.network',
            'wss://relay1.nostrchat.io',
            'wss://relay2.angor.io',
            'wss://relay2.nostrchat.io',
            'wss://relay5.bitransfer.org',
            'wss://relayone.geektank.ai',
            'wss://relayone.soundhsa.com',
            'wss://relayrs.notoshi.win',
            'wss://rn1.sotiras.org',
            'wss://santo.iguanatech.net',
            'wss://satsage.xyz',
            'wss://schnorr.me',
            'wss://slick.mjex.me',
            'wss://social.proxymana.net',
            'wss://soloco.nl',
            'wss://srtrelay.c-stellar.net',
            'wss://strfry.bonsai.com',
            'wss://strfry.felixzieger.de',
            'wss://strfry.openhoofd.nl',
            'wss://strfry.shock.network',
            'wss://temp.iris.to',
            'wss://theoutpost.life',
            'wss://tollbooth.stens.dev',
            'wss://travis-shears-nostr-relay-v2.fly.dev',
            'wss://vidono.apps.slidestr.net',
            'wss://vitor.nostr1.com',
            'wss://wheat.happytavern.co',
            'wss://wot.brightbolt.net',
            'wss://wot.codingarena.top',
            'wss://wot.downisontheup.ca',
            'wss://wot.dtonon.com',
            'wss://wot.geektank.ai',
            'wss://wot.nostr.net',
            'wss://wot.nostr.party',
            'wss://wot.nostr.place',
            'wss://wot.sebastix.social',
            'wss://wot.soundhsa.com',
            'wss://wot.sudocarlos.com',
            'wss://x.kojira.io',
            'wss://zap.watch'
        ];
        // Geo-located relays from Bitchat's relay directory for geohash channels
        this.geoRelays = [
            { url: 'wss://relay-admin.thaliyal.com', lat: 40.8218, lng: -74.45 },
            { url: 'wss://nostr.notribe.net', lat: 40.8302, lng: -74.1299 },
            { url: 'wss://strfry.bonsai.com', lat: 37.8715, lng: -122.273 },
            { url: 'wss://nostr-relay.online', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://shu05.shugur.net', lat: 48.8566, lng: 2.35222 },
            { url: 'wss://dev-nostr.bityacht.io', lat: 25.0797, lng: 121.234 },
            { url: 'wss://relay.nostrhub.tech', lat: 49.0291, lng: 8.35696 },
            { url: 'wss://relay.davidebtc.me', lat: 50.1109, lng: 8.68213 },
            { url: 'wss://relay.moinsen.com', lat: 50.4754, lng: 12.3683 },
            { url: 'wss://relay.olas.app', lat: 50.4754, lng: 12.3683 },
            { url: 'wss://orangepiller.org', lat: 60.1699, lng: 24.9384 },
            { url: 'wss://relayrs.notoshi.win', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://relay.guggero.org', lat: 47.3769, lng: 8.54169 },
            { url: 'wss://nostr.blankfors.se', lat: 60.1699, lng: 24.9384 },
            { url: 'wss://wot.sovbit.host', lat: 64.1466, lng: -21.9426 },
            { url: 'wss://nostr.huszonegy.world', lat: 47.4979, lng: 19.0402 },
            { url: 'wss://wot.sebastix.social', lat: 51.8933, lng: 4.42083 },
            { url: 'wss://articles.layer3.news', lat: 37.3387, lng: -121.885 },
            { url: 'wss://nostr.spicyz.io', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://nostr.jerrynya.fun', lat: 31.2304, lng: 121.474 },
            { url: 'wss://nostr.oxtr.dev', lat: 50.4754, lng: 12.3683 },
            { url: 'wss://relay.mwaters.net', lat: 50.9871, lng: 2.12554 },
            { url: 'wss://vitor.nostr1.com', lat: 40.7128, lng: -74.006 },
            { url: 'wss://relay.lumina.rocks', lat: 49.0291, lng: 8.35695 },
            { url: 'wss://nostr-relay-1.trustlessenterprise.com', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://nostr.bilthon.dev', lat: 25.8128, lng: -80.2377 },
            { url: 'wss://nostr.now', lat: 36.55, lng: 139.733 },
            { url: 'wss://nostr.girino.org', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://nostr-01.yakihonne.com', lat: 1.32123, lng: 103.695 },
            { url: 'wss://nostrelay.memory-art.xyz', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://relay.evanverma.com', lat: 40.8302, lng: -74.1299 },
            { url: 'wss://a.nos.lol', lat: 50.4754, lng: 12.3683 },
            { url: 'wss://purpura.cloud', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://relay.snort.social', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://relay.holzeis.me', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://nostr.spaceshell.xyz', lat: 40.7128, lng: -74.006 },
            { url: 'wss://nostr.liberty.fans', lat: 36.9104, lng: -89.5875 },
            { url: 'wss://relay.fundstr.me', lat: 42.3601, lng: -71.0589 },
            { url: 'wss://wot.basspistol.org', lat: 49.4521, lng: 11.0767 },
            { url: 'wss://relay.notoshi.win', lat: 13.4166, lng: 101.335 },
            { url: 'wss://relay.stream.labs.h3.se', lat: 59.4016, lng: 17.9455 },
            { url: 'wss://nostr.stakey.net', lat: 52.3676, lng: 4.90414 },
            { url: 'wss://relay.satlantis.io', lat: 32.8769, lng: -80.0114 },
            { url: 'wss://nostr-2.21crypto.ch', lat: 47.4988, lng: 8.72369 },
            { url: 'wss://nostr.satstralia.com', lat: 64.1476, lng: -21.9392 },
            { url: 'wss://slick.mjex.me', lat: 39.048, lng: -77.4817 },
            { url: 'wss://nostr-relay.nextblockvending.com', lat: 47.2343, lng: -119.853 },
            { url: 'wss://relay.origin.land', lat: 35.6673, lng: 139.751 },
            { url: 'wss://nostr.fbxl.net', lat: 48.382, lng: -89.2502 },
            { url: 'wss://relay.nostr.place', lat: 32.7767, lng: -96.797 },
            { url: 'wss://nr.yay.so', lat: 46.2126, lng: 6.1154 },
            { url: 'wss://nostream.breadslice.com', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://wot.tealeaf.dev', lat: 33.7488, lng: -84.3877 },
            { url: 'wss://relay.primal.net', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://relay.chorus.community', lat: 50.1109, lng: 8.68213 },
            { url: 'wss://wot.dergigi.com', lat: 64.1476, lng: -21.9392 },
            { url: 'wss://nostr-relay.amethyst.name', lat: 39.0438, lng: -77.4874 },
            { url: 'wss://nostr.mehdibekhtaoui.com', lat: 49.4939, lng: -1.54813 },
            { url: 'wss://relay.mess.ch', lat: 46.948, lng: 7.44745 },
            { url: 'wss://relay.sigit.io', lat: 50.4754, lng: 12.3683 },
            { url: 'wss://relay-rpi.edufeed.org', lat: 49.4543, lng: 11.0746 },
            { url: 'wss://nostr.faultables.net', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://relay.getsafebox.app', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://cyberspace.nostr1.com', lat: 40.7128, lng: -74.006 },
            { url: 'wss://relay.endfiat.money', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://soloco.nl', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://nostr.kungfu-g.rip', lat: 33.7946, lng: -84.4488 },
            { url: 'wss://nostrelay.circum.space', lat: 51.2217, lng: 6.77616 },
            { url: 'wss://relay.trustroots.org', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://relay.wellorder.net', lat: 45.5201, lng: -122.99 },
            { url: 'wss://relay.coinos.io', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://relay-testnet.k8s.layer3.news', lat: 37.3387, lng: -121.885 },
            { url: 'wss://relay.nostriot.com', lat: 41.5695, lng: -83.9786 },
            { url: 'wss://relay.bitcoinartclock.com', lat: 50.4754, lng: 12.3683 },
            { url: 'wss://nostr.einundzwanzig.space', lat: 50.1109, lng: 8.68213 },
            { url: 'wss://nostr.casa21.space', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://premium.primal.net', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://relay.tagayasu.xyz', lat: 43.6715, lng: -79.38 },
            { url: 'wss://nostr.mom', lat: 50.4754, lng: 12.3683 },
            { url: 'wss://nostr.zenon.network', lat: 43.5009, lng: -70.4428 },
            { url: 'wss://nostr-pub.wellorder.net', lat: 45.5201, lng: -122.99 },
            { url: 'wss://relay.g1sms.fr', lat: 43.9432, lng: 2.07537 },
            { url: 'wss://relay.illuminodes.com', lat: 47.6061, lng: -122.333 },
            { url: 'wss://dizzyspells.nostr1.com', lat: 40.7057, lng: -74.0136 },
            { url: 'wss://relay.mostro.network', lat: 40.8302, lng: -74.1299 },
            { url: 'wss://relay.nostr.wirednet.jp', lat: 34.706, lng: 135.493 },
            { url: 'wss://relay.barine.co', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://relay.damus.io', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://relay.0xchat.com', lat: 1.35208, lng: 103.82 },
            { url: 'wss://relay.mattybs.lol', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://no.str.cr', lat: 9.92857, lng: -84.0528 },
            { url: 'wss://relay.utxo.farm', lat: 35.6916, lng: 139.768 },
            { url: 'wss://nostr.pleb.one', lat: 38.6327, lng: -90.1961 },
            { url: 'wss://relay-dev.satlantis.io', lat: 40.8302, lng: -74.1299 },
            { url: 'wss://relay.nostrdice.com', lat: -33.8688, lng: 151.209 },
            { url: 'wss://relay.nostraddress.com', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://satsage.xyz', lat: 37.3986, lng: -121.964 },
            { url: 'wss://offchain.pub', lat: 36.1809, lng: -115.241 },
            { url: 'wss://noxir.kpherox.dev', lat: 34.8587, lng: 135.509 },
            { url: 'wss://nostr-relay.psfoundation.info', lat: 39.0438, lng: -77.4874 },
            { url: 'wss://khatru.nostrver.se', lat: 51.8933, lng: 4.42083 },
            { url: 'wss://purplerelay.com', lat: 50.1109, lng: 8.68213 },
            { url: 'wss://relay.tapestry.ninja', lat: 40.8054, lng: -74.0241 },
            { url: 'wss://nostr.night7.space', lat: 50.4754, lng: 12.3683 },
            { url: 'wss://nostr.rikmeijer.nl', lat: 50.4754, lng: 12.3683 },
            { url: 'wss://relay1.nostrchat.io', lat: 60.1699, lng: 24.9384 },
            { url: 'wss://nostr.21crypto.ch', lat: 47.4988, lng: 8.72369 },
            { url: 'wss://wot.soundhsa.com', lat: 33.1384, lng: -95.6011 },
            { url: 'wss://relay.orangepill.ovh', lat: 49.1689, lng: -0.358841 },
            { url: 'wss://talon.quest', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://nostr-rs-relay.dev.fedibtc.com', lat: 39.0438, lng: -77.4874 },
            { url: 'wss://wot.codingarena.top', lat: 50.4754, lng: 12.3683 },
            { url: 'wss://fanfares.nostr1.com', lat: 40.7128, lng: -74.006 },
            { url: 'wss://gnostr.com', lat: 42.6978, lng: 23.3246 },
            { url: 'wss://nostrelites.org', lat: 41.8781, lng: -87.6298 },
            { url: 'wss://relay.bitcoindistrict.org', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://relay.fr13nd5.com', lat: 52.5233, lng: 13.3426 },
            { url: 'wss://wot.nostr.place', lat: 30.2672, lng: -97.7431 },
            { url: 'wss://ithurtswhenip.ee', lat: 51.223, lng: 6.78245 },
            { url: 'wss://relay.dwadziesciajeden.pl', lat: 52.2297, lng: 21.0122 },
            { url: 'wss://relay.nostr.net', lat: 50.4754, lng: 12.3683 },
            { url: 'wss://nostr-relay.cbrx.io', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://dev-relay.lnfi.network', lat: 39.0997, lng: -94.5786 },
            { url: 'wss://relay.jeffg.fyi', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://nos.xmark.cc', lat: 50.6924, lng: 3.20113 },
            { url: 'wss://relay.21e6.cz', lat: 50.1682, lng: 14.0546 },
            { url: 'wss://relay.degmods.com', lat: 50.4754, lng: 12.3683 },
            { url: 'wss://nostr.coincrowd.fund', lat: 39.0438, lng: -77.4874 },
            { url: 'wss://nostr.myshosholoza.co.za', lat: 52.3676, lng: 4.90414 },
            { url: 'wss://relay.digitalezukunft.cyou', lat: 45.5019, lng: -73.5674 },
            { url: 'wss://r.lostr.net', lat: 52.3676, lng: 4.90414 },
            { url: 'wss://relay.etch.social', lat: 41.2619, lng: -95.8608 },
            { url: 'wss://nostr.tac.lol', lat: 47.4748, lng: -122.273 },
            { url: 'wss://nostr.azzamo.net', lat: 52.2633, lng: 21.0283 },
            { url: 'wss://nostr.4rs.nl', lat: 49.0291, lng: 8.35696 },
            { url: 'wss://nostr-03.dorafactory.org', lat: 1.35208, lng: 103.82 },
            { url: 'wss://relay.copylaradio.com', lat: 51.223, lng: 6.78245 },
            { url: 'wss://nostr.camalolo.com', lat: 24.1469, lng: 120.684 },
            { url: 'wss://nostr-dev.wellorder.net', lat: 45.5201, lng: -122.99 },
            { url: 'wss://relay.nostx.io', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://r.bitcoinhold.net', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://nproxy.kristapsk.lv', lat: 60.1699, lng: 24.9384 },
            { url: 'wss://adre.su', lat: 59.9311, lng: 30.3609 },
            { url: 'wss://relay.hasenpfeffr.com', lat: 39.0438, lng: -77.4874 },
            { url: 'wss://nos.lol', lat: 50.4754, lng: 12.3683 },
            { url: 'wss://nostr-02.czas.top', lat: 53.471, lng: 9.88208 },
            { url: 'wss://relay.nosto.re', lat: 51.8933, lng: 4.42083 },
            { url: 'wss://nostr.plantroon.com', lat: 50.1013, lng: 8.62643 },
            { url: 'wss://nostr.rblb.it', lat: 43.4633, lng: 11.8796 },
            { url: 'wss://nostr.thebiglake.org', lat: 32.71, lng: -96.6745 },
            { url: 'wss://nostr.luisschwab.net', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://relay.electriclifestyle.com', lat: 26.2897, lng: -80.1293 },
            { url: 'wss://librerelay.aaroniumii.com', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://nostr.88mph.life', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://shu02.shugur.net', lat: 21.4902, lng: 39.2246 },
            { url: 'wss://relay.hook.cafe', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://strfry.elswa-dev.online', lat: 48.8566, lng: 2.35222 },
            { url: 'wss://wot.sudocarlos.com', lat: 51.5072, lng: -0.127586 },
            { url: 'wss://relay.islandbitcoin.com', lat: 12.8498, lng: 77.6545 },
            { url: 'wss://nostr.tadryanom.me', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://relay.zone667.com', lat: 60.1699, lng: 24.9384 },
            { url: 'wss://nostr.agentcampfire.com', lat: 50.8933, lng: 6.05805 },
            { url: 'wss://relay.ditto.pub', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://relay03.lnfi.network', lat: 39.0997, lng: -94.5786 },
            { url: 'wss://relay2.angor.io', lat: 48.1046, lng: 11.6002 },
            { url: 'wss://srtrelay.c-stellar.net', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://relayone.soundhsa.com', lat: 33.1384, lng: -95.6011 },
            { url: 'wss://relay.javi.space', lat: 43.4633, lng: 11.8796 },
            { url: 'wss://nostr.carroarmato0.be', lat: 50.9928, lng: 3.26317 },
            { url: 'wss://nostr.hekster.org', lat: 37.3986, lng: -121.964 },
            { url: 'wss://strfry.shock.network', lat: 41.8959, lng: -88.2169 },
            { url: 'wss://nostr.2b9t.xyz', lat: 34.0549, lng: -118.243 },
            { url: 'wss://relay.toastr.net', lat: 40.8054, lng: -74.0241 },
            { url: 'wss://relay.bitcoinveneto.org', lat: 64.1466, lng: -21.9426 },
            { url: 'wss://relay.wavlake.com', lat: 41.2619, lng: -95.8608 },
            { url: 'wss://relay.arx-ccn.com', lat: 50.4754, lng: 12.3683 },
            { url: 'wss://relay.cosmicbolt.net', lat: 37.3986, lng: -121.964 },
            { url: 'wss://relay.mccormick.cx', lat: 52.3563, lng: 4.95714 },
            { url: 'wss://temp.iris.to', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://relay.vrtmrz.net', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://nostr-relay.zimage.com', lat: 34.282, lng: -118.439 },
            { url: 'wss://nostr.data.haus', lat: 50.4754, lng: 12.3683 },
            { url: 'wss://nostr.vulpem.com', lat: 49.4543, lng: 11.0746 },
            { url: 'wss://relay.agora.social', lat: 50.7383, lng: 15.0648 },
            { url: 'wss://nostr.ovia.to', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://nostr.red5d.dev', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://orangesync.tech', lat: 50.1109, lng: 8.68213 },
            { url: 'wss://relay.fountain.fm', lat: 39.0997, lng: -94.5786 },
            { url: 'wss://relay.aloftus.io', lat: 34.0881, lng: -118.379 },
            { url: 'wss://nostr.hifish.org', lat: 47.4043, lng: 8.57398 },
            { url: 'wss://relay.siamdev.cc', lat: 13.9178, lng: 100.424 },
            { url: 'wss://fenrir-s.notoshi.win', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://nostr.overmind.lol', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://wheat.happytavern.co', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://nostr.rtvslawenia.com', lat: 49.4543, lng: 11.0746 },
            { url: 'wss://relay.nostrhub.fr', lat: 48.1046, lng: 11.6002 },
            { url: 'wss://strfry.openhoofd.nl', lat: 51.9229, lng: 4.40833 },
            { url: 'wss://relay.usefusion.ai', lat: 38.7134, lng: -78.1591 },
            { url: 'wss://relay.credenso.cafe', lat: 43.3601, lng: -80.3127 },
            { url: 'wss://nostr.lostr.space', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://relay.jmoose.rocks', lat: 60.1699, lng: 24.9384 },
            { url: 'wss://relay.nostromo.social', lat: 49.4543, lng: 11.0746 },
            { url: 'wss://nostr.jfischer.org', lat: 49.0291, lng: 8.35696 },
            { url: 'wss://relay.wolfcoil.com', lat: 35.6092, lng: 139.73 },
            { url: 'wss://nostr.thaliyal.com', lat: 40.8218, lng: -74.45 },
            { url: 'wss://relay.magiccity.live', lat: 25.8128, lng: -80.2377 },
            { url: 'wss://relay.puresignal.news', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://prl.plus', lat: 55.7623, lng: 37.6381 },
            { url: 'wss://wot.brightbolt.net', lat: 47.6735, lng: -116.781 },
            { url: 'wss://relay.varke.eu', lat: 52.6921, lng: 6.19372 },
            { url: 'wss://alienos.libretechsystems.xyz', lat: 55.4724, lng: 9.87335 },
            { url: 'wss://relay.goodmorningbitcoin.com', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://pyramid.fiatjaf.com', lat: 51.5072, lng: -0.127586 },
            { url: 'wss://relay02.lnfi.network', lat: 39.0997, lng: -94.5786 },
            { url: 'wss://nostr.davidebtc.me', lat: 50.1109, lng: 8.68213 },
            { url: 'wss://nostr-verified.wellorder.net', lat: 45.5201, lng: -122.99 },
            { url: 'wss://relay.cypherflow.ai', lat: 48.8566, lng: 2.35222 },
            { url: 'wss://nostr.snowbla.de', lat: 60.1699, lng: 24.9384 },
            { url: 'wss://inbox.azzamo.net', lat: 52.2633, lng: 21.0283 },
            { url: 'wss://shu01.shugur.net', lat: 21.4902, lng: 39.2246 },
            { url: 'wss://nostr.middling.mydns.jp', lat: 35.8099, lng: 140.12 },
            { url: 'wss://nostr.kalf.org', lat: 52.3676, lng: 4.90414 },
            { url: 'wss://relay.laantungir.net', lat: -19.4692, lng: -42.5315 },
            { url: 'wss://relay.angor.io', lat: 48.1046, lng: 11.6002 },
            { url: 'wss://nostr2.girino.org', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://relay01.lnfi.network', lat: 39.0997, lng: -94.5786 },
            { url: 'wss://nostr.chaima.info', lat: 51.223, lng: 6.78245 },
            { url: 'wss://x.kojira.io', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://shu04.shugur.net', lat: 25.2604, lng: 55.2989 },
            { url: 'wss://santo.iguanatech.net', lat: 40.8302, lng: -74.1299 },
            { url: 'wss://relay.artx.market', lat: 43.652, lng: -79.3633 },
            { url: 'wss://alien.macneilmediagroup.com', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://nostr.sathoarder.com', lat: 48.5734, lng: 7.75211 },
            { url: 'wss://zap.watch', lat: 45.5029, lng: -73.5723 },
            { url: 'wss://relay.basspistol.org', lat: 46.2044, lng: 6.14316 },
            { url: 'wss://relay.13room.space', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://relay.bullishbounty.com', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://theoutpost.life', lat: 64.1476, lng: -21.9392 },
            { url: 'wss://nostr.coincards.com', lat: 53.5501, lng: -113.469 },
            { url: 'wss://black.nostrcity.club', lat: 41.8781, lng: -87.6298 },
            { url: 'wss://relay.npubhaus.com', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://relay.freeplace.nl', lat: 52.3676, lng: 4.90414 },
            { url: 'wss://relay.seq1.net', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://ynostr.yael.at', lat: 60.1699, lng: 24.9384 },
            { url: 'wss://relay.nostr.vet', lat: 52.6467, lng: 4.7395 },
            { url: 'wss://relay.lifpay.me', lat: 1.35208, lng: 103.82 },
            { url: 'wss://relay.chakany.systems', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://relay.lightning.pub', lat: 41.8959, lng: -88.2169 },
            { url: 'wss://wot.dtonon.com', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://yabu.me', lat: 35.6092, lng: 139.73 },
            { url: 'wss://wot.nostr.net', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://relay.libernet.app', lat: 40.7357, lng: -74.1724 },
            { url: 'wss://relay04.lnfi.network', lat: 39.0997, lng: -94.5786 },
            { url: 'wss://nostr.0x7e.xyz', lat: 47.4988, lng: 8.72369 },
            { url: 'wss://nostr.mikoshi.de', lat: 50.1109, lng: 8.68213 },
            { url: 'wss://wot.nostr.party', lat: 36.1627, lng: -86.7816 },
            { url: 'wss://relay.letsfo.com', lat: 51.098, lng: 17.0321 },
            { url: 'wss://nostr.makibisskey.work', lat: 43.6532, lng: -79.3832 },
            { url: 'wss://nostr.simplex.icu', lat: 50.8198, lng: -1.08798 }
        ];
        this.geoRelayConnections = new Map();
        this.currentGeoRelays = new Set();
        this.geoRelayCount = 10;
        this.discoveredRelays = new Set();
        this.relayList = [];
        this.lastRelayDiscovery = 0;
        this.relayDiscoveryInterval = 300000;
        this.maxRelaysForReq = 1000;
        this.relayTimeout = 2000;
        this.eventDeduplication = new Map();
        this.reconnectingRelays = new Set();
        this.blacklistedRelays = new Set();
        this.blacklistTimestamps = new Map();
        this.blacklistDuration = 600000;
        this.pubkey = null;
        this.privkey = null;
        this.nym = null;
        this.powDifficulty = 12;
        this.enablePow = false;
        this.connectionMode = 'ephemeral';
        this.originalProfile = null;
        this.currentChannel = 'bar';
        this.currentGeohash = '';
        this.currentPM = null;
        this.messages = new Map();
        this.prerenderedChannels = new Map();
        this.prerenderedChannelVersions = new Map();
        this.prerenderQueue = [];
        this.isPrerenderingActive = false;
        this.pmMessages = new Map();
        this.processedPMEventIds = new Set();
        this.processedMessageEventIds = new Set();
        this.lastPMSyncTime = Math.floor(Date.now() / 1000) - 604800;
        this.bitchatUsers = new Set();
        this.nymUsers = new Set();
        this.users = new Map();
        this.channelUsers = new Map();
        this.channels = new Map();
        this.pmConversations = new Map();
        this.unreadCounts = new Map();
        this.blockedUsers = new Set();
        this.blockedKeywords = new Set();
        this.blockedChannels = new Set();
        this.communityChannels = new Map();
        this.ownedCommunities = new Set();
        this.moderatedCommunities = new Set();
        this.communityBans = new Map();
        this.communityInvites = new Map();
        this.communityMembers = new Map();
        this.communityModerators = new Map();
        this.currentCommunity = null;
        this.processedModerationEvents = new Set();
        this.settings = this.loadSettings();
        this.pinnedLandingChannel = this.settings.pinnedLandingChannel || { type: 'ephemeral', channel: 'bar' };
        if (this.pinnedLandingChannel.type === 'geohash') {
            this.currentChannel = this.pinnedLandingChannel.geohash;
            this.currentGeohash = this.pinnedLandingChannel.geohash;
        } else if (this.pinnedLandingChannel.type === 'community') {
            this.currentCommunity = this.pinnedLandingChannel.communityId;
        } else {
            this.currentChannel = this.pinnedLandingChannel.channel || 'bar';
        }
        this.commandHistory = [];
        this.historyIndex = -1;
        this.connected = false;
        this.messageQueue = [];
        this.autocompleteIndex = -1;
        this.commandPaletteIndex = -1;
        this.gifPicker = null;
        this.gifSearchTimeout = null;
        this.giphyApiKey = 'G6neFEExTMBM0h3hM2QjQg4vG8jMMLa9';
        this.emojiAutocompleteIndex = -1;
        this.commonChannels = ['bar', 'random', 'nostr', 'bitcoin', 'tech', 'music', 'gaming', 'anime', 'memes', 'news', 'politics', 'science', 'art', 'food', 'sports'];
        this.commonGeohashes = ['w1', 'w2', 'dr5r', '9q8y', 'u4pr', 'gcpv', 'f2m6', 'xn77', 'tjm5'];
        this.userJoinedChannels = new Set(this.loadUserJoinedChannels());
        this.inPMMode = false;
        this.userSearchTerm = '';
        this.geohashRegex = /^[0-9bcdefghjkmnpqrstuvwxyz]{1,12}$/;
        this.pinnedChannels = new Set();
        this.reactions = new Map();
        this.failedRelays = new Map();
        this.relayRetryDelay = 15 * 60 * 1000;
        this.floodTracking = new Map();
        this.activeReactionPicker = null;
        this.activeReactionPickerButton = null;
        this.usingExtension = false;
        this.contextMenuTarget = null;
        this.contextMenuData = null;
        this.p2pConnections = new Map();
        this.p2pDataChannels = new Map();
        this.p2pFileOffers = new Map();
        this.p2pActiveTransfers = new Map();
        this.p2pPendingFiles = new Map();
        this.p2pReceivedChunks = new Map();
        this.p2pSignalingSubscriptions = new Set();
        this.p2pIceServers = [
            { urls: 'stun:stun.cloudflare.com:3478' },
            { urls: 'stun:stun.l.google.com:19302' },
            { urls: 'stun:stun1.l.google.com:19302' },
            { urls: 'stun:stun2.l.google.com:19302' }
        ];
        this.P2P_SIGNALING_KIND = 25051;
        this.P2P_CHUNK_SIZE = 16384;
        this.awayMessages = new Map();
        this.recentEmojis = [];
        this.allEmojis = {
            'smileys': ['😊', '😂', '🤣', '😍', '🥰', '😘', '😎', '🤔', '😢', '😭', '😡', '🤬', '😱', '😨', '😰', '😥', '😓', '🤗', '🤭', '🤫', '🤥', '😶', '😐', '😑', '😬', '🙄', '😯', '😦', '😧', '😮', '😲', '🥱', '😴', '🤤', '😪', '😵', '🤐', '🥴', '🤢', '🤮', '🤧', '😷', '🤒', '🤕', '🤑', '🤠', '😈', '👿', '👹', '👺', '🤡', '💩', '👻', '💀', '☠️', '👽', '👾', '🤖', '🎃', '😺', '😸', '😹', '😻', '😼', '😽', '🙀', '😿', '😾'],
            'gestures': ['👍', '👎', '👌', '✌️', '🤞', '🤟', '🤘', '🤙', '👈', '👉', '👆', '👇', '☝️', '✋', '🤚', '🖐️', '🖖', '👋', '🤏', '✍️', '👏', '🙌', '👐', '🤲', '🤝', '🙏', '💪', '🦾', '🦿', '🦵', '🦶', '👂', '🦻', '👃', '🧠', '🦷', '🦴', '👀', '👁️', '👅', '👄', '💋'],
            'hearts': ['❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '🤎', '💔', '❣️', '💕', '💞', '💓', '💗', '💖', '💘', '💝', '💟', '☮️', '✝️', '☪️', '🕉️', '☸️', '✡️', '🔯', '🕎', '☯️', '☦️', '🛐', '⛎', '♈', '♉', '♊', '♋', '♌', '♍', '♎', '♏', '♐', '♑', '♒', '♓'],
            'symbols': ['💯', '💢', '💥', '💫', '💦', '💨', '🕳️', '💣', '💬', '👁️‍🗨️', '🗨️', '🗯️', '💭', '💤', '✨', '🌟', '💫', '⭐', '🌠', '🔥', '💥', '☄️', '🎆', '🎇', '🎈', '🎉', '🎊', '🎋', '🎍', '🎎', '🎏', '🎐', '🎑', '🧧', '🎀', '🎁', '🎗️', '🎟️', '🎫'],
            'objects': ['⌚', '📱', '📲', '💻', '⌨️', '🖥️', '🖨️', '🖱️', '🖲️', '🕹️', '🗜️', '💽', '💾', '💿', '📀', '📼', '📷', '📸', '📹', '🎥', '📽️', '🎞️', '📞', '☎️', '📟', '📠', '📺', '📻', '🎙️', '🎚️', '🎛️', '⏱️', '⏲️', '⏰', '🕰️', '⌛', '⏳', '📡', '🔋', '🔌', '💡', '🔦', '🕯️', '🗑️', '🛢️', '💸', '💵', '💴', '💶', '💷', '💰', '💳', '🧾', '💎', '⚖️', '🔧', '🔨', '⚒️', '🛠️', '⛏️', '🔩', '⚙️', '⛓️', '🔫', '💣', '🔪', '🗡️', '⚔️', '🛡️', '🚬', '⚰️', '⚱️', '🏺', '🔮', '📿', '💈', '⚗️', '🔭', '🔬', '🕳️', '💊', '💉', '🩸', '🩹', '🩺', '🌡️', '🏷️', '🔖', '🚿', '🛁', '🛀', '🚰', '🚽', '🧻', '🧼', '🧽', '🧴', '🪒', '🧹', '🧺', '🔑', '🗝️', '🛏️', '🛋️', '🚪', '🪑', '🚿', '🛁', '🛀', '🧴', '🧷', '🧹', '🧺', '🧻', '🧼', '🧽', '🧯', '🛒', '🚬', '⚰️', '⚱️', '🗿'],
            'food': ['🍏', '🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🍈', '🍒', '🍑', '🥭', '🍍', '🥥', '🥝', '🍅', '🍆', '🥑', '🥦', '🥬', '🥒', '🌶️', '🌽', '🥕', '🧄', '🧅', '🥔', '🍠', '🥐', '🥯', '🍞', '🥖', '🥨', '🧀', '🥚', '🍳', '🧈', '🥞', '🧇', '🥓', '🥩', '🍗', '🍖', '🦴', '🌭', '🍔', '🍟', '🍕', '🥪', '🥙', '🧆', '🌮', '🌯', '🥗', '🥘', '🥫', '🍝', '🍜', '🍲', '🍛', '🍣', '🍱', '🥟', '🦪', '🍤', '🍙', '🍚', '🍘', '🍥', '🥠', '🥮', '🍢', '🍡', '🍧', '🍨', '🍦', '🥧', '🧁', '🍰', '🎂', '🍮', '🍭', '🍬', '🍫', '🍿', '🍩', '🍪', '🌰', '🥜', '🍯', '🥛', '🍼', '☕', '🍵', '🧃', '🥤', '🍶', '🍺', '🍻', '🥂', '🍷', '🥃', '🍸', '🍹', '🧉', '🍾', '🧊'],
            'activities': ['⚽', '🏀', '🏈', '⚾', '🥎', '🎾', '🏐', '🏉', '🥏', '🎱', '🪀', '🏓', '🏸', '🏒', '🏑', '🥍', '🏏', '🥅', '⛳', '🪁', '🏹', '🎣', '🤿', '🥊', '🥋', '🎽', '🛹', '🛷', '⛸️', '🥌', '🎿', '⛷️', '🏂', '🪂', '🏋️', '🤼', '🤸', '🤺', '🤾', '🏌️', '🏇', '🧘', '🏄', '🏊', '🤽', '🚣', '🧗', '🚴', '🚵', '🎪', '🎭', '🎨', '🎬', '🎤', '🎧', '🎼', '🎹', '🥁', '🎷', '🎺', '🎸', '🪕', '🎻', '🎲', '♟️', '🎯', '🎳', '🎮', '🎰', '🧩'],
            'nature': ['🐵', '🐒', '🦍', '🦧', '🐶', '🐕', '🦮', '🐕‍🦺', '🐩', '🐺', '🦊', '🦝', '🐱', '🐈', '🐈‍⬛', '🦁', '🐯', '🐅', '🐆', '🐴', '🐎', '🦄', '🦓', '🦌', '🦬', '🐮', '🐂', '🐃', '🐄', '🐷', '🐖', '🐗', '🐽', '🐏', '🐑', '🐐', '🐪', '🐫', '🦙', '🦒', '🐘', '🦣', '🦏', '🦛', '🐭', '🐁', '🐀', '🐹', '🐰', '🐇', '🐿️', '🦫', '🦔', '🦇', '🐻', '🐻‍❄️', '🐨', '🐼', '🦥', '🦦', '🦨', '🦘', '🦡', '🐾', '🦃', '🐔', '🐓', '🐣', '🐤', '🐥', '🐦', '🐧', '🕊️', '🦅', '🦆', '🦢', '🦉', '🦤', '🪶', '🦩', '🦚', '🦜', '🐸', '🐊', '🐢', '🦎', '🐍', '🐲', '🐉', '🦕', '🦖', '🐳', '🐋', '🐬', '🦭', '🐟', '🐠', '🐡', '🦈', '🐙', '🐚', '🐌', '🦋', '🐛', '🐜', '🐝', '🪲', '🐞', '🦗', '🪳', '🕷️', '🕸️', '🦂', '🦟', '🪰', '🪱', '🦠', '💐', '🌸', '💮', '🏵️', '🌹', '🥀', '🌺', '🌻', '🌼', '🌷', '🌱', '🪴', '🌲', '🌳', '🌴', '🌵', '🌾', '🌿', '☘️', '🍀', '🍁', '🍂', '🍃']
        };
        this.emojiMap = {
            'smile': '😊', 'laugh': '😂', 'rofl': '🤣', 'love': '😍', 'heart_eyes': '🥰',
            'kiss': '😘', 'cool': '😎', 'thinking': '🤔', 'cry': '😢', 'sob': '😭',
            'angry': '😡', 'rage': '🤬', 'scream': '😱', 'fearful': '😨', 'anxious': '😰',
            'sad': '😥', 'disappointed': '😓', 'hug': '🤗', 'shush': '🤭', 'quiet': '🤫',
            'lying': '🤥', 'neutral': '😐', 'expressionless': '😑', 'grimace': '😬', 'eye_roll': '🙄',
            'surprised': '😯', 'frowning': '😦', 'anguished': '😧', 'shocked': '😮', 'astonished': '😲',
            'yawn': '🥱', 'sleeping': '😴', 'drool': '🤤', 'sleepy': '😪', 'dizzy': '😵',
            'zipper': '🤐', 'woozy': '🥴', 'sick': '🤢', 'vomit': '🤮', 'sneeze': '🤧',
            'mask': '😷', 'thermometer': '🤒', 'bandage': '🤕', 'money': '🤑', 'cowboy': '🤠',
            'devil': '😈', 'imp': '👿', 'ogre': '👹', 'goblin': '👺', 'clown': '🤡',
            'poop': '💩', 'ghost': '👻', 'skull': '💀', 'alien': '👽', 'robot': '🤖',
            'jack': '🎃', 'cat_smile': '😺', 'cat_grin': '😸', 'cat_joy': '😹', 'cat_love': '😻',
            'cat_smirk': '😼', 'cat_kiss': '😽', 'cat_scream': '🙀', 'cat_cry': '😿', 'cat_angry': '😾',
            'thumbsup': '👍', 'thumbsdown': '👎', 'ok': '👌', 'peace': '✌️', 'crossed': '🤞',
            'rock': '🤟', 'metal': '🤘', 'call': '🤙', 'left': '👈', 'right': '👉',
            'up': '👆', 'down': '👇', 'point': '☝️', 'hand': '✋', 'backhand': '🤚',
            'vulcan': '🖖', 'wave': '👋', 'pinch': '🤏', 'writing': '✍️', 'clap': '👏',
            'raised': '🙌', 'open': '👐', 'palms': '🤲', 'handshake': '🤝', 'pray': '🙏',
            'muscle': '💪', 'ear': '👂', 'nose': '👃', 'brain': '🧠', 'eyes': '👀',
            'heart': '❤️', 'orange_heart': '🧡', 'yellow_heart': '💛', 'green_heart': '💚',
            'blue_heart': '💙', 'purple_heart': '💜', 'black_heart': '🖤', 'white_heart': '🤍',
            'brown_heart': '🤎', 'broken': '💔', 'exclamation_heart': '❣️', 'hearts': '💕',
            'revolving': '💞', 'heartbeat': '💓', 'growing': '💗', 'sparkling': '💖',
            'cupid': '💘', 'gift_heart': '💝', 'heart_decoration': '💟',
            '100': '💯', 'boom': '💥', 'fire': '🔥', 'star': '⭐', 'sparkles': '✨',
            'lightning': '⚡', 'warning': '⚠️', 'check': '✅', 'x': '❌', 'question': '❓',
            'exclamation': '❗', 'bangbang': '‼️', 'interrobang': '⁉️', 'zzz': '💤',
            'party': '🎉', 'tada': '🎊', 'gift': '🎁', 'trophy': '🏆', 'medal': '🥇',
            'soccer': '⚽', 'baseball': '⚾', 'basketball': '🏀', 'football': '🏈', 'tennis': '🎾',
            'volleyball': '🏐', 'rugby': '🏉', 'pool': '🎱', 'ping_pong': '🏓', 'badminton': '🏸',
            'hockey': '🏒', 'golf': '⛳', 'fishing': '🎣', 'boxing': '🥊', 'martial_arts': '🥋',
            'running': '🏃', 'walking': '🚶', 'cyclist': '🚴', 'mountain': '⛰️', 'camping': '🏕️',
            'beach': '🏖️', 'sunrise': '🌅', 'sunset': '🌆', 'night': '🌃', 'stars': '🌟',
            'rainbow': '🌈', 'sun': '☀️', 'moon': '🌙', 'cloud': '☁️', 'rain': '🌧️',
            'snow': '❄️', 'snowman': '⛄', 'thunder': '⛈️', 'tornado': '🌪️', 'fog': '🌫️',
            'apple': '🍎', 'banana': '🍌', 'strawberry': '🍓', 'cherry': '🍒', 'peach': '🍑',
            'watermelon': '🍉', 'grapes': '🍇', 'lemon': '🍋', 'orange': '🍊', 'pineapple': '🍍',
            'mango': '🥭', 'avocado': '🥑', 'broccoli': '🥦', 'corn': '🌽', 'carrot': '🥕',
            'hot_pepper': '🌶️', 'potato': '🥔', 'bread': '🍞', 'cheese': '🧀', 'egg': '🥚',
            'bacon': '🥓', 'hamburger': '🍔', 'fries': '🍟', 'pizza': '🍕', 'hotdog': '🌭',
            'sandwich': '🥪', 'taco': '🌮', 'burrito': '🌯', 'sushi': '🍣', 'ramen': '🍜',
            'spaghetti': '🍝', 'cake': '🎂', 'birthday': '🎂', 'pie': '🥧', 'donut': '🍩',
            'cookie': '🍪', 'chocolate': '🍫', 'candy': '🍬', 'lollipop': '🍭', 'honey': '🍯',
            'coffee': '☕', 'tea': '🍵', 'beer': '🍺', 'beers': '🍻', 'wine': '🍷',
            'cocktail': '🍸', 'tropical': '🍹', 'champagne': '🍾', 'sake': '🍶', 'milk': '🥛',
            'computer': '💻', 'desktop': '🖥️', 'printer': '🖨️', 'keyboard': '⌨️', 'mouse': '🖱️',
            'trackball': '🖲️', 'joystick': '🕹️', 'cd': '💿', 'dvd': '📀', 'vhs': '📼',
            'camera': '📷', 'video': '📹', 'movie': '🎥', 'phone': '📱', 'telephone': '☎️',
            'tv': '📺', 'radio': '📻', 'speaker': '🔊', 'mute': '🔇', 'bell': '🔔',
            'alarm': '⏰', 'stopwatch': '⏱️', 'timer': '⏲️', 'clock': '🕐', 'hourglass': '⌛',
            'mag': '🔍', 'bulb': '💡', 'flashlight': '🔦', 'candle': '🕯️', 'book': '📖',
            'books': '📚', 'newspaper': '📰', 'scroll': '📜', 'memo': '📝', 'pencil': '✏️',
            'pen': '🖊️', 'paintbrush': '🖌️', 'crayon': '🖍️', 'scissors': '✂️', 'pushpin': '📌',
            'paperclip': '📎', 'link': '🔗', 'chains': '⛓️', 'lock': '🔒', 'unlock': '🔓',
            'key': '🔑', 'hammer': '🔨', 'axe': '🪓', 'pick': '⛏️', 'wrench': '🔧',
            'screwdriver': '🪛', 'gear': '⚙️', 'clamp': '🗜️', 'balance': '⚖️', 'magnet': '🧲',
            'ladder': '🪜', 'test_tube': '🧪', 'petri': '🧫', 'dna': '🧬', 'microscope': '🔬',
            'telescope': '🔭', 'satellite': '📡', 'syringe': '💉', 'pill': '💊', 'adhesive': '🩹',
            'stethoscope': '🩺', 'thermometer_face': '🌡️', 'broom': '🧹', 'basket': '🧺', 'roll': '🧻',
            'soap': '🧼', 'sponge': '🧽', 'bucket': '🪣', 'toothbrush': '🪥',
            'gaming': '🎮', 'dice': '🎲', 'dart': '🎯', 'bowling': '🎳', 'slot': '🎰',
            'puzzle': '🧩', 'teddy': '🧸', 'spades': '♠️', 'hearts_suit': '♥️', 'diamonds': '♦️',
            'clubs': '♣️', 'chess': '♟️', 'mahjong': '🀄',
            'car': '🚗', 'taxi': '🚕', 'bus': '🚌', 'truck': '🚚', 'racing': '🏎️',
            'ambulance': '🚑', 'firetruck': '🚒', 'police': '🚓', 'motorcycle': '🏍️', 'bike': '🚲',
            'scooter': '🛴', 'skateboard': '🛹', 'train': '🚆', 'metro': '🚇', 'tram': '🚊',
            'monorail': '🚝', 'railway': '🚞', 'helicopter': '🚁', 'airplane': '✈️', 'rocket': '🚀',
            'ufo': '🛸', 'ship': '🚢', 'boat': '⛵', 'speedboat': '🚤', 'anchor': '⚓',
            'shrug': '🤷', 'facepalm': '🤦', 'celebrate': '🙌', 'mind_blown': '🤯',
            'money_face': '🤑', 'nerd': '🤓', 'sunglasses': '😎', 'upside_down': '🙃',
            'wink': '😉', 'stuck_out': '😛', 'zany': '🤪', 'raised_eyebrow': '🤨',
            'smirk': '😏', 'unamused': '😒', 'sweat': '😅', 'cold_sweat': '😰',
            'scream_cat': '🙀', 'pouting': '😡', 'triumph': '😤', 'relieved': '😌',
            'pensive': '😔', 'confused': '😕', 'worried': '😟', 'flushed': '😳',
            'hot': '🥵', 'cold': '🥶', 'exploding': '🤯', 'monocle': '🧐', 'nauseous': '🤢'
        };
        this.discoveredChannelsIndex = 0;
        this.swipeStartX = null;
        this.swipeThreshold = 50;
        this.enhancedEmojiModal = null;
        this.loadRecentEmojis();
        this.lightningAddress = null;
        this.userLightningAddresses = new Map();
        this.userAvatars = new Map();
        this.nostrConnect = null;
        this.usingNostrConnect = false;
        this.profileFetchQueue = [];
        this.profileFetchTimer = null;
        this.profileFetchBatchDelay = 100;
        this.localActiveStyle = null;
        this.localActiveFlair = null;
        this.shopItemsLoaded = false;
        this.shopPurchasesTimestamp = 0;
        this.zaps = new Map();
        this.currentZapTarget = null;
        this.currentZapInvoice = null;
        this.pendingLightningWaiters = new Map();
        this.zapCheckInterval = null;
        this.zapInvoiceData = null;
        this.listExpansionStates = new Map();
        this.userLocation = null;
        this.userColors = new Map();
        this.blurOthersImages = true;
        this.imageBlurSettings = this.loadImageBlurSettings();
        this.sortByProximity = localStorage.getItem('nym_sort_proximity') === 'true';
        this.verifiedDeveloper = {
            npub: 'npub16jdfqgazrkapk0yrqm9rdxlnys7ck39c7zmdzxtxqlmmpxg04r0sd733sv',
            pubkey: 'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df',
            title: 'NYM Developer'
        };
        this.isFlutterWebView = navigator.userAgent.includes('NYMApp') ||
            navigator.userAgent.includes('Flutter');

        if (this.isFlutterWebView) {
        }
        this.shopItems = {
            styles: [
                {
                    id: 'style-satoshi',
                    name: 'Satoshi',
                    description: 'Bitcoin-themed orange glow',
                    price: 21420,
                    preview: 'style-preview-satoshi',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Satoshi (Bitcoin)">
<title>Satoshi (Bitcoin)</title>
<circle cx="12" cy="12" r="9"/>
<path d="M10 6v12"/>
<path d="M10 7H13C15.1 7 16.5 8.2 16.5 9.8C16.5 11.4 15.1 12.5 13 12.5H10"/>
<path d="M10 12.5H13C15.1 12.5 16.5 13.7 16.5 15.3C16.5 16.9 15.1 18 13 18H10"/>
<path d="M12.5 5v2"/>
<path d="M12.5 17v2"/>
</svg>`
                },
                {
                    id: 'style-glitch',
                    name: 'Glitch',
                    description: 'Digital glitch effect',
                    price: 10101,
                    preview: 'style-preview-glitch',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Glitch">
<title>Glitch</title>
<rect x="3" y="5" width="18" height="12" rx="2"/>
<path d="M6 9H11 M13 9H18 M5 12H12 M14 12H17 M7 15H11 M12 15H18"/>
</svg>`
                },
                {
                    id: 'style-aurora',
                    name: 'Aurora',
                    description: 'Shifting neon aurora gradient',
                    price: 2424,
                    preview: 'style-preview-aurora',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Aurora">
<title>Aurora</title>
<path d="M2 15 Q7 12 12 15 T22 15"/>
<path d="M2 12 Q7 9 12 12 T22 12"/>
<path d="M2 9 Q7 6 12 9 T22 9"/>
</svg>`
                },
                {
                    id: 'style-neon',
                    name: 'Neon',
                    description: 'Cyberpunk neon purple',
                    price: 1984,
                    preview: 'style-preview-neon',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Neon">
<title>Neon</title>
<rect x="3.5" y="5" width="17" height="12" rx="3"/>
<path d="M17 8v2 M16 9h2"/>
</svg>`
                },
                {
                    id: 'style-ghost',
                    name: 'Ghost',
                    description: 'Mysterious ethereal fade',
                    price: 666,
                    preview: 'style-preview-ghost',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Ghost">
<title>Ghost</title>
<path d="M12 4c-3.5 0-6 2.6-6 6v5.5c0 .8.7 1.5 1.5 1.5.7 0 1.3-.4 1.9-.9.6.6 1.4.9 2.6.9s2-.3 2.6-.9c.6.5 1.2.9 1.9.9.8 0 1.5-.7 1.5-1.5V10c0-3.4-2.5-6-6-6Z"/>
<circle cx="9.5" cy="11" r="1" fill="currentColor" stroke="none"/>
<circle cx="14.5" cy="11" r="1" fill="currentColor" stroke="none"/>
</svg>`
                },
                {
                    id: 'style-matrix',
                    name: 'Matrix',
                    description: 'Green terminal glow effect',
                    price: 1337,
                    preview: 'style-preview-matrix',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Matrix">
<title>Matrix</title>
<rect x="3" y="5" width="18" height="12" rx="2"/>
<path d="M2 19H22"/>
<path d="M7 9V12 M10 8V12 M13 10V13 M16 8.5V13"/>
</svg>`
                },
                {
                    id: 'style-fire',
                    name: 'Fire',
                    description: 'Burning hot flame effect',
                    price: 911,
                    preview: 'style-preview-fire',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Fire">
<title>Fire</title>
<path d="M12 3c3 3 6 6 6 9.5 0 3.6-2.7 6.5-6 6.5s-6-2.9-6-6.5C6 9 9 6 12 3Z"/>
<path d="M12 8c1.9 1.7 3 3.4 3 5 0 1.9-1.3 3.5-3 3.5s-3-1.6-3-3.5c0-1.6 1.1-3.3 3-5Z"/>
</svg>`
                },
                {
                    id: 'style-ice',
                    name: 'Ice',
                    description: 'Cool frozen text effect',
                    price: 777,
                    preview: 'style-preview-ice',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Ice">
<title>Ice</title>
<path d="M12 2V22"/>
<path d="M2 12H22"/>
<path d="M4.9 6.5L19.1 17.5"/>
<path d="M19.1 6.5L4.9 17.5"/>
</svg>`
                },
                {
                    id: 'style-rainbow',
                    name: 'Rainbow',
                    description: 'Animated rainbow gradient',
                    price: 2222,
                    preview: 'style-preview-rainbow',
                    type: 'message-style',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Rainbow">
<title>Rainbow</title>
<path d="M4 16a8 8 0 0 1 16 0"/>
<path d="M6.5 16a5.5 5.5 0 0 1 11 0"/>
<path d="M9 16a3 3 0 0 1 6 0"/>
</svg>`
                }
            ],
            flair: [
                {
                    id: 'flair-crown',
                    name: 'Crown',
                    description: 'Royal golden crown badge',
                    price: 5000,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Crown">
<title>Crown</title>
<polyline points="3 9 7 13 12 7 17 13 21 9"/>
<path d="M5 18V13l4 2 3-5 3 5 4-2v5"/>
<path d="M4 18h16"/>
</svg>`
                },
                {
                    id: 'flair-diamond',
                    name: 'Diamond',
                    description: 'Sparkling diamond badge',
                    price: 10000,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Diamond">
<title>Diamond</title>
<polygon points="12 3 19 9 12 21 5 9"/>
<path d="M5 9h14"/>
<path d="M12 3L9 9M12 3L15 9"/>
</svg>`
                },
                {
                    id: 'flair-skull',
                    name: 'Skull',
                    description: 'Badass skull badge',
                    price: 1666,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Skull">
<title>Skull</title>
<circle cx="12" cy="10" r="5.5"/>
<rect x="8" y="14.5" width="8" height="4" rx="1.2"/>
<circle cx="9.5" cy="10" r="1.2"/>
<circle cx="14.5" cy="10" r="1.2"/>
<path d="M11.2 12.8 12 11.2 12.8 12.8Z"/>
<path d="M10 14.5v2M12 14.5v2M14 14.5v2"/>
</svg>`
                },
                {
                    id: 'flair-star',
                    name: 'Star',
                    description: 'Shining star badge',
                    price: 2500,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Star">
<title>Star</title>
<polygon points="12 2 14.8 8.2 21.5 9 16.5 13.4 17.9 20 12 16.8 6.1 20 7.5 13.4 2.5 9 9.2 8.2"/>
</svg>`
                },
                {
                    id: 'flair-lightning',
                    name: 'Lightning',
                    description: 'Electric lightning bolt badge',
                    price: 2100,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Lightning">
<title>Lightning</title>
<polygon points="13 2 6 12 11 12 9 22 18 10 13 10"/>
</svg>`
                },
                {
                    id: 'flair-heart',
                    name: 'Heart',
                    description: 'Loving heart badge',
                    price: 1111,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Heart">
<title>Heart</title>
<path d="M12 21
    C7 17 4 14 4 10
    C4 7 6 5 9 5
    C11 5 12 7 12 7
    C12 7 13 5 15 5
    C18 5 20 7 20 10
    C20 14 17 17 12 21Z"/>
</svg>`
                },
                {
                    id: 'flair-mask',
                    name: 'Fawkes',
                    description: 'Anonymous mask badge',
                    price: 4200,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Mask">
<title>Mask</title>
<path d="M12 4c-4.4 0-8 1.8-8 4v3c0 4.6 3.6 8.6 8 9
    c4.4-.4 8-4.4 8-9V8c0-2.2-3.6-4-8-4Z"/>
<path d="M7.5 11c.9-1.2 2.7-1.2 3.5 0"/>
<path d="M13 11c.9-1.2 2.7-1.2 3.5 0"/>
<path d="M8 14c1.4 1 2.6 1 4 0c1.4 1 2.6 1 4 0"/>
</svg>`
                },
                {
                    id: 'flair-rocket',
                    name: 'Rocket',
                    description: 'To the moon badge',
                    price: 2300,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Rocket">
<title>Rocket</title>
<polygon points="12 3 15 8 9 8"/>
<rect x="9" y="8" width="6" height="7" rx="3"/>
<circle cx="12" cy="11.5" r="1.6"/>
<polygon points="9 13 6.5 15 9 16"/>
<polygon points="15 13 17.5 15 15 16"/>
<polygon points="12 15.5 10.7 19 12 18 13.3 19"/>
</svg>`
                },
                {
                    id: 'flair-shield',
                    name: 'Shield',
                    description: 'Supporter of encryption badge',
                    price: 1900,
                    type: 'nickname-flair',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Shield">
<title>Shield</title>
<path d="M12 3l7 3v5c0 5-3.3 8.2-7 9.6C8.3 19.2 5 16 5 11V6l7-3Z"/>
<path d="M12 5v13"/>
</svg>`
                }

            ],
            special: [
                {
                    id: 'supporter-badge',
                    name: 'NYM Supporter',
                    description: 'Special supporter badge with golden messages',
                    price: 42069,
                    type: 'supporter',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Trophy">
<title>Trophy</title>
<path d="M8 21H16"/>
<path d="M12 17V21"/>
<path d="M7 9h10v2a5 5 0 0 1-5 5a5 5 0 0 1-5-5V9z"/>
<path d="M5 9H3a3 3 0 0 0 3 3"/>
<path d="M19 9h2a3 3 0 0 1-3 3"/>
</svg>`
                },
                {
                    id: 'cosmetic-aura-gold',
                    name: 'Gold Aura',
                    description: 'Golden glow around your messages',
                    price: 3500,
                    type: 'cosmetic',
                    cssClass: 'cosmetic-aura-gold',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Gold Aura">
<title>Gold Aura</title>
<circle cx="12" cy="12" r="8"/>
<circle cx="12" cy="12" r="5"/>
</svg>`
                },
                {
                    id: 'cosmetic-redacted',
                    name: 'Redacted',
                    description: 'Remove each message after 10 seconds',
                    price: 2800,
                    type: 'cosmetic',
                    cssClass: 'cosmetic-redacted',
                    icon: `
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"
width="1em" height="1em" fill="none" stroke="currentColor"
stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"
vector-effect="non-scaling-stroke" role="img" aria-label="Redacted">
<title>Redacted</title>
<line x1="4" y1="8" x2="20" y2="8"/>
<line x1="4" y1="12" x2="16" y2="12"/>
<line x1="4" y1="16" x2="18" y2="16"/>
</svg>`
                }
            ]
        };

        this.userPurchases = new Map();
        this.activeShopTab = 'styles';
        this.activeMessageStyle = null;
        this.activeFlair = null;
        this.otherUsersShopItems = new Map();
        this.shopItemsCache = new Map();
        this.activeCosmetics = new Set();
        this.loadShopActiveCache();
        setTimeout(() => {
            const cachedStyle = localStorage.getItem('nym_active_style');
            const cachedFlair = localStorage.getItem('nym_active_flair');

            if (cachedStyle && cachedStyle !== '' && !this.activeMessageStyle) {
                this.activeMessageStyle = cachedStyle;
                this.localActiveStyle = cachedStyle;
            }

            if (cachedFlair && cachedFlair !== '' && !this.activeFlair) {
                this.activeFlair = cachedFlair;
                this.localActiveFlair = cachedFlair;
            }
        }, 0);
    }

    // NIP-13: Validate proof of work
    validatePow(event, minimumDifficulty = 0) {
        if (minimumDifficulty === 0) return true;

        const pow = NostrTools.nip13.getPow(event.id);

        // Check if event has a nonce tag (optional but recommended)
        const nonceTag = event.tags?.find(t => t[0] === 'nonce');

        return pow >= minimumDifficulty;
    }

    // Cache "active items"
    loadShopActiveCache() {
        try {
            const raw = localStorage.getItem('nym_shop_active_cache');
            if (!raw) return;
            const cache = JSON.parse(raw);
            const now = Date.now();
            const maxAge = 24 * 60 * 60 * 1000; // 24 hours

            for (const [pubkey, entry] of Object.entries(cache)) {
                if (entry && entry.items && (now - entry.ts < maxAge)) {
                    this.otherUsersShopItems.set(pubkey, entry.items);
                    // Also store in memory cache with timestamp
                    this.shopItemsCache.set(pubkey, {
                        items: entry.items,
                        timestamp: entry.ts,
                        eventCreatedAt: entry.eventCreatedAt || 0
                    });
                }
            }
        } catch (e) { /* ignore */ }
    }

    cacheShopActiveItems(pubkey, items, eventCreatedAt = 0) {
        try {
            const raw = localStorage.getItem('nym_shop_active_cache');
            const cache = raw ? JSON.parse(raw) : {};
            cache[pubkey] = {
                items,
                ts: Date.now(),
                eventCreatedAt: eventCreatedAt
            };
            localStorage.setItem('nym_shop_active_cache', JSON.stringify(cache));

            // Also update memory cache
            this.shopItemsCache.set(pubkey, {
                items: items,
                timestamp: Date.now(),
                eventCreatedAt: eventCreatedAt
            });
        } catch (e) { /* ignore */ }
    }

    // Build current user's active items object used for broadcast
    _buildActiveItemsPayload() {
        return {
            style: this.activeMessageStyle || null,
            flair: this.activeFlair || null,
            supporter: this.userPurchases.has('supporter-badge'),
            cosmetics: Array.from(this.activeCosmetics || [])
        };
    }

    // Publish current user's active shop items
    async publishActiveShopItems() {
        if (!this.pubkey) return;

        const payload = this._buildActiveItemsPayload();

        // Cache locally for immediate access
        this.localActiveStyle = this.activeMessageStyle;
        this.localActiveFlair = this.activeFlair;
        localStorage.setItem('nym_active_style', this.activeMessageStyle || '');
        localStorage.setItem('nym_active_flair', this.activeFlair || '');

        const evt = {
            kind: 30078,
            created_at: Math.floor(Date.now() / 1000),
            tags: [
                ['d', 'nym-shop-active'],
                ['title', 'NYM Shop Active Items']
            ],
            content: JSON.stringify(payload),
            pubkey: this.pubkey
        };

        let signed;
        if (this.connectionMode === 'extension' && window.nostr) {
            signed = await window.nostr.signEvent(evt);
        } else if (this.privkey) {
            signed = window.NostrTools.finalizeEvent(evt, this.privkey);
        }
        if (signed) this.sendToRelay(['EVENT', signed]);
    }

    loadCachedShopItems() {

        if (!this.pubkey) {
            return;
        }

        // Try to load from localStorage cache first
        const cachedStyle = localStorage.getItem('nym_active_style');
        const cachedFlair = localStorage.getItem('nym_active_flair');


        if (cachedStyle && cachedStyle !== '') {
            this.activeMessageStyle = cachedStyle;
            this.localActiveStyle = cachedStyle;
        }

        if (cachedFlair && cachedFlair !== '') {
            this.activeFlair = cachedFlair;
            this.localActiveFlair = cachedFlair;
        }


        // Apply to any existing messages immediately
        this.applyShopStylesToOwnMessages();
    }

    applyShopStylesToOwnMessages() {
        if (!this.pubkey) return;

        const ownMessages = document.querySelectorAll(`.message[data-pubkey="${this.pubkey}"]`);

        ownMessages.forEach(msg => {
            // Remove previous styling classes
            [...msg.classList].forEach(cls => {
                if (cls.startsWith('style-') || cls.startsWith('cosmetic-') || cls === 'supporter-style') {
                    msg.classList.remove(cls);
                }
            });

            // Add active message style
            if (this.activeMessageStyle) {
                msg.classList.add(this.activeMessageStyle);
            }

            // Add supporter badge if owned
            if (this.userPurchases.has('supporter-badge')) {
                msg.classList.add('supporter-style');
            }

            // Add active cosmetics
            if (this.activeCosmetics && this.activeCosmetics.size > 0) {
                this.activeCosmetics.forEach(c => {
                    if (c === 'cosmetic-aura-gold') {
                        msg.classList.add('cosmetic-aura-gold');
                    }
                    if (c === 'cosmetic-redacted') {
                        const auth = msg.querySelector('.message-author');
                        if (auth) auth.classList.add('cosmetic-redacted');

                        // Apply redacted effect to message content after 10 seconds
                        const contentEl = msg.querySelector('.message-content');
                        if (contentEl && !contentEl.classList.contains('cosmetic-redacted-message')) {
                            setTimeout(() => {
                                contentEl.classList.add('cosmetic-redacted-message');
                            }, 10000);
                        }
                    }
                });
            }
        });

    }

    activateCosmetic(itemId) {
        // ensure item exists and is cosmetic
        const item = this.getShopItemById(itemId);
        if (!item || item.type !== 'cosmetic') return;

        if (this.activeCosmetics.has(itemId)) {
            this.activeCosmetics.delete(itemId);
            this.displaySystemMessage(`❎ Deactivated ${item.name}`);
        } else {
            this.activeCosmetics.add(itemId);
            this.displaySystemMessage(`🟡 Activated ${item.name}`);
        }
        // Save & broadcast
        this.savePurchaseToNostr();
        this.publishActiveShopItems();

        // Refresh inventory tab if open
        if (document.getElementById('shopModal').classList.contains('active') &&
            this.activeShopTab === 'inventory') {
            this.renderInventoryTab(document.getElementById('shopBody'));
        }
    }

    async openShop() {
        const modal = document.getElementById('shopModal');
        modal.classList.add('active');

        // Show loading state
        const shopBody = document.getElementById('shopBody');
        shopBody.innerHTML = `
<div class="shop-loading">
    <div class="shop-loading-spinner"></div>
    <div class="shop-loading-text">Loading shop items...</div>
</div>
`;

        // Display default tab
        this.switchShopTab('styles');
    }

    closeShop() {
        const modal = document.getElementById('shopModal');
        modal.classList.remove('active');
    }

    switchShopTab(tab, event) {
        this.activeShopTab = tab;

        // Update tab buttons
        document.querySelectorAll('.shop-tab').forEach(btn => {
            btn.classList.remove('active');
        });
        if (event && event.target) {
            event.target.classList.add('active');
        } else {
            // Fallback if event not provided
            document.querySelector(`.shop-tab:nth-child(${['styles', 'flair', 'special', 'inventory'].indexOf(tab) + 1})`).classList.add('active');
        }

        // Update content
        const shopBody = document.getElementById('shopBody');

        switch (tab) {
            case 'styles':
                this.renderStylesTab(shopBody);
                break;
            case 'flair':
                this.renderFlairTab(shopBody);
                break;
            case 'special':
                this.renderSpecialTab(shopBody);
                break;
            case 'inventory':
                this.renderInventoryTab(shopBody);
                break;
        }
    }

    renderStylesTab(container) {
        let html = '<div class="shop-category-title">Message Styles</div>';
        html += '<div class="shop-items">';

        this.shopItems.styles.forEach(item => {
            const isPurchased = this.userPurchases.has(item.id);
            html += `
    <div class="shop-item ${isPurchased ? 'purchased' : ''}" onclick="${!isPurchased ? `nym.purchaseItem('${item.id}')` : ''}">
        <div class="shop-item-icon">${item.icon}</div>
        <div class="shop-item-name">${item.name}</div>
        <div class="shop-item-description">${item.description}</div>
        <div class="shop-item-preview">
            <span class="${item.preview}">Preview Message</span>
        </div>
        <div class="shop-item-price">
            <span class="shop-price-amount">⚡ ${item.price} sats</span>
            ${!isPurchased ? '<button class="shop-buy-btn">BUY</button>' : ''}
        </div>
    </div>
`;
        });

        html += '</div>';
        container.innerHTML = html;
    }

    renderFlairTab(container) {
        let html = '<div class="shop-category-title">Nickname Flair</div>';
        html += '<div class="shop-items">';

        this.shopItems.flair.forEach(item => {
            const isPurchased = this.userPurchases.has(item.id);
            html += `
    <div class="shop-item ${isPurchased ? 'purchased' : ''}" onclick="${!isPurchased ? `nym.purchaseItem('${item.id}')` : ''}">
        <div class="shop-item-icon">${item.icon}</div>
        <div class="shop-item-name">${item.name}</div>
        <div class="shop-item-description">${item.description}</div>
        <div class="shop-item-preview">
            <span>Your_Nick <span class="flair-badge ${item.id.replace('flair-', 'flair-')}">${item.icon}</span></span>
        </div>
        <div class="shop-item-price">
            <span class="shop-price-amount">⚡ ${item.price} sats</span>
            ${!isPurchased ? '<button class="shop-buy-btn">BUY</button>' : ''}
        </div>
    </div>
`;
        });

        html += '</div>';
        container.innerHTML = html;
    }

    renderSpecialTab(container) {
        let html = '<div class="shop-category-title">Special Items</div>';
        html += '<div class="shop-items">';

        this.shopItems.special.forEach(item => {
            const isPurchased = this.userPurchases.has(item.id);
            html += `
    <div class="shop-item ${isPurchased ? 'purchased' : ''}" onclick="${!isPurchased ? `nym.purchaseItem('${item.id}')` : ''}">
        <div class="shop-item-icon">${item.icon}</div>
        <div class="shop-item-name">${item.name}</div>
        <div class="shop-item-description">${item.description}</div>
        ${item.benefits ? `
            <div class="shop-item-preview" style="font-size: 11px; text-align: left;">
                ${item.benefits.map(b => `• ${b}`).join('<br>')}
            </div>
        ` : ''}
        <div class="shop-item-price">
            <span class="shop-price-amount">⚡ ${item.price} sats</span>
            ${!isPurchased ? '<button class="shop-buy-btn">BUY</button>' : ''}
        </div>
    </div>
`;
        });

        html += '</div>';
        container.innerHTML = html;
    }

    renderInventoryTab(container) {
        let html = '<div class="shop-category-title">My Items</div>';

        if (this.userPurchases.size === 0) {
            html += '<div style="text-align: center; padding: 40px; color: var(--text-dim);">No items purchased yet</div>';
        } else {
            // Active message style
            const activeStyle = this.getActiveMessageStyle();
            if (activeStyle) {
                html += '<div class="shop-active-items">';
                html += '<div class="shop-active-items-title">Active Message Style</div>';
                html += `<div class="shop-active-item">${activeStyle.name}</div>`;
                html += '</div>';
            }

            // Active flair
            const activeFlair = this.getActiveFlair();
            if (activeFlair) {
                html += '<div class="shop-active-items">';
                html += '<div class="shop-active-items-title">Active Nickname Flair</div>';
                html += `<div class="shop-active-item">${activeFlair.name} ${activeFlair.icon}</div>`;
                html += '</div>';
            }

            // Active cosmetics
            if (this.activeCosmetics.size > 0) {
                html += '<div class="shop-active-items">';
                html += '<div class="shop-active-items-title">Active Cosmetics</div>';
                this.activeCosmetics.forEach(id => {
                    const it = this.getShopItemById(id);
                    if (it) html += `<div class="shop-active-item">${it.icon} ${it.name}</div>`;
                });
                html += '</div>';
            }

            // All purchased items with activate buttons
            html += '<div class="shop-category-title" style="margin-top: 20px;">All Purchased Items</div>';
            html += '<div class="shop-items">';

            this.userPurchases.forEach((purchase, itemId) => {
                const item = this.getShopItemById(itemId);
                if (!item) return;

                html += `
    <div class="shop-item purchased">
        <div class="shop-item-icon">${item.icon}</div>
        <div class="shop-item-name">${item.name}</div>
        <div class="shop-item-description">${item.description}</div>
        <div style="font-size: 10px; color: var(--text-dim); margin-top: 10px;">
            Purchased: ${new Date(purchase.timestamp * 1000).toLocaleDateString()}
        </div>
    `;

                if (item.type === 'message-style') {
                    const isActive = this.activeMessageStyle === itemId;
                    html += `
<button class="shop-buy-btn" onclick="nym.activateMessageStyle('${itemId}')" style="margin-top: 10px; width: 100%;">
${isActive ? 'DEACTIVATE' : 'ACTIVATE'}
</button>`;
                } else if (item.type === 'nickname-flair') {
                    const isActive = this.activeFlair === itemId;
                    html += `
<button class="shop-buy-btn" onclick="nym.activateFlair('${itemId}')" style="margin-top: 10px; width: 100%;">
${isActive ? 'DEACTIVATE' : 'ACTIVATE'}
</button>`;
                } else if (item.type === 'cosmetic') {
                    const isOn = this.activeCosmetics.has(itemId);
                    html += `
<button class="shop-buy-btn" onclick="nym.activateCosmetic('${itemId}')" style="margin-top: 10px; width: 100%;">
${isOn ? 'DEACTIVATE' : 'ACTIVATE'}
</button>`;
                } else if (item.type === 'supporter') {
                    // Supporter has no toggle (always on once owned)
                    html += `<div class="shop-item-preview"><span class="supporter-badge"><span class="supporter-badge-icon">🏆</span><span class="supporter-badge-text">Supporter</span></span></div>`;
                }

                html += `</div>`;
            });

            html += '</div>';
        }

        container.innerHTML = html;
    }

    getShopItemById(itemId) {
        const allItems = [
            ...this.shopItems.styles,
            ...this.shopItems.flair,
            ...this.shopItems.special
        ];
        return allItems.find(item => item.id === itemId);
    }

    async purchaseItem(itemId) {
        const item = this.getShopItemById(itemId);
        if (!item) return;

        // Generate Lightning invoice
        await this.generateShopInvoice(itemId, item.price);
    }

    async generateShopInvoice(itemId, amount) {
        const item = this.getShopItemById(itemId);

        // Store the purchase context
        this.currentPurchaseContext = {
            type: 'shop',
            itemId: itemId,
            item: item,
            amount: amount
        };

        // Create a zap modal for payment
        const zapModal = document.getElementById('zapModal');

        // Update zap modal for shop purchase
        document.getElementById('zapRecipientInfo').innerHTML = `
<div>Purchasing: <strong>${item.name}</strong></div>
<div style="font-size: 12px; margin-top: 5px; color: var(--warning);">Price: ${amount} sats</div>
`;

        // Hide preset amounts for shop purchases
        const zapAmountsContainer = document.querySelector('.zap-amounts');
        if (zapAmountsContainer) {
            zapAmountsContainer.style.display = 'none';
        }

        const customFormlabel = document.getElementById('zapAmountSection');
        if (customFormlabel) {
            customFormlabel.style.display = 'none';
        }

        // Set and lock the custom amount
        const customAmountInput = document.getElementById('zapCustomAmount');
        if (customAmountInput) {
            customAmountInput.style.display = 'none';
        }

        // Hide the comment field for shop purchases
        const commentSection = document.querySelector('.zap-comment');
        if (commentSection) {
            commentSection.style.display = 'none';
        }

        // Update send button to use existing invoice generation
        const sendBtn = document.getElementById('zapSendBtn');
        sendBtn.textContent = 'Generate Invoice';
        sendBtn.onclick = () => {
            this.generateShopPaymentInvoice();
        };

        // Open zap modal (will be above shop modal due to z-index fix)
        zapModal.classList.add('active');
    }

    async generateShopPaymentInvoice() {
        if (!this.currentPurchaseContext || this.currentPurchaseContext.type !== 'shop') {
            return;
        }

        const { itemId, item, amount } = this.currentPurchaseContext;

        // Show loading state
        document.getElementById('zapAmountSection').style.display = 'none';
        document.getElementById('zapInvoiceSection').style.display = 'block';
        document.getElementById('zapStatus').className = 'zap-status checking';
        document.getElementById('zapStatus').innerHTML = '<span class="loader"></span> Generating invoice...';

        try {
            // Set up a temporary zap target for the shop
            const originalZapTarget = this.currentZapTarget;
            this.currentZapTarget = {
                recipientPubkey: 'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df',
                lnAddress: '69420@wallet.yakihonne.com',
                messageId: null
            };

            // Create zap request event for shop purchase
            const zapRequest = await this.createShopZapRequest(amount, `NYM Shop Purchase: ${item.name}`);

            // Build the LNURL callback with the zap request
            const invoice = await this.fetchShopLightningInvoice(
                '69420@wallet.yakihonne.com',
                amount,
                `NYM Shop Purchase: ${item.name}`,
                zapRequest
            );

            if (invoice) {
                // Store invoice data for verification
                this.currentShopInvoice = {
                    ...invoice,
                    itemId: itemId,
                    item: item,
                    zapRequestId: zapRequest ? zapRequest.id : null
                };

                // Also set currentZapInvoice so openInWallet() works
                this.currentZapInvoice = invoice;

                // Display invoice using existing function
                this.displayZapInvoice(invoice);

                // Start listening for zap receipt
                this.listenForShopZapReceipt(zapRequest);

                // Also check with verify URL if available
                if (invoice.verify) {
                    this.checkShopPayment(invoice);
                }
            }

            // Restore original zap target
            this.currentZapTarget = originalZapTarget;

        } catch (error) {
            document.getElementById('zapStatus').className = 'zap-status error';
            document.getElementById('zapStatus').innerHTML = `❌ Failed: ${error.message}`;

            // Show retry button
            setTimeout(() => {
                document.getElementById('zapAmountSection').style.display = 'block';
                document.getElementById('zapInvoiceSection').style.display = 'none';
                document.getElementById('zapSendBtn').style.display = 'block';
            }, 3000);
        }
    }

    async createShopZapRequest(amountSats, description) {
        try {
            const zapRequest = {
                kind: 9734,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ['p', 'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df'], // Shop is the recipient
                    ['amount', (parseInt(amountSats) * 1000).toString()], // Amount in millisats
                    ['relays', ...this.broadcastRelays.slice(0, 5)], // Limit to 5 relays
                    ['shop-item', this.currentPurchaseContext.itemId], // Custom tag for shop item
                    ['shop-purchase', 'true'] // Flag this as a shop purchase
                ],
                content: description || '',
                pubkey: this.pubkey
            };

            // Sign the request
            const signedEvent = await this.signEvent(zapRequest);

            // Broadcast the zap request to relays
            if (signedEvent) {
                this.sendToRelay(['EVENT', signedEvent]);
            }

            return signedEvent;
        } catch (error) {
            return null;
        }
    }

    async fetchShopLightningInvoice(lnAddress, amountSats, comment, zapRequest) {
        try {
            const [username, domain] = lnAddress.split('@');
            if (!username || !domain) {
                throw new Error('Invalid lightning address format');
            }

            // Fetch LNURL endpoint
            const lnurlResponse = await fetch(`https://${domain}/.well-known/lnurlp/${username}`);
            if (!lnurlResponse.ok) {
                throw new Error('Failed to fetch LNURL endpoint');
            }

            const lnurlData = await lnurlResponse.json();

            // Convert sats to millisats
            const amountMillisats = parseInt(amountSats) * 1000;

            // Check bounds
            if (amountMillisats < lnurlData.minSendable || amountMillisats > lnurlData.maxSendable) {
                throw new Error(`Amount must be between ${lnurlData.minSendable / 1000} and ${lnurlData.maxSendable / 1000} sats`);
            }

            // Build callback URL
            const callbackUrl = new URL(lnurlData.callback);
            callbackUrl.searchParams.set('amount', amountMillisats);

            // Add comment if allowed
            if (comment && lnurlData.commentAllowed) {
                callbackUrl.searchParams.set('comment', comment.substring(0, lnurlData.commentAllowed));
            }

            // Add nostr zap request params
            if (zapRequest && lnurlData.allowsNostr && lnurlData.nostrPubkey) {
                callbackUrl.searchParams.set('nostr', JSON.stringify(zapRequest));
            }

            // Fetch invoice
            const invoiceResponse = await fetch(callbackUrl.toString());
            if (!invoiceResponse.ok) {
                throw new Error('Failed to fetch invoice');
            }

            const invoiceData = await invoiceResponse.json();

            if (invoiceData.pr) {
                return {
                    pr: invoiceData.pr,
                    successAction: invoiceData.successAction,
                    verify: invoiceData.verify,
                    amount: amountSats
                };
            } else {
                throw new Error('No payment request in response');
            }
        } catch (error) {
            throw error;
        }
    }

    listenForShopZapReceipt(zapRequest) {
        if (!zapRequest) return;

        // Store the subscription ID for later cleanup
        this.shopZapReceiptSubId = "shop-zap-" + Math.random().toString(36).substring(7);

        // Subscribe to zap receipts for the shop
        const subscription = [
            "REQ",
            this.shopZapReceiptSubId,
            {
                kinds: [9735],
                "#p": ['d49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df'], // Zaps to the shop
                since: Math.floor(Date.now() / 1000) - 60, // Last minute
                limit: 50
            }
        ];

        this.sendToRelay(subscription);

        // Set timeout to close subscription after 2 minutes
        setTimeout(() => {
            if (this.shopZapReceiptSubId) {
                this.sendToRelay(["CLOSE", this.shopZapReceiptSubId]);
                this.shopZapReceiptSubId = null;
            }
        }, 120000);
    }

    async checkShopPayment(invoice) {
        if (!invoice.verify) {
            // No verify URL, just wait for zap receipt event
            this.listenForZapReceipt();
            return;
        }

        let checkCount = 0;
        const maxChecks = 120; // Check for up to 2 minutes for shop purchases

        this.shopPaymentCheckInterval = setInterval(async () => {
            checkCount++;

            try {
                const response = await fetch(invoice.verify);
                const data = await response.json();

                if (data.settled || data.paid) {
                    // Payment confirmed!
                    clearInterval(this.shopPaymentCheckInterval);
                    this.shopPaymentCheckInterval = null;
                    await this.handleShopPaymentSuccess();
                } else if (checkCount >= maxChecks) {
                    // Timeout
                    clearInterval(this.shopPaymentCheckInterval);
                    this.shopPaymentCheckInterval = null;
                    document.getElementById('zapStatus').style.display = 'block';
                    document.getElementById('zapStatus').className = 'zap-status';
                    document.getElementById('zapStatus').innerHTML = '⏱️ Payment timeout - please check your wallet';
                }
            } catch (error) {
            }
        }, 1000); // Check every second
    }

    // Listen for zap receipt events
    listenForShopZapReceipt() {
        // Subscribe to zap receipt events (kind 9735) for this specific event
        const subscription = [
            "REQ",
            "zap-receipt-" + Math.random().toString(36).substring(7),
            {
                kinds: [9735],
                "#e": [this.currentZapTarget.messageId],
                since: Math.floor(Date.now() / 1000) - 300, // Last 5 minutes
                limit: 10
            }
        ];

        this.sendToRelay(subscription);

        // Also close the subscription after 60 seconds
        setTimeout(() => {
            this.sendToRelay(["CLOSE", subscription[1]]);
        }, 60000);
    }

    async handleShopPaymentSuccess() {
        if (!this.currentPurchaseContext || !this.currentShopInvoice) return;

        const { itemId, item, amount } = this.currentPurchaseContext;

        // Clear check intervals and subscriptions
        if (this.shopPaymentCheckInterval) {
            clearInterval(this.shopPaymentCheckInterval);
            this.shopPaymentCheckInterval = null;
        }

        if (this.shopZapReceiptSubId) {
            this.sendToRelay(["CLOSE", this.shopZapReceiptSubId]);
            this.shopZapReceiptSubId = null;
        }

        // Show success message
        document.getElementById('zapInvoiceDisplay').style.display = 'none';
        document.getElementById('zapStatus').style.display = 'block';
        document.getElementById('zapStatus').className = 'zap-status paid';
        document.getElementById('zapStatus').innerHTML = `
<div style="font-size: 24px; margin-bottom: 10px;">✅</div>
<div>Purchase successful!</div>
<div style="font-size: 16px; margin-top: 10px;">${item.name}</div>
<div style="font-size: 14px; color: var(--text-dim);">${amount} sats</div>
`;

        // Create purchase record with zap event ID if available
        const purchase = {
            itemId: itemId,
            amount: amount,
            timestamp: Math.floor(Date.now() / 1000),
            txid: this.currentShopInvoice.zapRequestId || 'shop_' + Date.now()
        };

        // Store purchase locally
        this.userPurchases.set(itemId, purchase);

        // Auto-activate cosmetics on purchase
        if (item?.type === 'cosmetic') {
            this.activeCosmetics.add(itemId);
        }

        // Save to Nostr
        await this.savePurchaseToNostr(purchase);

        // Publish active items so others see the update
        this.publishActiveShopItems();

        // **NEW: Generate recovery code for ephemeral users**
        const recoveryCode = this.handlePurchaseStrategy();

        // **NEW: If ephemeral, show the recovery code in the success message**
        if (this.connectionMode === 'ephemeral' && recoveryCode) {
            document.getElementById('zapStatus').innerHTML = `
    <div style="font-size: 24px; margin-bottom: 10px;">✅</div>
    <div>Purchase successful!</div>
    <div style="font-size: 16px; margin-top: 10px;">${item.name}</div>
    <div style="font-size: 14px; color: var(--text-dim);">${amount} sats</div>
    <div style="margin-top: 20px; padding: 15px; background: var(--bg-tertiary); border: 1px solid var(--warning); border-radius: 5px;">
        <div style="color: var(--warning); font-weight: bold; margin-bottom: 10px;">⚠️ SAVE YOUR RECOVERY CODE</div>
        <div style="font-size: 12px; color: var(--text-dim); margin-bottom: 10px;">Copy this code to restore your purchase in a new session:</div>
        <div style="font-family: monospace; color: var(--text-bright); font-size: 14px; word-break: break-all; cursor: pointer;" onclick="navigator.clipboard.writeText('${recoveryCode}'); this.textContent = 'Copied!';" title="Click to copy">${recoveryCode}</div>
    </div>
`;
        }

        // Close modals after delay
        setTimeout(() => {
            this.closeZapModal();
            this.closeShop();

            // Refresh shop display
            if (this.activeShopTab) {
                setTimeout(() => {
                    this.openShop();
                    this.switchShopTab('inventory');
                }, 500);
            }
        }, 2000);
    }

    async savePurchaseToNostr(purchaseJustMade = null) {
        if (!this.pubkey) return;

        try {
            // Merge purchase just made into map before saving
            if (purchaseJustMade) {
                this.userPurchases.set(purchaseJustMade.itemId, purchaseJustMade);
            }

            // Build full state
            const allPurchases = Array.from(this.userPurchases.entries()).map(([id, data]) => ({
                id, ...data
            }));

            const purchaseData = {
                purchases: allPurchases,
                activeStyle: this.activeMessageStyle || null,
                activeFlair: this.activeFlair || null,
                activeCosmetics: Array.from(this.activeCosmetics || [])
            };

            // Cache to localStorage (CRITICAL)
            localStorage.setItem('nym_active_style', this.activeMessageStyle || '');
            localStorage.setItem('nym_active_flair', this.activeFlair || '');

            const purchaseEvent = {
                kind: 30078,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ["d", "nym-shop-purchases"],
                    ["title", "NYM Shop Purchases"]
                ],
                content: JSON.stringify(purchaseData),
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(purchaseEvent);
            if (signedEvent) {
                this.sendToRelay(["EVENT", signedEvent]);
            }
        } catch (error) {
        }
    }

    async loadUserPurchases() {
        if (!this.pubkey) return;

        // Load from local cache immediately
        this.loadCachedShopItems();

        // Request shop purchases from Nostr
        const subscriptionId = "shop-" + Math.random().toString(36).substring(7);
        const subscription = [
            "REQ",
            subscriptionId,
            {
                kinds: [30078],
                authors: [this.pubkey],
                "#d": ["nym-shop-purchases", "nym-shop-active"],
                limit: 10  // Get last 10 events to ensure we have the latest
            }
        ];

        this.sendToRelay(subscription);

        // Wait for response
        return new Promise((resolve) => {
            setTimeout(() => {
                this.sendToRelay(["CLOSE", subscriptionId]);
                this.shopItemsLoaded = true;

                // After loading, publish current active set so others see us
                this.publishActiveShopItems();

                // Apply styles to any messages already displayed
                this.applyShopStylesToOwnMessages();

                resolve();
            }, 3000);
        });
    }

    getUserShopItems(pubkey) {
        if (pubkey === this.pubkey) {
            return {
                style: this.activeMessageStyle,
                flair: this.activeFlair,
                supporter: this.userPurchases.has('supporter-badge'),
                cosmetics: Array.from(this.activeCosmetics || [])
            };
        }
        return this.otherUsersShopItems?.get(pubkey) || null;
    }

    getFlairForUser(pubkey) {
        const userItems = this.getUserShopItems(pubkey);
        if (userItems && userItems.flair) {
            const flairItem = this.getShopItemById(userItems.flair);
            if (flairItem) {
                return `<span class="flair-badge ${userItems.flair.replace('flair-', 'flair-')}">${flairItem.icon}</span>`;
            }
        }
        return '';
    }

    activateMessageStyle(styleId) {
        // Toggle: if already active, deactivate it
        if (this.activeMessageStyle === styleId) {
            this.activeMessageStyle = null;
            this.localActiveStyle = null;
            localStorage.setItem('nym_active_style', '');
            this.savePurchaseToNostr();
            this.publishActiveShopItems();
            this.displaySystemMessage(`❎ Deactivated ${this.getShopItemById(styleId).name}`);
            this.renderInventoryTab(document.getElementById('shopBody'));
            this.applyShopStylesToOwnMessages();
            return;
        }

        // Otherwise activate it
        this.activeMessageStyle = styleId;

        // Cache immediately
        this.localActiveStyle = this.activeMessageStyle;
        localStorage.setItem('nym_active_style', this.activeMessageStyle || '');

        this.savePurchaseToNostr();
        this.publishActiveShopItems();
        this.displaySystemMessage(`✅ Activated ${this.getShopItemById(styleId).name}`);
        this.renderInventoryTab(document.getElementById('shopBody'));
        this.applyShopStylesToOwnMessages();
    }

    activateFlair(flairId) {
        // Toggle: if already active, deactivate it
        if (this.activeFlair === flairId) {
            this.activeFlair = null;
            this.localActiveFlair = null;
            localStorage.setItem('nym_active_flair', '');
            this.savePurchaseToNostr();
            this.publishActiveShopItems();
            this.displaySystemMessage(`❎ Deactivated ${this.getShopItemById(flairId).name}`);
            this.renderInventoryTab(document.getElementById('shopBody'));
            this.applyShopStylesToOwnMessages();
            return;
        }

        // Otherwise activate it
        this.activeFlair = flairId;

        // Cache immediately
        this.localActiveFlair = this.activeFlair;
        localStorage.setItem('nym_active_flair', this.activeFlair || '');

        this.savePurchaseToNostr();
        this.publishActiveShopItems();
        this.displaySystemMessage(`✅ Activated ${this.getShopItemById(flairId).name}`);
        this.renderInventoryTab(document.getElementById('shopBody'));
        this.applyShopStylesToOwnMessages();
    }

    getActiveMessageStyle() {
        if (this.activeMessageStyle) {
            return this.getShopItemById(this.activeMessageStyle);
        }
        return null;
    }

    getActiveFlair() {
        if (this.activeFlair) {
            return this.getShopItemById(this.activeFlair);
        }
        return null;
    }

    handlePurchaseStrategy() {
        if (this.connectionMode === 'ephemeral') {
            // Build a self-contained Base64 code so it works across sessions/devices
            const payload = {
                purchases: Array.from(this.userPurchases.entries()),
                activeStyle: this.activeMessageStyle || null,
                activeFlair: this.activeFlair || null,
                activeCosmetics: Array.from(this.activeCosmetics || []),
                ts: Date.now()
            };
            const code = this.generatePurchaseRecoveryCode(payload);

            // Also keep a local copy as a fallback
            localStorage.setItem('nym_shop_recovery_' + code, JSON.stringify(payload));

            this.displaySystemMessage(`
⚠️ EPHEMERAL PURCHASE RECOVERY CODE ⚠️
Save this code to restore this purchase in a new session on same device:
${code}
`);
            return code;
        } else {
            this.savePurchaseToNostr();
            return null;
        }
    }

    generatePurchaseRecoveryCode(payloadObj) {
        // Generate 16 random bytes → 32 uppercase hex chars
        const id = (() => {
            if (window.crypto?.getRandomValues) {
                const u8 = new Uint8Array(16);
                window.crypto.getRandomValues(u8);
                return Array.from(u8, b => b.toString(16).padStart(2, '0')).join('').toUpperCase();
            }
            // Minimal non-crypto fallback (still produces 32 chars)
            let s = '';
            while (s.length < 32) s += Math.random().toString(16).slice(2);
            return s.slice(0, 32).toUpperCase();
        })();

        const code = `NYM-${id}`;
        const json = JSON.stringify(payloadObj);
        localStorage.setItem('nym_shop_recovery_' + code, json);
        return code;
    }

    async restorePurchases(recoveryCode) {
        if (recoveryCode && recoveryCode.startsWith('NYM-')) {
            try {
                const stored = localStorage.getItem('nym_shop_recovery_' + recoveryCode);
                if (!stored) {
                    throw new Error('No stored data for code');
                }

                const data = JSON.parse(stored);

                this.userPurchases.clear();
                (data.purchases || []).forEach(([id, purchase]) => this.userPurchases.set(id, purchase));
                this.activeMessageStyle = data.activeStyle || null;
                this.activeFlair = data.activeFlair || null;
                this.activeCosmetics = new Set(Array.isArray(data.activeCosmetics) ? data.activeCosmetics : []);

                // Save & broadcast so others see it
                await this.savePurchaseToNostr();
                this.publishActiveShopItems();

                this.displaySystemMessage('✅ Shop item restored successfully!');
                if (document.getElementById('shopModal').classList.contains('active')) {
                    this.switchShopTab(this.activeShopTab);
                }
                return true;
            } catch (e) {
            }
        }

        this.displaySystemMessage('❌ Invalid recovery code');
        return false;
    }

    handleShopItemBroadcast(event) {
        const shopItemsTag = event.tags.find(t => t[0] === 'shop-items');
        if (shopItemsTag) {
            try {
                const items = JSON.parse(shopItemsTag[1]);
                const pubkey = event.pubkey;

                this.otherUsersShopItems.set(pubkey, items);

                const messages = document.querySelectorAll(`.message[data-pubkey="${pubkey}"]`);
                messages.forEach(msg => {
                    msg.classList.forEach(cls => {
                        if (cls.startsWith('style-') || cls === 'supporter-style') {
                            msg.classList.remove(cls);
                        }
                    });

                    if (items.style) {
                        msg.classList.add(items.style);
                    }
                    if (items.supporter) {
                        msg.classList.add('supporter-style');
                    }
                });

            } catch (error) {
            }
        }
    }

    async handleChannelLink(channelInput, event) {
        if (event) {
            event.preventDefault();
            event.stopPropagation();
        }

        // Parse channel type from prefix
        let channelType = 'auto';
        let channelName = channelInput;

        if (channelInput.startsWith('c:')) {
            channelType = 'community';
            channelName = channelInput.substring(2);
        } else if (channelInput.startsWith('g:')) {
            channelType = 'geohash';
            channelName = channelInput.substring(2);
        } else if (channelInput.startsWith('e:')) {
            channelType = 'ephemeral';
            channelName = channelInput.substring(2);
        }

        // Handle based on type
        if (channelType === 'community') {
            const communityId = channelName;

            if (this.connectionMode === 'ephemeral') {
                this.displaySystemMessage('Community channels require a persistent identity (extension or nsec login)');
                return;
            }

            // Check if community exists
            if (this.communityChannels.has(communityId)) {
                const community = this.communityChannels.get(communityId);

                // Check if private and has access
                if (community.isPrivate) {
                    const hasAccess = this.ownedCommunities.has(communityId) ||
                        (this.communityModerators.has(communityId) &&
                            this.communityModerators.get(communityId).has(this.pubkey)) ||
                        (this.communityMembers.has(communityId) &&
                            this.communityMembers.get(communityId).has(this.pubkey)) ||
                        (this.communityInvites.has(communityId) &&
                            this.communityInvites.get(communityId).has(this.pubkey));

                    if (!hasAccess) {
                        this.displaySystemMessage(`Cannot join private community "${community.name}" - invitation required`);
                        return;
                    }
                }

                // Add to UI if not present
                if (!document.querySelector(`[data-community="${communityId}"]`)) {
                    this.addCommunityChannel(community.name, communityId, community.isPrivate);
                }

                this.switchToCommunity(communityId);
                this.userJoinedChannels.add(communityId);
                this.saveUserChannels();
            } else {
                this.displaySystemMessage('Community not found or you do not have access');
            }
        } else if (channelType === 'geohash' || (channelType === 'auto' && this.isValidGeohash(channelName))) {
            // Geohash channel
            if (!this.channels.has(channelName)) {
                this.addChannel(channelName, channelName);
            }
            this.switchChannel(channelName, channelName);
            this.userJoinedChannels.add(channelName);
            this.saveUserChannels();
        } else {
            // Standard ephemeral channel
            if (!this.channels.has(channelName)) {
                this.addChannel(channelName, '');
            }
            this.switchChannel(channelName, '');
            await this.createChannel(channelName);
            this.userJoinedChannels.add(channelName);
            this.saveUserChannels();
        }
    }

    showGeohashExplorer() {
        const modal = document.getElementById('geohashExplorerModal');
        if (modal) {
            modal.style.display = 'flex';

            // Wait for modal to be visible before initializing globe
            setTimeout(() => {
                // Check if canvas container exists
                const canvasContainer = document.getElementById('geohashGlobeCanvas');
                if (!canvasContainer || !canvasContainer.parentElement) {
                    return;
                }

                // Always reinitialize globe when opening
                this.initializeGlobe();
            }, 100);
        }
    }

    closeGeohashExplorer() {
        const modal = document.getElementById('geohashExplorerModal');
        if (modal) {
            modal.style.display = 'none';
        }

        // Stop animation
        this.globeAnimationActive = false;

        // Clean up globe resources
        if (this.globe) {
            // Dispose of renderer
            if (this.globe.renderer) {
                this.globe.renderer.dispose();
                this.globe.renderer.forceContextLoss();
                this.globe.renderer.domElement = null;
            }

            // Clean up scene
            if (this.globe.scene) {
                this.globe.scene.traverse((object) => {
                    if (object.geometry) {
                        object.geometry.dispose();
                    }
                    if (object.material) {
                        if (Array.isArray(object.material)) {
                            object.material.forEach(material => material.dispose());
                        } else {
                            object.material.dispose();
                        }
                    }
                });
            }

            this.globe = null;
        }

        // Clean up resize handler
        if (this.globeResizeHandler) {
            window.removeEventListener('resize', this.globeResizeHandler);
            this.globeResizeHandler = null;
        }

    }

    initializeGlobe() {
        const container = document.getElementById('geohashGlobeCanvas');

        if (!container) {
            return;
        }

        // Clear any existing content
        container.innerHTML = '';

        // Create globe viz container
        const globeViz = document.createElement('div');
        globeViz.id = 'globeViz';
        globeViz.style.width = '100%';
        globeViz.style.height = '100%';
        globeViz.style.position = 'absolute';
        globeViz.style.top = '0';
        globeViz.style.left = '0';
        container.appendChild(globeViz);

        // Determine if we should show "Your Location" in legend
        const showYourLocation = this.settings.sortByProximity && this.userLocation;

        // Re-add the controls and info panel HTML with conditional legend
        container.insertAdjacentHTML('beforeend', `
<div class="geohash-info-panel" id="geohashInfoPanel" style="display: none;">
    <div class="geohash-info-title" id="geohashInfoTitle">Channel Info</div>
    <div id="geohashInfoContent"></div>
    <button class="geohash-join-btn" id="geohashJoinBtn">Join Channel</button>
</div>

<div class="geohash-controls">
    <button class="geohash-control-btn" onclick="nym.resetGlobeView()">Reset View</button>
</div>

<div class="geohash-legend">
    <div class="geohash-legend-item">
        <div class="geohash-legend-dot" style="background: var(--primary); box-shadow: 0 0 5px var(--primary);"></div>
        <span>Active Channels</span>
    </div>
    ${showYourLocation ? `
    <div class="geohash-legend-item">
        <div class="geohash-legend-dot" style="background: var(--warning);"></div>
        <span>Your Location</span>
    </div>
    ` : ''}
</div>
`);

        // Get geohash channels
        this.updateGeohashChannels();

        // Calculate optimal distance based on screen size
        const isMobile = window.innerWidth <= 768;
        const initialDistance = isMobile ? 400 : 300;

        // Create globe with dynamic sizing
        const Globe = new ThreeGlobe()
            .globeImageUrl('https://unpkg.com/three-globe@2.31.0/example/img/earth-blue-marble.jpg')
            .bumpImageUrl('https://unpkg.com/three-globe@2.31.0/example/img/earth-topology.png');

        // Setup renderer first
        const renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
        renderer.setPixelRatio(window.devicePixelRatio);
        globeViz.appendChild(renderer.domElement);

        // Setup camera
        const camera = new THREE.PerspectiveCamera();
        camera.position.z = initialDistance;

        // Define updateSize function
        const updateSize = () => {
            const width = container.clientWidth;
            const height = container.clientHeight;
            renderer.setSize(width, height);
            camera.aspect = width / height;
            camera.updateProjectionMatrix();
        };

        updateSize();

        // Setup scene with brighter lighting
        const scene = new THREE.Scene();
        scene.background = new THREE.Color(0x000011);
        scene.add(Globe);
        scene.add(new THREE.AmbientLight(0xffffff, 1.5));

        const directionalLight1 = new THREE.DirectionalLight(0xffffff, 1.2);
        directionalLight1.position.set(5, 3, 5);
        scene.add(directionalLight1);

        const directionalLight2 = new THREE.DirectionalLight(0xffffff, 0.8);
        directionalLight2.position.set(-5, -3, -5);
        scene.add(directionalLight2);

        // Create a container group for points that will rotate with the globe
        const pointsGroup = new THREE.Group();
        scene.add(pointsGroup);

        const GLOBE_RADIUS = 100; // three-globe default radius

        const polar2Cartesian = (lat, lng, relAltitude = 0) => {
            const phi = (90 - lat) * Math.PI / 180;
            const theta = (lng - 90) * Math.PI / 180;  // Subtract 90 instead of add
            const r = GLOBE_RADIUS * (1 + relAltitude);

            return {
                x: r * Math.sin(phi) * Math.cos(theta),
                y: r * Math.cos(phi),
                z: -r * Math.sin(phi) * Math.sin(theta)  // Negate the Z
            };
        };

        // Create clickable point meshes
        const pointMeshes = [];
        const POINT_ALTITUDE = 0.01; // Just above surface

        // Create individual sphere meshes for each geohash channel
        this.geohashChannels.forEach((channel, index) => {
            const geometry = new THREE.SphereGeometry(2.5, 16, 16);
            const material = new THREE.MeshBasicMaterial({
                color: channel.isJoined ? 0x00ff00 : 0x00ffff,
                transparent: true,
                opacity: 0.9
            });
            const sphere = new THREE.Mesh(geometry, material);

            // Convert lat/lng to 3D position using three-globe's coordinate system
            const pos = polar2Cartesian(channel.lat, channel.lng, POINT_ALTITUDE);
            sphere.position.set(pos.x, pos.y, pos.z);


            // Store channel data on the mesh
            sphere.userData = {
                geohash: channel.geohash,
                lat: channel.lat,
                lng: channel.lng,
                channelIndex: index,
                isGeohashPoint: true
            };

            // Add to points group (not Globe) so we can control rotation separately
            pointsGroup.add(sphere);
            pointMeshes.push(sphere);
        });

        // Add user location if available (check both userLocation and proximity setting)
        const hasLocation = this.userLocation || (this.settings.sortByProximity && navigator.geolocation);

        if (this.userLocation) {
            const geometry = new THREE.SphereGeometry(3, 16, 16);
            const material = new THREE.MeshBasicMaterial({
                color: 0xffff00,
                transparent: true,
                opacity: 0.9
            });
            const sphere = new THREE.Mesh(geometry, material);

            const pos = polar2Cartesian(this.userLocation.lat, this.userLocation.lng, POINT_ALTITUDE);
            sphere.position.set(pos.x, pos.y, pos.z);

            sphere.userData = {
                isUserLocation: true
            };

            pointsGroup.add(sphere);

        } else if (this.settings.sortByProximity && navigator.geolocation) {
            // If proximity sorting is enabled but location not yet loaded, try to get it now
            navigator.geolocation.getCurrentPosition(
                (position) => {
                    this.userLocation = {
                        lat: position.coords.latitude,
                        lng: position.coords.longitude
                    };

                    // Add the yellow dot now that we have location
                    const geometry = new THREE.SphereGeometry(3, 16, 16);
                    const material = new THREE.MeshBasicMaterial({
                        color: 0xffff00,
                        transparent: true,
                        opacity: 0.9
                    });
                    const sphere = new THREE.Mesh(geometry, material);

                    const pos = polar2Cartesian(this.userLocation.lat, this.userLocation.lng, POINT_ALTITUDE);
                    sphere.position.set(pos.x, pos.y, pos.z);

                    sphere.userData = {
                        isUserLocation: true
                    };

                    pointsGroup.add(sphere);

                },
                (error) => {
                }
            );
        }

        // Interaction state
        let autoRotate = true;
        let mouseDownX = 0;
        let mouseDownY = 0;
        let mouseDownTime = 0;
        let totalDragDistance = 0;
        let isDragging = false;
        let hoveredMesh = null;
        const CLICK_THRESHOLD = 5;
        const CLICK_TIME_THRESHOLD = 300;

        // Raycaster for interaction detection
        const raycaster = new THREE.Raycaster();
        const mouse = new THREE.Vector2();

        renderer.domElement.style.cursor = 'grab';

        // Helper function to get mouse coordinates
        const getMouseCoordinates = (clientX, clientY) => {
            const rect = renderer.domElement.getBoundingClientRect();
            mouse.x = ((clientX - rect.left) / rect.width) * 2 - 1;
            mouse.y = -((clientY - rect.top) / rect.height) * 2 + 1;
        };

        // Hover detection
        const checkHover = (clientX, clientY) => {
            if (isDragging) return;

            getMouseCoordinates(clientX, clientY);
            raycaster.setFromCamera(mouse, camera);

            const intersects = raycaster.intersectObjects(pointMeshes, false);

            if (intersects.length > 0) {
                const intersectedMesh = intersects[0].object;

                if (intersectedMesh.userData.isGeohashPoint) {
                    hoveredMesh = intersectedMesh;
                    renderer.domElement.style.cursor = 'pointer';
                    intersectedMesh.scale.set(1.2, 1.2, 1.2);
                }
            } else {
                if (hoveredMesh && hoveredMesh.userData.isGeohashPoint) {
                    hoveredMesh.scale.set(1, 1, 1);
                }
                hoveredMesh = null;
                renderer.domElement.style.cursor = 'grab';
            }
        };

        // Mousemove for hover
        renderer.domElement.addEventListener('mousemove', (e) => {
            if (!isDragging) {
                checkHover(e.clientX, e.clientY);
            }
        });

        // Pointer down - start tracking
        renderer.domElement.addEventListener('pointerdown', (e) => {
            e.preventDefault();

            mouseDownX = e.clientX;
            mouseDownY = e.clientY;
            mouseDownTime = Date.now();
            totalDragDistance = 0;
            isDragging = false;
            autoRotate = false;
            renderer.domElement.style.cursor = 'grabbing';

            const onPointerMove = (moveEvent) => {
                const deltaX = moveEvent.clientX - mouseDownX;
                const deltaY = moveEvent.clientY - mouseDownY;

                totalDragDistance += Math.abs(deltaX) + Math.abs(deltaY);

                if (totalDragDistance > CLICK_THRESHOLD) {
                    isDragging = true;
                    if (hoveredMesh && hoveredMesh.userData.isGeohashPoint) {
                        hoveredMesh.scale.set(1, 1, 1);
                    }
                    hoveredMesh = null;
                }

                // Apply rotation to both globe AND points group
                const rotationDeltaX = deltaX * 0.005;
                const rotationDeltaY = deltaY * 0.005;

                Globe.rotation.y += rotationDeltaX;
                Globe.rotation.x += rotationDeltaY;
                Globe.rotation.x = Math.max(-Math.PI / 2, Math.min(Math.PI / 2, Globe.rotation.x));

                // Sync points group rotation with Globe
                pointsGroup.rotation.copy(Globe.rotation);

                mouseDownX = moveEvent.clientX;
                mouseDownY = moveEvent.clientY;
            };

            const onPointerUp = (upEvent) => {
                document.removeEventListener('pointermove', onPointerMove);
                document.removeEventListener('pointerup', onPointerUp);

                const clickDuration = Date.now() - mouseDownTime;
                renderer.domElement.style.cursor = 'grab';

                // Check if this was a click
                if (totalDragDistance <= CLICK_THRESHOLD && clickDuration <= CLICK_TIME_THRESHOLD) {
                    getMouseCoordinates(upEvent.clientX, upEvent.clientY);
                    raycaster.setFromCamera(mouse, camera);

                    const intersects = raycaster.intersectObjects(pointMeshes, false);

                    if (intersects.length > 0) {
                        const clickedMesh = intersects[0].object;

                        if (clickedMesh.userData.isGeohashPoint) {
                            const geohash = clickedMesh.userData.geohash;
                            const clickedChannel = this.geohashChannels.find(ch => ch.geohash === geohash);

                            if (clickedChannel) {
                                this.selectGeohashChannel(clickedChannel);
                            }
                        }
                    }
                }

                isDragging = false;
                setTimeout(() => checkHover(upEvent.clientX, upEvent.clientY), 50);
            };

            document.addEventListener('pointermove', onPointerMove);
            document.addEventListener('pointerup', onPointerUp);
        });

        // Wheel zoom
        renderer.domElement.addEventListener('wheel', (e) => {
            e.preventDefault();
            camera.position.z += e.deltaY * 0.2;
            camera.position.z = Math.max(150, Math.min(600, camera.position.z));
        });

        // Pinch-to-zoom support for mobile
        let touchDistance = 0;
        let initialCameraZ = camera.position.z;

        renderer.domElement.addEventListener('touchstart', (e) => {
            if (e.touches.length === 2) {
                // Two-finger touch - start pinch
                const dx = e.touches[0].clientX - e.touches[1].clientX;
                const dy = e.touches[0].clientY - e.touches[1].clientY;
                touchDistance = Math.sqrt(dx * dx + dy * dy);
                initialCameraZ = camera.position.z;

                // Stop auto-rotation during pinch
                autoRotate = false;
            }
        }, { passive: false });

        renderer.domElement.addEventListener('touchmove', (e) => {
            if (e.touches.length === 2) {
                e.preventDefault();

                // Calculate new distance between touches
                const dx = e.touches[0].clientX - e.touches[1].clientX;
                const dy = e.touches[0].clientY - e.touches[1].clientY;
                const newDistance = Math.sqrt(dx * dx + dy * dy);

                if (touchDistance > 0) {
                    // Calculate zoom factor based on pinch distance change
                    const scale = touchDistance / newDistance;
                    const newZ = initialCameraZ * scale;

                    // Apply zoom with limits
                    camera.position.z = Math.max(150, Math.min(600, newZ));
                }
            }
        }, { passive: false });

        renderer.domElement.addEventListener('touchend', (e) => {
            if (e.touches.length < 2) {
                // Reset pinch state when less than 2 fingers
                touchDistance = 0;
            }
        });

        // Animation loop
        const animate = () => {
            if (!this.globeAnimationActive) return;

            if (autoRotate) {
                Globe.rotation.y += 0.002;
                // Sync points group rotation with Globe during auto-rotation
                pointsGroup.rotation.copy(Globe.rotation);
            }

            renderer.render(scene, camera);
            requestAnimationFrame(animate);
        };

        // Store references
        this.globe = {
            scene: Globe,
            camera: camera,
            renderer: renderer,
            pointMeshes: pointMeshes,
            pointsGroup: pointsGroup,
            autoRotate: autoRotate,
            setAutoRotate: (value) => {
                autoRotate = value;
                this.globe.autoRotate = value;
            },
            updatePoints: () => {
                this.updateGeohashChannels();

                // Remove existing point meshes from points group
                pointMeshes.forEach(mesh => pointsGroup.remove(mesh));
                pointMeshes.length = 0;

                // Recreate point meshes
                this.geohashChannels.forEach((channel, index) => {
                    const geometry = new THREE.SphereGeometry(2.5, 16, 16);
                    const material = new THREE.MeshBasicMaterial({
                        color: channel.isJoined ? 0x00ff00 : 0x00ffff,
                        transparent: true,
                        opacity: 0.9
                    });
                    const sphere = new THREE.Mesh(geometry, material);

                    const pos = polar2Cartesian(channel.lat, channel.lng, POINT_ALTITUDE);
                    sphere.position.set(pos.x, pos.y, pos.z);

                    sphere.userData = {
                        geohash: channel.geohash,
                        lat: channel.lat,
                        lng: channel.lng,
                        channelIndex: index,
                        isGeohashPoint: true
                    };

                    pointsGroup.add(sphere);
                    pointMeshes.push(sphere);
                });

                // Re-add user location if available
                if (this.userLocation) {
                    const geometry = new THREE.SphereGeometry(3, 16, 16);
                    const material = new THREE.MeshBasicMaterial({
                        color: 0xffff00,
                        transparent: true,
                        opacity: 0.9
                    });
                    const sphere = new THREE.Mesh(geometry, material);

                    const pos = polar2Cartesian(this.userLocation.lat, this.userLocation.lng, POINT_ALTITUDE);
                    sphere.position.set(pos.x, pos.y, pos.z);

                    sphere.userData = {
                        isUserLocation: true
                    };

                    pointsGroup.add(sphere);
                }

                // Sync rotation after updating points
                pointsGroup.rotation.copy(Globe.rotation);
            }
        };

        this.globeAnimationActive = true;

        // Handle resize
        const handleResize = () => {
            updateSize();
        };

        if (this.globeResizeHandler) {
            window.removeEventListener('resize', this.globeResizeHandler);
        }
        this.globeResizeHandler = handleResize;
        window.addEventListener('resize', this.globeResizeHandler);

        // Start animation
        animate();

    }

    addGeohashChannelToGlobe(geohash) {
        // If globe is active, update it
        if (this.globe && this.globeAnimationActive) {
            this.globe.updatePoints();
        }
    }

    updateGeohashChannels() {
        this.geohashChannels = [];

        // Get all geohash channels from discovered channels and user channels
        const allGeohashes = new Set();

        // From common geohashes
        this.commonGeohashes.forEach(g => allGeohashes.add(g.toLowerCase()));

        // From user's channels
        this.channels.forEach((value, key) => {
            if (value.geohash) {
                allGeohashes.add(value.geohash.toLowerCase());
            }
        });

        // From stored messages
        this.messages.forEach((msgs, channel) => {
            if (channel.startsWith('#') && this.isValidGeohash(channel.substring(1))) {
                allGeohashes.add(channel.substring(1).toLowerCase());
            }
        });

        // Convert to array with coordinates
        allGeohashes.forEach(geohash => {
            try {
                const coords = this.decodeGeohash(geohash);
                const messageCount = (this.messages.get(`#${geohash}`) || []).length;
                this.geohashChannels.push({
                    geohash: geohash.toLowerCase(), // Ensure lowercase
                    lat: coords.lat,
                    lng: coords.lng,
                    messages: messageCount,
                    isJoined: this.channels.has(geohash)
                });
            } catch (e) {
            }
        });
    }

    async selectGeohashChannel(channel) {
        this.selectedGeohash = channel.geohash.toLowerCase();

        // Stop auto-rotation when selecting a channel
        if (this.globe && this.globe.controls) {
            this.globe.controls.autoRotate = false;
            this.globe.autoRotate = false;
        }

        const infoPanel = document.getElementById('geohashInfoPanel');
        const infoTitle = document.getElementById('geohashInfoTitle');
        const infoContent = document.getElementById('geohashInfoContent');
        const joinBtn = document.getElementById('geohashJoinBtn');

        infoTitle.textContent = `#${channel.geohash.toLowerCase()}`;

        const distance = this.userLocation ?
            this.calculateDistance(this.userLocation.lat, this.userLocation.lng, channel.lat, channel.lng).toFixed(1) + ' km away' :
            '';

        // Get city and country from reverse geocoding
        let locationInfo = 'Loading location...';
        infoContent.innerHTML = `
<div class="geohash-info-item">
    <strong>Coordinates:</strong> ${channel.lat.toFixed(4)}, ${channel.lng.toFixed(4)}
</div>
<div class="geohash-info-item" id="locationInfoItem">
    <strong>Location:</strong> ${locationInfo}
</div>
${distance ? `<div class="geohash-info-item"><strong>Distance:</strong> ${distance}</div>` : ''}
<div class="geohash-info-item">
    <strong>Messages:</strong> ${channel.messages}
</div>
`;

        // Update join button
        if (channel.isJoined) {
            joinBtn.textContent = 'Go to Channel';
        } else {
            joinBtn.textContent = 'Join Channel';
        }

        // Set up join button with proper handler
        joinBtn.onclick = () => {
            this.joinSelectedGeohash();
        };

        infoPanel.style.display = 'block';

        // Fetch city and country asynchronously
        try {
            const response = await fetch(`https://nominatim.openstreetmap.org/reverse?format=json&lat=${channel.lat}&lon=${channel.lng}&zoom=10`);
            const data = await response.json();

            const city = data.address.city || data.address.town || data.address.village || data.address.county || '';
            const country = data.address.country || '';

            locationInfo = [city, country].filter(x => x).join(', ') || 'Unknown location';

            // Update the location info element
            const locationInfoItem = document.getElementById('locationInfoItem');
            if (locationInfoItem) {
                locationInfoItem.innerHTML = `<strong>Location:</strong> ${locationInfo}`;
            }
        } catch (error) {
            const locationInfoItem = document.getElementById('locationInfoItem');
            if (locationInfoItem) {
                locationInfoItem.innerHTML = `<strong>Location:</strong> Unknown`;
            }
        }

    }

    joinSelectedGeohash() {
        if (this.selectedGeohash) {
            const geohash = this.selectedGeohash.toLowerCase();


            // Close the explorer modal
            this.closeGeohashExplorer();

            // Small delay to ensure modal closes before switching
            setTimeout(() => {
                // Add the channel if not already present
                if (!this.channels.has(geohash)) {
                    this.addChannel(geohash, geohash);
                }

                // Switch to the channel
                this.switchChannel(geohash, geohash);

                // Mark as user-joined
                this.userJoinedChannels.add(geohash);
                this.saveUserChannels();

                this.displaySystemMessage(`Joined geohash channel #${geohash}`);
            }, 100);
        }
    }

    resetGlobeView() {
        if (this.globe) {
            this.globe.camera.position.set(0, 0, 300);
            this.globe.scene.rotation.set(0, 0, 0);
            this.globe.setAutoRotate(true);
            this.globe.autoRotate = true;

            // Close any open geohash channel details
            const infoPanel = document.getElementById('geohashInfoPanel');
            if (infoPanel) {
                infoPanel.style.display = 'none';
            }

        }
    }

    getUserColorClass(pubkey) {
        if (this.settings.theme !== 'bitchat') return '';

        // Your own messages are always orange
        if (pubkey === this.pubkey) {
            return 'bitchat-theme';
        }

        // Return cached color if exists
        if (this.userColors.has(pubkey)) {
            return this.userColors.get(pubkey);
        }

        // Generate unique color based on pubkey hash
        const colorClass = this.generateUniqueColor(pubkey);
        this.userColors.set(pubkey, colorClass);
        return colorClass;
    }

    // Generate a unique color based on pubkey
    generateUniqueColor(pubkey) {
        let hash = 0;
        for (let i = 0; i < pubkey.length; i++) {
            hash = pubkey.charCodeAt(i) + ((hash << 5) - hash);
        }

        // Generate HSL color
        const hue = Math.abs(hash) % 360;
        const saturation = 65 + (Math.abs(hash) % 35); // 65-100%
        const lightness = 60 + (Math.abs(hash) % 25);  // 60-85%

        // Create unique class name
        const uniqueClass = `bitchat-user-${Math.abs(hash) % 1000}`;

        // Add dynamic style if not exists
        if (!document.getElementById(uniqueClass)) {
            const style = document.createElement('style');
            style.id = uniqueClass;
            style.textContent = `
    .${uniqueClass} {
        color: hsl(${hue}, ${saturation}%, ${lightness}%) !important;
    }
    .${uniqueClass} .nym-suffix {
        color: hsl(${hue}, ${saturation}%, ${lightness}%) !important;
    }
`;
            document.head.appendChild(style);
        }

        return uniqueClass;
    }

    shareChannel() {
        // Generate the share URL
        const baseUrl = window.location.origin + window.location.pathname;
        let channelPart;

        // Determine what to share based on current mode with prefixes to avoid conflicts
        if (this.currentCommunity) {
            // For communities, use 'c:' prefix with community ID
            channelPart = `c:${this.currentCommunity}`;
        } else if (this.currentGeohash) {
            // For geohash channels, use 'g:' prefix
            channelPart = `g:${this.currentGeohash}`;
        } else {
            // For standard channels, use 'e:' prefix (ephemeral)
            channelPart = `e:${this.currentChannel}`;
        }

        const shareUrl = `${baseUrl}#${channelPart}`;

        // Set the URL in the input
        document.getElementById('shareUrlInput').value = shareUrl;

        // Show the modal
        document.getElementById('shareModal').classList.add('active');

        // Auto-select the text
        setTimeout(() => {
            document.getElementById('shareUrlInput').select();
        }, 100);
    }

    copyShareUrl() {
        const input = document.getElementById('shareUrlInput');
        input.select();

        navigator.clipboard.writeText(input.value).then(() => {
            const btn = document.querySelector('.copy-url-btn');
            const originalText = btn.textContent;
            btn.textContent = 'COPIED!';
            btn.classList.add('copied');

            setTimeout(() => {
                btn.textContent = originalText;
                btn.classList.remove('copied');
            }, 2000);
        }).catch(err => {
            this.displaySystemMessage('Failed to copy URL');
        });
    }

    shareToTwitter() {
        const url = document.getElementById('shareUrlInput').value;
        const channelName = this.currentGeohash || this.currentChannel;
        const text = `Join me in the #${channelName} channel on NYM - ephemeral Nostr chat`;
        const twitterUrl = `https://twitter.com/intent/tweet?text=${encodeURIComponent(text)}&url=${encodeURIComponent(url)}`;
        window.open(twitterUrl, '_blank');
    }

    shareToNostr() {
        const url = document.getElementById('shareUrlInput').value;
        const channelName = this.currentGeohash || this.currentChannel;
        const content = `Join me in the #${channelName} channel on NYM - ephemeral Nostr chat\n\n${url}`;

        // Copy to clipboard with Nostr note format
        const note = `nostr:note1${content}`;
        navigator.clipboard.writeText(content).then(() => {
            this.displaySystemMessage('Channel link copied for Nostr sharing');
            closeModal('shareModal');
        }).catch(err => {
            this.displaySystemMessage('Failed to copy for Nostr');
        });
    }

    shareToClipboard() {
        this.copyShareUrl();
    }

    // Add a command for sharing
    async cmdShare() {
        this.shareChannel();
    }

    decodeGeohash(geohash) {
        const BASE32 = '0123456789bcdefghjkmnpqrstuvwxyz';
        const bounds = {
            lat: [-90, 90],
            lng: [-180, 180]
        };

        let isEven = true;
        for (let i = 0; i < geohash.length; i++) {
            const cd = BASE32.indexOf(geohash[i].toLowerCase());
            if (cd === -1) throw new Error('Invalid geohash character');

            for (let j = 4; j >= 0; j--) {
                const mask = 1 << j;
                if (isEven) {
                    bounds.lng = (cd & mask) ?
                        [(bounds.lng[0] + bounds.lng[1]) / 2, bounds.lng[1]] :
                        [bounds.lng[0], (bounds.lng[0] + bounds.lng[1]) / 2];
                } else {
                    bounds.lat = (cd & mask) ?
                        [(bounds.lat[0] + bounds.lat[1]) / 2, bounds.lat[1]] :
                        [bounds.lat[0], (bounds.lat[0] + bounds.lat[1]) / 2];
                }
                isEven = !isEven;
            }
        }

        return {
            lat: (bounds.lat[0] + bounds.lat[1]) / 2,
            lng: (bounds.lng[0] + bounds.lng[1]) / 2
        };
    }

    getGeohashLocation(geohash) {
        try {
            const coords = this.decodeGeohash(geohash);
            const lat = coords.lat;
            const lng = coords.lng;

            // Format coordinates properly with N/S and E/W
            const latStr = Math.abs(lat).toFixed(2) + '°' + (lat >= 0 ? 'N' : 'S');
            const lngStr = Math.abs(lng).toFixed(2) + '°' + (lng >= 0 ? 'E' : 'W');

            return `${latStr}, ${lngStr}`;
        } catch (e) {
            return '';
        }
    }

    calculateDistance(lat1, lon1, lat2, lon2) {
        const R = 6371; // Earth radius in km
        const dLat = (lat2 - lat1) * Math.PI / 180;
        const dLon = (lon2 - lon1) * Math.PI / 180;
        const a = Math.sin(dLat / 2) * Math.sin(dLat / 2) +
            Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180) *
            Math.sin(dLon / 2) * Math.sin(dLon / 2);
        const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
        return R * c;
    }

    // Find the N closest relays to a geohash location
    getClosestRelaysForGeohash(geohash, count = this.geoRelayCount) {
        try {
            // Decode geohash to get center coordinates
            const coords = this.decodeGeohash(geohash);
            if (!coords || typeof coords.lat !== 'number' || typeof coords.lng !== 'number') {
                return [];
            }

            // Calculate distance from geohash center to each geo-located relay
            const relaysWithDistance = this.geoRelays.map(relay => ({
                url: relay.url,
                distance: this.calculateDistance(coords.lat, coords.lng, relay.lat, relay.lng)
            }));

            // Sort by distance (closest first)
            relaysWithDistance.sort((a, b) => a.distance - b.distance);

            // Return the N closest relays
            return relaysWithDistance.slice(0, count);
        } catch (error) {
            return [];
        }
    }

    // Connect to geo-specific relays for a geohash channel
    async connectToGeoRelays(geohash) {
        if (!geohash || !this.isValidGeohash(geohash)) {
            return;
        }

        // Check if we already have cached geo relays for this geohash
        if (this.geoRelayConnections.has(geohash)) {
            const cachedRelays = this.geoRelayConnections.get(geohash);
            // Verify connections are still alive
            let activeCount = 0;
            for (const url of cachedRelays) {
                const relay = this.relayPool.get(url);
                if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                    activeCount++;
                }
            }
            // If we have at least half of our target connections, don't reconnect
            if (activeCount >= Math.floor(this.geoRelayCount / 2)) {
                return;
            }
        }

        // Find closest relays for this geohash
        const closestRelays = this.getClosestRelaysForGeohash(geohash, this.geoRelayCount);
        if (closestRelays.length === 0) {
            return;
        }

        // Store which relays are for this geohash
        const geoRelayUrls = new Set(closestRelays.map(r => r.url));
        this.geoRelayConnections.set(geohash, geoRelayUrls);

        // Connect to each geo relay with staggered timing
        const connectionPromises = [];
        for (let i = 0; i < closestRelays.length; i++) {
            const relayUrl = closestRelays[i].url;

            // Skip if already connected
            if (this.relayPool.has(relayUrl)) {
                const existing = this.relayPool.get(relayUrl);
                if (existing.ws && existing.ws.readyState === WebSocket.OPEN) {
                    // Mark as geo relay and ensure subscription
                    this.currentGeoRelays.add(relayUrl);
                    continue;
                }
            }

            // Skip if blacklisted or recently failed
            if (this.blacklistedRelays.has(relayUrl) && !this.isBlacklistExpired(relayUrl)) {
                continue;
            }
            if (!this.shouldRetryRelay(relayUrl)) {
                continue;
            }

            // Stagger connections to avoid overwhelming the browser
            const delay = i * 100;
            const connectionPromise = new Promise(resolve => {
                setTimeout(async () => {
                    try {
                        await this.connectToRelayWithTimeout(relayUrl, 'geo', 3000);
                        this.currentGeoRelays.add(relayUrl);
                        this.subscribeToSingleRelay(relayUrl);
                        this.updateConnectionStatus();
                    } catch (err) {
                        this.trackRelayFailure(relayUrl);
                        // Don't log errors for geo relays - they're supplemental
                    }
                    resolve();
                }, delay);
            });
            connectionPromises.push(connectionPromise);
        }

        // Wait for all connection attempts to complete
        await Promise.all(connectionPromises);

        // Log final geo relay count
        const connectedGeoRelays = Array.from(this.currentGeoRelays).filter(url => {
            const relay = this.relayPool.get(url);
            return relay && relay.ws && relay.ws.readyState === WebSocket.OPEN;
        });
    }

    // Disconnect from geo-specific relays that are no longer needed
    cleanupGeoRelays(previousGeohash) {
        if (!previousGeohash) return;

        // Get relays that were connected for the previous geohash
        const previousGeoRelays = this.geoRelayConnections.get(previousGeohash);
        if (!previousGeoRelays) return;

        // Check if any of these relays are still needed for other geohash channels
        const stillNeededRelays = new Set();
        for (const [geohash, relays] of this.geoRelayConnections) {
            if (geohash !== previousGeohash) {
                for (const url of relays) {
                    stillNeededRelays.add(url);
                }
            }
        }

        // Disconnect relays that are no longer needed (unless they're broadcast relays)
        for (const url of previousGeoRelays) {
            if (!stillNeededRelays.has(url) &&
                !this.broadcastRelays.includes(url) &&
                !this.discoveredRelays.has(url)) {
                // This relay was only for the previous geohash - we can keep it connected
                // but mark it as no longer a primary geo relay
                this.currentGeoRelays.delete(url);
            }
        }
    }

    isVerifiedDeveloper(pubkey) {
        return pubkey === this.verifiedDeveloper.pubkey;
    }

    validateGeohashInput(input) {
        // Geohash valid characters: 0-9, b-z excluding a, i, l, o
        const validChars = '0123456789bcdefghjkmnpqrstuvwxyz';
        return input.split('').every(char => validChars.includes(char.toLowerCase()));
    }

    // NSEC decode method
    decodeNsec(nsec) {
        try {
            // Use nostr-tools nip19 decode
            if (window.NostrTools && window.NostrTools.nip19) {
                const decoded = window.NostrTools.nip19.decode(nsec);
                if (decoded.type === 'nsec') {
                    return decoded.data;
                }
            }
            throw new Error('Invalid nsec format');
        } catch (error) {
            throw new Error('Failed to decode nsec: ' + error.message);
        }
    }

    updateRelayStatus() {
        const listEl = document.getElementById('connectedRelaysList');
        if (!listEl) return;

        // Group relays by type
        const broadcastRelays = [];
        const readRelays = [];
        const nosflareRelays = [];
        const geoRelays = [];

        this.relayPool.forEach((relay, url) => {
            if (relay.type === 'broadcast') {
                broadcastRelays.push(url);
            } else if (relay.type === 'nosflare') {
                nosflareRelays.push(url);
            } else if (relay.type === 'geo') {
                geoRelays.push(url);
            } else if (relay.type === 'read') {
                readRelays.push(url);
            }
        });

        // Calculate total readable relays (broadcast, read, and geo relays can all be read from)
        const totalReadable = broadcastRelays.length + readRelays.length + geoRelays.length;

        let html = '';

        if (broadcastRelays.length > 0 || nosflareRelays.length > 0) {
            html += '<div style="margin-bottom: 10px;"><strong style="color: var(--primary);">Default Relays:</strong><br/>';
            broadcastRelays.forEach(url => {
                html += `<div style="font-size: 11px; margin-left: 10px;">• ${url}</div>`;
            });
            nosflareRelays.forEach(url => {
                html += `<div style="font-size: 11px; margin-left: 10px;">• ${url} (write-only)</div>`;
            });
            html += '</div>';
        }

        if (geoRelays.length > 0) {
            html += `<div style="margin-bottom: 10px;"><strong style="color: var(--warning);">Geohash Relays (${geoRelays.length}):</strong><br/>`;
            geoRelays.slice(0, 5).forEach(url => {
                html += `<div style="font-size: 11px; margin-left: 10px;">• ${url}</div>`;
            });
            if (geoRelays.length > 5) {
                html += `<div style="font-size: 11px; margin-left: 10px; color: var(--text-dim);">... and ${geoRelays.length - 5} more</div>`;
            }
            html += '</div>';
        }

        if (readRelays.length > 0) {
            html += `<div><strong style="color: var(--secondary);">Additional Read Relays (${readRelays.length}):</strong><br/>`;
            readRelays.slice(0, 10).forEach(url => {
                html += `<div style="font-size: 11px; margin-left: 10px;">• ${url}</div>`;
            });
            if (readRelays.length > 10) {
                html += `<div style="font-size: 11px; margin-left: 10px; color: var(--text-dim);">... and ${readRelays.length - 10} more</div>`;
            }
            html += '</div>';
        }

        html += `<div style="margin-top: 10px; font-size: 12px; color: var(--text-bright);">Total Connected: ${this.relayPool.size} relays (${totalReadable} readable)</div>`;

        listEl.innerHTML = html || '<div style="color: var(--text-dim); font-size: 12px;">No relays connected</div>';
    }

    async refreshRelays() {
        this.displaySystemMessage('Refreshing relay list...');
        this.lastRelayDiscovery = 0; // Force refresh
        await this.discoverRelays();
        await this.connectToRelays();
        this.updateRelayStatus();
    }

    isValidGeohash(str) {
        return this.geohashRegex.test(str.toLowerCase());
    }

    getChannelType(channel) {
        if (this.isValidGeohash(channel)) {
            return 'geo';
        }
        return 'standard';
    }

    handleChannelSearch(searchTerm) {
        const term = searchTerm.toLowerCase();
        const resultsDiv = document.getElementById('channelSearchResults');

        // Filter existing channels
        this.filterChannels(term);

        // Show create/join prompt if search term exists
        if (term.length > 0) {
            // Sanitize the search term (remove spaces and invalid characters)
            const sanitized = term.replace(/[^a-z0-9-]/g, '');

            if (!sanitized) {
                resultsDiv.innerHTML = '<div class="search-create-prompt" style="color: var(--danger);">Invalid name. Use only letters, numbers, and hyphens.</div>';
                return;
            }

            const isGeohash = this.isValidGeohash(sanitized);

            // Check if it's a community channel
            let matchedCommunity = null;
            this.communityChannels.forEach((community, id) => {
                if (community.name.toLowerCase() === sanitized || id.toLowerCase().includes(sanitized)) {
                    matchedCommunity = { id, community };
                }
            });

            const exists = Array.from(this.channels.keys()).some(k => k.toLowerCase() === sanitized);

            // Clear previous results
            resultsDiv.innerHTML = '';

            // Show matched community if found
            if (matchedCommunity) {
                const { id, community } = matchedCommunity;

                // Check if user can access this community
                const isOwned = this.ownedCommunities.has(id);
                const isModerated = this.moderatedCommunities.has(id);
                const isMember = this.communityMembers.has(id) &&
                    this.communityMembers.get(id).has(this.pubkey);
                const canAccess = !community.isPrivate || isOwned || isModerated || isMember;

                if (canAccess) {
                    const privacyBadge = community.isPrivate ? 'PRI' : 'PUB';
                    const privacyColor = community.isPrivate ? 'var(--purple)' : 'var(--primary)';

                    const prompt = document.createElement('div');
                    prompt.className = 'search-create-prompt';
                    prompt.style.cssText = 'display: flex; justify-content: space-between; align-items: center;';
                    prompt.innerHTML = `
            <span>Join community "${community.name}"</span>
            <span style="color: ${privacyColor}; border: 1px solid ${privacyColor}; padding: 2px 8px; border-radius: 3px; font-size: 10px;">${privacyBadge}</span>
        `;
                    prompt.onclick = () => {
                        this.switchToCommunity(id);
                        document.getElementById('channelSearch').value = '';
                        resultsDiv.innerHTML = '';
                        this.filterChannels('');
                    };
                    resultsDiv.appendChild(prompt);
                }
            }

            // Show geohash option if valid
            if (isGeohash && !exists) {
                const location = this.getGeohashLocation(sanitized) || 'Unknown location';
                const prompt = document.createElement('div');
                prompt.className = 'search-create-prompt';
                prompt.style.cssText = 'display: flex; justify-content: space-between; align-items: center;';
                prompt.innerHTML = `
        <span>Join geohash "${sanitized}" (${location})</span>
        <span style="color: var(--warning); border: 1px solid var(--warning); padding: 2px 8px; border-radius: 3px; font-size: 10px;">GEO</span>
    `;
                prompt.onclick = async () => {
                    this.addChannel(sanitized, sanitized);
                    this.switchChannel(sanitized, sanitized);
                    this.userJoinedChannels.add(sanitized);
                    document.getElementById('channelSearch').value = '';
                    resultsDiv.innerHTML = '';
                    this.filterChannels('');
                    this.saveUserChannels();
                };
                resultsDiv.appendChild(prompt);
            }

            // Show standard channel option if doesn't exist
            if (!exists && !matchedCommunity) {
                const prompt = document.createElement('div');
                prompt.className = 'search-create-prompt';
                prompt.style.cssText = 'display: flex; justify-content: space-between; align-items: center;';
                prompt.innerHTML = `
        <span>Create/Join channel "${sanitized}"</span>
        <span style="color: var(--blue); border: 1px solid var(--blue); padding: 2px 8px; border-radius: 3px; font-size: 10px;">EPH</span>
    `;
                prompt.onclick = async () => {
                    this.addChannel(sanitized, '');
                    this.switchChannel(sanitized, '');
                    await this.createChannel(sanitized);
                    this.userJoinedChannels.add(sanitized);
                    document.getElementById('channelSearch').value = '';
                    resultsDiv.innerHTML = '';
                    this.filterChannels('');
                    this.saveUserChannels();
                };
                resultsDiv.appendChild(prompt);
            }

            // Show create community option if logged in and name doesn't match existing
            if (this.connectionMode !== 'ephemeral' && !matchedCommunity && !isGeohash) {
                const prompt = document.createElement('div');
                prompt.className = 'search-create-prompt';
                prompt.style.cssText = 'display: flex; justify-content: space-between; align-items: center; margin-top: 5px;';
                prompt.innerHTML = `
        <span>Create public community "${sanitized}"</span>
        <span style="color: var(--primary); border: 1px solid var(--primary); padding: 2px 8px; border-radius: 3px; font-size: 10px;">PUB</span>
    `;
                prompt.onclick = async () => {
                    const communityId = await this.createCommunityChannel(sanitized, `Public community for ${sanitized}`, false);
                    if (communityId) {
                        this.switchToCommunity(communityId);
                    }
                    document.getElementById('channelSearch').value = '';
                    resultsDiv.innerHTML = '';
                    this.filterChannels('');
                };
                resultsDiv.appendChild(prompt);
            }

            // Show warning if original term had invalid characters
            if (term !== sanitized) {
                const warning = document.createElement('div');
                warning.className = 'search-create-prompt';
                warning.style.cssText = 'color: var(--text-dim); font-size: 11px; margin-top: 5px; cursor: default;';
                warning.innerHTML = `Note: Spaces and special characters removed. Using "${sanitized}"`;
                warning.onclick = null;
                resultsDiv.appendChild(warning);
            }
        } else {
            resultsDiv.innerHTML = '';
        }
    }

    loadRecentEmojis() {
        const saved = localStorage.getItem('nym_recent_emojis');
        if (saved) {
            this.recentEmojis = JSON.parse(saved);
        }
    }

    saveRecentEmojis() {
        localStorage.setItem('nym_recent_emojis', JSON.stringify(this.recentEmojis.slice(0, 20)));
    }

    addToRecentEmojis(emoji) {
        // Remove if already exists
        this.recentEmojis = this.recentEmojis.filter(e => e !== emoji);
        // Add to beginning
        this.recentEmojis.unshift(emoji);
        // Keep only 20 recent
        this.recentEmojis = this.recentEmojis.slice(0, 20);
        this.saveRecentEmojis();
    }

    async initialize() {
        try {
            // Check if nostr-tools is loaded
            if (typeof window.NostrTools === 'undefined') {
                throw new Error('nostr-tools not loaded');
            }

            // Setup event listeners
            this.setupEventListeners();
            this.setupCommands();
            this.setupEmojiPicker();
            this.setupContextMenu();
            this.setupMobileGestures();

            // Load saved preferences
            this.applyTheme(this.settings.theme);
            this.loadBlockedUsers();
            this.loadBlockedKeywords();
            this.loadBlockedChannels();
            this.loadPinnedChannels();

            // Load lightning address
            await this.loadLightningAddress();

            // Clean up old localStorage format
            this.cleanupOldLightningAddress();

            // Network change detection
            this.setupNetworkMonitoring();

            // Visibility change detection
            this.setupVisibilityMonitoring();

        } catch (error) {
            this.showNotification('Error', 'Failed to initialize: ' + error.message);
        }
    }

    setupVisibilityMonitoring() {
        // Track when app becomes visible/hidden
        document.addEventListener('visibilitychange', () => {
            if (document.visibilityState === 'visible') {
                const delay = this.isFlutterWebView ? 200 : 500;
                setTimeout(() => {
                    this.checkConnectionHealth();

                    if (!this.connected && navigator.onLine) {
                        this.attemptReconnection();
                    }

                    // Always refresh subscriptions when we come back to foreground
                    setTimeout(() => this.resubscribeAllRelays(), 250);
                }, delay);
            } else {
                // Stop monitoring when app goes to background
                if (this.reconnectionInterval) {
                    clearInterval(this.reconnectionInterval);
                    this.reconnectionInterval = null;
                }
            }
        });

        // Also listen for page focus (for desktop)
        window.addEventListener('focus', () => {
            const delay = this.isFlutterWebView ? 200 : 500;
            setTimeout(() => {
                this.checkConnectionHealth();

                // If disconnected, immediately start reconnection attempts
                if (!this.connected && navigator.onLine) {
                    this.attemptReconnection();
                }

                // Always refresh subscriptions when window regains focus
                setTimeout(() => this.resubscribeAllRelays(), 250);
            }, delay);
        });

        // For Flutter WebView, also check on resume event
        if (this.isFlutterWebView) {
            window.addEventListener('resume', () => {
                setTimeout(() => {
                    this.checkConnectionHealth();

                    // If disconnected, immediately start reconnection attempts
                    if (!this.connected && navigator.onLine) {
                        this.attemptReconnection();
                    }

                    // Always refresh subscriptions when app resumes
                    setTimeout(() => this.resubscribeAllRelays(), 250);
                }, 200);
            });
        }
    }

    async checkConnectionHealth() {

        // First, check if we think we're connected
        let actuallyConnected = 0;
        const deadRelays = [];

        this.relayPool.forEach((relay, url) => {
            if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                actuallyConnected++;
            } else {
                deadRelays.push(url);
            }
        });

        // Clean up dead relays
        deadRelays.forEach(url => {
            this.relayPool.delete(url);
            this.relayKinds.delete(url);
        });

        // If we have no actual connections, force reconnect
        if (actuallyConnected === 0) {
            this.connected = false;
            this.updateConnectionStatus('Disconnected');

            // Clear reconnecting set to allow fresh attempts
            if (this.reconnectingRelays) {
                this.reconnectingRelays.clear();
            }

            // Try to reconnect to broadcast relays
            await this.reconnectToBroadcastRelays();

            // ALSO reconnect to discovered relays after a short delay
            setTimeout(() => {
                this.retryDiscoveredRelays();
            }, 2000);

            // Reconnect to geo relays if we're in a geohash channel
            if (this.currentGeohash) {
                setTimeout(() => {
                    this.connectToGeoRelays(this.currentGeohash);
                }, 3000);
            }

        } else {
            // We have some connections, but update status to reflect actual count
            this.updateConnectionStatus();

            // If we're missing some broadcast relays, try to restore them
            const missingBroadcast = this.broadcastRelays.filter(url => !this.relayPool.has(url));
            if (missingBroadcast.length > 0) {
                this.reconnectToBroadcastRelays();
            }

            // ALSO check for missing discovered relays
            const missingDiscovered = Array.from(this.discoveredRelays).filter(url =>
                !this.relayPool.has(url) &&
                !this.broadcastRelays.includes(url) &&
                url !== this.nosflareRelay
            );

            if (missingDiscovered.length > 0) {
                setTimeout(() => {
                    this.retryDiscoveredRelays();
                }, 1000);
            }

            // Check geo relay health if we're in a geohash channel
            if (this.currentGeohash) {
                this.connectToGeoRelays(this.currentGeohash);
            }
        }
    }

    async reconnectToBroadcastRelays() {

        let connectedCount = 0;

        for (const relayUrl of this.broadcastRelays) {
            if (!this.relayPool.has(relayUrl) ||
                (this.relayPool.get(relayUrl).ws &&
                    this.relayPool.get(relayUrl).ws.readyState !== WebSocket.OPEN)) {

                try {
                    await this.connectToRelay(relayUrl, 'broadcast');
                    this.subscribeToSingleRelay(relayUrl);
                    connectedCount++;

                    if (connectedCount === 1) {
                        // After first successful connection
                        this.connected = true;
                        this.updateConnectionStatus();
                    }
                } catch (err) {
                    this.trackRelayFailure(relayUrl);
                }

                // Small delay between connections to avoid overwhelming
                await new Promise(resolve => setTimeout(resolve, 50));
            }
        }

        this.updateConnectionStatus();
    }

    setupNetworkMonitoring() {
        // Track reconnection attempts
        this.reconnectionAttempts = 0;
        this.maxReconnectionAttempts = 10;
        this.reconnectionInterval = null;

        // Listen for online/offline events
        window.addEventListener('online', () => {
            this.displaySystemMessage('Network connection restored, reconnecting...');
            this.reconnectionAttempts = 0; // Reset attempts on network restore

            // Force update connection status
            this.updateConnectionStatus('Reconnecting...');

            // Clear any existing reconnection interval
            if (this.reconnectionInterval) {
                clearInterval(this.reconnectionInterval);
                this.reconnectionInterval = null;
            }

            // Clear all reconnecting flags to allow fresh attempts
            if (this.reconnectingRelays) {
                this.reconnectingRelays.clear();
            }

            // Clear relay pool of dead connections
            this.relayPool.forEach((relay, url) => {
                if (!relay.ws || relay.ws.readyState !== WebSocket.OPEN) {
                    this.relayPool.delete(url);
                    this.relayKinds.delete(url);
                }
            });

            // Clear blacklist temporarily to allow retry
            const tempBlacklist = new Set(this.blacklistedRelays);
            this.blacklistedRelays.clear();

            // Attempt to reconnect to all broadcast relays
            this.broadcastRelays.forEach(relayUrl => {
                if (!this.relayPool.has(relayUrl)) {
                    this.connectToRelay(relayUrl, 'broadcast')
                        .then(() => {
                            this.subscribeToSingleRelay(relayUrl);
                            this.updateConnectionStatus();
                        })
                        .catch(err => {
                            // Restore to blacklist if it fails again
                            if (tempBlacklist.has(relayUrl)) {
                                this.blacklistedRelays.add(relayUrl);
                            }
                            this.updateConnectionStatus();
                        });
                }
            });
        });

        window.addEventListener('offline', () => {

            // Force cleanup of relay pool
            this.relayPool.forEach((relay, url) => {
                if (relay.ws) {
                    try {
                        relay.ws.close();
                    } catch (e) {
                        // Ignore close errors
                    }
                }
                this.relayPool.delete(url);
                this.relayKinds.delete(url);
            });

            this.connected = false;
            this.displaySystemMessage('Network connection lost');
            this.updateConnectionStatus('Disconnected');
        });

        // Start automatic reconnection monitoring
        this.startReconnectionMonitoring();
    }

    startReconnectionMonitoring() {
        // Only monitor when app is visible/active
        this.reconnectionInterval = null;

        const startMonitoring = () => {
            // Clear any existing interval
            if (this.reconnectionInterval) {
                clearInterval(this.reconnectionInterval);
            }

            // Only start if disconnected and visible
            if (!this.connected && !document.hidden) {
                this.reconnectionInterval = setInterval(() => {
                    // Only attempt if still visible
                    if (!document.hidden && !this.connected && navigator.onLine) {
                        this.attemptReconnection();
                    } else if (document.hidden) {
                        // Stop monitoring if app goes to background
                        clearInterval(this.reconnectionInterval);
                        this.reconnectionInterval = null;
                    }
                }, 5000);
            }
        };

        const stopMonitoring = () => {
            if (this.reconnectionInterval) {
                clearInterval(this.reconnectionInterval);
                this.reconnectionInterval = null;
            }
        };

        // Listen for visibility changes
        document.addEventListener('visibilitychange', () => {
            if (document.visibilityState === 'visible') {
                // App came to foreground - check immediately then start monitoring
                setTimeout(() => {
                    this.checkConnectionHealth();
                    if (!this.connected && navigator.onLine) {
                        this.attemptReconnection();
                        startMonitoring();
                    }
                }, 200);
            } else {
                // App went to background - stop monitoring
                stopMonitoring();
            }
        });

        // Start monitoring if currently visible and needed
        if (!document.hidden) {
            startMonitoring();
        }
    }

    async attemptReconnection() {
        // Prevent multiple simultaneous reconnection attempts
        if (this.isReconnecting) {
            return;
        }

        // Check if we've exceeded max attempts
        if (this.reconnectionAttempts >= this.maxReconnectionAttempts) {
            this.updateConnectionStatus('Disconnected - Click to reconnect');
            return;
        }

        this.isReconnecting = true;
        this.reconnectionAttempts++;

        this.updateConnectionStatus(`Reconnecting (${this.reconnectionAttempts}/${this.maxReconnectionAttempts})...`);

        try {
            // Clear dead connections first
            this.relayPool.forEach((relay, url) => {
                if (!relay.ws || relay.ws.readyState !== WebSocket.OPEN) {
                    this.relayPool.delete(url);
                    this.relayKinds.delete(url);
                }
            });

            // Try to connect to at least one broadcast relay
            let connected = false;
            for (const relayUrl of this.broadcastRelays) {
                if (this.relayPool.has(relayUrl)) {
                    const relay = this.relayPool.get(relayUrl);
                    if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                        connected = true;
                        break;
                    }
                }

                try {
                    await this.connectToRelayWithTimeout(relayUrl, 'broadcast', 3000);
                    this.subscribeToSingleRelay(relayUrl);
                    connected = true;
                    break;
                } catch (err) {
                }
            }

            if (connected) {
                this.connected = true;
                this.reconnectionAttempts = 0; // Reset on success
                this.updateConnectionStatus();

                // Reconnect to other relays in background
                this.reconnectToBroadcastRelays();

                // Also reconnect to geo relays if we're in a geohash channel
                if (this.currentGeohash) {
                    this.connectToGeoRelays(this.currentGeohash);
                }
            }
        } catch (error) {
            //
        } finally {
            this.isReconnecting = false;
        }
    }

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
    }

    closeSidebar() {
        const sidebar = document.getElementById('sidebar');
        sidebar.classList.remove('open');
        document.getElementById('mobileOverlay').classList.remove('active');
    }

    setupContextMenu() {
        // Close context menu on click outside - using event delegation
        document.addEventListener('click', (e) => {
            const contextMenu = document.getElementById('contextMenu');

            // Only proceed if context menu is actually active
            if (!contextMenu.classList.contains('active')) {
                return;
            }

            // If clicking outside the context menu and not on enhanced emoji modal
            if (!e.target.closest('.context-menu') && !e.target.closest('.enhanced-emoji-modal')) {
                contextMenu.classList.remove('active');
            }
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
            document.getElementById('contextMenu').classList.remove('active');
        });

        document.getElementById('ctxPM').addEventListener('click', () => {
            if (this.contextMenuData) {
                const baseNym = this.contextMenuData.nym;
                const suffix = this.getPubkeySuffix(this.contextMenuData.pubkey);
                const fullNym = `${baseNym}#${suffix}`;
                this.openUserPM(fullNym, this.contextMenuData.pubkey);
            }
            document.getElementById('contextMenu').classList.remove('active');
        });

        // Add zap handler
        document.getElementById('ctxZap').addEventListener('click', async () => {
            if (this.contextMenuData && this.contextMenuData.messageId) {
                const { messageId, pubkey, nym } = this.contextMenuData;

                // Close context menu immediately
                document.getElementById('contextMenu').classList.remove('active');

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

        // Add slap handler
        let slapOption = document.getElementById('ctxSlap');
        if (!slapOption) {
            // Create slap option if it doesn't exist
            slapOption = document.createElement('div');
            slapOption.className = 'context-menu-item';
            slapOption.id = 'ctxSlap';
            slapOption.textContent = 'Slap with Trout';

            // Insert after PM option
            const pmOption = document.getElementById('ctxPM');
            if (pmOption && pmOption.nextSibling) {
                pmOption.parentNode.insertBefore(slapOption, pmOption.nextSibling);
            } else if (pmOption) {
                pmOption.parentNode.appendChild(slapOption);
            }
        }

        // Add report handler
        document.getElementById('ctxReport').addEventListener('click', () => {
            if (this.contextMenuData) {
                this.openReportModal();
            }
            document.getElementById('contextMenu').classList.remove('active');
        });

        // Add the click handler for slap
        slapOption.addEventListener('click', () => {
            if (this.contextMenuData) {
                // Pass the pubkey directly as the argument
                this.cmdSlap(this.contextMenuData.pubkey);
            }
            document.getElementById('contextMenu').classList.remove('active');
        });

        document.getElementById('ctxReact').addEventListener('click', () => {
            if (this.contextMenuData && this.contextMenuData.messageId) {
                document.getElementById('contextMenu').classList.remove('active');

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

                    this.showEnhancedReactionPicker(this.contextMenuData.messageId, tempButton);

                    // Remove temp button after modal is created
                    setTimeout(() => tempButton.remove(), 100);
                }, 100);
            }
        });

        document.getElementById('ctxQuote').addEventListener('click', () => {
            if (this.contextMenuData && this.contextMenuData.content) {
                const input = document.getElementById('messageInput');
                const baseNym = this.contextMenuData.nym;
                const suffix = this.getPubkeySuffix(this.contextMenuData.pubkey);
                const fullNym = `${baseNym}#${suffix}`;
                input.value = `> @${fullNym}: ${this.contextMenuData.content}\n\n`;
                input.focus();
            }
            document.getElementById('contextMenu').classList.remove('active');
        });

        document.getElementById('ctxBlock').addEventListener('click', () => {
            if (this.contextMenuData) {
                // Pass the pubkey directly as the argument
                this.cmdBlock(this.contextMenuData.pubkey);
            }
            document.getElementById('contextMenu').classList.remove('active');
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
            document.getElementById('contextMenu').classList.remove('active');
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
            document.getElementById('contextMenu').classList.remove('active');
        });

        // Add delete message handler
        document.getElementById('ctxDeleteMessage').addEventListener('click', async () => {
            if (this.contextMenuData && this.contextMenuData.messageId && this.contextMenuData.pubkey === this.pubkey) {
                if (confirm('Are you sure you want to delete this message? This will send a deletion request to relays.')) {
                    await this.publishDeletionEvent(this.contextMenuData.messageId);
                    this.displaySystemMessage('Deletion request sent to relays');
                }
            }
            document.getElementById('contextMenu').classList.remove('active');
        });
    }

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
    }

    closeReportModal() {
        const modal = document.getElementById('reportModal');
        modal.style.display = 'none';

        // Reset form
        document.getElementById('reportType').value = 'nudity';
        document.getElementById('reportDetails').value = '';
        document.getElementById('reportMessage').checked = true;
    }

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
    }

    showContextMenu(e, nym, pubkey, content = null, messageId = null) {
        e.preventDefault();
        e.stopPropagation();

        const menu = document.getElementById('contextMenu');
        // Parse base nym from display format - this removes HTML tags
        const parsedNym = this.parseNymFromDisplay(nym);
        // Get just the base nym without any suffix
        const baseNym = parsedNym.split('#')[0] || parsedNym;
        const suffix = this.getPubkeySuffix(pubkey);
        const fullNym = `${baseNym}#${suffix}`;

        this.contextMenuData = { nym: baseNym, pubkey, content, messageId };

        // First, clear any existing dynamic menu items (community moderation options)
        const existingModItems = menu.querySelectorAll('.context-menu-item.moderation');
        existingModItems.forEach(item => item.remove());

        // Add slap option if it doesn't exist
        let slapOption = document.getElementById('ctxSlap');
        if (!slapOption) {
            // Create slap option
            slapOption = document.createElement('div');
            slapOption.className = 'context-menu-item';
            slapOption.id = 'ctxSlap';
            slapOption.textContent = 'Slap with Trout';

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

        // Add community moderation options if in a community and user is admin/mod
        if (this.currentCommunity && pubkey !== this.pubkey) {
            const isAdmin = this.ownedCommunities.has(this.currentCommunity);
            const isMod = this.communityModerators.has(this.currentCommunity) &&
                this.communityModerators.get(this.currentCommunity).has(this.pubkey);

            if (isAdmin || isMod) {
                const community = this.communityChannels.get(this.currentCommunity);
                const isTargetAdmin = community && community.admin === pubkey;
                const isTargetMod = this.communityModerators.has(this.currentCommunity) &&
                    this.communityModerators.get(this.currentCommunity).has(pubkey);
                const isTargetBanned = this.communityBans.has(this.currentCommunity) &&
                    this.communityBans.get(this.currentCommunity).has(pubkey);

                // Add separator
                const separator = document.createElement('div');
                separator.className = 'context-menu-item moderation';
                separator.style.borderTop = '1px solid var(--border)';
                separator.style.pointerEvents = 'none';
                separator.style.padding = '0';
                separator.style.margin = '5px 0';
                menu.appendChild(separator);

                // Add moderation label
                const modLabel = document.createElement('div');
                modLabel.className = 'context-menu-item moderation';
                modLabel.style.fontSize = '10px';
                modLabel.style.color = 'var(--text-dim)';
                modLabel.style.pointerEvents = 'none';
                modLabel.textContent = 'COMMUNITY MODERATION';
                menu.appendChild(modLabel);

                // Kick option (can't kick admin or other mods if you're a mod)
                if (!isTargetAdmin && !(isMod && isTargetMod) && !isTargetBanned) {
                    const kickOption = document.createElement('div');
                    kickOption.className = 'context-menu-item moderation';
                    kickOption.textContent = 'Kick';
                    kickOption.onclick = () => {
                        this.cmdKick(fullNym);
                        menu.classList.remove('active');
                    };
                    menu.appendChild(kickOption);
                }

                // Ban/Unban option
                if (!isTargetAdmin && !(isMod && isTargetMod)) {
                    const banOption = document.createElement('div');
                    banOption.className = 'context-menu-item moderation danger';
                    banOption.textContent = isTargetBanned ? 'Unban' : 'Ban';
                    banOption.onclick = () => {
                        if (isTargetBanned) {
                            this.cmdUnban(fullNym);
                        } else {
                            this.cmdBan(fullNym);
                        }
                        menu.classList.remove('active');
                    };
                    menu.appendChild(banOption);
                }

                // Admin-only options
                if (isAdmin && !isTargetAdmin) {
                    // Add/Remove moderator
                    const modOption = document.createElement('div');
                    modOption.className = 'context-menu-item moderation';
                    modOption.style.color = 'var(--secondary)';
                    modOption.textContent = isTargetMod ? 'Remove Moderator' : 'Make Moderator';
                    modOption.onclick = () => {
                        if (isTargetMod) {
                            this.cmdRemoveMod(fullNym);
                        } else {
                            this.cmdAddMod(fullNym);
                        }
                        menu.classList.remove('active');
                    };
                    menu.appendChild(modOption);
                }
            }
        }

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

        // Hide block option if it's your own message
        const blockOption = document.getElementById('ctxBlock');
        if (pubkey === this.pubkey) {
            blockOption.style.display = 'none';
        } else {
            blockOption.style.display = 'block';
            blockOption.textContent = this.blockedUsers.has(baseNym) ? 'Unblock User' : 'Block User';
        }

        // Hide PM option if it's yourself
        document.getElementById('ctxPM').style.display = pubkey === this.pubkey ? 'none' : 'block';

        // Show/hide quote option
        document.getElementById('ctxQuote').style.display = content ? 'block' : 'none';

        // Show/hide React option
        const reactOption = document.getElementById('ctxReact');
        reactOption.style.display = messageId ? 'block' : 'none';

        // Show/hide Delete Message option - only for own messages
        const deleteOption = document.getElementById('ctxDeleteMessage');
        if (pubkey === this.pubkey && messageId) {
            deleteOption.style.display = 'block';
        } else {
            deleteOption.style.display = 'none';
        }

        // Add active class first to make visible
        menu.classList.add('active');

        // Get dimensions after making visible
        const menuRect = menu.getBoundingClientRect();
        const windowHeight = window.innerHeight;
        const windowWidth = window.innerWidth;

        let top = e.pageY;
        let left = e.pageX;

        // Check if menu would go off bottom of screen
        if (top + menuRect.height > windowHeight) {
            top = windowHeight - menuRect.height - 10;
        }

        // Check if menu would go off right of screen
        if (left + menuRect.width > windowWidth) {
            left = windowWidth - menuRect.width - 10;
        }

        // Ensure menu doesn't go off top or left
        top = Math.max(10, top);
        left = Math.max(10, left);

        menu.style.left = left + 'px';
        menu.style.top = top + 'px';

        // Prevent the click from immediately closing the menu
        e.stopImmediatePropagation();
    }

    showMobileReactionPicker(messageId) {
        const picker = document.createElement('div');
        picker.className = 'reaction-picker active';
        picker.style.position = 'fixed';
        picker.style.bottom = '50%';
        picker.style.left = '50%';
        picker.style.transform = 'translate(-50%, 50%)';
        picker.style.zIndex = '1001';
        picker.style.display = 'grid';
        picker.style.gridTemplateColumns = 'repeat(5, 1fr)';

        picker.innerHTML = ['👍', '❤️', '😂', '🔥', '👎', '😮', '🤔', '💯', '🎉', '👏'].map(emoji =>
            `<button class="reaction-emoji" onclick="nym.sendReaction('${messageId}', '${emoji}'); this.parentElement.remove();">${emoji}</button>`
        ).join('');

        document.body.appendChild(picker);

        // Close on click outside
        setTimeout(() => {
            document.addEventListener('click', (e) => {
                if (!picker.contains(e.target)) {
                    picker.remove();
                }
            }, { once: true });
        }, 100);
    }

    loadBlockedKeywords() {
        const saved = localStorage.getItem('nym_blocked_keywords');
        if (saved) {
            this.blockedKeywords = new Set(JSON.parse(saved));
        }
        this.updateKeywordList();
    }

    saveBlockedKeywords() {
        localStorage.setItem('nym_blocked_keywords', JSON.stringify(Array.from(this.blockedKeywords)));
    }

    addBlockedKeyword() {
        const input = document.getElementById('newKeywordInput');
        const keyword = input.value.trim().toLowerCase();

        if (keyword) {
            this.blockedKeywords.add(keyword);
            this.saveBlockedKeywords();
            this.updateKeywordList();
            input.value = '';

            // Hide messages containing this keyword
            document.querySelectorAll('.message').forEach(msg => {
                const content = msg.querySelector('.message-content');
                if (content && content.textContent.toLowerCase().includes(keyword)) {
                    msg.classList.add('blocked');
                }
            });

            this.displaySystemMessage(`Blocked keyword: "${keyword}"`);

            // Sync to Nostr for persistent connections
            if (this.connectionMode !== 'ephemeral') {
                this.saveSyncedSettings();
            }
        }
    }

    removeBlockedKeyword(keyword) {
        this.blockedKeywords.delete(keyword);
        this.saveBlockedKeywords();
        this.updateKeywordList();

        // Re-check all messages
        document.querySelectorAll('.message').forEach(msg => {
            const author = msg.dataset.author;
            const content = msg.querySelector('.message-content');

            if (content && !this.blockedUsers.has(author)) {
                const hasBlockedKeyword = Array.from(this.blockedKeywords).some(kw =>
                    content.textContent.toLowerCase().includes(kw)
                );

                if (!hasBlockedKeyword) {
                    msg.classList.remove('blocked');
                }
            }
        });

        this.displaySystemMessage(`Unblocked keyword: "${keyword}"`);

        // Sync to Nostr for persistent connections
        if (this.connectionMode !== 'ephemeral') {
            this.saveSyncedSettings();
        }
    }

    updateKeywordList() {
        const list = document.getElementById('keywordList');
        if (this.blockedKeywords.size === 0) {
            list.innerHTML = '<div style="color: var(--text-dim); font-size: 12px;">No blocked keywords</div>';
        } else {
            list.innerHTML = Array.from(this.blockedKeywords).map(keyword => `
                <div class="keyword-item">
                    <span>${this.escapeHtml(keyword)}</span>
                    <button class="remove-keyword-btn" onclick="nym.removeBlockedKeyword('${this.escapeHtml(keyword).replace(/'/g, "\\'")}')">Remove</button>
                </div>
            `).join('');
        }
    }

    hasBlockedKeyword(text) {
        const lowerText = text.toLowerCase();
        return Array.from(this.blockedKeywords).some(keyword => lowerText.includes(keyword));
    }

    generateRandomNym() {
        const adjectives = [
            'quantum', 'neon', 'cyber', 'shadow', 'plasma',
            'echo', 'nexus', 'void', 'flux', 'ghost',
            'phantom', 'stealth', 'cryptic', 'dark', 'neural',
            'binary', 'matrix', 'digital', 'virtual', 'zero',
            'null', 'anon', 'masked', 'hidden', 'cipher',
            'enigma', 'spectral', 'rogue', 'omega', 'alpha',
            'delta', 'sigma', 'vortex', 'turbo', 'razor',
            'blade', 'frost', 'storm', 'glitch', 'pixel'
        ];

        const nouns = [
            'ghost', 'nomad', 'drift', 'pulse', 'wave',
            'spark', 'node', 'byte', 'mesh', 'link',
            'runner', 'hacker', 'coder', 'agent', 'proxy',
            'daemon', 'virus', 'worm', 'bot', 'droid',
            'reaper', 'shadow', 'wraith', 'specter', 'shade',
            'entity', 'unit', 'core', 'nexus', 'cypher',
            'breach', 'exploit', 'overflow', 'inject', 'root',
            'kernel', 'shell', 'terminal', 'console', 'script'
        ];

        const adj = adjectives[Math.floor(Math.random() * adjectives.length)];
        const noun = nouns[Math.floor(Math.random() * nouns.length)];

        // Use the last 4 chars of pubkey
        const suffix = this.getPubkeySuffix(this.pubkey);

        return `${adj}_${noun}#${suffix}`;
    }

    formatNymWithPubkey(nym, pubkey) {
        // If nym already has a # suffix, don't add another
        if (nym.includes('#')) {
            return nym;
        }

        // Get last 4 characters of pubkey
        const suffix = pubkey ? pubkey.slice(-4) : '????';
        return `${nym}<span class="nym-suffix">#${suffix}</span>`;
    }

    getPubkeySuffix(pubkey) {
        return pubkey ? pubkey.slice(-4) : '????';
    }

    parseNymFromDisplay(displayNym) {
        if (!displayNym) return 'anon';

        // Strip all HTML tags first, including flair
        const withoutHtml = displayNym.replace(/<[^>]*>/g, '').trim();

        // Then get base nym without suffix
        const parts = withoutHtml.split('#');
        return parts[0] || withoutHtml;
    }

    async connectToRelays() {
        try {
            this.updateConnectionStatus('Connecting...');

            // Check if we're already connected to ANY broadcast relay from pre-connection
            let initialConnected = false;
            let connectedRelayUrl = null;

            for (const relayUrl of this.broadcastRelays) {
                if (this.relayPool.has(relayUrl)) {
                    const relay = this.relayPool.get(relayUrl);
                    if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                        initialConnected = true;
                        connectedRelayUrl = relayUrl;
                        break;
                    }
                }
            }

            // If not already connected, try to connect to broadcast relays in parallel for speed
            if (!initialConnected) {
                // Get first 5 available relays for parallel connection attempt
                const initialRelays = this.broadcastRelays
                    .filter(url => this.shouldRetryRelay(url))
                    .slice(0, 5);

                if (initialRelays.length > 0) {
                    // Create connection promises that resolve with relay URL on success
                    const connectionPromises = initialRelays.map(relayUrl =>
                        this.connectToRelayWithTimeout(relayUrl, 'broadcast', 2000)
                            .then(() => relayUrl)
                            .catch(err => {
                                this.trackRelayFailure(relayUrl);
                                return null;
                            })
                    );

                    // Wait for first successful connection (Promise.any-like behavior)
                    const firstSuccessful = await new Promise((resolve) => {
                        let pending = connectionPromises.length;
                        connectionPromises.forEach(p => {
                            p.then(result => {
                                if (result) resolve(result);
                                else {
                                    pending--;
                                    if (pending === 0) resolve(null);
                                }
                            });
                        });
                    });

                    if (firstSuccessful) {
                        initialConnected = true;
                        connectedRelayUrl = firstSuccessful;
                    }
                }

                // If parallel attempt failed, fall back to sequential for remaining relays
                if (!initialConnected) {
                    const remainingRelays = this.broadcastRelays.slice(5);
                    for (const relayUrl of remainingRelays) {
                        if (!this.shouldRetryRelay(relayUrl)) {
                            continue;
                        }

                        try {
                            await this.connectToRelayWithTimeout(relayUrl, 'broadcast', 2000);
                            initialConnected = true;
                            connectedRelayUrl = relayUrl;
                            break;
                        } catch (err) {
                            this.trackRelayFailure(relayUrl);
                        }
                    }
                }
            }

            if (!initialConnected) {
                throw new Error('Could not connect to any broadcast relay');
            }

            // Enable input immediately after first relay connects
            document.getElementById('messageInput').disabled = false;
            document.getElementById('sendBtn').disabled = false;
            this.connected = true;

            // Process any queued messages that were waiting for connection
            if (this.messageQueue.length > 0) {
                const queuedMessages = [...this.messageQueue];
                this.messageQueue = [];
                queuedMessages.forEach(msg => {
                    try {
                        const parsed = JSON.parse(msg);
                        this.sendToRelay(parsed);
                    } catch (e) {
                    }
                });
            }

            // Set initial channel label to pinned landing channel
            const channelLabel = this.isValidGeohash(this.currentChannel) ? this.currentChannel : `#${this.currentChannel}`;
            const channelType = this.isValidGeohash(this.currentChannel) ? '(Geohash)' : '(Ephemeral)';
            document.getElementById('currentChannel').innerHTML = `${channelLabel} <span style="font-size: 12px; color: var(--text-dim);">${channelType}</span>`;


            // Start subscriptions on all connected relays
            this.subscribeToAllRelays();

            // Switch to the pinned landing channel based on type
            setTimeout(() => {
                const pinned = this.pinnedLandingChannel || { type: 'ephemeral', channel: 'bar' };

                if (pinned.type === 'community') {
                    // Give communities time to load, then switch
                    setTimeout(() => {
                        if (this.communityChannels.has(pinned.communityId)) {
                            this.switchToCommunity(pinned.communityId);
                        } else {
                            // Community not available, fallback to bar
                            this.switchChannel('bar', '');
                        }
                    }, 1000);
                } else if (pinned.type === 'geohash') {
                    this.switchChannel(pinned.geohash, pinned.geohash);
                } else {
                    // Ephemeral channel
                    this.switchChannel(pinned.channel || 'bar', '');
                }
            }, 100);

            // Update status to show we're connected
            this.updateConnectionStatus();
            this.displaySystemMessage(`Connected to the Nostr network via multiple relays...`);

            // Load synced settings for persistent connections
            if (this.connectionMode !== 'ephemeral') {
                // Wait a bit longer to ensure relays are ready
                setTimeout(() => {
                    this.loadSyncedSettings();
                }, 2000); // Increased from 1000ms
            }

            // Now connect to remaining broadcast relays in background
            this.broadcastRelays.forEach(relayUrl => {
                if (!this.relayPool.has(relayUrl) && this.shouldRetryRelay(relayUrl)) {
                    this.connectToRelay(relayUrl, 'broadcast')
                        .then(() => {
                            this.subscribeToSingleRelay(relayUrl);
                            this.updateConnectionStatus();
                        })
                        .catch(err => {
                            this.trackRelayFailure(relayUrl);
                        });
                }
            });

            // Connect to nosflare for sending only (no subscriptions)
            if (this.shouldRetryRelay(this.nosflareRelay)) {
                this.connectToRelay(this.nosflareRelay, 'nosflare')
                    .then(() => {
                        this.updateConnectionStatus();
                    })
                    .catch(err => {
                        this.trackRelayFailure(this.nosflareRelay);
                    });
            }

            // Discover additional relays in the background
            setTimeout(() => {
                this.discoverRelays().then(() => {
                    // Connect to discovered relays for additional reading sources
                    const relaysToConnect = Array.from(this.discoveredRelays)
                        .filter(url => !this.relayPool.has(url) && this.shouldRetryRelay(url))
                        .slice(0, this.maxRelaysForReq);

                    if (relaysToConnect.length > 0) {
                        // Stagger connections to avoid overwhelming the browser
                        relaysToConnect.forEach((relayUrl, index) => {
                            setTimeout(() => {
                                this.connectToRelayWithTimeout(relayUrl, 'read', this.relayTimeout)
                                    .then(() => {
                                        this.subscribeToSingleRelay(relayUrl);
                                        this.updateConnectionStatus();
                                    })
                                    .catch(err => {
                                        this.trackRelayFailure(relayUrl);
                                    });
                            }, index * 100);
                        });
                    }
                });
            }, 100);

        } catch (error) {
            this.updateConnectionStatus('Connection Failed');
            this.displaySystemMessage('Failed to connect to relays: ' + error.message);

            // Re-enable input anyway in case user wants to retry
            document.getElementById('messageInput').disabled = false;
            document.getElementById('sendBtn').disabled = false;
        }
    }

    async quickConnect() {
        // Try broadcast relays in order with very short timeout
        for (const relayUrl of this.broadcastRelays) {
            if (!this.shouldRetryRelay(relayUrl)) {
                continue;
            }

            try {
                await this.connectToRelayWithTimeout(relayUrl, 'broadcast', 1500); // 1.5 second timeout

                // Enable input immediately
                document.getElementById('messageInput').disabled = false;
                document.getElementById('sendBtn').disabled = false;
                this.connected = true;

                // Start subscriptions
                this.subscribeToSingleRelay(relayUrl);

                this.updateConnectionStatus();
                return true;
            } catch (err) {
                this.trackRelayFailure(relayUrl);
            }
        }

        return false; // All broadcast relays failed
    }

    resubscribeAllRelays() {
        this.relayPool.forEach((relay, url) => {
            if (relay.type === 'nosflare') return; // write-only
            if (!relay.ws || relay.ws.readyState !== WebSocket.OPEN) return;

            // Close existing subscriptions before resubscribing
            this.closeSubscriptionsForRelay(url);
            this.subscribeToSingleRelay(url);
        });
    }

    closeSubscriptionsForRelay(relayUrl) {
        const relay = this.relayPool.get(relayUrl);
        if (!relay || !relay.ws || relay.ws.readyState !== WebSocket.OPEN) return;

        // Never send to nosflare
        if (['wss://sendit.nosflare.com', 'wss://relay.nosflare.com'].includes(relayUrl)) return;

        // Close all active subscriptions for this relay
        if (relay.subscriptions) {
            relay.subscriptions.forEach(subId => {
                relay.ws.send(JSON.stringify(["CLOSE", subId]));
            });
            relay.subscriptions.clear();
        } else {
            // Initialize subscriptions set if it doesn't exist
            relay.subscriptions = new Set();
        }
    }

    subscribeToSingleRelay(relayUrl) {
        const relay = this.relayPool.get(relayUrl);
        if (!relay || !relay.ws || relay.ws.readyState !== WebSocket.OPEN) return;

        // Never send REQ to nosflare
        if (['wss://sendit.nosflare.com', 'wss://relay.nosflare.com'].includes(relayUrl)) return;

        const ws = relay.ws;

        const subId = "nym-" + Math.random().toString(36).substring(7);

        // Track this subscription
        if (!relay.subscriptions) {
            relay.subscriptions = new Set();
        }
        relay.subscriptions.add(subId);

        // Build filters array
        const filters = [
            // Messages in geohash channels
            {
                kinds: [20000],
                limit: 500,
            },
            // Reactions for geohash channels
            {
                kinds: [7],
                "#k": ["20000"],
                limit: 500,
            },
            // Messages in standard/ephemeral channels
            {
                kinds: [23333],
                limit: 500,
            },
            // Reactions for standard channels
            {
                kinds: [7],
                "#k": ["23333"],
                limit: 500,
            },
            // Messages in communities
            {
                kinds: [4550],
                limit: 500
            },
            // All public community definitions
            {
                kinds: [34550],
                limit: 500
            },
            // Reactions for community posts
            {
                kinds: [7],
                "#k": ["4550"],
                limit: 500
            },
            // Moderation events
            {
                kinds: [1984],
                limit: 500
            },
            // Reactions for PMs
            {
                kinds: [7],
                "#k": ["1059"],
                limit: 500
            },
            // User shop items
            {
                kinds: [30078],
                "#d": ["nym-shop-active"],
                limit: 1000
            },
            // Zap receipts
            {
                kinds: [9735],
                limit: 500,
            }
        ];

        if (this.pubkey) {
            filters.push(
                // Gift wraps addressed to me
                {
                    kinds: [1059],
                    "#p": [this.pubkey],
                    limit: 500,
                },
                // Profile/community definitions by me
                {
                    kinds: [34550],
                    authors: [this.pubkey],
                    limit: 500
                },
                // Any reactions with #p = my pubkey
                {
                    kinds: [7],
                    "#p": [this.pubkey],
                    limit: 500
                },
                // MY shop purchases and active items
                {
                    kinds: [30078],
                    authors: [this.pubkey],
                    "#d": ["nym-shop-purchases", "nym-shop-active"],
                    limit: 100
                },
                // P2P signaling addressed to me
                {
                    kinds: [25051],
                    "#p": [this.pubkey],
                    since: Math.floor(Date.now() / 1000) - 120, // Last 2 minutes
                    limit: 50
                }
            );
        }

        // Send single REQ with all filters
        ws.send(JSON.stringify(["REQ", subId, ...filters]));
    }

    async connectToRelayWithTimeout(relayUrl, type, timeout) {
        return Promise.race([
            this.connectToRelay(relayUrl, type),
            new Promise((_, reject) =>
                setTimeout(() => reject(new Error(`Timeout connecting to ${relayUrl}`)), timeout)
            )
        ]);
    }

    shouldRetryRelay(relayUrl) {
        const failedAttempt = this.failedRelays.get(relayUrl);
        if (!failedAttempt) return true;

        const now = Date.now();
        const canRetry = now - failedAttempt > this.relayRetryDelay;

        if (!canRetry) {
            //
        }

        return canRetry;
    }

    trackRelayFailure(relayUrl) {
        this.failedRelays.set(relayUrl, Date.now());
    }

    clearRelayFailure(relayUrl) {
        this.failedRelays.delete(relayUrl);
    }

    async connectToRelay(relayUrl, type = 'read') {
        return new Promise((resolve, reject) => {
            try {
                // Check if blacklisted but also check if expired
                if (this.blacklistedRelays.has(relayUrl)) {
                    if (!this.isBlacklistExpired(relayUrl)) {
                        // Still blacklisted
                        resolve();
                        return;
                    }
                    // Was expired and removed, continue connecting
                }

                if (!this.shouldRetryRelay(relayUrl)) {
                    resolve();
                    return;
                }

                // Skip if already connected
                if (this.relayPool.has(relayUrl)) {
                    const existingRelay = this.relayPool.get(relayUrl);
                    if (existingRelay.ws && existingRelay.ws.readyState === WebSocket.OPEN) {
                        resolve();
                        return;
                    }
                }

                const ws = new WebSocket(relayUrl);
                let verificationTimeout;
                let connectionTimeout;

                // Add connection timeout (5 seconds)
                connectionTimeout = setTimeout(() => {
                    if (ws.readyState !== WebSocket.OPEN) {
                        ws.close();
                        this.blacklistedRelays.add(relayUrl);
                        this.blacklistTimestamps.set(relayUrl, Date.now());
                        reject(new Error('Connection timeout'));
                    }
                }, 5000);

                ws.onopen = () => {
                    clearTimeout(connectionTimeout);

                    this.relayPool.set(relayUrl, {
                        ws,
                        type,
                        status: 'connected',
                        connectedAt: Date.now()
                    });

                    this.clearRelayFailure(relayUrl);

                    // For broadcast/nosflare/geo relays, just resolve
                    if (type === 'broadcast' || type === 'nosflare' || type === 'geo') {
                        resolve();
                        return;
                    }

                    // For read relays, set up verification timeout
                    if (type === 'read') {
                        // Initialize kinds tracking for this relay
                        if (!this.relayKinds.has(relayUrl)) {
                            this.relayKinds.set(relayUrl, new Set());
                        }

                        // Set timeout to check if relay sends our required kinds
                        verificationTimeout = setTimeout(() => {
                            const receivedKinds = this.relayKinds.get(relayUrl);
                            const hasRequiredKinds =
                                receivedKinds && (
                                    receivedKinds.has(20000) ||
                                    receivedKinds.has(23333) ||
                                    receivedKinds.has(7) ||
                                    receivedKinds.has(1059)
                                );

                            if (!hasRequiredKinds) {
                                ws.close();
                                this.relayPool.delete(relayUrl);
                                this.relayKinds.delete(relayUrl);
                                this.blacklistedRelays.add(relayUrl);
                                this.blacklistTimestamps.set(relayUrl, Date.now());
                                this.updateConnectionStatus();
                            }
                        }, this.relayVerificationTimeout);
                    }

                    resolve();
                };

                ws.onmessage = (event) => {
                    try {
                        const msg = JSON.parse(event.data);
                        this.handleRelayMessage(msg, relayUrl);
                    } catch (e) {
                    }
                };

                ws.onerror = (error) => {
                    clearTimeout(verificationTimeout);
                    clearTimeout(connectionTimeout);

                    // Immediately blacklist on connection error
                    this.blacklistedRelays.add(relayUrl);
                    this.blacklistTimestamps.set(relayUrl, Date.now());

                    reject(error);
                };

                ws.onclose = () => {
                    clearTimeout(verificationTimeout);
                    clearTimeout(connectionTimeout);

                    // If connection closed before opening, blacklist it
                    if (ws.readyState !== WebSocket.OPEN) {
                        this.blacklistedRelays.add(relayUrl);
                        this.blacklistTimestamps.set(relayUrl, Date.now());
                    }

                    // Immediately remove from pool and update status
                    this.relayPool.delete(relayUrl);
                    this.relayKinds.delete(relayUrl);

                    // Force status update after disconnect
                    this.updateConnectionStatus();

                    // Reconnect ALL relay types (broadcast, nosflare, AND read relays)
                    if (this.connected && !this.blacklistedRelays.has(relayUrl)) {
                        // Track disconnections
                        if (!this.reconnectingRelays) {
                            this.reconnectingRelays = new Set();
                        }

                        // Only reconnect if not already reconnecting this URL
                        if (this.reconnectingRelays.has(relayUrl)) {
                            return;
                        }

                        this.reconnectingRelays.add(relayUrl);

                        // Implement exponential backoff for reconnection
                        const attemptReconnect = (attempt = 0) => {
                            const maxAttempts = 10;
                            const baseDelay = 5000;
                            const maxDelay = 60000;

                            // Calculate exponential backoff delay
                            const delay = Math.min(baseDelay * Math.pow(1.5, attempt), maxDelay);

                            setTimeout(() => {
                                // Check WebSocket state and network connectivity
                                if (!navigator.onLine) {
                                    this.reconnectingRelays.delete(relayUrl);
                                    this.updateConnectionStatus();
                                    return;
                                }

                                // Check if we're still supposed to be connected
                                if (!this.connected) {
                                    this.reconnectingRelays.delete(relayUrl);
                                    this.updateConnectionStatus();
                                    return;
                                }

                                this.connectToRelay(relayUrl, type)
                                    .then(() => {
                                        // Re-subscribe after reconnection for ALL relay types (except nosflare which is write-only)
                                        if (type === 'broadcast' || type === 'read' || type === 'geo') {
                                            this.subscribeToSingleRelay(relayUrl);
                                        }
                                        this.updateConnectionStatus();

                                        // Remove from reconnecting set
                                        this.reconnectingRelays.delete(relayUrl);

                                        if (this.reconnectingRelays.size === 0) {

                                            // After broadcast relays reconnect, also retry discovered relays
                                            if (type === 'broadcast') {
                                                setTimeout(() => {
                                                    this.retryDiscoveredRelays();
                                                }, 2000);
                                            }
                                        }
                                    })
                                    .catch(err => {
                                        this.trackRelayFailure(relayUrl);
                                        this.updateConnectionStatus();

                                        // Try again if we haven't exceeded max attempts
                                        if (attempt < maxAttempts - 1) {
                                            attemptReconnect(attempt + 1);
                                        } else {
                                            this.reconnectingRelays.delete(relayUrl);
                                            this.updateConnectionStatus();
                                        }
                                    });
                            }, delay);
                        };

                        // Start reconnection attempts
                        attemptReconnect(0);
                    }
                };

            } catch (error) {
                this.blacklistedRelays.add(relayUrl);
                this.blacklistTimestamps.set(relayUrl, Date.now());
                this.trackRelayFailure(relayUrl);
                reject(error);
            }
        });
    }

    isBlacklistExpired(relayUrl) {
        if (!this.blacklistTimestamps.has(relayUrl)) {
            return true; // Not in timestamp map, shouldn't be blacklisted
        }

        const blacklistedAt = this.blacklistTimestamps.get(relayUrl);
        const now = Date.now();

        // Reduce blacklist duration from 5 minutes to 2 minutes
        const blacklistDuration = 120000; // 2 minutes instead of 5

        if (now - blacklistedAt > blacklistDuration) {
            // Expired, remove from blacklist
            this.blacklistedRelays.delete(relayUrl);
            this.blacklistTimestamps.delete(relayUrl);
            return true;
        }

        return false;
    }

    async retryDiscoveredRelays() {

        // Clean expired blacklist entries first
        for (const relayUrl of this.blacklistedRelays) {
            this.isBlacklistExpired(relayUrl);
        }

        // Try to connect to any discovered relays we're not connected to
        const relaysToTry = [];

        // From previously discovered relays (this is the main source)
        for (const relay of this.discoveredRelays) {
            if (!this.relayPool.has(relay) &&
                !this.blacklistedRelays.has(relay) &&
                !this.broadcastRelays.includes(relay) &&
                relay !== this.nosflareRelay &&
                !relaysToTry.includes(relay) &&
                this.shouldRetryRelay(relay)) {
                relaysToTry.push(relay);
            }
        }

        if (relaysToTry.length > 0) {

            // Try connecting to them with staggered timing
            for (let i = 0; i < Math.min(relaysToTry.length, 20); i++) { // Try up to 20 relays
                const relayUrl = relaysToTry[i];
                setTimeout(() => {
                    this.connectToRelayWithTimeout(relayUrl, 'read', this.relayTimeout)
                        .then(() => {
                            this.subscribeToSingleRelay(relayUrl);
                            this.updateConnectionStatus();
                        })
                        .catch(err => {
                            this.trackRelayFailure(relayUrl);
                        });
                }, i * 200); // Stagger by 200ms
            }
        } else {

            // If we have no discovered relays, try to discover them again
            this.discoverRelays().then(() => {
                // After discovery, try connecting to newly discovered relays
                const newRelaysToTry = Array.from(this.discoveredRelays)
                    .filter(url => !this.relayPool.has(url) &&
                        !this.blacklistedRelays.has(url) &&
                        !this.broadcastRelays.includes(url) &&
                        url !== this.nosflareRelay &&
                        this.shouldRetryRelay(url))
                    .slice(0, 10);

                if (newRelaysToTry.length > 0) {
                    newRelaysToTry.forEach((relayUrl, index) => {
                        setTimeout(() => {
                            this.connectToRelayWithTimeout(relayUrl, 'read', this.relayTimeout)
                                .then(() => {
                                    this.subscribeToSingleRelay(relayUrl);
                                    this.updateConnectionStatus();
                                })
                                .catch(err => {
                                    this.trackRelayFailure(relayUrl);
                                });
                        }, index * 200);
                    });
                }
            });
        }
    }

    syncMissingMessages() {
        // For current channel, check if stored messages are displayed
        const currentKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
        const storedMessages = this.messages.get(currentKey) || [];

        storedMessages.forEach(message => {
            // Check if message is already in DOM
            if (!document.querySelector(`[data-message-id="${message.id}"]`)) {
                // Message is stored but not displayed, display it now
                this.displayMessage(message);
            }
        });

        // For PMs if in PM mode
        if (this.inPMMode && this.currentPM) {
            const conversationKey = this.getPMConversationKey(this.currentPM);
            const pmMessages = this.pmMessages.get(conversationKey) || [];

            pmMessages.forEach(message => {
                if (!document.querySelector(`[data-message-id="${message.id}"]`)) {
                    this.displayMessage(message);
                }
            });
        }
    }

    // Generate QR code for invoice
    generateQRCode(text, elementId) {
        const element = document.getElementById(elementId);
        if (!element) return;

        // Create QR code using canvas
        const qr = new QRCode(element, {
            text: text,
            width: 256,
            height: 256,
            colorDark: "#000000",
            colorLight: "#ffffff",
            correctLevel: QRCode.CorrectLevel.L
        });
    }

    // Fetch invoice from LNURL
    async fetchLightningInvoice(lnAddress, amountSats, comment) {
        try {
            const [username, domain] = lnAddress.split('@');
            if (!username || !domain) {
                throw new Error('Invalid lightning address format');
            }

            // Fetch LNURL endpoint
            const lnurlResponse = await fetch(`https://${domain}/.well-known/lnurlp/${username}`);
            if (!lnurlResponse.ok) {
                throw new Error('Failed to fetch LNURL endpoint');
            }

            const lnurlData = await lnurlResponse.json();

            // Convert sats to millisats
            const amountMillisats = parseInt(amountSats) * 1000;

            // Check bounds
            if (amountMillisats < lnurlData.minSendable || amountMillisats > lnurlData.maxSendable) {
                throw new Error(`Amount must be between ${lnurlData.minSendable / 1000} and ${lnurlData.maxSendable / 1000} sats`);
            }

            // Build callback URL
            const callbackUrl = new URL(lnurlData.callback);
            callbackUrl.searchParams.set('amount', amountMillisats);

            // Add comment if allowed
            if (comment && lnurlData.commentAllowed) {
                callbackUrl.searchParams.set('comment', comment.substring(0, lnurlData.commentAllowed));
            }

            // Add nostr params for zap
            if (lnurlData.allowsNostr && lnurlData.nostrPubkey) {
                // Create zap request event
                const zapRequest = await this.createZapRequest(amountSats, comment);
                if (zapRequest) {
                    callbackUrl.searchParams.set('nostr', JSON.stringify(zapRequest));
                }
            }

            // Fetch invoice
            const invoiceResponse = await fetch(callbackUrl.toString());
            if (!invoiceResponse.ok) {
                throw new Error('Failed to fetch invoice');
            }

            const invoiceData = await invoiceResponse.json();

            if (invoiceData.pr) {
                return {
                    pr: invoiceData.pr,
                    successAction: invoiceData.successAction,
                    verify: invoiceData.verify,
                    amount: amountSats
                };
            } else {
                throw new Error('No payment request in response');
            }
        } catch (error) {
            throw error;
        }
    }

    // Resolve any pending waiters for a user's lightning address
    notifyLightningAddress(pubkey, address) {
        const waiters = this.pendingLightningWaiters.get(pubkey);
        if (!waiters) return;
        for (const resolve of Array.from(waiters)) {
            try { resolve(address); } catch (_) { }
        }
        this.pendingLightningWaiters.delete(pubkey);
    }

    // Wait for a user's lightning address to be discovered
    waitForLightningAddress(pubkey, timeoutMs = 8000) {
        // If already cached, resolve immediately
        if (this.userLightningAddresses.has(pubkey)) {
            return Promise.resolve(this.userLightningAddresses.get(pubkey));
        }

        return new Promise((resolve) => {
            const resolver = (addr) => resolve(addr || null);

            // Register waiter
            if (!this.pendingLightningWaiters.has(pubkey)) {
                this.pendingLightningWaiters.set(pubkey, new Set());
            }
            const set = this.pendingLightningWaiters.get(pubkey);
            set.add(resolver);

            // Timeout fallback
            const timer = setTimeout(() => {
                // Clean up this resolver to prevent leaks
                const s = this.pendingLightningWaiters.get(pubkey);
                if (s) {
                    s.delete(resolver);
                    if (s.size === 0) this.pendingLightningWaiters.delete(pubkey);
                }
                resolve(null);
            }, timeoutMs);

            // Wrap resolver to clear timeout when it fires
            const wrapped = (addr) => {
                clearTimeout(timer);
                resolve(addr || null);
            };

            // Replace the bare resolver with a wrapped one that clears the timeout
            set.delete(resolver);
            set.add(wrapped);
        });
    }

    async fetchLightningAddressForUser(pubkey) {
        // Serve from cache if available
        if (this.userLightningAddresses.has(pubkey)) {
            return this.userLightningAddresses.get(pubkey);
        }

        try { this.requestUserProfile(pubkey); } catch (_) { }

        // Fire a direct, one-shot profile request to all connected relays
        const subId = 'ln-addr-' + Math.random().toString(36).slice(2);
        const req = ["REQ", subId, { kinds: [0], authors: [pubkey], limit: 1 }];
        try { this.sendToRelay(req); } catch (_) { }

        // Wait for handleEvent(kind 0) to notice LUD16/LUD06 (or timeout)
        const addr = await this.waitForLightningAddress(pubkey, 8000);

        try { this.sendToRelay(["CLOSE", subId]); } catch (_) { }

        return addr;
    }

    async loadLightningAddress() {
        // Only load if we have a pubkey
        if (!this.pubkey) return;

        // First, try to load from pubkey-specific localStorage
        const saved = localStorage.getItem(`nym_lightning_address_${this.pubkey}`);
        if (saved) {
            this.lightningAddress = saved;
            this.updateLightningAddressDisplay();
            return;
        }

        // If not in localStorage, try to fetch from Nostr profile
        const profileAddress = await this.fetchLightningAddressForUser(this.pubkey);
        if (profileAddress) {
            this.lightningAddress = profileAddress;
            // Cache it in localStorage for this pubkey
            localStorage.setItem(`nym_lightning_address_${this.pubkey}`, profileAddress);
            this.updateLightningAddressDisplay();
        }
    }

    async saveLightningAddress(address) {
        if (address) {
            this.lightningAddress = address;
            // Save with pubkey-specific key
            localStorage.setItem(`nym_lightning_address_${this.pubkey}`, address);

            // Always save to Nostr profile (merging with existing data)
            await this.saveToNostrProfile();
        } else {
            this.lightningAddress = null;
            localStorage.removeItem(`nym_lightning_address_${this.pubkey}`);
            // Only remove from local storage
        }

        this.updateLightningAddressDisplay();
    }

    updateLightningAddressDisplay() {
        const display = document.getElementById('lightningAddressDisplay');
        const value = document.getElementById('lightningAddressValue');

        if (this.lightningAddress && display && value) {
            display.style.display = 'flex';
            value.textContent = this.lightningAddress;
        } else if (display) {
            display.style.display = 'none';
        }
    }

    async saveToNostrProfile() {
        if (!this.pubkey) return;

        try {
            let profileToSave;

            // For persistent connections, preserve existing profile data
            if (this.connectionMode !== 'ephemeral') {
                // Fetch current profile if we don't have it
                if (!this.originalProfile) {
                    await this.fetchProfileFromRelay(this.pubkey);
                }

                // Start with existing profile or empty object
                profileToSave = { ...(this.originalProfile || {}) };

                // Update only the specific fields we manage, don't delete others
                profileToSave.name = this.nym;
                profileToSave.display_name = this.nym;

                // Update lightning address if we have one
                if (this.lightningAddress) {
                    profileToSave.lud16 = this.lightningAddress;
                }
            } else {
                // Ephemeral mode - minimal profile
                profileToSave = {
                    name: this.nym,
                    display_name: this.nym,
                    lud16: this.lightningAddress,
                    about: `NYM user - ${this.nym}`
                };
            }

            const profileEvent = {
                kind: 0,
                created_at: Math.floor(Date.now() / 1000),
                tags: [],
                content: JSON.stringify(profileToSave),
                pubkey: this.pubkey
            };

            // Sign based on connection mode
            const signedEvent = await this.signEvent(profileEvent);

            if (signedEvent) {
                this.sendToRelay(["EVENT", signedEvent]);
            }
        } catch (error) {
        }
    }

    async fetchLightningAddressFromProfile(pubkey) {
        // Create a request for the user's profile
        const subscription = [
            "REQ",
            "profile-ln-" + Math.random().toString(36).substring(7),
            {
                kinds: [0],
                authors: [pubkey],
                limit: 1
            }
        ];

        // Send request
        this.sendToRelay(subscription);

        // Set timeout to close subscription
        setTimeout(() => {
            this.sendToRelay(["CLOSE", subscription[1]]);
        }, 3000);
    }

    // Show zap modal
    showZapModal(messageId, recipientPubkey, recipientNym) {
        // Check if recipient has lightning address
        const lnAddress = this.userLightningAddresses.get(recipientPubkey);

        if (!lnAddress) {
            this.displaySystemMessage(`${recipientNym} doesn't have a lightning address set`);
            return;
        }

        // Store target info
        this.currentZapTarget = {
            messageId,
            recipientPubkey,
            recipientNym,
            lnAddress
        };

        // Reset modal state
        document.getElementById('zapAmountSection').style.display = 'block';
        document.getElementById('zapInvoiceSection').style.display = 'none';
        document.getElementById('zapRecipientInfo').textContent = `Zapping @${recipientNym}`;
        document.getElementById('zapCustomAmount').value = '';
        document.getElementById('zapComment').value = '';
        document.getElementById('zapSendBtn').textContent = 'Generate Invoice';
        document.getElementById('zapSendBtn').onclick = () => this.generateZapInvoice();

        // Clear selected amounts
        document.querySelectorAll('.zap-amount-btn').forEach(btn => {
            btn.classList.remove('selected');
            btn.onclick = (e) => {
                document.querySelectorAll('.zap-amount-btn').forEach(b => b.classList.remove('selected'));
                e.target.closest('.zap-amount-btn').classList.add('selected');
                document.getElementById('zapCustomAmount').value = '';
            };
        });

        // Show modal
        document.getElementById('zapModal').classList.add('active');
    }

    showProfileZapModal(recipientPubkey, recipientNym, lnAddress) {
        // Store target info for profile zap (no messageId)
        this.currentZapTarget = {
            messageId: null, // No message ID for profile zaps
            recipientPubkey,
            recipientNym,
            lnAddress,
            isProfileZap: true
        };

        // Reset modal state
        document.getElementById('zapAmountSection').style.display = 'block';
        document.getElementById('zapInvoiceSection').style.display = 'none';
        document.getElementById('zapRecipientInfo').textContent = `Zapping @${recipientNym}'s profile`;
        document.getElementById('zapCustomAmount').value = '';
        document.getElementById('zapComment').value = '';
        document.getElementById('zapSendBtn').textContent = 'Generate Invoice';
        document.getElementById('zapSendBtn').onclick = () => this.generateZapInvoice();

        // Clear selected amounts
        document.querySelectorAll('.zap-amount-btn').forEach(btn => {
            btn.classList.remove('selected');
            btn.onclick = (e) => {
                document.querySelectorAll('.zap-amount-btn').forEach(b => b.classList.remove('selected'));
                e.target.closest('.zap-amount-btn').classList.add('selected');
                document.getElementById('zapCustomAmount').value = '';
            };
        });

        // Show modal
        document.getElementById('zapModal').classList.add('active');
    }

    cleanupOldLightningAddress() {
        // Remove old non-pubkey-specific entry if it exists
        const oldAddress = localStorage.getItem('nym_lightning_address');
        if (oldAddress) {
            localStorage.removeItem('nym_lightning_address');
        }
    }

    // Create zap request event (NIP-57)
    async createZapRequest(amountSats, comment) {
        try {
            if (!this.currentZapTarget) {
                return null;
            }

            const zapRequest = {
                kind: 9734,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ['p', this.currentZapTarget.recipientPubkey], // Recipient of zap
                    ['amount', (parseInt(amountSats) * 1000).toString()], // Amount in millisats
                    ['relays', ...this.broadcastRelays.slice(0, 5)] // Limit to 5 relays
                ],
                content: comment || '',
                pubkey: this.pubkey
            };

            // Add event tag only if this is a message zap (not profile zap)
            if (this.currentZapTarget.messageId) {
                zapRequest.tags.unshift(['e', this.currentZapTarget.messageId]); // Event being zapped

                let originalKind = '23333'; // Default
                if (this.inPMMode) {
                    originalKind = '1059'; // PMs via NIP-17
                } else if (this.currentCommunity) {
                    originalKind = '4550'; // Community post
                } else if (this.currentGeohash) {
                    originalKind = '20000';
                }
                zapRequest.tags.push(['k', originalKind]);
            }

            // Sign the request
            const signedEvent = await this.signEvent(zapRequest);

            return signedEvent;
        } catch (error) {
            return null;
        }
    }

    // Generate and display invoice
    async generateZapInvoice() {
        if (!this.currentZapTarget) return;

        // Get amount
        const selectedBtn = document.querySelector('.zap-amount-btn.selected');
        const customAmount = document.getElementById('zapCustomAmount').value;
        const amount = customAmount || (selectedBtn ? selectedBtn.dataset.amount : null);

        if (!amount || amount <= 0) {
            this.displaySystemMessage('Please select or enter an amount');
            return;
        }

        const comment = document.getElementById('zapComment').value || '';

        // Show loading state
        document.getElementById('zapAmountSection').style.display = 'none';
        document.getElementById('zapInvoiceSection').style.display = 'block';
        document.getElementById('zapStatus').className = 'zap-status checking';
        document.getElementById('zapStatus').innerHTML = '<span class="loader"></span> Generating invoice...';

        try {
            // Fetch the invoice
            const invoice = await this.fetchLightningInvoice(
                this.currentZapTarget.lnAddress,
                amount,
                comment
            );

            if (invoice) {
                this.currentZapInvoice = invoice;
                this.zapInvoiceData = {
                    ...invoice,
                    messageId: this.currentZapTarget.messageId,
                    recipientPubkey: this.currentZapTarget.recipientPubkey
                };

                // Display invoice
                this.displayZapInvoice(invoice);

                // Start checking for payment
                this.checkZapPayment(invoice);
            }
        } catch (error) {
            document.getElementById('zapStatus').className = 'zap-status';
            document.getElementById('zapStatus').innerHTML = `Failed: ${error.message}`;
        }
    }

    // Display the invoice with QR code
    displayZapInvoice(invoice) {
        document.getElementById('zapStatus').style.display = 'none';
        document.getElementById('zapInvoiceDisplay').style.display = 'block';

        // Display invoice text
        const invoiceEl = document.getElementById('zapInvoice');
        invoiceEl.textContent = invoice.pr;

        // Generate QR code
        const qrContainer = document.getElementById('zapQRCode');
        qrContainer.innerHTML = ''; // Clear existing QR

        // Set container to center content
        qrContainer.style.cssText = 'text-align: center; display: flex; justify-content: center; align-items: center;';

        // Create QR code element with white border styling
        const qrDiv = document.createElement('div');
        qrDiv.id = 'zapQRCodeCanvas';
        qrDiv.style.cssText = 'display: inline-block; padding: 15px; background: white; border: 5px solid white; border-radius: 10px;';
        qrContainer.appendChild(qrDiv);

        // Generate QR using the invoice
        try {
            new QRCode(qrDiv, {
                text: invoice.pr,  // Just the raw invoice, no lightning: prefix
                width: 200,
                height: 200,
                colorDark: "#000000",
                colorLight: "#ffffff",
                correctLevel: QRCode.CorrectLevel.L
            });

        } catch (err) {
            // Fallback if QRCode library not loaded
            qrContainer.innerHTML = `
    <div style="display: inline-block; padding: 20px; border: 5px solid white; background: white; color: black; text-align: center; border-radius: 10px;">
        <div style="font-size: 14px; margin-bottom: 10px;">Lightning Invoice</div>
        <div style="font-size: 10px; word-break: break-all;">${invoice.pr.substring(0, 60)}...</div>
        <div style="margin-top: 10px; font-size: 12px; color: red;">QR generation failed - copy invoice manually</div>
    </div>
`;
        }

        // Update button
        document.getElementById('zapSendBtn').textContent = 'Close';
        document.getElementById('zapSendBtn').onclick = () => this.closeZapModal();
    }

    // Check if payment was made
    async checkZapPayment(invoice) {
        if (!invoice.verify) {
            // No verify URL, just wait for zap receipt event
            this.listenForZapReceipt();
            return;
        }

        let checkCount = 0;
        const maxChecks = 60; // Check for up to 60 seconds

        this.zapCheckInterval = setInterval(async () => {
            checkCount++;

            try {
                const response = await fetch(invoice.verify);
                const data = await response.json();

                if (data.settled || data.paid) {
                    // Payment confirmed!
                    clearInterval(this.zapCheckInterval);
                    this.handleZapPaymentSuccess(invoice.amount);
                } else if (checkCount >= maxChecks) {
                    // Timeout
                    clearInterval(this.zapCheckInterval);
                    document.getElementById('zapStatus').style.display = 'block';
                    document.getElementById('zapStatus').className = 'zap-status';
                    document.getElementById('zapStatus').innerHTML = 'Payment timeout - please check your wallet';
                }
            } catch (error) {
            }
        }, 1000); // Check every second
    }

    // Listen for zap receipt events
    listenForZapReceipt() {
        // Subscribe to zap receipt events (kind 9735) for this specific event
        const subscription = [
            "REQ",
            "zap-receipt-" + Math.random().toString(36).substring(7),
            {
                kinds: [9735],
                "#e": [this.currentZapTarget.messageId],
                since: Math.floor(Date.now() / 1000) - 300, // Last 5 minutes
                limit: 10
            }
        ];

        this.sendToRelay(subscription);

        // Also close the subscription after 60 seconds
        setTimeout(() => {
            this.sendToRelay(["CLOSE", subscription[1]]);
        }, 60000);
    }

    // Handle successful payment
    handleZapPaymentSuccess(amount) {
        if (!this.currentZapTarget) return;

        // Clear check interval
        if (this.zapCheckInterval) {
            clearInterval(this.zapCheckInterval);
            this.zapCheckInterval = null;
        }

        // Update UI
        document.getElementById('zapInvoiceDisplay').style.display = 'none';
        document.getElementById('zapStatus').style.display = 'block';
        document.getElementById('zapStatus').className = 'zap-status paid';
        document.getElementById('zapStatus').innerHTML = `
<div style="font-size: 24px; margin-bottom: 10px;">⚡</div>
<div>Zap sent successfully!</div>
<div style="font-size: 20px; margin-top: 10px;">${amount} sats</div>
`;

        // Close modal after 2 seconds
        setTimeout(() => {
            this.closeZapModal();
        }, 2000);
    }

    // Handle zap receipt events (NIP-57)
    handleZapReceipt(event) {
        if (event.kind !== 9735) return;

        // Parse zap receipt
        const eTag = event.tags.find(t => t[0] === 'e');
        const pTag = event.tags.find(t => t[0] === 'p');
        const boltTag = event.tags.find(t => t[0] === 'bolt11');
        const descriptionTag = event.tags.find(t => t[0] === 'description');

        if (!eTag || !boltTag) return;

        const messageId = eTag[1];
        const bolt11 = boltTag[1];

        // Parse amount from bolt11
        const amount = this.parseAmountFromBolt11(bolt11);

        if (amount) {
            // Get zapper pubkey from description if available
            let zapperPubkey = event.pubkey;

            if (descriptionTag) {
                try {
                    const zapRequest = JSON.parse(descriptionTag[1]);
                    if (zapRequest.pubkey) {
                        zapperPubkey = zapRequest.pubkey;
                    }

                    // Optional: Verify the k tag to ensure it's for supported kinds
                    const kTag = zapRequest.tags?.find(t => t[0] === 'k');
                    if (kTag && !['20000', '23333', '1059', '4550'].includes(kTag[1])) {
                        return;
                    }
                } catch (e) {
                    // Ignore parse errors
                }
            }

            // Initialize zaps tracking for this message if needed
            if (!this.zaps.has(messageId)) {
                this.zaps.set(messageId, {
                    receipts: new Set(), // Track receipt IDs to prevent duplicates
                    amounts: new Map()   // Map of pubkey -> total amount
                });
            }

            const messageZaps = this.zaps.get(messageId);

            // Check if we've already processed this receipt (deduplication)
            if (messageZaps.receipts.has(event.id)) {
                return; // Already processed this zap receipt
            }

            // Mark this receipt as processed
            messageZaps.receipts.add(event.id);

            // Update the amount for this zapper
            const currentAmount = messageZaps.amounts.get(zapperPubkey) || 0;
            messageZaps.amounts.set(zapperPubkey, currentAmount + amount);

            // Update display for this message
            this.updateMessageZaps(messageId);

            // Check if this is for our current pending zap
            if (this.currentZapTarget &&
                this.currentZapTarget.messageId === messageId &&
                zapperPubkey === this.pubkey) {
                this.handleZapPaymentSuccess(amount);
            }
        }
    }

    // Parse amount from bolt11 invoice (simplified)
    parseAmountFromBolt11(bolt11) {
        const match = bolt11.match(/lnbc(\d+)([munp])/i);
        if (match) {
            const amount = parseInt(match[1]);
            const multiplier = match[2];

            switch (multiplier) {
                case 'm': return amount * 100000; // millisats to sats
                case 'u': return amount * 100; // microsats to sats
                case 'n': return Math.round(amount / 10); // nanosats to sats
                case 'p': return Math.round(amount / 10000); // picosats to sats
                default: return amount;
            }
        }
        return null;
    }

    // Update message with zap display
    updateMessageZaps(messageId) {
        const messageEl = document.querySelector(`[data-message-id="${messageId}"]`);
        if (!messageEl) return;

        const messageZaps = this.zaps.get(messageId);

        // Find or create reactions row
        let reactionsRow = messageEl.querySelector('.reactions-row');
        if (!reactionsRow) {
            reactionsRow = document.createElement('div');
            reactionsRow.className = 'reactions-row';
            messageEl.appendChild(reactionsRow);
        }

        // Remove existing zap badges
        const existingZap = reactionsRow.querySelector('.zap-badge');
        if (existingZap) {
            existingZap.remove();
        }
        const existingZapBtn = reactionsRow.querySelector('.add-zap-btn');
        if (existingZapBtn) {
            existingZapBtn.remove();
        }

        // Only add badges if there are zaps
        if (messageZaps && messageZaps.amounts.size > 0) {
            // Calculate total zaps from the amounts map
            let totalZaps = 0;
            messageZaps.amounts.forEach(amount => {
                totalZaps += amount;
            });

            const zapBadge = document.createElement('span');
            zapBadge.className = 'zap-badge';
            zapBadge.innerHTML = `
    <svg class="zap-icon" viewBox="0 0 24 24">
        <path d="M13 2L3 14h8l-1 8 10-12h-8l1-8z"/>
    </svg>
    ${totalZaps}
`;

            const zapperCount = messageZaps.amounts.size;
            zapBadge.title = `${zapperCount} zapper${zapperCount > 1 ? 's' : ''} • ${totalZaps} sats total`;

            // Insert at beginning of reactions row
            reactionsRow.insertBefore(zapBadge, reactionsRow.firstChild);

            // Add quick zap button ONLY if zaps exist and not own message
            const pubkey = messageEl.dataset.pubkey;
            if (pubkey && pubkey !== this.pubkey) {
                const addZapBtn = document.createElement('span');
                addZapBtn.className = 'add-zap-btn';
                addZapBtn.innerHTML = `
        <svg viewBox="0 0 24 24">
            <path d="M11 2L1 14h8l-1 8 10-12h-8l1-8z" stroke="var(--text)" fill="var(--text)"/>
            <circle cx="19" cy="6" r="5" fill="var(--text)" stroke="none"></circle>
            <line x1="19" y1="4" x2="19" y2="8" stroke="var(--bg)" stroke-width="1.5" stroke-linecap="round"></line>
            <line x1="17" y1="6" x2="21" y2="6" stroke="var(--bg)" stroke-width="1.5" stroke-linecap="round"></line>
        </svg>
    `;
                addZapBtn.title = 'Quick zap';
                addZapBtn.onclick = async (e) => {
                    e.stopPropagation();
                    await this.handleQuickZap(messageId, pubkey, messageEl);
                };

                // Insert after zap badge
                reactionsRow.insertBefore(addZapBtn, zapBadge.nextSibling);
            }
        }
    }

    async handleQuickZap(messageId, pubkey, messageEl) {
        // Get the author's nym
        const author = messageEl.dataset.author;

        // Show loading message
        this.displaySystemMessage(`Checking if @${author} can receive zaps...`);

        try {
            // Always fetch fresh to ensure we have the latest
            const lnAddress = await this.fetchLightningAddressForUser(pubkey);

            if (lnAddress) {
                // User has lightning address, show zap modal
                this.showZapModal(messageId, pubkey, author);
            } else {
                // No lightning address found
                this.displaySystemMessage(`@${author} cannot receive zaps (no lightning address set)`);
            }
        } catch (error) {
            this.displaySystemMessage(`Failed to check if @${author} can receive zaps`);
        }
    }

    // Close zap modal
    closeZapModal() {
        const modal = document.getElementById('zapModal');
        modal.classList.remove('active');

        // Clear any payment check intervals
        if (this.zapCheckInterval) {
            clearInterval(this.zapCheckInterval);
            this.zapCheckInterval = null;
        }
        if (this.shopPaymentCheckInterval) {
            clearInterval(this.shopPaymentCheckInterval);
            this.shopPaymentCheckInterval = null;
        }

        // Close any shop zap subscriptions
        if (this.shopZapReceiptSubId) {
            this.sendToRelay(["CLOSE", this.shopZapReceiptSubId]);
            this.shopZapReceiptSubId = null;
        }

        // Reset modal state for regular zaps
        const zapAmountsContainer = document.querySelector('.zap-amounts');
        if (zapAmountsContainer) {
            zapAmountsContainer.style.display = 'grid';
        }

        const customAmountInput = document.getElementById('zapCustomAmount');
        customAmountInput.value = '';
        customAmountInput.readOnly = false;
        customAmountInput.style.background = '';
        customAmountInput.style.cursor = '';

        const commentSection = document.querySelector('.zap-comment');
        if (commentSection) {
            commentSection.style.display = 'block';
        }

        const amountSection = document.getElementById('zapAmountSection');
        const invoiceSection = document.getElementById('zapInvoiceSection');
        const sendBtn = document.getElementById('zapSendBtn');

        amountSection.style.display = 'block';
        invoiceSection.style.display = 'none';
        sendBtn.style.display = 'block';
        sendBtn.textContent = 'Generate Invoice';

        // Reset button onclick to default
        sendBtn.onclick = () => this.generateZapInvoice();

        // Clear contexts
        this.currentZapTarget = null;
        this.currentZapInvoice = null;
        this.currentPurchaseContext = null;
        this.currentShopInvoice = null;

        // Clear selected amounts
        document.querySelectorAll('.zap-amount-btn').forEach(btn => {
            btn.classList.remove('selected');
        });
    }

    // Copy invoice to clipboard
    copyZapInvoice() {
        if (!this.currentZapInvoice) return;

        navigator.clipboard.writeText(this.currentZapInvoice.pr).then(() => {
            // Show feedback
            const btn = event.target;
            const originalText = btn.textContent;
            btn.textContent = 'Copied!';
            setTimeout(() => {
                btn.textContent = originalText;
            }, 2000);
        }).catch(err => {
            this.displaySystemMessage('Failed to copy invoice');
        });
    }

    // Open invoice in wallet
    openInWallet() {
        // heck both currentZapInvoice and currentShopInvoice
        const invoice = this.currentZapInvoice || this.currentShopInvoice;
        if (!invoice) return;

        // Try multiple methods to open wallet
        const invoiceStr = invoice.pr;

        // Check if invoice already has lightning: prefix
        const invoiceToOpen = invoiceStr.toLowerCase().startsWith('lightning:') ?
            invoiceStr : `lightning:${invoiceStr}`;

        // Try Flutter bridge first (for NYM native app)
        if (window.nymOpenExternal) {
            window.nymOpenExternal(invoiceToOpen);
        } else {
            // Fallback to standard window.open (for regular browsers)
            window.open(invoiceToOpen, '_blank');
        }

        // Also copy to clipboard as fallback (just the raw invoice)
        navigator.clipboard.writeText(invoiceStr).then(() => {
            this.displaySystemMessage('Invoice copied - paste in your wallet');
        }).catch(err => {
            this.displaySystemMessage('Failed to copy invoice');
        });
    }

    // Discovering relays via NIP-66
    async discoverRelays() {
        try {
            // Check if we need to refresh the relay list
            const now = Date.now();
            if (now - this.lastRelayDiscovery < this.relayDiscoveryInterval && this.discoveredRelays.size > 0) {
                return;
            }

            // Try to load from cache first
            this.loadCachedRelays();

            // Connect to monitor relays to get relay list
            for (const monitorRelay of this.monitorRelays) {
                try {
                    await this.fetchRelaysFromMonitor(monitorRelay);
                } catch (error) {
                }
            }

            // Save discovered relays to cache
            this.saveCachedRelays();

            this.lastRelayDiscovery = now;

        } catch (error) {
            // Fall back to broadcast relays if discovery fails
            if (this.discoveredRelays.size === 0) {
                this.broadcastRelays.forEach(relay => this.discoveredRelays.add(relay));
            }
        }
    }

    async fetchRelaysFromMonitor(monitorUrl) {
        return new Promise((resolve, reject) => {
            const ws = new WebSocket(monitorUrl);
            const timeout = setTimeout(() => {
                ws.close();
                reject(new Error('Timeout fetching relay list'));
            }, 10000);

            ws.onopen = () => {
                // Request relay metadata events (NIP-66 kind 30066)
                const subscription = [
                    "REQ",
                    "relay-list-" + Math.random().toString(36).substring(7),
                    {
                        kinds: [30066], // NIP-66 relay metadata
                        limit: 500
                    }
                ];
                ws.send(JSON.stringify(subscription));
            };

            ws.onmessage = (event) => {
                try {
                    const msg = JSON.parse(event.data);
                    if (Array.isArray(msg) && msg[0] === 'EVENT') {
                        const relayEvent = msg[2];
                        if (relayEvent && relayEvent.kind === 30066) {
                            this.parseRelayMetadata(relayEvent);
                        }
                    } else if (Array.isArray(msg) && msg[0] === 'EOSE') {
                        clearTimeout(timeout);
                        ws.close();
                        resolve();
                    }
                } catch (e) {
                }
            };

            ws.onerror = (error) => {
                clearTimeout(timeout);
                reject(error);
            };
        });
    }

    parseRelayMetadata(event) {
        try {
            // Extract relay URL from d tag
            const dTag = event.tags.find(t => t[0] === 'd');
            if (!dTag || !dTag[1]) return;

            const relayUrl = dTag[1];

            // Check if relay supports required NIPs
            const nTags = event.tags.filter(t => t[0] === 'n');
            const supportsRequired = nTags.some(t => t[1] === '1') || nTags.length === 0; // Basic protocol support

            if (supportsRequired && relayUrl.startsWith('wss://')) {
                this.discoveredRelays.add(relayUrl);
            }
        } catch (error) {
        }
    }

    loadCachedRelays() {
        try {
            const cached = localStorage.getItem('nym_discovered_relays');
            if (cached) {
                const data = JSON.parse(cached);
                if (data.timestamp && Date.now() - data.timestamp < this.relayDiscoveryInterval) {
                    data.relays.forEach(relay => this.discoveredRelays.add(relay));
                }
            }
        } catch (error) {
        }
    }

    saveCachedRelays() {
        try {
            const data = {
                timestamp: Date.now(),
                relays: Array.from(this.discoveredRelays)
            };
            localStorage.setItem('nym_discovered_relays', JSON.stringify(data));
        } catch (error) {
        }
    }

    async loadSyncedSettings() {
        if (!this.pubkey || this.connectionMode === 'ephemeral') return;

        // Request NIP-78 settings (kind 30078)
        const settingsSubscription = [
            "REQ",
            "settings-" + Math.random().toString(36).substring(7),
            {
                kinds: [30078],
                authors: [this.pubkey],
                "#d": ["nym-settings"],
                limit: 1
            }
        ];

        this.sendToRelay(settingsSubscription);

        // Request standard mute list (kind 10000)
        const muteSubscription = [
            "REQ",
            "mutes-" + Math.random().toString(36).substring(7),
            {
                kinds: [10000],
                authors: [this.pubkey],
                limit: 1
            }
        ];

        this.sendToRelay(muteSubscription);

        // Close subscriptions after timeout
        setTimeout(() => {
            this.sendToRelay(["CLOSE", settingsSubscription[1]]);
            this.sendToRelay(["CLOSE", muteSubscription[1]]);
        }, 3000);
    }

    async saveSyncedSettings() {
        if (!this.pubkey) return;

        try {
            // For ephemeral users, only sync lightning address
            if (this.connectionMode === 'ephemeral') {
                if (!this.lightningAddress) {
                    return;
                }

                const settingsData = {
                    lightningAddress: this.lightningAddress
                };

                const settingsEvent = {
                    kind: 30078,
                    created_at: Math.floor(Date.now() / 1000),
                    tags: [
                        ["d", "nym-settings"],
                        ["title", "NYM Settings"],
                        ["encrypted"]
                    ],
                    content: JSON.stringify(settingsData),
                    pubkey: this.pubkey
                };

                if (this.privkey) {
                    const signedSettingsEvent = window.NostrTools.finalizeEvent(settingsEvent, this.privkey);
                    this.sendToRelay(["EVENT", signedSettingsEvent]);
                }
                return; // Don't sync anything else for ephemeral users
            }

            // Save NYM-specific settings (kind 30078)
            const settingsData = {
                theme: this.settings.theme,
                sound: this.settings.sound,
                autoscroll: this.settings.autoscroll,
                showTimestamps: this.settings.showTimestamps,
                timeFormat: this.settings.timeFormat,
                sortByProximity: this.settings.sortByProximity,
                blurOthersImages: this.blurOthersImages,
                pinnedChannels: Array.from(this.pinnedChannels),
                blockedChannels: Array.from(this.blockedChannels),
                userJoinedChannels: Array.from(this.userJoinedChannels),
                lightningAddress: this.lightningAddress,
                dmForwardSecrecyEnabled: !!this.settings.dmForwardSecrecyEnabled,
                dmTTLSeconds: this.settings.dmTTLSeconds || 86400,
                readReceiptsEnabled: this.settings.readReceiptsEnabled !== false,  // Default true
                pinnedLandingChannel: this.pinnedLandingChannel || { type: 'ephemeral', channel: 'bar' }
            };

            const settingsEvent = {
                kind: 30078,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ["d", "nym-settings"],
                    ["title", "NYM Settings"],
                    ["encrypted"]
                ],
                content: JSON.stringify(settingsData),
                pubkey: this.pubkey
            };

            // Sign and send settings event
            let signedSettingsEvent;
            if (this.connectionMode === 'extension' && window.nostr) {
                signedSettingsEvent = await window.nostr.signEvent(settingsEvent);
            } else if (this.connectionMode === 'nsec' && this.privkey) {
                signedSettingsEvent = window.NostrTools.finalizeEvent(settingsEvent, this.privkey);
            }

            if (signedSettingsEvent) {
                this.sendToRelay(["EVENT", signedSettingsEvent]);
            }

            // Save mute list (kind 10000)
            const muteTags = [];

            // Add blocked users as 'p' tags
            for (const pubkey of this.blockedUsers) {
                muteTags.push(["p", pubkey]);
            }

            // Add blocked keywords/phrases as 'word' tags
            for (const keyword of this.blockedKeywords) {
                muteTags.push(["word", keyword]);
            }

            const muteEvent = {
                kind: 10000,
                created_at: Math.floor(Date.now() / 1000),
                tags: muteTags,
                content: "",
                pubkey: this.pubkey
            };

            // Sign and send mute event
            let signedMuteEvent;
            if (this.connectionMode === 'extension' && window.nostr) {
                signedMuteEvent = await window.nostr.signEvent(muteEvent);
            } else if (this.connectionMode === 'nsec' && this.privkey) {
                signedMuteEvent = window.NostrTools.finalizeEvent(muteEvent, this.privkey);
            }

            if (signedMuteEvent) {
                this.sendToRelay(["EVENT", signedMuteEvent]);
            }

        } catch (error) {
        }
    }

    discoverChannels() {
        // Create a mixed array of all channels
        const allChannels = [];

        // Add all standard channels
        this.commonChannels.forEach(channel => {
            // Don't re-add if already exists or if user-joined
            if (!this.channels.has(channel) && !this.userJoinedChannels.has(channel)) {
                allChannels.push({
                    name: channel,
                    geohash: '',
                    type: 'standard',
                    sortKey: Math.random()
                });
            }
        });

        // Add all geohash channels
        this.commonGeohashes.forEach(geohash => {
            // Don't re-add if already exists or if user-joined
            if (!this.channels.has(geohash) && !this.userJoinedChannels.has(geohash)) {
                allChannels.push({
                    name: geohash,
                    geohash: geohash,
                    type: 'geo',
                    sortKey: Math.random()
                });
            }
        });

        // Sort randomly to mix standard and geo channels
        allChannels.sort((a, b) => a.sortKey - b.sortKey);

        // Add channels to UI in mixed order
        allChannels.forEach(channel => {
            this.addChannel(channel.name, channel.geohash);
        });
    }

    sendToRelay(message) {
        const msg = JSON.stringify(message);

        if (Array.isArray(message) && message[0] === 'EVENT') {
            // For EVENT messages, send to broadcast relays and nosflare
            this.broadcastEvent(message);
        } else if (Array.isArray(message) && message[0] === 'REQ') {
            // For REQ messages, send to all relays EXCEPT sendit.nosflare.com
            this.sendRequestToAllRelaysExceptNosflare(message);
        } else {
            // For other messages (CLOSE, etc.), send to all relays
            this.relayPool.forEach((relay, url) => {
                if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                    relay.ws.send(msg);
                }
            });
        }
    }

    sendRequestToAllRelaysExceptNosflare(message) {
        const msg = JSON.stringify(message);

        // Send REQ to all connected relays EXCEPT sendit.nosflare.com
        this.relayPool.forEach((relay, url) => {
            if (relay.ws && relay.ws.readyState === WebSocket.OPEN && !['wss://sendit.nosflare.com', 'wss://relay.nosflare.com'].includes(url)) {
                relay.ws.send(msg);
            }
        });
    }

    broadcastEvent(message) {
        const msg = JSON.stringify(message);

        let evt = null;
        try {
            if (Array.isArray(message) && message[0] === 'EVENT' && message[1] && typeof message[1] === 'object') {
                evt = message[1];
            }
        } catch (_) { }

        const wideFanout = evt && (evt.kind === 7 || evt.kind === 20000 || evt.kind === 23333 || evt.kind === 4550 || evt.kind === 1984 || evt.kind === 34550 || evt.kind === 9734 || evt.kind === 9735 || evt.kind === 1059 || evt.kind === 25051);

        if (wideFanout) {
            // Send to every connected relay for maximum propagation
            this.relayPool.forEach((relay, url) => {
                if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                    relay.ws.send(msg);
                }
            });
        } else {
            // Broadcast relays + nosflare
            this.broadcastRelays.forEach(relayUrl => {
                const relay = this.relayPool.get(relayUrl);
                if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                    relay.ws.send(msg);
                }
            });

            // Also send to nosflare if connected, to ensure a widely reachable write endpoint
            const nosflare = this.relayPool.get('wss://sendit.nosflare.com');
            if (nosflare && nosflare.ws && nosflare.ws.readyState === WebSocket.OPEN) {
                nosflare.ws.send(msg);
            }
        }
    }

    sendRequestToAllRelays(message) {
        const msg = JSON.stringify(message);

        // Send REQ to all connected relays EXCEPT nosflare
        this.relayPool.forEach((relay, url) => {
            if (relay.ws && relay.ws.readyState === WebSocket.OPEN && relay.type !== 'nosflare') {
                relay.ws.send(msg);
            }
        });
    }

    subscribeToAllRelays() {
        // Get all relays except nosflare
        const readableRelays = Array.from(this.relayPool.entries())
            .filter(([url, relay]) => relay.type !== 'nosflare' && relay.ws && relay.ws.readyState === WebSocket.OPEN);

        if (readableRelays.length === 0) {
            return;
        }

        // Send subscriptions to each readable relay
        readableRelays.forEach(([url, relay]) => {
            this.subscribeToSingleRelay(url);
        });

        // Also do channel discovery
        this.discoverChannels();
    }

    handleRelayMessage(msg, relayUrl) {
        if (!Array.isArray(msg)) return;

        const [type, ...data] = msg;

        switch (type) {
            case 'EVENT':
                const [subscriptionId, event] = data;

                // Track what kinds this relay is sending us
                if (event && event.kind) {
                    if (!this.relayKinds.has(relayUrl)) {
                        this.relayKinds.set(relayUrl, new Set());
                    }
                    const relayKindTracker = this.relayKinds.get(relayUrl);

                    // For reactions (kind 7), only count them if they have the right k tags
                    if (event.kind === 7) {
                        const kTag = event.tags?.find(t => t[0] === 'k');
                        if (kTag && ['20000', '23333', '1059', '4550'].includes(kTag[1])) {
                            relayKindTracker.add(7);
                        }
                    } else {
                        // For other kinds, add them directly
                        relayKindTracker.add(event.kind);
                    }
                }

                // Handle profile events (kind 0) for lightning addresses
                if (event && event.kind === 0) {
                    try {
                        const profile = JSON.parse(event.content);
                        const pubkey = event.pubkey;

                        if (profile.lud16 || profile.lud06) {
                            const lnAddress = profile.lud16 || profile.lud06;
                            this.userLightningAddresses.set(pubkey, lnAddress);
                        }

                        if (profile.name || profile.username || profile.display_name) {
                            const profileName = (profile.name || profile.username || profile.display_name).substring(0, 20);
                            if (!this.users.has(pubkey) || this.users.get(pubkey).nym.startsWith('anon-')) {
                                const existingUser = this.users.get(pubkey);
                                this.users.set(pubkey, {
                                    nym: profileName,
                                    pubkey,
                                    lastSeen: existingUser?.lastSeen || 0,
                                    status: existingUser?.status || 'online',
                                    channels: existingUser?.channels || new Set()
                                });
                            } else {
                                // Update existing user name without discarding channels/status
                                const u = this.users.get(pubkey);
                                u.nym = profileName;
                                // Don't update lastSeen - only channel messages should update presence
                                this.users.set(pubkey, u);
                            }

                            // Refresh PM sidebar entry and any open PM header
                            this.updatePMNicknameFromProfile(pubkey, profileName);
                        }
                    } catch (e) { }
                }
                // Deduplicate events by ID
                if (event && event.id) {
                    if (this.eventDeduplication.has(event.id)) {
                        // We've already processed this event
                        return;
                    }

                    // Mark event as seen
                    this.eventDeduplication.set(event.id, true);

                    // Clean up old events periodically (keep last 10000)
                    if (this.eventDeduplication.size > 10000) {
                        const entriesToDelete = this.eventDeduplication.size - 10000;
                        let deleted = 0;
                        for (const key of this.eventDeduplication.keys()) {
                            if (deleted >= entriesToDelete) break;
                            this.eventDeduplication.delete(key);
                            deleted++;
                        }
                    }
                }

                this.handleEvent(event);
                break;
            case 'OK':
                // Event was accepted
                break;
            case 'EOSE':
                // End of stored events
                break;
            case 'NOTICE':
                const notice = data[0];
                break;
        }
    }

    cleanupNonResponsiveRelays() {
        const now = Date.now();

        this.relayPool.forEach((relay, url) => {
            if (relay.type === 'read') {
                const kinds = this.relayKinds.get(url);

                // Check if relay has sent any of our required kinds
                if (kinds && kinds.size > 0) {
                    const hasRequiredKinds =
                        kinds.has(20000) || // geohash channels
                        kinds.has(23333) || // standard channels  
                        kinds.has(7) ||     // reactions (already filtered for our k tags)
                        kinds.has(1059);    // PMs

                    if (!hasRequiredKinds) {
                        relay.ws.close();
                        this.relayPool.delete(url);
                        this.relayKinds.delete(url);
                        this.blacklistedRelays.add(url);
                        this.updateConnectionStatus();
                    }
                } else if (now - relay.connectedAt > this.relayVerificationTimeout) {
                    // No kinds received within timeout
                    relay.ws.close();
                    this.relayPool.delete(url);
                    this.relayKinds.delete(url);
                    this.blacklistedRelays.add(url);
                    this.updateConnectionStatus();
                }
            }
        });
    }

    async handleEvent(event) {
        // Early deduplication for channel messages to prevent re-processing on reconnect
        if ([20000, 23333, 4550].includes(event.kind)) {
            if (this.processedMessageEventIds.has(event.id)) {
                return; // Already processed this message
            }
            this.processedMessageEventIds.add(event.id);

            // Prune if too large (keep last 5000 event IDs)
            if (this.processedMessageEventIds.size > 5000) {
                const idsArray = Array.from(this.processedMessageEventIds);
                this.processedMessageEventIds = new Set(idsArray.slice(-4000));
            }
        }

        const messageAge = Date.now() - (event.created_at * 1000);
        const isHistorical = messageAge > 10000; // Older than 10 seconds

        if (event.pubkey === this.pubkey) {
            // For messages (kind 20000, 23333, 4550)
            if ([20000, 23333, 4550].includes(event.kind)) {
                // Check if message already displayed in DOM
                if (document.querySelector(`[data-message-id="${event.id}"]`)) {
                    return; // Already displayed optimistically, skip
                }
            }

            // For reactions (kind 7)
            if (event.kind === 7) {
                const eTag = event.tags.find(t => t[0] === 'e');
                if (eTag) {
                    const messageId = eTag[1];
                    const emoji = event.content;

                    // Check if we already have this reaction in state
                    if (this.reactions.has(messageId)) {
                        const messageReactions = this.reactions.get(messageId);
                        if (messageReactions.has(emoji) &&
                            messageReactions.get(emoji).has(this.pubkey)) {
                            return; // Already added optimistically, skip
                        }
                    }
                }
            }
        }

        // Handle NIP-72 moderation events FIRST (before processing messages)
        if (event.kind === 5 && event.tags.some(t => t[0] === 'a' && t[1]?.includes('34550:'))) {
            // Community deletion event
            const aTag = event.tags.find(t => t[0] === 'a');
            if (aTag) {
                const [kind, adminPubkey, communityId] = aTag[1].split(':');

                // Verify the deletion is from the community admin
                const community = this.communityChannels.get(communityId);
                if (community && community.admin === event.pubkey && event.pubkey === adminPubkey) {
                    // Remove the community
                    this.communityChannels.delete(communityId);
                    this.ownedCommunities.delete(communityId);
                    this.moderatedCommunities.delete(communityId);

                    // Remove from UI
                    const item = document.querySelector(`[data-community="${communityId}"]`);
                    if (item) item.remove();

                    this.displaySystemMessage(`Community "${community.name}" has been deleted by admin`);

                    // If currently viewing this community, switch to bar
                    if (this.currentCommunity === communityId) {
                        this.switchChannel('bar', '');
                    }
                }
            }
            return;
        }

        // Handle NIP-72 moderation events FIRST (before processing messages)
        if (event.kind === 1984) { // NIP-56 reporting/moderation events
            const pTag = event.tags.find(t => t[0] === 'p');
            const aTag = event.tags.find(t => t[0] === 'a');
            const actionTag = event.tags.find(t => t[0] === 'action');

            if (pTag && aTag && actionTag) {
                const targetPubkey = pTag[1];
                const [kind, adminPubkey, communityId] = aTag[1].split(':');
                const action = actionTag[1];

                // Verify the moderation event is from admin or mod
                const community = this.communityChannels.get(communityId);
                if (!community) return;

                const isFromAdmin = event.pubkey === community.admin;
                const isFromMod = this.communityModerators.has(communityId) &&
                    this.communityModerators.get(communityId).has(event.pubkey);

                if (!isFromAdmin && !isFromMod) {
                    return;
                }

                // Mark this moderation event as processed
                if (this.processedModerationEvents.has(event.id)) {
                    return; // Already processed
                }
                this.processedModerationEvents.add(event.id);

                // Clean up old processed events (keep last 1000)
                if (this.processedModerationEvents.size > 1000) {
                    const toDelete = Array.from(this.processedModerationEvents).slice(0, -1000);
                    toDelete.forEach(id => this.processedModerationEvents.delete(id));
                }

                // Process the moderation action
                switch (action) {
                    case 'ban':
                        if (!this.communityBans.has(communityId)) {
                            this.communityBans.set(communityId, new Set());
                        }
                        this.communityBans.get(communityId).add(targetPubkey);

                        // Hide messages from banned user if viewing this community
                        if (this.currentCommunity === communityId) {
                            document.querySelectorAll('.message').forEach(msg => {
                                if (msg.dataset.pubkey === targetPubkey) {
                                    msg.remove();
                                }
                            });
                        }

                        // Clean up stored messages
                        this.cleanupBannedMessages(communityId, targetPubkey);

                        // Show notification ONLY if in this community AND not from current user
                        if (this.currentCommunity === communityId && event.pubkey !== this.pubkey) {
                            const targetNym = this.getNymFromPubkey(targetPubkey);
                            const modNym = this.getNymFromPubkey(event.pubkey);
                            this.displaySystemMessage(`${targetNym} was banned by ${modNym}`);
                        }
                        break;

                    case 'unban':
                        if (this.communityBans.has(communityId)) {
                            this.communityBans.get(communityId).delete(targetPubkey);
                        }

                        // Show notification ONLY if in this community AND not from current user
                        if (this.currentCommunity === communityId && event.pubkey !== this.pubkey) {
                            const targetNym = this.getNymFromPubkey(targetPubkey);
                            const modNym = this.getNymFromPubkey(event.pubkey);
                            this.displaySystemMessage(`${targetNym} was unbanned by ${modNym}`);
                        }
                        break;

                    case 'kick':
                        // Get expiry timestamp
                        const expiryTag = event.tags.find(t => t[0] === 'expiry');
                        if (expiryTag) {
                            const kickExpiry = parseInt(expiryTag[1]);

                            // Initialize temporary kicks map if needed
                            if (!this.communityTemporaryKicks) {
                                this.communityTemporaryKicks = new Map();
                            }
                            if (!this.communityTemporaryKicks.has(communityId)) {
                                this.communityTemporaryKicks.set(communityId, new Map());
                            }

                            // Add the kick
                            this.communityTemporaryKicks.get(communityId).set(targetPubkey, kickExpiry);

                            // If the kicked user is us and we're in this community, kick us out
                            if (targetPubkey === this.pubkey && this.currentCommunity === communityId) {
                                const communityName = community.name;
                                this.displaySystemMessage(`You have been kicked from ${communityName}. You can rejoin in 15 minutes.`);

                                // Switch to #bar after a short delay
                                setTimeout(() => {
                                    this.switchChannel('bar', '');
                                }, 1500);
                            }

                            // Set up auto-cleanup after expiry
                            const timeRemaining = kickExpiry - Date.now();
                            if (timeRemaining > 0) {
                                setTimeout(() => {
                                    if (this.communityTemporaryKicks.has(communityId)) {
                                        const kicks = this.communityTemporaryKicks.get(communityId);
                                        if (kicks.has(targetPubkey)) {
                                            kicks.delete(targetPubkey);
                                            if (targetPubkey === this.pubkey) {
                                                this.displaySystemMessage(`Your kick from ${community?.name || 'the community'} has expired. You can rejoin now.`);
                                            }
                                        }
                                    }
                                }, timeRemaining);
                            }
                        }
                        break;
                }
            }
            return;
        }

        if (event.kind === 20000) {
            // Validate PoW (NIP-13)
            if (this.enablePow && !this.validatePow(event, this.powDifficulty)) {
                return;
            }

            // Handle geohash channel messages
            const nymTag = event.tags.find(t => t[0] === 'n');
            const geohashTag = event.tags.find(t => t[0] === 'g');

            const nym = nymTag ? nymTag[1] : this.getNymFromPubkey(event.pubkey);
            const geohash = geohashTag ? geohashTag[1] : '';

            // Check if user is blocked or message contains blocked keywords
            if (this.isNymBlocked(nym) || this.hasBlockedKeyword(event.content)) {
                return;
            }

            if (this.isSpamMessage(event.content)) {
                return;
            }

            // Check flooding FOR THIS CHANNEL (only for non-historical messages)
            if (!isHistorical && this.isFlooding(event.pubkey, geohash)) {
                return;
            }

            // Only track flood for new messages in this channel
            if (!isHistorical) {
                this.trackMessage(event.pubkey, geohash, isHistorical);
            }

            // Track notification state for this channel
            const channelKey = geohash;
            if (!this.channelNotificationTracking) {
                this.channelNotificationTracking = new Map();
            }
            if (!this.channelNotificationTracking.has(channelKey)) {
                this.channelNotificationTracking.set(channelKey, new Set());
            }
            const alreadyNotified = this.channelNotificationTracking.get(channelKey).has(event.id);

            // Check for BRB auto-response (UNIVERSAL) - only for NEW messages
            if (!isHistorical && this.isMentioned(event.content) && this.awayMessages.has(this.pubkey)) {
                // Check if we haven't already responded to this user in this session
                const responseKey = `brb_universal_${this.pubkey}_${nym}`;
                if (!sessionStorage.getItem(responseKey)) {
                    sessionStorage.setItem(responseKey, '1');

                    // Send auto-response to the same channel where mentioned
                    const response = `@${nym} [Auto-Reply] ${this.awayMessages.get(this.pubkey)}`;
                    await this.publishMessage(response, geohash, geohash);
                }
            }

            // Add channel if it's new (and not blocked)
            if (geohash && !this.channels.has(geohash) && !this.isChannelBlocked(geohash, geohash)) {
                this.addChannelToList(geohash, geohash);
            }

            // Check if this is a P2P file offer
            const offerTag = event.tags.find(t => t[0] === 'offer');
            let fileOffer = null;
            if (offerTag) {
                try {
                    fileOffer = JSON.parse(offerTag[1]);
                    this.p2pFileOffers.set(fileOffer.offerId, fileOffer);
                } catch (e) {
                    console.error('Error parsing file offer:', e);
                }
            }

            const message = {
                id: event.id,
                author: nym,
                pubkey: event.pubkey,
                content: event.content,
                timestamp: new Date(event.created_at * 1000),
                channel: geohash ? geohash : 'unknown',
                geohash: geohash,
                isOwn: event.pubkey === this.pubkey,
                isHistorical: isHistorical,
                isFileOffer: !!fileOffer,
                fileOffer: fileOffer
            };

            // Don't display duplicate of own messages
            if (!this.isDuplicateMessage(message)) {
                this.displayMessage(message);
                this.updateUserPresence(nym, event.pubkey, message.channel, geohash);

                // Show notification if mentioned and not blocked
                const shouldNotify = !message.isOwn &&
                    this.isMentioned(message.content) &&
                    !this.isNymBlocked(nym) &&
                    !isHistorical &&
                    !alreadyNotified &&
                    (document.hidden || this.currentChannel !== geohash || this.currentGeohash !== geohash);

                if (shouldNotify) {
                    // Mark as notified
                    this.channelNotificationTracking.get(channelKey).add(event.id);

                    const channelInfo = {
                        type: 'geohash',
                        channel: geohash,
                        geohash: geohash,
                        id: event.id
                    };
                    this.showNotification(nym, message.content, channelInfo);
                }
            }
        } else if (event.kind === 23333) {
            // Validate PoW (NIP-13)
            if (this.enablePow && !this.validatePow(event, this.powDifficulty)) {
                return;
            }

            // Handle standard channel messages
            const nymTag = event.tags.find(t => t[0] === 'n');
            const channelTag = event.tags.find(t => t[0] === 'd');

            const nym = nymTag ? nymTag[1] : this.getNymFromPubkey(event.pubkey);
            const channel = channelTag ? channelTag[1] : 'bar';

            // Check if user is blocked or message contains blocked keywords
            if (this.isNymBlocked(nym) || this.hasBlockedKeyword(event.content)) {
                return;
            }

            if (this.isSpamMessage(event.content)) {
                return;
            }

            // Check flooding FOR THIS CHANNEL (only for non-historical messages)
            if (!isHistorical && this.isFlooding(event.pubkey, channel)) {
                return;
            }

            // Only track flood for new messages in this channel
            if (!isHistorical) {
                this.trackMessage(event.pubkey, channel, isHistorical);
            }

            // Track notification state for this channel
            const channelKey = channel;
            if (!this.channelNotificationTracking) {
                this.channelNotificationTracking = new Map();
            }
            if (!this.channelNotificationTracking.has(channelKey)) {
                this.channelNotificationTracking.set(channelKey, new Set());
            }
            const alreadyNotified = this.channelNotificationTracking.get(channelKey).has(event.id);

            // Check for BRB auto-response (UNIVERSAL) - only for NEW messages
            if (!isHistorical && this.isMentioned(event.content) && this.awayMessages.has(this.pubkey)) {
                // Check if we haven't already responded to this user in this session
                const responseKey = `brb_universal_${this.pubkey}_${nym}`;
                if (!sessionStorage.getItem(responseKey)) {
                    sessionStorage.setItem(responseKey, '1');

                    // Send auto-response to the same channel where mentioned
                    const response = `@${nym} [Auto-Reply] ${this.awayMessages.get(this.pubkey)}`;
                    await this.publishMessage(response, channel, '');
                }
            }

            // Add channel if it's new (and not blocked)
            if (!this.channels.has(channel) && !this.isChannelBlocked(channel, '')) {
                this.addChannelToList(channel, '');
            }

            // Check if this is a P2P file offer
            const offerTag23333 = event.tags.find(t => t[0] === 'offer');
            let fileOffer23333 = null;
            if (offerTag23333) {
                try {
                    fileOffer23333 = JSON.parse(offerTag23333[1]);
                    this.p2pFileOffers.set(fileOffer23333.offerId, fileOffer23333);
                } catch (e) {
                    console.error('Error parsing file offer:', e);
                }
            }

            const message = {
                id: event.id,
                author: nym,
                pubkey: event.pubkey,
                content: event.content,
                timestamp: new Date(event.created_at * 1000),
                channel: channel,
                geohash: '',
                isOwn: event.pubkey === this.pubkey,
                isHistorical: isHistorical,
                isFileOffer: !!fileOffer23333,
                fileOffer: fileOffer23333
            };

            // Don't display duplicate of own messages
            if (!this.isDuplicateMessage(message)) {
                this.displayMessage(message);
                this.updateUserPresence(nym, event.pubkey, channel, '');

                // Show notification if mentioned and not blocked
                const shouldNotify = !message.isOwn &&
                    this.isMentioned(message.content) &&
                    !this.isNymBlocked(nym) &&
                    !isHistorical &&
                    !alreadyNotified &&
                    (document.hidden || this.currentChannel !== channel || this.currentGeohash !== '');

                if (shouldNotify) {
                    // Mark as notified
                    this.channelNotificationTracking.get(channelKey).add(event.id);

                    const channelInfo = {
                        type: 'standard',
                        channel: channel,
                        geohash: '',
                        id: event.id
                    };
                    this.showNotification(nym, message.content, channelInfo);
                }
            }
        } else if (event.kind === 34550) {
            const dTag = event.tags.find(t => t[0] === 'd');

            if (dTag) {
                const nameTag = event.tags.find(t => t[0] === 'name');
                const descTag = event.tags.find(t => t[0] === 'description');
                const imageTag = event.tags.find(t => t[0] === 'image');
                const privacyTag = event.tags.find(t => t[0] === 'private' || t[0] === 'public');

                if (!nameTag) {
                    return;
                }

                const communityId = dTag[1];
                const name = nameTag[1];
                const description = descTag ? descTag[1] : '';
                const imageUrl = imageTag ? imageTag[1] : '';
                const isPrivate = privacyTag ? privacyTag[0] === 'private' : false;

                // Store or update community
                this.communityChannels.set(communityId, {
                    name: name,
                    description: description,
                    imageUrl: imageUrl,
                    isPrivate: isPrivate,
                    admin: event.pubkey,
                    createdAt: event.created_at * 1000
                });

                // Don't show communities to ephemeral users
                if (this.connectionMode === 'ephemeral') {
                    return; // Skip adding to UI for ephemeral users
                }

                // Filter out communities with spaces - don't add to UI
                if (name.includes(' ')) {
                    return; // Don't add to UI, just store in map
                }

                // Check if this is the official NYM community
                const isNYMCommunity = event.pubkey === this.verifiedDeveloper.pubkey &&
                    name.toLowerCase() === 'nym';

                // For private communities, only show if user is a member, mod, or admin
                if (isPrivate && !isNYMCommunity) {
                    const isAdmin = event.pubkey === this.pubkey;
                    const isMod = this.communityModerators.has(communityId) &&
                        this.communityModerators.get(communityId).has(this.pubkey);
                    const isMember = this.communityMembers.has(communityId) &&
                        this.communityMembers.get(communityId).has(this.pubkey);

                    if (!isAdmin && !isMod && !isMember) {
                        return; // Don't show private communities unless member
                    }
                }

                // Track if user owns this community
                if (event.pubkey === this.pubkey) {
                    this.ownedCommunities.add(communityId);
                }

                // Parse moderators
                const modTags = event.tags.filter(t => t[0] === 'p' && t[3] === 'moderator');
                if (modTags.length > 0) {
                    if (!this.communityModerators.has(communityId)) {
                        this.communityModerators.set(communityId, new Set());
                    }
                    // Clear existing mods and repopulate from latest definition
                    this.communityModerators.get(communityId).clear();
                    modTags.forEach(tag => {
                        const modPubkey = tag[1];
                        this.communityModerators.get(communityId).add(modPubkey);

                        if (modPubkey === this.pubkey) {
                            this.moderatedCommunities.add(communityId);

                            // Add to UI if we're a moderator
                            if (!document.querySelector(`[data-community="${communityId}"]`)) {
                                this.addCommunityChannel(name, communityId, isPrivate);
                                this.userJoinedChannels.add(communityId);
                                this.saveUserChannels();
                            }
                        }
                    });
                } else {
                    // No moderator tags - clear moderators for this community
                    if (this.communityModerators.has(communityId)) {
                        this.communityModerators.get(communityId).clear();
                    }
                }

                // Parse banned users from community definition
                const bannedTags = event.tags.filter(t => t[0] === 'p' && t[3] === 'banned');
                if (bannedTags.length > 0) {
                    if (!this.communityBans.has(communityId)) {
                        this.communityBans.set(communityId, new Set());
                    }
                    // Clear existing bans and repopulate from latest definition
                    this.communityBans.get(communityId).clear();
                    bannedTags.forEach(tag => {
                        const bannedPubkey = tag[1];
                        this.communityBans.get(communityId).add(bannedPubkey);
                    });

                    // If we're currently viewing this community, remove banned users' messages
                    if (this.currentCommunity === communityId) {
                        bannedTags.forEach(tag => {
                            const bannedPubkey = tag[1];
                            // Remove from DOM
                            document.querySelectorAll(`.message[data-pubkey="${bannedPubkey}"]`).forEach(msg => {
                                msg.remove();
                            });
                            // Clean up stored messages
                            this.cleanupBannedMessages(communityId, bannedPubkey);
                        });
                    }
                } else {
                    // No banned tags means no bans - clear any local bans for this community
                    if (this.communityBans.has(communityId)) {
                        this.communityBans.get(communityId).clear();
                    }
                }

                // Add to UI if not already present
                if (!document.querySelector(`[data-community="${communityId}"]`)) {

                    if (isNYMCommunity || event.pubkey === this.pubkey || !isPrivate) {
                        this.addCommunityChannel(name, communityId, isPrivate);

                        // Only mark as user-joined if owned or NYM community
                        if (isNYMCommunity || event.pubkey === this.pubkey) {
                            this.userJoinedChannels.add(communityId);
                        }

                        // AUTO-PIN THE NYM COMMUNITY
                        if (isNYMCommunity) {
                            this.pinnedChannels.add(communityId);
                            this.savePinnedChannels();
                        }

                        if (event.pubkey === this.pubkey) {
                            this.saveUserChannels();
                        }
                    }
                }
            }
        } else if (event.kind === 4550) {
            // Validate PoW (NIP-13)
            if (this.enablePow && !this.validatePow(event, this.powDifficulty)) {
                return;
            }

            // Handle COMMUNITY POSTS
            const aTag = event.tags.find(t => t[0] === 'a');

            if (aTag) {
                const nymTag = event.tags.find(t => t[0] === 'n');

                // Parse a tag: "34550:adminPubkey:communityId"
                const [kind, adminPubkey, communityId] = aTag[1].split(':');

                // CHECK IF USER IS BANNED BEFORE PROCESSING
                if (this.communityBans.has(communityId) &&
                    this.communityBans.get(communityId).has(event.pubkey)) {
                    return; // Don't process messages from banned users AT ALL
                }

                // ALSO CHECK IF USER IS GLOBALLY BLOCKED
                const nymForCheck = nymTag ? nymTag[1] : this.getNymFromPubkey(event.pubkey);
                if (this.blockedUsers.has(event.pubkey) || this.isNymBlocked(nymForCheck)) {
                    return;
                }

                const nym = nymTag ? nymTag[1] : this.getNymFromPubkey(event.pubkey);

                // Check if user is blocked globally
                if (this.isNymBlocked(nym) || this.hasBlockedKeyword(event.content)) {
                    return;
                }

                if (this.isSpamMessage(event.content)) {
                    return;
                }

                // Check if message is from this community
                if (!this.communityChannels.has(communityId)) {
                    // Store community info if we don't have it
                    this.communityChannels.set(communityId, {
                        name: communityId.split('-')[0],
                        admin: adminPubkey,
                        createdAt: Date.now()
                    });
                }

                const messageAge = Date.now() - (event.created_at * 1000);
                const isHistorical = messageAge > 10000;

                // Check if this is a P2P file offer
                const offerTag4550 = event.tags.find(t => t[0] === 'offer');
                let fileOffer4550 = null;
                if (offerTag4550) {
                    try {
                        fileOffer4550 = JSON.parse(offerTag4550[1]);
                        this.p2pFileOffers.set(fileOffer4550.offerId, fileOffer4550);
                    } catch (e) {
                        console.error('Error parsing file offer:', e);
                    }
                }

                // Check flooding
                if (!isHistorical && this.isFlooding(event.pubkey, communityId)) {
                    return;
                }

                if (!isHistorical) {
                    this.trackMessage(event.pubkey, communityId, isHistorical);
                }

                const message = {
                    id: event.id,
                    author: nym,
                    pubkey: event.pubkey,
                    content: event.content,
                    timestamp: new Date(event.created_at * 1000),
                    channel: communityId,
                    geohash: '',
                    isCommunity: true,
                    communityId: communityId,
                    isOwn: event.pubkey === this.pubkey,
                    isHistorical: isHistorical,
                    isFileOffer: !!fileOffer4550,
                    fileOffer: fileOffer4550
                };

                // Store message - Only store if not from banned user
                if (!this.messages.has(communityId)) {
                    this.messages.set(communityId, []);
                }

                const exists = this.messages.get(communityId).some(m => m.id === event.id);
                if (!exists) {
                    this.messages.get(communityId).push(message);
                    this.messages.get(communityId).sort((a, b) => a.timestamp - b.timestamp);
                }

                // Display if in this community - will be filtered by loadCommunityMessages
                if (this.currentCommunity === communityId) {
                    if (!exists) {
                        this.displayMessage(message);
                        this.updateUserPresence(nym, event.pubkey, communityId, '');

                        // Track notification state for this community
                        if (!this.channelNotificationTracking) {
                            this.channelNotificationTracking = new Map();
                        }
                        if (!this.channelNotificationTracking.has(communityId)) {
                            this.channelNotificationTracking.set(communityId, new Set());
                        }
                        const alreadyNotified = this.channelNotificationTracking.get(communityId).has(event.id);

                        // Show notification if mentioned and not blocked
                        const shouldNotify = !message.isOwn &&
                            this.isMentioned(message.content) &&
                            !this.isNymBlocked(nym) &&
                            !isHistorical &&
                            !alreadyNotified &&
                            (document.hidden || this.currentCommunity !== communityId);

                        if (shouldNotify) {
                            // Mark as notified
                            this.channelNotificationTracking.get(communityId).add(event.id);

                            const channelInfo = {
                                type: 'community',
                                communityId: communityId,
                                channel: communityId,
                                id: event.id
                            };
                            this.showNotification(nym, message.content, channelInfo);
                        }
                    }
                } else if (!exists) {
                    // Message is for different community
                    // Update unread count for other communities
                    if (!message.isOwn && !isHistorical) {
                        this.updateUnreadCount(communityId);
                    }
                    // Invalidate pre-render cache for this community since it has new messages
                    this.invalidatePrerender(communityId);
                }
            }
        } else if (event.kind === 30078) {
            const dTag = event.tags.find(t => t[0] === 'd');
            if (!dTag) return;

            // Active items broadcast for everyone
            if (dTag[1] === 'nym-shop-active') {
                try {
                    const items = JSON.parse(event.content || '{}');

                    // For our own events, handle specially
                    if (event.pubkey === this.pubkey) {
                        // Check timestamp to ensure we're using the latest
                        const currentTimestamp = this.shopItemsCache.get(event.pubkey)?.eventCreatedAt || 0;

                        if (event.created_at > currentTimestamp) {
                            // This is newer than what we have, update our state
                            this.activeMessageStyle = items.style || null;
                            this.activeFlair = items.flair || null;
                            this.activeCosmetics = new Set(Array.isArray(items.cosmetics) ? items.cosmetics : []);

                            // Cache locally
                            this.localActiveStyle = this.activeMessageStyle;
                            this.localActiveFlair = this.activeFlair;
                            localStorage.setItem('nym_active_style', this.activeMessageStyle || '');
                            localStorage.setItem('nym_active_flair', this.activeFlair || '');

                            // Update cache timestamp
                            this.cacheShopActiveItems(event.pubkey, {
                                style: this.activeMessageStyle,
                                flair: this.activeFlair,
                                supporter: this.userPurchases.has('supporter-badge'),
                                cosmetics: Array.from(this.activeCosmetics || [])
                            }, event.created_at);

                            // Apply to our messages
                            this.applyShopStylesToOwnMessages();

                        }
                        return;
                    }

                    // For other users
                    // Check if we have a cached version with a newer timestamp
                    const cachedData = this.shopItemsCache.get(event.pubkey);
                    if (cachedData && cachedData.eventCreatedAt >= event.created_at) {
                        // We already have newer or same data, skip update to prevent flicker
                        return;
                    }

                    // Normalize cosmetics to array
                    const normalized = {
                        style: items.style || null,
                        flair: items.flair || null,
                        supporter: !!items.supporter,
                        cosmetics: Array.isArray(items.cosmetics) ? items.cosmetics : []
                    };

                    // Update cache and store
                    this.otherUsersShopItems.set(event.pubkey, normalized);
                    this.cacheShopActiveItems(event.pubkey, normalized, event.created_at);

                    // Only update visible messages if this is actually newer data
                    if (!cachedData || cachedData.eventCreatedAt < event.created_at) {
                        const messages = document.querySelectorAll(`.message[data-pubkey="${event.pubkey}"]`);
                        messages.forEach(msg => {
                            // Remove previous styling classes
                            [...msg.classList].forEach(cls => {
                                if (cls.startsWith('style-') || cls.startsWith('cosmetic-') || cls === 'supporter-style') {
                                    msg.classList.remove(cls);
                                }
                            });
                            // Add new style
                            if (normalized.style) msg.classList.add(normalized.style);
                            if (normalized.supporter) msg.classList.add('supporter-style');
                            if (Array.isArray(normalized.cosmetics)) {
                                normalized.cosmetics.forEach(c => {
                                    if (c === 'cosmetic-aura-gold') {
                                        msg.classList.add('cosmetic-aura-gold');
                                    }
                                    if (c === 'cosmetic-redacted') {
                                        const auth = msgDiv.querySelector('.message-author');
                                        if (auth) auth.classList.add('cosmetic-redacted');

                                        // Apply redacted effect to message content after 10 seconds
                                        const contentEl = msgDiv.querySelector('.message-content');
                                        if (contentEl && !contentEl.classList.contains('cosmetic-redacted-message')) {
                                            setTimeout(() => {
                                                contentEl.classList.add('cosmetic-redacted-message');
                                            }, 10000);
                                        }
                                    }
                                });
                            }
                        });
                    }
                } catch (e) {
                }
                return;
            }

            // Our purchase record
            if (dTag[1] === 'nym-shop-purchases' && event.pubkey === this.pubkey) {
                try {
                    const data = JSON.parse(event.content || '{}');

                    // Check timestamp to prevent overwriting with older data
                    const currentTimestamp = this.shopPurchasesTimestamp || 0;
                    if (event.created_at < currentTimestamp) {
                        return;
                    }

                    this.shopPurchasesTimestamp = event.created_at;
                    this.userPurchases.clear();
                    (data.purchases || []).forEach(p => this.userPurchases.set(p.id, p));

                    // Update active items and cache them
                    if (data.activeStyle !== undefined) {
                        this.activeMessageStyle = data.activeStyle || null;
                        this.localActiveStyle = this.activeMessageStyle;
                        localStorage.setItem('nym_active_style', this.activeMessageStyle || '');
                    }

                    if (data.activeFlair !== undefined) {
                        this.activeFlair = data.activeFlair || null;
                        this.localActiveFlair = this.activeFlair;
                        localStorage.setItem('nym_active_flair', this.activeFlair || '');
                    }

                    if (data.activeCosmetics !== undefined) {
                        this.activeCosmetics = new Set(Array.isArray(data.activeCosmetics) ? data.activeCosmetics : []);
                    }

                    // After loading, broadcast our current active items so others see it
                    this.publishActiveShopItems();

                    // Apply to our messages immediately
                    this.applyShopStylesToOwnMessages();

                } catch (error) {
                }
            }
        } else if (event.kind === 7) {
            // Handle reactions (NIP-25)
            this.handleReaction(event);
        } else if (event.kind === 9735) {
            // Check if this is a shop zap receipt
            const pTag = event.tags.find(t => t[0] === 'p');
            const descriptionTag = event.tags.find(t => t[0] === 'description');

            if (pTag && pTag[1] === 'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df' && this.currentShopInvoice) {
                // This is a zap to the shop
                try {
                    if (descriptionTag) {
                        const zapRequest = JSON.parse(descriptionTag[1]);

                        // Check if this is our shop purchase
                        const shopPurchaseTag = zapRequest.tags?.find(t => t[0] === 'shop-purchase');
                        const shopItemTag = zapRequest.tags?.find(t => t[0] === 'shop-item');

                        if (shopPurchaseTag && shopItemTag &&
                            zapRequest.pubkey === this.pubkey &&
                            shopItemTag[1] === this.currentPurchaseContext?.itemId) {

                            // This is our shop purchase payment!

                            // Close the subscription
                            if (this.shopZapReceiptSubId) {
                                this.sendToRelay(["CLOSE", this.shopZapReceiptSubId]);
                                this.shopZapReceiptSubId = null;
                            }

                            // Handle successful payment
                            await this.handleShopPaymentSuccess();
                            return;
                        }
                    }
                } catch (e) {
                }
            }

            // Otherwise, handle as normal zap receipt
            this.handleZapReceipt(event);
        } else if (event.kind === 1059) {
            await this.handleGiftWrapDM(event);
        } else if (event.kind === 10000) {
            // Handle mute list of users/keywords
            this.handleMuteList(event);
        } else if (event.kind === 30078) {
            // Handle synced settings
            this.handleSyncedSettings(event);
        } else if (event.kind === 0) {
            // Handle profile events (kind 0) for lightning addresses
            try {
                const profile = JSON.parse(event.content);
                const pubkey = event.pubkey;

                // Store lightning address if present
                if (profile.lud16 || profile.lud06) {
                    const lnAddress = profile.lud16 || profile.lud06;
                    this.userLightningAddresses.set(pubkey, lnAddress);
                }

                // Update nym if we don't have one for this user
                if (profile.name || profile.username || profile.display_name) {
                    const profileName = profile.name || profile.username || profile.display_name;
                    if (!this.users.has(pubkey) || this.users.get(pubkey).nym.startsWith('anon-')) {
                        const existingUser = this.users.get(pubkey);
                        this.users.set(pubkey, {
                            nym: profileName.substring(0, 20),
                            pubkey: pubkey,
                            lastSeen: existingUser?.lastSeen || 0,
                            status: existingUser?.status || 'online',
                            channels: existingUser?.channels || new Set()
                        });
                    }
                }
            } catch (e) {
                // Ignore profile parse errors
            }
        } else if (event.kind === this.P2P_SIGNALING_KIND) {
            // Handle P2P signaling (WebRTC SDP/ICE)
            this.handleP2PSignalingEvent(event);
        }
    }

    isSpamMessage(content) {
        // Check if spam filter is disabled
        if (this.spamFilterEnabled === false) return false;

        // Remove whitespace to check the core content
        const trimmed = content.trim();

        // Allow empty messages or very short ones
        if (trimmed.length < 20) return false;

        // Block client spam
        if (trimmed.includes('joined the channel via bitchat.land')) return true;

        // Block non-nym community messages
        if (trimmed.includes('["client","chorus"]')) return true;

        // Check if it's a URL (contains :// or starts with www.)
        if (trimmed.includes('://') || trimmed.startsWith('www.')) return false;

        // Check for Lightning invoices (lnbc, lntb, lnts prefixes)
        if (/^ln(bc|tb|ts)/i.test(trimmed)) return false;

        // Check for Cashu tokens
        if (/^cashu/i.test(trimmed)) return false;

        // Check for Nostr identifiers (npub/nsec/note/nevent/naddr)
        if (/^(npub|nsec|note|nevent|naddr)1[a-z0-9]+$/i.test(trimmed)) return false;

        // Check for code blocks or formatted content
        if (trimmed.includes('```') || trimmed.includes('`')) return false;

        const words = trimmed.split(/[\s\u3000\u2000-\u200B\u0020\u00A0.,;!?。、，；！？\n]/);
        const longestWord = Math.max(...words.map(w => w.length));

        if (longestWord > 100) {
            if (trimmed.startsWith('data:image')) return false;

            const hasOnlyAlphaNumeric = /^[a-zA-Z0-9]+$/.test(trimmed);
            if (hasOnlyAlphaNumeric && trimmed.length > 100) {
                return true;
            }

            if (/^[a-zA-Z0-9]+$/.test(words.find(w => w.length > 100))) {
                const longWord = words.find(w => w.length > 100);
                const charFreq = {};
                for (const char of longWord) {
                    charFreq[char] = (charFreq[char] || 0) + 1;
                }

                const frequencies = Object.values(charFreq);
                const avgFreq = longWord.length / Object.keys(charFreq).length;
                const variance = frequencies.reduce((sum, freq) => sum + Math.pow(freq - avgFreq, 2), 0) / frequencies.length;

                if (variance < 2 && longWord.length > 100) {
                    return true;
                }
            }
        }

        return false;
    }

    async sendBRBResponse(mentioner, awayMessage) {
        // Send auto-response only once per mentioner
        const responseKey = `brb_${this.pubkey}_${mentioner}`;
        if (sessionStorage.getItem(responseKey)) {
            return; // Already sent response to this user
        }

        sessionStorage.setItem(responseKey, '1');
        const response = `@${mentioner} [Auto-Reply] ${awayMessage}`;
        await this.publishMessage(response, this.currentChannel, this.currentGeohash);
    }

    handleSyncedSettings(event) {
        if (event.pubkey !== this.pubkey) return;

        try {
            const settings = JSON.parse(event.content);

            // Restore image blur settings
            if (settings.blurOthersImages !== undefined) {
                this.blurOthersImages = settings.blurOthersImages;
                localStorage.setItem(`nym_image_blur_${this.pubkey}`, settings.blurOthersImages.toString());
            }

            // Restore proximity sorting preference
            if (settings.sortByProximity !== undefined) {
                this.settings.sortByProximity = settings.sortByProximity;
                localStorage.setItem('nym_sort_proximity', settings.sortByProximity);

                // If enabled, try to get location
                if (settings.sortByProximity && !this.userLocation) {
                    navigator.geolocation.getCurrentPosition(
                        (position) => {
                            this.userLocation = {
                                lat: position.coords.latitude,
                                lng: position.coords.longitude
                            };
                            this.sortChannelsByActivity();
                        },
                        (error) => {
                            this.settings.sortByProximity = false;
                            localStorage.setItem('nym_sort_proximity', 'false');
                        }
                    );
                }
            }

            // Apply theme
            if (settings.theme) {
                this.settings.theme = settings.theme;
                this.applyTheme(settings.theme);
                localStorage.setItem('nym_theme', settings.theme);
            }

            // Apply sound settings
            if (settings.sound !== undefined) {
                this.settings.sound = settings.sound;
                localStorage.setItem('nym_sound', settings.sound);
            }

            // Apply autoscroll
            if (settings.autoscroll !== undefined) {
                this.settings.autoscroll = settings.autoscroll;
                localStorage.setItem('nym_autoscroll', settings.autoscroll);
            }

            // Apply timestamp settings
            if (settings.showTimestamps !== undefined) {
                this.settings.showTimestamps = settings.showTimestamps;
                localStorage.setItem('nym_timestamps', settings.showTimestamps);
            }

            // Apply time format settings
            if (settings.timeFormat !== undefined) {
                this.settings.timeFormat = settings.timeFormat;
                localStorage.setItem('nym_time_format', settings.timeFormat);
                if (document.querySelectorAll('.message-time').length > 0) {
                    this.refreshMessageTimestamps();
                }
            }

            // Restore pinned channels
            if (settings.pinnedChannels) {
                this.pinnedChannels = new Set(settings.pinnedChannels);
                localStorage.setItem('nym_pinned_channels', JSON.stringify(settings.pinnedChannels));
                this.updateChannelPins();
            }

            // Restore blocked channels (keep this in custom settings)
            if (settings.blockedChannels) {
                this.blockedChannels = new Set(settings.blockedChannels);
                localStorage.setItem('nym_blocked_channels', JSON.stringify(settings.blockedChannels));
                this.updateBlockedChannelsList();
            }

            // Restore user joined channels
            if (settings.userJoinedChannels) {
                this.userJoinedChannels.clear();

                settings.userJoinedChannels.forEach(key => {
                    this.userJoinedChannels.add(key);
                    if (!this.channels.has(key)) {
                        if (this.isValidGeohash(key)) {
                            this.addChannel(key, key);
                        } else {
                            this.addChannel(key, '');
                        }
                    }
                });

                localStorage.setItem('nym_user_joined_channels', JSON.stringify(settings.userJoinedChannels));
                localStorage.setItem('nym_user_channels', JSON.stringify(
                    settings.userJoinedChannels.map(key => ({
                        key: key,
                        channel: this.isValidGeohash(key) ? key : key,
                        geohash: this.isValidGeohash(key) ? key : ''
                    }))
                ));
            }

            // Restore lightning address
            if (settings.lightningAddress) {
                this.lightningAddress = settings.lightningAddress;
                localStorage.setItem(`nym_lightning_address_${this.pubkey}`, settings.lightningAddress);
                this.updateLightningAddressDisplay();

                const lightningInput = document.getElementById('lightningAddressInput');
                if (lightningInput) {
                    lightningInput.value = settings.lightningAddress;
                }
            }

            // Restore pinned landing channel
            if (settings.pinnedLandingChannel) {
                this.pinnedLandingChannel = settings.pinnedLandingChannel;
                this.settings.pinnedLandingChannel = settings.pinnedLandingChannel;
                localStorage.setItem('nym_pinned_landing_channel', JSON.stringify(settings.pinnedLandingChannel));
            }

            // Update UI elements if settings modal is open
            if (document.getElementById('settingsModal').classList.contains('active')) {
                document.getElementById('themeSelect').value = this.settings.theme;
                document.getElementById('soundSelect').value = this.settings.sound;
                document.getElementById('autoscrollSelect').value = String(this.settings.autoscroll);
                document.getElementById('timestampSelect').value = String(this.settings.showTimestamps);
                document.getElementById('timeFormatSelect').value = this.settings.timeFormat;

                const blurSelect = document.getElementById('blurImagesSelect');
                if (blurSelect) {
                    blurSelect.value = String(this.blurOthersImages);
                }

                const timeFormatGroup = document.getElementById('timeFormatGroup');
                if (timeFormatGroup) {
                    timeFormatGroup.style.display = this.settings.showTimestamps ? 'block' : 'none';
                }
            }
            if (settings.dmForwardSecrecyEnabled !== undefined) {
                this.settings.dmForwardSecrecyEnabled = !!settings.dmForwardSecrecyEnabled;
                localStorage.setItem('nym_dm_fwdsec_enabled', String(this.settings.dmForwardSecrecyEnabled));
            }
            if (settings.dmTTLSeconds !== undefined) {
                const ttl = parseInt(settings.dmTTLSeconds, 10);
                this.settings.dmTTLSeconds = isFinite(ttl) && ttl > 0 ? ttl : 86400;
                localStorage.setItem('nym_dm_ttl_seconds', String(this.settings.dmTTLSeconds));
            }
            // Restore read receipts setting (default true if not set)
            if (settings.readReceiptsEnabled !== undefined) {
                this.settings.readReceiptsEnabled = settings.readReceiptsEnabled !== false;
                localStorage.setItem('nym_read_receipts_enabled', String(this.settings.readReceiptsEnabled));
            }

            // If modal open, reflect values
            if (document.getElementById('settingsModal').classList.contains('active')) {
                const dmEnabledSel = document.getElementById('dmForwardSecrecySelect');
                const dmTtlSel = document.getElementById('dmTTLSelect');
                const dmTtlGroup = document.getElementById('dmTTLGroup');
                if (dmEnabledSel && dmTtlSel && dmTtlGroup) {
                    dmEnabledSel.value = this.settings.dmForwardSecrecyEnabled ? 'true' : 'false';
                    dmTtlSel.value = String(this.settings.dmTTLSeconds || 86400);
                    dmTtlGroup.style.display = this.settings.dmForwardSecrecyEnabled ? 'block' : 'none';
                }
                // Also update read receipts select if modal is open
                const readReceiptsSel = document.getElementById('readReceiptsSelect');
                if (readReceiptsSel) {
                    readReceiptsSel.value = this.settings.readReceiptsEnabled !== false ? 'true' : 'false';
                }
            }
        } catch (error) {
        }
    }

    handleMuteList(event) {
        if (event.pubkey !== this.pubkey || event.kind !== 10000) return;

        // Extract blocked users from 'p' tags
        const mutedPubkeys = event.tags
            .filter(tag => tag[0] === 'p' && tag[1])
            .map(tag => tag[1]);

        if (mutedPubkeys.length > 0) {
            // Replace (not merge) with synced blocked users
            this.blockedUsers = new Set(mutedPubkeys);
            this.saveBlockedUsers();
            this.updateBlockedList();
            this.updateUserList();

            // Hide messages from blocked users after mute list loads
            mutedPubkeys.forEach(pubkey => {
                this.hideMessagesFromBlockedUser(pubkey);
            });
        }

        // Extract blocked keywords from 'word' tags
        const mutedWords = event.tags
            .filter(tag => tag[0] === 'word' && tag[1])
            .map(tag => tag[1]);

        if (mutedWords.length > 0) {
            // Replace (not merge) with synced keywords
            this.blockedKeywords = new Set(mutedWords);
            this.saveBlockedKeywords();
            this.updateKeywordList();

            // Hide messages with blocked keywords after mute list loads
            this.hideMessagesWithBlockedKeywords();
        }
    }

    handleReaction(event) {
        const reactionContent = event.content;
        const eTag = event.tags.find(t => t[0] === 'e');
        const kTag = event.tags.find(t => t[0] === 'k');

        if (!eTag) return;

        // Only process reactions for our supported kinds (include 1059 = NIP-17 gift wraps)
        if (kTag && !['20000', '23333', '1059', '4550'].includes(kTag[1])) {
            return;
        }

        const messageId = eTag[1];
        const reactorNym = this.getNymFromPubkey(event.pubkey);

        // Store reaction with pubkey and nym
        if (!this.reactions.has(messageId)) {
            this.reactions.set(messageId, new Map());
        }

        const messageReactions = this.reactions.get(messageId);
        if (!messageReactions.has(reactionContent)) {
            messageReactions.set(reactionContent, new Map());
        }

        // Store pubkey with nym
        messageReactions.get(reactionContent).set(event.pubkey, reactorNym);

        // Update UI if message is visible
        this.updateMessageReactions(messageId);
    }

    updateMessageReactions(messageId) {
        const messageEl = document.querySelector(`[data-message-id="${messageId}"]`);
        if (!messageEl) return;

        const reactions = this.reactions.get(messageId);
        if (!reactions || reactions.size === 0) {
            // Even if no reactions, update zaps display
            this.updateMessageZaps(messageId);
            return;
        }

        // Hide the hover reaction button since we have reactions
        const hoverReactionBtn = messageEl.querySelector('.reaction-btn');
        if (hoverReactionBtn) {
            hoverReactionBtn.style.display = 'none';
        }

        // Remove existing reactions display but preserve zap badges
        let reactionsRow = messageEl.querySelector('.reactions-row');
        let zapBadge = null;
        let addZapBtn = null;

        if (reactionsRow) {
            // Save zap badge and button if they exist
            zapBadge = reactionsRow.querySelector('.zap-badge');
            if (zapBadge) {
                zapBadge = zapBadge.cloneNode(true);
            }
            addZapBtn = reactionsRow.querySelector('.add-zap-btn');
            if (addZapBtn) {
                addZapBtn = addZapBtn.cloneNode(true);
            }
        }

        if (!reactionsRow) {
            reactionsRow = document.createElement('div');
            reactionsRow.className = 'reactions-row';
            messageEl.appendChild(reactionsRow);
        }

        // Clear and rebuild reactions
        reactionsRow.innerHTML = '';

        // Re-add zap badge first if it exists
        if (zapBadge) {
            reactionsRow.appendChild(zapBadge);
        }

        // Re-add quick zap button ONLY if it already existed (meaning there are zaps)
        if (addZapBtn) {
            reactionsRow.appendChild(addZapBtn);
            // Re-attach the click handler
            const pubkey = messageEl.dataset.pubkey;
            addZapBtn.onclick = async (e) => {
                e.stopPropagation();
                await this.handleQuickZap(messageId, pubkey, messageEl);
            };
        }

        // Clear and rebuild reactions
        reactions.forEach((reactors, emoji) => {
            const badge = document.createElement('span');

            // Check if current user has already reacted with this emoji
            const hasReacted = reactors.has(this.pubkey);

            // Set class based on reaction state
            badge.className = hasReacted ? 'reaction-badge user-reacted' : 'reaction-badge';
            badge.dataset.emoji = emoji;
            badge.dataset.messageId = messageId;

            badge.innerHTML = `${emoji} ${reactors.size}`;

            // Create tooltip with user names
            if (hasReacted) {
                const otherUsers = Array.from(reactors.entries())
                    .filter(([pk, nym]) => pk !== this.pubkey)
                    .map(([pk, nym]) => nym);
                badge.title = otherUsers.length > 0 ?
                    `You and ${otherUsers.join(', ')}` :
                    'You reacted with this';
            } else {
                const users = Array.from(reactors.values()).join(', ');
                badge.title = `Click to also react with ${emoji} | ${users}`;
            }

            // Add click handler - NO optimistic update here since sendReaction handles it
            badge.onclick = async (e) => {
                e.stopPropagation();
                if (!hasReacted) {
                    // Just call sendReaction - it handles optimistic updates
                    await this.sendReaction(messageId, emoji);
                } else {
                    this.displaySystemMessage(`You already reacted with ${emoji}`);
                }
            };

            reactionsRow.appendChild(badge);
        });

        // Adds "add reaction" badge
        const addBtn = document.createElement('span');
        addBtn.className = 'add-reaction-btn';
        addBtn.innerHTML = `
<svg viewBox="0 0 24 24">
    <circle cx="12" cy="12" r="10"></circle>
    <circle cx="9" cy="9" r="1"></circle>
    <circle cx="15" cy="9" r="1"></circle>
    <path d="M8 14s1.5 2 4 2 4-2 4-2"></path>
    <circle cx="18" cy="6" r="5" fill="var(--text)" stroke="none"></circle>
    <line x1="18" y1="4" x2="18" y2="8" stroke="var(--bg)" stroke-width="1.5" stroke-linecap="round"></line>
    <line x1="16" y1="6" x2="20" y2="6" stroke="var(--bg)" stroke-width="1.5" stroke-linecap="round"></line>
</svg>
`;
        addBtn.title = 'Add reaction';
        addBtn.onclick = (e) => {
            e.stopPropagation();
            this.showEnhancedReactionPicker(messageId, addBtn);
        };
        reactionsRow.appendChild(addBtn);
    }

    showReactionPicker(messageId, button) {
        // Toggle if clicking same button
        if (this.enhancedEmojiModal && this.activeReactionPickerButton === button) {
            this.closeEnhancedEmojiModal();
            this.activeReactionPickerButton = null;
            return;
        }

        // Remember which button opened this
        this.activeReactionPickerButton = button;

        // Use enhanced picker
        this.showEnhancedReactionPicker(messageId, button);
    }

    showEnhancedReactionPicker(messageId, button) {
        // Check if clicking the same button that opened the current modal
        if (this.enhancedEmojiModal && this.activeReactionPickerButton === button) {
            this.closeEnhancedEmojiModal();
            return;
        }

        // Close any existing picker
        this.closeEnhancedEmojiModal();

        // Remember which button opened this
        this.activeReactionPickerButton = button;

        const modal = document.createElement('div');
        modal.className = 'enhanced-emoji-modal active';

        // Create reverse lookup for emoji names
        const emojiToNames = {};
        Object.entries(this.emojiMap).forEach(([name, emoji]) => {
            if (!emojiToNames[emoji]) {
                emojiToNames[emoji] = [];
            }
            emojiToNames[emoji].push(name);
        });

        modal.innerHTML = `
<div class="emoji-modal-header">
    <input type="text" class="emoji-search-input" placeholder="Search emoji by name..." id="emojiSearchInput">
</div>
${this.recentEmojis.length > 0 ? `
    <div class="emoji-section">
        <div class="emoji-section-title">Recently Used</div>
        <div class="emoji-grid">
            ${this.recentEmojis.map(emoji =>
            `<button class="emoji-option" data-emoji="${emoji}" title="${emojiToNames[emoji] ? emojiToNames[emoji].join(', ') : ''}">${emoji}</button>`
        ).join('')}
        </div>
    </div>
` : ''}
${Object.entries(this.allEmojis).map(([category, emojis]) => `
    <div class="emoji-section" data-category="${category}">
        <div class="emoji-section-title">${category.charAt(0).toUpperCase() + category.slice(1)}</div>
        <div class="emoji-grid">
            ${emojis.map(emoji => {
            const names = emojiToNames[emoji] || [];
            return `<button class="emoji-option" data-emoji="${emoji}" data-names="${names.join(' ')}" title="${names.join(', ')}">${emoji}</button>`;
        }).join('')}
        </div>
    </div>
`).join('')}
`;

        // Position modal
        const rect = button.getBoundingClientRect();
        modal.style.position = 'fixed';

        // Check if on mobile
        if (window.innerWidth <= 768) {
            // Center on mobile
            modal.style.top = '50%';
            modal.style.left = '50%';
            modal.style.transform = 'translate(-50%, -50%)';
            modal.style.maxWidth = '90%';
            modal.style.maxHeight = '80vh';
            modal.style.zIndex = '10000';
        } else {
            // Desktop positioning - check if near top of screen
            const spaceBelow = window.innerHeight - rect.bottom;
            const spaceAbove = rect.top;

            if (spaceBelow > 450 || spaceBelow > spaceAbove) {
                // Show below button
                modal.style.top = (rect.bottom + 10) + 'px';
                modal.style.bottom = 'auto';
            } else {
                // Show above button
                modal.style.bottom = (window.innerHeight - rect.top + 10) + 'px';
                modal.style.top = 'auto';
            }

            // Horizontal positioning
            if (rect.left > window.innerWidth * 0.5) {
                modal.style.right = Math.min(window.innerWidth - rect.right, 10) + 'px';
                modal.style.left = 'auto';
            } else {
                modal.style.left = Math.max(rect.left, 10) + 'px';
                modal.style.right = 'auto';
            }

            modal.style.maxHeight = '400px';
        }

        document.body.appendChild(modal);
        this.enhancedEmojiModal = modal;

        // Add search functionality
        const searchInput = modal.querySelector('#emojiSearchInput');
        searchInput.addEventListener('input', (e) => {
            const search = e.target.value.toLowerCase();
            modal.querySelectorAll('.emoji-option').forEach(btn => {
                const emoji = btn.textContent;
                const names = btn.dataset.names || '';
                const shouldShow = !search ||
                    emoji.includes(search) ||
                    names.toLowerCase().includes(search);
                btn.style.display = shouldShow ? '' : 'none';
            });
            // Hide empty sections
            modal.querySelectorAll('.emoji-section').forEach(section => {
                const hasVisible = Array.from(section.querySelectorAll('.emoji-option'))
                    .some(btn => btn.style.display !== 'none');
                section.style.display = hasVisible ? '' : 'none';
            });
        });

        // Add click handlers
        modal.querySelectorAll('.emoji-option').forEach(btn => {
            btn.onclick = async (e) => {
                e.stopPropagation();
                const emoji = btn.dataset.emoji;
                this.addToRecentEmojis(emoji);
                await this.sendReaction(messageId, emoji);
                this.closeEnhancedEmojiModal();
            };
        });

        // Focus search
        searchInput.focus();
    }

    toggleEmojiPicker() {
        // Check if modal already exists
        if (this.enhancedEmojiModal) {
            // Close existing modal
            this.closeEnhancedEmojiModal();
            return;
        }

        // Create modal for emoji picker
        const button = document.querySelector('.icon-btn.input-btn[title="Emoji"]');
        if (button) {
            this.showEnhancedEmojiPickerForInput(button);
        }
    }

    showEnhancedEmojiPickerForInput(button) {
        // Close any existing picker
        this.closeEnhancedEmojiModal();

        const modal = document.createElement('div');
        modal.className = 'enhanced-emoji-modal active';

        // Create reverse lookup for emoji names
        const emojiToNames = {};
        Object.entries(this.emojiMap).forEach(([name, emoji]) => {
            if (!emojiToNames[emoji]) {
                emojiToNames[emoji] = [];
            }
            emojiToNames[emoji].push(name);
        });

        modal.innerHTML = `
<div class="emoji-modal-header">
    <input type="text" class="emoji-search-input" placeholder="Search emoji by name..." id="emojiSearchInput">
</div>
${this.recentEmojis.length > 0 ? `
    <div class="emoji-section">
        <div class="emoji-section-title">Recently Used</div>
        <div class="emoji-grid">
            ${this.recentEmojis.map(emoji =>
            `<button class="emoji-option" data-emoji="${emoji}" title="${emojiToNames[emoji] ? emojiToNames[emoji].join(', ') : ''}">${emoji}</button>`
        ).join('')}
        </div>
    </div>
` : ''}
${Object.entries(this.allEmojis).map(([category, emojis]) => `
    <div class="emoji-section" data-category="${category}">
        <div class="emoji-section-title">${category.charAt(0).toUpperCase() + category.slice(1)}</div>
        <div class="emoji-grid">
            ${emojis.map(emoji => {
            const names = emojiToNames[emoji] || [];
            return `<button class="emoji-option" data-emoji="${emoji}" data-names="${names.join(' ')}" title="${names.join(', ')}">${emoji}</button>`;
        }).join('')}
        </div>
    </div>
`).join('')}
`;

        // Position near button
        const rect = button.getBoundingClientRect();
        modal.style.position = 'fixed';

        // Check if on mobile
        if (window.innerWidth <= 768) {
            modal.style.bottom = '60px';
            modal.style.left = '50%';
            modal.style.transform = 'translateX(-50%)';
            modal.style.right = 'auto';
            modal.style.maxWidth = '90%';
        } else {
            modal.style.bottom = (window.innerHeight - rect.top + 10) + 'px';
            modal.style.right = Math.min(window.innerWidth - rect.right + 50, 10) + 'px';
        }

        document.body.appendChild(modal);
        this.enhancedEmojiModal = modal;

        // Add search functionality
        const searchInput = modal.querySelector('#emojiSearchInput');
        searchInput.addEventListener('input', (e) => {
            const search = e.target.value.toLowerCase();
            modal.querySelectorAll('.emoji-option').forEach(btn => {
                const emoji = btn.textContent;
                const names = btn.dataset.names || '';
                const shouldShow = !search ||
                    emoji.includes(search) ||
                    names.toLowerCase().includes(search);
                btn.style.display = shouldShow ? '' : 'none';
            });
            // Hide empty sections
            modal.querySelectorAll('.emoji-section').forEach(section => {
                const hasVisible = Array.from(section.querySelectorAll('.emoji-option'))
                    .some(btn => btn.style.display !== 'none');
                section.style.display = hasVisible ? '' : 'none';
            });
        });

        // Add click handlers for inserting emoji into input
        modal.querySelectorAll('.emoji-option').forEach(btn => {
            btn.onclick = (e) => {
                e.stopPropagation();
                const emoji = btn.dataset.emoji;
                this.insertEmoji(emoji);
                this.closeEnhancedEmojiModal();
            };
        });

        // Focus search
        searchInput.focus();
    }

    closeEnhancedEmojiModal() {
        if (this.enhancedEmojiModal) {
            this.enhancedEmojiModal.remove();
            this.enhancedEmojiModal = null;
        }
        // Clear the button reference
        this.activeReactionPickerButton = null;
    }

    async sendReaction(messageId, emoji) {
        try {
            const messageEl = document.querySelector(`[data-message-id="${messageId}"]`);
            if (!messageEl) return;

            const targetPubkey = messageEl.dataset.pubkey;
            if (!targetPubkey) return;

            // Ensure local state contains this reaction
            if (!this.reactions.has(messageId)) {
                this.reactions.set(messageId, new Map());
            }
            const messageReactions = this.reactions.get(messageId);
            if (!messageReactions.has(emoji)) {
                messageReactions.set(emoji, new Map());
            }

            // Check if already reacted
            if (messageReactions.get(emoji).has(this.pubkey)) {
                return; // Already reacted with this emoji
            }

            // Add reaction immediately to local state
            messageReactions.get(emoji).set(this.pubkey, this.nym);

            // Update UI immediately
            this.updateMessageReactions(messageId);

            // Infer original kind directly from the rendered message element/container context
            const container = document.getElementById('messagesContainer');
            let originalKind = '23333'; // default to standard
            if (messageEl.classList.contains('pm')) {
                originalKind = '1059'; // NIP-17 gift wrap
            } else if (container && container.dataset && container.dataset.lastCommunity) {
                originalKind = '4550';  // community post
            } else if (container && container.dataset && container.dataset.lastChannel) {
                const lc = container.dataset.lastChannel;
                // lastChannel is "#geohash" or "channel"; treat geohash with leading "#" as kind 20000
                if (lc.startsWith('#') && this.isValidGeohash(lc.substring(1))) {
                    originalKind = '20000';
                } else {
                    originalKind = '23333';
                }
            } else if (this.currentCommunity) {
                originalKind = '4550';
            } else if (this.currentGeohash) {
                originalKind = '20000';
            }

            const event = {
                kind: 7,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ['e', messageId],
                    ['p', targetPubkey],
                    ['k', originalKind]
                ],
                content: emoji,
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(event);

            if (signedEvent) {
                // Send to relay (async - UI already updated)
                this.sendToRelay(["EVENT", signedEvent]);
                this.addToRecentEmojis(emoji);
            } else {
                // Signing failed - revert the optimistic update
                messageReactions.get(emoji).delete(this.pubkey);
                this.updateMessageReactions(messageId);
                this.displaySystemMessage('Failed to sign reaction');
            }
        } catch (error) {
            // Revert optimistic update on error
            const messageReactions = this.reactions.get(messageId);
            if (messageReactions && messageReactions.has(emoji)) {
                messageReactions.get(emoji).delete(this.pubkey);
                this.updateMessageReactions(messageId);
            }
        }
    }

    trackMessage(pubkey, channel, isHistorical = false) {
        // Don't track historical messages from initial load
        if (isHistorical) {
            return;
        }

        const now = Date.now();
        const channelKey = channel; // Use channel as key for per-channel tracking

        // Create channel-specific tracking
        if (!this.floodTracking.has(channelKey)) {
            this.floodTracking.set(channelKey, new Map());
        }

        const channelTracking = this.floodTracking.get(channelKey);

        if (!channelTracking.has(pubkey)) {
            channelTracking.set(pubkey, {
                count: 1,
                firstMessageTime: now,
                blocked: false
            });
            return;
        }

        const tracking = channelTracking.get(pubkey);

        // Reset if more than 2 seconds have passed
        if (now - tracking.firstMessageTime > 2000) {
            tracking.count = 1;
            tracking.firstMessageTime = now;
            tracking.blocked = false;
        } else {
            tracking.count++;

            // Block if more than 10 messages in 2 seconds IN THIS CHANNEL
            if (tracking.count > 10 && !tracking.blocked) {
                tracking.blocked = true;
                tracking.blockedUntil = now + 900000; // 15 minutes

                const nym = this.getNymFromPubkey(pubkey);
            }
        }
    }

    isFlooding(pubkey, channel) {
        const channelTracking = this.floodTracking.get(channel);
        if (!channelTracking) return false;

        const tracking = channelTracking.get(pubkey);
        if (!tracking) return false;

        if (tracking.blocked) {
            const now = Date.now();
            if (now < tracking.blockedUntil) {
                return true;
            } else {
                // Unblock after timeout
                tracking.blocked = false;
                tracking.blockedUntil = null;
            }
        }

        return false;
    }

    // NIP-44 helpers (v2) using bundled nostr-tools API
    async encryptNIP44(plaintext, recipientPubkey) {
        // Try extension first (it does ECDH in the extension)
        if (window.nostr?.nip44?.encrypt) {
            return await window.nostr.nip44.encrypt(recipientPubkey, plaintext);
        }
        // Local fallback derive conversation key and encrypt
        if (!this.privkey) throw new Error('No privkey available for NIP-44 encryption');
        const { nip44 } = window.NostrTools;
        const ck = nip44.getConversationKey(this.privkey, recipientPubkey);
        return nip44.encrypt(plaintext, ck);
    }

    async decryptNIP44(payload, senderPubkey) {
        // Try extension first
        if (window.nostr?.nip44?.decrypt) {
            return await window.nostr.nip44.decrypt(senderPubkey, payload);
        }
        // Local fallback derive conversation key and decrypt
        if (!this.privkey) throw new Error('No privkey available for NIP-44 decryption');
        const { nip44 } = window.NostrTools;
        const ck = nip44.getConversationKey(this.privkey, senderPubkey);
        return nip44.decrypt(payload, ck);
    }

    randomNow() {
        const TWO_DAYS = 2 * 24 * 60 * 60;
        return Math.round(Date.now() / 1000 - Math.random() * TWO_DAYS);
    }

    // Generate UUID v4
    generateUUID() {
        return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => {
            const r = Math.random() * 16 | 0;
            return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
        }).toUpperCase();
    }

    // Debug: decode and log bitchat1: structure
    decodeBitchatStructure(content) {
        if (!content.startsWith('bitchat1:')) return null;
        try {
            let b64 = content.slice(9);
            b64 = b64.replace(/-/g, '+').replace(/_/g, '/');
            while (b64.length % 4) b64 += '=';
            const bytes = Uint8Array.from(atob(b64), c => c.charCodeAt(0));

            // Parse header
            const version = bytes[0];
            const type = bytes[1];
            const ttl = bytes[2];

            // Timestamp (8 bytes big endian)
            let timestamp = 0n;
            for (let i = 0; i < 8; i++) {
                timestamp = (timestamp << 8n) | BigInt(bytes[3 + i]);
            }

            // Payload length (2 bytes)
            const payloadLen = (bytes[11] << 8) | bytes[12];

            // Sender ID (8 bytes)
            const senderID = Array.from(bytes.subarray(13, 21)).map(b => b.toString(16).padStart(2, '0')).join('');

            // Payload section starts at byte 21
            const flags = bytes[21];
            const uuidLen = (bytes[22] << 8) | bytes[23];
            const uuid = new TextDecoder().decode(bytes.subarray(24, 24 + uuidLen));

            const msgTypeOffset = 24 + uuidLen;
            const msgType = bytes[msgTypeOffset];
            const msgLen = bytes[msgTypeOffset + 1];
            const message = new TextDecoder().decode(bytes.subarray(msgTypeOffset + 2, msgTypeOffset + 2 + msgLen));

            return {
                version, type, ttl,
                timestamp: Number(timestamp),
                payloadLen, senderID,
                flags, uuidLen, uuid,
                msgType, msgLen, message,
                totalBytes: bytes.length
            };
        } catch (e) {
            return null;
        }
    }

    // Encode message in Bitchat's bitchat1: format
    encodeBitchatMessage(content, recipientPubkey = null) {
        const now = Date.now();
        const messageID = this.generateUUID();
        const messageBytes = new TextEncoder().encode(content);
        const messageIDBytes = new TextEncoder().encode(messageID);

        const tlvParts = [];

        // MESSAGE_ID field (type 0x00)
        tlvParts.push(0x00);
        tlvParts.push(messageIDBytes.length & 0xFF);
        for (const b of messageIDBytes) tlvParts.push(b);

        // CONTENT field (type 0x01)
        tlvParts.push(0x01);
        tlvParts.push(messageBytes.length & 0xFF);
        for (const b of messageBytes) tlvParts.push(b);

        const noisePayload = [];
        noisePayload.push(0x01); // PRIVATE_MESSAGE
        for (const b of tlvParts) noisePayload.push(b);

        const parts = [];

        // Header bytes 0-2
        parts.push(0x01); // version 1
        parts.push(0x11); // type = NOISE_ENCRYPTED
        parts.push(0x07); // TTL 7

        // Timestamp bytes 3-10 (8 bytes, big endian milliseconds)
        const ts = BigInt(now);
        for (let i = 7; i >= 0; i--) {
            parts.push(Number((ts >> BigInt(i * 8)) & 0xFFn));
        }

        // Flags byte 11
        // 0x01 = HAS_RECIPIENT, 0x02 = HAS_SIGNATURE, 0x04 = IS_COMPRESSED
        const hasRecipient = !!recipientPubkey;
        const flags = hasRecipient ? 0x01 : 0x00;
        parts.push(flags);

        // Payload length bytes 12-13 (2 bytes, big-endian)
        const payloadLen = noisePayload.length;
        parts.push((payloadLen >> 8) & 0xFF);
        parts.push(payloadLen & 0xFF);

        // Sender ID bytes 14-21 (first 8 bytes of our pubkey)
        for (let i = 0; i < 8; i++) {
            parts.push(parseInt(this.pubkey.substring(i * 2, i * 2 + 2), 16));
        }

        // Recipient ID bytes 22-29 (if HAS_RECIPIENT flag set)
        if (hasRecipient) {
            for (let i = 0; i < 8; i++) {
                parts.push(parseInt(recipientPubkey.substring(i * 2, i * 2 + 2), 16));
            }
        }

        // Payload (NoisePayload)
        for (const b of noisePayload) parts.push(b);

        // Pad to next block size (256, 512, 1024, 2048) with 0xBE
        const blockSizes = [256, 512, 1024, 2048];
        let targetSize = blockSizes.find(s => s >= parts.length) || 2048;
        while (parts.length < targetSize) {
            parts.push(0xBE);
        }

        // Convert to base64url
        const bytes = new Uint8Array(parts);
        const base64 = btoa(String.fromCharCode(...bytes));
        const base64url = base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

        return { content: 'bitchat1:' + base64url, messageId: messageID };
    }

    // Encode a Bitchat receipt (DELIVERED=0x03 or READ_RECEIPT=0x02)
    encodeBitchatReceipt(messageId, receiptType, recipientPubkey) {
        const messageIdBytes = new TextEncoder().encode(messageId);

        // NoisePayload for receipts: [type][raw messageId] (no TLV wrapper!)
        // Bitchat sends receipts with just the UUID string directly
        const noisePayload = [];
        noisePayload.push(receiptType); // 0x02=READ_RECEIPT, 0x03=DELIVERED
        for (const b of messageIdBytes) noisePayload.push(b);

        // BitchatPacket header
        const parts = [];
        const now = Date.now();

        parts.push(0x01); // version
        parts.push(0x11); // type = NOISE_ENCRYPTED
        parts.push(0x07); // TTL

        // Timestamp (8 bytes big-endian)
        const ts = BigInt(now);
        for (let i = 7; i >= 0; i--) {
            parts.push(Number((ts >> BigInt(i * 8)) & 0xFFn));
        }

        // Flags (include recipient)
        parts.push(0x01); // HAS_RECIPIENT

        // Payload length
        const payloadLen = noisePayload.length;
        parts.push((payloadLen >> 8) & 0xFF);
        parts.push(payloadLen & 0xFF);

        // Sender ID (first 8 bytes of our pubkey)
        for (let i = 0; i < 8; i++) {
            parts.push(parseInt(this.pubkey.substring(i * 2, i * 2 + 2), 16));
        }

        // Recipient ID
        for (let i = 0; i < 8; i++) {
            parts.push(parseInt(recipientPubkey.substring(i * 2, i * 2 + 2), 16));
        }

        // Payload
        for (const b of noisePayload) parts.push(b);

        // Pad to block size
        const blockSizes = [256, 512, 1024, 2048];
        let targetSize = blockSizes.find(s => s >= parts.length) || 2048;
        while (parts.length < targetSize) {
            parts.push(0xBE);
        }

        const bytes = new Uint8Array(parts);
        const base64 = btoa(String.fromCharCode(...bytes));
        const base64url = base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

        return 'bitchat1:' + base64url;
    }

    // Send a receipt (DELIVERED or READ) back to a Bitchat user
    // receiptType: 0x02 = READ_RECEIPT, 0x03 = DELIVERED
    async sendBitchatReceipt(messageId, receiptType, recipientPubkey) {
        if (!this.privkey || !this.bitchatUsers.has(recipientPubkey)) return;

        // Skip READ receipts (0x02) if user has disabled them in settings
        if (receiptType === 0x02 && this.settings?.readReceiptsEnabled === false) {
            return;
        }

        const receiptContent = this.encodeBitchatReceipt(messageId, receiptType, recipientPubkey);

        const now = Math.floor(Date.now() / 1000);
        const rumor = {
            kind: 14,
            created_at: now,
            tags: [],
            content: receiptContent,
            pubkey: this.pubkey
        };

        const wrapped = this.bitchatWrapEvent(rumor, this.privkey, recipientPubkey, null);
        this.sendToRelay(['EVENT', wrapped]);
    }

    // NYM receipt types: 'delivered' or 'read'
    // Uses NIP-17 gift wrap with a special rumor format for receipts
    // Format: rumor with kind 69420 (custom), content empty, tags include ['x', messageId] and ['receipt', type]
    // Using kind 69420 instead of 14 to avoid showing blank DMs in other NIP-17 clients
    async sendNymReceipt(messageId, receiptType, recipientPubkey) {
        if (!this.privkey) return;

        // Skip READ receipts if user has disabled them in settings
        if (receiptType === 'read' && this.settings?.readReceiptsEnabled === false) {
            return;
        }

        const now = Math.floor(Date.now() / 1000);
        const rumor = {
            kind: 69420,
            created_at: now,
            tags: [
                ['p', recipientPubkey],
                ['x', messageId],  // Reference to original message
                ['receipt', receiptType]  // 'delivered' or 'read'
            ],
            content: '',  // Empty content for receipts
            pubkey: this.pubkey
        };

        // Wrap using standard NIP-59 format
        const wrapped = this.nip59WrapEvent(rumor, this.privkey, recipientPubkey, null);
        this.sendToRelay(['EVENT', wrapped]);
    }

    // Check if a rumor is a NYM receipt
    isNymReceipt(rumor) {
        if (!rumor || !rumor.tags) return false;
        return rumor.tags.some(t => Array.isArray(t) && t[0] === 'receipt' && (t[1] === 'delivered' || t[1] === 'read'));
    }

    // Extract receipt info from a NYM receipt rumor
    parseNymReceipt(rumor) {
        if (!rumor || !rumor.tags) return null;

        let messageId = null;
        let receiptType = null;

        for (const tag of rumor.tags) {
            if (Array.isArray(tag)) {
                if (tag[0] === 'x' && tag[1]) {
                    messageId = tag[1];
                } else if (tag[0] === 'receipt' && tag[1]) {
                    receiptType = tag[1];
                }
            }
        }

        if (messageId && receiptType) {
            return { messageId, receiptType };
        }
        return null;
    }

    // Check if a rumor is a NYM message (has 'x' tag for message ID)
    isNymMessage(rumor) {
        if (!rumor || !rumor.tags) return false;
        return rumor.tags.some(t => Array.isArray(t) && t[0] === 'x' && t[1] && !this.isNymReceipt(rumor));
    }

    // Extract NYM message ID from rumor
    getNymMessageId(rumor) {
        if (!rumor || !rumor.tags) return null;
        const xTag = rumor.tags.find(t => Array.isArray(t) && t[0] === 'x' && t[1]);
        return xTag ? xTag[1] : null;
    }

    // Key derivation: HKDF(full compressed shared point 33 bytes, empty salt, "nip44-v2" info)
    encryptBitchat(plaintext, senderPrivateKey, recipientPublicKey) {
        const NT = window.NostrTools;

        // Get full compressed shared point (33 bytes including prefix)
        // Try 02 prefix first - Bitchat will try both prefixes when decrypting
        const sharedPoint = NT._secp256k1.getSharedSecret(senderPrivateKey, '02' + recipientPublicKey);

        // Bitchat key derivation: HKDF with full compressed point, empty salt, "nip44-v2" as info
        const prk = NT._hkdfExtract(NT._sha256, sharedPoint, new Uint8Array(0)); // truly empty salt
        const info = new TextEncoder().encode('nip44-v2');
        const bitchatKey = NT._hkdfExpand(NT._sha256, prk, info, 32);

        // Generate random 24-byte nonce
        const nonce = crypto.getRandomValues(new Uint8Array(24));

        // Encrypt using XChaCha20-Poly1305
        const plaintextBytes = new TextEncoder().encode(plaintext);
        const ciphertextWithTag = NT._xchacha20poly1305(bitchatKey, nonce).encrypt(plaintextBytes);

        // Combine: nonce || ciphertext || tag
        const payload = new Uint8Array(nonce.length + ciphertextWithTag.length);
        payload.set(nonce, 0);
        payload.set(ciphertextWithTag, nonce.length);

        // Encode as base64url with v2: prefix
        const base64 = btoa(String.fromCharCode(...payload));
        const base64url = base64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
        return 'v2:' + base64url;
    }

    // Bitchat-compatible gift wrap (uses raw XChaCha20-Poly1305 instead of NIP-44)
    bitchatWrapEvent(event, senderPrivateKey, recipientPublicKey, expirationTs = null) {
        const NT = window.NostrTools;

        // Rumor (unsigned) with computed id
        const now = Math.floor(Date.now() / 1000);
        const rumor = {
            created_at: now,
            content: '',
            tags: [],
            ...event,
            pubkey: NT.getPublicKey(senderPrivateKey)
        };
        rumor.id = NT.getEventHash(rumor);

        // Bitchat decrypts seal using ECDH(recipient_privkey, seal.pubkey)
        const senderPubkey = NT.getPublicKey(senderPrivateKey);
        const sealedContent = this.encryptBitchat(JSON.stringify(rumor), senderPrivateKey, recipientPublicKey);
        const sealUnsigned = {
            kind: 13,
            content: sealedContent,
            created_at: this.randomNow(),
            tags: []
        };
        const seal = NT.finalizeEvent(sealUnsigned, senderPrivateKey);

        // GiftWrap (kind 1059) with different ephemeral keypair
        const wrapEphSk = NT.generateSecretKey();
        const wrapEphPk = NT.getPublicKey(wrapEphSk);
        const wrapContent = this.encryptBitchat(JSON.stringify(seal), wrapEphSk, recipientPublicKey);
        const wrapUnsigned = {
            kind: 1059,
            content: wrapContent,
            created_at: this.randomNow(),
            tags: [['p', recipientPublicKey]],
            pubkey: wrapEphPk
        };

        return NT.finalizeEvent(wrapUnsigned, wrapEphSk);
    }

    nip59WrapEvent(event, senderPrivateKey, recipientPublicKey, expirationTs = null) {
        const NT = window.NostrTools;

        // Rumor (unsigned) with computed id
        const now = Math.floor(Date.now() / 1000);
        const rumor = {
            created_at: now,
            content: '',
            tags: [],
            ...event,
            pubkey: NT.getPublicKey(senderPrivateKey)
        };
        rumor.id = NT.getEventHash(rumor);

        // Seal (kind 13)
        const ckSeal = NT.nip44.getConversationKey(senderPrivateKey, recipientPublicKey);
        const sealedContent = NT.nip44.encrypt(JSON.stringify(rumor), ckSeal);
        const sealUnsigned = {
            kind: 13,
            content: sealedContent,
            created_at: this.randomNow(),
            tags: []
        };
        const seal = NT.finalizeEvent(sealUnsigned, senderPrivateKey);

        // GiftWrap (kind 1059) with ephemeral keypair
        const ephSk = NT.generateSecretKey();
        const ephPk = NT.getPublicKey(ephSk);
        const ckWrap = NT.nip44.getConversationKey(ephSk, recipientPublicKey);
        const wrapContent = NT.nip44.encrypt(JSON.stringify(seal), ckWrap);
        const wrapUnsigned = {
            kind: 1059,
            content: wrapContent,
            created_at: this.randomNow(),
            tags: [['p', recipientPublicKey]],
            pubkey: ephPk
        };

        // Add expiration only if enabled
        if (expirationTs) {
            wrapUnsigned.tags.push(['expiration', String(expirationTs)]);
        }

        return NT.finalizeEvent(wrapUnsigned, ephSk);
    }

    nip59UnwrapEvent(wrap, recipientPrivateKey) {
        const NT = window.NostrTools;

        // Unwrap GiftWrap (ECDH with wrap.pubkey = ephemeral sender)
        const ckWrap = NT.nip44.getConversationKey(recipientPrivateKey, wrap.pubkey);
        const sealJson = NT.nip44.decrypt(wrap.content, ckWrap);
        const seal = JSON.parse(sealJson);

        // Unwrap Seal (ECDH with seal.pubkey = sender identity)
        const ckSeal = NT.nip44.getConversationKey(recipientPrivateKey, seal.pubkey);
        const rumorJson = NT.nip44.decrypt(seal.content, ckSeal);
        return JSON.parse(rumorJson); // rumor
    }

    // Send PM using NIP-17 (GiftWrap 1059) and optional forward secrecy
    async sendNIP17PM(content, recipientPubkey) {
        const now = Math.floor(Date.now() / 1000);

        // Generate message ID for delivery receipts (NYM format)
        const nymMessageId = this.generateUUID();

        const rumor = {
            kind: 14,
            created_at: now,
            tags: [
                ['p', recipientPubkey],
                ['x', nymMessageId]  // NYM message ID for delivery receipts
            ],
            content,
            pubkey: this.pubkey
        };

        // Optional expiration (NIP-40) on gift wrap level
        const expirationTs = (this.settings?.dmForwardSecrecyEnabled && this.settings?.dmTTLSeconds > 0)
            ? Math.floor(Date.now() / 1000) + this.settings.dmTTLSeconds
            : null;

        // Local key available (ephemeral/nsec)
        if (this.privkey) {
            const NT = window.NostrTools;
            const useBitchatFormat = this.bitchatUsers.has(recipientPubkey);
            let wrapped;
            let bitchatMessageId = null;
            if (useBitchatFormat) {
                // Use Bitchat v2: encryption with bitchat1: message format
                // Bitchat sends rumor with EMPTY tags (no p tag in rumor)
                const encoded = this.encodeBitchatMessage(content, recipientPubkey);
                bitchatMessageId = encoded.messageId;

                const bitchatRumor = {
                    kind: 14,
                    created_at: now,
                    tags: [],  // Bitchat uses empty tags in rumor!
                    content: encoded.content,
                    pubkey: this.pubkey
                };
                wrapped = this.bitchatWrapEvent(bitchatRumor, this.privkey, recipientPubkey, expirationTs);
            } else {
                // Use NYM format with message ID tag for delivery receipts
                wrapped = this.nip59WrapEvent(rumor, this.privkey, recipientPubkey, expirationTs);
            }

            this.sendToRelay(['EVENT', wrapped]);

            // Schedule deletion if redacted cosmetic is active
            if (this.activeCosmetics && this.activeCosmetics.has('cosmetic-redacted')) {
                const eventIdToDelete = wrapped.id;
                setTimeout(() => {
                    this.publishDeletionEvent(eventIdToDelete);
                }, 600000); // 10 minutes
            }

            // Show locally
            const conversationKey = this.getPMConversationKey(recipientPubkey);
            if (!this.pmMessages.has(conversationKey)) this.pmMessages.set(conversationKey, []);
            this.pmMessages.get(conversationKey).push({
                id: wrapped.id,
                author: this.nym,
                pubkey: this.pubkey,
                content,
                timestamp: new Date(),
                isOwn: true,
                isPM: true,
                conversationKey,
                conversationPubkey: recipientPubkey,
                eventKind: 1059,
                bitchatMessageId,  // For tracking Bitchat delivery/read receipts
                nymMessageId: useBitchatFormat ? null : nymMessageId,  // For tracking NYM delivery/read receipts
                deliveryStatus: 'sent'  // sent -> delivered -> read
            });

            this.addPMConversation(this.getNymFromPubkey(recipientPubkey), recipientPubkey, Date.now());
            this.movePMToTop(recipientPubkey);

            if (this.inPMMode && this.currentPM === recipientPubkey) {
                this.displayMessage(this.pmMessages.get(conversationKey).slice(-1)[0]);
            }
            return true;
        }

        // Extension-only path (seal via extension, wrap locally)
        if (window.nostr?.nip44?.encrypt && window.nostr?.signEvent) {
            const NT = window.NostrTools;

            rumor.id = NT.getEventHash(rumor);

            // Seal (kind 13) signed by identity in extension
            const sealContent = await window.nostr.nip44.encrypt(recipientPubkey, JSON.stringify(rumor));
            const sealUnsigned = {
                kind: 13, content: sealContent, created_at: this.randomNow(), tags: []
            };
            const seal = await window.nostr.signEvent(sealUnsigned);

            // GiftWrap (kind 1059) with local ephemeral
            const ephSk = NT.generateSecretKey();
            const ckWrap = NT.nip44.getConversationKey(ephSk, recipientPubkey);
            const wrapContent = NT.nip44.encrypt(JSON.stringify(seal), ckWrap);
            const wrapUnsigned = {
                kind: 1059,
                content: wrapContent,
                created_at: this.randomNow(),
                tags: [['p', recipientPubkey]]
            };

            // Add expiration only if enabled
            if (expirationTs) {
                wrapUnsigned.tags.push(['expiration', String(expirationTs)]);
            }

            const wrapped = NT.finalizeEvent(wrapUnsigned, ephSk);

            this.sendToRelay(['EVENT', wrapped]);

            // Schedule deletion if redacted cosmetic is active
            if (this.activeCosmetics && this.activeCosmetics.has('cosmetic-redacted')) {
                const eventIdToDelete = wrapped.id;
                setTimeout(() => {
                    this.publishDeletionEvent(eventIdToDelete);
                }, 600000); // 10 minutes
            }

            // Show locally
            const conversationKey = this.getPMConversationKey(recipientPubkey);
            if (!this.pmMessages.has(conversationKey)) this.pmMessages.set(conversationKey, []);
            this.pmMessages.get(conversationKey).push({
                id: wrapped.id,
                author: this.nym,
                pubkey: this.pubkey,
                content,
                timestamp: new Date(),
                isOwn: true,
                isPM: true,
                conversationKey,
                conversationPubkey: recipientPubkey,
                eventKind: 1059,
                nymMessageId,  // For tracking NYM delivery/read receipts
                deliveryStatus: 'sent'  // sent -> delivered -> read
            });

            this.addPMConversation(this.getNymFromPubkey(recipientPubkey), recipientPubkey, Date.now());
            this.movePMToTop(recipientPubkey);

            if (this.inPMMode && this.currentPM === recipientPubkey) {
                this.displayMessage(this.pmMessages.get(conversationKey).slice(-1)[0]);
            }
            return true;
        }

        throw new Error('No signing/encryption available for NIP-17 (need local privkey or extension)');
    }

    // Receive NIP-17 (GiftWrap 1059): unwrap, verify, store
    async handleGiftWrapDM(event) {
        try {
            const NT = window.NostrTools;

            // Process only gift wraps addressed to me
            if (this.pubkey) {
                const wrapRecipients = [];
                for (const t of event.tags || []) {
                    if (Array.isArray(t) && t[0] === 'p' && typeof t[1] === 'string') {
                        wrapRecipients.push(t[1]);
                    }
                }
                if (wrapRecipients.length > 0 && !wrapRecipients.includes(this.pubkey)) {
                    return; // not for me
                }
            }

            // Early deduplication - check before expensive decryption
            if (this.processedPMEventIds.has(event.id)) {
                return; // Already processed this event
            }
            this.processedPMEventIds.add(event.id);

            // Update lastPMSyncTime to track newest received PM
            if (event.created_at && event.created_at > this.lastPMSyncTime) {
                this.lastPMSyncTime = event.created_at;
            }

            // Limit Set size to prevent memory leaks (keep last 5000 events)
            if (this.processedPMEventIds.size > 5000) {
                const idsArray = Array.from(this.processedPMEventIds);
                this.processedPMEventIds = new Set(idsArray.slice(-2500));
            }

            // Bitchat uses XChaCha20-Poly1305 with HKDF key derivation
            // Format: v2: + base64url(nonce(24) || ciphertext || tag(16))
            // Key: HKDF(full compressed shared point 33 bytes, salt=empty, info="nip44-v2")
            const decryptBitchat = (content, senderPubkey) => {
                // Strip v2: prefix
                if (content.startsWith('v2:')) {
                    content = content.slice(3);
                }
                // Convert base64url to standard base64
                content = content.replace(/-/g, '+').replace(/_/g, '/');
                while (content.length % 4) content += '=';

                const payload = Uint8Array.from(atob(content), c => c.charCodeAt(0));
                const info = new TextEncoder().encode('nip44-v2');
                const nonce = payload.subarray(0, 24);
                const ciphertextWithTag = payload.subarray(24);

                // Bitchat tries both 02 (even Y) and 03 (odd Y) prefixes for x-only pubkeys
                for (const prefix of ['02', '03']) {
                    try {
                        const sharedPoint = NT._secp256k1.getSharedSecret(this.privkey, prefix + senderPubkey);

                        // Method 5: Full compressed point (33 bytes) -> HKDF
                        const prk = NT._hkdfExtract(NT._sha256, sharedPoint, new Uint8Array(0));
                        const key = NT._hkdfExpand(NT._sha256, prk, info, 32);

                        const plaintext = NT._xchacha20poly1305(key, nonce).decrypt(ciphertextWithTag);
                        return new TextDecoder().decode(plaintext);
                    } catch (e) {
                        // Try other prefix
                    }
                }

                throw new Error('Bitchat decryption failed');
            };

            // Parse Bitchat message format: bitchat1:<base64url payload>
            // Returns { type, content } where type is NoisePayloadType
            // NoisePayloadType: 0x01=PRIVATE_MESSAGE, 0x02=READ_RECEIPT, 0x03=DELIVERED
            const parseBitchatMessage = (content) => {
                if (!content.startsWith('bitchat1:')) {
                    return { type: 0x01, content }; // Not bitchat format, treat as message
                }

                try {
                    // Strip prefix and decode base64url
                    let b64 = content.slice(9); // Remove 'bitchat1:'
                    b64 = b64.replace(/-/g, '+').replace(/_/g, '/');
                    while (b64.length % 4) b64 += '=';

                    const bytes = Uint8Array.from(atob(b64), c => c.charCodeAt(0));

                    // Parse BitchatPacket header to find NoisePayloadType
                    // Header: version(1) + type(1) + TTL(1) + timestamp(8) + flags(1) + payloadLen(2) = 14 bytes
                    // Then: senderID(8) + recipientID(8 if HAS_RECIPIENT) + payload
                    const flags = bytes[11];
                    const hasRecipient = (flags & 0x01) !== 0;
                    const payloadStart = 14 + 8 + (hasRecipient ? 8 : 0); // header + senderID + recipientID?

                    const noisePayloadType = bytes[payloadStart];

                    // For receipts (READ_RECEIPT=0x02, DELIVERED=0x03), extract messageId
                    // Bitchat sends receipts as: [NoisePayloadType][raw messageId string] (no TLV!)
                    if (noisePayloadType !== 0x01) {
                        let pos = payloadStart + 1;
                        let end = bytes.length;
                        while (end > 0 && bytes[end - 1] === 0xBE) end--;

                        let messageId = null;
                        // Check if it's TLV format (starts with 0x00) or raw string
                        if (pos < end && bytes[pos] === 0x00 && pos + 2 < end) {
                            // TLV format: [0x00][len][messageID]
                            const idLen = bytes[pos + 1];
                            if (pos + 2 + idLen <= end) {
                                try {
                                    messageId = new TextDecoder().decode(bytes.subarray(pos + 2, pos + 2 + idLen));
                                } catch (e) { }
                            }
                        } else {
                            // Raw string format (Bitchat sends UUIDs directly)
                            // UUID format: 8-4-4-4-12 = 36 chars (e.g., "07DFE7B7-151D-40D8-BA38-B93...")
                            try {
                                const rawBytes = bytes.subarray(pos, Math.min(pos + 36, end));
                                messageId = new TextDecoder().decode(rawBytes);
                                // Validate it looks like a UUID
                                if (!/^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i.test(messageId)) {
                                    messageId = null;
                                }
                            } catch (e) { }
                        }
                        return { type: noisePayloadType, content: null, messageId };
                    }

                    // For PRIVATE_MESSAGE, extract the content and messageId from TLV
                    // TLV format after NoisePayloadType: [0x00][len][messageID][0x01][len][content]
                    let pos = payloadStart + 1; // Skip NoisePayloadType byte
                    let messageContent = null;
                    let messageId = null;

                    // Strip trailing padding (0xBE bytes) for bounds checking
                    let end = bytes.length;
                    while (end > 0 && bytes[end - 1] === 0xBE) end--;

                    // Parse TLV fields
                    while (pos < end - 2) {
                        const fieldType = bytes[pos];
                        const fieldLen = bytes[pos + 1];
                        if (pos + 2 + fieldLen > end) break;

                        if (fieldType === 0x00) { // MESSAGE_ID field
                            try {
                                messageId = new TextDecoder().decode(bytes.subarray(pos + 2, pos + 2 + fieldLen));
                            } catch (e) { }
                        } else if (fieldType === 0x01) { // CONTENT field
                            try {
                                messageContent = new TextDecoder().decode(bytes.subarray(pos + 2, pos + 2 + fieldLen));
                            } catch (e) { }
                        }
                        pos += 2 + fieldLen;
                    }

                    return { type: noisePayloadType, content: messageContent || '', messageId };
                } catch (e) {
                    return { type: 0x01, content };
                }
            };

            // Check if content is Bitchat format (v2: prefix)
            const isBitchatFormat = (content) => content.startsWith('v2:');

            // Unwrap local privkey path
            const unwrapWithLocal = () => {
                let sealJson, seal, rumorJson, rumor;

                if (isBitchatFormat(event.content)) {
                    // Bitchat raw XChaCha20-Poly1305 format
                    sealJson = decryptBitchat(event.content, event.pubkey);
                    seal = JSON.parse(sealJson);

                    if (isBitchatFormat(seal.content)) {
                        rumorJson = decryptBitchat(seal.content, seal.pubkey);
                    } else {
                        const ckSeal = NT.nip44.getConversationKey(this.privkey, seal.pubkey);
                        rumorJson = NT.nip44.decrypt(seal.content, ckSeal);
                    }
                    rumor = JSON.parse(rumorJson);
                } else {
                    // Standard NIP-44 format
                    const ckWrap = NT.nip44.getConversationKey(this.privkey, event.pubkey);
                    sealJson = NT.nip44.decrypt(event.content, ckWrap);
                    seal = JSON.parse(sealJson);

                    const ckSeal = NT.nip44.getConversationKey(this.privkey, seal.pubkey);
                    rumorJson = NT.nip44.decrypt(seal.content, ckSeal);
                    rumor = JSON.parse(rumorJson);
                }

                return { seal, rumor };
            };

            // Unwrap extension-only path (only works for standard NIP-44, not Bitchat)
            const unwrapWithExtension = async () => {
                // Extensions can't do raw ECDH, so Bitchat format won't work
                if (isBitchatFormat(event.content)) {
                    throw new Error('Bitchat format requires local key');
                }

                const sealJson = await window.nostr.nip44.decrypt(event.pubkey, event.content);
                const seal = JSON.parse(sealJson);

                const rumorJson = await window.nostr.nip44.decrypt(seal.pubkey, seal.content);
                const rumor = JSON.parse(rumorJson);

                return { seal, rumor };
            };

            let seal, rumor;
            if (this.privkey) {
                ({ seal, rumor } = unwrapWithLocal());
            } else if (window.nostr?.nip44?.decrypt) {
                ({ seal, rumor } = await unwrapWithExtension());
            } else {
                return; // no way to decrypt
            }

            // Validate rumor and identity
            // Accept kind 14 (DM), kind 15 (file), and kind 69420 (NYM receipt)
            if (!rumor || (rumor.kind !== 14 && rumor.kind !== 15 && rumor.kind !== 69420)) {
                return;
            }
            if (typeof rumor.content !== 'string') {
                return;
            }
            // Note: Bitchat uses ephemeral key for seal, so seal.pubkey may differ from rumor.pubkey
            // We only require rumor.pubkey to be present (the actual sender identity)
            if (!rumor.pubkey) {
                return;
            }

            const senderPubkey = rumor.pubkey;
            const isOwn = !!this.pubkey && senderPubkey === this.pubkey;

            // Track if this user uses Bitchat format (for replies)
            const isBitchatUser = isBitchatFormat(event.content) || rumor.content?.startsWith('bitchat1:');
            if (isBitchatUser && !isOwn) {
                this.bitchatUsers.add(senderPubkey);
            }

            // Track if this user uses NYM format with delivery receipts (has 'x' tag)
            const isNymUser = this.isNymMessage(rumor) || this.isNymReceipt(rumor);
            if (isNymUser && !isOwn) {
                this.nymUsers.add(senderPubkey);
            }

            // Fetch profile for any PM sender we don't have (await to get nickname)
            if (!isOwn && !this.users.has(senderPubkey)) {
                await this.fetchProfileDirect(senderPubkey);
            }

            // Determine the peer for the conversation
            const rumorPTags = (rumor.tags || []).filter(t => Array.isArray(t) && t[0] === 'p' && typeof t[1] === 'string').map(t => t[1]);
            let peerPubkey = null;
            if (isOwn) {
                peerPubkey = rumorPTags.find(pk => pk !== this.pubkey) || rumorPTags[0] || null;
            } else {
                peerPubkey = senderPubkey;
            }
            if (!peerPubkey) return; // can't place the message without a peer

            const conversationKey = this.getPMConversationKey(peerPubkey);
            if (!this.pmMessages.has(conversationKey)) this.pmMessages.set(conversationKey, []);

            // Deduplicate within the correct conversation
            const list = this.pmMessages.get(conversationKey);
            if (list.some(m => m.id === event.id)) return;

            const tsSec = rumor.created_at || Math.floor(Date.now() / 1000);

            // Handle NYM delivery/read receipts (tag-based format)
            if (this.isNymReceipt(rumor)) {
                const nymReceipt = this.parseNymReceipt(rumor);
                if (nymReceipt && nymReceipt.messageId) {
                    const receiptId = nymReceipt.messageId.toUpperCase();
                    const receiptType = nymReceipt.receiptType;

                    for (const [convKey, messages] of this.pmMessages) {
                        const msg = messages.find(m => m.nymMessageId?.toUpperCase() === receiptId);
                        if (msg && msg.isOwn) {
                            const statusOrder = { sent: 0, delivered: 1, read: 2 };
                            if ((statusOrder[receiptType] || 0) >= (statusOrder[msg.deliveryStatus] || 0)) {
                                msg.deliveryStatus = receiptType;
                                // Update in-place without re-rendering to avoid flicker
                                const msgEl = document.querySelector(`[data-message-id="${msg.id}"]`);
                                if (msgEl) {
                                    let statusEl = msgEl.querySelector('.delivery-status');
                                    if (!statusEl) {
                                        statusEl = document.createElement('span');
                                        msgEl.appendChild(statusEl);
                                    }
                                    statusEl.className = `delivery-status ${receiptType}`;
                                    statusEl.title = receiptType.charAt(0).toUpperCase() + receiptType.slice(1);
                                    statusEl.textContent = receiptType === 'read' ? '✓✓' : '✓';
                                }
                            }
                            break;
                        }
                    }
                }
                return;
            }

            // Parse bitchat1: format if present to extract actual message
            const parsed = parseBitchatMessage(rumor.content);

            // Handle Bitchat delivery receipts (0x03) and read receipts (0x02)
            if (parsed.type === 0x02 || parsed.type === 0x03) {
                const receiptType = parsed.type === 0x02 ? 'read' : 'delivered';
                const receiptId = parsed.messageId?.toUpperCase();

                if (receiptId) {
                    for (const [convKey, messages] of this.pmMessages) {
                        const msg = messages.find(m => m.bitchatMessageId?.toUpperCase() === receiptId);
                        if (msg && msg.isOwn) {
                            const statusOrder = { sent: 0, delivered: 1, read: 2 };
                            if ((statusOrder[receiptType] || 0) >= (statusOrder[msg.deliveryStatus] || 0)) {
                                msg.deliveryStatus = receiptType;
                                // Update in-place without re-rendering to avoid flicker
                                const msgEl = document.querySelector(`[data-message-id="${msg.id}"]`);
                                if (msgEl) {
                                    let statusEl = msgEl.querySelector('.delivery-status');
                                    if (!statusEl) {
                                        statusEl = document.createElement('span');
                                        msgEl.appendChild(statusEl);
                                    }
                                    statusEl.className = `delivery-status ${receiptType}`;
                                    statusEl.title = receiptType.charAt(0).toUpperCase() + receiptType.slice(1);
                                    statusEl.textContent = receiptType === 'read' ? '✓✓' : '✓';
                                }
                            }
                            break;
                        }
                    }
                }
                return;
            }

            if (parsed.type !== 0x01) return;

            const messageContent = parsed.content;

            // Get sender name from kind 0 profile (not from rumor tags)
            const senderName = this.getNymFromPubkey(senderPubkey);

            // Extract NYM message ID from rumor tags
            const nymMsgId = this.getNymMessageId(rumor);

            const msg = {
                id: event.id,                                  // keep outer id for reactions/zaps
                author: isOwn ? this.nym : senderName,
                pubkey: senderPubkey,
                content: messageContent,
                timestamp: new Date(tsSec * 1000),
                isOwn,
                isPM: true,
                conversationKey,
                conversationPubkey: peerPubkey,
                eventKind: 1059,
                isHistorical: (Date.now() / 1000 - tsSec) > 10,
                bitchatMessageId: parsed.messageId,  // For sending Bitchat read receipts
                nymMessageId: nymMsgId  // For sending NYM read receipts
            };

            list.push(msg);
            list.sort((a, b) => a.timestamp - b.timestamp);
            this.pmMessages.set(conversationKey, list);

            // Send DELIVERED receipt back to Bitchat user
            if (!isOwn && parsed.messageId && this.bitchatUsers.has(senderPubkey)) {
                this.sendBitchatReceipt(parsed.messageId, 0x03, senderPubkey); // 0x03 = DELIVERED
            }

            // Send DELIVERED receipt back to NYM user
            if (!isOwn && nymMsgId && this.nymUsers.has(senderPubkey)) {
                this.sendNymReceipt(nymMsgId, 'delivered', senderPubkey);
            }

            // Use sender's profile name for conversation
            const peerName = this.getNymFromPubkey(peerPubkey);
            this.addPMConversation(peerName, peerPubkey, tsSec * 1000);
            this.movePMToTop(peerPubkey);

            if (this.inPMMode && this.currentPM === peerPubkey) {
                this.displayMessage(msg);
                // Send READ receipt if viewing the conversation
                if (!isOwn && parsed.messageId && this.bitchatUsers.has(senderPubkey)) {
                    this.sendBitchatReceipt(parsed.messageId, 0x02, senderPubkey); // 0x02 = READ
                }
                // Send READ receipt for NYM users
                if (!isOwn && nymMsgId && this.nymUsers.has(senderPubkey)) {
                    this.sendNymReceipt(nymMsgId, 'read', senderPubkey);
                }
            } else if (!msg.isHistorical && !isOwn) {
                // Only notify for messages from others
                this.updateUnreadCount(conversationKey);
                this.showNotification(`PM from ${msg.author}`, messageContent, {
                    type: 'pm',
                    nym: msg.author,
                    pubkey: peerPubkey,   // open the correct thread
                    id: conversationKey
                });
            }
        } catch (err) {
            // Log decryption failures for debugging
        }
    }

    getPMConversationKey(otherPubkey) {
        // Create a unique key for this PM conversation between two users
        const keys = [this.pubkey, otherPubkey].sort();
        return `pm-${keys.join('-')}`;
    }

    async sendPM(content, recipientPubkey) {
        try {
            if (!this.connected) throw new Error('Not connected to relay');

            const wrapped = await this.sendNIP17PM(content, recipientPubkey);
            return !!wrapped;
        } catch (error) {
            this.displaySystemMessage('Failed to send PM: ' + error.message);
            return false;
        }
    }

    movePMToTop(pubkey) {
        const pmList = document.getElementById('pmList');
        const pmItem = pmList.querySelector(`[data-pubkey="${pubkey}"]`);

        if (pmItem) {
            // Update the timestamp
            const now = Date.now();
            pmItem.dataset.lastMessageTime = now;

            // Update in memory
            const conversation = this.pmConversations.get(pubkey);
            if (conversation) {
                conversation.lastMessageTime = now;
            }

            // Remove and re-insert in correct order
            pmItem.remove();
            this.insertPMInOrder(pmItem, pmList);
        }
    }

    reorderPMs() {
        const pmList = document.getElementById('pmList');
        const items = Array.from(pmList.querySelectorAll('.pm-item'));

        // Sort by timestamp (most recent first)
        items.sort((a, b) => {
            const timeA = parseInt(a.dataset.lastMessageTime || '0');
            const timeB = parseInt(b.dataset.lastMessageTime || '0');
            return timeB - timeA;
        });

        // Clear and re-append in order
        pmList.innerHTML = '';
        items.forEach(item => pmList.appendChild(item));

        // Re-add/update view more button
        this.updateViewMoreButton('pmList');
    }

    requestUserProfile(pubkey) {
        try {
            // Use the batched profile fetching system
            this.fetchProfileFromRelay(pubkey);
        } catch (_) { }
    }

    // Direct profile fetch for PM senders - uses sendToRelay and existing kind 0 handler
    async fetchProfileDirect(pubkey) {
        const subId = 'pm-profile-' + Math.random().toString(36).slice(2);
        const req = ["REQ", subId, { kinds: [0], authors: [pubkey], limit: 1 }];

        try { this.sendToRelay(req); } catch (_) { }

        // Wait for the main handleRelayMessage kind 0 handler to process response
        await new Promise(resolve => setTimeout(resolve, 1500));

        try { this.sendToRelay(["CLOSE", subId]); } catch (_) { }
    }

    updatePMNicknameFromProfile(pubkey, profileName) {
        if (!profileName) return;
        const clean = this.parseNymFromDisplay(profileName).substring(0, 20);

        // Update memory
        if (this.pmConversations.has(pubkey)) {
            this.pmConversations.get(pubkey).nym = clean;
        }

        // Update sidebar DOM item if present
        const item = document.querySelector(`.pm-item[data-pubkey="${pubkey}"]`);
        if (item) {
            const suffix = this.getPubkeySuffix(pubkey);
            const verifiedBadge = this.isVerifiedDeveloper(pubkey)
                ? `<span class="verified-badge" title="${this.verifiedDeveloper.title}">✓</span>`
                : '';
            const pmNameEl = item.querySelector('.pm-name');
            if (pmNameEl) {
                pmNameEl.innerHTML = `@${this.escapeHtml(clean)}<span class="nym-suffix">#${suffix}</span> ${verifiedBadge}`;
            }
        }

        // Update displayed messages from this user
        const suffix = this.getPubkeySuffix(pubkey);
        const verifiedBadge = this.isVerifiedDeveloper(pubkey)
            ? `<span class="verified-badge" title="${this.verifiedDeveloper.title}">✓</span>`
            : '';
        const flairHtml = this.getFlairForUser(pubkey);
        document.querySelectorAll(`.message[data-pubkey="${pubkey}"] .message-author`).forEach(el => {
            el.innerHTML = `${this.escapeHtml(clean)}<span class="nym-suffix">#${suffix}</span>${verifiedBadge}${flairHtml}:`;
        });

        // Update any visible notification banner from this user
        const notif = document.querySelector(`.notification[data-pubkey="${pubkey}"] .notification-title`);
        if (notif) {
            notif.textContent = `PM from ${clean}#${suffix}`;
        }
    }

    addPMConversation(nym, pubkey, timestamp = Date.now()) {
        // Prefer known profile name if available
        let baseNym = this.users.has(pubkey)
            ? this.parseNymFromDisplay(this.users.get(pubkey).nym)
            : this.parseNymFromDisplay(nym);

        if (!this.pmConversations.has(pubkey)) {
            this.pmConversations.set(pubkey, {
                nym: baseNym,
                lastMessageTime: timestamp
            });

            const pmList = document.getElementById('pmList');
            const item = document.createElement('div');
            item.className = 'pm-item list-item';
            item.dataset.pubkey = pubkey;
            item.dataset.lastMessageTime = timestamp;

            const suffix = this.getPubkeySuffix(pubkey);
            const verifiedBadge = this.isVerifiedDeveloper(pubkey)
                ? `<span class="verified-badge" title="${this.verifiedDeveloper.title}">✓</span>`
                : '';

            // Get user's shop items for flair
            const userShopItems = this.getUserShopItems(pubkey);
            const flairHtml = this.getFlairForUser(pubkey);

            // Clean the base nym of any HTML for display
            const cleanBaseNym = this.parseNymFromDisplay(baseNym);

            item.innerHTML = `
<span class="pm-name">@${this.escapeHtml(cleanBaseNym)}<span class="nym-suffix">#${suffix}</span>${flairHtml} ${verifiedBadge}</span>
<div class="channel-badges">
<span class="pm-badge">PM</span>
<span class="delete-pm" onclick="event.stopPropagation(); nym.deletePM('${pubkey}')">✕</span>
<span class="unread-badge" style="display:none">0</span>
</div>
`;
            item.onclick = () => this.openPM(cleanBaseNym, pubkey);

            this.insertPMInOrder(item, pmList);
            this.updateViewMoreButton('pmList');

            // Proactively request their profile
            if (!this.users.has(pubkey) || /^anon$/i.test(cleanBaseNym)) {
                this.requestUserProfile(pubkey);
            }
        }
    }

    insertPMInOrder(newItem, pmList) {
        const newTime = parseInt(newItem.dataset.lastMessageTime);
        const existingItems = Array.from(pmList.querySelectorAll('.pm-item'));
        const viewMoreBtn = pmList.querySelector('.view-more-btn');

        // Find the correct position to insert (most recent first)
        let insertBefore = null;
        for (const item of existingItems) {
            const itemTime = parseInt(item.dataset.lastMessageTime || '0');
            if (newTime > itemTime) {
                insertBefore = item;
                break;
            }
        }

        // If we found a position, insert there
        if (insertBefore) {
            pmList.insertBefore(newItem, insertBefore);
        } else if (viewMoreBtn) {
            // If no position found but there's a view more button, insert before it
            pmList.insertBefore(newItem, viewMoreBtn);
        } else {
            // Otherwise append to the end
            pmList.appendChild(newItem);
        }
    }

    deletePM(pubkey) {
        if (confirm('Delete this PM conversation?')) {
            // Remove from conversations
            this.pmConversations.delete(pubkey);

            // Remove messages
            const conversationKey = this.getPMConversationKey(pubkey);
            this.pmMessages.delete(conversationKey);

            // Remove from UI
            const item = document.querySelector(`[data-pubkey="${pubkey}"]`);
            if (item) item.remove();

            // If currently viewing this PM, switch to bar
            if (this.inPMMode && this.currentPM === pubkey) {
                this.switchChannel('bar', '');
            }

            this.displaySystemMessage('PM conversation deleted');
        }
    }

    openPM(nym, pubkey) {
        this.inPMMode = true;
        this.currentPM = pubkey;
        this.currentChannel = null;
        this.currentGeohash = null;

        // Format the nym with pubkey suffix for display
        const known = this.users.get(pubkey);
        const baseNym = known ? this.parseNymFromDisplay(known.nym) : this.parseNymFromDisplay(nym);
        const suffix = this.getPubkeySuffix(pubkey);
        const displayNym = `${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>`;
        document.getElementById('currentChannel').innerHTML = `@${displayNym} <span style="font-size: 12px; color: var(--text-dim);">(PM)</span>`;

        // Update UI with formatted nym
        document.getElementById('currentChannel').innerHTML = `@${displayNym} <span style="font-size: 12px; color: var(--text-dim);">(PM)</span>`;
        document.getElementById('channelMeta').textContent = 'Private message';

        // Hide share button in PM mode
        const shareBtn = document.getElementById('shareChannelBtn');
        if (shareBtn) {
            shareBtn.style.display = 'none';
        }

        // Update active states
        document.querySelectorAll('.channel-item').forEach(item => {
            item.classList.remove('active');
        });
        document.querySelectorAll('.pm-item').forEach(item => {
            item.classList.toggle('active', item.dataset.pubkey === pubkey);
        });

        // Clear unread count
        const conversationKey = this.getPMConversationKey(pubkey);
        this.clearUnreadCount(conversationKey);

        // Load PM messages
        this.loadPMMessages(conversationKey);

        // Send READ receipts for all unread messages from this peer
        const pmMsgs = this.pmMessages.get(conversationKey) || [];
        for (const msg of pmMsgs) {
            if (!msg.isOwn) {
                // Send Bitchat READ receipt if applicable
                if (msg.bitchatMessageId && this.bitchatUsers.has(msg.pubkey)) {
                    this.sendBitchatReceipt(msg.bitchatMessageId, 0x02, msg.pubkey);
                }
                // Send NYM READ receipt if applicable
                if (msg.nymMessageId && this.nymUsers.has(msg.pubkey)) {
                    this.sendNymReceipt(msg.nymMessageId, 'read', msg.pubkey);
                }
            }
        }

        // Close mobile sidebar on mobile
        if (window.innerWidth <= 768) {
            this.closeSidebar();
        }
    }

    loadPMMessages(conversationKey) {
        const container = document.getElementById('messagesContainer');
        container.innerHTML = '';

        let pmMessages = this.pmMessages.get(conversationKey) || [];

        // Limit PM messages to prevent memory issues
        const maxPMMessages = 500;
        const originalCount = pmMessages.length;

        // If we have too many messages, prune the stored array
        if (pmMessages.length > maxPMMessages) {
            // Keep only the most recent messages
            pmMessages = pmMessages.slice(-maxPMMessages);
            // Update the stored messages
            this.pmMessages.set(conversationKey, pmMessages);
        }

        // Filter messages that are part of this specific conversation
        const filteredMessages = pmMessages.filter(msg => {
            // Check if message is from blocked user
            if (this.blockedUsers.has(msg.author) || msg.blocked) {
                return false;
            }

            // Check if message content is spam
            if (this.isSpamMessage(msg.content)) {
                return false;
            }

            // Ensure the message is between the current user and the PM recipient only
            return msg.conversationKey === conversationKey &&
                (msg.pubkey === this.pubkey || msg.pubkey === this.currentPM);
        });

        // Sort messages by timestamp
        filteredMessages.sort((a, b) => a.timestamp - b.timestamp);

        // If we pruned messages, show a notice
        if (originalCount > maxPMMessages) {
            const loadMoreDiv = document.createElement('div');
            loadMoreDiv.className = 'system-message';
            loadMoreDiv.style.cssText = 'cursor: pointer; color: var(--text-dim); font-size: 12px;';
            loadMoreDiv.textContent = `Showing most recent ${maxPMMessages} messages (${originalCount - maxPMMessages} older messages hidden for performance)`;
            container.appendChild(loadMoreDiv);
        }

        // Display only these filtered messages
        filteredMessages.forEach(msg => {
            // Double-check this is a PM before displaying
            if (msg.isPM && msg.conversationKey === conversationKey) {
                // Use displayMessage to properly handle reactions
                this.displayMessage(msg);
            }
        });

        if (filteredMessages.length === 0) {
            this.displaySystemMessage('Start of private message');
        }

        // Scroll to bottom
        if (this.settings.autoscroll) {
            // Use setTimeout to ensure DOM has updated
            setTimeout(() => {
                container.scrollTop = container.scrollHeight;
            }, 0);
        }
    }

    openUserPM(nym, pubkey) {
        // Don't open PM with yourself
        if (pubkey === this.pubkey) {
            this.displaySystemMessage("You can't send private messages to yourself");
            return;
        }

        // Extract base nym if it has a suffix
        const baseNym = nym.split('#')[0] || nym;

        // Add to PM conversations if not exists
        this.addPMConversation(baseNym, pubkey);
        // Open the PM
        this.openPM(baseNym, pubkey);
    }

    isMentioned(content) {
        if (!content || !this.nym) return false;

        // Strip HTML from nym for comparison
        const cleanNym = this.parseNymFromDisplay(this.nym);

        // Create pattern that matches the clean nym with optional suffix
        const nymPattern = new RegExp(`@${cleanNym}(#[0-9a-f]{4})?\\b`, 'gi');

        // Strip HTML from content for mention detection
        const cleanContent = content.replace(/<[^>]*>/g, '');

        return nymPattern.test(cleanContent);
    }

    async generateKeypair() {
        try {
            // Generate ephemeral keys using nostr-tools bundle functions
            const sk = window.NostrTools.generateSecretKey();
            const pk = window.NostrTools.getPublicKey(sk);

            this.privkey = sk;
            this.pubkey = pk;


            return { privkey: sk, pubkey: pk };
        } catch (error) {
            throw error;
        }
    }

    async useExtension() {
        if (!window.nostr) {
            throw new Error('No Nostr extension detected. Please install Alby or nos2x.');
        }

        try {
            const pk = await window.nostr.getPublicKey();
            this.pubkey = pk;
            this.usingExtension = true;

            // Queue profile fetch - will be processed after relay connection
            // Don't await here to avoid 3-second timeout when not connected
            this.fetchProfileFromRelay(pk);

            return { pubkey: pk };
        } catch (error) {
            throw new Error('Failed to connect to Nostr extension');
        }
    }

    async useNostrConnect(bunkerUri) {
        try {
            this.nostrConnect = new NostrConnectClient();

            const remotePubkey = await this.nostrConnect.connect(bunkerUri);
            this.pubkey = remotePubkey;
            this.usingNostrConnect = true;

            // Queue profile fetch - will be processed after relay connection
            // Don't await here to avoid 3-second timeout when not connected
            this.fetchProfileFromRelay(remotePubkey);

            return { pubkey: remotePubkey };

        } catch (error) {
            throw error;
        }
    }

    async signEvent(event) {
        if (this.usingNostrConnect && this.nostrConnect) {
            return await this.nostrConnect.signEvent(event);
        } else if (this.connectionMode === 'extension' && window.nostr) {
            return await window.nostr.signEvent(event);
        } else if (this.privkey) {
            return window.NostrTools.finalizeEvent(event, this.privkey);
        } else {
            throw new Error('No signing method available');
        }
    }

    async fetchProfileFromRelay(pubkey) {
        return new Promise((resolve) => {
            // Add to queue
            this.profileFetchQueue.push({ pubkey, resolve });

            // Clear existing timer
            if (this.profileFetchTimer) {
                clearTimeout(this.profileFetchTimer);
            }

            // Set timer to process batch
            this.profileFetchTimer = setTimeout(() => {
                this.processBatchedProfileFetch();
            }, this.profileFetchBatchDelay);
        });
    }

    processBatchedProfileFetch() {
        if (this.profileFetchQueue.length === 0) return;

        // Get unique pubkeys and their resolvers
        const batch = this.profileFetchQueue;
        this.profileFetchQueue = [];
        this.profileFetchTimer = null;

        const pubkeyMap = new Map();
        batch.forEach(({ pubkey, resolve }) => {
            if (!pubkeyMap.has(pubkey)) {
                pubkeyMap.set(pubkey, []);
            }
            pubkeyMap.get(pubkey).push(resolve);
        });

        const pubkeys = Array.from(pubkeyMap.keys());
        const resolvers = pubkeyMap;

        // Fetch profiles for pubkeys

        const timeout = setTimeout(() => {
            resolvers.forEach(resolveList => {
                resolveList.forEach(resolve => resolve());
            });
        }, 3000);

        const subId = "profile-batch-" + Math.random().toString(36).substring(7);
        const originalHandler = this.handleRelayMessage.bind(this);
        const foundPubkeys = new Set();

        this.handleRelayMessage = (msg) => {
            if (!Array.isArray(msg)) return;

            const [type, ...data] = msg;

            if (type === 'EVENT' && data[0] === subId) {
                const event = data[1];
                if (event && event.kind === 0 && resolvers.has(event.pubkey)) {
                    foundPubkeys.add(event.pubkey);

                    try {
                        const profile = JSON.parse(event.content);

                        // Store complete original profile for non-ephemeral connections
                        if (event.pubkey === this.pubkey && this.connectionMode !== 'ephemeral') {
                            this.originalProfile = profile;
                        }

                        // Get name for own profile
                        if (event.pubkey === this.pubkey && (profile.name || profile.username || profile.display_name)) {
                            const profileName = profile.name || profile.username || profile.display_name;
                            this.nym = profileName.substring(0, 20);
                            document.getElementById('currentNym').textContent = this.nym;
                        }

                        // Store and update for OTHER users (Bitchat users, PM contacts)
                        if (event.pubkey !== this.pubkey && (profile.name || profile.username || profile.display_name)) {
                            const profileName = (profile.name || profile.username || profile.display_name).substring(0, 20);
                            // Store in users map
                            if (!this.users.has(event.pubkey) || this.users.get(event.pubkey).nym.startsWith('anon')) {
                                this.users.set(event.pubkey, {
                                    nym: profileName,
                                    pubkey: event.pubkey,
                                    lastSeen: 0,
                                    status: 'online',
                                    channels: new Set()
                                });
                            }
                            // Update PM nickname displays
                            this.updatePMNicknameFromProfile(event.pubkey, profileName);
                        }

                        // Get lightning address
                        if (event.pubkey === this.pubkey && (profile.lud16 || profile.lud06)) {
                            const lnAddress = profile.lud16 || profile.lud06;
                            this.lightningAddress = lnAddress;
                            localStorage.setItem(`nym_lightning_address_${this.pubkey}`, lnAddress);
                            this.updateLightningAddressDisplay();
                        }
                    } catch (e) {
                    }

                    // Resolve all promises for this pubkey
                    const resolveList = resolvers.get(event.pubkey);
                    resolveList.forEach(resolve => resolve());
                    resolvers.delete(event.pubkey);
                }
            } else if (type === 'EOSE' && data[0] === subId) {
                clearTimeout(timeout);
                this.handleRelayMessage = originalHandler;

                // Resolve any remaining unfound profiles
                resolvers.forEach(resolveList => {
                    resolveList.forEach(resolve => resolve());
                });
            }

            originalHandler(msg);
        };

        const subscription = [
            "REQ",
            subId,
            {
                kinds: [0],
                authors: pubkeys, // Array of all pubkeys
                limit: pubkeys.length
            }
        ];

        if (this.connected) {
            this.sendToRelay(subscription);
            setTimeout(() => {
                this.sendToRelay(["CLOSE", subId]);
            }, 3500);
        } else {
            this.messageQueue.push(JSON.stringify(subscription));
        }
    }

    async publishMessage(content, channel = this.currentChannel, geohash = this.currentGeohash) {
        try {
            if (!this.connected) {
                throw new Error('Not connected to relay');
            }

            const tags = [
                ['n', this.nym]
            ];

            let kind;

            // Use appropriate kind and tags based on channel type
            if (geohash) {
                kind = 20000; // Geohash channels use kind 20000
                tags.push(['g', geohash]);
            } else {
                kind = 23333; // Standard channels use kind 23333
                tags.push(['d', channel]);
            }

            let event = {
                kind: kind,
                created_at: Math.floor(Date.now() / 1000),
                tags: tags,
                content: content,
                pubkey: this.pubkey
            };

            // Mine PoW if enabled (NIP-13)
            if (this.enablePow && this.powDifficulty > 0) {
                event = NostrTools.nip13.minePow(event, this.powDifficulty);
            }

            // Sign event (after mining PoW)
            const signedEvent = await this.signEvent(event);

            const optimisticMessage = {
                id: signedEvent.id, // Use the signed event ID
                content: content,
                author: this.nym,
                pubkey: this.pubkey,
                timestamp: new Date(signedEvent.created_at * 1000),
                channel: channel,
                geohash: geohash,
                isOwn: true,
                isHistorical: false,
                isPM: false,
                isCommunity: false
            };

            // Display immediately (optimistic)
            this.displayMessage(optimisticMessage);

            // Send to relay (async - UI already updated)
            this.sendToRelay(["EVENT", signedEvent]);

            // Schedule deletion if redacted cosmetic is active
            if (this.activeCosmetics && this.activeCosmetics.has('cosmetic-redacted')) {
                const eventIdToDelete = signedEvent.id;
                setTimeout(() => {
                    this.publishDeletionEvent(eventIdToDelete);
                }, 600000); // 10 minutes
            }

            return true;
        } catch (error) {
            this.displaySystemMessage('Failed to send message: ' + error.message);
            return false;
        }
    }

    async publishCommunityMessage(content, communityId) {
        try {

            if (!this.connected) {
                throw new Error('Not connected to relay');
            }

            const community = this.communityChannels.get(communityId);
            if (!community) {
                throw new Error('Community not found');
            }


            // CHECK IF USER IS BANNED
            if (this.communityBans.has(communityId) &&
                this.communityBans.get(communityId).has(this.pubkey)) {
                throw new Error('You are banned from this community');
            }

            // CHECK IF USER IS TEMPORARILY KICKED
            if (this.communityTemporaryKicks && this.communityTemporaryKicks.has(communityId)) {
                const kicks = this.communityTemporaryKicks.get(communityId);
                if (kicks.has(this.pubkey)) {
                    const kickExpiry = kicks.get(this.pubkey);
                    if (Date.now() < kickExpiry) {
                        const minutesLeft = Math.ceil((kickExpiry - Date.now()) / 60000);
                        throw new Error(`You are temporarily kicked from this community. Try again in ${minutesLeft} minute${minutesLeft !== 1 ? 's' : ''}.`);
                    } else {
                        // Kick expired, remove it
                        kicks.delete(this.pubkey);
                    }
                }
            }

            // Check if message contains blocked keywords
            if (this.hasCommunityBlockedKeyword(content, communityId)) {
                throw new Error('Message contains blocked keywords');
            }

            let event = {
                kind: 4550,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ['a', `34550:${community.admin}:${communityId}`],
                    ['n', this.nym]
                ],
                content: content,
                pubkey: this.pubkey
            };

            // Mine PoW if enabled (NIP-13)
            if (this.enablePow && this.powDifficulty > 0) {
                event = NostrTools.nip13.minePow(event, this.powDifficulty);
            }


            const signedEvent = await this.signEvent(event);


            const optimisticMessage = {
                id: signedEvent.id,
                content: content,
                author: this.nym,
                pubkey: this.pubkey,
                timestamp: new Date(signedEvent.created_at * 1000),
                communityId: communityId,
                isOwn: true,
                isHistorical: false,
                isPM: false,
                isCommunity: true
            };

            // Display immediately (optimistic)
            this.displayMessage(optimisticMessage);

            // Send to relay (async)
            this.sendToRelay(["EVENT", signedEvent]);

            // Schedule deletion if redacted cosmetic is active  
            if (this.activeCosmetics && this.activeCosmetics.has('cosmetic-redacted')) {
                const eventIdToDelete = signedEvent.id;
                setTimeout(() => {
                    this.publishDeletionEvent(eventIdToDelete);
                }, 600000); // 10 minutes
            }


            return true;
        } catch (error) {
            this.displaySystemMessage('Failed to send message: ' + error.message);
            return false;
        }
    }

    async publishDeletionEvent(eventId) {
        try {
            if (!this.connected) {
                return;
            }

            // Create kind 5 deletion event
            const event = {
                kind: 5,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ['e', eventId]
                ],
                content: 'Message redacted',
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(event);

            if (signedEvent) {
                this.sendToRelay(["EVENT", signedEvent]);
            }
        } catch (error) {
        }
    }

    async createChannel(channelName) {
        try {
            if (!this.connected) {
                throw new Error('Not connected to relay');
            }

            const event = {
                kind: 23333, // Channel creation/joining
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ['d', channelName],
                    ['relay', this.relayUrl], // Add relay tag
                    ['about', `Channel #${channelName} created via NYM`]
                ],
                content: JSON.stringify({
                    name: channelName,
                    about: `Channel #${channelName}`,
                    picture: ''
                }),
                pubkey: this.pubkey
            };

            // Sign event
            const signedEvent = await this.signEvent(event);

            // Send to relay
            this.sendToRelay(["EVENT", signedEvent]);

            return true;
        } catch (error) {
            return false;
        }
    }

    async createCommunityChannel(name, description, isPrivate = false, imageUrl = '') {
        try {
            if (!this.connected) {
                throw new Error('Not connected to relay');
            }

            if (this.connectionMode === 'ephemeral') {
                throw new Error('Community channels require a persistent identity (extension or nsec login)');
            }

            // Validate name - no spaces allowed
            if (name.includes(' ')) {
                throw new Error('Community names cannot contain spaces. Use hyphens instead (e.g., "my-community")');
            }

            // Generate unique community identifier with pubkey suffix
            const suffix = this.getPubkeySuffix(this.pubkey);
            const sanitizedName = this.sanitizeCommunityName(name);
            const communityId = `${sanitizedName}-${suffix}`;

            const event = {
                kind: 34550, // NIP-72 community definition
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ['d', communityId], // Unique identifier
                    ['name', name],
                    ['description', description || `Community ${name}`],
                    ['image', imageUrl || ''], // Community image
                    ['p', this.pubkey, '', 'admin']
                ],
                content: description || '',
                pubkey: this.pubkey
            };

            // Add privacy tag
            if (isPrivate) {
                event.tags.push(['private']);
            } else {
                event.tags.push(['public']);
            }

            // Sign event
            const signedEvent = await this.signEvent(event);

            // Send to relay
            this.sendToRelay(["EVENT", signedEvent]);

            // Store locally
            this.communityChannels.set(communityId, {
                name: name,
                description: description,
                imageUrl: imageUrl,
                isPrivate: isPrivate,
                admin: this.pubkey,
                createdAt: Date.now()
            });

            // Initialize collections
            if (!this.communityMembers.has(communityId)) {
                this.communityMembers.set(communityId, new Set([this.pubkey]));
            }
            if (!this.communityModerators.has(communityId)) {
                this.communityModerators.set(communityId, new Set());
            }

            this.ownedCommunities.add(communityId);

            // Add to UI as a COMMUNITY channel (not standard)
            this.addCommunityChannel(name, communityId, isPrivate);

            this.displaySystemMessage(`Created ${isPrivate ? 'private' : 'public'} community: ${name}`);
            this.displaySystemMessage(`Community ID: ${communityId}`);
            this.displaySystemMessage(`Use /communityinfo to see community details`);
            this.displaySystemMessage(`Use /addmod to add moderators`);

            return communityId;
        } catch (error) {
            this.displaySystemMessage('Failed to create community: ' + error.message);
            return null;
        }
    }

    sanitizeCommunityName(name) {
        // Replace spaces with hyphens for URL/ID compatibility
        return name.toLowerCase().replace(/\s+/g, '-').replace(/[^a-z0-9-]/g, '');
    }

    addCommunityChannel(name, communityId, isPrivate) {
        const list = document.getElementById('channelList');

        // Filter out communities with spaces in the name
        if (name.includes(' ')) {
            // Still store it in communityChannels map but don't display
            if (!this.communityChannels.has(communityId)) {
                this.communityChannels.set(communityId, {
                    name: name,
                    isPrivate: isPrivate
                });
            }
            return;
        }

        // Check if already exists
        if (document.querySelector(`[data-community="${communityId}"]`)) {
            return;
        }

        const item = document.createElement('div');
        item.className = 'channel-item list-item';
        item.dataset.community = communityId;
        item.dataset.channel = name; // Just the display name
        item.dataset.geohash = ''; // Not a geohash
        item.dataset.isCommunity = 'true'; // Mark as community

        const badge = isPrivate ?
            '<span class="std-badge" style="border-color: var(--purple); color: var(--purple);">PRI</span>' :
            '<span class="std-badge" style="border-color: var(--primary); color: var(--primary);">PUB</span>';

        const isPinned = this.pinnedChannels.has(communityId);
        if (isPinned) {
            item.classList.add('pinned');
        }

        const pinButton = `
<span class="pin-btn ${isPinned ? 'pinned' : ''}" data-community="${communityId}">
    <svg viewBox="0 0 24 24">
        <path d="M16,12V4H17V2H7V4H8V12L6,14V16H11.2V22H12.8V16H18V14L16,12Z"/>
    </svg>
</span>
`;

        item.innerHTML = `
<span class="channel-name">#${this.escapeHtml(name)}</span>
<div class="channel-badges">
    ${pinButton}
    ${badge}
    <span class="unread-badge" style="display:none">0</span>
</div>
`;

        // Add click handler for the entire item
        item.addEventListener('click', (e) => {
            // Don't trigger if clicking on pin button
            if (!e.target.closest('.pin-btn')) {
                this.switchToCommunity(communityId);
            }
        });

        // Add pin handler
        const pinBtn = item.querySelector('.pin-btn');
        if (pinBtn) {
            pinBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                e.preventDefault();
                this.togglePin(communityId, '', true); // community flag
            });
        }

        // Get all existing items (excluding view more button)
        const existingItems = Array.from(list.querySelectorAll('.channel-item'));
        const viewMoreBtn = list.querySelector('.view-more-btn');

        // Find a random position among existing items
        // Exclude #bar (first item) and NYM community if it exists
        let insertableItems = existingItems.filter(existingItem => {
            const isBar = existingItem.dataset.channel === 'bar' && !existingItem.dataset.geohash && !existingItem.dataset.isCommunity;
            const isNYM = existingItem.dataset.community &&
                this.communityChannels.get(existingItem.dataset.community)?.name?.toLowerCase() === 'nym' &&
                this.communityChannels.get(existingItem.dataset.community)?.admin === this.verifiedDeveloper.pubkey;
            return !isBar && !isNYM;
        });

        if (insertableItems.length > 0) {
            // Insert at random position
            const randomIndex = Math.floor(Math.random() * (insertableItems.length + 1));
            if (randomIndex === insertableItems.length) {
                // Insert at the end (before view more button)
                if (viewMoreBtn) {
                    list.insertBefore(item, viewMoreBtn);
                } else {
                    list.appendChild(item);
                }
            } else {
                // Insert before the randomly selected item
                list.insertBefore(item, insertableItems[randomIndex]);
            }
        } else {
            // No insertable items, just add before view more or at end
            if (viewMoreBtn) {
                list.insertBefore(item, viewMoreBtn);
            } else {
                list.appendChild(item);
            }
        }

        // Store in channels map with community flag
        this.channels.set(communityId, {
            channel: name,
            community: communityId,
            isCommunity: true,
            isPrivate: isPrivate
        });

        this.userJoinedChannels.add(communityId);
        this.updateChannelPins();
        this.updateViewMoreButton('channelList');
    }

    async uploadImage(file) {
        const progress = document.getElementById('uploadProgress');
        const progressFill = document.getElementById('progressFill');

        try {
            progress.classList.add('active');
            progressFill.style.width = '20%';

            // Compute SHA-256 hash
            const arrayBuffer = await file.arrayBuffer();
            const hashBuffer = await crypto.subtle.digest('SHA-256', arrayBuffer);
            const hashArray = Array.from(new Uint8Array(hashBuffer));
            const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');

            progressFill.style.width = '40%';

            // Create and sign Nostr event
            const uploadEvent = {
                kind: 24242,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ['t', 'upload'],
                    ['x', hashHex]
                ],
                content: 'Uploading blob with SHA-256 hash',
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(uploadEvent);

            progressFill.style.width = '60%';

            // Prepare form data
            const formData = new FormData();
            formData.append('file', file);

            // Convert signed event to base64
            const eventString = JSON.stringify(signedEvent);
            const eventBase64 = btoa(eventString);

            progressFill.style.width = '80%';

            // Upload to nostrmedia.com
            const response = await fetch('https://nostrmedia.com/upload', {
                method: 'POST',
                headers: {
                    'Authorization': `Nostr ${eventBase64}`
                },
                body: formData
            });

            progressFill.style.width = '100%';

            if (response.ok) {
                const data = await response.json();
                if (data.url) {
                    const imageUrl = data.url;
                    const input = document.getElementById('messageInput');
                    input.value += imageUrl + ' ';
                    input.focus();
                } else {
                    throw new Error('No URL in response');
                }
            } else {
                throw new Error(`Upload failed: ${response.status}`);
            }
        } catch (error) {
            this.displaySystemMessage('Failed to upload image: ' + error.message);
        } finally {
            setTimeout(() => {
                progress.classList.remove('active');
            }, 500);
        }
    }

    // Initialize P2P signaling subscription for the current user
    initP2PSignaling() {
        if (!this.pubkey) return;

        const subId = 'p2p-sig-' + Math.random().toString(36).substring(2, 10);
        const filter = {
            kinds: [this.P2P_SIGNALING_KIND],
            '#p': [this.pubkey],
            since: Math.floor(Date.now() / 1000) - 60 // Last minute
        };

        this.sendToRelay(['REQ', subId, filter]);
        this.p2pSignalingSubscriptions.add(subId);
    }

    // Handle incoming P2P signaling events
    handleP2PSignalingEvent(event) {
        try {
            const data = JSON.parse(event.content);
            const senderPubkey = event.pubkey;

            if (data.type === 'offer') {
                this.handleP2POffer(senderPubkey, data);
            } else if (data.type === 'answer') {
                this.handleP2PAnswer(senderPubkey, data);
            } else if (data.type === 'ice-candidate') {
                this.handleP2PIceCandidate(senderPubkey, data);
            }
        } catch (e) {
            console.error('P2P signaling error:', e);
        }
    }

    // Share a file via P2P
    async shareP2PFile(file) {
        if (!this.connected || !this.pubkey) {
            this.displaySystemMessage('Must be connected to share files');
            return;
        }

        // Compute file hash for identification
        const arrayBuffer = await file.arrayBuffer();
        const hashBuffer = await crypto.subtle.digest('SHA-256', arrayBuffer);
        const hashArray = Array.from(new Uint8Array(hashBuffer));
        const fileHash = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');

        // Create unique offer ID
        const offerId = fileHash.substring(0, 16) + '-' + Date.now().toString(36);

        // Store file for seeding
        this.p2pPendingFiles.set(offerId, file);

        // Create file offer metadata
        const fileOffer = {
            offerId: offerId,
            name: file.name,
            size: file.size,
            type: file.type || 'application/octet-stream',
            hash: fileHash,
            seederPubkey: this.pubkey,
            timestamp: Math.floor(Date.now() / 1000)
        };

        // Store offer locally
        this.p2pFileOffers.set(offerId, fileOffer);

        // Determine channel info and kind for the offer event
        let tags = [
            ['n', this.nym],
            ['offer', JSON.stringify(fileOffer)]
        ];

        let kind;

        if (this.currentGeohash) {
            kind = 20000; // Geohash channel kind
            tags.push(['g', this.currentGeohash]);
        } else if (this.currentCommunity) {
            kind = 4550; // Community channel kind
            const community = this.communityChannels.get(this.currentCommunity);
            if (community) {
                tags.push(['a', `34550:${community.creator}:${community.name}`]);
            }
        } else if (this.currentChannel) {
            kind = 23333; // Standard channel kind
            tags.push(['d', this.currentChannel]);
        } else {
            this.displaySystemMessage('No channel selected for file sharing');
            return;
        }

        // Create and sign the file offer event
        const event = {
            kind: kind,
            created_at: Math.floor(Date.now() / 1000),
            tags: tags,
            content: `Sharing file through NYM: ${file.name} (${this.formatFileSize(file.size)})`,
            pubkey: this.pubkey
        };

        const signedEvent = await this.signEvent(event);

        // Create optimistic message for immediate display
        const optimisticMessage = {
            id: signedEvent.id,
            author: this.nym,
            pubkey: this.pubkey,
            content: event.content,
            timestamp: new Date(event.created_at * 1000),
            channel: this.currentCommunity || this.currentChannel,
            geohash: this.currentGeohash || '',
            isOwn: true,
            isHistorical: false,
            isFileOffer: true,
            fileOffer: fileOffer,
            isCommunity: !!this.currentCommunity,
            communityId: this.currentCommunity || null
        };

        // Display locally immediately
        this.displayMessage(optimisticMessage);

        // Broadcast to relays
        this.sendToRelay(['EVENT', signedEvent]);

        this.displaySystemMessage(`File "${file.name}" is now available for P2P download`);
    }

    // Format file size for display
    formatFileSize(bytes) {
        if (bytes < 1024) return bytes + ' B';
        if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
        if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
        return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
    }

    // Get file type category for icon styling
    getFileTypeCategory(filename, mimeType) {
        const ext = filename.split('.').pop().toLowerCase();
        const audioExts = ['mp3', 'wav', 'flac', 'aac', 'ogg', 'm4a', 'wma'];
        const videoExts = ['mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm'];
        const archiveExts = ['zip', 'rar', '7z', 'tar', 'gz', 'bz2'];
        const docExts = ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'rtf'];

        if (audioExts.includes(ext) || mimeType?.startsWith('audio/')) return 'audio';
        if (videoExts.includes(ext) || mimeType?.startsWith('video/')) return 'video';
        if (archiveExts.includes(ext)) return 'archive';
        if (docExts.includes(ext)) return 'document';
        return 'file';
    }

    // Request a file from a seeder
    async requestP2PFile(offerId) {
        const offer = this.p2pFileOffers.get(offerId);
        if (!offer) {
            this.displaySystemMessage('File offer not found');
            return;
        }

        if (offer.seederPubkey === this.pubkey) {
            this.displaySystemMessage('Cannot download your own file');
            return;
        }

        // Update UI to show connecting
        const btn = document.querySelector(`[data-offer-id="${offerId}"] .file-offer-btn`);
        const progressDiv = document.getElementById(`progress-${offerId}`);
        if (btn) {
            btn.textContent = 'Connecting...';
            btn.classList.add('downloading');
            btn.onclick = null;
        }
        if (progressDiv) {
            progressDiv.style.display = 'block';
        }

        // Create transfer state
        const transferId = offerId + '-' + Date.now().toString(36);
        this.p2pActiveTransfers.set(transferId, {
            offerId: offerId,
            offer: offer,
            status: 'connecting',
            bytesReceived: 0,
            startTime: Date.now()
        });
        this.p2pReceivedChunks.set(transferId, []);

        // Create WebRTC connection
        await this.createP2PConnection(offer.seederPubkey, transferId, true);
    }

    // Create a WebRTC peer connection
    async createP2PConnection(peerPubkey, transferId, isInitiator) {
        const connectionId = peerPubkey + '-' + transferId;

        // Create new RTCPeerConnection
        const pc = new RTCPeerConnection({
            iceServers: this.p2pIceServers
        });

        this.p2pConnections.set(connectionId, pc);

        // Handle ICE candidates
        pc.onicecandidate = (event) => {
            if (event.candidate) {
                this.sendP2PSignal(peerPubkey, {
                    type: 'ice-candidate',
                    candidate: event.candidate,
                    transferId: transferId
                });
            }
        };

        pc.oniceconnectionstatechange = () => {
            const transfer = this.p2pActiveTransfers.get(transferId);
            if (pc.iceConnectionState === 'failed' || pc.iceConnectionState === 'disconnected') {
                if (transfer) {
                    this.updateTransferStatus(transferId, 'error', 'Connection failed');
                }
            }
        };

        if (isInitiator) {
            // Create data channel for receiving file
            const dc = pc.createDataChannel('fileTransfer', {
                ordered: true
            });
            this.setupDataChannel(dc, transferId, false);
            this.p2pDataChannels.set(connectionId, dc);

            // Create and send offer
            const offer = await pc.createOffer();
            await pc.setLocalDescription(offer);

            const transfer = this.p2pActiveTransfers.get(transferId);
            this.sendP2PSignal(peerPubkey, {
                type: 'offer',
                sdp: pc.localDescription,
                transferId: transferId,
                offerId: transfer?.offerId
            });
        } else {
            // Wait for data channel from peer
            pc.ondatachannel = (event) => {
                const dc = event.channel;
                this.setupDataChannel(dc, transferId, true);
                this.p2pDataChannels.set(connectionId, dc);
            };
        }

        return pc;
    }

    // Setup data channel handlers
    setupDataChannel(dc, transferId, isSender) {
        dc.binaryType = 'arraybuffer';

        dc.onopen = () => {
            if (isSender) {
                // Start sending file
                this.startSendingFile(transferId, dc);
            } else {
                this.updateTransferStatus(transferId, 'transferring', 'Receiving...');
            }
        };

        dc.onmessage = (event) => {
            if (!isSender) {
                this.handleFileChunk(transferId, event.data);
            }
        };

        dc.onerror = (error) => {
            console.error('Data channel error:', error);
            this.updateTransferStatus(transferId, 'error', 'Transfer error');
        };

        dc.onclose = () => {
            // Check if transfer completed
            const transfer = this.p2pActiveTransfers.get(transferId);
            if (transfer && transfer.status !== 'complete' && transfer.status !== 'error') {
                this.updateTransferStatus(transferId, 'error', 'Connection closed');
            }
        };
    }

    // Start sending file chunks
    async startSendingFile(transferId, dataChannel) {
        const transfer = this.p2pActiveTransfers.get(transferId);
        if (!transfer) return;

        const file = this.p2pPendingFiles.get(transfer.offerId);
        if (!file) {
            dataChannel.send(JSON.stringify({ type: 'error', message: 'File no longer available' }));
            return;
        }

        // Send file metadata first
        dataChannel.send(JSON.stringify({
            type: 'metadata',
            name: file.name,
            size: file.size,
            mimeType: file.type
        }));

        // Read and send file in chunks
        const chunkSize = this.P2P_CHUNK_SIZE;
        const totalChunks = Math.ceil(file.size / chunkSize);
        let offset = 0;
        let chunkIndex = 0;

        const sendNextChunk = async () => {
            if (offset >= file.size) {
                // Send completion signal
                dataChannel.send(JSON.stringify({ type: 'complete' }));
                return;
            }

            const chunk = file.slice(offset, offset + chunkSize);
            const arrayBuffer = await chunk.arrayBuffer();

            // Wait for buffer to clear if needed
            while (dataChannel.bufferedAmount > chunkSize * 10) {
                await new Promise(resolve => setTimeout(resolve, 10));
            }

            if (dataChannel.readyState === 'open') {
                dataChannel.send(arrayBuffer);
                offset += chunkSize;
                chunkIndex++;

                // Continue sending
                setTimeout(sendNextChunk, 0);
            }
        };

        sendNextChunk();
    }

    // Handle received file chunk
    handleFileChunk(transferId, data) {
        const transfer = this.p2pActiveTransfers.get(transferId);
        if (!transfer) return;

        // Handle JSON messages (metadata, complete, error)
        if (typeof data === 'string' || data instanceof ArrayBuffer && data.byteLength < 500) {
            try {
                let jsonStr = data;
                if (data instanceof ArrayBuffer) {
                    jsonStr = new TextDecoder().decode(data);
                }
                const msg = JSON.parse(jsonStr);

                if (msg.type === 'metadata') {
                    transfer.metadata = msg;
                    return;
                } else if (msg.type === 'complete') {
                    this.completeFileTransfer(transferId);
                    return;
                } else if (msg.type === 'error') {
                    this.updateTransferStatus(transferId, 'error', msg.message);
                    return;
                }
            } catch (e) {
                // Not JSON, treat as binary chunk
            }
        }

        // Binary chunk
        const chunks = this.p2pReceivedChunks.get(transferId);
        if (chunks && data instanceof ArrayBuffer) {
            chunks.push(data);
            transfer.bytesReceived += data.byteLength;

            // Update progress
            if (transfer.offer) {
                const progress = Math.min(100, (transfer.bytesReceived / transfer.offer.size) * 100);
                this.updateTransferProgress(transferId, progress);
            }
        }
    }

    // Complete file transfer and trigger download
    completeFileTransfer(transferId) {
        const transfer = this.p2pActiveTransfers.get(transferId);
        const chunks = this.p2pReceivedChunks.get(transferId);

        if (!transfer || !chunks) return;

        // Combine chunks into blob
        const blob = new Blob(chunks, {
            type: transfer.metadata?.mimeType || transfer.offer?.type || 'application/octet-stream'
        });

        // Create download link
        const url = URL.createObjectURL(blob);
        const a = document.createElement('a');
        a.href = url;
        a.download = transfer.metadata?.name || transfer.offer?.name || 'download';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(url);

        // Update status
        this.updateTransferStatus(transferId, 'complete', 'Download complete!');

        // Cleanup
        this.p2pReceivedChunks.delete(transferId);

        this.displaySystemMessage(`File "${transfer.offer?.name || 'file'}" downloaded successfully`);
    }

    // Update transfer progress UI
    updateTransferProgress(transferId, percent) {
        const transfer = this.p2pActiveTransfers.get(transferId);
        if (!transfer) return;

        const offerId = transfer.offerId;
        const progressFill = document.getElementById(`progress-fill-${offerId}`);
        const progressText = document.getElementById(`progress-text-${offerId}`);

        if (progressFill) {
            progressFill.style.width = percent.toFixed(1) + '%';
        }
        if (progressText) {
            const elapsed = (Date.now() - transfer.startTime) / 1000;
            const speed = transfer.bytesReceived / elapsed;
            progressText.textContent = `${percent.toFixed(1)}% • ${this.formatFileSize(Math.round(speed))}/s`;
        }
    }

    // Update transfer status
    updateTransferStatus(transferId, status, message) {
        const transfer = this.p2pActiveTransfers.get(transferId);
        if (!transfer) return;

        transfer.status = status;

        const offerId = transfer.offerId;
        const progressText = document.getElementById(`progress-text-${offerId}`);
        const btn = document.querySelector(`[data-offer-id="${offerId}"] .file-offer-btn`);

        if (progressText) {
            progressText.textContent = message;
            progressText.className = 'file-offer-progress-text ' + status;
        }

        if (status === 'complete' && btn) {
            btn.textContent = 'Downloaded';
            btn.classList.remove('downloading');
        } else if (status === 'error' && btn) {
            btn.textContent = 'Retry';
            btn.classList.remove('downloading');
            btn.onclick = () => this.requestP2PFile(offerId);
        }
    }

    // Send P2P signaling message via Nostr
    async sendP2PSignal(targetPubkey, data) {
        const event = {
            kind: this.P2P_SIGNALING_KIND,
            created_at: Math.floor(Date.now() / 1000),
            tags: [
                ['p', targetPubkey]
            ],
            content: JSON.stringify(data),
            pubkey: this.pubkey
        };

        const signedEvent = await this.signEvent(event);
        this.sendToRelay(['EVENT', signedEvent]);
    }

    // Handle incoming SDP offer
    async handleP2POffer(senderPubkey, data) {
        const { sdp, transferId, offerId } = data;

        // Check if we have this file to offer
        if (!this.p2pPendingFiles.has(offerId)) {
            return; // We don't have this file
        }

        // Create transfer state for sending
        this.p2pActiveTransfers.set(transferId, {
            offerId: offerId,
            offer: this.p2pFileOffers.get(offerId),
            status: 'connecting',
            bytesSent: 0,
            startTime: Date.now()
        });

        // Create peer connection and set remote description
        const pc = await this.createP2PConnection(senderPubkey, transferId, false);
        await pc.setRemoteDescription(new RTCSessionDescription(sdp));

        // Create and send answer
        const answer = await pc.createAnswer();
        await pc.setLocalDescription(answer);

        this.sendP2PSignal(senderPubkey, {
            type: 'answer',
            sdp: pc.localDescription,
            transferId: transferId
        });
    }

    // Handle incoming SDP answer
    async handleP2PAnswer(senderPubkey, data) {
        const { sdp, transferId } = data;
        const connectionId = senderPubkey + '-' + transferId;

        const pc = this.p2pConnections.get(connectionId);
        if (pc) {
            await pc.setRemoteDescription(new RTCSessionDescription(sdp));
        }
    }

    // Handle incoming ICE candidate
    async handleP2PIceCandidate(senderPubkey, data) {
        const { candidate, transferId } = data;
        const connectionId = senderPubkey + '-' + transferId;

        const pc = this.p2pConnections.get(connectionId);
        if (pc && candidate) {
            try {
                await pc.addIceCandidate(new RTCIceCandidate(candidate));
            } catch (e) {
                console.error('Error adding ICE candidate:', e);
            }
        }
    }

    // Open P2P transfers modal
    openP2PTransfersModal() {
        const modal = document.getElementById('p2pTransfersModal');
        const list = document.getElementById('p2pTransfersList');

        if (!modal || !list) return;

        // Build transfer list
        list.innerHTML = '';

        if (this.p2pActiveTransfers.size === 0 && this.p2pPendingFiles.size === 0) {
            list.innerHTML = '<div class="p2p-empty-state">No active transfers</div>';
        } else {
            // Show seeding files
            this.p2pPendingFiles.forEach((file, offerId) => {
                const offer = this.p2pFileOffers.get(offerId);
                if (offer) {
                    const item = document.createElement('div');
                    item.className = 'p2p-transfer-item';
                    item.innerHTML = `
                        <div class="p2p-transfer-header">
                            <span class="p2p-transfer-filename">${this.escapeHtml(offer.name)}</span>
                            <span class="p2p-transfer-size">${this.formatFileSize(offer.size)}</span>
                        </div>
                        <div class="p2p-transfer-status">
                            <span class="p2p-transfer-status-text complete">Seeding</span>
                            <div class="p2p-transfer-actions">
                                <button class="p2p-transfer-btn cancel" onclick="nym.stopSeeding('${offerId}')">Stop</button>
                            </div>
                        </div>
                    `;
                    list.appendChild(item);
                }
            });

            // Show active transfers
            this.p2pActiveTransfers.forEach((transfer, transferId) => {
                if (transfer.offer) {
                    const item = document.createElement('div');
                    item.className = 'p2p-transfer-item';
                    const progress = transfer.offer.size > 0 ? (transfer.bytesReceived / transfer.offer.size) * 100 : 0;
                    item.innerHTML = `
                        <div class="p2p-transfer-header">
                            <span class="p2p-transfer-filename">${this.escapeHtml(transfer.offer.name)}</span>
                            <span class="p2p-transfer-size">${this.formatFileSize(transfer.offer.size)}</span>
                        </div>
                        <div class="p2p-transfer-progress">
                            <div class="p2p-transfer-progress-fill" style="width: ${progress.toFixed(1)}%"></div>
                        </div>
                        <div class="p2p-transfer-status">
                            <span class="p2p-transfer-status-text ${transfer.status}">${transfer.status}</span>
                            <div class="p2p-transfer-actions">
                                <button class="p2p-transfer-btn cancel" onclick="nym.cancelTransfer('${transferId}')">Cancel</button>
                            </div>
                        </div>
                    `;
                    list.appendChild(item);
                }
            });
        }

        modal.classList.add('active');
    }

    // Stop seeding a file
    stopSeeding(offerId) {
        this.p2pPendingFiles.delete(offerId);
        this.displaySystemMessage('Stopped seeding file');
        this.openP2PTransfersModal(); // Refresh modal
    }

    // Cancel an active transfer
    cancelTransfer(transferId) {
        const transfer = this.p2pActiveTransfers.get(transferId);
        if (transfer) {
            // Close any associated connections
            this.p2pConnections.forEach((pc, connectionId) => {
                if (connectionId.includes(transferId)) {
                    pc.close();
                    this.p2pConnections.delete(connectionId);
                }
            });

            this.p2pActiveTransfers.delete(transferId);
            this.p2pReceivedChunks.delete(transferId);
            this.displaySystemMessage('Transfer cancelled');
            this.openP2PTransfersModal(); // Refresh modal
        }
    }

    isDuplicateMessage(message) {
        const displayChannel = message.geohash ? `#${message.geohash}` : message.channel;
        const channelMessages = this.messages.get(displayChannel) || [];
        return channelMessages.some(m =>
            m.id === message.id ||
            (m.content === message.content &&
                m.author === message.author &&
                Math.abs(m.timestamp - message.timestamp) < 2000)
        );
    }

    getNymFromPubkey(pubkey) {
        const user = this.users.get(pubkey);
        if (user) {
            // Get user's flair
            const flairHtml = this.getFlairForUser(pubkey);
            // Get clean nym without existing HTML
            const cleanNym = this.parseNymFromDisplay(user.nym);
            // Return nym with flair included
            return `${cleanNym}#${this.getPubkeySuffix(pubkey)}${flairHtml}`;
        }

        // Check if we've seen this user in PM conversations
        const pmConvo = Array.from(this.pmConversations.values())
            .find(conv => conv.pubkey === pubkey);
        if (pmConvo && pmConvo.nym) {
            const flairHtml = this.getFlairForUser(pubkey);
            const cleanNym = this.parseNymFromDisplay(pmConvo.nym);
            return `${cleanNym}#${this.getPubkeySuffix(pubkey)}${flairHtml}`;
        }

        // Return shortened pubkey as fallback with anon prefix
        return `anon#${pubkey.slice(-4)}`;
    }

    displayMessage(message) {
        // Check if message is from a blocked user (from stored state OR by pubkey)
        if (message.blocked || this.blockedUsers.has(message.pubkey) || this.isNymBlocked(message.author)) {
            return; // Don't display blocked messages
        }

        // For community messages, also check if user is banned from that community
        if (message.isCommunity && message.communityId) {
            if (this.communityBans.has(message.communityId) &&
                this.communityBans.get(message.communityId).has(message.pubkey)) {
                return;
            }
        }

        // Handle PM messages differently
        if (message.isPM) {
            // Check if we should display this PM now
            if (!this.inPMMode || this.currentPM !== message.conversationPubkey) {
                // Not viewing this PM conversation right now, but message is already stored
                return;
            }

            // Don't display if it's not part of the current conversation
            const currentConversationKey = this.getPMConversationKey(this.currentPM);
            if (message.conversationKey !== currentConversationKey) {
                return;
            }
        } else if (message.isCommunity) {
            // Handle COMMUNITY messages
            if (this.inPMMode) {
                // In PM mode, don't display community messages
                return;
            }

            // Only display if we're viewing this community
            if (this.currentCommunity !== message.communityId) {
                return;
            }

            const storageKey = message.communityId;

            // Store message if not already exists
            if (!this.messages.has(storageKey)) {
                this.messages.set(storageKey, []);
            }

            // Check if message already exists
            const exists = this.messages.get(storageKey).some(m => m.id === message.id);
            if (!exists) {
                // Add message and sort by timestamp with millisecond precision
                this.messages.get(storageKey).push(message);
                this.messages.get(storageKey).sort((a, b) => {
                    return a.timestamp.getTime() - b.timestamp.getTime();
                });
            }
        } else {
            // Regular channel message
            if (this.inPMMode) {
                // In PM mode, don't display channel messages
                return;
            }

            // Don't display if we're in a community
            if (this.currentCommunity) {
                return;
            }

            const storageKey = message.geohash ? `#${message.geohash}` : message.channel;

            // Store message if not already exists
            if (!this.messages.has(storageKey)) {
                this.messages.set(storageKey, []);
            }

            // Check if message already exists
            const exists = this.messages.get(storageKey).some(m => m.id === message.id);
            if (!exists) {
                // Add message and sort by timestamp with millisecond precision
                this.messages.get(storageKey).push(message);
                this.messages.get(storageKey).sort((a, b) => {
                    return a.timestamp.getTime() - b.timestamp.getTime();
                });

                // Prune messages if exceeding limit (500 max)
                const messages = this.messages.get(storageKey);
                if (messages && messages.length > 500) {
                    // Keep only the most recent 500 messages
                    const prunedMessages = messages.slice(-500);
                    this.messages.set(storageKey, prunedMessages);

                    // Also prune DOM if currently viewing this channel
                    const currentKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
                    if (currentKey === storageKey) {
                        const container = document.getElementById('messagesContainer');
                        const messageDOMs = container.querySelectorAll('.message[data-message-id]');

                        // Remove old DOM elements beyond 500
                        const toRemove = messageDOMs.length - 500;
                        if (toRemove > 0) {
                            for (let i = 0; i < toRemove; i++) {
                                messageDOMs[i].remove();
                            }
                        }
                    }
                }
            }

            // Check if this is for current channel
            const currentKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
            if (storageKey !== currentKey) {
                // Message is for different channel, update unread count but don't display
                if (!message.isOwn && !exists && !message.isHistorical) {
                    this.updateUnreadCount(storageKey);
                }
                // Invalidate pre-render cache for this channel since it has new messages
                if (!exists) {
                    this.invalidatePrerender(storageKey);
                }
                return;
            }
        }

        // Don't re-add if already displayed in DOM
        if (document.querySelector(`[data-message-id="${message.id}"]`)) {
            return;
        }

        // Now actually display the message in the DOM
        const container = document.getElementById('messagesContainer');
        const shouldScroll = container.scrollHeight - container.scrollTop <= container.clientHeight + 50;

        const time = this.settings.showTimestamps ?
            message.timestamp.toLocaleTimeString('en-US', {
                hour: '2-digit',
                minute: '2-digit',
                hour12: this.settings.timeFormat === '12hr'
            }) : '';

        // Get user's shop items for styling
        const userShopItems = this.getUserShopItems(message.pubkey);
        const flairHtml = this.getFlairForUser(message.pubkey);
        const supporterBadge = userShopItems?.supporter ?
            '<span class="supporter-badge"><span class="supporter-badge-icon">🏆</span><span class="supporter-badge-text">Supporter</span></span>' : '';

        const messageEl = document.createElement('div');

        // Check if nym is blocked or message contains blocked keywords or is spam
        if (this.blockedUsers.has(message.author) ||
            this.hasBlockedKeyword(message.content) ||
            this.isSpamMessage(message.content)) {
            // Don't create the element at all for blocked/spam content
            return;
        }

        // Check if nym is flooding in THIS CHANNEL (but not for PMs and not for historical messages)
        const channelToCheck = message.communityId || message.geohash || message.channel;
        if (!message.isPM && !message.isHistorical && this.isFlooding(message.pubkey, channelToCheck)) {
            messageEl.className = 'message flooded';
        }

        // Check if message mentions the user
        const isMentioned = !message.isOwn && this.isMentioned(message.content);

        // Check for action messages
        if (message.content.startsWith('/me ')) {
            messageEl.className = 'action-message';

            // Get clean author name and flair
            const cleanAuthor = this.parseNymFromDisplay(message.author);
            const authorFlairHtml = this.getFlairForUser(message.pubkey);
            const authorWithFlair = `${this.escapeHtml(cleanAuthor)}#${this.getPubkeySuffix(message.pubkey)}${authorFlairHtml}`;

            // Get the action content (everything after /me)
            const actionContent = message.content.substring(4);

            // Format the action content but preserve any HTML in mentioned users
            const formattedAction = this.formatMessage(actionContent);

            messageEl.innerHTML = `* ${authorWithFlair} ${formattedAction}`;
        } else {
            const classes = ['message'];

            if (message.isOwn) {
                classes.push('self');
            } else if (message.isPM) {
                classes.push('pm');
            } else if (isMentioned) {
                classes.push('mentioned');
            }

            // Apply shop styles (message-level)
            if (userShopItems?.style) {
                classes.push(userShopItems.style);
            }
            if (userShopItems?.supporter) {
                classes.push('supporter-style');
            }
            // Apply cosmetics (message-level glow)
            if (Array.isArray(userShopItems?.cosmetics)) {
                if (userShopItems.cosmetics.includes('cosmetic-aura-gold')) {
                    classes.push('cosmetic-aura-gold');
                }
            }

            messageEl.className = classes.join(' ');
            messageEl.dataset.messageId = message.id;
            messageEl.dataset.author = message.author;
            messageEl.dataset.pubkey = message.pubkey;
            messageEl.dataset.timestamp = message.timestamp.getTime();

            const authorClass = message.isOwn ? 'self' : '';
            const userColorClass = this.getUserColorClass(message.pubkey);

            // Add verified badge if this is the developer
            const verifiedBadge = this.isVerifiedDeveloper(message.pubkey) ?
                `<span class="verified-badge" title="${this.verifiedDeveloper.title}">✓</span>` : '';

            // Check if this is a valid event ID (not temporary PM ID)
            const isValidEventId = message.id && /^[0-9a-f]{64}$/i.test(message.id);
            const isMobile = window.innerWidth <= 768;

            // Show reaction button for all messages with valid IDs (including PMs and community posts)
            const reactionButton = isValidEventId && !isMobile ? `
    <button class="reaction-btn" onclick="nym.showReactionPicker('${message.id}', this)">
        <svg viewBox="0 0 24 24">
            <circle cx="12" cy="12" r="10"></circle>
            <path d="M8 14s1.5 2 4 2 4-2 4-2"></path>
            <circle cx="9" cy="9" r="1"></circle>
            <circle cx="15" cy="9" r="1"></circle>
        </svg>
    </button>
` : '';

            // Build the initial HTML with quote detection
            const formattedContent = this.formatMessageWithQuotes(message.content);

            const baseNym = this.parseNymFromDisplay(message.author);
            const displayAuthorBase = `${this.escapeHtml(baseNym)}<span class="nym-suffix">#${this.getPubkeySuffix(message.pubkey)}</span>${flairHtml}`;
            let displayAuthor = displayAuthorBase; // string used in HTML
            let authorExtraClass = '';
            if (Array.isArray(userShopItems?.cosmetics) && userShopItems.cosmetics.includes('cosmetic-redacted')) {
                authorExtraClass = 'cosmetic-redacted';
            }

            const escapedAuthorBase = this.escapeHtml(message.author).split('#')[0] || this.escapeHtml(message.author);
            const authorWithHtml = `${escapedAuthorBase}<span class="nym-suffix">#${this.getPubkeySuffix(message.pubkey)}</span>`;

            // Prepare full timestamp for tooltip
            const fullTimestamp = message.timestamp.toLocaleString('en-US', {
                year: 'numeric',
                month: 'short',
                day: 'numeric',
                hour: '2-digit',
                minute: '2-digit',
                second: '2-digit',
                hour12: this.settings.timeFormat === '12hr'
            });

            // Delivery status checkmarks for own PM messages
            let deliveryCheckmark = '';
            if (message.isOwn && message.isPM && message.deliveryStatus) {
                if (message.deliveryStatus === 'read') {
                    deliveryCheckmark = '<span class="delivery-status read" title="Read">✓✓</span>';
                } else if (message.deliveryStatus === 'delivered') {
                    deliveryCheckmark = '<span class="delivery-status delivered" title="Delivered">✓</span>';
                } else if (message.deliveryStatus === 'sent') {
                    deliveryCheckmark = '<span class="delivery-status sent" title="Sent">○</span>';
                }
            }

            // Check if this is a file offer and render special UI
            let messageContentHtml;
            if (message.isFileOffer && message.fileOffer) {
                const offer = message.fileOffer;
                const fileCategory = this.getFileTypeCategory(offer.name, offer.type);
                const isOwnOffer = message.isOwn;
                messageContentHtml = `
                    <div class="file-offer" data-offer-id="${offer.offerId}">
                        <div class="file-offer-header">
                            <div class="file-offer-icon ${fileCategory}">
                                <svg viewBox="0 0 24 24" stroke-width="2">
                                    <path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"></path>
                                    <polyline points="13 2 13 9 20 9"></polyline>
                                </svg>
                            </div>
                            <div class="file-offer-info">
                                <div class="file-offer-name" title="${this.escapeHtml(offer.name)}">${this.escapeHtml(offer.name)}</div>
                                <div class="file-offer-meta">${this.formatFileSize(offer.size)} • ${offer.type || 'Unknown type'}</div>
                            </div>
                        </div>
                        ${isOwnOffer ? `
                            <div class="file-offer-seeding">
                                <div class="file-offer-seeding-dot"></div>
                                <span>Seeding - available for download</span>
                            </div>
                        ` : `
                            <div class="file-offer-actions">
                                <button class="file-offer-btn" onclick="nym.requestP2PFile('${offer.offerId}')">Download</button>
                            </div>
                            <div class="file-offer-progress" id="progress-${offer.offerId}" style="display: none;">
                                <div class="file-offer-progress-bar">
                                    <div class="file-offer-progress-fill" id="progress-fill-${offer.offerId}"></div>
                                </div>
                                <div class="file-offer-progress-text" id="progress-text-${offer.offerId}">Connecting...</div>
                            </div>
                        `}
                    </div>
                `;
            } else {
                messageContentHtml = formattedContent;
            }

            messageEl.innerHTML = `
    ${time ? `<span class="message-time ${this.settings.timeFormat === '12hr' ? 'time-12hr' : ''}" data-full-time="${fullTimestamp}" title="${fullTimestamp}">${time}</span>` : ''}
    <span class="message-author ${authorClass} ${userColorClass} ${authorExtraClass}">${displayAuthor}${verifiedBadge}${supporterBadge}:</span>
    <span class="message-content ${userColorClass}">${messageContentHtml}</span>
    ${reactionButton}
    ${deliveryCheckmark}
`;

            const authorSpan = messageEl.querySelector('.message-author');
            if (authorSpan) {
                authorSpan.style.cursor = 'pointer';
                authorSpan.addEventListener('click', (e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    this.showContextMenu(e, displayAuthor, message.pubkey, message.content, message.id);
                    return false;
                });
            }
        }

        // Apply shop styles for own messages (load from cache if needed)
        if (message.pubkey === this.pubkey) {
            // Use cached values if shop items haven't loaded yet
            const activeStyle = this.activeMessageStyle || this.localActiveStyle;
            const activeFlair = this.activeFlair || this.localActiveFlair;

            if (activeStyle) {
                messageEl.classList.add(activeStyle);
            }
            if (this.userPurchases.has('supporter-badge')) {
                messageEl.classList.add('supporter-style');
            }
            if (this.activeCosmetics && this.activeCosmetics.size > 0) {
                this.activeCosmetics.forEach(c => {
                    if (c === 'cosmetic-aura-gold') {
                        messageEl.classList.add('cosmetic-aura-gold');
                    }
                    if (c === 'cosmetic-redacted') {
                        const auth = messageEl.querySelector('.message-author');
                        if (auth) auth.classList.add('cosmetic-redacted');

                        // Apply redacted effect to message content after 10 seconds
                        const contentEl = messageEl.querySelector('.message-content');
                        if (contentEl && !contentEl.classList.contains('cosmetic-redacted-message')) {
                            setTimeout(() => {
                                contentEl.classList.add('cosmetic-redacted-message');
                            }, 10000);
                        }
                    }
                });
            }
        }

        // Apply cosmetics from OTHER users to their messages
        if (message.pubkey !== this.pubkey && userShopItems?.cosmetics) {
            userShopItems.cosmetics.forEach(c => {
                if (c === 'cosmetic-redacted') {
                    const auth = messageEl.querySelector('.message-author');
                    if (auth) auth.classList.add('cosmetic-redacted');

                    // Apply redacted effect to message content after 10 seconds
                    const contentEl = messageEl.querySelector('.message-content');
                    if (contentEl && !contentEl.classList.contains('cosmetic-redacted-message')) {
                        setTimeout(() => {
                            contentEl.classList.add('cosmetic-redacted-message');
                        }, 10000);
                    }
                }
            });
        }

        // Apply blur to images if settings enabled and not own message
        if (!message.isOwn && this.blurOthersImages) {
            const images = messageEl.querySelectorAll('img');
            images.forEach(img => {
                img.classList.add('blurred');
            });
        }

        // Only sort by timestamp if we're scrolled to the bottom or if this is historical
        const isScrolledToBottom = container.scrollHeight - container.scrollTop <= container.clientHeight + 100;
        const shouldSort = isScrolledToBottom || message.isHistorical;

        if (shouldSort) {
            // Find the correct position to insert the message based on timestamp
            const existingMessages = Array.from(container.querySelectorAll('.message[data-timestamp]'));
            const messageTimestamp = message.timestamp.getTime();

            let insertBefore = null;
            for (const existing of existingMessages) {
                const existingTimestamp = parseInt(existing.dataset.timestamp);
                if (messageTimestamp < existingTimestamp) {
                    insertBefore = existing;
                    break;
                }
            }

            if (insertBefore) {
                container.insertBefore(messageEl, insertBefore);
            } else {
                const typingIndicator = container.querySelector('.typing-indicator');
                if (typingIndicator) {
                    container.insertBefore(messageEl, typingIndicator);
                } else {
                    container.appendChild(messageEl);
                }
            }
        } else {
            // Just append at the end for new messages when not at bottom
            const typingIndicator = container.querySelector('.typing-indicator');
            if (typingIndicator) {
                container.insertBefore(messageEl, typingIndicator);
            } else {
                container.appendChild(messageEl);
            }
        }

        // Add existing reactions if any (for both channel messages, PMs, and community posts)
        if (message.id && this.reactions.has(message.id)) {
            this.updateMessageReactions(message.id);
        }

        // Add zaps display - check if this message has any zaps
        if (message.id && this.zaps.has(message.id)) {
            this.updateMessageZaps(message.id);
        }

        // Track scroll position before adding images
        const scrollBeforeImages = container.scrollTop;
        const heightBeforeImages = container.scrollHeight;
        const isAtBottom = shouldScroll;

        // Wait for any images in the message to load
        const images = messageEl.querySelectorAll('img');
        if (images.length > 0) {
            let loadedImages = 0;
            const totalImages = images.length;

            const handleImageLoad = () => {
                loadedImages++;
                if (loadedImages === totalImages) {
                    // All images loaded
                    if (this.settings.autoscroll && isAtBottom) {
                        // Scroll to bottom if we were at bottom before
                        container.scrollTop = container.scrollHeight;
                    } else if (!isAtBottom) {
                        // Maintain scroll position for older messages
                        const heightAfterImages = container.scrollHeight;
                        const heightDiff = heightAfterImages - heightBeforeImages;
                        container.scrollTop = scrollBeforeImages + heightDiff;
                    }
                }
            };

            images.forEach(img => {
                if (img.complete) {
                    handleImageLoad();
                } else {
                    img.addEventListener('load', handleImageLoad, { once: true });
                    img.addEventListener('error', handleImageLoad, { once: true });
                }
            });
        } else {
            // No images, just handle scrolling normally
            if (this.settings.autoscroll && shouldScroll) {
                container.scrollTop = container.scrollHeight;
            }
        }

        // Play notification sound for mentions and PMs (but not for historical messages or own messages)
        if (!message.isHistorical && !message.isOwn && this.settings.sound) {
            if (isMentioned || message.isPM) {
                this.playSound(this.settings.sound);
            }
        }
    }

    pruneChannelMessages(channelKey, maxMessages = 500) {
        const messages = this.messages.get(channelKey);
        if (!messages || messages.length <= maxMessages) return;

        // Keep only the most recent messages
        const prunedMessages = messages.slice(-maxMessages);
        this.messages.set(channelKey, prunedMessages);

        // If currently viewing this channel, refresh the display
        const currentKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
        if (currentKey === channelKey) {
            this.loadChannelMessages(channelKey);
        }
    }

    formatMessageWithQuotes(content) {
        // Check if content contains a quote pattern
        const quotePattern = /^>(.+?)$/gm;
        const quotes = content.match(quotePattern);

        if (!quotes) {
            return this.formatMessage(content);
        }

        // Process each quote to extract and lookup the author
        let html = '';
        let lastIndex = 0;
        let match;

        quotePattern.lastIndex = 0;
        while ((match = quotePattern.exec(content)) !== null) {
            // Add any content before this quote
            if (match.index > lastIndex) {
                const beforeQuote = content.substring(lastIndex, match.index);
                html += this.formatMessage(beforeQuote);
            }

            const quotedText = match[1].trim();

            // Extract author from quote if it follows pattern "> @author: message"
            const authorMatch = quotedText.match(/^@([^:]+):\s*(.+)/);

            if (authorMatch) {
                const quotedAuthor = authorMatch[1].trim();
                const quotedMessage = authorMatch[2];

                // Clean the author name of HTML for comparison
                const cleanAuthor = quotedAuthor.replace(/<[^>]*>/g, '');

                // Look up the author's pubkey
                let authorPubkey = null;
                this.users.forEach((user, pubkey) => {
                    const userNym = this.parseNymFromDisplay(user.nym);
                    const fullNym = `${userNym}#${this.getPubkeySuffix(pubkey)}`;
                    if (fullNym === cleanAuthor || userNym === cleanAuthor) {
                        authorPubkey = pubkey;
                    }
                });

                // Get author's flair if found
                const flairHtml = authorPubkey ? this.getFlairForUser(authorPubkey) : '';
                const displayAuthor = `${this.escapeHtml(cleanAuthor)}${flairHtml}`;

                html += `<blockquote><span class="quote-author">@${displayAuthor}:</span> ${this.formatMessage(quotedMessage)}</blockquote>`;
            } else {
                // Regular quote without author
                html += `<blockquote>${this.formatMessage(quotedText)}</blockquote>`;
            }

            lastIndex = match.index + match[0].length;
        }

        // Add any remaining content
        if (lastIndex < content.length) {
            const remainingContent = content.substring(lastIndex);
            html += this.formatMessage(remainingContent);
        }

        return html;
    }

    closeReactionPickerHandler(e) {
        if (this.activeReactionPicker && !this.activeReactionPicker.contains(e.target)) {
            this.closeReactionPicker();
        }
    }

    closeReactionPicker() {
        if (this.activeReactionPicker) {
            this.activeReactionPicker.remove();
            this.activeReactionPicker = null;
            this.activeReactionPickerButton = null;
        }
    }

    currentDisplayChannel() {
        // Return consistent key format for message storage
        return this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
    }

    formatMessage(content) {
        let formatted = content;

        formatted = formatted
            .replace(/&(?![a-z]+;|#[0-9]+;|#x[0-9a-f]+;)/gi, '&amp;')
            .replace(/<(?!span class="flair|\/span|svg|\/svg|path|\/path|title|\/title)/g, '&lt;')
            .replace(/>(?![^<]*<\/(?:span|svg|title|path)>)/g, '&gt;')
            .replace(/"/g, '&quot;');

        // Code blocks with proper line break handling
        formatted = formatted.replace(/```([\s\S]*?)```/g, (match, code) => {
            const formattedCode = code.trim().replace(/\n/g, '<br/>');
            return `<pre><code>${formattedCode}</code></pre>`;
        });

        // Bold **text** or __text__
        formatted = formatted.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
        formatted = formatted.replace(/__(.+?)__/g, '<strong>$1</strong>');

        // Italic *text* or _text_
        formatted = formatted.replace(/(?<![:/])(\*|_)([^*_\s][^*_]*)\1/g, '<em>$2</em>');

        // Strikethrough ~~text~~
        formatted = formatted.replace(/~~(.+?)~~/g, '<del>$1</del>');

        // Blockquotes > text
        formatted = formatted.replace(/^&gt; (.+)$/gm, '<blockquote>$1</blockquote>');

        // Headers
        formatted = formatted.replace(/^### (.+)$/gm, '<h3>$1</h3>');
        formatted = formatted.replace(/^## (.+)$/gm, '<h2>$1</h2>');
        formatted = formatted.replace(/^# (.+)$/gm, '<h1>$1</h1>');

        // Convert image URLs to images
        formatted = formatted.replace(
            /(https?:\/\/[^\s]+\.(jpg|jpeg|png|gif|webp)(\?[^\s]*)?)/gi,
            (match, url) => {
                return `<img src="${url}" alt="Image" onclick="nym.expandImage('${url}')" />`;
            }
        );

        // Convert NYM app channel links BEFORE general URLs
        formatted = formatted.replace(
            /https?:\/\/app\.nym\.bar\/#([egc]):([^\s<>"]+)/gi,
            (match, prefix, channelId) => {
                return `<span class="channel-link" onclick="event.preventDefault(); event.stopPropagation(); nym.handleChannelLink('${prefix}:${this.escapeHtml(channelId)}', event); return false;">${match}</span>`;
            }
        );

        // Convert other URLs to links (but not placeholders)
        formatted = formatted.replace(
            /(https?:\/\/[^\s]+)(?![^<]*>)(?!__)/g,
            '<a href="$1" target="_blank" rel="noopener">$1</a>'
        );

        // Process mentions and channels together in one pass
        formatted = formatted.replace(
            /(@[^@#\s]*(?:<span class="flair[^"]*"[^>]*>[\s\S]*?<\/span>)?[^@#\s]*#[0-9a-f]{4}\b)|(@[^@\s][^@\s]*)|(?:^|\s)(#[\w\s-]+?)(?=\s|$|[.,!?])/gi,
            (match, mentionWithSuffix, simpleMention, channel, offset) => {
                if (mentionWithSuffix) {
                    // This is a mention with a pubkey suffix, may contain HTML flair
                    // Don't escape the HTML that's already there for flair
                    return `<span style="color: var(--secondary)">${mentionWithSuffix}</span>`;
                } else if (simpleMention) {
                    // This is a simple mention without spaces or suffix
                    return `<span style="color: var(--secondary)">${simpleMention}</span>`;
                } else if (channel) {
                    // This is a channel reference - check all types
                    const channelName = channel.substring(1).trim(); // Remove the # and trim

                    // Sanitize channel name (remove spaces and invalid chars)
                    const sanitized = channelName.toLowerCase().replace(/[^a-z0-9-]/g, '');

                    if (!sanitized) {
                        // Invalid channel name, just return as text
                        return match;
                    }

                    // Check for community channels that user has access to
                    let communityMatches = [];
                    this.communityChannels.forEach((community, id) => {
                        if (community.name.toLowerCase() === sanitized) {
                            // Filter out communities with spaces
                            if (community.name.includes(' ')) {
                                return;
                            }

                            // Filter out private communities user doesn't have access to
                            if (community.isPrivate) {
                                const hasAccess = this.ownedCommunities.has(id) ||
                                    (this.communityModerators.has(id) &&
                                        this.communityModerators.get(id).has(this.pubkey)) ||
                                    (this.communityMembers.has(id) &&
                                        this.communityMembers.get(id).has(this.pubkey)) ||
                                    (this.communityInvites.has(id) &&
                                        this.communityInvites.get(id).has(this.pubkey));

                                if (hasAccess) {
                                    communityMatches.push({ id, community });
                                }
                            } else {
                                // Public community - always include
                                communityMatches.push({ id, community });
                            }
                        }
                    });

                    // Check if this is a geohash channel - show modal to let user choose GEO or EPH
                    if (this.geohashRegex && this.geohashRegex.test(sanitized)) {
                        const isActive = this.currentGeohash === sanitized;
                        const classes = ['channel-reference', 'geohash-reference'];
                        if (isActive) classes.push('active-channel');

                        const location = this.getGeohashLocation(sanitized);
                        let title = `Click to choose channel type: GEO or EPH`;
                        if (location) {
                            title += ` (${location})`;
                        }

                        // Show options modal instead of directly navigating - user can choose GEO or EPH
                        return `${offset || ''}<span class="${classes.join(' ')}" title="${title}" onclick="event.preventDefault(); event.stopPropagation(); nym.showChannelOptions('${sanitized}'); return false;">${channel}</span>`;
                    }

                    // If we have community matches, use the first one
                    if (communityMatches.length > 0) {
                        const { id, community } = communityMatches[0];
                        const classes = ['channel-reference', 'community-reference'];

                        // Check if this is the current community
                        if (this.currentCommunity === id) {
                            classes.push('active-channel');
                        }

                        return `${offset || ''}<span class="${classes.join(' ')}" title="Community: ${community.name}" onclick="event.preventDefault(); event.stopPropagation(); nym.handleChannelLink('c:${id}', event); return false;">#${community.name}</span>`;
                    }

                    // Standard/EPH channel - always link any valid hashtag
                    const classes = ['channel-reference'];

                    // Check if this is the current channel
                    if (this.currentChannel === sanitized) {
                        classes.push('active-channel');
                    }

                    // Check if this channel is joined by user
                    if (this.userJoinedChannels && this.userJoinedChannels.has(sanitized)) {
                        classes.push('joined-channel');
                    }

                    return `${offset || ''}<span class="${classes.join(' ')}" onclick="event.preventDefault(); event.stopPropagation(); nym.handleChannelLink('e:${sanitized}', event); return false;">${channel}</span>`;
                }
            }
        );

        // Convert emoji shortcodes :emoji:
        formatted = formatted.replace(/:([a-z0-9_]+):/g, (match, code) => {
            const emoji = this.emojiMap[code];
            return emoji || match;
        });

        // Convert simple emoticons to emojis
        formatted = formatted.replace(/(^|\s):\)($|\s)/g, '$1😊$2');
        formatted = formatted.replace(/(^|\s):\(($|\s)/g, '$1😢$2');
        formatted = formatted.replace(/(^|\s):D($|\s)/g, '$1😃$2');
        formatted = formatted.replace(/(^|\s):P($|\s)/g, '$1😛$2');
        formatted = formatted.replace(/(^|\s);-?\)($|\s)/g, '$1😉$2');
        formatted = formatted.replace(/(^|\s):o($|\s)/gi, '$1😮$2');
        formatted = formatted.replace(/(^|\s):\|($|\s)/g, '$1😐$2');
        formatted = formatted.replace(/(^|\s)&lt;3($|\s)/g, '$1❤️$2');
        formatted = formatted.replace(/(^|\s)\/\\($|\s)/g, '$1⚠️$2');

        // Line breaks
        formatted = formatted.replace(/\n/g, '<br>');

        return formatted;
    }

    expandImage(src) {
        document.getElementById('modalImage').src = src;
        document.getElementById('imageModal').classList.add('active');
    }

    quickJoinChannel(channel) {
        // Sanitize channel name
        const sanitized = channel.toLowerCase().replace(/[^a-z0-9-]/g, '');

        if (!sanitized) {
            this.displaySystemMessage('Invalid channel name. Use only letters, numbers, and hyphens.');
            return;
        }

        const type = this.getChannelType(sanitized);

        if (type === 'geo') {
            this.addChannel(sanitized, sanitized);
            this.switchChannel(sanitized, sanitized);
            this.userJoinedChannels.add(sanitized);
        } else {
            this.addChannel(sanitized, '');
            this.switchChannel(sanitized, '');
            // Also create the channel with kind 23333
            this.createChannel(sanitized);
            this.userJoinedChannels.add(sanitized);
        }

        // Save after quick join
        this.saveUserChannels();
    }

    quickJoinCommunity(communityId) {
        const community = this.communityChannels.get(communityId);
        if (!community) {
            this.displaySystemMessage('Community not found');
            return;
        }

        // Check if community has spaces (shouldn't happen, but safety check)
        if (community.name.includes(' ')) {
            this.displaySystemMessage('This community has an invalid name (contains spaces)');
            return;
        }

        if (this.connectionMode === 'ephemeral') {
            this.displaySystemMessage('Community channels require a persistent identity (extension or nsec)');
            return;
        }

        // Check if it's a private community and user has access
        if (community.isPrivate) {
            const hasAccess = this.ownedCommunities.has(communityId) ||
                (this.communityModerators.has(communityId) &&
                    this.communityModerators.get(communityId).has(this.pubkey)) ||
                (this.communityMembers.has(communityId) &&
                    this.communityMembers.get(communityId).has(this.pubkey)) ||
                (this.communityInvites.has(communityId) &&
                    this.communityInvites.get(communityId).has(this.pubkey));

            if (!hasAccess) {
                this.displaySystemMessage('This is a private community. You need an invitation.');
                return;
            }
        }

        // Add to UI if not present
        if (!document.querySelector(`[data-community="${communityId}"]`)) {
            this.addCommunityChannel(community.name, communityId, community.isPrivate);
        }

        this.switchToCommunity(communityId);
        this.userJoinedChannels.add(communityId);
        this.saveUserChannels();
    }

    showChannelOptions(channelName) {
        // Sanitize the channel name
        const sanitized = channelName.toLowerCase().replace(/[^a-z0-9-]/g, '');

        if (!sanitized) {
            this.displaySystemMessage('Invalid channel name');
            return;
        }

        // Close any existing channel options modal
        const existingModal = document.getElementById('channelOptionsModal');
        if (existingModal) {
            existingModal.remove();
        }

        // Create modal
        const modal = document.createElement('div');
        modal.id = 'channelOptionsModal';
        modal.className = 'modal active';

        let optionsHtml = '';
        let optionCount = 0;

        // Check for community channels that user has access to
        const communityMatches = [];
        this.communityChannels.forEach((community, id) => {
            if (community.name.toLowerCase() === sanitized) {
                // Filter out communities with spaces
                if (community.name.includes(' ')) {
                    return;
                }

                // Filter out private communities user doesn't have access to
                if (community.isPrivate) {
                    const hasAccess = this.ownedCommunities.has(id) ||
                        (this.communityModerators.has(id) &&
                            this.communityModerators.get(id).has(this.pubkey)) ||
                        (this.communityMembers.has(id) &&
                            this.communityMembers.get(id).has(this.pubkey)) ||
                        (this.communityInvites.has(id) &&
                            this.communityInvites.get(id).has(this.pubkey));

                    if (hasAccess) {
                        communityMatches.push({ id, community });
                    }
                } else {
                    // Public community - always include
                    communityMatches.push({ id, community });
                }
            }
        });

        // Add community options
        communityMatches.forEach(({ id, community }) => {
            optionCount++;
            const privacyBadge = community.isPrivate ? 'PRI' : 'PUB';
            const privacyColor = community.isPrivate ? 'var(--purple)' : 'var(--primary)';

            // Different access info based on user's role
            let accessInfo = '';
            if (community.isPrivate) {
                if (this.ownedCommunities.has(id)) {
                    accessInfo = ' (Private - You are Admin)';
                } else if (this.communityModerators.has(id) && this.communityModerators.get(id).has(this.pubkey)) {
                    accessInfo = ' (Private - You are Moderator)';
                } else if (this.communityMembers.has(id) && this.communityMembers.get(id).has(this.pubkey)) {
                    accessInfo = ' (Private - You are Member)';
                } else if (this.communityInvites.has(id) && this.communityInvites.get(id).has(this.pubkey)) {
                    accessInfo = ' (Private - You are Invited)';
                } else {
                    accessInfo = ' (Private)';
                }
            } else {
                accessInfo = ' (Public)';
            }

            optionsHtml += `
    <button class="icon-btn channel-option-btn" onclick="nym.joinChannelOption('community', '${id}'); nym.closeChannelOptions();" style="width: 100%; margin-bottom: 10px; text-align: left; display: flex; justify-content: space-between; align-items: center;">
        <span>#${this.escapeHtml(community.name)}${accessInfo}</span>
        <span style="color: ${privacyColor}; border: 1px solid ${privacyColor}; padding: 2px 8px; border-radius: 3px; font-size: 10px;">${privacyBadge}</span>
    </button>
`;
        });

        // Check if it's a valid geohash
        const isGeohash = this.isValidGeohash(sanitized);
        if (isGeohash) {
            optionCount++;
            const location = this.getGeohashLocation(sanitized) || 'Unknown location';
            optionsHtml += `
    <button class="icon-btn channel-option-btn" onclick="nym.joinChannelOption('geohash', '${this.escapeHtml(sanitized)}'); nym.closeChannelOptions();" style="width: 100%; margin-bottom: 10px; text-align: left; display: flex; justify-content: space-between; align-items: center;">
        <span>#${this.escapeHtml(sanitized)} (${location})</span>
        <span style="color: var(--warning); border: 1px solid var(--warning); padding: 2px 8px; border-radius: 3px; font-size: 10px;">GEO</span>
    </button>
`;
        }

        // Always show standard channel option
        optionCount++;
        optionsHtml += `
<button class="icon-btn channel-option-btn" onclick="nym.joinChannelOption('standard', '${this.escapeHtml(sanitized)}'); nym.closeChannelOptions();" style="width: 100%; margin-bottom: 10px; text-align: left; display: flex; justify-content: space-between; align-items: center;">
    <span>#${this.escapeHtml(sanitized)} (Ephemeral)</span>
    <span style="color: var(--blue); border: 1px solid var(--blue); padding: 2px 8px; border-radius: 3px; font-size: 10px;">EPH</span>
</button>
`;

        // Only show modal if there are multiple options
        if (optionCount > 1) {
            modal.innerHTML = `
    <div class="modal-content" style="max-width: 500px;">
        <div class="modal-header">Choose Channel Type for #${this.escapeHtml(sanitized)}</div>
        <div class="modal-body">
            <div style="margin-bottom: 15px; color: var(--text-dim); font-size: 12px;">
                Multiple channels with this name exist. Select which one to join:
            </div>
            ${optionsHtml}
        </div>
        <div class="modal-actions">
            <button class="icon-btn" onclick="nym.closeChannelOptions()">Cancel</button>
        </div>
    </div>
`;

            document.body.appendChild(modal);

            // Close on click outside
            setTimeout(() => {
                modal.addEventListener('click', (e) => {
                    if (e.target === modal) {
                        this.closeChannelOptions();
                    }
                });
            }, 100);
        } else {
            // Only one option, join directly
            if (communityMatches.length > 0) {
                this.joinChannelOption('community', communityMatches[0].id);
            } else if (isGeohash) {
                this.joinChannelOption('geohash', sanitized);
            } else {
                this.joinChannelOption('standard', sanitized);
            }
        }
    }

    closeChannelOptions() {
        const modal = document.getElementById('channelOptionsModal');
        if (modal) {
            modal.remove();
        }
    }

    async joinChannelOption(type, identifier) {
        if (type === 'community') {
            // Community IDs are already validated, use as-is
            this.quickJoinCommunity(identifier);
        } else if (type === 'geohash') {
            // Sanitize geohash identifier
            const sanitized = identifier.toLowerCase().replace(/[^0-9bcdefghjkmnpqrstuvwxyz]/g, '');

            if (!sanitized || !this.isValidGeohash(sanitized)) {
                this.displaySystemMessage('Invalid geohash');
                return;
            }

            // Join as geohash channel
            this.addChannel(sanitized, sanitized);
            this.switchChannel(sanitized, sanitized);
            this.userJoinedChannels.add(sanitized);
            this.saveUserChannels();
        } else if (type === 'standard') {
            // Sanitize standard channel name
            const sanitized = identifier.toLowerCase().replace(/[^a-z0-9-]/g, '');

            if (!sanitized) {
                this.displaySystemMessage('Invalid channel name');
                return;
            }

            // Join as standard ephemeral channel
            this.addChannel(sanitized, '');
            this.switchChannel(sanitized, '');
            await this.createChannel(sanitized);
            this.userJoinedChannels.add(sanitized);
            this.saveUserChannels();
        }
    }

    insertMention(nym) {
        const input = document.getElementById('messageInput');
        const currentValue = input.value;
        const mention = `@${nym} `;

        // Insert at cursor position or append
        const start = input.selectionStart;
        const end = input.selectionEnd;

        if (start !== undefined) {
            input.value = currentValue.substring(0, start) + mention + currentValue.substring(end);
            input.selectionStart = input.selectionEnd = start + mention.length;
        } else {
            input.value = currentValue + mention;
        }

        input.focus();
    }

    displaySystemMessage(content, type = 'system') {
        const container = document.getElementById('messagesContainer');
        const messageEl = document.createElement('div');
        messageEl.className = type === 'action' ? 'action-message' : 'system-message';
        messageEl.innerHTML = content;
        container.appendChild(messageEl);

        if (this.settings.autoscroll) {
            container.scrollTop = container.scrollHeight;
        }
    }

    updateUserPresence(nym, pubkey, channel, geohash) {
        const channelKey = geohash || channel;

        // Update or create user with deduplication by pubkey
        if (!this.users.has(pubkey)) {
            this.users.set(pubkey, {
                nym: nym,
                pubkey: pubkey,
                lastSeen: Date.now(),
                status: this.awayMessages.has(pubkey) ? 'away' : 'online',
                channels: new Set([channelKey])
            });
        } else {
            const user = this.users.get(pubkey);
            user.lastSeen = Date.now();
            user.nym = nym; // Update nym in case it changed
            user.channels.add(channelKey);
            user.status = this.awayMessages.has(pubkey) ? 'away' : 'online';
        }

        // Track users per channel
        if (!this.channelUsers.has(channelKey)) {
            this.channelUsers.set(channelKey, new Set());
        }
        this.channelUsers.get(channelKey).add(pubkey);

        this.updateUserList();
    }

    updateUserList() {
        const userListContent = document.getElementById('userListContent');
        const currentChannelKey = this.currentCommunity || this.currentGeohash || this.currentChannel;

        // Get deduplicated active users (one entry per pubkey)
        const uniqueUsers = new Map();
        this.users.forEach((user, pubkey) => {
            if (Date.now() - user.lastSeen < 300000 && !this.blockedUsers.has(user.nym)) {
                if (!uniqueUsers.has(pubkey)) {
                    uniqueUsers.set(pubkey, user);
                }
            }
        });

        const allUsers = Array.from(uniqueUsers.values())
            .filter(user => user && user.nym)
            .sort((a, b) => {
                const nymA = String(a.nym || '');
                const nymB = String(b.nym || '');
                return nymA.localeCompare(nymB);
            });

        // Filter users based on search term
        let displayUsers = allUsers;
        if (this.userSearchTerm) {
            const term = this.userSearchTerm.toLowerCase();
            displayUsers = allUsers.filter(user =>
                this.parseNymFromDisplay(user.nym).toLowerCase().includes(term)
            );
        }

        // Get users in current channel for the count
        let channelUserCount = 0;
        this.users.forEach((user, pubkey) => {
            if (Date.now() - user.lastSeen < 300000 &&
                !this.blockedUsers.has(user.nym) &&
                user.channels.has(currentChannelKey)) {
                channelUserCount++;
            }
        });

        // Build HTML
        userListContent.innerHTML = displayUsers.map((user) => {
            const baseNym = this.parseNymFromDisplay(user.nym);
            const suffix = this.getPubkeySuffix(user.pubkey);
            const displayNym = `${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>`;
            const verifiedBadge = this.isVerifiedDeveloper(user.pubkey)
                ? `<span class="verified-badge" title="${this.verifiedDeveloper.title}" style="margin-left: 3px;">✓</span>`
                : '';

            const userColorClass = this.settings.theme === 'bitchat' ? this.getUserColorClass(user.pubkey) : '';

            return `
    <div class="user-item list-item ${userColorClass}" 
            onclick="nym.openUserPM('${this.escapeHtml(baseNym)}', '${user.pubkey}')" 
            oncontextmenu="nym.showContextMenu(event, '${this.escapeHtml(displayNym)}', '${user.pubkey}')"
            data-nym="${this.escapeHtml(baseNym)}">
        <span class="user-status ${user.status}"></span>
        <span class="${userColorClass}">${displayNym} ${verifiedBadge}</span>
    </div>
`;
        }).join('');

        this.updateViewMoreButton('userListContent');

        const userListTitle = document.querySelector('#userList .nav-title-text');
        if (userListTitle) {
            userListTitle.textContent = `Active Nyms (${allUsers.length})`;
        }

        if (!this.inPMMode) {
            const meta = document.getElementById('channelMeta');
            if (meta) meta.textContent = `${channelUserCount} active nyms`;
        }
    }

    filterChannels(searchTerm) {
        const items = document.querySelectorAll('.channel-item');
        const term = searchTerm.toLowerCase();
        const list = document.getElementById('channelList');

        items.forEach(item => {
            const channelName = item.querySelector('.channel-name').textContent.toLowerCase();
            if (term.length === 0 || channelName.includes(term)) {
                item.style.display = 'flex';
                item.classList.remove('search-hidden');
            } else {
                item.style.display = 'none';
                item.classList.add('search-hidden');
            }
        });

        // Hide view more button during search
        const viewMoreBtn = list.querySelector('.view-more-btn');
        if (viewMoreBtn) {
            viewMoreBtn.style.display = term ? 'none' : 'block';
        }
    }

    filterPMs(searchTerm) {
        const items = document.querySelectorAll('.pm-item');
        const term = searchTerm.toLowerCase();
        const list = document.getElementById('pmList');

        items.forEach(item => {
            const pmName = item.querySelector('.pm-name').textContent.toLowerCase();
            if (term.length === 0 || pmName.includes(term)) {
                item.style.display = 'flex';
                item.classList.remove('search-hidden');
            } else {
                item.style.display = 'none';
                item.classList.add('search-hidden');
            }
        });

        // Hide view more button during search
        const viewMoreBtn = list.querySelector('.view-more-btn');
        if (viewMoreBtn) {
            viewMoreBtn.style.display = term ? 'none' : 'block';
        }
    }

    filterUsers(searchTerm) {
        this.userSearchTerm = searchTerm;
        this.updateUserList();

        const list = document.getElementById('userListContent');

        // Hide view more button during search
        const viewMoreBtn = list.querySelector('.view-more-btn');
        if (viewMoreBtn) {
            viewMoreBtn.style.display = searchTerm ? 'none' : 'block';
        }
    }

    togglePin(channel, geohash, isCommunity = false) {
        // Don't allow pinning/unpinning #bar since it's always at top
        if (channel === 'bar' && !geohash && !isCommunity) {
            this.displaySystemMessage('#bar is always at the top');
            return;
        }

        // Check if this is the NYM community
        const key = isCommunity ? channel : (geohash || channel);

        if (isCommunity && this.communityChannels.has(key)) {
            const community = this.communityChannels.get(key);
            const isNYMCommunity = community.admin === this.verifiedDeveloper.pubkey &&
                community.name.toLowerCase() === 'nym';

            if (isNYMCommunity) {
                this.displaySystemMessage('#NYM community is always pinned');
                return;
            }
        }

        // For other channels, toggle pin status
        if (this.pinnedChannels.has(key)) {
            this.pinnedChannels.delete(key);
        } else {
            this.pinnedChannels.add(key);
        }

        this.savePinnedChannels();
        this.updateChannelPins();

        if (this.connectionMode !== 'ephemeral') {
            this.saveSyncedSettings();
        }
    }

    updateChannelPins() {
        document.querySelectorAll('.channel-item').forEach(item => {
            let key;

            // Check if this is a community channel
            if (item.dataset.isCommunity === 'true') {
                key = item.dataset.community;
            } else {
                const channel = item.dataset.channel;
                const geohash = item.dataset.geohash;
                key = geohash || channel;
            }

            const pinBtn = item.querySelector('.pin-btn');

            if (this.pinnedChannels.has(key)) {
                item.classList.add('pinned');
                if (pinBtn) pinBtn.classList.add('pinned');
            } else {
                item.classList.remove('pinned');
                if (pinBtn) pinBtn.classList.remove('pinned');
            }
        });
    }

    savePinnedChannels() {
        localStorage.setItem('nym_pinned_channels', JSON.stringify(Array.from(this.pinnedChannels)));
    }

    loadPinnedChannels() {
        const saved = localStorage.getItem('nym_pinned_channels');
        if (saved) {
            this.pinnedChannels = new Set(JSON.parse(saved));
            this.updateChannelPins();
        }
    }

    setupEventListeners() {
        const input = document.getElementById('messageInput');

        input.addEventListener('keydown', (e) => {
            const autocomplete = document.getElementById('autocompleteDropdown');
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
            this.handleInputChange(e.target.value);
            this.autoResizeTextarea(e.target);
        });

        // Use event delegation for channel clicks
        document.getElementById('channelList').addEventListener('click', (e) => {
            // Handle channel item clicks
            const channelItem = e.target.closest('.channel-item');
            if (channelItem && !e.target.closest('.pin-btn')) {
                e.preventDefault();
                e.stopPropagation();

                // Check if it's a community channel FIRST
                if (channelItem.dataset.isCommunity === 'true' && channelItem.dataset.community) {
                    // It's a community channel - switch to community
                    const communityId = channelItem.dataset.community;

                    // Don't reload if already in this community
                    if (!nym.inPMMode && nym.currentCommunity === communityId) {
                        return;
                    }

                    // Add debounce to prevent double-clicks
                    if (channelItem.dataset.clicking === 'true') return;
                    channelItem.dataset.clicking = 'true';

                    nym.switchToCommunity(communityId);

                    // Reset click flag after a short delay
                    setTimeout(() => {
                        delete channelItem.dataset.clicking;
                    }, 1000);
                } else {
                    // Regular channel handling
                    const channel = channelItem.dataset.channel;
                    const geohash = channelItem.dataset.geohash || '';

                    // Don't reload if already in channel
                    if (!nym.inPMMode &&
                        !nym.currentCommunity &&
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

            // Close @ mention autocomplete if clicking outside
            if (!e.target.closest('#autocompleteDropdown') && !e.target.closest('#messageInput')) {
                this.hideAutocomplete();
            }

            // Close enhanced emoji modal if clicking outside
            if (!e.target.closest('.enhanced-emoji-modal') &&
                !e.target.closest('.reaction-btn') &&
                !e.target.closest('.add-reaction-btn') &&
                !e.target.closest('.icon-btn.input-btn[title="Emoji"]') &&
                !e.target.closest('#ctxReact')) {
                this.closeEnhancedEmojiModal();
            }

            // Close GIF picker if clicking outside
            if (!e.target.closest('.gif-picker') &&
                !e.target.closest('.icon-btn[title="GIF"]')) {
                this.closeGifPicker();
            }

            // Handle command palette item click
            if (e.target.closest('.command-item')) {
                this.selectCommand(e.target.closest('.command-item'));
            }
        });

        // File input
        document.getElementById('fileInput').addEventListener('change', (e) => {
            if (e.target.files && e.target.files[0]) {
                this.uploadImage(e.target.files[0]);
            }
        });

        // P2P File input
        document.getElementById('p2pFileInput').addEventListener('change', (e) => {
            if (e.target.files && e.target.files[0]) {
                this.shareP2PFile(e.target.files[0]);
                e.target.value = ''; // Reset for next selection
            }
        });

        // Modal controls
        document.getElementById('channelTypeSelect').addEventListener('change', (e) => {
            const type = e.target.value;
            document.getElementById('standardChannelGroup').style.display =
                type === 'standard' ? 'block' : 'none';
            document.getElementById('geohashGroup').style.display =
                type === 'geohash' ? 'block' : 'none';
            document.getElementById('communityChannelGroup').style.display =
                type === 'community' ? 'block' : 'none';
        });
    }

    setupCommands() {
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
            '/slap': { desc: 'Slap someone with a trout', fn: (args) => this.cmdSlap(args) },
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
            '/invite': { desc: 'Invite a user to current channel', fn: (args) => this.cmdInvite(args) },
            '/share': { desc: 'Share current channel URL', fn: () => this.cmdShare() },
            '/leave': { desc: 'Leave current channel', fn: () => this.cmdLeave() },
            '/quit': { desc: 'Disconnect from NYM', fn: () => this.cmdQuit() },

            // Community channel commands
            '/createcommunity': { desc: 'Create a community channel', fn: (args) => this.cmdCreateCommunity(args) },
            '/cc': { desc: 'Shortcut for /createcommunity', fn: (args) => this.cmdCreateCommunity(args) },
            '/addmod': { desc: 'Add moderator to community', fn: (args) => this.cmdAddMod(args) },
            '/removemod': { desc: 'Remove moderator', fn: (args) => this.cmdRemoveMod(args) },
            '/kick': { desc: 'Kick user from community', fn: (args) => this.cmdKick(args) },
            '/ban': { desc: 'Ban user from community', fn: (args) => this.cmdBan(args) },
            '/unban': { desc: 'Unban user from community', fn: (args) => this.cmdUnban(args) },
            '/invitetocommunity': { desc: 'Invite user to private community', fn: (args) => this.cmdInviteToCommunity(args) },
            '/communityinfo': { desc: 'Show community info', fn: () => this.cmdCommunityInfo() },
            '/ci': { desc: 'Shortcut for /communityinfo', fn: () => this.cmdCommunityInfo() },
            '/members': { desc: 'List community members', fn: () => this.cmdListMembers() },
            '/mods': { desc: 'List community moderators', fn: () => this.cmdListMods() },
            '/communitysettings': { desc: 'Manage community settings', fn: () => this.cmdCommunitySettings() },
            '/cs': { desc: 'Shortcut for /communitysettings', fn: () => this.cmdCommunitySettings() }
        };
    }

    handleInputChange(value) {
        // Check for emoji autocomplete with :
        const colonIndex = value.lastIndexOf(':');
        if (colonIndex !== -1 && colonIndex === value.length - 1 ||
            (colonIndex !== -1 && value.substring(colonIndex).match(/^:[a-z]*$/))) {
            const search = value.substring(colonIndex + 1);
            this.showEmojiAutocomplete(search);
        } else {
            this.hideEmojiAutocomplete();
        }

        // Check for @ mentions
        const lastAtIndex = value.lastIndexOf('@');
        if (lastAtIndex !== -1 && lastAtIndex === value.length - 1 ||
            (lastAtIndex !== -1 && value.substring(lastAtIndex).match(/^@\w*$/))) {
            const search = value.substring(lastAtIndex + 1);
            this.showAutocomplete(search);
        } else {
            this.hideAutocomplete();
        }

        // Check for commands
        if (value.startsWith('/')) {
            this.showCommandPalette(value);
        } else {
            this.hideCommandPalette();
        }
    }

    showEmojiAutocomplete(search) {
        const dropdown = document.getElementById('emojiAutocomplete');

        // Build complete emoji list from all categories
        const allEmojiEntries = [];

        // Add emoji shortcodes
        Object.entries(this.emojiMap).forEach(([name, emoji]) => {
            allEmojiEntries.push({ name, emoji, priority: 1 });
        });

        // Add all categorized emojis with searchable names
        Object.entries(this.allEmojis).forEach(([category, emojis]) => {
            emojis.forEach(emoji => {
                // Try to find a name for this emoji in emojiMap
                const existingEntry = allEmojiEntries.find(e => e.emoji === emoji);
                if (!existingEntry) {
                    // Generate a searchable name from the emoji itself
                    allEmojiEntries.push({
                        name: emoji,
                        emoji,
                        priority: 2
                    });
                }
            });
        });

        // Filter based on search
        let matches = [];
        if (search === '') {
            // Show recent emojis first, then common ones
            const recentSet = new Set(this.recentEmojis);
            matches = [
                ...this.recentEmojis.map(emoji => ({
                    name: Object.entries(this.emojiMap).find(([n, e]) => e === emoji)?.[0] || emoji,
                    emoji
                })),
                ...allEmojiEntries.filter(e => !recentSet.has(e.emoji)).slice(0, 10)
            ].slice(0, 8);
        } else {
            matches = allEmojiEntries
                .filter(entry =>
                    entry.name.toLowerCase().includes(search.toLowerCase()) ||
                    entry.emoji.includes(search)
                )
                .sort((a, b) => a.priority - b.priority)
                .slice(0, 8);
        }

        if (matches.length > 0) {
            dropdown.innerHTML = matches.map(({ name, emoji }, index) => `
                <div class="emoji-item ${index === 0 ? 'selected' : ''}" data-name="${name}" data-emoji="${emoji}">
                    <span class="emoji-item-emoji">${emoji}</span>
                    <span class="emoji-item-name">:${name}:</span>
                </div>
            `).join('');
            dropdown.classList.add('active');
            this.emojiAutocompleteIndex = 0;

            // Add click handlers for each emoji item
            dropdown.querySelectorAll('.emoji-item').forEach((item, index) => {
                item.onclick = (e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    this.emojiAutocompleteIndex = index;
                    // Remove selected from all, add to clicked
                    dropdown.querySelectorAll('.emoji-item').forEach(i => i.classList.remove('selected'));
                    item.classList.add('selected');
                    this.selectEmojiAutocomplete();
                };
            });
        } else {
            this.hideEmojiAutocomplete();
        }
    }

    hideEmojiAutocomplete() {
        document.getElementById('emojiAutocomplete').classList.remove('active');
        this.emojiAutocompleteIndex = -1;
    }

    navigateEmojiAutocomplete(direction) {
        const items = document.querySelectorAll('.emoji-item');
        if (items.length === 0) return;

        items[this.emojiAutocompleteIndex]?.classList.remove('selected');

        this.emojiAutocompleteIndex += direction;
        if (this.emojiAutocompleteIndex < 0) this.emojiAutocompleteIndex = items.length - 1;
        if (this.emojiAutocompleteIndex >= items.length) this.emojiAutocompleteIndex = 0;

        items[this.emojiAutocompleteIndex].classList.add('selected');
        items[this.emojiAutocompleteIndex].scrollIntoView({ block: 'nearest' });
    }

    selectEmojiAutocomplete() {
        const selected = document.querySelector('.emoji-item.selected');
        if (selected) {
            const emoji = selected.dataset.emoji;
            const input = document.getElementById('messageInput');
            const value = input.value;
            const colonIndex = value.lastIndexOf(':');

            input.value = value.substring(0, colonIndex) + emoji + ' ';
            input.focus();
            this.hideEmojiAutocomplete();
            this.addToRecentEmojis(emoji);
        }
    }

    showAutocomplete(search) {
        const dropdown = document.getElementById('autocompleteDropdown');

        // Get current time for activity check
        const now = Date.now();
        const activeThreshold = 300000; // 5 minutes

        // Collect and categorize users
        const onlineUsers = [];
        const offlineUsers = [];

        this.users.forEach((user, pubkey) => {
            // Create formatted nym for matching
            const baseNym = user.nym.split('#')[0] || user.nym;
            const suffix = this.getPubkeySuffix(pubkey);
            const searchableNym = `${baseNym}#${suffix}`;

            if (!this.blockedUsers.has(user.nym) &&
                searchableNym.toLowerCase().includes(search.toLowerCase())) {

                // Create HTML version for display
                const displayNym = `${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>`;

                const userEntry = {
                    nym: user.nym,
                    pubkey: pubkey,
                    displayNym: displayNym,
                    searchableNym: searchableNym,
                    lastSeen: user.lastSeen
                };

                if (now - user.lastSeen < activeThreshold) {
                    onlineUsers.push(userEntry);
                } else {
                    offlineUsers.push(userEntry);
                }
            }
        });

        // Sort each group alphabetically by searchable name
        onlineUsers.sort((a, b) => a.searchableNym.localeCompare(b.searchableNym));
        offlineUsers.sort((a, b) => a.searchableNym.localeCompare(b.searchableNym));

        // Combine with online users first
        const allUsers = [...onlineUsers, ...offlineUsers].slice(0, 8);

        if (allUsers.length > 0) {
            dropdown.innerHTML = allUsers.map((user, index) => {
                const isOnline = now - user.lastSeen < activeThreshold;
                const statusIndicator = isOnline ?
                    '<span style="color: var(--primary); margin-right: 5px;">●</span>' :
                    '<span style="color: var(--text-dim); margin-right: 5px;">○</span>';

                return `
        <div class="autocomplete-item ${index === 0 ? 'selected' : ''}" 
                data-nym="${user.nym}"
                data-pubkey="${user.pubkey}"
                onclick="nym.selectSpecificAutocomplete('${user.nym}', '${user.pubkey}')">
            ${statusIndicator}<strong>@${user.displayNym}</strong>
        </div>
    `;
            }).join('');
            dropdown.classList.add('active');
            this.autocompleteIndex = 0;

            // Add click handlers
            dropdown.querySelectorAll('.autocomplete-item').forEach((item, index) => {
                item.onclick = (e) => {
                    e.preventDefault();
                    e.stopPropagation();
                    this.autocompleteIndex = index;
                    dropdown.querySelectorAll('.autocomplete-item').forEach(i => i.classList.remove('selected'));
                    item.classList.add('selected');
                    this.selectAutocomplete();
                };
            });
        } else {
            this.hideAutocomplete();
        }
    }

    selectSpecificAutocomplete(nym, pubkey) {
        const input = document.getElementById('messageInput');
        const value = input.value;
        const lastAtIndex = value.lastIndexOf('@');

        // Use just the base nym without suffix in the message
        input.value = value.substring(0, lastAtIndex) + '@' + nym + ' ';
        input.focus();
        this.hideAutocomplete();
    }

    hideAutocomplete() {
        document.getElementById('autocompleteDropdown').classList.remove('active');
        this.autocompleteIndex = -1;
    }

    navigateAutocomplete(direction) {
        const items = document.querySelectorAll('.autocomplete-item');
        if (items.length === 0) return;

        items[this.autocompleteIndex]?.classList.remove('selected');

        this.autocompleteIndex += direction;
        if (this.autocompleteIndex < 0) this.autocompleteIndex = items.length - 1;
        if (this.autocompleteIndex >= items.length) this.autocompleteIndex = 0;

        items[this.autocompleteIndex].classList.add('selected');
        items[this.autocompleteIndex].scrollIntoView({ block: 'nearest' });
    }

    selectAutocomplete() {
        const selected = document.querySelector('.autocomplete-item.selected');
        if (selected) {
            const nym = selected.dataset.nym;
            const pubkey = selected.dataset.pubkey;
            const input = document.getElementById('messageInput');
            const value = input.value;
            const lastAtIndex = value.lastIndexOf('@');

            // Use base nym with suffix
            const baseNym = nym.split('#')[0] || nym;
            const suffix = this.getPubkeySuffix(pubkey);
            input.value = value.substring(0, lastAtIndex) + '@' + baseNym + '#' + suffix + ' ';
            input.focus();
            this.hideAutocomplete();
        }
    }

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
    }

    hideCommandPalette() {
        document.getElementById('commandPalette').classList.remove('active');
        this.commandPaletteIndex = -1;
    }

    navigateCommandPalette(direction) {
        const items = document.querySelectorAll('.command-item');
        if (items.length === 0) return;

        items[this.commandPaletteIndex]?.classList.remove('selected');

        this.commandPaletteIndex += direction;
        if (this.commandPaletteIndex < 0) this.commandPaletteIndex = items.length - 1;
        if (this.commandPaletteIndex >= items.length) this.commandPaletteIndex = 0;

        items[this.commandPaletteIndex].classList.add('selected');
        items[this.commandPaletteIndex].scrollIntoView({ block: 'nearest' });
    }

    selectCommand(element = null) {
        const selected = element || document.querySelector('.command-item.selected');
        if (selected) {
            const cmd = selected.dataset.command;
            const input = document.getElementById('messageInput');
            input.value = cmd + ' ';
            input.focus();
            this.hideCommandPalette();
        }
    }

    async sendMessage() {
        const input = document.getElementById('messageInput');
        const content = input.value.trim();

        if (!content) return;

        if (!this.connected) {
            this.displaySystemMessage('Not connected to relay. Please wait...');
            return;
        }

        // Add to history
        this.commandHistory.push(content);
        this.historyIndex = this.commandHistory.length;

        if (content.startsWith('/')) {
            this.handleCommand(content);
        } else {
            if (this.inPMMode && this.currentPM) {
                // Send PM
                await this.sendPM(content, this.currentPM);
            } else if (this.currentCommunity) {
                // Send to community (kind 4550)
                await this.publishCommunityMessage(content, this.currentCommunity);
            } else if (this.currentGeohash) {
                // Send to geohash channel (kind 20000)
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
            } else {
                // Send to standard channel (kind 23333)
                await this.publishMessage(content, this.currentChannel, '');
            }
        }

        input.value = '';
        this.autoResizeTextarea(input);
        this.hideCommandPalette();
        this.hideAutocomplete();
        this.hideEmojiAutocomplete();
    }

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
    }

    // Command implementations
    showHelp() {
        const helpText = Object.entries(this.commands)
            .map(([cmd, info]) => `${cmd} - ${info.desc}  \n`)
            .join('');

        this.displaySystemMessage(
            `Available commands:  \n${helpText}\n\nMarkdown supported: **bold**, *italic*, ~~strikethrough~~, \`code\`, > quote\n\nType : to quickly pick an emoji\n\nNyms are shown as name#xxxx where xxxx is the last 4 characters of their pubkey\n\nClick on users for more options`
        );
    }

    async cmdJoin(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /join channel, /join #geohash, or /join communityname');
            return;
        }

        let channel = args.trim().toLowerCase();

        // Check if it's a geohash (starts with #)
        if (channel.startsWith('#')) {
            const geohash = channel.substring(1);

            // Validate geohash
            if (!this.isValidGeohash(geohash)) {
                this.displaySystemMessage('Invalid geohash format');
                return;
            }

            this.addChannel(geohash, geohash);
            this.switchChannel(geohash, geohash);
            this.userJoinedChannels.add(geohash);
            this.saveUserChannels();
            return;
        }

        // Check if this might be a community channel
        let matchedCommunity = null;
        let matchedCommunityId = null;

        // Search through known communities
        this.communityChannels.forEach((community, id) => {
            if (community.name.toLowerCase() === channel ||
                id.toLowerCase() === channel ||
                id.toLowerCase().startsWith(channel + '-')) {
                matchedCommunity = community;
                matchedCommunityId = id;
            }
        });

        if (matchedCommunity) {
            // This is a community channel
            if (this.connectionMode === 'ephemeral') {
                this.displaySystemMessage('═══ ERROR: Cannot Join Community ═══');
                this.displaySystemMessage('Community channels require a persistent identity.');
                this.displaySystemMessage('Please reconnect using a Nostr extension or NSEC to join communities.');
                this.displaySystemMessage('Ephemeral users can only join standard (EPH) and geohash (GEO) channels.');
                return;
            }

            // CHECK IF TEMPORARILY KICKED
            if (this.communityTemporaryKicks && this.communityTemporaryKicks.has(matchedCommunityId)) {
                const kicks = this.communityTemporaryKicks.get(matchedCommunityId);
                if (kicks.has(this.pubkey)) {
                    const kickExpiry = kicks.get(this.pubkey);
                    if (Date.now() < kickExpiry) {
                        const minutesLeft = Math.ceil((kickExpiry - Date.now()) / 60000);
                        this.displaySystemMessage(`You are temporarily kicked from this community. Try again in ${minutesLeft} minute${minutesLeft !== 1 ? 's' : ''}.`);
                        return;
                    } else {
                        // Kick expired, remove it
                        kicks.delete(this.pubkey);
                    }
                }
            }

            // CHECK IF BANNED
            if (this.communityBans.has(matchedCommunityId) &&
                this.communityBans.get(matchedCommunityId).has(this.pubkey)) {
                this.displaySystemMessage(`You are banned from the community "${matchedCommunity.name}".`);
                return;
            }

            // Check if it's a private community and user has access
            if (matchedCommunity.isPrivate) {
                const isAdmin = matchedCommunity.admin === this.pubkey;
                const isMod = this.communityModerators.has(matchedCommunityId) &&
                    this.communityModerators.get(matchedCommunityId).has(this.pubkey);
                const isMember = this.communityMembers.has(matchedCommunityId) &&
                    this.communityMembers.get(matchedCommunityId).has(this.pubkey);
                const isInvited = this.communityInvites.has(matchedCommunityId) &&
                    this.communityInvites.get(matchedCommunityId).has(this.pubkey);

                if (!isAdmin && !isMod && !isMember && !isInvited) {
                    this.displaySystemMessage('This is a private community. You need an invitation to join.');
                    return;
                }

                // If invited, add to members
                if (isInvited) {
                    if (!this.communityMembers.has(matchedCommunityId)) {
                        this.communityMembers.set(matchedCommunityId, new Set());
                    }
                    this.communityMembers.get(matchedCommunityId).add(this.pubkey);

                    // Remove from invites
                    this.communityInvites.get(matchedCommunityId).delete(this.pubkey);
                }
            } else {
                // Public community - add user as member
                if (!this.communityMembers.has(matchedCommunityId)) {
                    this.communityMembers.set(matchedCommunityId, new Set());
                }
                this.communityMembers.get(matchedCommunityId).add(this.pubkey);
            }

            // Add to UI if not already present
            if (!document.querySelector(`[data-community="${matchedCommunityId}"]`)) {
                this.addCommunityChannel(matchedCommunity.name, matchedCommunityId, matchedCommunity.isPrivate);
            }

            // Switch to the community
            this.switchToCommunity(matchedCommunityId);
            this.userJoinedChannels.add(matchedCommunityId);
            this.saveUserChannels();

            this.displaySystemMessage(`Joined ${matchedCommunity.isPrivate ? 'private' : 'public'} community: ${matchedCommunity.name}`);
            return;
        }

        // Validate standard channel name - no spaces allowed
        if (channel.includes(' ')) {
            this.displaySystemMessage('Channel names cannot contain spaces. Use hyphens instead (e.g., "my-channel")');
            return;
        }

        // Sanitize channel name
        channel = channel.toLowerCase().replace(/[^a-z0-9-]/g, '');

        if (!channel) {
            this.displaySystemMessage('Invalid channel name. Use only letters, numbers, and hyphens.');
            return;
        }

        // Standard channel
        this.addChannel(channel, '');
        this.switchChannel(channel, '');

        // Create channel with kind 23333
        await this.createChannel(channel);
        this.userJoinedChannels.add(channel);
        this.saveUserChannels();
    }

    async cmdLeave() {
        if (this.inPMMode) {
            this.displaySystemMessage('Use /pm to switch channels or close PMs from the sidebar');
            return;
        }

        if (this.currentChannel === 'bar' && !this.currentGeohash && !this.currentCommunity) {
            this.displaySystemMessage('Cannot leave the default #bar channel');
            return;
        }

        if (this.currentCommunity) {
            const community = this.communityChannels.get(this.currentCommunity);

            // Check if this is a public community (just discovered, not owned/moderated/member)
            const isOwned = this.ownedCommunities.has(this.currentCommunity);
            const isModerated = this.moderatedCommunities.has(this.currentCommunity);
            const isMember = this.communityMembers.has(this.currentCommunity) &&
                this.communityMembers.get(this.currentCommunity).has(this.pubkey);

            if (community && !community.isPrivate && !isOwned && !isModerated && !isMember) {
                // Public community - just remove from sidebar (will be re-discovered)
                const element = document.querySelector(`[data-community="${this.currentCommunity}"]`);
                if (element) {
                    element.remove();
                }
                this.channels.delete(this.currentCommunity);
                this.userJoinedChannels.delete(this.currentCommunity);
                this.displaySystemMessage(`Left public community: ${community.name}`);
                this.switchChannel('bar', '');
                return;
            }

            // For owned/moderated/member communities, can't leave
            if (isOwned) {
                this.displaySystemMessage('You cannot leave a community you created. Use /communitysettings to delete it.');
                return;
            }

            if (isModerated || isMember) {
                this.displaySystemMessage('Use community settings or contact admin to leave this community');
                return;
            }
        }

        this.removeChannel(this.currentChannel, this.currentGeohash);
    }


    async cmdPM(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /pm nym, /pm nym#xxxx, or /pm [pubkey]');
            return;
        }

        const targetInput = args.trim();

        // Check if input is a pubkey (64 hex characters)
        if (/^[0-9a-f]{64}$/i.test(targetInput)) {
            const targetPubkey = targetInput.toLowerCase();

            if (targetPubkey === this.pubkey) {
                this.displaySystemMessage("You can't send private messages to yourself");
                return;
            }

            // Get nym from pubkey
            const targetNym = this.getNymFromPubkey(targetPubkey);
            this.openUserPM(targetNym, targetPubkey);
            return;
        }

        // Handle both nym and nym#xxxx formats
        let searchNym = targetInput;
        let searchSuffix = null;

        const hashIndex = targetInput.indexOf('#');
        if (hashIndex !== -1) {
            searchNym = targetInput.substring(0, hashIndex);
            searchSuffix = targetInput.substring(hashIndex + 1);
        }

        // Find user by nym, considering suffix if provided
        const matches = [];
        this.users.forEach((user, pubkey) => {
            const baseNym = user.nym.split('#')[0] || user.nym;
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
            this.displaySystemMessage(`Multiple users found with nym "${searchNym}": ${matchList}`);
            this.displaySystemMessage('Please specify using the #xxxx suffix or full pubkey');
            return;
        }

        // Single match or exact suffix match
        const targetPubkey = matches[0].pubkey;
        const targetNym = matches[0].nym;

        if (targetPubkey === this.pubkey) {
            this.displaySystemMessage("You can't send private messages to yourself");
            return;
        }

        this.openUserPM(targetNym, targetPubkey);
    }

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

        this.nym = newNym;
        document.getElementById('currentNym').textContent = this.nym;

        // Save profile for persistent connections
        if (this.connectionMode !== 'ephemeral') {
            await this.saveToNostrProfile();
        }

        const changeMessage = `Your nym's new nick is now ${this.nym}`;
        this.displaySystemMessage(changeMessage);
    }

    async cmdWho() {
        const currentChannelKey = this.currentGeohash || this.currentChannel;
        const channelUserSet = this.channelUsers.get(currentChannelKey) || new Set();

        const users = Array.from(channelUserSet)
            .map(pubkey => this.users.get(pubkey))
            .filter(u => u && Date.now() - u.lastSeen < 300000)
            .filter(u => !this.blockedUsers.has(u.nym))
            .map(u => {
                const baseNym = u.nym.split('#')[0] || u.nym;
                const suffix = this.getPubkeySuffix(u.pubkey);
                return `${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>`;
            })
            .join(', ');

        this.displaySystemMessage(`Online nyms in this channel: ${users || 'none'}`);
    }

    async cmdClear() {
        document.getElementById('messagesContainer').innerHTML = '';
        this.displaySystemMessage('Chat cleared');
    }

    async cmdInvite(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /invite nym, /invite nym#xxxx, or /invite [pubkey]');
            return;
        }

        if (this.inPMMode) {
            this.displaySystemMessage('Cannot invite users while in PM mode');
            return;
        }

        const targetInput = args.trim();
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
                const baseNym = user.nym.split('#')[0] || user.nym;
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
                this.displaySystemMessage(`Multiple users found with nym "${searchNym}": ${matchList}`);
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

        // Determine if target is ephemeral (check if they have a persistent identity)
        const targetIsEphemeral = await this.isUserEphemeral(targetPubkey);

        // Create channel info with proper type detection
        let channelInfo;
        let joinCommand;
        let canJoin = true;

        if (this.currentCommunity) {
            // Community channel
            const community = this.communityChannels.get(this.currentCommunity);
            const privacyType = community?.isPrivate ? 'private' : 'public';
            channelInfo = `#${community?.name || this.currentCommunity} [${privacyType.toUpperCase()} COMMUNITY]`;
            joinCommand = `/join ${community?.name || this.currentCommunity}`;

            // Check if target is ephemeral - they can't join communities
            if (targetIsEphemeral) {
                canJoin = false;
            }
        } else if (this.currentGeohash) {
            // Geohash channel
            channelInfo = `#${this.currentGeohash} [GEO]`;
            joinCommand = `/join #${this.currentGeohash}`;
        } else {
            // Standard channel
            channelInfo = `#${this.currentChannel} [EPH]`;
            joinCommand = `/join ${this.currentChannel}`;
        }

        // Send an invitation as a PM
        let inviteMessage;
        if (canJoin) {
            inviteMessage = `📨 Channel Invitation: You've been invited to join ${channelInfo}. Use ${joinCommand} to join!`;
        } else {
            inviteMessage = `📨 Channel Invitation: You've been invited to join ${channelInfo}. However, community channels require a persistent identity (extension or nsec login). Ephemeral users cannot join communities.`;
        }

        // Send as PM
        const sent = await this.sendPM(inviteMessage, targetPubkey);

        if (sent) {
            const displayNym = this.formatNymWithPubkey(matchedNym, targetPubkey);
            if (canJoin) {
                this.displaySystemMessage(`Invitation sent to ${displayNym} for ${channelInfo}`);
            } else {
                this.displaySystemMessage(`Invitation sent to ${displayNym} for ${channelInfo} (Note: They cannot join as an ephemeral user)`);
            }

            // Also send a mention in the current channel (only if they can join)
            if (canJoin) {
                const publicNotice = `@${matchedNym} you've been invited to this channel! Check your PMs for details.`;

                if (this.currentCommunity) {
                    await this.publishCommunityMessage(publicNotice, this.currentCommunity);
                } else {
                    await this.publishMessage(publicNotice, this.currentChannel, this.currentGeohash);
                }
            }
        } else {
            this.displaySystemMessage(`Failed to send invitation to ${this.formatNymWithPubkey(matchedNym, targetPubkey)}`);
        }
    }

    // Helper function to check if user is ephemeral
    async isUserEphemeral(pubkey) {
        // A user is ephemeral if they don't have a profile (kind 0 event)
        // We can check if we have their profile data
        return new Promise((resolve) => {
            const subId = "check-ephemeral-" + Math.random().toString(36).substring(7);
            let found = false;

            const timeout = setTimeout(() => {
                this.sendToRelay(["CLOSE", subId]);
                resolve(true); // No profile found, likely ephemeral
            }, 2000);

            // Temporary handler for this check
            const originalHandler = this.handleRelayMessage.bind(this);
            this.handleRelayMessage = (msg, relayUrl) => {
                if (Array.isArray(msg) && msg[0] === 'EVENT' && msg[1] === subId) {
                    const event = msg[2];
                    if (event && event.kind === 0 && event.pubkey === pubkey) {
                        found = true;
                        clearTimeout(timeout);
                        this.handleRelayMessage = originalHandler;
                        this.sendToRelay(["CLOSE", subId]);
                        resolve(false); // Has profile, not ephemeral
                    }
                } else if (Array.isArray(msg) && msg[0] === 'EOSE' && msg[1] === subId) {
                    clearTimeout(timeout);
                    this.handleRelayMessage = originalHandler;
                    this.sendToRelay(["CLOSE", subId]);
                    resolve(!found); // If no profile found, they're ephemeral
                }
                originalHandler(msg, relayUrl);
            };

            // Request user's profile
            const subscription = [
                "REQ",
                subId,
                {
                    kinds: [0],
                    authors: [pubkey],
                    limit: 1
                }
            ];

            this.sendToRelay(subscription);
        });
    }

    async cmdCreateCommunity(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /createcommunity name [description] [--private]');
            this.displaySystemMessage('Example: /createcommunity bitcoin "Bitcoin discussion" --private');
            this.displaySystemMessage('Note: Community names cannot contain spaces. Use hyphens instead.');
            return;
        }

        if (this.connectionMode === 'ephemeral') {
            this.displaySystemMessage('Community channels require a persistent identity. Please use extension or nsec login.');
            return;
        }

        const parts = args.split('"');
        const name = parts[0].trim().replace('--private', '').trim();
        const description = parts[1] || '';
        const isPrivate = args.includes('--private');

        if (!name) {
            this.displaySystemMessage('Please provide a community name');
            return;
        }

        // Validate name - no spaces allowed
        if (name.includes(' ')) {
            this.displaySystemMessage('Community names cannot contain spaces. Use hyphens instead (e.g., "my-community")');
            return;
        }

        const communityId = await this.createCommunityChannel(name, description, isPrivate);

        if (communityId) {
            this.switchToCommunity(communityId);
        }
    }

    async cmdAddMod(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /addmod nym, /addmod nym#xxxx, or /addmod [pubkey]');
            return;
        }

        if (!this.currentCommunity) {
            this.displaySystemMessage('You must be in a community channel to use /addmod');
            return;
        }

        const community = this.communityChannels.get(this.currentCommunity);
        if (!community) {
            this.displaySystemMessage('Current community not found');
            return;
        }

        // Only admin can add moderators
        if (!this.ownedCommunities.has(this.currentCommunity)) {
            this.displaySystemMessage('Only the community admin can add moderators');
            return;
        }

        const targetPubkey = await this.findUserPubkey(args.trim());
        if (!targetPubkey) return;

        const matchedNym = this.getNymFromPubkey(targetPubkey);

        if (targetPubkey === this.pubkey) {
            this.displaySystemMessage("You're already the admin (and a moderator)");
            return;
        }

        // Check if already a moderator
        if (this.communityModerators.has(this.currentCommunity) &&
            this.communityModerators.get(this.currentCommunity).has(targetPubkey)) {
            this.displaySystemMessage(`${this.formatNymWithPubkey(matchedNym, targetPubkey)} is already a moderator`);
            return;
        }

        // Add as moderator
        if (!this.communityModerators.has(this.currentCommunity)) {
            this.communityModerators.set(this.currentCommunity, new Set());
        }
        this.communityModerators.get(this.currentCommunity).add(targetPubkey);

        // Update community definition
        await this.updateCommunityDefinitionWithBans(this.currentCommunity);

        // Parse base nym from display format - this removes HTML tags
        const parsedNym = this.parseNymFromDisplay(matchedNym);
        // Get just the base nym without any suffix
        const baseNym = parsedNym.split('#')[0] || parsedNym;
        const suffix = this.getPubkeySuffix(targetPubkey);
        const fullNym = `${baseNym}#${suffix}`;

        const displayNym = this.formatNymWithPubkey(matchedNym, targetPubkey);
        this.displaySystemMessage(`Added ${displayNym} as a moderator`);

        // Announce in channel with full nym#suffix
        await this.publishCommunityMessage(`⭐ ${fullNym} is now a moderator of this community`, this.currentCommunity);
    }

    async cmdRemoveMod(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /removemod nym, /removemod nym#xxxx, or /removemod [pubkey]');
            return;
        }

        if (!this.currentCommunity) {
            this.displaySystemMessage('You must be in a community channel to use /removemod');
            return;
        }

        const community = this.communityChannels.get(this.currentCommunity);
        if (!community) {
            this.displaySystemMessage('Current community not found');
            return;
        }

        // Only admin can remove moderators
        if (!this.ownedCommunities.has(this.currentCommunity)) {
            this.displaySystemMessage('Only the community admin can remove moderators');
            return;
        }

        const targetPubkey = await this.findUserPubkey(args.trim());
        if (!targetPubkey) return;

        const matchedNym = this.getNymFromPubkey(targetPubkey);

        if (targetPubkey === this.pubkey) {
            this.displaySystemMessage("You can't remove yourself as admin");
            return;
        }

        // Check if actually a moderator
        if (!this.communityModerators.has(this.currentCommunity) ||
            !this.communityModerators.get(this.currentCommunity).has(targetPubkey)) {
            this.displaySystemMessage(`${this.formatNymWithPubkey(matchedNym, targetPubkey)} is not a moderator`);
            return;
        }

        // Remove from moderators
        this.communityModerators.get(this.currentCommunity).delete(targetPubkey);

        // Update community definition
        await this.updateCommunityDefinitionWithBans(this.currentCommunity);

        // Parse base nym from display format - this removes HTML tags
        const parsedNym = this.parseNymFromDisplay(matchedNym);
        // Get just the base nym without any suffix
        const baseNym = parsedNym.split('#')[0] || parsedNym;
        const suffix = this.getPubkeySuffix(targetPubkey);
        const fullNym = `${baseNym}#${suffix}`;

        const displayNym = this.formatNymWithPubkey(matchedNym, targetPubkey);
        this.displaySystemMessage(`Removed ${displayNym} as a moderator`);

        // Announce in channel with full nym#suffix
        await this.publishCommunityMessage(`📋 ${fullNym} is no longer a moderator of this community`, this.currentCommunity);
    }

    async cmdKick(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /kick nym, /kick nym#xxxx, or /kick [pubkey]');
            return;
        }

        if (!this.currentCommunity) {
            this.displaySystemMessage('You must be in a community channel to use /kick');
            return;
        }

        const community = this.communityChannels.get(this.currentCommunity);
        if (!community) {
            this.displaySystemMessage('Current community not found');
            return;
        }

        // Check if user is admin or moderator
        const isAdmin = this.ownedCommunities.has(this.currentCommunity);
        const isMod = this.communityModerators.has(this.currentCommunity) &&
            this.communityModerators.get(this.currentCommunity).has(this.pubkey);

        if (!isAdmin && !isMod) {
            this.displaySystemMessage('Only admins and moderators can kick users');
            return;
        }

        const targetPubkey = await this.findUserPubkey(args.trim());
        if (!targetPubkey) return;

        const targetNym = this.getNymFromPubkey(targetPubkey);

        // Parse base nym from display format
        const parsedNym = this.parseNymFromDisplay(targetNym);
        const baseNym = parsedNym.split('#')[0] || parsedNym;
        const suffix = this.getPubkeySuffix(targetPubkey);
        const fullNym = `${baseNym}#${suffix}`;

        // Don't allow kicking admin
        if (targetPubkey === community.admin) {
            this.displaySystemMessage("You can't kick the community admin");
            return;
        }

        // Mods can't kick other mods
        if (isMod && !isAdmin) {
            const targetIsMod = this.communityModerators.has(this.currentCommunity) &&
                this.communityModerators.get(this.currentCommunity).has(targetPubkey);
            if (targetIsMod) {
                this.displaySystemMessage("Moderators can't kick other moderators");
                return;
            }
        }

        // Initialize temporary kicks map if needed
        if (!this.communityTemporaryKicks) {
            this.communityTemporaryKicks = new Map();
        }
        if (!this.communityTemporaryKicks.has(this.currentCommunity)) {
            this.communityTemporaryKicks.set(this.currentCommunity, new Map());
        }

        // Add temporary kick (15 minutes)
        const kickExpiry = Date.now() + (15 * 60 * 1000); // 15 minutes
        this.communityTemporaryKicks.get(this.currentCommunity).set(targetPubkey, kickExpiry);

        // Publish kick event as NIP-56 moderation event (kind 1984)
        const kickEvent = {
            kind: 1984,
            created_at: Math.floor(Date.now() / 1000),
            tags: [
                ['a', `34550:${community.admin}:${this.currentCommunity}`],
                ['p', targetPubkey],
                ['action', 'kick'],
                ['expiry', kickExpiry.toString()]
            ],
            content: `Kicked from community for 15 minutes`,
            pubkey: this.pubkey
        };

        // Sign the event
        const signedEvent = await this.signEvent(kickEvent);

        // Send the signed event
        this.sendToRelay(["EVENT", signedEvent]);

        const displayNym = this.formatNymWithPubkey(targetNym, targetPubkey);
        this.displaySystemMessage(`Kicked ${displayNym} from this community (15 min cooldown)`);

        // Also announce in the community channel
        await this.publishCommunityMessage(`👢 ${fullNym} has been kicked from this community (15 min cooldown)`, this.currentCommunity);

        // Set up auto-cleanup after 15 minutes
        setTimeout(() => {
            if (this.communityTemporaryKicks.has(this.currentCommunity)) {
                const kicks = this.communityTemporaryKicks.get(this.currentCommunity);
                if (kicks.has(targetPubkey)) {
                    kicks.delete(targetPubkey);
                }
            }
        }, 15 * 60 * 1000);
    }

    async cmdBan(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /ban nym, /ban nym#xxxx, or /ban [pubkey]');
            return;
        }

        if (!this.currentCommunity) {
            this.displaySystemMessage('You must be in a community channel to use /ban');
            return;
        }

        const community = this.communityChannels.get(this.currentCommunity);
        if (!community) {
            this.displaySystemMessage('Current community not found');
            return;
        }

        // Check if user is admin or moderator
        const isAdmin = this.ownedCommunities.has(this.currentCommunity);
        const isMod = this.communityModerators.has(this.currentCommunity) &&
            this.communityModerators.get(this.currentCommunity).has(this.pubkey);

        if (!isAdmin && !isMod) {
            this.displaySystemMessage('Only admins and moderators can ban users');
            return;
        }

        const targetPubkey = await this.findUserPubkey(args.trim());
        if (!targetPubkey) return;

        const targetNym = this.getNymFromPubkey(targetPubkey);

        if (targetPubkey === this.pubkey) {
            this.displaySystemMessage("You can't ban yourself");
            return;
        }

        // Check if already banned
        if (this.communityBans.has(this.currentCommunity) &&
            this.communityBans.get(this.currentCommunity).has(targetPubkey)) {
            this.displaySystemMessage(`${this.formatNymWithPubkey(targetNym, targetPubkey)} is already banned`);
            return;
        }

        // Add to bans
        if (!this.communityBans.has(this.currentCommunity)) {
            this.communityBans.set(this.currentCommunity, new Set());
        }
        this.communityBans.get(this.currentCommunity).add(targetPubkey);

        // Remove from moderators if they were one
        if (this.communityModerators.has(this.currentCommunity)) {
            this.communityModerators.get(this.currentCommunity).delete(targetPubkey);
        }

        // Clean up messages from banned user immediately
        if (this.messages.has(this.currentCommunity)) {
            this.messages.get(this.currentCommunity).forEach(msg => {
                if (msg.pubkey === targetPubkey) {
                    msg.blocked = true;
                }
            });
        }

        // Remove from DOM immediately
        document.querySelectorAll(`.message[data-pubkey="${targetPubkey}"]`).forEach(msg => {
            if (msg.closest('.messages-container')?.dataset.lastCommunity === this.currentCommunity) {
                msg.remove();
            }
        });

        // Update community definition
        await this.updateCommunityDefinitionWithBans(this.currentCommunity);

        // Parse base nym from display format - this removes HTML tags
        const parsedNym = this.parseNymFromDisplay(targetNym);
        // Get just the base nym without any suffix
        const baseNym = parsedNym.split('#')[0] || parsedNym;
        const suffix = this.getPubkeySuffix(targetPubkey);
        const fullNym = `${baseNym}#${suffix}`;

        const displayNym = this.formatNymWithPubkey(targetNym, targetPubkey);
        this.displaySystemMessage(`Banned ${displayNym} from this community`);

        // Announce in channel with full nym#suffix
        await this.publishCommunityMessage(`🚫 ${fullNym} has been banned from this community`, this.currentCommunity);
    }

    async cmdUnban(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /unban nym, /unban nym#xxxx, or /unban [pubkey]');
            return;
        }

        if (!this.currentCommunity) {
            this.displaySystemMessage('You must be in a community channel to use /unban');
            return;
        }

        const community = this.communityChannels.get(this.currentCommunity);
        if (!community) {
            this.displaySystemMessage('Current community not found');
            return;
        }

        // Check if user is admin or moderator
        const isAdmin = this.ownedCommunities.has(this.currentCommunity);
        const isMod = this.communityModerators.has(this.currentCommunity) &&
            this.communityModerators.get(this.currentCommunity).has(this.pubkey);

        if (!isAdmin && !isMod) {
            this.displaySystemMessage('Only admins and moderators can unban users');
            return;
        }

        const targetPubkey = await this.findUserPubkey(args.trim());
        if (!targetPubkey) return;

        const targetNym = this.getNymFromPubkey(targetPubkey);

        // Parse base nym from display format
        const parsedNym = this.parseNymFromDisplay(targetNym);
        const baseNym = parsedNym.split('#')[0] || parsedNym;
        const suffix = this.getPubkeySuffix(targetPubkey);
        const fullNym = `${baseNym}#${suffix}`;

        // Check if actually banned
        if (!this.communityBans.has(this.currentCommunity) ||
            !this.communityBans.get(this.currentCommunity).has(targetPubkey)) {
            this.displaySystemMessage(`${this.formatNymWithPubkey(targetNym, targetPubkey)} is not banned`);
            return;
        }

        // Remove from bans
        this.communityBans.get(this.currentCommunity).delete(targetPubkey);

        // Update community definition
        await this.updateCommunityDefinitionWithBans(this.currentCommunity);

        // Re-subscribe to the unbanned user's messages for this community
        if (this.connected && this.relay) {
            const filter = {
                kinds: [1],
                authors: [targetPubkey],
                '#q': [this.currentCommunity],
                since: Math.floor(Date.now() / 1000)
            };

            this.relay.subscribe([filter], {
                onevent: (event) => {
                    this.handleNostrEvent(event);
                },
                oneose: () => {
                }
            });
        }

        const displayNym = this.formatNymWithPubkey(targetNym, targetPubkey);
        this.displaySystemMessage(`Unbanned ${displayNym} from this community`);
        await this.publishCommunityMessage(`✅ ${fullNym} has been unbanned from this community`, this.currentCommunity);
    }

    async cmdInviteToCommunity(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /invitetocommunity nym, /invitetocommunity nym#xxxx, or /invitetocommunity [pubkey]');
            return;
        }

        if (!this.currentCommunity) {
            this.displaySystemMessage('You must be in a community channel to use /invitetocommunity');
            return;
        }

        const community = this.communityChannels.get(this.currentCommunity);
        if (!community) {
            this.displaySystemMessage('Current community not found');
            return;
        }

        // Check if user is a moderator or admin
        const isAdmin = this.ownedCommunities.has(this.currentCommunity);
        const isMod = this.communityModerators.has(this.currentCommunity) &&
            this.communityModerators.get(this.currentCommunity).has(this.pubkey);

        if (!isAdmin && !isMod) {
            this.displaySystemMessage('You must be an admin or moderator to invite users to private communities');
            return;
        }

        const targetInput = args.trim();
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
            // Handle nym with optional suffix
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
                const baseNym = user.nym.split('#')[0] || user.nym;
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
                this.displaySystemMessage(`User ${targetInput} not found`);
                return;
            }

            if (matches.length > 1 && !searchSuffix) {
                const matchList = matches.map(m =>
                    `${this.formatNymWithPubkey(m.nym, m.pubkey)}`
                ).join(', ');
                this.displaySystemMessage(`Multiple users found with nym "${searchNym}": ${matchList}`);
                this.displaySystemMessage('Please specify using the #xxxx suffix or full pubkey');
                return;
            }

            targetPubkey = matches[0].pubkey;
            matchedNym = matches[0].nym;

            if (targetPubkey === this.pubkey) {
                this.displaySystemMessage("You can't invite yourself");
                return;
            }
        }

        // Check if target is banned
        const bannedUsers = this.communityBans.get(this.currentCommunity) || new Set();
        if (bannedUsers.has(targetPubkey)) {
            this.displaySystemMessage(`Cannot invite ${this.formatNymWithPubkey(matchedNym, targetPubkey)} - they are banned from this community`);
            return;
        }

        // Check if target is ephemeral
        const targetIsEphemeral = await this.isUserEphemeral(targetPubkey);
        if (targetIsEphemeral) {
            this.displaySystemMessage(`Cannot invite ${this.formatNymWithPubkey(matchedNym, targetPubkey)} - ephemeral users cannot join communities`);
            return;
        }

        // Check if already invited or member
        if (!this.communityInvites) {
            this.communityInvites = new Map();
        }
        if (!this.communityInvites.has(this.currentCommunity)) {
            this.communityInvites.set(this.currentCommunity, new Set());
        }

        const invitedUsers = this.communityInvites.get(this.currentCommunity);
        if (invitedUsers.has(targetPubkey)) {
            this.displaySystemMessage(`${this.formatNymWithPubkey(matchedNym, targetPubkey)} has already been invited`);
            return;
        }

        // Add to invited users
        invitedUsers.add(targetPubkey);

        // Send PM with invitation details
        const privacyType = community.isPrivate ? 'PRIVATE' : 'PUBLIC';
        const inviteMessage = `📨 Community Invitation: You've been invited to join #${community.name} [${privacyType} COMMUNITY]. Use /join ${community.name} to join!`;

        const sent = await this.sendPM(inviteMessage, targetPubkey);

        const displayNym = this.formatNymWithPubkey(matchedNym, targetPubkey);
        if (sent) {
            this.displaySystemMessage(`Invitation sent to ${displayNym} for community #${community.name}`);

            // Announce in community channel
            await this.publishCommunityMessage(`📨 ${matchedNym} has been invited to this community`, this.currentCommunity);
        } else {
            this.displaySystemMessage(`Failed to send invitation to ${displayNym}`);
        }
    }

    async cmdCommunityInfo() {
        if (!this.isCurrentChannelCommunity()) {
            this.displaySystemMessage('This is not a community channel');
            return;
        }

        const communityId = this.getCurrentCommunityId();
        const community = this.communityChannels.get(communityId);

        if (!community) {
            this.displaySystemMessage('Community info not available');
            return;
        }

        const isAdmin = this.ownedCommunities.has(communityId);
        const isMod = this.communityModerators.has(communityId) &&
            this.communityModerators.get(communityId).has(this.pubkey);
        const type = community.isPrivate ? 'Private' : 'Public';

        const mods = this.communityModerators.get(communityId) || new Set();
        const members = this.communityMembers.get(communityId) || new Set();
        const banned = this.communityBans.get(communityId) || new Set();

        // Deduplicate member count
        const allMembers = new Set();
        allMembers.add(this.pubkey); // Admin
        mods.forEach(modPubkey => allMembers.add(modPubkey));
        members.forEach(memberPubkey => allMembers.add(memberPubkey));

        let info = `
═══ Community Info ═══<br/>
Name: ${community.name}<br/>
Type: ${type}<br/>
Description: ${community.description || 'None'}<br/>
Your Role: ${isAdmin ? 'Admin' : isMod ? 'Moderator' : 'Member'}<br/>
Moderators: ${mods.size}<br/>
Members: ${allMembers.size}<br/>
Banned: ${banned.size}<br/>
Created: ${new Date(community.createdAt).toLocaleDateString()}
`;

        this.displaySystemMessage(info);

        if (isAdmin || isMod) {
            this.displaySystemMessage('Use /members to see all members');
            this.displaySystemMessage('Use /mods to see all moderators');
            this.displaySystemMessage('Use /communitysettings for more options');
        }
    }

    async cmdListMembers() {
        if (!this.isCurrentChannelCommunity()) {
            this.displaySystemMessage('This is not a community channel');
            return;
        }

        const communityId = this.getCurrentCommunityId();

        if (!this.canModerate(communityId)) {
            this.displaySystemMessage('Only admins and moderators can view member list');
            return;
        }

        const members = this.communityMembers.get(communityId) || new Set();
        const community = this.communityChannels.get(communityId);

        if (members.size === 0) {
            this.displaySystemMessage('No members found');
            return;
        }

        let memberList = `═══ Community Members (${members.size}) ═══\n`;

        members.forEach(pubkey => {
            const nym = this.getNymFromPubkey(pubkey);
            const isAdmin = community.admin === pubkey;
            const isMod = this.communityModerators.has(communityId) &&
                this.communityModerators.get(communityId).has(pubkey);

            let role = '';
            if (isAdmin) role = ' [ADMIN]';
            else if (isMod) role = ' [MOD]';

            memberList += `${nym}${role}\n`;
        });

        this.displaySystemMessage(memberList);
    }

    async cmdListMods() {
        if (!this.isCurrentChannelCommunity()) {
            this.displaySystemMessage('This is not a community channel');
            return;
        }

        const communityId = this.getCurrentCommunityId();
        const mods = this.communityModerators.get(communityId) || new Set();
        const community = this.communityChannels.get(communityId);

        let modList = `═══ Community Moderators ═══\n`;
        modList += `Admin: ${this.getNymFromPubkey(community.admin)}\n`;

        if (mods.size > 0) {
            modList += `\nModerators (${mods.size}):\n`;
            mods.forEach(pubkey => {
                const nym = this.getNymFromPubkey(pubkey);
                modList += `${nym}\n`;
            });
        } else {
            modList += '\nNo additional moderators';
        }

        this.displaySystemMessage(modList);
    }

    async cmdCommunitySettings() {
        if (!this.isCurrentChannelCommunity()) {
            this.displaySystemMessage('This is not a community channel');
            return;
        }

        const communityId = this.getCurrentCommunityId();

        if (!this.ownedCommunities.has(communityId)) {
            this.displaySystemMessage('Only community admins can access settings');
            return;
        }

        // Show community settings modal
        this.showCommunitySettingsModal(communityId);
    }

    async cmdBlock(args) {
        if (!args) {
            // If no args, check if in a channel that can be blocked
            if (this.inPMMode) {
                this.displaySystemMessage('Usage: /block nym, /block nym#xxxx, /block [pubkey], or /block #channel');
                return;
            }

            // Check current channel
            const currentChannelName = this.currentGeohash || this.currentChannel;
            if (currentChannelName === 'bar' && !this.currentGeohash) {
                this.displaySystemMessage('Cannot block the default #bar channel');
                return;
            }

            // Block current channel
            if (confirm(`Block channel #${currentChannelName}?`)) {
                if (this.currentGeohash) {
                    this.blockChannel(this.currentGeohash, this.currentGeohash);
                    this.displaySystemMessage(`Blocked geohash channel #${this.currentGeohash}`);
                } else {
                    this.blockChannel(this.currentChannel, '');
                    this.displaySystemMessage(`Blocked channel #${this.currentChannel}`);
                }

                // Switch to #bar
                this.switchChannel('bar', '');

                this.updateBlockedChannelsList();

                // Sync to Nostr
                if (this.connectionMode !== 'ephemeral') {
                    await this.saveSyncedSettings();
                }
            }
            return;
        }

        const target = args.trim();

        // Check if it's a channel block
        if (target.startsWith('#') && !target.includes('@')) {
            const channelName = target.substring(1);

            // Check if it's current channel
            if ((this.currentChannel === channelName && !this.currentGeohash) ||
                (this.currentGeohash === channelName)) {
                // Block current channel and switch to bar
                if (confirm(`Block and leave channel #${channelName}?`)) {
                    if (this.isValidGeohash(channelName)) {
                        this.blockChannel(channelName, channelName);
                        this.displaySystemMessage(`Blocked geohash channel #${channelName}`);
                    } else {
                        this.blockChannel(channelName, '');
                        this.displaySystemMessage(`Blocked channel #${channelName}`);
                    }

                    // Switch to #bar
                    this.switchChannel('bar', '');

                    this.updateBlockedChannelsList();

                    // Sync to Nostr
                    if (this.connectionMode !== 'ephemeral') {
                        await this.saveSyncedSettings();
                    }
                }
                return;
            }

            // Don't allow blocking #bar
            if (channelName === 'bar') {
                this.displaySystemMessage("Cannot block the default #bar channel");
                return;
            }

            // Determine if it's a geohash or standard channel
            if (this.isValidGeohash(channelName)) {
                this.blockChannel(channelName, channelName);
                this.displaySystemMessage(`Blocked geohash channel #${channelName}`);
            } else {
                this.blockChannel(channelName, '');
                this.displaySystemMessage(`Blocked channel #${channelName}`);
            }

            this.updateBlockedChannelsList();

            // Sync to Nostr
            if (this.connectionMode !== 'ephemeral') {
                await this.saveSyncedSettings();
            }

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

            // Save to synced settings for persistent connections
            if (this.connectionMode !== 'ephemeral') {
                await this.saveSyncedSettings();
            }
            return;
        }

        this.blockedUsers.add(targetPubkey);
        this.saveBlockedUsers();
        this.hideMessagesFromBlockedUser(targetPubkey);

        this.displaySystemMessage(`Blocked ${cleanNym}`);
        this.updateUserList();
        this.updateBlockedList();

        // Save to synced settings for persistent connections
        if (this.connectionMode !== 'ephemeral') {
            await this.saveSyncedSettings();
        }
    }

    unblockByPubkey(pubkey) {
        this.blockedUsers.delete(pubkey);
        this.saveBlockedUsers();
        this.showMessagesFromUnblockedUser(pubkey);

        const nym = this.getNymFromPubkey(pubkey);
        this.displaySystemMessage(`Unblocked ${nym}`);
        this.updateUserList();
        this.updateBlockedList();

        // Save to synced settings for persistent connections
        if (this.connectionMode !== 'ephemeral') {
            this.saveSyncedSettings();
        }
    }

    hideMessagesFromBlockedUser(pubkey) {
        // Hide messages in current DOM
        document.querySelectorAll('.message').forEach(msg => {
            if (msg.dataset.pubkey === pubkey) {
                msg.style.display = 'none';
                msg.classList.add('blocked-user-message');
            }
        });

        // Mark messages as blocked in stored messages
        this.messages.forEach((channelMessages, channel) => {
            channelMessages.forEach(msg => {
                if (msg.pubkey === pubkey) {
                    msg.blocked = true;
                }
            });
        });

        // Mark PM messages as blocked
        this.pmMessages.forEach((conversationMessages, conversationKey) => {
            conversationMessages.forEach(msg => {
                if (msg.pubkey === pubkey) {
                    msg.blocked = true;
                }
            });
        });
    }

    hideMessagesWithBlockedKeywords() {
        // Hide messages in current DOM that contain blocked keywords
        document.querySelectorAll('.message').forEach(msg => {
            const content = msg.querySelector('.message-content');
            if (content) {
                const hasBlockedKeyword = Array.from(this.blockedKeywords).some(kw =>
                    content.textContent.toLowerCase().includes(kw)
                );

                if (hasBlockedKeyword) {
                    msg.style.display = 'none';
                    msg.classList.add('blocked');
                }
            }
        });

        // Mark messages as blocked in stored messages
        this.messages.forEach((channelMessages, channel) => {
            channelMessages.forEach(msg => {
                if (this.hasBlockedKeyword(msg.content)) {
                    msg.blocked = true;
                }
            });
        });

        // Mark PM messages as blocked
        this.pmMessages.forEach((conversationMessages, conversationKey) => {
            conversationMessages.forEach(msg => {
                if (this.hasBlockedKeyword(msg.content)) {
                    msg.blocked = true;
                }
            });
        });
    }

    isNymBlocked(nym) {
        const cleanNym = this.parseNymFromDisplay(nym);
        return Array.from(this.blockedUsers).some(blockedNym =>
            this.parseNymFromDisplay(blockedNym) === cleanNym
        );
    }

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

                // Sync to Nostr
                if (this.connectionMode !== 'ephemeral') {
                    await this.saveSyncedSettings();
                }
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

        this.displaySystemMessage(`Unblocked ${this.formatNymWithPubkey(targetNym, targetPubkey)}`);
        this.updateUserList();
        this.updateBlockedList();

        // Save to synced settings for persistent connections
        if (this.connectionMode !== 'ephemeral') {
            await this.saveSyncedSettings();
        }
    }

    showMessagesFromUnblockedUser(pubkey) {
        // Unmark messages in stored messages FIRST
        this.messages.forEach((channelMessages, channel) => {
            channelMessages.forEach(msg => {
                if (msg.pubkey === pubkey) {
                    delete msg.blocked;
                }
            });
        });

        // Unmark PM messages
        this.pmMessages.forEach((conversationMessages, conversationKey) => {
            conversationMessages.forEach(msg => {
                if (msg.pubkey === pubkey) {
                    delete msg.blocked;
                }
            });
        });

        // Show messages in current DOM (unless blocked by keywords)
        document.querySelectorAll('.message.blocked-user-message').forEach(msg => {
            if (msg.dataset.pubkey === pubkey) {
                const content = msg.querySelector('.message-content');
                if (!content || !this.hasBlockedKeyword(content.textContent)) {
                    msg.style.display = '';
                    msg.classList.remove('blocked-user-message');
                }
            }
        });
    }

    async cmdSlap(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /slap nym, /slap nym#xxxx, or /slap [pubkey]');
            return;
        }

        const targetInput = args.trim();
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
                this.displaySystemMessage(`Multiple users found with nym "${searchNym}": ${matchList}`);
                this.displaySystemMessage('Please specify using the #xxxx suffix or full pubkey');
                return;
            }

            // Use the target nym for the action (without HTML tags)
            targetNym = matches.length > 0 ? matches[0].nym : searchNym;
        }

        // Create the slap message content  
        const slapContent = `/me slaps ${targetNym} around a bit with a large trout`;

        // Send the message using the appropriate method based on current context
        try {
            if (this.inPMMode && this.currentPM) {
                // Send as PM
                await this.sendPM(slapContent, this.currentPM);
            } else if (this.currentCommunity) {
                // Send to community channel
                await this.publishCommunityMessage(slapContent, this.currentCommunity);
            } else if (this.currentGeohash) {
                // Send to geohash channel
                await this.publishMessage(slapContent, this.currentGeohash, this.currentGeohash);
            } else {
                // Send to standard ephemeral channel
                await this.publishMessage(slapContent, this.currentChannel, '');
            }
        } catch (error) {
            this.displaySystemMessage('Failed to send slap: ' + error.message);
        }
    }

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
            } else if (this.currentCommunity) {
                // Send to community channel
                await this.publishCommunityMessage(content, this.currentCommunity);
            } else if (this.currentGeohash) {
                // Send to geohash channel
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
            } else {
                // Send to standard ephemeral channel
                await this.publishMessage(content, this.currentChannel, '');
            }
        } catch (error) {
            this.displaySystemMessage('Failed to send message: ' + error.message);
        }
    }

    async cmdShrug() {
        const content = '¯\\_(ツ)_/¯';

        try {
            if (this.inPMMode && this.currentPM) {
                await this.sendPM(content, this.currentPM);
            } else if (this.currentCommunity) {
                await this.publishCommunityMessage(content, this.currentCommunity);
            } else if (this.currentGeohash) {
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
            } else {
                await this.publishMessage(content, this.currentChannel, '');
            }
        } catch (error) {
            this.displaySystemMessage('Failed to send message: ' + error.message);
        }
    }

    async cmdBold(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /bold text');
            return;
        }

        const content = `**${args}**`;

        try {
            if (this.inPMMode && this.currentPM) {
                await this.sendPM(content, this.currentPM);
            } else if (this.currentCommunity) {
                await this.publishCommunityMessage(content, this.currentCommunity);
            } else if (this.currentGeohash) {
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
            } else {
                await this.publishMessage(content, this.currentChannel, '');
            }
        } catch (error) {
            this.displaySystemMessage('Failed to send message: ' + error.message);
        }
    }

    async cmdItalic(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /italic text');
            return;
        }

        const content = `*${args}*`;

        try {
            if (this.inPMMode && this.currentPM) {
                await this.sendPM(content, this.currentPM);
            } else if (this.currentCommunity) {
                await this.publishCommunityMessage(content, this.currentCommunity);
            } else if (this.currentGeohash) {
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
            } else {
                await this.publishMessage(content, this.currentChannel, '');
            }
        } catch (error) {
            this.displaySystemMessage('Failed to send message: ' + error.message);
        }
    }

    async cmdStrike(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /strike text');
            return;
        }

        const content = `~~${args}~~`;

        try {
            if (this.inPMMode && this.currentPM) {
                await this.sendPM(content, this.currentPM);
            } else if (this.currentCommunity) {
                await this.publishCommunityMessage(content, this.currentCommunity);
            } else if (this.currentGeohash) {
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
            } else {
                await this.publishMessage(content, this.currentChannel, '');
            }
        } catch (error) {
            this.displaySystemMessage('Failed to send message: ' + error.message);
        }
    }

    async cmdCode(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /code text');
            return;
        }

        const content = `\`\`\`\n${args}\n\`\`\``;

        try {
            if (this.inPMMode && this.currentPM) {
                await this.sendPM(content, this.currentPM);
            } else if (this.currentCommunity) {
                await this.publishCommunityMessage(content, this.currentCommunity);
            } else if (this.currentGeohash) {
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
            } else {
                await this.publishMessage(content, this.currentChannel, '');
            }
        } catch (error) {
            this.displaySystemMessage('Failed to send message: ' + error.message);
        }
    }

    async cmdQuote(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /quote text');
            return;
        }

        const content = `> ${args}`;

        try {
            if (this.inPMMode && this.currentPM) {
                await this.sendPM(content, this.currentPM);
            } else if (this.currentCommunity) {
                await this.publishCommunityMessage(content, this.currentCommunity);
            } else if (this.currentGeohash) {
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
            } else {
                await this.publishMessage(content, this.currentChannel, '');
            }
        } catch (error) {
            this.displaySystemMessage('Failed to send message: ' + error.message);
        }
    }

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
    }

    async cmdBack() {
        if (this.awayMessages.has(this.pubkey)) {
            this.awayMessages.delete(this.pubkey);

            // Update user status
            if (this.users.has(this.pubkey)) {
                this.users.get(this.pubkey).status = 'online';
            }

            this.displaySystemMessage('Away message cleared - you are back!');

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
    }

    async cmdZap(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /zap nym, /zap nym#xxxx, or /zap [pubkey]');
            return;
        }

        const targetInput = args.trim();

        // Check if input is a pubkey (64 hex characters)
        if (/^[0-9a-f]{64}$/i.test(targetInput)) {
            const targetPubkey = targetInput.toLowerCase();

            if (targetPubkey === this.pubkey) {
                this.displaySystemMessage("You can't zap yourself");
                return;
            }

            const targetNym = this.getNymFromPubkey(targetPubkey);
            const displayNym = this.formatNymWithPubkey(targetNym, targetPubkey);
            this.displaySystemMessage(`Checking if @${displayNym} can receive zaps...`);

            const lnAddress = await this.fetchLightningAddressForUser(targetPubkey);

            if (lnAddress) {
                this.showProfileZapModal(targetPubkey, targetNym, lnAddress);
            } else {
                this.displaySystemMessage(`@${displayNym} cannot receive zaps (no lightning address set)`);
            }
            return;
        }

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
            if (user.nym === searchNym || user.nym.toLowerCase() === searchNym.toLowerCase()) {
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
            this.displaySystemMessage(`User ${targetInput} not found`);
            return;
        }

        if (matches.length > 1 && !searchSuffix) {
            const matchList = matches.map(m =>
                `${this.formatNymWithPubkey(m.nym, m.pubkey)}`
            ).join(', ');
            this.displaySystemMessage(`Multiple users found with nym "${searchNym}": ${matchList}`);
            this.displaySystemMessage('Please specify using the #xxxx suffix or full pubkey');
            return;
        }

        const targetPubkey = matches[0].pubkey;
        const targetNym = matches[0].nym;

        if (targetPubkey === this.pubkey) {
            this.displaySystemMessage("You can't zap yourself");
            return;
        }

        // Check for lightning address
        const displayNym = this.formatNymWithPubkey(targetNym, targetPubkey);
        this.displaySystemMessage(`Checking if @${displayNym} can receive zaps...`);

        const lnAddress = await this.fetchLightningAddressForUser(targetPubkey);

        if (lnAddress) {
            // Show zap modal for profile zap (no messageId)
            this.showProfileZapModal(targetPubkey, targetNym, lnAddress);
        } else {
            this.displaySystemMessage(`@${displayNym} cannot receive zaps (no lightning address set)`);
        }
    }

    async cmdQuit() {
        this.displaySystemMessage('Disconnecting from NYM...');

        // Clear saved connection preferences
        localStorage.removeItem('nym_connection_mode');
        localStorage.removeItem('nym_relay_url');
        localStorage.removeItem('nym_nsec'); // Clear saved nsec

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
    }

    loadBlockedChannels() {
        const saved = localStorage.getItem('nym_blocked_channels');
        if (saved) {
            this.blockedChannels = new Set(JSON.parse(saved));
        }
    }

    saveBlockedChannels() {
        localStorage.setItem('nym_blocked_channels', JSON.stringify(Array.from(this.blockedChannels)));
    }

    isChannelBlocked(channel, geohash) {
        const key = geohash || channel;
        return this.blockedChannels.has(key);
    }

    blockChannel(channel, geohash) {
        const key = geohash || channel;
        this.blockedChannels.add(key);
        this.saveBlockedChannels();

        // Remove from DOM immediately
        const selector = geohash ?
            `[data-geohash="${geohash}"]` :
            `[data-channel="${channel}"][data-geohash=""]`;
        const element = document.querySelector(selector);
        if (element) {
            element.remove();
        }

        // Remove from channels map
        this.channels.delete(key);

        // If currently in this channel, switch to #bar
        if ((this.currentChannel === channel && this.currentGeohash === geohash) ||
            (geohash && this.currentGeohash === geohash)) {
            this.switchChannel('bar', '');
        }

        // Update view more button after removing
        this.updateViewMoreButton('channelList');
    }

    unblockChannel(channel, geohash) {
        const key = geohash || channel;
        this.blockedChannels.delete(key);
        this.saveBlockedChannels();

        // Re-add the channel to the sidebar
        if (geohash) {
            this.addChannel(geohash, geohash);
        } else {
            this.addChannel(channel, '');
        }

        // Update view more button after adding
        this.updateViewMoreButton('channelList');
    }

    updateBlockedChannelsList() {
        const container = document.getElementById('blockedChannelsList');
        if (!container) return;

        if (this.blockedChannels.size === 0) {
            container.innerHTML = '<div style="color: var(--text-dim); font-size: 12px;">No blocked channels</div>';
        } else {
            container.innerHTML = Array.from(this.blockedChannels).map(key => {
                const displayName = this.isValidGeohash(key) ? `#${key} [GEO]` : `#${key} [EPH]`;
                return `
        <div class="blocked-item">
            <span>${this.escapeHtml(displayName)}</span>
            <button class="unblock-btn" onclick="nym.unblockChannelFromSettings('${this.escapeHtml(key)}')">Unblock</button>
        </div>
    `;
            }).join('');
        }
    }

    unblockChannelFromSettings(key) {
        if (this.isValidGeohash(key)) {
            this.unblockChannel(key, key);
        } else {
            this.unblockChannel(key, '');
        }
        this.updateBlockedChannelsList();

        // Sync to Nostr if logged in
        if (this.connectionMode !== 'ephemeral') {
            this.saveSyncedSettings();
        }
    }

    switchChannel(channel, geohash = '') {
        // Store previous state
        const previousChannel = this.currentChannel;
        const previousGeohash = this.currentGeohash;
        const previousCommunity = this.currentCommunity;

        // Check if we're actually switching to a different channel
        const isSameChannel = !this.inPMMode &&
            channel === previousChannel &&
            geohash === previousGeohash &&
            !previousCommunity;

        if (isSameChannel) {
            // Still ensure the sidebar active state is correct (for initialization)
            document.querySelectorAll('.channel-item').forEach(item => {
                const isActive = item.dataset.channel === channel &&
                    item.dataset.geohash === geohash &&
                    !item.dataset.community;
                item.classList.toggle('active', isActive);
            });
            return; // Don't reload the same channel
        }

        this.inPMMode = false;
        this.currentPM = null;
        this.currentChannel = channel;
        this.currentGeohash = geohash;
        this.currentCommunity = null; // Clear community mode

        // Handle geo-relay connections for Bitchat compatibility
        // Clean up previous geo relays if switching away from a geohash channel
        if (previousGeohash && previousGeohash !== geohash) {
            this.cleanupGeoRelays(previousGeohash);
        }

        // Connect to nearby relays for geohash channels (async, non-blocking)
        if (geohash) {
            this.connectToGeoRelays(geohash);
        }

        // Show share button in channel mode
        const shareBtn = document.getElementById('shareChannelBtn');
        if (shareBtn) {
            shareBtn.style.display = 'block';
        }

        const displayName = geohash ? `#${geohash}` : `#${channel}`;
        let fullTitle = displayName;

        // Add channel type label
        if (geohash) {
            // Geohash channel - add location info and label
            const location = this.getGeohashLocation(geohash);

            if (location) {
                fullTitle = `${displayName} <span style="font-size: 12px; color: var(--text-dim);">(Geohash)</span><br/><font size="2" style="color: var(--text-dim);text-shadow:none;"><a style="color: var(--text-dim);text-shadow:none;" href="https://www.openstreetmap.org/search?query=${location}&zoom=5&minlon=-138.55957031250003&minlat=11.953349393643416&maxlon=-97.69042968750001&maxlat=55.25407706707272#map=5/47.81/5.63" target="_blank" rel="noopener">${location}</a></font>`;

                if (this.userLocation && this.settings.sortByProximity) {
                    try {
                        const coords = this.decodeGeohash(geohash);
                        const distance = this.calculateDistance(
                            this.userLocation.lat, this.userLocation.lng,
                            coords.lat, coords.lng
                        );
                        fullTitle = `${displayName} <span style="font-size: 12px; color: var(--text-dim);">(Geohash)</span><br/><font size="2" style="color: var(--text-dim);text-shadow:none;"><a style="color: var(--text-dim);text-shadow:none;" href="https://www.openstreetmap.org/search?query=${location}&zoom=5&minlon=-138.55957031250003&minlat=11.953349393643416&maxlon=-97.69042968750001&maxlat=55.25407706707272#map=5/47.81/5.63" target="_blank" rel="noopener">${location}</a> (${distance.toFixed(1)}km)</font>`;
                    } catch (e) {
                    }
                }
            } else {
                // No location info available, just add label
                fullTitle = `${displayName} <span style="font-size: 12px; color: var(--text-dim);">(Geohash)</span>`;
            }
        } else {
            // Standard ephemeral channel
            fullTitle = `${displayName} <span style="font-size: 12px; color: var(--text-dim);">(Ephemeral)</span>`;
        }

        document.getElementById('currentChannel').innerHTML = fullTitle;

        // Ensure channel exists in sidebar before updating active state
        if (!document.querySelector(`[data-channel="${channel}"][data-geohash="${geohash}"]:not([data-community])`)) {
            this.addChannel(channel, geohash);
        }

        // Update active state
        document.querySelectorAll('.channel-item').forEach(item => {
            const isActive = item.dataset.channel === channel &&
                item.dataset.geohash === geohash &&
                !item.dataset.community; // Make sure it's not a community item
            item.classList.toggle('active', isActive);
        });

        document.querySelectorAll('.pm-item').forEach(item => {
            item.classList.remove('active');
        });

        // Clear unread count
        const unreadKey = geohash ? `#${geohash}` : channel;
        this.clearUnreadCount(unreadKey);

        // Load channel messages only if switching to different channel
        const storageKey = geohash ? `#${geohash}` : channel;
        const previousKey = previousGeohash ? `#${previousGeohash}` : previousChannel;

        if (storageKey !== previousKey || previousCommunity) {
            this.loadChannelMessages(displayName);
        }

        // Update user list for this channel
        this.updateUserList();

        // Close mobile sidebar on mobile
        if (window.innerWidth <= 768) {
            this.closeSidebar();
        }
    }

    switchToCommunity(communityId) {
        const community = this.communityChannels.get(communityId);
        if (!community) {
            this.displaySystemMessage('Community not found');
            return;
        }

        // Check if we're already in this community
        if (!this.inPMMode && this.currentCommunity === communityId) {
            return; // Don't reload the same community
        }

        // Set community mode - clear ALL other modes
        this.inPMMode = false;
        this.currentPM = null;
        this.currentChannel = null; // Clear standard channel
        this.currentGeohash = ''; // Clear geohash
        this.currentCommunity = communityId; // Set community

        // Show share button in community mode
        const shareBtn = document.getElementById('shareChannelBtn');
        if (shareBtn) {
            shareBtn.style.display = 'block';
        }

        document.getElementById('currentChannel').innerHTML = `#${this.escapeHtml(community.name)} <span style="font-size: 12px; color: var(--text-dim);">(Community)</span>`;

        // Update active state - only activate community items
        document.querySelectorAll('.channel-item').forEach(item => {
            const itemCommunity = item.dataset.community || '';
            const isCommunityItem = item.dataset.isCommunity === 'true';

            if (isCommunityItem) {
                item.classList.toggle('active', itemCommunity === communityId);
            } else {
                item.classList.remove('active');
            }
        });

        document.querySelectorAll('.pm-item').forEach(item => {
            item.classList.remove('active');
        });

        // Clear unread count
        this.clearUnreadCount(communityId);

        // Load community messages (will check internally if already loaded)
        this.loadCommunityMessages(communityId);

        // Update user list
        this.updateUserList();

        // Close mobile sidebar
        if (window.innerWidth <= 768) {
            this.closeSidebar();
        }
    }

    loadCommunityMessages(communityId) {
        const container = document.getElementById('messagesContainer');

        // Check if we're loading the same community
        if (container.dataset.lastCommunity === communityId) {
            return;
        }

        // Clear and mark new community
        container.innerHTML = '';
        container.dataset.lastCommunity = communityId;

        // Clear channel marker since we're in a community
        delete container.dataset.lastChannel;

        const community = this.communityChannels.get(communityId);
        if (!community) return;

        // Community messages would be stored under the community ID
        const communityMessages = this.messages.get(communityId) || [];

        // Try to use pre-rendered content for instant display
        const prerenderedContent = this.getPrerenderedContent(communityId);
        if (prerenderedContent && communityMessages.length > 0) {
            // Clone all children from the pre-rendered container
            const fragment = document.createDocumentFragment();
            Array.from(prerenderedContent.children).forEach(child => {
                fragment.appendChild(child.cloneNode(true));
            });

            container.appendChild(fragment);

            // Scroll to bottom after rendering
            if (this.settings.autoscroll) {
                setTimeout(() => {
                    container.scrollTop = container.scrollHeight;
                }, 0);
            }
            return;
        }

        // Fall back to standard rendering if no pre-rendered content
        // Get the ban list for this community BEFORE displaying messages
        const bannedUsers = this.communityBans.get(communityId) || new Set();

        // Filter out messages from banned users AND globally blocked users
        const filteredMessages = communityMessages.filter(msg => {
            // Check if author is banned from THIS community
            if (bannedUsers.has(msg.pubkey)) {
                return false;
            }
            // Check if author is globally blocked (by pubkey or nym)
            if (this.blockedUsers.has(msg.pubkey) || this.isNymBlocked(msg.author) || msg.blocked) {
                return false;
            }
            // Check if message contains blocked keywords for this community
            if (this.hasCommunityBlockedKeyword(msg.content, communityId)) {
                return false;
            }
            // Check if message contains globally blocked keywords
            if (this.hasBlockedKeyword(msg.content)) {
                return false;
            }
            return true;
        });

        filteredMessages.forEach(msg => {
            this.displayMessage(msg);
        });

        if (filteredMessages.length === 0) {
            this.displaySystemMessage(`Welcome to #${community.name}`);
            this.displaySystemMessage(`This is a ${community.isPrivate ? 'private' : 'public'} community`);
        }

        if (this.settings.autoscroll) {
            setTimeout(() => {
                container.scrollTop = container.scrollHeight;
            }, 0);
        }

        // Queue this community for pre-rendering in case we switch away and back
        if (communityMessages.length > 0 && !this.prerenderedChannels.has(communityId)) {
            setTimeout(() => {
                this.prerenderCommunity(communityId);
            }, 1000);
        }
    }

    loadChannelMessages(displayName) {
        const container = document.getElementById('messagesContainer');
        const storageKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;

        // Check if we're loading the same channel
        if (container.dataset.lastChannel === storageKey) {
            return;
        }

        // Clear and mark new channel
        container.innerHTML = '';
        container.dataset.lastChannel = storageKey;

        // Clear community marker since we're in a regular channel
        delete container.dataset.lastCommunity;

        let channelMessages = this.messages.get(storageKey) || [];

        // Try to use pre-rendered content for instant display
        const prerenderedContent = this.getPrerenderedContent(storageKey);
        if (prerenderedContent && channelMessages.length > 0) {
            // Clone all children from the pre-rendered container
            const fragment = document.createDocumentFragment();
            Array.from(prerenderedContent.children).forEach(child => {
                const clone = child.cloneNode(true);

                // Re-attach onclick handler for "Load More" button
                if (clone.dataset.loadMore === 'true') {
                    const originalCount = channelMessages.length;
                    clone.onclick = () => {
                        if (originalCount > 500) {
                            if (confirm(`Loading ${originalCount} messages may slow down your browser. Continue?`)) {
                                this.displayAllChannelMessages(storageKey);
                            }
                        } else {
                            this.displayAllChannelMessages(storageKey);
                        }
                    };
                }

                fragment.appendChild(clone);
            });

            container.appendChild(fragment);

            // Scroll to bottom after rendering
            if (this.settings.autoscroll) {
                setTimeout(() => {
                    container.scrollTop = container.scrollHeight;
                }, 0);
            }
            return;
        }

        // Fall back to standard rendering if no pre-rendered content
        // Limit display to prevent freezing
        const maxDisplayMessages = 500;
        const originalCount = channelMessages.length;

        // Sort messages by timestamp
        channelMessages.sort((a, b) => a.timestamp - b.timestamp);

        // Get only the most recent messages for display
        const messagesToDisplay = channelMessages.slice(-maxDisplayMessages);

        // If we have more messages than we're displaying, show a notice
        if (originalCount > maxDisplayMessages) {
            const loadMoreDiv = document.createElement('div');
            loadMoreDiv.className = 'system-message';
            loadMoreDiv.style.cssText = 'cursor: pointer; color: var(--text-dim); font-size: 12px; text-align: center; padding: 10px;';
            loadMoreDiv.textContent = `Showing most recent ${maxDisplayMessages} messages (${originalCount - maxDisplayMessages} older messages available)`;
            loadMoreDiv.onclick = () => {
                // Load all messages (with a warning)
                if (originalCount > 500) {
                    if (confirm(`Loading ${originalCount} messages may slow down your browser. Continue?`)) {
                        this.displayAllChannelMessages(storageKey);
                    }
                } else {
                    this.displayAllChannelMessages(storageKey);
                }
            };
            container.appendChild(loadMoreDiv);
        }

        // Display messages, filtering out blocked users
        messagesToDisplay.forEach(msg => {
            if (!this.blockedUsers.has(msg.author) && !msg.blocked) {
                this.displayMessage(msg);
            }
        });

        if (channelMessages.length === 0) {
            this.displaySystemMessage(`Joined ${displayName}`);
        }

        // Scroll to bottom after rendering
        if (this.settings.autoscroll) {
            setTimeout(() => {
                container.scrollTop = container.scrollHeight;
            }, 0);
        }

        // Queue this channel for pre-rendering in case we switch away and back
        if (channelMessages.length > 0 && !this.prerenderedChannels.has(storageKey)) {
            // Schedule pre-rendering after a short delay
            setTimeout(() => {
                this.prerenderChannel(storageKey);
            }, 1000);
        }
    }

    displayAllChannelMessages(storageKey) {
        const container = document.getElementById('messagesContainer');
        container.innerHTML = '';

        const channelMessages = this.messages.get(storageKey) || [];

        // Show loading indicator for large sets
        if (channelMessages.length > 1000) {
            this.displaySystemMessage('Loading all messages...');
        }

        // Use requestAnimationFrame to prevent blocking
        let index = 0;
        const batchSize = 50;

        const renderBatch = () => {
            const batch = channelMessages.slice(index, index + batchSize);

            batch.forEach(msg => {
                if (!this.blockedUsers.has(msg.author) && !msg.blocked) {
                    this.displayMessage(msg);
                }
            });

            index += batchSize;

            if (index < channelMessages.length) {
                requestAnimationFrame(renderBatch);
            } else {
                // Finished loading all
                if (this.settings.autoscroll) {
                    container.scrollTop = container.scrollHeight;
                }
            }
        };

        requestAnimationFrame(renderBatch);
    }

    // Pre-render a channel's messages into an off-screen container
    prerenderChannel(storageKey) {
        const channelMessages = this.messages.get(storageKey) || [];

        // Don't pre-render empty channels or channels with very few messages
        if (channelMessages.length < 1) {
            return null;
        }

        // Check if we already have a valid pre-render for this channel
        const currentVersion = channelMessages.length;
        const cachedVersion = this.prerenderedChannelVersions.get(storageKey);

        if (cachedVersion === currentVersion && this.prerenderedChannels.has(storageKey)) {
            return this.prerenderedChannels.get(storageKey);
        }

        // Create an off-screen container
        const container = document.createElement('div');
        container.className = 'prerendered-channel-container';
        container.dataset.storageKey = storageKey;
        // Properly detect geohash by validating the hash portion (after #)
        const possibleGeohash = storageKey.startsWith('#') ? storageKey.substring(1) : '';
        container.dataset.isGeohash = possibleGeohash && this.isValidGeohash(possibleGeohash) ? 'true' : 'false';
        container.style.display = 'none';

        // Sort messages by timestamp
        const sortedMessages = [...channelMessages].sort((a, b) => a.timestamp - b.timestamp);

        // Limit to last 500 messages
        const maxDisplayMessages = 500;
        const messagesToDisplay = sortedMessages.slice(-maxDisplayMessages);

        // If we have more messages than we're displaying, add a "load more" notice
        if (channelMessages.length > maxDisplayMessages) {
            const loadMoreDiv = document.createElement('div');
            loadMoreDiv.className = 'system-message';
            loadMoreDiv.style.cssText = 'cursor: pointer; color: var(--text-dim); font-size: 12px; text-align: center; padding: 10px;';
            loadMoreDiv.textContent = `Showing most recent ${maxDisplayMessages} messages (${channelMessages.length - maxDisplayMessages} older messages available)`;
            loadMoreDiv.dataset.loadMore = 'true';
            loadMoreDiv.dataset.storageKey = storageKey;
            container.appendChild(loadMoreDiv);
        }

        // Render messages directly to the container
        messagesToDisplay.forEach(msg => {
            if (!this.blockedUsers.has(msg.author) && !msg.blocked) {
                const messageEl = this.createMessageElement(msg);
                if (messageEl) {
                    container.appendChild(messageEl);
                }
            }
        });

        // Store the pre-rendered container and its version
        this.prerenderedChannels.set(storageKey, container);
        this.prerenderedChannelVersions.set(storageKey, currentVersion);

        return container;
    }

    // Create a message element without appending to DOM (for pre-rendering)
    createMessageElement(message) {
        // Check if message is from a blocked user
        if (message.blocked || this.blockedUsers.has(message.pubkey) || this.isNymBlocked(message.author)) {
            return null;
        }

        // Check for blocked keywords or spam
        if (this.hasBlockedKeyword(message.content) || this.isSpamMessage(message.content)) {
            return null;
        }

        const time = this.settings.showTimestamps ?
            message.timestamp.toLocaleTimeString('en-US', {
                hour: '2-digit',
                minute: '2-digit',
                hour12: this.settings.timeFormat === '12hr'
            }) : '';

        const userShopItems = this.getUserShopItems(message.pubkey);
        const flairHtml = this.getFlairForUser(message.pubkey);
        const supporterBadge = userShopItems?.supporter ?
            '<span class="supporter-badge"><span class="supporter-badge-icon">🏆</span><span class="supporter-badge-text">Supporter</span></span>' : '';

        const messageEl = document.createElement('div');

        // Check if nym is flooding
        const channelToCheck = message.communityId || message.geohash || message.channel;
        if (!message.isPM && !message.isHistorical && this.isFlooding(message.pubkey, channelToCheck)) {
            messageEl.className = 'message flooded';
        }

        const isMentioned = !message.isOwn && this.isMentioned(message.content);

        // Check for action messages
        if (message.content.startsWith('/me ')) {
            messageEl.className = 'action-message';
            const cleanAuthor = this.parseNymFromDisplay(message.author);
            const authorFlairHtml = this.getFlairForUser(message.pubkey);
            const authorWithFlair = `${this.escapeHtml(cleanAuthor)}#${this.getPubkeySuffix(message.pubkey)}${authorFlairHtml}`;
            const actionContent = message.content.substring(4);
            const formattedAction = this.formatMessage(actionContent);
            messageEl.innerHTML = `* ${authorWithFlair} ${formattedAction}`;
        } else {
            const classes = ['message'];

            if (message.isOwn) {
                classes.push('self');
            } else if (message.isPM) {
                classes.push('pm');
            } else if (isMentioned) {
                classes.push('mentioned');
            }

            if (userShopItems?.style) {
                classes.push(userShopItems.style);
            }
            if (userShopItems?.supporter) {
                classes.push('supporter-style');
            }
            if (Array.isArray(userShopItems?.cosmetics)) {
                if (userShopItems.cosmetics.includes('cosmetic-aura-gold')) {
                    classes.push('cosmetic-aura-gold');
                }
            }

            messageEl.className = classes.join(' ');
            messageEl.dataset.messageId = message.id;
            messageEl.dataset.author = message.author;
            messageEl.dataset.pubkey = message.pubkey;
            messageEl.dataset.timestamp = message.timestamp.getTime();

            const authorClass = message.isOwn ? 'self' : '';
            const userColorClass = this.getUserColorClass(message.pubkey);

            const verifiedBadge = this.isVerifiedDeveloper(message.pubkey) ?
                `<span class="verified-badge" title="${this.verifiedDeveloper.title}">✓</span>` : '';

            const isValidEventId = message.id && /^[0-9a-f]{64}$/i.test(message.id);
            const isMobile = window.innerWidth <= 768;

            const reactionButton = isValidEventId && !isMobile ? `
    <button class="reaction-btn" onclick="nym.showReactionPicker('${message.id}', this)">
        <svg viewBox="0 0 24 24">
            <circle cx="12" cy="12" r="10"></circle>
            <path d="M8 14s1.5 2 4 2 4-2 4-2"></path>
            <circle cx="9" cy="9" r="1"></circle>
            <circle cx="15" cy="9" r="1"></circle>
        </svg>
    </button>
` : '';

            const formattedContent = this.formatMessageWithQuotes(message.content);
            const baseNym = this.parseNymFromDisplay(message.author);
            const displayAuthorBase = `${this.escapeHtml(baseNym)}<span class="nym-suffix">#${this.getPubkeySuffix(message.pubkey)}</span>${flairHtml}`;
            let displayAuthor = displayAuthorBase;
            let authorExtraClass = '';
            if (Array.isArray(userShopItems?.cosmetics) && userShopItems.cosmetics.includes('cosmetic-redacted')) {
                authorExtraClass = 'cosmetic-redacted';
            }

            const fullTimestamp = message.timestamp.toLocaleString('en-US', {
                year: 'numeric',
                month: 'short',
                day: 'numeric',
                hour: '2-digit',
                minute: '2-digit',
                second: '2-digit',
                hour12: this.settings.timeFormat === '12hr'
            });

            let deliveryCheckmark = '';
            if (message.isOwn && message.isPM && message.deliveryStatus) {
                if (message.deliveryStatus === 'read') {
                    deliveryCheckmark = '<span class="delivery-status read" title="Read">✓✓</span>';
                } else if (message.deliveryStatus === 'delivered') {
                    deliveryCheckmark = '<span class="delivery-status delivered" title="Delivered">✓</span>';
                } else if (message.deliveryStatus === 'sent') {
                    deliveryCheckmark = '<span class="delivery-status sent" title="Sent">○</span>';
                }
            }

            messageEl.innerHTML = `
    ${time ? `<span class="message-time ${this.settings.timeFormat === '12hr' ? 'time-12hr' : ''}" data-full-time="${fullTimestamp}" title="${fullTimestamp}">${time}</span>` : ''}
    <span class="message-author ${authorClass} ${userColorClass} ${authorExtraClass}">${displayAuthor}${verifiedBadge}${supporterBadge}:</span>
    <span class="message-content ${userColorClass}">${formattedContent}</span>
    ${reactionButton}
    ${deliveryCheckmark}
`;
        }

        return messageEl;
    }

    // Pre-render a community's messages into an off-screen container
    prerenderCommunity(communityId) {
        const communityMessages = this.messages.get(communityId) || [];
        const community = this.communityChannels.get(communityId);

        // Don't pre-render empty communities or if community doesn't exist
        if (communityMessages.length < 1 || !community) {
            return null;
        }

        // Check if we already have a valid pre-render for this community
        const currentVersion = communityMessages.length;
        const cachedVersion = this.prerenderedChannelVersions.get(communityId);

        if (cachedVersion === currentVersion && this.prerenderedChannels.has(communityId)) {
            return this.prerenderedChannels.get(communityId);
        }

        // Create an off-screen container
        const container = document.createElement('div');
        container.className = 'prerendered-channel-container';
        container.dataset.storageKey = communityId;
        container.dataset.isCommunity = 'true';
        container.style.display = 'none';

        // Get the ban list and filters for this community
        const bannedUsers = this.communityBans.get(communityId) || new Set();

        // Filter messages according to community rules
        const filteredMessages = communityMessages.filter(msg => {
            // Check if author is banned from THIS community
            if (bannedUsers.has(msg.pubkey)) {
                return false;
            }
            // Check if author is globally blocked (by pubkey or nym)
            if (this.blockedUsers.has(msg.pubkey) || this.isNymBlocked(msg.author) || msg.blocked) {
                return false;
            }
            // Check if message contains blocked keywords for this community
            if (this.hasCommunityBlockedKeyword && this.hasCommunityBlockedKeyword(msg.content, communityId)) {
                return false;
            }
            // Check if message contains globally blocked keywords
            if (this.hasBlockedKeyword(msg.content)) {
                return false;
            }
            return true;
        });

        // Sort messages by timestamp
        const sortedMessages = [...filteredMessages].sort((a, b) => a.timestamp - b.timestamp);

        // Limit to last 500 messages
        const maxDisplayMessages = 500;
        const messagesToDisplay = sortedMessages.slice(-maxDisplayMessages);

        // Render messages directly to the container
        messagesToDisplay.forEach(msg => {
            const messageEl = this.createMessageElement(msg);
            if (messageEl) {
                container.appendChild(messageEl);
            }
        });

        // Store the pre-rendered container and its version
        this.prerenderedChannels.set(communityId, container);
        this.prerenderedChannelVersions.set(communityId, currentVersion);

        return container;
    }

    // Invalidate pre-rendered content for a channel (call when new messages arrive)
    invalidatePrerender(storageKey) {
        // Simply remove the cached version so it will be re-rendered on next access
        this.prerenderedChannelVersions.delete(storageKey);

        // Queue this channel for re-prerendering if it has messages
        if (this.messages.has(storageKey) && this.messages.get(storageKey).length > 0) {
            if (!this.prerenderQueue.includes(storageKey)) {
                this.prerenderQueue.push(storageKey);
                this.startBackgroundPrerendering();
            }
        }
    }

    // Queue all channels with messages for pre-rendering
    queueChannelsForPrerender() {
        this.prerenderQueue = [];

        // Add all channels that have messages
        for (const [storageKey, messages] of this.messages) {
            if (messages.length > 0) {
                // Don't include the current channel/community (it's already rendered)
                const currentKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
                if (storageKey !== currentKey && storageKey !== this.currentCommunity) {
                    this.prerenderQueue.push(storageKey);
                }
            }
        }

        // Sort by unread count (prioritize channels with unread messages)
        this.prerenderQueue.sort((a, b) => {
            const unreadA = this.unreadCounts.get(a) || 0;
            const unreadB = this.unreadCounts.get(b) || 0;
            return unreadB - unreadA;
        });
    }

    // Start background pre-rendering using requestIdleCallback
    startBackgroundPrerendering() {
        if (this.isPrerenderingActive || this.prerenderQueue.length === 0) {
            return;
        }

        this.isPrerenderingActive = true;
        this.processNextPrerenderItem();
    }

    // Process one channel from the prerender queue
    processNextPrerenderItem() {
        if (this.prerenderQueue.length === 0) {
            this.isPrerenderingActive = false;
            return;
        }

        const storageKey = this.prerenderQueue.shift();

        // Skip if this is the current channel or community
        const currentKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
        if (storageKey === currentKey || storageKey === this.currentCommunity) {
            this.processNextPrerenderItem();
            return;
        }

        // Use requestIdleCallback if available, otherwise setTimeout
        const scheduleNext = (callback) => {
            if (typeof requestIdleCallback === 'function') {
                requestIdleCallback(callback, { timeout: 1000 });
            } else {
                setTimeout(callback, 50);
            }
        };

        scheduleNext(() => {
            try {
                // Community channels use prerenderCommunity, all others use prerenderChannel
                if (this.communityChannels.has(storageKey)) {
                    this.prerenderCommunity(storageKey);
                } else {
                    this.prerenderChannel(storageKey);
                }
            } catch (err) {
                // Silently handle pre-render errors
            }

            // Continue with next item
            scheduleNext(() => this.processNextPrerenderItem());
        });
    }

    // Get pre-rendered content for a channel (returns container or null)
    getPrerenderedContent(storageKey) {
        const channelMessages = this.messages.get(storageKey) || [];
        const currentVersion = channelMessages.length;
        const cachedVersion = this.prerenderedChannelVersions.get(storageKey);

        // Check if cache is valid
        if (cachedVersion === currentVersion && this.prerenderedChannels.has(storageKey)) {
            return this.prerenderedChannels.get(storageKey);
        }

        return null;
    }

    addChannel(channel, geohash = '') {
        const list = document.getElementById('channelList');
        const key = geohash || channel;

        // Don't add blocked channels
        if (this.isChannelBlocked(channel, geohash)) {
            return;
        }

        if (!document.querySelector(`[data-channel="${channel}"][data-geohash="${geohash}"]`)) {
            const item = document.createElement('div');
            item.className = 'channel-item list-item';
            item.dataset.channel = channel;
            item.dataset.geohash = geohash;

            // Check if this is the current active channel
            const isCurrentChannel = !this.inPMMode &&
                !this.currentCommunity &&
                this.currentChannel === channel &&
                (this.currentGeohash || '') === geohash;
            if (isCurrentChannel) {
                item.classList.add('active');
            }

            const displayName = geohash ? `#${geohash}` : `#${channel}`;
            const badge = geohash ? '<span class="geohash-badge">GEO</span>' : '<span class="std-badge">EPH</span>';

            // Get location information for geohash channels
            let locationHint = '';
            if (geohash) {
                const location = this.getGeohashLocation(geohash);
                if (location) {
                    locationHint = ` title="${location}"`;
                }
            }

            const isPinned = this.pinnedChannels.has(key);
            if (isPinned) {
                item.classList.add('pinned');
            }

            // Don't show pin button for #bar
            const isBar = channel === 'bar' && !geohash;
            const pinButton = isBar ? '' : `
    <span class="pin-btn ${isPinned ? 'pinned' : ''}" data-channel="${channel}" data-geohash="${geohash}">
        <svg viewBox="0 0 24 24">
            <path d="M16,12V4H17V2H7V4H8V12L6,14V16H11.2V22H12.8V16H18V14L16,12Z"/>
        </svg>
    </span>
`;

            item.innerHTML = `
    <span class="channel-name"${locationHint}>${displayName}</span>
    <div class="channel-badges">
        ${pinButton}
        ${badge}
        <span class="unread-badge" style="display:none">0</span>
    </div>
`;

            // Add pin button handler using event listener instead of inline onclick
            if (!isBar) {
                const pinBtn = item.querySelector('.pin-btn');
                if (pinBtn) {
                    pinBtn.addEventListener('click', (e) => {
                        e.stopPropagation();
                        e.preventDefault();
                        this.togglePin(channel, geohash);
                    });
                }
            }

            // Insert before the view more button if it exists
            const viewMoreBtn = list.querySelector('.view-more-btn');
            if (viewMoreBtn) {
                list.insertBefore(item, viewMoreBtn);
            } else {
                list.appendChild(item);
            }

            this.channels.set(key, { channel, geohash });
            this.updateChannelPins();

            // Check if we need to add/update view more button
            this.updateViewMoreButton('channelList');
        }
    }

    updateViewMoreButton(listId) {
        const list = document.getElementById(listId);
        if (!list) return;

        // Don't manage view more button if search is active
        const searchInput = list.parentElement?.querySelector('.search-input.active');
        if (searchInput && searchInput.value.trim().length > 0) {
            return;
        }

        const items = list.querySelectorAll('.list-item:not(.search-hidden)');
        let existingBtn = list.querySelector('.view-more-btn');

        // Get current expansion state
        const isExpanded = this.listExpansionStates.get(listId) || false;

        if (items.length > 20) {
            // We need a button
            if (!existingBtn) {
                const btn = document.createElement('div');
                btn.className = 'view-more-btn';
                btn.onclick = () => this.toggleListExpansion(listId);
                list.appendChild(btn);
                existingBtn = btn;
            }

            // Update button text based on state
            if (isExpanded) {
                existingBtn.textContent = 'Show less';
                list.classList.remove('list-collapsed');
                list.classList.add('list-expanded');
            } else {
                existingBtn.textContent = `View ${items.length - 20} more...`;
                list.classList.add('list-collapsed');
                list.classList.remove('list-expanded');
            }

            // Make sure button is visible
            existingBtn.style.display = 'block';
        } else {
            // Don't need a button - remove if exists
            if (existingBtn) {
                existingBtn.remove();
            }
            list.classList.remove('list-collapsed', 'list-expanded');
            // Clear expansion state since button is gone
            this.listExpansionStates.delete(listId);
        }
    }

    toggleListExpansion(listId) {
        const list = document.getElementById(listId);
        if (!list) return;

        let btn = list.querySelector('.view-more-btn');
        const items = list.querySelectorAll('.list-item');

        // Toggle the state
        const currentState = this.listExpansionStates.get(listId) || false;
        const newState = !currentState;
        this.listExpansionStates.set(listId, newState);

        if (newState) {
            // Expanding
            list.classList.remove('list-collapsed');
            list.classList.add('list-expanded');

            // Move button to the end of the list
            if (btn) {
                btn.remove();
                btn = document.createElement('div');
                btn.className = 'view-more-btn';
                btn.textContent = 'Show less';
                btn.onclick = () => this.toggleListExpansion(listId);
                list.appendChild(btn);
            }
        } else {
            // Collapsing
            list.classList.add('list-collapsed');
            list.classList.remove('list-expanded');

            // Move button back to after the 20th item
            if (btn) {
                btn.remove();
                btn = document.createElement('div');
                btn.className = 'view-more-btn';
                btn.textContent = `View ${items.length - 20} more...`;
                btn.onclick = () => this.toggleListExpansion(listId);

                // Insert after the 20th visible item
                if (items.length > 20 && items[19]) {
                    items[19].insertAdjacentElement('afterend', btn);
                } else {
                    list.appendChild(btn);
                }
            }
        }
    }

    removeChannel(channel, geohash = '') {
        const key = geohash || channel;

        // Don't allow removing #bar (default channel)
        if (channel === 'bar' && !geohash) {
            this.displaySystemMessage('Cannot remove the default #bar channel');
            return;
        }

        // Remove from channels map
        this.channels.delete(key);

        // Remove from user-joined set
        this.userJoinedChannels.delete(key);

        // Remove from DOM
        const selector = geohash ?
            `[data-geohash="${geohash}"]` :
            `[data-channel="${channel}"][data-geohash=""]`;
        const element = document.querySelector(selector);
        if (element) {
            element.remove();
        }

        // If we're currently in this channel, switch to #bar
        if ((this.currentChannel === channel && this.currentGeohash === geohash) ||
            (geohash && this.currentGeohash === geohash)) {
            this.switchChannel('bar', '');
        }

        // Save the updated channel list
        this.saveUserChannels();

        this.displaySystemMessage(`Left channel ${geohash ? '#' + geohash : '#' + channel}`);
    }

    // Add left-click context menu for channel items
    setupChannelContextMenu() {
        document.addEventListener('contextmenu', (e) => {
            const channelItem = e.target.closest('.channel-item');
            if (channelItem) {
                e.preventDefault();
                const channel = channelItem.dataset.channel;
                const geohash = channelItem.dataset.geohash;

                // Don't allow removing #bar
                if (channel === 'bar' && !geohash) {
                    return;
                }

                // Create a simple context menu for leaving channel
                const menu = document.createElement('div');
                menu.className = 'context-menu active';
                menu.style.left = e.pageX + 'px';
                menu.style.top = e.pageY + 'px';
                menu.innerHTML = `
        <div class="context-menu-item" onclick="nym.removeChannel('${channel}', '${geohash}'); this.parentElement.remove();">
            Leave Channel
        </div>
    `;

                // Remove any existing channel context menu
                document.querySelectorAll('.channel-context-menu').forEach(m => m.remove());
                menu.classList.add('channel-context-menu');
                document.body.appendChild(menu);

                // Close on click outside
                setTimeout(() => {
                    document.addEventListener('click', () => menu.remove(), { once: true });
                }, 100);
            }
        });
    }

    saveUserJoinedChannels() {
        const existing = this.loadUserJoinedChannels();
        const combined = new Set([...existing, ...this.userJoinedChannels]);
        localStorage.setItem('nym_user_joined_channels', JSON.stringify(Array.from(combined)));
    }

    loadUserJoinedChannels() {
        const saved = localStorage.getItem('nym_user_joined_channels');
        if (saved) {
            try {
                return JSON.parse(saved);
            } catch (error) {
                return [];
            }
        }
        return [];
    }

    saveUserChannels() {
        const userChannels = [];
        this.channels.forEach((value, key) => {
            const isCommunity = value.isCommunity;
            const isOwnedCommunity = isCommunity && this.ownedCommunities.has(key);
            const isModeratedCommunity = isCommunity && this.moderatedCommunities.has(key);
            const isMemberCommunity = isCommunity && this.communityMembers.has(key) &&
                this.communityMembers.get(key).has(this.pubkey);
            if (this.userJoinedChannels.has(key) || isOwnedCommunity || isModeratedCommunity || isMemberCommunity) {
                userChannels.push({
                    key: key,
                    channel: value.channel,
                    geohash: value.geohash,
                    isCommunity: value.isCommunity,
                    community: value.community
                });
            }
        });

        // Save the channels
        localStorage.setItem('nym_user_channels', JSON.stringify(userChannels));

        // Also save the joined channels set
        this.saveUserJoinedChannels();
    }

    loadUserChannels() {
        const saved = localStorage.getItem('nym_user_channels');
        const savedJoined = localStorage.getItem('nym_user_joined_channels');

        // First, load the joined channels set
        if (savedJoined) {
            try {
                const joinedChannels = JSON.parse(savedJoined);
                joinedChannels.forEach(key => this.userJoinedChannels.add(key));
            } catch (error) {
            }
        }

        // Then load the channel details
        if (saved) {
            try {
                const userChannels = JSON.parse(saved);

                userChannels.forEach(({ key, channel, geohash, isCommunity, community }) => {
                    if (isCommunity) {
                        // For communities, only restore if owned/moderated/member
                        // Public communities will be re-discovered automatically
                        const isOwned = this.ownedCommunities.has(key);
                        const isModerated = this.moderatedCommunities.has(key);
                        const isMember = this.communityMembers.has(key) &&
                            this.communityMembers.get(key).has(this.pubkey);

                        if (isOwned || isModerated || isMember) {
                            // Will be added when community definition is received
                            this.userJoinedChannels.add(key);
                        }
                    } else {
                        // Regular channels - add the channel to the list if not already present
                        if (!this.channels.has(key)) {
                            this.addChannel(channel, geohash);
                        }
                        // Make sure it's marked as user-joined
                        this.userJoinedChannels.add(key);
                    }
                });

                // Sort channels after loading
                this.sortChannelsByActivity();

                const regularChannelCount = userChannels.filter(c => !c.isCommunity).length;
                if (regularChannelCount > 0) {
                    this.displaySystemMessage(`Restored ${regularChannelCount} previously joined channels`);
                }
            } catch (error) {
            }
        }
    }

    clearUserChannels() {
        localStorage.removeItem('nym_user_channels');
    }

    addChannelToList(channel, geohash) {
        // For geohash channels, ALWAYS use the geohash as the key
        const key = geohash ? geohash : channel;

        // Check if this channel was previously user-joined
        const wasUserJoined = this.userJoinedChannels.has(key);

        // Only add if not already in channels map
        if (geohash) {
            // This is a geohash channel
            if (!this.channels.has(geohash)) {
                this.addChannel(geohash, geohash);
                if (wasUserJoined) {
                    this.userJoinedChannels.add(geohash);
                }
                this.addGeohashChannelToGlobe(geohash);
            }
        } else {
            // This is a standard channel
            if (!this.channels.has(channel)) {
                this.addChannel(channel, '');
                if (wasUserJoined) {
                    this.userJoinedChannels.add(channel);
                }
            }
        }
    }

    updateUnreadCount(channel) {
        const count = (this.unreadCounts.get(channel) || 0) + 1;
        this.unreadCounts.set(channel, count);

        // Handle PM unread counts using conversation key
        if (channel.startsWith('pm-')) {
            // Extract the other user's pubkey from conversation key
            const keys = channel.substring(3).split('-');
            const otherPubkey = keys.find(k => k !== this.pubkey);
            if (otherPubkey) {
                const badge = document.querySelector(`[data-pubkey="${otherPubkey}"] .unread-badge`);
                if (badge) {
                    badge.textContent = count > 99 ? '99+' : count;
                    badge.style.display = count > 0 ? 'block' : 'none';
                }
            }
        } else {
            // Regular channel unread counts
            let selector;
            if (channel.startsWith('#')) {
                // Geohash channel
                selector = `[data-geohash="${channel.substring(1)}"]`;
            } else {
                // Check if it's a community channel by ID
                const communityElement = document.querySelector(`[data-community="${channel}"]`);
                if (communityElement) {
                    // It's a community channel
                    selector = `[data-community="${channel}"]`;
                } else {
                    // Standard channel
                    selector = `[data-channel="${channel}"][data-geohash=""]`;
                }
            }

            const badge = document.querySelector(`${selector} .unread-badge`);
            if (badge) {
                badge.textContent = count > 99 ? '99+' : count;
                badge.style.display = count > 0 ? 'block' : 'none';
            }
        }

        // Re-sort channels by activity
        this.sortChannelsByActivity();
    }

    sortChannelsByActivity() {
        const channelList = document.getElementById('channelList');
        const channels = Array.from(channelList.querySelectorAll('.channel-item'));

        // Save view more button if it exists
        const viewMoreBtn = channelList.querySelector('.view-more-btn');

        // Store current scroll position
        const scrollTop = channelList.scrollTop;

        channels.sort((a, b) => {
            // #bar is always first
            const aIsBar = a.dataset.channel === 'bar' && !a.dataset.geohash && !a.dataset.isCommunity;
            const bIsBar = b.dataset.channel === 'bar' && !b.dataset.geohash && !b.dataset.isCommunity;

            if (aIsBar) return -1;
            if (bIsBar) return 1;

            // Check if either is the NYM community (special pin that can't be unpinned)
            const aIsNYM = a.dataset.community &&
                this.communityChannels.get(a.dataset.community)?.name?.toLowerCase() === 'nym' &&
                this.communityChannels.get(a.dataset.community)?.admin === this.verifiedDeveloper.pubkey;
            const bIsNYM = b.dataset.community &&
                this.communityChannels.get(b.dataset.community)?.name?.toLowerCase() === 'nym' &&
                this.communityChannels.get(b.dataset.community)?.admin === this.verifiedDeveloper.pubkey;

            // NYM community comes right after #bar
            if (aIsNYM && !bIsBar) return -1;
            if (bIsNYM && !aIsBar) return 1;

            // Active channel is third
            const aIsActive = a.classList.contains('active');
            const bIsActive = b.classList.contains('active');

            if (aIsActive && !bIsActive) return -1;
            if (!aIsActive && bIsActive) return 1;

            // Then sort by pinned status
            const aPinned = a.classList.contains('pinned');
            const bPinned = b.classList.contains('pinned');

            if (aPinned && !bPinned) return -1;
            if (!aPinned && bPinned) return 1;

            // Check if these are geohash channels
            const aIsGeo = !!a.dataset.geohash && a.dataset.geohash !== '';
            const bIsGeo = !!b.dataset.geohash && b.dataset.geohash !== '';

            // If proximity sorting is enabled, sort ALL geohash channels by distance first
            if (this.settings.sortByProximity && this.userLocation) {
                // If both are geohash, sort by distance
                if (aIsGeo && bIsGeo) {
                    try {
                        const coordsA = this.decodeGeohash(a.dataset.geohash);
                        const coordsB = this.decodeGeohash(b.dataset.geohash);

                        const distA = this.calculateDistance(
                            this.userLocation.lat, this.userLocation.lng,
                            coordsA.lat, coordsA.lng
                        );
                        const distB = this.calculateDistance(
                            this.userLocation.lat, this.userLocation.lng,
                            coordsB.lat, coordsB.lng
                        );

                        // Return distance comparison (don't fall through to unread count)
                        return distA - distB;
                    } catch (e) {
                        // Fall through to unread count if error
                    }
                }

                // If only one is geo, put geo channels first when proximity sorting is on
                if (aIsGeo && !bIsGeo) return -1;
                if (!aIsGeo && bIsGeo) return 1;
            }

            // Default: sort by unread count
            const aChannel = a.dataset.community || (a.dataset.geohash ? `#${a.dataset.geohash}` : a.dataset.channel);
            const bChannel = b.dataset.community || (b.dataset.geohash ? `#${b.dataset.geohash}` : b.dataset.channel);

            const aUnread = this.unreadCounts.get(aChannel) || 0;
            const bUnread = this.unreadCounts.get(bChannel) || 0;

            if (aUnread === bUnread) return 0;
            return bUnread - aUnread;
        });

        // Clear and re-append
        channelList.innerHTML = '';
        channels.forEach(channel => channelList.appendChild(channel));

        // Re-add view more button
        this.updateViewMoreButton('channelList');

        // Restore scroll position
        channelList.scrollTop = scrollTop;
    }

    clearUnreadCount(channel) {
        const storageKey = channel.startsWith('#') && !this.isValidGeohash(channel.substring(1))
            ? channel.substring(1)
            : channel;

        this.unreadCounts.set(storageKey, 0);

        // Handle PM unread counts using conversation key
        if (storageKey.startsWith('pm-')) {
            // Extract the other user's pubkey from conversation key
            const keys = storageKey.substring(3).split('-');
            const otherPubkey = keys.find(k => k !== this.pubkey);
            if (otherPubkey) {
                const badge = document.querySelector(`[data-pubkey="${otherPubkey}"] .unread-badge`);
                if (badge) {
                    badge.style.display = 'none';
                }
            }
        } else {
            // Regular channel unread counts
            let selector;
            if (channel.startsWith('#')) {
                const channelName = channel.substring(1);
                if (this.isValidGeohash(channelName)) {
                    // It's a geohash
                    selector = `[data-geohash="${channelName}"]`;
                } else {
                    // It's a standard channel with # prefix in display
                    selector = `[data-channel="${channelName}"][data-geohash=""]`;
                }
            } else {
                // Check if it's a community channel
                const communityElement = document.querySelector(`[data-community="${channel}"]`);
                if (communityElement) {
                    selector = `[data-community="${channel}"]`;
                } else {
                    // Standard channel without # prefix
                    selector = `[data-channel="${channel}"][data-geohash=""]`;
                }
            }

            const badge = document.querySelector(`${selector} .unread-badge`);
            if (badge) {
                badge.style.display = 'none';
            }
        }
    }

    navigateHistory(direction) {
        const input = document.getElementById('messageInput');

        if (direction === -1 && this.historyIndex > 0) {
            this.historyIndex--;
            input.value = this.commandHistory[this.historyIndex];
        } else if (direction === 1 && this.historyIndex < this.commandHistory.length - 1) {
            this.historyIndex++;
            input.value = this.commandHistory[this.historyIndex];
        } else if (direction === 1 && this.historyIndex === this.commandHistory.length - 1) {
            this.historyIndex = this.commandHistory.length;
            input.value = '';
        }

        this.autoResizeTextarea(input);
    }

    autoResizeTextarea(textarea) {
        textarea.style.height = 'auto';
        textarea.style.height = Math.min(textarea.scrollHeight, 120) + 'px';
    }

    updateConnectionStatus(status) {
        const statusEl = document.getElementById('connectionStatus');
        const dot = document.getElementById('statusDot');

        // If status is a custom message, show it
        if (status && typeof status === 'string') {
            statusEl.textContent = status;

            // Update dot color based on status text
            if (status.includes('Connected') || status.includes('relays')) {
                dot.style.background = 'var(--primary)';
            } else if (status.includes('Connecting') || status.includes('Discovering')) {
                dot.style.background = 'var(--warning)';
            } else if (status.includes('Failed') || status.includes('Disconnected')) {
                dot.style.background = 'var(--danger)';
            }
        } else {
            // Check actual WebSocket connection states, not just pool size
            let actuallyConnected = 0;
            let geoRelaysConnected = 0;

            this.relayPool.forEach((relay, url) => {
                if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                    actuallyConnected++;
                    if (relay.type === 'geo') {
                        geoRelaysConnected++;
                    }
                } else {
                    // Clean up dead connections from pool
                    this.relayPool.delete(url);
                    this.relayKinds.delete(url);
                }
            });

            if (actuallyConnected > 0) {
                statusEl.textContent = `Connected (${actuallyConnected} relays)`;
                dot.style.background = 'var(--primary)';
                this.connected = true;
            } else {
                statusEl.textContent = 'Disconnected';
                dot.style.background = 'var(--danger)';
                this.connected = false;
            }

        }
    }

    setupEmojiPicker() {
        const emojis = this.recentEmojis.length > 0 ? this.recentEmojis :
            ['😊', '😂', '🤣', '❤️', '👍', '🔥', '✨', '🎉', '💯', '🤔', '😎', '🚀',
                '💻', '🌟', '⚡', '🎯', '💡', '🤖', '👻', '🎭', '🌈', '🍕', '☕', '🎮'];
        const picker = document.getElementById('emojiPicker');

        picker.innerHTML = '';
        emojis.forEach(emoji => {
            const btn = document.createElement('button');
            btn.className = 'emoji-btn';
            btn.textContent = emoji;
            btn.onclick = () => this.insertEmoji(emoji);
            picker.appendChild(btn);
        });
    }

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
    }

    showGifPicker() {
        const gifPicker = document.getElementById('gifPicker');

        gifPicker.innerHTML = `
<div class="gif-modal-header">
    <input type="text" class="gif-search-input" placeholder="Search GIFs..." id="gifSearchInput">
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

        // Focus search
        searchInput.focus();
    }

    async loadTrendingGifs() {
        const resultsDiv = document.getElementById('gifResults');
        resultsDiv.innerHTML = '<div class="gif-loading">Loading trending GIFs...</div>';

        try {
            const response = await fetch(
                `https://api.giphy.com/v1/gifs/trending?api_key=${this.giphyApiKey}&limit=20&rating=g`
            );
            const data = await response.json();

            this.displayGifs(data.data);
        } catch (error) {
            resultsDiv.innerHTML = '<div class="gif-error">Failed to load GIFs</div>';
        }
    }

    async searchGifs(query) {
        const resultsDiv = document.getElementById('gifResults');
        resultsDiv.innerHTML = '<div class="gif-loading">Searching GIFs...</div>';

        try {
            const response = await fetch(
                `https://api.giphy.com/v1/gifs/search?api_key=${this.giphyApiKey}&q=${encodeURIComponent(query)}&limit=20&rating=g`
            );
            const data = await response.json();

            if (data.data.length === 0) {
                resultsDiv.innerHTML = '<div class="gif-error">No GIFs found</div>';
            } else {
                this.displayGifs(data.data);
            }
        } catch (error) {
            resultsDiv.innerHTML = '<div class="gif-error">Failed to search GIFs</div>';
        }
    }

    displayGifs(gifs) {
        const resultsDiv = document.getElementById('gifResults');

        resultsDiv.innerHTML = gifs.map(gif => {
            const url = gif.images.fixed_height.url;
            return `
    <div class="gif-item" data-gif-url="${url}">
        <img src="${url}" alt="${gif.title}">
    </div>
`;
        }).join('');

        // Add click handlers
        resultsDiv.querySelectorAll('.gif-item').forEach(item => {
            item.onclick = () => {
                const gifUrl = item.dataset.gifUrl;
                this.insertGif(gifUrl);
            };
        });
    }

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
    }

    closeGifPicker() {
        const gifPicker = document.getElementById('gifPicker');
        gifPicker.classList.remove('active');
        gifPicker.innerHTML = '';
    }

    insertEmoji(emoji) {
        const input = document.getElementById('messageInput');
        const start = input.selectionStart;
        const end = input.selectionEnd;
        const text = input.value;

        input.value = text.substring(0, start) + emoji + text.substring(end);
        input.selectionStart = input.selectionEnd = start + emoji.length;
        input.focus();

        this.addToRecentEmojis(emoji);
    }

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
    }

    showNotification(title, body, channelInfo = null) {
        const baseTitle = this.parseNymFromDisplay(title);

        // If this is a PM notification (we have a pubkey), append plain suffix for readability
        let titleToShow = baseTitle;
        if (channelInfo && channelInfo.pubkey) {
            const suffix = this.getPubkeySuffix(channelInfo.pubkey);
            titleToShow = `${baseTitle}#${suffix}`;
        }

        // Sound
        if (this.settings.sound !== 'none') {
            this.playSound(this.settings.sound);
        }

        // Browser notification
        if (typeof Notification !== 'undefined' && Notification.permission === 'granted') {
            try {
                const notification = new Notification(titleToShow, {
                    body: body,
                    icon: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" fill="%23000"/><text x="50" y="55" font-size="40" fill="%230ff" text-anchor="middle" font-family="monospace">NYM</text></svg>',
                    tag: channelInfo ? (channelInfo.id || 'nym-notification') : 'nym-notification',
                    requireInteraction: false,
                    data: { channelInfo: channelInfo }
                });

                if (channelInfo) {
                    notification.onclick = (event) => {
                        event.preventDefault();
                        window.focus();

                        if (channelInfo.type === 'pm') {
                            this.openUserPM(baseTitle, channelInfo.pubkey);
                        } else if (channelInfo.type === 'community') {
                            this.switchToCommunity(channelInfo.communityId);
                        } else if (channelInfo.type === 'geohash') {
                            this.switchChannel(channelInfo.channel, channelInfo.geohash);
                        } else {
                            this.switchChannel(channelInfo.channel, '');
                        }

                        notification.close();
                    };
                }
            } catch (error) {
            }
        }

        // In-app notification (fallback)
        const notifEl = document.createElement('div');
        notifEl.className = 'notification';
        if (channelInfo && channelInfo.pubkey) {
            notifEl.dataset.pubkey = channelInfo.pubkey;
        }
        notifEl.innerHTML = `
<div class="notification-title">${this.escapeHtml(titleToShow)}</div>
<div class="notification-body">${this.escapeHtml(body)}</div>
<div class="notification-time">${new Date().toLocaleTimeString()}</div>
`;

        if (channelInfo) {
            notifEl.style.cursor = 'pointer';
            notifEl.onclick = () => {
                if (channelInfo.type === 'pm') {
                    this.openUserPM(baseTitle, channelInfo.pubkey);
                } else if (channelInfo.type === 'community') {
                    this.switchToCommunity(channelInfo.communityId);
                } else if (channelInfo.type === 'geohash') {
                    this.switchChannel(channelInfo.channel, channelInfo.geohash);
                } else {
                    this.switchChannel(channelInfo.channel, '');
                }
                notifEl.remove();
            };
        }

        document.body.appendChild(notifEl);
        setTimeout(() => {
            notifEl.style.animation = 'slideIn 0.3s reverse';
            setTimeout(() => notifEl.remove(), 300);
        }, 3000);
    }

    playSound(type) {
        const audioContext = new (window.AudioContext || window.webkitAudioContext)();
        const oscillator = audioContext.createOscillator();
        const gainNode = audioContext.createGain();

        oscillator.connect(gainNode);
        gainNode.connect(audioContext.destination);

        switch (type) {
            case 'beep':
                oscillator.frequency.value = 800;
                gainNode.gain.value = 0.1;
                break;
            case 'icq':
                oscillator.frequency.value = 600;
                gainNode.gain.value = 0.15;
                break;
            case 'msn':
                oscillator.frequency.value = 1000;
                gainNode.gain.value = 0.1;
                break;
        }

        oscillator.start();
        oscillator.stop(audioContext.currentTime + 0.1);
    }

    applyTheme(theme) {
        const root = document.documentElement;
        document.body.classList.remove('theme-ghost', 'theme-bitchat');

        if (theme === 'ghost') {
            document.body.classList.add('theme-ghost');
        } else if (theme === 'bitchat') {
            document.body.classList.add('theme-bitchat');
        }

        const themes = {
            matrix: {
                primary: '#00ff00',
                secondary: '#00ffff',
                text: '#00ff00',
                textDim: '#008800',
                textBright: '#00ffaa',
                lightning: '#f7931a'
            },
            amber: {
                primary: '#ffb000',
                secondary: '#ffd700',
                text: '#ffb000',
                textDim: '#cc8800',
                textBright: '#ffcc00',
                lightning: '#ffa500'
            },
            cyber: {
                primary: '#ff00ff',
                secondary: '#00ffff',
                text: '#ff00ff',
                textDim: '#aa00aa',
                textBright: '#ff66ff',
                lightning: '#ffaa00'
            },
            hacker: {
                primary: '#00ffff',
                secondary: '#00ff00',
                text: '#00ffff',
                textDim: '#008888',
                textBright: '#66ffff',
                lightning: '#00ff88'
            },
            ghost: {
                primary: '#ffffff',
                secondary: '#cccccc',
                text: '#ffffff',
                textDim: '#666666',
                textBright: '#ffffff',
                lightning: '#dddddd'
            },
            bitchat: {
                primary: '#00ff00',
                secondary: '#00ffff',
                text: '#00ff00',
                textDim: '#008800',
                textBright: '#00ffaa',
                lightning: '#f7931a'
            }
        };

        if (theme === 'ghost') {
            document.body.classList.add('theme-ghost');
        }

        const selectedTheme = themes[theme];
        if (selectedTheme) {
            Object.entries(selectedTheme).forEach(([key, value]) => {
                const cssVar = `--${key.replace(/([A-Z])/g, '-$1').toLowerCase()}`;
                root.style.setProperty(cssVar, value);
            });
        }
        this.refreshMessages();
    }

    refreshMessages() {
        // Clear user colors cache when theme changes
        this.userColors.clear();

        // Re-display all messages to apply new colors
        const container = document.getElementById('messagesContainer');
        const messages = container.querySelectorAll('.message');

        messages.forEach(msg => {
            const pubkey = msg.dataset.pubkey;
            const authorElement = msg.querySelector('.message-author');
            if (authorElement) {
                // Remove existing bitchat classes
                const classesToRemove = [];
                authorElement.classList.forEach(cls => {
                    if (cls.startsWith('bitchat-user-') || cls === 'bitchat-theme') {
                        classesToRemove.push(cls);
                    }
                });

                classesToRemove.forEach(cls => authorElement.classList.remove(cls));

                // Add new color class
                const colorClass = this.getUserColorClass(pubkey);
                if (colorClass) {
                    authorElement.classList.add(colorClass);
                }
            }
        });

        // Also refresh user list
        this.updateUserList();
    }

    refreshMessageTimestamps() {
        // Update all visible timestamps to use new format
        document.querySelectorAll('.message-time').forEach(timeEl => {
            const timestamp = parseInt(timeEl.closest('.message').dataset.timestamp);
            if (timestamp) {
                const date = new Date(timestamp);
                const newTime = date.toLocaleTimeString('en-US', {
                    hour: '2-digit',
                    minute: '2-digit',
                    hour12: this.settings.timeFormat === '12hr'
                });
                timeEl.textContent = newTime;

                // Update class for spacing
                if (this.settings.timeFormat === '12hr') {
                    timeEl.classList.add('time-12hr');
                } else {
                    timeEl.classList.remove('time-12hr');
                }
            }
        });
    }

    cleanupBitchatStyles() {
        // Remove all dynamically created bitchat styles
        document.querySelectorAll('style[id^="bitchat-user-"]').forEach(style => {
            style.remove();
        });
    }

    cleanupBannedMessages(communityId, bannedPubkey) {
        // Mark messages from banned user as blocked in stored messages
        if (this.messages.has(communityId)) {
            this.messages.get(communityId).forEach(msg => {
                if (msg.pubkey === bannedPubkey) {
                    msg.blocked = true;
                }
            });
        }

        // Remove from DOM
        document.querySelectorAll(`.message[data-pubkey="${bannedPubkey}"]`).forEach(msg => {
            msg.remove();
        });
    }

    restoreUnbannedMessages(communityId, unbannedPubkey) {
        // Unmark messages from unbanned user in stored messages
        if (this.messages.has(communityId)) {
            this.messages.get(communityId).forEach(msg => {
                if (msg.pubkey === unbannedPubkey) {
                    delete msg.blocked;
                }
            });
        }

        // Reload community messages if currently viewing this community
        if (this.currentCommunity === communityId) {
            this.loadCommunityMessages(communityId);
        }
    }

    loadSettings() {
        let pinnedLandingChannel;
        try {
            const saved = localStorage.getItem('nym_pinned_landing_channel');
            pinnedLandingChannel = saved ? JSON.parse(saved) : { type: 'ephemeral', channel: 'bar' };
        } catch (e) {
            // Fallback for old string format
            const saved = localStorage.getItem('nym_pinned_landing_channel');
            if (saved) {
                pinnedLandingChannel = { type: 'ephemeral', channel: saved };
            } else {
                pinnedLandingChannel = { type: 'ephemeral', channel: 'bar' };
            }
        }

        return {
            theme: localStorage.getItem('nym_theme') || 'bitchat',
            sound: localStorage.getItem('nym_sound') || 'beep',
            autoscroll: localStorage.getItem('nym_autoscroll') !== 'false',
            showTimestamps: localStorage.getItem('nym_timestamps') !== 'false',
            sortByProximity: localStorage.getItem('nym_sort_proximity') === 'true',
            timeFormat: localStorage.getItem('nym_time_format') || '24hr',
            dmForwardSecrecyEnabled: localStorage.getItem('nym_dm_fwdsec_enabled') === 'true',
            dmTTLSeconds: parseInt(localStorage.getItem('nym_dm_ttl_seconds') || '86400', 10),
            readReceiptsEnabled: localStorage.getItem('nym_read_receipts_enabled') !== 'false',  // Enabled by default
            pinnedLandingChannel: pinnedLandingChannel
        };
    }

    loadImageBlurSettings() {
        const saved = localStorage.getItem(`nym_image_blur_${this.pubkey}`);
        if (saved !== null) {
            return saved === 'true';
        }
        return true; // Default to blur
    }

    saveImageBlurSettings() {
        localStorage.setItem(`nym_image_blur_${this.pubkey}`, this.blurOthersImages.toString());

        // Sync to Nostr for persistent connections
        if (this.connectionMode !== 'ephemeral') {
            this.saveSyncedSettings();
        }
    }

    toggleImageBlur() {
        this.blurOthersImages = !this.blurOthersImages;
        this.saveImageBlurSettings();

        // Update all existing images
        document.querySelectorAll('.message img').forEach(img => {
            const messageEl = img.closest('.message');
            if (messageEl && !messageEl.classList.contains('self')) {
                if (this.blurOthersImages) {
                    img.classList.add('blurred');
                } else {
                    img.classList.remove('blurred');
                }
            }
        });
    }

    saveSettings() {
        localStorage.setItem('nym_theme', this.settings.theme);
        localStorage.setItem('nym_sound', this.settings.sound);
        localStorage.setItem('nym_autoscroll', this.settings.autoscroll);
        localStorage.setItem('nym_timestamps', this.settings.showTimestamps);
        localStorage.setItem('nym_sort_proximity', this.settings.sortByProximity);
        const powDifficulty = parseInt(document.getElementById('powDifficultySelect').value);
        this.powDifficulty = powDifficulty;
        this.enablePow = powDifficulty > 0;
        localStorage.setItem('nym_pow_difficulty', powDifficulty.toString());
    }

    loadBlockedUsers() {
        const blocked = localStorage.getItem('nym_blocked');
        if (blocked) {
            this.blockedUsers = new Set(JSON.parse(blocked));
        }
        this.updateBlockedList();
    }

    saveBlockedUsers() {
        localStorage.setItem('nym_blocked', JSON.stringify(Array.from(this.blockedUsers)));
    }

    updateBlockedList() {
        const list = document.getElementById('blockedList');
        if (this.blockedUsers.size === 0) {
            list.innerHTML = '<div style="color: var(--text-dim); font-size: 12px;">No blocked users</div>';
        } else {
            // Show loading state
            list.innerHTML = '<div style="color: var(--text-dim); font-size: 12px;">Loading...</div>';

            // Load async without blocking
            this.loadBlockedUsersAsync(list);
        }
    }

    async loadBlockedUsersAsync(listElement) {
        // Initialize nymCache if it doesn't exist
        if (!this.nymCache) {
            this.nymCache = {};
        }

        // Fetch metadata for blocked users who aren't in cache
        const blockedArray = Array.from(this.blockedUsers);
        const uncachedPubkeys = blockedArray.filter(pk => !this.nymCache[pk]);

        if (uncachedPubkeys.length > 0) {
            await this.fetchMetadataForBlockedUsers(uncachedPubkeys);
        }

        // Now render with proper nyms
        listElement.innerHTML = blockedArray.map(pubkey => {
            const nym = this.getNymFromPubkey(pubkey);
            return `
    <div class="blocked-item">
        <span>${nym}</span>
        <button class="unblock-btn" onclick="nym.unblockByPubkey('${pubkey}')">Unblock</button>
    </div>
`;
        }).join('');
    }

    // Fetch metadata for blocked users
    async fetchMetadataForBlockedUsers(pubkeys) {
        if (pubkeys.length === 0) return;

        return new Promise((resolve) => {
            const subId = "blocked-meta-" + Math.random().toString(36).substring(7);
            let receivedCount = 0;
            let messageHandlers = [];

            const cleanup = () => {
                messageHandlers.forEach(handler => {
                    const index = this.relayMessageHandlers?.indexOf(handler);
                    if (index > -1) {
                        this.relayMessageHandlers.splice(index, 1);
                    }
                });
                this.sendToRelay(["CLOSE", subId]);
            };

            const timeout = setTimeout(() => {
                cleanup();
                resolve();
            }, 3000);

            const handleMessage = (msg, relayUrl) => {
                if (!Array.isArray(msg)) return false;

                const [type, ...data] = msg;

                if (type === 'EVENT' && data[0] === subId) {
                    const event = data[1];
                    if (event && event.kind === 0) {
                        // Temporarily process metadata ONLY for caching the nym
                        try {
                            const metadata = JSON.parse(event.content);
                            const name = metadata.name || metadata.display_name || metadata.displayName;
                            if (name) {
                                // Store in nym cache (without adding to profile cache)
                                this.nymCache[event.pubkey] = name;
                            }
                            receivedCount++;

                            // If we got all metadata, resolve early
                            if (receivedCount >= pubkeys.length) {
                                clearTimeout(timeout);
                                cleanup();
                                resolve();
                            }
                        } catch (e) {
                        }
                    }
                } else if (type === 'EOSE' && data[0] === subId) {
                    clearTimeout(timeout);
                    cleanup();
                    resolve();
                }

                return false;
            };

            if (!this.relayMessageHandlers) {
                this.relayMessageHandlers = [];
            }
            this.relayMessageHandlers.push(handleMessage);
            messageHandlers.push(handleMessage);

            // Request metadata for blocked users
            const subscription = [
                "REQ",
                subId,
                {
                    kinds: [0],
                    authors: pubkeys
                }
            ];

            this.sendToRelay(subscription);
        });
    }

    escapeHtml(text) {
        const map = {
            '&': '&amp;',
            '<': '&lt;',
            '>': '&gt;',
            '"': '&quot;',
        };
        return String(text).replace(/[&<>"]/g, m => map[m]);
    }

    isCurrentChannelCommunity() {
        return this.currentCommunity !== null;
    }

    getCurrentCommunityId() {
        return this.currentCommunity;
    }

    canModerate(communityId) {
        const isAdmin = this.ownedCommunities.has(communityId);
        const isMod = this.communityModerators.has(communityId) &&
            this.communityModerators.get(communityId).has(this.pubkey);
        return isAdmin || isMod;
    }

    async findUserPubkey(input) {
        const hashIndex = input.indexOf('#');
        let searchNym = input;
        let searchSuffix = null;

        if (hashIndex !== -1) {
            searchNym = input.substring(0, hashIndex);
            searchSuffix = input.substring(hashIndex + 1);
        }

        const matches = [];

        // First, search in active users
        this.users.forEach((user, pubkey) => {
            const baseNym = user.nym.split('#')[0] || user.nym;
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

        // If no matches in active users, search in stored messages
        if (matches.length === 0) {
            // Search through all stored messages
            this.messages.forEach((channelMessages, channel) => {
                channelMessages.forEach(msg => {
                    if (msg.pubkey && msg.author) {
                        const baseNym = msg.author.split('#')[0] || msg.author;
                        if (baseNym === searchNym || baseNym.toLowerCase() === searchNym.toLowerCase()) {
                            if (searchSuffix) {
                                if (msg.pubkey.endsWith(searchSuffix)) {
                                    // Check if not already in matches
                                    if (!matches.find(m => m.pubkey === msg.pubkey)) {
                                        matches.push({ nym: msg.author, pubkey: msg.pubkey });
                                    }
                                }
                            } else {
                                // Check if not already in matches
                                if (!matches.find(m => m.pubkey === msg.pubkey)) {
                                    matches.push({ nym: msg.author, pubkey: msg.pubkey });
                                }
                            }
                        }
                    }
                });
            });

            // Also search in PM messages
            this.pmMessages.forEach((conversationMessages, conversationKey) => {
                conversationMessages.forEach(msg => {
                    if (msg.pubkey && msg.author) {
                        const baseNym = msg.author.split('#')[0] || msg.author;
                        if (baseNym === searchNym || baseNym.toLowerCase() === searchNym.toLowerCase()) {
                            if (searchSuffix) {
                                if (msg.pubkey.endsWith(searchSuffix)) {
                                    // Check if not already in matches
                                    if (!matches.find(m => m.pubkey === msg.pubkey)) {
                                        matches.push({ nym: msg.author, pubkey: msg.pubkey });
                                    }
                                }
                            } else {
                                // Check if not already in matches
                                if (!matches.find(m => m.pubkey === msg.pubkey)) {
                                    matches.push({ nym: msg.author, pubkey: msg.pubkey });
                                }
                            }
                        }
                    }
                });
            });

            // Also search in community members if in a community
            if (this.currentCommunity && this.communityMembers.has(this.currentCommunity)) {
                this.communityMembers.get(this.currentCommunity).forEach(pubkey => {
                    // Try to get nym from cache
                    const cachedNym = this.getNymFromPubkey(pubkey);
                    if (cachedNym) {
                        const baseNym = cachedNym.split('#')[0] || cachedNym;
                        if (baseNym === searchNym || baseNym.toLowerCase() === searchNym.toLowerCase()) {
                            if (searchSuffix) {
                                if (pubkey.endsWith(searchSuffix)) {
                                    if (!matches.find(m => m.pubkey === pubkey)) {
                                        matches.push({ nym: cachedNym, pubkey: pubkey });
                                    }
                                }
                            } else {
                                if (!matches.find(m => m.pubkey === pubkey)) {
                                    matches.push({ nym: cachedNym, pubkey: pubkey });
                                }
                            }
                        }
                    }
                });
            }
        }

        // If still no matches and we have a suffix, we can construct a pubkey
        // This is useful for moderators who might have the full nym#suffix
        if (matches.length === 0 && searchSuffix && searchSuffix.length === 4) {
            // If we're in a community, search through all messages to find a pubkey ending with this suffix
            if (this.currentCommunity) {
                const communityMessages = this.messages.get(this.currentCommunity) || [];
                communityMessages.forEach(msg => {
                    if (msg.pubkey && msg.pubkey.endsWith(searchSuffix)) {
                        const baseNym = msg.author.split('#')[0] || msg.author;
                        if (baseNym.toLowerCase() === searchNym.toLowerCase()) {
                            if (!matches.find(m => m.pubkey === msg.pubkey)) {
                                matches.push({ nym: msg.author, pubkey: msg.pubkey });
                            }
                        }
                    }
                });
            }
        }

        if (matches.length === 0) {
            this.displaySystemMessage(`User ${input} not found. Try using the full nym#xxxx format if you know their pubkey suffix.`);
            return null;
        }

        if (matches.length > 1 && !searchSuffix) {
            const matchList = matches.map(m =>
                `${this.formatNymWithPubkey(m.nym, m.pubkey)}`
            ).join(', ');
            this.displaySystemMessage(`Multiple users found: ${matchList}`);
            this.displaySystemMessage('Please specify using the #xxxx suffix');
            return null;
        }

        return matches[0].pubkey;
    }

    async updateCommunityRole(communityId, targetPubkey, role) {
        const community = this.communityChannels.get(communityId);
        if (!community) return;

        // Get current moderators
        const mods = this.communityModerators.get(communityId) || new Set();

        // Update community definition with new moderator list
        const event = {
            kind: 34550,
            created_at: Math.floor(Date.now() / 1000),
            tags: [
                ['d', communityId],
                ['name', community.name],
                ['description', community.description || ''],
                ['p', this.pubkey, '', 'admin'],
            ],
            content: community.description || '',
            pubkey: this.pubkey
        };

        // Add all moderators
        if (role === 'moderator') {
            mods.add(targetPubkey);
        } else if (role === 'remove') {
            mods.delete(targetPubkey);
        }

        mods.forEach(modPubkey => {
            event.tags.push(['p', modPubkey, '', 'moderator']);
        });

        // Add privacy tag
        if (community.isPrivate) {
            event.tags.push(['private']);
        } else {
            event.tags.push(['public']);
        }

        // Sign and send
        const signedEvent = await this.signEvent(event);

        if (signedEvent) {
            this.sendToRelay(["EVENT", signedEvent]);
        }
    }

    async updateCommunityDefinitionWithBans(communityId) {
        const community = this.communityChannels.get(communityId);
        if (!community) return;

        // Only admin can update community definition
        if (community.admin !== this.pubkey) {
            return;
        }

        // Get current moderators
        const mods = this.communityModerators.get(communityId) || new Set();

        // Get current banned users
        const banned = this.communityBans.get(communityId) || new Set();

        // Create updated community definition
        const event = {
            kind: 34550,
            created_at: Math.floor(Date.now() / 1000),
            tags: [
                ['d', communityId],
                ['name', community.name],
                ['description', community.description || ''],
                ['image', community.imageUrl || ''],
                ['p', this.pubkey, '', 'admin'],
            ],
            content: community.description || '',
            pubkey: this.pubkey
        };

        // Add moderators
        mods.forEach(modPubkey => {
            event.tags.push(['p', modPubkey, '', 'moderator']);
        });

        // Add banned users - THIS IS KEY FOR PERSISTENCE
        banned.forEach(bannedPubkey => {
            event.tags.push(['p', bannedPubkey, '', 'banned']);
        });

        // Add privacy tag
        if (community.isPrivate) {
            event.tags.push(['private']);
        } else {
            event.tags.push(['public']);
        }

        // Sign and send
        const signedEvent = await this.signEvent(event);

        if (signedEvent) {
            this.sendToRelay(["EVENT", signedEvent]);
        }
    }

    async publishCommunityModeration(communityId, targetPubkey, action) {
        const community = this.communityChannels.get(communityId);
        if (!community) return;

        // Use NIP-56 reporting event (kind 1984) for moderation
        const event = {
            kind: 1984, // NIP-56 report/moderation
            created_at: Math.floor(Date.now() / 1000),
            tags: [
                ['a', `34550:${community.admin}:${communityId}`], // Reference to community
                ['p', targetPubkey], // Target user
                ['action', action], // ban, unban, kick
                ['reason', `${action} by moderator`]
            ],
            content: `User ${action} in community ${community.name}`,
            pubkey: this.pubkey
        };

        const signedEvent = await this.signEvent(event);

        if (signedEvent) {
            this.sendToRelay(["EVENT", signedEvent]);
        }
    }

    showCommunitySettingsModal(communityId) {
        const community = this.communityChannels.get(communityId);
        if (!community) return;

        const modal = document.getElementById('communitySettingsModal');
        if (!modal) {
            this.displaySystemMessage('Community settings UI not available');
            return;
        }

        // Populate modal with community data
        document.getElementById('communityNameDisplay').textContent = community.name;
        document.getElementById('communityDescEdit').value = community.description || '';
        document.getElementById('communityPrivacyEdit').value = community.isPrivate ? 'private' : 'public';

        // Load dynamic content
        this.loadCommunitySettingsUI(communityId);

        modal.classList.add('active');
    }

    async loadCommunitySettingsUI(communityId) {
        const community = this.communityChannels.get(communityId);
        if (!community) return;

        // Load community image
        const imageEdit = document.getElementById('communityImageEdit');
        const imagePreview = document.getElementById('communityImagePreview');
        const imagePreviewImg = document.getElementById('communityImagePreviewImg');

        if (imageEdit) {
            imageEdit.value = community.imageUrl || '';
        }

        if (community.imageUrl && imagePreviewImg && imagePreview) {
            imagePreviewImg.src = community.imageUrl;
            imagePreview.style.display = 'block';

            imagePreviewImg.onerror = () => {
                imagePreview.style.display = 'none';
            };
        } else if (imagePreview) {
            imagePreview.style.display = 'none';
        }

        // Add live preview on image URL change
        if (imageEdit) {
            imageEdit.addEventListener('input', (e) => {
                const url = e.target.value.trim();
                if (url && imagePreviewImg && imagePreview) {
                    imagePreviewImg.src = url;
                    imagePreview.style.display = 'block';

                    imagePreviewImg.onerror = () => {
                        imagePreview.style.display = 'none';
                    };
                } else if (imagePreview) {
                    imagePreview.style.display = 'none';
                }
            });
        }

        // Load blocked keywords for this community
        const keywordList = document.getElementById('communityKeywordList');
        if (keywordList) {
            const communityKeywords = this.communityBlockedKeywords?.get(communityId) || new Set();

            if (communityKeywords.size === 0) {
                keywordList.innerHTML = '<div style="color: var(--text-dim); font-size: 12px;">No blocked keywords</div>';
            } else {
                keywordList.innerHTML = '';
                communityKeywords.forEach(keyword => {
                    const item = document.createElement('div');
                    item.style.cssText = 'display: flex; justify-content: space-between; align-items: center; padding: 5px; margin: 2px 0;';
                    item.innerHTML = `
            <span>${this.escapeHtml(keyword)}</span>
            <button class="unblock-btn" onclick="nym.removeCommunityKeyword('${this.escapeHtml(keyword).replace(/'/g, "\\'")}')">Remove</button>
        `;
                    keywordList.appendChild(item);
                });
            }
        }

        // Load moderators list
        const mods = this.communityModerators.get(communityId) || new Set();
        const modsList = document.getElementById('communityModsList');

        if (mods.size === 0) {
            modsList.innerHTML = '<div style="color: var(--text-dim); font-size: 12px;">No moderators assigned</div>';
        } else {
            modsList.innerHTML = '';
            mods.forEach(pubkey => {
                const nym = this.getNymFromPubkey(pubkey);
                const item = document.createElement('div');
                item.style.cssText = 'display: flex; justify-content: space-between; align-items: center; padding: 5px; margin: 2px 0;';
                item.innerHTML = `
        <span>${nym}</span>
        <button class="unblock-btn" onclick="nym.removeModFromSettings('${pubkey}')">Remove</button>
    `;
                modsList.appendChild(item);
            });
        }

        // Load banned users list
        const banned = this.communityBans.get(communityId) || new Set();
        const bansList = document.getElementById('communityBansList');

        if (banned.size === 0) {
            bansList.innerHTML = '<div style="color: var(--text-dim); font-size: 12px;">No banned users</div>';
        } else {
            bansList.innerHTML = '';
            banned.forEach(pubkey => {
                const nym = this.getNymFromPubkey(pubkey);
                const item = document.createElement('div');
                item.style.cssText = 'display: flex; justify-content: space-between; align-items: center; padding: 5px; margin: 2px 0;';
                item.innerHTML = `
        <span>${nym}</span>
        <button class="unblock-btn" onclick="nym.unbanFromSettings('${pubkey}')">Unban</button>
    `;
                bansList.appendChild(item);
            });
        }

        // Update statistics with deduplication
        const members = this.communityMembers.get(communityId) || new Set();

        // Create a deduplicated set of all members (admin + mods + regular members)
        const allMembers = new Set();

        // Add admin (community owner)
        allMembers.add(community.admin);

        // Add all moderators
        mods.forEach(modPubkey => allMembers.add(modPubkey));

        // Add all regular members
        members.forEach(memberPubkey => allMembers.add(memberPubkey));

        // Now calculate stats without double-counting
        const totalMembers = allMembers.size;
        const totalMods = mods.size;
        const totalBanned = banned.size;

        document.getElementById('statMembers').textContent = totalMembers;
        document.getElementById('statMods').textContent = totalMods;
        document.getElementById('statBanned').textContent = totalBanned;
    }

    addCommunityKeyword() {
        const communityId = this.getCurrentCommunityId();
        if (!communityId) return;

        const input = document.getElementById('newCommunityKeywordInput');
        const keyword = input.value.trim().toLowerCase();

        if (keyword) {
            if (!this.communityBlockedKeywords) {
                this.communityBlockedKeywords = new Map();
            }
            if (!this.communityBlockedKeywords.has(communityId)) {
                this.communityBlockedKeywords.set(communityId, new Set());
            }

            this.communityBlockedKeywords.get(communityId).add(keyword);
            this.saveCommunityKeywords(communityId);
            this.loadCommunitySettingsUI(communityId);
            input.value = '';

            // Hide messages containing this keyword in this community
            if (this.currentCommunity === communityId) {
                document.querySelectorAll('.message').forEach(msg => {
                    const content = msg.querySelector('.message-content');
                    if (content && content.textContent.toLowerCase().includes(keyword)) {
                        msg.classList.add('blocked');
                        msg.style.display = 'none';
                    }
                });
            }

            this.displaySystemMessage(`Blocked keyword in community: "${keyword}"`);
        }
    }

    removeCommunityKeyword(keyword) {
        const communityId = this.getCurrentCommunityId();
        if (!communityId) return;

        if (this.communityBlockedKeywords?.has(communityId)) {
            this.communityBlockedKeywords.get(communityId).delete(keyword);
            this.saveCommunityKeywords(communityId);
            this.loadCommunitySettingsUI(communityId);

            // Re-check all messages in this community
            if (this.currentCommunity === communityId) {
                document.querySelectorAll('.message.blocked').forEach(msg => {
                    const content = msg.querySelector('.message-content');
                    if (content) {
                        const hasOtherBlockedKeyword = Array.from(
                            this.communityBlockedKeywords.get(communityId) || []
                        ).some(kw => content.textContent.toLowerCase().includes(kw));

                        if (!hasOtherBlockedKeyword) {
                            msg.classList.remove('blocked');
                            msg.style.display = '';
                        }
                    }
                });
            }

            this.displaySystemMessage(`Unblocked keyword in community: "${keyword}"`);
        }
    }

    saveCommunityKeywords(communityId) {
        if (!this.communityBlockedKeywords?.has(communityId)) return;

        const keywords = Array.from(this.communityBlockedKeywords.get(communityId));
        localStorage.setItem(`nym_community_keywords_${communityId}`, JSON.stringify(keywords));
    }

    loadCommunityKeywords(communityId) {
        const saved = localStorage.getItem(`nym_community_keywords_${communityId}`);
        if (saved) {
            if (!this.communityBlockedKeywords) {
                this.communityBlockedKeywords = new Map();
            }
            this.communityBlockedKeywords.set(communityId, new Set(JSON.parse(saved)));
        }
    }

    hasCommunityBlockedKeyword(text, communityId) {
        if (!this.communityBlockedKeywords?.has(communityId)) return false;

        const lowerText = text.toLowerCase();
        return Array.from(this.communityBlockedKeywords.get(communityId)).some(
            keyword => lowerText.includes(keyword)
        );
    }

    async addModFromSettings() {
        const input = document.getElementById('addModInput').value.trim();
        if (!input) {
            this.displaySystemMessage('Please enter a nym');
            return;
        }

        const communityId = this.getCurrentCommunityId();
        if (!communityId) return;

        const community = this.communityChannels.get(communityId);
        if (!community) {
            this.displaySystemMessage('Current community not found');
            return;
        }

        // Only admin can add moderators
        if (!this.ownedCommunities.has(communityId)) {
            this.displaySystemMessage('Only the community admin can add moderators');
            return;
        }

        const targetPubkey = await this.findUserPubkey(input);
        if (!targetPubkey) {
            // Clear input even on failure
            document.getElementById('addModInput').value = '';
            return;
        }

        const matchedNym = this.getNymFromPubkey(targetPubkey);

        if (targetPubkey === this.pubkey) {
            this.displaySystemMessage("You're already the admin (and a moderator)");
            document.getElementById('addModInput').value = '';
            return;
        }

        // Check if already a moderator
        if (this.communityModerators.has(communityId) &&
            this.communityModerators.get(communityId).has(targetPubkey)) {
            this.displaySystemMessage(`${this.formatNymWithPubkey(matchedNym, targetPubkey)} is already a moderator`);
            document.getElementById('addModInput').value = '';
            return;
        }

        // Add as moderator
        if (!this.communityModerators.has(communityId)) {
            this.communityModerators.set(communityId, new Set());
        }
        this.communityModerators.get(communityId).add(targetPubkey);

        // Update community definition
        await this.updateCommunityDefinitionWithBans(communityId);

        // Parse base nym from display format - this removes HTML tags
        const parsedNym = this.parseNymFromDisplay(matchedNym);
        // Get just the base nym without any suffix
        const baseNym = parsedNym.split('#')[0] || parsedNym;
        const suffix = this.getPubkeySuffix(targetPubkey);
        const fullNym = `${baseNym}#${suffix}`;

        const displayNym = this.formatNymWithPubkey(matchedNym, targetPubkey);
        this.displaySystemMessage(`Added ${displayNym} as a moderator`);

        // Announce in channel with full nym#suffix
        await this.publishCommunityMessage(`⭐ ${fullNym} is now a moderator of this community`, communityId);

        // Clear input and reload UI
        document.getElementById('addModInput').value = '';
        this.loadCommunitySettingsUI(communityId);
    }

    async removeModFromSettings(pubkey) {
        const communityId = this.getCurrentCommunityId();
        if (!communityId) return;

        const community = this.communityChannels.get(communityId);
        if (!community) {
            this.displaySystemMessage('Current community not found');
            return;
        }

        // Only admin can remove moderators
        if (!this.ownedCommunities.has(communityId)) {
            this.displaySystemMessage('Only the community admin can remove moderators');
            return;
        }

        const matchedNym = this.getNymFromPubkey(pubkey);

        if (pubkey === this.pubkey) {
            this.displaySystemMessage("You can't remove yourself as admin");
            return;
        }

        // Check if actually a moderator
        if (!this.communityModerators.has(communityId) ||
            !this.communityModerators.get(communityId).has(pubkey)) {
            this.displaySystemMessage(`${this.formatNymWithPubkey(matchedNym, pubkey)} is not a moderator`);
            return;
        }

        // Remove from moderators
        this.communityModerators.get(communityId).delete(pubkey);

        // Update community definition
        await this.updateCommunityDefinitionWithBans(communityId);

        // Parse base nym from display format - this removes HTML tags
        const parsedNym = this.parseNymFromDisplay(matchedNym);
        // Get just the base nym without any suffix
        const baseNym = parsedNym.split('#')[0] || parsedNym;
        const suffix = this.getPubkeySuffix(pubkey);
        const fullNym = `${baseNym}#${suffix}`;

        const displayNym = this.formatNymWithPubkey(matchedNym, pubkey);
        this.displaySystemMessage(`Removed ${displayNym} as a moderator`);

        // Announce in channel with full nym#suffix
        await this.publishCommunityMessage(`📋 ${fullNym} is no longer a moderator of this community`, communityId);

        // Reload UI
        this.loadCommunitySettingsUI(communityId);
    }

    async unbanFromSettings(pubkey) {
        const communityId = this.getCurrentCommunityId();
        if (!communityId) return;

        const community = this.communityChannels.get(communityId);
        if (!community) return;

        // Check if user is admin or moderator
        const isAdmin = this.ownedCommunities.has(communityId);
        const isMod = this.communityModerators.has(communityId) &&
            this.communityModerators.get(communityId).has(this.pubkey);

        if (!isAdmin && !isMod) {
            this.displaySystemMessage('Only admins and moderators can unban users');
            return;
        }

        // Get target nym for display
        const targetNym = this.getNymFromPubkey(pubkey);

        // Parse base nym from display format - this removes HTML tags
        const parsedNym = this.parseNymFromDisplay(targetNym);
        // Get just the base nym without any suffix
        const baseNym = parsedNym.split('#')[0] || parsedNym;
        const suffix = this.getPubkeySuffix(pubkey);
        const fullNym = `${baseNym}#${suffix}`;

        // Check if actually banned
        if (!this.communityBans.has(communityId) ||
            !this.communityBans.get(communityId).has(pubkey)) {
            this.displaySystemMessage(`${this.formatNymWithPubkey(targetNym, pubkey)} is not banned`);
            return;
        }

        // Remove from bans
        this.communityBans.get(communityId).delete(pubkey);

        // Update community definition
        await this.updateCommunityDefinitionWithBans(communityId);

        // Re-subscribe to the unbanned user's messages for this community
        if (this.connected && this.relay) {
            const filter = {
                kinds: [1],
                authors: [pubkey],
                '#q': [communityId],
                since: Math.floor(Date.now() / 1000)
            };

            this.relay.subscribe([filter], {
                onevent: (event) => {
                    this.handleNostrEvent(event);
                },
                oneose: () => {
                }
            });
        }

        const displayNym = this.formatNymWithPubkey(targetNym, pubkey);
        this.displaySystemMessage(`Unbanned ${displayNym} from this community`);

        // Announce in channel with full nym#suffix
        await this.publishCommunityMessage(`✅ ${fullNym} has been unbanned from this community`, communityId);

        // Reload UI
        this.loadCommunitySettingsUI(communityId);
    }

    async saveCommunitySettings() {
        const communityId = this.getCurrentCommunityId();
        if (!communityId) return;

        const community = this.communityChannels.get(communityId);
        if (!community) return;

        // Get updated values
        const newDesc = document.getElementById('communityDescEdit').value.trim();
        const newImageUrl = document.getElementById('communityImageEdit').value.trim();
        const newPrivacy = document.getElementById('communityPrivacyEdit').value === 'private';

        // Update local state
        community.description = newDesc;
        community.imageUrl = newImageUrl;
        community.isPrivate = newPrivacy;

        // Update the community definition event
        const mods = this.communityModerators.get(communityId) || new Set();

        const event = {
            kind: 34550,
            created_at: Math.floor(Date.now() / 1000),
            tags: [
                ['d', communityId],
                ['name', community.name],
                ['description', newDesc],
                ['image', newImageUrl],
                ['p', this.pubkey, '', 'admin'],
            ],
            content: newDesc,
            pubkey: this.pubkey
        };

        // Add moderators
        mods.forEach(modPubkey => {
            event.tags.push(['p', modPubkey, '', 'moderator']);
        });

        // Add privacy tag
        if (newPrivacy) {
            event.tags.push(['private']);
        } else {
            event.tags.push(['public']);
        }

        // Sign and send
        const signedEvent = await this.signEvent(event);

        if (signedEvent) {
            this.sendToRelay(["EVENT", signedEvent]);
            this.displaySystemMessage('Community settings updated');

            // Update channel badge if privacy changed
            this.updateCommunityBadge(communityId, newPrivacy);

            closeModal('communitySettingsModal');
        }
    }

    updateCommunityBadge(communityId, isPrivate) {
        const item = document.querySelector(`[data-community="${communityId}"]`);
        if (!item) return;

        const badgeContainer = item.querySelector('.channel-badges');
        const existingBadge = badgeContainer.querySelector('.std-badge');

        if (existingBadge) {
            if (isPrivate) {
                existingBadge.style.borderColor = 'var(--purple)';
                existingBadge.style.color = 'var(--purple)';
                existingBadge.textContent = 'PRI';
            } else {
                existingBadge.style.borderColor = 'var(--primary)';
                existingBadge.style.color = 'var(--primary)';
                existingBadge.textContent = 'PUB';
            }
        }
    }

    async deleteCommunity() {
        const communityId = this.getCurrentCommunityId();
        if (!communityId) return;

        const community = this.communityChannels.get(communityId);
        if (!community) return;

        if (!confirm(`Are you sure you want to delete the community "${community.name}"? This cannot be undone.`)) {
            return;
        }

        // Publish deletion event (kind 5 - deletion)
        const event = {
            kind: 5,
            created_at: Math.floor(Date.now() / 1000),
            tags: [
                ['a', `34550:${this.pubkey}:${communityId}`]
            ],
            content: 'Community deleted by admin',
            pubkey: this.pubkey
        };

        const signedEvent = await this.signEvent(event);

        if (signedEvent) {
            this.sendToRelay(["EVENT", signedEvent]);
        }

        // Remove locally
        this.communityChannels.delete(communityId);
        this.ownedCommunities.delete(communityId);
        this.communityMembers.delete(communityId);
        this.communityModerators.delete(communityId);
        this.communityBans.delete(communityId);
        this.communityInvites.delete(communityId);

        // Remove from UI
        const item = document.querySelector(`[data-community="${communityId}"]`);
        if (item) {
            item.remove();
        }

        this.channels.delete(communityId);
        this.userJoinedChannels.delete(communityId);

        this.displaySystemMessage(`Community "${community.name}" has been deleted`);

        closeModal('communitySettingsModal');

        // Switch to bar
        this.switchChannel('bar', '');
    }
}

// NIP-46 Nostr Connect Client Implementation
class NostrConnectClient {
    constructor() {
        this.localKeypair = null;
        this.remotePubkey = null;
        this.relayUrl = null;
        this.relay = null;
        this.pendingRequests = new Map();
        this.secret = null;
        this.connected = false;
        this.connectionTimeout = null;
    }

    // Helper to convert Uint8Array to hex string
    bytesToHex(bytes) {
        if (typeof bytes === 'string') return bytes;
        return Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
    }

    parseBunkerUri(uri) {
        try {
            if (!uri.startsWith('bunker://')) {
                throw new Error('Invalid bunker URI format');
            }

            const withoutProtocol = uri.substring(9);
            const [pubkeyPart, queryString] = withoutProtocol.split('?');

            this.remotePubkey = pubkeyPart;

            const params = new URLSearchParams(queryString);
            this.relayUrl = params.get('relay');
            this.secret = params.get('secret');

            if (!this.relayUrl) {
                throw new Error('Bunker URI must include relay parameter');
            }

            return {
                remotePubkey: this.remotePubkey,
                relay: this.relayUrl,
                secret: this.secret
            };
        } catch (error) {
            throw error;
        }
    }

    async generateBunkerUri(relayUrl = null) {
        const sk = window.NostrTools.generateSecretKey();
        const pk = window.NostrTools.getPublicKey(sk);

        // Convert to hex for compatibility
        this.localKeypair = {
            privkey: this.bytesToHex(sk),
            pubkey: pk
        };
        this.relayUrl = relayUrl || 'wss://relay.nsec.app';
        this.secret = this.generateSecret();

        const uri = `bunker://${pk}?relay=${encodeURIComponent(this.relayUrl)}&secret=${this.secret}`;
        return uri;
    }

    generateSecret() {
        const array = new Uint8Array(16);
        crypto.getRandomValues(array);
        return Array.from(array, byte => byte.toString(16).padStart(2, '0')).join('');
    }

    async connect(bunkerUri) {
        return new Promise(async (resolve, reject) => {
            try {
                const parsed = this.parseBunkerUri(bunkerUri);

                const sk = window.NostrTools.generateSecretKey();
                const pk = window.NostrTools.getPublicKey(sk);

                // Convert to hex for compatibility
                this.localKeypair = {
                    privkey: this.bytesToHex(sk),
                    pubkey: pk
                };

                await this.connectToRelay();

                const connectResponse = await this.sendRequest('connect', [pk, this.secret || '']);

                if (connectResponse === 'ack') {
                    this.connected = true;
                    resolve(this.remotePubkey);
                } else {
                    throw new Error('Connection rejected by remote signer');
                }

            } catch (error) {
                reject(error);
            }
        });
    }

    async connectToRelay() {
        return new Promise((resolve, reject) => {
            try {
                this.relay = new WebSocket(this.relayUrl);

                this.relay.onopen = () => {

                    const subId = 'nip46-' + Math.random().toString(36).substring(7);
                    const filter = {
                        kinds: [24133],
                        "#p": [this.localKeypair.pubkey],
                        authors: [this.remotePubkey]
                    };

                    this.relay.send(JSON.stringify(['REQ', subId, filter]));
                    resolve();
                };

                this.relay.onerror = (error) => {
                    reject(error);
                };

                this.relay.onmessage = async (msg) => {
                    await this.handleRelayMessage(msg);
                };

            } catch (error) {
                reject(error);
            }
        });
    }

    async handleRelayMessage(msg) {
        try {
            const data = JSON.parse(msg.data);

            if (data[0] === 'EVENT') {
                const event = data[2];

                if (event.kind === 24133) {

                    // Use NIP-44 decryption
                    const conversationKey = window.NostrTools.nip44.getConversationKey(
                        this.localKeypair.privkey,
                        event.pubkey
                    );
                    const decrypted = window.NostrTools.nip44.decrypt(
                        event.content,
                        conversationKey
                    );


                    const response = JSON.parse(decrypted);

                    const requestId = response.id;

                    if (this.pendingRequests.has(requestId)) {
                        const { resolve, reject } = this.pendingRequests.get(requestId);

                        // Handle auth_url response
                        if (response.result === 'auth_url' && response.error) {
                            // Open the auth URL in a popup
                            const width = 500;
                            const height = 700;
                            const left = (window.screen.width - width) / 2;
                            const top = (window.screen.height - height) / 2;
                            window.open(
                                response.error,
                                'nostr-connect-auth',
                                `width=${width},height=${height},left=${left},top=${top},popup=yes`
                            );
                            return;
                        }

                        if (response.error) {
                            reject(new Error(response.error));
                        } else {
                            resolve(response.result);
                        }

                        this.pendingRequests.delete(requestId);
                    } else {
                    }
                }
            } else if (data[0] === 'OK') {
            }
        } catch (error) {
        }
    }

    async sendRequest(method, params = []) {
        return new Promise(async (resolve, reject) => {
            try {
                const requestId = this.generateRequestId();

                const request = {
                    id: requestId,
                    method: method,
                    params: params
                };


                // Use NIP-44 encryption
                const conversationKey = window.NostrTools.nip44.getConversationKey(
                    this.localKeypair.privkey,
                    this.remotePubkey
                );
                const encrypted = window.NostrTools.nip44.encrypt(
                    JSON.stringify(request),
                    conversationKey
                );

                const event = {
                    kind: 24133,
                    created_at: Math.floor(Date.now() / 1000),
                    tags: [['p', this.remotePubkey]],
                    content: encrypted,
                    pubkey: this.localKeypair.pubkey
                };

                const signedEvent = window.NostrTools.finalizeEvent(event, this.localKeypair.privkey);

                this.relay.send(JSON.stringify(['EVENT', signedEvent]));

                this.pendingRequests.set(requestId, { resolve, reject });

                setTimeout(() => {
                    if (this.pendingRequests.has(requestId)) {
                        this.pendingRequests.delete(requestId);
                        reject(new Error('Request timeout'));
                    }
                }, 30000);

            } catch (error) {
                reject(error);
            }
        });
    }

    generateRequestId() {
        return Math.random().toString(36).substring(2) + Date.now().toString(36);
    }

    async getPublicKey() {
        return await this.sendRequest('get_public_key');
    }

    async signEvent(event) {
        const unsignedEvent = {
            kind: event.kind,
            created_at: event.created_at,
            tags: event.tags,
            content: event.content,
            pubkey: event.pubkey
        };

        const result = await this.sendRequest('sign_event', [JSON.stringify(unsignedEvent)]);
        return JSON.parse(result);
    }

    async nip04Encrypt(thirdPartyPubkey, plaintext) {
        return await this.sendRequest('nip04_encrypt', [thirdPartyPubkey, plaintext]);
    }

    async nip04Decrypt(thirdPartyPubkey, ciphertext) {
        return await this.sendRequest('nip04_decrypt', [thirdPartyPubkey, ciphertext]);
    }

    async nip44Encrypt(thirdPartyPubkey, plaintext) {
        return await this.sendRequest('nip44_encrypt', [thirdPartyPubkey, plaintext]);
    }

    async nip44Decrypt(thirdPartyPubkey, ciphertext) {
        return await this.sendRequest('nip44_decrypt', [thirdPartyPubkey, ciphertext]);
    }

    disconnect() {
        if (this.relay) {
            this.relay.close();
        }
        this.connected = false;
        this.pendingRequests.clear();
    }
}

// Global instance
const nym = new NYM();

// Global functions for onclick handlers
function toggleSidebar() {
    nym.toggleSidebar();
}

function toggleSearch(inputId) {
    const search = document.getElementById(inputId);
    search.classList.toggle('active');
    if (search.classList.contains('active')) {
        search.focus();
    }
}

function sendMessage() {
    nym.sendMessage();
}

function selectImage() {
    document.getElementById('fileInput').click();
}

function selectP2PFile() {
    document.getElementById('p2pFileInput').click();
}

function closeModal(id) {
    document.getElementById(id).classList.remove('active');
}

function closeImageModal() {
    document.getElementById('imageModal').classList.remove('active');
}

function editNick() {
    document.getElementById('newNickInput').value = nym.nym;
    document.getElementById('nickEditModal').classList.add('active');
}

function changeNick() {
    const newNick = document.getElementById('newNickInput').value.trim();
    if (newNick && newNick !== nym.nym) {
        nym.cmdNick(newNick);
    }
    closeModal('nickEditModal');
}

async function changeRelay() {
    const relaySelect = document.getElementById('connectedRelaySelect').value;
    const customRelay = document.getElementById('customConnectedRelay').value;

    const newRelayUrl = relaySelect === 'custom' ? customRelay : relaySelect;

    if (!newRelayUrl) {
        alert('Please select or enter a relay URL');
        return;
    }

    nym.displaySystemMessage('Switching relay...');
    await nym.connectToRelay(newRelayUrl);
}

async function showSettings() {
    nym.updateRelayStatus();

    // Load lightning address
    const lightningInput = document.getElementById('lightningAddressInput');
    if (lightningInput) {
        lightningInput.value = nym.lightningAddress || '';
    }

    // Load proximity sorting setting
    const proximitySelect = document.getElementById('proximitySelect');
    if (proximitySelect) {
        proximitySelect.value = nym.settings.sortByProximity ? 'true' : 'false';
    }

    // Load blur settings
    const blurSelect = document.getElementById('blurImagesSelect');
    if (blurSelect) {
        blurSelect.value = nym.blurOthersImages ? 'true' : 'false';
    }

    // Show/hide and load auto-ephemeral setting ONLY for ephemeral mode
    const autoEphemeralSettingGroup = document.getElementById('autoEphemeralSettingGroup');
    const autoEphemeralSelect = document.getElementById('autoEphemeralSelect');

    if (nym.connectionMode === 'ephemeral') {
        autoEphemeralSettingGroup.style.display = 'block';
        if (autoEphemeralSelect) {
            const autoEphemeral = localStorage.getItem('nym_auto_ephemeral') === 'true';
            autoEphemeralSelect.value = autoEphemeral ? 'true' : 'false';
        }
    } else {
        autoEphemeralSettingGroup.style.display = 'none';
    }

    // Initialize pinned landing channel searchable dropdown
    const pinnedSearchInput = document.getElementById('pinnedLandingChannelSearch');
    const pinnedValueInput = document.getElementById('pinnedLandingChannelValue');
    const pinnedDropdown = document.getElementById('pinnedLandingChannelDropdown');

    if (pinnedSearchInput && pinnedValueInput && pinnedDropdown) {
        // Get current pinned value
        const currentPinned = nym.pinnedLandingChannel || { type: 'ephemeral', channel: 'bar' };

        // Build all channel options
        const channelOptions = [];

        // Add common ephemeral channels
        nym.commonChannels.forEach(channel => {
            channelOptions.push({
                group: 'Common Ephemeral Channels',
                label: `#${channel}`,
                value: { type: 'ephemeral', channel: channel },
                searchText: channel.toLowerCase()
            });
        });

        // Add geohash channels
        Array.from(nym.channels.entries())
            .filter(([key, val]) => nym.isValidGeohash(key))
            .forEach(([geohash]) => {
                const location = nym.getGeohashLocation(geohash);
                channelOptions.push({
                    group: 'Geohash Channels',
                    label: location ? `${geohash} (${location})` : geohash,
                    value: { type: 'geohash', geohash: geohash },
                    searchText: (geohash + ' ' + (location || '')).toLowerCase()
                });
            });

        // Add community channels
        nym.communityChannels.forEach((community, communityId) => {
            channelOptions.push({
                group: 'Community Channels',
                label: `#${community.name} (Community)`,
                value: { type: 'community', communityId: communityId, name: community.name },
                searchText: community.name.toLowerCase()
            });
        });

        // Add user joined channels (excluding already listed ones)
        Array.from(nym.userJoinedChannels)
            .filter(ch => !nym.isValidGeohash(ch) && !nym.commonChannels.includes(ch))
            .forEach(channel => {
                channelOptions.push({
                    group: 'User Joined Channels',
                    label: `#${channel}`,
                    value: { type: 'ephemeral', channel: channel },
                    searchText: channel.toLowerCase()
                });
            });

        // Set current value
        const currentOption = channelOptions.find(opt =>
            JSON.stringify(opt.value) === JSON.stringify(currentPinned)
        );
        if (currentOption) {
            pinnedSearchInput.value = currentOption.label;
            pinnedValueInput.value = JSON.stringify(currentOption.value);
        } else {
            pinnedSearchInput.value = '#bar';
            pinnedValueInput.value = JSON.stringify({ type: 'ephemeral', channel: 'bar' });
        }

        // Function to render filtered options
        const renderOptions = (filter = '') => {
            const filterLower = filter.toLowerCase().replace(/^#/, '');
            const filtered = filter
                ? channelOptions.filter(opt => opt.searchText.includes(filterLower))
                : channelOptions;

            if (filtered.length === 0) {
                pinnedDropdown.innerHTML = '<div style="padding: 8px 12px; color: var(--text-dim);">No channels found</div>';
                return;
            }

            // Group options
            const grouped = {};
            filtered.forEach(opt => {
                if (!grouped[opt.group]) grouped[opt.group] = [];
                grouped[opt.group].push(opt);
            });

            // Render grouped options
            let html = '';
            Object.keys(grouped).forEach(groupName => {
                html += `<div style="padding: 6px 12px; font-size: 11px; font-weight: bold; color: var(--text-dim); text-transform: uppercase; background: var(--background); margin-top: 4px;">${groupName}</div>`;
                grouped[groupName].forEach(opt => {
                    html += `<div class="channel-dropdown-option" data-value='${JSON.stringify(opt.value)}' style="padding: 8px 12px; cursor: pointer; color: var(--text);">${opt.label}</div>`;
                });
            });

            pinnedDropdown.innerHTML = html;

            // Add click handlers
            pinnedDropdown.querySelectorAll('.channel-dropdown-option').forEach(option => {
                option.addEventListener('mouseenter', function () {
                    this.style.background = 'var(--background)';
                });
                option.addEventListener('mouseleave', function () {
                    this.style.background = 'transparent';
                });
                option.addEventListener('click', function () {
                    const valueData = JSON.parse(this.dataset.value);
                    pinnedSearchInput.value = this.textContent;
                    pinnedValueInput.value = this.dataset.value;
                    pinnedDropdown.style.display = 'none';
                });
            });
        };

        // Show dropdown on focus
        pinnedSearchInput.addEventListener('focus', () => {
            renderOptions(pinnedSearchInput.value);
            pinnedDropdown.style.display = 'block';
        });

        // Filter on input
        pinnedSearchInput.addEventListener('input', () => {
            renderOptions(pinnedSearchInput.value);
            pinnedDropdown.style.display = 'block';
        });

        // Hide dropdown on blur (with delay for click to register)
        pinnedSearchInput.addEventListener('blur', () => {
            setTimeout(() => {
                pinnedDropdown.style.display = 'none';
            }, 200);
        });

        // Prevent dropdown from closing when clicking inside it
        pinnedDropdown.addEventListener('mousedown', (e) => {
            e.preventDefault();
        });
    }

    document.getElementById('themeSelect').value = nym.settings.theme;
    document.getElementById('soundSelect').value = nym.settings.sound;
    document.getElementById('autoscrollSelect').value = nym.settings.autoscroll;
    document.getElementById('timestampSelect').value = nym.settings.showTimestamps;
    document.getElementById('timeFormatSelect').value = nym.settings.timeFormat;

    // Show/hide time format option based on timestamp visibility
    const timeFormatGroup = document.getElementById('timeFormatGroup');
    if (timeFormatGroup) {
        timeFormatGroup.style.display = nym.settings.showTimestamps ? 'block' : 'none';
    }

    nym.updateBlockedList();
    nym.updateKeywordList();
    nym.updateBlockedChannelsList();

    // Fill in disappearing message controls
    const dmEnabledSel = document.getElementById('dmForwardSecrecySelect');
    const dmTtlSel = document.getElementById('dmTTLSelect');
    const dmTtlGroup = document.getElementById('dmTTLGroup');

    if (dmEnabledSel && dmTtlSel && dmTtlGroup) {
        dmEnabledSel.value = nym.settings.dmForwardSecrecyEnabled ? 'true' : 'false';
        dmTtlSel.value = String(nym.settings.dmTTLSeconds || 86400);
        dmTtlGroup.style.display = nym.settings.dmForwardSecrecyEnabled ? 'block' : 'none';

        dmEnabledSel.onchange = () => {
            dmTtlGroup.style.display = dmEnabledSel.value === 'true' ? 'block' : 'none';
        };
    }

    // Fill in read receipts toggle
    const readReceiptsSel = document.getElementById('readReceiptsSelect');
    if (readReceiptsSel) {
        readReceiptsSel.value = nym.settings.readReceiptsEnabled !== false ? 'true' : 'false';
    }

    document.getElementById('settingsModal').classList.add('active');
}

async function saveSettings() {
    // Get all settings values
    const lightningAddress = document.getElementById('lightningAddressInput').value.trim();
    const theme = document.getElementById('themeSelect').value;
    const sound = document.getElementById('soundSelect').value;
    const autoscroll = document.getElementById('autoscrollSelect').value === 'true';
    const showTimestamps = document.getElementById('timestampSelect').value === 'true';
    const timeFormat = document.getElementById('timeFormatSelect').value;
    const sortByProximity = document.getElementById('proximitySelect').value === 'true';
    const blurImages = document.getElementById('blurImagesSelect').value === 'true';

    // Apply all settings
    nym.settings.theme = theme;
    nym.settings.sound = sound;
    nym.settings.autoscroll = autoscroll;
    nym.settings.showTimestamps = showTimestamps;
    nym.settings.timeFormat = timeFormat;

    // Apply blur settings
    nym.blurOthersImages = blurImages;
    nym.saveImageBlurSettings();

    // Read disappearing message controls
    const dmEnabled = document.getElementById('dmForwardSecrecySelect').value === 'true';
    const dmTTL = parseInt(document.getElementById('dmTTLSelect').value || '86400', 10);

    // Apply in memory
    nym.settings.dmForwardSecrecyEnabled = dmEnabled;
    nym.settings.dmTTLSeconds = isFinite(dmTTL) && dmTTL > 0 ? dmTTL : 86400;

    // Persist locally
    localStorage.setItem('nym_dm_fwdsec_enabled', String(nym.settings.dmForwardSecrecyEnabled));
    localStorage.setItem('nym_dm_ttl_seconds', String(nym.settings.dmTTLSeconds));

    // Read and save read receipts setting
    const readReceiptsEnabled = document.getElementById('readReceiptsSelect').value === 'true';
    nym.settings.readReceiptsEnabled = readReceiptsEnabled;
    localStorage.setItem('nym_read_receipts_enabled', String(readReceiptsEnabled));

    // Only handle auto-ephemeral if currently in ephemeral mode
    if (nym.connectionMode === 'ephemeral') {
        const autoEphemeral = document.getElementById('autoEphemeralSelect').value === 'true';
        if (autoEphemeral) {
            localStorage.setItem('nym_auto_ephemeral', 'true');
        } else {
            localStorage.removeItem('nym_auto_ephemeral');
        }
    }

    // Save pinned landing channel
    const pinnedValueInput = document.getElementById('pinnedLandingChannelValue');
    if (pinnedValueInput && pinnedValueInput.value) {
        try {
            const pinnedLandingChannel = JSON.parse(pinnedValueInput.value);
            nym.pinnedLandingChannel = pinnedLandingChannel;
            nym.settings.pinnedLandingChannel = pinnedLandingChannel;
            localStorage.setItem('nym_pinned_landing_channel', JSON.stringify(pinnedLandingChannel));
        } catch (e) {
            // Fallback to default
            const defaultChannel = { type: 'ephemeral', channel: 'bar' };
            nym.pinnedLandingChannel = defaultChannel;
            nym.settings.pinnedLandingChannel = defaultChannel;
            localStorage.setItem('nym_pinned_landing_channel', JSON.stringify(defaultChannel));
        }
    }

    // Handle proximity sorting
    if (sortByProximity) {
        if (!nym.userLocation) {
            // Request location permission
            navigator.geolocation.getCurrentPosition(
                async (position) => {
                    nym.userLocation = {
                        lat: position.coords.latitude,
                        lng: position.coords.longitude
                    };
                    nym.settings.sortByProximity = true;
                    localStorage.setItem('nym_sort_proximity', 'true');

                    // Re-sort immediately after getting location
                    nym.sortChannelsByActivity();

                    nym.displaySystemMessage('Location access granted. Geohash channels sorted by proximity.');

                    // Sync to Nostr if logged in
                    if (nym.connectionMode !== 'ephemeral') {
                        await nym.saveSyncedSettings();
                    }
                },
                (error) => {
                    nym.displaySystemMessage('Location access denied. Proximity sorting disabled.');
                    nym.settings.sortByProximity = false;
                    localStorage.setItem('nym_sort_proximity', 'false');
                    document.getElementById('proximitySelect').value = 'false';
                }
            );
        } else {
            // Already have location
            nym.settings.sortByProximity = true;
            localStorage.setItem('nym_sort_proximity', 'true');
            nym.sortChannelsByActivity(); // Re-sort
        }
    } else {
        // Disabling
        nym.settings.sortByProximity = false;
        localStorage.setItem('nym_sort_proximity', 'false');
        nym.userLocation = null;
        nym.sortChannelsByActivity(); // Re-sort to default
    }

    // Save theme and other settings
    nym.applyTheme(theme);
    nym.saveSettings();
    localStorage.setItem('nym_time_format', timeFormat);

    // Refresh messages to apply new time format
    nym.refreshMessageTimestamps();

    // Save lightning address
    if (lightningAddress !== nym.lightningAddress) {
        await nym.saveLightningAddress(lightningAddress || null);
    }

    // Sync to Nostr
    if (nym.connectionMode !== 'ephemeral') {
        await nym.saveSyncedSettings();
        nym.displaySystemMessage('Settings saved and synced to Nostr');
    } else {
        nym.displaySystemMessage('Settings saved locally');
    }

    closeModal('settingsModal');
}

function showAbout() {
    const connectedRelays = nym.relayPool.size;
    nym.displaySystemMessage(`
═══ NYM - Nostr Ynstant Messenger v2.26.69 ═══<br/>
Protocol: <a href="https://nostr.com" target="_blank" rel="noopener" style="color: var(--secondary)">Nostr</a> (kinds 4550, 20000, 23333, 34550 channels)<br/>
Connected Relays: ${connectedRelays} relays<br/>
Your nym: ${nym.nym || 'Not set'}<br/>
<br/>
Created for ephemeral, anonymous communication.<br/>
Your identity exists only for this session.<br/>
No accounts. No persistence. Just nyms.<br/>
<br/>
Inspired by and bridged with Jack Dorsey's <a href="https://bitchat.free" target="_blank" rel="noopener" style="color: var(--secondary)">Bitchat</a><br/>
<br/>
NYM is FOSS code on <a href="https://github.com/Spl0itable/NYM" target="_blank" rel="noopener" style="color: var(--secondary)">GitHub</a><br/><br/>
Made with ♥ by <a href="https://nostrservices.com" target="_blank" rel="noopener" style="color: var(--secondary)">21 Million LLC</a><br/><br/>
Lead developer: <a href="https://njump.me/npub16jdfqgazrkapk0yrqm9rdxlnys7ck39c7zmdzxtxqlmmpxg04r0sd733sv" target="_blank" rel="noopener" style="color: var(--secondary)">Luxas</a>
`);
}

function showChannelModal() {
    document.getElementById('channelModal').classList.add('active');
}

async function joinOrCreateChannel() {
    const channelType = document.getElementById('channelTypeSelect').value;

    if (channelType === 'standard') {
        let name = document.getElementById('channelNameInput').value.trim();

        // Validate and sanitize
        if (!name) {
            alert('Please enter a channel name');
            return;
        }

        // Remove spaces and invalid characters
        name = name.toLowerCase().replace(/[^a-z0-9-]/g, '');

        if (!name) {
            alert('Invalid channel name. Use only letters, numbers, and hyphens.');
            return;
        }

        if (name.includes(' ')) {
            alert('Channel names cannot contain spaces. Use hyphens instead (e.g., "my-channel")');
            return;
        }

        await nym.cmdJoin(name);

    } else if (channelType === 'geohash') {
        let geohash = document.getElementById('geohashInput').value.trim().toLowerCase();
        geohash = geohash.replace(/[^0-9bcdefghjkmnpqrstuvwxyz]/g, '');

        if (!geohash) {
            alert('Please enter a valid geohash');
            return;
        }

        if (!nym.isValidGeohash(geohash)) {
            alert('Invalid geohash. Valid characters are: 0-9, b-z (except a, i, l, o)');
            return;
        }

        await nym.cmdJoin('#' + geohash);

    } else if (channelType === 'community') {
        // Check if ephemeral user
        if (nym.connectionMode === 'ephemeral') {
            alert('Community channels require a persistent identity. Please use extension or nsec login.');
            closeModal('channelModal');
            return;
        }

        let name = document.getElementById('communityNameInput').value.trim();
        const description = document.getElementById('communityDescInput').value.trim();
        const imageUrl = document.getElementById('communityImageInput').value.trim();
        const isPrivate = document.getElementById('communityPrivacySelect').value === 'private';

        if (!name) {
            alert('Please enter a community name');
            return;
        }

        // Remove spaces and invalid characters
        name = name.toLowerCase().replace(/[^a-z0-9-]/g, '');

        if (!name) {
            alert('Invalid community name. Use only letters, numbers, and hyphens.');
            return;
        }

        // Double-check for spaces (should be caught by oninput, but just in case)
        if (name.includes(' ')) {
            alert('Community names cannot contain spaces. Use hyphens instead (e.g., "my-community")');
            return;
        }

        const communityId = await nym.createCommunityChannel(name, description, isPrivate, imageUrl);
        if (communityId) {
            nym.switchToCommunity(communityId);
        }
    }

    closeModal('channelModal');
    document.getElementById('channelNameInput').value = '';
    document.getElementById('geohashInput').value = '';
    document.getElementById('communityNameInput').value = '';
    document.getElementById('communityDescInput').value = '';
    document.getElementById('communityImageInput').value = '';
    document.getElementById('communityPrivacySelect').value = 'public';
}

// Function to check for saved connection on page load
async function checkSavedConnection() {
    // Auto-ephemeral preference FIRST
    const autoEphemeral = localStorage.getItem('nym_auto_ephemeral');
    if (autoEphemeral === 'true') {
        try {
            // Hide setup modal
            const setupModal = document.getElementById('setupModal');
            setupModal.classList.remove('active');

            nym.displaySystemMessage('Auto-starting ephemeral session...');

            // Generate ephemeral keypair
            await nym.generateKeypair();
            nym.nym = nym.generateRandomNym();
            nym.connectionMode = 'ephemeral';
            document.getElementById('currentNym').textContent = nym.nym;

            // Connect to relays
            await nym.connectToRelays();

            // Request notification permission
            if (typeof Notification !== 'undefined' && Notification.permission === 'default') {
                Notification.requestPermission();
            }

            // Welcome message
            nym.displaySystemMessage(`Welcome to NYM, ${nym.nym}! Type /help for available commands.`);
            nym.displaySystemMessage(`Your ephemeral identity is active for this session only.`);
            nym.displaySystemMessage(`Click on any nym's nickname for more options.`);

            // Start tutorial if not seen
            window.maybeStartTutorial(false);

            // Route to channel from URL if present
            await routeToUrlChannel();

            return; // Exit early
        } catch (error) {
            // Clear the preference and show setup modal
            localStorage.removeItem('nym_auto_ephemeral');
            document.getElementById('setupModal').classList.add('active');
            return;
        }
    }

    const savedMode = localStorage.getItem('nym_connection_mode');
    const savedRelay = localStorage.getItem('nym_relay_url');
    const savedNsec = localStorage.getItem('nym_nsec');
    const savedBunkerUri = localStorage.getItem('nym_bunker_uri');

    // Saved NSEC restore
    if (savedNsec) {
        try {
            const setupModal = document.getElementById('setupModal');
            setupModal.classList.remove('active');

            nym.displaySystemMessage('Restoring NSEC session...');

            // Restore from saved nsec
            nym.privkey = nym.decodeNsec(savedNsec);
            nym.pubkey = window.NostrTools.getPublicKey(nym.privkey);
            nym.connectionMode = 'nsec';

            // Default text while loading
            nym.nym = 'Loading profile...';
            document.getElementById('currentNym').textContent = nym.nym;

            // Connect to relays
            await nym.connectToRelays();

            // Fetch profile after connection
            if (nym.connected) {
                await nym.fetchProfileFromRelay(nym.pubkey);
                if (nym.nym === 'Loading profile...') {
                    nym.nym = nym.generateRandomNym();
                    document.getElementById('currentNym').textContent = nym.nym;
                }
            }

            if (typeof Notification !== 'undefined' && Notification.permission === 'default') {
                Notification.requestPermission();
            }

            nym.displaySystemMessage(`Welcome back to NYM, ${nym.nym}!`);
            nym.displaySystemMessage(`Your Nostr identity has been restored.`);
            nym.displaySystemMessage(`Type /help for available commands.`);

            // Start tutorial if not seen
            window.maybeStartTutorial(false);

            return;
        } catch (error) {
            localStorage.removeItem('nym_nsec');
            localStorage.removeItem('nym_connection_mode');
            localStorage.removeItem('nym_relay_url');
            document.getElementById('setupModal').classList.add('active');
        }
        return;
    }

    // Bunker mode restore
    if (savedBunkerUri && savedMode === 'bunker') {
        try {
            const setupModal = document.getElementById('setupModal');
            setupModal.classList.remove('active');

            nym.displaySystemMessage('Reconnecting with Nostr Connect bunker...');
            await nym.useNostrConnect(savedBunkerUri);

            await nym.connectToRelays();

            // Fetch profile after connection if not already loaded
            if (nym.connected && (!nym.nym || nym.nym === 'Loading profile...')) {
                await nym.fetchProfileFromRelay(nym.pubkey);
            }

            // Fallback to random nym if profile wasn't found
            if (!nym.nym || nym.nym === 'Loading profile...') {
                nym.nym = nym.generateRandomNym();
                document.getElementById('currentNym').textContent = nym.nym;
            }

            if (typeof Notification !== 'undefined' && Notification.permission === 'default') {
                Notification.requestPermission();
            }

            nym.displaySystemMessage(`Welcome back to NYM, ${nym.nym}!`);
            nym.displaySystemMessage(`Your Nostr Connect identity has been restored.`);
            nym.displaySystemMessage(`Type /help for available commands.`);

            await routeToUrlChannel();
            window.maybeStartTutorial(false);
            return;
        } catch (error) {
            localStorage.removeItem('nym_bunker_uri');
        }
    }

    // Extension mode restore
    if (savedMode === 'extension' && window.nostr) {
        try {
            const setupModal = document.getElementById('setupModal');
            setupModal.classList.remove('active');

            nym.displaySystemMessage('Reconnecting with Nostr extension...');
            await nym.useExtension();

            // Connect to all relays, not just one
            await nym.connectToRelays();

            // Fetch profile after connection if not already loaded
            if (nym.connected && (!nym.nym || nym.nym === 'Loading profile...')) {
                await nym.fetchProfileFromRelay(nym.pubkey);
            }

            // Fallback to random nym if profile wasn't found
            if (!nym.nym || nym.nym === 'Loading profile...') {
                nym.nym = nym.generateRandomNym();
                document.getElementById('currentNym').textContent = nym.nym;
            }

            if (typeof Notification !== 'undefined' && Notification.permission === 'default') {
                Notification.requestPermission();
            }

            nym.displaySystemMessage(`Welcome back to NYM, ${nym.nym}!`);
            nym.displaySystemMessage(`Your Nostr identity has been restored.`);
            nym.displaySystemMessage(`Type /help for available commands.`);

            // Start tutorial if not seen
            window.maybeStartTutorial(false);

        } catch (error) {
            localStorage.removeItem('nym_connection_mode');
            localStorage.removeItem('nym_relay_url');
            document.getElementById('setupModal').classList.add('active');
        }
    }
    // If no saved connection, the setup modal remains visible (default).
}

async function initializeNym() {
    // Show loading state on button
    const enterBtn = document.getElementById('enterNymBtn');
    const originalBtnText = enterBtn.innerHTML;
    enterBtn.disabled = true;
    enterBtn.innerHTML = '<span class="loader"></span> Connecting...';

    try {
        // Check if running in NYMApp shell
        const isNYMApp = navigator.userAgent.includes('NYMApp');

        const mode = document.getElementById('connectionMode').value;
        nym.connectionMode = mode; // Store connection mode


        // Get or generate nym first
        const nymInput = document.getElementById('nymInput').value.trim();

        // Handle different connection modes
        if (mode === 'ephemeral') {
            await nym.generateKeypair();
            nym.nym = nymInput || nym.generateRandomNym();
            document.getElementById('currentNym').textContent = nym.nym;
            localStorage.removeItem('nym_connection_mode');

            // Auto-ephemeral checkbox
            const autoEphemeralCheckbox = document.getElementById('autoEphemeralCheckbox');
            if (autoEphemeralCheckbox && autoEphemeralCheckbox.checked) {
                localStorage.setItem('nym_auto_ephemeral', 'true');
            }

        } else if (mode === 'extension') {
            await nym.useExtension();

            if (nym.nym === 'Loading profile...' && !nymInput) {
                nym.nym = nym.generateRandomNym();
                document.getElementById('currentNym').textContent = nym.nym;
            } else if (nymInput && nym.nym === 'Loading profile...') {
                nym.nym = nymInput;
                document.getElementById('currentNym').textContent = nym.nym;
            }

        } else if (mode === 'nsec') {
            let nsecValue = document.getElementById('nsecInput').value.trim();

            if (!nsecValue) {
                const savedNsec = localStorage.getItem('nym_nsec');
                if (savedNsec) {
                    nsecValue = savedNsec;
                }
            }

            if (!nsecValue) {
                throw new Error('Please enter your NSEC');
            }

            // Decode NSEC to get private key
            nym.privkey = nym.decodeNsec(nsecValue);
            nym.pubkey = window.NostrTools.getPublicKey(nym.privkey);

            // Queue profile fetch - will be processed after relay connection
            // Don't await here to avoid 3-second timeout when not connected
            nym.fetchProfileFromRelay(nym.pubkey);

            // Use input nym if provided, otherwise set placeholder for now
            if (nymInput) {
                nym.nym = nymInput;
            } else {
                nym.nym = 'Loading profile...';
            }

            document.getElementById('currentNym').textContent = nym.nym;

            // Store NSEC securely
            localStorage.setItem('nym_nsec', nsecValue);
        } else if (mode === 'bunker') {
            let bunkerUri = document.getElementById('bunkerInput').value.trim();

            if (!bunkerUri && window.tempBunkerConnection) {
                bunkerUri = window.tempBunkerConnection.uri;
            }

            if (!bunkerUri) {
                const savedBunker = localStorage.getItem('nym_bunker_uri');
                if (savedBunker) {
                    bunkerUri = savedBunker;
                }
            }

            if (!bunkerUri) {
                throw new Error('Please provide a bunker URI or complete pairing');
            }

            await nym.useNostrConnect(bunkerUri);

            const nymInput = document.getElementById('nymInput').value.trim();
            if (nymInput) {
                nym.nym = nymInput;
            } else if (!nym.nym || nym.nym === 'Loading profile...') {
                nym.nym = nym.generateRandomNym();
            }

            document.getElementById('currentNym').textContent = nym.nym;

            localStorage.setItem('nym_bunker_uri', bunkerUri);
        }

        // If nym is still not generated, generate it now
        if (!nym.nym) {
            nym.nym = nym.generateRandomNym();
            document.getElementById('currentNym').textContent = nym.nym;
        }

        // Save connection preferences
        if (mode !== 'ephemeral') {
            localStorage.setItem('nym_connection_mode', mode);
        }

        if (mode === 'extension' || mode === 'nsec') {
            if (nym.pubkey) {
                // Load cached shop items IMMEDIATELY - before any relay connection
                nym.loadCachedShopItems();
            }
        }

        // Connect to relays
        await nym.connectToRelays();

        // Fetch profile after connection for persistent modes
        if ((mode === 'extension' || mode === 'nsec' || mode === 'bunker') && nym.connected) {
            // Fetch profile if not already loaded
            if (!nym.nym || nym.nym === 'Loading profile...') {
                await nym.fetchProfileFromRelay(nym.pubkey);
            }

            // Fallback to random nym if profile wasn't found
            if (!nym.nym || nym.nym === 'Loading profile...') {
                nym.nym = nym.generateRandomNym();
                document.getElementById('currentNym').textContent = nym.nym;
            }

            // Load synced settings (give relays time to respond)
            setTimeout(() => {
                nym.loadSyncedSettings();
            }, 2000);

            // Load shop purchases from relays (this will also refresh cached items if newer data is found)
            setTimeout(async () => {
                await nym.loadUserPurchases();
            }, 2500);
        }

        // Request notification permission
        if (typeof Notification !== 'undefined' && Notification.permission === 'default') {
            Notification.requestPermission();
        }

        // Restore button state
        enterBtn.disabled = false;
        enterBtn.innerHTML = originalBtnText;

        // Close setup modal
        closeModal('setupModal');

        // Welcome messages
        const modeText = mode === 'ephemeral' ? 'ephemeral' : 'persistent Nostr';
        nym.displaySystemMessage(`Welcome to NYM, ${nym.nym}! Type /help for available commands.`);
        nym.displaySystemMessage(`Your ${modeText} identity is active${mode === 'ephemeral' ? ' for this session only' : ''}.`);
        nym.displaySystemMessage(`Click on any nym's nickname for more options.`);

        // Route to channel from URL if present
        await routeToUrlChannel();

        // Start tutorial if not seen yet
        window.maybeStartTutorial(false);

        // Start background pre-rendering of channels after a delay
        // This allows initial messages to load first
        setTimeout(() => {
            nym.queueChannelsForPrerender();
            nym.startBackgroundPrerendering();
        }, 5000);

    } catch (error) {
        // Restore button state on error
        enterBtn.disabled = false;
        enterBtn.innerHTML = originalBtnText;
        alert('Failed to initialize: ' + error.message);
    }
}


// Nostr Connect / Bunker pairing functions
async function showBunkerPairing() {
    const pairingSection = document.getElementById('bunkerPairingSection');
    const qrContainer = document.getElementById('bunkerQRCode');
    const uriDisplay = document.getElementById('bunkerUriDisplay');
    const waitingStatus = document.getElementById('bunkerWaitingStatus');

    pairingSection.style.display = 'block';
    waitingStatus.style.display = 'none';

    try {
        const tempClient = new NostrConnectClient();
        const relayUrl = 'wss://relay.nsec.app';
        const uri = await tempClient.generateBunkerUri(relayUrl);

        uriDisplay.textContent = uri;

        qrContainer.innerHTML = '';

        const qrImg = document.createElement('img');
        qrImg.src = `https://api.qrserver.com/v1/create-qr-code/?size=200x200&data=${encodeURIComponent(uri)}`;
        qrImg.style.maxWidth = '200px';
        qrContainer.appendChild(qrImg);

        window.tempBunkerConnection = {
            uri: uri,
            client: tempClient
        };

        waitingStatus.style.display = 'block';
        await tempClient.connectToRelay();


    } catch (error) {
        alert('Failed to generate pairing QR code: ' + error.message);
    }
}

function copyBunkerUri() {
    const uri = document.getElementById('bunkerUriDisplay').textContent;
    navigator.clipboard.writeText(uri);

    const display = document.getElementById('bunkerUriDisplay');
    const originalBg = display.style.backgroundColor;
    display.style.backgroundColor = 'var(--primary)';
    setTimeout(() => {
        display.style.backgroundColor = originalBg;
    }, 500);
}

async function createNewAccount(nickname) {
    // Generate keys
    await nym.generateKeypair();

    // Encode nsec for storage
    const nsecEncoded = window.NostrTools.nip19.nsecEncode(nym.privkey);

    // Store nsec
    localStorage.setItem('nym_nsec', nsecEncoded);
    localStorage.setItem('nym_connection_mode', 'nsec');

    // Set nickname
    nym.nym = nickname || nym.generateRandomNym();
    document.getElementById('currentNym').textContent = nym.nym;

    // Connect to relays first
    await nym.connectToRelays();

    // Publish kind 0 metadata event
    await nym.saveToNostrProfile();

    return nsecEncoded;
}

let currentStep = 0;
const totalSteps = 4;

function nextAccountCreationStep() {
    if (currentStep < totalSteps - 1) {
        hideStep(currentStep);
        currentStep++;
        showStep(currentStep);
        updateStepIndicator();
    }
}

function previousAccountCreationStep() {
    if (currentStep > 0) {
        hideStep(currentStep);
        currentStep--;
        showStep(currentStep);
        updateStepIndicator();
    }
}

function showStep(stepIndex) {
    document.getElementById(`step-${stepIndex}`).style.display = 'block';
}

function hideStep(stepIndex) {
    document.getElementById(`step-${stepIndex}`).style.display = 'none';
}

function updateStepIndicator() {
    for (let i = 0; i < totalSteps; i++) {
        const indicator = document.getElementById(`indicator-${i}`);
        if (i === currentStep) {
            indicator.classList.add('active');
        } else if (i < currentStep) {
            indicator.classList.add('completed');
            indicator.classList.remove('active');
        } else {
            indicator.classList.remove('active', 'completed');
        }
    }
}

async function generateAndDisplayKeys() {
    // Generate the keypair
    await nym.generateKeypair();

    // Encode keys for display
    const nsecEncoded = window.NostrTools.nip19.nsecEncode(nym.privkey);
    const npubEncoded = window.NostrTools.nip19.npubEncode(nym.pubkey);

    // Display in the UI
    document.getElementById('generated-nsec').textContent = nsecEncoded;
    document.getElementById('generated-npub').textContent = npubEncoded;

    // Store temporarily
    window.tempNsec = nsecEncoded;
}

function copyNsecToClipboard() {
    const nsec = document.getElementById('generated-nsec').textContent;
    navigator.clipboard.writeText(nsec);

    // Visual feedback
    const btn = event.target;
    const originalText = btn.textContent;
    btn.textContent = 'Copied!';
    setTimeout(() => {
        btn.textContent = originalText;
    }, 2000);
}

async function finalizeAccountCreation() {
    const nickname = document.getElementById('newAccountNym').value.trim();

    if (!nickname) {
        alert('Please enter a nickname');
        return;
    }

    try {
        // Use the stored nsec
        nym.privkey = nym.decodeNsec(window.tempNsec);
        nym.pubkey = window.NostrTools.getPublicKey(nym.privkey);
        nym.nym = nickname;
        nym.connectionMode = 'nsec';

        // Store permanently
        localStorage.setItem('nym_nsec', window.tempNsec);
        localStorage.setItem('nym_connection_mode', 'nsec');

        document.getElementById('currentNym').textContent = nym.nym;

        // Connect to relays
        await nym.connectToRelays();

        // Publish profile (kind 0 event)
        await nym.saveToNostrProfile();

        // Clear temp
        delete window.tempNsec;

        // Close modal
        closeModal('setupModal');

        // Welcome messages
        nym.displaySystemMessage(`Welcome to NYM, ${nym.nym}! Your Nostr account has been created.`);
        nym.displaySystemMessage(`Your persistent identity is now active. Make sure you've saved your private key!`);
        nym.displaySystemMessage(`Type /help for available commands.`);

        // Route to channel
        await routeToUrlChannel();

        // Start tutorial
        window.maybeStartTutorial(false);

    } catch (error) {
        alert('Failed to create account: ' + error.message);
    }
}

// Disconnect/logout function
function disconnectNym() {
    // Clear saved connection
    localStorage.removeItem('nym_connection_mode');
    localStorage.removeItem('nym_relay_url');
    localStorage.removeItem('nym_bunker_uri');

    if (nym.nostrConnect) {
        nym.nostrConnect.disconnect();
        nym.nostrConnect = null;
        nym.usingNostrConnect = false;
    }

    // Disconnect from relay
    if (nym && nym.ws) {
        nym.disconnect();
    }

    // Reload page to start fresh
    window.location.reload();
}

// Sign-out button
function signOut() {
    if (confirm('Sign out and disconnect from NYM?')) {
        // Clear auto-ephemeral preference on logout
        localStorage.removeItem('nym_auto_ephemeral');
        nym.cmdQuit();
    }
}

// Initialize on load
document.addEventListener('DOMContentLoaded', () => {
    // Parse URL for channel routing BEFORE initialization
    parseUrlChannel();

    // Check if running in NYMApp shell and hide extension option
    const isNYMApp = navigator.userAgent.includes('NYMApp');
    if (isNYMApp) {
        const connectionMode = document.getElementById('connectionMode');
        const extensionOption = connectionMode.querySelector('option[value="extension"]');
        if (extensionOption) {
            extensionOption.remove();
        }

        // If extension was the default selected, switch to ephemeral
        if (connectionMode.value === 'extension') {
            connectionMode.value = 'ephemeral';
        }
    }

    nym.initialize();

    // Pre-connect to a broadcast relay for instant connection
    async function preConnect() {
        for (const relayUrl of nym.broadcastRelays) {
            try {
                await nym.connectToRelay(relayUrl, 'broadcast');
                nym.updateConnectionStatus('Ready');
                return; // Stop after first successful connection
            } catch (err) {
            }
        }
        // If all failed, just log it - the main connection flow will try again
    }

    preConnect();

    // Auto-focus nickname input
    document.getElementById('nymInput').focus();

    // Connection mode change listener
    document.getElementById('connectionMode').addEventListener('change', (e) => {
        const mode = e.target.value;
        const nsecGroup = document.getElementById('nsecGroup');
        const nymGroup = document.getElementById('nymGroup');
        const hint = document.getElementById('nymHint');
        const nymInput = document.getElementById('nymInput');
        const nsecInput = document.getElementById('nsecInput');
        const autoEphemeralGroup = document.getElementById('autoEphemeralGroup');

        // Hide all special groups first
        nsecGroup.style.display = 'none';
        autoEphemeralGroup.style.display = 'none'; // Hide auto-ephemeral by default
        const bunkerGroup = document.getElementById('bunkerGroup');
        if (bunkerGroup) bunkerGroup.style.display = 'none';

        switch (mode) {
            case 'ephemeral':
                hint.textContent = 'Your ephemeral pseudonym for this session';
                nymInput.placeholder = 'Leave empty for random nick';
                autoEphemeralGroup.style.display = 'block'; // Show only for ephemeral
                break;
            case 'extension':
                hint.textContent = 'Will use your Nostr profile name if available';
                nymInput.placeholder = 'Override profile name (optional)';
                break;
            case 'nsec':
                nsecGroup.style.display = 'block';
                hint.textContent = 'Will use your Nostr profile name if available';
                nymInput.placeholder = 'Override profile name (optional)';

                // Auto-fill saved nsec if available
                const savedNsec = localStorage.getItem('nym_nsec');
                if (savedNsec) {
                    nsecInput.value = savedNsec;
                }
                break;
            case 'create':
                // Hide standard groups
                nsecGroup.style.display = 'none';
                nymGroup.style.display = 'none';
                autoEphemeralGroup.style.display = 'none';

                // Show account creation steps
                document.getElementById('accountCreationSteps').style.display = 'block';
                document.getElementById('enterNymBtn').style.display = 'none';

                // Reset to first step
                currentStep = 0;
                for (let i = 0; i < totalSteps; i++) {
                    hideStep(i);
                }
                showStep(0);
                updateStepIndicator();
                break;
            case 'bunker':
                nsecGroup.style.display = 'none';
                autoEphemeralGroup.style.display = 'none';
                const bunkerGroup = document.getElementById('bunkerGroup');
                if (bunkerGroup) bunkerGroup.style.display = 'block';
                hint.textContent = 'Will use your Nostr profile from the bunker';
                nymInput.placeholder = 'Override profile name (optional)';

                const savedBunker = localStorage.getItem('nym_bunker_uri');
                if (savedBunker) {
                    document.getElementById('bunkerInput').value = savedBunker;
                }
                break;

                // Reset account creation UI when switching modes
                if (mode !== 'create') {
                    document.getElementById('accountCreationSteps').style.display = 'none';
                    document.getElementById('enterNymBtn').style.display = 'block';
                }
        }
    });

    // Add listener to show/hide time format option
    document.getElementById('timestampSelect').addEventListener('change', (e) => {
        const timeFormatGroup = document.getElementById('timeFormatGroup');
        if (timeFormatGroup) {
            timeFormatGroup.style.display = e.target.value === 'true' ? 'block' : 'none';
        }
    });

    // Check if proximity sorting was enabled
    setTimeout(() => {
        if (nym.settings.sortByProximity === true) {
            navigator.geolocation.getCurrentPosition(
                (position) => {
                    nym.userLocation = {
                        lat: position.coords.latitude,
                        lng: position.coords.longitude
                    };
                    // Re-sort channels with location
                    nym.sortChannelsByActivity();
                },
                (error) => {
                    nym.settings.sortByProximity = false;
                    localStorage.setItem('nym_sort_proximity', 'false');
                }
            );
        }
    }, 1000);

    // Periodically clean up non-responsive relays
    setInterval(() => {
        if (nym.connected) {
            nym.cleanupNonResponsiveRelays();
        }
    }, 5000);

    // Periodically update connection status
    setInterval(() => {
        if (nym.connected) {
            nym.updateConnectionStatus();
        }
    }, 1000);

    // Periodic connection health check
    setInterval(() => {
        if (nym.connected || nym.relayPool.size > 0) {
            // Only log if we think we should be connected
            nym.checkConnectionHealth();
        }
    }, 1000);

    // Check for saved connection AFTER initialization is complete
    setTimeout(() => {
        checkSavedConnection();
    }, 100);

    // Periodically update user list
    setInterval(() => {
        if (nym.connected) {
            nym.updateUserList();
        }
    }, 5000);

    // Override the existing search functions to handle collapsed lists properly
    const originalHandleChannelSearch = nym.handleChannelSearch;
    nym.handleChannelSearch = function (searchTerm) {
        // First expand the list to make all items searchable
        const channelList = document.getElementById('channelList');
        const wasCollapsed = channelList.classList.contains('list-collapsed');

        if (wasCollapsed && searchTerm.length > 0) {
            channelList.classList.remove('list-collapsed');
            channelList.classList.add('list-expanded');
        }

        // Call original search function
        originalHandleChannelSearch.call(this, searchTerm);

        // Restore collapsed state if search is cleared
        if (wasCollapsed && searchTerm.length === 0) {
            channelList.classList.add('list-collapsed');
            channelList.classList.remove('list-expanded');
        }
    };

    const originalFilterPMs = nym.filterPMs;
    nym.filterPMs = function (searchTerm) {
        // First expand the list to make all items searchable
        const pmList = document.getElementById('pmList');
        const wasCollapsed = pmList.classList.contains('list-collapsed');

        if (wasCollapsed && searchTerm.length > 0) {
            pmList.classList.remove('list-collapsed');
            pmList.classList.add('list-expanded');
        }

        // Call original filter function
        originalFilterPMs.call(this, searchTerm);

        // Restore collapsed state if search is cleared
        if (wasCollapsed && searchTerm.length === 0) {
            pmList.classList.add('list-collapsed');
            pmList.classList.remove('list-expanded');
        }
    };

    const originalFilterUsers = nym.filterUsers;
    nym.filterUsers = function (searchTerm) {
        // First expand the list to make all items searchable
        const userList = document.getElementById('userListContent');
        const wasCollapsed = userList.classList.contains('list-collapsed');

        if (wasCollapsed && searchTerm.length > 0) {
            userList.classList.remove('list-collapsed');
            userList.classList.add('list-expanded');
        }

        // Call original filter function
        originalFilterUsers.call(this, searchTerm);

        // Restore collapsed state if search is cleared
        if (wasCollapsed && searchTerm.length === 0) {
            userList.classList.add('list-collapsed');
            userList.classList.remove('list-expanded');
        }
    };

    // Background message cleanup
    setInterval(() => {
        // Clean up stored messages for inactive channels
        const currentKey = nym.currentGeohash ? `#${nym.currentGeohash}` : nym.currentChannel;

        nym.messages.forEach((messages, channel) => {
            // Skip current channel
            if (channel === currentKey) return;

            // Prune inactive channels to 500 messages max
            if (messages.length > 500) {
                nym.messages.set(channel, messages.slice(-500));
            }
        });

        // Prune event deduplication if too large (keep recent entries for proper deduplication)
        if (nym.eventDeduplication.size > 10000) {
            const entriesToDelete = nym.eventDeduplication.size - 7500;
            let deleted = 0;
            for (const key of nym.eventDeduplication.keys()) {
                if (deleted >= entriesToDelete) break;
                nym.eventDeduplication.delete(key);
                deleted++;
            }
        }
    }, 60000);

    // Periodically check and clear expired blacklists
    setInterval(() => {
        if (nym.connected) {
            // Check all blacklisted relays for expiration
            const expiredRelays = [];
            nym.blacklistedRelays.forEach(relayUrl => {
                if (nym.isBlacklistExpired(relayUrl)) {
                    expiredRelays.push(relayUrl);
                }
            });

            // Try to reconnect to expired blacklisted relays
            expiredRelays.forEach(relayUrl => {
                if (nym.broadcastRelays.includes(relayUrl) && !nym.relayPool.has(relayUrl)) {
                    nym.connectToRelay(relayUrl, 'broadcast')
                        .then(() => {
                            nym.subscribeToSingleRelay(relayUrl);
                            nym.updateConnectionStatus();
                        })
                        .catch(err => {
                            nym.trackRelayFailure(relayUrl);
                        });
                }
            });
        }
    }, 60000); // Check every minute

    // Auto-scroll to bottom when input is focused on mobile
    const messageInput = document.getElementById('messageInput');
    const messagesContainer = document.getElementById('messagesContainer');

    if (messageInput && messagesContainer) {
        messageInput.addEventListener('focus', function () {
            if (window.innerWidth <= 768) {
                setTimeout(() => {
                    messagesContainer.scrollTop = messagesContainer.scrollHeight;
                }, 300);
            }
        });
    }
});

// Parse URL for channel routing
function parseUrlChannel() {
    const hash = window.location.hash;
    if (hash && hash.length > 1) {
        const channelFromUrl = hash.substring(1).toLowerCase();

        // Store for use after initialization
        window.pendingChannel = channelFromUrl;
    }
}

// Handle channel routing after initialization
async function routeToUrlChannel() {
    if (window.pendingChannel) {
        const channelInput = window.pendingChannel;
        delete window.pendingChannel;

        // Small delay for persistent connections to ensure relays are ready
        if (nym.connectionMode !== 'ephemeral') {
            await new Promise(resolve => setTimeout(resolve, 2000));
        }

        // Parse channel type from prefix
        let channelType = 'auto'; // auto-detect if no prefix
        let channelName = channelInput;

        if (channelInput.startsWith('c:')) {
            channelType = 'community';
            channelName = channelInput.substring(2);
        } else if (channelInput.startsWith('g:')) {
            channelType = 'geohash';
            channelName = channelInput.substring(2);
        } else if (channelInput.startsWith('e:')) {
            channelType = 'ephemeral';
            channelName = channelInput.substring(2);
        }

        // Handle based on type
        if (channelType === 'community') {
            // Handle community routing
            const communityId = channelName;

            // Function to check for community
            const checkForCommunity = () => {
                if (nym.communityChannels.has(communityId)) {
                    const community = nym.communityChannels.get(communityId);

                    if (nym.connectionMode === 'ephemeral') {
                        nym.displaySystemMessage(`Community "${community.name}" requires a persistent identity (extension or nsec login)`);
                        return false;
                    }

                    if (!document.querySelector(`[data-community="${communityId}"]`)) {
                        nym.addCommunityChannel(community.name, communityId, community.isPrivate);
                    }

                    nym.switchToCommunity(communityId);
                    nym.userJoinedChannels.add(communityId);
                    nym.saveUserChannels();
                    nym.displaySystemMessage(`Joined community #${community.name} from URL`);
                    return true;
                }
                return false;
            };

            // Try to find community immediately
            let foundCommunity = checkForCommunity();

            // If not found and user is persistent, wait for discovery
            if (!foundCommunity && nym.connectionMode !== 'ephemeral') {
                nym.displaySystemMessage(`Looking for community...`);

                // Wait up to 5 seconds for community to be discovered
                for (let i = 0; i < 10; i++) {
                    await new Promise(resolve => setTimeout(resolve, 500));
                    foundCommunity = checkForCommunity();
                    if (foundCommunity) break;
                }

                if (!foundCommunity) {
                    nym.displaySystemMessage(`Community not found. It may be private or no longer exist.`);
                }
            }
        } else if (channelType === 'geohash' || (channelType === 'auto' && nym.isValidGeohash(channelName))) {
            // Geohash channel
            nym.addChannel(channelName, channelName);
            nym.switchChannel(channelName, channelName);
            nym.userJoinedChannels.add(channelName);
            nym.saveUserChannels();
            nym.displaySystemMessage(`Joined geohash channel #${channelName} from URL`);
        } else {
            // Standard ephemeral channel
            nym.addChannel(channelName, '');
            nym.switchChannel(channelName, '');
            await nym.createChannel(channelName);
            nym.userJoinedChannels.add(channelName);
            nym.saveUserChannels();
            nym.displaySystemMessage(`Joined channel #${channelName} from URL`);
        }

        // Clear the URL hash to clean up
        history.replaceState(null, null, window.location.pathname);
    }
}