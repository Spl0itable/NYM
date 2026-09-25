/// Data models for the Nymbot client surface.
///
/// Field names mirror the `functions/api/bot.js` worker response shapes and the
/// client contract in `docs/specs/04-features.md` §11.2-11.5.
library;

import '../i18n/i18n.dart' show creditFigure;

const int kNominalTurnIn = 3000;
const int kNominalTurnOut = 700;

class BulkBonus {
  const BulkBonus({required this.bonus, required this.standardSats, required this.proSats});

  factory BulkBonus.fromJson(Map<String, dynamic> j) => BulkBonus(
        bonus: (j['bonus'] as num?)?.toDouble() ?? 0,
        standardSats: (j['standardSats'] as num?)?.toInt() ?? 0,
        proSats: (j['proSats'] as num?)?.toInt() ?? 0,
      );

  final double bonus;
  final int standardSats;
  final int proSats;

  int satsFor(bool pro) => pro ? proSats : standardSats;

  Map<String, dynamic> toJson() =>
      {'bonus': bonus, 'standardSats': standardSats, 'proSats': proSats};
}

const List<BulkBonus> kBulkBonusFallback = [
  BulkBonus(bonus: 0.10, standardSats: 500, proSats: 5000),
  BulkBonus(bonus: 0.15, standardSats: 1000, proSats: 10000),
  BulkBonus(bonus: 0.20, standardSats: 5000, proSats: 50000),
];

/// The Pro frontier models selectable with `?model <name>`.
///
/// Exact list + ids verified against `functions/api/bot.js` `BOT_PRO_MODELS`
/// (and README line 172 / spec §11.3). [key] is the value sent as `proModel`;
/// [label] is the README's display name; [baseCredits] is the per-call base
/// Pro-credit cost (1, except Fable = 2).
class ProModel {
  const ProModel({
    required this.key,
    required this.label,
    required this.modelId,
    required this.baseCredits,
    this.inUsdPerMTok,
    this.outUsdPerMTok,
    this.cacheReadUsdPerMTok,
    this.max,
    this.description = '',
    this.author = '',
    this.authorSlug = '',
    this.vision = false,
    this.reasoning = false,
    this.tools = false,
    this.context,
    this.hosting = '',
    this.priced = true,
  });

  /// One entry from the worker's `models` action, which serves the live
  /// Cloudflare catalog (mirrored hourly into D1) rather than [kProModels].
  factory ProModel.fromJson(Map<String, dynamic> j) {
    int? asInt(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
    return ProModel(
      key: (j['key'] ?? '').toString(),
      label: (j['label'] ?? j['key'] ?? '').toString(),
      // The live catalog keys by slug and carries the id separately; older
      // payloads may omit it.
      modelId: (j['model'] ?? j['modelId'] ?? '').toString(),
      baseCredits: asInt(j['credits']) ?? asInt(j['baseCredits']) ?? 1,
      inUsdPerMTok: (j['inUsdPerMTok'] as num?)?.toDouble(),
      outUsdPerMTok: (j['outUsdPerMTok'] as num?)?.toDouble(),
      cacheReadUsdPerMTok: (j['cacheReadUsdPerMTok'] as num?)?.toDouble(),
      max: asInt(j['max']),
      description: (j['description'] ?? '').toString(),
      author: (j['author'] ?? '').toString(),
      authorSlug: (j['authorSlug'] ?? '').toString(),
      vision: j['vision'] == true,
      reasoning: j['reasoning'] == true,
      tools: j['tools'] == true,
      context: asInt(j['context']),
      hosting: (j['hosting'] ?? '').toString(),
      // Absent means "assume priced" so an older worker doesn't gray the list.
      priced: j['priced'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'label': label,
        'model': modelId,
        'credits': baseCredits,
        if (inUsdPerMTok != null) 'inUsdPerMTok': inUsdPerMTok,
        if (outUsdPerMTok != null) 'outUsdPerMTok': outUsdPerMTok,
        if (cacheReadUsdPerMTok != null) 'cacheReadUsdPerMTok': cacheReadUsdPerMTok,
        if (max != null) 'max': max,
        if (description.isNotEmpty) 'description': description,
        if (author.isNotEmpty) 'author': author,
        if (authorSlug.isNotEmpty) 'authorSlug': authorSlug,
        'vision': vision,
        'reasoning': reasoning,
        'tools': tools,
        if (context != null) 'context': context,
        if (hosting.isNotEmpty) 'hosting': hosting,
        'priced': priced,
      };

  /// Value passed to the worker as `proModel`, e.g. `claude-opus`.
  final String key;

  /// README display label, e.g. `Claude Opus 5`.
  final String label;

  /// Internal model id, mirroring `BOT_PRO_MODELS[key].model` in
  /// `functions/api/bot.js`. A `provider/…` slug is third-party: `anthropic/…`
  /// goes to Anthropic's native endpoint through the AI Gateway, everything
  /// else to the gateway's unified-billing one. A `@cf/…` prefix is
  /// Cloudflare-hosted and runs on the worker's AI binding directly — no
  /// gateway hop and no upstream credential, which is why DeepSeek's working
  /// entries are the `@cf/` ones. Documentation only: the client sends [key].
  final String modelId;

  /// Base Pro credits charged per model call (before length scaling).
  final int baseCredits;

  final double? inUsdPerMTok;
  final double? outUsdPerMTok;
  final double? cacheReadUsdPerMTok;

  bool get metered => (inUsdPerMTok ?? 0) > 0 && (outUsdPerMTok ?? 0) > 0;

  /// Max Pro credits a single (max-length) reply can scale to (PWA
  /// `_botProModels[].max`, pms.js:2085-2091). Null/<= [baseCredits] means the
  /// model is flat-priced. Optional so existing call sites are unaffected.
  final int? max;

  /// One-line blurb from the model's Cloudflare page. Empty for the built-in
  /// fallback entries, which predate the live catalog.
  final String description;

  /// Provider display name (`Anthropic`) and slug (`anthropic`), used to group
  /// the picker. Empty on the built-in fallback entries.
  final String author;
  final String authorSlug;

  /// Capability flags from the catalog's tags.
  final bool vision;
  final bool reasoning;
  final bool tools;

  /// Context window in tokens, when the catalog knows it.
  final int? context;

  /// `cloudflare-hosted` or `third-party`, from the catalog. Empty when the
  /// worker predates the field. Only used to badge the row.
  final String hosting;

  /// Whether Cloudflare runs the weights itself, so the call needs no gateway
  /// and no upstream provider credential.
  bool get cloudflareHosted =>
      hosting == 'cloudflare-hosted' || modelId.startsWith('@cf/');

  /// False when Cloudflare publishes no price for the model, so the worker is
  /// charging its conservative default. Shown as a caveat rather than hidden.
  final bool priced;

  double? turnCredits(double usdPerCredit, double minChargeCredits) {
    if (!metered || usdPerCredit <= 0) return null;
    final spend = (kNominalTurnIn * inUsdPerMTok! +
            kNominalTurnOut * outUsdPerMTok!) /
        1e6 /
        usdPerCredit;
    return spend < minChargeCredits ? minChargeCredits : spend;
  }

  String turnLabel(double usdPerCredit, double minChargeCredits) {
    final turn = turnCredits(usdPerCredit, minChargeCredits);
    if (turn != null) {
      final n = creditFigure(turn);
      return '~$n credit${n == '1' ? '' : 's'} a turn';
    }
    final base = '$baseCredits Pro credit${baseCredits == 1 ? '' : 's'}';
    final m = max;
    return (m != null && m > baseCredits)
        ? 'from $base, up to $m for max-length replies'
        : '$base/reply';
  }

  String? ratesLabel() {
    if (!metered) return null;
    final cached = (cacheReadUsdPerMTok ?? 0) > 0
        ? ', \$$cacheReadUsdPerMTok/M cached'
        : '';
    return '\$$inUsdPerMTok/M in, \$$outUsdPerMTok/M out$cached';
  }

  String priceLine(double usdPerCredit, double minChargeCredits) {
    final rates = ratesLabel();
    final turn = turnLabel(usdPerCredit, minChargeCredits);
    return rates == null ? turn : '$turn · $rates';
  }

  String get priceLabel => ratesLabel() ?? turnLabel(0.0, 0.0);
}

/// The built-in Pro models, in README order (line 172): Claude Fable 5, Claude
/// Opus 5, Claude Sonnet 5, Claude Haiku 4.5, GPT-5.6 Sol, GPT-5.4 mini, Gemini
/// 3.1 Pro, Gemini 3.6 Flash, Grok 4.6, Kimi K3, Qwen 3.5, MiniMax M3, then the
/// Cloudflare-hosted DeepSeek entries.
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
    label: 'Claude Opus 5',
    modelId: 'anthropic/claude-opus-5',
    baseCredits: 1,
    max: 8,
  ),
  ProModel(
    key: 'claude-sonnet',
    label: 'Claude Sonnet 5',
    modelId: 'anthropic/claude-sonnet-5',
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
    label: 'GPT-5.6 Sol',
    modelId: 'openai/gpt-5.6-sol',
    baseCredits: 1,
    max: 6,
  ),
  ProModel(
    key: 'gpt-5-mini',
    label: 'GPT-5.4 mini',
    modelId: 'openai/gpt-5.4-mini',
    baseCredits: 1,
    max: 1,
  ),
  ProModel(
    key: 'gemini-pro',
    label: 'Gemini 3.1 Pro',
    modelId: 'google/gemini-3.1-pro',
    baseCredits: 1,
    max: 5,
  ),
  ProModel(
    key: 'gemini-flash',
    label: 'Gemini 3.6 Flash',
    modelId: 'google/gemini-3.6-flash',
    baseCredits: 1,
    max: 3,
  ),
  ProModel(
    key: 'grok',
    label: 'Grok 4.6',
    modelId: 'xai/grok-4.6',
    baseCredits: 1,
    max: 6,
  ),
  ProModel(
    key: 'kimi',
    label: 'Kimi K3',
    modelId: 'moonshotai/kimi-k3',
    baseCredits: 1,
    max: 3,
  ),
  ProModel(
    key: 'qwen',
    label: 'Qwen 3.5',
    modelId: 'alibaba/qwen3.5-397b-a17b',
    baseCredits: 1,
    max: 3,
  ),
  ProModel(
    key: 'minimax',
    label: 'MiniMax M3',
    modelId: 'minimax/m3',
    baseCredits: 1,
    max: 3,
  ),
  // Cloudflare-hosted. DeepSeek's third-party route is rejected by its
  // upstream provider; these run on the worker's AI binding and answer.
  ProModel(
    key: 'deepseek-v4-pro',
    label: 'DeepSeek V4 Pro',
    modelId: '@cf/deepseek-ai/deepseek-v4-pro-0813',
    baseCredits: 1,
    max: 3,
    author: 'DeepSeek',
    authorSlug: 'deepseek',
    hosting: 'cloudflare-hosted',
    reasoning: true,
    tools: true,
  ),
  ProModel(
    key: 'deepseek-v4-flash',
    label: 'DeepSeek V4 Flash',
    modelId: '@cf/deepseek-ai/deepseek-v4-flash-0731',
    baseCredits: 1,
    max: 1,
    author: 'DeepSeek',
    authorSlug: 'deepseek',
    hosting: 'cloudflare-hosted',
    reasoning: true,
    tools: true,
  ),
  ProModel(
    key: 'deepseek-r1-distill-qwen-32b',
    label: 'DeepSeek R1 Distill Qwen 32B',
    modelId: '@cf/deepseek-ai/deepseek-r1-distill-qwen-32b',
    baseCredits: 1,
    max: 3,
    author: 'DeepSeek',
    authorSlug: 'deepseek',
    hosting: 'cloudflare-hosted',
    reasoning: true,
  ),
];

/// Retired `?model` keys, mapped to their replacements. Mirrors
/// `BOT_PRO_MODEL_ALIASES` in `functions/api/bot.js` so a preference persisted
/// by an older build still resolves instead of silently reverting to standard
/// routing.
const Map<String, String> kProModelAliases = {
  'codex': 'gpt-5',
  'claude-opus-4.8': 'claude-opus',
  'claude-sonnet-4.6': 'claude-sonnet',
  'deepseek': 'deepseek-v4-pro',
  'deepseek-v4': 'deepseek-v4-pro',
};

/// One provider's models in the picker, in the order the worker returned them.
class ProModelGroup {
  const ProModelGroup({
    required this.author,
    required this.authorSlug,
    required this.keys,
  });

  factory ProModelGroup.fromJson(Map<String, dynamic> j) {
    final rawKeys = j['keys'];
    return ProModelGroup(
      author: (j['author'] ?? '').toString(),
      authorSlug: (j['authorSlug'] ?? '').toString(),
      keys: [
        for (final k in (rawKeys is List ? rawKeys : const [])) k.toString(),
      ],
    );
  }

  Map<String, dynamic> toJson() =>
      {'author': author, 'authorSlug': authorSlug, 'keys': keys};

  final String author;
  final String authorSlug;
  final List<String> keys;
}

/// The Pro model list the picker renders.
///
/// [kProModelCatalogFallback] is [kProModels] — what ships in the binary and
/// what renders whenever the live catalog can't be reached. A fetched catalog
/// replaces it wholesale; nothing merges, so the worker stays the single
/// source of truth for what a reply costs.
class ProModelCatalog {
  const ProModelCatalog({
    required this.models,
    this.groups = const [],
    this.aliases = const {},
    this.source = 'builtin',
    this.fetchedAt = 0,
    this.usdPerCredit = 0.0,
    this.minChargeCredits = 0.0,
    this.bulkBonus = kBulkBonusFallback,
  });

  factory ProModelCatalog.fromJson(Map<String, dynamic> j) {
    // Every field is type-checked rather than cast: a malformed response has
    // to degrade to the built-in list, not throw out of a background refresh.
    final rawModels = j['models'];
    final rawGroups = j['groups'];
    final rawAliases = j['aliases'];
    final models = [
      for (final m in (rawModels is List ? rawModels : const []))
        if (m is Map) ProModel.fromJson(m.cast<String, dynamic>()),
    ]..removeWhere((m) => m.key.isEmpty);
    return ProModelCatalog(
      models: models,
      groups: [
        for (final g in (rawGroups is List ? rawGroups : const []))
          if (g is Map) ProModelGroup.fromJson(g.cast<String, dynamic>()),
      ],
      aliases: {
        if (rawAliases is Map)
          for (final e in rawAliases.entries)
            e.key.toString(): e.value.toString(),
      },
      source: (j['source'] ?? '').toString(),
      fetchedAt: (j['fetchedAt'] is num)
          ? (j['fetchedAt'] as num).toInt()
          : DateTime.now().millisecondsSinceEpoch,
      usdPerCredit: (j['usdPerCredit'] as num?)?.toDouble() ?? 0,
      minChargeCredits: (j['minChargeCredits'] as num?)?.toDouble() ?? 0,
      bulkBonus: () {
        final raw = j['bulkBonus'];
        if (raw is! List) return kBulkBonusFallback;
        final rows = [
          for (final r in raw)
            if (r is Map) BulkBonus.fromJson(r.cast<String, dynamic>()),
        ]..removeWhere((b) => b.bonus <= 0 || b.standardSats <= 0);
        return rows.isEmpty ? kBulkBonusFallback : rows;
      }(),
    );
  }

  Map<String, dynamic> toJson() => {
        'models': [for (final m in models) m.toJson()],
        'groups': [for (final g in groups) g.toJson()],
        'aliases': aliases,
        'source': source,
        'fetchedAt': fetchedAt,
        'usdPerCredit': usdPerCredit,
        'minChargeCredits': minChargeCredits,
        'bulkBonus': [for (final b in bulkBonus) b.toJson()],
      };

  final List<ProModel> models;
  final List<ProModelGroup> groups;

  /// Retired/short keys mapped to a current one, so a model pinned before a
  /// version bump (`claude-opus` → `claude-opus-5`) keeps resolving.
  final Map<String, String> aliases;

  /// `catalog` when the worker served the live list, `builtin` when it fell
  /// back to its own table.
  final String source;
  final int fetchedAt;

  final double usdPerCredit;
  final double minChargeCredits;

  final List<BulkBonus> bulkBonus;

  double bulkMultiplier(int sats, bool pro) {
    var best = 0.0;
    for (final row in bulkBonus) {
      final at = row.satsFor(pro);
      if (at > 0 && sats >= at && row.bonus > best) best = row.bonus;
    }
    return 1 + best;
  }

  int creditsForSats(int sats, bool pro) {
    if (sats <= 0) return 0;
    final each = pro ? 100 : 10;
    return (sats / each * bulkMultiplier(sats, pro)).floor();
  }

  String bulkBonusLine(bool pro) {
    final rows = bulkBonus.toList()
      ..sort((a, b) => a.satsFor(pro).compareTo(b.satsFor(pro)));
    if (rows.isEmpty) return '';
    final parts = rows.map((r) {
      final at = r.satsFor(pro);
      final n = at >= 1000 ? '${at ~/ 1000}K' : '$at';
      return '+${(r.bonus * 100).round()}% at $n';
    }).join(', ');
    return 'Bulk bonus: $parts sats.';
  }

  bool get isEmpty => models.isEmpty;

  ProModel? byKey(String key) {
    final k = key.trim().toLowerCase();
    if (k.isEmpty) return null;
    ProModel? exact(String want) {
      for (final m in models) {
        if (m.key == want) return m;
      }
      return null;
    }

    final direct = exact(k);
    if (direct != null) return direct;

    // Aliases chain: a retired built-in key ("claude-opus-4.8") maps to a
    // family name ("claude-opus"), which the live map maps to the current
    // model ("claude-opus-5"). Bounded, and it never revisits a key, so a
    // cycle in the served map can't hang the picker.
    var cur = k;
    final seen = <String>{cur};
    for (var hop = 0; hop < 4; hop++) {
      final next = aliases[cur] ?? kProModelAliases[cur];
      if (next == null || !seen.add(next)) break;
      final hit = exact(next);
      if (hit != null) return hit;
      cur = next;
    }

    // A full model id also resolves, for a preference stored by id.
    for (final m in models) {
      if (m.modelId.isNotEmpty && m.modelId == key) return m;
    }
    return null;
  }

  /// Groups as the picker draws them: the worker's grouping when present,
  /// otherwise one unnamed group holding everything.
  List<MapEntry<String, List<ProModel>>> grouped() {
    if (groups.isEmpty) {
      return [MapEntry('', List<ProModel>.unmodifiable(models))];
    }
    final byKeyMap = {for (final m in models) m.key: m};
    final out = <MapEntry<String, List<ProModel>>>[];
    for (final g in groups) {
      final rows = [
        for (final k in g.keys)
          if (byKeyMap[k] != null) byKeyMap[k]!,
      ];
      if (rows.isNotEmpty) out.add(MapEntry(g.author, rows));
    }
    return out;
  }
}

/// The catalog that ships in the binary — used until a live one arrives, and
/// whenever the worker is unreachable.
const ProModelCatalog kProModelCatalogFallback =
    ProModelCatalog(models: kProModels);

/// A single PM-only Nymbot command, surfaced by the `?…` suggestion palette
/// inside the private bot chat (PWA `botPMCommands`, commands.js:272-281).
class BotPMCommand {
  const BotPMCommand({required this.name, required this.desc});

  /// The command including its leading `?`, e.g. `?model`.
  final String name;

  /// One-line description shown beneath the command name.
  final String desc;
}

/// The PM-only commands the PWA shows in the Nymbot private chat, in order
/// (commands.js `botPMCommands`). NOTE: this is the *PM* set — distinct from the
/// public-channel `?` commands (`kBotCommands`), which are not wired here.
const List<BotPMCommand> kBotPMCommands = [
  BotPMCommand(
    name: '?help',
    desc: 'Guide to premium, Pro models & credits (free)',
  ),
  BotPMCommand(
    name: '?model',
    desc: 'Pick a Pro frontier model (?model off for standard)',
  ),
  BotPMCommand(
    name: '?image',
    desc: 'Generate an image (--model <name> on Pro; ?image models)',
  ),
  BotPMCommand(
    name: '?speak',
    desc: 'Read text aloud as a voice clip',
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

/// Deeper completions surfaced after `?model ` (commands.js
/// `_botPMSubcommands`). Returns the rows to show for a base command once a
/// trailing space has been typed, with each row's full insertion text.
/// Returns null when [cmd] has no subcommands.
List<BotPMCommand>? botPMSubcommands(String cmd) {
  if (cmd == '?model') {
    return [
      for (final m in kProModels)
        BotPMCommand(
            name: '?model ${m.key}', desc: '${m.label} — ${m.priceLabel}'),
      const BotPMCommand(
          name: '?model off', desc: 'Back to standard multi-model routing'),
    ];
  }
  return null;
}

/// Filters [kBotPMCommands] (and subcommands) for the `?…` palette given the
/// current input. Mirrors `showBotCommandPalette` (commands.js:436-468):
///  * a bare prefix (`?mo`) filters the 10 base commands by `startsWith`;
///  * a base command plus a space (`?model `) surfaces its subcommands filtered
///    by the remaining text.
List<BotPMCommand> filterBotPMCommands(String input) {
  // Preserve a trailing space (it's meaningful: `?model ` → show subcommands),
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
  // i.e. just-typed trailing space, lists them all).
  final sp = needle.indexOf(' ');
  final base = needle.substring(0, sp);
  final rest = needle.substring(sp + 1).trimLeft();
  final subs = botPMSubcommands(base);
  if (subs == null) return const [];
  return [
    for (final s in subs)
      if (s.name
          .toLowerCase()
          .substring(base.length)
          .trimLeft()
          .startsWith(rest))
        s,
  ];
}

/// Looks up a Pro model by its `?model` argument. Accepts the canonical [key]
/// as well as a loose match on the label (case-insensitive). Returns null for
/// unknown names or the literal `off`.
ProModel? lookupProModel(String name) {
  var n = name.trim().toLowerCase();
  if (n.isEmpty || n == 'off') return null;
  n = kProModelAliases[n] ?? n;
  for (final m in kProModels) {
    if (m.key == n) return m;
    if (m.label.toLowerCase() == n) return m;
  }
  // Loose contains match (e.g. "opus" -> Claude Opus 5).
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
    this.lowBalance = false,
  });

  /// The reply body with any reasoning block stripped out.
  final String text;

  /// The extracted reasoning (contents of `<think>…</think>`), or null.
  final String? reasoning;

  /// Auto-router classification, e.g. `coding`/`reasoning`/`creative`/
  /// `translation`/`general`/`pro` (worker `taskType`).
  final String? taskType;

  /// Number of model calls made.
  final int? modelCalls;

  /// Output tokens generated by the reply.
  final int? outputTokens;

  /// Credits charged for this reply.
  final double? cost;

  /// Remaining balance after the reply (tier depends on [pro]).
  final double? balance;

  /// True when answered by a pinned Pro model.
  final bool pro;

  /// The Pro model key used, when [pro].
  final String? proModel;

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

  final double balance; // standard credits available, fractions included
  final int totalPurchased;
  final int totalUsed;
  final double proBalance; // Pro credits available, fractions included
  final int proTotalPurchased;
  final int proTotalUsed;

  factory BotBalance.fromJson(Map<String, dynamic> j) => BotBalance(
        balance: _credits(j['balanceCredits'] ?? j['balance']),
        totalPurchased: _int(j['totalPurchased']),
        totalUsed: _int(j['totalUsed']),
        proBalance: _credits(j['proBalanceCredits'] ?? j['proBalance']),
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

double _credits(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
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
  double? cost,
  double? balance,
  bool pro = false,
  String? proModel,
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
    lowBalance: lowBalance,
  );
}
