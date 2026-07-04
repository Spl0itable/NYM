/// Data models for the Nymbot client surface.
///
/// Field names mirror the `functions/api/bot.js` worker response shapes and the
/// client contract in `docs/specs/04-features.md` §11.2-11.5.
library;

/// The Pro frontier models selectable with `?model <name>`.
///
/// Exact list + ids verified against `functions/api/bot.js` `BOT_PRO_MODELS`
/// (and README line 170 / spec §11.3). [key] is the value sent as `proModel`;
/// [label] is the README's display name; [baseCredits] is the per-call base
/// Pro-credit cost (1, except Fable = 2).
class ProModel {
  const ProModel({
    required this.key,
    required this.label,
    required this.modelId,
    required this.baseCredits,
    this.max,
  });

  /// Value passed to the worker as `proModel`, e.g. `claude-opus`.
  final String key;

  /// README display label, e.g. `Claude Opus 4.8`.
  final String label;

  /// Internal provider/model id, e.g. `anthropic/claude-opus-4.8`.
  final String modelId;

  /// Base Pro credits charged per model call (before length scaling).
  final int baseCredits;

  /// Max Pro credits a single (max-length) reply can scale to (PWA
  /// `_botProModels[].max`, pms.js:2085-2091). Null/<= [baseCredits] means the
  /// model is flat-priced. Optional so existing call sites are unaffected.
  final int? max;

  /// The PWA's `_botProPriceLabel` (pms.js:2096-2098): `"<n> Pro credit(s)/reply"`
  /// for flat models, else `"from <base>, up to <max> for max-length replies"`.
  String get priceLabel {
    final base = '$baseCredits Pro credit${baseCredits == 1 ? '' : 's'}';
    final m = max;
    return (m != null && m > baseCredits)
        ? 'from $base, up to $m for max-length replies'
        : '$base/reply';
  }
}

/// The 7 Pro models, in README order (line 170):
/// Claude Fable 5, Claude Opus 4.8, Claude Sonnet 4.6, Claude Haiku 4.5,
/// GPT-5.1, GPT-5 mini, GPT-5.1 Codex.
const List<ProModel> kProModels = [
  ProModel(
    key: 'claude-fable',
    label: 'Claude Fable 5',
    modelId: 'anthropic/claude-fable-5',
    baseCredits: 2,
    max: 16,
  ),
  ProModel(
    key: 'claude-opus',
    label: 'Claude Opus 4.8',
    modelId: 'anthropic/claude-opus-4.8',
    baseCredits: 1,
    max: 8,
  ),
  ProModel(
    key: 'claude-sonnet',
    label: 'Claude Sonnet 4.6',
    modelId: 'anthropic/claude-sonnet-4.6',
    baseCredits: 1,
    max: 6,
  ),
  ProModel(
    key: 'claude-haiku',
    label: 'Claude Haiku 4.5',
    modelId: 'anthropic/claude-haiku-4.5',
    baseCredits: 1,
    max: 1,
  ),
  ProModel(
    key: 'gpt-5',
    label: 'GPT-5.1',
    modelId: 'openai/gpt-5.1',
    baseCredits: 1,
    max: 4,
  ),
  ProModel(
    key: 'gpt-5-mini',
    label: 'GPT-5 mini',
    modelId: 'openai/gpt-5-mini',
    baseCredits: 1,
    max: 1,
  ),
  ProModel(
    key: 'codex',
    label: 'GPT-5.1 Codex',
    modelId: 'openai/gpt-5.1-codex',
    baseCredits: 1,
    max: 4,
  ),
];

/// A single PM-only Nymbot command, surfaced by the `?…` suggestion palette
/// inside the private bot chat (PWA `botPMCommands`, commands.js:272-281).
class BotPMCommand {
  const BotPMCommand({required this.name, required this.desc});

  /// The command including its leading `?`, e.g. `?model`.
  final String name;

  /// One-line description shown beneath the command name.
  final String desc;
}

/// The 8 PM-only commands the PWA shows in the Nymbot private chat, in order
/// (commands.js `botPMCommands`). NOTE: this is the *PM* set — distinct from the
/// public-channel `?` commands (`kBotCommands`), which are not wired here.
const List<BotPMCommand> kBotPMCommands = [
  BotPMCommand(
    name: '?help',
    desc: 'Guide to premium, Pro models & git repos (free)',
  ),
  BotPMCommand(
    name: '?model',
    desc: 'Pick a Pro frontier model (?model off for standard)',
  ),
  BotPMCommand(
    name: '?git',
    desc: 'Connect a git repo to Pro replies (GitHub/GitLab/Gitea)',
  ),
  BotPMCommand(
    name: '?buy',
    desc: 'Buy Nymbot credits (Standard/Pro switch)',
  ),
  BotPMCommand(
    name: '?balance',
    desc: 'Check your standard & Pro credit balances',
  ),
  BotPMCommand(
    name: '?gift',
    desc: 'Gift Nymbot credits to another user',
  ),
  BotPMCommand(
    name: '?transfer',
    desc: 'Transfer ALL your Nymbot credits to another pubkey',
  ),
  BotPMCommand(
    name: '?clear',
    desc: 'Clear Nymbot chat history and start fresh',
  ),
];

/// Deeper completions surfaced after `?model ` / `?git ` (commands.js
/// `_botPMSubcommands`, :397-434). Returns the rows to show for a base command
/// once a trailing space has been typed, with each row's full insertion text.
/// [rest] is the already-typed text after the base command — it selects the
/// third-level `?git provider <partial>` completions (commands.js:408-416).
/// Returns null when [cmd] has no subcommands.
List<BotPMCommand>? botPMSubcommands(String cmd, [String rest = '']) {
  if (cmd == '?model') {
    return [
      for (final m in kProModels)
        BotPMCommand(name: '?model ${m.key}', desc: '${m.label} — ${m.priceLabel}'),
      const BotPMCommand(
          name: '?model off', desc: 'Back to standard multi-model routing'),
    ];
  }
  if (cmd == '?git') {
    // Third level: `?git provider <partial>` → the provider rows
    // (commands.js:409-416 — `${p.label} — default host ${p.host}; append a
    // custom host for self-hosted`).
    if (RegExp(r'^provider\s+').hasMatch(rest)) {
      return [
        for (final p in GitProvider.values)
          BotPMCommand(
            name: '?git provider ${p.wire}',
            desc:
                '${p.label} — default host ${p.defaultHost}; append a custom host for self-hosted',
          ),
      ];
    }
    return const [
      BotPMCommand(
          name: '?git provider', desc: 'Choose github, gitlab, or gitea [host]'),
      BotPMCommand(name: '?git token', desc: 'Save your personal access token'),
      BotPMCommand(name: '?git repos', desc: 'List repos the token can access'),
      BotPMCommand(
          name: '?git repo', desc: 'Select working repo (owner/name [branch])'),
      BotPMCommand(name: '?git branch', desc: 'Set the working branch'),
      BotPMCommand(
          name: '?git writes on', desc: 'Allow commits, branches & pull requests'),
      BotPMCommand(
          name: '?git writes off', desc: 'Back to read-only repo access'),
      BotPMCommand(name: '?git off', desc: 'Disconnect the repo (keeps the token)'),
      BotPMCommand(
          name: '?git disconnect', desc: 'Remove token and repo from this device'),
    ];
  }
  return null;
}

/// Filters [kBotPMCommands] (and subcommands) for the `?…` palette given the
/// current input. Mirrors `showBotCommandPalette` (commands.js:436-468):
///  * a bare prefix (`?mo`) filters the 8 base commands by `startsWith`;
///  * a base command plus a space (`?git `) surfaces its subcommands filtered
///    by the remaining text.
List<BotPMCommand> filterBotPMCommands(String input) {
  // Preserve a trailing space (it's meaningful: `?git ` → show subcommands),
  // but ignore leading whitespace.
  final needle = input.trimLeft().toLowerCase();
  if (needle.isEmpty || !needle.startsWith('?')) return const [];

  // Base-command prefix match (no space typed yet).
  if (!needle.contains(' ')) {
    return [
      for (final c in kBotPMCommands)
        if (c.name.startsWith(needle)) c,
    ];
  }

  // `?<cmd> <rest>` → subcommands of <cmd> filtered by <rest> (empty `rest`,
  // i.e. just-typed trailing space, lists them all). `?git provider <partial>`
  // drills into the third-level provider rows (commands.js `_botPMSubcommands`
  // provider branch, :408-416).
  final sp = needle.indexOf(' ');
  final base = needle.substring(0, sp);
  final rest = needle.substring(sp + 1).trimLeft();
  final subs = botPMSubcommands(base, rest);
  if (subs == null) return const [];
  return [
    for (final s in subs)
      if (s.name.toLowerCase().substring(base.length).trimLeft().startsWith(rest))
        s,
  ];
}

/// Looks up a Pro model by its `?model` argument. Accepts the canonical [key]
/// as well as a loose match on the label (case-insensitive). Returns null for
/// unknown names or the literal `off`.
ProModel? lookupProModel(String name) {
  final n = name.trim().toLowerCase();
  if (n.isEmpty || n == 'off') return null;
  for (final m in kProModels) {
    if (m.key == n) return m;
    if (m.label.toLowerCase() == n) return m;
  }
  // Loose contains match (e.g. "opus" -> Claude Opus 4.8).
  for (final m in kProModels) {
    if (m.label.toLowerCase().contains(n) || m.key.contains(n)) return m;
  }
  return null;
}

/// Result of splitting a bot reply into its visible text and optional
/// `<think>…</think>` reasoning (spec §11.5; worker `sanitizeBotResponse`).
class BotReply {
  const BotReply({
    required this.text,
    this.reasoning,
    this.taskType,
    this.modelCalls,
    this.outputTokens,
    this.cost,
    this.balance,
    this.pro = false,
    this.proModel,
    this.git = false,
    this.lowBalance = false,
  });

  /// The reply body with any reasoning block stripped out.
  final String text;

  /// The extracted reasoning (contents of `<think>…</think>`), or null.
  final String? reasoning;

  /// Auto-router classification, e.g. `coding`/`reasoning`/`creative`/
  /// `translation`/`general`/`pro` (worker `taskType`).
  final String? taskType;

  /// Number of model calls made (git agent loop can use up to 6).
  final int? modelCalls;

  /// Output tokens generated by the reply.
  final int? outputTokens;

  /// Credits charged for this reply.
  final int? cost;

  /// Remaining balance after the reply (tier depends on [pro]).
  final int? balance;

  /// True when answered by a pinned Pro model.
  final bool pro;

  /// The Pro model key used, when [pro].
  final String? proModel;

  /// True when the reply ran in git/repo mode.
  final bool git;

  /// Worker hint that the balance is now low.
  final bool lowBalance;

  bool get hasReasoning => reasoning != null && reasoning!.trim().isNotEmpty;

  /// Cap mirrors the worker's `BOT_THINKING_MAX_CHARS` (4000) — the client
  /// should not render more reasoning than the worker would send.
  static const int kReasoningMaxChars = 4000;
}

/// Standard + Pro credit balances (`action: balance`).
/// Field names verified against worker response (lines 1254-1260) and spec §11.5
/// `BotBalance`.
class BotBalance {
  const BotBalance({
    required this.balance,
    required this.totalPurchased,
    required this.totalUsed,
    required this.proBalance,
    required this.proTotalPurchased,
    required this.proTotalUsed,
  });

  final int balance; // standard credits available
  final int totalPurchased;
  final int totalUsed;
  final int proBalance; // Pro credits available
  final int proTotalPurchased;
  final int proTotalUsed;

  factory BotBalance.fromJson(Map<String, dynamic> j) => BotBalance(
        balance: _int(j['balance']),
        totalPurchased: _int(j['totalPurchased']),
        totalUsed: _int(j['totalUsed']),
        proBalance: _int(j['proBalance']),
        proTotalPurchased: _int(j['proTotalPurchased']),
        proTotalUsed: _int(j['proTotalUsed']),
      );

  static const empty = BotBalance(
    balance: 0,
    totalPurchased: 0,
    totalUsed: 0,
    proBalance: 0,
    proTotalPurchased: 0,
    proTotalUsed: 0,
  );
}

/// Credit tier for buys/balances.
enum CreditTier { standard, pro }

extension CreditTierWire on CreditTier {
  String get wire => this == CreditTier.pro ? 'pro' : 'standard';

  /// Sats per credit (README line 170): Standard = 10, Pro = 100.
  int get satsPerCredit => this == CreditTier.pro ? 100 : 10;
}

/// A Lightning invoice returned by `action: create-invoice`.
/// Fields verified against worker (lines 1347-1353) + spec §11.2.
class BotInvoice {
  const BotInvoice({
    required this.pr,
    required this.invoiceId,
    this.verify,
    this.serverVerify = false,
    this.needsReceipt = false,
    this.tier = CreditTier.standard,
    this.amountSats = 0,
  });

  /// BOLT11 invoice string (render as QR + copyable text).
  final String pr;

  /// SHA256 of [pr]; used to poll `check-invoice` / `claim-credits`.
  final String invoiceId;

  /// LUD-21 verify URL, when the wallet supports it.
  final String? verify;

  /// True when the server can verify the payment itself (NWC).
  final bool serverVerify;

  /// True when the client must supply a NIP-57 receipt to claim.
  final bool needsReceipt;

  final CreditTier tier;
  final int amountSats;

  factory BotInvoice.fromJson(
    Map<String, dynamic> j, {
    CreditTier tier = CreditTier.standard,
    int amountSats = 0,
  }) =>
      BotInvoice(
        pr: (j['pr'] ?? '').toString(),
        invoiceId: (j['invoiceId'] ?? '').toString(),
        verify: j['verify']?.toString(),
        serverVerify: j['serverVerify'] == true,
        needsReceipt: j['needsReceipt'] == true,
        tier: tier,
        amountSats: amountSats,
      );
}

/// Git provider for the `?git` connect flow (spec §11.4).
enum GitProvider { github, gitlab, gitea }

extension GitProviderWire on GitProvider {
  String get wire => switch (this) {
        GitProvider.github => 'github',
        GitProvider.gitlab => 'gitlab',
        GitProvider.gitea => 'gitea',
      };

  /// PWA `_gitProviders[key].label` (pms.js:2153-2157).
  String get label => switch (this) {
        GitProvider.github => 'GitHub',
        GitProvider.gitlab => 'GitLab',
        GitProvider.gitea => 'Gitea/Forgejo',
      };

  /// PWA `_gitProviders[key].tokenHint` — the parenthesised how-to that the
  /// `?git token` usage/system messages embed (pms.js:2153-2157).
  String get tokenHint => switch (this) {
        GitProvider.github =>
          'fine-grained personal access token (github.com → Settings → Developer settings)',
        GitProvider.gitlab =>
          'personal access token with api scope (GitLab → Preferences → Access tokens)',
        GitProvider.gitea => 'access token (Settings → Applications)',
      };

  /// Default API host for the provider (Gitea defaults to Codeberg).
  String get defaultHost => switch (this) {
        GitProvider.github => 'github.com',
        GitProvider.gitlab => 'gitlab.com',
        GitProvider.gitea => 'codeberg.org',
      };
}

/// On-device git connection config. The [token] (PAT) is stored client-side
/// only and wiped by Panic Mode — it is sent per request and never persisted
/// server-side (spec §11.4). Mirrors spec §11.5 `GitConfig` plus the PWA's
/// progressive `nym_botpm_git` blob (pms.js `_getGitConfig`): the staged
/// `?git provider` → `?git token` → `?git repo` flow builds it field by field,
/// so [token] / [repo] may still be empty.
class GitConfig {
  const GitConfig({
    required this.provider,
    required this.host,
    this.token = '',
    this.repo = '',
    this.branch,
    this.allowWrites = false,
    this.login,
  });

  final GitProvider provider;
  final String host;
  final String token; // PAT — on-device only ('' until `?git token`).
  final String repo; // owner/repo (or group/subgroup/repo on GitLab)
  final String? branch;
  final bool allowWrites; // toggled by `?git writes on`.

  /// Verified account login for the saved token (PWA `cfg.login`).
  final String? login;

  bool get hasToken => token.isNotEmpty;
  bool get hasRepo => hasToken && repo.isNotEmpty;

  Map<String, dynamic> toWire() => {
        'provider': provider.wire,
        'host': host,
        'token': token,
        'repo': repo,
        // Always present — empty string when unset, byte-parity with the PWA's
        // `branch: git.branch || ''` (pms.js:2464).
        'branch': branch ?? '',
        'allowWrites': allowWrites,
      };

  /// Prefs blob (the PWA's `nym_botpm_git` localStorage JSON).
  Map<String, dynamic> toJson() => {
        'provider': provider.wire,
        'host': host,
        if (token.isNotEmpty) 'token': token,
        if (repo.isNotEmpty) 'repo': repo,
        if (branch != null && branch!.isNotEmpty) 'branch': branch,
        'allowWrites': allowWrites,
        if (login != null && login!.isNotEmpty) 'login': login,
      };

  static GitConfig? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    final provider = GitProvider.values.firstWhere(
      (p) => p.wire == (j['provider'] ?? 'github'),
      orElse: () => GitProvider.github,
    );
    return GitConfig(
      provider: provider,
      host: (j['host'] ?? provider.defaultHost).toString(),
      token: (j['token'] ?? '').toString(),
      repo: (j['repo'] ?? '').toString(),
      branch: (j['branch'] as String?)?.isEmpty == true
          ? null
          : j['branch'] as String?,
      allowWrites: j['allowWrites'] == true,
      login: (j['login'] as String?)?.isEmpty == true
          ? null
          : j['login'] as String?,
    );
  }

  GitConfig copyWith({
    GitProvider? provider,
    String? host,
    String? token,
    String? repo,
    Object? branch = _sentinel,
    bool? allowWrites,
    Object? login = _sentinel,
  }) =>
      GitConfig(
        provider: provider ?? this.provider,
        host: host ?? this.host,
        token: token ?? this.token,
        repo: repo ?? this.repo,
        branch: identical(branch, _sentinel) ? this.branch : branch as String?,
        allowWrites: allowWrites ?? this.allowWrites,
        login: identical(login, _sentinel) ? this.login : login as String?,
      );

  static const Object _sentinel = Object();
}

int _int(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

/// Splits a raw model reply into visible text + `<think>…</think>` reasoning.
///
/// Mirrors the worker's `<think>` convention (`sanitizeBotResponse`, bot.js
/// lines 2397-2432): one or more `<think>…</think>` blocks are removed from the
/// body and concatenated (newline-separated) into [BotReply.reasoning]. The
/// match is case-insensitive and dot-all (spans newlines). Pure — no network.
BotReply splitReasoning(
  String raw, {
  String? taskType,
  int? modelCalls,
  int? outputTokens,
  int? cost,
  int? balance,
  bool pro = false,
  String? proModel,
  bool git = false,
  bool lowBalance = false,
}) {
  final buf = StringBuffer();
  final body = raw.replaceAllMapped(
    RegExp(r'<think>([\s\S]*?)<\/think>', caseSensitive: false),
    (m) {
      final inner = (m.group(1) ?? '').trim();
      if (inner.isNotEmpty) {
        if (buf.isNotEmpty) buf.write('\n\n');
        buf.write(inner);
      }
      return '';
    },
  );

  var reasoning = buf.isEmpty ? null : buf.toString();
  if (reasoning != null && reasoning.length > BotReply.kReasoningMaxChars) {
    reasoning =
        '${reasoning.substring(0, BotReply.kReasoningMaxChars)}\n… [reasoning truncated]';
  }

  return BotReply(
    text: body.trim(),
    reasoning: reasoning,
    taskType: taskType,
    modelCalls: modelCalls,
    outputTokens: outputTokens,
    cost: cost,
    balance: balance,
    pro: pro,
    proModel: proModel,
    git: git,
    lowBalance: lowBalance,
  );
}
