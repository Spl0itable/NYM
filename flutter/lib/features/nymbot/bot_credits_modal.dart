import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/identity/modal_chrome.dart';
import '../shop/shop_purchase_policy.dart';
import '../../state/nostr_controller.dart';
import '../i18n/i18n.dart';
import 'nymbot_models.dart';
import 'nymbot_providers.dart';
import '../../widgets/common/nym_field.dart';

/// Shown instead of the purchase UI where credits can't be sold; named so a test can hold the i18n catalog to it.
const String kBotCreditsBuyNotice =
    'Nymbot credits cannot be purchased in this app. Credits are '
    'bought from the Nymchat web app in your browser. Credits you '
    'already have work here as usual.';
const String kBotCreditsGiftNotice =
    'Nymbot credits cannot be gifted from this app. Credits are '
    'bought from the Nymchat web app in your browser, and can be '
    'gifted from there. Credits you already have work here as '
    'usual.';
const String kBotCreditsHeader = 'NYMBOT CREDITS';
const String kBotCreditsTitle = 'Nymbot private message credits';

/// Every literal the credits sheet shows when purchases are off.
const List<String> kBotCreditsDisabledStrings = [
  kBotCreditsBuyNotice,
  kBotCreditsGiftNotice,
  kBotCreditsHeader,
  kBotCreditsTitle,
];

/// Nymbot buy/gift credits sheet; in gift mode the invoice carries `recipientPubkey` so the worker credits them.
class BotCreditsModal extends ConsumerStatefulWidget {
  const BotCreditsModal({
    super.key,
    required this.colors,
    this.giftRecipientPubkey,
    this.giftRecipientNym,
    this.initialTier = CreditTier.standard,
  });

  final NymColors colors;

  /// Recipient pubkey when gifting; null for a self-buy.
  final String? giftRecipientPubkey;

  /// Recipient base nym when gifting.
  final String? giftRecipientNym;

  /// Opening tier; Pro when a Pro model is pinned.
  final CreditTier initialTier;

  bool get isGift =>
      giftRecipientPubkey != null && giftRecipientPubkey!.isNotEmpty;

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

  /// Selected preset; null when the custom field drives the amount.
  int? _selectedPreset;
  BotInvoice? _invoice;
  bool _loading = false;
  String? _error;

  static const List<int> _standardPresets = [100, 500, 1000, 2500, 5000, 10000];
  static const List<int> _proPresets = [
    2000,
    5000,
    10000,
    20000,
    50000,
    100000
  ];

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

  ProModelCatalog get _catalog {
    final c = ref.read(proModelCatalogProvider);
    return c.isEmpty ? kProModelCatalogFallback : c;
  }

  int _creditsForSats(int sats) =>
      _catalog.creditsForSats(sats < 0 ? 0 : sats, _tier == CreditTier.pro);

  /// Effective amount in sats; the custom field wins when non-empty.
  int? get _amountSats {
    final raw = _custom.text.trim();
    if (raw.isNotEmpty) {
      final v = int.tryParse(raw);
      return (v != null && v > 0) ? v : null;
    }
    return _selectedPreset;
  }

  String _satLabel(int sats) => sats >= 1000
      ? '${(sats / 1000).toStringAsFixed(sats % 1000 == 0 ? 0 : 1)}K'
      : '$sats';

  String get _creditWord => _tier == CreditTier.pro ? tr('Pro') : tr('credits');

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    // Presented in the zap modal's chrome, like the PWA.
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
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.only(bottom: 14),
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: c.glassBorder)),
                  ),
                  child: Text(
                    botCreditPurchasesDisabled
                        ? tr(kBotCreditsHeader)
                        : tr('SEND LIGHTNING ZAP'),
                    style: TextStyle(
                      color: c.primary,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                Text(
                  botCreditPurchasesDisabled
                      ? tr(kBotCreditsTitle)
                      : widget.isGift
                          ? tr('Gift Nymbot credits to @{nym}',
                              {'nym': widget.giftRecipientNym ?? 'user'})
                          : tr('Buy Nymbot private message credits'),
                  style: TextStyle(
                      color: c.textBright,
                      fontSize: 16,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 14),
                if (botCreditPurchasesDisabled)
                  _purchasesDisabledNote(c)
                else if (_invoice == null) ...[
                  _tierFraming(c),
                  const SizedBox(height: 10),
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
                    Text(_error!,
                        style: TextStyle(color: c.danger, fontSize: 12)),
                  ],
                  const SizedBox(height: 14),
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
                  _InvoiceView(
                      invoice: _invoice!,
                      colors: c,
                      onBack: () {
                        setState(() => _invoice = null);
                      }),
              ],
            ),
          ),
        ),
        ModalChrome.closeChip(c, () => Navigator.of(context).maybePop()),
      ],
    );
  }

  /// Says where to buy credits when they can't be sold here, with no call to action (see shop_purchase_policy.dart).
  Widget _purchasesDisabledNote(NymColors c) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 4, bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: c.insetFill,
        border: Border.all(color: c.insetBorder),
        borderRadius: NymRadius.rsm,
      ),
      child: Text(
        tr(widget.isGift ? kBotCreditsGiftNotice : kBotCreditsBuyNotice),
        style: TextStyle(color: c.textDim, fontSize: 12, height: 1.45),
      ),
    );
  }

  /// Two equal tier pills; the active one uses the lightning accent for both tiers.
  Widget _tierFraming(NymColors c) {
    return Text(
      tr('Standard picks a model for you, per question. Pro answers with the '
          'one frontier model you choose. Separate balances, and neither '
          'converts into the other.'),
      style: TextStyle(color: c.textDim, fontSize: 12, height: 1.35),
    );
  }

  Widget _tierToggle(NymColors c) {
    Widget seg(String label, CreditTier tier) {
      final active = _tier == tier;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() {
            _tier = tier;
            _invoice = null;
            // Reset the selection since preset sets differ per tier.
            _selectedPreset = null;
          }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: active
                  ? c.lightning.withValues(alpha: 0.12)
                  : c.insetFill,
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

  /// Sats presets, each showing its bulk-bonus credit count.
  Widget _amountGrid(NymColors c) {
    return GridView.count(
      crossAxisCount: 3,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1.5,
      children: [
        for (final sats in _presets) _amountBtn(c, sats),
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
              : c.insetFill,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? c.lightning.withValues(alpha: 0.5) : c.border,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                      color: c.lightning.withValues(alpha: 0.15),
                      blurRadius: 15)
                ]
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

  Widget _customRow(NymColors c) {
    return TextField(
      controller: _custom,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      style: TextStyle(color: c.inputText, fontSize: 14),
      decoration: NymField.decoration(c,
          hint: tr('Custom amount (sats)'),
          fontSize: 14,
          radius: BorderRadius.circular(8),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
    );
  }

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
      style:
          TextStyle(color: c.text, fontSize: 13, fontWeight: FontWeight.w600),
    );
  }

  Widget _pricingNote(NymColors c) {
    final lines = _tier == CreditTier.pro
        ? [
            tr('Pro replies are metered on the tokens they use, charged in '
                'thousandths of a credit — the per-million-token rates are in ?model.'),
            tr('Repeated context is billed at the cached rate, a tenth of the fresh one.'),
            _catalog.bulkBonusLine(true),
          ]
        : [
            tr('Replies are metered on the tokens they use, charged in thousandths '
                'of a credit — a short question costs a fraction of one.'),
            tr('Coding and reasoning/math cost more per token, because those routes '
                'use larger models.'),
            _catalog.bulkBonusLine(false),
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
                  style:
                      TextStyle(color: c.textDim, fontSize: 11, height: 1.35)),
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

    // Worker memo like "Nymbot credits gift for @nym — 100 messages".
    final isPro = _tier == CreditTier.pro;
    final credits = _creditsForSats(sats);
    final creditWord = isPro
        ? '$credits Pro credit${credits == 1 ? '' : 's'}'
        : '$credits message${credits == 1 ? '' : 's'}';
    final giftNym = widget.giftRecipientNym;
    final comment = giftNym != null
        ? 'Nymbot ${isPro ? 'Pro ' : ''}credits gift for @$giftNym — $creditWord'
        : 'Nymbot ${isPro ? 'Pro ' : ''}credits — $creditWord';

    // Best-effort signed NIP-57 zap request so the worker's receipt-verify fallback stays available.
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
      // Null means the chat isn't bound to an identity yet; the worker needs a pubkey.
      if (inv == null) {
        err = tr(
            'Open the Nymbot chat once to bind your identity, then try again.');
      } else if (inv.pr.isEmpty) {
        err = tr('Failed to generate invoice. Please try again.');
        inv = null;
      }
    } catch (e) {
      // Surface the real failure; never fabricate a placeholder bolt11.
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

/// Invoice screen: bolt11 QR, copy, open-wallet, and settlement polling.
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
  static const int _maxChecks = 180; // 180 × 2s ≈ 6 min.
  bool _paid = false;
  bool _checking = false;
  String _status = tr('Waiting for payment…');

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _check());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _check({bool manual = false}) async {
    if (_paid) return;
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
        // Give up after 180 polls with a distinct hint.
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
      // No Lightning wallet registered; leave the QR and copy path.
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    if (_paid) {
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
        Row(
          children: [
            Expanded(
              child: _iconBtn(
                c,
                tr('Copy Invoice'),
                () => Clipboard.setData(ClipboardData(text: widget.invoice.pr)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: _iconBtn(c, tr('Open Wallet'), _openWallet)),
          ],
        ),
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
                    style: TextStyle(color: _checking ? c.warning : c.text)),
              ),
            ],
          ),
        ),
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

/// 15px spinner: a 2px dim ring with a primary sweep at 1s linear.
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
