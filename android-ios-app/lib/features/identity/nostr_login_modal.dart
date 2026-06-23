import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/crypto/bech32_codec.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../services/storage/key_value_store.dart';
import '../../services/storage/secure_store.dart';
import '../../state/settings_provider.dart' show keyValueStoreProvider;
import 'nip46_service.dart';

/// Login with Nostr (`#nostrLoginModal`, index.html:1017).
///
/// Sections (verbatim order): a disabled NIP-07 browser-extension button (no
/// extension on native), a NIP-46 remote-signer flow (build a
/// `nostrconnect://` URI + QR, or paste a `bunker://` URI), then paste-nsec
/// (validated via [decodeNsec]). Returns the entered nsec via `Navigator.pop`
/// when the user logs in with a key.
class NostrLoginModal extends ConsumerStatefulWidget {
  const NostrLoginModal({super.key});

  static Future<String?> open(BuildContext context) {
    return showDialog<String>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
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
  final _bunkerController = TextEditingController();
  String? _error;
  bool _remoteSignerOpen = false;
  String? _nostrConnectUri;

  Nip46Service? _nip46;
  String _remoteStatus = 'Waiting for remote signer…';
  bool _connecting = false;

  @override
  void dispose() {
    _nsecController.dispose();
    _bunkerController.dispose();
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
          constraints: const BoxConstraints(maxWidth: 460),
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: c.bgSecondary,
                borderRadius: NymRadius.rxl,
                border: Border.all(color: c.glassBorder),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 40,
                    offset: const Offset(0, 20),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.9,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _header(c),
                    Flexible(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Login with your Nostr identity to sync settings '
                              'across devices.',
                              style:
                                  TextStyle(color: c.textDim, fontSize: 13),
                            ),
                            const SizedBox(height: 16),
                            _extensionOption(c),
                            _divider(c),
                            _remoteSignerOption(c),
                            _divider(c),
                            _nsecOption(c),
                          ],
                        ),
                      ),
                    ),
                    _actions(c),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(NymColors c) => Container(
        padding: const EdgeInsets.fromLTRB(24, 20, 16, 16),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.glassBorder)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'Login with Nostr',
                style: TextStyle(
                  color: c.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            IconButton(
              icon: Icon(Icons.close, color: c.textDim),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );

  Widget _divider(NymColors c) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Expanded(child: Divider(color: c.glassBorder)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text('or', style: TextStyle(color: c.textDim)),
            ),
            Expanded(child: Divider(color: c.glassBorder)),
          ],
        ),
      );

  /// NIP-07 — web only. Native has no browser extension, so it's disabled.
  Widget _extensionOption(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Opacity(
          opacity: 0.4,
          child: FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.primary),
            onPressed: null,
            child: const Text('Login with Browser Extension'),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Browser extensions (Alby, nos2x) are web-only — not available in '
          'the native app.',
          style: TextStyle(color: c.textDim, fontSize: 11),
        ),
      ],
    );
  }

  Widget _remoteSignerOption(NymColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: c.primary),
          onPressed: _startRemoteSigner,
          child: const Text('Login with Remote Signer'),
        ),
        const SizedBox(height: 4),
        Text(
          'Use Amber, or another NIP-46 compatible remote signer',
          style: TextStyle(color: c.textDim, fontSize: 11),
        ),
        if (_remoteSignerOpen) ...[
          const SizedBox(height: 12),
          Center(
            child: Column(
              children: [
                Text(_remoteStatus,
                    style: TextStyle(color: c.textDim, fontSize: 12)),
                const SizedBox(height: 10),
                if (_nostrConnectUri != null)
                  Container(
                    padding: const EdgeInsets.all(10),
                    color: Colors.white,
                    child: QrImageView(
                      data: _nostrConnectUri!,
                      size: 180,
                      backgroundColor: Colors.white,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text('Connection String',
              style: TextStyle(color: c.text, fontSize: 12)),
          const SizedBox(height: 6),
          // Paste a bunker:// URI from the signer.
          TextField(
            controller: _bunkerController,
            style: TextStyle(color: c.text, fontSize: 13),
            decoration: _decoration(c, 'bunker://… or scan above'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.primary),
            onPressed: _connecting ? null : _connectBunker,
            child: Text(_connecting ? 'Connecting…' : 'Connect'),
          ),
          const SizedBox(height: 6),
          Text(
            'Scan the QR with your remote signer, or paste a bunker:// '
            'connection string here and tap Connect.',
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
        Text('Paste your nsec', style: TextStyle(color: c.text, fontSize: 12)),
        const SizedBox(height: 6),
        TextField(
          controller: _nsecController,
          obscureText: true,
          style: TextStyle(color: c.text, fontSize: 13),
          decoration: _decoration(c, 'nsec1...'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(_error!, style: TextStyle(color: c.danger, fontSize: 12)),
        ],
        const SizedBox(height: 6),
        Text(
          'Your private key stays local and is never sent to any server',
          style: TextStyle(color: c.textDim, fontSize: 11),
        ),
      ],
    );
  }

  Widget _actions(NymColors c) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.glassBorder)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Cancel', style: TextStyle(color: c.textDim)),
          ),
          const SizedBox(width: 8),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: c.primary),
            onPressed: _loginWithNsec,
            child: const Text('Login'),
          ),
        ],
      ),
    );
  }

  InputDecoration _decoration(NymColors c, String hint) => InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: TextStyle(color: c.textDim),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: OutlineInputBorder(
          borderRadius: NymRadius.rxs,
          borderSide: BorderSide(color: c.glassBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: NymRadius.rxs,
          borderSide: BorderSide(color: c.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: NymRadius.rxs,
          borderSide: BorderSide(color: c.primaryA(0.3)),
        ),
      );

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
      _remoteStatus = 'Waiting for remote signer…';
      _error = null;
    });
    // Await the signer-initiated connect ack, then complete login.
    () async {
      try {
        await service.awaitConnect();
        if (!mounted) return;
        setState(() => _remoteStatus = 'Connected! Fetching public key…');
        final result = await service.finishNostrConnect();
        if (!mounted) return;
        Navigator.of(context).pop(result.userPubkey);
      } catch (e) {
        if (!mounted) return;
        setState(() => _remoteStatus = 'Connection failed: $e');
      }
    }();
  }

  /// Connects using a pasted `bunker://` (or `nostrconnect://`) URI: opens the
  /// relay, performs the NIP-46 connect + get_public_key RPC, persists the
  /// session, and pops the modal with the user pubkey.
  Future<void> _connectBunker() async {
    final input = _bunkerController.text.trim();
    if (input.isEmpty) {
      setState(() => _error = 'Paste a bunker:// connection string.');
      return;
    }
    setState(() {
      _connecting = true;
      _error = null;
      _remoteStatus = 'Connecting to remote signer…';
    });
    final service = _nip46 ?? _makeService();
    _nip46 = service;
    try {
      final result = await service.connectViaUri(input);
      if (!mounted) return;
      Navigator.of(context).pop(result.userPubkey);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _remoteStatus = 'Connection failed: $e';
        _error = 'Remote signer connection failed.';
      });
    }
  }

  /// Validate the pasted nsec via [decodeNsec] and return it to the caller.
  void _loginWithNsec() {
    final input = _nsecController.text.trim();
    if (input.isEmpty) {
      setState(() => _error = 'Enter your nsec.');
      return;
    }
    try {
      final bytes = decodeNsec(input);
      if (bytes.length != 32) {
        setState(() => _error = 'Invalid nsec.');
        return;
      }
    } catch (_) {
      setState(() => _error = 'Invalid nsec — could not decode.');
      return;
    }
    Navigator.of(context).pop(input);
  }
}
