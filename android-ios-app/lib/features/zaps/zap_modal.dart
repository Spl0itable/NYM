import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../services/api/api_client.dart';
import '../../state/nostr_controller.dart';
import 'lnurl.dart';

/// `#zapModal` (`.zap-modal`, index.html lines 2021-2098; zaps.js
/// `showZapModal` / `generateZapInvoice` / `displayZapInvoice`). Preset amounts
/// + custom + comment, then resolves the recipient's lightning address via
/// LNURL-pay, shows the bolt11 QR + copy + Open Wallet, and polls the LUD-21
/// verify URL for a "paid" affordance.
///
/// Lazy network: nothing is fetched until the user picks an amount (Generate).
class ZapModal extends ConsumerStatefulWidget {
  const ZapModal({
    super.key,
    required this.recipientPubkey,
    required this.recipientNym,
    required this.lightningAddress,
    this.messageId,
    this.originalKind,
  });

  /// Recipient pubkey (zap `['p', …]`).
  final String recipientPubkey;

  /// Recipient display nym (shown in the header).
  final String recipientNym;

  /// Recipient's resolved lightning address (lud16/lud06).
  final String lightningAddress;

  /// The zapped message id (null for a profile zap).
  final String? messageId;

  /// `['k', …]` original kind tag for a message zap.
  final String? originalKind;

  /// Preset sats amounts (index.html `data-amount`).
  static const presets = [21, 100, 500, 1000, 5000, 10000];

  static Future<void> show(
    BuildContext context, {
    required String recipientPubkey,
    required String recipientNym,
    required String lightningAddress,
    String? messageId,
    String? originalKind,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: const Color(0xB3000000), // rgba(0,0,0,0.7)
      builder: (_) => ZapModal(
        recipientPubkey: recipientPubkey,
        recipientNym: recipientNym,
        lightningAddress: lightningAddress,
        messageId: messageId,
        originalKind: originalKind,
      ),
    );
  }

  @override
  ConsumerState<ZapModal> createState() => _ZapModalState();
}

enum _Phase { amount, generating, invoice, paid, error }

class _ZapModalState extends ConsumerState<ZapModal> {
  final _customController = TextEditingController();
  final _commentController = TextEditingController();
  final _api = ApiClient();
  int? _selected;
  _Phase _phase = _Phase.amount;
  String _statusText = '';
  LnInvoice? _invoice;
  Timer? _verifyTimer;

  /// Lowercased bolt11s we've already counted as paid (zaps.js
  /// `_selfCountedZapInvoices`) — guards against the verify poll and a kind-9735
  /// receipt echo both firing success for the same invoice.
  final Set<String> _settledInvoices = {};

  @override
  void dispose() {
    _customController.dispose();
    _commentController.dispose();
    _verifyTimer?.cancel();
    _api.dispose();
    super.dispose();
  }

  int? get _amount {
    final custom = int.tryParse(_customController.text.trim());
    if (custom != null && custom > 0) return custom;
    return _selected;
  }

  Future<void> _generate() async {
    final amount = _amount;
    if (amount == null || amount <= 0) return;
    // No-lightning-address guard (zaps.js `fetchLightningInvoice` throws
    // 'No lightning address available'; modal callers normally pre-check).
    if (widget.lightningAddress.trim().isEmpty) {
      setState(() {
        _phase = _Phase.error;
        _statusText =
            '@${widget.recipientNym} cannot receive zaps (no lightning address set)';
      });
      return;
    }
    setState(() {
      _phase = _Phase.generating;
      _statusText = 'Generating invoice...';
    });
    try {
      final controller = ref.read(nostrControllerProvider);
      final params = await Lnurl.fetchPayParams(widget.lightningAddress);
      var comment = _commentController.text.trim();
      if (comment.isEmpty) {
        comment = widget.messageId != null
            ? 'Zap for your message'
            : 'Profile zap';
      }
      // Build (and sign) the NIP-57 zap request only when the provider supports
      // it; buildZapRequest returns null when there is no live signer.
      final zapReq = (params.allowsNostr && params.nostrPubkey != null)
          ? await controller.buildZapRequest(
              recipientPubkey: widget.recipientPubkey,
              amountSats: amount,
              messageId: widget.messageId,
              originalKind: widget.originalKind,
              comment: comment,
            )
          : null;
      final invoice = await Lnurl.fetchInvoice(
        params: params,
        amountSats: amount,
        comment: comment,
        zapRequest: zapReq,
      );
      if (!mounted) return;
      setState(() {
        _invoice = invoice;
        _phase = _Phase.invoice;
      });
      // LUD-21: poll the backend `zap-verify` proxy for up to 3 minutes
      // (zaps.js checkZapPayment → _serverVerifyZapPaid, 180 × 1s). The proxy
      // server-side fetches the LUD-21 verify URL (or validates a NIP-57
      // receipt), so the client only reads `data.paid`.
      if (invoice.verify != null) _startVerifyPolling(invoice);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _statusText = 'Failed: $e';
      });
    }
  }

  void _startVerifyPolling(LnInvoice invoice) {
    var checks = 0;
    _verifyTimer = Timer.periodic(const Duration(seconds: 1), (t) async {
      checks++;
      final paid = await _api.zapVerify(
        pr: invoice.pr,
        verifyUrl: invoice.verify,
        providerPubkey: invoice.providerPubkey,
      );
      if (!mounted) return;
      if (paid) {
        t.cancel();
        _markPaid(invoice);
      } else if (checks >= 180) {
        t.cancel();
        setState(() {
          _phase = _Phase.error;
          _statusText = 'Payment timeout - please check your wallet';
        });
      }
    });
  }

  /// Marks the invoice paid + plays the success affordance, deduped by lowercased
  /// bolt11 (zaps.js `handleZapPaymentSuccess`; dedup via `_selfCountedZapInvoices`).
  void _markPaid(LnInvoice invoice) {
    if (!_settledInvoices.add(invoice.dedupKey)) return; // already counted
    HapticFeedback.lightImpact(); // PWA `window.nymHapticTap`
    setState(() => _phase = _Phase.paid);
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  Future<void> _copyInvoice() async {
    final pr = _invoice?.pr;
    if (pr == null) return;
    await Clipboard.setData(ClipboardData(text: pr));
  }

  Future<void> _openWallet() async {
    final pr = _invoice?.pr;
    if (pr == null) return;
    final uri = Uri.parse(
        pr.toLowerCase().startsWith('lightning:') ? pr : 'lightning:$pr');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Fall back to copying so the user can paste into a wallet.
      await Clipboard.setData(ClipboardData(text: pr));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400),
        width: MediaQuery.of(context).size.width * 0.9,
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: c.bgSecondary,
          border: Border.all(color: c.glassBorder),
          borderRadius: NymRadius.rxl,
          boxShadow: const [
            BoxShadow(color: Color(0x80000000), blurRadius: 32, offset: Offset(0, 8)),
          ],
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(c),
              const SizedBox(height: 16),
              Text(
                widget.messageId != null
                    ? 'Zapping @${widget.recipientNym}'
                    : "Zapping @${widget.recipientNym}'s profile",
                style: TextStyle(color: c.textDim, fontSize: 13),
              ),
              const SizedBox(height: 16),
              if (_phase == _Phase.amount) ..._amountSection(c),
              if (_phase == _Phase.generating) _status(c, checking: true),
              if (_phase == _Phase.error) _status(c),
              if (_phase == _Phase.invoice) ..._invoiceSection(c),
              if (_phase == _Phase.paid) _paidSection(c),
              const SizedBox(height: 20),
              _actions(c),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(NymColors c) {
    return Row(
      children: [
        Expanded(
          child: Text(
            'SEND LIGHTNING ZAP',
            style: TextStyle(
              color: c.primary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
        ),
        InkWell(
          onTap: () => Navigator.of(context).maybePop(),
          borderRadius: const BorderRadius.all(Radius.circular(16)),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.05),
              border: Border.all(color: c.glassBorder),
            ),
            child: Icon(Icons.close, size: 16, color: c.textDim),
          ),
        ),
      ],
    );
  }

  List<Widget> _amountSection(NymColors c) {
    return [
      Text(
        'SELECT AMOUNT',
        style: TextStyle(
          color: c.textDim,
          fontSize: 11,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 12),
      GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 1.6,
        children: [
          for (final amt in ZapModal.presets) _amountBtn(c, amt),
        ],
      ),
      const SizedBox(height: 20),
      Row(
        children: [
          Expanded(
            child: _input(c, _customController, 'Custom amount (sats)',
                number: true, onChanged: (_) => setState(() => _selected = null)),
          ),
          const SizedBox(width: 10),
          _generateBtn(c),
        ],
      ),
      const SizedBox(height: 20),
      Text(
        'COMMENT (OPTIONAL)',
        style: TextStyle(
          color: c.textDim,
          fontSize: 11,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 8),
      _input(c, _commentController, 'Add a comment to your zap'),
    ];
  }

  Widget _amountBtn(NymColors c, int amt) {
    final selected = _selected == amt;
    final label = amt >= 1000 ? '${amt ~/ 1000}K' : '$amt';
    return InkWell(
      onTap: () {
        setState(() {
          _selected = amt;
          _customController.clear();
        });
        _generate();
      },
      borderRadius: NymRadius.rsm,
      child: Container(
        decoration: BoxDecoration(
          color: selected
              ? c.lightning.withValues(alpha: 0.12)
              : Colors.white.withValues(alpha: 0.04),
          border: Border.all(
            color: c.lightning.withValues(alpha: selected ? 0.5 : 0.0),
          ),
          borderRadius: NymRadius.rsm,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: TextStyle(
                color: c.lightning,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text('sats', style: TextStyle(color: c.text, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _generateBtn(NymColors c) {
    return InkWell(
      onTap: _generate,
      borderRadius: NymRadius.rsm,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.lightning.withValues(alpha: 0.12),
          border: Border.all(color: c.lightning.withValues(alpha: 0.4)),
          borderRadius: NymRadius.rsm,
        ),
        child: Text(
          'Generate',
          style: TextStyle(
            color: c.lightning,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  List<Widget> _invoiceSection(NymColors c) {
    final pr = _invoice!.pr;
    return [
      Container(
        alignment: Alignment.center,
        margin: const EdgeInsets.symmetric(vertical: 8),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: c.lightning.withValues(alpha: 0.3)),
            borderRadius: NymRadius.rsm,
          ),
          child: QrImageView(
            data: pr,
            size: 200,
            backgroundColor: Colors.white,
          ),
        ),
      ),
      Container(
        padding: const EdgeInsets.all(15),
        margin: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          border: Border.all(color: c.lightning.withValues(alpha: 0.3)),
          borderRadius: NymRadius.rsm,
        ),
        child: Text(
          pr,
          style: TextStyle(
            color: c.textDim,
            fontSize: 12,
            fontFamily: 'monospace',
          ),
        ),
      ),
      Row(
        children: [
          Expanded(child: _iconBtn(c, 'Copy Invoice', _copyInvoice)),
          const SizedBox(width: 10),
          Expanded(child: _iconBtn(c, 'Open Wallet', _openWallet)),
        ],
      ),
      // WebLN is not applicable on native — mirrors the PWA hiding the WebLN
      // path when `window.webln` is absent.
    ];
  }

  Widget _paidSection(NymColors c) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        border: Border.all(color: c.primary),
        borderRadius: NymRadius.rsm,
      ),
      child: Column(
        children: [
          const Text('⚡', style: TextStyle(fontSize: 40)),
          const SizedBox(height: 4),
          Text('Zap sent successfully!',
              style: TextStyle(color: c.primary)),
          const SizedBox(height: 4),
          Text('${_invoice?.amountSats ?? ''} sats',
              style: TextStyle(color: c.primary, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _status(NymColors c, {bool checking = false}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        border: Border.all(color: checking ? c.warning : c.glassBorder),
        borderRadius: NymRadius.rsm,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (checking) ...[
            SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(strokeWidth: 2, color: c.primary),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              checking ? 'Generating invoice...' : _statusText,
              textAlign: TextAlign.center,
              style: TextStyle(color: checking ? c.warning : c.text),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actions(NymColors c) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _iconBtn(c, 'Cancel', () => Navigator.of(context).maybePop()),
      ],
    );
  }

  Widget _iconBtn(NymColors c, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: NymRadius.rsm,
      child: Container(
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.primary.withValues(alpha: 0.1),
          border: Border.all(color: c.primary.withValues(alpha: 0.3)),
          borderRadius: NymRadius.rsm,
        ),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            color: c.primary,
            fontSize: 12,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _input(
    NymColors c,
    TextEditingController controller,
    String hint, {
    bool number = false,
    ValueChanged<String>? onChanged,
  }) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      keyboardType: number ? TextInputType.number : TextInputType.text,
      style: TextStyle(color: c.textBright, fontSize: 15),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: c.textDim),
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.05),
        border: OutlineInputBorder(
          borderRadius: NymRadius.rsm,
          borderSide: BorderSide(color: c.glassBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: NymRadius.rsm,
          borderSide: BorderSide(color: c.glassBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: NymRadius.rsm,
          borderSide: BorderSide(color: c.primary.withValues(alpha: 0.3)),
        ),
      ),
    );
  }
}
