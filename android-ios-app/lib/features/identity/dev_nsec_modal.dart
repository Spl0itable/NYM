import 'package:flutter/material.dart';

import '../../core/crypto/bech32_codec.dart';
import '../../core/crypto/keys.dart';
import '../../core/theme/nym_colors.dart';
import '../i18n/i18n.dart';
import 'modal_chrome.dart';

/// The reserved developer pubkey ("Luxas"), `verifiedDeveloper.pubkey`
/// (app.js:1092). Picking a reserved nickname requires proving ownership of the
/// matching nsec before the name is allowed.
const String kVerifiedDeveloperPubkey =
    'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df';

/// Reserved nicknames (`isReservedNick`, users.js:66-69): a name is reserved
/// when its base (lower-cased, `#suffix` stripped, trimmed) is in this set.
const Set<String> kReservedNicks = {'luxas', 'nymbot'};

/// Whether [nick] is a reserved nickname (matches the PWA's `isReservedNick`).
bool isReservedNick(String nick) {
  final base = nick.toLowerCase().replaceFirst(RegExp(r'#.*$'), '').trim();
  return kReservedNicks.contains(base);
}

/// Result of a successful developer-nsec verification.
class DevNsecResult {
  const DevNsecResult({required this.nsec, required this.pubkey});

  /// The verified nsec (as entered), so callers can persist it for auto-login
  /// (`nymSecretSet('nym_dev_nsec', cmdResult.nsec)`, app.js:2702).
  final String nsec;

  /// The derived developer pubkey (equals [kVerifiedDeveloperPubkey]).
  final String pubkey;
}

/// Verifies [nsec] maps to the developer pubkey (`verifyDeveloperNsec`,
/// users.js:75-86). Returns the result on a match, or null otherwise.
DevNsecResult? verifyDeveloperNsec(String nsec) {
  try {
    final bytes = decodeNsec(nsec.trim());
    if (bytes.length != 32) return null;
    final derived = getPublicKeyHex(bytes);
    if (derived == kVerifiedDeveloperPubkey) {
      return DevNsecResult(nsec: nsec.trim(), pubkey: derived);
    }
  } catch (_) {}
  return null;
}

/// "Reserved Nickname" verification modal (`#devNsecModal`, index.html:995-1014
/// + `showDevNsecModal`/`verifyDevNsec`, app.js:3159-3190).
///
/// Shown when a user picks a reserved nickname ("Luxas" is the developer
/// handle): a password field for the nsec, an inline error when it doesn't
/// match, and Cancel/Verify actions. Resolves a [DevNsecResult] on success, or
/// null on cancel.
class DevNsecModal extends StatefulWidget {
  const DevNsecModal({super.key});

  /// Opens the modal, resolving the verified result or null (cancel).
  static Future<DevNsecResult?> open(BuildContext context) {
    return showDialog<DevNsecResult>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      // `.modal` has no backdrop close-action — only Cancel / ✕ dismiss it.
      barrierDismissible: false,
      builder: (_) => const DevNsecModal(),
    );
  }

  @override
  State<DevNsecModal> createState() => _DevNsecModalState();
}

class _DevNsecModalState extends State<DevNsecModal> {
  final _nsec = TextEditingController();
  bool _error = false;

  @override
  void dispose() {
    _nsec.dispose();
    super.dispose();
  }

  void _verify() {
    final result = verifyDeveloperNsec(_nsec.text);
    if (result != null) {
      Navigator.of(context).pop(result);
    } else {
      setState(() => _error = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          // `.modal-content`: default max-width 500.
          constraints: const BoxConstraints(maxWidth: 500),
          child: Material(
            color: Colors.transparent,
            child: Stack(
              children: [
                ModalChrome.box(
                  c,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ModalChrome.header(c, tr('Reserved Nickname')),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(32, 0, 32, 0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // `.form-label`.
                            Text(
                              tr('"Luxas" is reserved for the Nymchat developer.'),
                              style: TextStyle(
                                color: c.textDim,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 1.2,
                              ),
                            ),
                            const SizedBox(height: 8),
                            // `.nm-h-19` hint.
                            Text(
                              tr('Paste your nsec to verify your identity:'),
                              style:
                                  TextStyle(color: c.textDim, fontSize: 11),
                            ),
                            const SizedBox(height: 8),
                            ModalChrome.focusRing(
                              c,
                              child: TextField(
                                controller: _nsec,
                                obscureText: true,
                                style: TextStyle(
                                    color: c.textBright, fontSize: 15),
                                decoration:
                                    ModalChrome.inputDecoration(c, 'nsec1...'),
                              ),
                            ),
                            if (_error) ...[
                              const SizedBox(height: 6),
                              // `.nm-h-20` error.
                              Text(
                                tr('Invalid nsec - does not match the developer '
                                    'pubkey.'),
                                style:
                                    TextStyle(color: c.danger, fontSize: 12),
                              ),
                            ],
                          ],
                        ),
                      ),
                      // `.modal-actions`: center, gap 10.
                      Padding(
                        padding: const EdgeInsets.fromLTRB(32, 24, 32, 32),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ModalChrome.iconButton(c, tr('Cancel'),
                                () => Navigator.of(context).pop()),
                            const SizedBox(width: 10),
                            ModalChrome.sendButton(c, tr('Verify'), _verify),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                ModalChrome.closeChip(
                    c, () => Navigator.of(context).pop()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
