import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/crypto/bech32_codec.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../services/storage/key_value_store.dart';
import '../../services/storage/secure_store.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart' show keyValueStoreProvider;
import 'modal_chrome.dart';
import 'nip46_service.dart';

/// Login with Nostr (`#nostrLoginModal`, index.html:1017).
///
/// Sections (verbatim order, as rendered by the native NymchatApp shell — the
/// browser-extension option + its divider are `display:none` on native, so they
/// are NOT rendered): intro → NIP-46 remote-signer flow (build a
/// `nostrconnect://` URI + QR; the signer scans and connects automatically) →
/// one divider → paste-nsec (validated via [decodeNsec]). Returns the entered
/// nsec via `Navigator.pop` when the user logs in with a key.
class NostrLoginModal extends ConsumerStatefulWidget {
  const NostrLoginModal({super.key});

  static Future<String?> open(BuildContext context) {
    return showDialog<String>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      // `.modal` has no backdrop close-action — only Cancel / ✕ dismiss it.
      barrierDismissible: false,
      builder: (_) => const NostrLoginModal(),
    );
  }

  @override
  ConsumerState<NostrLoginModal> createState() => _NostrLoginModalState();
}

/// Adapts [SecureStore] to the [Nip46SecureStore] interface used by
/// [Nip46Service].
class _Nip46SecureStoreAdapter implements Nip46SecureStore {
  _Nip46SecureStoreAdapter(this._store);
  final SecureStore _store;
  @override
  Future<String?> get(String key) => _store.get(key);
  @override
  Future<void> set(String key, String value) => _store.set(key, value);
  @override
  Future<void> remove(String key) => _store.remove(key);
}

/// Adapts [KeyValueStore] to the [Nip46KeyValueStore] interface.
class _Nip46KvAdapter implements Nip46KeyValueStore {
  _Nip46KvAdapter(this._kv);
  final KeyValueStore _kv;
  @override
  String? getString(String key) => _kv.getString(key);
  @override
  Future<void> setString(String key, String value) =>
      _kv.setString(key, value);
}

class _NostrLoginModalState extends ConsumerState<NostrLoginModal> {
  final _nsecController = TextEditingController();
  String? _error;
  bool _remoteSignerOpen = false;
  String? _nostrConnectUri;

  Nip46Service? _nip46;
  String _remoteStatus = 'Waiting for remote signer...';

  /// Guards the async nsec adopt so a double-tap can't re-enter login.
  bool _loggingIn = false;

  @override
  void dispose() {
    _nsecController.dispose();
    _nip46?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          // `.modal-content.nm-h-1`: max-width 440.
          constraints: const BoxConstraints(maxWidth: 440),
          child: Material(
            color: Colors.transparent,
            child: Stack(
              children: [
                ModalChrome.box(
                  c,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(context).size.height * 0.9,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ModalChrome.header(c, 'Login with Nostr'),
                        Flexible(
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // `.nm-h-21`: 13px text-dim, mb18.
                                Text(
                                  'Login with your Nostr identity to sync '
                                  'settings across devices.',
                                  style: TextStyle(
                                      color: c.textDim, fontSize: 13),
                                ),
                                const SizedBox(height: 18),
                                _remoteSignerOption(c),
                                ModalChrome.orDivider(c),
                                _nsecOption(c),
                                _actions(c),
                                // `.nm-h-35` ToS / Privacy footer.
                                const SizedBox(height: 16),
                                _tosFooter(c),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                ModalChrome.closeChip(c, () => Navigator.of(context).pop()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _remoteSignerOption(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ModalChrome.sendButton(
          c,
          'Login with Remote Signer',
          _startRemoteSigner,
          fullWidth: true,
        ),
        const SizedBox(height: 5),
        // `.form-hint`.
        Text(
          'Use Amber, or another NIP-46 compatible remote signer',
          style: TextStyle(color: c.textDim, fontSize: 11),
        ),
        if (_remoteSignerOpen) ...[
          const SizedBox(height: 12),
          Center(
            child: Column(
              children: [
                // `.nm-h-28`: 13px text-dim, mb12.
                Text(_remoteStatus,
                    style: TextStyle(color: c.textDim, fontSize: 13)),
                const SizedBox(height: 12),
                if (_nostrConnectUri != null)
                  // `.nm-h-29`: white box, padding 12, radius 8; QR module 220.
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: NymRadius.rxs,
                    ),
                    child: QrImageView(
                      data: _nostrConnectUri!,
                      size: 220,
                      backgroundColor: Colors.white,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // `.form-label` "Connection String".
          ModalChrome.formLabel(c, 'Connection String'),
          const SizedBox(height: 8),
          // `.nm-h-31`: readonly connection-string field (font 11) + Copy.
          Row(
            children: [
              Expanded(
                // `.form-input` readonly box holding the `nostrconnect://` URI.
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 11),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: NymRadius.rsm,
                    border: Border.all(color: c.glassBorder),
                  ),
                  child: SelectableText(
                    _nostrConnectUri ?? '',
                    maxLines: 1,
                    style: TextStyle(color: c.textBright, fontSize: 11),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ModalChrome.iconButton(c, 'Copy', () {
                final uri = _nostrConnectUri;
                if (uri != null) {
                  Clipboard.setData(ClipboardData(text: uri));
                }
              }),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            'Scan the QR code or copy this connection string into your remote '
            'signer app',
            style: TextStyle(color: c.textDim, fontSize: 11),
          ),
        ],
      ],
    );
  }

  Widget _nsecOption(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ModalChrome.formLabel(c, 'Paste your nsec'),
        const SizedBox(height: 8),
        ModalChrome.focusRing(
          c,
          child: TextField(
            controller: _nsecController,
            obscureText: true,
            style: TextStyle(color: c.textBright, fontSize: 15),
            decoration: ModalChrome.inputDecoration(c, 'nsec1...'),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 5),
          // `.nm-h-20` error line.
          Text(_error!, style: TextStyle(color: c.danger, fontSize: 12)),
        ],
        const SizedBox(height: 5),
        Text(
          'Your private key stays local and is never sent to any server',
          style: TextStyle(color: c.textDim, fontSize: 11),
        ),
      ],
    );
  }

  Widget _actions(NymColors c) {
    return Padding(
      // `.modal-actions`: center, gap 10.
      padding: const EdgeInsets.only(top: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ModalChrome.iconButton(
              c, 'Cancel', () => Navigator.of(context).pop()),
          const SizedBox(width: 10),
          ModalChrome.sendButton(
            c,
            'Login',
            _loggingIn ? null : () => _loginWithNsec(),
            child: _loggingIn
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: c.primary),
                  )
                : null,
          ),
        ],
      ),
    );
  }

  /// `.nm-h-35` — centered "By logging in, you agree to our [ToS] and
  /// [Privacy Policy]." with secondary-cyan links.
  Widget _tosFooter(NymColors c) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Text.rich(
        TextSpan(
          style: TextStyle(color: c.textDim, fontSize: 12),
          children: [
            const TextSpan(text: 'By logging in, you agree to our '),
            TextSpan(
              text: 'Terms of Service',
              style: TextStyle(color: c.secondary),
              recognizer: ModalChrome.linkTap('static/tos.html'),
            ),
            const TextSpan(text: ' and '),
            TextSpan(
              text: 'Privacy Policy',
              style: TextStyle(color: c.secondary),
              recognizer: ModalChrome.linkTap('static/pp.html'),
            ),
            const TextSpan(text: '.'),
          ],
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  Nip46Service _makeService() => Nip46Service(
        kv: _Nip46KvAdapter(ref.read(keyValueStoreProvider)),
        secure: _Nip46SecureStoreAdapter(SecureStore()),
      );

  /// Starts the `nostrconnect://` flow: builds the URI + QR and opens the relay
  /// to await the signer's connect acknowledgement. When the signer connects we
  /// fetch its pubkey, persist the session, and pop the modal.
  void _startRemoteSigner() {
    final service = _makeService();
    final uri = service.startNostrConnect();
    setState(() {
      _nip46 = service;
      _remoteSignerOpen = true;
      _nostrConnectUri = uri;
      _remoteStatus = 'Waiting for remote signer...';
      _error = null;
    });
    // Await the signer-initiated connect ack, then complete login.
    () async {
      try {
        await service.awaitConnect();
        if (!mounted) return;
        setState(() => _remoteStatus = 'Connected! Fetching public key...');
        final result = await service.finishNostrConnect();
        if (!mounted) return;
        Navigator.of(context).pop(result.userPubkey);
      } catch (e) {
        if (!mounted) return;
        setState(() => _remoteStatus = 'Connection failed: $e');
      }
    }();
  }

  /// Validate the pasted nsec via [decodeNsec], then ADOPT it as the running
  /// identity (persist method+nsec, re-boot under the new pubkey, re-subscribe
  /// relays) via [NostrController.loginWithNsec] — the native analogue of the
  /// PWA's `nostrLoginWithNsec` → `applyNostrLogin` (app.js:5036-5074 / 5487).
  /// Pops with the nsec so the setup caller advances the gate; the controller's
  /// boot-epoch bump also remounts the gate onto the shell.
  Future<void> _loginWithNsec() async {
    if (_loggingIn) return;
    final input = _nsecController.text.trim();
    if (input.isEmpty) {
      setState(() => _error = 'Please enter your nsec.');
      return;
    }
    try {
      final bytes = decodeNsec(input);
      if (bytes.length != 32) {
        setState(() => _error = 'Invalid nsec key. Please check and try again.');
        return;
      }
    } catch (_) {
      setState(() => _error = 'Invalid nsec key. Please check and try again.');
      return;
    }
    setState(() {
      _loggingIn = true;
      _error = null;
    });
    try {
      // Persist + adopt the imported account at runtime (no app restart needed).
      await ref.read(nostrControllerProvider).loginWithNsec(input);
    } catch (_) {
      // Defensive: validation above already rejects bad keys, but never strand
      // the user on a half-login — surface the same error and let them retry.
      if (!mounted) return;
      setState(() {
        _loggingIn = false;
        _error = 'Invalid nsec key. Please check and try again.';
      });
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(input);
  }
}
