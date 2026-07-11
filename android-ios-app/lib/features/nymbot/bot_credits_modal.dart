import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/nym_colors.dart';
import '../../features/identity/modal_chrome.dart';
import '../../state/nostr_controller.dart';
import '../i18n/i18n.dart';
import 'nymbot_models.dart';
import 'nymbot_providers.dart';

/// The Nymbot **buy / gift credits** modal — a 1:1 port of the PWA's
/// `showBotCreditsModal` (zaps.js:530-660) presented as a bottom sheet.
///
/// Two modes share one surface, mirroring the PWA:
///   * **Buy** (`giftRecipient == null`): "Buy Nymbot private message credits".
///   * **Gift** (`giftRecipient != null`): "Gift Nymbot credits to @nym" — the
///     created invoice carries `recipientPubkey`, so the worker credits THEM.
///
/// Layout matches the PWA: a Standard/Pro tier toggle (both segments use the
/// lightning accent), a grid of sats presets (per-tier, with the bulk-bonus
/// credit count shown on each), a custom-amount field, a live credit estimate,
/// and — once an amount is picked — the Lightning invoice (QR placeholder +
/// copyable bolt11).
class BotCreditsModal extends ConsumerStatefulWidget {
  const BotCreditsModal({
    super.key,
    required this.colors,
    this.giftRecipientPubkey,
    this.giftRecipientNym,
    this.initialTier = CreditTier.standard,
  });

  final NymColors colors;

  /// Recipient pubkey when gifting (PWA `giftRecipient.pubkey`). Null = self-buy.
  final String? giftRecipientPubkey;

  /// Recipient base nym when gifting (PWA `giftRecipient.nym`).
  final String? giftRecipientNym;

  /// Opening tier (PWA passes `'pro'` when a Pro model is pinned).
  final CreditTier initialTier;

  bool get isGift =>
      giftRecipientPubkey != null && giftRecipientPubkey!.isNotEmpty;

  /// Presents the modal as a scroll-controlled bottom sheet.
  static Future<void> show(
    BuildContext context, {
    required NymColors colors,
    String? giftRecipientPubkey,
    String? giftRecipientNym,
    CreditTier initialTier = CreditTier.standard,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: colors.bgSecondary,
      builder: (_) => BotCreditsModal(
        colors: colors,
        giftRecipientPubkey: giftRecipientPubkey,
        giftRecipientNym: giftRecipientNym,
        initialTier: initialTier,
      ),
    );
  }

  @override
  ConsumerState<BotCreditsModal> createState() => _BotCreditsModalState();
}

class _BotCreditsModalState extends ConsumerState<BotCreditsModal> {
  late CreditTier _tier;
  final _custom = TextEditingController();

  /// The selected preset (null when the custom field drives the amount).
  int? _selectedPreset;
  BotInvoice? _invoice;
  bool _loading = false;
  String? _error;

  /// Preset purchase tiers (PWA `_botCreditTiers` / `_botProCreditPresets`,
  /// zaps.js:349-352).
  static const List<int> _standardPresets = [100, 500, 1000, 2500, 5000, 10000];
  static const List<int> _proPresets = [2000, 5000, 10000, 20000, 50000, 100000];

  @override
  void initState() {
    super.initState();
    _tier = widget.initialTier;
    _custom.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  List<int> get _presets =>
      _tier == CreditTier.pro ? _proPresets : _standardPresets;

  /// Credits for [sats] at the current tier, with the bulk bonus
  /// (PWA `_botCreditsForSats` / `_botProCreditsForSats`, zaps.js:324-342).
  int _creditsForSats(int sats) {
    final s = sats < 0 ? 0 : sats;
    double mult = 1;
    if (_tier == CreditTier.pro) {
      if (s >= 50000) {
        mult = 1.20;
      } else if (s >= 10000) {
        mult = 1.15;
      } else if (s >= 5000) {
        mult = 1.10;
      }
      return ((s / 100) * mult).floor();
    }
    if (s >= 5000) {
      mult = 1.20;
    } else if (s >= 1000) {
      mult = 1.15;
    } else if (s >= 500) {
      mult = 1.10;
    }
    return ((s / 10) * mult).floor();
  }

  /// The effective amount in sats (custom field wins when non-empty).
  int? get _amountSats {
    final raw = _custom.text.trim();
    if (raw.isNotEmpty) {
      final v = int.tryParse(raw);
      return (v != null && v > 0) ? v : null;
    }
    return _selectedPreset;
  }

  String _satLabel(int sats) =>
      sats >= 1000 ? '${(sats / 1000).toStringAsFixed(sats % 1000 == 0 ? 0 : 1)}K' : '$sats';

  String get _creditWord =>
      _tier == CreditTier.pro ? tr('Pro') : tr('credits');

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    // The PWA presents this purchase through the zap modal chrome
    // (`showBotCreditsModal` reuses `#zapModal`, zaps.js:530): a
    // `.modal-header "Send Lightning Zap"` with a bottom rule + the absolute
    // `.modal-close` ✕ chip, with `#zapRecipientInfo` carrying the buy/gift
    // line. Mirror that here over the bottom sheet.
    return Stack(
      children: [
        Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 18,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // `.modal-header`: 22px UPPERCASE primary ls1.5 w700 + rule.
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.only(bottom: 14),
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    border:
                        Border(bottom: BorderSide(color: c.glassBorder)),
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
                ),
                // PWA `zapRecipientInfo`: gift vs buy heading.
                Text(
                  widget.isGift
                      ? tr('Gift Nymbot credits to @{nym}',
                          {'nym': widget.giftRecipientNym ?? 'user'})
                      : tr('Buy Nymbot private message credits'),
                  style: TextStyle(
                      color: c.textBright,
                      fontSize: 16,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 14),
                if (_invoice == null) ...[
              _tierToggle(c),
              const SizedBox(height: 12),
              _amountGrid(c),
              const SizedBox(height: 12),
              _customRow(c),
              const SizedBox(height: 10),
              _estimate(c),
              _pricingNote(c),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: c.danger, fontSize: 12)),
              ],
              const SizedBox(height: 14),
              // `.send-btn` chrome (styles-chat.css:1920-1943): translucent
              // primary/0.1 pill, primary/0.3 border, h42, 12px UPPERCASE
              // ls1.5 w600 primary label, disabled opacity 0.35. While
              // generating, the PWA pairs the 15px `.loader` with
              // "Generating invoice..." (zaps.js:588-590).
              ModalChrome.sendButton(
                c,
                widget.isGift
                    ? tr('Generate gift invoice')
                    : tr('Pay with Lightning'),
                (_loading || _amountSats == null) ? null : _generate,
                fullWidth: true,
                child: _loading
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _loader(c),
                          const SizedBox(width: 8),
                          Text(
                            tr('GENERATING INVOICE…'),
                            style: TextStyle(
                              color: c.primary,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ],
                      )
                    : null,
              ),
                ] else
                  _InvoiceView(invoice: _invoice!, colors: c, onBack: () {
                    setState(() => _invoice = null);
                  }),
              ],
            ),
          ),
        ),
        // `.modal-close`: 32×32 glass ✕ chip, absolute top-right (14,14).
        ModalChrome.closeChip(c, () => Navigator.of(context).maybePop()),
      ],
    );
  }

  /// `.bot-credit-tier-toggle`: two equal pills; the active one uses the
  /// lightning accent for BOTH Standard and Pro (zaps.js:432-440).
  Widget _tierToggle(NymColors c) {
    Widget seg(String label, CreditTier tier) {
      final active = _tier == tier;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() {
            _tier = tier;
            _invoice = null;
            // Reset the selection — preset sets differ per tier.
            _selectedPreset = null;
          }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: active
                  ? c.lightning.withValues(alpha: 0.12)
                  // Inactive fill: white@0.04 dark / black@0.04 light (mode-aware).
                  : c.insetFill,
              // `.bot-credit-tier-btn`: radius --radius-sm (12).
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: active ? c.lightning.withValues(alpha: 0.5) : c.border,
              ),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: active ? c.lightning : c.textDim,
                fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                fontSize: 13,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.bgTertiary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          seg(tr('Standard'), CreditTier.standard),
          seg(tr('Pro'), CreditTier.pro),
        ],
      ),
    );
  }

  /// The sats-preset grid (`.zap-amounts` in credit mode): each cell shows the
  /// sat label + the bulk-bonus credit count. Selected = lightning glow.
  Widget _amountGrid(NymColors c) {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.5,
      children: [
        for (final sats in _presets)
          _amountBtn(c, sats),
      ],
    );
  }

  Widget _amountBtn(NymColors c, int sats) {
    final selected = _custom.text.trim().isEmpty && _selectedPreset == sats;
    final credits = _creditsForSats(sats);
    return GestureDetector(
      onTap: () => setState(() {
        _selectedPreset = sats;
        _custom.clear();
      }),
      child: Container(
        decoration: BoxDecoration(
          color: selected
              ? c.lightning.withValues(alpha: 0.12)
              // Unselected fill: white@0.04 dark / black@0.04 light (mode-aware).
              : c.insetFill,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? c.lightning.withValues(alpha: 0.5) : c.border,
          ),
          boxShadow: selected
              ? [BoxShadow(color: c.lightning.withValues(alpha: 0.15), blurRadius: 15)]
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(tr('{amount} sats', {'amount': _satLabel(sats)}),
                style: TextStyle(
                    color: c.lightning,
                    fontSize: 15,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text('$credits $_creditWord',
                style: TextStyle(color: c.textDim, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  /// Custom-amount field (`zapCustomAmount`).
  Widget _customRow(NymColors c) {
    return TextField(
      controller: _custom,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      style: TextStyle(color: c.text, fontSize: 14),
      decoration: InputDecoration(
        hintText: tr('Custom amount (sats)'),
        hintStyle: TextStyle(color: c.textDim),
        isDense: true,
        filled: true,
        fillColor: c.bgTertiary,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: c.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: c.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: c.lightning),
        ),
      ),
    );
  }

  /// Live credit estimate (`botCreditEstimate`).
  Widget _estimate(NymColors c) {
    final sats = _amountSats;
    if (sats == null) {
      return Text(tr('Select or enter an amount'),
          style: TextStyle(color: c.textDim, fontSize: 12));
    }
    final credits = _creditsForSats(sats);
    final tierWord = _tier == CreditTier.pro ? tr('Pro') : tr('standard');
    final text = credits == 1
        ? tr('≈ {n} {tier} credit', {'n': credits, 'tier': tierWord})
        : tr('≈ {n} {tier} credits', {'n': credits, 'tier': tierWord});
    return Text(
      text,
      style: TextStyle(color: c.text, fontSize: 13, fontWeight: FontWeight.w600),
    );
  }

  /// Pricing note (`.bot-credit-pricing-note`, zaps.js:466-480).
  Widget _pricingNote(NymColors c) {
    final lines = _tier == CreditTier.pro
        ? [
            tr('Pro replies start at 1–2 Pro credits and scale with reply length '
                '(each model\'s range is in ?model).'),
            tr('Bulk bonus: +10% at 5K sats, +15% at 10K, +20% at 50K.'),
          ]
        : [
            tr('1 credit per general chat, creative writing, or translation reply.'),
            tr('2 credits per coding or reasoning/math reply (larger models).'),
            tr('Bulk bonus: +10% at 500 sats, +15% at 1K, +20% at 5K.'),
          ];
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(l,
                  style: TextStyle(color: c.textDim, fontSize: 11, height: 1.35)),
            ),
        ],
      ),
    );
  }

  Future<void> _generate() async {
    final sats = _amountSats;
    if (sats == null) {
      setState(() => _error = tr('Please select or enter an amount'));
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });

    // Build the purchase comment exactly like the PWA (zaps.js:596-603) so the
    // worker memo reads e.g. "Nymbot credits gift for @nym — 100 messages".
    final isPro = _tier == CreditTier.pro;
    final credits = _creditsForSats(sats);
    final creditWord = isPro
        ? '$credits Pro credit${credits == 1 ? '' : 's'}'
        : '$credits message${credits == 1 ? '' : 's'}';
    final giftNym = widget.giftRecipientNym;
    final comment = giftNym != null
        ? 'Nymbot ${isPro ? 'Pro ' : ''}credits gift for @$giftNym — $creditWord'
        : 'Nymbot ${isPro ? 'Pro ' : ''}credits — $creditWord';

    // Signed NIP-57 zap request riding the create-invoice body so the worker's
    // `canNip57` receipt-verify fallback stays available (zaps.js:601-604) —
    // best-effort, exactly like the PWA's try/catch (a signer failure omits it).
    Map<String, dynamic>? zapRequest;
    try {
      final zr = await ref.read(nostrControllerProvider).buildZapRequest(
            recipientPubkey: NostrController.nymbotPubkey,
            amountSats: sats,
            comment: comment,
          );
      zapRequest = zr?.toJson();
    } catch (_) {}

    BotInvoice? inv;
    String? err;
    try {
      inv = await ref.read(botChatControllerProvider.notifier).buy(
            sats,
            _tier,
            recipientPubkey: widget.giftRecipientPubkey,
            comment: comment,
            zapRequest: zapRequest,
          );
      // A null result means the chat isn't bound to an identity yet — the worker
      // can't issue an invoice without a pubkey (PWA gates on `this.pubkey`).
      if (inv == null) {
        err = tr(
            'Open the Nymbot chat once to bind your identity, then try again.');
      } else if (inv.pr.isEmpty) {
        err = tr('Failed to generate invoice. Please try again.');
        inv = null;
      }
    } catch (e) {
      // Surface the real failure (PWA: `Failed: ${error.message}`,
      // zaps.js:627) — never fabricate a placeholder bolt11.
      err = tr('Failed: {error}', {'error': _short(e)});
      inv = null;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _invoice = inv;
      _error = err;
    });
  }

  static String _short(Object e) {
    final s = e.toString();
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }
}

/// The invoice screen: a real bolt11 QR + copyable invoice + Open-wallet
/// (`lightning:` URI) + live settlement polling, mirroring `displayZapInvoice`
/// + `checkBotCreditPaymentViaServer` for the credit purchase (zaps.js:611-694).
class _InvoiceView extends ConsumerStatefulWidget {
  const _InvoiceView({
    required this.invoice,
    required this.colors,
    required this.onBack,
  });

  final BotInvoice invoice;
  final NymColors colors;
  final VoidCallback onBack;

  @override
  ConsumerState<_InvoiceView> createState() => _InvoiceViewState();
}

class _InvoiceViewState extends ConsumerState<_InvoiceView> {
  Timer? _poll;
  int _checks = 0;
  static const int _maxChecks = 180; // PWA: 180 × 2s ≈ 6 min.
  bool _paid = false;
  bool _checking = false;
  String _status = tr('Waiting for payment…');

  @override
  void initState() {
    super.initState();
    // Poll the worker every 2s for settlement (PWA: 2000ms interval).
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _check());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _check({bool manual = false}) async {
    if (_paid) return;
    // PWA manualCheckPayment: `.zap-status.checking` + loader +
    // "Checking payment..." while the server round-trip runs (zaps.js:707-712).
    if (manual) {
      setState(() {
        _checking = true;
        _status = tr('Checking payment…');
      });
    }
    _checks++;
    final paid = await ref
        .read(botChatControllerProvider.notifier)
        .checkInvoicePaid(widget.invoice);
    if (!mounted) return;
    if (paid) {
      _poll?.cancel();
      setState(() {
        _paid = true;
        _checking = false;
        // handleZapPaymentSuccess shows the same success line for credit
        // purchases as for zaps (zaps.js:1130-1134).
        _status = tr('Zap sent successfully!');
      });
      return;
    }
    if (_checks >= _maxChecks) {
      _poll?.cancel();
    }
    setState(() {
      _checking = false;
      if (manual) {
        _status = tr(
            'Not paid yet — complete the payment in your wallet, then tap again.');
      } else if (_checks >= _maxChecks) {
        // PWA gives up after 180 polls with a distinct hint (zaps.js:686-693).
        _status = tr(
            'Payment not detected yet — if you paid, tap "I\'ve paid" or run ?balance shortly.');
      }
    });
  }

  Future<void> _openWallet() async {
    final uri = Uri.parse('lightning:${widget.invoice.pr}');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // No Lightning wallet registered — leave the QR/copy path for the user.
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    if (_paid) {
      // `.zap-status.paid` (styles-chat.css:288-292): primary border + text
      // over the white/0.03 status fill, with the `zapSuccess` 0.5s scale pop.
      // Content mirrors handleZapPaymentSuccess (zaps.js:1130-1134): ⚡ 24px
      // (mb 10), the status line, `${amount} sats` 20px (mt 10).
      final card = Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        margin: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          border: Border.all(color: c.primary),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            const Text('⚡', style: TextStyle(fontSize: 24)),
            const SizedBox(height: 10),
            Text(_status,
                textAlign: TextAlign.center,
                style: TextStyle(color: c.primary)),
            if (widget.invoice.amountSats > 0) ...[
              const SizedBox(height: 10),
              Text(tr('{n} sats', {'n': widget.invoice.amountSats}),
                  style: TextStyle(color: c.primary, fontSize: 20)),
            ],
          ],
        ),
      );
      return Column(
        children: [
          // `@keyframes zapSuccess`: scale 1 → 1.05 → 1 over 0.5s.
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 500),
            builder: (_, t, child) {
              final pop = 1 + 0.05 * (1 - (2 * t - 1).abs());
              return Transform.scale(scale: pop, child: child);
            },
            child: card,
          ),
          const SizedBox(height: 16),
          ModalChrome.sendButton(
            c,
            tr('Done'),
            () => Navigator.of(context).maybePop(),
            fullWidth: true,
          ),
        ],
      );
    }
    return Column(
      children: [
        // Real bolt11 QR (200px module) in a white frame.
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.lightning.withValues(alpha: 0.3)),
          ),
          child: QrImageView(
            data: widget.invoice.pr,
            size: 200,
            backgroundColor: Colors.white,
          ),
        ),
        const SizedBox(height: 12),
        SelectableText(
          widget.invoice.pr,
          maxLines: 2,
          style: TextStyle(
              color: c.textDim, fontSize: 11, fontFamily: 'monospace'),
        ),
        const SizedBox(height: 10),
        // `.zap-invoice-actions` (styles-chat.css:268-272): two `.icon-btn
        // nm-flex1` pills — "Copy Invoice" / "Open Wallet" — stretched
        // equally with a 10px gap (index.html:2075-2079).
        Row(
          children: [
            Expanded(
              child: _iconBtn(
                c,
                tr('Copy Invoice'),
                () =>
                    Clipboard.setData(ClipboardData(text: widget.invoice.pr)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: _iconBtn(c, tr('Open Wallet'), _openWallet)),
          ],
        ),
        // `.zap-status` (styles-chat.css:274-286): centered box, white/0.03
        // fill, glass border, padding 12, margin 10 0; `.checking` swaps the
        // border + text to `--warning` and shows the 15px `.loader`
        // (manualCheckPayment, zaps.js:707-712).
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          margin: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.03),
            border: Border.all(color: _checking ? c.warning : c.glassBorder),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_checking) ...[
                _loader(c),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(_status,
                    textAlign: TextAlign.center,
                    style:
                        TextStyle(color: _checking ? c.warning : c.text)),
              ),
            ],
          ),
        ),
        // `.modal-actions` (index.html:2083-2086): an `.icon-btn` beside the
        // `.send-btn` "I've paid" (an immediate re-check, PWA
        // `manualCheckPayment`), centered with a 10px gap.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ModalChrome.iconButton(c, tr('Change amount'), widget.onBack),
            const SizedBox(width: 10),
            ModalChrome.sendButton(
              c,
              tr("I've paid"),
              _checking ? null : () => _check(manual: true),
            ),
          ],
        ),
      ],
    );
  }

  /// An `.icon-btn.nm-flex1` — the bordered translucent uppercase pill
  /// (styles-shell.css:912-926) stretched by its parent [Expanded]: white/0.05
  /// fill + glass border + `--text` label in dark; black/0.03 fill + black/0.1
  /// border + `--primary` label in light (styles-themes-responsive.css:595-599).
  Widget _iconBtn(NymColors c, String label, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: c.subtleFill,
          border: Border.all(
              color: c.isLight ? const Color(0x1A000000) : c.glassBorder),
          borderRadius: BorderRadius.circular(8),
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
}

/// The 15px `.loader` spinner (styles-components.css:2173-2182): a 2px
/// `--text-dim` ring with a `--primary` sweep, spinning at 1s linear.
Widget _loader(NymColors c) {
  return SizedBox(
    width: 15,
    height: 15,
    child: CircularProgressIndicator(
      strokeWidth: 2,
      color: c.primary,
      backgroundColor: c.textDim,
    ),
  );
}
