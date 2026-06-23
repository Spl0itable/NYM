/// Riverpod wiring for the Nymbot feature: the [NymbotService] singleton, the
/// private-chat state, and the `?`/`@Nymbot` interception helpers.
///
/// These providers are self-contained — the parent app wires them into the
/// composer via the [isBotCommand] / [isNymbotMention] interceptors and opens
/// `BotChatScreen` for the private bot PM.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'bot_commands.dart';
import 'nymbot_models.dart';
import 'nymbot_service.dart';

// =============================================================================
// Interception helpers (pure — safe to call from the composer hot path)
// =============================================================================

/// True when [text] is a Nymbot public command, i.e. begins with `?` followed
/// by a non-space character. (`?` alone, or `? foo`, is not a command.)
///
/// Matches the worker/PWA rule: a leading `?` then a command token.
bool isBotCommand(String text) {
  final t = text.trimLeft();
  return t.length >= 2 && t[0] == '?' && !_isSpace(t[1]);
}

/// True when [text] mentions `@Nymbot` (case-insensitive), which routes the
/// message to `?ask` (README line 179: also triggered via an `@Nymbot`
/// mention followed by the question). The mention may appear anywhere.
bool isNymbotMention(String text) =>
    _nymbotMention.hasMatch(text);

/// `@Nymbot` as a word (not part of a longer handle like `@Nymbotz`).
final RegExp _nymbotMention =
    RegExp(r'(^|[^A-Za-z0-9_])@Nymbot\b', caseSensitive: false);

/// Strips a leading `@Nymbot` mention and returns the remaining question text,
/// for turning `@Nymbot what is nostr` into the `?ask` args `what is nostr`.
String stripNymbotMention(String text) =>
    text.replaceFirst(_nymbotMention, '').trim();

bool _isSpace(String ch) => ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r';

// =============================================================================
// Service provider
// =============================================================================

/// The lazy Nymbot HTTP service. No network until a method is called.
final nymbotServiceProvider = Provider<NymbotService>((ref) {
  final service = NymbotService();
  ref.onDispose(service.dispose);
  return service;
});

// =============================================================================
// Private bot-chat state
// =============================================================================

/// One message in the private Nymbot chat.
class BotChatMessage {
  const BotChatMessage({
    required this.id,
    required this.text,
    required this.fromUser,
    required this.timestamp,
    this.reasoning,
    this.pending = false,
    this.error = false,
    this.taskType,
    this.proModel,
    this.cost,
  });

  final String id;
  final String text;
  final bool fromUser; // true = sent by the local user, false = Nymbot.
  final DateTime timestamp;

  /// Collapsed "💭 Reasoning" content for bot replies, when present.
  final String? reasoning;

  final bool pending; // awaiting reply / in-flight.
  final bool error;
  final String? taskType;
  final String? proModel;
  final int? cost;

  bool get hasReasoning =>
      reasoning != null && reasoning!.trim().isNotEmpty;

  BotChatMessage copyWith({
    String? text,
    String? reasoning,
    bool? pending,
    bool? error,
    String? taskType,
    String? proModel,
    int? cost,
  }) =>
      BotChatMessage(
        id: id,
        text: text ?? this.text,
        fromUser: fromUser,
        timestamp: timestamp,
        reasoning: reasoning ?? this.reasoning,
        pending: pending ?? this.pending,
        error: error ?? this.error,
        taskType: taskType ?? this.taskType,
        proModel: proModel ?? this.proModel,
        cost: cost ?? this.cost,
      );
}

/// Immutable snapshot of the private Nymbot chat.
class BotChatState {
  const BotChatState({
    this.messages = const [],
    this.proModel,
    this.git,
    this.balance = BotBalance.empty,
    this.sending = false,
  });

  final List<BotChatMessage> messages;

  /// The pinned Pro model (`?model <name>`), or null for standard routing.
  final ProModel? proModel;

  /// Connected git repo config (`?git`), or null when not connected.
  final GitConfig? git;

  final BotBalance balance;
  final bool sending;

  bool get isPro => proModel != null;

  BotChatState copyWith({
    List<BotChatMessage>? messages,
    Object? proModel = _sentinel,
    Object? git = _sentinel,
    BotBalance? balance,
    bool? sending,
  }) =>
      BotChatState(
        messages: messages ?? this.messages,
        proModel:
            identical(proModel, _sentinel) ? this.proModel : proModel as ProModel?,
        git: identical(git, _sentinel) ? this.git : git as GitConfig?,
        balance: balance ?? this.balance,
        sending: sending ?? this.sending,
      );

  static const _sentinel = Object();
}

/// Controller for the private Nymbot chat. Holds the message list, the pinned
/// Pro model, the git config (PAT on-device only), and the credit balance.
///
/// The actual `pubkey`/`auth` blob comes from the parent identity layer — the
/// app sets it via [bind] before sending. Until bound, sends are refused so this
/// stays decoupled from shared identity state.
class BotChatController extends StateNotifier<BotChatState> {
  BotChatController(this._service) : super(const BotChatState());

  final NymbotService _service;

  String? _pubkey;
  Map<String, dynamic>? _auth;

  /// Wires in the user's identity for paid requests. Called by the parent app.
  void bind({required String pubkey, Map<String, dynamic>? auth}) {
    _pubkey = pubkey;
    _auth = auth;
  }

  bool get isBound => _pubkey != null;

  // --- Local controls --------------------------------------------------------

  /// Applies `?model <name|off>`. `off` (or unknown) clears the pin.
  void setModel(String arg) {
    if (arg.trim().toLowerCase() == 'off') {
      state = state.copyWith(proModel: null);
      return;
    }
    state = state.copyWith(proModel: lookupProModel(arg));
  }

  void setModelDirect(ProModel? model) =>
      state = state.copyWith(proModel: model);

  /// Connects a git repo. The PAT lives only in [GitConfig.token] here — wiped
  /// by [wipeOnPanic].
  void connectGit(GitConfig config) => state = state.copyWith(git: config);

  void disconnectGit() => state = state.copyWith(git: null);

  /// Panic Mode hook: wipe the on-device PAT + git config.
  void wipeOnPanic() => state = state.copyWith(git: null);

  void setBalance(BotBalance b) => state = state.copyWith(balance: b);

  // --- Network ---------------------------------------------------------------

  /// Sends a private chat message and appends the reply (with reasoning split
  /// out). Returns the reply, or null if not bound / on error (the error is also
  /// reflected as a failed message in [state]).
  Future<BotReply?> send(String text, {String? eventId, bool fresh = false}) async {
    if (_pubkey == null || text.trim().isEmpty) return null;

    final now = DateTime.now();
    final userMsg = BotChatMessage(
      id: 'u_${now.microsecondsSinceEpoch}',
      text: text,
      fromUser: true,
      timestamp: now,
    );
    final pendingId = 'b_${now.microsecondsSinceEpoch}';
    final pendingMsg = BotChatMessage(
      id: pendingId,
      text: '',
      fromUser: false,
      timestamp: now,
      pending: true,
      proModel: state.proModel?.key,
    );
    state = state.copyWith(
      messages: [...state.messages, userMsg, pendingMsg],
      sending: true,
    );

    try {
      final reply = await _service.sendBotMessage(
        text,
        pubkey: _pubkey!,
        auth: _auth,
        eventId: eventId,
        proModel: state.proModel?.key,
        fresh: fresh,
        git: state.git,
      );
      _replacePending(
        pendingId,
        (m) => m.copyWith(
          text: reply.text,
          reasoning: reply.reasoning,
          pending: false,
          taskType: reply.taskType,
          cost: reply.cost,
        ),
      );
      if (reply.balance != null) {
        // Reflect the post-charge balance on whichever ledger was used.
        final b = state.balance;
        state = state.copyWith(
          balance: reply.pro
              ? BotBalance(
                  balance: b.balance,
                  totalPurchased: b.totalPurchased,
                  totalUsed: b.totalUsed,
                  proBalance: reply.balance!,
                  proTotalPurchased: b.proTotalPurchased,
                  proTotalUsed: b.proTotalUsed,
                )
              : BotBalance(
                  balance: reply.balance!,
                  totalPurchased: b.totalPurchased,
                  totalUsed: b.totalUsed,
                  proBalance: b.proBalance,
                  proTotalPurchased: b.proTotalPurchased,
                  proTotalUsed: b.proTotalUsed,
                ),
        );
      }
      state = state.copyWith(sending: false);
      return reply;
    } on NymbotInsufficientCredits catch (e) {
      _replacePending(
        pendingId,
        (m) => m.copyWith(
          text: e.message,
          pending: false,
          error: true,
        ),
      );
      state = state.copyWith(sending: false);
      return null;
    } catch (_) {
      _replacePending(
        pendingId,
        (m) => m.copyWith(
          text: 'Failed to reach Nymbot. Tap to retry.',
          pending: false,
          error: true,
        ),
      );
      state = state.copyWith(sending: false);
      return null;
    }
  }

  /// Refreshes the credit balance from the worker.
  Future<void> refreshBalance() async {
    if (_pubkey == null) return;
    try {
      final b = await _service.balance(pubkey: _pubkey!, auth: _auth);
      state = state.copyWith(balance: b);
    } catch (_) {
      // Lazy/best-effort; leave existing balance in place.
    }
  }

  /// Creates a buy invoice (Standard/Pro). Returns null if not bound.
  Future<BotInvoice?> buy(int amountSats, CreditTier tier) async {
    if (_pubkey == null) return null;
    return _service.buy(
      amountSats: amountSats,
      tier: tier,
      pubkey: _pubkey!,
      auth: _auth,
    );
  }

  void _replacePending(
    String id,
    BotChatMessage Function(BotChatMessage) update,
  ) {
    state = state.copyWith(
      messages: [
        for (final m in state.messages) m.id == id ? update(m) : m,
      ],
    );
  }
}

/// The private Nymbot chat controller.
final botChatControllerProvider =
    StateNotifierProvider<BotChatController, BotChatState>((ref) {
  return BotChatController(ref.watch(nymbotServiceProvider));
});

/// Convenience: the catalogue of public `?` commands (for help/autocomplete UI).
final botCommandsProvider = Provider<List<BotCommand>>((_) => kBotCommands);

/// Convenience: the Pro model list (for the `?model` picker).
final proModelsProvider = Provider<List<ProModel>>((_) => kProModels);
