/// The recovery code has to be reachable, or the root is generated, stored and
/// never shown: no second device can be linked, and a lost device takes the
/// post-quantum history with it.
///
/// Source-level, like pq_own_echo_test.dart — the modal needs a whole provider
/// graph to pump, and what these guard is the wiring, not the pixels.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/features/i18n/app_strings_catalog.dart';

void main() {
  final modal =
      File('lib/features/identity/nick_edit_modal.dart').readAsStringSync();
  final controller = File('lib/state/nostr_controller.dart').readAsStringSync();

  group('the recovery code is reachable', () {
    test('the modal reads it through pqRootCode', () {
      expect(modal.contains('ctrl.pqRootCode'), isTrue);
    });

    test('it sits in the same slideout as the nsec', () {
      expect(modal.indexOf('_pqRootRow(c)'),
          greaterThan(modal.indexOf('_nsecRow(c),')));
    });

    test('it renders masked until revealed', () {
      expect(modal.contains('_pqRootVisible ? code :'), isTrue);
    });

    test('and can be copied', () {
      expect(modal.contains('Post-quantum recovery code copied'), isTrue);
    });

    // Reveal and link are mutually exclusive: showing both would ask a device
    // that already holds the code to paste one.
    test('a device holding the code sees no paste box', () {
      expect(
          modal.contains(
              'code == null ? _pqRootLinkRow(c) : _pqRootCodeRow(c, code)'),
          isTrue);
    });

    test('linking goes through the checked controller path', () {
      expect(modal.contains('linkPqRootFromCode'), isTrue);
    });

    test('a rejected code says so rather than failing silently', () {
      expect(modal.contains('does not match this account'), isTrue);
    });

    test('the text controller is disposed', () {
      expect(modal.contains('_pqRootLink.dispose()'), isTrue);
    });

    test('the toggle names both halves, not just the private key', () {
      expect(
          modal.contains("Reveal this nym's private key and recovery code"),
          isTrue);
      expect(modal.contains('tr("Reveal this nym\'s private key")'), isFalse);
    });
  });

  group('the record identifies its root', () {
    // A record without a fingerprint reads in the PWA as no record at all, and
    // a device that believes there is no record generates a second root.
    test('both publish paths stamp one', () {
      expect(controller.contains('PqRootRecord.forRoot(root)'), isTrue);
      expect(controller.contains('PqRootRecord.forRoot(held)'), isTrue);
      expect(controller.contains('sync.pqRootRecordSet(const PqRootRecord())'),
          isFalse,
          reason: 'an empty record carries no fingerprint');
    });

    test('the republish path does not invent a root it does not hold', () {
      expect(controller.contains('final held = _pqRoot;\n        if (held == null) return;'),
          isTrue);
    });
  });

  group('the post-quantum notice', () {
    final gate =
        File('lib/features/onboarding/boot_gate.dart').readAsStringSync();
    final tutorial = File('lib/features/onboarding/tutorial_overlay.dart')
        .readAsStringSync();

    // Two explanations of the same thing back to back is worse than one.
    test('it is suppressed while the tutorial is still ahead', () {
      expect(gate.contains('if (!seen) {'), isTrue);
      expect(
          gate.contains(
              'unawaited(ref.read(nostrControllerProvider).dismissPqUpgradeNotice())'),
          isTrue,
          reason: 'dismissed, not deferred, so the tour never shows it twice');
    });

    test('the tutorial is what covers it instead', () {
      expect(tutorial.contains('post-quantum recovery code'), isTrue);
      expect(tutorial.contains('nympq1'), isTrue);
      // The whole point of the code is that losing it is unrecoverable.
      expect(tutorial.contains('cannot be recovered'), isTrue);
    });

    test('it fires only once', () {
      expect(gate.contains('if (_pqNoticeShown) return;'), isTrue);
      expect(gate.contains('await ctrl.dismissPqUpgradeNotice();'), isTrue);
    });

    // A returning user on a new device is not covered, and telling them they
    // are would be false.
    test('a device needing the code is told to link, not that it is covered',
        () {
      expect(gate.contains('final linkNeeded = ctrl.pqRootLinkNeeded;'), isTrue);
      expect(gate.contains('Add your post-quantum recovery code'), isTrue);
      // Asserted against the catalog, not the source: the literal is wrapped
      // across lines there, so a source grep tests the formatter.
      expect(
          kAppStringsCatalog.any((s) => s.contains('does not have it yet')),
          isTrue);
    });

    // It already has the user's attention; sending them off to find the panel
    // loses most of them.
    test('and can link from the notice itself', () {
      expect(gate.contains('showAppPrompt('), isTrue);
      expect(gate.contains('ctrl.linkPqRootFromCode(code)'), isTrue);
      expect(gate.contains("placeholder: 'nympq1"), isTrue);
      expect(kAppStringsCatalog, contains('Link this device'));
    });

    test('and is told plainly whether the code matched', () {
      expect(
          kAppStringsCatalog,
          contains('Linked. This device can now read your quantum-resistant '
              'messages.'));
      expect(kAppStringsCatalog.any((s) => s.startsWith('That code does not '
          'match this account.')), isTrue);
    });

    // The other half: a device that HAS the code is handed it, not sent
    // looking for it.
    test('a device that holds the code gets it in the notice', () {
      expect(gate.contains('copyValue: ctrl.pqRootCode'), isTrue);
      expect(gate.contains('copiedMessage:'), isTrue);
      final dlg =
          File('lib/widgets/common/app_dialog.dart').readAsStringSync();
      expect(dlg.contains('Widget _copyRow(NymColors c)'), isTrue);
      expect(dlg.contains('Clipboard.setData(ClipboardData(text: value))'),
          isTrue);
    });

    test('and the timer is cancelled on dispose', () {
      expect(gate.contains('_pqNoticeDelay?.cancel();'), isTrue);
    });
  });

  // The modal is the "view" half as much as the "edit" half, so the pubkey is
  // read on open rather than discovered by tapping four characters.
  group('the Nym details modal', () {
    test('it is titled for viewing as well as editing', () {
      expect(modal.contains("View or Edit Nym's Details"), isTrue);
      expect(modal.contains("Change Nym's Details"), isFalse);
    });

    test('the pubkey panel is open, not behind a tap', () {
      expect(modal.contains('_pubkeySlideout(c),'), isTrue);
      expect(modal.contains('if (_pubkeyOpen)'), isFalse);
      expect(modal.contains('_pubkeyOpen'), isFalse,
          reason: 'the toggle state is gone entirely, not just unused');
    });

    test('the suffix no longer advertises a reveal that does not exist', () {
      expect(modal.contains('Click to view full pubkey'), isFalse);
      expect(modal.contains('Click the #'), isFalse);
    });

    test('copy and swap read the same as the context menu', () {
      expect(modal.contains("tr('Copy npub')"), isTrue);
      expect(modal.contains("tr('Copy hex pubkey')"), isTrue);
      expect(modal.contains("tr('Show hex')"), isTrue);
      expect(modal.contains("tr('Show npub')"), isTrue);
    });

    test('the swap button carries the same glyph as the context-menu row', () {
      expect(modal.contains('icon: NymIcons.ctxSwapFormat'), isTrue);
      final icons = File('lib/widgets/nym_icons.dart').readAsStringSync();
      expect(icons.contains('ctxSwapFormat'), isTrue);
      // Same path data as the PWA's #ctxTogglePubkeyFormat.
      expect(icons.contains('M 2 6 L 12 6'), isTrue);
    });

    test('the format switch still writes the shared preference', () {
      expect(modal.contains('writePubkeyFormat(prefs, next)'), isTrue,
          reason: 'one preference, so the context menu agrees');
    });

    // The panel explains where the nickname's #suffix comes from, so it has to
    // come first: the nickname field below it is the thing being explained.
    test('the pubkey panel is built above the nickname group', () {
      final pk = modal.indexOf('_pubkeySlideout(c),');
      final nick = modal.indexOf('_nicknameGroup(c),');
      expect(pk, greaterThan(-1));
      expect(nick, greaterThan(-1));
      expect(pk, lessThan(nick));
    });

    test('the nickname field carries no hint of its own', () {
      expect(modal.contains('ephemeral pseudonym'), isFalse,
          reason: 'the panel above explains the suffix now');
      expect(
          kAppStringsCatalog.any(
              (s) => s.contains('the start of your public key')),
          isFalse,
          reason: 'and the sentence that said so is gone from the catalog');
    });

    test('the panel explains the suffix, and gets it the right way round', () {
      final para = kAppStringsCatalog.firstWhere(
          (s) => s.startsWith('A "pubkey" aka "public key"'));
      expect(
          para,
          endsWith('The four characters after the # in a nickname are the '
              'last four of the hex format.'));
      expect(modal.contains('last four of the hex '), isTrue);
    });
  });

  // The bug this guards: _ensurePqRoot ran once, from the boot settings
  // restore. A launch that could not reach /api/storage spent the whole
  // session with no root, silently announcing an nsec-derived key.
  group('the root question is re-asked until it is answered', () {
    final ctrl = File('lib/state/nostr_controller.dart').readAsStringSync();

    test('every completed settings read runs the decision again', () {
      final merge = ctrl.substring(
          ctrl.indexOf('Future<void> _mergeRemoteSettings(StorageSync sync)'));
      final body = merge.substring(0, merge.indexOf('\n  Future<'));
      expect(body.contains('_settingsGetFailed = false;'), isTrue);
      expect(body.contains('_ensurePqRoot()'), isTrue,
          reason: 'a reconnect that succeeds must be able to generate');
    });

    test('and a settled answer costs nothing to re-ask', () {
      expect(
          ctrl.contains(
              'if (_pqRootSettled && (_pqRoot != null || _pqRootLocked)) return;'),
          isTrue);
    });

    test('the decision no longer asks for a local nsec', () {
      final root =
          File('lib/features/identity/pq_root.dart').readAsStringSync();
      expect(root.contains('hasLocalKey'), isFalse,
          reason: 'a signer login needs the root to become capable at all');
    });

    // Onboarding does not log anyone in; it boots the auto-ephemeral identity.
    // Gating generation on a durable login therefore excluded almost every
    // real account, which is why the apps kept announcing an nsec-derived key
    // while the PWA — which has no such gate — did not.
    test('nor whether the identity is a durable login', () {
      final root =
          File('lib/features/identity/pq_root.dart').readAsStringSync();
      expect(root.contains('durableIdentity'), isFalse);
      expect(ctrl.contains('durableIdentity: sync.durableIdentity'), isFalse);
    });

    test('only a per-session throwaway keypair opts out', () {
      expect(ctrl.contains('throwawayKeypair:'), isTrue);
      expect(ctrl.contains('StorageKeys.randomKeypairPerSession'), isTrue);
    });

    test('a root that does not match the record is dropped, not announced', () {
      expect(ctrl.contains('if (!matches) _pqRoot = null;'), isTrue);
    });
  });

  // The report that found the generation bug: the modal said "no recovery
  // code yet" while settings said "Active ... with 2 contacts", on an account
  // minutes old.
  group('the settings status matches the recovery-code panel', () {
    final screen =
        File('lib/features/settings/settings_screen.dart').readAsStringSync();

    test('plain Active requires a root, not merely an nsec', () {
      expect(screen.contains('pqCapable && pqRootHeld'), isTrue);
      expect(screen.contains('kPqStatusNoRoot'), isTrue);
    });

    test('and the green is reserved for that same state', () {
      expect(screen.contains('color: pqCapable && pqRootHeld'), isTrue);
    });

    test('the no-root line is translatable', () {
      expect(screen.contains('kPqStatusNoRoot,'), isTrue,
          reason: 'it must be in kPqStatusStrings for the sweep');
      expect(
          kAppStringsCatalog.any(
              (s) => s.startsWith('Active, but on the older key')),
          isTrue);
    });
  });

  // A root we generated but could not publish is recoverable; one we threw
  // away is not.
  group('a generated root is kept even if its record does not publish', () {
    final ctrl = File('lib/state/nostr_controller.dart').readAsStringSync();
    // To the NEXT method, not to the first `return;` — the persist guard is
    // itself a return, and slicing there cuts the branch in half.
    final branch = ctrl.substring(ctrl.indexOf('case PqRootAction.generate:'));
    final body =
        branch.substring(0, branch.indexOf('Future<bool> linkPqRootFromCode'));

    test('it is persisted before the record is published', () {
      final persist = body.indexOf('_persistPqRoot(root)');
      final publish = body.indexOf('pqRootRecordSet(');
      expect(persist, greaterThan(-1));
      expect(publish, greaterThan(-1));
      expect(persist, lessThan(publish));
    });

    test('and a failed publish does not discard it', () {
      expect(body.contains('if (!await sync.pqRootRecordSet'), isFalse,
          reason: 'publishRecord retries on the next boot; losing the root '
              'leaves the account with no post-quantum at all');
    });

    test('overlapping runs cannot mint two roots', () {
      expect(ctrl.contains('if (_pqRootInFlight) return;'), isTrue);
      expect(ctrl.contains('_pqRootInFlight = true;'), isTrue);
      expect(ctrl.contains('_pqRootInFlight = false;'), isTrue);
    });
  });

  // The device that most needs the prompt is a FRESH install joining an
  // account that already has a root: no upgrade, so the upgrade notice is
  // never armed, and the screen telling it to link never appeared.
  group('a locked device is prompted even without an upgrade', () {
    final ctrl = File('lib/state/nostr_controller.dart').readAsStringSync();
    final gate = File('lib/features/onboarding/boot_gate.dart').readAsStringSync();

    test('the link prompt is its own signal, not the upgrade one', () {
      expect(ctrl.contains('bool get pqRootLinkPromptPending'), isTrue);
      expect(ctrl.contains('if (!pqRootLinkNeeded) return false;'), isTrue);
      expect(ctrl.contains('nym_pq_link_prompt_\$self'), isTrue,
          reason: 'keyed per account, so switching identities asks again');
    });

    test('and either signal opens the notice', () {
      expect(
          gate.contains(
              'if (!ctrl.pqUpgradeNoticePending && !linkPending) return;'),
          isTrue);
      expect(gate.contains('await ctrl.dismissPqRootLinkPrompt();'), isTrue);
    });

    test('it re-checks after the settings read could have settled', () {
      expect(gate.contains('_pqNoticeRetry'), isTrue,
          reason: 'the lock is only known once section 6 settles');
      expect(gate.contains('_pqNoticeRetry?.cancel();'), isTrue);
    });
  });

  group('linking verifies against the record, not our epoch', () {
    final ctrl = File('lib/state/nostr_controller.dart').readAsStringSync();
    final link = ctrl.substring(
        ctrl.indexOf('Future<bool> linkPqRootFromCode'),
        ctrl.indexOf('Future<void> _reloadSettingsAfterLink'));

    // The record is the account's own statement of which root it uses: exact,
    // epoch-free, and always present on a device that needs linking.
    test('the fingerprint is the primary check', () {
      expect(link.contains('record.matches(root)'), isTrue);
      expect(link.contains('_storageSync?.pqRootRecord'), isTrue);
    });

    test('and the announced-key fallback uses the announcement own epoch', () {
      expect(link.contains('_pqRegistry.epochFor(self!)'), isTrue,
          reason: 'our counter is not the publishing device\'s counter');
    });

    test('a successful link clears the lock and re-reads settings', () {
      expect(link.contains('_pqRootLocked = false;'), isTrue);
      expect(link.contains('_reloadSettingsAfterLink()'), isTrue);
      expect(ctrl.contains('sync.clearSettingsHashes();'), isTrue,
          reason: 'an identical blob must still be republished');
    });
  });

  // A second device logging in must not publish its defaults over the
  // account's settings before it can read them.
  group('a locked device never overwrites settings it cannot read', () {
    final sync = File('lib/services/api/storage_sync.dart').readAsStringSync();
    final ctrl = File('lib/state/nostr_controller.dart').readAsStringSync();

    test('rows that did not open are counted, not silently skipped', () {
      expect(sync.contains('var pending = 0;'), isTrue);
      expect(
          sync.contains(
              '_settingsRestoreUnreadable = pending > 0 && _pqRootLockedOut;'),
          isTrue);
    });

    test('and saving is refused while any row is unread', () {
      expect(sync.contains('if (_settingsRestoreUnreadable) return false;'),
          isTrue);
    });

    // The v1 reasoning: with a local nsec, an all-fail decode is final. Under
    // v2 the rows are sealed to the ROOT, which a fresh device does not have
    // yet — so that verdict wiped accounts.
    test('an all-fail decode is not final while locked out', () {
      expect(sync.contains('if (_pqRootLockedOut) return null;'), isTrue);
      expect(sync.contains('if (storedBlobs == 0 || _signer is LocalSigner)'),
          isFalse,
          reason: 'the old branch treated a locked device as unreadable-forever');
    });

    test('the controller tells the storage layer the verdict', () {
      expect(ctrl.contains('sync.pqRootLocked = true;'), isTrue);
      expect(ctrl.contains('sync.pqRootLocked = false;'), isTrue);
    });

    // The lock is decided AFTER the load that read the rows — section 6 needs
    // a completed read to tell "no record" from "could not look" — so the
    // first load computes the verdict with the lock still unknown. Without
    // recomputing, the very boot that does the wiping is the unprotected one.
    test('the verdict is recomputed when the lock is decided', () {
      expect(sync.contains('_lastLoadPending = pending;'), isTrue);
      expect(
          sync.contains(
              '_settingsRestoreUnreadable = v && _lastLoadPending > 0;'),
          isTrue);
    });
  });

  group('the recovery-code panel confirms what it holds', () {
    final modal =
        File('lib/features/identity/nick_edit_modal.dart').readAsStringSync();

    test('it shows the fingerprint, as the PWA does', () {
      expect(modal.contains('pq.pqRootFingerprint(bytes)'), isTrue);
      expect(kAppStringsCatalog, contains('Fingerprint: {fp}'));
    });
  });

  group('the encrypt-at-rest offer survives an unreadable first load', () {
    final gate = File('lib/features/onboarding/boot_gate.dart').readAsStringSync();

    // The flag it needs lives in the settings a locked device cannot read, so
    // at the 2.5s mark it is simply not there yet.
    test('it is re-checked after the settings have had time to land', () {
      final retry = gate.substring(gate.indexOf('_pqNoticeRetry = Timer('));
      expect(retry.substring(0, 700).contains('_maybePromptEncryptAtRest()'),
          isTrue);
    });
  });

  group('every new string is translatable', () {
    // A string missing from the catalog stays English in every other language,
    // silently, and only in this one panel.
    test('the recovery-code strings are in the sweep catalog', () {
      for (final s in const [
        'Post-quantum recovery code',
        'Post-quantum recovery code copied',
        "Reveal this nym's private key and recovery code",
        'Link',
        'Linked. This device can now read your quantum-resistant messages.',
        'That code does not match this account. Check it and try again.',
      ]) {
        expect(kAppStringsCatalog, contains(s), reason: s);
      }
    });

    test('so are the two long ones, exactly as concatenated', () {
      expect(
          kAppStringsCatalog,
          contains('This code, not your nsec, is what makes your messages '
              'quantum-resistant. Copy it to any other device you use this '
              'account on. Store it with your nsec and never share it.'));
      expect(
          kAppStringsCatalog,
          contains('This device has no recovery code yet. Paste the one from a '
              'device that already has it — you will find it in this same '
              'panel there — so both can read the same quantum-resistant '
              'messages.'));
    });
  });
}
