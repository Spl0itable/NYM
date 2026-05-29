// inline-bindings.js - Single delegated dispatcher that replaces inline event handlers

// Short haptic pulse used to confirm a long-press fired on mobile
window.nymHapticTap = function (ms) {
    try {
        if (window.Haptics && typeof window.Haptics.postMessage === 'function') {
            window.Haptics.postMessage('tap');
            return;
        }
        if (navigator && typeof navigator.vibrate === 'function') {
            navigator.vibrate(ms || 30);
        }
    } catch (_) { /* ignore */ }
};

(function () {
    'use strict';

    var ACTIONS = (window.NYM_ACTIONS = window.NYM_ACTIONS || {});

    // Walk up from el looking for an ancestor with the given attribute.
    function closestWithAttr(el, attr) {
        while (el && el.nodeType === 1) {
            if (el.hasAttribute && el.hasAttribute(attr)) return el;
            el = el.parentNode;
        }
        return null;
    }

    function dispatch(eventType, attr, event) {
        var node = closestWithAttr(event.target, attr);
        if (!node) return;
        var name = node.getAttribute(attr);
        var handler = ACTIONS[name];
        if (typeof handler === 'function') {
            try { handler(event, node); }
            catch (e) { console.error('[inline-bindings] handler error for', name, e); }
        } else if (name) {
            console.warn('[inline-bindings] no handler registered for', name);
        }
    }

    document.addEventListener('click',    function (e) { dispatch('click',    'data-action',     e); }, false);
    document.addEventListener('change',   function (e) { dispatch('change',   'data-on-change',  e); }, false);
    document.addEventListener('input',    function (e) { dispatch('input',    'data-on-input',   e); }, false);
    document.addEventListener('keyup',    function (e) { dispatch('keyup',    'data-on-keyup',   e); }, false);
    document.addEventListener('keydown',  function (e) { dispatch('keydown',  'data-on-keydown', e); }, false);

    // Avatar / image fallback. `error` events do not bubble
    document.addEventListener('error', function (e) {
        var t = e.target;
        if (!t || t.tagName !== 'IMG') return;
        if (t.dataset && t.dataset.avatarPubkey && window.nym && typeof window.nym.generateAvatarSvg === 'function') {
            // If the image actually decoded (e.g. error fired on a cancelled
            // load while the new src is already painting), don't replace it.
            if (t.complete && t.naturalHeight > 0) return;
            var fallback = window.nym.generateAvatarSvg(t.dataset.avatarPubkey);
            // Avoid loops if the fallback itself somehow errors.
            if (t.src === fallback) return;
            t.onerror = null;
            t.src = fallback;
            return;
        }
        // Custom emoji failed to load — retry a couple of times so a transient
        // miss gets a chance to re-fetch and populate the long-lived edge cache.
        if (t.classList && t.classList.contains('custom-emoji')) {
            if (t.complete && t.naturalHeight > 0) return;
            var tries = parseInt(t.dataset.emojiRetry || '0', 10);
            if (tries < 2) {
                t.dataset.emojiRetry = String(tries + 1);
                if (!t.dataset.emojiBaseSrc) {
                    t.dataset.emojiBaseSrc = t.src.split('&_r=')[0].split('?_r=')[0];
                }
                var baseSrc = t.dataset.emojiBaseSrc;
                var sep = baseSrc.indexOf('?') === -1 ? '?' : '&';
                setTimeout(function () {
                    t.src = baseSrc + sep + '_r=' + (tries + 1);
                }, 800 * (tries + 1));
            }
            return;
        }
        if (t.dataset && t.dataset.errorAction) {
            var fn = ACTIONS[t.dataset.errorAction];
            if (typeof fn === 'function') {
                try { fn(e, t); } catch (err) { console.error(err); }
            }
        }
    }, true);

    // Action registry
    function nym() { return window.nym; }
    function byId(id) { return document.getElementById(id); }

    Object.assign(ACTIONS, {
        // Generic
        'closeModal':                 function (_e, t) { window.closeModal(t.dataset.modalId); },
        'noop':                       function () {},
        'stopPropagation':            function (e) { e.stopPropagation(); },

        // Sidebar / global
        'closeSidebar':               function () { nym().closeSidebar(); },
        'openNotificationsModal':     function () { nym().openNotificationsModal(); },
        'closeNotificationsModal':    function () { nym().closeNotificationsModal(); },
        'toggleSidebar':              function () { window.toggleSidebar(); },
        'openShop':                   function () { nym().openShop(); },
        'closeShop':                  function () { nym().closeShop(); },
        'openShopAndCloseSidebar':    function () { nym().openShop(); nym().closeSidebar(); },
        'showSettingsAndCloseSidebar':function () { window.showSettings(); nym().closeSidebar(); },
        'showAboutAndCloseSidebar':   function () { window.showAbout(); nym().closeSidebar(); },
        'signOutAndCloseSidebar':     function () { window.signOut(); nym().closeSidebar(); },
        'showSettings':               function () { window.showSettings(); },
        'showAbout':                  function () { window.showAbout(); },
        'sendAboutContact':           function () { window.sendAboutContact(); },
        'reportSpamFalsePositive':    function (_e, t) { window.reportSpamFalsePositive(t.dataset.spamContent || ''); },
        'signOut':                    function () { window.signOut(); },
        'openNostrLogin':             function () { window.openNostrLogin(); },
        'editNick':                   function () { window.editNick(); },
        'openRelayStats':             function () { window.openRelayStats(); },
        'showGeohashExplorer':        function () { nym().showGeohashExplorer(); },
        'closeGeohashExplorer':       function () { nym().closeGeohashExplorer(); },
        'resetGlobeView':             function () { nym().resetGlobeView(); },
        'zoomMapIn':                  function () { nym().zoomMapIn(); },
        'zoomMapOut':                 function () { nym().zoomMapOut(); },
        'toggleHeatmap':              function () { nym().toggleHeatmap(); },
        'toggleDaynight':             function () { nym().toggleDaynight(); },
        'toggleGeohashGrid':          function () { nym().toggleGeohashGrid(); },
        'setActiveWindow':            function (_e, t) { nym().setGeohashActiveWindow(t.dataset.hours); },
        'setActiveWindowFromSelect':  function (_e, t) { nym().setGeohashActiveWindow(t.value); },
        'closeGeohashInfo':           function () { nym().closeGeohashInfo(); },

        // Image / context-menu avatar/banner
        'expandImageFromSrcStop':     function (e, t) {
            e.stopPropagation();
            nym().expandImage(t.src);
            nym().closeContextMenu();
        },
        'expandImageFromSrc':         function (_e, t) { nym().expandImage(t.src); },
        'expandImageFromData':        function (_e, t) {
            const gallery = t.closest('.message-gallery');
            if (gallery) {
                const imgs = Array.from(gallery.querySelectorAll('img'));
                const idx = imgs.indexOf(t);
                nym().expandImage(t.currentSrc || t.src, { gallery: imgs.map(i => i.currentSrc || i.src), index: idx >= 0 ? idx : 0 });
            } else {
                nym().expandImage(t.currentSrc || t.src);
            }
        },
        'closeImageModal':            function () { window.closeImageModal(); },
        'downloadModalMedia':         function (e) { window.downloadModalMedia(e); },
        'imageModalPrev':             function (e) { e.stopPropagation(); if (window.navigateImageModalGallery) window.navigateImageModalGallery(-1); },
        'imageModalNext':             function (e) { e.stopPropagation(); if (window.navigateImageModalGallery) window.navigateImageModalGallery(1); },

        // Channel nav / search
        'navigateBack':               function () { nym().navigateBack(); },
        'navigateForward':            function () { nym().navigateForward(); },
        'shareChannel':               function () { nym().shareChannel(); },
        'toggleFavoriteCurrentChannel': function () { nym().toggleFavoriteCurrentChannel(); },
        'initiateAudioCall':          function () { nym().initiateAudioCall(); },
        'initiateVideoCall':          function () { nym().initiateVideoCall(); },
        'acceptIncomingCall':         function () { nym().acceptCall(); },
        'rejectIncomingCall':         function () { nym().rejectCall(); },
        'hangupCall':                 function () { nym().hangupCall(); },
        'toggleCallMute':             function () { nym().toggleCallMute(); },
        'toggleCallVideo':            function () { nym().toggleCallVideo(); },
        'toggleSearch':               function (_e, t) { window.toggleSearch(t.dataset.searchTarget); },
        'clearSearch':                function (_e, t) { window.clearSearch(t.dataset.searchTarget); },
        'toggleSectionCollapse':      function (e, t) { e.stopPropagation(); window.toggleSectionCollapse(t.dataset.sectionTarget); },
        'channelSearchInput':         function (_e, t) {
            t.value = t.value.toLowerCase();
            nym().handleChannelSearch(t.value);
        },
        'channelSearchKeyup':         function (_e, t) { nym().handleChannelSearch(t.value); },
        'filterPMs':                  function (_e, t) { nym().filterPMs(t.value); },
        'filterUsers':                function (_e, t) { nym().filterUsers(t.value); },

        // Input area buttons
        'selectImage':                function () { window.selectImage(); },
        'selectP2PFile':              function () { window.selectP2PFile(); },
        'toggleEmojiPicker':          function () { nym().toggleEmojiPicker(); },
        'closeEnhancedEmojiModal':    function () { nym().closeEnhancedEmojiModal(); },
        'toggleEmojiPackFavorite':    function (e, t) { e && e.stopPropagation && e.stopPropagation(); nym().toggleEmojiPackFavorite(t && t.dataset ? t.dataset.packKey : ''); },
        'toggleEmojiCategoryFavorite':function (e, t) { e && e.stopPropagation && e.stopPropagation(); nym().toggleEmojiCategoryFavorite(t && t.dataset ? t.dataset.category : ''); },
        'toggleGifPicker':            function () { nym().toggleGifPicker(); },
        'closeGifPicker':             function () { nym().closeGifPicker(); },
        'scrollToBottom':             function () { window.scrollToBottom(); },

        // PM / report modals
        'focusPmRecipient':           function () { var i = byId('pmRecipientInput'); if (i) i.focus(); },
        'onNewPMRecipientInput':      function (_e, t) { nym().onNewPMRecipientInput(t.value); },
        'onNewPMRecipientKeydown':    function (e)    { nym().onNewPMRecipientKeydown(e); },
        'startNewPMFromModal':        function () { nym().startNewPMFromModal(); },
        'openNewPMModal':             function () { nym().openNewPMModal(); },
        'closeReportModal':           function () { nym().closeReportModal(); },
        'submitReport':               function () { nym().submitReport(); },

        // Poll
        'addPollOption':              function () { window.addPollOption(); },
        'submitPoll':                 function () { window.submitPoll(); },

        // Dev nsec
        'cancelDevNsec':              function () { window.cancelDevNsec(); },
        'verifyDevNsec':              function () { window.verifyDevNsec(); },

        // Nostr login
        'nostrLoginCloseAndCancel':   function () { window.nostrLoginCancelRemoteSigner(); window.closeModal('nostrLoginModal'); },
        'nostrLoginWithExtension':    function () { window.nostrLoginWithExtension(); },
        'nostrLoginStartRemoteSigner':function () { window.nostrLoginStartRemoteSigner(); },
        'nostrLoginCopyBunkerURI':    function () { window.nostrLoginCopyBunkerURI(); },
        'nostrLoginCancelRemoteSigner': function () { window.nostrLoginCancelRemoteSigner(); },
        'nostrLoginWithNsec':         function () { window.nostrLoginWithNsec(); },

        // Nick edit
        'handleNickEditAvatarSelect': function (e) { window.handleNickEditAvatarSelect(e); },
        'triggerNickEditAvatarUpload':function () { window.triggerNickEditAvatarUpload(); },
        'removeNickEditAvatar':       function () { window.removeNickEditAvatar(); },
        'handleNickEditBannerSelect': function (e) { window.handleNickEditBannerSelect(e); },
        'triggerNickEditBannerUpload':function () { var i = byId('nickEditBannerInput'); if (i) i.click(); },
        'removeNickEditBanner':       function () { window.removeNickEditBanner(); },
        'updateBioCharCount':         function () { window.updateBioCharCount(); },
        'toggleRevealPrivkey':        function () { window.toggleRevealPrivkey(); },
        'toggleNsecVisibility':       function () { window.toggleNsecVisibility(); },
        'copyRevealedNsec':           function () { window.copyRevealedNsec(); },
        'randomizeNick':              function () { window.randomizeNick(); },
        'changeNick':                 function () { window.changeNick(); },

        // Setup modal
        'handleSetupAvatarSelect':    function (e) { window.handleSetupAvatarSelect(e); },
        'triggerSetupAvatarUpload':   function () { window.triggerSetupAvatarUpload(); },
        'removeSetupAvatar':          function () { window.removeSetupAvatar(); },
        'handleSetupBannerSelect':    function (e) { window.handleSetupBannerSelect(e); },
        'triggerSetupBannerUpload':   function () { var i = byId('setupBannerInput'); if (i) i.click(); },
        'removeSetupBanner':          function () { window.removeSetupBanner(); },
        'updateSetupBioCharCount':    function () { window.updateSetupBioCharCount(); },
        'initializeNym':              function () { window.initializeNym(); },

        // Settings
        'selectWallpaper':            function (_e, t) { window.selectWallpaper(t.dataset.wallpaper); },
        'triggerWallpaperUpload':     function () { window.triggerWallpaperUpload(); },
        'handleWallpaperUpload':      function (e) { window.handleWallpaperUpload(e); },
        'selectMessageLayout':        function (_e, t) { window.selectMessageLayout(t.dataset.layout); },
        'previewTextSize':            function (_e, t) { window.previewTextSize(t.value); },
        'commitTextSize':             function (_e, t) { window.commitTextSize(t.value); },
        'resetTextSize':              function () { window.resetTextSize(); },
        'toggleLowDataModeFromStats': function (e) { window.toggleLowDataModeFromStats(e); },
        'onTransparencyChange':       function (_e, t) { window.onTransparencyChange(t.value); },
        'addBlockedKeyword':          function () { nym().addBlockedKeyword(); },
        'executeSettingsTransfer':    function () { nym().executeSettingsTransfer(); },
        'clearLocalStorageCache':     function () { window.clearLocalStorageCache(); },
        'resetSettings':              function () { window.resetSettings(); },
        'saveSettings':               function () { window.saveSettings(); },
        'onRandomKeypairChange':      function (_e, t) {
            var w = byId('hardcoreKeypairWarning');
            if (w) w.style.display = t.value === 'hardcore' ? 'block' : 'none';
        },

        // Shop
        'restorePurchasesFromInput':  function () {
            var i = byId('recoveryCodeInput');
            nym().restorePurchases(i ? i.value : '');
        },
        'switchShopTab':              function (e, t) { nym().switchShopTab(t.dataset.shopTab, e); },

        // Zap modal
        'closeZapModal':              function () { nym().closeZapModal(); },
        'copyZapInvoice':             function () { nym().copyZapInvoice(); },
        'openInWallet':               function () { nym().openInWallet(); },

        // Share modal
        'copyShareUrl':               function () { nym().copyShareUrl(); },

        // Notifications modal toggles
        'toggleNotificationsEnabled': function (_e, t) { nym().toggleNotificationsEnabled(t.checked); },
        'toggleGroupMentionsOnly':    function (_e, t) { nym().toggleGroupMentionsOnly(t.checked); },
        'toggleNotifyFriendsOnly':    function (_e, t) { nym().toggleNotifyFriendsOnly(t.checked); },

        // Dynamically-rendered (innerHTML) handlers from JS modules
        'reactionShowPicker':         function (_e, t) { nym().showReactionPicker(t.dataset.messageId, t); },
        'translateHoverMessage':      function (_e, t) { nym().translateHoverMessage(t); },
        'stopSeeding':                function (_e, t) { nym().stopSeeding(t.dataset.offerId); },
        'cancelTransfer':             function (_e, t) { nym().cancelTransfer(t.dataset.transferId); },
        'downloadTorrent':            function (_e, t) { nym().downloadTorrent(t.dataset.offerId); },
        'requestP2PFile':             function (_e, t) { nym().requestP2PFile(t.dataset.offerId); },
        'votePoll':                   function (_e, t) { nym().votePoll(t.dataset.pollId, parseInt(t.dataset.optionIndex, 10)); },
        'showPollVoters':             function (e, t) { nym().showPollVotersModal(t.dataset.pollId, t, e); },
        'expandVideoFromContainer':   function (e, t) {
            e.stopPropagation();
            var v = t.previousElementSibling;
            var source = v && v.querySelector && v.querySelector('source');
            var src = (v && v.dataset && v.dataset.blobSrc)
                || (v && v.currentSrc)
                || (source && source.src)
                || t.dataset.videoSrc;
            nym().expandVideo(src);
        },
        'channelLink':                function (e, t) {
            e.preventDefault();
            e.stopPropagation();
            nym().handleChannelLink(t.dataset.channelRef, e);
            return false;
        },
        'showFullTimestamp':          function (e, t) {
            if (e && e.stopPropagation) e.stopPropagation();
            var n = nym();
            var full = '';
            var msgEl = t && t.closest ? t.closest('[data-timestamp]') : null;
            if (msgEl && msgEl.dataset && msgEl.dataset.timestamp && typeof n._formatFullTimestamp === 'function') {
                full = n._formatFullTimestamp(parseInt(msgEl.dataset.timestamp));
            }
            if (!full) full = (t && t.dataset && t.dataset.fullTime) || (t && t.getAttribute && t.getAttribute('title')) || '';
            if (full) n.showTimestampPopup(t, full);
        },
        'showVerificationInfo':       function (e, t) {
            if (e && e.preventDefault) e.preventDefault();
            if (e && e.stopPropagation) e.stopPropagation();
            nym().showVerificationPopup(t, t && t.dataset && t.dataset.verified === 'true');
            return false;
        },
        'codeBlockCopy':              function (_e, t) {
            try {
                var code = t.dataset.code;
                if (!code) return;
                var text = decodeURIComponent(escape(atob(code)));
                navigator.clipboard.writeText(text).then(function () {
                    t.textContent = 'Copied!';
                    setTimeout(function () { t.textContent = 'Copy'; }, 1500);
                }).catch(function () {});
            } catch (e) {}
        },
        'dismissShopSuccess':         function () { nym().dismissShopSuccess(); },

        // Group moderation context-menu actions. Target pubkey lives on
        // nym().contextMenuData, set when the menu was opened.
        'kickMemberFromContext':      function () {
            var d = nym().contextMenuData;
            if (d && d.pubkey) nym().kickFromGroup(d.pubkey);
        },
        'banMemberFromContext':       function () {
            var d = nym().contextMenuData;
            if (!d || !d.pubkey) return;
            window.showAppConfirm('Ban this user from the group? They cannot be re-invited unless the owner unbans them.', { danger: true, okLabel: 'Ban' }).then(function (ok) {
                if (ok) nym().banFromGroup(d.pubkey);
            });
        },
        'addModFromContext':          function () {
            var d = nym().contextMenuData;
            if (d && d.pubkey) nym().promoteModerator(d.pubkey);
        },
        'removeModFromContext':       function () {
            var d = nym().contextMenuData;
            if (d && d.pubkey) nym().revokeModerator(d.pubkey);
        },
        'transferOwnerFromContext':   function () {
            var d = nym().contextMenuData;
            if (!d || !d.pubkey) return;
            window.showAppConfirm('Transfer group ownership to this user? You will lose owner privileges.', { danger: true, okLabel: 'Transfer' }).then(function (ok) {
                if (ok) nym().transferOwner(d.pubkey);
            });
        },
        'deleteMessageFromContext':   function () {
            var n = nym();
            var d = n.contextMenuData;
            if (!d || !d.messageId) { n.closeContextMenu(); return; }
            var isOwn = d.pubkey === n.pubkey;
            n.closeContextMenu();
            if (isOwn) {
                window.showAppConfirm('Are you sure you want to delete this message? This will send a deletion request to relays.', { danger: true, okLabel: 'Delete' }).then(function (ok) {
                    if (!ok) return;
                    n.publishDeletionEvent(d.messageId, n.inPMMode ? 1059 : n.channelWire(n.currentGeohash).kind).then(function () {
                        n.displaySystemMessage('Deletion request sent to relays');
                    });
                });
            } else if (n.inPMMode && n.currentGroup) {
                window.showAppConfirm("Delete this member's message for everyone in the group?", { danger: true, okLabel: 'Delete' }).then(function (ok) {
                    if (ok) n.modDeleteGroupMessage(d.messageId, d.pubkey);
                });
            }
        },

        // Error-event actions (referenced via data-error-action)
        'errorHideElement':           function (_e, t) { t.style.display = 'none'; },

        // Generic
        'removeParent':               function (_e, t) { if (t.parentElement) t.parentElement.remove(); },
        'removeElementById':          function (_e, t) {
            var el = byId(t.dataset.removeId);
            if (el) el.remove();
        },

        // Shop dynamic
        'purchaseItem':               function (_e, t) { nym().purchaseItem(t.dataset.itemId); },
        'activateMessageStyle':       function (_e, t) { nym().activateMessageStyle(t.dataset.itemId); },
        'activateFlair':              function (_e, t) { nym().activateFlair(t.dataset.itemId); },
        'activateCosmetic':           function (_e, t) { nym().activateCosmetic(t.dataset.itemId); },
        'activateSupporter':          function () { nym().activateSupporter(); },
        'promptTransferShopItem':     function (_e, t) { nym().promptTransferShopItem(t.dataset.itemId); },
        'executeTransferShopItem':    function (_e, t) { nym().executeTransferShopItem(t.dataset.itemId); },
        'promptGiftShopItem':         function (_e, t) { nym().promptGiftShopItem(t.dataset.itemId); },
        'executeGiftShopItem':        function (_e, t) { nym().executeGiftShopItem(t.dataset.itemId); },
        'copyTextFromData':           function (_e, t) {
            try {
                navigator.clipboard.writeText(t.dataset.copyText || '').then(function () {
                    var orig = t.textContent;
                    t.textContent = 'Copied!';
                    setTimeout(function () { t.textContent = orig; }, 1500);
                }).catch(function () {});
            } catch (e) {}
        },
        'acceptSettingsTransfer':     function (_e, t) { nym().acceptSettingsTransfer(t.dataset.eventId); },
        'rejectSettingsTransfer':     function (_e, t) { nym().rejectSettingsTransfer(t.dataset.eventId); },

        // Autocomplete
        'selectSpecificAutocomplete': function (_e, t) {
            nym().selectSpecificAutocomplete(t.dataset.acNym, t.dataset.acPubkey);
        },
        'selectSpecificEmojiAutocomplete': function (_e, t) {
            nym().selectSpecificEmojiAutocomplete(t.dataset.emoji);
        },
        'selectChannelAutocompleteItem': function (_e, t) {
            nym().selectChannelAutocompleteItem(t.dataset.channelName);
        },

        // Channels (settings list buttons)
        'unblockChannelFromSettings': function (_e, t) { nym().unblockChannelFromSettings(t.dataset.channelKey); },
        'unhideChannelFromSettings':  function (_e, t) { nym().unhideChannelFromSettings(t.dataset.channelKey); },

        // PM / group sidebar list items
        'openPMItem':                 function (_e, t) { nym().openPM(t.dataset.nym, t.dataset.pubkey); },
        'openGroupItem':              function (_e, t) { nym().openGroup(t.dataset.groupId); },

        // PMs dynamic
        'removeNewPMRecipient':       function (_e, t) { nym().removeNewPMRecipient(t.dataset.pubkey); }
    });
})();
