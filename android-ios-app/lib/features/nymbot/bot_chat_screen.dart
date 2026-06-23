import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import 'nymbot_models.dart';
import 'nymbot_providers.dart';

/// The private 1:1 Nymbot chat screen.
///
/// 1:1 port of the PWA's paid Nymbot PM surface (README "Nymbot" section + spec
/// §11). Features:
///   * message list with the bot,
///   * a collapsed "💭 Reasoning" section above replies that have reasoning,
///   * the Standard / Pro model switch,
///   * `?balance` / `?buy` (invoice QR placeholder),
///   * `?model <name>` picker (the 7 Pro frontier models),
///   * the `?git` connect flow (provider + PAT + repo/branch; PAT on-device,
///     wiped by panic).
///
/// Payment/invoice settlement is stubbed (see TODO(verify) markers); the full UI
/// is built.
class BotChatScreen extends ConsumerStatefulWidget {
  const BotChatScreen({super.key});

  @override
  ConsumerState<BotChatScreen> createState() => _BotChatScreenState();
}

class _BotChatScreenState extends ConsumerState<BotChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Lazy: fetch balance once when the screen opens (no-op if unbound).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(botChatControllerProvider.notifier).refreshBalance();
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  NymColors _colors(BuildContext context) =>
      Theme.of(context).extension<NymColors>() ?? _fallbackColors;

  @override
  Widget build(BuildContext context) {
    final c = _colors(context);
    final state = ref.watch(botChatControllerProvider);

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        backgroundColor: c.bgSecondary,
        foregroundColor: c.textBright,
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: c.purple.withValues(alpha: 0.2),
              child: Text('🤖', style: const TextStyle(fontSize: 16)),
            ),
            const SizedBox(width: 10),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Nymbot',
                    style: TextStyle(
                        color: c.textBright,
                        fontSize: 16,
                        fontWeight: FontWeight.w600)),
                Text(
                  state.isPro
                      ? 'Pro · ${state.proModel!.label}'
                      : 'Standard · auto-routed',
                  style: TextStyle(color: c.textDim, fontSize: 11),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Balance',
            icon: Icon(Icons.account_balance_wallet_outlined, color: c.text),
            onPressed: () => _showBalance(context),
          ),
          IconButton(
            tooltip: 'Connect git repo',
            icon: Icon(Icons.source_outlined,
                color: state.git != null ? c.primary : c.text),
            onPressed: () => _showGitConnect(context),
          ),
        ],
      ),
      body: Column(
        children: [
          _TierSwitch(
            isPro: state.isPro,
            proLabel: state.proModel?.label,
            colors: c,
            onTapStandard: () =>
                ref.read(botChatControllerProvider.notifier).setModelDirect(null),
            onTapPro: () => _showModelPicker(context),
          ),
          Expanded(child: _buildMessageList(c, state)),
          _Composer(
            controller: _input,
            colors: c,
            sending: state.sending,
            onSubmit: _handleSubmit,
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList(NymColors c, BotChatState state) {
    if (state.messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Private, end-to-end encrypted chat with Nymbot.\n'
            'Standard replies are auto-routed (10 sats each); switch to Pro to '
            'pin a frontier model.\n\nType ?help for the guide.',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.textDim, fontSize: 13, height: 1.5),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      itemCount: state.messages.length,
      itemBuilder: (_, i) => _MessageBubble(
        message: state.messages[i],
        colors: c,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Submit / command interception (mirrors the PWA: `?` commands typed inside
  // the bot PM are handled as control commands).
  // ---------------------------------------------------------------------------

  void _handleSubmit() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final ctrl = ref.read(botChatControllerProvider.notifier);

    if (text.startsWith('?')) {
      final lower = text.toLowerCase();
      if (lower == '?balance') {
        _input.clear();
        _showBalance(context);
        return;
      }
      if (lower == '?buy') {
        _input.clear();
        _showBuy(context);
        return;
      }
      if (lower.startsWith('?model')) {
        final arg = text.substring(6).trim();
        _input.clear();
        if (arg.isEmpty) {
          _showModelPicker(context);
        } else {
          ctrl.setModel(arg);
        }
        return;
      }
      if (lower.startsWith('?git')) {
        _input.clear();
        // `?git writes on/off` toggles writes when already connected.
        final state = ref.read(botChatControllerProvider);
        if (lower.contains('writes') && state.git != null) {
          final on = lower.contains('on');
          ctrl.connectGit(state.git!.copyWith(allowWrites: on));
        } else {
          _showGitConnect(context);
        }
        return;
      }
    }

    _input.clear();
    ctrl.send(text);
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Modals
  // ---------------------------------------------------------------------------

  void _showBalance(BuildContext context) {
    final c = _colors(context);
    final b = ref.read(botChatControllerProvider).balance;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.bgSecondary,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Credit balance',
                style: TextStyle(
                    color: c.textBright,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            _balanceRow('Standard', b.balance, '10 sats each', c),
            const SizedBox(height: 8),
            _balanceRow('Pro', b.proBalance, '100 sats each', c,
                accent: c.primary),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  Navigator.pop(context);
                  _showBuy(context);
                },
                child: const Text('Buy credits'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _balanceRow(String label, int value, String hint, NymColors c,
      {Color? accent}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.bgTertiary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
                color: accent ?? c.blue, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        color: c.textBright, fontWeight: FontWeight.w600)),
                Text(hint, style: TextStyle(color: c.textDim, fontSize: 11)),
              ],
            ),
          ),
          Text('$value',
              style: TextStyle(
                  color: c.textBright,
                  fontSize: 20,
                  fontWeight: FontWeight.w700)),
          const SizedBox(width: 4),
          Text('cr', style: TextStyle(color: c.textDim, fontSize: 11)),
        ],
      ),
    );
  }

  void _showBuy(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _colors(context).bgSecondary,
      builder: (_) => _BuyModal(colors: _colors(context)),
    );
  }

  void _showModelPicker(BuildContext context) {
    final c = _colors(context);
    final current = ref.read(botChatControllerProvider).proModel;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.bgSecondary,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Text('Pro model',
                      style: TextStyle(
                          color: c.textBright,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Text('100 sats / credit',
                      style: TextStyle(color: c.textDim, fontSize: 11)),
                ],
              ),
            ),
            ListTile(
              leading: Icon(Icons.auto_awesome, color: c.blue),
              title: Text('Standard (auto-routed)',
                  style: TextStyle(color: c.text)),
              subtitle: Text('Best model per task · 10 sats each',
                  style: TextStyle(color: c.textDim, fontSize: 11)),
              trailing: current == null
                  ? Icon(Icons.check, color: c.primary)
                  : null,
              onTap: () {
                ref.read(botChatControllerProvider.notifier).setModelDirect(null);
                Navigator.pop(context);
              },
            ),
            Divider(height: 1, color: c.border),
            for (final m in kProModels)
              ListTile(
                leading: Icon(Icons.bolt, color: c.primary),
                title: Text(m.label, style: TextStyle(color: c.text)),
                subtitle: Text(
                    '${m.modelId} · base ${m.baseCredits} cr',
                    style: TextStyle(color: c.textDim, fontSize: 11)),
                trailing: current?.key == m.key
                    ? Icon(Icons.check, color: c.primary)
                    : null,
                onTap: () {
                  ref
                      .read(botChatControllerProvider.notifier)
                      .setModelDirect(m);
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showGitConnect(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _colors(context).bgSecondary,
      builder: (_) => _GitConnectModal(
        colors: _colors(context),
        existing: ref.read(botChatControllerProvider).git,
        onConnect: (cfg) =>
            ref.read(botChatControllerProvider.notifier).connectGit(cfg),
        onDisconnect: () =>
            ref.read(botChatControllerProvider.notifier).disconnectGit(),
      ),
    );
  }
}

// =============================================================================
// Tier switch (Standard / Pro)
// =============================================================================

class _TierSwitch extends StatelessWidget {
  const _TierSwitch({
    required this.isPro,
    required this.proLabel,
    required this.colors,
    required this.onTapStandard,
    required this.onTapPro,
  });

  final bool isPro;
  final String? proLabel;
  final NymColors colors;
  final VoidCallback onTapStandard;
  final VoidCallback onTapPro;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.bgTertiary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          _segment('Standard', !isPro, onTapStandard, c, c.blue),
          _segment(
            isPro && proLabel != null ? 'Pro · $proLabel' : 'Pro',
            isPro,
            onTapPro,
            c,
            c.primary,
          ),
        ],
      ),
    );
  }

  Widget _segment(
      String label, bool active, VoidCallback onTap, NymColors c, Color accent) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: active ? accent.withValues(alpha: 0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
                color: active ? accent : Colors.transparent, width: 1),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: active ? c.textBright : c.textDim,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// Message bubble + collapsed reasoning
// =============================================================================

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.message, required this.colors});

  final BotChatMessage message;
  final NymColors colors;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    final fromUser = message.fromUser;
    final bubbleColor = fromUser ? c.primary.withValues(alpha: 0.16) : c.bgSecondary;

    return Align(
      alignment: fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        child: Column(
          crossAxisAlignment:
              fromUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!fromUser && message.hasReasoning)
              _ReasoningSection(reasoning: message.reasoning!, colors: c),
            Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: message.error
                    ? c.danger.withValues(alpha: 0.14)
                    : bubbleColor,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                    color: message.error ? c.danger : c.border),
              ),
              child: message.pending
                  ? _TypingDots(color: c.textDim)
                  : Text(
                      message.text,
                      style: TextStyle(
                        color: message.error ? c.danger : c.text,
                        fontSize: 14,
                        height: 1.4,
                      ),
                    ),
            ),
            if (!fromUser && (message.taskType != null || message.cost != null))
              Padding(
                padding: const EdgeInsets.only(bottom: 6, left: 4),
                child: Text(
                  [
                    if (message.proModel != null) message.proModel,
                    if (message.taskType != null) message.taskType,
                    if (message.cost != null) '${message.cost} cr',
                  ].join(' · '),
                  style: TextStyle(color: c.textDim, fontSize: 10),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The collapsed "💭 Reasoning" section. Tap to expand/collapse.
class _ReasoningSection extends StatefulWidget {
  const _ReasoningSection({required this.reasoning, required this.colors});

  final String reasoning;
  final NymColors colors;

  @override
  State<_ReasoningSection> createState() => _ReasoningSectionState();
}

class _ReasoningSectionState extends State<_ReasoningSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 2),
      decoration: BoxDecoration(
        color: c.bgTertiary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('💭', style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 6),
                  Text('Reasoning',
                      style: TextStyle(
                          color: c.textDim,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: c.textDim,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Text(
                widget.reasoning,
                style: TextStyle(
                    color: c.textDim,
                    fontSize: 12,
                    height: 1.4,
                    fontStyle: FontStyle.italic),
              ),
            ),
        ],
      ),
    );
  }
}

class _TypingDots extends StatelessWidget {
  const _TypingDots({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: color),
        ),
        const SizedBox(width: 8),
        Text('Nymbot is thinking…',
            style: TextStyle(color: color, fontSize: 13)),
      ],
    );
  }
}

// =============================================================================
// Composer
// =============================================================================

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.colors,
    required this.sending,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final NymColors colors;
  final bool sending;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: c.bgSecondary,
          border: Border(top: BorderSide(color: c.border)),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                style: TextStyle(color: c.text, fontSize: 14),
                onSubmitted: (_) => onSubmit(),
                textInputAction: TextInputAction.send,
                decoration: InputDecoration(
                  hintText: 'Message Nymbot…  (try ?help)',
                  hintStyle: TextStyle(color: c.textDim),
                  filled: true,
                  fillColor: c.bgTertiary,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide(color: c.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide(color: c.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide(color: c.primary),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: sending ? null : onSubmit,
              icon: const Icon(Icons.send, size: 18),
              style: IconButton.styleFrom(backgroundColor: c.primary),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Buy modal (Standard / Pro switch + invoice QR placeholder)
// =============================================================================

class _BuyModal extends ConsumerStatefulWidget {
  const _BuyModal({required this.colors});
  final NymColors colors;

  @override
  ConsumerState<_BuyModal> createState() => _BuyModalState();
}

class _BuyModalState extends ConsumerState<_BuyModal> {
  CreditTier _tier = CreditTier.standard;
  int _amountSats = 1000;
  BotInvoice? _invoice;
  bool _loading = false;

  static const _presets = [1000, 5000, 10000, 25000];

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Buy credits',
              style: TextStyle(
                  color: c.textBright,
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 14),
          // Standard / Pro switch.
          _TierSwitch(
            isPro: _tier == CreditTier.pro,
            proLabel: null,
            colors: c,
            onTapStandard: () => setState(() {
              _tier = CreditTier.standard;
              _invoice = null;
            }),
            onTapPro: () => setState(() {
              _tier = CreditTier.pro;
              _invoice = null;
            }),
          ),
          const SizedBox(height: 6),
          Text(
            _tier == CreditTier.pro
                ? 'Pro credits · 100 sats each'
                : 'Standard credits · 10 sats each',
            style: TextStyle(color: c.textDim, fontSize: 12),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in _presets)
                ChoiceChip(
                  label: Text('$p sats'),
                  selected: _amountSats == p,
                  onSelected: (_) => setState(() {
                    _amountSats = p;
                    _invoice = null;
                  }),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '≈ ${(_amountSats / _tier.satsPerCredit).floor()} '
            '${_tier == CreditTier.pro ? "Pro" : "standard"} credits',
            style: TextStyle(color: c.textDim, fontSize: 12),
          ),
          const SizedBox(height: 16),
          if (_invoice != null) ...[
            _InvoiceView(invoice: _invoice!, colors: c),
          ] else
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _loading ? null : _createInvoice,
                icon: _loading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.bolt),
                label: Text(_loading ? 'Creating invoice…' : 'Pay with Lightning'),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _createInvoice() async {
    setState(() => _loading = true);
    // TODO(verify): wire to NymbotService.buy via the controller once the
    // identity/auth blob is bound. For now this builds the invoice through the
    // controller, which no-ops (returns null) when unbound — the UI then shows a
    // placeholder so the flow is reviewable without a live backend.
    BotInvoice? inv;
    try {
      inv = await ref
          .read(botChatControllerProvider.notifier)
          .buy(_amountSats, _tier);
    } catch (_) {
      inv = null;
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _invoice = inv ??
          BotInvoice(
            // TODO(verify): placeholder invoice — replace with the real `pr`.
            pr: 'lnbc${_amountSats}n1p...stub-invoice-bind-identity-to-buy',
            invoiceId: 'stub',
            tier: _tier,
            amountSats: _amountSats,
          );
    });
  }
}

class _InvoiceView extends StatelessWidget {
  const _InvoiceView({required this.invoice, required this.colors});
  final BotInvoice invoice;
  final NymColors colors;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Column(
      children: [
        // QR placeholder. TODO(verify): render a real QR for `invoice.pr` once a
        // qr widget/dep is available in the shell.
        Container(
          width: 200,
          height: 200,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.border),
          ),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.qr_code_2, size: 96, color: Colors.black87),
              const SizedBox(height: 4),
              const Text('Lightning invoice',
                  style: TextStyle(color: Colors.black54, fontSize: 11)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SelectableText(
          invoice.pr,
          maxLines: 2,
          style: TextStyle(
              color: c.textDim, fontSize: 11, fontFamily: 'monospace'),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Clipboard.setData(
                    ClipboardData(text: invoice.pr)),
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                // TODO(verify): open the device wallet via lightning: URI.
                onPressed: () {},
                icon: const Icon(Icons.account_balance_wallet, size: 16),
                label: const Text('Open wallet'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text('Waiting for payment…',
            style: TextStyle(color: c.textDim, fontSize: 11)),
      ],
    );
  }
}

// =============================================================================
// Git connect modal (provider + PAT + repo/branch)
// =============================================================================

class _GitConnectModal extends StatefulWidget {
  const _GitConnectModal({
    required this.colors,
    required this.existing,
    required this.onConnect,
    required this.onDisconnect,
  });

  final NymColors colors;
  final GitConfig? existing;
  final ValueChanged<GitConfig> onConnect;
  final VoidCallback onDisconnect;

  @override
  State<_GitConnectModal> createState() => _GitConnectModalState();
}

class _GitConnectModalState extends State<_GitConnectModal> {
  late GitProvider _provider;
  late final TextEditingController _host;
  late final TextEditingController _token;
  late final TextEditingController _repo;
  late final TextEditingController _branch;
  late bool _allowWrites;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _provider = e?.provider ?? GitProvider.github;
    _host = TextEditingController(text: e?.host ?? _provider.defaultHost);
    _token = TextEditingController(text: e?.token ?? '');
    _repo = TextEditingController(text: e?.repo ?? '');
    _branch = TextEditingController(text: e?.branch ?? '');
    _allowWrites = e?.allowWrites ?? false;
  }

  @override
  void dispose() {
    _host.dispose();
    _token.dispose();
    _repo.dispose();
    _branch.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Connect a git repo',
                style: TextStyle(
                    color: c.textBright,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              'Pro replies can read your code and, with writes on, commit, '
              'branch, and open PRs. Your access token is stored only on this '
              'device (Panic Mode wipes it) and sent per request — never stored '
              'server-side.',
              style: TextStyle(color: c.textDim, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 16),
            // Provider selector.
            Wrap(
              spacing: 8,
              children: [
                for (final p in GitProvider.values)
                  ChoiceChip(
                    label: Text(p.label),
                    selected: _provider == p,
                    onSelected: (_) => setState(() {
                      _provider = p;
                      _host.text = p.defaultHost;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            _field(_host, 'Host', 'github.com', c),
            const SizedBox(height: 10),
            _field(_token, 'Personal access token (PAT)', 'ghp_… / glpat-… ',
                c, obscure: true),
            const SizedBox(height: 10),
            _field(_repo, 'Repository', 'owner/repo', c),
            const SizedBox(height: 10),
            _field(_branch, 'Branch (optional)', 'main', c),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _allowWrites,
              activeThumbColor: c.primary,
              title: Text('Allow writes',
                  style: TextStyle(color: c.text, fontSize: 14)),
              subtitle: Text('commit, create branches, open pull/merge requests',
                  style: TextStyle(color: c.textDim, fontSize: 11)),
              onChanged: (v) => setState(() => _allowWrites = v),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (widget.existing != null)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        widget.onDisconnect();
                        Navigator.pop(context);
                      },
                      child: const Text('Disconnect'),
                    ),
                  ),
                if (widget.existing != null) const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: _canConnect ? _connect : null,
                    child: const Text('Connect'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  bool get _canConnect =>
      _token.text.trim().isNotEmpty && _repo.text.trim().isNotEmpty;

  void _connect() {
    widget.onConnect(GitConfig(
      provider: _provider,
      host: _host.text.trim().isEmpty ? _provider.defaultHost : _host.text.trim(),
      token: _token.text.trim(),
      repo: _repo.text.trim(),
      branch: _branch.text.trim().isEmpty ? null : _branch.text.trim(),
      allowWrites: _allowWrites,
    ));
    Navigator.pop(context);
  }

  Widget _field(TextEditingController ctrl, String label, String hint,
      NymColors c,
      {bool obscure = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: c.textDim, fontSize: 12)),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          obscureText: obscure,
          style: TextStyle(color: c.text, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
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
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Fallback theme colours (used only when NymColors isn't registered, e.g. in a
// bare widget test). The real app supplies NymColors via the theme extension.
// =============================================================================

const NymColors _fallbackColors = NymColors(
  primary: Color(0xFF7C5CFF),
  secondary: Color(0xFF4DA3FF),
  warning: Color(0xFFE0A800),
  danger: Color(0xFFE5484D),
  purple: Color(0xFF7C5CFF),
  blue: Color(0xFF4DA3FF),
  lightning: Color(0xFFF7931A),
  bg: Color(0xFF0E0E12),
  bgSecondary: Color(0xFF16161C),
  bgTertiary: Color(0xFF1E1E26),
  text: Color(0xFFE6E6EA),
  textDim: Color(0xFF9A9AA6),
  textBright: Color(0xFFFFFFFF),
  border: Color(0xFF2A2A33),
  glassBg: Color(0x22FFFFFF),
  glassBorder: Color(0x33FFFFFF),
  brightness: Brightness.dark,
);
