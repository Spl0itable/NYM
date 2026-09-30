import 'package:flutter/material.dart';
import '../../widgets/common/keyboard_inset_dialog.dart';

import '../../core/crypto/key_format.dart' show normalizePrivkeyInput;
import '../../core/crypto/keys.dart';
import '../../core/theme/nym_colors.dart';
import '../i18n/i18n.dart';
import 'modal_chrome.dart';

/// The reserved developer pubkey; picking a reserved nick requires proving the matching nsec.
const String kVerifiedDeveloperPubkey =
    'd49a9023a21dba1b3c8306ca369bf3243d8b44b8f0b6d1196607f7b0990fa8df';

/// A nick is reserved when its lowercased base, `#suffix` stripped, is in this set.
const Set<String> kReservedNicks = {'luxas', 'nymbot'};

bool isReservedNick(String nick) {
  final base = nick.toLowerCase().replaceFirst(RegExp(r'#.*$'), '').trim();
  return kReservedNicks.contains(base);
}

class DevNsecResult {
  const DevNsecResult({required this.nsec, required this.pubkey});

  /// The verified nsec as entered, so callers can persist it for auto-login.
  final String nsec;

  final String pubkey;
}

/// Returns the result when [nsec] maps to the developer pubkey, else null.
DevNsecResult? verifyDeveloperNsec(String nsec) {
  // Accepts `nsec1…` or bare 64-char hex.
  final bytes = normalizePrivkeyInput(nsec);
  if (bytes == null || bytes.length != 32) return null;
  final derived = getPublicKeyHex(bytes);
  if (derived == kVerifiedDeveloperPubkey) {
    return DevNsecResult(nsec: nsec.trim(), pubkey: derived);
  }
  return null;
}

/// "Reserved Nickname" verification modal; resolves a [DevNsecResult] or null on cancel.
class DevNsecModal extends StatefulWidget {
  const DevNsecModal({super.key});

  static Future<DevNsecResult?> open(BuildContext context) {
    return showDialog<DevNsecResult>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.7),
      // No backdrop dismiss; only Cancel or the close button close it.
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
    return KeyboardInsetDialog(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
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
                            Text(
                              tr('Paste your nsec to verify your identity:'),
                              style: TextStyle(color: c.textDim, fontSize: 11),
                            ),
                            const SizedBox(height: 8),
                            ModalChrome.focusRing(
                              c,
                              child: TextField(
                                controller: _nsec,
                                obscureText: true,
                                style: TextStyle(
                                    color: c.inputText, fontSize: 15),
                                decoration:
                                    ModalChrome.inputDecoration(c, 'nsec1... or hex private key'),
                              ),
                            ),
                            if (_error) ...[
                              const SizedBox(height: 6),
                              Text(
                                tr('Invalid nsec - does not match the developer '
                                    'pubkey.'),
                                style: TextStyle(color: c.danger, fontSize: 12),
                              ),
                            ],
                          ],
                        ),
                      ),
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
                ModalChrome.closeChip(c, () => Navigator.of(context).pop()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
