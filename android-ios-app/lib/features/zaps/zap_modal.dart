import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/identity/modal_chrome.dart';
import '../../services/api/api_client.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../i18n/i18n.dart';
import 'lnurl.dart';
import 'zap_logic.dart';

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
    // `.modal` barrier: solid-ui (default) dark `rgba(0,0,0,0.75)` →
    // `body.solid-ui.light-mode .modal { rgba(0,0,0,0.45) }`
    // (styles-themes-responsive.css:1630-1635).
    final isLight = context.nym.isLight;
    return showDialog<void>(
      context: context,
      barrierColor: isLight
          ? const Color(0x73000000) // black @ 0.45
          : const Color(0xBF000000), // black @ 0.75
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
  final _customFocus = FocusNode();
  final _commentController = TextEditingController();
  final _api = ApiClient();
  int? _selected;
  _Phase _phase = _Phase.amount;
  String _statusText = '';
  LnInvoice? _invoice;
  Timer? _verifyTimer;

  /// True while the manual "I've paid" re-check is in flight (zaps.js
  /// `manualCheckPayment` shows a "Checking payment..." spinner state).
  bool _checkingManual = false;

  /// Lowercased bolt11s we've already counted as paid (zaps.js
  /// `_selfCountedZapInvoices`) — guards against the verify poll and a kind-9735
  /// receipt echo both firing success for the same invoice.
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

  /// The Custom field's "Generate" (and Enter) path (zaps.js `triggerCustom`):
  /// a blank/≤0 custom amount focuses the field and returns (no fallback to a
  /// selected preset); a valid one clears any preset highlight and generates.
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
    // No-lightning-address guard (zaps.js `fetchLightningInvoice` throws
    // 'No lightning address available'; modal callers normally pre-check).
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
        _statusText = tr('Failed: {error}', {'error': e});
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
          _statusText = tr('Payment timeout - please check your wallet');
        });
      }
    });
  }

  /// Marks the invoice paid + plays the success affordance, deduped by lowercased
  /// bolt11 (zaps.js `handleZapPaymentSuccess`; dedup via `_selfCountedZapInvoices`).
  void _markPaid(LnInvoice invoice) {
    if (!_settledInvoices.add(invoice.dedupKey)) return; // already counted
    // PWA `window.nymHapticTap` — the same shared 30ms vibrate every other
    // haptic site fires (inline-bindings.js:112-114), mapped app-wide to
    // mediumImpact.
    HapticFeedback.mediumImpact();
    // Record our own zap on the target message's badge instantly (zaps.js
    // `_recordOwnMessageZap`), deduped by the invoice's bolt11 so a later
    // kind-9735 echo for the same payment can't double-count (same dedupKey
    // scheme as the receipt path, _onPrivateZap).
    final messageId = widget.messageId;
    if (messageId != null && messageId.isNotEmpty) {
      ref.read(appStateProvider.notifier).recordMessageZap(
            messageId: messageId,
            zapperPubkey: ref.read(appStateProvider).selfPubkey,
            amountSats: invoice.amountSats,
            dedupKey: ZapLogic.dedupKey(bolt11: invoice.pr, eventId: ''),
            // The self-zap is verify-URL/server confirmed → verified (zaps.js
            // `_recordOwnMessageZap(..., true)`, line 1102/1606).
          );
      // Announce the zap so OTHER clients update the badge (zaps.js
      // `_publishOwnMessageZapEvent` / `_publishOwnPrivateZapEvent`). The
      // controller reads the current view and picks public (channel) vs
      // gift-wrapped (PM/group) delivery. Deduped end-to-end by bolt11 so this
      // announce, the self-record above, and any public-receipt echo of the
      // same payment count once.
      unawaited(ref.read(nostrControllerProvider).announceMessageZap(
            messageId: messageId,
            recipientPubkey: widget.recipientPubkey,
            bolt11: invoice.pr,
            originalKind: widget.originalKind,
          ));
    }
    setState(() => _phase = _Phase.paid);
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  /// "I've paid" manual re-check (zaps.js `manualCheckPayment`). Re-checks the
  /// current invoice once and finalizes if paid; otherwise shows the PWA's
  /// "not paid yet — tap again" status line without leaving the invoice screen.
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
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400),
        width: MediaQuery.of(context).size.width * 0.9,
        margin: const EdgeInsets.all(16),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: c.bgSecondary,
          border: Border.all(color: c.glassBorder),
          borderRadius: NymRadius.rxl,
          // `body.light-mode .modal-content { box-shadow: 0 8px 40px
          // rgba(0,0,0,0.12) }` — softer single shadow in light mode
          // (styles-themes-responsive.css:1050-1052).
          boxShadow: [
            BoxShadow(
              color: c.isLight
                  ? const Color(0x1F000000) // black @ 0.12
                  : const Color(0x80000000), // black @ 0.5
              blurRadius: c.isLight ? 40 : 32,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        // `showDialog` does not insert a Material, so the InkWell-based buttons
        // (amount grid, close, generate, copy/wallet, "I've paid") would fail
        // `debugCheckHasMaterial`. A transparent Material supplies the ink
        // ancestor without painting over the Container's own decoration.
        child: Material(
          type: MaterialType.transparency,
          // `.modal-close` is a separate absolutely-positioned chip over the
          // card, not an inline Row child — so the body and the chip are
          // siblings in a Stack. The `.modal-content` 32px padding lives on the
          // scroll content so the chip can sit at the card corner (14,14).
          child: Stack(
            children: [
              SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _header(c),
                    const SizedBox(height: 24), // `.modal-header` margin-bottom
                // `#zapRecipientInfo` (`.nm-h-75`) — centered, body-size, mb20.
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
              // `.modal-close`: 32×32 glass ✕ chip, absolute top-right (14,14).
              ModalChrome.closeChip(c, () => Navigator.of(context).maybePop()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(NymColors c) {
    // `.modal-header`: 22px, uppercase, --primary, ls1.5, with a hairline
    // bottom border + 14px padding-bottom under the title. The close ✕ is the
    // separate absolute chip (build) — not an inline Row child here.
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
    // `.zap-amounts` is a 3-col grid, collapsing to 2 cols under 768px
    // (styles-themes-responsive.css @media).
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
      // `Comment <span class="nm-h-2">(optional)</span>` — "(optional)" is
      // lowercase w400 ls0 (not uppercased with the rest of the label).
      _formLabel(c, tr('Comment'), optional: true),
      const SizedBox(height: 8),
      _input(c, _commentController, tr('Add a comment to your zap')),
    ];
  }

  /// `.form-label` — 11px UPPERCASE ls1.2 w600 text-dim, with an optional
  /// trailing `.nm-h-2` "(optional)" span (lowercase, w400, ls0).
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
          // `.zap-amount-btn` resting border = `--glass-border`; selected →
          // lightning/0.5.
          border: Border.all(
            color: selected
                ? c.lightning.withValues(alpha: 0.5)
                : c.glassBorder,
          ),
          borderRadius: NymRadius.rsm,
          // `.zap-amount-btn.selected` → soft lightning glow.
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
            // `.zap-amount-btn .sats` — 18px bold lightning.
            Text(
              label,
              style: TextStyle(
                color: c.lightning,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            // bare "sats" text node inherits `.zap-amount-btn` (14px, --text).
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
        // `.zap-invoice-qr` — margin 20px 0.
        margin: const EdgeInsets.symmetric(vertical: 20),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white,
            // `.zap-invoice-qr` — 2px lightning/0.3 border.
            border: Border.all(color: c.lightning.withValues(alpha: 0.3), width: 2),
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
        // `.zap-invoice` — margin 20px 0.
        margin: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          border: Border.all(color: c.lightning.withValues(alpha: 0.3)),
          borderRadius: NymRadius.rsm,
        ),
        child: Text(
          pr,
          // `.zap-invoice` inherits --font-sans (no mono rule); 12px text-dim.
          style: TextStyle(color: c.textDim, fontSize: 12),
        ),
      ),
      // `.zap-invoice-actions` — Copy / Open Wallet `.icon-btn`s, intrinsic
      // width, centered, gap 10 (not stretched).
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _iconBtn(c, tr('Copy Invoice'), _copyInvoice),
          const SizedBox(width: 10),
          _iconBtn(c, tr('Open Wallet'), _openWallet),
        ],
      ),
      // WebLN is not applicable on native — mirrors the PWA hiding the WebLN
      // path when `window.webln` is absent.
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
    // `@keyframes zapSuccess`: scale 1 → 1.05 → 1 over 0.5s.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 500),
      builder: (_, t, child) {
        // Triangle 0→1→0 in t, peaking at 0.05 extra scale halfway through.
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
              child: CircularProgressIndicator(strokeWidth: 2, color: c.primary),
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
    // On the invoice screen the PWA reveals a primary "I've paid" button beside
    // Cancel (index.html `#zapPaidBtn`, zaps.js `displayZapInvoice`). Both keep
    // intrinsic widths centered with a 10px gap (`.modal-actions`).
    if (_phase == _Phase.invoice) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _iconBtn(c, tr('Cancel'), () => Navigator.of(context).maybePop()),
          const SizedBox(width: 10),
          _sendBtn(c, tr("I've paid"), _checkingManual ? null : _manualCheck),
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _iconBtn(c, tr('Cancel'), () => Navigator.of(context).maybePop()),
      ],
    );
  }

  /// `.icon-btn` — bordered uppercase ghost pill (bg white/0.05, glass border,
  /// radius 8, color `--text`, 12px w500 ls0.8, padding 7/14). Used for
  /// Cancel / Copy Invoice / Open Wallet.
  Widget _iconBtn(NymColors c, String label, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: NymRadius.rxs,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          // `body.light-mode .icon-btn { background: rgba(0,0,0,0.03);
          // color: var(--primary) }` (styles-themes-responsive.css:595-599);
          // dark base white@0.05 + `--text`. `subtleFill` is exactly
          // black@.03 light / white@.05 dark (nym_colors.dart:112).
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

  /// `.send-btn` — translucent primary outline pill (bg primary/0.1, border
  /// primary/0.3, text `--primary`, radius 12, h42, padding 22/10, 12px w600
  /// ls1.5; disabled opacity 0.35). The PWA's "I've paid" call-to-action.
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
