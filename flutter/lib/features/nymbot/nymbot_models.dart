/// Nymbot client data models; field names mirror the bot worker's response shapes.
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

/// A Pro model selectable with `?model <name>`; [key] is sent as `proModel`.
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

  /// One entry from the worker's live `models` catalog.
  factory ProModel.fromJson(Map<String, dynamic> j) {
    int? asInt(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
    return ProModel(
      key: (j['key'] ?? '').toString(),
      label: (j['label'] ?? j['key'] ?? '').toString(),
      // The live catalog keys by slug with the id separate; older payloads may omit it.
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
      // Absent means priced, so an older worker doesn't gray out the list.
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

  /// Sent to the worker as `proModel`, e.g. `claude-opus`.
  final String key;

  final String label;

  /// Internal model id, for documentation only; the client sends [key].
  final String modelId;

  /// Base Pro credits per call, before length scaling.
  final int baseCredits;

  final double? inUsdPerMTok;
  final double? outUsdPerMTok;
  final double? cacheReadUsdPerMTok;

  bool get metered => (inUsdPerMTok ?? 0) > 0 && (outUsdPerMTok ?? 0) > 0;

  /// Max Pro credits a max-length reply can scale to; null or <= [baseCredits] means flat-priced.
  final int? max;

  /// One-line blurb; empty on built-in fallback entries.
  final String description;

  /// Provider name and slug for grouping; empty on built-in fallback entries.
  final String author;
  final String authorSlug;

  /// Capability flags from the catalog's tags.
  final bool vision;
  final bool reasoning;
  final bool tools;

  /// Context window in tokens, when known.
  final int? context;

  /// `cloudflare-hosted` or `third-party`; empty on older workers; only used for a badge.
  final String hosting;

  /// Cloudflare runs the weights, so no gateway or upstream credential is needed.
  bool get cloudflareHosted =>
      hosting == 'cloudflare-hosted' || modelId.startsWith('@cf/');

  /// False when Cloudflare publishes no price and the worker charges its conservative default.
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

/// Built-in Pro models in README order.
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
  // Cloudflare-hosted; DeepSeek's third-party route is rejected upstream.
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

/// Retired `?model` keys mapped to replacements, so older persisted preferences still resolve.
const Map<String, String> kProModelAliases = {
  'codex': 'gpt-5',
  'claude-opus-4.8': 'claude-opus',
  'claude-sonnet-4.6': 'claude-sonnet',
  'deepseek': 'deepseek-v4-pro',
  'deepseek-v4': 'deepseek-v4-pro',
};

/// One provider's models, in worker order.
class ProModelGroup {
  const ProModelGroup({
    required this.author,
    required this.authorSlug,
    required this.keys,
    this.kind = '',
  });

  factory ProModelGroup.fromJson(Map<String, dynamic> j) {
    final rawKeys = j['keys'];
    return ProModelGroup(
      author: (j['author'] ?? '').toString(),
      authorSlug: (j['authorSlug'] ?? '').toString(),
      kind: (j['kind'] ?? '').toString(),
      keys: [
        for (final k in (rawKeys is List ? rawKeys : const [])) k.toString(),
      ],
    );
  }

  Map<String, dynamic> toJson() => {
        'author': author,
        'authorSlug': authorSlug,
        if (kind.isNotEmpty) 'kind': kind,
        'keys': keys,
      };

  final String author;
  final String authorSlug;
  final List<String> keys;
  final String kind;
}

class GeneratorResolution {
  const GeneratorResolution({required this.res, this.credits});

  factory GeneratorResolution.fromJson(Map<String, dynamic> j) =>
      GeneratorResolution(
        res: (j['res'] ?? '').toString(),
        credits: j['credits'] is num ? j['credits'] as num : null,
      );

  Map<String, dynamic> toJson() => {'res': res, 'credits': credits};

  final String res;
  final num? credits;
}

class ProGenerator {
  const ProGenerator({
    required this.key,
    required this.kind,
    required this.command,
    required this.label,
    this.credits,
    this.priced = true,
    this.needsImage = false,
    this.author = '',
    this.authorSlug = '',
    this.description = '',
    this.resolution,
    this.resolutions = const [],
  });

  factory ProGenerator.fromJson(Map<String, dynamic> j) {
    final rawRes = j['resolutions'];
    final resolutions = [
      for (final r in (rawRes is List ? rawRes : const []))
        if (r is Map) GeneratorResolution.fromJson(r.cast<String, dynamic>()),
    ]..removeWhere((r) => r.res.isEmpty);
    final res = (j['resolution'] ?? '').toString();
    return ProGenerator(
      key: (j['key'] ?? '').toString(),
      kind: (j['kind'] ?? '').toString(),
      command: (j['command'] ?? '').toString().trim(),
      label: (j['label'] ?? j['key'] ?? '').toString(),
      credits: j['credits'] is num ? j['credits'] as num : null,
      priced: j['priced'] != false,
      needsImage: j['needsImage'] == true,
      author: (j['author'] ?? '').toString(),
      authorSlug: (j['authorSlug'] ?? '').toString(),
      description: (j['description'] ?? '').toString(),
      resolution: res.isNotEmpty
          ? res
          : (resolutions.isEmpty ? null : resolutions.last.res),
      resolutions: resolutions,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'kind': kind,
        'command': command,
        'label': label,
        'credits': credits,
        'priced': priced,
        'needsImage': needsImage,
        if (author.isNotEmpty) 'author': author,
        if (authorSlug.isNotEmpty) 'authorSlug': authorSlug,
        if (description.isNotEmpty) 'description': description,
        if (resolution != null) 'resolution': resolution,
        if (resolutions.isNotEmpty)
          'resolutions': [for (final r in resolutions) r.toJson()],
      };

  final String key;
  final String kind;
  final String command;
  final String label;
  final num? credits;
  final bool priced;
  final bool needsImage;
  final String author;
  final String authorSlug;
  final String description;
  final String? resolution;
  final List<GeneratorResolution> resolutions;

  bool get isVideo => kind == 'video';

  String insertText([String? res]) =>
      (res == null || res.isEmpty || res == resolution)
          ? '$command '
          : '$command --res $res ';
}

/// The picker's model list; a fetched catalog replaces the built-in one wholesale, keeping the worker authoritative on cost.
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
    this.generators = const [],
    this.priceUnavailable = false,
    this.btcUsd,
    this.standardUsdPerCredit,
  });

  factory ProModelCatalog.fromJson(Map<String, dynamic> j) {
    // Type-check every field so a malformed response degrades to the built-in list instead of throwing.
    final rawModels = j['models'];
    final rawGroups = j['groups'];
    final rawAliases = j['aliases'];
    final models = [
      for (final m in (rawModels is List ? rawModels : const []))
        if (m is Map && (m['kind'] == null || m['kind'] == 'chat') && m['command'] == null)
          ProModel.fromJson(m.cast<String, dynamic>()),
    ]..removeWhere((m) => m.key.isEmpty);
    final generators = [
      for (final m in (rawModels is List ? rawModels : const []))
        if (m is Map &&
            (m['kind'] == 'image' || m['kind'] == 'video') &&
            m['command'] is String)
          ProGenerator.fromJson(m.cast<String, dynamic>()),
    ]..removeWhere((g) => g.key.isEmpty || g.command.isEmpty);
    double? price(Object? v) => v is num && v > 0 ? v.toDouble() : null;
    return ProModelCatalog(
      models: models,
      generators: generators,
      priceUnavailable: j['priceUnavailable'] == true,
      btcUsd: price(j['btcUsd']),
      standardUsdPerCredit: price(j['standardUsdPerCredit']),
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
        'models': [
          for (final m in models) m.toJson(),
          for (final g in generators) g.toJson(),
        ],
        'groups': [for (final g in groups) g.toJson()],
        'aliases': aliases,
        'source': source,
        'fetchedAt': fetchedAt,
        'usdPerCredit': usdPerCredit,
        'minChargeCredits': minChargeCredits,
        'bulkBonus': [for (final b in bulkBonus) b.toJson()],
        if (priceUnavailable) 'priceUnavailable': true,
        'btcUsd': btcUsd,
        'standardUsdPerCredit': standardUsdPerCredit,
      };

  final List<ProModel> models;
  final List<ProGenerator> generators;
  final bool priceUnavailable;
  final double? btcUsd;
  final double? standardUsdPerCredit;
  final List<ProModelGroup> groups;

  /// Retired or short keys mapped to current ones.
  final Map<String, String> aliases;

  /// `catalog` for the worker's live list, `builtin` for its fallback table.
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

    // Aliases chain (retired key -> family -> current); bounded and cycle-safe.
    var cur = k;
    final seen = <String>{cur};
    for (var hop = 0; hop < 4; hop++) {
      final next = aliases[cur] ?? kProModelAliases[cur];
      if (next == null || !seen.add(next)) break;
      final hit = exact(next);
      if (hit != null) return hit;
      cur = next;
    }

    // A full model id also resolves.
    for (final m in models) {
      if (m.modelId.isNotEmpty && m.modelId == key) return m;
    }
    return null;
  }

  /// The worker's grouping when present, else one unnamed group.
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

  List<MapEntry<String, List<ProGenerator>>> groupedGenerators() {
    final byKeyMap = {for (final g in generators) g.key: g};
    final placed = <String>{};
    final byAuthor = <String, List<ProGenerator>>{};
    void add(String author, ProGenerator gen) {
      if (!placed.add(gen.key)) return;
      byAuthor.putIfAbsent(author, () => []).add(gen);
    }

    for (final g in groups) {
      for (final k in g.keys) {
        final gen = byKeyMap[k];
        if (gen != null) add(g.author, gen);
      }
    }
    for (final gen in generators) {
      add(gen.author, gen);
    }
    return [for (final e in byAuthor.entries) MapEntry(e.key, e.value)];
  }
}

/// Built-in catalog used until a live one arrives or when the worker is unreachable.
const ProModelCatalog kProModelCatalogFallback =
    ProModelCatalog(models: kProModels);

/// A PM-only Nymbot command for the private bot chat's `?` palette.
class BotPMCommand {
  const BotPMCommand({required this.name, required this.desc});

  /// The command including its leading `?`, e.g. `?model`.
  final String name;

  final String desc;
}

/// PM-only commands in order, distinct from the public `?` set.
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

/// Completions after `?model `, with each row's full insertion text; null without subcommands.
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

/// `?mo` filters base commands by prefix; `?model ` lists its subcommands filtered by the rest.
List<BotPMCommand> filterBotPMCommands(String input) {
  // Keep a trailing space (it triggers subcommands) but ignore leading whitespace.
  final needle = input.trimLeft().toLowerCase();
  if (needle.isEmpty || !needle.startsWith('?')) return const [];

  if (!needle.contains(' ')) {
    return [
      for (final c in kBotPMCommands)
        if (c.name.startsWith(needle)) c,
    ];
  }

  // Empty rest lists every subcommand.
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

/// Looks up a Pro model by key or loose label match; null for unknown names or `off`.
ProModel? lookupProModel(String name) {
  var n = name.trim().toLowerCase();
  if (n.isEmpty || n == 'off') return null;
  n = kProModelAliases[n] ?? n;
  for (final m in kProModels) {
    if (m.key == n) return m;
    if (m.label.toLowerCase() == n) return m;
  }
  // Loose contains match, e.g. "opus".
  for (final m in kProModels) {
    if (m.label.toLowerCase().contains(n) || m.key.contains(n)) return m;
  }
  return null;
}

/// A bot reply split into visible text and optional `<think>` reasoning.
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

  final String text;

  /// Contents of `<think>…</think>`, or null.
  final String? reasoning;

  /// Auto-router classification, e.g. `coding`, `reasoning`, `pro`.
  final String? taskType;

  final int? modelCalls;

  final int? outputTokens;

  /// Credits charged for this reply.
  final double? cost;

  /// Remaining balance after the reply; tier depends on [pro].
  final double? balance;

  final bool pro;

  final String? proModel;

  final bool lowBalance;

  bool get hasReasoning => reasoning != null && reasoning!.trim().isNotEmpty;

  /// Matches the worker's reasoning cap.
  static const int kReasoningMaxChars = 4000;
}

/// Standard and Pro credit balances.
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

enum CreditTier { standard, pro }

extension CreditTierWire on CreditTier {
  String get wire => this == CreditTier.pro ? 'pro' : 'standard';

  /// Standard = 10, Pro = 100.
  int get satsPerCredit => this == CreditTier.pro ? 100 : 10;
}

/// A Lightning invoice from `action: create-invoice`.
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

  /// BOLT11 invoice string.
  final String pr;

  /// SHA256 of [pr], used to poll `check-invoice` / `claim-credits`.
  final String invoiceId;

  /// LUD-21 verify URL, when the wallet supports it.
  final String? verify;

  /// True when the server can verify payment itself (NWC).
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

/// Moves every case-insensitive `<think>…</think>` block out of the body into [BotReply.reasoning], newline-joined.
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
