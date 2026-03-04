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
                title: 'Nymchat Tutorial',
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
                body: 'Get flair addon packs to change the styling of your messages and nickname. Edit settings such as sorting geohash channels by proximity, adding a Bitcoin lightning address, changing the app\'s theme, manage blocked users and keywords, and more. Logout to terminate session and start anew.',
                selector: (window.innerWidth > 768 ? '.header-actions' : '.sidebar-actions'),
                onBefore: () => { if (window.innerWidth <= 768) return ensureSidebarOpenOnMobile(); }
            },
            {
                title: 'Channels',
                body: 'Browse and switch geohash channels. Use the search feature to find and join geohash channels.',
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
                body: 'That\'s it. Enjoy Nymchat! Check out all of the available commands by typing the /help command in any channel.',
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
            state.elTitle.textContent = step.title || 'Nymchat';
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
        this.defaultRelays = this.broadcastRelays.slice(0, 5);
        // Bitchat app's hardcoded DM relays - always ensure these are connected
        // and used for DM EVENT/REQ to guarantee cross-app PM delivery
        this.bitchatDMRelays = [
            'wss://relay.damus.io',
            'wss://nos.lol',
            'wss://relay.primal.net',
            'wss://offchain.pub',
            'wss://nostr21.com'
        ];
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
        this.pendingSettingsTransfers = [];
        this.dismissedTransferEvents = new Set(JSON.parse(localStorage.getItem('nym_dismissed_transfers') || '[]'));
        this.powDifficulty = 12;
        this.enablePow = false;
        this.connectionMode = 'ephemeral';
        this.currentChannel = 'nym';
        this.currentGeohash = '';
        this.currentPM = null;
        this.messages = new Map();
        this.channelDOMCache = new Map();
        this.virtualScroll = {
            windowSize: 100,
            currentStartIndex: 0,
            currentEndIndex: 0,
            suppressAutoScroll: false
        };
        this._suppressInputButtonHide = false;
        this.userScrolledUp = false;
        this._scrollRAF = null;
        this.pmMessages = new Map();
        this.processedPMEventIds = new Set();
        this.pendingDMs = new Map();
        this.dmRetryInterval = null;
        this.dmRetryCheckMs = 5000;
        this.dmRetryMaxAttempts = 3;
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
        this.discoveredGeohashes = new Set();
        this.channelSubscriptions = new Map();
        this.channelLoadedFromRelays = new Set();
        this.channelSubscriptionBatchSize = 10;
        this.channelMessageLimit = 100;
        this.settings = this.loadSettings();
        this.pinnedLandingChannel = this.settings.pinnedLandingChannel || { type: 'geohash', geohash: 'nym' };
        if (this.pinnedLandingChannel.type === 'geohash' && this.pinnedLandingChannel.geohash) {
            this.currentChannel = this.pinnedLandingChannel.geohash;
            this.currentGeohash = this.pinnedLandingChannel.geohash;
        } else {
            this.currentChannel = 'nym';
            this.currentGeohash = 'nym';
        }
        this.commandHistory = [];
        this.historyIndex = -1;
        this.connected = false;
        this.initialConnectionInProgress = false;
        this.messageQueue = [];
        this.autocompleteIndex = -1;
        this.commandPaletteIndex = -1;
        this.gifPicker = null;
        this.gifSearchTimeout = null;
        this.giphyApiKey = 'G6neFEExTMBM0h3hM2QjQg4vG8jMMLa9';
        this.emojiAutocompleteIndex = -1;
        this.commonGeohashes = ['nym', '9q', 'w2', 'dr5r', '9q8y', 'u4pr', 'gcpv', 'f2m6', 'xn77', 'tjm5'];
        this.userJoinedChannels = new Set(this.loadUserJoinedChannels());
        this.inPMMode = false;
        this.userSearchTerm = '';
        this.geohashRegex = /^[0-9bcdefghjkmnpqrstuvwxyz]{1,12}$/;
        this.pinnedChannels = new Set();
        this.hiddenChannels = new Set();
        this.hideNonPinned = false;
        this.reactions = new Map();
        this.failedRelays = new Map();
        this.relayRetryDelay = 2 * 60 * 1000;
        this.previouslyConnectedRelays = new Set();
        this.floodTracking = new Map();
        this.activeReactionPicker = null;
        this.activeReactionPickerButton = null;
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
            { urls: 'stun:stun.l.google.com:19302' },
            { urls: 'stun:stun1.l.google.com:19302' },
            { urls: 'stun:stun2.l.google.com:19302' },
            { urls: 'stun:stun.cloudflare.com:3478' }
        ];
        this.P2P_SIGNALING_KIND = 25051;
        this.P2P_FILE_STATUS_KIND = 25052;
        this.PRESENCE_KIND = 20001;
        this.P2P_CHUNK_SIZE = 16384;
        this.p2pUnseededOffers = new Set();
        this.torrentClient = null;
        this.torrentSeeds = new Map();
        this.awayMessages = new Map();
        this.recentEmojis = [];
        this.allEmojis = {
            'smileys': ['😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂', '🙂', '🙃', '😉', '😊', '😇', '🥰', '😍', '🤩', '😘', '😗', '☺️', '😚', '😙', '🥲', '😋', '😛', '😜', '🤪', '😝', '🤑', '🤗', '🤭', '🫢', '🫣', '🤫', '🤔', '🫡', '🤐', '🤨', '😐', '😑', '😶', '🫥', '😏', '😒', '🙄', '😬', '🤥', '😌', '😔', '😪', '🤤', '😴', '😷', '🤒', '🤕', '🤢', '🤮', '🤧', '🥵', '🥶', '🥴', '😵', '😵‍💫', '🤯', '🤠', '🥳', '🥸', '😎', '🤓', '🧐', '😕', '🫤', '😟', '☹️', '🙁', '😮', '😯', '😲', '😳', '🥺', '🥹', '😦', '😧', '😨', '😰', '😥', '😢', '😭', '😱', '😖', '😣', '😞', '😓', '😩', '😫', '🥱', '😤', '😡', '😠', '🤬', '😈', '👿', '💀', '☠️', '💩', '🤡', '👹', '👺', '👻', '👽', '👾', '🤖', '🎃', '😺', '😸', '😹', '😻', '😼', '😽', '🙀', '😿', '😾'],
            'people': ['👶', '🧒', '👦', '👧', '🧑', '👱', '👨', '🧔', '👩', '🧓', '👴', '👵', '🙍', '🙎', '🙅', '🙆', '💁', '🙋', '🧏', '🙇', '🤦', '🤷', '👮', '🕵️', '💂', '🥷', '👷', '🫅', '🤴', '👸', '👳', '👲', '🧕', '🤵', '👰', '🤰', '🫃', '🫄', '🤱', '👼', '🎅', '🤶', '🦸', '🦹', '🧙', '🧚', '🧛', '🧜', '🧝', '🧞', '🧟', '🧌', '💆', '💇', '🚶', '🧍', '🧎', '🏃', '💃', '🕺', '🕴️', '👯', '🧖', '🧗', '🤸', '🏌️', '🏇', '⛷️', '🏂', '🏋️', '🤼', '🤽', '🤾', '🤺', '⛹️', '🧘', '🛀', '🛌', '👭', '👫', '👬', '💏', '💑', '👪', '👨‍👩‍👦', '👨‍👩‍👧', '👨‍👩‍👧‍👦', '👨‍👩‍👦‍👦', '👨‍👩‍👧‍👧', '🗣️', '👤', '👥', '🫂'],
            'gestures': ['👍', '👎', '👌', '🤌', '🤏', '✌️', '🤞', '🫰', '🤟', '🤘', '🤙', '👈', '👉', '👆', '🖕', '👇', '☝️', '🫵', '👋', '🤚', '🖐️', '✋', '🖖', '🫱', '🫲', '🫳', '🫴', '👏', '🙌', '🫶', '👐', '🤲', '🤝', '🙏', '✍️', '💅', '🤳', '💪', '🦾', '🦿', '🦵', '🦶', '👂', '🦻', '👃', '🧠', '🫀', '🫁', '🦷', '🦴', '👀', '👁️', '👅', '👄', '🫦', '💋'],
            'hearts': ['❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '🤎', '❤️‍🔥', '❤️‍🩹', '💔', '❣️', '💕', '💞', '💓', '💗', '💖', '💘', '💝', '💟', '♥️'],
            'symbols': ['💯', '💢', '💥', '💫', '💦', '💨', '🕳️', '💣', '💬', '👁️‍🗨️', '🗨️', '🗯️', '💭', '💤', '✨', '🌟', '💫', '⭐', '🌠', '🔥', '☄️', '🎆', '🎇', '🎈', '🎉', '🎊', '🎋', '🎍', '🎎', '🎏', '🎐', '🎑', '🧧', '🎀', '🎁', '🎗️', '🎟️', '🎫', '🔮', '🧿', '🪬', '🎮', '🕹️', '🎰', '🎲', '♟️', '🧩', '🧸', '🪅', '🪩', '🪆', '♠️', '♥️', '♦️', '♣️', '🀄', '🃏', '🔇', '🔈', '🔉', '🔊', '📢', '📣', '📯', '🔔', '🔕', '🎵', '🎶', '🎼', '☮️', '✝️', '☪️', '🕉️', '☸️', '✡️', '🔯', '🕎', '☯️', '☦️', '🛐', '⛎', '♈', '♉', '♊', '♋', '♌', '♍', '♎', '♏', '♐', '♑', '♒', '♓', '🆔', '⚛️', '🉑', '☢️', '☣️', '📴', '📳', '🈶', '🈚', '🈸', '🈺', '🈷️', '✴️', '🆚', '💮', '🉐', '㊙️', '㊗️', '🈴', '🈵', '🈹', '🈲', '🅰️', '🅱️', '🆎', '🆑', '🅾️', '🆘', '❌', '⭕', '🛑', '⛔', '📛', '🚫', '💯', '💢', '♨️', '🚷', '🚯', '🚳', '🚱', '🔞', '📵', '🚭', '❗', '❕', '❓', '❔', '‼️', '⁉️', '🔅', '🔆', '〽️', '⚠️', '🚸', '🔱', '⚜️', '🔰', '♻️', '✅', '🈯', '💹', '❇️', '✳️', '❎', '🌐', '💠', 'Ⓜ️', '🌀', '💤', '🏧', '🚾', '♿', '🅿️', '🛗', '🈳', '🈂️', '🛂', '🛃', '🛄', '🛅', '🚹', '🚺', '🚼', '⚧️', '🚻', '🚮', '🎦', '📶', '🈁', '🔣', 'ℹ️', '🔤', '🔡', '🔠', '🆖', '🆗', '🆙', '🆒', '🆕', '🆓', '0️⃣', '1️⃣', '2️⃣', '3️⃣', '4️⃣', '5️⃣', '6️⃣', '7️⃣', '8️⃣', '9️⃣', '🔟', '🔢', '#️⃣', '*️⃣', '⏏️', '▶️', '⏸️', '⏯️', '⏹️', '⏺️', '⏭️', '⏮️', '⏩', '⏪', '⏫', '⏬', '◀️', '🔼', '🔽', '➡️', '⬅️', '⬆️', '⬇️', '↗️', '↘️', '↙️', '↖️', '↕️', '↔️', '↩️', '↪️', '⤴️', '⤵️', '🔀', '🔁', '🔂', '🔄', '🔃', '➕', '➖', '➗', '✖️', '🟰', '♾️', '💲', '💱', '™️', '©️', '®️', '〰️', '➰', '➿', '🔚', '🔙', '🔛', '🔝', '🔜', '✔️', '☑️', '🔘', '🔴', '🟠', '🟡', '🟢', '🔵', '🟣', '⚫', '⚪', '🟤', '🔺', '🔻', '🔸', '🔹', '🔶', '🔷', '🔳', '🔲', '▪️', '▫️', '◾', '◽', '◼️', '◻️', '🟥', '🟧', '🟨', '🟩', '🟦', '🟪', '⬛', '⬜', '🟫', '🔈', '🔉', '🔊', '🔇', '📣', '📢', '🔔', '🔕', '🃏', '🀄', '🎴', '🔁', '🔂', '🔀'],
            'objects': ['⌚', '📱', '📲', '💻', '⌨️', '🖥️', '🖨️', '🖱️', '🖲️', '🕹️', '🗜️', '💽', '💾', '💿', '📀', '📼', '📷', '📸', '📹', '🎥', '📽️', '🎞️', '📞', '☎️', '📟', '📠', '📺', '📻', '🎙️', '🎚️', '🎛️', '⏱️', '⏲️', '⏰', '🕰️', '⌛', '⏳', '📡', '🔋', '🪫', '🔌', '💡', '🔦', '🕯️', '🪔', '🧯', '🛢️', '💸', '💵', '💴', '💶', '💷', '🪙', '💰', '💳', '🪪', '🧾', '💎', '⚖️', '🪜', '🧰', '🪛', '🔧', '🔨', '⚒️', '🛠️', '⛏️', '🪚', '🔩', '⚙️', '🪤', '⛓️', '🧲', '🔫', '💣', '🧨', '🪓', '🔪', '🗡️', '⚔️', '🛡️', '🚬', '⚰️', '🪦', '⚱️', '🏺', '🔮', '📿', '🧿', '🪬', '💈', '⚗️', '🔭', '🔬', '🕳️', '🩻', '🩹', '🩺', '💊', '💉', '🩸', '🌡️', '🧬', '🦠', '🧫', '🧪', '🏷️', '🔖', '🚽', '🪠', '🚿', '🛁', '🛀', '🪥', '🪒', '🧻', '🧼', '🫧', '🪣', '🧽', '🧴', '🛏️', '🛋️', '🪑', '🚪', '🪞', '🪟', '🧹', '🧺', '🧯', '🛒', '🚬', '⚰️', '⚱️', '🗿', '🪧', '🪪'],
            'clothing': ['👓', '🕶️', '🥽', '🥼', '🦺', '👔', '👕', '👖', '🧣', '🧤', '🧥', '🧦', '👗', '👘', '🥻', '🩱', '🩲', '🩳', '👙', '👚', '👛', '👜', '👝', '🛍️', '🎒', '🩴', '👞', '👟', '🥾', '🥿', '👠', '👡', '🩰', '👢', '👑', '👒', '🎩', '🎓', '🧢', '🪖', '⛑️', '📿', '💄', '💍', '💎', '🪭', '🪮'],
            'nature': ['🐵', '🐒', '🦍', '🦧', '🐶', '🐕', '🦮', '🐕‍🦺', '🐩', '🐺', '🦊', '🦝', '🐱', '🐈', '🐈‍⬛', '🦁', '🐯', '🐅', '🐆', '🐴', '🐎', '🦄', '🦓', '🦌', '🫎', '🦬', '🐮', '🐂', '🐃', '🐄', '🐷', '🐖', '🐗', '🐽', '🐏', '🐑', '🐐', '🐪', '🐫', '🦙', '🦒', '🐘', '🦣', '🦏', '🦛', '🐭', '🐁', '🐀', '🐹', '🐰', '🐇', '🐿️', '🦫', '🦔', '🦇', '🐻', '🐻‍❄️', '🐨', '🐼', '🦥', '🦦', '🦨', '🦘', '🦡', '🐾', '🦃', '🐔', '🐓', '🐣', '🐤', '🐥', '🐦', '🐧', '🕊️', '🦅', '🦆', '🦢', '🦉', '🦤', '🪶', '🦩', '🦚', '🦜', '🪽', '🐦‍⬛', '🪿', '🐸', '🐊', '🐢', '🦎', '🐍', '🐲', '🐉', '🦕', '🦖', '🐳', '🐋', '🐬', '🦭', '🐟', '🐠', '🐡', '🦈', '🐙', '🐚', '🪸', '🪼', '🐌', '🦋', '🐛', '🐜', '🐝', '🪲', '🐞', '🦗', '🪳', '🕷️', '🕸️', '🦂', '🦟', '🪰', '🪱', '🦠', '💐', '🌸', '💮', '🏵️', '🌹', '🥀', '🌺', '🌻', '🌼', '🌷', '🪷', '🌱', '🪴', '🌲', '🌳', '🌴', '🌵', '🌾', '🌿', '☘️', '🍀', '🍁', '🍂', '🍃', '🪹', '🪺', '🍄', '🪨', '🪵'],
            'food': ['🍏', '🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🫐', '🍈', '🍒', '🍑', '🥭', '🍍', '🥥', '🥝', '🍅', '🍆', '🥑', '🥦', '🥬', '🥒', '🌶️', '🫑', '🌽', '🥕', '🧄', '🧅', '🥔', '🍠', '🫘', '🥐', '🥯', '🍞', '🫓', '🥖', '🥨', '🧀', '🥚', '🍳', '🧈', '🥞', '🧇', '🥓', '🥩', '🍗', '🍖', '🦴', '🌭', '🍔', '🍟', '🍕', '🫔', '🥪', '🥙', '🧆', '🌮', '🌯', '🫕', '🥗', '🥘', '🫙', '🥫', '🍝', '🍜', '🍲', '🍛', '🍣', '🍱', '🥟', '🦪', '🍤', '🍙', '🍚', '🍘', '🍥', '🥠', '🥮', '🍢', '🍡', '🍧', '🍨', '🍦', '🥧', '🧁', '🍰', '🎂', '🍮', '🍭', '🍬', '🍫', '🍿', '🍩', '🍪', '🌰', '🥜', '🍯', '🥛', '🍼', '🫗', '☕', '🫖', '🍵', '🧃', '🥤', '🧋', '🍶', '🍺', '🍻', '🥂', '🍷', '🥃', '🍸', '🍹', '🧉', '🍾', '🧊', '🥄', '🍴', '🍽️', '🥣', '🥡', '🥢', '🫙'],
            'activities': ['⚽', '🏀', '🏈', '⚾', '🥎', '🎾', '🏐', '🏉', '🥏', '🎱', '🪀', '🏓', '🏸', '🏒', '🏑', '🥍', '🏏', '🪃', '🥅', '⛳', '🪁', '🏹', '🎣', '🤿', '🥊', '🥋', '🎽', '🛹', '🛼', '🛷', '⛸️', '🥌', '🎿', '⛷️', '🏂', '🪂', '🏋️', '🤼', '🤸', '🤺', '🤾', '🏌️', '🏇', '🧘', '🏄', '🏊', '🤽', '🚣', '🧗', '🚴', '🚵', '🎪', '🎭', '🎨', '🎬', '🎤', '🎧', '🎼', '🎹', '🥁', '🪘', '🎷', '🎺', '🪗', '🎸', '🪕', '🎻', '🪈', '🎲', '🎯', '🎳', '🎰', '🧩'],
            'travel': ['🚗', '🚕', '🚙', '🚌', '🚎', '🏎️', '🚓', '🚑', '🚒', '🚐', '🛻', '🚚', '🚛', '🚜', '🦯', '🦽', '🦼', '🛴', '🚲', '🛵', '🏍️', '🛺', '🛞', '🚨', '🚔', '🚍', '🚘', '🚖', '🛞', '🚡', '🚠', '🚟', '🚃', '🚋', '🚞', '🚝', '🚄', '🚅', '🚈', '🚂', '🚆', '🚇', '🚊', '🚉', '✈️', '🛫', '🛬', '🛩️', '💺', '🛰️', '🚀', '🛸', '🚁', '🛶', '⛵', '🚤', '🛥️', '🛳️', '⛴️', '🚢', '⚓', '🪝', '⛽', '🚧', '🚦', '🚥', '🚏', '🗺️', '🗿', '🗽', '🗼', '🏰', '🏯', '🏟️', '🎡', '🎢', '🎠', '⛲', '⛱️', '🏖️', '🏝️', '🏜️', '🌋', '⛰️', '🏔️', '🗻', '🏕️', '🛖', '🏠', '🏡', '🏘️', '🏚️', '🏗️', '🏭', '🏢', '🏬', '🏣', '🏤', '🏥', '🏦', '🏨', '🏪', '🏫', '🏩', '💒', '🏛️', '⛪', '🕌', '🕍', '🛕', '🕋', '⛩️', '🛤️', '🛣️', '🗾', '🎑', '🏞️', '🌅', '🌄', '🌠', '🎇', '🎆', '🌇', '🌆', '🏙️', '🌃', '🌌', '🌉', '🌁'],
            'weather': ['☀️', '🌤️', '⛅', '🌥️', '☁️', '🌦️', '🌧️', '⛈️', '🌩️', '🌨️', '❄️', '☃️', '⛄', '🌬️', '💨', '🌪️', '🌫️', '🌈', '☔', '💧', '🌊', '🔥', '🌙', '🌛', '🌜', '🌚', '🌕', '🌖', '🌗', '🌘', '🌑', '🌒', '🌓', '🌔', '🌍', '🌎', '🌏', '🪐', '⭐', '🌟', '✨', '💫', '☄️'],
            'flags': ['🏳️', '🏴', '🏁', '🚩', '🏳️‍🌈', '🏳️‍⚧️', '🏴‍☠️', '🇺🇸', '🇬🇧', '🇨🇦', '🇦🇺', '🇩🇪', '🇫🇷', '🇯🇵', '🇰🇷', '🇨🇳', '🇮🇳', '🇧🇷', '🇲🇽', '🇪🇸', '🇮🇹', '🇷🇺', '🇸🇪', '🇳🇴', '🇩🇰', '🇫🇮', '🇳🇱', '🇧🇪', '🇦🇹', '🇨🇭', '🇵🇱', '🇺🇦', '🇹🇷', '🇬🇷', '🇵🇹', '🇮🇪', '🇿🇦', '🇳🇬', '🇪🇬', '🇰🇪', '🇦🇷', '🇨🇱', '🇨🇴', '🇵🇪', '🇻🇪', '🇹🇭', '🇻🇳', '🇮🇩', '🇵🇭', '🇲🇾', '🇸🇬', '🇳🇿', '🇸🇦', '🇦🇪', '🇮🇱', '🇵🇰', '🇧🇩', '🇭🇰', '🇹🇼', '🇨🇿', '🇭🇺', '🇷🇴', '🇭🇷', '🇷🇸', '🇧🇬', '🇸🇰', '🇸🇮', '🇱🇹', '🇱🇻', '🇪🇪', '🇮🇸', '🇱🇺', '🇲🇹', '🇨🇾', '🇯🇲', '🇹🇹', '🇧🇸', '🇧🇧', '🇵🇷', '🇨🇺', '🇩🇴', '🇭🇹', '🇵🇦', '🇨🇷', '🇬🇹', '🇭🇳', '🇸🇻', '🇳🇮', '🇧🇴', '🇪🇨', '🇺🇾', '🇵🇾', '🇬🇾']
        };
        this.emojiMap = {
            // Smileys & faces
            'grinning': '😀', 'smiley': '😃', 'grin': '😄', 'beaming': '😁', 'laughing': '😆',
            'sweat_smile': '😅', 'rofl': '🤣', 'laugh': '😂', 'slightly_smiling': '🙂', 'upside_down': '🙃',
            'wink': '😉', 'smile': '😊', 'innocent': '😇', 'heart_eyes': '🥰', 'love': '😍',
            'star_struck': '🤩', 'kiss': '😘', 'kissing': '😗', 'relaxed': '☺️', 'kissing_closed': '😚',
            'kissing_smiling': '😙', 'holding_tears': '🥲', 'yum': '😋', 'stuck_out': '😛', 'stuck_out_wink': '😜',
            'zany': '🤪', 'stuck_out_closed': '😝', 'money_face': '🤑', 'hug': '🤗', 'shush': '🤭',
            'peeking': '🫣', 'quiet': '🤫', 'thinking': '🤔', 'salute': '🫡', 'zipper': '🤐',
            'raised_eyebrow': '🤨', 'neutral': '😐', 'expressionless': '😑', 'no_mouth': '😶', 'dotted_face': '🫥',
            'smirk': '😏', 'unamused': '😒', 'eye_roll': '🙄', 'grimace': '😬', 'lying': '🤥',
            'relieved': '😌', 'pensive': '😔', 'sleepy': '😪', 'drool': '🤤', 'sleeping': '😴',
            'mask': '😷', 'thermometer': '🤒', 'bandage': '🤕', 'sick': '🤢', 'vomit': '🤮',
            'sneeze': '🤧', 'hot': '🥵', 'cold': '🥶', 'woozy': '🥴', 'dizzy': '😵',
            'spiral_eyes': '😵‍💫', 'mind_blown': '🤯', 'cowboy': '🤠', 'partying': '🥳', 'disguise': '🥸',
            'cool': '😎', 'nerd': '🤓', 'monocle': '🧐', 'confused': '😕', 'diagonal_mouth': '🫤',
            'worried': '😟', 'frowning': '☹️', 'slightly_frowning': '🙁', 'shocked': '😮', 'surprised': '😯',
            'astonished': '😲', 'flushed': '😳', 'pleading': '🥺', 'face_holding_tears': '🥹', 'anguished': '😧',
            'fearful': '😨', 'anxious': '😰', 'sad': '😥', 'cry': '😢', 'sob': '😭',
            'scream': '😱', 'confounded': '😖', 'persevere': '😣', 'disappointed': '😞', 'sweat': '😓',
            'weary': '😩', 'tired': '😫', 'yawn': '🥱', 'triumph': '😤', 'pouting': '😡',
            'angry': '😠', 'rage': '🤬', 'devil': '😈', 'imp': '👿', 'skull': '💀',
            'skull_crossbones': '☠️', 'poop': '💩', 'clown': '🤡', 'ogre': '👹', 'goblin': '👺',
            'ghost': '👻', 'alien': '👽', 'space_invader': '👾', 'robot': '🤖', 'jack': '🎃',
            'cat_smile': '😺', 'cat_grin': '😸', 'cat_joy': '😹', 'cat_love': '😻', 'cat_smirk': '😼',
            'cat_kiss': '😽', 'cat_scream': '🙀', 'cat_cry': '😿', 'cat_angry': '😾',
            // People
            'baby': '👶', 'child': '🧒', 'boy': '👦', 'girl': '👧', 'person': '🧑',
            'blond': '👱', 'man': '👨', 'bearded': '🧔', 'woman': '👩', 'older_person': '🧓',
            'old_man': '👴', 'old_woman': '👵', 'frowning_person': '🙍', 'pouting_person': '🙎', 'no_good': '🙅',
            'ok_person': '🙆', 'tipping': '💁', 'raising_hand': '🙋', 'deaf_person': '🧏', 'bowing': '🙇',
            'facepalm': '🤦', 'shrug': '🤷', 'police_officer': '👮', 'detective': '🕵️', 'guard': '💂',
            'ninja': '🥷', 'construction': '👷', 'royalty': '🫅', 'prince': '🤴', 'princess': '👸',
            'turban': '👳', 'skullcap': '👲', 'headscarf': '🧕', 'tuxedo': '🤵', 'bride': '👰',
            'pregnant': '🤰', 'pregnant_man': '🫃', 'pregnant_person': '🫄', 'breast_feeding': '🤱', 'angel': '👼',
            'santa': '🎅', 'mrs_claus': '🤶', 'superhero': '🦸', 'supervillain': '🦹', 'mage': '🧙',
            'fairy': '🧚', 'vampire': '🧛', 'merperson': '🧜', 'elf': '🧝', 'genie': '🧞',
            'zombie': '🧟', 'troll': '🧌', 'massage': '💆', 'haircut': '💇', 'walking': '🚶',
            'standing': '🧍', 'kneeling': '🧎', 'running': '🏃', 'dancer': '💃', 'man_dancing': '🕺',
            'levitate': '🕴️', 'people_dancing': '👯', 'sauna': '🧖', 'climbing': '🧗', 'cartwheeling': '🤸',
            'golfer': '🏌️', 'horse_racing': '🏇', 'skier': '⛷️', 'snowboarder': '🏂', 'weight_lifter': '🏋️',
            'wrestlers': '🤼', 'water_polo': '🤽', 'handball': '🤾', 'fencer': '🤺', 'basketball_player': '⛹️',
            'meditating': '🧘', 'bath': '🛀', 'sleeping_person': '🛌', 'women_holding_hands': '👭', 'couple': '👫',
            'men_holding_hands': '👬', 'kiss_couple': '💏', 'couple_heart': '💑', 'family': '👪',
            'speaking_head': '🗣️', 'silhouette': '👤', 'silhouettes': '👥', 'people_hugging': '🫂',
            // Gestures & body
            'thumbsup': '👍', 'thumbsdown': '👎', 'ok_hand': '👌', 'pinched': '🤌', 'pinch': '🤏',
            'peace': '✌️', 'crossed': '🤞', 'hand_with_fingers': '🫰', 'rock': '🤟', 'metal': '🤘',
            'call': '🤙', 'left': '👈', 'right': '👉', 'up': '👆', 'middle_finger': '🖕',
            'down': '👇', 'point': '☝️', 'point_at_you': '🫵', 'wave': '👋', 'backhand': '🤚',
            'fingers_splayed': '🖐️', 'hand': '✋', 'vulcan': '🖖', 'rightward_hand': '🫱', 'leftward_hand': '🫲',
            'palm_down': '🫳', 'palm_up': '🫴', 'clap': '👏', 'raised': '🙌', 'heart_hands': '🫶',
            'open': '👐', 'palms': '🤲', 'handshake': '🤝', 'pray': '🙏', 'writing': '✍️',
            'nail_polish': '💅', 'selfie': '🤳', 'muscle': '💪', 'mechanical_arm': '🦾', 'mechanical_leg': '🦿',
            'leg': '🦵', 'foot': '🦶', 'ear': '👂', 'hearing_aid': '🦻', 'nose': '👃',
            'brain': '🧠', 'anatomical_heart': '🫀', 'lungs': '🫁', 'tooth': '🦷', 'bone': '🦴',
            'eyes': '👀', 'eye': '👁️', 'tongue': '👅', 'lips': '👄', 'biting_lip': '🫦', 'kiss_mark': '💋',
            // Hearts
            'heart': '❤️', 'orange_heart': '🧡', 'yellow_heart': '💛', 'green_heart': '💚',
            'blue_heart': '💙', 'purple_heart': '💜', 'black_heart': '🖤', 'white_heart': '🤍',
            'brown_heart': '🤎', 'heart_on_fire': '❤️‍🔥', 'mending_heart': '❤️‍🩹', 'broken': '💔',
            'exclamation_heart': '❣️', 'two_hearts': '💕', 'revolving': '💞', 'heartbeat': '💓',
            'growing': '💗', 'sparkling': '💖', 'cupid': '💘', 'gift_heart': '💝', 'heart_decoration': '💟',
            // Symbols & misc
            '100': '💯', 'anger': '💢', 'boom': '💥', 'dizzy_symbol': '💫', 'sweat_drops': '💦',
            'dash': '💨', 'hole': '🕳️', 'bomb': '💣', 'speech': '💬', 'eye_speech': '👁️‍🗨️',
            'left_speech': '🗨️', 'right_anger': '🗯️', 'thought': '💭', 'zzz': '💤',
            'sparkles': '✨', 'stars': '🌟', 'star': '⭐', 'shooting_star': '🌠', 'fire': '🔥',
            'comet': '☄️', 'fireworks': '🎆', 'sparkler': '🎇', 'balloon': '🎈', 'party': '🎉',
            'tada': '🎊', 'tanabata': '🎋', 'pine': '🎍', 'dolls': '🎎', 'carp_streamer': '🎏',
            'wind_chime': '🎐', 'moon_viewing': '🎑', 'red_envelope': '🧧', 'ribbon': '🎀', 'gift': '🎁',
            'reminder_ribbon': '🎗️', 'ticket': '🎟️', 'admission': '🎫', 'crystal_ball': '🔮', 'nazar': '🧿',
            'hamsa': '🪬', 'gaming': '🎮', 'joystick': '🕹️', 'slot': '🎰', 'dice': '🎲',
            'chess': '♟️', 'puzzle': '🧩', 'teddy': '🧸', 'pinata': '🪅', 'mirror_ball': '🪩',
            'nesting_dolls': '🪆', 'spades': '♠️', 'hearts_suit': '♥️', 'diamonds': '♦️', 'clubs': '♣️',
            'mahjong': '🀄', 'joker': '🃏', 'music': '🎵', 'notes': '🎶', 'musical_score': '🎼',
            'warning': '⚠️', 'check': '✅', 'x': '❌', 'question': '❓', 'exclamation': '❗',
            'bangbang': '‼️', 'interrobang': '⁉️', 'lightning': '⚡', 'trophy': '🏆', 'medal': '🥇',
            'silver_medal': '🥈', 'bronze_medal': '🥉', 'sports_medal': '🏅', 'military_medal': '🎖️',
            'copyright': '©️', 'registered': '®️', 'tm': '™️', 'infinity': '♾️',
            'peace_symbol': '☮️', 'cross': '✝️', 'star_crescent': '☪️', 'om': '🕉️', 'wheel_dharma': '☸️',
            'star_david': '✡️', 'yin_yang': '☯️', 'atom': '⚛️', 'radioactive': '☢️', 'biohazard': '☣️',
            'recycle': '♻️',
            // Objects
            'watch': '⌚', 'phone': '📱', 'calling': '📲', 'computer': '💻', 'keyboard': '⌨️',
            'desktop': '🖥️', 'printer': '🖨️', 'mouse': '🖱️', 'trackball': '🖲️', 'cd': '💿',
            'dvd': '📀', 'vhs': '📼', 'camera': '📷', 'camera_flash': '📸', 'video': '📹',
            'movie': '🎥', 'projector': '📽️', 'film': '🎞️', 'telephone': '☎️', 'pager': '📟',
            'fax': '📠', 'tv': '📺', 'radio': '📻', 'microphone': '🎙️', 'level_slider': '🎚️',
            'control_knobs': '🎛️', 'stopwatch': '⏱️', 'timer': '⏲️', 'alarm': '⏰', 'mantelpiece_clock': '🕰️',
            'hourglass': '⌛', 'hourglass_flowing': '⏳', 'satellite_dish': '📡', 'battery': '🔋', 'low_battery': '🪫',
            'plug': '🔌', 'bulb': '💡', 'flashlight': '🔦', 'candle': '🕯️', 'lamp': '🪔',
            'fire_extinguisher': '🧯', 'oil': '🛢️', 'dollar': '💵', 'yen': '💴', 'euro': '💶',
            'pound': '💷', 'coin': '🪙', 'money_bag': '💰', 'credit_card': '💳', 'id_card': '🪪',
            'receipt': '🧾', 'gem': '💎', 'balance': '⚖️', 'ladder': '🪜', 'toolbox': '🧰',
            'screwdriver': '🪛', 'wrench': '🔧', 'hammer': '🔨', 'hammer_wrench': '🛠️', 'pick': '⛏️',
            'saw': '🪚', 'nut_bolt': '🔩', 'gear': '⚙️', 'mousetrap': '🪤', 'chains': '⛓️',
            'magnet': '🧲', 'gun': '🔫', 'bomb': '💣', 'firecracker': '🧨', 'axe': '🪓',
            'knife': '🔪', 'dagger': '🗡️', 'crossed_swords': '⚔️', 'shield': '🛡️', 'coffin': '⚰️',
            'headstone': '🪦', 'urn': '⚱️', 'amphora': '🏺', 'barber': '💈', 'alembic': '⚗️',
            'telescope': '🔭', 'microscope': '🔬', 'xray': '🩻', 'adhesive': '🩹', 'stethoscope': '🩺',
            'pill': '💊', 'syringe': '💉', 'drop_blood': '🩸', 'thermometer_obj': '🌡️', 'dna': '🧬',
            'microbe': '🦠', 'petri': '🧫', 'test_tube': '🧪', 'label': '🏷️', 'bookmark': '🔖',
            'toilet': '🚽', 'plunger': '🪠', 'shower': '🚿', 'bathtub': '🛁', 'toothbrush': '🪥',
            'razor': '🪒', 'roll': '🧻', 'soap': '🧼', 'bubbles': '🫧', 'bucket': '🪣',
            'sponge': '🧽', 'lotion': '🧴', 'bed': '🛏️', 'couch': '🛋️', 'chair': '🪑',
            'door': '🚪', 'mirror': '🪞', 'window': '🪟', 'broom': '🧹', 'basket': '🧺',
            'cart': '🛒', 'moai': '🗿', 'placard': '🪧',
            'book': '📖', 'books': '📚', 'newspaper': '📰', 'scroll': '📜', 'memo': '📝',
            'pencil': '✏️', 'pen': '🖊️', 'paintbrush': '🖌️', 'crayon': '🖍️', 'scissors': '✂️',
            'pushpin': '📌', 'paperclip': '📎', 'link': '🔗', 'lock': '🔒', 'unlock': '🔓',
            'key': '🔑', 'old_key': '🗝️', 'mag': '🔍', 'bell': '🔔', 'no_bell': '🔕',
            'speaker': '🔊', 'mute': '🔇',
            // Clothing
            'glasses': '👓', 'sunglasses_obj': '🕶️', 'goggles': '🥽', 'lab_coat': '🥼', 'safety_vest': '🦺',
            'necktie': '👔', 'tshirt': '👕', 'jeans': '👖', 'scarf': '🧣', 'gloves': '🧤',
            'coat': '🧥', 'socks': '🧦', 'dress': '👗', 'kimono': '👘', 'sari': '🥻',
            'swimsuit': '🩱', 'briefs': '🩲', 'shorts': '🩳', 'bikini': '👙', 'blouse': '👚',
            'purse': '👛', 'handbag': '👜', 'pouch': '👝', 'shopping': '🛍️', 'backpack': '🎒',
            'thong_sandal': '🩴', 'shoe': '👞', 'sneaker': '👟', 'hiking_boot': '🥾', 'flat_shoe': '🥿',
            'heel': '👠', 'sandal': '👡', 'ballet': '🩰', 'boot': '👢', 'crown': '👑',
            'womans_hat': '👒', 'top_hat': '🎩', 'graduation': '🎓', 'cap': '🧢', 'helmet': '🪖',
            'rescue_helmet': '⛑️', 'lipstick': '💄', 'ring': '💍',
            // Nature & animals
            'monkey_face': '🐵', 'monkey': '🐒', 'gorilla': '🦍', 'orangutan': '🦧', 'dog': '🐶',
            'dog2': '🐕', 'guide_dog': '🦮', 'service_dog': '🐕‍🦺', 'poodle': '🐩', 'wolf': '🐺',
            'fox': '🦊', 'raccoon': '🦝', 'cat': '🐱', 'cat2': '🐈', 'black_cat': '🐈‍⬛',
            'lion': '🦁', 'tiger': '🐯', 'tiger2': '🐅', 'leopard': '🐆', 'horse': '🐴',
            'horse2': '🐎', 'unicorn': '🦄', 'zebra': '🦓', 'deer': '🦌', 'moose': '🫎',
            'bison': '🦬', 'cow': '🐮', 'ox': '🐂', 'water_buffalo': '🐃', 'cow2': '🐄',
            'pig': '🐷', 'pig2': '🐖', 'boar': '🐗', 'pig_nose': '🐽', 'ram': '🐏',
            'sheep': '🐑', 'goat': '🐐', 'camel': '🐪', 'two_hump_camel': '🐫', 'llama': '🦙',
            'giraffe': '🦒', 'elephant': '🐘', 'mammoth': '🦣', 'rhino': '🦏', 'hippo': '🦛',
            'mouse_face': '🐭', 'mouse2': '🐁', 'rat': '🐀', 'hamster': '🐹', 'rabbit': '🐰',
            'rabbit2': '🐇', 'chipmunk': '🐿️', 'beaver': '🦫', 'hedgehog': '🦔', 'bat': '🦇',
            'bear': '🐻', 'polar_bear': '🐻‍❄️', 'koala': '🐨', 'panda': '🐼', 'sloth': '🦥',
            'otter': '🦦', 'skunk': '🦨', 'kangaroo': '🦘', 'badger': '🦡', 'paw_prints': '🐾',
            'turkey': '🦃', 'chicken': '🐔', 'rooster': '🐓', 'hatching_chick': '🐣', 'baby_chick': '🐤',
            'chick': '🐥', 'bird': '🐦', 'penguin': '🐧', 'dove': '🕊️', 'eagle': '🦅',
            'duck': '🦆', 'swan': '🦢', 'owl': '🦉', 'dodo': '🦤', 'feather': '🪶',
            'flamingo': '🦩', 'peacock': '🦚', 'parrot': '🦜', 'wing': '🪽', 'black_bird': '🐦‍⬛',
            'goose': '🪿', 'frog': '🐸', 'crocodile': '🐊', 'turtle': '🐢', 'lizard': '🦎',
            'snake': '🐍', 'dragon_face': '🐲', 'dragon': '🐉', 'sauropod': '🦕', 'trex': '🦖',
            'whale': '🐳', 'whale2': '🐋', 'dolphin': '🐬', 'seal': '🦭', 'fish': '🐟',
            'tropical_fish': '🐠', 'blowfish': '🐡', 'shark': '🦈', 'octopus': '🐙', 'shell': '🐚',
            'coral': '🪸', 'jellyfish': '🪼', 'snail': '🐌', 'butterfly': '🦋', 'bug': '🐛',
            'ant': '🐜', 'bee': '🐝', 'beetle': '🪲', 'ladybug': '🐞', 'cricket': '🦗',
            'cockroach': '🪳', 'spider': '🕷️', 'web': '🕸️', 'scorpion': '🦂', 'mosquito': '🦟',
            'fly': '🪰', 'worm': '🪱', 'bouquet': '💐', 'cherry_blossom': '🌸', 'flower_white': '💮',
            'rosette': '🏵️', 'rose': '🌹', 'wilted': '🥀', 'hibiscus': '🌺', 'sunflower': '🌻',
            'blossom': '🌼', 'tulip': '🌷', 'lotus': '🪷', 'seedling': '🌱', 'potted_plant': '🪴',
            'evergreen': '🌲', 'deciduous': '🌳', 'palm': '🌴', 'cactus': '🌵', 'rice': '🌾',
            'herb': '🌿', 'shamrock': '☘️', 'four_leaf': '🍀', 'maple_leaf': '🍁', 'fallen_leaf': '🍂',
            'leaves': '🍃', 'nest': '🪹', 'nest_eggs': '🪺', 'mushroom': '🍄', 'rock': '🪨', 'wood': '🪵',
            // Food & drink
            'green_apple': '🍏', 'apple': '🍎', 'pear': '🍐', 'orange': '🍊', 'lemon': '🍋',
            'banana': '🍌', 'watermelon': '🍉', 'grapes': '🍇', 'strawberry': '🍓', 'blueberries': '🫐',
            'melon': '🍈', 'cherry': '🍒', 'peach': '🍑', 'mango': '🥭', 'pineapple': '🍍',
            'coconut': '🥥', 'kiwi': '🥝', 'tomato': '🍅', 'eggplant': '🍆', 'avocado': '🥑',
            'broccoli': '🥦', 'leafy_green': '🥬', 'cucumber': '🥒', 'hot_pepper': '🌶️', 'bell_pepper': '🫑',
            'corn': '🌽', 'carrot': '🥕', 'garlic': '🧄', 'onion': '🧅', 'potato': '🥔',
            'sweet_potato': '🍠', 'beans': '🫘', 'croissant': '🥐', 'bagel': '🥯', 'bread': '🍞',
            'flatbread': '🫓', 'baguette': '🥖', 'pretzel': '🥨', 'cheese': '🧀', 'egg': '🥚',
            'cooking': '🍳', 'butter': '🧈', 'pancakes': '🥞', 'waffle': '🧇', 'bacon': '🥓',
            'steak': '🥩', 'poultry_leg': '🍗', 'meat': '🍖', 'bone': '🦴', 'hotdog': '🌭',
            'hamburger': '🍔', 'fries': '🍟', 'pizza': '🍕', 'tamale': '🫔', 'sandwich': '🥪',
            'pita': '🥙', 'falafel': '🧆', 'taco': '🌮', 'burrito': '🌯', 'fondue': '🫕',
            'salad': '🥗', 'stew': '🥘', 'jar': '🫙', 'canned': '🥫', 'spaghetti': '🍝',
            'ramen': '🍜', 'soup': '🍲', 'curry': '🍛', 'sushi': '🍣', 'bento': '🍱',
            'dumpling': '🥟', 'oyster': '🦪', 'shrimp': '🍤', 'rice_ball': '🍙', 'rice_bowl': '🍚',
            'rice_cracker': '🍘', 'fish_cake': '🍥', 'fortune_cookie': '🥠', 'moon_cake': '🥮', 'oden': '🍢',
            'dango': '🍡', 'ice_shaved': '🍧', 'ice_cream': '🍨', 'cone': '🍦', 'pie': '🥧',
            'cupcake': '🧁', 'cake': '🎂', 'birthday': '🎂', 'custard': '🍮', 'lollipop': '🍭',
            'candy': '🍬', 'chocolate': '🍫', 'popcorn': '🍿', 'donut': '🍩', 'cookie': '🍪',
            'chestnut': '🌰', 'peanuts': '🥜', 'honey': '🍯', 'milk': '🥛', 'baby_bottle': '🍼',
            'pouring_liquid': '🫗', 'coffee': '☕', 'teapot': '🫖', 'tea': '🍵', 'juice': '🧃',
            'cup_straw': '🥤', 'boba': '🧋', 'sake': '🍶', 'beer': '🍺', 'beers': '🍻',
            'clinking': '🥂', 'wine': '🍷', 'tumbler': '🥃', 'cocktail': '🍸', 'tropical': '🍹',
            'mate': '🧉', 'champagne': '🍾', 'ice_cube': '🧊', 'spoon': '🥄', 'fork_knife': '🍴',
            'plate': '🍽️', 'bowl_spoon': '🥣', 'takeout': '🥡', 'chopsticks': '🥢',
            // Activities & sports
            'soccer': '⚽', 'basketball': '🏀', 'football': '🏈', 'baseball': '⚾', 'softball': '🥎',
            'tennis': '🎾', 'volleyball': '🏐', 'rugby': '🏉', 'flying_disc': '🥏', 'pool': '🎱',
            'yo_yo': '🪀', 'ping_pong': '🏓', 'badminton': '🏸', 'hockey': '🏒', 'field_hockey': '🏑',
            'lacrosse': '🥍', 'cricket_game': '🏏', 'boomerang': '🪃', 'goal_net': '🥅', 'golf': '⛳',
            'kite': '🪁', 'bow_arrow': '🏹', 'fishing': '🎣', 'diving_mask': '🤿', 'boxing': '🥊',
            'martial_arts': '🥋', 'running_shirt': '🎽', 'skateboard': '🛹', 'roller_skate': '🛼', 'sled': '🛷',
            'ice_skate': '⛸️', 'curling': '🥌', 'ski': '🎿', 'circus': '🎪', 'performing_arts': '🎭',
            'art': '🎨', 'clapper': '🎬', 'microphone2': '🎤', 'headphones': '🎧', 'piano': '🎹',
            'drum': '🥁', 'long_drum': '🪘', 'sax': '🎷', 'trumpet': '🎺', 'accordion': '🪗',
            'guitar': '🎸', 'banjo': '🪕', 'violin': '🎻', 'flute': '🪈', 'dart': '🎯',
            'bowling': '🎳',
            // Travel & places
            'car': '🚗', 'taxi': '🚕', 'suv': '🚙', 'bus': '🚌', 'trolleybus': '🚎',
            'racing': '🏎️', 'police_car': '🚓', 'ambulance': '🚑', 'firetruck': '🚒', 'minibus': '🚐',
            'pickup_truck': '🛻', 'truck': '🚚', 'articulated': '🚛', 'tractor': '🚜', 'scooter': '🛴',
            'bike': '🚲', 'motor_scooter': '🛵', 'motorcycle': '🏍️', 'auto_rickshaw': '🛺', 'wheel': '🛞',
            'police_light': '🚨', 'oncoming_police': '🚔', 'train': '🚆', 'metro': '🚇', 'tram': '🚊',
            'station': '🚉', 'bullet_train': '🚄', 'high_speed': '🚅', 'monorail': '🚝', 'railway': '🚞',
            'airplane': '✈️', 'departure': '🛫', 'arrival': '🛬', 'small_airplane': '🛩️', 'seat': '💺',
            'satellite': '🛰️', 'rocket': '🚀', 'ufo': '🛸', 'helicopter': '🚁', 'canoe': '🛶',
            'boat': '⛵', 'speedboat': '🚤', 'motor_boat': '🛥️', 'passenger_ship': '🛳️', 'ferry': '⛴️',
            'ship': '🚢', 'anchor': '⚓', 'hook': '🪝', 'fuel_pump': '⛽', 'construction_sign': '🚧',
            'traffic_light': '🚦', 'vertical_traffic': '🚥', 'bus_stop': '🚏', 'world_map': '🗺️',
            'statue_liberty': '🗽', 'tokyo_tower': '🗼', 'castle': '🏰', 'japanese_castle': '🏯',
            'stadium': '🏟️', 'ferris_wheel': '🎡', 'roller_coaster': '🎢', 'carousel': '🎠', 'fountain': '⛲',
            'beach_umbrella': '⛱️', 'beach': '🏖️', 'island': '🏝️', 'desert': '🏜️', 'volcano': '🌋',
            'mountain': '⛰️', 'snow_mountain': '🏔️', 'mount_fuji': '🗻', 'camping': '🏕️', 'hut': '🛖',
            'house': '🏠', 'house_garden': '🏡', 'derelict': '🏚️', 'building_construction': '🏗️', 'factory': '🏭',
            'office': '🏢', 'department_store': '🏬', 'post_office': '🏣', 'hospital': '🏥', 'bank': '🏦',
            'hotel': '🏨', 'convenience': '🏪', 'school': '🏫', 'love_hotel': '🏩', 'wedding': '💒',
            'classical': '🏛️', 'church': '⛪', 'mosque': '🕌', 'synagogue': '🕍', 'hindu_temple': '🛕',
            'kaaba': '🕋', 'shinto_shrine': '⛩️', 'railway_track': '🛤️', 'road': '🛣️',
            'sunrise': '🌅', 'sunrise_city': '🌄', 'night': '🌃', 'milky_way': '🌌', 'bridge_night': '🌉',
            // Weather
            'sun': '☀️', 'sun_clouds': '🌤️', 'partly_cloudy': '⛅', 'sun_behind_cloud': '🌥️', 'cloud': '☁️',
            'sun_rain': '🌦️', 'rain': '🌧️', 'thunder': '⛈️', 'lightning_cloud': '🌩️', 'snow_cloud': '🌨️',
            'snow': '❄️', 'snowman_snow': '☃️', 'snowman': '⛄', 'wind_face': '🌬️', 'wind': '💨',
            'tornado': '🌪️', 'fog': '🌫️', 'rainbow': '🌈', 'umbrella_rain': '☔', 'droplet': '💧',
            'wave': '🌊', 'moon': '🌙', 'crescent_moon': '🌛', 'last_quarter_face': '🌜', 'new_moon_face': '🌚',
            'full_moon': '🌕', 'waning_gibbous': '🌖', 'last_quarter': '🌗', 'waning_crescent': '🌘',
            'new_moon': '🌑', 'waxing_crescent': '🌒', 'first_quarter': '🌓', 'waxing_gibbous': '🌔',
            'earth_africa': '🌍', 'earth_americas': '🌎', 'earth_asia': '🌏', 'ringed_planet': '🪐',
            // Flags
            'white_flag': '🏳️', 'black_flag': '🏴', 'checkered_flag': '🏁', 'triangular_flag': '🚩',
            'rainbow_flag': '🏳️‍🌈', 'transgender_flag': '🏳️‍⚧️', 'pirate_flag': '🏴‍☠️',
            'us': '🇺🇸', 'gb': '🇬🇧', 'ca': '🇨🇦', 'au': '🇦🇺', 'de': '🇩🇪',
            'fr': '🇫🇷', 'jp': '🇯🇵', 'kr': '🇰🇷', 'cn': '🇨🇳', 'india': '🇮🇳',
            'br': '🇧🇷', 'mx': '🇲🇽', 'es': '🇪🇸', 'it': '🇮🇹', 'ru': '🇷🇺',
            'se': '🇸🇪', 'no': '🇳🇴', 'dk': '🇩🇰', 'fi': '🇫🇮', 'nl': '🇳🇱',
            'ch': '🇨🇭', 'pl': '🇵🇱', 'ua': '🇺🇦', 'tr': '🇹🇷', 'gr': '🇬🇷',
            'pt': '🇵🇹', 'ie': '🇮🇪', 'za': '🇿🇦', 'ng': '🇳🇬', 'eg': '🇪🇬',
            'ar': '🇦🇷', 'th': '🇹🇭', 'vn': '🇻🇳', 'id': '🇮🇩', 'ph': '🇵🇭',
            'sg': '🇸🇬', 'nz': '🇳🇿', 'sa': '🇸🇦', 'ae': '🇦🇪', 'il': '🇮🇱',
            'tw': '🇹🇼', 'hk': '🇭🇰', 'pr': '🇵🇷', 'cu': '🇨🇺', 'jm': '🇯🇲',
            // Aliases (restore original shortcodes that were renamed during expansion)
            'ok': '👌', 'money': '🤑', 'hearts': '💕', 'celebrate': '🙌',
            'sunglasses': '😎', 'nauseous': '🤢', 'cold_sweat': '😰',
            'scream_cat': '🙀', 'exploding': '🤯', 'clock': '🕐', 'sunset': '🌆',
            'joy': '😂', '+1': '👍', '-1': '👎', 'thumbs_up': '👍', 'thumbs_down': '👎',
            'fingers_crossed': '🤞', 'raised_hands': '🙌', 'pray_hands': '🙏',
            'flex': '💪', 'eyes_emoji': '👀', 'tongue_out': '😛', 'lol': '😂',
            'crying': '😭', 'smiling': '😊', 'kissing_heart': '😘', 'winking': '😉',
            'grinning_face': '😀', 'happy': '😊', 'smiley_face': '😃',
            'rolling_eyes': '🙄', 'face_palm': '🤦', 'shrugging': '🤷',
            'clapping': '👏', 'wave_hand': '👋', 'fist': '✊', 'punch': '👊',
            'pointing_up': '☝️', 'pointing_down': '👇', 'pointing_left': '👈', 'pointing_right': '👉',
            'red_heart': '❤️', 'love_heart': '❤️', 'heartbreak': '💔',
            'skull_emoji': '💀', 'poo': '💩', 'hundred': '💯', 'flames': '🔥',
            'sparkle': '✨', 'zap': '⚡', 'snow_emoji': '❄️', 'rain_emoji': '🌧️',
            'sun_emoji': '☀️', 'moon_emoji': '🌙', 'earth': '🌍', 'globe': '🌎',
            'usa': '🇺🇸', 'uk': '🇬🇧', 'canada': '🇨🇦', 'japan': '🇯🇵', 'germany': '🇩🇪',
            'france': '🇫🇷', 'brazil': '🇧🇷', 'mexico': '🇲🇽', 'italy': '🇮🇹',
            'pizza_emoji': '🍕', 'beer_emoji': '🍺', 'coffee_emoji': '☕', 'wine_emoji': '🍷',
            'rocket_emoji': '🚀', 'car_emoji': '🚗', 'airplane_emoji': '✈️',
            'money_bag': '💰', 'cash': '💵', 'btc': '₿'
        };
        this.discoveredChannelsIndex = 0;
        this.swipeStartX = null;
        this.swipeThreshold = 50;
        this.enhancedEmojiModal = null;
        this.loadRecentEmojis();
        this.lightningAddress = null;
        this.userLightningAddresses = new Map();
        this.userAvatars = new Map();
        this.avatarBlobCache = new Map();
        this.avatarBlobInflight = new Map();
        this.profileFetchedAt = new Map();
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
            title: 'Nymchat Developer'
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
                    name: 'Nymchat Supporter',
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
        this.supporterBadgeActive = localStorage.getItem('nym_supporter_active') !== 'false';
        this.loadShopActiveCache();
        this._restorePurchasesFromCache();
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
            supporter: this.userPurchases.has('supporter-badge') && this.supporterBadgeActive !== false,
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
                ['title', 'Nymchat Shop Active Items']
            ],
            content: JSON.stringify(payload),
            pubkey: this.pubkey
        };

        let signed;
        if (this.privkey) {
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

        // Restore cached purchases so items show as "purchased" in the shop
        this._restorePurchasesFromCache();

        // Apply to any existing messages immediately
        this.applyShopStylesToOwnMessages();
    }

    _cachePurchases() {
        try {
            const data = Array.from(this.userPurchases.entries());
            const cosmeticsArr = Array.from(this.activeCosmetics || []);
            localStorage.setItem('nym_purchases_cache', JSON.stringify({
                purchases: data,
                activeCosmetics: cosmeticsArr,
                ts: Date.now()
            }));
        } catch (e) { /* ignore */ }
    }

    _restorePurchasesFromCache() {
        try {
            const raw = localStorage.getItem('nym_purchases_cache');
            if (!raw) return;
            const cache = JSON.parse(raw);
            if (!cache || !cache.purchases) return;

            // Only restore if userPurchases is currently empty (avoid overwriting Nostr data)
            if (this.userPurchases.size === 0) {
                cache.purchases.forEach(([id, purchase]) => {
                    this.userPurchases.set(id, purchase);
                });
                if (cache.activeCosmetics) {
                    this.activeCosmetics = new Set(cache.activeCosmetics);
                }
            }
        } catch (e) { /* ignore */ }
    }

    applyCachedShopItemsToNewIdentity() {
        if (!this.pubkey) return;

        // Restore cached purchases so items show as "purchased" in the shop
        this._restorePurchasesFromCache();

        // Load cached active style/flair from localStorage
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

        // If there are any active items or purchases, publish them for the new pubkey
        if (this.activeMessageStyle || this.activeFlair || (this.activeCosmetics && this.activeCosmetics.size > 0) || this.userPurchases.size > 0) {
            // Also cache for the new pubkey so others see it immediately
            this.cacheShopActiveItems(this.pubkey, {
                style: this.activeMessageStyle,
                flair: this.activeFlair,
                supporter: this.userPurchases.has('supporter-badge'),
                cosmetics: Array.from(this.activeCosmetics || [])
            }, Math.floor(Date.now() / 1000));

            // Save purchases to Nostr for the new keypair
            this.savePurchaseToNostr();

            // Broadcast active items for the new pubkey so other users see the styling
            this.publishActiveShopItems();

            // Apply to any messages already displayed
            this.applyShopStylesToOwnMessages();
        }
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

            // Add supporter badge if owned and active
            const supporterActive = this.userPurchases.has('supporter-badge') && this.supporterBadgeActive !== false;
            if (supporterActive) {
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
                                contentEl.textContent = '';
                            }, 10000);
                        }
                    }
                });
            }

            // Update flair badge in author element
            const authorEl = msg.querySelector('.message-author');
            if (authorEl) {
                const existingFlair = authorEl.querySelector('.flair-badge');
                if (existingFlair) existingFlair.remove();
                if (this.activeFlair) {
                    const flairItem = this.getShopItemById(this.activeFlair);
                    if (flairItem) {
                        const flairSpan = document.createElement('span');
                        flairSpan.className = `flair-badge ${this.activeFlair}`;
                        flairSpan.innerHTML = flairItem.icon;
                        const suffix = authorEl.querySelector('.nym-suffix');
                        if (suffix) {
                            suffix.after(flairSpan);
                        }
                    }
                }

                // Update supporter badge
                const existingSupporter = authorEl.querySelector('.supporter-badge');
                if (existingSupporter) existingSupporter.remove();
                if (supporterActive) {
                    const badge = document.createElement('span');
                    badge.className = 'supporter-badge';
                    badge.innerHTML = '<span class="supporter-badge-icon">\u{1F3C6}</span><span class="supporter-badge-text">Supporter</span>';
                    authorEl.insertBefore(badge, authorEl.lastChild);
                }
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

        // Apply to own messages immediately
        this.applyShopStylesToOwnMessages();

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
            ${!isPurchased ? '<button class="shop-buy-btn">GET</button>' : ''}
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
            ${!isPurchased ? '<button class="shop-buy-btn">GET</button>' : ''}
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
            ${!isPurchased ? '<button class="shop-buy-btn">GET</button>' : ''}
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
                    const isActive = this.supporterBadgeActive !== false;
                    html += `<div class="shop-item-preview"><span class="supporter-badge"><span class="supporter-badge-icon">🏆</span><span class="supporter-badge-text">Supporter</span></span></div>`;
                    html += `
<button class="shop-buy-btn" onclick="nym.activateSupporter()" style="margin-top: 10px; width: 100%;">
${isActive ? 'DEACTIVATE' : 'ACTIVATE'}
</button>`;
                }

                // Transfer button for all purchased items
                html += `
<button class="shop-buy-btn shop-transfer-btn" onclick="nym.promptTransferShopItem('${itemId}')" style="margin-top: 8px; width: 100%; background: linear-gradient(135deg, rgba(0, 255, 170, 0.12), rgba(0, 255, 170, 0.05)); border-color: rgba(0, 255, 170, 0.3); color: var(--text-bright);">
TRANSFER TO PUBKEY
</button>`;

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
            const zapRequest = await this.createShopZapRequest(amount, `Nymchat Shop Purchase: ${item.name}`);

            // Build the LNURL callback with the zap request
            const invoice = await this.fetchShopLightningInvoice(
                '69420@wallet.yakihonne.com',
                amount,
                `Nymchat Shop Purchase: ${item.name}`,
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

        // Capture context and nullify immediately to prevent duplicate handling
        // (both invoice polling and zap receipt events can trigger this)
        const { itemId, item, amount } = this.currentPurchaseContext;
        const shopInvoice = this.currentShopInvoice;
        this.currentPurchaseContext = null;
        this.currentShopInvoice = null;

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
            txid: shopInvoice.zapRequestId || 'shop_' + Date.now()
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

        // If there's a recovery code, don't auto-close — let the user dismiss manually
        const hasRecovery = this.connectionMode === 'ephemeral' && recoveryCode;

        // Replace modal action buttons with a Close button
        const modalActions = document.querySelector('#zapModal .modal-actions');
        if (modalActions) {
            if (hasRecovery) {
                modalActions.innerHTML = `<button class="send-btn" onclick="nym.dismissShopSuccess()">Close</button>`;
            } else {
                modalActions.innerHTML = `<button class="send-btn" onclick="nym.dismissShopSuccess()">Close</button>`;
                // Auto-close after 5 seconds for non-recovery purchases
                this._shopSuccessAutoClose = setTimeout(() => {
                    this.dismissShopSuccess();
                }, 5000);
            }
        }
    }

    dismissShopSuccess() {
        if (this._shopSuccessAutoClose) {
            clearTimeout(this._shopSuccessAutoClose);
            this._shopSuccessAutoClose = null;
        }
        this.closeZapModal();
        this.closeShop();

        // Refresh shop display
        if (this.activeShopTab) {
            setTimeout(() => {
                this.openShop();
                this.switchShopTab('inventory');
            }, 500);
        }
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
                activeCosmetics: Array.from(this.activeCosmetics || []),
                supporterActive: this.supporterBadgeActive !== false
            };

            // Cache to localStorage (CRITICAL)
            localStorage.setItem('nym_active_style', this.activeMessageStyle || '');
            localStorage.setItem('nym_active_flair', this.activeFlair || '');
            this._cachePurchases();

            const purchaseEvent = {
                kind: 30078,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ["d", "nym-shop-purchases"],
                    ["title", "Nymchat Shop Purchases"]
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

        // Subscribe to incoming transfers (shop items & settings) from other users.
        // Uses only the standard #p tag filter (relays reliably index single-letter tags).
        // The d-tag routing in handleEvent() distinguishes shop vs settings transfers.
        // This subscription stays open for the session so transfers are received in real-time.
        const transferSubId = "transfers-" + Math.random().toString(36).substring(7);
        const transferSub = [
            "REQ",
            transferSubId,
            {
                kinds: [30078],
                "#p": [this.pubkey],
                limit: 50
            }
        ];

        this.sendToRelay(transferSub);

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
                supporter: this.userPurchases.has('supporter-badge') && this.supporterBadgeActive !== false,
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

    activateSupporter() {
        if (!this.userPurchases.has('supporter-badge')) return;

        // Toggle supporter badge
        if (this.supporterBadgeActive !== false) {
            this.supporterBadgeActive = false;
            localStorage.setItem('nym_supporter_active', 'false');
            this.displaySystemMessage('❎ Deactivated Nymchat Supporter badge');
        } else {
            this.supporterBadgeActive = true;
            localStorage.setItem('nym_supporter_active', 'true');
            this.displaySystemMessage('✅ Activated Nymchat Supporter badge');
        }

        this.savePurchaseToNostr();
        this.publishActiveShopItems();
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

                // Cache purchases locally
                this._cachePurchases();

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

    promptTransferShopItem(itemId) {
        const item = this.getShopItemById(itemId);
        if (!item) return;

        if (!this.userPurchases.has(itemId)) {
            this.displaySystemMessage('❌ You do not own this item');
            return;
        }

        // Create a modal prompt for entering the recipient pubkey
        const modal = document.createElement('div');
        modal.className = 'modal active';
        modal.id = 'transferModal';
        modal.innerHTML = `
<div class="modal-content" style="max-width: 420px;">
    <button class="modal-close" onclick="document.getElementById('transferModal').remove()">✕</button>
    <h3 style="color: var(--text-bright); margin-bottom: 15px;">Transfer Item</h3>
    <div style="margin-bottom: 15px;">
        <div style="display: flex; align-items: center; gap: 10px; margin-bottom: 10px;">
            <span>${item.icon}</span>
            <strong>${item.name}</strong>
        </div>
        <p style="font-size: 12px; color: var(--text-dim); margin-bottom: 15px;">
            Enter the recipient's hex pubkey (64 characters). This will send a Nostr event granting them access to this item on their devices.
        </p>
        <input type="text" id="transferPubkeyInput" placeholder="Recipient hex pubkey (64 chars)"
            style="width: 100%; padding: 10px; background: var(--bg); border: 1px solid var(--glass-border); border-radius: 8px; color: var(--text); font-family: var(--font-mono); font-size: 12px;" />
        <p id="transferError" style="color: var(--danger); font-size: 11px; margin-top: 5px; display: none;"></p>
    </div>
    <div style="display: flex; gap: 10px;">
        <button class="send-btn" onclick="nym.executeTransferShopItem('${itemId}')" style="flex: 1;">Confirm</button>
        <button class="send-btn" onclick="document.getElementById('transferModal').remove()" style="flex: 1; background: var(--bg-tertiary);">Cancel</button>
    </div>
</div>`;
        document.body.appendChild(modal);

        // Focus the input
        setTimeout(() => document.getElementById('transferPubkeyInput')?.focus(), 100);
    }

    async executeTransferShopItem(itemId) {
        const input = document.getElementById('transferPubkeyInput');
        const errorEl = document.getElementById('transferError');
        if (!input || !errorEl) return;

        const recipientPubkey = input.value.trim().toLowerCase();

        // Validate hex pubkey (64 hex chars)
        if (!/^[0-9a-f]{64}$/.test(recipientPubkey)) {
            errorEl.textContent = 'Invalid pubkey. Must be 64 hex characters.';
            errorEl.style.display = 'block';
            return;
        }

        if (recipientPubkey === this.pubkey) {
            errorEl.textContent = 'Cannot transfer to yourself.';
            errorEl.style.display = 'block';
            return;
        }

        const item = this.getShopItemById(itemId);
        if (!item || !this.userPurchases.has(itemId)) {
            errorEl.textContent = 'Item not found in your inventory.';
            errorEl.style.display = 'block';
            return;
        }

        const purchase = this.userPurchases.get(itemId);

        try {
            // Publish a transfer event (kind 30078 with d tag "nym-shop-transfer")
            const transferPayload = {
                itemId: itemId,
                itemName: item.name,
                itemType: item.type,
                fromPubkey: this.pubkey,
                toPubkey: recipientPubkey,
                originalPurchase: purchase,
                transferredAt: Math.floor(Date.now() / 1000)
            };

            const transferEvent = {
                kind: 30078,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ['d', `nym-shop-transfer-${itemId}-${recipientPubkey}`],
                    ['title', 'Nymchat Shop Item Transfer'],
                    ['p', recipientPubkey],
                    ['transfer-item', itemId],
                    ['transfer-to', recipientPubkey]
                ],
                content: JSON.stringify(transferPayload),
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(transferEvent);
            if (signedEvent) {
                this.sendToRelay(['EVENT', signedEvent]);
            }

            // Close the transfer modal
            const modal = document.getElementById('transferModal');
            if (modal) modal.remove();

            this.displaySystemMessage(`Transfer event sent! ${item.name} has been shared with ${recipientPubkey.substring(0, 8)}...`);

            // Refresh the inventory tab if open
            if (this.activeShopTab === 'inventory') {
                this.renderInventoryTab(document.getElementById('shopBody'));
            }
        } catch (error) {
            errorEl.textContent = 'Failed to send transfer event. Please try again.';
            errorEl.style.display = 'block';
        }
    }

    handleShopTransferEvent(event) {
        try {
            // Verify event signature
            if (!window.NostrTools.verifyEvent(event)) return;

            const transferTo = event.tags.find(t => t[0] === 'transfer-to');
            if (!transferTo || transferTo[1] !== this.pubkey) return;

            const data = JSON.parse(event.content);
            if (!data.itemId || !data.fromPubkey) return;

            // Verify the event was actually signed by the claimed sender
            if (event.pubkey !== data.fromPubkey) return;

            // Skip if already handled
            if (this.dismissedTransferEvents.has(event.id)) return;

            // Verify this item exists in the shop
            const item = this.getShopItemById(data.itemId);
            if (!item) return;

            // Skip if we already own this item
            if (this.userPurchases.has(data.itemId)) return;

            // Mark as handled so relays don't re-trigger it
            this.dismissTransferEvent(event.id);

            // Add the item to our purchases
            const purchase = {
                itemId: data.itemId,
                amount: data.originalPurchase?.amount || 0,
                timestamp: data.transferredAt || Math.floor(Date.now() / 1000),
                txid: `transfer_from_${data.fromPubkey.substring(0, 8)}_${Date.now()}`,
                transferredFrom: data.fromPubkey
            };

            this.userPurchases.set(data.itemId, purchase);

            // Cache purchases locally
            this._cachePurchases();

            // Save to Nostr so it persists
            this.savePurchaseToNostr();
            this.publishActiveShopItems();

            this.displaySystemMessage(`You received "${data.itemName}" from ${data.fromPubkey.substring(0, 8)}...! Check your Flair Shop inventory.`);
        } catch (e) {
            // Silently ignore malformed transfer events
        }
    }

    async executeSettingsTransfer() {
        const input = document.getElementById('settingsTransferPubkeyInput');
        const errorEl = document.getElementById('settingsTransferError');
        if (!input || !errorEl) return;

        const recipientPubkey = input.value.trim().toLowerCase();
        errorEl.style.display = 'none';

        if (!/^[0-9a-f]{64}$/.test(recipientPubkey)) {
            errorEl.textContent = 'Invalid pubkey. Must be 64 hex characters.';
            errorEl.style.display = 'block';
            return;
        }

        if (recipientPubkey === this.pubkey) {
            errorEl.textContent = 'Cannot transfer settings to yourself.';
            errorEl.style.display = 'block';
            return;
        }

        try {
            const avatarUrl = this.userAvatars.get(this.pubkey) || localStorage.getItem('nym_avatar_url') || '';

            const settingsPayload = {
                fromPubkey: this.pubkey,
                fromNym: this.nym,
                toPubkey: recipientPubkey,
                transferredAt: Math.floor(Date.now() / 1000),
                nickname: this.nym,
                avatarUrl: avatarUrl,
                settings: {
                    theme: this.settings.theme,
                    sound: this.settings.sound,
                    autoscroll: this.settings.autoscroll,
                    showTimestamps: this.settings.showTimestamps,
                    timeFormat: this.settings.timeFormat,
                    sortByProximity: this.settings.sortByProximity,
                    blurOthersImages: this.blurOthersImages,
                    lightningAddress: this.lightningAddress,
                    dmForwardSecrecyEnabled: !!this.settings.dmForwardSecrecyEnabled,
                    dmTTLSeconds: this.settings.dmTTLSeconds || 86400,
                    readReceiptsEnabled: this.settings.readReceiptsEnabled !== false,
                    pinnedLandingChannel: this.pinnedLandingChannel || { type: 'geohash', geohash: 'nym' },
                    wallpaperType: localStorage.getItem('nym_wallpaper_type') || 'geometric',
                    wallpaperCustomUrl: localStorage.getItem('nym_wallpaper_custom_url') || '',
                    colorMode: this.getColorMode(),
                    nickStyle: this.settings.nickStyle || 'fancy'
                }
            };

            const transferEvent = {
                kind: 30078,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ['d', `nym-settings-transfer-${this.pubkey}-${recipientPubkey}`],
                    ['title', 'Nymchat Settings Transfer'],
                    ['p', recipientPubkey],
                    ['settings-transfer-to', recipientPubkey]
                ],
                content: JSON.stringify(settingsPayload),
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(transferEvent);
            if (signedEvent) {
                this.sendToRelay(['EVENT', signedEvent]);
            }

            input.value = '';
            this.displaySystemMessage(`Settings transfer sent to ${recipientPubkey.substring(0, 8)}...!`);
        } catch (error) {
            errorEl.textContent = 'Failed to send settings transfer. Please try again.';
            errorEl.style.display = 'block';
        }
    }

    handleSettingsTransferEvent(event) {
        try {
            // Verify event signature
            if (!window.NostrTools.verifyEvent(event)) return;

            const transferTo = event.tags.find(t => t[0] === 'settings-transfer-to');
            if (!transferTo || transferTo[1] !== this.pubkey) return;

            const data = JSON.parse(event.content);
            if (!data.fromPubkey || !data.settings) return;

            // Verify the event was actually signed by the claimed sender
            if (event.pubkey !== data.fromPubkey) return;

            // Check if we already handled or have this pending transfer
            if (this.dismissedTransferEvents.has(event.id)) return;
            if (this.pendingSettingsTransfers.some(t => t.eventId === event.id)) return;

            // Add to pending list
            this.pendingSettingsTransfers.push({
                eventId: event.id,
                fromPubkey: data.fromPubkey,
                fromNym: data.fromNym || data.fromPubkey.substring(0, 8) + '...',
                nickname: data.nickname,
                avatarUrl: data.avatarUrl,
                settings: data.settings,
                transferredAt: data.transferredAt || event.created_at
            });

            // Notify user via system message
            this.displaySystemMessage(`Settings received from ${data.fromPubkey.substring(0, 8)}...! Approve from settings modal.`);

            // Update the pending transfers UI if the settings modal is open
            this.renderPendingSettingsTransfers();
        } catch (e) {
            // Silently ignore malformed transfer events
        }
    }

    acceptSettingsTransfer(eventId) {
        const transfer = this.pendingSettingsTransfers.find(t => t.eventId === eventId);
        if (!transfer) return;

        // Apply nickname
        if (transfer.nickname) {
            this.nym = transfer.nickname;
            localStorage.setItem(`nym_nickname_${this.pubkey}`, transfer.nickname);
            document.getElementById('currentNym').innerHTML = this.formatNymWithPubkey(this.nym, this.pubkey);
            this.saveToNostrProfile();
        }

        // Apply avatar
        if (transfer.avatarUrl) {
            this.userAvatars.set(this.pubkey, transfer.avatarUrl);
            localStorage.setItem('nym_avatar_url', transfer.avatarUrl);
            this.cacheAvatarImage(this.pubkey, transfer.avatarUrl);
        }

        // Apply settings
        const s = transfer.settings;
        if (s) {
            if (s.theme) {
                this.settings.theme = s.theme;
                this.applyTheme(s.theme);
                localStorage.setItem('nym_theme', s.theme);
            }
            if (s.sound !== undefined) {
                this.settings.sound = s.sound;
                localStorage.setItem('nym_sound', s.sound);
            }
            if (s.autoscroll !== undefined) {
                this.settings.autoscroll = s.autoscroll;
                localStorage.setItem('nym_autoscroll', s.autoscroll);
            }
            if (s.showTimestamps !== undefined) {
                this.settings.showTimestamps = s.showTimestamps;
                localStorage.setItem('nym_timestamps', s.showTimestamps);
            }
            if (s.timeFormat !== undefined) {
                this.settings.timeFormat = s.timeFormat;
                localStorage.setItem('nym_time_format', s.timeFormat);
            }
            if (s.sortByProximity !== undefined) {
                this.settings.sortByProximity = s.sortByProximity;
                localStorage.setItem('nym_sort_proximity', s.sortByProximity);
            }
            if (s.blurOthersImages !== undefined) {
                this.blurOthersImages = s.blurOthersImages;
                localStorage.setItem(`nym_image_blur_${this.pubkey}`, s.blurOthersImages.toString());
            }
            if (s.lightningAddress) {
                this.lightningAddress = s.lightningAddress;
                localStorage.setItem(`nym_lightning_address_${this.pubkey}`, s.lightningAddress);
            }
            if (s.dmForwardSecrecyEnabled !== undefined) {
                this.settings.dmForwardSecrecyEnabled = s.dmForwardSecrecyEnabled;
                localStorage.setItem('nym_dm_fwdsec_enabled', String(s.dmForwardSecrecyEnabled));
            }
            if (s.dmTTLSeconds !== undefined) {
                this.settings.dmTTLSeconds = s.dmTTLSeconds;
                localStorage.setItem('nym_dm_ttl_seconds', String(s.dmTTLSeconds));
            }
            if (s.readReceiptsEnabled !== undefined) {
                this.settings.readReceiptsEnabled = s.readReceiptsEnabled;
                localStorage.setItem('nym_read_receipts_enabled', String(s.readReceiptsEnabled));
            }
            if (s.pinnedLandingChannel) {
                this.pinnedLandingChannel = s.pinnedLandingChannel;
                this.settings.pinnedLandingChannel = s.pinnedLandingChannel;
                localStorage.setItem('nym_pinned_landing_channel', JSON.stringify(s.pinnedLandingChannel));
            }
            if (s.wallpaperType !== undefined) {
                this.saveWallpaper(s.wallpaperType, s.wallpaperCustomUrl || '');
                this.applyWallpaper(s.wallpaperType, s.wallpaperCustomUrl || '');
            }
            if (s.colorMode) {
                localStorage.setItem('nym_color_mode', s.colorMode);
                this.applyColorMode();
            }
            if (s.nickStyle) {
                this.settings.nickStyle = s.nickStyle;
                localStorage.setItem('nym_nick_style', s.nickStyle);
            }

            // Save synced settings to Nostr
            this.saveSyncedSettings();
        }

        // Remove from pending and mark as dismissed so relays don't re-trigger it
        this.pendingSettingsTransfers = this.pendingSettingsTransfers.filter(t => t.eventId !== eventId);
        this.dismissTransferEvent(eventId);
        this.renderPendingSettingsTransfers();

        // Update sidebar avatar
        this.updateSidebarAvatar();

        // Update settings modal UI if open
        if (document.getElementById('settingsModal').classList.contains('active')) {
            const s = transfer.settings;
            if (s) {
                if (s.theme) document.getElementById('themeSelect').value = s.theme;
                if (s.sound !== undefined) document.getElementById('soundSelect').value = s.sound;
                if (s.autoscroll !== undefined) document.getElementById('autoscrollSelect').value = String(s.autoscroll);
                if (s.showTimestamps !== undefined) {
                    document.getElementById('timestampSelect').value = String(s.showTimestamps);
                    const timeFormatGroup = document.getElementById('timeFormatGroup');
                    if (timeFormatGroup) timeFormatGroup.style.display = s.showTimestamps ? 'block' : 'none';
                }
                if (s.timeFormat !== undefined) document.getElementById('timeFormatSelect').value = s.timeFormat;
                if (s.sortByProximity !== undefined) {
                    const el = document.getElementById('proximitySelect');
                    if (el) el.value = String(s.sortByProximity);
                }
                if (s.blurOthersImages !== undefined) {
                    const el = document.getElementById('blurImagesSelect');
                    if (el) el.value = String(s.blurOthersImages);
                }
                if (s.lightningAddress) {
                    const el = document.getElementById('lightningAddressInput');
                    if (el) el.value = s.lightningAddress;
                }
                if (s.dmForwardSecrecyEnabled !== undefined) {
                    const el = document.getElementById('dmForwardSecrecySelect');
                    if (el) el.value = String(s.dmForwardSecrecyEnabled);
                    const ttlGroup = document.getElementById('dmTTLGroup');
                    if (ttlGroup) ttlGroup.style.display = s.dmForwardSecrecyEnabled ? 'block' : 'none';
                }
                if (s.dmTTLSeconds !== undefined) {
                    const el = document.getElementById('dmTTLSelect');
                    if (el) el.value = String(s.dmTTLSeconds);
                }
                if (s.readReceiptsEnabled !== undefined) {
                    const el = document.getElementById('readReceiptsSelect');
                    if (el) el.value = String(s.readReceiptsEnabled);
                }
                if (s.nickStyle) {
                    const el = document.getElementById('nickStyleSelect');
                    if (el) el.value = s.nickStyle;
                }
                if (s.colorMode) {
                    const colorModeGroup = document.getElementById('colorModeGroup');
                    if (colorModeGroup) {
                        colorModeGroup.querySelectorAll('.color-mode-btn').forEach(btn => {
                            btn.classList.toggle('active', btn.dataset.mode === s.colorMode);
                        });
                    }
                }
                if (s.wallpaperType !== undefined) {
                    document.querySelectorAll('.wallpaper-option').forEach(opt => {
                        opt.classList.toggle('selected', opt.dataset.wallpaper === s.wallpaperType);
                    });
                }
            }
        }

        this.displaySystemMessage(`Settings from ${transfer.fromNym} applied successfully!`);
    }

    rejectSettingsTransfer(eventId) {
        const transfer = this.pendingSettingsTransfers.find(t => t.eventId === eventId);
        this.pendingSettingsTransfers = this.pendingSettingsTransfers.filter(t => t.eventId !== eventId);
        this.renderPendingSettingsTransfers();
        this.dismissTransferEvent(eventId);
        if (transfer) {
            this.displaySystemMessage(`Settings transfer from ${transfer.fromNym} rejected.`);
        }
    }

    dismissTransferEvent(eventId) {
        this.dismissedTransferEvents.add(eventId);
        localStorage.setItem('nym_dismissed_transfers', JSON.stringify([...this.dismissedTransferEvents]));
    }

    renderPendingSettingsTransfers() {
        const container = document.getElementById('pendingSettingsTransfers');
        if (!container) return;

        if (this.pendingSettingsTransfers.length === 0) {
            container.innerHTML = '<div style="color: var(--text-dim); font-size: 12px;">No pending transfers</div>';
            return;
        }

        container.innerHTML = this.pendingSettingsTransfers.map(t => {
            const date = new Date(t.transferredAt * 1000).toLocaleString();
            return `
                <div style="display: flex; align-items: center; justify-content: space-between; padding: 8px; margin-bottom: 6px; background: rgba(255,255,255,0.03); border: 1px solid var(--glass-border); border-radius: 8px;">
                    <div style="flex: 1; min-width: 0;">
                        <div style="font-size: 13px; color: var(--text); font-weight: 500;">${this.escapeHtml(t.fromNym)}</div>
                        <div style="font-size: 11px; color: var(--text-dim); margin-top: 2px;">${date}</div>
                        <div style="font-size: 11px; color: var(--text-dim);">Includes: ${t.nickname ? 'nickname' : ''}${t.avatarUrl ? ', avatar' : ''}${t.settings ? ', preferences' : ''}</div>
                    </div>
                    <div style="display: flex; gap: 6px; margin-left: 8px;">
                        <button class="icon-btn" onclick="nym.acceptSettingsTransfer('${t.eventId}')" style="padding: 4px 10px; font-size: 12px;">Accept</button>
                        <button class="icon-btn" onclick="nym.rejectSettingsTransfer('${t.eventId}')" style="padding: 4px 10px; font-size: 12px; color: var(--danger); border-color: var(--danger);">Reject</button>
                    </div>
                </div>`;
        }).join('');
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

        // Strip any prefix
        let channelName = channelInput;
        if (channelInput.startsWith('g:')) {
            channelName = channelInput.substring(2);
        } else if (channelInput.startsWith('e:') || channelInput.startsWith('c:')) {
            channelName = channelInput.substring(2);
        }

        // Only handle geohash channels
        if (this.isValidGeohash(channelName)) {
            if (!this.channels.has(channelName)) {
                this.addChannel(channelName, channelName);
            }
            this.switchChannel(channelName, channelName);
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

        const isLight = document.body.classList.contains('light-mode');

        // Generate HSL color (adjusted for light/dark backgrounds)
        const hue = Math.abs(hash) % 360;
        const saturation = isLight ? (55 + (Math.abs(hash) % 35)) : (65 + (Math.abs(hash) % 35));
        const lightness = isLight ? (25 + (Math.abs(hash) % 20)) : (60 + (Math.abs(hash) % 25));

        // Create unique class name (include mode so it regenerates on switch)
        const modeTag = isLight ? 'l' : 'd';
        const uniqueClass = `bitchat-user-${modeTag}${Math.abs(hash) % 1000}`;

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

        // For geohash channels, use 'g:' prefix
        channelPart = `g:${this.currentGeohash || 'nym'}`;

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
        const text = `Join me in the #${channelName} channel on Nymchat - ephemeral Nostr chat`;
        const twitterUrl = `https://twitter.com/intent/tweet?text=${encodeURIComponent(text)}&url=${encodeURIComponent(url)}`;
        window.open(twitterUrl, '_blank');
    }

    shareToNostr() {
        const url = document.getElementById('shareUrlInput').value;
        const channelName = this.currentGeohash || this.currentChannel;
        const content = `Join me in the #${channelName} channel on Nymchat - ephemeral Nostr chat\n\n${url}`;

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

        // Always ensure default relays (first 5 broadcast relays) are connected
        this.ensureDefaultRelaysConnected();
    }

    // Ensure the first 5 broadcast relays are always connected regardless of channel
    async ensureDefaultRelaysConnected() {
        for (const relayUrl of this.defaultRelays) {
            const relay = this.relayPool.get(relayUrl);
            const isConnected = relay && relay.ws && relay.ws.readyState === WebSocket.OPEN;

            if (!isConnected && this.shouldRetryRelay(relayUrl)) {
                try {
                    await this.connectToRelayWithTimeout(relayUrl, 'broadcast', 3000);
                    this.subscribeToSingleRelay(relayUrl);
                    this.updateConnectionStatus();
                } catch (err) {
                    this.trackRelayFailure(relayUrl);
                }
            }
        }
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

    isReservedNick(nick) {
        const reserved = ['luxas'];
        return reserved.includes(nick.toLowerCase().replace(/#.*$/, '').trim());
    }

    verifyDeveloperNsec(nsec) {
        try {
            const secretKey = this.decodeNsec(nsec);
            const derivedPubkey = window.NostrTools.getPublicKey(secretKey);
            if (derivedPubkey === this.verifiedDeveloper.pubkey) {
                return { valid: true, secretKey, pubkey: derivedPubkey };
            }
            return { valid: false };
        } catch (e) {
            return { valid: false };
        }
    }

    applyDeveloperIdentity(secretKey, pubkey) {
        this.privkey = secretKey;
        this.pubkey = pubkey;
        this.nym = 'Luxas';
        document.getElementById('currentNym').innerHTML = this.formatNymWithPubkey(this.nym, this.pubkey);
        this.updateSidebarAvatar();
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
            // Sanitize the search term for geohash (only valid geohash chars)
            const sanitized = term.replace(/[^0-9bcdefghjkmnpqrstuvwxyz]/g, '');

            if (!sanitized) {
                resultsDiv.innerHTML = '<div class="search-create-prompt" style="color: var(--danger);">Invalid geohash. Valid characters are: 0-9, b-z (except a, i, l, o).</div>';
                return;
            }

            const isGeohash = this.isValidGeohash(sanitized);
            const exists = Array.from(this.channels.keys()).some(k => k.toLowerCase() === sanitized);

            // Clear previous results
            resultsDiv.innerHTML = '';

            // Show geohash option if valid
            if (isGeohash && !exists) {
                const location = this.getGeohashLocation(sanitized) || 'Unknown location';
                const prompt = document.createElement('div');
                prompt.className = 'search-create-prompt';
                prompt.style.cssText = 'display: flex; justify-content: space-between; align-items: center;';
                prompt.innerHTML = `
        <span>Join geohash channel "${sanitized}" (${location})</span>
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
            } else if (!isGeohash) {
                resultsDiv.innerHTML = '<div class="search-create-prompt" style="color: var(--text-dim);">Enter a valid geohash code to join a channel.</div>';
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
            this.applyColorMode();
            this.setupColorModeListener();
            this.loadBlockedUsers();
            this.loadBlockedKeywords();
            this.loadBlockedChannels();
            this.loadPinnedChannels();
            this.loadHiddenChannels();
            this.loadWallpaper();

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
                    // Clear failed relays and blacklist to allow immediate reconnection
                    this.clearRelayBlocksForReconnection();

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
                // Clear failed relays and blacklist to allow immediate reconnection
                this.clearRelayBlocksForReconnection();

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
                    // Clear failed relays and blacklist to allow immediate reconnection
                    this.clearRelayBlocksForReconnection();

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

    // Clear relay blocks (failed list, blacklist, reconnecting set) to allow fresh reconnection attempts
    clearRelayBlocksForReconnection() {
        // Clear failed relays so they can be retried immediately
        this.failedRelays.clear();

        // Clear blacklist and timestamps
        this.blacklistedRelays.clear();
        this.blacklistTimestamps.clear();

        // Clear reconnecting set to allow fresh attempts
        if (this.reconnectingRelays) {
            this.reconnectingRelays.clear();
        }

        // Reset reconnection attempt counter so we get a fresh set of attempts
        this.reconnectionAttempts = 0;
        this.isReconnecting = false;
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

            // Always ensure default relays (first 5 broadcast) are connected
            this.ensureDefaultRelaysConnected();
        }
    }

    async reconnectToBroadcastRelays() {

        let connectedCount = 0;

        // Prioritize previously connected relays for faster reconnection
        const relaysToConnect = [...this.broadcastRelays];
        if (this.previouslyConnectedRelays && this.previouslyConnectedRelays.size > 0) {
            relaysToConnect.sort((a, b) => {
                const aWasConnected = this.previouslyConnectedRelays.has(a);
                const bWasConnected = this.previouslyConnectedRelays.has(b);
                if (aWasConnected && !bWasConnected) return -1;
                if (!aWasConnected && bWasConnected) return 1;
                return 0;
            });
        }

        for (const relayUrl of relaysToConnect) {
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
            this.blacklistTimestamps.clear();
            this.isReconnecting = false;

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

            // Retry any pending DMs after network restore
            setTimeout(() => this.retryPendingDMsOnReconnect(), 3000);
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

            // Don't start monitoring during initial connection - let connectToRelays() handle it
            if (this.initialConnectionInProgress) {
                return;
            }

            // Only start if disconnected and visible
            if (!this.connected && !document.hidden) {
                this.reconnectionInterval = setInterval(() => {
                    // Skip during initial connection
                    if (this.initialConnectionInProgress) {
                        return;
                    }
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
                    // Verify the relay is actually connected (not silently skipped)
                    const relay = this.relayPool.get(relayUrl);
                    if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                        this.subscribeToSingleRelay(relayUrl);
                        connected = true;
                        break;
                    }
                } catch (err) {
                }
            }

            if (connected) {
                this.connected = true;
                this.reconnectionAttempts = 0; // Reset on success
                this.updateConnectionStatus();

                // Reconnect to other relays in background
                this.reconnectToBroadcastRelays();

                // Always ensure default relays (first 5 broadcast) are connected
                this.ensureDefaultRelaysConnected();

                // Also reconnect to geo relays if we're in a geohash channel
                if (this.currentGeohash) {
                    this.connectToGeoRelays(this.currentGeohash);
                }

                // Retry any pending DMs that haven't been delivered
                setTimeout(() => this.retryPendingDMsOnReconnect(), 2000);
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
            slapOption.innerHTML = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" style="vertical-align: middle; margin-right: 8px;"><path d="M 1 8 Q 3 4 8 4 Q 11 4 13 6 L 15 4.5 L 15 11.5 L 13 10 Q 11 12 8 12 Q 3 12 1 8 Z" fill="none" /><circle cx="5" cy="7.5" r="0.7" fill="currentColor" stroke="none" /><path d="M 9 6.5 Q 10 8 9 9.5" stroke-linecap="round" /></svg>Slap with Trout';

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
            hugOption.innerHTML = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" style="vertical-align: middle; margin-right: 8px;"><circle cx="6" cy="5" r="2" /><circle cx="10" cy="5" r="2" /><path d="M 2 14 C 2 10 4 9 6 9 C 7 9 7.5 9.5 8 10 C 8.5 9.5 9 9 10 9 C 12 9 14 10 14 14" stroke-linecap="round" stroke-linejoin="round" /><path d="M 4 11.5 Q 8 9 12 11.5" stroke-linecap="round" /></svg>Give warm Hug';

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

        // Add the click handler for hug
        hugOption.addEventListener('click', () => {
            if (this.contextMenuData) {
                this.cmdHug(this.contextMenuData.pubkey);
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

        // Populate avatar header
        const ctxAvatarImg = document.getElementById('ctxAvatarImg');
        const ctxAvatarNym = document.getElementById('ctxAvatarNym');
        if (ctxAvatarImg) {
            ctxAvatarImg.src = this.getAvatarUrl(pubkey);
            ctxAvatarImg.onerror = function () { this.onerror = null; this.src = `https://robohash.org/${pubkey}.png?set=set1&size=80x80`; };
        }
        if (ctxAvatarNym) {
            ctxAvatarNym.innerHTML = `${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>`;
        }

        // Add slap option if it doesn't exist
        let slapOption = document.getElementById('ctxSlap');
        if (!slapOption) {
            // Create slap option
            slapOption = document.createElement('div');
            slapOption.className = 'context-menu-item';
            slapOption.id = 'ctxSlap';
            slapOption.innerHTML = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.3" style="vertical-align: middle; margin-right: 8px;"><path d="M 1 8 Q 3 4 8 4 Q 11 4 13 6 L 15 4.5 L 15 11.5 L 13 10 Q 11 12 8 12 Q 3 12 1 8 Z" fill="none" /><circle cx="5" cy="7.5" r="0.7" fill="currentColor" stroke="none" /><path d="M 9 6.5 Q 10 8 9 9.5" stroke-linecap="round" /></svg>Slap with Trout';

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
            hugOption.innerHTML = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" style="vertical-align: middle; margin-right: 8px;"><circle cx="6" cy="5" r="2" /><circle cx="10" cy="5" r="2" /><path d="M 2 14 C 2 10 4 9 6 9 C 7 9 7.5 9.5 8 10 C 8.5 9.5 9 9 10 9 C 12 9 14 10 14 14" stroke-linecap="round" stroke-linejoin="round" /><path d="M 4 11.5 Q 8 9 12 11.5" stroke-linecap="round" /></svg>Give warm Hug';

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

        // Hide block option if it's your own message
        const blockOption = document.getElementById('ctxBlock');
        if (pubkey === this.pubkey) {
            blockOption.style.display = 'none';
        } else {
            blockOption.style.display = 'block';
            const blockSvg = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" style="vertical-align: middle; margin-right: 8px;"><circle cx="8" cy="8" r="6" /><line x1="3.75" y1="3.75" x2="12.25" y2="12.25" stroke-width="1.5" stroke-linecap="round" /></svg>';
blockOption.innerHTML = blockSvg + (this.blockedUsers.has(baseNym) ? 'Unblock User' : 'Block User');
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

        // Hide report option for own messages
        document.getElementById('ctxReport').style.display = pubkey === this.pubkey ? 'none' : 'block';

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
        const style = localStorage.getItem('nym_nick_style') || 'fancy';

        // Use the last 4 chars of pubkey
        const suffix = this.getPubkeySuffix(this.pubkey);

        if (style === 'simple') {
            const randomNum = Math.floor(1000 + Math.random() * 9000);
            return `nym${randomNum}#${suffix}`;
        }

        // Fancy style: adjective_noun
        const adjectives = [
            'quantum', 'neon', 'cyber', 'shadow', 'plasma',
            'echo', 'nexus', 'void', 'flux', 'ghost',
            'phantom', 'stealth', 'cryptic', 'dark', 'neural',
            'binary', 'matrix', 'digital', 'virtual', 'zero',
            'null', 'anon', 'masked', 'hidden', 'cipher',
            'enigma', 'spectral', 'rogue', 'omega', 'alpha',
            'delta', 'sigma', 'vortex', 'turbo', 'razor',
            'blade', 'frost', 'storm', 'glitch', 'pixel',
            'hyper', 'proto', 'nano', 'micro', 'ultra',
            'silent', 'feral', 'lucid', 'primal', 'astral',
            'cobalt', 'onyx', 'crimson', 'obsidian', 'iron',
            'solar', 'lunar', 'stellar', 'cosmic', 'atomic',
            'toxic', 'rogue', 'rapid', 'swift', 'fierce'
        ];

        const nouns = [
            'ghost', 'nomad', 'drift', 'pulse', 'wave',
            'spark', 'node', 'byte', 'mesh', 'link',
            'runner', 'hacker', 'coder', 'agent', 'proxy',
            'daemon', 'virus', 'worm', 'bot', 'droid',
            'reaper', 'shadow', 'wraith', 'specter', 'shade',
            'entity', 'unit', 'core', 'nexus', 'cypher',
            'breach', 'exploit', 'overflow', 'inject', 'root',
            'kernel', 'shell', 'terminal', 'console', 'script',
            'raven', 'wolf', 'viper', 'hawk', 'lynx',
            'phantom', 'signal', 'cipher', 'vector', 'forge',
            'circuit', 'photon', 'glider', 'shard', 'vault',
            'beacon', 'torrent', 'crypt', 'grid', 'orbit'
        ];

        const adj = adjectives[Math.floor(Math.random() * adjectives.length)];
        const noun = nouns[Math.floor(Math.random() * nouns.length)];

        return `${adj}_${noun}#${suffix}`;
    }

    formatNymWithPubkey(nym, pubkey) {
        // If nym already has a # suffix, wrap the existing suffix with nym-suffix class
        if (nym.includes('#')) {
            const hashIndex = nym.lastIndexOf('#');
            const baseName = nym.substring(0, hashIndex);
            const existingSuffix = nym.substring(hashIndex + 1);
            return `${baseName}<span class="nym-suffix">#${existingSuffix}</span>`;
        }

        // Get last 4 characters of pubkey
        const suffix = pubkey ? pubkey.slice(-4) : '????';
        return `${nym}<span class="nym-suffix">#${suffix}</span>`;
    }

    updateSidebarAvatar() {
        const el = document.getElementById('sidebarAvatar');
        if (el && this.pubkey) {
            const pubkey = this.pubkey;
            el.src = this.getAvatarUrl(pubkey);
            el.onerror = function () { this.onerror = null; this.src = `https://robohash.org/${pubkey}.png?set=set1&size=80x80`; };
        }
    }

    getPubkeySuffix(pubkey) {
        return pubkey ? pubkey.slice(-4) : '????';
    }

    parseNymFromDisplay(displayNym) {
        if (!displayNym) return 'anon';

        // Strip all HTML tags first, including flair
        let withoutHtml = displayNym.replace(/<[^>]*>/g, '').trim();

        // Decode HTML entities (e.g., &lt; &gt; from display formatting)
        withoutHtml = withoutHtml.replace(/&lt;/g, '').replace(/&gt;/g, '').replace(/&amp;/g, '&').replace(/&quot;/g, '"').trim();

        // Then get base nym without suffix
        const parts = withoutHtml.split('#');
        return parts[0] || withoutHtml;
    }

    async connectToRelays() {
        try {
            this.initialConnectionInProgress = true;
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
                            .then(() => {
                                // Verify actual connection before reporting success
                                const relay = this.relayPool.get(relayUrl);
                                if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                                    return relayUrl;
                                }
                                return null;
                            })
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
            const channelLabel = `#${this.currentChannel}`;
            const channelType = this.isValidGeohash(this.currentChannel) ? '(Geohash)' : '(Ephemeral)';
            document.getElementById('currentChannel').innerHTML = `${channelLabel} <span style="font-size: 12px; color: var(--text-dim);">${channelType}</span>`;


            // Start subscriptions on all connected relays
            this.subscribeToAllRelays();

            // Switch to the pinned landing channel (geohash only)
            // Reset current channel so switchChannel doesn't skip via isSameChannel check,
            // which would prevent geohash coordinates from being displayed on the landing channel
            setTimeout(() => {
                const pinned = this.pinnedLandingChannel || { type: 'geohash', geohash: 'nym' };
                this.currentChannel = '';
                this.currentGeohash = '';

                if (pinned.type === 'geohash' && pinned.geohash) {
                    this.switchChannel(pinned.geohash, pinned.geohash);
                } else {
                    this.switchChannel('nym', 'nym');
                }
            }, 100);

            // Update status to show we're connected
            this.updateConnectionStatus();
            this.displaySystemMessage(`Connected to the Nostr network via multiple relays...`);


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
        } finally {
            this.initialConnectionInProgress = false;
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

        const since1h = Math.floor(Date.now() / 1000) - 3600;

        const filters = [
            // Messages in geohash channels (past 1hr)
            {
                kinds: [20000],
                since: since1h,
                limit: 100,
            },
            // Presence broadcasts (away/online status)
            {
                kinds: [this.PRESENCE_KIND],
                since: since1h,
                limit: 100,
            },
            // Reactions for geohash channels
            {
                kinds: [7],
                "#k": ["20000"],
                since: since1h,
                limit: 100,
            },
            // Reactions for PMs
            {
                kinds: [7],
                "#k": ["1059"],
                limit: 100
            },
            // User shop items
            {
                kinds: [30078],
                "#d": ["nym-shop-active"],
                limit: 100
            },
            // Zap receipts
            {
                kinds: [9735],
                limit: 100,
            }
        ];

        if (this.pubkey) {
            filters.push(
                // Gift wraps addressed to me
                {
                    kinds: [1059],
                    "#p": [this.pubkey],
                    limit: 100,
                },
                // Any reactions with #p = my pubkey
                {
                    kinds: [7],
                    "#p": [this.pubkey],
                    limit: 100
                },
                // MY shop purchases and active items
                {
                    kinds: [30078],
                    authors: [this.pubkey],
                    "#d": ["nym-shop-purchases", "nym-shop-active"],
                    limit: 100
                },
                // Incoming transfers (shop items & settings) from other users
                {
                    kinds: [30078],
                    "#p": [this.pubkey],
                    limit: 50
                },
                // P2P signaling addressed to me
                {
                    kinds: [25051],
                    "#p": [this.pubkey],
                    since: Math.floor(Date.now() / 1000) - 120, // Last 2 minutes
                    limit: 50
                },
                // P2P file status events (unseeded notifications) for current channel
                {
                    kinds: [25052],
                    since: Math.floor(Date.now() / 1000) - 86400, // Last 24 hours
                    limit: 100
                }
            );
        }

        // Send single REQ with all filters
        ws.send(JSON.stringify(["REQ", subId, ...filters]));
    }

    // This is called when a user switches to a channel that hasn't been fully loaded
    subscribeToChannelTargeted(channelKey, channelType) {
        // Skip if already loaded
        if (this.channelLoadedFromRelays.has(channelKey)) {
            return;
        }

        // Mark as loaded to prevent duplicate requests
        this.channelLoadedFromRelays.add(channelKey);

        const subId = "nym-ch-" + Math.random().toString(36).substring(7);
        const since1h = Math.floor(Date.now() / 1000) - 3600; // 1 hour ago
        let filters = [];

        // Only geohash channels supported
        filters = [
            {
                kinds: [20000],
                "#g": [channelKey],
                since: since1h,
                limit: this.channelMessageLimit
            },
            {
                kinds: [7],
                "#k": ["20000"],
                since: since1h,
                limit: this.channelMessageLimit
            }
        ];

        if (filters.length === 0) return;

        // Send to all readable relays except nosflare
        this.relayPool.forEach((relay, url) => {
            if (relay.ws && relay.ws.readyState === WebSocket.OPEN &&
                !['wss://sendit.nosflare.com', 'wss://relay.nosflare.com'].includes(url)) {

                // Track subscription
                if (!relay.subscriptions) {
                    relay.subscriptions = new Set();
                }
                relay.subscriptions.add(subId);

                relay.ws.send(JSON.stringify(["REQ", subId, ...filters]));
            }
        });

        // Store the subscription ID for this channel
        this.channelSubscriptions.set(channelKey, subId);
    }

    // Batch multiple channel subscriptions into fewer REQs for efficiency
    subscribeToChannelBatch(channels) {
        if (!channels || channels.length === 0) return;

        // Only geohash channels
        const geohashChannels = [];
        const since1h = Math.floor(Date.now() / 1000) - 3600;

        channels.forEach(({ key, type }) => {
            // Skip already loaded channels
            if (this.channelLoadedFromRelays.has(key)) return;
            geohashChannels.push(key);
        });

        // Build batched filters
        const filters = [];

        if (geohashChannels.length > 0) {
            filters.push({
                kinds: [20000],
                "#g": geohashChannels,
                since: since1h,
                limit: this.channelMessageLimit * geohashChannels.length
            });
            // Mark as loaded
            geohashChannels.forEach(ch => this.channelLoadedFromRelays.add(ch));
        }

        if (filters.length === 0) return;

        const subId = "nym-batch-" + Math.random().toString(36).substring(7);

        // Send to all readable relays
        this.relayPool.forEach((relay, url) => {
            if (relay.ws && relay.ws.readyState === WebSocket.OPEN &&
                !['wss://sendit.nosflare.com', 'wss://relay.nosflare.com'].includes(url)) {

                if (!relay.subscriptions) {
                    relay.subscriptions = new Set();
                }
                relay.subscriptions.add(subId);

                relay.ws.send(JSON.stringify(["REQ", subId, ...filters]));
            }
        });
    }

    // Load messages for a channel from relays - called when switching channels
    loadChannelFromRelays(channelKey, channelType) {
        // Only load if we haven't already sent a targeted request
        if (this.channelLoadedFromRelays.has(channelKey)) {
            return;
        }

        // Check if we have few messages for this channel (under 50)
        const storageKey = channelType === 'geohash' ? `#${channelKey}` : channelKey;
        const currentMessages = this.messages.get(storageKey) || [];

        // If we have very few messages, send a targeted request
        if (currentMessages.length < 50) {
            this.subscribeToChannelTargeted(channelKey, channelType);
        } else {
            // Mark as loaded so we don't recheck on every channel switch
            this.channelLoadedFromRelays.add(channelKey);
        }
    }

    // Force refresh a channel from relays - used by /sync command or manual refresh
    refreshChannelFromRelays(channelKey, channelType) {
        // Remove from loaded set to allow re-fetching
        this.channelLoadedFromRelays.delete(channelKey);

        // Close existing subscription if any
        const existingSubId = this.channelSubscriptions.get(channelKey);
        if (existingSubId) {
            this.relayPool.forEach((relay, url) => {
                if (relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                    relay.ws.send(JSON.stringify(["CLOSE", existingSubId]));
                    if (relay.subscriptions) {
                        relay.subscriptions.delete(existingSubId);
                    }
                }
            });
            this.channelSubscriptions.delete(channelKey);
        }

        // Send new targeted request
        this.subscribeToChannelTargeted(channelKey, channelType);
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
                        // Still blacklisted - reject so callers know no connection was made
                        reject(new Error(`Relay ${relayUrl} is blacklisted`));
                        return;
                    }
                    // Was expired and removed, continue connecting
                }

                if (!this.shouldRetryRelay(relayUrl)) {
                    reject(new Error(`Relay ${relayUrl} should not be retried yet`));
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

                ws.onclose = (event) => {
                    clearTimeout(verificationTimeout);
                    clearTimeout(connectionTimeout);

                    // Track if this relay was previously successfully connected
                    const wasConnected = this.relayPool.has(relayUrl) &&
                        this.relayPool.get(relayUrl).ws === ws;

                    // Only blacklist on actual connection failures, not normal closes
                    const isConnectionFailure = !wasConnected && event.code !== 1000 && event.code !== 1001;

                    if (isConnectionFailure) {
                        this.blacklistedRelays.add(relayUrl);
                        this.blacklistTimestamps.set(relayUrl, Date.now());
                    }

                    // Track previously connected relays for prioritized reconnection
                    if (wasConnected) {
                        if (!this.previouslyConnectedRelays) {
                            this.previouslyConnectedRelays = new Set();
                        }
                        this.previouslyConnectedRelays.add(relayUrl);
                    }

                    // Immediately remove from pool and update status
                    this.relayPool.delete(relayUrl);
                    this.relayKinds.delete(relayUrl);

                    // Force status update after disconnect
                    this.updateConnectionStatus();

                    // Reconnect ALL relay types (broadcast, nosflare, AND read relays)
                    // For previously connected relays, always attempt reconnection (no blacklist check)
                    if (this.connected && (wasConnected || !this.blacklistedRelays.has(relayUrl))) {
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
                        // Use faster reconnection for previously connected relays
                        const attemptReconnect = (attempt = 0) => {
                            const maxAttempts = 10;
                            // Faster initial delay for previously connected relays (1s vs 5s)
                            const baseDelay = wasConnected ? 1000 : 5000;
                            const maxDelay = wasConnected ? 30000 : 60000;

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

                                            // Retry any pending DMs after relays reconnect
                                            setTimeout(() => this.retryPendingDMsOnReconnect(), 1000);
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
            // Also save globally so new sessions inherit the lightning address
            localStorage.setItem('nym_lightning_address_global', address);

            // Always save to Nostr profile (merging with existing data)
            await this.saveToNostrProfile();
        } else {
            this.lightningAddress = null;
            localStorage.removeItem(`nym_lightning_address_${this.pubkey}`);
            localStorage.removeItem('nym_lightning_address_global');
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

        // Skip kind 0 updates for the verified developer - they have their own profile data
        if (this.isVerifiedDeveloper(this.pubkey)) return;

        try {
            // Ephemeral mode - minimal profile
            const profileToSave = {
                name: this.nym,
                display_name: this.nym,
                lud16: this.lightningAddress,
                about: `Nymchat user - ${this.nym}`
            };

            // Include avatar picture if set
            const avatarUrl = this.userAvatars.get(this.pubkey);
            if (avatarUrl) {
                profileToSave.picture = avatarUrl;
            }

            const profileEvent = {
                kind: 0,
                created_at: Math.floor(Date.now() / 1000),
                tags: [],
                content: JSON.stringify(profileToSave),
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(profileEvent);

            if (signedEvent) {
                this.sendToRelay(["EVENT", signedEvent]);
            }
        } catch (error) {
        }
    }

    getAvatarUrl(pubkey) {
        // Prefer cached blob URL (instant, no network)
        const blob = this.avatarBlobCache.get(pubkey);
        if (blob) return blob;
        // Check custom avatar URL
        const custom = this.userAvatars.get(pubkey);
        if (custom) return custom;
        // Fall back to robohash
        return `https://robohash.org/${pubkey}.png?set=set1&size=80x80`;
    }

    // Fetch an avatar image and cache it as a blob object URL.
    // Deduplicates concurrent requests for the same pubkey.
    cacheAvatarImage(pubkey, url) {
        if (this.avatarBlobCache.has(pubkey)) return Promise.resolve();
        if (this.avatarBlobInflight.has(pubkey)) return this.avatarBlobInflight.get(pubkey);
        const p = fetch(url, { mode: 'cors' })
            .then(r => { if (!r.ok) throw new Error(r.status); return r.blob(); })
            .then(blob => {
                // Revoke old blob URL if avatar changed
                const old = this.avatarBlobCache.get(pubkey);
                if (old) URL.revokeObjectURL(old);
                const objectUrl = URL.createObjectURL(blob);
                this.avatarBlobCache.set(pubkey, objectUrl);
                this.updateRenderedAvatars(pubkey, objectUrl);
            })
            .catch(() => { })  // silently ignore – original URL still works as fallback
            .finally(() => { this.avatarBlobInflight.delete(pubkey); });
        this.avatarBlobInflight.set(pubkey, p);
        return p;
    }

    // Update already-rendered message avatars when a kind 0 profile picture arrives
    updateRenderedAvatars(pubkey, avatarUrl) {
        const fallback = `https://robohash.org/${pubkey}.png?set=set1&size=80x80`;
        document.querySelectorAll(`img[data-avatar-pubkey="${pubkey}"]`).forEach(img => {
            img.onerror = function () { this.onerror = null; this.src = fallback; };
            img.src = avatarUrl;
        });
        // Update context menu avatar if open for this user
        const ctxImg = document.getElementById('ctxAvatarImg');
        if (ctxImg && this.contextMenuData?.pubkey === pubkey) {
            ctxImg.onerror = function () { this.onerror = null; this.src = fallback; };
            ctxImg.src = avatarUrl;
        }
    }

    async uploadAvatar(file) {
        try {
            // Compute SHA-256 hash
            const arrayBuffer = await file.arrayBuffer();
            const hashBuffer = await crypto.subtle.digest('SHA-256', arrayBuffer);
            const hashArray = Array.from(new Uint8Array(hashBuffer));
            const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');

            // Create and sign Nostr event for blossom upload auth
            const now = Math.floor(Date.now() / 1000);
            const uploadEvent = {
                kind: 24242,
                created_at: now,
                tags: [
                    ['t', 'upload'],
                    ['x', hashHex],
                    ['expiration', String(now + 600)]
                ],
                content: 'Uploading blob with SHA-256 hash',
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(uploadEvent);
            const eventBase64 = btoa(JSON.stringify(signedEvent));

            const response = await fetch('https://blossom.band/upload', {
                method: 'PUT',
                headers: {
                    'Authorization': `Nostr ${eventBase64}`,
                    'Content-Type': file.type || 'image/png'
                },
                body: file
            });

            if (response.ok) {
                const data = await response.json();
                if (data.url) {
                    // Clear old cached blob so cacheAvatarImage will fetch the new one
                    const oldBlob = this.avatarBlobCache.get(this.pubkey);
                    if (oldBlob) URL.revokeObjectURL(oldBlob);
                    this.avatarBlobCache.delete(this.pubkey);

                    // Store locally
                    this.userAvatars.set(this.pubkey, data.url);
                    this.cacheAvatarImage(this.pubkey, data.url);

                    // Persist for auto-ephemeral reuse
                    localStorage.setItem('nym_avatar_url', data.url);

                    // Update sidebar avatar
                    this.updateSidebarAvatar();

                    // Update rendered avatars immediately
                    this.updateRenderedAvatars(this.pubkey, data.url);

                    // Update nostr profile with picture
                    await this.saveToNostrProfile();

                    // Broadcast avatar update so other users clear their cache
                    this.publishAvatarUpdate(data.url);

                    return data.url;
                }
            }
            throw new Error(`Upload failed: ${response.status}`);
        } catch (error) {
            this.displaySystemMessage('Failed to upload avatar: ' + error.message);
            return null;
        }
    }

    removeAvatar() {
        const oldBlob = this.avatarBlobCache.get(this.pubkey);
        if (oldBlob) { URL.revokeObjectURL(oldBlob); this.avatarBlobCache.delete(this.pubkey); }
        this.userAvatars.delete(this.pubkey);
        localStorage.removeItem('nym_avatar_url');
        this.updateSidebarAvatar();
        this.updateRenderedAvatars(this.pubkey, this.getAvatarUrl(this.pubkey));
        this.saveToNostrProfile();
        // Broadcast avatar removal so other users clear their cache
        this.publishAvatarUpdate('');
    }

    // Wallpaper Methods
    async uploadWallpaper(file) {
        // Validate minimum image size
        const minWidth = 1920;
        const minHeight = 1080;

        const validSize = await new Promise((resolve) => {
            const img = new Image();
            img.onload = () => {
                URL.revokeObjectURL(img.src);
                resolve(img.width >= minWidth && img.height >= minHeight);
            };
            img.onerror = () => {
                URL.revokeObjectURL(img.src);
                resolve(false);
            };
            img.src = URL.createObjectURL(file);
        });

        if (!validSize) {
            this.displaySystemMessage(`Wallpaper image must be at least ${minWidth}x${minHeight} pixels.`);
            return null;
        }

        try {
            // Compute SHA-256 hash
            const arrayBuffer = await file.arrayBuffer();
            const hashBuffer = await crypto.subtle.digest('SHA-256', arrayBuffer);
            const hashArray = Array.from(new Uint8Array(hashBuffer));
            const hashHex = hashArray.map(b => b.toString(16).padStart(2, '0')).join('');

            // Create and sign Nostr event for blossom upload auth
            const now = Math.floor(Date.now() / 1000);
            const uploadEvent = {
                kind: 24242,
                created_at: now,
                tags: [
                    ['t', 'upload'],
                    ['x', hashHex],
                    ['expiration', String(now + 600)]
                ],
                content: 'Uploading blob with SHA-256 hash',
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(uploadEvent);
            const eventBase64 = btoa(JSON.stringify(signedEvent));

            const response = await fetch('https://blossom.band/upload', {
                method: 'PUT',
                headers: {
                    'Authorization': `Nostr ${eventBase64}`,
                    'Content-Type': file.type || 'image/png'
                },
                body: file
            });

            if (response.ok) {
                const data = await response.json();
                if (data.url) {
                    return data.url;
                }
            }
            throw new Error(`Upload failed: ${response.status}`);
        } catch (error) {
            this.displaySystemMessage('Failed to upload wallpaper: ' + error.message);
            return null;
        }
    }

    applyWallpaper(type, customUrl) {
        const layer = document.getElementById('wallpaperLayer');
        if (!layer) return;

        const presets = ['geometric', 'circuit', 'dots', 'waves', 'topography', 'hexagons', 'diamonds'];

        // Remove any existing wallpaper classes and inline background-image
        presets.forEach(p => layer.classList.remove(`wallpaper-pattern-${p}`));
        layer.classList.remove('has-custom-wallpaper');
        layer.style.backgroundImage = '';

        if (type === 'none' || !type) return;

        if (presets.includes(type)) {
            layer.classList.add(`wallpaper-pattern-${type}`);
        } else if (type === 'custom' && customUrl) {
            layer.classList.add('has-custom-wallpaper');
            // Layer a semi-transparent overlay on top of the image for readability
            const isLight = document.body.classList.contains('light-mode');
            const overlay = isLight
                ? 'rgba(245, 245, 242, 0.85)'
                : 'rgba(10, 10, 15, 0.82)';
            layer.style.backgroundImage = `linear-gradient(${overlay}, ${overlay}), url('${customUrl}')`;
        }
    }

    saveWallpaper(type, customUrl) {
        localStorage.setItem('nym_wallpaper_type', type);
        if (type === 'custom' && customUrl) {
            localStorage.setItem('nym_wallpaper_custom_url', customUrl);
        } else {
            localStorage.removeItem('nym_wallpaper_custom_url');
        }
    }

    loadWallpaper() {
        const type = localStorage.getItem('nym_wallpaper_type') || 'geometric';
        const customUrl = localStorage.getItem('nym_wallpaper_custom_url') || '';
        this.applyWallpaper(type, customUrl);
        return { type, customUrl };
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

                let originalKind = '20000'; // Default geohash
                if (this.inPMMode) {
                    originalKind = '1059'; // PMs via NIP-17
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
                    if (kTag && !['20000', '1059'].includes(kTag[1])) {
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

    // Parse amount from bolt11 invoice
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

        // Capture scroll state before modifying DOM so we can auto-scroll if needed
        const container = document.getElementById('messagesContainer');
        const wasAtBottom = container && (container.scrollHeight - container.scrollTop <= container.clientHeight + 150);

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
    ${this.abbreviateNumber(totalZaps)}
`;

            const zapperCount = messageZaps.amounts.size;
            zapBadge.title = `${this.abbreviateNumber(zapperCount)} zapper${zapperCount > 1 ? 's' : ''} • ${this.abbreviateNumber(totalZaps)} sats total`;

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

        // Auto-scroll to keep zaps visible if user was already at the bottom
        if (wasAtBottom) {
            this._scheduleScrollToBottom();
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

        // Try Flutter bridge first (for Nymchat native app)
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
        // No synced settings in ephemeral-only mode
        return;

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
                        ["title", "Nymchat Settings"],
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

            // Save Nymchat-specific settings (kind 30078)
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
                pinnedLandingChannel: this.pinnedLandingChannel || { type: 'geohash', geohash: 'nym' }
            };

            const settingsEvent = {
                kind: 30078,
                created_at: Math.floor(Date.now() / 1000),
                tags: [
                    ["d", "nym-settings"],
                    ["title", "Nymchat Settings"],
                    ["encrypted"]
                ],
                content: JSON.stringify(settingsData),
                pubkey: this.pubkey
            };

            // Sign and send settings event
            let signedSettingsEvent;
            if (this.privkey) {
                signedSettingsEvent = window.NostrTools.finalizeEvent(settingsEvent, this.privkey);
            }

            if (signedSettingsEvent) {
                this.sendToRelay(["EVENT", signedSettingsEvent]);
            }

        } catch (error) {
        }
    }

    discoverChannels() {
        // Create a mixed array of geohash channels
        const allChannels = [];

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

    // Send DM events (kind 1059) with priority to bitchat's hardcoded relays
    // Ensures cross-app PM delivery by always hitting bitchat's relay set,
    // similar to how geohash channels prioritize geo-located relays
    sendDMToRelays(message) {
        const msg = JSON.stringify(message);
        const sent = new Set();

        // Priority: always send to bitchat's DM relays first
        for (const url of this.bitchatDMRelays) {
            const relay = this.relayPool.get(url);
            if (relay && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                relay.ws.send(msg);
                sent.add(url);
            }
        }

        // Then fan out to all other connected relays for maximum propagation
        this.relayPool.forEach((relay, url) => {
            if (!sent.has(url) && relay.ws && relay.ws.readyState === WebSocket.OPEN) {
                relay.ws.send(msg);
            }
        });

        return sent.size;
    }

    // Track a sent DM for retry if delivery receipt is not received
    trackPendingDM(eventId, wrappedEvents, recipientPubkey, conversationKey) {
        this.pendingDMs.set(eventId, {
            wrappedEvents, // Array of ['EVENT', wrapped] messages to re-send
            recipientPubkey,
            conversationKey,
            attempts: 0,
            lastAttempt: Date.now(),
            maxAttempts: this.dmRetryMaxAttempts
        });

        // Start the retry checker if not already running
        if (!this.dmRetryInterval) {
            this.dmRetryInterval = setInterval(() => this.retryPendingDMs(), this.dmRetryCheckMs);
        }
    }

    // Retry sending DMs that haven't received a delivery receipt
    retryPendingDMs() {
        if (this.pendingDMs.size === 0) {
            // No pending DMs, stop the interval
            if (this.dmRetryInterval) {
                clearInterval(this.dmRetryInterval);
                this.dmRetryInterval = null;
            }
            return;
        }

        const now = Date.now();

        for (const [eventId, pending] of this.pendingDMs) {
            // Check if this message has been delivered (status upgraded from 'sent')
            const msgs = this.pmMessages.get(pending.conversationKey);
            if (msgs) {
                const msg = msgs.find(m => m.id === eventId);
                if (msg && msg.deliveryStatus !== 'sent') {
                    // Delivered or read - remove from pending
                    this.pendingDMs.delete(eventId);
                    continue;
                }
            }

            // Only retry if enough time has passed since last attempt
            if (now - pending.lastAttempt < this.dmRetryCheckMs) continue;

            // Check if max attempts reached
            if (pending.attempts >= pending.maxAttempts) {
                // Mark as failed in the message list
                if (msgs) {
                    const msg = msgs.find(m => m.id === eventId);
                    if (msg && msg.deliveryStatus === 'sent') {
                        msg.deliveryStatus = 'failed';
                        // Invalidate cached DOM for this conversation since status changed
                        this.channelDOMCache.delete(pending.conversationKey);
                        // Update the UI checkmark if visible
                        if (this.inPMMode && this.currentPM === pending.recipientPubkey) {
                            const msgEl = document.querySelector(`[data-message-id="${eventId}"]`);
                            if (msgEl) {
                                let statusEl = msgEl.querySelector('.delivery-status');
                                if (statusEl) {
                                    statusEl.className = 'delivery-status failed';
                                    statusEl.title = 'Failed to deliver - click to retry';
                                    statusEl.textContent = '!';
                                    statusEl.style.cursor = 'pointer';
                                    statusEl.onclick = () => this.manualRetryDM(eventId);
                                }
                            }
                        }
                    }
                }
                this.pendingDMs.delete(eventId);
                continue;
            }

            // Retry: re-send all wrapped events to relays
            pending.attempts++;
            pending.lastAttempt = now;

            for (const wrappedMsg of pending.wrappedEvents) {
                this.sendDMToRelays(wrappedMsg);
            }
        }
    }

    // Manual retry for a failed DM (triggered by clicking the ! indicator)
    manualRetryDM(eventId) {
        const msgs = this.pmMessages.get(this.getPMConversationKey(this.currentPM));
        if (!msgs) return;
        const msg = msgs.find(m => m.id === eventId);
        if (!msg) return;

        // Re-send the original message content
        msg.deliveryStatus = 'sent';

        // Update UI immediately
        const msgEl = document.querySelector(`[data-message-id="${eventId}"]`);
        if (msgEl) {
            let statusEl = msgEl.querySelector('.delivery-status');
            if (statusEl) {
                statusEl.className = 'delivery-status sent';
                statusEl.title = 'Sent';
                statusEl.textContent = '○';
                statusEl.style.cursor = '';
                statusEl.onclick = null;
            }
        }

        // Re-send by composing a new PM to the same recipient
        this.sendNIP17PM(msg.content, msg.conversationPubkey);
    }

    // Called on relay reconnection to retry any pending DMs
    retryPendingDMsOnReconnect() {
        if (this.pendingDMs.size === 0) return;

        for (const [eventId, pending] of this.pendingDMs) {
            // Check if already delivered
            const msgs = this.pmMessages.get(pending.conversationKey);
            if (msgs) {
                const msg = msgs.find(m => m.id === eventId);
                if (msg && msg.deliveryStatus !== 'sent') {
                    this.pendingDMs.delete(eventId);
                    continue;
                }
            }

            // Re-send all wrapped events
            for (const wrappedMsg of pending.wrappedEvents) {
                this.sendDMToRelays(wrappedMsg);
            }
            pending.lastAttempt = Date.now();
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

        const wideFanout = evt && (evt.kind === 0 || evt.kind === 7 || evt.kind === 20000 || evt.kind === this.PRESENCE_KIND || evt.kind === 9734 || evt.kind === 9735 || evt.kind === 1059 || evt.kind === 25051 || evt.kind === 25052);

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

        // Send discovery subscriptions to each relay (small limits)
        readableRelays.forEach(([url, relay]) => {
            this.subscribeToSingleRelay(url);
        });

        // Also do channel discovery
        this.discoverChannels();

        // Wait 2 seconds for initial discovery to populate channels, then load full history
        setTimeout(() => {
            this.loadJoinedChannelsFromRelays();
        }, 2000);
    }

    // Pre-load messages for user-joined channels using batch subscriptions
    loadJoinedChannelsFromRelays() {
        const channelsToLoad = [];

        // Add user-joined channels
        this.userJoinedChannels.forEach(channelKey => {
            // Determine if it's a geohash or ephemeral channel
            const isGeohash = this.geohashRegex.test(channelKey);
            channelsToLoad.push({
                key: channelKey,
                type: isGeohash ? 'geohash' : 'ephemeral'
            });
        });

        // Add common channels that user might visit
        this.commonChannels.forEach(channel => {
            if (!this.channelLoadedFromRelays.has(channel)) {
                channelsToLoad.push({ key: channel, type: 'ephemeral' });
            }
        });

        // Add common geohashes
        this.commonGeohashes.forEach(geohash => {
            if (!this.channelLoadedFromRelays.has(geohash)) {
                channelsToLoad.push({ key: geohash, type: 'geohash' });
            }
        });

        // Also load current channel if not loaded
        if (this.currentChannel && !this.channelLoadedFromRelays.has(this.currentChannel)) {
            const isGeohash = this.currentGeohash && this.currentGeohash === this.currentChannel;
            channelsToLoad.push({
                key: this.currentChannel,
                type: isGeohash ? 'geohash' : 'ephemeral'
            });
        }

        // Batch load in chunks
        const batchSize = this.channelSubscriptionBatchSize;
        for (let i = 0; i < channelsToLoad.length; i += batchSize) {
            const batch = channelsToLoad.slice(i, i + batchSize);
            // Stagger batch requests to avoid overwhelming relays
            setTimeout(() => {
                this.subscribeToChannelBatch(batch);
            }, Math.floor(i / batchSize) * 500);
        }
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
                        if (kTag && ['20000', '1059'].includes(kTag[1])) {
                            relayKindTracker.add(7);
                        }
                    } else {
                        // For other kinds, add them directly
                        relayKindTracker.add(event.kind);
                    }
                }

                // Handle profile events (kind 0) for lightning addresses and avatars
                if (event && event.kind === 0) {
                    try {
                        const profile = JSON.parse(event.content);
                        const pubkey = event.pubkey;

                        if (profile.lud16 || profile.lud06) {
                            const lnAddress = profile.lud16 || profile.lud06;
                            this.userLightningAddresses.set(pubkey, lnAddress);
                            this.notifyLightningAddress(pubkey, lnAddress);
                        }

                        // Extract avatar from profile picture field
                        if (profile.picture) {
                            const prevUrl = this.userAvatars.get(pubkey);
                            if (prevUrl !== profile.picture) {
                                // Avatar URL changed — revoke old blob and re-fetch
                                const oldBlob = this.avatarBlobCache.get(pubkey);
                                if (oldBlob) { URL.revokeObjectURL(oldBlob); this.avatarBlobCache.delete(pubkey); }
                                this.userAvatars.set(pubkey, profile.picture);
                                // cacheAvatarImage will call updateRenderedAvatars with the blob URL when done
                                this.cacheAvatarImage(pubkey, profile.picture);
                                // Temporarily show the raw URL while blob is being fetched
                                this.updateRenderedAvatars(pubkey, profile.picture);
                            } else if (!this.avatarBlobCache.has(pubkey)) {
                                // Same URL but no blob cached yet — trigger fetch
                                this.userAvatars.set(pubkey, profile.picture);
                                this.cacheAvatarImage(pubkey, profile.picture);
                            }
                            // If same URL and blob already cached, do nothing — avatars are fine
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
        if (event.kind === 20000) {
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
            // For geohash channel messages (kind 20000)
            if (event.kind === 20000) {
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


        if (event.kind === 20000) {
            // Validate PoW (NIP-13)
            if (this.enablePow && !this.validatePow(event, this.powDifficulty)) {
                return;
            }

            // Handle geohash channel messages
            const nymTag = event.tags.find(t => t[0] === 'n');
            const geohashTag = event.tags.find(t => t[0] === 'g');

            // Strip any existing #suffix from n tag (bitchat includes it, Nymchat adds its own)
            const rawNym = nymTag ? nymTag[1].split('#')[0] : null;
            const nym = rawNym || this.getNymFromPubkey(event.pubkey);
            const geohash = geohashTag ? geohashTag[1] : '';

            // Track discovered geohash for potential batch loading
            if (geohash && !this.discoveredGeohashes.has(geohash)) {
                this.discoveredGeohashes.add(geohash);
            }

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

            // Fetch kind 0 profile for channel message senders we haven't seen,
            // or re-fetch if the cached profile is stale (older than 5 minutes)
            // so avatar/name changes are picked up for active users.
            if (event.pubkey !== this.pubkey) {
                const lastFetch = this.profileFetchedAt.get(event.pubkey) || 0;
                const stale = Date.now() - lastFetch > 5 * 60 * 1000;
                if (!this.userAvatars.has(event.pubkey) || stale) {
                    this.profileFetchedAt.set(event.pubkey, Date.now());
                    await this.fetchProfileDirect(event.pubkey);
                }
            }

            const message = {
                id: event.id,
                author: nym,
                pubkey: event.pubkey,
                content: event.content,
                timestamp: new Date(Math.min(event.created_at * 1000, Date.now())),
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
                this.updateUserPresence(nym, event.pubkey, message.channel, geohash, event.created_at);

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
                                        const auth = msg.querySelector('.message-author');
                                        if (auth) auth.classList.add('cosmetic-redacted');

                                        // Apply redacted effect to message content after 10 seconds
                                        const contentEl = msg.querySelector('.message-content');
                                        if (contentEl && !contentEl.classList.contains('cosmetic-redacted-message')) {
                                            setTimeout(() => {
                                                contentEl.classList.add('cosmetic-redacted-message');
                                                contentEl.textContent = '';
                                            }, 10000);
                                        }
                                    }
                                });
                            }

                            // Update flair badge in author element
                            const authorEl = msg.querySelector('.message-author');
                            if (authorEl) {
                                const existingFlair = authorEl.querySelector('.flair-badge');
                                if (existingFlair) existingFlair.remove();
                                if (normalized.flair) {
                                    const flairItem = this.getShopItemById(normalized.flair);
                                    if (flairItem) {
                                        const flairSpan = document.createElement('span');
                                        flairSpan.className = `flair-badge ${normalized.flair}`;
                                        flairSpan.innerHTML = flairItem.icon;
                                        // Insert flair after nym-suffix, before colon/supporter
                                        const suffix = authorEl.querySelector('.nym-suffix');
                                        if (suffix) {
                                            suffix.after(flairSpan);
                                        }
                                    }
                                }

                                // Update supporter badge
                                const existingSupporter = authorEl.querySelector('.supporter-badge');
                                if (existingSupporter) existingSupporter.remove();
                                if (normalized.supporter) {
                                    const badge = document.createElement('span');
                                    badge.className = 'supporter-badge';
                                    badge.innerHTML = '<span class="supporter-badge-icon">\u{1F3C6}</span><span class="supporter-badge-text">Supporter</span>';
                                    // Insert before the colon at the end
                                    authorEl.insertBefore(badge, authorEl.lastChild);
                                }
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

                    if (data.supporterActive !== undefined) {
                        this.supporterBadgeActive = data.supporterActive;
                        localStorage.setItem('nym_supporter_active', this.supporterBadgeActive ? 'true' : 'false');
                    }

                    // Cache purchases locally for persistence across ephemeral sessions
                    this._cachePurchases();

                    // After loading, broadcast our current active items so others see it
                    this.publishActiveShopItems();

                    // Apply to our messages immediately
                    this.applyShopStylesToOwnMessages();

                } catch (error) {
                }
            }

            // Shop item transfers (from another user to us)
            if (dTag[1]?.startsWith('nym-shop-transfer-') && event.pubkey !== this.pubkey) {
                this.handleShopTransferEvent(event);
            }

            // Settings transfers (from another user to us)
            if (dTag[1]?.startsWith('nym-settings-transfer-') && event.pubkey !== this.pubkey) {
                this.handleSettingsTransferEvent(event);
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
            // Handle profile events (kind 0) for lightning addresses and avatars
            try {
                const profile = JSON.parse(event.content);
                const pubkey = event.pubkey;

                // Store lightning address if present
                if (profile.lud16 || profile.lud06) {
                    const lnAddress = profile.lud16 || profile.lud06;
                    this.userLightningAddresses.set(pubkey, lnAddress);
                    this.notifyLightningAddress(pubkey, lnAddress);
                }

                // Extract avatar from profile picture field
                if (profile.picture) {
                    const prevUrl = this.userAvatars.get(pubkey);
                    if (prevUrl !== profile.picture) {
                        const oldBlob = this.avatarBlobCache.get(pubkey);
                        if (oldBlob) { URL.revokeObjectURL(oldBlob); this.avatarBlobCache.delete(pubkey); }
                        this.userAvatars.set(pubkey, profile.picture);
                        this.cacheAvatarImage(pubkey, profile.picture);
                        this.updateRenderedAvatars(pubkey, profile.picture);
                    } else if (!this.avatarBlobCache.has(pubkey)) {
                        this.userAvatars.set(pubkey, profile.picture);
                        this.cacheAvatarImage(pubkey, profile.picture);
                    }
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
        } else if (event.kind === this.P2P_FILE_STATUS_KIND) {
            // Handle P2P file status events (unseeded notifications)
            this.handleP2PFileStatusEvent(event);
        } else if (event.kind === this.PRESENCE_KIND) {
            // Handle presence broadcasts (away/online status)
            this.handlePresenceEvent(event);
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

        // Block non-nym client messages
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
        if (kTag && !['20000', '1059'].includes(kTag[1])) {
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

        // Capture scroll state before modifying DOM so we can auto-scroll if needed
        const container = document.getElementById('messagesContainer');
        const wasAtBottom = container && (container.scrollHeight - container.scrollTop <= container.clientHeight + 150);

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

            badge.innerHTML = `${emoji} ${this.abbreviateNumber(reactors.size)}`;

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

            // Long-press to show reactors modal
            let longPressTimer = null;
            let didLongPress = false;

            const startLongPress = (e) => {
                didLongPress = false;
                longPressTimer = setTimeout(() => {
                    didLongPress = true;
                    e.preventDefault();
                    this.showReactorsModal(messageId, emoji, badge);
                }, 500);
            };

            const cancelLongPress = () => {
                if (longPressTimer) {
                    clearTimeout(longPressTimer);
                    longPressTimer = null;
                }
            };

            badge.addEventListener('mousedown', startLongPress);
            badge.addEventListener('touchstart', startLongPress, { passive: false });
            badge.addEventListener('mouseup', cancelLongPress);
            badge.addEventListener('mouseleave', cancelLongPress);
            badge.addEventListener('touchend', cancelLongPress);
            badge.addEventListener('touchmove', cancelLongPress);

            // Click handler - only fire if not a long press
            badge.onclick = async (e) => {
                e.stopPropagation();
                if (didLongPress) return;
                if (!hasReacted) {
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

        // Auto-scroll to keep reactions visible if user was already at the bottom
        if (wasAtBottom) {
            this._scheduleScrollToBottom();
        }
    }

    showReactorsModal(messageId, emoji, badge) {
        // Close any existing reactors modal
        this.closeReactorsModal();

        const reactions = this.reactions.get(messageId);
        if (!reactions) return;
        const reactors = reactions.get(emoji);
        if (!reactors || reactors.size === 0) return;

        // Build user list
        const userItems = Array.from(reactors.entries()).map(([pubkey, nym]) => {
            const isYou = pubkey === this.pubkey;
            const baseNym = this.parseNymFromDisplay(nym);
            const suffix = this.getPubkeySuffix(pubkey);
            return `<div class="reactors-modal-user" data-pubkey="${pubkey}">
                <span class="reactors-modal-nym">${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span></span>
                ${isYou ? '<span class="reactors-modal-you">you</span>' : ''}
            </div>`;
        }).join('');

        const modal = document.createElement('div');
        modal.className = 'reactors-modal';
        modal.innerHTML = `
            <div class="reactors-modal-header">${emoji} <span class="reactors-modal-count">${reactors.size}</span></div>
            <div class="reactors-modal-list">${userItems}</div>
        `;

        document.body.appendChild(modal);
        this.reactorsModal = modal;

        // Position near the badge
        const rect = badge.getBoundingClientRect();
        const modalRect = modal.getBoundingClientRect();
        const spaceAbove = rect.top;
        const spaceBelow = window.innerHeight - rect.bottom;

        // Horizontal: align left edge with badge, but keep within viewport
        let left = rect.left;
        if (left + modalRect.width > window.innerWidth - 10) {
            left = window.innerWidth - modalRect.width - 10;
        }
        if (left < 10) left = 10;
        modal.style.left = left + 'px';

        // Vertical: prefer above, fall back to below
        if (spaceAbove > modalRect.height + 10) {
            modal.style.bottom = (window.innerHeight - rect.top + 6) + 'px';
        } else {
            modal.style.top = (rect.bottom + 6) + 'px';
        }

        // Click user row to open PM
        modal.querySelectorAll('.reactors-modal-user').forEach(el => {
            el.addEventListener('click', (e) => {
                const pubkey = el.dataset.pubkey;
                if (pubkey !== this.pubkey) {
                    const user = this.users.get(pubkey);
                    const baseNym = user ? this.parseNymFromDisplay(user.nym) : `anon`;
                    this.openUserPM(baseNym, pubkey);
                }
                this.closeReactorsModal();
            });
        });
    }

    closeReactorsModal() {
        if (this.reactorsModal) {
            this.reactorsModal.remove();
            this.reactorsModal = null;
        }
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

            // Infer original kind from message context
            let originalKind = '20000'; // default to geohash channel
            if (messageEl.classList.contains('pm')) {
                originalKind = '1059'; // NIP-17 gift wrap
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
        // Randomize timestamp by ±2 hours for NIP-59 metadata protection
        // Previously ±2 days, but bitchat only looks back 24 hours for DMs
        // so large offsets caused messages to fall outside its subscription window
        const TWO_HOURS = 2 * 60 * 60;
        return Math.round(Date.now() / 1000 - Math.random() * TWO_HOURS);
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
        this.sendDMToRelays(['EVENT', wrapped]);
    }

    // Nymchat receipt types: 'delivered' or 'read'
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
        this.sendDMToRelays(['EVENT', wrapped]);
    }

    // Check if a rumor is a Nymchat receipt
    isNymReceipt(rumor) {
        if (!rumor || !rumor.tags) return false;
        return rumor.tags.some(t => Array.isArray(t) && t[0] === 'receipt' && (t[1] === 'delivered' || t[1] === 'read'));
    }

    // Extract receipt info from a Nymchat receipt rumor
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

    // Check if a rumor is a Nymchat message (has 'x' tag for message ID)
    isNymMessage(rumor) {
        if (!rumor || !rumor.tags) return false;
        return rumor.tags.some(t => Array.isArray(t) && t[0] === 'x' && t[1] && !this.isNymReceipt(rumor));
    }

    // Extract Nymchat message ID from rumor
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

        // Generate message ID for delivery receipts (Nymchat format)
        const nymMessageId = this.generateUUID();

        const rumor = {
            kind: 14,
            created_at: now,
            tags: [
                ['p', recipientPubkey],
                ['x', nymMessageId]  // Nymchat message ID for delivery receipts
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
            const isKnownBitchat = this.bitchatUsers.has(recipientPubkey);
            const isKnownNym = this.nymUsers.has(recipientPubkey);
            const isUnknownPeer = !isKnownBitchat && !isKnownNym;
            let wrapped;
            let bitchatMessageId = null;
            const sentWrappedEvents = []; // Track wrapped events for retry

            // For known bitchat users OR unknown peers, send bitchat-format wrap
            // This ensures bitchat app users can always decrypt our messages
            if (isKnownBitchat || isUnknownPeer) {
                const encoded = this.encodeBitchatMessage(content, recipientPubkey);
                bitchatMessageId = encoded.messageId;

                const bitchatRumor = {
                    kind: 14,
                    created_at: now,
                    tags: [],  // Bitchat uses empty tags in rumor!
                    content: encoded.content,
                    pubkey: this.pubkey
                };
                const bitchatWrapped = this.bitchatWrapEvent(bitchatRumor, this.privkey, recipientPubkey, expirationTs);
                this.sendDMToRelays(['EVENT', bitchatWrapped]);
                sentWrappedEvents.push(['EVENT', bitchatWrapped]);
                wrapped = bitchatWrapped;

                // Schedule deletion if redacted cosmetic is active
                if (this.activeCosmetics && this.activeCosmetics.has('cosmetic-redacted')) {
                    setTimeout(() => { this.publishDeletionEvent(bitchatWrapped.id); }, 600000);
                }
            }

            // For known nymchat users OR unknown peers, send nymchat-format wrap
            // Unknown peers get BOTH formats so either app can decrypt
            if (isKnownNym || isUnknownPeer) {
                const nymWrapped = this.nip59WrapEvent(rumor, this.privkey, recipientPubkey, expirationTs);
                this.sendDMToRelays(['EVENT', nymWrapped]);
                sentWrappedEvents.push(['EVENT', nymWrapped]);
                wrapped = nymWrapped;

                // Schedule deletion if redacted cosmetic is active
                if (this.activeCosmetics && this.activeCosmetics.has('cosmetic-redacted')) {
                    setTimeout(() => { this.publishDeletionEvent(nymWrapped.id); }, 600000);
                }
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
                nymMessageId: isKnownBitchat ? null : nymMessageId,  // For tracking Nymchat delivery/read receipts
                deliveryStatus: 'sent'  // sent -> delivered -> read
            });
            // Cap PM conversations at 100 messages
            const sentPmList = this.pmMessages.get(conversationKey);
            if (sentPmList && sentPmList.length > 100) {
                this.pmMessages.set(conversationKey, sentPmList.slice(-100));
            }

            // Track for automatic retry if delivery receipt not received
            this.trackPendingDM(wrapped.id, sentWrappedEvents, recipientPubkey, conversationKey);

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

            const sentWrappedEvents = [['EVENT', wrapped]];
            this.sendDMToRelays(['EVENT', wrapped]);

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
                nymMessageId,  // For tracking Nymchat delivery/read receipts
                deliveryStatus: 'sent'  // sent -> delivered -> read
            });
            // Cap PM conversations at 100 messages
            const sentPmList2 = this.pmMessages.get(conversationKey);
            if (sentPmList2 && sentPmList2.length > 100) {
                this.pmMessages.set(conversationKey, sentPmList2.slice(-100));
            }

            // Track for automatic retry if delivery receipt not received
            this.trackPendingDM(wrapped.id, sentWrappedEvents, recipientPubkey, conversationKey);

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
            // Accept kind 14 (DM), kind 15 (file), and kind 69420 (Nymchat receipt)
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

            // Track if this user uses Nymchat format with delivery receipts (has 'x' tag)
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

            // Handle Nymchat delivery/read receipts (tag-based format)
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
                                // Remove from pending retry queue since delivery confirmed
                                this.pendingDMs.delete(msg.id);
                                // Invalidate cached DOM for this conversation since status changed
                                this.channelDOMCache.delete(convKey);
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
                                // Remove from pending retry queue since delivery confirmed
                                this.pendingDMs.delete(msg.id);
                                // Invalidate cached DOM for this conversation since status changed
                                this.channelDOMCache.delete(convKey);
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

            // Content-based dedup for dual-wrapped messages: when nymchat sends
            // both bitchat + nymchat format to unknown peers, the recipient may
            // decrypt both. Deduplicate by sender + content + close timestamp.
            if (list.some(m => m.pubkey === senderPubkey && m.content === messageContent && Math.abs((m.timestamp?.getTime() / 1000 || 0) - tsSec) < 5)) return;

            // Silently drop channel invitations for blocked channels
            if (messageContent && messageContent.includes('Channel Invitation:')) {
                const inviteMatch = messageContent.match(/join\s+#([a-z0-9]+)/i);
                if (inviteMatch) {
                    const invitedChannel = inviteMatch[1];
                    if (this.isChannelBlocked(invitedChannel, invitedChannel)) {
                        return;
                    }
                }
            }

            // Get sender name from kind 0 profile (not from rumor tags)
            const senderName = this.getNymFromPubkey(senderPubkey);

            // Extract Nymchat message ID from rumor tags
            const nymMsgId = this.getNymMessageId(rumor);

            const msg = {
                id: event.id,                                  // keep outer id for reactions/zaps
                author: isOwn ? this.nym : senderName,
                pubkey: senderPubkey,
                content: messageContent,
                timestamp: new Date(Math.min(tsSec * 1000, Date.now())),
                isOwn,
                isPM: true,
                conversationKey,
                conversationPubkey: peerPubkey,
                eventKind: 1059,
                isHistorical: (Date.now() / 1000 - tsSec) > 10,
                bitchatMessageId: parsed.messageId,  // For sending Bitchat read receipts
                nymMessageId: nymMsgId  // For sending Nymchat read receipts
            };

            list.push(msg);
            list.sort((a, b) => a.timestamp - b.timestamp);
            // Cap PM conversations at 100 messages to prevent memory bloat
            if (list.length > 100) {
                list = list.slice(-100);
            }
            this.pmMessages.set(conversationKey, list);

            // Send DELIVERED receipt back to Bitchat user
            if (!isOwn && parsed.messageId && this.bitchatUsers.has(senderPubkey)) {
                this.sendBitchatReceipt(parsed.messageId, 0x03, senderPubkey); // 0x03 = DELIVERED
            }

            // Send DELIVERED receipt back to Nymchat user
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
                // Send READ receipt for Nymchat users
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
            // Store the failed message in pmMessages so it persists across navigation
            const conversationKey = this.getPMConversationKey(recipientPubkey);
            if (!this.pmMessages.has(conversationKey)) this.pmMessages.set(conversationKey, []);
            const failedId = 'failed-' + Date.now() + '-' + Math.random().toString(36).slice(2, 8);
            const failedMsg = {
                id: failedId,
                author: this.nym,
                pubkey: this.pubkey,
                content,
                timestamp: new Date(),
                isOwn: true,
                isPM: true,
                conversationKey,
                conversationPubkey: recipientPubkey,
                eventKind: 1059,
                deliveryStatus: 'failed'
            };
            this.pmMessages.get(conversationKey).push(failedMsg);
            // Invalidate cached DOM for this conversation
            this.channelDOMCache.delete(conversationKey);
            // Display the failed message if currently viewing this PM
            if (this.inPMMode && this.currentPM === recipientPubkey) {
                this.displayMessage(failedMsg);
            }
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

            // Re-apply search filter if search is active
            const searchInput = document.getElementById('pmSearch');
            if (searchInput && searchInput.value.trim().length > 0) {
                const term = searchInput.value.toLowerCase();
                const pmName = pmItem.querySelector('.pm-name').textContent.toLowerCase();
                if (!pmName.includes(term)) {
                    pmItem.style.display = 'none';
                    pmItem.classList.add('search-hidden');
                }
            }
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

        // Re-apply search filter if search is active
        const searchInput = document.getElementById('pmSearch');
        if (searchInput && searchInput.value.trim().length > 0) {
            this.filterPMs(searchInput.value);
        }
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
        const avatarSrc = this.getAvatarUrl(pubkey);
        document.querySelectorAll(`.message[data-pubkey="${pubkey}"] .message-author`).forEach(el => {
            el.innerHTML = `<img src="${this.escapeHtml(avatarSrc)}" class="avatar-message" data-avatar-pubkey="${pubkey}" alt="" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${pubkey}.png?set=set1&size=80x80'">&lt;${this.escapeHtml(clean)}<span class="nym-suffix">#${suffix}</span>${flairHtml}${verifiedBadge}&gt;`;
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

            const pmAvatarSrc = this.getAvatarUrl(pubkey);
            item.innerHTML = `
<img src="${this.escapeHtml(pmAvatarSrc)}" class="avatar-pm" alt="" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${pubkey}.png?set=set1&size=80x80'">
<span class="pm-name">@${this.escapeHtml(cleanBaseNym)}<span class="nym-suffix">#${suffix}</span>${flairHtml} ${verifiedBadge}</span>
<div class="channel-badges">
<span class="delete-pm" onclick="event.stopPropagation(); nym.deletePM('${pubkey}')">✕</span>
<span class="unread-badge" style="display:none">0</span>
</div>
`;
            item.onclick = () => this.openPM(cleanBaseNym, pubkey);

            this.insertPMInOrder(item, pmList);

            // Hide new item if it doesn't match active search filter
            const searchInput = document.getElementById('pmSearch');
            if (searchInput && searchInput.value.trim().length > 0) {
                const term = searchInput.value.toLowerCase();
                const pmName = item.querySelector('.pm-name').textContent.toLowerCase();
                if (!pmName.includes(term)) {
                    item.style.display = 'none';
                    item.classList.add('search-hidden');
                }
            }

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
                this.switchChannel('nym', 'nym');
            }

            this.displaySystemMessage('PM conversation deleted');
        }
    }

    openPM(nym, pubkey) {
        this.inPMMode = true;
        this.currentPM = pubkey;
        this.currentChannel = null;
        this.currentGeohash = null;
        this.userScrolledUp = false;

        // Format the nym with pubkey suffix for display
        const known = this.users.get(pubkey);
        const baseNym = known ? this.parseNymFromDisplay(known.nym) : this.parseNymFromDisplay(nym);
        const suffix = this.getPubkeySuffix(pubkey);
        const pmAvatarSrc = this.getAvatarUrl(pubkey);
        const displayNym = `${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>`;
        const pmHeaderHtml = `<img src="${this.escapeHtml(pmAvatarSrc)}" class="avatar-message" data-avatar-pubkey="${pubkey}" alt="" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${pubkey}.png?set=set1&size=80x80'">@${displayNym} <span style="font-size: 12px; color: var(--text-dim);">(PM)</span>`;

        // Update UI with formatted nym
        document.getElementById('currentChannel').innerHTML = pmHeaderHtml;
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
                // Send Nymchat READ receipt if applicable
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

        // Skip reload if already viewing this PM conversation
        if (container.dataset.lastChannel === conversationKey) {
            return;
        }

        // Cache current channel/PM DOM before switching
        this.cacheCurrentContainerDOM();
        container.dataset.lastChannel = conversationKey;

        // Try to restore from DOM cache if messages haven't changed
        const pmMessages = this.pmMessages.get(conversationKey) || [];
        const cached = this.channelDOMCache.get(conversationKey);
        const currentFingerprint = this._computeMessageFingerprint(pmMessages);

        if (cached && cached.messageCount === pmMessages.length &&
            cached.messageFingerprint === currentFingerprint) {
            // Message count unchanged, restore cached DOM instantly
            container.innerHTML = '';
            container.appendChild(cached.fragment);
            this.channelDOMCache.delete(conversationKey);

            // Restore virtual scroll state
            this.virtualScroll.currentStartIndex = cached.virtualScrollState.currentStartIndex;
            this.virtualScroll.currentEndIndex = cached.virtualScrollState.currentEndIndex;

            // Re-init virtual scroll handler (isPM = true)
            container.dataset.virtualScrollKey = conversationKey;
            container.dataset.virtualScrollIsPM = 'true';

            // Scroll to bottom
            if (this.settings.autoscroll) {
                this._suppressInputButtonHide = true;
                setTimeout(() => {
                    container.scrollTop = container.scrollHeight;
                    setTimeout(() => {
                        this._suppressInputButtonHide = false;
                    }, 300);
                }, 0);
            }
            return;
        }

        // Cache miss or stale (new messages arrived) - render fresh
        this.channelDOMCache.delete(conversationKey);

        // Get filtered messages
        const filteredMessages = this.getFilteredPMMessages(conversationKey);

        if (filteredMessages.length === 0) {
            container.innerHTML = '';
            this.displaySystemMessage('Start of private message');
            return;
        }

        // Use virtual scrolling for efficient rendering (isPM = true)
        this.renderMessagesWithVirtualScroll(container, conversationKey, true, true);
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

        // Escape special regex characters in the nym
        const escapedNym = cleanNym.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

        // Create pattern that matches the clean nym with optional suffix
        const nymPattern = new RegExp(`@${escapedNym}(#[0-9a-f]{4})?(?:\\b|$)`, 'gi');

        // Strip HTML from content and deduplicate suffixes for mention detection
        let cleanContent = content.replace(/<[^>]*>/g, '');
        cleanContent = cleanContent.replace(/@([^@#\s]+)#([0-9a-f]{4})#\2\b/gi, '@$1#$2');

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

    async signEvent(event) {
        if (this.privkey) {
            return window.NostrTools.finalizeEvent(event, this.privkey);
        } else {
            throw new Error('No signing method available');
        }
    }

    async publishDeletionEvent(messageId) {
        try {
            const event = {
                kind: 5,
                created_at: Math.floor(Date.now() / 1000),
                tags: [['e', messageId]],
                content: '',
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(event);
            this.sendToRelay(['EVENT', signedEvent]);

            // Remove message from DOM
            const messageEl = document.querySelector(`[data-message-id="${messageId}"]`);
            if (messageEl) {
                messageEl.remove();
            }

            // Remove message from stored messages
            this.messages.forEach((msgs, channel) => {
                const idx = msgs.findIndex(m => m.id === messageId);
                if (idx !== -1) {
                    msgs.splice(idx, 1);
                }
            });
        } catch (error) {
            this.displaySystemMessage('Failed to delete message: ' + error.message);
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


                        // Get name for own profile
                        if (event.pubkey === this.pubkey && (profile.name || profile.username || profile.display_name)) {
                            const profileName = profile.name || profile.username || profile.display_name;
                            this.nym = profileName.substring(0, 20);
                            document.getElementById('currentNym').innerHTML = this.formatNymWithPubkey(this.nym, this.pubkey);
                            this.updateSidebarAvatar();
                        }

                        // Extract avatar from profile picture field
                        if (profile.picture) {
                            const prevUrl = this.userAvatars.get(event.pubkey);
                            if (prevUrl !== profile.picture) {
                                const oldBlob = this.avatarBlobCache.get(event.pubkey);
                                if (oldBlob) { URL.revokeObjectURL(oldBlob); this.avatarBlobCache.delete(event.pubkey); }
                                this.userAvatars.set(event.pubkey, profile.picture);
                                this.cacheAvatarImage(event.pubkey, profile.picture);
                                this.updateRenderedAvatars(event.pubkey, profile.picture);
                            } else if (!this.avatarBlobCache.has(event.pubkey)) {
                                this.userAvatars.set(event.pubkey, profile.picture);
                                this.cacheAvatarImage(event.pubkey, profile.picture);
                            }
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

            const now = Math.floor(Date.now() / 1000);
            const tags = [
                ['n', this.nym]
            ];

            const kind = 20000; // Geohash channels use kind 20000
            tags.push(['g', geohash || 'nym']);
            tags.push(['expiration', String(now + 3600)]); // Expire after 1 hour

            let event = {
                kind: kind,
                created_at: now,
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


    async publishPresence(status, awayMessage = '') {
        try {
            if (!this.connected) return;

            const tags = [
                ['n', this.nym],
                ['status', status]
            ];
            if (status === 'away' && awayMessage) {
                tags.push(['away', awayMessage]);
            }

            let event = {
                kind: this.PRESENCE_KIND,
                created_at: Math.floor(Date.now() / 1000),
                tags: tags,
                content: '',
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(event);
            this.sendToRelay(["EVENT", signedEvent]);
        } catch (error) {
            // Silently fail - presence is best-effort
        }
    }

    async publishAvatarUpdate(avatarUrl) {
        try {
            if (!this.connected) return;

            const tags = [
                ['n', this.nym],
                ['status', 'online'],
                ['avatar-update', avatarUrl]
            ];

            let event = {
                kind: this.PRESENCE_KIND,
                created_at: Math.floor(Date.now() / 1000),
                tags: tags,
                content: '',
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(event);
            this.sendToRelay(["EVENT", signedEvent]);
        } catch (error) {
            // Silently fail - avatar update broadcast is best-effort
        }
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
            const now = Math.floor(Date.now() / 1000);
            const uploadEvent = {
                kind: 24242,
                created_at: now,
                tags: [
                    ['t', 'upload'],
                    ['x', hashHex],
                    ['expiration', String(now + 600)] // 10 minutes from now
                ],
                content: 'Uploading blob with SHA-256 hash',
                pubkey: this.pubkey
            };

            const signedEvent = await this.signEvent(uploadEvent);

            progressFill.style.width = '60%';

            // Convert signed event to base64
            const eventString = JSON.stringify(signedEvent);
            const eventBase64 = btoa(eventString);

            progressFill.style.width = '80%';

            // Upload to blossom.band
            const response = await fetch('https://blossom.band/upload', {
                method: 'PUT',
                headers: {
                    'Authorization': `Nostr ${eventBase64}`,
                    'Content-Type': file.type || 'application/octet-stream'
                },
                body: file
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

        // Close any existing signaling subscriptions
        this.p2pSignalingSubscriptions.forEach(subId => {
            this.sendToRelay(['CLOSE', subId]);
        });
        this.p2pSignalingSubscriptions.clear();

        const subId = 'p2p-sig-' + Math.random().toString(36).substring(2, 10);
        const filter = {
            kinds: [this.P2P_SIGNALING_KIND],
            '#p': [this.pubkey],
            since: Math.floor(Date.now() / 1000) - 120 // Last 2 minutes for relay propagation delay
        };

        this.sendToRelay(['REQ', subId, filter]);
        this.p2pSignalingSubscriptions.add(subId);

        // Reinitialize periodically to keep subscription fresh
        if (this._p2pSignalingInterval) clearInterval(this._p2pSignalingInterval);
        this._p2pSignalingInterval = setInterval(() => {
            if (this.connected && this.pubkey) {
                this.p2pSignalingSubscriptions.forEach(subId => {
                    this.sendToRelay(['CLOSE', subId]);
                });
                this.p2pSignalingSubscriptions.clear();

                const newSubId = 'p2p-sig-' + Math.random().toString(36).substring(2, 10);
                const newFilter = {
                    kinds: [this.P2P_SIGNALING_KIND],
                    '#p': [this.pubkey],
                    since: Math.floor(Date.now() / 1000) - 120
                };
                this.sendToRelay(['REQ', newSubId, newFilter]);
                this.p2pSignalingSubscriptions.add(newSubId);
            }
        }, 60000); // Refresh every 60 seconds
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

    // Handle P2P file status events (e.g., unseeded notifications)
    handleP2PFileStatusEvent(event) {
        try {
            const data = JSON.parse(event.content);
            if (data.status === 'unseeded' && data.offerId) {
                this.p2pUnseededOffers.add(data.offerId);
                // Update UI to show file is no longer available
                this.updateFileOfferUI(data.offerId, 'unseeded');
            }
        } catch (e) {
            // Try tag-based approach
            const offerIdTag = event.tags.find(t => t[0] === 'offer_id');
            const statusTag = event.tags.find(t => t[0] === 'status');
            if (offerIdTag && statusTag && statusTag[1] === 'unseeded') {
                this.p2pUnseededOffers.add(offerIdTag[1]);
                this.updateFileOfferUI(offerIdTag[1], 'unseeded');
            }
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

        const now = Math.floor(Date.now() / 1000);

        if (this.currentGeohash) {
            kind = 20000; // Geohash channel kind
            tags.push(['g', this.currentGeohash]);
        } else {
            this.displaySystemMessage('No channel selected for file sharing');
            return;
        }

        tags.push(['expiration', String(now + 3600)]); // Expire after 1 hour

        // Create and sign the file offer event
        const event = {
            kind: kind,
            created_at: now,
            tags: tags,
            content: `Sharing file through Nymchat: ${file.name} (${this.formatFileSize(file.size)})`,
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
            channel: this.currentChannel,
            geohash: this.currentGeohash || '',
            isOwn: true,
            isHistorical: false,
            isFileOffer: true,
            fileOffer: fileOffer
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

        if (this.p2pUnseededOffers.has(offerId)) {
            this.displaySystemMessage('This file is no longer being seeded by the owner');
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

        // Trickle ICE candidates to the peer
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
            if (pc.iceConnectionState === 'failed') {
                if (transfer) {
                    this.updateTransferStatus(transferId, 'error', 'Connection failed - peer may be offline');
                }
                this.cleanupP2PConnection(connectionId, transferId);
            } else if (pc.iceConnectionState === 'disconnected') {
                // Give it a moment to recover before declaring error
                setTimeout(() => {
                    if (pc.iceConnectionState === 'disconnected' || pc.iceConnectionState === 'failed') {
                        if (transfer && transfer.status !== 'complete') {
                            this.updateTransferStatus(transferId, 'error', 'Connection lost');
                        }
                        this.cleanupP2PConnection(connectionId, transferId);
                    }
                }, 5000);
            } else if (pc.iceConnectionState === 'connected') {
                if (transfer) transfer.status = 'transferring';
            }
        };

        // Connection timeout - 30 seconds to establish
        const connectionTimeout = setTimeout(() => {
            const transfer = this.p2pActiveTransfers.get(transferId);
            if (transfer && transfer.status === 'connecting') {
                this.updateTransferStatus(transferId, 'error', 'Connection timed out - peer may be offline');
                this.cleanupP2PConnection(connectionId, transferId);
            }
        }, 30000);

        // Clear timeout when connected
        const origOnIceChange = pc.oniceconnectionstatechange;
        pc.oniceconnectionstatechange = (e) => {
            if (pc.iceConnectionState === 'connected' || pc.iceConnectionState === 'completed') {
                clearTimeout(connectionTimeout);
            }
            origOnIceChange.call(this, e);
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

    // Cleanup a P2P connection and associated resources
    cleanupP2PConnection(connectionId, transferId) {
        const pc = this.p2pConnections.get(connectionId);
        if (pc) {
            try { pc.close(); } catch (e) { /* ignore */ }
            this.p2pConnections.delete(connectionId);
        }
        const dc = this.p2pDataChannels.get(connectionId);
        if (dc) {
            try { dc.close(); } catch (e) { /* ignore */ }
            this.p2pDataChannels.delete(connectionId);
        }
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
            try {
                dataChannel.send(JSON.stringify({ type: 'error', message: 'File no longer available' }));
            } catch (e) { /* channel may be closed */ }
            this.updateTransferStatus(transferId, 'error', 'File no longer available');
            return;
        }

        // Send file metadata first as JSON string
        dataChannel.send(JSON.stringify({
            type: 'metadata',
            name: file.name,
            size: file.size,
            mimeType: file.type
        }));

        // Small delay to ensure metadata is received before binary data
        await new Promise(resolve => setTimeout(resolve, 50));

        // Read and send file in chunks
        const chunkSize = this.P2P_CHUNK_SIZE;
        let offset = 0;

        const sendNextChunk = async () => {
            if (dataChannel.readyState !== 'open') {
                this.updateTransferStatus(transferId, 'error', 'Connection closed during transfer');
                return;
            }

            if (offset >= file.size) {
                // Small delay to ensure all data chunks are flushed before sending complete
                await new Promise(resolve => setTimeout(resolve, 100));
                try {
                    dataChannel.send(JSON.stringify({ type: 'complete' }));
                } catch (e) { /* ignore */ }
                transfer.status = 'complete';
                return;
            }

            const chunk = file.slice(offset, offset + chunkSize);
            const arrayBuffer = await chunk.arrayBuffer();

            // Wait for buffer to clear if needed (backpressure)
            let waitAttempts = 0;
            while (dataChannel.bufferedAmount > chunkSize * 10 && waitAttempts < 500) {
                await new Promise(resolve => setTimeout(resolve, 20));
                waitAttempts++;
                if (dataChannel.readyState !== 'open') {
                    this.updateTransferStatus(transferId, 'error', 'Connection closed during transfer');
                    return;
                }
            }

            if (dataChannel.readyState === 'open') {
                dataChannel.send(arrayBuffer);
                offset += chunkSize;

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

        // Handle JSON string messages (metadata, complete, error)
        if (typeof data === 'string') {
            try {
                const msg = JSON.parse(data);

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
                // Not JSON, ignore
            }
            return;
        }

        // Binary chunk (ArrayBuffer)
        if (data instanceof ArrayBuffer) {
            const chunks = this.p2pReceivedChunks.get(transferId);
            if (chunks) {
                chunks.push(data);
                transfer.bytesReceived += data.byteLength;

                // Update progress
                if (transfer.offer) {
                    const progress = Math.min(100, (transfer.bytesReceived / transfer.offer.size) * 100);
                    this.updateTransferProgress(transferId, progress);
                }
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
                    const isTorrent = this.torrentSeeds.has(offerId);
                    const item = document.createElement('div');
                    item.className = 'p2p-transfer-item';
                    item.innerHTML = `
                        <div class="p2p-transfer-header">
                            <span class="p2p-transfer-filename">${this.escapeHtml(offer.name)}</span>
                            <span class="p2p-transfer-size">${this.formatFileSize(offer.size)}</span>
                        </div>
                        <div class="p2p-transfer-status">
                            <span class="p2p-transfer-status-text complete">Seeding${isTorrent ? ' (Torrent)' : ' (P2P)'}</span>
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

    // Stop seeding a file and broadcast unseeded event
    async stopSeeding(offerId) {
        const offer = this.p2pFileOffers.get(offerId);
        this.p2pPendingFiles.delete(offerId);
        this.p2pUnseededOffers.add(offerId);

        // Stop torrent seeding if applicable
        this.stopSeedingTorrent(offerId);

        // Close any active transfer connections for this offer
        const transfersToCancel = [];
        this.p2pActiveTransfers.forEach((transfer, transferId) => {
            if (transfer.offerId === offerId) {
                transfersToCancel.push(transferId);
            }
        });
        transfersToCancel.forEach(transferId => this.cancelTransfer(transferId));

        // Broadcast unseeded event via Nostr so peers know the file is no longer available
        if (offer && this.pubkey) {
            try {
                let tags = [
                    ['offer_id', offerId],
                    ['status', 'unseeded']
                ];
                if (offer.hash) tags.push(['x', offer.hash]);
                if (this.currentGeohash) tags.push(['g', this.currentGeohash]);

                const event = {
                    kind: this.P2P_FILE_STATUS_KIND,
                    created_at: Math.floor(Date.now() / 1000),
                    tags: tags,
                    content: JSON.stringify({ offerId, name: offer.name, status: 'unseeded' }),
                    pubkey: this.pubkey
                };

                const signedEvent = await this.signEvent(event);
                this.sendToRelay(['EVENT', signedEvent]);
            } catch (e) {
                console.error('Failed to broadcast unseeded event:', e);
            }
        }

        // Update any visible file offer UI to show unseeded status
        this.updateFileOfferUI(offerId, 'unseeded');

        this.displaySystemMessage('Stopped seeding file' + (offer ? `: ${offer.name}` : ''));
        this.openP2PTransfersModal(); // Refresh modal
    }

    // Update file offer UI element to reflect current status
    updateFileOfferUI(offerId, status) {
        const offerEl = document.querySelector(`[data-offer-id="${offerId}"]`);
        if (!offerEl) return;

        if (status === 'unseeded') {
            // Update the seeding indicator or download button to show unavailable
            const seedingDiv = offerEl.querySelector('.file-offer-seeding');
            if (seedingDiv) {
                seedingDiv.innerHTML = `
                    <div class="file-offer-unseeded-dot"></div>
                    <span>No longer seeding</span>
                `;
                seedingDiv.className = 'file-offer-unseeded';
            }
            const actionDiv = offerEl.querySelector('.file-offer-actions');
            if (actionDiv) {
                const btn = actionDiv.querySelector('.file-offer-btn');
                if (btn) {
                    btn.textContent = 'Unavailable';
                    btn.classList.add('unavailable');
                    btn.onclick = null;
                    btn.style.cursor = 'default';
                }
            }
        }
    }

    // Initialize WebTorrent client (lazy)
    getTorrentClient() {
        if (!this.torrentClient && typeof WebTorrent !== 'undefined') {
            this.torrentClient = new WebTorrent();
            this.torrentClient.on('error', (err) => {
                console.error('WebTorrent error:', err);
            });
        }
        return this.torrentClient;
    }

    // Share a file via WebTorrent (creates a torrent and seeds it)
    // Handle torrent file sharing - either a .torrent file or seed via WebTorrent
    async shareP2PFileTorrent(file) {
        if (!this.connected || !this.pubkey) {
            this.displaySystemMessage('Must be connected to share files');
            return;
        }

        const client = this.getTorrentClient();
        if (!client) {
            this.displaySystemMessage('WebTorrent is not available. Falling back to direct P2P.');
            return this.shareP2PFile(file);
        }

        if (!this.currentGeohash) {
            this.displaySystemMessage('No channel selected for file sharing');
            return;
        }

        const isTorrentFile = file.name.endsWith('.torrent') || file.type === 'application/x-bittorrent';

        if (isTorrentFile) {
            // User selected a .torrent file - read it and add to client
            this.displaySystemMessage(`Loading torrent file "${file.name}"...`);
            const torrentBuffer = await file.arrayBuffer();

            client.add(new Uint8Array(torrentBuffer), (torrent) => {
                this.onTorrentReady(torrent, file.name);
            });
        } else {
            // Regular file - create a new torrent and seed it
            this.displaySystemMessage(`Creating torrent for "${file.name}"...`);
            client.seed(file, { announceList: [] }, (torrent) => {
                this.onTorrentReady(torrent, null);
            });
        }
    }

    // Common handler once a torrent is ready (seeded or loaded from .torrent)
    onTorrentReady(torrent, originalTorrentFileName) {
        // Use the first file in the torrent for display info
        const torrentFile = torrent.files[0];
        const displayName = torrentFile ? torrentFile.name : (originalTorrentFileName || 'Unknown');
        const displaySize = torrent.length || 0;

        const offerId = torrent.infoHash.substring(0, 16) + '-' + Date.now().toString(36);

        // Store torrent reference
        this.torrentSeeds.set(offerId, torrent);

        // Store a placeholder in pending files for the transfers modal
        const placeholderFile = new File([], displayName, { type: 'application/x-bittorrent' });
        this.p2pPendingFiles.set(offerId, placeholderFile);

        // Create file offer metadata with magnet URI
        const fileOffer = {
            offerId: offerId,
            name: displayName,
            size: displaySize,
            type: torrentFile ? (torrentFile.type || 'application/octet-stream') : 'application/octet-stream',
            seederPubkey: this.pubkey,
            timestamp: Math.floor(Date.now() / 1000),
            magnetURI: torrent.magnetURI,
            infoHash: torrent.infoHash
        };

        // Store offer locally
        this.p2pFileOffers.set(offerId, fileOffer);

        // Build tags for the Nostr event
        const now = Math.floor(Date.now() / 1000);
        const tags = [
            ['n', this.nym],
            ['offer', JSON.stringify(fileOffer)],
            ['g', this.currentGeohash],
            ['expiration', String(now + 3600)] // Expire after 1 hour
        ];

        // Create and broadcast the file offer event
        const event = {
            kind: 20000,
            created_at: now,
            tags: tags,
            content: `Sharing file via torrent: ${displayName} (${this.formatFileSize(displaySize)})`,
            pubkey: this.pubkey
        };

        this.signEvent(event).then(signedEvent => {
            const optimisticMessage = {
                id: signedEvent.id,
                author: this.nym,
                pubkey: this.pubkey,
                content: event.content,
                timestamp: new Date(event.created_at * 1000),
                channel: this.currentChannel,
                geohash: this.currentGeohash || '',
                isOwn: true,
                isHistorical: false,
                isFileOffer: true,
                fileOffer: fileOffer
            };

            this.displayMessage(optimisticMessage);
            this.sendToRelay(['EVENT', signedEvent]);
            this.displaySystemMessage(`Seeding torrent: "${displayName}"`);
        });
    }

    // Download a file via WebTorrent
    async downloadTorrent(offerId) {
        const offer = this.p2pFileOffers.get(offerId);
        if (!offer || !offer.magnetURI) {
            this.displaySystemMessage('Torrent info not found for this file');
            return;
        }

        if (offer.seederPubkey === this.pubkey) {
            this.displaySystemMessage('Cannot download your own file');
            return;
        }

        if (this.p2pUnseededOffers.has(offerId)) {
            this.displaySystemMessage('This file is no longer being seeded');
            return;
        }

        const client = this.getTorrentClient();
        if (!client) {
            this.displaySystemMessage('WebTorrent is not available in this browser');
            return;
        }

        // Update UI
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

        // Check if already downloading this torrent
        const existingTorrent = client.get(offer.infoHash || offer.magnetURI);
        if (existingTorrent) {
            this.displaySystemMessage('Already downloading this torrent');
            return;
        }

        const transferId = offerId + '-torrent-' + Date.now().toString(36);
        this.p2pActiveTransfers.set(transferId, {
            offerId: offerId,
            offer: offer,
            status: 'connecting',
            bytesReceived: 0,
            startTime: Date.now(),
            isTorrent: true
        });

        client.add(offer.magnetURI, (torrent) => {
            const transfer = this.p2pActiveTransfers.get(transferId);
            if (!transfer) return; // Was cancelled

            transfer.status = 'transferring';
            transfer.torrent = torrent;

            torrent.on('download', () => {
                transfer.bytesReceived = torrent.downloaded;
                const progress = Math.min(100, (torrent.downloaded / torrent.length) * 100);
                this.updateTransferProgress(transferId, progress);

                if (btn) {
                    btn.textContent = `${progress.toFixed(1)}%`;
                }
            });

            torrent.on('done', () => {
                // Download complete - save each file
                torrent.files.forEach((file) => {
                    file.getBlob((err, blob) => {
                        if (err) {
                            this.displaySystemMessage('Error saving file: ' + err.message);
                            return;
                        }

                        const url = URL.createObjectURL(blob);
                        const a = document.createElement('a');
                        a.href = url;
                        a.download = file.name;
                        document.body.appendChild(a);
                        a.click();
                        document.body.removeChild(a);
                        URL.revokeObjectURL(url);
                    });
                });

                this.updateTransferStatus(transferId, 'complete', 'Download complete!');
                this.displaySystemMessage(`Torrent download complete: "${offer.name}"`);

                // Keep seeding for a bit, then remove
                setTimeout(() => {
                    try { torrent.destroy(); } catch (e) { /* ignore */ }
                    this.p2pActiveTransfers.delete(transferId);
                }, 60000);
            });

            torrent.on('error', (err) => {
                this.updateTransferStatus(transferId, 'error', 'Torrent error: ' + err.message);
            });
        });
    }

    // Stop seeding a torrent
    stopSeedingTorrent(offerId) {
        const torrent = this.torrentSeeds.get(offerId);
        if (torrent) {
            try { torrent.destroy(); } catch (e) { /* ignore */ }
            this.torrentSeeds.delete(offerId);
        }
    }

    // Cancel an active transfer
    cancelTransfer(transferId) {
        const transfer = this.p2pActiveTransfers.get(transferId);
        if (transfer) {
            // If it's a torrent transfer, destroy the torrent
            if (transfer.isTorrent && transfer.torrent) {
                try { transfer.torrent.destroy(); } catch (e) { /* ignore */ }
            }

            // Close any associated WebRTC connections and data channels
            const connectionsToDelete = [];
            this.p2pConnections.forEach((pc, connectionId) => {
                if (connectionId.endsWith(transferId)) {
                    try { pc.close(); } catch (e) { /* ignore */ }
                    connectionsToDelete.push(connectionId);
                }
            });
            connectionsToDelete.forEach(id => {
                this.p2pConnections.delete(id);
                if (this.p2pDataChannels.has(id)) {
                    try { this.p2pDataChannels.get(id).close(); } catch (e) { /* ignore */ }
                    this.p2pDataChannels.delete(id);
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
            // Get clean nym without existing HTML
            const cleanNym = this.parseNymFromDisplay(user.nym);
            return `${cleanNym}#${this.getPubkeySuffix(pubkey)}`;
        }

        // Check if we've seen this user in PM conversations
        const pmConvo = Array.from(this.pmConversations.values())
            .find(conv => conv.pubkey === pubkey);
        if (pmConvo && pmConvo.nym) {
            const cleanNym = this.parseNymFromDisplay(pmConvo.nym);
            return `${cleanNym}#${this.getPubkeySuffix(pubkey)}`;
        }

        // Return shortened pubkey as fallback with anon prefix
        return `anon#${pubkey.slice(-4)}`;
    }

    displayMessage(message) {
        // Check if message is from a blocked user (from stored state OR by pubkey)
        if (message.blocked || this.blockedUsers.has(message.pubkey) || this.isNymBlocked(message.author)) {
            return; // Don't display blocked messages
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
        } else {
            // Regular geohash channel message
            if (this.inPMMode) {
                // In PM mode, don't display channel messages
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

                // Prune in-memory messages if exceeding limit (100 max)
                const messages = this.messages.get(storageKey);
                if (messages && messages.length > 100) {
                    this.messages.set(storageKey, messages.slice(-100));
                }
            }

            // Check if this is for current channel
            const currentKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;
            if (storageKey !== currentKey) {
                // Message is for different channel, update unread count but don't display
                if (!message.isOwn && !exists && !message.isHistorical) {
                    this.updateUnreadCount(storageKey);
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


        // Check if user is near the bottom BEFORE we add the new message to DOM.
        // We use a generous threshold so rapid message bursts don't lose the "at bottom" state.
        const isNearBottom = container.scrollHeight - container.scrollTop <= container.clientHeight + 150;
        const shouldScroll = !this.virtualScroll.suppressAutoScroll &&
            !this.userScrolledUp && isNearBottom;

        // Clamp timestamp to now so messages never appear in the future
        const now = new Date();
        const displayTimestamp = message.timestamp > now ? now : message.timestamp;

        const time = this.settings.showTimestamps ?
            displayTimestamp.toLocaleTimeString('en-US', {
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
        const channelToCheck = message.geohash || message.channel;
        if (!message.isPM && !message.isHistorical && this.isFlooding(message.pubkey, channelToCheck)) {
            messageEl.className = 'message flooded';
        }

        // Check if message mentions the user
        const isMentioned = !message.isOwn && this.isMentioned(message.content);

        // Check for action messages
        if (message.content.startsWith('/me ')) {
            messageEl.className = 'action-message';
            messageEl.dataset.messageId = message.id;
            messageEl.dataset.timestamp = displayTimestamp.getTime();

            // Get clean author name and flair
            const cleanAuthor = this.parseNymFromDisplay(message.author);
            const authorFlairHtml = this.getFlairForUser(message.pubkey);
            const actionAvatarSrc = this.getAvatarUrl(message.pubkey);
            const authorWithFlair = `<img src="${this.escapeHtml(actionAvatarSrc)}" class="avatar-message" data-avatar-pubkey="${message.pubkey}" alt="" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${message.pubkey}.png?set=set1&size=80x80'">${this.escapeHtml(cleanAuthor)}#${this.getPubkeySuffix(message.pubkey)}${authorFlairHtml}`;

            // Get the action content (everything after /me)
            const actionContent = message.content.substring(4);

            // Format the action content but preserve any HTML in mentioned users
            const formattedAction = this.formatMessage(actionContent);

            messageEl.innerHTML = `* ${authorWithFlair} ${formattedAction} *`;
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
            messageEl.dataset.timestamp = displayTimestamp.getTime();

            const authorClass = message.isOwn ? 'self' : '';
            const userColorClass = this.getUserColorClass(message.pubkey);

            // Add verified badge if this is the developer
            const verifiedBadge = this.isVerifiedDeveloper(message.pubkey) ?
                `<span class="verified-badge" title="${this.verifiedDeveloper.title}">✓</span>` : '';

            // Check if this is a valid event ID (not temporary PM ID)
            const isValidEventId = message.id && /^[0-9a-f]{64}$/i.test(message.id);
            const isMobile = window.innerWidth <= 768;

            // Show reaction button for all messages with valid IDs (including PMs)
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
            const avatarSrc = this.getAvatarUrl(message.pubkey);
            const displayAuthorBase = `<img src="${this.escapeHtml(avatarSrc)}" class="avatar-message" data-avatar-pubkey="${message.pubkey}" alt="" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${message.pubkey}.png?set=set1&size=80x80'">&lt;${this.escapeHtml(baseNym)}<span class="nym-suffix">#${this.getPubkeySuffix(message.pubkey)}</span>${flairHtml}`;
            let displayAuthor = displayAuthorBase; // string used in HTML
            let authorExtraClass = '';
            if (Array.isArray(userShopItems?.cosmetics) && userShopItems.cosmetics.includes('cosmetic-redacted')) {
                authorExtraClass = 'cosmetic-redacted';
            }

            const escapedAuthorBase = this.escapeHtml(message.author).split('#')[0] || this.escapeHtml(message.author);
            const authorWithHtml = `${escapedAuthorBase}<span class="nym-suffix">#${this.getPubkeySuffix(message.pubkey)}</span>`;

            // Prepare full timestamp for tooltip
            const fullTimestamp = displayTimestamp.toLocaleString('en-US', {
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
                } else if (message.deliveryStatus === 'failed') {
                    deliveryCheckmark = `<span class="delivery-status failed" title="Failed to deliver - click to retry" style="cursor:pointer" data-retry-event-id="${message.id}">!</span>`;
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
                const isUnseeded = this.p2pUnseededOffers.has(offer.offerId) || (isOwnOffer && !this.p2pPendingFiles.has(offer.offerId) && message.isHistorical);
                const isTorrent = !!offer.magnetURI;

                let statusHtml;
                if (isOwnOffer) {
                    if (isUnseeded) {
                        statusHtml = `
                            <div class="file-offer-unseeded">
                                <div class="file-offer-unseeded-dot"></div>
                                <span>No longer seeding</span>
                            </div>
                        `;
                    } else {
                        statusHtml = `
                            <div class="file-offer-seeding">
                                <div class="file-offer-seeding-dot"></div>
                                <span>Seeding - available for download</span>
                                <button class="file-offer-stop-btn" onclick="nym.stopSeeding('${offer.offerId}')" title="Stop seeding">Stop</button>
                            </div>
                        `;
                    }
                } else if (isUnseeded) {
                    statusHtml = `
                        <div class="file-offer-unseeded">
                            <div class="file-offer-unseeded-dot"></div>
                            <span>No longer available</span>
                        </div>
                    `;
                } else {
                    statusHtml = `
                        <div class="file-offer-actions">
                            ${isTorrent ? `
                                <button class="file-offer-btn torrent-btn" onclick="nym.downloadTorrent('${offer.offerId}')">Download (Torrent)</button>
                            ` : `
                                <button class="file-offer-btn" onclick="nym.requestP2PFile('${offer.offerId}')">Download</button>
                            `}
                        </div>
                        <div class="file-offer-progress" id="progress-${offer.offerId}" style="display: none;">
                            <div class="file-offer-progress-bar">
                                <div class="file-offer-progress-fill" id="progress-fill-${offer.offerId}"></div>
                            </div>
                            <div class="file-offer-progress-text" id="progress-text-${offer.offerId}">Connecting...</div>
                        </div>
                    `;
                }

                messageContentHtml = `
                    <div class="file-offer${isTorrent ? ' torrent' : ''}" data-offer-id="${offer.offerId}">
                        <div class="file-offer-header">
                            <div class="file-offer-icon ${fileCategory}">
                                <svg viewBox="0 0 24 24" stroke-width="2">
                                    <path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"></path>
                                    <polyline points="13 2 13 9 20 9"></polyline>
                                </svg>
                            </div>
                            <div class="file-offer-info">
                                <div class="file-offer-name" title="${this.escapeHtml(offer.name)}">${this.escapeHtml(offer.name)}</div>
                                <div class="file-offer-meta">${this.formatFileSize(offer.size)} • ${offer.type || 'Unknown type'}${isTorrent ? ' • Torrent' : ''}</div>
                            </div>
                        </div>
                        ${statusHtml}
                    </div>
                `;
            } else {
                messageContentHtml = formattedContent;
            }

            // Detect emoji-only messages (1-6 emoji with optional whitespace, no other text)
            const emojiOnlyClass = !message.isFileOffer && this.isEmojiOnly(message.content) ? ' emoji-only' : '';

            messageEl.innerHTML = `
    ${time ? `<span class="message-time ${this.settings.timeFormat === '12hr' ? 'time-12hr' : ''}" data-full-time="${fullTimestamp}" title="${fullTimestamp}">${time}</span>` : ''}
    <span class="message-author ${authorClass} ${userColorClass} ${authorExtraClass}">${displayAuthor}${verifiedBadge}${supporterBadge}&gt;</span>
    <span class="message-content ${userColorClass}${emojiOnlyClass}">${messageContentHtml}</span>
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
            if (this.userPurchases.has('supporter-badge') && this.supporterBadgeActive !== false) {
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
                                contentEl.textContent = '';
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
                            contentEl.textContent = '';
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

        // Always insert messages in correct timestamp order to prevent out-of-order display
        {
            const existingMessages = Array.from(container.querySelectorAll('[data-timestamp]'));
            const messageTimestamp = displayTimestamp.getTime();

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
                container.appendChild(messageEl);
            }
        }

        // Prune oldest messages from DOM to stay at the 100 message cap
        {
            const domMessages = container.querySelectorAll('[data-message-id]');
            if (domMessages.length > this.channelMessageLimit) {
                const toRemove = domMessages.length - this.channelMessageLimit;
                for (let i = 0; i < toRemove; i++) {
                    domMessages[i].remove();
                }
            }
        }

        // Add existing reactions if any (for both channel messages and PMs)
        if (message.id && this.reactions.has(message.id)) {
            this.updateMessageReactions(message.id);
        }

        // Add zaps display - check if this message has any zaps
        if (message.id && this.zaps.has(message.id)) {
            this.updateMessageZaps(message.id);
        }

        // Scroll handling: use coalesced rAF to batch scroll operations.
        // When images are present, also scroll after they load.
        if (shouldScroll) {
            this._scheduleScrollToBottom();

            // If message has images, schedule another scroll after they load
            const images = messageEl.querySelectorAll('img:not(.avatar-message)');
            if (images.length > 0) {
                let loaded = 0;
                const total = images.length;
                const onLoad = () => {
                    if (++loaded === total && !this.userScrolledUp) {
                        this._scheduleScrollToBottom();
                    }
                };
                images.forEach(img => {
                    if (img.complete) onLoad();
                    else {
                        img.addEventListener('load', onLoad, { once: true });
                        img.addEventListener('error', onLoad, { once: true });
                    }
                });
            }
        }

        // Play notification sound for mentions and PMs (but not for historical messages or own messages)
        if (!message.isHistorical && !message.isOwn && this.settings.sound) {
            if (isMentioned || message.isPM) {
                this.playSound(this.settings.sound);
            }
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

                // Clean the author name of HTML, entities, and deduplicate suffixes for comparison
                let cleanAuthor = quotedAuthor.replace(/<[^>]*>/g, '').replace(/&lt;/g, '').replace(/&gt;/g, '').trim();
                cleanAuthor = cleanAuthor.replace(/^([^#]+)#([0-9a-f]{4})#\2$/i, '$1#$2');

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

        // Deduplicate suffixes in mentions from external apps (e.g., @user#abcd#abcd -> @user#abcd)
        formatted = formatted.replace(/@([^@#\s]+)#([0-9a-f]{4})#\2\b/gi, '@$1#$2');

        formatted = formatted
            .replace(/&(?![a-z]+;|#[0-9]+;|#x[0-9a-f]+;)/gi, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
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

        // Convert Nymchat app channel links BEFORE general URLs
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

        // Process mentions and geohash channel references in one pass
        formatted = formatted.replace(
            /(@[^@#\n]*?(?<!\s)#[0-9a-f]{4}\b)|(@[^@\s][^@\s]*)|(^|\s)(#[0-9bcdefghjkmnpqrstuvwxyz]+)(?=\s|$|[.,!?])/gi,
            (match, mentionWithSuffix, simpleMention, whitespace, channel) => {
                if (mentionWithSuffix) {
                    return `<span style="color: var(--secondary)">${mentionWithSuffix}</span>`;
                } else if (simpleMention) {
                    return `<span style="color: var(--secondary)">${simpleMention}</span>`;
                } else if (channel) {
                    const channelName = channel.substring(1).trim();
                    const sanitized = channelName.toLowerCase().replace(/[^0-9bcdefghjkmnpqrstuvwxyz]/g, '');

                    if (!sanitized || !this.isValidGeohash(sanitized)) {
                        return match;
                    }

                    const isActive = this.currentGeohash === sanitized;
                    const classes = ['channel-reference', 'geohash-reference'];
                    if (isActive) classes.push('active-channel');

                    const location = this.getGeohashLocation(sanitized);
                    let title = `Geohash channel`;
                    if (location) {
                        title += `: ${location}`;
                    }

                    return `${whitespace || ''}<span class="${classes.join(' ')}" style="text-decoration: underline;" title="${title}" onclick="event.preventDefault(); event.stopPropagation(); nym.handleChannelLink('g:${sanitized}', event); return false;">${channel}</span>`;
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

        // Wrap emoji characters in <span class="emoji"> to isolate them from --font-sans
        // This regex matches all Unicode emoji including: emoticons, symbols, dingbats,
        // skin tone modifiers, regional indicator flag sequences, variation selectors,
        // ZWJ sequences, keycap sequences (#️⃣ 0️⃣-9️⃣), and tag flag sequences.
        formatted = formatted.replace(
            /(?:<[^>]+>)|((?:[\u{1F1E0}-\u{1F1FF}]{2})|(?:[#*0-9]\u{FE0F}?\u{20E3})|(?:(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?(?:\u{200D}(?:\p{Emoji_Presentation}|\p{Extended_Pictographic})(?:\u{FE0F}|\u{FE0E})?(?:[\u{1F3FB}-\u{1F3FF}])?)*)(?:[\u{E0020}-\u{E007E}]+\u{E007F})?)/gu,
            (match, emoji) => {
                // If this is an HTML tag, skip it
                if (!emoji) return match;
                return `<span class="emoji">${match}</span>`;
            }
        );

        // Line breaks
        formatted = formatted.replace(/\n/g, '<br>');

        return formatted;
    }

    // Check if a raw message is emoji-only (1-6 emoji, optional whitespace, no other text)
    isEmojiOnly(content) {
        if (!content) return false;
        // Strip whitespace and check if remaining chars are all emoji (up to 6)
        const stripped = content.replace(/\s/g, '');
        // Matches flag sequences, keycap sequences, and all ZWJ/skin-tone emoji
        const singleEmoji = '(?:[\\u{1F1E0}-\\u{1F1FF}]{2})|(?:[#*0-9]\\u{FE0F}?\\u{20E3})|(?:(?:\\p{Emoji_Presentation}|\\p{Extended_Pictographic})(?:\\u{FE0F}|\\u{FE0E})?(?:[\\u{1F3FB}-\\u{1F3FF}])?(?:\\u{200D}(?:\\p{Emoji_Presentation}|\\p{Extended_Pictographic})(?:\\u{FE0F}|\\u{FE0E})?(?:[\\u{1F3FB}-\\u{1F3FF}])?)*)(?:[\\u{E0020}-\\u{E007E}]+\\u{E007F})?';
        const emojiPattern = new RegExp(`^(?:${singleEmoji}){1,6}$`, 'u');
        return emojiPattern.test(stripped);
    }

    expandImage(src) {
        document.getElementById('modalImage').src = src;
        document.getElementById('imageModal').classList.add('active');
    }

    quickJoinChannel(channel) {
        // Sanitize channel name for geohash
        const sanitized = channel.toLowerCase().replace(/[^0-9bcdefghjkmnpqrstuvwxyz]/g, '');

        if (!sanitized || !this.isValidGeohash(sanitized)) {
            this.displaySystemMessage('Invalid geohash channel.');
            return;
        }

        this.addChannel(sanitized, sanitized);
        this.switchChannel(sanitized, sanitized);
        this.userJoinedChannels.add(sanitized);

        // Save after quick join
        this.saveUserChannels();
    }


    // No longer needed - geohash links navigate directly

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

        this._scheduleScrollToBottom();
    }

    // Coalesced scroll-to-bottom: batches multiple scroll requests into one rAF frame.
    // This prevents layout thrashing when many messages arrive in quick succession.
    _scheduleScrollToBottom(force = false) {
        if (!force && (!this.settings.autoscroll || this.userScrolledUp)) return;
        if (!force && this.virtualScroll.suppressAutoScroll) return;
        if (this._scrollRAF) return; // already scheduled

        this._scrollRAF = requestAnimationFrame(() => {
            this._scrollRAF = null;
            const container = document.getElementById('messagesContainer');
            if (!container) return;
            container.scrollTop = container.scrollHeight;
        });
    }

    handlePresenceEvent(event) {
        const nymTag = event.tags.find(t => t[0] === 'n');
        const statusTag = event.tags.find(t => t[0] === 'status');
        const awayTag = event.tags.find(t => t[0] === 'away');
        const avatarUpdateTag = event.tags.find(t => t[0] === 'avatar-update');

        if (!statusTag) return;

        const pubkey = event.pubkey;
        const status = statusTag[1];
        const nym = nymTag ? nymTag[1].split('#')[0] : null;
        const eventTime = event.created_at || 0;

        // Ignore our own presence events
        if (pubkey === this.pubkey) return;

        // Skip stale presence events - only process if newer than last seen
        if (!this.presenceTimestamps) this.presenceTimestamps = new Map();
        const lastTimestamp = this.presenceTimestamps.get(pubkey) || 0;
        if (eventTime < lastTimestamp) return;
        this.presenceTimestamps.set(pubkey, eventTime);

        // Handle avatar update: clear cached avatar and re-fetch
        if (avatarUpdateTag) {
            const newAvatarUrl = avatarUpdateTag[1];
            const oldBlob = this.avatarBlobCache.get(pubkey);
            if (oldBlob) URL.revokeObjectURL(oldBlob);
            this.avatarBlobCache.delete(pubkey);

            if (newAvatarUrl) {
                this.userAvatars.set(pubkey, newAvatarUrl);
                this.cacheAvatarImage(pubkey, newAvatarUrl);
                this.updateRenderedAvatars(pubkey, newAvatarUrl);
            } else {
                // Avatar removed - fall back to robohash
                this.userAvatars.delete(pubkey);
                this.updateRenderedAvatars(pubkey, this.getAvatarUrl(pubkey));
            }
        }

        // Update away messages map for this user
        if (status === 'away' && awayTag) {
            this.awayMessages.set(pubkey, awayTag[1]);
        } else if (status === 'online') {
            this.awayMessages.delete(pubkey);
        }

        // Update user status if we know this user
        if (this.users.has(pubkey)) {
            const user = this.users.get(pubkey);
            user.status = status;
            if (nym) user.nym = nym;
            this.updateUserList();
        }
    }

    updateUserPresence(nym, pubkey, channel, geohash, createdAt) {
        const channelKey = geohash || channel;

        // Use the event's created_at timestamp (seconds) converted to ms,
        // so historical messages don't falsely mark users as online
        const eventTime = createdAt ? createdAt * 1000 : Date.now();

        // Determine base status from away messages or event age
        const activeThreshold = 300000; // 5 minutes
        const isRecent = (Date.now() - eventTime) < activeThreshold;
        let baseStatus;
        if (this.awayMessages.has(pubkey)) {
            baseStatus = 'away';
        } else if (isRecent) {
            baseStatus = 'online';
        } else {
            baseStatus = 'offline';
        }

        // Update or create user with deduplication by pubkey
        if (!this.users.has(pubkey)) {
            this.users.set(pubkey, {
                nym: nym,
                pubkey: pubkey,
                lastSeen: eventTime,
                status: baseStatus,
                channels: new Set([channelKey])
            });
        } else {
            const user = this.users.get(pubkey);
            // Only update lastSeen if this event is more recent
            if (eventTime > user.lastSeen) {
                user.lastSeen = eventTime;
                user.status = baseStatus;
            }
            user.nym = nym; // Update nym in case it changed
            user.channels.add(channelKey);
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
        const currentChannelKey = this.currentGeohash || this.currentChannel;

        // Get deduplicated users (one entry per pubkey), including inactive
        // Compute effective status without mutating the source user objects
        const uniqueUsers = new Map();
        const now = Date.now();
        const activeThreshold = 300000; // 5 minutes
        this.users.forEach((user, pubkey) => {
            if (!this.blockedUsers.has(user.nym)) {
                if (!uniqueUsers.has(pubkey)) {
                    let effectiveStatus = user.status;
                    if (now - user.lastSeen >= activeThreshold && effectiveStatus !== 'away') {
                        effectiveStatus = 'offline';
                    }
                    uniqueUsers.set(pubkey, { ...user, effectiveStatus });
                }
            }
        });

        // Sort into three explicit groups: active first, then away, then inactive
        // Each group is alphabetically sorted by nym
        const alphabetical = (a, b) => {
            const nymA = this.parseNymFromDisplay(a.nym || '').toLowerCase();
            const nymB = this.parseNymFromDisplay(b.nym || '').toLowerCase();
            return nymA.localeCompare(nymB);
        };
        const validUsers = Array.from(uniqueUsers.values()).filter(user => user && user.nym);
        const activeUsers = validUsers.filter(u => u.effectiveStatus === 'online').sort(alphabetical);
        const awayUsers = validUsers.filter(u => u.effectiveStatus === 'away').sort(alphabetical);
        const inactiveUsers = validUsers.filter(u => u.effectiveStatus === 'offline').sort(alphabetical);
        const allUsers = [...activeUsers, ...awayUsers, ...inactiveUsers];

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

        // Build updated DOM by reusing existing nodes where possible
        // so that unchanged avatar <img> elements are never removed/re-added
        // (which would cause visible flickering).
        const existingItems = new Map();
        userListContent.querySelectorAll('.user-item[data-pubkey]').forEach(el => {
            existingItems.set(el.dataset.pubkey, el);
        });

        const fragment = document.createDocumentFragment();

        displayUsers.forEach((user) => {
            const baseNym = this.parseNymFromDisplay(user.nym);
            const suffix = this.getPubkeySuffix(user.pubkey);
            const displayNym = `${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>`;
            const verifiedBadge = this.isVerifiedDeveloper(user.pubkey)
                ? `<span class="verified-badge" title="${this.verifiedDeveloper.title}" style="margin-left: 3px;">✓</span>`
                : '';
            const userColorClass = this.settings.theme === 'bitchat' ? this.getUserColorClass(user.pubkey) : '';
            const avatarSrc = this.getAvatarUrl(user.pubkey);

            let el = existingItems.get(user.pubkey);
            if (el) {
                // Reuse existing DOM node — only update mutable parts
                existingItems.delete(user.pubkey);
                const statusSpan = el.querySelector('.user-status');
                if (statusSpan) statusSpan.className = `user-status ${user.effectiveStatus}`;
                const img = el.querySelector('img.avatar-user-list');
                if (img && img.getAttribute('src') !== avatarSrc) img.src = avatarSrc;
                el.className = `user-item list-item ${userColorClass}`;
                fragment.appendChild(el);
            } else {
                // Create new element for a user not previously in the list
                const wrapper = document.createElement('div');
                wrapper.innerHTML = `<div class="user-item list-item ${userColorClass}"
                        onclick="nym.openUserPM('${this.escapeHtml(baseNym)}', '${user.pubkey}')"
                        oncontextmenu="nym.showContextMenu(event, '${this.escapeHtml(displayNym)}', '${user.pubkey}')"
                        data-pubkey="${user.pubkey}"
                        data-nym="${this.escapeHtml(baseNym)}">
                    <img src="${this.escapeHtml(avatarSrc)}" class="avatar-user-list" alt="" loading="lazy" data-avatar-pubkey="${user.pubkey}" onerror="this.onerror=null;this.src='https://robohash.org/${user.pubkey}.png?set=set1&size=80x80'">
                    <span class="user-status ${user.effectiveStatus}"></span>
                    <span class="${userColorClass}">${displayNym} ${verifiedBadge}</span>
                </div>`;
                fragment.appendChild(wrapper.firstElementChild);
            }
        });

        // Remove users no longer in the list
        existingItems.forEach(el => el.remove());

        // Replace content — moves existing nodes (preserving loaded images)
        userListContent.textContent = '';
        userListContent.appendChild(fragment);

        this.updateViewMoreButton('userListContent');

        const activeCount = allUsers.filter(u => u.effectiveStatus !== 'offline').length;
        const userListTitle = document.querySelector('#userList .nav-title-text');
        if (userListTitle) {
            userListTitle.textContent = `Nyms (${this.abbreviateNumber(activeCount)} active)`;
        }

        if (!this.inPMMode) {
            const meta = document.getElementById('channelMeta');
            if (meta) meta.textContent = `${this.abbreviateNumber(channelUserCount)} active nyms`;
        }

        // Refresh mention menu if it's currently open so it reflects latest presence
        this.refreshAutocompleteIfOpen();
    }

    filterChannels(searchTerm) {
        const items = document.querySelectorAll('.channel-item');
        const term = searchTerm.toLowerCase();
        const list = document.getElementById('channelList');

        // Update wrapper has-value class for clear button visibility
        const wrapper = document.getElementById('channelSearchWrapper');
        if (wrapper) {
            wrapper.classList.toggle('has-value', term.length > 0);
        }

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

        // Update wrapper has-value class for clear button visibility
        const wrapper = document.getElementById('pmSearchWrapper');
        if (wrapper) {
            wrapper.classList.toggle('has-value', term.length > 0);
        }

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

        // Update wrapper has-value class for clear button visibility
        const wrapper = document.getElementById('userSearchWrapper');
        if (wrapper) {
            wrapper.classList.toggle('has-value', searchTerm.length > 0);
        }

        const list = document.getElementById('userListContent');

        // Hide view more button during search
        const viewMoreBtn = list.querySelector('.view-more-btn');
        if (viewMoreBtn) {
            viewMoreBtn.style.display = searchTerm ? 'none' : 'block';
        }
    }

    togglePin(channel, geohash) {
        // Don't allow pinning/unpinning #nym since it's always at top
        if (geohash === 'nym') {
            this.displaySystemMessage('#nym is always at the top');
            return;
        }

        const key = geohash || channel;

        // Toggle pin status
        if (this.pinnedChannels.has(key)) {
            this.pinnedChannels.delete(key);
        } else {
            this.pinnedChannels.add(key);
        }

        this.savePinnedChannels();
        this.updateChannelPins();
    }

    updateChannelPins() {
        document.querySelectorAll('.channel-item').forEach(item => {
            let key;

            const channel = item.dataset.channel;
            const geohash = item.dataset.geohash;
            key = geohash || channel;

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

    toggleHideChannel(channel, geohash) {
        if (geohash === 'nym') {
            this.displaySystemMessage('#nym cannot be hidden');
            return;
        }

        const key = geohash || channel;

        if (this.hiddenChannels.has(key)) {
            this.hiddenChannels.delete(key);
        } else {
            this.hiddenChannels.add(key);
        }

        this.saveHiddenChannels();
        this.applyHiddenChannels();
    }

    applyHiddenChannels() {
        document.querySelectorAll('.channel-item').forEach(item => {
            const channel = item.dataset.channel;
            const geohash = item.dataset.geohash;
            const key = geohash || channel;

            // Don't override search filter visibility
            if (item.classList.contains('search-hidden')) {
                return;
            }

            // Never hide #nym or the active channel
            if (geohash === 'nym' || item.classList.contains('active')) {
                item.style.display = '';
                return;
            }

            // Hide if explicitly hidden
            if (this.hiddenChannels.has(key)) {
                item.style.display = 'none';
                return;
            }

            // Hide if "hide non-pinned" is on and channel is not pinned
            if (this.hideNonPinned && !this.pinnedChannels.has(key)) {
                item.style.display = 'none';
                return;
            }

            item.style.display = '';
        });
    }

    saveHiddenChannels() {
        localStorage.setItem('nym_hidden_channels', JSON.stringify(Array.from(this.hiddenChannels)));
    }

    loadHiddenChannels() {
        const saved = localStorage.getItem('nym_hidden_channels');
        if (saved) {
            this.hiddenChannels = new Set(JSON.parse(saved));
        }
        const hideNonPinned = localStorage.getItem('nym_hide_non_pinned');
        this.hideNonPinned = hideNonPinned === 'true';
        this.applyHiddenChannels();
    }

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

            // Close reactors modal if clicking outside
            if (!e.target.closest('.reactors-modal') &&
                !e.target.closest('.reaction-badge')) {
                this.closeReactorsModal();
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
            '/invite': { desc: 'Invite a user to current channel', fn: (args) => this.cmdInvite(args) },
            '/share': { desc: 'Share current channel URL', fn: () => this.cmdShare() },
            '/leave': { desc: 'Leave current channel', fn: () => this.cmdLeave() },
            '/quit': { desc: 'Disconnect from Nymchat', fn: () => this.cmdQuit() }
        };
    }

    handleInputChange(value) {
        // Check for @ mentions first
        const lastAtIndex = value.lastIndexOf('@');
        const isMentionActive = lastAtIndex !== -1 && (lastAtIndex === value.length - 1 ||
            value.substring(lastAtIndex).match(/^@[^\s]*$/));

        if (isMentionActive) {
            const search = value.substring(lastAtIndex + 1);
            this.showAutocomplete(search);
            // Hide emoji autocomplete - colon may be part of a nickname
            this.hideEmojiAutocomplete();
        } else {
            this.hideAutocomplete();

            // Only check for emoji autocomplete when not in a mention context
            const colonIndex = value.lastIndexOf(':');
            if (colonIndex !== -1 && colonIndex === value.length - 1 ||
                (colonIndex !== -1 && value.substring(colonIndex).match(/^:[a-z0-9_+-]*$/))) {
                const search = value.substring(colonIndex + 1);
                this.showEmojiAutocomplete(search);
            } else {
                this.hideEmojiAutocomplete();
            }
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
        const currentChannelKey = this.currentGeohash || this.currentChannel;

        // Get current time for activity check
        const now = Date.now();
        const activeThreshold = 300000; // 5 minutes

        // Collect users with effective status (matching sidebar logic)
        const channelActiveUsers = [];
        const channelAwayUsers = [];
        const channelOfflineUsers = [];
        const otherActiveUsers = [];
        const otherAwayUsers = [];
        const otherOfflineUsers = [];

        this.users.forEach((user, pubkey) => {
            // Create formatted nym for matching
            const baseNym = user.nym.split('#')[0] || user.nym;
            const suffix = this.getPubkeySuffix(pubkey);
            const searchableNym = `${baseNym}#${suffix}`;

            if (!this.blockedUsers.has(user.nym) &&
                searchableNym.toLowerCase().includes(search.toLowerCase())) {

                // Compute effective status matching sidebar logic
                let effectiveStatus = user.status;
                if (now - user.lastSeen >= activeThreshold && effectiveStatus !== 'away') {
                    effectiveStatus = 'offline';
                }

                // Create HTML version for display
                const displayNym = `${this.escapeHtml(baseNym)}<span class="nym-suffix">#${suffix}</span>`;

                const userEntry = {
                    nym: user.nym,
                    pubkey: pubkey,
                    displayNym: displayNym,
                    searchableNym: searchableNym,
                    lastSeen: user.lastSeen,
                    effectiveStatus: effectiveStatus
                };

                const inCurrentChannel = user.channels && user.channels.has(currentChannelKey);

                if (inCurrentChannel) {
                    if (effectiveStatus === 'online') channelActiveUsers.push(userEntry);
                    else if (effectiveStatus === 'away') channelAwayUsers.push(userEntry);
                    else channelOfflineUsers.push(userEntry);
                } else {
                    if (effectiveStatus === 'online') otherActiveUsers.push(userEntry);
                    else if (effectiveStatus === 'away') otherAwayUsers.push(userEntry);
                    else otherOfflineUsers.push(userEntry);
                }
            }
        });

        // Sort each group alphabetically
        const sortAlpha = (a, b) => a.searchableNym.localeCompare(b.searchableNym);
        channelActiveUsers.sort(sortAlpha);
        channelAwayUsers.sort(sortAlpha);
        channelOfflineUsers.sort(sortAlpha);
        otherActiveUsers.sort(sortAlpha);
        otherAwayUsers.sort(sortAlpha);
        otherOfflineUsers.sort(sortAlpha);

        // Channel members first (active > away > offline), then others (active > away > offline)
        const allUsers = [
            ...channelActiveUsers, ...channelAwayUsers, ...channelOfflineUsers,
            ...otherActiveUsers, ...otherAwayUsers, ...otherOfflineUsers
        ].slice(0, 8);

        if (allUsers.length > 0) {
            dropdown.innerHTML = allUsers.map((user, index) => {
                const statusClass = user.effectiveStatus === 'online' ? '' :
                    user.effectiveStatus === 'away' ? ' away' : ' offline';
                const statusIndicator = `<span class="user-status${statusClass}" style="display: inline-block; margin-right: 6px; vertical-align: middle;"></span>`;

                const acAvatarSrc = this.getAvatarUrl(user.pubkey);
                return `
        <div class="autocomplete-item ${index === 0 ? 'selected' : ''}"
                data-nym="${user.nym}"
                data-pubkey="${user.pubkey}"
                onclick="nym.selectSpecificAutocomplete('${user.nym}', '${user.pubkey}')">
            <img src="${this.escapeHtml(acAvatarSrc)}" class="avatar-message" data-avatar-pubkey="${user.pubkey}" alt="" loading="lazy" onerror="this.onerror=null;this.src='https://robohash.org/${user.pubkey}.png?set=set1&size=80x80'">${statusIndicator}<strong>@${user.displayNym}</strong>
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

    refreshAutocompleteIfOpen() {
        const dropdown = document.getElementById('autocompleteDropdown');
        if (!dropdown || !dropdown.classList.contains('active')) return;
        const input = document.getElementById('messageInput');
        if (!input) return;
        const value = input.value;
        const lastAtIndex = value.lastIndexOf('@');
        if (lastAtIndex !== -1 && (lastAtIndex === value.length - 1 ||
            value.substring(lastAtIndex).match(/^@[^\s]*$/))) {
            const search = value.substring(lastAtIndex + 1);
            this.showAutocomplete(search);
        }
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
            } else if (this.currentGeohash) {
                // Send to geohash channel (kind 20000)
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
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
            this.displaySystemMessage('Usage: /join #geohash (e.g., /join #9q5 or /join nym)');
            return;
        }

        let channel = args.trim().toLowerCase();

        // Strip leading # if present
        if (channel.startsWith('#')) {
            channel = channel.substring(1);
        }

        // Validate geohash
        if (!this.isValidGeohash(channel)) {
            this.displaySystemMessage('Invalid geohash format. Use only valid geohash characters (0-9, b-z excluding a, i, l, o).');
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
    }

    async cmdLeave() {
        if (this.inPMMode) {
            this.displaySystemMessage('Use /pm to switch channels or close PMs from the sidebar');
            return;
        }

        if (this.currentGeohash === 'nym') {
            this.displaySystemMessage('Cannot leave the default #nym channel');
            return;
        }

        this.removeChannel(this.currentChannel, this.currentGeohash);
    }


    async cmdPM(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /pm nym, /pm nym#xxxx, or /pm [pubkey]');
            return;
        }

        const targetInput = args.trim().replace(/^@/, '');

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

        // Create channel info for geohash channel
        const channelInfo = `#${this.currentGeohash}`;
        const joinCommand = `/join #${this.currentGeohash}`;

        // Send an invitation as a PM
        const inviteMessage = `📨 Channel Invitation: You've been invited to join ${channelInfo}. Use ${joinCommand} to join!`;

        // Send as PM
        const sent = await this.sendPM(inviteMessage, targetPubkey);

        if (sent) {
            const displayNym = this.formatNymWithPubkey(matchedNym, targetPubkey);
            this.displaySystemMessage(`Invitation sent to ${displayNym} for ${channelInfo}`);

            // Also send a mention in the current channel
            const publicNotice = `@${matchedNym} you've been invited to this channel! Check your PMs for details.`;
            await this.publishMessage(publicNotice, this.currentChannel, this.currentGeohash);
        } else {
            this.displaySystemMessage(`Failed to send invitation to ${this.formatNymWithPubkey(matchedNym, targetPubkey)}`);
        }
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

            // Block geohash channel
            if (this.isValidGeohash(channelName)) {
                this.blockChannel(channelName, channelName);
                this.displaySystemMessage(`Blocked geohash channel #${channelName}`);
            } else {
                this.displaySystemMessage(`Invalid geohash: ${channelName}`);
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
            return;
        }

        this.blockedUsers.add(targetPubkey);
        this.saveBlockedUsers();
        this.hideMessagesFromBlockedUser(targetPubkey);

        this.displaySystemMessage(`Blocked ${cleanNym}`);
        this.updateUserList();
        this.updateBlockedList();

    }

    unblockByPubkey(pubkey) {
        this.blockedUsers.delete(pubkey);
        this.saveBlockedUsers();
        this.showMessagesFromUnblockedUser(pubkey);

        const nym = this.getNymFromPubkey(pubkey);
        this.displaySystemMessage(`Unblocked ${nym}`);
        this.updateUserList();
        this.updateBlockedList();

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
                this.displaySystemMessage(`Multiple users found with nym "${searchNym}": ${matchList}`);
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
    }

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
                this.displaySystemMessage(`Multiple users found with nym "${searchNym}": ${matchList}`);
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
            } else if (this.currentGeohash) {
                // Send to geohash channel
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
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
            } else if (this.currentGeohash) {
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
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
            } else if (this.currentGeohash) {
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
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
            } else if (this.currentGeohash) {
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
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
            } else if (this.currentGeohash) {
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
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
            } else if (this.currentGeohash) {
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
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
            } else if (this.currentGeohash) {
                await this.publishMessage(content, this.currentGeohash, this.currentGeohash);
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
    }

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
    }

    async cmdZap(args) {
        if (!args) {
            this.displaySystemMessage('Usage: /zap nym, /zap nym#xxxx, or /zap [pubkey]');
            return;
        }

        const targetInput = args.trim().replace(/^@/, '');

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

        // If currently in this channel, switch to #nym
        if ((this.currentChannel === channel && this.currentGeohash === geohash) ||
            (geohash && this.currentGeohash === geohash)) {
            this.switchChannel('nym', 'nym');
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
    }

    updateHiddenChannelsList() {
        const container = document.getElementById('hiddenChannelsList');
        if (!container) return;

        if (this.hiddenChannels.size === 0) {
            container.innerHTML = '<div style="color: var(--text-dim); font-size: 12px;">No hidden channels</div>';
        } else {
            container.innerHTML = Array.from(this.hiddenChannels).map(key => {
                const displayName = `#${key}`;
                const location = this.getGeohashLocation(key);
                const label = location ? `${this.escapeHtml(displayName)} (${this.escapeHtml(location)})` : this.escapeHtml(displayName);
                return `
        <div class="blocked-item">
            <span>${label}</span>
            <button class="unblock-btn" onclick="nym.unhideChannelFromSettings('${this.escapeHtml(key)}')">Unhide</button>
        </div>
    `;
            }).join('');
        }
    }

    unhideChannelFromSettings(key) {
        this.hiddenChannels.delete(key);
        this.saveHiddenChannels();
        this.applyHiddenChannels();
        this.updateHiddenChannelsList();
    }

    switchChannel(channel, geohash = '') {
        // Store previous state
        const previousChannel = this.currentChannel;
        const previousGeohash = this.currentGeohash;

        // Check if we're actually switching to a different channel
        const isSameChannel = !this.inPMMode &&
            channel === previousChannel &&
            geohash === previousGeohash;

        if (isSameChannel) {
            // Check if the DOM is out of sync with the message store
            // (e.g. too many messages arrived and virtual scroll state is stale)
            const container = document.getElementById('messagesContainer');
            const storageKey = geohash ? `#${geohash}` : channel;
            const storedCount = (this.messages.get(storageKey) || []).length;
            const domCount = container ? container.querySelectorAll('.message[data-message-id]').length : 0;

            // If there are stored messages but none in the DOM, force a re-render
            if (storedCount > 0 && domCount === 0) {
                // Clear lastChannel so loadChannelMessages won't skip
                if (container) container.dataset.lastChannel = '';
                // Fall through to full channel load below
            } else {
                // Still ensure the sidebar active state is correct (for initialization)
                document.querySelectorAll('.channel-item').forEach(item => {
                    const isActive = item.dataset.channel === channel &&
                        item.dataset.geohash === geohash;
                    item.classList.toggle('active', isActive);
                });
                return; // Don't reload the same channel
            }
        }

        this.inPMMode = false;
        this.currentPM = null;
        this.currentChannel = channel;
        this.currentGeohash = geohash;
        this.userScrolledUp = false;

        // Handle geo-relay connections for Bitchat compatibility
        // Clean up previous geo relays if switching away from a geohash channel
        if (previousGeohash && previousGeohash !== geohash) {
            this.cleanupGeoRelays(previousGeohash);
        }

        // Connect to nearby relays for geohash channels (async, non-blocking)
        if (geohash) {
            this.connectToGeoRelays(geohash);
        }

        // Always ensure default relays (first 5 broadcast) stay connected
        this.ensureDefaultRelaysConnected();

        // This ensures we get more messages even with few relays connected
        const channelType = geohash ? 'geohash' : 'ephemeral';
        const channelKey = geohash || channel;
        this.loadChannelFromRelays(channelKey, channelType);

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
        if (!document.querySelector(`[data-channel="${channel}"][data-geohash="${geohash}"]`)) {
            this.addChannel(channel, geohash);
        }

        // Update active state
        document.querySelectorAll('.channel-item').forEach(item => {
            const isActive = item.dataset.channel === channel &&
                item.dataset.geohash === geohash;
            item.classList.toggle('active', isActive);
        });

        document.querySelectorAll('.pm-item').forEach(item => {
            item.classList.remove('active');
        });

        // Clear unread count
        const unreadKey = geohash ? `#${geohash}` : channel;
        this.clearUnreadCount(unreadKey);

        // Load channel messages - loadChannelMessages has its own dedup check
        // via container.dataset.lastChannel, so always call it to handle
        // switching back from PM mode to the same channel correctly
        this.loadChannelMessages(displayName);

        // Update user list for this channel
        this.updateUserList();

        // Track current channel for auto-ephemeral session resume
        if (localStorage.getItem('nym_auto_ephemeral') === 'true') {
            localStorage.setItem('nym_auto_ephemeral_channel', JSON.stringify({
                channel: channel,
                geohash: geohash
            }));
        }

        // Close mobile sidebar on mobile
        if (window.innerWidth <= 768) {
            this.closeSidebar();
        }
    }


    cacheCurrentContainerDOM() {
        const container = document.getElementById('messagesContainer');
        const previousKey = container.dataset.lastChannel;
        if (!previousKey || container.children.length === 0) return;

        const fragment = document.createDocumentFragment();
        while (container.firstChild) {
            fragment.appendChild(container.firstChild);
        }

        // Get message count and fingerprint for cache invalidation
        const messages = this.messages.get(previousKey) || this.pmMessages.get(previousKey) || [];
        this.channelDOMCache.set(previousKey, {
            fragment,
            messageCount: messages.length,
            messageFingerprint: this._computeMessageFingerprint(messages),
            virtualScrollState: {
                currentStartIndex: this.virtualScroll.currentStartIndex,
                currentEndIndex: this.virtualScroll.currentEndIndex
            }
        });

        // Limit cache to 5 channels to prevent memory bloat
        if (this.channelDOMCache.size > 5) {
            const oldestKey = this.channelDOMCache.keys().next().value;
            this.channelDOMCache.delete(oldestKey);
        }
    }

    // Compute a lightweight fingerprint of messages for cache invalidation.
    // Detects changes in count, message IDs, and delivery status.
    _computeMessageFingerprint(messages) {
        if (!messages || messages.length === 0) return '';
        // Use last 10 messages for efficiency — most changes happen at the tail
        const tail = messages.slice(-10);
        return tail.map(m => `${m.id}:${m.deliveryStatus || ''}`).join('|');
    }

    loadChannelMessages(displayName) {
        const container = document.getElementById('messagesContainer');
        const storageKey = this.currentGeohash ? `#${this.currentGeohash}` : this.currentChannel;

        // Check if we're loading the same channel
        if (container.dataset.lastChannel === storageKey) {
            return;
        }

        // Cancel any in-progress batched render for the previous channel
        if (this._renderAbortKey) {
            this._renderAbortKey = null;
        }

        // Cache current container DOM before switching
        this.cacheCurrentContainerDOM();
        container.dataset.lastChannel = storageKey;

        // Try to restore from cache if messages haven't changed
        const channelMessages = this.messages.get(storageKey) || [];
        const cached = this.channelDOMCache.get(storageKey);
        const currentFingerprint = this._computeMessageFingerprint(channelMessages);

        if (cached && cached.messageCount === channelMessages.length &&
            cached.messageFingerprint === currentFingerprint) {
            // Message count unchanged, restore cached DOM instantly
            container.innerHTML = '';
            container.appendChild(cached.fragment);
            this.channelDOMCache.delete(storageKey);

            // Restore virtual scroll state
            this.virtualScroll.currentStartIndex = cached.virtualScrollState.currentStartIndex;
            this.virtualScroll.currentEndIndex = cached.virtualScrollState.currentEndIndex;

            // Scroll to bottom
            if (this.settings.autoscroll) {
                this._suppressInputButtonHide = true;
                requestAnimationFrame(() => {
                    container.scrollTop = container.scrollHeight;
                    setTimeout(() => {
                        this._suppressInputButtonHide = false;
                    }, 300);
                });
            }
            return;
        }

        // Cache miss or stale (new messages arrived) - render fresh
        this.channelDOMCache.delete(storageKey);
        container.innerHTML = '';

        if (channelMessages.length === 0) {
            this.displaySystemMessage(`Joined ${displayName}`);
            return;
        }

        // Use virtual scrolling for efficient rendering (batched to prevent freeze)
        this.renderMessagesWithVirtualScroll(container, storageKey, true);
    }

    displayAllChannelMessages(storageKey) {
        const container = document.getElementById('messagesContainer');
        container.innerHTML = '';

        // Get filtered messages using the shared filter function
        const filteredMessages = this.getFilteredMessages(storageKey);

        // Show loading indicator for large sets
        if (filteredMessages.length > 1000) {
            this.displaySystemMessage('Loading all messages...');
        }

        // Use requestAnimationFrame to prevent blocking
        let index = 0;
        const batchSize = 50;

        const renderBatch = () => {
            const batch = filteredMessages.slice(index, index + batchSize);

            batch.forEach(msg => {
                this.displayMessage(msg);
            });

            index += batchSize;

            if (index < filteredMessages.length) {
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

    // Initialize virtual scroll for a container

    // Get filtered messages for a storage key (applies block filters)
    getFilteredMessages(storageKey) {
        const messages = this.messages.get(storageKey) || [];

        return messages.filter(msg => {
            if (this.blockedUsers.has(msg.pubkey) || this.isNymBlocked(msg.author) || msg.blocked) return false;
            if (this.hasBlockedKeyword(msg.content)) return false;
            if (this.isSpamMessage(msg.content)) return false;
            return true;
        }).sort((a, b) => a.timestamp - b.timestamp);
    }

    // Get filtered PM messages for a conversation key
    getFilteredPMMessages(conversationKey) {
        const pmMessages = this.pmMessages.get(conversationKey) || [];

        return pmMessages.filter(msg => {
            // Check if message is from blocked user
            if (this.blockedUsers.has(msg.pubkey) || msg.blocked) return false;
            // Check if message content is spam
            if (this.isSpamMessage(msg.content)) return false;
            // Ensure the message is between the current user and the PM recipient only
            if (msg.conversationKey !== conversationKey) return false;
            if (msg.pubkey !== this.pubkey && msg.pubkey !== this.currentPM) return false;
            return true;
        }).sort((a, b) => a.timestamp - b.timestamp);
    }

    // Render all messages for a channel or PM conversation
    // isPM: if true, uses pmMessages with conversationKey instead of messages with storageKey
    renderMessagesWithVirtualScroll(container, storageKey, scrollToBottom = true, isPM = false) {
        const messages = isPM ? this.getFilteredPMMessages(storageKey) : this.getFilteredMessages(storageKey);

        // Store context for scroll handlers
        container.dataset.virtualScrollKey = storageKey;
        container.dataset.virtualScrollIsPM = isPM ? 'true' : 'false';

        // Clear container
        container.innerHTML = '';

        if (messages.length === 0) {
            return;
        }

        // If this channel has reached the message limit, show a notice at the top
        if (!isPM && messages.length >= this.channelMessageLimit) {
            const notice = document.createElement('div');
            notice.className = 'system-message channel-history-limit';
            notice.textContent = 'You\'ve reached the edge of this channel\'s history. Older messages are lost to the void — only the latest 100 messages are shown.';
            container.appendChild(notice);
        }

        // Render all messages sorted by timestamp
        this.virtualScroll.suppressAutoScroll = true;

        // Suppress input-button hiding during initial render + scroll-to-bottom
        // so that the programmatic scroll doesn't trigger the hide logic
        this._suppressInputButtonHide = true;

        for (let i = 0; i < messages.length; i++) {
            this.displayMessage(messages[i]);
        }

        this.virtualScroll.suppressAutoScroll = false;

        // Scroll to bottom if requested
        if (scrollToBottom && this.settings.autoscroll) {
            requestAnimationFrame(() => {
                container.scrollTop = container.scrollHeight;
                // Clear the suppression after the scroll-to-bottom settles
                setTimeout(() => {
                    this._suppressInputButtonHide = false;
                }, 300);
            });
        } else {
            // Clear suppression after a brief delay if not scrolling
            setTimeout(() => {
                this._suppressInputButtonHide = false;
            }, 300);
        }
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
                this.currentChannel === channel &&
                (this.currentGeohash || '') === geohash;
            if (isCurrentChannel) {
                item.classList.add('active');
            }

            const displayName = geohash ? `#${geohash}` : `#${channel}`;

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

            const pinButton = `
    <span class="pin-btn ${isPinned ? 'pinned' : ''}" data-channel="${channel}" data-geohash="${geohash}">
        <svg viewBox="0 0 24 24">
            <path d="M16,12V4H17V2H7V4H8V12L6,14V16H11.2V22H12.8V16H18V14L16,12Z"/>
        </svg>
    </span>
`;

            const hideButton = `
    <span class="hide-btn" data-channel="${channel}" data-geohash="${geohash}" title="Hide channel">
        <svg viewBox="0 0 24 24">
            <path d="M12 7c2.76 0 5 2.24 5 5 0 .65-.13 1.26-.36 1.83l2.92 2.92c1.51-1.26 2.7-2.89 3.43-4.75-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25-3.98.7l2.16 2.16C10.74 7.13 11.35 7 12 7zM2 4.27l2.28 2.28.46.46A11.8 11.8 0 0 0 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 4.38-.84l.42.42L19.73 22 21 20.73 3.27 3 2 4.27zM7.53 9.8l1.55 1.55c-.05.21-.08.43-.08.65 0 1.66 1.34 3 3 3 .22 0 .44-.03.65-.08l1.55 1.55c-.67.33-1.41.53-2.2.53-2.76 0-5-2.24-5-5 0-.79.2-1.53.53-2.2zm4.31-.78l3.15 3.15.02-.16c0-1.66-1.34-3-3-3l-.17.01z"/>
        </svg>
    </span>
`;

            item.innerHTML = `
    <span class="channel-name"${locationHint}>${displayName}</span>
    <div class="channel-badges">
        ${hideButton}
        ${pinButton}
        <span class="unread-badge" style="display:none">0</span>
    </div>
`;

            // Add pin button handler
            const pinBtn = item.querySelector('.pin-btn');
            if (pinBtn) {
                pinBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    e.preventDefault();
                    this.togglePin(channel, geohash);
                });
            }

            // Add hide button handler
            const hideBtn = item.querySelector('.hide-btn');
            if (hideBtn) {
                hideBtn.addEventListener('click', (e) => {
                    e.stopPropagation();
                    e.preventDefault();
                    this.toggleHideChannel(channel, geohash);
                });
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
            this.applyHiddenChannels();

            // Hide new channel if it doesn't match active search filter
            const searchInput = document.getElementById('channelSearch');
            if (searchInput && searchInput.value.trim().length > 0) {
                const term = searchInput.value.toLowerCase();
                const channelName = item.querySelector('.channel-name').textContent.toLowerCase();
                if (!channelName.includes(term)) {
                    item.style.display = 'none';
                    item.classList.add('search-hidden');
                }
            }

            // Check if we need to add/update view more button
            this.updateViewMoreButton('channelList');
        }
    }

    updateViewMoreButton(listId) {
        const list = document.getElementById(listId);
        if (!list) return;

        // Don't manage view more button if search is active
        const searchWrapper = list.parentElement?.querySelector('.search-input-wrapper');
        const searchInput = searchWrapper?.querySelector('.search-input');
        if (searchInput && searchInput.value.trim().length > 0) {
            // Hide the view-more button during active search
            const existingBtn = list.querySelector('.view-more-btn');
            if (existingBtn) {
                existingBtn.style.display = 'none';
            }
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
                existingBtn.textContent = `View ${this.abbreviateNumber(items.length - 20)} more...`;
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
                btn.textContent = `View ${this.abbreviateNumber(items.length - 20)} more...`;
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

        // Don't allow removing default channel #nym
        if (key === 'nym') {
            this.displaySystemMessage('Cannot remove the default #nym channel');
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

        // If we're currently in this channel, switch to #nym
        if ((this.currentChannel === channel && this.currentGeohash === geohash) ||
            (geohash && this.currentGeohash === geohash)) {
            this.switchChannel('nym', 'nym');
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

                // Don't allow removing default channel #nym
                const key = geohash || channel;
                if (key === 'nym') {
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
            if (this.userJoinedChannels.has(key)) {
                userChannels.push({
                    key: key,
                    channel: value.channel,
                    geohash: value.geohash
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

                userChannels.forEach(({ key, channel, geohash }) => {
                    // Only restore geohash channels
                    if (geohash && this.isValidGeohash(geohash)) {
                        if (!this.channels.has(key)) {
                            this.addChannel(channel, geohash);
                        }
                        this.userJoinedChannels.add(key);
                    }
                });

                // Sort channels after loading
                this.sortChannelsByActivity();

                const channelCount = userChannels.filter(c => c.geohash).length;
                if (channelCount > 0) {
                    this.displaySystemMessage(`Restored ${channelCount} previously joined channels`);
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
                selector = `[data-channel="${channel}"][data-geohash=""]`;
            }

            const badge = document.querySelector(`${selector} .unread-badge`);
            if (badge) {
                badge.textContent = count > 99 ? '99+' : count;
                badge.style.display = count > 0 ? 'block' : 'none';
            }
        }

        // Re-sort channels by activity (debounced to prevent DOM thrashing
        // that makes channel links unclickable during rapid message bursts)
        if (this._sortDebounceTimer) clearTimeout(this._sortDebounceTimer);
        this._sortDebounceTimer = setTimeout(() => {
            this._sortDebounceTimer = null;
            this.sortChannelsByActivity();
        }, 300);
    }

    sortChannelsByActivity() {
        const channelList = document.getElementById('channelList');
        const channels = Array.from(channelList.querySelectorAll('.channel-item'));

        // Save view more button if it exists
        const viewMoreBtn = channelList.querySelector('.view-more-btn');

        // Store current scroll position
        const scrollTop = channelList.scrollTop;

        channels.sort((a, b) => {
            // #nym is always first
            const aIsDefault = a.dataset.geohash === 'nym';
            const bIsDefault = b.dataset.geohash === 'nym';

            if (aIsDefault) return -1;
            if (bIsDefault) return 1;

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
            const aChannel = a.dataset.geohash ? `#${a.dataset.geohash}` : a.dataset.channel;
            const bChannel = b.dataset.geohash ? `#${b.dataset.geohash}` : b.dataset.channel;

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

        // Apply hidden channel visibility
        this.applyHiddenChannels();

        // Re-apply channel search filter if search is active
        const searchInput = document.getElementById('channelSearch');
        if (searchInput && searchInput.value.trim().length > 0) {
            this.filterChannels(searchInput.value);
        }

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
                selector = `[data-channel="${channel}"][data-geohash=""]`;
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
        const picker = document.getElementById('emojiPicker');
        if (!picker) return;

        // Build reverse lookup for names
        const emojiToNames = {};
        Object.entries(this.emojiMap).forEach(([name, emoji]) => {
            if (!emojiToNames[emoji]) emojiToNames[emoji] = [];
            emojiToNames[emoji].push(name);
        });

        let html = `<div class="emoji-picker-search">
            <input type="text" class="emoji-picker-search-input" placeholder="Search emoji..." id="emojiPickerSearch">
        </div>`;

        // Recent emojis section
        if (this.recentEmojis.length > 0) {
            html += `<div class="emoji-picker-section" data-category="recent">
                <div class="emoji-picker-section-title">Recent</div>
                <div class="emoji-picker-grid">
                    ${this.recentEmojis.map(emoji => {
                const names = emojiToNames[emoji] || [];
                return `<button class="emoji-btn" data-emoji="${emoji}" data-names="${names.join(' ')}" title="${names.join(', ')}">${emoji}</button>`;
            }).join('')}
                </div>
            </div>`;
        }

        // All category sections
        Object.entries(this.allEmojis).forEach(([category, emojis]) => {
            html += `<div class="emoji-picker-section" data-category="${category}">
                <div class="emoji-picker-section-title">${category.charAt(0).toUpperCase() + category.slice(1)}</div>
                <div class="emoji-picker-grid">
                    ${emojis.map(emoji => {
                const names = emojiToNames[emoji] || [];
                return `<button class="emoji-btn" data-emoji="${emoji}" data-names="${names.join(' ')}" title="${names.join(', ')}">${emoji}</button>`;
            }).join('')}
                </div>
            </div>`;
        });

        picker.innerHTML = html;

        // Search handler
        const searchInput = picker.querySelector('#emojiPickerSearch');
        if (searchInput) {
            searchInput.addEventListener('input', (e) => {
                const search = e.target.value.toLowerCase();
                picker.querySelectorAll('.emoji-btn').forEach(btn => {
                    const names = btn.dataset.names || '';
                    const shouldShow = !search ||
                        btn.textContent.includes(search) ||
                        names.toLowerCase().includes(search);
                    btn.style.display = shouldShow ? '' : 'none';
                });
                picker.querySelectorAll('.emoji-picker-section').forEach(section => {
                    const hasVisible = Array.from(section.querySelectorAll('.emoji-btn'))
                        .some(btn => btn.style.display !== 'none');
                    section.style.display = hasVisible ? '' : 'none';
                });
            });
        }

        // Click handlers
        picker.querySelectorAll('.emoji-btn').forEach(btn => {
            btn.onclick = () => this.insertEmoji(btn.dataset.emoji || btn.textContent);
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
                    icon: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><rect width="100" height="100" fill="%23000"/><text x="50" y="55" font-size="24" fill="%230ff" text-anchor="middle" font-family="monospace">Nymchat</text></svg>',
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
                        } else if (channelInfo.type === 'geohash') {
                            this.switchChannel(channelInfo.channel, channelInfo.geohash);
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
                } else if (channelInfo.type === 'geohash') {
                    this.switchChannel(channelInfo.channel, channelInfo.geohash);
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

        const isLight = document.body.classList.contains('light-mode');

        const themes = {
            matrix: {
                dark: {
                    primary: '#00ff00',
                    secondary: '#00ffff',
                    text: '#00ff00',
                    textDim: '#00BD00',
                    textBright: '#00ffaa',
                    lightning: '#f7931a'
                },
                light: {
                    primary: '#007a00',
                    secondary: '#007a7a',
                    text: '#006600',
                    textDim: '#558855',
                    textBright: '#004d00',
                    lightning: '#c47a15'
                }
            },
            amber: {
                dark: {
                    primary: '#ffb000',
                    secondary: '#ffd700',
                    text: '#ffb000',
                    textDim: '#cc8800',
                    textBright: '#ffcc00',
                    lightning: '#ffa500'
                },
                light: {
                    primary: '#9a6a00',
                    secondary: '#8a7200',
                    text: '#7a5500',
                    textDim: '#8a7a55',
                    textBright: '#5a3a00',
                    lightning: '#b87300'
                }
            },
            cyber: {
                dark: {
                    primary: '#ff00ff',
                    secondary: '#00ffff',
                    text: '#ff00ff',
                    textDim: '#DB16DB',
                    textBright: '#ff66ff',
                    lightning: '#ffaa00'
                },
                light: {
                    primary: '#990099',
                    secondary: '#007a7a',
                    text: '#880088',
                    textDim: '#885588',
                    textBright: '#660066',
                    lightning: '#b87300'
                }
            },
            hacker: {
                dark: {
                    primary: '#00ffff',
                    secondary: '#00ff00',
                    text: '#00ffff',
                    textDim: '#01c2c2',
                    textBright: '#66ffff',
                    lightning: '#00ff88'
                },
                light: {
                    primary: '#007a7a',
                    secondary: '#007a00',
                    text: '#006666',
                    textDim: '#558888',
                    textBright: '#004d4d',
                    lightning: '#009955'
                }
            },
            ghost: {
                dark: {
                    primary: '#ffffff',
                    secondary: '#cccccc',
                    text: '#ffffff',
                    textDim: '#cccccc',
                    textBright: '#ffffff',
                    lightning: '#dddddd'
                },
                light: {
                    primary: '#333333',
                    secondary: '#555555',
                    text: '#222222',
                    textDim: '#777777',
                    textBright: '#000000',
                    lightning: '#999999'
                }
            },
            bitchat: {
                dark: {
                    primary: '#00ff00',
                    secondary: '#00ffff',
                    text: '#00ff00',
                    textDim: '#cccccc',
                    textBright: '#00ffaa',
                    lightning: '#f7931a'
                },
                light: {
                    primary: '#007a00',
                    secondary: '#007a7a',
                    text: '#006600',
                    textDim: '#666666',
                    textBright: '#004d00',
                    lightning: '#c47a15'
                }
            }
        };

        const mode = isLight ? 'light' : 'dark';
        const selectedTheme = themes[theme] && themes[theme][mode];
        if (selectedTheme) {
            Object.entries(selectedTheme).forEach(([key, value]) => {
                const cssVar = `--${key.replace(/([A-Z])/g, '-$1').toLowerCase()}`;
                root.style.setProperty(cssVar, value);
            });
        }
        this.refreshMessages();
    }

    getColorMode() {
        return localStorage.getItem('nym_color_mode') || 'auto';
    }

    resolveColorMode() {
        const mode = this.getColorMode();
        if (mode === 'light') return 'light';
        if (mode === 'dark') return 'dark';
        // auto: use system preference
        return window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
    }

    applyColorMode(mode) {
        const resolved = mode || this.resolveColorMode();
        if (resolved === 'light') {
            document.body.classList.add('light-mode');
        } else {
            document.body.classList.remove('light-mode');
        }
        // Re-apply current theme to pick up light/dark color variants
        this.applyTheme(this.settings.theme);
    }

    setupColorModeListener() {
        this._colorModeMediaQuery = window.matchMedia('(prefers-color-scheme: light)');
        this._colorModeHandler = () => {
            if (this.getColorMode() === 'auto') {
                this.applyColorMode();
            }
        };
        this._colorModeMediaQuery.addEventListener('change', this._colorModeHandler);
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

    loadSettings() {
        let pinnedLandingChannel;
        try {
            const saved = localStorage.getItem('nym_pinned_landing_channel');
            pinnedLandingChannel = saved ? JSON.parse(saved) : { type: 'geohash', geohash: 'nym' };
        } catch (e) {
            pinnedLandingChannel = { type: 'geohash', geohash: 'nym' };
        }

        return {
            theme: localStorage.getItem('nym_theme') || 'bitchat',
            sound: localStorage.getItem('nym_sound') || 'beep',
            autoscroll: localStorage.getItem('nym_autoscroll') !== 'false',
            showTimestamps: localStorage.getItem('nym_timestamps') !== 'false',
            sortByProximity: localStorage.getItem('nym_sort_proximity') === 'true',
            timeFormat: localStorage.getItem('nym_time_format') || '12hr',
            dmForwardSecrecyEnabled: localStorage.getItem('nym_dm_fwdsec_enabled') === 'true',
            dmTTLSeconds: parseInt(localStorage.getItem('nym_dm_ttl_seconds') || '86400', 10),
            readReceiptsEnabled: localStorage.getItem('nym_read_receipts_enabled') !== 'false',  // Enabled by default
            pinnedLandingChannel: pinnedLandingChannel,
            nickStyle: localStorage.getItem('nym_nick_style') || 'fancy'
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

    abbreviateNumber(n) {
        if (n < 1000) return String(n);
        if (n < 1000000) return (n / 1000).toFixed(n < 10000 ? 1 : 0) + 'k';
        return (n / 1000000).toFixed(1) + 'M';
    }

    async findUserPubkey(input) {
        const cleanInput = input.replace(/^@/, '');
        const hashIndex = cleanInput.indexOf('#');
        let searchNym = cleanInput;
        let searchSuffix = null;

        if (hashIndex !== -1) {
            searchNym = cleanInput.substring(0, hashIndex);
            searchSuffix = cleanInput.substring(hashIndex + 1);
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

        }

        if (matches.length === 0) {
            this.displaySystemMessage(`User ${cleanInput} not found. Try using the full nym#xxxx format if you know their pubkey suffix.`);
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

}

// Global instance
const nym = new NYM();

// Global functions for onclick handlers
function toggleSidebar() {
    nym.toggleSidebar();
}

function toggleSearch(inputId) {
    const wrapper = document.getElementById(inputId + 'Wrapper');
    const search = document.getElementById(inputId);
    if (wrapper) {
        wrapper.classList.toggle('active');
        if (wrapper.classList.contains('active')) {
            search.focus();
        } else {
            // Clear search when hiding
            clearSearch(inputId);
        }
    } else {
        // Fallback for inputs without wrapper
        search.classList.toggle('active');
        if (search.classList.contains('active')) {
            search.focus();
        }
    }
}

function clearSearch(inputId) {
    const search = document.getElementById(inputId);
    const wrapper = document.getElementById(inputId + 'Wrapper');
    if (search) {
        search.value = '';
        if (wrapper) {
            wrapper.classList.remove('has-value', 'active');
        }
        // Trigger the appropriate filter to reset the list
        if (inputId === 'pmSearch') {
            nym.filterPMs('');
        } else if (inputId === 'channelSearch') {
            nym.handleChannelSearch('');
        } else if (inputId === 'userSearch') {
            nym.filterUsers('');
        }
    }
}

function scrollToBottom() {
    const container = document.getElementById('messagesContainer');
    if (!container) return;

    // User explicitly wants to go to the bottom — clear the scrolled-up flag
    nym.userScrolledUp = false;

    // Cancel any pending coalesced scroll so we can do it immediately
    if (nym._scrollRAF) {
        cancelAnimationFrame(nym._scrollRAF);
        nym._scrollRAF = null;
    }

    // Force scroll to bottom immediately, then again on next frame to handle
    // any pending layout changes (images loading, animations, etc.)
    container.scrollTop = container.scrollHeight;
    nym._scheduleScrollToBottom(true);
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
    // Only show the base nym (without #suffix) in the editable field
    const baseNym = nym.parseNymFromDisplay(nym.nym);
    document.getElementById('newNickInput').value = baseNym;
    // Show the non-editable suffix next to the input
    const suffix = nym.getPubkeySuffix(nym.pubkey);
    const suffixEl = document.getElementById('nickSuffixDisplay');
    suffixEl.textContent = `#${suffix}`;
    suffixEl.title = 'Click to view full pubkey';

    // Click handler to show full pubkey tooltip
    suffixEl.onclick = (e) => {
        e.stopPropagation();
        // Remove any existing tooltip
        const existing = document.getElementById('pubkeyTooltip');
        if (existing) { existing.remove(); return; }

        const tooltip = document.createElement('div');
        tooltip.id = 'pubkeyTooltip';
        tooltip.className = 'pubkey-tooltip';
        tooltip.innerHTML = `
            <div class="pubkey-tooltip-label">Full Hex Pubkey</div>
            <div class="pubkey-tooltip-value">${nym.pubkey}</div>
            <button class="pubkey-tooltip-copy" onclick="event.stopPropagation(); navigator.clipboard.writeText('${nym.pubkey}'); this.textContent='Copied!'; setTimeout(() => this.textContent='Copy', 1200);">Copy</button>
        `;
        suffixEl.appendChild(tooltip);

        // Close on outside click
        const closeTooltip = (ev) => {
            if (!tooltip.contains(ev.target) && ev.target !== suffixEl) {
                tooltip.remove();
                document.removeEventListener('click', closeTooltip);
            }
        };
        setTimeout(() => document.addEventListener('click', closeTooltip), 0);
    };

    // Show current avatar in edit modal and reset upload UI state
    const preview = document.getElementById('nickEditAvatarPreview');
    if (preview) {
        preview.src = nym.getAvatarUrl(nym.pubkey);
    }
    const hasCustom = nym.userAvatars.has(nym.pubkey);
    setAvatarUploadState('nickEdit', {
        spinning: false, statusText: '', statusType: '',
        btnText: 'Change photo', btnDisabled: false, showRemove: hasCustom
    });

    document.getElementById('nickEditModal').classList.add('active');
}

async function changeNick() {
    const newNick = document.getElementById('newNickInput').value.trim();
    // Strip any # suffix the user may have typed - the suffix is derived from pubkey
    const baseNick = nym.parseNymFromDisplay(newNick);
    const currentBase = nym.parseNymFromDisplay(nym.nym);
    if (baseNick && baseNick !== currentBase) {
        closeModal('nickEditModal');
        const cmdResult = await nym.cmdNick(baseNick);
        // If auto-ephemeral is enabled, persist the new nickname so it's reused on next session
        if (localStorage.getItem('nym_auto_ephemeral') === 'true') {
            localStorage.setItem('nym_auto_ephemeral_nick', baseNick);
            // For reserved (developer) nicks, also save the verified nsec for auto-login
            if (cmdResult && cmdResult.nsec) {
                localStorage.setItem('nym_dev_nsec', cmdResult.nsec);
            }
        }
        return;
    }
    closeModal('nickEditModal');
}

function randomizeNick() {
    const generated = nym.generateRandomNym();
    // Extract base name without #suffix
    const baseName = generated.split('#')[0];
    document.getElementById('newNickInput').value = baseName;

    // Randomize the robohash avatar preview if no custom avatar is set
    if (!nym.userAvatars.has(nym.pubkey)) {
        const preview = document.getElementById('nickEditAvatarPreview');
        if (preview) {
            preview.src = `https://robohash.org/${encodeURIComponent(baseName)}.png?set=set1&size=80x80`;
        }
    }
}

// Pre-generated keypair from setup modal avatar upload (reused in initializeNym)
let setupKeypair = null;
// Uploaded avatar URL from setup modal (applied to profile in initializeNym)
let setupAvatarUrl = null;

function setAvatarUploadState(prefix, { spinning, statusText, statusType, btnText, btnDisabled, showRemove }) {
    const spinner = document.getElementById(prefix + 'AvatarSpinner');
    const status = document.getElementById(prefix + 'AvatarStatus');
    const uploadBtn = document.getElementById(prefix + 'AvatarUploadBtn');
    const removeBtn = document.getElementById(prefix + 'AvatarRemoveBtn');
    if (spinner) spinner.classList.toggle('active', !!spinning);
    if (status) {
        status.textContent = statusText || '';
        status.className = 'avatar-upload-status' + (statusType ? ' ' + statusType : '');
    }
    if (uploadBtn && btnText !== undefined) {
        uploadBtn.textContent = btnText;
        uploadBtn.disabled = !!btnDisabled;
    }
    if (removeBtn && showRemove !== undefined) {
        removeBtn.style.display = showRemove ? 'inline-flex' : 'none';
    }
}

async function handleSetupAvatarSelect(event) {
    const file = event?.target?.files?.[0];
    if (!file) return;

    if (file.type && !file.type.startsWith('image/')) {
        setAvatarUploadState('setup', { statusText: 'Please select an image file', statusType: 'error' });
        return;
    }
    if (file.size > 5 * 1024 * 1024) {
        setAvatarUploadState('setup', { statusText: 'Image must be under 5MB', statusType: 'error' });
        return;
    }

    const preview = document.getElementById('setupAvatarPreview');

    // Show local preview immediately using object URL (like wallpaper uploader)
    if (preview) {
        preview.src = URL.createObjectURL(file);
    }

    // Show uploading state
    setAvatarUploadState('setup', {
        spinning: true,
        statusText: 'Uploading avatar...',
        statusType: 'uploading',
        btnText: 'Uploading...',
        btnDisabled: true,
        showRemove: false
    });

    // Generate keypair in background if not already done
    if (!setupKeypair) {
        setupKeypair = await nym.generateKeypair();
    }

    const url = await nym.uploadAvatar(file);

    if (url) {
        setupAvatarUrl = url;
        if (preview) preview.src = url;
        setAvatarUploadState('setup', {
            spinning: false,
            statusText: 'Avatar uploaded successfully',
            statusType: 'success',
            btnText: 'Change photo',
            btnDisabled: false,
            showRemove: true
        });
    } else {
        if (preview) preview.src = 'https://robohash.org/default.png?set=set1&size=80x80';
        setAvatarUploadState('setup', {
            spinning: false,
            statusText: 'Upload failed — try again',
            statusType: 'error',
            btnText: 'Choose photo',
            btnDisabled: false,
            showRemove: false
        });
    }

    // Reset file input
    event.target.value = '';
}

function removeSetupAvatar() {
    setupAvatarUrl = null;
    if (setupKeypair) {
        const oldBlob = nym.avatarBlobCache.get(nym.pubkey);
        if (oldBlob) { URL.revokeObjectURL(oldBlob); nym.avatarBlobCache.delete(nym.pubkey); }
        nym.userAvatars.delete(nym.pubkey);
        localStorage.removeItem('nym_avatar_url');
    }
    const preview = document.getElementById('setupAvatarPreview');
    if (preview) preview.src = 'https://robohash.org/default.png?set=set1&size=80x80';
    setAvatarUploadState('setup', {
        spinning: false, statusText: '', statusType: '',
        btnText: 'Choose photo', btnDisabled: false, showRemove: false
    });
}

// Avatar upload handler for nick edit modal (uploads immediately since keypair exists)
async function handleNickEditAvatarSelect(event) {
    const file = event?.target?.files?.[0];
    if (!file) return;

    if (file.type && !file.type.startsWith('image/')) {
        setAvatarUploadState('nickEdit', { statusText: 'Please select an image file', statusType: 'error' });
        return;
    }
    if (file.size > 5 * 1024 * 1024) {
        setAvatarUploadState('nickEdit', { statusText: 'Image must be under 5MB', statusType: 'error' });
        return;
    }

    const preview = document.getElementById('nickEditAvatarPreview');

    // Show local preview immediately using object URL (like wallpaper uploader)
    if (preview) {
        preview.src = URL.createObjectURL(file);
    }

    // Show uploading state
    setAvatarUploadState('nickEdit', {
        spinning: true,
        statusText: 'Uploading avatar...',
        statusType: 'uploading',
        btnText: 'Uploading...',
        btnDisabled: true,
        showRemove: false
    });

    const url = await nym.uploadAvatar(file);

    if (url) {
        if (preview) preview.src = url;
        setAvatarUploadState('nickEdit', {
            spinning: false,
            statusText: 'Avatar updated successfully',
            statusType: 'success',
            btnText: 'Change photo',
            btnDisabled: false,
            showRemove: true
        });
    } else {
        if (preview) preview.src = nym.getAvatarUrl(nym.pubkey);
        setAvatarUploadState('nickEdit', {
            spinning: false,
            statusText: 'Upload failed — try again',
            statusType: 'error',
            btnText: 'Change photo',
            btnDisabled: false
        });
    }

    // Reset file input
    event.target.value = '';
}

function removeNickEditAvatar() {
    nym.removeAvatar();
    const preview = document.getElementById('nickEditAvatarPreview');
    if (preview) {
        preview.src = nym.getAvatarUrl(nym.pubkey);
    }
    setAvatarUploadState('nickEdit', {
        spinning: false, statusText: '', statusType: '',
        btnText: 'Change photo', btnDisabled: false, showRemove: false
    });
}

// Developer nsec verification modal state
let devNsecResolve = null;
let devNsecContext = null;

function showDevNsecModal(context) {
    return new Promise((resolve) => {
        devNsecResolve = resolve;
        devNsecContext = context;
        document.getElementById('devNsecInput').value = '';
        document.getElementById('devNsecError').style.display = 'none';
        document.getElementById('devNsecModal').classList.add('active');
    });
}

function cancelDevNsec() {
    closeModal('devNsecModal');
    if (devNsecResolve) {
        devNsecResolve(null);
        devNsecResolve = null;
    }
}

function verifyDevNsec() {
    const nsec = document.getElementById('devNsecInput').value.trim();
    const result = nym.verifyDeveloperNsec(nsec);
    if (result.valid) {
        document.getElementById('devNsecError').style.display = 'none';
        closeModal('devNsecModal');
        if (devNsecResolve) {
            devNsecResolve({ ...result, nsec });
            devNsecResolve = null;
        }
    } else {
        document.getElementById('devNsecError').style.display = 'block';
    }
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

    // Load color mode setting (auto-save and auto-apply on click)
    const colorModeGroup = document.getElementById('colorModeGroup');
    if (colorModeGroup) {
        const currentMode = nym.getColorMode();
        colorModeGroup.querySelectorAll('.color-mode-btn').forEach(btn => {
            btn.classList.toggle('active', btn.dataset.mode === currentMode);
            btn.onclick = () => {
                colorModeGroup.querySelectorAll('.color-mode-btn').forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
                localStorage.setItem('nym_color_mode', btn.dataset.mode);
                nym.applyColorMode();
            };
        });
    }

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

    // Load auto-ephemeral setting (always shown, always ephemeral mode)
    const autoEphemeralSelect = document.getElementById('autoEphemeralSelect');
    if (autoEphemeralSelect) {
        const autoEphemeral = localStorage.getItem('nym_auto_ephemeral') === 'true';
        autoEphemeralSelect.value = autoEphemeral ? 'true' : 'false';
    }

    // Load nickname style setting
    const nickStyleSelect = document.getElementById('nickStyleSelect');
    if (nickStyleSelect) {
        nickStyleSelect.value = nym.settings.nickStyle || 'fancy';
    }

    // Load hide non-pinned channels setting
    const hideNonPinnedSelect = document.getElementById('hideNonPinnedSelect');
    if (hideNonPinnedSelect) {
        hideNonPinnedSelect.value = nym.hideNonPinned ? 'true' : 'false';
    }

    // Populate hidden channels list
    nym.updateHiddenChannelsList();

    // Initialize pinned landing channel searchable dropdown
    const pinnedSearchInput = document.getElementById('pinnedLandingChannelSearch');
    const pinnedValueInput = document.getElementById('pinnedLandingChannelValue');
    const pinnedDropdown = document.getElementById('pinnedLandingChannelDropdown');

    if (pinnedSearchInput && pinnedValueInput && pinnedDropdown) {
        // Get current pinned value
        const currentPinned = nym.pinnedLandingChannel || { type: 'geohash', geohash: 'nym' };

        // Build geohash channel options only
        const channelOptions = [];

        // Add common geohashes
        nym.commonGeohashes.forEach(geohash => {
            const location = nym.getGeohashLocation(geohash);
            channelOptions.push({
                group: 'Common Geohash Channels',
                label: location ? `#${geohash} (${location})` : `#${geohash}`,
                value: { type: 'geohash', geohash: geohash },
                searchText: (geohash + ' ' + (location || '')).toLowerCase()
            });
        });

        // Add user's joined geohash channels (excluding already listed ones)
        Array.from(nym.channels.entries())
            .filter(([key, val]) => nym.isValidGeohash(key) && !nym.commonGeohashes.includes(key))
            .forEach(([geohash]) => {
                const location = nym.getGeohashLocation(geohash);
                channelOptions.push({
                    group: 'Joined Geohash Channels',
                    label: location ? `#${geohash} (${location})` : `#${geohash}`,
                    value: { type: 'geohash', geohash: geohash },
                    searchText: (geohash + ' ' + (location || '')).toLowerCase()
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
            pinnedSearchInput.value = '#nym';
            pinnedValueInput.value = JSON.stringify({ type: 'geohash', geohash: 'nym' });
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

    const themeSelect = document.getElementById('themeSelect');
    themeSelect.value = nym.settings.theme;
    themeSelect.onchange = function () {
        nym.settings.theme = this.value;
        nym.applyTheme(this.value);
        nym.saveSettings();
    };

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

    // Initialize wallpaper UI selection
    initWallpaperUI();

    // Render pending settings transfers
    nym.renderPendingSettingsTransfers();

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
    const nickStyle = document.getElementById('nickStyleSelect').value;

    // Save color mode
    const colorModeGroup = document.getElementById('colorModeGroup');
    const activeColorBtn = colorModeGroup ? colorModeGroup.querySelector('.color-mode-btn.active') : null;
    const colorMode = activeColorBtn ? activeColorBtn.dataset.mode : 'auto';
    localStorage.setItem('nym_color_mode', colorMode);
    nym.applyColorMode();

    // Save nickname style
    nym.settings.nickStyle = nickStyle;
    localStorage.setItem('nym_nick_style', nickStyle);

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

    // Handle auto-ephemeral setting
    const autoEphemeral = document.getElementById('autoEphemeralSelect').value === 'true';
    if (autoEphemeral) {
        localStorage.setItem('nym_auto_ephemeral', 'true');
    } else {
        localStorage.removeItem('nym_auto_ephemeral');
        localStorage.removeItem('nym_auto_ephemeral_nick');
        localStorage.removeItem('nym_auto_ephemeral_channel');
    }

    // Handle hide non-pinned channels setting
    const hideNonPinned = document.getElementById('hideNonPinnedSelect').value === 'true';
    nym.hideNonPinned = hideNonPinned;
    localStorage.setItem('nym_hide_non_pinned', String(hideNonPinned));
    nym.applyHiddenChannels();

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
            const defaultChannel = { type: 'geohash', geohash: 'nym' };
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

    nym.displaySystemMessage('Settings saved');

    closeModal('settingsModal');
}

function clearLocalStorageCache() {
    if (!confirm('Clear all cached settings and preferences? This will not log you out.')) {
        return;
    }

    // Preserve session identity and shop purchase keys
    const preserveKeys = {};
    for (let i = 0; i < localStorage.length; i++) {
        const key = localStorage.key(i);
        if (key && (
            key === 'nym_auto_ephemeral' ||
            key === 'nym_auto_ephemeral_nick' ||
            key === 'nym_auto_ephemeral_channel' ||
            key === 'nym_dev_nsec' ||
            key === 'nym_active_style' ||
            key === 'nym_active_flair' ||
            key === 'nym_shop_active_cache' ||
            key === 'nym_purchases_cache' ||
            key.startsWith('nym_shop_recovery_')
        )) {
            preserveKeys[key] = localStorage.getItem(key);
        }
    }

    // Remove all nym_ keys
    const keysToRemove = [];
    for (let i = 0; i < localStorage.length; i++) {
        const key = localStorage.key(i);
        if (key && key.startsWith('nym_')) {
            keysToRemove.push(key);
        }
    }
    keysToRemove.forEach(key => localStorage.removeItem(key));

    // Restore preserved keys
    for (const [key, value] of Object.entries(preserveKeys)) {
        if (value !== null) {
            localStorage.setItem(key, value);
        }
    }

    // Reset in-memory state to defaults
    nym.pinnedChannels = new Set();
    nym.hiddenChannels = new Set();
    nym.hideNonPinned = false;
    nym.blockedUsers = new Set();
    nym.blockedChannels = new Set();
    nym.blockedKeywords = new Set();
    nym.settings = nym.loadSettings();

    // Re-apply defaults visually
    nym.applyColorMode();
    nym.applyWallpaper('none');
    nym.updateChannelPins();
    nym.applyHiddenChannels();

    nym.displaySystemMessage('Local storage cache cleared. Settings reset to defaults.');
    closeModal('settingsModal');
}

// Wallpaper Functions
function selectWallpaper(type) {
    // Update selection UI
    document.querySelectorAll('.wallpaper-option').forEach(opt => {
        opt.classList.toggle('selected', opt.dataset.wallpaper === type);
    });

    // If it's not custom, apply immediately
    if (type !== 'custom') {
        nym.applyWallpaper(type);
        nym.saveWallpaper(type);
    }
}

function triggerSetupAvatarUpload() {
    document.getElementById('setupAvatarInput').click();
}

function triggerNickEditAvatarUpload() {
    document.getElementById('nickEditAvatarInput').click();
}

function triggerWallpaperUpload() {
    document.getElementById('wallpaperFileInput').click();
}

async function handleWallpaperUpload(event) {
    const file = event.target.files[0];
    if (!file) return;

    // Show uploading state
    const customOption = document.getElementById('customWallpaperOption');
    const customPreview = document.getElementById('customWallpaperPreview');
    const originalContent = customPreview.innerHTML;
    customPreview.innerHTML = '<span style="font-size: 10px; color: var(--text-dim);">Uploading...</span>';

    const url = await nym.uploadWallpaper(file);

    if (url) {
        // Update the custom preview thumbnail
        customPreview.innerHTML = '';
        customPreview.style.backgroundImage = `url('${url}')`;

        // Select custom wallpaper
        document.querySelectorAll('.wallpaper-option').forEach(opt => {
            opt.classList.toggle('selected', opt.dataset.wallpaper === 'custom');
        });

        nym.applyWallpaper('custom', url);
        nym.saveWallpaper('custom', url);
        nym.displaySystemMessage('Wallpaper uploaded and applied.');
    } else {
        customPreview.innerHTML = originalContent;
    }

    // Reset file input
    event.target.value = '';
}

function initWallpaperUI() {
    const { type, customUrl } = nym.loadWallpaper();

    // Highlight saved selection in settings grid
    document.querySelectorAll('.wallpaper-option').forEach(opt => {
        opt.classList.toggle('selected', opt.dataset.wallpaper === type);
    });

    // If custom, update the preview thumbnail
    if (type === 'custom' && customUrl) {
        const customPreview = document.getElementById('customWallpaperPreview');
        if (customPreview) {
            customPreview.innerHTML = '';
            customPreview.style.backgroundImage = `url('${customUrl}')`;
        }
    }
}

function showAbout() {
    const connectedRelays = nym.relayPool.size;
    nym.displaySystemMessage(`
═══ Nymchat v3.33.134 ═══<br/>
Protocol: <a href="https://nostr.com" target="_blank" rel="noopener" style="color: var(--secondary)">Nostr</a> (kind 20000 geohash channels)<br/>
Connected Relays: ${connectedRelays} relays<br/>
Your nym: ${nym.nym || 'Not set'}<br/>
<br/>
Inspired by and bridged with Jack Dorsey's <a href="https://bitchat.free" target="_blank" rel="noopener" style="color: var(--secondary)">Bitchat</a><br/>
<br/>
Nymchat is FOSS code on <a href="https://github.com/Spl0itable/NYM" target="_blank" rel="noopener" style="color: var(--secondary)">GitHub</a><br/>
Made with ♥ by <a href="https://nostrservices.com" target="_blank" rel="noopener" style="color: var(--secondary)">21 Million LLC</a><br/>
Lead developer: <a href="https://njump.me/npub16jdfqgazrkapk0yrqm9rdxlnys7ck39c7zmdzxtxqlmmpxg04r0sd733sv" target="_blank" rel="noopener" style="color: var(--secondary)">Luxas#a8df</a><br/>
<a href="static/tos.html" target="_blank" rel="noopener" style="color: var(--secondary)">Terms of Service</a> | <a href="static/pp.html" target="_blank" rel="noopener" style="color: var(--secondary)">Privacy Policy</a><br/>
`);
}

// Function to check for saved connection on page load
async function checkSavedConnection() {
    // Clear any legacy persistent login data
    localStorage.removeItem('nym_connection_mode');
    localStorage.removeItem('nym_nsec');
    localStorage.removeItem('nym_bunker_uri');
    localStorage.removeItem('nym_relay_url');

    // Auto-ephemeral preference
    const autoEphemeral = localStorage.getItem('nym_auto_ephemeral');
    if (autoEphemeral === 'true') {
        try {
            // Hide setup modal
            const setupModal = document.getElementById('setupModal');
            setupModal.classList.remove('active');

            let isDeveloperLogin = false;

            // Use saved custom nickname if available, otherwise random
            const savedNick = localStorage.getItem('nym_auto_ephemeral_nick');
            if (savedNick && nym.isReservedNick(savedNick)) {
                // Reserved nick - check for saved nsec to auto-verify
                const savedNsec = localStorage.getItem('nym_dev_nsec');
                if (savedNsec) {
                    const result = nym.verifyDeveloperNsec(savedNsec);
                    if (result.valid) {
                        nym.applyDeveloperIdentity(result.secretKey, result.pubkey);
                        isDeveloperLogin = true;
                        nym.displaySystemMessage('Auto-starting verified session...');
                    } else {
                        // Invalid saved nsec - clear it and use random nym
                        localStorage.removeItem('nym_dev_nsec');
                        await nym.generateKeypair();
                        nym.nym = nym.generateRandomNym();
                        nym.connectionMode = 'ephemeral';
                        nym.displaySystemMessage('Auto-starting ephemeral session...');
                    }
                } else {
                    await nym.generateKeypair();
                    nym.nym = nym.generateRandomNym();
                    nym.connectionMode = 'ephemeral';
                    nym.displaySystemMessage('Auto-starting ephemeral session...');
                }
            } else {
                // Generate ephemeral keypair
                await nym.generateKeypair();
                nym.nym = savedNick || nym.generateRandomNym();
                nym.connectionMode = 'ephemeral';
                nym.displaySystemMessage('Auto-starting ephemeral session...');
            }
            document.getElementById('currentNym').innerHTML = nym.formatNymWithPubkey(nym.nym, nym.pubkey);
            nym.updateSidebarAvatar();

            // Connect to relays
            await nym.connectToRelays();

            // Apply cached shop items (styles/flairs) to the new ephemeral identity
            nym.applyCachedShopItemsToNewIdentity();

            if (isDeveloperLogin) {
                // Developer login - load lightning address from their kind 0 profile
                await nym.loadLightningAddress();
            } else {
                // Restore lightning address from global localStorage to new session
                const globalLnAddress = localStorage.getItem('nym_lightning_address_global');
                if (globalLnAddress) {
                    nym.lightningAddress = globalLnAddress;
                    localStorage.setItem(`nym_lightning_address_${nym.pubkey}`, globalLnAddress);
                    nym.updateLightningAddressDisplay();
                }

                // Restore avatar from localStorage for ephemeral sessions
                const savedAvatarUrl = localStorage.getItem('nym_avatar_url');
                if (savedAvatarUrl) {
                    nym.userAvatars.set(nym.pubkey, savedAvatarUrl);
                    nym.cacheAvatarImage(nym.pubkey, savedAvatarUrl);
                    nym.updateSidebarAvatar();
                }

                // Publish profile with restored avatar and lightning address
                await nym.saveToNostrProfile();

                // Re-publish profile after more relays connect
                setTimeout(() => { nym.saveToNostrProfile(); }, 5000);
            }

            // Request notification permission
            if (typeof Notification !== 'undefined' && Notification.permission === 'default') {
                Notification.requestPermission();
            }

            // Welcome message
            nym.displaySystemMessage(`Welcome to Nymchat, ${nym.nym}! Type /help for available commands.`);
            if (isDeveloperLogin) {
                nym.displaySystemMessage(`Identity verified. You are now logged in as ${nym.nym}.`);
            }
            nym.displaySystemMessage(`Click on any nym's nickname for more options.`);

            // Start tutorial if not seen
            window.maybeStartTutorial(false);

            // Resume to last channel from previous auto-ephemeral session
            const savedChannel = localStorage.getItem('nym_auto_ephemeral_channel');
            if (savedChannel) {
                try {
                    const { channel, geohash } = JSON.parse(savedChannel);
                    if (channel && channel !== nym.currentChannel) {
                        if (geohash) {
                            nym.addChannel(channel, geohash);
                        }
                        nym.switchChannel(channel, geohash || '');
                    }
                } catch (e) { }
            }

            // Route to channel from URL if present (overrides saved channel)
            await routeToUrlChannel();

            return; // Exit early
        } catch (error) {
            // Clear the preference and show setup modal
            localStorage.removeItem('nym_auto_ephemeral');
            localStorage.removeItem('nym_auto_ephemeral_nick');
            document.getElementById('setupModal').classList.add('active');
            return;
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
        // Get or generate nym first
        const nymInput = document.getElementById('nymInput').value.trim();
        let isDeveloperLogin = false;

        // Check if reserved nickname
        if (nymInput && nym.isReservedNick(nymInput)) {
            const result = await showDevNsecModal('init');
            if (!result) {
                enterBtn.disabled = false;
                enterBtn.innerHTML = originalBtnText;
                return;
            }
            // Verified developer - use their persistent keypair (discard any setup modal keypair)
            setupKeypair = null;
            setupAvatarUrl = null;
            nym.applyDeveloperIdentity(result.secretKey, result.pubkey);
            isDeveloperLogin = true;
            localStorage.removeItem('nym_connection_mode');
        } else {
            // Generate ephemeral keypair (reuse if already created from avatar upload)
            nym.connectionMode = 'ephemeral';
            if (!setupKeypair) {
                await nym.generateKeypair();
            }
            nym.nym = nymInput || nym.generateRandomNym();
            document.getElementById('currentNym').innerHTML = nym.formatNymWithPubkey(nym.nym, nym.pubkey);
            nym.updateSidebarAvatar();
            localStorage.removeItem('nym_connection_mode');
        }

        // Auto-ephemeral checkbox - save custom nickname if provided
        const autoEphemeralCheckbox = document.getElementById('autoEphemeralCheckbox');
        if (autoEphemeralCheckbox && autoEphemeralCheckbox.checked) {
            localStorage.setItem('nym_auto_ephemeral', 'true');
            if (nymInput) {
                localStorage.setItem('nym_auto_ephemeral_nick', nymInput);
                // If developer verified, also save nsec for auto-login
                if (nym.isReservedNick(nymInput)) {
                    const nsecVal = document.getElementById('devNsecInput').value.trim();
                    if (nsecVal) {
                        localStorage.setItem('nym_dev_nsec', nsecVal);
                    }
                }
            }
        }

        // Connect to relays
        await nym.connectToRelays();

        // Apply cached shop items (styles/flairs) to the new ephemeral identity
        nym.applyCachedShopItemsToNewIdentity();

        if (isDeveloperLogin) {
            // Developer login - load lightning address from their kind 0 profile
            await nym.loadLightningAddress();
        } else {
            // Restore lightning address from global localStorage to new session
            const globalLnAddress = localStorage.getItem('nym_lightning_address_global');
            if (globalLnAddress) {
                nym.lightningAddress = globalLnAddress;
                localStorage.setItem(`nym_lightning_address_${nym.pubkey}`, globalLnAddress);
                nym.updateLightningAddressDisplay();
            }

            // Apply avatar: either from setup modal upload or from localStorage
            if (setupAvatarUrl) {
                // Avatar was already uploaded in the setup modal - just ensure it's applied
                nym.userAvatars.set(nym.pubkey, setupAvatarUrl);
                nym.cacheAvatarImage(nym.pubkey, setupAvatarUrl);
                localStorage.setItem('nym_avatar_url', setupAvatarUrl);
                nym.updateSidebarAvatar();
                setupAvatarUrl = null;
                setupKeypair = null;
                await nym.saveToNostrProfile();
            } else {
                // Restore avatar from localStorage for ephemeral sessions
                const savedAvatarUrl = localStorage.getItem('nym_avatar_url');
                if (savedAvatarUrl) {
                    nym.userAvatars.set(nym.pubkey, savedAvatarUrl);
                    nym.cacheAvatarImage(nym.pubkey, savedAvatarUrl);
                    nym.updateSidebarAvatar();
                }
                // Publish profile with restored avatar and/or lightning address
                await nym.saveToNostrProfile();
            }

            // Re-publish profile after more relays connect
            setTimeout(() => { nym.saveToNostrProfile(); }, 5000);
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
        nym.displaySystemMessage(`Welcome to Nymchat, ${nym.nym}! Type /help for available commands.`);
        if (isDeveloperLogin) {
            nym.displaySystemMessage(`Identity verified. You are now logged in as ${nym.nym}.`);
        }
        nym.displaySystemMessage(`Click on any nym's nickname for more options.`);

        // Route to channel from URL if present
        await routeToUrlChannel();

        // Start tutorial if not seen yet
        window.maybeStartTutorial(false);

    } catch (error) {
        // Restore button state on error
        enterBtn.disabled = false;
        enterBtn.innerHTML = originalBtnText;
        alert('Failed to initialize: ' + error.message);
    }
}



// Disconnect/logout function
function disconnectNym() {
    // Disconnect from relay
    if (nym && nym.ws) {
        nym.disconnect();
    }

    // Reload page to start fresh
    window.location.reload();
}

// Sign-out button
function signOut() {
    if (confirm('Sign out and disconnect from Nymchat?')) {
        // Clear auto-ephemeral preferences on logout
        localStorage.removeItem('nym_auto_ephemeral');
        localStorage.removeItem('nym_auto_ephemeral_nick');
        localStorage.removeItem('nym_auto_ephemeral_channel');
        localStorage.removeItem('nym_dev_nsec');
        localStorage.removeItem('nym_color_mode');
        localStorage.removeItem('nym_purchases_cache');
        localStorage.removeItem('nym_active_style');
        localStorage.removeItem('nym_active_flair');
        nym.cmdQuit();
    }
}

// Initialize on load
document.addEventListener('DOMContentLoaded', () => {
    // Parse URL for channel routing BEFORE initialization
    parseUrlChannel();

    nym.initialize();

    // Pre-select auto-ephemeral checkbox if previously enabled
    if (localStorage.getItem('nym_auto_ephemeral') === 'true') {
        const cb = document.getElementById('autoEphemeralCheckbox');
        if (cb) cb.checked = true;
    }

    // Scale logo-ascii to fit inside sidebar at any resolution
    (function scaleLogoToFit() {
        const logo = document.querySelector('.logo-ascii');
        if (!logo) return;
        const container = logo.parentElement;
        const containerWidth = container.clientWidth;
        const logoNaturalWidth = logo.scrollWidth;
        if (logoNaturalWidth > containerWidth && containerWidth > 0) {
            const scale = containerWidth / logoNaturalWidth;
            logo.style.transformOrigin = 'top center';
            logo.style.transform = `scaleX(${scale})`;
        }
    })();

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

    // Periodically update connection status (skip during initial connection)
    setInterval(() => {
        if (nym.connected && !nym.initialConnectionInProgress) {
            nym.updateConnectionStatus();
        }
    }, 1000);

    // Periodic connection health check (skip during initial connection to avoid race conditions)
    setInterval(() => {
        if (!nym.initialConnectionInProgress && (nym.connected || nym.relayPool.size > 0)) {
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

            // Prune inactive channels to 100 messages max
            if (messages.length > 100) {
                nym.messages.set(channel, messages.slice(-100));
            }
        });

        // Prune PM conversations to 100 messages max
        const currentPMKey = nym.currentPM ? nym.getPMConversationKey(nym.currentPM) : null;
        nym.pmMessages.forEach((messages, convKey) => {
            if (convKey === currentPMKey) return;
            if (messages.length > 100) {
                nym.pmMessages.set(convKey, messages.slice(-100));
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

    // Scroll-to-bottom button and mobile input-buttons hide on scroll
    const messageInput = document.getElementById('messageInput');
    const messagesContainer = document.getElementById('messagesContainer');
    const scrollToBottomBtn = document.getElementById('scrollToBottomBtn');
    const inputButtons = document.querySelector('.input-buttons');

    if (messagesContainer && scrollToBottomBtn) {
        let mobileScrollTimer = null;
        let isExpandingButtons = false;

        messagesContainer.addEventListener('scroll', () => {
            const distanceFromBottom = messagesContainer.scrollHeight - messagesContainer.scrollTop - messagesContainer.clientHeight;

            // When scrolled to the very top, show history limit notice if channel is at capacity
            if (messagesContainer.scrollTop <= 5 && !nym.inPMMode) {
                const storageKey = nym.currentGeohash ? `#${nym.currentGeohash}` : nym.currentChannel;
                const channelMessages = nym.messages.get(storageKey) || [];
                if (channelMessages.length >= nym.channelMessageLimit && !messagesContainer.querySelector('.channel-history-limit')) {
                    const notice = document.createElement('div');
                    notice.className = 'system-message channel-history-limit';
                    notice.textContent = 'You\'ve reached the edge of this channel\'s history. Older messages are lost to the void \u2014 only the latest 100 messages are shown.';
                    messagesContainer.insertBefore(notice, messagesContainer.firstChild);
                }
            }

            // Track whether user has intentionally scrolled away from the bottom.
            // This flag prevents new messages from yanking the user back to the
            // bottom while they are reading older messages. It is cleared when
            // the user scrolls back near the bottom or clicks the scroll-to-bottom button.
            // Use a single threshold (150px) to avoid a dead zone between set/clear.
            if (distanceFromBottom > 150) {
                nym.userScrolledUp = true;
            } else {
                nym.userScrolledUp = false;
            }

            // Show/hide scroll-to-bottom button
            if (distanceFromBottom > 150) {
                scrollToBottomBtn.classList.add('visible');
            } else {
                scrollToBottomBtn.classList.remove('visible');
            }

            // On mobile, hide input buttons while scrolling up
            if (window.innerWidth <= 768 && inputButtons) {
                // Skip hiding buttons if they are currently expanding back into view,
                // or if we're in the middle of an initial channel render/scroll-to-bottom
                if (distanceFromBottom > 200 && !isExpandingButtons && !nym._suppressInputButtonHide) {
                    inputButtons.classList.add('hidden-on-scroll');
                    scrollToBottomBtn.classList.add('controls-hidden');
                }

                // Show buttons again after scrolling stops
                if (!isExpandingButtons) {
                    if (mobileScrollTimer) clearTimeout(mobileScrollTimer);
                    mobileScrollTimer = setTimeout(() => {
                        const wasNearBottom = messagesContainer.scrollHeight - messagesContainer.scrollTop - messagesContainer.clientHeight < 200;
                        isExpandingButtons = true;
                        inputButtons.classList.remove('hidden-on-scroll');
                        scrollToBottomBtn.classList.remove('controls-hidden');
                        // Clear the flag after the CSS transition completes (250ms + buffer)
                        setTimeout(() => {
                            isExpandingButtons = false;
                        }, 300);
                        // When buttons expand back and user is near bottom, auto-scroll
                        // so the expanding input area doesn't overlap the last message
                        if (wasNearBottom && !nym.userScrolledUp) {
                            setTimeout(() => {
                                nym._scheduleScrollToBottom();
                            }, 270);
                        }
                    }, 800);
                }
            }
        }, { passive: true });
    }

    // Auto-scroll to bottom when input is focused on mobile (only if near bottom)
    if (messageInput && messagesContainer) {
        messageInput.addEventListener('focus', function () {
            if (window.innerWidth <= 768 && !nym.userScrolledUp) {
                setTimeout(() => {
                    nym._scheduleScrollToBottom();
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

        // Strip any prefix
        let channelName = channelInput;
        if (channelInput.startsWith('g:')) {
            channelName = channelInput.substring(2);
        } else if (channelInput.startsWith('e:') || channelInput.startsWith('c:')) {
            channelName = channelInput.substring(2);
        }

        // Only handle geohash channels
        if (nym.isValidGeohash(channelName)) {
            nym.addChannel(channelName, channelName);
            nym.switchChannel(channelName, channelName);
            nym.userJoinedChannels.add(channelName);
            nym.saveUserChannels();
            nym.displaySystemMessage(`Joined geohash channel #${channelName} from URL`);
        } else {
            nym.displaySystemMessage(`Invalid geohash channel: ${channelName}`);
        }

        // Clear the URL hash to clean up
        history.replaceState(null, null, window.location.pathname);
    }
}