import 'dart:async';

import 'package:flutter/material.dart';
import '../../widgets/common/keyboard_inset_dialog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/utils/haptics.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/identity/modal_chrome.dart';
import '../../services/api/api_client.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../i18n/i18n.dart';
import '../shop/shop_controller.dart';
import 'lnurl.dart';
import 'zap_logic.dart';
import '../../widgets/common/nym_sheet.dart';
import '../../widgets/common/nym_field.dart';

/// Zap modal: amount and comment, LNURL-pay invoice with QR, then LUD-21 payment polling.
class ZapModal extends ConsumerStatefulWidget {
  const ZapModal({
    super.key,
    required this.recipientPubkey,
    required this.recipientNym,
    required this.lightningAddress,
    this.messageId,
    this.originalKind,
  });

  final String recipientPubkey;

  final String recipientNym;

  /// Resolved lightning address (lud16/lud06).
  final String lightningAddress;

  /// Zapped message id; null for a profile zap.
  final String? messageId;

  /// `['k', …]` original kind for a message zap.
  final String? originalKind;

  static const presets = [21, 100, 500, 1000, 5000, 10000];

  static Future<void> show(
    BuildContext context, {
    required String recipientPubkey,
    required String recipientNym,
    required String lightningAddress,
    String? messageId,
    String? originalKind,
  }) {
    final isLight = context.nym.isLight;
    return showNymSheet<void>(
      context,
      (_) => ZapModal(
        recipientPubkey: recipientPubkey,
        recipientNym: recipientNym,
        lightningAddress: lightningAddress,
        messageId: messageId,
        originalKind: originalKind,
      ),
      barrierColor: isLight
          ? const Color(0x73000000)
          : const Color(0xBF000000),
    );
  }

  @override
  ConsumerState<ZapModal> createState() => _ZapModalState();
}

enum _Phase { amount, generating, invoice, paid, error }

class _ZapModalState extends ConsumerState<ZapModal> {
  final _customController = TextEditingController();
  final _customFocus = FocusNode();
  final _commentController = TextEditingController();
  final _api = ApiClient();
  int? _selected;
  _Phase _phase = _Phase.amount;
  String _statusText = '';
  LnInvoice? _invoice;
  Timer? _verifyTimer;

  /// True while the manual "I've paid" re-check is in flight.
  bool _checkingManual = false;

  /// Lowercased bolt11s already counted, so the poll and a receipt echo can't both fire success.
  final Set<String> _settledInvoices = {};

  @override
  void dispose() {
    _customController.dispose();
    _customFocus.dispose();
    _commentController.dispose();
    _verifyTimer?.cancel();
    _api.dispose();
    super.dispose();
  }

  /// A blank or non-positive custom amount focuses the field; a valid one clears the preset and generates.
  void _triggerCustom() {
    final val = int.tryParse(_customController.text.trim());
    if (val == null || val <= 0) {
      _customFocus.requestFocus();
      return;
    }
    setState(() => _selected = null);
    _generate();
  }

  int? get _amount {
    final custom = int.tryParse(_customController.text.trim());
    if (custom != null && custom > 0) return custom;
    return _selected;
  }

  Future<void> _generate() async {
    final amount = _amount;
    if (amount == null || amount <= 0) return;
    if (widget.lightningAddress.trim().isEmpty) {
      setState(() {
        _phase = _Phase.error;
        _statusText = tr(
            '@{nym} cannot receive zaps (no lightning address set)',
            {'nym': widget.recipientNym});
      });
      return;
    }
    setState(() {
      _phase = _Phase.generating;
      _statusText = tr('Generating invoice...');
    });
    try {
      final controller = ref.read(nostrControllerProvider);
      final params = await Lnurl.fetchPayParams(widget.lightningAddress);
      var comment = _commentController.text.trim();
      if (comment.isEmpty) {
        comment =
            widget.messageId != null ? 'Zap for your message' : 'Profile zap';
      }
      // Sign a NIP-57 zap request only when the provider supports it; null without a live signer.
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
      _persistPendingZap(invoice);
      // Poll the `zap-verify` proxy for up to 3 minutes; it checks LUD-21 or the NIP-57 receipt server-side.
      _startVerifyPolling(invoice);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _statusText = tr('Failed: {error}', {'error': e});
      });
    }
  }

  void _startVerifyPolling(LnInvoice invoice) {
    final lud21 = invoice.verify != null;
    final step = Duration(seconds: lud21 ? 1 : 3);
    final maxChecks = lud21 ? 180 : 60;
    var checks = 0;
    _verifyTimer = Timer.periodic(step, (t) async {
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
      } else if (checks >= maxChecks) {
        t.cancel();
        if (!lud21) return;
        setState(() {
          _phase = _Phase.error;
          _statusText = tr('Payment timeout - please check your wallet');
        });
      }
    });
  }

  /// Persist the invoice so the next foreground re-verifies it if the OS evicts the app while the wallet is open.
  static String pendingZapId(String pr) => 'zap:${pr.toLowerCase()}';

  void _persistPendingZap(LnInvoice invoice) {
    final messageId = widget.messageId;
    if (messageId == null || messageId.isEmpty) return;
    try {
      ref.read(shopControllerProvider.notifier).addPendingPurchase({
        'kind': 'zap',
        'invoiceId': pendingZapId(invoice.pr),
        'pr': invoice.pr,
        'verify': invoice.verify,
        'providerPubkey': invoice.providerPubkey,
        'amount': invoice.amountSats,
        'messageId': messageId,
        'recipientPubkey': widget.recipientPubkey,
        'originalKind': widget.originalKind,
      });
    } catch (_) {
      // No store (tests/headless): the live poll still settles this zap.
    }
  }

  void _clearPendingZap(LnInvoice invoice) {
    try {
      ref
          .read(shopControllerProvider.notifier)
          .removePendingPurchase(pendingZapId(invoice.pr));
    } catch (_) {}
  }

  /// Marks paid and plays the success affordance, deduped by lowercased bolt11.
  void _markPaid(LnInvoice invoice) {
    if (!_settledInvoices.add(invoice.dedupKey)) return; // already counted
    _clearPendingZap(invoice);
    Haptics.medium();
    // Record our zap on the message badge now, deduped by bolt11 so a later receipt echo can't double-count.
    final messageId = widget.messageId;
    if (messageId != null && messageId.isNotEmpty) {
      ref.read(appStateProvider.notifier).recordMessageZap(
            messageId: messageId,
            zapperPubkey: ref.read(appStateProvider).selfPubkey,
            amountSats: invoice.amountSats,
            dedupKey: ZapLogic.dedupKey(bolt11: invoice.pr, eventId: ''),
            // Server-confirmed, so verified.
          );
      // Announce the zap so other clients update; bolt11 dedup makes every copy count once.
      unawaited(ref.read(nostrControllerProvider).announceMessageZap(
            messageId: messageId,
            recipientPubkey: widget.recipientPubkey,
            bolt11: invoice.pr,
            originalKind: widget.originalKind,
          ));
    }
    setState(() => _phase = _Phase.paid);
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) Navigator.of(context).pop();
    });
  }

  /// Re-checks once, finalizing if paid or showing "not paid yet" otherwise.
  Future<void> _manualCheck() async {
    final invoice = _invoice;
    if (invoice == null || _checkingManual) return;
    setState(() {
      _checkingManual = true;
      _statusText = tr('Checking payment...');
    });
    try {
      final paid = await _api.zapVerify(
        pr: invoice.pr,
        verifyUrl: invoice.verify,
        providerPubkey: invoice.providerPubkey,
      );
      if (!mounted) return;
      if (paid) {
        _verifyTimer?.cancel();
        _markPaid(invoice);
        return;
      }
      setState(() {
        _checkingManual = false;
        _statusText = tr(
            'Not paid yet — complete the payment in your wallet, then tap again.');
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _checkingManual = false;
        _statusText = tr('Could not check yet — try again in a moment.');
      });
    }
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
    final body = Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(c),
                const SizedBox(height: 24),
                Text(
                  widget.messageId != null
                      ? tr('Zapping @{nym}', {'nym': widget.recipientNym})
                      : tr("Zapping @{nym}'s profile",
                          {'nym': widget.recipientNym}),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.textDim, fontSize: 15),
                ),
                const SizedBox(height: 20),
                if (_phase == _Phase.amount) ..._amountSection(c),
                if (_phase == _Phase.generating) _status(c, checking: true),
                if (_phase == _Phase.error) _status(c),
                if (_phase == _Phase.invoice) ..._invoiceSection(c),
                if (_phase == _Phase.invoice && _statusText.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _status(c, checking: _checkingManual),
                ],
                if (_phase == _Phase.paid) _paidSection(c),
                const SizedBox(height: 20),
                _actions(c),
              ],
            ),
          ),
          ModalChrome.closeChip(c, () => Navigator.of(context).pop()),
        ],
      ),
    );
    return NymDiscardGuard(
      isDirty: () =>
          _phase == _Phase.amount &&
          (_customController.text.trim().isNotEmpty ||
              _commentController.text.trim().isNotEmpty),
      child: nymSheetOr(
        context,
        body,
        (body) => KeyboardInsetDialog(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            width: MediaQuery.of(context).size.width * 0.9,
            margin: const EdgeInsets.all(16),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: c.bgSecondary,
              border: Border.all(color: c.glassBorder),
              borderRadius: NymRadius.rxl,
              boxShadow: [
                BoxShadow(
                  color: c.isLight
                      ? const Color(0x1F000000)
                      : const Color(0x80000000),
                  blurRadius: c.isLight ? 40 : 32,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: body,
          ),
        ),
      ),
    );
  }

  Widget _header(NymColors c) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.glassBorder)),
      ),
      child: Text(
        tr('SEND LIGHTNING ZAP'),
        style: TextStyle(
          color: c.primary,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  List<Widget> _amountSection(NymColors c) {
    // 3 columns, 2 under 768px.
    final cols = MediaQuery.of(context).size.width < 768 ? 2 : 3;
    return [
      _formLabel(c, tr('Select Amount')),
      const SizedBox(height: 8),
      GridView.count(
        crossAxisCount: cols,
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
            child: _input(c, _customController, tr('Custom amount (sats)'),
                number: true,
                focusNode: _customFocus,
                onSubmitted: (_) => _triggerCustom()),
          ),
          const SizedBox(width: 10),
          _generateBtn(c),
        ],
      ),
      const SizedBox(height: 20),
      // "(optional)" stays lowercase w400, unlike the rest of the label.
      _formLabel(c, tr('Comment'), optional: true),
      const SizedBox(height: 8),
      _input(c, _commentController, tr('Add a comment to your zap')),
    ];
  }

  Widget _formLabel(NymColors c, String text, {bool optional = false}) {
    return Text.rich(
      TextSpan(
        text: text.toUpperCase(),
        style: TextStyle(
          color: c.textDim,
          fontSize: 11,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w600,
        ),
        children: optional
            ? [
                TextSpan(
                  text: ' ${tr('(optional)')}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w400,
                    letterSpacing: 0,
                  ),
                ),
              ]
            : null,
      ),
    );
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
            color:
                selected ? c.lightning.withValues(alpha: 0.5) : c.glassBorder,
          ),
          borderRadius: NymRadius.rsm,
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: c.lightning.withValues(alpha: 0.15),
                    blurRadius: 15,
                  ),
                ]
              : null,
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
            Text(tr('sats'), style: TextStyle(color: c.text, fontSize: 14)),
          ],
        ),
      ),
    );
  }

  Widget _generateBtn(NymColors c) {
    return InkWell(
      onTap: _triggerCustom,
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
          tr('Generate'),
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
        margin: const EdgeInsets.symmetric(vertical: 20),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            border:
                Border.all(color: c.lightning.withValues(alpha: 0.3), width: 2),
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
        margin: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          border: Border.all(color: c.lightning.withValues(alpha: 0.3)),
          borderRadius: NymRadius.rsm,
        ),
        child: Text(
          pr,
          style: TextStyle(color: c.textDim, fontSize: 12),
        ),
      ),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _iconBtn(c, tr('Copy Invoice'), _copyInvoice),
          const SizedBox(width: 10),
          _iconBtn(c, tr('Open Wallet'), _openWallet),
        ],
      ),
      // WebLN doesn't apply on native.
    ];
  }

  Widget _paidSection(NymColors c) {
    final card = Container(
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
          Text(tr('Zap sent successfully!'),
              style: TextStyle(color: c.primary)),
          const SizedBox(height: 4),
          Text(tr('{n} sats', {'n': _invoice?.amountSats ?? ''}),
              style: TextStyle(color: c.primary, fontSize: 12)),
        ],
      ),
    );
    // Scale 1 -> 1.05 -> 1 over 0.5s.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 500),
      builder: (_, t, child) {
        final pop = 1 + 0.05 * (1 - (2 * t - 1).abs());
        return Transform.scale(scale: pop, child: child);
      },
      child: card,
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
              child:
                  CircularProgressIndicator(strokeWidth: 2, color: c.primary),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              _statusText.isNotEmpty
                  ? _statusText
                  : (checking ? tr('Generating invoice...') : ''),
              textAlign: TextAlign.center,
              style: TextStyle(color: checking ? c.warning : c.text),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actions(NymColors c) {
    if (_phase == _Phase.invoice) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _iconBtn(c, tr('Cancel'), () => Navigator.of(context).pop()),
          const SizedBox(width: 10),
          _sendBtn(c, tr("I've paid"), _checkingManual ? null : _manualCheck),
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _iconBtn(c, tr('Cancel'), () => Navigator.of(context).pop()),
      ],
    );
  }

  Widget _iconBtn(NymColors c, String label, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: NymRadius.rxs,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: c.subtleFill,
          border: Border.all(color: c.glassBorder),
          borderRadius: NymRadius.rxs,
        ),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            color: c.isLight ? c.primary : c.text,
            fontSize: 12,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }

  Widget _sendBtn(NymColors c, String label, VoidCallback? onTap) {
    return Opacity(
      opacity: onTap == null ? 0.35 : 1,
      child: InkWell(
        onTap: onTap,
        borderRadius: NymRadius.rsm,
        child: Container(
          height: 42,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
          decoration: BoxDecoration(
            color: c.primaryA(0.1),
            border: Border.all(color: c.primaryA(0.3)),
            borderRadius: NymRadius.rsm,
          ),
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              color: c.primary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.5,
            ),
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
    ValueChanged<String>? onSubmitted,
    FocusNode? focusNode,
  }) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      keyboardType: number ? TextInputType.number : TextInputType.text,
      style: TextStyle(color: c.inputText, fontSize: 15),
      decoration: NymField.decoration(c, hint: hint),
    );
  }
}
